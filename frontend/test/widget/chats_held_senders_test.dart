import 'dart:async';

import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/sync_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/presentation/safety_number_page.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_list_row.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/authentication_harness.dart';

const _narrow = Size(360, 800);

/// A claimed sender this phone has a contact row for, and one it has none for.
const _alice = 'u-alice';
const _stranger = '1a2b3c4d5e6f70818293a4b5';

/// The instant the summaries below are dated from; the held senders are dated
/// against it.
final _base = DateTime.utc(2026, 10, 9);

void main() {
  group('the order of the rows', () {
    final older = _conversation('older', at: _base.subtract(_minutes(60)));
    final newer = _conversation('newer', at: _base.subtract(_minutes(10)));
    final pinned = _conversation(
      'pinned',
      at: _base.subtract(_minutes(500)),
      pinned: true,
    );

    List<String> order(
      List<ChatListItemViewModel> items,
      List<ChatHeldSenderViewModel> held,
    ) => [
      for (final entry in chatListEntries(items, held))
        switch (entry) {
          ChatListConversationEntry(:final item) => item.conversationId,
          ChatListHeldSenderEntry(:final sender) => 'held:${sender.userId}',
        },
    ];

    test('with nothing held the rows are the conversations as given', () {
      expect(order([pinned, newer, older], const []), [
        'pinned',
        'newer',
        'older',
      ]);
    });

    test('a held sender sorts among the conversations by its latest hold, '
        'and a pinned one stays first', () {
      final held = [
        _held('u-between', at: _base.subtract(_minutes(30))),
        _held('u-newest', at: _base.subtract(_minutes(1))),
        _held('u-oldest', at: _base.subtract(_minutes(900))),
      ];
      expect(order([pinned, newer, older], held), [
        'pinned',
        'held:u-newest',
        'newer',
        'held:u-between',
        'older',
        'held:u-oldest',
      ]);
    });

    test('a held sender newer than everything never pushes a pinned row '
        'down', () {
      final held = [_held('u-now', at: _base)];
      expect(order([pinned, older], held), ['pinned', 'held:u-now', 'older']);
    });

    test('with no conversation a held sender is the whole list', () {
      expect(order(const [], [_held('u-only', at: _base)]), ['held:u-only']);
    });

    test('two senders held at the same moment keep a stable order', () {
      final held = [_held('u-b', at: _base), _held('u-a', at: _base)];
      expect(order(const [], held), ['held:u-a', 'held:u-b']);
    });
  });

  group('the names of the senders', () {
    test('a known sender is "@username" and an unknown one the short '
        'identity without the "@"', () {
      final items = chatHeldSenderItems(
        [
          HeldSender(userId: _alice, count: 2, latestHeldAt: _base),
          HeldSender(userId: _stranger, count: 1, latestHeldAt: _base),
        ],
        contacts: [_contact(_alice, 'alice')],
      );
      expect(items.map((item) => item.sender), ['@alice', '1a2b3c4d…']);
    });

    test('a sender with no held envelope has no row', () {
      expect(
        chatHeldSenderItems([
          HeldSender(userId: _alice, count: 0, latestHeldAt: _base),
        ], contacts: const []),
        isEmpty,
      );
    });

    test('the name is the username, and a verified display name never '
        'replaces it', () {
      final items = chatHeldSenderItems(
        [HeldSender(userId: _alice, count: 1, latestHeldAt: _base)],
        contacts: [_contact(_alice, 'alice', displayName: 'Alice Smith')],
      );
      expect(items.single.sender, '@alice');
    });
  });

  group('the Chats list', () {
    testWidgets('with no held envelope there is no row', (tester) async {
      final app = await _pumpApp(tester, summaries: _summaries());
      expect(find.text('Weekend plans'), findsOneWidget);
      expect(find.textContaining('Verify to read'), findsNothing);
      expect(
        find.byWidgetPredicate((widget) => widget is ChatHeldSenderRow),
        findsNothing,
      );
      app.dispose();
    });

    testWidgets('one row for each sender, with its count, and the unknown '
        'sender by its short identity', (tester) async {
      final app = await _pumpApp(
        tester,
        summaries: _summaries(),
        contacts: [_contact(_alice, 'alice')],
      );

      app.held.add([
        HeldSender(
          userId: _alice,
          count: 3,
          latestHeldAt: _base.subtract(_minutes(5)),
        ),
        HeldSender(
          userId: _stranger,
          count: 1,
          latestHeldAt: _base.subtract(_minutes(6)),
        ),
      ]);
      await _settle(tester);

      expect(
        find.text('@alice sent you 3 messages. Verify to read them.'),
        findsOneWidget,
      );
      expect(
        find.text('1a2b3c4d… sent you 1 message. Verify to read it.'),
        findsOneWidget,
      );
      expect(find.byType(ChatHeldSenderRow), findsNWidgets(2));
      // The conversations are still there.
      expect(find.text('Weekend plans'), findsOneWidget);
      app.dispose();
    });

    testWidgets('a count that moves updates the row, and an emptied stream '
        'takes the row away', (tester) async {
      final app = await _pumpApp(
        tester,
        summaries: _summaries(),
        contacts: [_contact(_alice, 'alice')],
      );

      app.held.add([HeldSender(userId: _alice, count: 2, latestHeldAt: _base)]);
      await _settle(tester);
      expect(
        find.text('@alice sent you 2 messages. Verify to read them.'),
        findsOneWidget,
      );

      app.held.add([HeldSender(userId: _alice, count: 5, latestHeldAt: _base)]);
      await _settle(tester);
      expect(
        find.text('@alice sent you 5 messages. Verify to read them.'),
        findsOneWidget,
      );

      app.held.add(const []);
      await _settle(tester);
      expect(find.byType(ChatHeldSenderRow), findsNothing);
      expect(find.textContaining('Verify to read'), findsNothing);
      expect(find.text('Weekend plans'), findsOneWidget);
      app.dispose();
    });

    testWidgets('a held sender alone fills the list: the empty state does '
        'not hide it', (tester) async {
      final app = await _pumpApp(tester, contacts: [_contact(_alice, 'alice')]);
      expect(find.text('No chats yet'), findsOneWidget);

      app.held.add([HeldSender(userId: _alice, count: 1, latestHeldAt: _base)]);
      await _settle(tester);
      expect(find.text('No chats yet'), findsNothing);
      expect(find.byType(ChatHeldSenderRow), findsOneWidget);

      app.held.add(const []);
      await _settle(tester);
      expect(find.text('No chats yet'), findsOneWidget);
      app.dispose();
    });

    testWidgets('a tap opens the safety number of the claimed sender', (
      tester,
    ) async {
      final app = await _pumpApp(
        tester,
        summaries: _summaries(),
        contacts: [_contact(_alice, 'alice')],
      );
      app.held.add([HeldSender(userId: _alice, count: 2, latestHeldAt: _base)]);
      await _settle(tester);

      await tester.tap(find.byKey(const ValueKey('chats-held-sender-$_alice')));
      await _settle(tester);

      expect(find.byType(SafetyNumberPage), findsOneWidget);
      expect(
        GoRouterState.of(
          tester.element(find.byType(SafetyNumberPage)),
        ).uri.path,
        '/contacts/$_alice/safety',
      );
      app.dispose();
    });

    testWidgets('the row shows no preview, no time, no badge and no menu', (
      tester,
    ) async {
      final app = await _pumpApp(
        tester,
        summaries: _summaries(),
        contacts: [_contact(_alice, 'alice')],
      );
      app.held.add([HeldSender(userId: _alice, count: 2, latestHeldAt: _base)]);
      await _settle(tester);

      final row = find.byKey(const ValueKey('chats-held-sender-$_alice'));
      // Its only text is the line.
      expect(
        find.descendant(of: row, matching: find.byType(Text)),
        findsNWidgets(2),
        reason: 'the line, and the initials of the avatar',
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(
            '@alice sent you 2 messages. Verify to read them.',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('No messages yet')),
        findsNothing,
      );
      // A long press opens no menu: there is no conversation to pin or mute.
      await tester.longPress(row);
      await _settle(tester);
      expect(find.text('Pin'), findsNothing);
      expect(find.text('Mute'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      app.dispose();
    });

    testWidgets('a screen reader meets one button with the line and where it '
        'leads', (tester) async {
      final semantics = tester.ensureSemantics();
      final app = await _pumpApp(
        tester,
        summaries: _summaries(),
        contacts: [_contact(_alice, 'alice')],
      );
      app.held.add([HeldSender(userId: _alice, count: 2, latestHeldAt: _base)]);
      await _settle(tester);

      final node = tester.getSemantics(
        find.byKey(const ValueKey('chats-held-sender-$_alice')),
      );
      expect(
        node,
        isSemantics(
          label: '@alice sent you 2 messages. Verify to read them.',
          hint: 'Open the safety number',
          isButton: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
      app.dispose();
    });

    for (final scale in const [1.0, 2.0]) {
      testWidgets('in Persian at ${(scale * 100).round()} % text the rows '
          'fit', (tester) async {
        final app = await _pumpApp(
          tester,
          summaries: _summaries(),
          contacts: [_contact(_alice, 'alice')],
          locale: const Locale('fa'),
          textScale: scale,
        );
        app.held.add([
          HeldSender(userId: _alice, count: 12, latestHeldAt: _base),
          HeldSender(userId: _stranger, count: 1, latestHeldAt: _base),
        ]);
        await _settle(tester);

        expect(find.byType(ChatHeldSenderRow), findsNWidgets(2));
        expect(find.textContaining('پیام برای شما فرستاده است'), findsWidgets);
        expect(tester.takeException(), isNull);
        app.dispose();
      });
    }

    testWidgets('in English at 200 % text the row fits', (tester) async {
      final app = await _pumpApp(
        tester,
        summaries: _summaries(),
        contacts: [_contact(_alice, 'alice')],
        textScale: 2,
      );
      app.held.add([
        HeldSender(userId: _stranger, count: 128, latestHeldAt: _base),
      ]);
      await _settle(tester);

      expect(find.byType(ChatHeldSenderRow), findsOneWidget);
      expect(tester.takeException(), isNull);
      app.dispose();
    });

    testWidgets('the search page lists no held sender', (tester) async {
      final app = await _pumpApp(
        tester,
        summaries: _summaries(),
        contacts: [_contact(_alice, 'alice')],
      );
      app.held.add([HeldSender(userId: _alice, count: 2, latestHeldAt: _base)]);
      await _settle(tester);

      await tester.tap(find.byKey(const ValueKey('chats-search-action')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('chats-search-field')),
        'alice',
      );
      await _settle(tester);

      expect(find.byType(ChatHeldSenderRow), findsNothing);
      expect(find.textContaining('Verify to read'), findsNothing);
      app.dispose();
    });
  });
}

Duration _minutes(int count) => Duration(minutes: count);

ChatListItemViewModel _conversation(
  String id, {
  required DateTime at,
  bool pinned = false,
}) => ChatListItemViewModel(
  conversationId: id,
  title: id,
  preview: '',
  timestamp: at,
  unreadCount: 0,
  muted: false,
  pinned: pinned,
  savedMessages: false,
  peerUserId: 'peer-$id',
);

ChatHeldSenderViewModel _held(String userId, {required DateTime at}) =>
    ChatHeldSenderViewModel(
      userId: userId,
      sender: userId,
      avatarName: userId,
      count: 1,
      latestHeldAt: at,
    );

ContactProjection _contact(
  String userId,
  String username, {
  String? displayName,
}) => ContactProjection(
  userId: userId,
  username: username,
  trustState: ContactTrustState.unverified,
  authenticatedProfile: displayName == null
      ? null
      : AuthenticatedProfile(
          displayName: displayName,
          avatarSeed: 2,
          version: 1,
          authorDeviceId: 'device',
        ),
);

List<ConversationSummary> _summaries() => [
  ConversationSummary(
    conversationId: 'c-group',
    kind: ConversationKind.group,
    peerUserId: null,
    lastMessage: 'Who brings the ball?',
    lastActivityMs: _base.millisecondsSinceEpoch - 2 * 60000,
    unreadCount: 0,
    mutedUntil: null,
    draft: null,
    pinnedMessageIds: const {},
    displayTitle: 'Weekend plans',
  ),
];

/// The application over the held-senders stream this test drives.
final class _App {
  _App(this.container, this.held);

  final ProviderContainer container;
  final StreamController<List<HeldSender>> held;

  void dispose() {
    unawaited(held.close());
  }
}

/// Mounts the application signed in, on the real router, over providers that
/// never reach storage, as `chats_search_page_test.dart` does. The held
/// senders are whatever [_App.held] last emitted.
Future<_App> _pumpApp(
  WidgetTester tester, {
  List<ConversationSummary> summaries = const [],
  List<ContactProjection> contacts = const [],
  Locale locale = const Locale('en'),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _narrow;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final harness = AuthenticationHarness();
  addTearDown(harness.close);
  final held = StreamController<List<HeldSender>>.broadcast();
  final container = ProviderContainer(
    overrides: [
      authenticationUseCasesProvider.overrideWithValue(harness.useCases),
      localDatabaseProvider.overrideWith(
        (ref) => Completer<LocalDatabase>().future,
      ),
      conversationSummariesProvider.overrideWith(
        (ref, userId) => Stream.value(summaries),
      ),
      contactListProvider.overrideWith((ref, userId) => Stream.value(contacts)),
      contactProvider.overrideWith(
        (ref, userId) => Stream.value(
          ContactProjection(
            userId: userId,
            username: userId,
            trustState: ContactTrustState.unverified,
          ),
        ),
      ),
      heldSendersProvider.overrideWith((ref) => held.stream),
      voiceRoomsProvider.overrideWith((ref) => Stream.value(const [])),
    ],
  );
  addTearDown(container.dispose);
  final signedIn = await container
      .read(authenticationControllerProvider.notifier)
      .login(username: 'reader', password: 'correct horse battery');
  expect(signedIn, isTrue);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: CommunicationPlatformApp(
        environment: AppEnvironment.production,
        locale: locale,
        themeMode: ThemeMode.light,
      ),
    ),
  );
  await _settle(tester);
  return _App(container, held);
}

/// Long enough for a route transition and for the projections to answer.
Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}
