import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/app/dependencies/attachment_providers.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/application/ports/attachment_sweep_port.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:communication_platform/features/messaging/presentation/direct_chat_page.dart';
import 'package:communication_platform/features/messaging/presentation/visible_conversation.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/authentication_harness.dart' as auth;

const _deviceId = '00000000-0000-0000-0000-000000000011';
const _peer = '00000000-0000-0000-0000-000000000002';
const _member = '00000000-0000-0000-0000-000000000003';
const _directId =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _messageId = '10101010101010101010101010101010';

void main() {
  late LocalDatabase database;
  late _Fanout fanout;
  late _GroupSender groupSender;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    await database.customSelect('SELECT 1').getSingle();
    fanout = _Fanout();
    groupSender = _GroupSender();
  });

  tearDown(() async {
    await database.close();
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
  });
}

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
GroupState _group(String groupId, String name, {bool member = true}) =>
    GroupState(
      groupId: groupId,
      metadata: GroupMetadata(name: name, description: ''),
      invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
      historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
      members: [
        GroupMember(
          userId: _member,
          displayName: 'Member',
          role: GroupRole.owner,
          verified: true,
        ),
        GroupMember(
          userId: auth.userId,
          displayName: 'Reader',
          role: GroupRole.member,
          verified: true,
          membership: member
              ? GroupMembershipState.active
              : GroupMembershipState.removed,
        ),
      ],
      controlRevision: 1,
      controlStateHash:
          '1010101010101010101010101010101010101010101010101010101010101010',
      lifecycle: GroupLifecycle.active,
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
        ),
      ),
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
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Unmounted inside the test, so a draft the composer flushes as it leaves
  // is written while the database is still open.
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  return container;
}

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
