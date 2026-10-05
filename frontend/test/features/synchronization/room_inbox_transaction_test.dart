import 'package:communication_platform/core/protocol/pairwise_sync_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../voice/support/room_fakes.dart';

const _envelope = '50000000-0000-4000-8000-000000000001';
final _roomId = 'ab' * 32;

/// A room payload arrives as an ordinary envelope on a pairwise session, as a
/// group payload does. The ratchet step that opened it and the room change it
/// carries commit as one: neither may survive without the other.
void main() {
  late LocalDatabase database;
  late DriftRoomRepository rooms;
  late DriftSyncStore sync;
  late SignedRoomControlEvent create;
  late RoomState room;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    rooms = DriftRoomRepository(database);
    sync = DriftSyncStore(database);
    create = await signRoomEvent(
      signerUserId: roomAlice,
      signerDeviceId: roomAlicePhone,
      roomId: _roomId,
      revision: 1,
      previous: null,
      operation: CreateRoomOperation(
        name: 'Atomic inbox',
        memberUserIds: [roomAlice, roomBob],
      ),
      eventMarker: 1,
    );
    room = _apply(null, create);
    await rooms.commitTransition(
      expectedPrevious: null,
      next: room,
      prepared: PreparedRoomTransition(controls: [create]),
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
    await sync.beginNextEnvelopeInspection(now: DateTime.utc(2026, 9, 30));
  });

  tearDown(() => database.close());

  Future<PreparedRoomInboxTransition> rename() async {
    final signed = await signRoomEvent(
      signerUserId: roomAlice,
      signerDeviceId: roomAlicePhone,
      roomId: _roomId,
      revision: 2,
      previous: create,
      operation: const RenameRoomOperation('Renamed'),
      eventMarker: 2,
    );
    return PreparedRoomInboxTransition(
      opaqueEventId: 'room-control:${signed.event.eventId}',
      senderUserId: roomAlice,
      senderDeviceId: roomAlicePhone,
      expectedPrevious: room,
      next: _apply(room, signed),
      prepared: PreparedRoomTransition(controls: [signed]),
    );
  }

  test('a pairwise receive and a room control commit together', () async {
    final result = await sync.commitOpaqueInspection(
      envelopeId: _envelope,
      inspection: _inspection(roomCommit: await rename()),
    );

    expect(result, isA<Success<bool>>());
    expect(
      await database.select(database.pairwiseSessions).get(),
      hasLength(1),
    );
    final stored =
        (await rooms.readStoredRoom(_roomId) as Success<RoomState?>).value!;
    expect(stored.controlRevision, 2);
    expect(stored.name, 'Renamed');
    expect(
      (await database.select(database.inboxEnvelopes).getSingle())
          .dependencyClass,
      EnvelopeDependency.groupState.index,
    );
  });

  test('a stale compare-and-swap rolls the pairwise receive back', () async {
    final change = await rename();
    // Another receive moved the room on after this one read it.
    await database
        .update(database.roomStates)
        .write(const RoomStatesCompanion(controlRevision: Value(7)));

    final result = await sync.commitOpaqueInspection(
      envelopeId: _envelope,
      inspection: _inspection(roomCommit: change),
    );

    expect(result, isA<FailureResult<bool>>());
    expect(await database.select(database.pairwiseSessions).get(), isEmpty);
    expect(
      await database.select(database.roomControlEvents).get(),
      hasLength(1),
    );
    expect(
      (await database.select(database.inboxEnvelopes).getSingle())
          .processingState,
      InboxProcessingState.inspecting.index,
    );
  });

  test(
    'an answer owed to one device commits with the request for it',
    () async {
      final answer = RoomSyncPayloadCodec.encode(
        RoomTranscriptPayload(
          roomId: _roomId,
          baseRevision: 1,
          baseStateHash: create.controlStateHash,
          entries: const [],
        ),
      );

      final result = await sync.commitOpaqueInspection(
        envelopeId: _envelope,
        inspection: _inspection(
          roomCommit: PreparedRoomInboxOutbound(
            opaqueEventId: 'room-state-request:$_envelope',
            senderUserId: roomAlice,
            senderDeviceId: roomAlicePhone,
            work: RoomOutboundWork(
              operationId: 'room-state-response:$_envelope',
              roomId: _roomId,
              eventId: 'room-state-response:$_envelope',
              payload: answer,
              recipientUserIds: const [roomAlice],
              recipientDeviceId: roomAlicePhone,
            ),
          ),
        ),
      );

      expect(result, isA<Success<bool>>());
      final work = await database
          .select(database.roomOutboundObjects)
          .getSingle();
      expect(work.recipientDeviceId, roomAlicePhone);
      expect(work.payload, answer);
    },
  );

  test('an inspection carrying a group and a room change is refused', () async {
    final result = await sync.commitOpaqueInspection(
      envelopeId: _envelope,
      inspection: _inspection(
        roomCommit: await rename(),
        groupCommit: PreparedGroupInboxStateRequest(
          opaqueEventId: 'room-control:${'02' * 16}',
          senderUserId: roomAlice,
          senderDeviceId: roomAlicePhone,
          groupId: 'cd' * 32,
          peerUserId: roomAlice,
        ),
      ),
    );

    expect(result, isA<FailureResult<bool>>());
    expect(await database.select(database.pairwiseSessions).get(), isEmpty);
  });

  test('a room change claiming another sender is refused', () async {
    final change = await rename();
    final result = await sync.commitOpaqueInspection(
      envelopeId: _envelope,
      inspection: _inspection(
        roomCommit: PreparedRoomInboxTransition(
          opaqueEventId: change.opaqueEventId,
          senderUserId: roomBob,
          senderDeviceId: roomBobPhone,
          expectedPrevious: change.expectedPrevious,
          next: change.next,
          prepared: change.prepared,
        ),
        pairwiseSender: (roomAlice, roomAlicePhone),
      ),
    );

    expect(result, isA<FailureResult<bool>>());
    expect(
      ((await rooms.readStoredRoom(_roomId) as Success<RoomState?>).value!)
          .controlRevision,
      1,
    );
  });

  test('a mailbox gap makes every active room wait for its state', () async {
    await sync.persistDrainPage(
      DrainPage(
        envelopes: [
          SyncEnvelope(
            id: '50000000-0000-4000-8000-000000000009',
            sequence: 9,
            exactCiphertext: Uint8List(1024),
          ),
        ],
        hasMore: false,
        prunedThrough: 5,
      ),
    );

    final waiting =
        (await rooms.readRoom(_roomId) as Success<RoomState?>).value!;
    expect(waiting.lifecycle, RoomLifecycle.stateRecoveryRequired);
    expect(RoomAuthorization.mayAct(waiting, roomBob), isFalse);
  });
}

RoomState _apply(RoomState? previous, SignedRoomControlEvent signed) =>
    (const RoomControlStateMachine().apply(
              previous: previous,
              signedControl: signed,
              localUserId: roomBob,
            )
            as RoomControlAccepted)
        .state;

OpaqueEnvelopeInspection _inspection({
  required PreparedRoomInboxCommit roomCommit,
  PreparedGroupInboxCommit? groupCommit,
  (String, String)? pairwiseSender,
}) {
  final (senderUserId, senderDeviceId) =
      pairwiseSender ?? (roomCommit.senderUserId, roomCommit.senderDeviceId);
  return OpaqueEnvelopeInspection(
    opaqueEventId: roomCommit.opaqueEventId,
    dependency: EnvelopeDependency.groupState,
    groupCommit: groupCommit,
    roomCommit: roomCommit,
    pairwiseCommit: PairwiseSyncReceiveCommit(
      envelopeId: _envelope,
      opaqueEventId: roomCommit.opaqueEventId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
      replayMarker: Uint8List(32),
      openedOpaquePayload: Uint8List.fromList(RoomSyncProtocolV1.magic),
      sessionTransition: PairwiseSyncSessionTransition(
        localDeviceId: roomBobPhone,
        remoteUserId: senderUserId,
        remoteDeviceId: senderDeviceId,
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
}
