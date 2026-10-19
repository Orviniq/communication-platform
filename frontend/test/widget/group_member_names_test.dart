import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/authentication_use_cases.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';
import 'package:communication_platform/features/groups/presentation/create_group_page.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/groups/presentation/group_info_page.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/authentication_harness.dart' as auth;

/// A receiving phone decodes a roster of user ids and roles and no name, so
/// every name on a group screen is worked out from this phone's contacts.
/// These tests give the screens the roster a control event
/// decodes to, and a different set of names for each member: a verified
/// contact, a directory username, and nobody.
const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _owner = '00000000-0000-0000-0000-000000000001';
const _admin = '00000000-0000-0000-0000-000000000002';
const _stranger = '00000000-0000-0000-0000-000000000003';

const _questionId = '44444444444444444444444444444444';
const _answerId = '55555555555555555555555555555555';

void main() {
  final strings = lookupAppLocalizations(const Locale('en'));

  /// The names of the three members: a verified contact, a directory username
  /// and nobody.
  GroupMemberNames names() => GroupMemberNames({
    _owner: const GroupMemberName(name: 'Alice Smith', verified: true),
    _admin: const GroupMemberName(name: 'bob', verified: false),
  });

  Finder aUserId() => find.textContaining(RegExp('00000000'));

  group('Group Info', () {
    testWidgets('names each member by contact, username or "Unknown member", '
        'never blank and never by id', (tester) async {
      await _pump(
        tester,
        GroupInfoPage(
          groupId: _groupId,
          injectedState: _state(),
          injectedMemberNames: names(),
          currentUserId: _owner,
          onMutate: (_) async => Result.success(_state()),
        ),
      );

      Finder inRow(String userId, String text) => find.descendant(
        of: find.byKey(ValueKey('group-member-$userId')),
        matching: find.text(text),
      );
      expect(inRow(_owner, 'Alice Smith'), findsOneWidget);
      expect(inRow(_admin, 'bob'), findsOneWidget);
      expect(inRow(_stranger, strings.groupUnknownMember), findsOneWidget);
      expect(aUserId(), findsNothing);
      // Each row holds a name: a row of blanks would leave the avatar and the
      // role badge only.
      for (final userId in [_owner, _admin, _stranger]) {
        final texts = tester
            .widgetList<Text>(
              find.descendant(
                of: find.byKey(ValueKey('group-member-$userId')),
                matching: find.byType(Text),
              ),
            )
            .map((text) => text.data ?? '');
        expect(texts.where((text) => text.trim().isEmpty), isEmpty);
      }
    });

    testWidgets('"Verified" follows this phone\'s trust state of the user', (
      tester,
    ) async {
      await _pump(
        tester,
        GroupInfoPage(
          groupId: _groupId,
          injectedState: _state(),
          injectedMemberNames: names(),
          currentUserId: _owner,
          onMutate: (_) async => Result.success(_state()),
        ),
      );

      Finder verifiedIn(String userId) => find.descendant(
        of: find.byKey(ValueKey('group-member-$userId')),
        matching: find.text(strings.groupVerifiedMember),
      );
      // The roster says every member is verified; the phone says one is.
      expect(verifiedIn(_owner), findsOneWidget);
      expect(verifiedIn(_admin), findsNothing);
      expect(verifiedIn(_stranger), findsNothing);
    });

    testWidgets('the member sheet carries the same name', (tester) async {
      await _pump(
        tester,
        GroupInfoPage(
          groupId: _groupId,
          injectedState: _state(),
          injectedMemberNames: names(),
          currentUserId: _owner,
          onMutate: (_) async => Result.success(_state()),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('group-member-$_stranger')));
      await tester.pumpAndSettle();

      // The row, and the title of the sheet over it.
      expect(find.text(strings.groupUnknownMember), findsNWidgets(2));
      expect(aUserId(), findsNothing);
    });
  });

  group('the group chat', () {
    testWidgets('author labels and reply quotes use the same names', (
      tester,
    ) async {
      await _pump(
        tester,
        GroupChatPage(
          groupId: _groupId,
          injectedState: _state(),
          injectedMemberNames: names(),
          injectedMessages: [
            _message(_questionId, sender: _admin, text: 'Original question'),
            _message(
              _answerId,
              sender: _stranger,
              text: 'An answer',
              at: 200,
              replyTo: _questionId,
            ),
          ],
          currentUserId: _owner,
          onSend: (_, {replyToMessageId, quoteFallback}) async =>
              const Result.success(null),
        ),
      );

      Finder inMessage(String messageId, String text) => find.descendant(
        of: find.byKey(ValueKey('message-$messageId')),
        matching: find.text(text),
      );
      // The author of the question, and of the answer.
      expect(inMessage(_questionId, 'bob'), findsOneWidget);
      expect(inMessage(_answerId, strings.groupUnknownMember), findsOneWidget);
      // The answer quotes the question, with the name of its author.
      expect(inMessage(_answerId, 'bob'), findsOneWidget);
      expect(aUserId(), findsNothing);
      expect(find.textContaining('…'), findsNothing);
    });
  });

  group('Create Group', () {
    testWidgets('a restored session stores its username as the owner\'s name', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final repository = _Repository();
      final harness = _RestoredHarness();
      addTearDown(harness.close);
      final container = ProviderContainer(
        overrides: [
          authenticationUseCasesProvider.overrideWithValue(harness.useCases),
          currentMessagingDeviceIdProvider.overrideWith(
            (ref) => Future.value('00000000-0000-0000-0000-000000000011'),
          ),
          contactListProvider.overrideWith(
            (ref, ownUserId) => Stream.value([
              const ContactProjection(
                userId: _admin,
                username: 'bob',
                trustState: ContactTrustState.unverified,
              ),
            ]),
          ),
          groupUseCasesProvider.overrideWith((ref) => repository.useCases()),
        ],
      );
      addTearDown(container.dispose);
      // A cold start: nothing was typed, so the name can only come from the
      // stored session.
      await container.read(authenticationControllerProvider.notifier).restore();
      expect(
        container.read(authenticationControllerProvider).username,
        'alice',
      );

      final router = GoRouter(
        initialLocation: '/chats/new',
        routes: [
          GoRoute(
            path: '/chats/new',
            builder: (context, state) => const CreateGroupPage(),
          ),
          GoRoute(
            path: '/chats',
            builder: (context, state) => const Text('Chats list'),
          ),
          GoRoute(
            path: '/groups/:groupId',
            builder: (context, state) => const Text('Group chat'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, appChild) =>
                AppDesignSystem(child: appChild ?? const SizedBox.shrink()),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final picker = find.byKey(const ValueKey('group-picker-$_admin'));
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('group-next')));
      await tester.tap(find.byKey(const ValueKey('group-next')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('group-name-field')),
          matching: find.byType(EditableText),
        ),
        'Private Team',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('group-create')));
      await tester.tap(find.byKey(const ValueKey('group-create')));
      await tester.pumpAndSettle();

      final created = repository.committed.single;
      final owner = created.members.singleWhere(
        (member) => member.role == GroupRole.owner,
      );
      expect(owner.userId, auth.userId);
      expect(owner.displayName, 'alice');
      expect(owner.displayName, isNot(owner.userId));
    });
  });
}

/// The roster as a control event decodes it on a receiving phone: user ids and
/// roles, and no name, with every member marked verified as the creator's
/// phone wrote it.
GroupState _state() => GroupState(
  groupId: _groupId,
  metadata: const GroupMetadata(name: 'Private Team', description: ''),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.reshareAvailable,
  members: [
    GroupMember(
      userId: _owner,
      displayName: '',
      role: GroupRole.owner,
      verified: true,
    ),
    GroupMember(
      userId: _admin,
      displayName: '',
      role: GroupRole.admin,
      verified: true,
    ),
    GroupMember(
      userId: _stranger,
      displayName: '',
      role: GroupRole.member,
      verified: true,
    ),
  ],
  controlRevision: 1,
  controlStateHash:
      '1010101010101010101010101010101010101010101010101010101010101010',
);

ConversationMessage _message(
  String messageId, {
  required String sender,
  required String text,
  int at = 100,
  String? replyTo,
}) => ConversationMessage(
  messageId: messageId,
  conversationId: _groupId,
  senderUserId: sender,
  senderDeviceId: 'device',
  text: text,
  replyToMessageId: replyTo,
  quoteFallback: null,
  createdMs: at,
  orderingMs: at,
  orderingEventId: messageId,
  timestampState: MessageTimestampState.plausible,
  revision: 0,
  edited: false,
  deletedForEveryone: false,
  deletedForMe: false,
  pinned: false,
  unread: false,
  transportState: MessageTransportState.received,
  receiptState: MessageReceiptState.none,
  reactions: const [],
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, appChild) =>
            AppDesignSystem(child: appChild ?? const SizedBox.shrink()),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Authentication whose stored session holds the username `alice`, so a
/// restore is the only place the name can come from.
final class _RestoredHarness {
  _RestoredHarness() {
    final repository = auth.WidgetAuthenticationRepository(
      loginResult: Result.success(
        AccountSessionGrant(
          accessToken: 'unused',
          accessExpiresAt: DateTime.utc(2026, 7, 28, 12),
          accessLifetime: const Duration(minutes: 10),
          userId: auth.userId,
          scope: AccountSessionScope.register,
        ),
      ),
      registrationResult: const Result.success(
        AccountRegistration(userId: auth.userId),
      ),
    );
    final session = auth.WidgetAuthenticationSession();
    final restoring = _RestoringSession();
    useCases = AuthenticationUseCases(
      register: RegisterAccount(repository),
      login: LoginAccount(repository, session),
      restore: RestoreAccountSession(restoring),
      logout: LogoutAccount(session),
      erase: EraseAccount(repository, session),
      lifecycle: lifecycle,
    );
  }

  final lifecycle = auth.WidgetLifecycle();
  late final AuthenticationUseCases useCases;

  Future<void> close() => lifecycle.close();
}

final class _RestoringSession implements AuthenticationSessionPort {
  @override
  Future<Result<AccountSessionBoundary>> restore() async => Result.success(
    AccountSessionBoundary(
      userId: auth.userId,
      deviceId: '00000000-0000-0000-0000-000000000011',
      username: 'alice',
      scope: AccountSessionScope.full,
      offline: false,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Keeps what a create commits. The state it commits is the only thing the
/// test reads.
final class _Repository implements GroupRepositoryPort {
  final committed = <GroupState>[];

  GroupUseCases useCases() {
    final crypto = _Crypto();
    final identity = _Identity();
    const clock = _Clock();
    return GroupUseCases(
      create: CreateGroup(
        repository: this,
        crypto: crypto,
        identity: identity,
        clock: clock,
      ),
      mutate: MutateGroup(
        repository: this,
        crypto: crypto,
        identity: identity,
        clock: clock,
      ),
      sendMessage: SendGroupMessage(repository: this, sender: _Sender()),
      retryMessage: RetryGroupMessage(repository: this, sender: _Sender()),
      setReaction: SetGroupReaction(repository: this, sender: _Sender()),
      deleteForEveryone: DeleteGroupMessageForEveryone(
        repository: this,
        sender: _Sender(),
      ),
    );
  }

  @override
  Future<Result<List<StoredGroupControl>>> readTranscript(
    String groupId, {
    int afterRevision = 0,
  }) async => const Result.success([]);

  @override
  Future<Result<void>> commitTransition({
    required GroupState? expectedPrevious,
    required GroupState next,
    required PreparedGroupTransition prepared,
  }) async {
    committed.add(next);
    return const Result.success(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Crypto implements GroupControlCryptoPort {
  @override
  Future<Result<SignedGroupControlEvent>> seal(GroupControlEvent event) async =>
      Result.success(
        SignedGroupControlEvent(
          event: event,
          controlStateHash: event.eventId * 2,
          canonicalBytes: Uint8List.fromList(utf8.encode(event.eventId)),
          signature: Uint8List(SignedGroupControlEvent.signatureBytes),
        ),
      );

  @override
  Future<Result<SignedGroupControlEvent>> open({
    required GroupSignedControlBytes control,
    required Uint8List signerSigningPublic,
  }) => throw UnimplementedError();
}

final class _Identity implements GroupIdentityPort {
  var _issued = 0;

  @override
  Future<Result<Uint8List>> randomIdentifier() async {
    _issued += 1;
    return Result.success(
      Uint8List.fromList(
        List<int>.generate(16, (index) => (_issued * 31 + index) & 0xff),
      ),
    );
  }
}

final class _Sender implements GroupMessageSenderPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 10, 18, 12);
}
