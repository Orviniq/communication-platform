import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/app/dependencies/group_member_name_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_info_page.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/authentication_harness.dart' as auth;

const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _owner = '00000000-0000-0000-0000-000000000003';
const _deviceId = '00000000-0000-0000-0000-000000000011';
const _chatsStandIn = 'The Chats list';

/// Leaving deletes the group from this phone, so Group Info has nothing left
/// to show and returns to Chats (ADR-096 D3).
void main() {
  final strings = lookupAppLocalizations(const Locale('en'));

  testWidgets('Leave says the group is deleted from this phone, and returns '
      'to Chats once it commits', (tester) async {
    final repository = _Repository(_state());
    final sweep = _Sweep();
    await _pump(tester, repository: repository, sweep: sweep);

    await tester.tap(find.text(strings.groupLeaveAction));
    await tester.pumpAndSettle();
    expect(find.text(strings.groupConfirmLeaveBody), findsOneWidget);
    expect(strings.groupConfirmLeaveBody, contains('deleted from this phone'));

    await tester.tap(find.text(strings.groupLeaveAction).last);
    await tester.pumpAndSettle();

    expect(find.text(_chatsStandIn), findsOneWidget);
    expect(find.byKey(const ValueKey('group-info-screen')), findsNothing);
    expect(repository.committed.single.lifecycle, GroupLifecycle.left);
    expect(sweep.sweeps, 1);
  });

  testWidgets('Group Info returns to Chats when another device of this '
      'account leaves, or an admin removes it', (tester) async {
    final repository = _Repository(_state());
    await _pump(tester, repository: repository, sweep: _Sweep());
    expect(find.byKey(const ValueKey('group-info-screen')), findsOneWidget);

    repository.changes.add(_state(lifecycle: GroupLifecycle.removed));
    await tester.pumpAndSettle();

    expect(find.text(_chatsStandIn), findsOneWidget);
    expect(repository.committed, isEmpty);
  });

  testWidgets('a refused Leave stays on Group Info and says so', (
    tester,
  ) async {
    final repository = _Repository(_state())..refuse = true;
    final sweep = _Sweep();
    await _pump(tester, repository: repository, sweep: sweep);

    await tester.tap(find.text(strings.groupLeaveAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.groupLeaveAction).last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-info-screen')), findsOneWidget);
    expect(find.text(strings.groupActionFailed), findsOneWidget);
    expect(find.text(_chatsStandIn), findsNothing);
    expect(sweep.sweeps, 0);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required _Repository repository,
  required _Sweep sweep,
}) async {
  // Tall enough that the whole of Group Info, Leave included, is built.
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 2000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final harness = auth.AuthenticationHarness();
  addTearDown(harness.close);
  final container = ProviderContainer(
    overrides: [
      authenticationUseCasesProvider.overrideWithValue(harness.useCases),
      currentMessagingDeviceIdProvider.overrideWith(
        (ref) => Future.value(_deviceId),
      ),
      groupProvider.overrideWith((ref, groupId) async* {
        yield repository.state;
        yield* repository.changes.stream;
      }),
      groupMemberNamesProvider.overrideWith(
        (ref, request) => Stream.value(
          GroupMemberNames({
            _owner: const GroupMemberName(name: 'Owner', verified: true),
            auth.userId: const GroupMemberName(name: 'Me', verified: true),
          }),
        ),
      ),
      groupUseCasesProvider.overrideWith(
        (ref) => GroupUseCases(
          create: CreateGroup(
            repository: repository,
            crypto: const _Crypto(),
            identity: const _Identity(),
            clock: const _Clock(),
          ),
          mutate: MutateGroup(
            repository: repository,
            crypto: const _Crypto(),
            identity: const _Identity(),
            clock: const _Clock(),
            removalSweep: sweep,
          ),
          sendMessage: SendGroupMessage(
            repository: repository,
            sender: _UnusedSender(),
          ),
          retryMessage: RetryGroupMessage(
            repository: repository,
            sender: _UnusedSender(),
          ),
          setReaction: SetGroupReaction(
            repository: repository,
            sender: _UnusedSender(),
          ),
          deleteForEveryone: DeleteGroupMessageForEveryone(
            repository: repository,
            sender: _UnusedSender(),
          ),
          setPin: SetGroupPin(repository: repository, sender: _UnusedSender()),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  // Not awaited: a page still on screen holds the stream, and its close waits
  // for that listener.
  addTearDown(() => unawaited(repository.changes.close()));
  expect(
    await container
        .read(authenticationControllerProvider.notifier)
        .login(username: 'reader', password: 'correct horse battery'),
    isTrue,
  );
  final router = GoRouter(
    initialLocation: '/chats',
    routes: [
      GoRoute(
        path: '/chats',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text(_chatsStandIn))),
      ),
      GoRoute(
        path: '/groups/:groupId/info',
        builder: (context, state) =>
            GroupInfoPage(groupId: state.pathParameters['groupId']!),
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
        locale: const Locale('en'),
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Group Info above Chats, as the group chat's header opens it.
  unawaited(router.push('/groups/$_groupId/info'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('group-info-screen')), findsOneWidget);
}

/// This account as a member of a group another user owns.
GroupState _state({GroupLifecycle lifecycle = GroupLifecycle.active}) =>
    GroupState(
      groupId: _groupId,
      metadata: const GroupMetadata(name: 'Team'),
      invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
      historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
      members: [
        GroupMember(userId: _owner, displayName: '', role: GroupRole.owner),
        GroupMember(
          userId: auth.userId,
          displayName: '',
          role: GroupRole.member,
          membership: lifecycle == GroupLifecycle.removed
              ? GroupMembershipState.removed
              : GroupMembershipState.active,
        ),
      ],
      controlRevision: 1,
      controlStateHash: '10' * 32,
      lifecycle: lifecycle,
    );

/// The group store as Group Info and the change use case see it: a commit
/// becomes the state the page is watching, as the database would make it.
final class _Repository implements GroupRepositoryPort {
  _Repository(this.state);

  GroupState state;
  final changes = StreamController<GroupState?>();
  final committed = <GroupState>[];
  var refuse = false;

  @override
  Future<Result<GroupState?>> readGroup(String groupId) async =>
      Result.success(state);

  @override
  Future<Result<void>> commitTransition({
    required GroupState? expectedPrevious,
    required GroupState next,
    required PreparedGroupTransition prepared,
  }) async {
    if (refuse) {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    state = next;
    committed.add(next);
    changes.add(next);
    return const Result.success(null);
  }

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

/// Seals without signing: the state machine checks the chain, not the key.
final class _Crypto implements GroupControlCryptoPort {
  const _Crypto();

  @override
  Future<Result<SignedGroupControlEvent>> seal(GroupControlEvent event) async =>
      Result.success(
        SignedGroupControlEvent(
          event: event,
          controlStateHash: '20' * 32,
          canonicalBytes: Uint8List.fromList(const [1, 2, 3]),
          signature: Uint8List(64),
        ),
      );

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _Identity implements GroupIdentityPort {
  const _Identity();

  @override
  Future<Result<Uint8List>> randomIdentifier() async =>
      Result.success(Uint8List.fromList(List<int>.filled(16, 7)));
}

final class _Sweep implements GroupRemovalSweepPort {
  var sweeps = 0;

  @override
  Future<void> sweepAfterGroupRemoval() async => sweeps += 1;
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() =>
      DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true);
}

final class _UnusedSender implements GroupMessageSenderPort {
  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}
