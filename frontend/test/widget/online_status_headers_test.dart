import 'dart:async';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/signal_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/messaging/infrastructure/memory_volatile_conversation_state.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/direct_chat_page.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_share_setting.dart';
import 'package:communication_platform/features/signals/application/presence_status_book.dart';
import 'package:communication_platform/features/signals/domain/peer_status_model.dart';
import 'package:communication_platform/features/signals/infrastructure/presence_adapters.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/signals/support/presence_fakes.dart';
import '../features/voice/support/signal_fakes.dart';

const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _me = '00000000-0000-0000-0000-000000000001';
const _alice = '00000000-0000-0000-0000-000000000002';
const _bob = '00000000-0000-0000-0000-000000000003';
const _bobPhone = '00000000-0000-0000-0000-0000000000b1';
const _bobTablet = '00000000-0000-0000-0000-0000000000b2';

/// ADR-098 D11: what the headers say, in order of precedence, and the
/// Settings switch that turns the saying off.
void main() {
  group('the direct chat header', () {
    // 16:00 on Monday 19 October 2026, this phone's local time.
    DateTime now() => DateTime(2026, 10, 19, 16);

    Finder inBar(String text) =>
        find.descendant(of: find.byType(AppBar), matching: find.text(text));

    Finder anyStatus() => find.descendant(
      of: find.byType(AppBar),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            ((widget.data ?? '').contains('last seen') ||
                (widget.data ?? '').contains('online') ||
                (widget.data ?? '').contains('typing') ||
                (widget.data ?? '').contains('آخرین') ||
                (widget.data ?? '').contains('آنلاین') ||
                (widget.data ?? '').contains('نوشتن')),
      ),
    );

    testWidgets('typing wins over online', (tester) async {
      await _pumpView(
        tester,
        typing: true,
        status: const PeerStatusOnline(),
        now: now,
      );

      expect(inBar('typing…'), findsOneWidget);
      expect(inBar('online'), findsNothing);
    });

    testWidgets('online wins over a last seen', (tester) async {
      await _pumpView(tester, status: const PeerStatusOnline(), now: now);

      expect(inBar('online'), findsOneWidget);
      expect(anyStatus(), findsOneWidget);
    });

    testWidgets('a last seen earlier today says the time', (tester) async {
      await _pumpView(
        tester,
        status: PeerStatusLastSeen(DateTime(2026, 10, 19, 14, 5)),
        now: now,
      );

      expect(inBar('last seen today at 2:05 PM'), findsOneWidget);
    });

    testWidgets('a last seen yesterday says so, with the time', (tester) async {
      await _pumpView(
        tester,
        status: PeerStatusLastSeen(DateTime(2026, 10, 18, 23, 30)),
        now: now,
      );

      expect(inBar('last seen yesterday at 11:30 PM'), findsOneWidget);
    });

    testWidgets('a last seen on an earlier day says the date', (tester) async {
      await _pumpView(
        tester,
        status: PeerStatusLastSeen(DateTime(2026, 10, 12, 14, 5)),
        now: now,
      );

      expect(inBar('last seen Mon, Oct 12'), findsOneWidget);
      expect(find.textContaining('2:05'), findsNothing);
    });

    testWidgets('the day is this phone\'s local day, whatever the instant\'s '
        'zone', (tester) async {
      // A last seen kept as a UTC instant is read in local time: 00:30 local
      // today is yesterday's date in UTC on a phone east of it, and 23:30 local
      // yesterday is today's date in UTC on a phone west of it.
      await _pumpView(
        tester,
        status: PeerStatusLastSeen(DateTime(2026, 10, 19, 0, 30).toUtc()),
        now: now,
      );
      expect(inBar('last seen today at 12:30 AM'), findsOneWidget);

      await _pumpView(
        tester,
        status: PeerStatusLastSeen(DateTime(2026, 10, 18, 23, 30).toUtc()),
        now: now,
      );
      expect(inBar('last seen yesterday at 11:30 PM'), findsOneWidget);
    });

    testWidgets('nothing known says nothing', (tester) async {
      await _pumpView(tester, now: now);

      expect(anyStatus(), findsNothing);
    });

    testWidgets('a peer this user has not verified shows no status', (
      tester,
    ) async {
      await _pumpView(
        tester,
        status: const PeerStatusOnline(),
        gate: ChatSecurityGate.unverifiedIdentity,
        now: now,
      );

      expect(anyStatus(), findsNothing);
    });

    testWidgets('Saved Messages shows no status', (tester) async {
      await _pumpView(
        tester,
        status: const PeerStatusOnline(),
        savedMessages: true,
        now: now,
      );

      expect(anyStatus(), findsNothing);
    });

    testWidgets('in Persian', (tester) async {
      await _pumpView(
        tester,
        locale: const Locale('fa'),
        status: const PeerStatusOnline(),
        now: now,
      );
      expect(inBar('آنلاین'), findsOneWidget);

      await _pumpView(
        tester,
        locale: const Locale('fa'),
        typing: true,
        now: now,
      );
      expect(inBar('در حال نوشتن…'), findsOneWidget);

      await _pumpView(
        tester,
        locale: const Locale('fa'),
        status: PeerStatusLastSeen(DateTime(2026, 10, 19, 14, 5)),
        now: now,
      );
      expect(find.textContaining('آخرین بازدید امروز ساعت'), findsOneWidget);
    });

    testWidgets('does not overflow in Persian at 200% text', (tester) async {
      for (final status in [
        const PeerStatusOnline(),
        PeerStatusLastSeen(DateTime(2026, 10, 18, 23, 30)),
        PeerStatusLastSeen(DateTime(2026, 10, 12, 14, 5)),
      ]) {
        await _pumpView(
          tester,
          locale: const Locale('fa'),
          status: status,
          textScale: 2,
          size: const Size(360, 740),
          now: now,
        );
        expect(tester.takeException(), isNull, reason: '$status');
      }
    });

    testWidgets('does not overflow in English at 200% text', (tester) async {
      await _pumpView(
        tester,
        status: PeerStatusLastSeen(DateTime(2026, 10, 18, 23, 30)),
        textScale: 2,
        size: const Size(360, 740),
        now: now,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the direct chat header over the status book', () {
    late _BookRig rig;

    setUp(() => rig = _BookRig());
    tearDown(() => rig.close());

    Finder inBar(String text) =>
        find.descendant(of: find.byType(AppBar), matching: find.text(text));

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(rig.scope(_directPage()));
      await rig.settle(tester);
    }

    testWidgets('a frame from the peer shows online, 40 s of silence a last '
        'seen', (tester) async {
      await pumpPage(tester);
      expect(inBar('online'), findsNothing);

      await rig.book.heard(
        const PresenceDevice(userId: _bob, deviceId: _bobPhone),
      );
      await rig.settle(tester);
      expect(inBar('online'), findsOneWidget);

      await tester.runAsync(
        () => rig.timers.advance(
          const Duration(seconds: 39),
          settle: () => Future<void>.delayed(Duration.zero),
        ),
      );
      await rig.settle(tester);
      expect(inBar('online'), findsOneWidget);

      await tester.runAsync(
        () => rig.timers.advance(
          const Duration(seconds: 2),
          settle: () => Future<void>.delayed(Duration.zero),
        ),
      );
      await rig.settle(tester);
      expect(inBar('online'), findsNothing);
      expect(find.textContaining('last seen'), findsOneWidget);
    });

    testWidgets('with the switch off nothing shows, and turning it on brings '
        'the status back', (tester) async {
      await pumpPage(tester);
      await rig.book.heard(
        const PresenceDevice(userId: _bob, deviceId: _bobPhone),
      );
      await rig.settle(tester);
      expect(inBar('online'), findsOneWidget);

      await rig.setting.set(sharing: false);
      await rig.settle(tester);
      expect(inBar('online'), findsNothing);
      expect(find.textContaining('last seen'), findsNothing);

      // A frame heard while the switch is off shows nothing either.
      await rig.book.heard(
        const PresenceDevice(userId: _bob, deviceId: _bobTablet),
      );
      await rig.settle(tester);
      expect(inBar('online'), findsNothing);

      await rig.setting.set(sharing: true);
      await rig.settle(tester);
      expect(find.textContaining('last seen'), findsNothing);
      await rig.book.heard(
        const PresenceDevice(userId: _bob, deviceId: _bobPhone),
      );
      await rig.settle(tester);
      expect(inBar('online'), findsOneWidget);
    });
  });

  group('the group header', () {
    late MemoryVolatileConversationState typing;
    late FakeSignalClock clock;

    setUp(() {
      clock = FakeSignalClock(DateTime.utc(2026, 10, 19, 12));
      typing = MemoryVolatileConversationState(clock: clock);
    });

    Finder inBar(String text) =>
        find.descendant(of: find.byType(AppBar), matching: find.text(text));

    Future<void> pump(
      WidgetTester tester, {
      int online = 0,
      Locale locale = const Locale('en'),
      double textScale = 1,
      Size size = const Size(430, 900),
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appEnvironmentProvider.overrideWithValue(
              AppEnvironment.development,
            ),
            timeSourceProvider.overrideWithValue(clock),
            volatileConversationStateProvider.overrideWithValue(typing),
          ],
          child: MaterialApp(
            locale: locale,
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: AppDesignSystem(child: child ?? const SizedBox.shrink()),
            ),
            home: GroupChatPage(
              groupId: _groupId,
              injectedState: _groupState(),
              injectedMessages: const [],
              injectedTyping: typing.watchTyping(_groupId),
              injectedOnlineCount: online,
              currentUserId: _me,
              injectedMemberNames: GroupMemberNames({
                _alice: const GroupMemberName(name: 'Alice', verified: true),
                _bob: const GroupMemberName(name: 'Bob', verified: true),
              }),
              onSend: (_, {replyToMessageId, quoteFallback}) async =>
                  const Result.success(null),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
    }

    testWidgets('says how many are online beside the member count', (
      tester,
    ) async {
      await pump(tester, online: 3);

      expect(inBar('3 members · 3 online'), findsOneWidget);
      typing.dispose();
    });

    testWidgets('says only the member count while nobody is online', (
      tester,
    ) async {
      await pump(tester);

      expect(inBar('3 members'), findsOneWidget);
      expect(find.textContaining('online'), findsNothing);
      typing.dispose();
    });

    testWidgets('names the members who type in its place', (tester) async {
      await pump(tester, online: 2);
      typing.applyTyping(
        conversationId: _groupId,
        userId: _alice,
        deviceId: 'phone',
        isTyping: true,
        expiresAt: clock.now().add(const Duration(seconds: 15)),
        authenticatedAt: clock.now(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(inBar('Alice is typing…'), findsOneWidget);
      expect(find.textContaining('online'), findsNothing);
      typing.dispose();
    });

    testWidgets('in Persian, without an overflow at 200% text', (tester) async {
      await pump(
        tester,
        online: 2,
        locale: const Locale('fa'),
        textScale: 2,
        size: const Size(360, 740),
      );

      expect(find.textContaining('آنلاین'), findsOneWidget);
      expect(tester.takeException(), isNull);
      typing.dispose();
    });
  });
}

/// A real status book over memory stores and a manual clock, behind the
/// providers the screens read.
final class _BookRig {
  _BookRig() {
    conversations.held[_groupId] = PresenceGroupConversation(_groupId, [
      _me,
      _alice,
      _bob,
    ]);
  }

  final clock = FakeSignalClock(DateTime(2026, 10, 19, 12));
  late final timers = ManualPresenceTimers(clock);
  final ledger = MemoryPresenceLedger();
  final store = MemoryPresenceSharePreference();
  late final setting = PresenceShareSetting(store);
  final conversations = FakePresenceConversations();
  late final book = PresenceStatusBook(
    store: ledger,
    sharing: setting,
    conversations: conversations,
    clock: clock,
    timers: timers,
  );

  Widget scope(Widget home) => ProviderScope(
    overrides: [
      appEnvironmentProvider.overrideWithValue(AppEnvironment.development),
      timeSourceProvider.overrideWithValue(clock),
      presenceShareSettingProvider.overrideWith(
        (ref) => Future<PresenceShareSetting>.value(setting),
      ),
      presenceStatusBookProvider.overrideWith(
        (ref) => Future<PresenceStatusBook>.value(book),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          AppDesignSystem(child: child ?? const SizedBox.shrink()),
      home: home,
    ),
  );

  /// Lets the book's turns, the provider streams and the frame after them run.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await book.idle;
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
  }

  /// Not awaited: the book's `dispose` waits for the done event of its change
  /// stream, and a provider stream that Riverpod paused (a screen already
  /// gone) never takes it, which hangs a test's tear-down. The app does not
  /// await it either.
  void close() {
    unawaited(book.dispose());
    unawaited(setting.dispose());
  }
}

Widget _directPage() => DirectChatPage(
  peerUserId: _bob,
  injectedModel: _model(savedMessages: false),
);

ChatTimelineViewModel _model({
  bool typing = false,
  ChatSecurityGate gate = ChatSecurityGate.ready,
  bool savedMessages = false,
}) => ChatTimelineViewModel(
  state: ChatTimelineLoadState.empty,
  conversationId: 'conversation',
  title: savedMessages ? 'Saved Messages' : 'Bob',
  savedMessages: savedMessages,
  securityGate: gate,
  offline: false,
  hasMoreBefore: false,
  loadingBefore: false,
  olderLoadFailed: false,
  typing: typing,
  pinnedMessages: const [],
  messages: const [],
);

Future<void> _pumpView(
  WidgetTester tester, {
  required DateTime Function() now,
  PeerStatus status = const PeerStatusNone(),
  bool typing = false,
  ChatSecurityGate gate = ChatSecurityGate.ready,
  bool savedMessages = false,
  Locale locale = const Locale('en'),
  double textScale = 1,
  Size size = const Size(430, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        key: UniqueKey(),
        locale: locale,
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: AppDesignSystem(child: child ?? const SizedBox.shrink()),
        ),
        home: ChatConversationView(
          model: _model(
            typing: typing,
            gate: gate,
            savedMessages: savedMessages,
          ),
          onIntent: (_) {},
          peerUserId: savedMessages ? null : _bob,
          peerStatus: status,
          now: now,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

GroupState _groupState() => GroupState(
  groupId: _groupId,
  metadata: const GroupMetadata(name: 'Team', description: ''),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.reshareAvailable,
  members: [
    for (final (userId, role) in [
      (_me, GroupRole.owner),
      (_alice, GroupRole.member),
      (_bob, GroupRole.member),
    ])
      GroupMember(userId: userId, displayName: '', role: role, verified: true),
  ],
  controlRevision: 1,
  controlStateHash:
      '1010101010101010101010101010101010101010101010101010101010101010',
  lifecycle: GroupLifecycle.active,
);
