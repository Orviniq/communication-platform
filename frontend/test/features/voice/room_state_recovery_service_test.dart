import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/application/room_state_recovery_service.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

final _roomId = 'ab' * 32;
final _soloRoomId = 'cd' * 32;

void main() {
  late LocalDatabase database;
  late DriftRoomRepository rooms;
  late FakeRoomClock clock;
  late _Repair repair;
  late RoomStateRecoveryService recovery;
  late SignedRoomControlEvent create;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    rooms = DriftRoomRepository(database);
    clock = FakeRoomClock();
    repair = _Repair();
    recovery = RoomStateRecoveryService(
      repository: rooms,
      repair: repair,
      clock: clock,
      currentUserId: roomBob,
      currentDeviceId: roomBobPhone,
    );
    create = await signRoomEvent(
      signerUserId: roomAlice,
      signerDeviceId: roomAlicePhone,
      roomId: _roomId,
      revision: 1,
      previous: null,
      operation: CreateRoomOperation(
        name: 'Standup',
        memberUserIds: [roomAlice, roomBob, roomCarol],
      ),
      eventMarker: 1,
    );
    await rooms.commitTransition(
      expectedPrevious: null,
      next:
          (const RoomControlStateMachine().apply(
                    previous: null,
                    signedControl: create,
                    localUserId: roomBob,
                  )
                  as RoomControlAccepted)
              .state,
      prepared: PreparedRoomTransition(controls: [create]),
    );
  });

  tearDown(() => database.close());

  Future<List<RoomOutboundWork>> pending() async =>
      (await rooms.readPendingOutbound() as Success<List<RoomOutboundWork>>)
          .value;

  test('a gap repairs, then asks the members in turn', () async {
    await database.transaction(rooms.recordQueueGapInsideTransaction);

    expect(await recovery.requestDueStates(), isA<Success<int>>());

    expect(repair.users, [roomAlice]);
    final first = (await pending()).single;
    expect(first.recipientUserIds, [roomAlice]);
    final request =
        RoomSyncPayloadCodec.decode(first.payload) as RoomStateRequestPayload;
    expect(request.haveRevision, 1);
    expect(request.haveStateHash, create.controlStateHash);

    // Nobody answers, so the next member in line is asked.
    await rooms.markOutboundRouted(operationId: first.operationId);
    clock.advance(const Duration(hours: 1));
    await recovery.requestDueStates();
    expect(await pending(), isEmpty);
    clock.advance(const Duration(hours: 6));
    await recovery.requestDueStates();
    expect((await pending()).single.recipientUserIds, [roomCarol]);
    expect(repair.users, [roomAlice, roomCarol]);
  });

  test('a gap in a room nobody else is active in stops waiting', () async {
    final solo = await signRoomEvent(
      signerUserId: roomBob,
      signerDeviceId: roomBobPhone,
      roomId: _soloRoomId,
      revision: 1,
      previous: null,
      operation: CreateRoomOperation(
        name: 'Solo',
        memberUserIds: [roomBob, roomCarol],
      ),
      eventMarker: 2,
    );
    final created =
        (const RoomControlStateMachine().apply(
                  previous: null,
                  signedControl: solo,
                  localUserId: roomBob,
                )
                as RoomControlAccepted)
            .state;
    final leave = await signRoomEvent(
      signerUserId: roomCarol,
      signerDeviceId: roomCarolPhone,
      roomId: _soloRoomId,
      revision: 2,
      previous: solo,
      operation: RemoveRoomMemberOperation(roomCarol),
      eventMarker: 3,
    );
    await rooms.commitTransition(
      expectedPrevious: null,
      next: created,
      prepared: PreparedRoomTransition(controls: [solo]),
    );
    await rooms.commitTransition(
      expectedPrevious: created,
      next:
          (const RoomControlStateMachine().apply(
                    previous: created,
                    signedControl: leave,
                    localUserId: roomBob,
                  )
                  as RoomControlAccepted)
              .state,
      prepared: PreparedRoomTransition(controls: [leave]),
    );
    await database.transaction(rooms.recordQueueGapInsideTransaction);

    await recovery.requestDueStates();

    final open = await database.select(database.roomStateRequests).get();
    expect(open.map((row) => row.roomId), [_roomId]);
  });

  test(
    'a request after an event from ahead gives up after three tries',
    () async {
      await rooms.openStateRequest(roomId: _roomId, peerUserId: roomCarol);

      for (var attempt = 0; attempt < 3; attempt += 1) {
        await recovery.requestDueStates();
        clock.advance(const Duration(hours: 7));
      }
      expect(
        (await pending()).map((work) => work.recipientUserIds.single).toSet(),
        {roomCarol},
      );
      expect(repair.users, isEmpty);

      await recovery.requestDueStates();

      expect(await database.select(database.roomStateRequests).get(), isEmpty);
    },
  );
}

final class _Repair implements RoomSessionRepairPort {
  final users = <String>[];

  @override
  Future<Result<int>> requestRepairWithUser({
    required String localDeviceId,
    required String remoteUserId,
  }) async {
    users.add(remoteUserId);
    return const Result.success(1);
  }
}
