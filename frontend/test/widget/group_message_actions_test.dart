import 'dart:async';
import 'dart:convert';

import 'package:communication_platform/app/dependencies/attachment_providers.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/group_member_name_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/application/ports/attachment_sweep_port.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/direct_chat_page.dart';
import 'package:communication_platform/features/messaging/presentation/visible_conversation.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/application_event_harness.dart';
import '../support/attachment_descriptor_fixture.dart';
import '../support/authentication_harness.dart' as auth;

const _deviceId = '00000000-0000-0000-0000-000000000011';
const _peer = '00000000-0000-0000-0000-000000000002';
const _member = '00000000-0000-0000-0000-000000000003';
const _otherMember = '00000000-0000-0000-0000-000000000004';
const _directId =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _leftGroupId =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _messageId = '10101010101010101010101010101010';
const _secondMessageId = '11111111111111111111111111111111';
const _arrivingMessageId = '12121212121212121212121212121212';
const _otherMessageId = '13131313131313131313131313131313';

void main() {
  late LocalDatabase database;
  late _Fanout fanout;
  late _GroupSender groupSender;
  final strings = lookupAppLocalizations(const Locale('en'));

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    await database.customSelect('SELECT 1').getSingle();
    fanout = _Fanout();
    groupSender = _GroupSender();
  });

  tearDown(() async {
    await database.close();
  });

  /// The routed group chat over two messages from another member, or over
  /// [messages].
  Future<ProviderContainer> openGroup(
    WidgetTester tester, {
    bool unread = false,
    VisibleConversationRegistry? registry,
    List<ConversationSummary> others = const [],
    List<_SeedMessage> messages = const [
      (id: _messageId, sender: _member, text: 'hello team'),
      (id: _secondMessageId, sender: _member, text: 'see you there'),
    ],
    GroupState? state,
  }) async {
    await _seedConversation(
      database,
      conversationId: _groupId,
      kind: ConversationKind.group,
      unread: unread,
      messages: messages,
    );
    return _pump(
      tester,
      database: database,
      fanout: fanout,
      groupSender: groupSender,
      groups: {_groupId: state ?? _group(_groupId, 'Team')},
      summaries: [
        _summary(_groupId, ConversationKind.group, title: 'Team'),
        ...others,
      ],
      registry: registry,
      page: const GroupChatPage(groupId: _groupId),
    );
  }

  testWidgets('an open group chat returns to Chats when this account is no '
      'longer in the group (ADR-096 D3)', (tester) async {
    await _seedConversation(
      database,
      conversationId: _groupId,
      kind: ConversationKind.group,
      messages: const [],
    );
    final router = GoRouter(
      initialLocation: '/chats',
      routes: [
        GoRoute(
          path: '/chats',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('The Chats list'))),
        ),
        GoRoute(
          path: '/groups/:groupId',
          builder: (context, state) =>
              GroupChatPage(groupId: state.pathParameters['groupId']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await _pump(
      tester,
      database: database,
      fanout: fanout,
      groupSender: groupSender,
      groups: {
        _groupId: _group(
          _groupId,
          'Team',
          member: false,
          lifecycle: GroupLifecycle.removed,
        ),
      },
      summaries: const [],
      page: MaterialApp.router(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    );

    unawaited(router.push('/groups/$_groupId'));
    await tester.pumpAndSettle();

    expect(find.text('The Chats list'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-chat-screen')), findsNothing);
  });

  group('a group chat', () {
    testWidgets('Copy writes the message text to the clipboard', (
      tester,
    ) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await openGroup(tester);

      await _openActions(tester, 'hello team');
      await tester.tap(find.text(strings.chatCopyAction));
      await tester.pumpAndSettle();

      expect(copied, ['hello team']);
    });

    testWidgets('Star and Delete for me reach the local state with the '
        'message id', (tester) async {
      await openGroup(tester);

      await _openActions(tester, 'hello team');
      await tester.tap(find.text(strings.chatStarAction));
      await tester.pumpAndSettle();
      expect((await _row(database, _messageId)).starred, isTrue);
      expect((await _row(database, _secondMessageId)).starred, isFalse);

      await _openActions(tester, 'see you there');
      await tester.tap(find.text(strings.chatDeleteAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.chatDeleteForMeAction));
      await tester.pumpAndSettle();
      expect((await _row(database, _secondMessageId)).deletedForMe, isTrue);
      expect((await _row(database, _messageId)).deletedForMe, isFalse);
      expect(find.text(strings.chatActionFailedMessage), findsNothing);
    });

    testWidgets('a draft is kept, and a reopened group shows it in the '
        'composer', (tester) async {
      final container = await openGroup(tester);

      await tester.enterText(
        find.byKey(const ValueKey('chat-composer-field')),
        'unsent words',
      );
      await tester.pump();
      // Leaving the group: the composer writes its draft as it goes.
      await tester.pumpWidget(_app(container, const SizedBox.shrink()));
      await tester.pumpAndSettle();
      expect(
        utf8.decode((await _conversation(database)).draftCiphertext!),
        'unsent words',
      );

      await tester.pumpWidget(
        _app(container, const GroupChatPage(groupId: _groupId)),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const ValueKey('chat-composer-field')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        'unsent words',
      );
    });
  });

  group('the read mark and its receipts (ADR-091)', () {
    /// The ids each committed read receipt names, in the order committed.
    /// Every event the shared send path commits passes the fan-out, a receipt
    /// included.
    List<List<String>> readReceipts() => [
      for (final committed in fanout.events)
        if (committed.event.kind == ApplicationEventKind.receiptRead)
          [
            for (final id in (committed.event.body as ReceiptBody).messageIds)
              protocolBytesToHex(id),
          ],
    ];

    testWidgets('opening a group with unread messages of two members clears '
        'its unread count and commits one read receipt for each member', (
      tester,
    ) async {
      await openGroup(
        tester,
        unread: true,
        messages: const [
          (id: _messageId, sender: _member, text: 'hello team'),
          (id: _otherMessageId, sender: _otherMember, text: 'hi all'),
          (id: _secondMessageId, sender: _member, text: 'see you there'),
        ],
      );

      expect((await _conversation(database)).unreadCount, 0);
      expect((await _row(database, _messageId)).unread, isFalse);
      expect((await _row(database, _otherMessageId)).unread, isFalse);
      expect((await _row(database, _secondMessageId)).unread, isFalse);
      expect(fanout.events, hasLength(2));
      expect(
        readReceipts().map((ids) => ids.toSet()),
        unorderedEquals([
          {_messageId, _secondMessageId},
          {_otherMessageId},
        ]),
      );
      expect(
        fanout.events.map((committed) => committed.conversationKind),
        everyElement(ConversationKind.group.index),
      );
      expect(groupSender.texts, isEmpty);
    });

    testWidgets('a group this account left is read on this phone, and '
        'commits no receipt', (tester) async {
      await openGroup(
        tester,
        unread: true,
        state: _group(_groupId, 'Team', member: false),
      );

      expect((await _conversation(database)).unreadCount, 0);
      expect((await _row(database, _messageId)).unread, isFalse);
      expect(fanout.events, isEmpty);
    });

    testWidgets('a group waiting for its state is read on this phone, and '
        'commits no receipt', (tester) async {
      await openGroup(
        tester,
        unread: true,
        state: _group(
          _groupId,
          'Team',
          lifecycle: GroupLifecycle.stateRecoveryRequired,
        ),
      );

      expect((await _conversation(database)).unreadCount, 0);
      expect(fanout.events, isEmpty);
    });

    testWidgets('a message that arrives while the group is on screen does '
        'not stay unread, and its sender is told', (tester) async {
      await openGroup(tester);
      expect(fanout.events, isEmpty);

      await _insertMessage(
        database,
        conversationId: _groupId,
        message: (id: _arrivingMessageId, sender: _member, text: 'just now'),
        at: 1700000000100,
        unread: true,
      );
      await (database.update(database.conversations)
            ..where((row) => row.conversationId.equals(_groupId)))
          .write(const ConversationsCompanion(unreadCount: Value(1)));
      await tester.pumpAndSettle();

      expect(find.text('just now'), findsOneWidget);
      expect((await _row(database, _arrivingMessageId)).unread, isFalse);
      expect((await _conversation(database)).unreadCount, 0);
      expect(readReceipts(), [
        [_arrivingMessageId],
      ]);
    });

    testWidgets('the registry of what is on screen names the group while it '
        'is open', (tester) async {
      final registry = VisibleConversationRegistry(observeLifecycle: false);
      addTearDown(registry.dispose);
      final container = await openGroup(tester, registry: registry);

      expect(registry.conversationId, _groupId);

      await tester.pumpWidget(_app(container, const SizedBox.shrink()));
      await tester.pumpAndSettle();
      expect(registry.conversationId, isNull);
    });
  });

  group(
    'read receipts reach the sender and its reader list (ADR-091 D1, D7)',
    () {
      const sentMs = 1700000000000;
      const otherDevice = '00000000-0000-0000-0000-000000000044';
      const memberDevice = '00000000-0000-0000-0000-000000000033';
      final groupBytes = Uint8List.fromList(List<int>.filled(32, 0xaa));
      final messageId = sequentialId(1);
      final messageKey = ValueKey('message-${protocolBytesToHex(messageId)}');
      var eventSeed = 0;
      final counters = <String, int>{};

      setUp(() {
        eventSeed = 0;
        counters.clear();
      });

      /// One event of the group's conversation, applied as this phone receives
      /// it (or, for the message, as it wrote it).
      Future<void> apply({
        required ApplicationEventKind kind,
        required String user,
        required String device,
        required ApplicationEventBody body,
        required int createdMs,
        List<Uint8List> references = const [],
      }) async {
        final counter = (counters[device] ?? 0) + 1;
        counters[device] = counter;
        final applied = await applyCommit(
          database,
          applicationCommit(
            eventId: sequentialId(100 + eventSeed++),
            kind: kind,
            senderUser: user,
            senderDevice: device,
            counter: counter,
            body: body,
            references: references,
            conversationKind: ConversationKind.group,
            peer: null,
            localOrigin: device == _deviceId,
            createdMs: createdMs,
            conversationId: groupBytes,
            currentUser: auth.userId,
            currentDevice: _deviceId,
          ),
        );
        expect(applied.disposition, ApplicationApplyDisposition.applied);
      }

      Future<void> read(String user, String device, int createdMs) => apply(
        kind: ApplicationEventKind.receiptRead,
        user: user,
        device: device,
        body: ReceiptBody(messageIds: [messageId]),
        references: [messageId],
        createdMs: createdMs,
      );

      Finder mark(AppIconData icon) => find.descendant(
        of: find.byKey(messageKey),
        matching: find.byWidgetPredicate(
          (widget) => widget is AppIcon && widget.data == icon,
        ),
      );

      String timeLabel(WidgetTester tester, int ms) {
        final material = MaterialLocalizations.of(
          tester.element(find.byType(Scaffold).first),
        );
        final readAt = DateTime.fromMillisecondsSinceEpoch(
          ms,
          isUtc: true,
        ).toLocal();
        return strings.chatReadDateAndTime(
          material.formatMediumDate(readAt),
          material.formatTimeOfDay(TimeOfDay.fromDateTime(readAt)),
        );
      }

      testWidgets('two members read an own message: two ticks after the first, '
          '"Seen by 2" and the list with both, the newest first', (
        tester,
      ) async {
        await apply(
          kind: ApplicationEventKind.messageCreate,
          user: auth.userId,
          device: _deviceId,
          body: MessageCreateBody(messageId: messageId, text: 'to the group'),
          createdMs: sentMs,
        );
        await _pump(
          tester,
          database: database,
          fanout: fanout,
          groupSender: groupSender,
          groups: {_groupId: _group(_groupId, 'Team')},
          summaries: [
            _summary(_groupId, ConversationKind.group, title: 'Team'),
          ],
          page: const GroupChatPage(groupId: _groupId),
        );
        expect(find.text('to the group'), findsOneWidget);
        expect(mark(AppIcons.read), findsNothing);

        // The first member to read draws the second tick.
        await read(_otherMember, otherDevice, sentMs + 5000);
        await tester.pumpAndSettle();
        expect(mark(AppIcons.read), findsOneWidget);

        await _openActions(tester, 'to the group');
        expect(find.text(strings.chatSeenByCount(1)), findsOneWidget);

        // The second member's receipt arrives while the sheet is open.
        await read(_member, memberDevice, sentMs + 40000);
        await tester.pumpAndSettle();
        expect(find.text('Seen by 2'), findsOneWidget);
        expect(mark(AppIcons.read), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('chat-readers-row')));
        await tester.pumpAndSettle();

        final member = find.byKey(const ValueKey('chat-reader-$_member'));
        final other = find.byKey(const ValueKey('chat-reader-$_otherMember'));
        expect(member, findsOneWidget);
        expect(other, findsOneWidget);
        expect(
          tester.getTopLeft(member).dy,
          lessThan(tester.getTopLeft(other).dy),
          reason: 'the newest read is first',
        );
        expect(
          find.descendant(of: member, matching: find.text('Member')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: member,
            matching: find.text(timeLabel(tester, sentMs + 40000)),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: other, matching: find.text('Other')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: other,
            matching: find.text(timeLabel(tester, sentMs + 5000)),
          ),
          findsOneWidget,
        );

        // Closed inside the test: the sheet's query is cancelled here, drift
        // schedules a timer when one is, and it has to run before the test
        // ends.
        popAppModal(tester.element(member));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 1));
      });
    },
  );

  group('the undelivered hint (ADR-093 D19)', () {
    const hint = 'Not delivered yet. If';

    // The stored message is the same in both chats: this account's own,
    // accepted by the relay in 2023, with no receipt. The direct chat asks the
    // sender to look into it, and the group chat says nothing.
    testWidgets('a direct chat shows it under the old own message', (
      tester,
    ) async {
      await _seedConversation(
        database,
        conversationId: _directId,
        kind: ConversationKind.direct,
        peerUserId: _peer,
        messages: [
          (id: _messageId, sender: auth.userId, text: 'sent long ago'),
        ],
      );
      await _pump(
        tester,
        database: database,
        fanout: fanout,
        groupSender: groupSender,
        groups: {_groupId: _group(_groupId, 'Team')},
        summaries: [_summary(_directId, ConversationKind.direct, peer: _peer)],
        page: const DirectChatPage(
          peerUserId: _peer,
          conversationId: _directId,
        ),
      );

      expect(find.text('sent long ago'), findsOneWidget);
      expect(find.textContaining(hint), findsOneWidget);
    });

    testWidgets('a group chat shows none under the same old own message', (
      tester,
    ) async {
      await openGroup(
        tester,
        messages: [
          (id: _messageId, sender: auth.userId, text: 'sent long ago'),
        ],
      );

      expect(find.text('sent long ago'), findsOneWidget);
      expect(find.textContaining(hint), findsNothing);
    });
  });

  group('forward', () {
    testWidgets('from a direct chat into a group, the group use case gets '
        'the text', (tester) async {
      await _seedConversation(
        database,
        conversationId: _directId,
        kind: ConversationKind.direct,
        peerUserId: _peer,
        messages: [(id: _messageId, sender: _peer, text: 'pass it on')],
      );
      await _pump(
        tester,
        database: database,
        fanout: fanout,
        groupSender: groupSender,
        groups: {_groupId: _group(_groupId, 'Team')},
        summaries: [
          _summary(_directId, ConversationKind.direct, peer: _peer),
          _summary(_groupId, ConversationKind.group, title: 'Team'),
        ],
        page: const DirectChatPage(
          peerUserId: _peer,
          conversationId: _directId,
        ),
      );

      await _openActions(tester, 'pass it on');
      await tester.tap(find.text('Forward').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team').last);
      await tester.pump();
      await tester.tap(find.text('Forward').last);
      await tester.pumpAndSettle();

      expect(groupSender.texts, [(groupId: _groupId, text: 'pass it on')]);
      expect(fanout.events, isEmpty);
    });

    testWidgets('from a group into a direct chat and into Saved Messages', (
      tester,
    ) async {
      await openGroup(
        tester,
        others: [_summary(_directId, ConversationKind.direct, peer: _peer)],
      );

      await _openActions(tester, 'hello team');
      await tester.tap(find.text(strings.chatForwardAction));
      await tester.pumpAndSettle();
      // The open group is not a target of its own forward.
      expect(_targetTitles(tester), [
        strings.savedMessagesTitle,
        chatShortIdentity(_peer),
      ]);
      await tester.tap(find.text(strings.savedMessagesTitle).last);
      await tester.pump();
      await tester.tap(find.text(chatShortIdentity(_peer)).last);
      await tester.pump();
      await tester.tap(find.text(strings.chatForwardAction).last);
      await tester.pumpAndSettle();

      expect(groupSender.texts, isEmpty);
      expect(fanout.events, hasLength(2));
      final saved = fanout.events.singleWhere(
        (event) => event.conversationKind == ConversationKind.saved.index,
      );
      final direct = fanout.events.singleWhere(
        (event) => event.conversationKind == ConversationKind.direct.index,
      );
      expect(direct.peerUserId, _peer);
      for (final event in [saved, direct]) {
        expect((event.event.body as MessageCreateBody).text, 'hello team');
      }
      expect(find.text(strings.chatActionFailedMessage), findsNothing);
    });

    testWidgets('the picker of an attachment message lists no group', (
      tester,
    ) async {
      ChatListItemViewModel target(
        String id,
        String title, {
        bool group = false,
        bool saved = false,
      }) => ChatListItemViewModel(
        conversationId: id,
        title: title,
        preview: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        unreadCount: 0,
        muted: false,
        pinned: false,
        savedMessages: saved,
        peerUserId: group || saved ? null : _peer,
        group: group,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          builder: (context, child) =>
              AppDesignSystem(child: child ?? const SizedBox.shrink()),
          home: ChatConversationView(
            model: _timeline([
              _viewModel('a file and a caption', attachment: true),
              _viewModel('plain words'),
            ]),
            forwardTargets: () => [
              target('', 'Saved Messages', saved: true),
              target(_groupId, 'Team', group: true),
              target(_directId, 'Someone'),
            ],
            onIntent: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _openActions(tester, 'a file and a caption');
      await tester.tap(find.text(strings.chatForwardAction));
      await tester.pumpAndSettle();
      expect(_targetTitles(tester), ['Saved Messages', 'Someone']);
      popAppModal(tester.element(find.byType(CheckboxListTile).first));
      await tester.pumpAndSettle();

      // The same picker over a text message lists the group.
      await _openActions(tester, 'plain words');
      await tester.tap(find.text(strings.chatForwardAction));
      await tester.pumpAndSettle();
      expect(_targetTitles(tester), ['Saved Messages', 'Team', 'Someone']);
    });

    testWidgets('a refused group target does not stop the other targets, and '
        'the user is told', (tester) async {
      await _seedConversation(
        database,
        conversationId: _directId,
        kind: ConversationKind.direct,
        peerUserId: _peer,
        messages: [(id: _messageId, sender: _peer, text: 'pass it on')],
      );
      await _pump(
        tester,
        database: database,
        fanout: fanout,
        groupSender: groupSender,
        groups: {
          // This account was removed from the newer group, so the rule of a
          // group send refuses it.
          _leftGroupId: _group(_leftGroupId, 'Left Team', member: false),
          _groupId: _group(_groupId, 'Team'),
        },
        summaries: [
          _summary(_directId, ConversationKind.direct, peer: _peer),
          _summary(
            _leftGroupId,
            ConversationKind.group,
            title: 'Left Team',
            at: 1700000000900,
          ),
          _summary(_groupId, ConversationKind.group, title: 'Team'),
        ],
        page: const DirectChatPage(
          peerUserId: _peer,
          conversationId: _directId,
        ),
      );

      await _openActions(tester, 'pass it on');
      await tester.tap(find.text(strings.chatForwardAction));
      await tester.pumpAndSettle();
      // Saved Messages, then the refused group, then the group after it.
      final titles = _targetTitles(tester);
      expect(titles, [strings.savedMessagesTitle, 'Left Team', 'Team']);
      for (final title in titles) {
        await tester.tap(find.text(title).last);
        await tester.pump();
      }
      await tester.tap(find.text(strings.chatForwardAction).last);
      await tester.pumpAndSettle();

      expect(groupSender.texts, [(groupId: _groupId, text: 'pass it on')]);
      expect(fanout.events, hasLength(1));
      expect(
        fanout.events.single.conversationKind,
        ConversationKind.saved.index,
      );
      expect(find.text(strings.chatActionFailedMessage), findsOneWidget);
    });
  });
}

/// The titles the open forward picker lists, in order.
List<String> _targetTitles(WidgetTester tester) => [
  for (final tile in tester.widgetList<CheckboxListTile>(
    find.byType(CheckboxListTile),
  ))
    (tile.title! as Text).data!,
];

Future<Message> _row(LocalDatabase database, String messageId) =>
    (database.select(
      database.messages,
    )..where((row) => row.messageId.equals(messageId))).getSingle();

Future<Conversation> _conversation(LocalDatabase database) => (database.select(
  database.conversations,
)..where((row) => row.conversationId.equals(_groupId))).getSingle();

ChatTimelineViewModel _timeline(List<ChatMessageViewModel> messages) =>
    ChatTimelineViewModel(
      state: ChatTimelineLoadState.data,
      conversationId: _directId,
      title: 'Someone',
      savedMessages: false,
      securityGate: ChatSecurityGate.ready,
      offline: false,
      hasMoreBefore: false,
      loadingBefore: false,
      olderLoadFailed: false,
      typing: false,
      pinnedMessages: const [],
      messages: messages,
    );

ChatMessageViewModel _viewModel(String text, {bool attachment = false}) =>
    ChatMessageViewModel(
      id: attachment ? _messageId : _secondMessageId,
      authorId: _peer,
      authorName: 'Someone',
      outgoing: false,
      kind: attachment
          ? ChatTimelineContentKind.attachment
          : ChatTimelineContentKind.text,
      text: text,
      timestamp: DateTime(2026, 10, 14, attachment ? 10 : 11),
      delivery: ChatDeliveryViewState.received,
      firstInAuthorGroup: true,
      lastInAuthorGroup: true,
      edited: false,
      deleted: false,
      pinned: false,
      starred: false,
      unread: false,
      timestampSkewed: false,
      canEdit: false,
      canDeleteForEveryone: false,
      attachments: attachment ? [testAttachmentDescriptor()] : const [],
    );

typedef _SeedMessage = ({String id, String sender, String text});

Future<void> _seedConversation(
  LocalDatabase database, {
  required String conversationId,
  required ConversationKind kind,
  required List<_SeedMessage> messages,
  String? peerUserId,
  bool unread = false,
}) async {
  await database
      .into(database.conversations)
      .insert(
        ConversationsCompanion.insert(
          conversationId: conversationId,
          kind: kind.index,
          listProjectionCiphertext: Uint8List.fromList(utf8.encode('preview')),
          sortKey: 1700000000000 + messages.length,
          peerUserId: Value(peerUserId),
          unreadCount: Value(unread ? messages.length : 0),
        ),
      );
  for (final (index, message) in messages.indexed) {
    await _insertMessage(
      database,
      conversationId: conversationId,
      message: message,
      at: 1700000000000 + index,
      unread: unread,
    );
  }
}

Future<void> _insertMessage(
  LocalDatabase database, {
  required String conversationId,
  required _SeedMessage message,
  required int at,
  bool unread = false,
}) => database
    .into(database.messages)
    .insert(
      MessagesCompanion.insert(
        messageId: message.id,
        conversationId: conversationId,
        currentEventId: 'event-${message.id}',
        projectionCiphertext: Uint8List.fromList(utf8.encode(message.text)),
        status: 3,
        revision: 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
        senderUserId: Value(message.sender),
        orderingMs: Value(at),
        orderingEventId: Value('event-${message.id}'),
        unread: Value(unread),
      ),
    );

ConversationSummary _summary(
  String conversationId,
  ConversationKind kind, {
  String? peer,
  String? title,
  int at = 1700000000000,
}) => ConversationSummary(
  conversationId: conversationId,
  kind: kind,
  peerUserId: peer,
  lastMessage: null,
  lastActivityMs: at,
  unreadCount: 0,
  mutedUntil: null,
  draft: null,
  pinnedMessageIds: const {},
  displayTitle: title,
);

/// A group the signed-in account belongs to, or, with [member] false, one
/// that no longer lets it send.
GroupState _group(
  String groupId,
  String name, {
  bool member = true,
  GroupLifecycle lifecycle = GroupLifecycle.active,
}) => GroupState(
  groupId: groupId,
  metadata: GroupMetadata(name: name, description: ''),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
  members: [
    GroupMember(
      userId: _member,
      displayName: '',
      role: GroupRole.owner,
      verified: true,
    ),
    GroupMember(
      userId: auth.userId,
      displayName: '',
      role: GroupRole.member,
      verified: true,
      membership: member
          ? GroupMembershipState.active
          : GroupMembershipState.removed,
    ),
    GroupMember(
      userId: _otherMember,
      displayName: '',
      role: GroupRole.member,
      verified: true,
    ),
  ],
  controlRevision: 1,
  controlStateHash:
      '1010101010101010101010101010101010101010101010101010101010101010',
  lifecycle: lifecycle,
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required LocalDatabase database,
  required _Fanout fanout,
  required _GroupSender groupSender,
  required Map<String, GroupState> groups,
  required List<ConversationSummary> summaries,
  required Widget page,
  VisibleConversationRegistry? registry,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final harness = auth.AuthenticationHarness();
  addTearDown(harness.close);
  final visible =
      registry ?? VisibleConversationRegistry(observeLifecycle: false);
  final groupRepository = _GroupRepository(groups);
  final container = ProviderContainer(
    overrides: [
      authenticationUseCasesProvider.overrideWithValue(harness.useCases),
      localDatabaseProvider.overrideWith((ref) => Future.value(database)),
      currentMessagingDeviceIdProvider.overrideWith(
        (ref) => Future.value(_deviceId),
      ),
      visibleConversationProvider.overrideWithValue(visible),
      conversationSummariesProvider.overrideWith(
        (ref, userId) => Stream.value(summaries),
      ),
      contactProvider.overrideWith(
        (ref, userId) => Stream.value(
          ContactProjection(
            userId: userId,
            username: userId,
            trustState: ContactTrustState.verified,
          ),
        ),
      ),
      attachmentCacheRootProvider.overrideWith(
        (ref) => Completer<Never>().future,
      ),
      attachmentUploadJobsProvider.overrideWith(
        (ref, request) => Stream.value(const []),
      ),
      attachmentSweepProvider.overrideWithValue(_Sweep()),
      publishedLimitsProvider.overrideWithValue(ServerConfig.fallback),
      sendConversationEventsProvider.overrideWith(
        (ref, scope) => SendConversationEvents(
          repository: DriftConversationDomainRepository(database),
          protocol: _Protocol(),
          fanout: fanout,
          clock: const _Clock(),
          attachments: _Sweep(),
        ),
      ),
      groupProvider.overrideWith(
        (ref, groupId) => Stream.value(groups[groupId]),
      ),
      // What the contacts store would answer for the three members. The
      // roster below carries ids and roles, as a decoded control event does.
      groupMemberNamesProvider.overrideWith(
        (ref, request) => Stream.value(
          GroupMemberNames({
            _member: const GroupMemberName(name: 'Member', verified: true),
            auth.userId: const GroupMemberName(name: 'Reader', verified: true),
            _otherMember: const GroupMemberName(name: 'Other', verified: true),
          }),
        ),
      ),
      groupUseCasesProvider.overrideWith(
        (ref) => GroupUseCases(
          create: CreateGroup(
            repository: groupRepository,
            crypto: const _UnusedCrypto(),
            identity: const _UnusedIdentity(),
            clock: const _Clock(),
          ),
          mutate: MutateGroup(
            repository: groupRepository,
            crypto: const _UnusedCrypto(),
            identity: const _UnusedIdentity(),
            clock: const _Clock(),
          ),
          sendMessage: SendGroupMessage(
            repository: groupRepository,
            sender: groupSender,
          ),
          retryMessage: RetryGroupMessage(
            repository: groupRepository,
            sender: groupSender,
          ),
          setReaction: SetGroupReaction(
            repository: groupRepository,
            sender: groupSender,
          ),
          deleteForEveryone: DeleteGroupMessageForEveryone(
            repository: groupRepository,
            sender: groupSender,
          ),
          setPin: SetGroupPin(
            repository: groupRepository,
            sender: groupSender,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final signedIn = await container
      .read(authenticationControllerProvider.notifier)
      .login(username: 'reader', password: 'correct horse battery');
  expect(signedIn, isTrue);
  await tester.pumpWidget(_app(container, page));
  await tester.pumpAndSettle();
  // Unmounted inside the test, so a draft the composer flushes as it leaves
  // is written while the database is still open.
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  return container;
}

Widget _app(ProviderContainer container, Widget page) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        home: page,
      ),
    );

/// Opens the message sheet of the bubble that shows [text].
Future<void> _openActions(WidgetTester tester, String text) async {
  await tester.tap(find.text(text).last);
  // The bubble's double-tap recognizer holds the arena before a tap wins.
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() =>
      DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true);
}

final class _Protocol implements ApplicationProtocolPort {
  int next = 1;

  @override
  Future<Result<Uint8List>> encode(ApplicationEventRecord event) async =>
      Result.success(Uint8List.fromList([event.kindValue, ...event.eventId]));

  @override
  Future<Result<DecodedApplicationEvent>> decode(Uint8List bytes) async =>
      throw UnimplementedError();

  @override
  Future<Result<Uint8List>> deriveDirectConversationId({
    required Uint8List firstUserId,
    required Uint8List secondUserId,
  }) async => Result.success(Uint8List.fromList(List<int>.filled(32, 0xdd)));

  @override
  Future<Result<Uint8List>> deriveSavedConversationId(Uint8List userId) async =>
      Result.success(Uint8List.fromList(List<int>.filled(32, 0x88)));

  @override
  Future<Result<Uint8List>> generateEventId() async =>
      Result.success(Uint8List.fromList(List<int>.filled(16, next++)));
}

final class _Sweep implements AttachmentSweepPort {
  @override
  Future<void> sweepAfterDeletion() async {}
}

/// Records each event the shared send path commits, which is everything a
/// direct chat or Saved Messages sends, receipts included.
final class _Fanout implements ApplicationFanoutPort {
  final List<ApplicationEventCommit> events = [];

  @override
  Future<Result<void>> commitLocalEcho({
    required String operationId,
    required String eventId,
    required String currentUserId,
    required String currentDeviceId,
    required String peerUserId,
    required Uint8List openedPayload,
    required ApplicationEventCommit applicationEvent,
  }) async {
    events.add(applicationEvent);
    return const Result.success(null);
  }

  @override
  Future<Result<bool>> retryFailedSend(String operationId) async =>
      const Result.success(false);
}

/// What the group use cases hand on, once the rule of a group send let it
/// through.
final class _GroupSender implements GroupMessageSenderPort {
  final List<({String groupId, String text})> texts = [];

  @override
  Future<Result<void>> sendText({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String text,
    String? replyToMessageId,
    String? quoteFallback,
  }) async {
    texts.add((groupId: groupId, text: text));
    return const Result.success(null);
  }

  @override
  Future<Result<void>> retryText({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String messageId,
    required String text,
    String? replyToMessageId,
    String? quoteFallback,
  }) async => const Result.success(null);

  @override
  Future<Result<void>> setReaction({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String messageId,
    required String? emoji,
  }) async => const Result.success(null);

  final List<({String messageId, bool pinned})> pins = [];

  @override
  Future<Result<void>> deleteForEveryone({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String messageId,
  }) async => const Result.success(null);

  @override
  Future<Result<void>> setPin({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String messageId,
    required bool pinned,
  }) async {
    pins.add((messageId: messageId, pinned: pinned));
    return const Result.success(null);
  }
}

final class _GroupRepository implements GroupRepositoryPort {
  _GroupRepository(this.groups);

  final Map<String, GroupState> groups;

  @override
  Future<Result<GroupState?>> readGroup(String groupId) async =>
      Result.success(groups[groupId]);

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _UnusedCrypto implements GroupControlCryptoPort {
  const _UnusedCrypto();

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _UnusedIdentity implements GroupIdentityPort {
  const _UnusedIdentity();

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}
