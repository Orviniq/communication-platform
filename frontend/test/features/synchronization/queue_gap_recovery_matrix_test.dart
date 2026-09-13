import 'dart:convert';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/device_control_crypto_port.dart';
import 'package:communication_platform/core/application/ports/pairwise_session_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart'
    as native;
import 'package:communication_platform/core/protocol/pairwise_sync_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_mls_inbound_coordinator.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/development_in_memory_group_mls.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:communication_platform/features/synchronization/infrastructure/pairwise_opaque_envelope_inspector.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The device half of the queue-gap removal/re-add recovery matrix.
///
/// `backend/messaging/API.md` prunes undelivered envelopes after
/// `ENVELOPE_TTL_DAYS` (default 7) and reports `pruned_through`, the highest
/// sequence ever deleted from this mailbox. `CLIENT_CONTRACT.md` §H makes the
/// consequence explicit: when the last acked sequence is below it, envelopes
/// were lost, they may have been MLS Commits, the device cannot self-recover,
/// and it must be removed and added back for a fresh Welcome.
///
/// These tests walk that path from detection to a cleared baseline, and pin the
/// states in between so none of them can quietly become optimistic. The peer
/// side of the same matrix lives in
/// `test/features/groups/domain/group_readmission_test.dart`.
const _localUser = '10000000-0000-4000-8000-000000000001';
const _localDevice = '20000000-0000-4000-8000-000000000001';
const _peer = '30000000-0000-4000-8000-000000000001';
const _peerDevice = '40000000-0000-4000-8000-000000000001';
const _keyPackageSecretId = 'beta-pq-mls-key-packages-v1';

void main() {
  late LocalDatabase database;
  late DriftGroupRepository groups;
  late DriftSyncStore sync;
  late _ScriptedGroupMls crypto;
  late GroupMlsInboundCoordinator coordinator;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    groups = DriftGroupRepository(database);
    sync = DriftSyncStore(database);
    crypto = _ScriptedGroupMls();
    coordinator = GroupMlsInboundCoordinator(
      repository: groups,
      crypto: crypto,
      localUserId: _localUser,
      localDeviceId: _localDevice,
      clock: _now,
    );
    await _insertUser(database, _localUser);
    await _insertUser(database, _peer);
    await _insertLocalDevice(database);
  });

  tearDown(() => database.close());

  group('detection', () {
    test('a gap flags every group this device can still follow', () async {
      final live = await _createGroup(database, groups, seed: 300);
      final abandoned = await _createGroup(database, groups, seed: 310);
      await _forceLifecycle(database, abandoned.groupId, GroupLifecycle.left);

      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);

      expect(await _recoveryFlag(database, live.groupId), 1);
      // A group this device already left can never produce a re-admission.
      // Flagging it would make the obligation impossible to discharge and
      // leave the device blocked forever.
      expect(await _recoveryFlag(database, abandoned.groupId), 0);
    });

    test('an already-collected pruned_through is not a gap', () async {
      final group = await _createGroup(database, groups, seed: 320);
      await _drainWithGap(sync, prunedThrough: 4, sequence: 5);
      await sync.markGroupRecovered(group.groupId);

      await sync.persistDrainPage(
        DrainPage(
          envelopes: [_envelope('50000000-0000-4000-8000-000000000009', 9)],
          hasMore: false,
          prunedThrough: 4,
        ),
      );

      final projection = await sync.readProjection() as Success<SyncProjection>;
      expect(projection.value.queueGapState, QueueGapState.clear);
      expect(await _recoveryFlag(database, group.groupId), 0);
    });

    test('a later, larger prune re-arms a cleared gap', () async {
      final group = await _createGroup(database, groups, seed: 330);
      await _drainWithGap(sync, prunedThrough: 4, sequence: 5);
      await sync.markGroupRecovered(group.groupId);
      expect(await _gapState(sync), QueueGapState.clear);

      await sync.persistDrainPage(
        DrainPage(
          envelopes: [_envelope('50000000-0000-4000-8000-00000000000a', 40)],
          hasMore: false,
          prunedThrough: 30,
        ),
      );

      expect(await _gapState(sync), QueueGapState.recoveryRequired);
      expect(await _recoveryFlag(database, group.groupId), 1);
    });
  });

  group('the blocked state is honest', () {
    late GroupState group;

    setUp(() async {
      group = await _createGroup(database, groups, seed: 340);
      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);
    });

    test(
      'the group reads as rejoin-required without touching MLS state',
      () async {
        final before = await groups.readOpaqueMlsState(group.groupId);

        final projected =
            await groups.readGroup(group.groupId) as Success<GroupState?>;

        expect(
          projected.value!.lifecycle,
          GroupLifecycle.queueGapRejoinRequired,
        );
        expect(
          (await groups.readOpaqueMlsState(group.groupId)
                  as Success<Uint8List?>)
              .value,
          orderedEquals((before as Success<Uint8List?>).value!),
        );
      },
    );

    test('outbound group messages are refused', () async {
      final result =
          await SendGroupMessage(
            repository: groups,
            crypto: crypto,
            clock: const _Clock(),
            developmentPreviewOnly: false,
          )(
            groupId: group.groupId,
            senderUserId: _localUser,
            senderDeviceId: _localDevice,
            text: 'this must not reach an epoch we no longer hold',
          );

      expect(result, isA<FailureResult<GroupMessage>>());
      expect(
        (result as FailureResult<GroupMessage>).failure,
        isA<SecurityFailure>(),
      );
      expect(await database.select(database.messages).get(), isEmpty);
    });

    test('outbound membership controls are refused', () async {
      final result =
          await MutateGroup(
            repository: groups,
            crypto: crypto,
            clock: const _Clock(),
            developmentPreviewOnly: false,
          )(
            groupId: group.groupId,
            actorUserId: _localUser,
            actorDeviceId: _localDevice,
            operation: const RemoveGroupMemberOperation(_peer),
          );

      expect(
        (result as FailureResult<GroupState>).failure,
        isA<SecurityFailure>(),
      );
      expect(crypto.prepareControlCalls, isZero);
    });

    test('inbound control and application objects are refused', () async {
      final control = await coordinator.inspect(_object(_ScriptKind.control));
      final application = await coordinator.inspect(
        _object(_ScriptKind.application),
      );

      expect(control, isA<FailureResult<PreparedGroupInboxCommit>>());
      expect(application, isA<FailureResult<PreparedGroupInboxCommit>>());
      // The desynced group never reaches the crypto core at all.
      expect(crypto.inspectControlCalls, isZero);
      expect(crypto.inspectApplicationCalls, isZero);
    });

    test(
      'storage refuses a control that tries to extend the gapped group',
      () async {
        final extension = await _preparedExtension(group);

        final result = await groups.commitTransition(
          expectedPrevious: group,
          next: extension.$2,
          prepared: extension.$1,
          developmentPreviewOnly: false,
        );

        expect(
          (result as FailureResult<void>).failure,
          isA<ValidationFailure>(),
        );
        expect(
          await _revisionOf(database, group.groupId),
          group.controlRevision,
        );
      },
    );
  });

  group('cryptographic re-admission', () {
    late GroupState stale;

    setUp(() async {
      stale = await _createGroup(database, groups, seed: 350);
      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);
      await _seedKeyPackageState(database);
    });

    test('a fresh Welcome supersedes the gapped group', () async {
      crypto.welcome = _readmission(stale.groupId);

      final inspected = await coordinator.inspect(_object(_ScriptKind.welcome));

      final commit =
          (inspected as Success<PreparedGroupInboxCommit>).value
              as PreparedGroupInboxRejoin;
      expect(commit.supersededLocal.controlRevision, stale.controlRevision);
      expect(commit.next.lifecycle, GroupLifecycle.active);
      expect(commit.next.controlRevision, greaterThan(stale.controlRevision));
      expect(commit.next.acceptedEpoch, greaterThan(stale.acceptedEpoch));
      expect(commit.prepared.consumedKeyPackageState, isNotNull);
    });

    test(
      'the re-admission is what unblocks the queue, not the gap itself',
      () async {
        crypto.welcome = _readmission(stale.groupId);

        final rejoin = await coordinator.inspectQueueGapRejoin(
          _object(_ScriptKind.welcome),
        );

        expect(
          (rejoin as Success<PreparedGroupInboxCommit?>).value,
          isA<PreparedGroupInboxRejoin>(),
        );
      },
    );

    test('a Welcome for a live group is refused', () async {
      await sync.markGroupRecovered(stale.groupId);
      crypto.welcome = _readmission(stale.groupId);

      final inspected = await coordinator.inspect(_object(_ScriptKind.welcome));
      final rejoin = await coordinator.inspectQueueGapRejoin(
        _object(_ScriptKind.welcome),
      );

      expect(inspected, isA<FailureResult<PreparedGroupInboxCommit>>());
      expect((rejoin as Success<PreparedGroupInboxCommit?>).value, isNull);
    });

    test(
      'a re-admission that does not move the group forward is refused',
      () async {
        // Push the retained group past the revision the re-admission lands on,
        // so an internally well-formed Welcome is nonetheless a replay of an
        // admission this device has already moved beyond. Accepting it would
        // roll the roster and epoch back to state the gap already invalidated.
        await sync.markGroupRecovered(stale.groupId);
        var current = stale;
        for (var index = 0; index < 3; index += 1) {
          final extension = await _preparedExtension(current);
          expect(
            await groups.commitTransition(
              expectedPrevious: current,
              next: extension.$2,
              prepared: extension.$1,
              developmentPreviewOnly: false,
            ),
            isA<Success<void>>(),
          );
          current = extension.$2;
        }
        expect(current.controlRevision, greaterThan(3));
        await _drainWithGap(sync, prunedThrough: 30, sequence: 31);
        crypto.welcome = _readmission(stale.groupId);

        final inspected = await coordinator.inspect(
          _object(_ScriptKind.welcome),
        );

        expect(inspected, isA<FailureResult<PreparedGroupInboxCommit>>());
        expect(
          (await coordinator.inspectQueueGapRejoin(_object(_ScriptKind.welcome))
                  as Success<PreparedGroupInboxCommit?>)
              .value,
          isNull,
        );
        expect(
          await _revisionOf(database, stale.groupId),
          current.controlRevision,
        );
      },
    );

    test('a Welcome that does not admit this device is refused', () async {
      crypto.welcome = _readmission(stale.groupId, admitLocalDevice: false);

      final inspected = await coordinator.inspect(_object(_ScriptKind.welcome));

      expect(inspected, isA<FailureResult<PreparedGroupInboxCommit>>());
    });

    test('a Welcome with no consumed KeyPackage is refused', () async {
      crypto.welcome = _readmission(stale.groupId, consumeKeyPackage: false);

      final inspected = await coordinator.inspect(_object(_ScriptKind.welcome));

      expect(inspected, isA<FailureResult<PreparedGroupInboxCommit>>());
    });

    test('a rejected Welcome leaves the obligation standing', () async {
      crypto.welcomeFails = true;

      final rejoin = await coordinator.inspectQueueGapRejoin(
        _object(_ScriptKind.welcome),
      );

      expect((rejoin as Success<PreparedGroupInboxCommit?>).value, isNull);
      expect(await _recoveryFlag(database, stale.groupId), 1);
      expect(await _gapState(sync), QueueGapState.recoveryRequired);
    });

    test('objects that are not join-capable stay deferred', () async {
      for (final kind in [_ScriptKind.control, _ScriptKind.application]) {
        final rejoin = await coordinator.inspectQueueGapRejoin(_object(kind));
        expect((rejoin as Success<PreparedGroupInboxCommit?>).value, isNull);
      }
      // A join-capable object for a group this device does not follow is not
      // part of this recovery either.
      crypto.probeGroupId = _otherGroupId;
      final unknown = await coordinator.inspectQueueGapRejoin(
        _object(_ScriptKind.welcome),
      );
      expect((unknown as Success<PreparedGroupInboxCommit?>).value, isNull);
    });
  });

  group('the recovery transaction', () {
    late GroupState stale;

    setUp(() async {
      stale = await _createGroup(database, groups, seed: 360);
      await _seedKeyPackageState(database);
      await _seedMessage(database, stale.groupId);
      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);
      await _retainAndPresentRejoin(sync, database);
      crypto.welcome = _readmission(stale.groupId);
    });

    test(
      'a re-admission clears the gap, baseline, and retained queue',
      () async {
        final commit = await _prepareRejoin(coordinator);

        final result = await sync.commitOpaqueInspection(
          envelopeId: _rejoinEnvelope,
          inspection: _inspection(commit),
        );

        expect(result, isA<Success<bool>>());
        final projection =
            await sync.readProjection() as Success<SyncProjection>;
        expect(projection.value.queueGapState, QueueGapState.clear);
        // The acknowledged loss baseline moves through the observed
        // pruned_through, so the same permanent gap cannot reopen every drain.
        expect(projection.value.highestContiguousAcknowledgedSequence, 7);
        expect(
          (await database.select(database.syncCheckpoints).getSingle())
              .drainRequested,
          isTrue,
        );
        final released = await (database.select(
          database.inboxEnvelopes,
        )..where((row) => row.envelopeId.equals(_blockedEnvelope))).getSingle();
        expect(released.processingState, InboxProcessingState.received.index);
        // The pairwise half of the same transaction landed too, so the
        // envelope that carried the re-admission is acknowledgeable.
        final carrier = await (database.select(
          database.inboxEnvelopes,
        )..where((row) => row.envelopeId.equals(_rejoinEnvelope))).getSingle();
        expect(
          carrier.processingState,
          InboxProcessingState.readyToAcknowledge.index,
        );
        expect(
          await database.select(database.pairwiseSessions).get(),
          hasLength(1),
        );
      },
    );

    test(
      'the rejoined group is live, re-rostered, and re-transcripted',
      () async {
        await sync.commitOpaqueInspection(
          envelopeId: _rejoinEnvelope,
          inspection: _inspection(await _prepareRejoin(coordinator)),
        );

        final rejoined =
            await groups.readGroup(stale.groupId) as Success<GroupState?>;
        expect(rejoined.value!.lifecycle, GroupLifecycle.active);
        expect(rejoined.value!.controlRevision, 3);
        expect(rejoined.value!.acceptedEpoch, 3);
        expect(await _recoveryFlag(database, stale.groupId), 0);
        final transcript =
            await groups.readVerifiedTranscript(stale.groupId)
                as Success<List<GroupControlTranscriptEntry>>;
        // The stale single-entry transcript is replaced by the authenticated
        // one the Welcome carried, not merged with it.
        expect(
          transcript.value.map((entry) => entry.signedControl.event.revision),
          [1, 2, 3],
        );
        expect(
          (await groups.readOpaqueMlsState(stale.groupId)
                  as Success<Uint8List?>)
              .value,
          isNot(orderedEquals(_staleOpaqueState)),
        );
      },
    );

    test('the KeyPackage is consumed exactly once', () async {
      await sync.commitOpaqueInspection(
        envelopeId: _rejoinEnvelope,
        inspection: _inspection(await _prepareRejoin(coordinator)),
      );

      final secret = await (database.select(
        database.secureSecrets,
      )..where((row) => row.secretId.equals(_keyPackageSecretId))).getSingle();
      expect(secret.stateRevision, 2);
      expect(secret.wrappedCiphertextOrOpaqueHandle, [77]);
    });

    test('locally held history survives the rejoin', () async {
      await sync.commitOpaqueInspection(
        envelopeId: _rejoinEnvelope,
        inspection: _inspection(await _prepareRejoin(coordinator)),
      );

      // Already decrypted and durable, and no future epoch depends on it.
      expect(await database.select(database.messages).get(), hasLength(1));
    });

    test(
      'a concurrent change to the retained group aborts the rejoin',
      () async {
        final commit = await _prepareRejoin(coordinator);
        await sync.markGroupRecovered(stale.groupId);
        await groups.commitTransition(
          expectedPrevious: stale,
          next: (await _preparedExtension(stale)).$2,
          prepared: (await _preparedExtension(stale)).$1,
          developmentPreviewOnly: false,
        );
        await _drainWithGap(sync, prunedThrough: 9, sequence: 10);

        final result = await sync.commitOpaqueInspection(
          envelopeId: _rejoinEnvelope,
          inspection: _inspection(commit),
        );

        expect(result, isA<FailureResult<bool>>());
        expect(await _gapState(sync), QueueGapState.recoveryRequired);
        expect(await _recoveryFlag(database, stale.groupId), 1);
        // The group kept the revision the concurrent control gave it, so the
        // stale re-admission neither replaced nor half-replaced it.
        expect(
          await _revisionOf(database, stale.groupId),
          stale.controlRevision + 1,
        );
        expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      },
    );

    test('a failed rejoin rolls back the pairwise receive with it', () async {
      final commit = await _prepareRejoin(coordinator);
      await (database.delete(
        database.secureSecrets,
      )..where((row) => row.secretId.equals(_keyPackageSecretId))).go();

      final result = await sync.commitOpaqueInspection(
        envelopeId: _rejoinEnvelope,
        inspection: _inspection(commit),
      );

      expect(result, isA<FailureResult<bool>>());
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      expect(
        await database.select(database.pairwiseReplayMarkers).get(),
        isEmpty,
      );
      expect(await _gapState(sync), QueueGapState.recoveryRequired);
      expect(await _revisionOf(database, stale.groupId), stale.controlRevision);
    });
  });

  group('multiple affected groups', () {
    test('one recovery does not release the device', () async {
      final first = await _createGroup(database, groups, seed: 370);
      final second = await _createGroup(database, groups, seed: 380);
      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);
      await _blockEnvelope(sync, database);

      await sync.markGroupRecovered(first.groupId);

      expect(await _gapState(sync), QueueGapState.recoveryRequired);
      expect(await _recoveryFlag(database, second.groupId), 1);
      expect(
        (await (database.select(database.inboxEnvelopes)
                  ..where((row) => row.envelopeId.equals(_blockedEnvelope)))
                .getSingle())
            .processingState,
        InboxProcessingState.blockedByQueueGap.index,
      );
      expect(
        (await sync.readProjection() as Success<SyncProjection>)
            .value
            .highestContiguousAcknowledgedSequence,
        0,
      );

      await sync.markGroupRecovered(second.groupId);

      expect(await _gapState(sync), QueueGapState.clear);
    });
  });

  group('explicit abandonment', () {
    test('abandoning the last affected group retires the gap', () async {
      final group = await _createGroup(database, groups, seed: 390);
      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);

      final result = await sync.markGroupLeft(group.groupId);

      expect(result, isA<Success<void>>());
      expect(await database.select(database.mlsGroups).get(), isEmpty);
      expect(await _gapState(sync), QueueGapState.clear);
      expect(
        (await sync.readProjection() as Success<SyncProjection>)
            .value
            .highestContiguousAcknowledgedSequence,
        7,
      );
    });

    test('a live group is never abandoned through the recovery path', () async {
      final gapped = await _createGroup(database, groups, seed: 400);
      final live = await _createGroup(database, groups, seed: 410);
      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);
      await sync.markGroupRecovered(live.groupId);

      final result = await sync.markGroupLeft(live.groupId);

      expect((result as FailureResult<void>).failure, isA<ValidationFailure>());
      expect(await database.select(database.mlsGroups).get(), hasLength(2));
      expect(await _recoveryFlag(database, gapped.groupId), 1);
    });

    test('there is nothing to abandon without a gap', () async {
      final group = await _createGroup(database, groups, seed: 420);

      final result = await sync.markGroupLeft(group.groupId);

      expect((result as FailureResult<void>).failure, isA<ValidationFailure>());
      expect(await database.select(database.mlsGroups).get(), hasLength(1));
    });
  });

  group('resumability', () {
    test('an interrupted recovery resumes from durable state alone', () async {
      final group = await _createGroup(database, groups, seed: 430);
      await _seedKeyPackageState(database);
      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);
      await _retainAndPresentRejoin(sync, database);
      crypto.welcome = _readmission(group.groupId);

      // Nothing of the recovery lives in memory: drop every collaborator and
      // rebuild them over the same database, as a process restart would.
      final restartedGroups = DriftGroupRepository(database);
      final restartedSync = DriftSyncStore(database);
      final restartedCoordinator = GroupMlsInboundCoordinator(
        repository: restartedGroups,
        crypto: crypto,
        localUserId: _localUser,
        localDeviceId: _localDevice,
        clock: _now,
      );

      expect(await _gapState(restartedSync), QueueGapState.recoveryRequired);
      expect(await _recoveryFlag(database, group.groupId), 1);
      expect(
        (await restartedGroups.readGroup(group.groupId) as Success<GroupState?>)
            .value!
            .lifecycle,
        GroupLifecycle.queueGapRejoinRequired,
      );

      final commit = await _prepareRejoin(restartedCoordinator);
      final result = await restartedSync.commitOpaqueInspection(
        envelopeId: _rejoinEnvelope,
        inspection: _inspection(commit),
      );

      expect(result, isA<Success<bool>>());
      expect(await _gapState(restartedSync), QueueGapState.clear);
    });

    test('a recovered gap does not reopen on a later drain', () async {
      final group = await _createGroup(database, groups, seed: 440);
      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);
      await sync.markGroupRecovered(group.groupId);

      for (var sequence = 9; sequence < 12; sequence += 1) {
        await sync.persistDrainPage(
          DrainPage(
            envelopes: [
              _envelope(
                '50000000-0000-4000-8000-0000000000${sequence.toRadixString(16).padLeft(2, '0')}',
                sequence,
              ),
            ],
            hasMore: false,
            prunedThrough: 7,
          ),
        );
        expect(await _gapState(sync), QueueGapState.clear);
        expect(await _recoveryFlag(database, group.groupId), 0);
      }
    });
  });

  group('the blocked inbox admits only a re-admission', () {
    late GroupState group;
    late PairwiseOpaqueEnvelopeInspector inspector;

    setUp(() async {
      group = await _createGroup(database, groups, seed: 450);
      await _seedKeyPackageState(database);
      await _seedPairwiseSession(database);
      await _drainWithGap(sync, prunedThrough: 7, sequence: 8);
      inspector = PairwiseOpaqueEnvelopeInspector(
        localDeviceId: _localDevice,
        store: DriftPairwiseTransportStore(database),
        liveDevices: _Unused(),
        crypto: _StubPairwiseCrypto(),
        applicationProtocol: _Unused(),
        deviceControlCrypto: _Unused(),
        conversationResolver: _Unused(),
        currentUserId: _localUser,
        clock: const _Clock(),
        groupInbound: coordinator,
      );
    });

    test('a re-admission is inspected while the gap holds', () async {
      crypto.welcome = _readmission(group.groupId);

      final inspected = await inspector.inspect(
        envelopeId: _rejoinEnvelope,
        exactCiphertext: Uint8List(1024),
        allowPotentiallyMls: false,
      );

      final value = (inspected as Success<OpaqueEnvelopeInspection>).value;
      expect(value.groupCommit, isA<PreparedGroupInboxRejoin>());
      expect(value.dependency, EnvelopeDependency.potentiallyMls);
    });

    test('everything else is deferred, not decided', () async {
      crypto.probeKind = _ScriptKind.control;

      final inspected = await inspector.inspect(
        envelopeId: _rejoinEnvelope,
        exactCiphertext: Uint8List(1024),
        allowPotentiallyMls: false,
      );

      final value = (inspected as Success<OpaqueEnvelopeInspection>).value;
      expect(value.groupCommit, isNull);
      expect(value.opaqueEventId, 'group-deferred:$_rejoinEnvelope');
      expect(value.dependency, EnvelopeDependency.potentiallyMls);
    });

    test(
      'a relay cannot reattribute a re-admission to another session',
      () async {
        crypto.welcome = _readmission(
          group.groupId,
          signerDeviceId: _otherDevice,
        );

        final inspected = await inspector.inspect(
          envelopeId: _rejoinEnvelope,
          exactCiphertext: Uint8List(1024),
          allowPotentiallyMls: false,
        );

        expect(
          (inspected as FailureResult<OpaqueEnvelopeInspection>).failure,
          isA<SecurityFailure>(),
        );
      },
    );
  });
}

// --- fixtures ---------------------------------------------------------------

const _groupIdSeed = 'bbbbbbbb';
const _otherGroupId =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _otherDevice = '40000000-0000-4000-8000-00000000000f';
const _rejoinEnvelope = '50000000-0000-4000-8000-000000000001';
const _blockedEnvelope = '50000000-0000-4000-8000-000000000002';
final _staleOpaqueState = Uint8List.fromList(utf8.encode('stale'));

DateTime _now() => DateTime.utc(2026, 8, 18, 12);

enum _ScriptKind { welcome, control, application }

Future<GroupState> _createGroup(
  LocalDatabase database,
  DriftGroupRepository repository, {
  required int seed,
}) async {
  final created =
      await CreateGroup(
            repository: repository,
            crypto: DevelopmentInMemoryGroupMls.forTests(seed: seed),
            clock: const _Clock(),
            developmentPreviewOnly: true,
          )(
            currentUserId: _localUser,
            currentDeviceId: _localDevice,
            ownerDisplayName: 'Local',
            metadata: GroupMetadata(name: 'Team $seed'),
            selectedMembers: [
              GroupMember(
                userId: _peer,
                displayName: 'Peer',
                role: GroupRole.member,
                deviceIds: const [_peerDevice],
              ),
            ],
          )
          as Success<GroupState>;
  await database.delete(database.groupOutboundObjects).go();
  return created.value;
}

Future<void> _drainWithGap(
  DriftSyncStore sync, {
  required int prunedThrough,
  required int sequence,
}) => sync.persistDrainPage(
  DrainPage(
    envelopes: [
      _envelope(
        '50000000-0000-4000-8000-0000000000${sequence.toRadixString(16).padLeft(2, '0')}',
        sequence,
      ),
    ],
    hasMore: false,
    prunedThrough: prunedThrough,
  ),
);

SyncEnvelope _envelope(String id, int sequence) =>
    SyncEnvelope(id: id, sequence: sequence, exactCiphertext: Uint8List(1024));

/// Persists an envelope already retained because it might depend on lost MLS
/// state, so the release side of the recovery has something to release.
Future<void> _blockEnvelope(DriftSyncStore sync, LocalDatabase database) async {
  await sync.persistDrainPage(
    DrainPage(
      envelopes: [_envelope(_blockedEnvelope, 20)],
      hasMore: false,
      prunedThrough: 7,
    ),
  );
  await sync.blockEnvelopeForQueueGap(_blockedEnvelope);
}

/// Retains everything already drained the way the gap does, then presents the
/// re-admission envelope for inspection, as a real drain pass would.
Future<void> _retainAndPresentRejoin(
  DriftSyncStore sync,
  LocalDatabase database,
) async {
  await _blockEnvelope(sync, database);
  for (final row in await database.select(database.inboxEnvelopes).get()) {
    await sync.blockEnvelopeForQueueGap(row.envelopeId);
  }
  await sync.persistDrainPage(
    DrainPage(
      envelopes: [_envelope(_rejoinEnvelope, 21)],
      hasMore: false,
      prunedThrough: 7,
    ),
  );
  await sync.beginNextEnvelopeInspection(now: _now());
}

Future<QueueGapState> _gapState(DriftSyncStore sync) async =>
    (await sync.readProjection() as Success<SyncProjection>)
        .value
        .queueGapState;

Future<int> _recoveryFlag(LocalDatabase database, String groupId) async =>
    (await (database.select(
          database.mlsGroups,
        )..where((row) => row.groupId.equals(groupId))).getSingle())
        .queueGapRecoveryState;

Future<int> _revisionOf(
  LocalDatabase database,
  String groupId,
) async => (await (database.select(
  database.mlsGroups,
)..where((row) => row.groupId.equals(groupId))).getSingle()).controlRevision;

Future<void> _forceLifecycle(
  LocalDatabase database,
  String groupId,
  GroupLifecycle lifecycle,
) =>
    (database.update(database.mlsGroups)
          ..where((row) => row.groupId.equals(groupId)))
        .write(MlsGroupsCompanion(lifecycle: Value(lifecycle.index)));

/// A well-formed ordinary control extension of [previous], used to prove that
/// even a valid one cannot land on a queue-gapped group.
Future<(PreparedGroupTransition, GroupState)> _preparedExtension(
  GroupState previous,
) async {
  final signed = _signed(
    groupId: previous.groupId,
    revision: previous.controlRevision + 1,
    previousHash: previous.controlStateHash,
    epoch: previous.acceptedEpoch,
    operation: const UpdateGroupMetadataOperation(
      GroupMetadata(name: 'Edited'),
    ),
    controlHash: _repeat('61', 32),
    signerUserId: _localUser,
    signerDeviceId: _localDevice,
  );
  final applied =
      const GroupControlStateMachine().apply(
            previous: previous,
            signedControl: signed,
            localUserId: _localUser,
          )
          as GroupControlAccepted;
  return (
    PreparedGroupTransition(
      signedControl: signed,
      newOpaqueMlsState: Uint8List.fromList([9, 9]),
      mlsObject: Uint8List.fromList('CPGTO001-extension'.codeUnits),
      mutationId: 'extension-${signed.event.eventId}',
      recipientUserIds: const [_peer],
    ),
    applied.state,
  );
}

Future<PreparedGroupInboxCommit> _prepareRejoin(
  GroupMlsInboundCoordinator coordinator,
) async =>
    (await coordinator.inspect(_object(_ScriptKind.welcome))
            as Success<PreparedGroupInboxCommit>)
        .value;

Uint8List _object(_ScriptKind kind) =>
    Uint8List.fromList(utf8.encode('CPGTO001|${kind.name}'));

/// The transition a peer's remove-then-add produces for this device: a Welcome
/// carrying the complete control transcript (create, remove, re-add) plus a
/// consumed KeyPackage.
PreparedGroupTransition _readmission(
  String groupId, {
  bool admitLocalDevice = true,
  bool consumeKeyPackage = true,
  String signerDeviceId = _peerDevice,
}) {
  final create = _signed(
    groupId: groupId,
    revision: 1,
    previousHash: null,
    epoch: 1,
    operation: CreateGroupOperation(
      metadata: const GroupMetadata(name: 'Team'),
      invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
      historySharingPolicy: GroupHistorySharingPolicy.reshareAvailable,
      initialMembers: [
        GroupMember(
          userId: _peer,
          displayName: 'Peer',
          role: GroupRole.owner,
          deviceIds: const [_peerDevice],
        ),
        GroupMember(
          userId: _localUser,
          displayName: 'Local',
          role: GroupRole.member,
          deviceIds: const [_localDevice],
        ),
      ],
    ),
    controlHash: _repeat('a1', 32),
    signerUserId: _peer,
    signerDeviceId: signerDeviceId,
  );
  final remove = _signed(
    groupId: groupId,
    revision: 2,
    previousHash: create.controlStateHash,
    epoch: 2,
    operation: const RemoveGroupMemberOperation(_localUser),
    controlHash: _repeat('a2', 32),
    signerUserId: _peer,
    signerDeviceId: signerDeviceId,
  );
  final readd = _signed(
    groupId: groupId,
    revision: 3,
    previousHash: remove.controlStateHash,
    epoch: 3,
    operation: InviteGroupMembersOperation([
      GroupMember(
        userId: admitLocalDevice ? _localUser : _otherUser,
        displayName: 'Local',
        role: GroupRole.member,
        verified: true,
        deviceIds: const [_localDevice],
      ),
    ]),
    controlHash: _repeat('a3', 32),
    signerUserId: _peer,
    signerDeviceId: signerDeviceId,
  );
  return PreparedGroupTransition(
    signedControl: readd,
    newOpaqueMlsState: Uint8List.fromList(utf8.encode('REJOINED|$groupId')),
    mlsObject: _object(_ScriptKind.welcome),
    mutationId: 'welcome-${readd.event.eventId}',
    recipientUserIds: const [],
    outbound: false,
    consumedKeyPackageState: consumeKeyPackage
        ? ConsumedGroupKeyPackageState(
            deviceId: _localDevice,
            expectedStateRevision: 1,
            nextSealedState: Uint8List.fromList([77]),
          )
        : null,
    controlTranscriptEntry: _transcriptEntry(readd),
    precedingControlTranscript: [
      _transcriptEntry(create),
      _transcriptEntry(remove),
    ],
  );
}

const _otherUser = '30000000-0000-4000-8000-00000000000f';

GroupControlTranscriptEntry _transcriptEntry(SignedGroupControlEvent signed) =>
    GroupControlTranscriptEntry(
      signedControl: signed,
      signedPayload: Uint8List.fromList('CPGCV001'.codeUnits),
      signerAuthenticationProof: Uint8List.fromList('CPBRV001'.codeUnits),
    );

SignedGroupControlEvent _signed({
  required String groupId,
  required int revision,
  required String? previousHash,
  required int epoch,
  required GroupControlOperation operation,
  required String controlHash,
  required String signerUserId,
  required String signerDeviceId,
}) {
  final event = GroupControlEvent(
    eventId: '$_groupIdSeed${revision.toRadixString(16).padLeft(24, '0')}',
    groupId: groupId,
    revision: revision,
    previousControlStateHash: previousHash,
    mlsEpoch: epoch,
    mlsCommitHash: operation.changesMembership ? _repeat('77', 32) : null,
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
    signature: Uint8List.fromList(List.filled(64, 3)),
  );
}

String _repeat(String pair, int count) => List.filled(count, pair).join();

OpaqueEnvelopeInspection _inspection(PreparedGroupInboxCommit groupCommit) =>
    OpaqueEnvelopeInspection(
      opaqueEventId: groupCommit.opaqueEventId,
      dependency: EnvelopeDependency.potentiallyMls,
      groupCommit: groupCommit,
      pairwiseCommit: PairwiseSyncReceiveCommit(
        envelopeId: _rejoinEnvelope,
        opaqueEventId: groupCommit.opaqueEventId,
        senderUserId: groupCommit.senderUserId,
        senderDeviceId: groupCommit.senderDeviceId,
        replayMarker: Uint8List(32),
        openedOpaquePayload: _object(_ScriptKind.welcome),
        sessionTransition: PairwiseSyncSessionTransition(
          localDeviceId: _localDevice,
          remoteUserId: _peer,
          remoteDeviceId: _peerDevice,
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

Future<void> _insertLocalDevice(LocalDatabase database) => database
    .into(database.devices)
    .insert(
      DevicesCompanion.insert(
        deviceId: _localDevice,
        userId: _localUser,
        publicBundle: Uint8List.fromList([1]),
        revocationState: 0,
        isCurrentDevice: const Value(true),
      ),
    );

Future<void> _seedKeyPackageState(LocalDatabase database) async {
  await database
      .into(database.secureSecrets)
      .insert(
        SecureSecretsCompanion.insert(
          secretId: _keyPackageSecretId,
          kind: 2,
          wrappedCiphertextOrOpaqueHandle: Uint8List.fromList([50]),
          formatVersion: 1,
        ),
      );
}

Future<void> _seedMessage(LocalDatabase database, String groupId) => database
    .into(database.messages)
    .insert(
      MessagesCompanion.insert(
        messageId: 'dddddddddddddddddddddddddddddddd',
        conversationId: groupId,
        currentEventId: 'dddddddddddddddddddddddddddddddd',
        projectionCiphertext: Uint8List.fromList(utf8.encode('kept')),
        status: 1,
        revision: 0,
        createdAt: DateTime.utc(2026, 8, 10),
      ),
    );

Future<void> _seedPairwiseSession(LocalDatabase database) async {
  await database
      .into(database.secureSecrets)
      .insert(
        SecureSecretsCompanion.insert(
          secretId: 'current-device-key-state-v1',
          kind: 1,
          wrappedCiphertextOrOpaqueHandle: Uint8List.fromList([60]),
          formatVersion: 1,
        ),
      );
  await database
      .into(database.pairwiseSessions)
      .insert(
        PairwiseSessionsCompanion.insert(
          localDeviceId: _localDevice,
          remoteUserId: const Value(_peer),
          remoteDeviceId: _peerDevice,
          sessionId: Value(Uint8List(16)),
          opaqueCryptoStateHandle: Uint8List.fromList([61]),
          stateVersion: 1,
          disposition: Value(
            PairwiseSessionDisposition.primaryBidirectional.index,
          ),
          repairState: Value(PairwiseRepairState.ready.index),
        ),
      );
}

// --- doubles ----------------------------------------------------------------

/// A scripted stand-in for the reviewed crypto core.
///
/// It returns already-authenticated preparations so the tests exercise the
/// application and storage decisions around re-admission, not the beta MLS
/// implementation, which has its own vectors and fixtures.
final class _ScriptedGroupMls implements GroupMlsCryptoPort {
  PreparedGroupTransition? welcome;
  bool welcomeFails = false;
  _ScriptKind probeKind = _ScriptKind.welcome;
  String? probeGroupId;
  int prepareControlCalls = 0;
  int inspectControlCalls = 0;
  int inspectApplicationCalls = 0;

  @override
  Future<Result<GroupMlsTransportProbe>> probeIncomingTransport(
    Uint8List mlsObject,
  ) async {
    final marker = utf8.decode(mlsObject).split('|').last;
    final kind = _ScriptKind.values.firstWhere(
      (value) => value.name == marker,
      orElse: () => probeKind,
    );
    final groupId =
        probeGroupId ?? welcome?.signedControl.event.groupId ?? _otherGroupId;
    return Result.success(
      GroupMlsTransportProbe(
        kind: switch (kind) {
          _ScriptKind.welcome => GroupMlsTransportKind.welcome,
          _ScriptKind.control => GroupMlsTransportKind.control,
          _ScriptKind.application => GroupMlsTransportKind.application,
        },
        groupId: groupId,
      ),
    );
  }

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingWelcome({
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async {
    final prepared = welcome;
    if (welcomeFails || prepared == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    return Result.success(prepared);
  }

  @override
  Future<Result<PreparedGroupTransition>> prepareControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
    required int createdMs,
  }) async {
    prepareControlCalls += 1;
    return const Result.failure(
      UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
    );
  }

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async {
    inspectControlCalls += 1;
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );
  }

  @override
  Future<Result<PreparedGroupMessage>> inspectIncomingApplication({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async {
    inspectApplicationCalls += 1;
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );
  }

  @override
  Future<Result<PreparedGroupTransition>> prepareCreate(
    GroupCreationIntent intent,
  ) async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  @override
  Future<Result<PreparedGroupMessage>> prepareApplicationMessage({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required String senderUserId,
    required String senderDeviceId,
    required String text,
    required int createdMs,
  }) async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  @override
  Future<Result<GroupForkResolution>> reconcileFork({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required List<Uint8List> siblingCommits,
    required String localUserId,
    required String localDeviceId,
  }) async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );
}

/// Opens the envelope to exactly the scripted group object; the pairwise
/// transport itself is covered by its own suite.
final class _StubPairwiseCrypto implements PairwiseSessionCryptoPort {
  @override
  Future<Result<native.PairwisePublicHeaderInspection>> inspectPublicHeader({
    required Uint8List envelope,
  }) async => Result.success(
    native.PairwisePublicHeaderInspection(
      kind: native.PairwisePublicEnvelopeKind.regular,
      sessionId: Uint8List(16),
    ),
  );

  @override
  Future<Result<native.PairwiseRatchetDecryptResult>> decrypt({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List recipientDeviceId,
    required native.PairwiseSessionState session,
    required Uint8List envelope,
    required int otherSessionsSkippedKeys,
  }) async => Result.success(
    native.PairwiseRatchetDecryption(
      nextSession: session,
      openedPayload: _object(_ScriptKind.welcome),
      replayMarker: Uint8List(32),
      payloadKind: native.PairwiseOpenedPayloadKind.opaque,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not exercised by the queue-gap matrix');
}

final class _Unused
    implements
        PairwiseLiveDeviceResolverPort,
        ApplicationProtocolPort,
        DeviceControlCryptoPort,
        ApplicationConversationResolverPort {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not exercised by the queue-gap matrix');
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 8, 18, 12);
}
