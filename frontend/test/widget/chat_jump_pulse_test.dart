import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_message_builder.dart';
import 'package:communication_platform/features/messaging/presentation/chat_timeline_adapter.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_pulse.dart';

const _count = 60;

/// A jump to a message pulses it, once, and leaves nothing behind.
///
/// The timeline is the real adapter. The host around it does what a chat page
/// does: it answers a jump with a new request, so a second tap on the same
/// message is a different request from the first.
void main() {
  testWidgets('a jump pulses the message and the tint then clears', (
    tester,
  ) async {
    await _pump(tester);
    final target = _id(3);

    _host(tester).jumpTo(target);
    final first = await pumpUntilPulse(tester, target);
    expect(first, closeTo(chatPulsePeak, .05));

    // It fades: a later reading is fainter and still there.
    await tester.pump(const Duration(milliseconds: 900));
    final later = pulseStrength(tester, target);
    expect(later, greaterThan(0));
    expect(later, lessThan(first));

    // After the pulse nothing stays, on the target or anywhere else.
    await tester.pump(AppMotion.pulse);
    await tester.pump();
    expect(pulseStrength(tester, target), 0);
    for (final builder in tester.widgetList<ChatMessageBuilder>(
      find.byType(ChatMessageBuilder),
    )) {
      expect(builder.pulse, isNull, reason: builder.message.id);
    }
    expect(find.byType(ChatTimelineAdapter), findsOneWidget);
  });

  testWidgets('the pulse is a tint, and the bubble keeps its 1 px border', (
    tester,
  ) async {
    await _pump(tester);
    final target = _id(3);
    double borderWidth() =>
        ((tester
                            .widget<AnimatedContainer>(
                              find.byKey(ValueKey('message-$target')),
                            )
                            .decoration!
                        as BoxDecoration)
                    .border!
                as Border)
            .top
            .width;

    _host(tester).jumpTo(target);
    await pumpUntilPulse(tester, target);
    expect(borderWidth(), 1);
    await tester.pumpAndSettle();
    expect(borderWidth(), 1);
  });

  testWidgets('a second jump to the same message scrolls and pulses again', (
    tester,
  ) async {
    await _pump(tester);
    final target = _id(3);
    final timeline = find.byKey(const PageStorageKey('chat-timeline'));

    _host(tester).jumpTo(target);
    await pumpUntilPulse(tester, target);
    await tester.pumpAndSettle();
    expect(_onScreen(tester, target), isTrue);
    expect(pulseStrength(tester, target), 0);

    // Back to the newest end, so the target is somewhere else entirely.
    for (var step = 0; step < 12; step++) {
      await tester.drag(timeline, const Offset(0, -900));
      await tester.pumpAndSettle();
    }
    expect(_onScreen(tester, target), isFalse);

    _host(tester).jumpTo(target);
    final second = await pumpUntilPulse(tester, target);
    expect(second, closeTo(chatPulsePeak, .05));
    await tester.pumpAndSettle();
    expect(_onScreen(tester, target), isTrue);
    expect(pulseStrength(tester, target), 0);
  });

  testWidgets('a jump while a pulse is running restarts it at full tint', (
    tester,
  ) async {
    await _pump(tester);
    final target = _id(3);

    _host(tester).jumpTo(target);
    await pumpUntilPulse(tester, target);
    await tester.pump(const Duration(milliseconds: 900));
    final fading = pulseStrength(tester, target);

    // The tap ends the old pulse as the new jump begins, and the new pulse
    // starts when the scroll has arrived - from full tint again.
    _host(tester).jumpTo(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(pulseStrength(tester, target), 0);
    final again = await pumpUntilPulse(tester, target);
    expect(again, greaterThan(fading));
    expect(again, closeTo(chatPulsePeak, .05));
    await tester.pumpAndSettle();
    expect(pulseStrength(tester, target), 0);
  });

  testWidgets('with reduced motion the tint is steady for 1 s and then goes', (
    tester,
  ) async {
    await _pump(tester, reducedMotion: true);
    final target = _id(3);

    _host(tester).jumpTo(target);
    final first = await pumpUntilPulse(tester, target);
    // Full strength and no fade, however long it has been showing.
    expect(first, closeTo(chatPulsePeak, 1e-9));
    await tester.pump(const Duration(milliseconds: 500));
    expect(pulseStrength(tester, target), closeTo(chatPulsePeak, 1e-9));

    // It was first seen within one step of its start: still there at about
    // 0.8 s, gone at about 1.1 s. The times are the spec's, not the constant's.
    await tester.pump(const Duration(milliseconds: 300));
    expect(pulseStrength(tester, target), closeTo(chatPulsePeak, 1e-9));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(pulseStrength(tester, target), 0);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a jump to a message outside the window arrives with the page', (
    tester,
  ) async {
    await _pump(tester, loadedFrom: 40);
    final target = _id(5);
    expect(find.byKey(ValueKey('message-$target')), findsNothing);

    _host(tester).jumpTo(target);
    await tester.pumpAndSettle();
    // Nothing to scroll to yet, and nothing pulses.
    expect(find.byKey(ValueKey('message-$target')), findsNothing);

    // The page that carries it arrives later, as the window widening does.
    _host(tester).loadAll();
    await tester.pump();
    final strength = await pumpUntilPulse(tester, target);
    expect(strength, closeTo(chatPulsePeak, .05));
    await tester.pumpAndSettle();
    expect(_onScreen(tester, target), isTrue);
    expect(pulseStrength(tester, target), 0);
  });

  testWidgets('a tap on a reply quote pulses the message it quotes', (
    tester,
  ) async {
    final messages = [
      for (var index = 0; index < 40; index++)
        _message(
          index,
          replyToMessageId: index == 39 ? _id(2) : null,
          replyQuote: index == 39 ? 'quoted-body' : null,
        ),
    ];
    await _pumpApp(
      tester,
      ChatConversationView(
        model: _timeline(messages, hasMoreBefore: false),
        onIntent: (_) {},
      ),
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('message-${_id(39)}')),
        matching: find.text('quoted-body'),
      ),
    );
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    final strength = await pumpUntilPulse(tester, _id(2));
    expect(strength, closeTo(chatPulsePeak, .05));
    await tester.pumpAndSettle();
    expect(pulseStrength(tester, _id(2)), 0);
    expect(_onScreen(tester, _id(2)), isTrue);
  });
}

_HostState _host(WidgetTester tester) =>
    tester.state<_HostState>(find.byType(_Host));

/// Whether the bubble is inside the timeline's viewport.
bool _onScreen(WidgetTester tester, String messageId) {
  final bubble = find.byKey(ValueKey('message-$messageId'));
  if (bubble.evaluate().isEmpty) return false;
  final viewport = tester.getRect(
    find.byKey(const PageStorageKey('chat-timeline')),
  );
  final rect = tester.getRect(bubble);
  return rect.top >= viewport.top && rect.bottom <= viewport.bottom;
}

Future<void> _pump(
  WidgetTester tester, {
  bool reducedMotion = false,
  int loadedFrom = 0,
}) => _pumpApp(
  tester,
  Scaffold(body: _Host(loadedFrom: loadedFrom)),
  reducedMotion: reducedMotion,
);

Future<void> _pumpApp(
  WidgetTester tester,
  Widget home, {
  bool reducedMotion = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 900);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reducedMotion);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The page around the timeline: it keeps the messages and hands out one new
/// jump request for every tap.
class _Host extends StatefulWidget {
  const _Host({required this.loadedFrom});

  final int loadedFrom;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late int _from = widget.loadedFrom;
  ChatJumpRequest? _jump;
  var _serial = 0;

  void jumpTo(String messageId) =>
      setState(() => _jump = ChatJumpRequest(messageId, ++_serial));

  void loadAll() => setState(() => _from = 0);

  @override
  Widget build(BuildContext context) {
    final messages = [
      for (var index = _from; index < _count; index++) _message(index),
    ];
    return ChatTimelineAdapter(
      model: _timeline(messages, hasMoreBefore: _from > 0, jump: _jump),
      onIntent: (intent) {
        if (intent case JumpToMessageIntent(:final messageId)) {
          jumpTo(messageId);
        }
      },
    );
  }
}

ChatTimelineViewModel _timeline(
  List<ChatMessageViewModel> messages, {
  required bool hasMoreBefore,
  ChatJumpRequest? jump,
}) => ChatTimelineViewModel(
  state: ChatTimelineLoadState.data,
  conversationId: 'conversation',
  title: 'Peer',
  savedMessages: false,
  securityGate: ChatSecurityGate.ready,
  offline: false,
  hasMoreBefore: hasMoreBefore,
  loadingBefore: false,
  olderLoadFailed: false,
  typing: false,
  pinnedMessages: const [],
  messages: messages,
  jump: jump,
);

ChatMessageViewModel _message(
  int index, {
  String? replyToMessageId,
  String? replyQuote,
}) {
  final outgoing = index.isEven;
  return ChatMessageViewModel(
    id: _id(index),
    authorId: outgoing ? 'self' : 'peer',
    authorName: outgoing ? 'You' : 'Peer',
    outgoing: outgoing,
    kind: ChatTimelineContentKind.text,
    text: 'message-$index',
    timestamp: DateTime(2026, 7, 30, 10).add(Duration(minutes: index)),
    delivery: outgoing
        ? ChatDeliveryViewState.accepted
        : ChatDeliveryViewState.received,
    firstInAuthorGroup: true,
    lastInAuthorGroup: true,
    edited: false,
    deleted: false,
    pinned: false,
    starred: false,
    unread: false,
    timestampSkewed: false,
    canEdit: outgoing,
    canDeleteForEveryone: outgoing,
    replyToMessageId: replyToMessageId,
    replyAuthor: replyToMessageId == null ? null : 'Peer',
    replyQuote: replyQuote,
  );
}

String _id(int value) => value.toRadixString(16).padLeft(32, '0');
