import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/development_in_memory_group_mls.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/storage_fault_injection.dart';

/// Transaction-failure injection for the piece-18 compare-and-swap boundary on
/// the closed-beta group path.
///
/// `docs/local-data-model.md` ("Transaction boundaries" -> "MLS state") requires
/// that new opaque MLS state, the accepted control or application fact, the
/// membership/conversation projections, and the exact prepared outbound object
/// commit as one compare-and-swap unit, before any network I/O. That is a claim
/// about what survives an interruption, so each test aborts one exact statement
/// inside the real transaction and then asserts the whole unit is absent.
///
/// The two directions of the invariant are named explicitly, because only one
/// of them is obvious: state must never outlive its outbound ciphertext, and
/// the outbound ciphertext must never outlive the state that produced it. Both
/// would be silent in production - the first fails as an unexplained peer
/// divergence an epoch later, the second as an object no live epoch can open.
const _owner = '10000000-0000-4000-8000-000000000001';
const _ownerDevice = '20000000-0000-4000-8000-000000000001';
const _member = '30000000-0000-4000-8000-000000000001';
const _memberDevice = '40000000-0000-4000-8000-000000000001';
const _invitee = '50000000-0000-4000-8000-000000000001';
const _inviteeDevice = '60000000-0000-4000-8000-000000000001';

void main() {
  late LocalDatabase database;
  late DriftGroupRepository repository;
  late StorageFaultInjector faults;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    repository = DriftGroupRepository(database);
    faults = StorageFaultInjector(database);
    for (final userId in const [_owner, _member, _invitee]) {
      await _insertUser(database, userId);
    }
  });

  tearDown(() => database.close());

  group('creation commits as one unit or not at all', () {
    // The headline cell: an epoch that exists locally but whose Commit was
    // never persisted can never be transmitted, so every peer stays an epoch
    // behind forever and this device cannot tell why.
    test('no group survives a failed outbound-object write', () async {
      await faults.failOn('group_outbound_objects', InjectedWrite.insert);

      final result = await _create(repository);

      expect(
        (result as FailureResult<GroupState>).failure,
        const StorageFailure(StorageFailureKind.unavailable),
      );
      await _expectNothingPersisted(database);
    });

    test('no outbound object survives a failed opaque-state write', () async {
      await faults.failOn('mls_groups', InjectedWrite.insert);

      final result = await _create(repository);

      expect(result, isA<FailureResult<GroupState>>());
      await _expectNothingPersisted(database);
    });

    test('no state survives a failed control-fact write', () async {
      await faults.failOn('group_control_events', InjectedWrite.insert);

      final result = await _create(repository);

      expect(result, isA<FailureResult<GroupState>>());
      await _expectNothingPersisted(database);
    });

    test('no state survives a failed conversation projection', () async {
      await faults.failOn('conversations', InjectedWrite.insert);

      final result = await _create(repository);

      expect(result, isA<FailureResult<GroupState>>());
      await _expectNothingPersisted(database);
    });

    test('no state survives a failed membership projection', () async {
      await faults.failOn('memberships', InjectedWrite.insert);

      final result = await _create(repository);

      expect(result, isA<FailureResult<GroupState>>());
      await _expectNothingPersisted(database);
    });
  });

  group('a control transition never half-advances an epoch', () {
    late GroupState created;

    setUp(() async {
      created = (await _create(repository) as Success<GroupState>).value;
    });

    test('a failed outbound-object write leaves the parent epoch', () async {
      await faults.failOn('group_outbound_objects', InjectedWrite.insert);

      final result = await _invite(repository, created);

      expect(result, isA<FailureResult<GroupState>>());
      await _expectUnchangedSince(database, created, outboundObjects: 1);
    });

    test('a failed control-fact write leaves the parent epoch', () async {
      await faults.failOn('group_control_events', InjectedWrite.insert);

      final result = await _invite(repository, created);

      expect(result, isA<FailureResult<GroupState>>());
      await _expectUnchangedSince(database, created, outboundObjects: 1);
    });

    test('a failed roster projection leaves the parent epoch', () async {
      await faults.failOn('memberships', InjectedWrite.insert);

      final result = await _invite(repository, created);

      expect(result, isA<FailureResult<GroupState>>());
      await _expectUnchangedSince(database, created, outboundObjects: 1);
      // The roster is deleted and rewritten inside the transaction, so a
      // failure here is the one that could plausibly leave a group with no
      // members at all rather than merely an unchanged one.
      expect(await database.select(database.memberships).get(), hasLength(2));
    });

    test('a failed opaque-state write leaves the parent epoch', () async {
      await faults.failOn('mls_groups', InjectedWrite.update);

      final result = await _invite(repository, created);

      expect(result, isA<FailureResult<GroupState>>());
      await _expectUnchangedSince(database, created, outboundObjects: 1);
    });

    test('a concurrent revision wins the compare-and-swap', () async {
      // Prepared against the parent, then overtaken before it could commit.
      // Nothing about the losing branch may survive - least of all its
      // outbound object, which peers would open at an epoch that never was.
      final crypto = DevelopmentInMemoryGroupMls.forTests(seed: 700);
      final stale =
          await crypto.prepareControl(
                current: created,
                currentOpaqueMlsState: Uint8List.fromList([1]),
                operation: const UpdateGroupMetadataOperation(
                  GroupMetadata(name: 'Losing branch'),
                ),
                actorUserId: _owner,
                actorDeviceId: _ownerDevice,
                createdMs: 1_700_000_000_200,
              )
              as Success<PreparedGroupTransition>;
      final losing =
          const GroupControlStateMachine().apply(
                previous: created,
                signedControl: stale.value.signedControl,
                localUserId: _owner,
              )
              as GroupControlAccepted;
      final concurrent =
          await _invite(repository, created) as Success<GroupState>;

      final result = await repository.commitTransition(
        expectedPrevious: created,
        next: losing.state,
        prepared: stale.value,
        developmentPreviewOnly: false,
      );

      expect(
        (result as FailureResult<void>).failure,
        const ValidationFailure(ValidationFailureKind.conflict),
      );
      await _expectUnchangedSince(
        database,
        concurrent.value,
        outboundObjects: 2,
      );
    });
  });

  group('an application message never advances state alone', () {
    late GroupState created;

    setUp(() async {
      created = (await _create(repository) as Success<GroupState>).value;
      await database.delete(database.groupOutboundObjects).go();
    });

    test('a failed outbound-object write leaves no message', () async {
      await faults.failOn('group_outbound_objects', InjectedWrite.insert);

      final result = await _send(repository, created);

      expect(result, isA<FailureResult<GroupMessage>>());
      await _expectNoMessage(database, created);
    });

    test('a failed message projection leaves no outbound object', () async {
      await faults.failOn('messages', InjectedWrite.insert);

      final result = await _send(repository, created);

      expect(result, isA<FailureResult<GroupMessage>>());
      await _expectNoMessage(database, created);
    });

    test('a failed immutable fact leaves no outbound object', () async {
      await faults.failOn('message_events', InjectedWrite.insert);

      final result = await _send(repository, created);

      expect(result, isA<FailureResult<GroupMessage>>());
      await _expectNoMessage(database, created);
    });

    test('a failed ratchet-state write leaves no outbound object', () async {
      await faults.failOn('mls_groups', InjectedWrite.update);

      final result = await _send(repository, created);

      expect(result, isA<FailureResult<GroupMessage>>());
      await _expectNoMessage(database, created);
    });

    test('a stale compare-and-swap witness commits nothing', () async {
      final stale = created.copyWith(
        controlStateHash: List.filled(32, 'ee').join(),
      );

      final result = await repository.commitMessage(
        expectedGroup: stale,
        prepared: _preparedMessage(created, messageId: 'a' * 32),
        developmentPreviewOnly: false,
      );

      expect(
        (result as FailureResult<void>).failure,
        const ValidationFailure(ValidationFailureKind.conflict),
      );
      await _expectNoMessage(database, created);
    });
  });

  group('an interrupted commit leaves durable storage usable', () {
    test('the database reopens clean and the retry succeeds', () async {
      final restartable = await RestartableDatabase.create('group-commit-');
      addTearDown(restartable.dispose);
      var live = restartable.database;
      for (final userId in const [_owner, _member, _invitee]) {
        await _insertUser(live, userId);
      }
      await StorageFaultInjector(
        live,
      ).failOn('group_outbound_objects', InjectedWrite.insert);

      final interrupted = await _create(DriftGroupRepository(live));
      expect(interrupted, isA<FailureResult<GroupState>>());

      // Process death: every Dart object goes, the file stays. The reopen runs
      // the production `beforeOpen` path, whose `PRAGMA quick_check` throws
      // `LocalDatabaseIntegrityException` if the aborted write corrupted it.
      live = await restartable.restart();
      final restarted = DriftGroupRepository(live);

      expect(await live.select(live.mlsGroups).get(), isEmpty);
      final retried = await _create(restarted, seed: 900);
      expect(retried, isA<Success<GroupState>>());
      expect(
        (await live.select(live.groupOutboundObjects).getSingle())
            .deliveryState,
        1,
      );
    });
  });

  group('direction is part of the boundary', () {
    // A locally originated transition that carries no outbound object would
    // advance this device's epoch with nothing to send. The inbound paths
    // already refuse the mirror image of this, so the outbound ones must too.
    test(
      'a local transition prepared with no outbound work is refused',
      () async {
        final result =
            await CreateGroup(
              repository: repository,
              crypto: _InboundShapedCrypto(),
              clock: const _Clock(),
              developmentPreviewOnly: false,
            ).call(
              currentUserId: _owner,
              currentDeviceId: _ownerDevice,
              ownerDisplayName: 'Owner',
              metadata: const GroupMetadata(name: 'Directionless'),
              selectedMembers: [_memberOf(_member, _memberDevice)],
            );

        expect(
          (result as FailureResult<GroupState>).failure,
          const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
        await _expectNothingPersisted(database);
      },
    );

    test('a local message prepared with no outbound work is refused', () async {
      final created = (await _create(repository) as Success<GroupState>).value;
      await database.delete(database.groupOutboundObjects).go();

      final result =
          await SendGroupMessage(
            repository: repository,
            crypto: _InboundShapedCrypto(),
            clock: const _Clock(),
            developmentPreviewOnly: false,
          ).call(
            groupId: created.groupId,
            senderUserId: _owner,
            senderDeviceId: _ownerDevice,
            text: 'directionless',
          );

      expect(
        (result as FailureResult<GroupMessage>).failure,
        const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
      await _expectNoMessage(database, created);
    });
  });
}

Future<Result<GroupState>> _create(
  DriftGroupRepository repository, {
  int seed = 600,
}) =>
    CreateGroup(
      repository: repository,
      crypto: DevelopmentInMemoryGroupMls.forTests(seed: seed),
      clock: const _Clock(),
      developmentPreviewOnly: false,
    ).call(
      currentUserId: _owner,
      currentDeviceId: _ownerDevice,
      ownerDisplayName: 'Owner',
      metadata: const GroupMetadata(name: 'Beta group'),
      selectedMembers: [_memberOf(_member, _memberDevice)],
    );

Future<Result<GroupState>> _invite(
  DriftGroupRepository repository,
  GroupState current,
) =>
    MutateGroup(
      repository: repository,
      crypto: DevelopmentInMemoryGroupMls.forTests(seed: 650),
      clock: const _Clock(),
      developmentPreviewOnly: false,
    ).call(
      groupId: current.groupId,
      actorUserId: _owner,
      actorDeviceId: _ownerDevice,
      operation: InviteGroupMembersOperation([
        _memberOf(_invitee, _inviteeDevice),
      ]),
    );

Future<Result<GroupMessage>> _send(
  DriftGroupRepository repository,
  GroupState current,
) =>
    SendGroupMessage(
      repository: repository,
      crypto: DevelopmentInMemoryGroupMls.forTests(seed: 680),
      clock: const _Clock(),
      developmentPreviewOnly: false,
    ).call(
      groupId: current.groupId,
      senderUserId: _owner,
      senderDeviceId: _ownerDevice,
      text: 'beta group message',
    );

GroupMember _memberOf(String userId, String deviceId) => GroupMember(
  userId: userId,
  displayName: 'Member',
  role: GroupRole.member,
  deviceIds: [deviceId],
);

PreparedGroupMessage _preparedMessage(
  GroupState group, {
  required String messageId,
}) => PreparedGroupMessage(
  groupId: group.groupId,
  messageId: messageId,
  senderUserId: _owner,
  senderDeviceId: _ownerDevice,
  text: 'stale witness',
  createdMs: 1_700_000_000_100,
  epoch: group.acceptedEpoch,
  newOpaqueMlsState: Uint8List.fromList([44]),
  mlsObject: Uint8List.fromList('CPGTO001-stale'.codeUnits),
  operationId: 'stale-$messageId',
  recipientUserIds: const [_owner, _member],
);

Future<void> _expectNothingPersisted(LocalDatabase database) async {
  expect(await database.select(database.mlsGroups).get(), isEmpty);
  expect(await database.select(database.conversations).get(), isEmpty);
  expect(await database.select(database.groupControlEvents).get(), isEmpty);
  expect(await database.select(database.groupOutboundObjects).get(), isEmpty);
  expect(await database.select(database.memberships).get(), isEmpty);
  expect(await database.select(database.messages).get(), isEmpty);
}

/// Asserts the group is byte-for-byte the epoch it was before the interrupted
/// transition, and that no new outbound object appeared beside it.
Future<void> _expectUnchangedSince(
  LocalDatabase database,
  GroupState expected, {
  required int outboundObjects,
}) async {
  final row = await (database.select(
    database.mlsGroups,
  )..where((item) => item.groupId.equals(expected.groupId))).getSingle();
  expect(row.controlRevision, expected.controlRevision);
  expect(row.acceptedEpoch, expected.acceptedEpoch);
  expect(
    await database.select(database.groupControlEvents).get(),
    hasLength(expected.controlRevision),
  );
  expect(
    await database.select(database.groupOutboundObjects).get(),
    hasLength(outboundObjects),
  );
}

Future<void> _expectNoMessage(LocalDatabase database, GroupState group) async {
  expect(await database.select(database.messages).get(), isEmpty);
  expect(await database.select(database.messageEvents).get(), isEmpty);
  expect(await database.select(database.groupOutboundObjects).get(), isEmpty);
  final row = await (database.select(
    database.mlsGroups,
  )..where((item) => item.groupId.equals(group.groupId))).getSingle();
  expect(row.stateVersion, 1);
}

Future<void> _insertUser(LocalDatabase database, String userId) => database
    .into(database.users)
    .insert(
      UsersCompanion.insert(
        userId: userId,
        activated: true,
        directoryEntryCiphertext: Uint8List.fromList([1]),
        localState: 0,
      ),
    );

/// Returns transitions shaped like an *inbound* result - no outbound object -
/// from the locally originated preparation calls.
final class _InboundShapedCrypto implements GroupMlsCryptoPort {
  final _delegate = DevelopmentInMemoryGroupMls.forTests(seed: 950);

  @override
  Future<Result<PreparedGroupTransition>> prepareCreate(
    GroupCreationIntent intent,
  ) async {
    final prepared =
        await _delegate.prepareCreate(intent)
            as Success<PreparedGroupTransition>;
    return Result.success(
      PreparedGroupTransition(
        signedControl: prepared.value.signedControl,
        newOpaqueMlsState: prepared.value.newOpaqueMlsState,
        mlsObject: prepared.value.mlsObject,
        mutationId: prepared.value.mutationId,
        recipientUserIds: const [],
        outbound: false,
      ),
    );
  }

  @override
  Future<Result<PreparedGroupMessage>> prepareApplicationMessage({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required String senderUserId,
    required String senderDeviceId,
    required String text,
    required int createdMs,
  }) async {
    final prepared =
        await _delegate.prepareApplicationMessage(
              current: current,
              currentOpaqueMlsState: currentOpaqueMlsState,
              senderUserId: senderUserId,
              senderDeviceId: senderDeviceId,
              text: text,
              createdMs: createdMs,
            )
            as Success<PreparedGroupMessage>;
    return Result.success(
      PreparedGroupMessage(
        groupId: prepared.value.groupId,
        messageId: prepared.value.messageId,
        senderUserId: prepared.value.senderUserId,
        senderDeviceId: prepared.value.senderDeviceId,
        text: prepared.value.text,
        createdMs: prepared.value.createdMs,
        epoch: prepared.value.epoch,
        newOpaqueMlsState: prepared.value.newOpaqueMlsState,
        mlsObject: prepared.value.mlsObject,
        operationId: prepared.value.operationId,
        recipientUserIds: const [],
        outbound: false,
      ),
    );
  }

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) => throw UnimplementedError();
  @override
  Future<Result<PreparedGroupMessage>> inspectIncomingApplication({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) => throw UnimplementedError();
  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingWelcome({
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) => throw UnimplementedError();
  @override
  Future<Result<PreparedGroupTransition>> prepareControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
    required int createdMs,
  }) => throw UnimplementedError();
  @override
  Future<Result<GroupMlsTransportProbe>> probeIncomingTransport(
    Uint8List mlsObject,
  ) => throw UnimplementedError();
  @override
  Future<Result<GroupForkResolution>> reconcileFork({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required List<Uint8List> siblingCommits,
    required String localUserId,
    required String localDeviceId,
  }) => throw UnimplementedError();
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 8, 18, 9);
}
