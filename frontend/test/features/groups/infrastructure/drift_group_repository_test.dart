import 'dart:convert';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = '10000000-0000-4000-8000-000000000001';
const _ownerDevice = '20000000-0000-4000-8000-000000000001';
const _member = '30000000-0000-4000-8000-000000000001';
const _outsider = '40000000-0000-4000-8000-000000000001';
const _envelope = '50000000-0000-4000-8000-000000000001';
final _groupA = 'a1' * 32;
final _groupB = 'b2' * 32;
final _groupC = 'c3' * 32;

/// A group's roster is client state (`backend/CLIENT_CONTRACT.md` §F): the
/// projection, the signed transcript that justifies it, the bytes it still
/// owes, and the requests it still waits on all live in this store.
void main() {
  late LocalDatabase database;
  late DriftGroupRepository repository;

  Future<({GroupState group, SignedGroupControlEvent create})> commitCreate(
    String groupId, {
    String localUserId = _owner,
    List<GroupOutboundWork> outbound = const [],
  }) async {
    final create = _signed(
      groupId,
      revision: 1,
      previous: null,
      operation: _createOperation(),
    );
    final group = _apply(null, create, localUserId: localUserId);
    final committed = await repository.commitTransition(
      expectedPrevious: null,
      next: group,
      prepared: PreparedGroupTransition(controls: [create], outbound: outbound),
    );
    expect(committed, isA<Success<void>>());
    return (group: group, create: create);
  }

  Future<GroupState> stored(String groupId) async =>
      (await repository.readStoredGroup(groupId) as Success<GroupState?>)
          .value!;

  Future<GroupState> projected(String groupId) async =>
      (await repository.readGroup(groupId) as Success<GroupState?>).value!;

  Future<(QueueGapState, int)> gap(DriftSyncStore sync) async {
    final projection =
        (await sync.readProjection() as Success<SyncProjection>).value;
    return (
      projection.queueGapState,
      projection.highestContiguousAcknowledgedSequence,
    );
  }

  Future<void> drainWithGap(DriftSyncStore sync) async {
    final persisted = await sync.persistDrainPage(
      DrainPage(
        envelopes: [
          SyncEnvelope(
            id: _envelope,
            sequence: 6,
            exactCiphertext: Uint8List(1024),
          ),
        ],
        hasMore: false,
        prunedThrough: 5,
      ),
    );
    expect(persisted, isA<Success<void>>());
  }

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    repository = DriftGroupRepository(database);
  });

  tearDown(() => database.close());

  test(
    'a group reads back exactly as committed, with its transcript',
    () async {
      final (:group, :create) = await commitCreate(_groupA);

      final read = await stored(_groupA);
      expect(read.groupId, _groupA);
      expect(read.metadata, group.metadata);
      expect(read.invitationPolicy, group.invitationPolicy);
      expect(read.historySharingPolicy, group.historySharingPolicy);
      expect(read.members, group.members);
      expect(read.controlRevision, 1);
      expect(read.controlStateHash, create.controlStateHash);
      expect(read.lifecycle, GroupLifecycle.active);
      expect((await projected(_groupA)).lifecycle, GroupLifecycle.active);

      final transcript =
          (await repository.readTranscript(_groupA)
                  as Success<List<StoredGroupControl>>)
              .value;
      expect(transcript.single.eventId, create.event.eventId);
      expect(transcript.single.previousControlStateHash, isNull);
      expect(transcript.single.controlStateHash, create.controlStateHash);
      expect(transcript.single.signerUserId, _owner);
      expect(transcript.single.signerDeviceId, _ownerDevice);
      expect(transcript.single.canonicalBytes, create.canonicalBytes);
      expect(transcript.single.signature, create.signature);

      final conversation = await database
          .select(database.conversations)
          .getSingle();
      expect(conversation.conversationId, _groupA);
      expect(conversation.kind, ConversationKind.group.index);
      expect(utf8.decode(conversation.displayTitleCiphertext!), 'Stored');
    },
  );

  test(
    'a transition built on a state another commit replaced is refused whole',
    () async {
      final (:group, :create) = await commitCreate(_groupA);
      final first = _signed(
        _groupA,
        revision: 2,
        previous: create,
        operation: const RenameGroupOperation(GroupMetadata(name: 'First')),
      );
      final second = _signed(
        _groupA,
        revision: 2,
        previous: create,
        operation: const RenameGroupOperation(GroupMetadata(name: 'Second')),
        branch: 1,
      );
      expect(
        await repository.commitTransition(
          expectedPrevious: group,
          next: _apply(group, first),
          prepared: PreparedGroupTransition(controls: [first]),
        ),
        isA<Success<void>>(),
      );

      final result = await repository.commitTransition(
        expectedPrevious: group,
        next: _apply(group, second),
        prepared: PreparedGroupTransition(
          controls: [second],
          outbound: [_work(_groupA, 'never-queued')],
        ),
      );

      expect(
        (result as FailureResult<void>).failure,
        const ValidationFailure(ValidationFailureKind.conflict),
      );
      expect((await stored(_groupA)).metadata.name, 'First');
      expect(
        (await repository.readTranscript(_groupA)
                as Success<List<StoredGroupControl>>)
            .value
            .map((entry) => entry.eventId),
        [create.event.eventId, first.event.eventId],
      );
      expect(
        await database.select(database.groupOutboundObjects).get(),
        isEmpty,
      );
    },
  );

  test('a transition that does not continue its own base is refused', () async {
    final (:group, :create) = await commitCreate(_groupA);
    final rename = _signed(
      _groupA,
      revision: 2,
      previous: create,
      operation: const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
    );

    final result = await repository.commitTransition(
      expectedPrevious: null,
      next: _apply(group, rename),
      prepared: PreparedGroupTransition(controls: [rename]),
    );

    expect(
      (result as FailureResult<void>).failure,
      const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );
    expect((await stored(_groupA)).controlRevision, 1);
  });

  test('owed bytes are queued once and routed once', () async {
    final work = _work(_groupA, 'group-control:first', includeOwnDevices: true);
    await commitCreate(_groupA, outbound: [work]);
    await database.transaction(
      () => repository.queueOutboundInsideTransaction(work),
    );

    final pending =
        (await repository.readPendingOutbound()
                as Success<List<GroupOutboundWork>>)
            .value;
    expect(pending, hasLength(1));
    expect(pending.single.operationId, work.operationId);
    expect(pending.single.eventId, work.eventId);
    expect(pending.single.payload, work.payload);
    expect(pending.single.recipientUserIds, [_member]);
    expect(pending.single.recipientDeviceId, isNull);
    expect(pending.single.includeOwnDevices, isTrue);

    expect(
      await repository.markOutboundRouted(operationId: work.operationId),
      isA<Success<void>>(),
    );
    expect(
      await repository.markOutboundRouted(operationId: work.operationId),
      isA<Success<void>>(),
    );
    expect(
      (await repository.readPendingOutbound()
              as Success<List<GroupOutboundWork>>)
          .value,
      isEmpty,
    );
    expect(
      (await repository.markOutboundRouted(operationId: 'missing')
              as FailureResult<void>)
          .failure,
      const ValidationFailure(ValidationFailureKind.conflict),
    );
  });

  test(
    'a queue gap asks every active group, and closes when the last one answers',
    () async {
      await commitCreate(_groupA);
      await commitCreate(_groupB);
      // A group this device is not in cannot be answered for it.
      await commitCreate(_groupC, localUserId: _outsider);
      final sync = DriftSyncStore(database);

      await drainWithGap(sync);

      final requests = await database.select(database.groupStateRequests).get();
      expect(
        requests.map((row) => (row.groupId, row.reason)),
        unorderedEquals([(_groupA, 0), (_groupB, 0)]),
      );
      expect(
        (await projected(_groupA)).lifecycle,
        GroupLifecycle.stateRecoveryRequired,
      );
      expect((await stored(_groupA)).lifecycle, GroupLifecycle.active);
      expect(await gap(sync), (QueueGapState.recoveryRequired, 0));

      expect(
        await repository.retireStateRequest(_groupA),
        isA<Success<void>>(),
      );

      expect(await gap(sync), (QueueGapState.recoveryRequired, 0));

      expect(
        await repository.retireStateRequest(_groupB),
        isA<Success<void>>(),
      );

      expect(await gap(sync), (QueueGapState.clear, 5));
      expect((await projected(_groupA)).lifecycle, GroupLifecycle.active);
    },
  );

  test('a queue gap with no group to ask closes at once', () async {
    await commitCreate(_groupC, localUserId: _outsider);
    final sync = DriftSyncStore(database);

    await drainWithGap(sync);

    expect(await database.select(database.groupStateRequests).get(), isEmpty);
    expect(await gap(sync), (QueueGapState.clear, 5));
  });

  test(
    'a closing gap releases envelopes already acknowledged above it',
    () async {
      await commitCreate(_groupA);
      final sync = DriftSyncStore(database);
      await drainWithGap(sync);
      // Nothing waits on the gap, so the envelope above it is opened and
      // acknowledged while the group's request is still open.
      await (database.update(database.inboxEnvelopes)).write(
        InboxEnvelopesCompanion(
          processingState: Value(InboxProcessingState.acknowledged.index),
        ),
      );

      await repository.retireStateRequest(_groupA);

      expect(await gap(sync), (QueueGapState.clear, 6));
      expect(await database.select(database.inboxEnvelopes).get(), isEmpty);
    },
  );

  test(
    'requests for unknown groups are bounded, and an open one is kept',
    () async {
      for (
        var index = 0;
        index < DriftGroupRepository.maximumStateRequests + 3;
        index += 1
      ) {
        await repository.openStateRequest(
          groupId: index.toRadixString(16).padLeft(64, '0'),
          peerUserId: _member,
        );
      }

      expect(
        await database.select(database.groupStateRequests).get(),
        hasLength(DriftGroupRepository.maximumStateRequests),
      );

      await repository.openStateRequest(groupId: '0' * 64, peerUserId: _owner);

      final first = await (database.select(
        database.groupStateRequests,
      )..where((row) => row.groupId.equals('0' * 64))).getSingle();
      expect(first.peerUserId, _member);
      expect(first.reason, 1);
    },
  );

  test(
    'a sent request records who was asked, and waits before asking again',
    () async {
      await repository.openStateRequest(groupId: _groupA, peerUserId: _member);
      final requestedAt = DateTime.utc(2026, 9, 13, 12);
      final work = _work(_groupA, 'group-state-request:$_groupA:1');

      expect(
        await repository.recordStateRequestSent(
          groupId: _groupA,
          peerUserId: _owner,
          work: work,
          requestedAt: requestedAt,
        ),
        isA<Success<void>>(),
      );

      final row = await database
          .select(database.groupStateRequests)
          .getSingle();
      expect(row.peerUserId, _owner);
      expect(row.attempts, 1);
      expect(row.requestedAt!.toUtc(), requestedAt);
      expect(
        (await repository.readPendingOutbound()
                as Success<List<GroupOutboundWork>>)
            .value
            .single
            .operationId,
        work.operationId,
      );

      Future<List<GroupStateRequest>> due(DateTime retryBefore) async =>
          (await repository.readDueStateRequests(retryBefore: retryBefore)
                  as Success<List<GroupStateRequest>>)
              .value;
      expect(
        await due(requestedAt.subtract(const Duration(seconds: 1))),
        isEmpty,
      );
      final again = (await due(requestedAt)).single;
      expect(again.reason, GroupStateRequestReason.behind);
      expect(again.peerUserId, _owner);
      expect(again.attempts, 1);

      final unopened = await repository.recordStateRequestSent(
        groupId: _groupB,
        peerUserId: _owner,
        work: _work(_groupB, 'group-state-request:$_groupB:1'),
        requestedAt: requestedAt,
      );
      expect(
        (unopened as FailureResult<void>).failure,
        const ValidationFailure(ValidationFailureKind.conflict),
      );
    },
  );

  test(
    'a confirmation retires only the request for the state it saw',
    () async {
      final (:group, :create) = await commitCreate(_groupA);
      await repository.openStateRequest(groupId: _groupA, peerUserId: _member);

      await database.transaction(
        () => repository.confirmStateCurrentInsideTransaction(
          groupId: _groupA,
          controlRevision: 2,
          controlStateHash: group.controlStateHash,
        ),
      );

      expect(
        await database.select(database.groupStateRequests).get(),
        hasLength(1),
      );

      await database.transaction(
        () => repository.confirmStateCurrentInsideTransaction(
          groupId: _groupA,
          controlRevision: 1,
          controlStateHash: create.controlStateHash,
        ),
      );

      expect(await database.select(database.groupStateRequests).get(), isEmpty);
    },
  );

  test(
    'a fork quarantines the group; a refused event only leaves a record',
    () async {
      await commitCreate(_groupA);
      GroupQuarantineRecord record(GroupQuarantineReason reason) =>
          GroupQuarantineRecord(
            groupId: _groupA,
            reason: reason,
            opaqueDigest: Uint8List(32),
            receivedAt: DateTime.utc(2026, 9, 13),
          );

      await database.transaction(
        () => repository.quarantineInsideTransaction(
          record(GroupQuarantineReason.unauthorizedControl),
          retainLifecycle: true,
        ),
      );

      expect((await stored(_groupA)).lifecycle, GroupLifecycle.active);
      expect(
        await database.select(database.quarantineRecords).get(),
        hasLength(1),
      );

      await database.transaction(
        () => repository.quarantineInsideTransaction(
          record(GroupQuarantineReason.siblingControl),
          retainLifecycle: false,
        ),
      );

      final forked = await stored(_groupA);
      expect(forked.lifecycle, GroupLifecycle.forkQuarantined);
      expect(forked.quarantineReason, GroupQuarantineReason.siblingControl);
      expect(
        await database.select(database.quarantineRecords).get(),
        hasLength(2),
      );
    },
  );

  test('storage that does not read back intact fails closed', () async {
    final (:group, :create) = await commitCreate(_groupA);
    final rename = _signed(
      _groupA,
      revision: 2,
      previous: create,
      operation: const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
    );
    await repository.commitTransition(
      expectedPrevious: group,
      next: _apply(group, rename),
      prepared: PreparedGroupTransition(controls: [rename]),
    );

    await (database.update(
      database.groupControlEvents,
    )..where((row) => row.revision.equals(2))).write(
      GroupControlEventsCompanion(
        previousControlStateHash: Value(Uint8List(32)),
      ),
    );

    expect(
      (await repository.readTranscript(_groupA) as FailureResult).failure,
      const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );

    await (database.update(database.groupStates)).write(
      GroupStatesCompanion(
        controlProjectionCiphertext: Value(
          Uint8List.fromList(utf8.encode('{}')),
        ),
      ),
    );

    expect(
      (await repository.readStoredGroup(_groupA) as FailureResult).failure,
      const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );
    expect(
      (await repository.readGroup(_groupA) as FailureResult).failure,
      const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );
  });
}

SignedGroupControlEvent _signed(
  String groupId, {
  required int revision,
  required SignedGroupControlEvent? previous,
  required GroupControlOperation operation,
  int branch = 0,
}) {
  final marker = ((branch << 4) | revision).toRadixString(16).padLeft(2, '0');
  final eventId = '${groupId.substring(0, 16)}${marker * 8}';
  return SignedGroupControlEvent(
    event: GroupControlEvent(
      eventId: eventId,
      groupId: groupId,
      revision: revision,
      previousControlStateHash: previous?.controlStateHash,
      signerUserId: _owner,
      signerDeviceId: _ownerDevice,
      createdMs: 1700000000000 + revision,
      operation: operation,
    ),
    controlStateHash: '${groupId.substring(0, 32)}${marker * 16}',
    canonicalBytes: Uint8List.fromList(utf8.encode('control $eventId')),
    signature: Uint8List.fromList(List<int>.filled(64, revision)),
  );
}

GroupState _apply(
  GroupState? previous,
  SignedGroupControlEvent signed, {
  String localUserId = _owner,
}) =>
    (const GroupControlStateMachine().apply(
              previous: previous,
              signedControl: signed,
              localUserId: localUserId,
            )
            as GroupControlAccepted)
        .state;

CreateGroupOperation _createOperation() => CreateGroupOperation(
  metadata: const GroupMetadata(name: 'Stored', description: 'Kept here'),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
  members: [
    GroupMember(
      userId: _owner,
      displayName: 'Owner',
      role: GroupRole.owner,
      verified: true,
    ),
    GroupMember(userId: _member, displayName: 'Member', role: GroupRole.member),
  ],
);

GroupOutboundWork _work(
  String groupId,
  String operationId, {
  bool includeOwnDevices = false,
}) => GroupOutboundWork(
  operationId: operationId,
  groupId: groupId,
  eventId: operationId,
  payload: Uint8List.fromList(const [1, 2, 3]),
  recipientUserIds: const [_member],
  includeOwnDevices: includeOwnDevices,
);
