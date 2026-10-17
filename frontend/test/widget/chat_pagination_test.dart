import 'dart:async';
import 'dart:math' as math;

import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_timeline.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:communication_platform/features/messaging/presentation/chat_message_builder.dart';
import 'package:communication_platform/features/messaging/presentation/chat_timeline_adapter.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_model_mapper.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/conversation_history_harness.dart';

const _conversationId = 'conversation';

/// The three things a window silently breaks, driven end to end.
///
/// The repository, the window and the timeline widget are all real here,
/// against a real database, because each of these failures lives in the seam
/// between two of them: a page that arrives without the reader's position, a
/// jump whose target was never loaded, and a message that arrives while the
/// reader is somewhere else entirely.
void main() {
  late LocalDatabase database;
  late ConversationTimelineWindow window;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    await database.customSelect('SELECT 1').getSingle();
    await seedConversationHistory(
      database,
      conversationId: _conversationId,
      messages: 300,
      withChildren: false,
    );
    window = ConversationTimelineWindow(
      repository: DriftConversationDomainRepository(database),
      currentUserId: 'self',
      conversationId: _conversationId,
      pageSize: 40,
    );
  });

  tearDown(() async {
    await window.dispose();
    await database.close();
  });

  testWidgets('loading an older page leaves the reader on the same line', (
    tester,
  ) async {
    await _pump(tester, window);
    expect(_loaded(tester), 40);

    // Somewhere into the loaded history, so there is a line to keep.
    await tester.drag(
      find.byKey(const PageStorageKey('chat-timeline')),
      const Offset(0, 700),
    );
    await tester.pumpAndSettle();

    final anchor = find.byKey(ValueKey('message-${_topmostVisible(tester)}'));
    expect(anchor, findsOneWidget);
    final before = tester.getTopLeft(anchor).dy;

    await _loadOlder(tester, window);

    // A page arrived from the database, not merely from the widget's own
    // window, and the reader did not move.
    expect(_loaded(tester), 80);
    expect(anchor, findsOneWidget);
    expect((tester.getTopLeft(anchor).dy - before).abs(), lessThan(1.1));
  });

  testWidgets('a jump resolves a message older than anything loaded', (
    tester,
  ) async {
    final state = await _pump(tester, window);
    expect(_loaded(tester), 40);

    // The oldest message in the conversation: 260 messages below the window,
    // and the kind of target the pinned banner and a search hit both produce.
    final target = conversationMessageId(_conversationId, 0);
    expect(find.byKey(ValueKey('message-$target')), findsNothing);

    state.jumpTo(target);
    await tester.pumpAndSettle();

    // The window opened far enough back to contain it, and the timeline
    // resolved the jump it could not resolve when it was asked.
    expect(_loaded(tester), 300);
    expect(find.byKey(ValueKey('message-$target')), findsOneWidget);
  });

  testWidgets('a message arriving leaves the reader on the same line', (
    tester,
  ) async {
    await _pump(tester, window);
    // Somewhere into the loaded history, so there is a line to keep. A reader
    // sitting at the newest end has none, and being pushed along by an
    // arrival is what they want.
    await tester.drag(
      find.byKey(const PageStorageKey('chat-timeline')),
      const Offset(0, 700),
    );
    await tester.pumpAndSettle();

    final anchor = find.byKey(ValueKey('message-${_topmostVisible(tester)}'));
    final before = tester.getTopLeft(anchor).dy;

    await appendConversationMessage(
      database,
      conversationId: _conversationId,
      index: 300,
    );
    await tester.pumpAndSettle();

    // The arrival went in at the newest end, which in a reversed viewport
    // moves everything older than it by the height of the new bubble. The
    // anchor is what takes that back out again.
    expect(anchor, findsOneWidget);
    expect((tester.getTopLeft(anchor).dy - before).abs(), lessThan(1.1));
  });

  testWidgets('the anchor registry stays bounded while the reader scrolls', (
    tester,
  ) async {
    final state = await _pump(tester, window);
    // The whole conversation, loaded and drawn: a jump to the oldest message
    // opens the window to all three hundred and widens what the widget draws
    // to match, which is the largest this screen ever gets.
    final oldest = conversationMessageId(_conversationId, 0);
    state.jumpTo(oldest);
    await tester.pumpAndSettle();
    expect(_loaded(tester), 300);

    final adapter = tester.state<ChatTimelineAdapterState>(
      find.byType(ChatTimelineAdapter),
    );
    var highWater = adapter.anchoredRowCount;
    var retainedHighWater = adapter.retainedRowCount;
    for (var step = 0; step < 14; step++) {
      await tester.drag(
        find.byKey(const PageStorageKey('chat-timeline')),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      highWater = math.max(highWater, adapter.anchoredRowCount);
      retainedHighWater = math.max(retainedHighWater, adapter.retainedRowCount);
    }

    // Three hundred messages have been on screen. What is registered for
    // anchoring is what is mounted, and what is retained for reuse is two
    // frames of that — neither is a function of how far anybody scrolled.
    expect(highWater, lessThan(60));
    expect(retainedHighWater, lessThan(140));
    expect(adapter.anchoredRowCount, lessThan(60));

    // Back at the newest end, so nothing near the far end is mounted any more
    // and every row that was registered for it has been dropped. A jump still
    // finds its target, which is the call site the key map was quietly also
    // serving.
    final evicted = conversationMessageId(_conversationId, 250);
    expect(find.byKey(ValueKey('message-$evicted')), findsNothing);
    state.jumpTo(evicted);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('message-$evicted')), findsOneWidget);
  });

  testWidgets('a message arriving appears while the reader is paged back', (
    tester,
  ) async {
    await _pump(tester, window);
    await _loadOlder(tester, window);
    await _loadOlder(tester, window);
    expect(_loaded(tester), 120);
    final oldestLoaded = conversationMessageId(_conversationId, 180);
    expect(_messageIds(tester).first, oldestLoaded);

    await appendConversationMessage(
      database,
      conversationId: _conversationId,
      index: 300,
    );
    await tester.pumpAndSettle();

    // The window is anchored at its lower bound, so the new message joins it
    // without pushing the oldest loaded message back out — which is what a
    // count-from-the-top window would have done, moving the line the reader is
    // on every time anybody said anything.
    expect(_loaded(tester), 121);
    expect(_messageIds(tester).first, oldestLoaded);
    expect(
      _messageIds(tester).last,
      conversationMessageId(_conversationId, 300),
    );
  });
}

Future<void> _loadOlder(
  WidgetTester tester,
  ConversationTimelineWindow window,
) async {
  await window.loadOlder();
  await tester.pumpAndSettle();
}

/// The id of the message nearest the top of the viewport.
String _topmostVisible(WidgetTester tester) {
  final viewport = tester.getRect(
    find.byKey(const PageStorageKey('chat-timeline')),
  );
  String? best;
  var bestTop = double.infinity;
  for (final element in find.byType(ChatMessageBuilder).evaluate()) {
    final box = element.renderObject! as RenderBox;
    final top = box.localToGlobal(Offset.zero).dy;
    if (top < viewport.top || top > viewport.bottom - 40) continue;
    if (top < bestTop) {
      bestTop = top;
      best = (element.widget as ChatMessageBuilder).message.id;
    }
  }
  return best!;
}

List<String> _messageIds(WidgetTester tester) => tester
    .state<_HarnessState>(find.byType(_Harness))
    .messages
    .map((message) => message.id)
    .toList(growable: false);

int _loaded(WidgetTester tester) => _messageIds(tester).length;

Future<_HarnessState> _pump(
  WidgetTester tester,
  ConversationTimelineWindow window,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          AppDesignSystem(child: child ?? const SizedBox.shrink()),
      home: Scaffold(body: _Harness(window: window)),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_HarnessState>(find.byType(_Harness));
}

/// The chat page's half of the contract, and nothing else.
///
/// It watches the window, maps its page, and turns the two intents that move
/// the window back into calls on it — which is exactly what
/// `ChatConversationPage` does around a `StreamProvider`.
class _Harness extends StatefulWidget {
  const _Harness({required this.window});

  final ConversationTimelineWindow window;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  ConversationTimelineState? _state;
  ChatJumpRequest? _jump;
  var _jumpSerial = 0;
  StreamSubscription<ConversationTimelineState>? _subscription;

  List<ChatMessageViewModel> get messages => _model?.messages ?? const [];
  ChatTimelineViewModel? _model;

  void jumpTo(String messageId) {
    setState(() => _jump = ChatJumpRequest(messageId, ++_jumpSerial));
    unawaited(widget.window.reveal(messageId));
  }

  @override
  void initState() {
    super.initState();
    _subscription = widget.window.states.listen((state) {
      if (mounted) setState(() => _state = state);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state == null) return const SizedBox.shrink();
    final model = ChatTimelineViewModel(
      state: state.page.messages.isEmpty
          ? ChatTimelineLoadState.empty
          : ChatTimelineLoadState.data,
      conversationId: _conversationId,
      title: 'Peer',
      savedMessages: false,
      securityGate: ChatSecurityGate.ready,
      offline: false,
      hasMoreBefore: state.page.hasMoreBefore,
      loadingBefore: state.loadingBefore,
      olderLoadFailed: state.olderLoadFailed,
      typing: false,
      pinnedMessages: ChatViewModelMapper.messages(
        state.page.pinned,
        currentUserId: 'self',
        currentUserName: 'You',
        peerName: 'Peer',
      ),
      messages: ChatViewModelMapper.messages(
        state.page.messages,
        currentUserId: 'self',
        currentUserName: 'You',
        peerName: 'Peer',
      ),
      jump: _jump,
    );
    _model = model;
    return SizedBox(
      height: 620,
      child: ChatTimelineAdapter(
        model: model,
        onIntent: (intent) {
          if (intent is LoadOlderMessagesIntent) {
            unawaited(widget.window.loadOlder());
          }
          if (intent case JumpToMessageIntent(:final messageId)) {
            jumpTo(messageId);
          }
        },
      ),
    );
  }
}
