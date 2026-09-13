import 'dart:convert';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/pairwise_sync_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/development_in_memory_group_mls.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/storage_fault_injection.dart';

/// Crash and transaction-failure coverage for the inbound half of the
/// closed-beta group path.
///
/// `docs/sync-engine.md` ("Incoming durable envelopes") makes the receive one
/// transaction that records the envelope, applies the verified event, updates
/// projections and marks the envelope ready to acknowledge - and acknowledges
/// only after that transaction commits. `docs/local-data-model.md` nests the
/// MLS compare-and-swap inside it. So the pairwise ratchet step, the group
/// epoch, and the envelope's own state are one fact with three parts, and an
/// interruption may not separate them in either direction.
///
/// The direction that is easy to miss is the second one. The group commit runs
/// *before* the envelope is marked ready, so a failure in the pairwise leg
/// after the group leg has already written must still undo the epoch. A test
/// that only ever fails the group leg would never notice.
const _local = '10000000-0000-4000-8000-000000000001';
const _localDevice = '20000000-0000-4000-8000-000000000001';
const _localOtherDevice = '20000000-0000-4000-8000-000000000002';
const _peer = '30000000-0000-4000-8000-000000000001';
const _peerDevice = '40000000-0000-4000-8000-000000000001';
const _envelopeId = '50000000-0000-4000-8000-000000000001';
const _redelivered = '50000000-0000-4000-8000-000000000002';

void main() {
  late LocalDatabase database;
  late DriftGroupRepository groups;
  late DriftSyncStore sync;
  late StorageFaultInjector faults;
  late GroupState beta;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    groups = DriftGroupRepository(database);
    sync = DriftSyncStore(database);
    faults = StorageFaultInjector(database);
    await _insertUser(database, _local);
    await _insertUser(database, _peer);
    beta = await _createGroup(database, groups);
    await _present(sync, _envelopeId, 1);
  });

  tearDown(() => database.close());

  group('an inbound control never lands in pieces', () {
    test('a failed accepted fact rolls back the whole receive', () async {
      final commit = _incomingControl(beta);
      await faults.failOn('group_control_events', InjectedWrite.insert);

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(commit, _envelopeId),
      );

      expect(result, isA<FailureResult<bool>>());
      await _expectNothingApplied(database, beta);
    });

    test('a failed roster projection rolls back the whole receive', () async {
      final commit = _incomingControl(beta);
      await faults.failOn('memberships', InjectedWrite.insert);

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(commit, _envelopeId),
      );

      expect(result, isA<FailureResult<bool>>());
      await _expectNothingApplied(database, beta);
      // The roster is cleared and rewritten in the same transaction, so this
      // is the failure that could leave a group with no members at all.
      expect(await database.select(database.memberships).get(), hasLength(2));
    });

    test('a failed opaque-state write rolls back the whole receive', () async {
      final commit = _incomingControl(beta);
      await faults.failOn('mls_groups', InjectedWrite.update);

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(commit, _envelopeId),
      );

      expect(result, isA<FailureResult<bool>>());
      await _expectNothingApplied(database, beta);
    });

    // The reverse direction: the group leg already wrote, then the pairwise
    // leg failed on the last statement of the same transaction.
    test('a failed envelope marker rolls back the accepted epoch', () async {
      final commit = _incomingControl(beta);
      await faults.failOn('inbox_envelopes', InjectedWrite.update);

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(commit, _envelopeId),
      );

      expect(result, isA<FailureResult<bool>>());
      expect(await _revision(database, beta), beta.controlRevision);
      expect(await _epoch(database, beta), beta.acceptedEpoch);
      expect(
        await database.select(database.groupControlEvents).get(),
        hasLength(1),
      );
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
    });
  });

  group('an inbound application never lands in pieces', () {
    test('a failed message projection rolls back the ratchet', () async {
      await faults.failOn('messages', InjectedWrite.insert);

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(_incomingMessage(beta), _envelopeId),
      );

      expect(result, isA<FailureResult<bool>>());
      await _expectNothingApplied(database, beta);
      expect(await database.select(database.messageEvents).get(), isEmpty);
    });

    test('a failed immutable fact rolls back the ratchet', () async {
      await faults.failOn('message_events', InjectedWrite.insert);

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(_incomingMessage(beta), _envelopeId),
      );

      expect(result, isA<FailureResult<bool>>());
      await _expectNothingApplied(database, beta);
      expect(await database.select(database.messages).get(), isEmpty);
    });

    test('a failed envelope marker rolls back the message', () async {
      await faults.failOn('inbox_envelopes', InjectedWrite.update);

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(_incomingMessage(beta), _envelopeId),
      );

      expect(result, isA<FailureResult<bool>>());
      await _expectNothingApplied(database, beta);
    });
  });

  group('a fork outcome is as atomic as an accepted one', () {
    test('an unrecordable quarantine leaves the group live', () async {
      await faults.failOn('quarantine', InjectedWrite.insert);

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(_incomingFork(beta), _envelopeId),
      );

      expect(result, isA<FailureResult<bool>>());
      final row = await _groupRow(database, beta);
      expect(row.lifecycle, GroupLifecycle.active.index);
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      expect(
        (await database.select(database.inboxEnvelopes).getSingle())
            .processingState,
        InboxProcessingState.inspecting.index,
      );
    });

    test('a recorded quarantine and the receive commit together', () async {
      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(_incomingFork(beta), _envelopeId),
      );

      expect(result, isA<Success<bool>>());
      final row = await _groupRow(database, beta);
      expect(row.lifecycle, GroupLifecycle.forkQuarantined.index);
      expect(
        await database.select(database.quarantineRecords).get(),
        hasLength(1),
      );
      expect(
        await database.select(database.pairwiseSessions).get(),
        hasLength(1),
      );
    });
  });

  group('a crash between commit and acknowledgement is a safe duplicate', () {
    test('the redelivered envelope applies nothing a second time', () async {
      final commit = _incomingMessage(beta);
      final first = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(commit, _envelopeId),
      );
      expect((first as Success<bool>).value, isTrue);
      final appliedEpoch = await _epoch(database, beta);

      // The process died before the acknowledgement reached the relay, so the
      // relay sends the same envelope again under a new inbox id.
      await _present(sync, _redelivered, 2);
      final second = await sync.commitOpaqueInspection(
        envelopeId: _redelivered,
        inspection: _inspection(commit, _redelivered),
      );

      expect(second, isA<FailureResult<bool>>());
      expect(await database.select(database.messages).get(), hasLength(1));
      expect(await database.select(database.messageEvents).get(), hasLength(1));
      expect(await _epoch(database, beta), appliedEpoch);
      expect(
        (await database.select(database.pairwiseReplayMarkers).get()),
        hasLength(1),
      );
      // The first envelope is still waiting to be acknowledged, so the retry
      // that the crash interrupted still happens.
      expect(
        (await (database.select(
              database.inboxEnvelopes,
            )..where((row) => row.envelopeId.equals(_envelopeId))).getSingle())
            .processingState,
        InboxProcessingState.readyToAcknowledge.index,
      );
    });
  });

  group('an interrupted receive is resumable from durable state', () {
    test(
      'the envelope is re-offered after a restart and applies once',
      () async {
        final restartable = await RestartableDatabase.create('group-inbox-');
        addTearDown(restartable.dispose);
        var live = restartable.database;
        await _insertUser(live, _local);
        await _insertUser(live, _peer);
        final restartedGroups = DriftGroupRepository(live);
        final restarted = await _createGroup(live, restartedGroups);
        var store = DriftSyncStore(live);
        await _present(store, _envelopeId, 1);
        await StorageFaultInjector(
          live,
        ).failOn('group_control_events', InjectedWrite.insert);
        expect(
          await store.commitOpaqueInspection(
            envelopeId: _envelopeId,
            inspection: _inspection(_incomingControl(restarted), _envelopeId),
          ),
          isA<FailureResult<bool>>(),
        );

        live = await restartable.restart();
        store = DriftSyncStore(live);

        final offered = await store.beginNextEnvelopeInspection(
          now: DateTime.utc(2026, 8, 18, 12),
        );
        expect((offered as Success<SyncEnvelope?>).value?.id, _envelopeId);
        final applied = await store.commitOpaqueInspection(
          envelopeId: _envelopeId,
          inspection: _inspection(_incomingControl(restarted), _envelopeId),
        );

        expect((applied as Success<bool>).value, isTrue);
        expect(await _revision(live, restarted), restarted.controlRevision + 1);
        expect(await live.select(live.groupControlEvents).get(), hasLength(2));
      },
    );
  });

  group('a re-admission abandons the epoch it replaces', () {
    test('un-routed work for the dead epoch is discarded whole', () async {
      // The retained group still holds an object prepared at an epoch whose
      // secrets are gone. Keeping it would put a permanently unopenable object
      // on the wire; the ciphertext already handed to the pairwise outbox is a
      // different matter and must not be touched, because a recipient may
      // already hold it.
      await database
          .into(database.outboxOperations)
          .insert(
            OutboxOperationsCompanion.insert(
              operationId: 'already-fanned-out',
              eventId: 'dead-epoch-event',
              recipientDeviceId: _peerDevice,
              batchIndex: 0,
              exactRecipientCiphertext: Uint8List(1024),
              attemptState: OutboxAttemptState.queued.index,
            ),
          );
      expect(
        await database.select(database.groupOutboundObjects).get(),
        hasLength(1),
      );

      await (database.update(database.mlsGroups)
            ..where((row) => row.groupId.equals(beta.groupId)))
          .write(const MlsGroupsCompanion(queueGapRecoveryState: Value(1)));
      final blocked =
          (await groups.readGroup(beta.groupId) as Success<GroupState?>).value!;
      await _seedKeyPackageState(database);

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelopeId,
        inspection: _inspection(
          _readmission(blocked, beta.groupId),
          _envelopeId,
        ),
      );

      expect(result, isA<Success<bool>>());
      expect(
        await database.select(database.groupOutboundObjects).get(),
        isEmpty,
      );
      expect(
        await database.select(database.outboxOperations).get(),
        hasLength(1),
      );
    });
  });
}

Future<GroupState> _createGroup(
  LocalDatabase database,
  DriftGroupRepository repository,
) async {
  final created =
      await CreateGroup(
            repository: repository,
            crypto: DevelopmentInMemoryGroupMls.forTests(seed: 500),
            clock: const _Clock(),
            developmentPreviewOnly: false,
          )(
            currentUserId: _local,
            currentDeviceId: _localDevice,
            ownerDisplayName: 'Local',
            metadata: const GroupMetadata(name: 'Inbound beta'),
            selectedMembers: [
              GroupMember(
                userId: _peer,
                displayName: 'Peer',
                role: GroupRole.member,
                deviceIds: [_peerDevice],
              ),
            ],
          )
          as Success<GroupState>;
  return created.value;
}

/// A metadata edit this device's other device signed and fanned out to it.
PreparedGroupInboxTransition _incomingControl(GroupState current) {
  final signed = _signed(
    groupId: current.groupId,
    revision: current.controlRevision + 1,
    previousHash: current.controlStateHash,
    epoch: current.acceptedEpoch,
    operation: const UpdateGroupMetadataOperation(
      GroupMetadata(name: 'Renamed elsewhere'),
    ),
    controlHash: _repeat('b1', 32),
  );
  final applied =
      const GroupControlStateMachine().apply(
            previous: current,
            signedControl: signed,
            localUserId: _local,
          )
          as GroupControlAccepted;
  return PreparedGroupInboxTransition(
    expectedPrevious: current,
    next: applied.state,
    prepared: PreparedGroupTransition(
      signedControl: signed,
      newOpaqueMlsState: Uint8List.fromList([61]),
      mlsObject: _object,
      mutationId: 'inbound-${signed.event.eventId}',
      recipientUserIds: const [],
      outbound: false,
      controlTranscriptEntry: _transcriptEntry(signed),
    ),
  );
}

PreparedGroupInboxMessage _incomingMessage(GroupState current) =>
    PreparedGroupInboxMessage(
      expectedGroup: current,
      prepared: PreparedGroupMessage(
        groupId: current.groupId,
        messageId: 'c' * 32,
        senderUserId: _local,
        senderDeviceId: _localOtherDevice,
        text: 'inbound beta message',
        createdMs: 1_700_000_000_500,
        epoch: current.acceptedEpoch,
        newOpaqueMlsState: Uint8List.fromList([62]),
        mlsObject: _object,
        operationId: 'inbound-message',
        recipientUserIds: const [],
        outbound: false,
      ),
    );

PreparedGroupInboxForkResolution _incomingFork(GroupState current) =>
    PreparedGroupInboxForkResolution(
      resolution: GroupForkLocalBranchSuperseded(
        canonicalEventId: 'd' * 32,
        canonicalControlStateHash: '11',
        canonicalSignerUserId: _local,
      ),
      record: GroupQuarantineRecord(
        groupId: current.groupId,
        reason: GroupQuarantineReason.siblingCommit,
        opaqueDigest: Uint8List.fromList(List.filled(16, 0xdd)),
        receivedAt: DateTime.utc(2026, 8, 18, 11),
      ),
      siblingEventId: 'd' * 32,
      siblingSignerUserId: _local,
      siblingSignerDeviceId: _localOtherDevice,
    );

/// A peers-removed-then-added Welcome carrying its own complete transcript.
PreparedGroupInboxRejoin _readmission(GroupState superseded, String groupId) {
  final create = _signed(
    groupId: groupId,
    revision: 1,
    previousHash: null,
    epoch: 1,
    operation: CreateGroupOperation(
      metadata: GroupMetadata(name: 'Inbound beta'),
      invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
      historySharingPolicy: GroupHistorySharingPolicy.reshareAvailable,
      initialMembers: [
        GroupMember(
          userId: _peer,
          displayName: 'Peer',
          role: GroupRole.owner,
          deviceIds: [_peerDevice],
        ),
        GroupMember(
          userId: _local,
          displayName: 'Local',
          role: GroupRole.member,
          deviceIds: [_localDevice],
        ),
      ],
    ),
    controlHash: _repeat('c1', 32),
    signerUserId: _peer,
    signerDeviceId: _peerDevice,
  );
  final remove = _signed(
    groupId: groupId,
    revision: superseded.controlRevision + 1,
    previousHash: create.controlStateHash,
    epoch: superseded.acceptedEpoch + 1,
    operation: const RemoveGroupMemberOperation(_local),
    controlHash: _repeat('c2', 32),
    signerUserId: _peer,
    signerDeviceId: _peerDevice,
  );
  final readd = _signed(
    groupId: groupId,
    revision: superseded.controlRevision + 2,
    previousHash: remove.controlStateHash,
    epoch: superseded.acceptedEpoch + 2,
    operation: InviteGroupMembersOperation([
      GroupMember(
        userId: _local,
        displayName: 'Local',
        role: GroupRole.member,
        verified: true,
        deviceIds: [_localDevice],
      ),
    ]),
    controlHash: _repeat('c3', 32),
    signerUserId: _peer,
    signerDeviceId: _peerDevice,
  );
  var reconstructed =
      const GroupControlStateMachine().apply(
            previous: null,
            signedControl: create,
            localUserId: _local,
          )
          as GroupControlAccepted;
  for (final entry in [remove, readd]) {
    reconstructed =
        const GroupControlStateMachine().apply(
              previous: reconstructed.state,
              signedControl: entry,
              localUserId: _local,
            )
            as GroupControlAccepted;
  }
  return PreparedGroupInboxRejoin(
    supersededLocal: superseded,
    next: reconstructed.state,
    prepared: PreparedGroupTransition(
      signedControl: readd,
      newOpaqueMlsState: Uint8List.fromList([63]),
      mlsObject: _object,
      mutationId: 'rejoin-${readd.event.eventId}',
      recipientUserIds: const [],
      outbound: false,
      consumedKeyPackageState: ConsumedGroupKeyPackageState(
        deviceId: _localDevice,
        expectedStateRevision: 1,
        nextSealedState: Uint8List.fromList([79]),
      ),
      controlTranscriptEntry: _transcriptEntry(readd),
      precedingControlTranscript: [
        _transcriptEntry(create),
        _transcriptEntry(remove),
      ],
    ),
  );
}

SignedGroupControlEvent _signed({
  required String groupId,
  required int revision,
  required String? previousHash,
  required int epoch,
  required GroupControlOperation operation,
  required String controlHash,
  String signerUserId = _local,
  String signerDeviceId = _localOtherDevice,
}) {
  final event = GroupControlEvent(
    eventId: 'e${revision.toRadixString(16).padLeft(31, '0')}',
    groupId: groupId,
    revision: revision,
    previousControlStateHash: previousHash,
    mlsEpoch: epoch,
    mlsCommitHash: operation.changesMembership ? _repeat('66', 32) : null,
    signerUserId: signerUserId,
    signerDeviceId: signerDeviceId,
    createdMs: 1_700_000_000_000 + revision,
    operation: operation,
  );
  return SignedGroupControlEvent(
    event: event,
    controlStateHash: controlHash,
    canonicalBytes: Uint8List.fromList(
      utf8.encode(event.deterministicProjection),
    ),
    signature: Uint8List.fromList(List.filled(64, 5)),
  );
}

GroupControlTranscriptEntry _transcriptEntry(SignedGroupControlEvent signed) =>
    GroupControlTranscriptEntry(
      signedControl: signed,
      signedPayload: Uint8List.fromList('CPGCV001'.codeUnits),
      signerAuthenticationProof: Uint8List.fromList('CPBRV001'.codeUnits),
    );

final Uint8List _object = Uint8List.fromList('CPGTO001'.codeUnits);

String _repeat(String pair, int count) => List.filled(count, pair).join();

OpaqueEnvelopeInspection _inspection(
  PreparedGroupInboxCommit groupCommit,
  String envelopeId,
) => OpaqueEnvelopeInspection(
  opaqueEventId: groupCommit.opaqueEventId,
  dependency: EnvelopeDependency.potentiallyMls,
  groupCommit: groupCommit,
  pairwiseCommit: PairwiseSyncReceiveCommit(
    envelopeId: envelopeId,
    opaqueEventId: groupCommit.opaqueEventId,
    senderUserId: groupCommit.senderUserId,
    senderDeviceId: groupCommit.senderDeviceId,
    replayMarker: Uint8List(32),
    openedOpaquePayload: _object,
    sessionTransition: PairwiseSyncSessionTransition(
      localDeviceId: _localDevice,
      remoteUserId: groupCommit.senderUserId,
      remoteDeviceId: groupCommit.senderDeviceId,
      sessionId: Uint8List(16),
      nextOpaqueState: Uint8List.fromList([81]),
      expectedStateVersion: null,
      nextStateVersion: 1,
      nextSkippedKeyCount: 0,
      disposition: PairwiseSessionDisposition.primaryBidirectional.index,
      repairState: PairwiseRepairState.ready.index,
    ),
  ),
);

Future<void> _present(DriftSyncStore sync, String id, int sequence) async {
  await sync.persistDrainPage(
    DrainPage(
      envelopes: [
        SyncEnvelope(
          id: id,
          sequence: sequence,
          exactCiphertext: Uint8List(1024),
        ),
      ],
      hasMore: false,
      prunedThrough: 0,
    ),
  );
  await sync.beginNextEnvelopeInspection(now: DateTime.utc(2026, 8, 18, 11));
}

Future<MlsGroup> _groupRow(LocalDatabase database, GroupState group) =>
    (database.select(
      database.mlsGroups,
    )..where((row) => row.groupId.equals(group.groupId))).getSingle();

Future<int> _revision(LocalDatabase database, GroupState group) async =>
    (await _groupRow(database, group)).controlRevision;

Future<int> _epoch(LocalDatabase database, GroupState group) async =>
    (await _groupRow(database, group)).acceptedEpoch;

/// Nothing of the receive survived: not the group leg, not the pairwise leg,
/// and not the envelope's progress, so the next run starts it over cleanly.
Future<void> _expectNothingApplied(
  LocalDatabase database,
  GroupState group,
) async {
  final row = await _groupRow(database, group);
  expect(row.controlRevision, group.controlRevision);
  expect(row.acceptedEpoch, group.acceptedEpoch);
  expect(row.stateVersion, 1);
  expect(await database.select(database.pairwiseSessions).get(), isEmpty);
  expect(await database.select(database.pairwiseReplayMarkers).get(), isEmpty);
  expect(await database.select(database.pairwiseOpenedPayloads).get(), isEmpty);
  expect(
    (await (database.select(
          database.inboxEnvelopes,
        )..where((item) => item.envelopeId.equals(_envelopeId))).getSingle())
        .processingState,
    InboxProcessingState.inspecting.index,
  );
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

Future<void> _seedKeyPackageState(LocalDatabase database) async {
  await database
      .into(database.devices)
      .insert(
        DevicesCompanion.insert(
          deviceId: _localDevice,
          userId: _local,
          publicBundle: Uint8List.fromList([1]),
          revocationState: 0,
          isCurrentDevice: const Value(true),
        ),
      );
  await database
      .into(database.secureSecrets)
      .insert(
        SecureSecretsCompanion.insert(
          secretId: 'beta-pq-mls-key-packages-v1',
          kind: 2,
          wrappedCiphertextOrOpaqueHandle: Uint8List.fromList([50]),
          formatVersion: 1,
        ),
      );
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 8, 18, 10);
}
