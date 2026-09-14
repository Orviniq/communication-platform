import 'dart:convert';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/pairwise_sync_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = '10000000-0000-4000-8000-000000000001';
const _ownerDevice = '20000000-0000-4000-8000-000000000001';
const _member = '30000000-0000-4000-8000-000000000001';
const _memberDevice = '40000000-0000-4000-8000-000000000001';
const _envelope = '50000000-0000-4000-8000-000000000001';
final _groupId = 'ab' * 32;

/// A group payload arrives as an ordinary envelope on a pairwise session. The
/// ratchet step that opened it and the group change it carries commit as one:
/// neither may survive without the other.
void main() {
  late LocalDatabase database;
  late DriftGroupRepository groups;
  late DriftSyncStore sync;
  late SignedGroupControlEvent create;
  late GroupState group;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    groups = DriftGroupRepository(database);
    sync = DriftSyncStore(database);
    // This device belongs to the member; the owner created the group.
    create = _signed(
      revision: 1,
      previous: null,
      operation: CreateGroupOperation(
        metadata: const GroupMetadata(name: 'Atomic inbox'),
        invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
        historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
        members: [
          GroupMember(
            userId: _owner,
            displayName: 'Owner',
            role: GroupRole.owner,
          ),
          GroupMember(
            userId: _member,
            displayName: 'Member',
            role: GroupRole.member,
          ),
        ],
      ),
    );
    group = _apply(null, create);
    expect(
      await groups.commitTransition(
        expectedPrevious: null,
        next: group,
        prepared: PreparedGroupTransition(controls: [create]),
      ),
      isA<Success<void>>(),
    );
    await sync.persistDrainPage(
      DrainPage(
        envelopes: [
          SyncEnvelope(
            id: _envelope,
            sequence: 1,
            exactCiphertext: Uint8List(1024),
          ),
        ],
        hasMore: false,
        prunedThrough: 0,
      ),
    );
    await sync.beginNextEnvelopeInspection(now: const _Clock().now());
  });

  tearDown(() => database.close());

  test('a pairwise receive and a group control commit together', () async {
    final rename = _signed(
      revision: 2,
      previous: create,
      operation: const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
    );

    final result = await sync.commitOpaqueInspection(
      envelopeId: _envelope,
      inspection: _inspection(
        PreparedGroupInboxTransition(
          opaqueEventId: 'group-control:${rename.event.eventId}',
          senderUserId: _owner,
          senderDeviceId: _ownerDevice,
          expectedPrevious: group,
          next: _apply(group, rename),
          prepared: PreparedGroupTransition(controls: [rename]),
        ),
      ),
    );

    expect(result, isA<Success<bool>>());
    expect(
      await database.select(database.pairwiseSessions).get(),
      hasLength(1),
    );
    expect(
      await database.select(database.pairwiseReplayMarkers).get(),
      hasLength(1),
    );
    final stored =
        (await groups.readStoredGroup(_groupId) as Success<GroupState?>).value!;
    expect(stored.controlRevision, 2);
    expect(stored.metadata.name, 'Renamed');
    expect(
      await database.select(database.groupControlEvents).get(),
      hasLength(2),
    );
    expect(
      (await database.select(database.inboxEnvelopes).getSingle())
          .dependencyClass,
      EnvelopeDependency.groupState.index,
    );
  });

  test('a stale compare-and-swap rolls the pairwise receive back', () async {
    final rename = _signed(
      revision: 2,
      previous: create,
      operation: const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
    );
    // Another receive moved the group on after this one read it.
    await database
        .update(database.groupStates)
        .write(const GroupStatesCompanion(controlRevision: Value(7)));

    final result = await sync.commitOpaqueInspection(
      envelopeId: _envelope,
      inspection: _inspection(
        PreparedGroupInboxTransition(
          opaqueEventId: 'group-control:${rename.event.eventId}',
          senderUserId: _owner,
          senderDeviceId: _ownerDevice,
          expectedPrevious: group,
          next: _apply(group, rename),
          prepared: PreparedGroupTransition(controls: [rename]),
        ),
      ),
    );

    expect(result, isA<FailureResult<bool>>());
    expect(await database.select(database.pairwiseSessions).get(), isEmpty);
    expect(
      await database.select(database.pairwiseReplayMarkers).get(),
      isEmpty,
    );
    expect(
      await database.select(database.groupControlEvents).get(),
      hasLength(1),
    );
    expect(
      (await database.select(database.inboxEnvelopes).getSingle())
          .processingState,
      InboxProcessingState.inspecting.index,
    );
  });

  test('a request for state commits with the receive that raised it', () async {
    final result = await sync.commitOpaqueInspection(
      envelopeId: _envelope,
      inspection: _inspection(
        PreparedGroupInboxStateRequest(
          opaqueEventId: 'group-control:${'0c' * 16}',
          senderUserId: _owner,
          senderDeviceId: _ownerDevice,
          groupId: _groupId,
          peerUserId: _owner,
        ),
      ),
    );

    expect(result, isA<Success<bool>>());
    final request = await database
        .select(database.groupStateRequests)
        .getSingle();
    expect(request.groupId, _groupId);
    expect(request.peerUserId, _owner);
    expect(request.reason, 1);
    expect(
      await database.select(database.pairwiseSessions).get(),
      hasLength(1),
    );
  });

  test(
    'an answer owed to one device commits with the request for it',
    () async {
      final answer = GroupSyncPayloadCodec.encode(
        GroupTranscriptPayload(
          groupId: _groupId,
          baseRevision: 0,
          baseStateHash: null,
          entries: [GroupSignedControlBytes.fromSigned(create)],
        ),
      );

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelope,
        inspection: _inspection(
          PreparedGroupInboxOutbound(
            opaqueEventId: 'group-state-request:$_envelope',
            senderUserId: _owner,
            senderDeviceId: _ownerDevice,
            work: GroupOutboundWork(
              operationId: 'group-state-response:$_envelope',
              groupId: _groupId,
              eventId: 'group-state-response:$_envelope',
              payload: answer,
              recipientUserIds: const [_owner],
              recipientDeviceId: _ownerDevice,
            ),
          ),
        ),
      );

      expect(result, isA<Success<bool>>());
      final work = await database
          .select(database.groupOutboundObjects)
          .getSingle();
      expect(work.recipientDeviceId, _ownerDevice);
      expect(work.includeOwnDevices, isFalse);
      expect(work.payload, answer);
    },
  );
}

SignedGroupControlEvent _signed({
  required int revision,
  required SignedGroupControlEvent? previous,
  required GroupControlOperation operation,
}) {
  final marker = revision.toRadixString(16).padLeft(2, '0');
  return SignedGroupControlEvent(
    event: GroupControlEvent(
      eventId: marker * 16,
      groupId: _groupId,
      revision: revision,
      previousControlStateHash: previous?.controlStateHash,
      signerUserId: _owner,
      signerDeviceId: _ownerDevice,
      createdMs: 1700000000000 + revision,
      operation: operation,
    ),
    controlStateHash: marker * 32,
    canonicalBytes: Uint8List.fromList(utf8.encode('control $marker')),
    signature: Uint8List(SignedGroupControlEvent.signatureBytes),
  );
}

GroupState _apply(GroupState? previous, SignedGroupControlEvent signed) =>
    (const GroupControlStateMachine().apply(
              previous: previous,
              signedControl: signed,
              localUserId: _member,
            )
            as GroupControlAccepted)
        .state;

OpaqueEnvelopeInspection _inspection(PreparedGroupInboxCommit groupCommit) =>
    OpaqueEnvelopeInspection(
      opaqueEventId: groupCommit.opaqueEventId,
      dependency: EnvelopeDependency.groupState,
      groupCommit: groupCommit,
      pairwiseCommit: PairwiseSyncReceiveCommit(
        envelopeId: _envelope,
        opaqueEventId: groupCommit.opaqueEventId,
        senderUserId: groupCommit.senderUserId,
        senderDeviceId: groupCommit.senderDeviceId,
        replayMarker: Uint8List(32),
        openedOpaquePayload: Uint8List.fromList(GroupSyncProtocolV1.magic),
        sessionTransition: PairwiseSyncSessionTransition(
          localDeviceId: _memberDevice,
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

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 9, 13, 12);
}
