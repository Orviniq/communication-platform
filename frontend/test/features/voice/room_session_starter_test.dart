import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/voice/application/room_session_starter.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

final _roomId = 'ab' * 32;

/// Device ids sort Alice's phone, Alice's tablet, Bob, Carol, Dave.
void main() {
  late SignedRoomControlEvent create;

  setUp(() async {
    create = await signRoomEvent(
      signerUserId: roomAlice,
      signerDeviceId: roomAlicePhone,
      roomId: _roomId,
      revision: 1,
      previous: null,
      operation: CreateRoomOperation(
        name: 'Standup',
        memberUserIds: [roomAlice, roomBob, roomCarol, roomDave],
      ),
      eventMarker: 1,
    );
  });

  test('after accepting a change, a device starts only upward', () async {
    final bob = await _Device.holding(create, roomBob, roomBobPhone);
    // Alice's phone started its session with Bob when it sent the create.
    bob.sessions.establish(roomBobPhone, roomAlicePhone);

    final started = await bob.starter.startDueSessions();

    expect((started as Success<int>).value, 2);
    final work = await bob.pending();
    expect(
      work.map(
        (item) => (item.recipientUserIds.single, item.recipientDeviceId),
      ),
      [(roomCarol, roomCarolPhone), (roomDave, roomDavePhone)],
      reason: "Alice's tablet sorts below Bob and starts its own",
    );
    for (final item in work) {
      final request =
          RoomSyncPayloadCodec.decode(item.payload) as RoomStateRequestPayload;
      expect(request.roomId, _roomId);
      expect(request.haveRevision, 1);
      expect(request.haveStateHash, create.controlStateHash);
      expect(item.includeOwnDevices, isFalse);
    }
    expect(await bob.due(), isEmpty);
    await bob.close();
  });

  test(
    'two devices that accept one change start one session between them',
    () async {
      final bob = await _Device.holding(create, roomBob, roomBobPhone);
      final carol = await _Device.holding(create, roomCarol, roomCarolPhone);

      await bob.starter.startDueSessions();
      await carol.starter.startDueSessions();

      Set<String?> startedBy(List<RoomOutboundWork> work) => {
        for (final item in work) item.recipientDeviceId,
      };
      final bobStarted = startedBy(await bob.pending());
      final carolStarted = startedBy(await carol.pending());
      expect(bobStarted, contains(roomCarolPhone));
      expect(carolStarted, isNot(contains(roomBobPhone)));
      expect(carolStarted, {roomDavePhone});
      await bob.close();
      await carol.close();
    },
  );

  test('once a day a device starts every session still missing', () async {
    final bob = await _Device.holding(create, roomBob, roomBobPhone);
    bob.sessions.establish(roomBobPhone, roomAlicePhone);
    await bob.starter.startDueSessions();
    await bob.routeAll();
    // Carol and Dave fetched their requests; Alice's tablet never started
    // its own, because it was switched off when the room was made.
    bob.sessions
      ..establish(roomBobPhone, roomCarolPhone)
      ..establish(roomBobPhone, roomDavePhone);

    bob.clock.advance(const Duration(hours: 23));
    expect((await bob.starter.startDueSessions() as Success<int>).value, 0);
    bob.clock.advance(const Duration(hours: 2));
    expect((await bob.starter.startDueSessions() as Success<int>).value, 1);

    expect((await bob.pending()).single.recipientDeviceId, roomAliceTablet);
    await bob.close();
  });

  test(
    'payloads already owed to a member start its sessions instead',
    () async {
      final bob = await _Device.holding(create, roomBob, roomBobPhone);
      await bob.database.transaction(
        () => bob.rooms.queueOutboundInsideTransaction(
          RoomOutboundWork(
            operationId: 'room-transcript:owed:$roomDave',
            roomId: _roomId,
            eventId: 'room-transcript:owed:$roomDave',
            payload: RoomSyncPayloadCodec.encode(
              RoomStateRequestPayload(
                roomId: _roomId,
                haveRevision: 0,
                haveStateHash: null,
              ),
            ),
            recipientUserIds: const [roomDave],
          ),
        ),
      );

      await bob.starter.startDueSessions();

      final targets = [
        for (final item in await bob.pending()) ?item.recipientDeviceId,
      ];
      expect(targets, [roomCarolPhone]);
      await bob.close();
    },
  );

  test('a member whose devices cannot be authenticated is left out', () async {
    final bob = await _Device.holding(create, roomBob, roomBobPhone);
    bob.devices.blockedUsers.add(roomCarol);

    final report =
        (await bob.starter.startSessionsForCall(_roomId)
                as Success<RoomSessionCheckReport>)
            .value;

    expect(report.unresolvedUserIds, {roomCarol});
    expect(report.started.map((target) => target.deviceId), [
      roomAlicePhone,
      roomAliceTablet,
      roomDavePhone,
    ]);
    await bob.close();
  });

  test(
    "the call's check starts every missing session, whichever sorts lower",
    () async {
      final bob = await _Device.holding(create, roomBob, roomBobPhone);
      bob.sessions
        ..establish(roomBobPhone, roomAlicePhone)
        ..establish(roomBobPhone, roomCarolPhone);

      final report =
          (await bob.starter.startSessionsForCall(_roomId)
                  as Success<RoomSessionCheckReport>)
              .value;

      expect(report.started, [
        const RoomSessionTarget(userId: roomAlice, deviceId: roomAliceTablet),
        const RoomSessionTarget(userId: roomDave, deviceId: roomDavePhone),
      ]);
      expect(report.unresolvedUserIds, isEmpty);
      expect(await bob.due(), isEmpty, reason: 'the check is recorded');

      await bob.rooms.openStateRequest(roomId: _roomId, peerUserId: roomAlice);
      expect(
        (await bob.starter.startSessionsForCall(_roomId)
                as FailureResult<RoomSessionCheckReport>)
            .failure,
        const SecurityFailure(SecurityFailureKind.policyBlocked),
        reason: 'a room that may be missing a removal starts nothing',
      );
      await bob.close();
    },
  );
}

/// One device holding the room created by [create].
final class _Device {
  _Device._(
    this.database,
    this.rooms,
    this.starter,
    this.sessions,
    this.devices,
    this.clock,
  );

  static Future<_Device> holding(
    SignedRoomControlEvent create,
    String userId,
    String deviceId,
  ) async {
    final database = LocalDatabase(NativeDatabase.memory());
    final rooms = DriftRoomRepository(database);
    final state =
        (const RoomControlStateMachine().apply(
                  previous: null,
                  signedControl: create,
                  localUserId: userId,
                )
                as RoomControlAccepted)
            .state;
    await rooms.commitTransition(
      expectedPrevious: null,
      next: state,
      prepared: PreparedRoomTransition(controls: [create]),
    );
    final sessions = FakeRoomSessions();
    final devices = FakeRoomLiveDevices({
      roomAlice: [roomAlicePhone, roomAliceTablet],
      roomBob: [roomBobPhone],
      roomCarol: [roomCarolPhone],
      roomDave: [roomDavePhone],
    });
    final clock = FakeRoomClock();
    return _Device._(
      database,
      rooms,
      RoomSessionStarter(
        repository: rooms,
        liveDevices: devices,
        sessions: sessions,
        clock: clock,
        currentUserId: userId,
        currentDeviceId: deviceId,
      ),
      sessions,
      devices,
      clock,
    );
  }

  final LocalDatabase database;
  final DriftRoomRepository rooms;
  final RoomSessionStarter starter;
  final FakeRoomSessions sessions;
  final FakeRoomLiveDevices devices;
  final FakeRoomClock clock;

  Future<List<RoomOutboundWork>> pending() async =>
      (await rooms.readPendingOutbound() as Success<List<RoomOutboundWork>>)
          .value;

  Future<List<RoomSessionCheck>> due() async =>
      (await rooms.readDueSessionChecks(
                checkedBefore: clock.now().subtract(const Duration(hours: 24)),
              )
              as Success<List<RoomSessionCheck>>)
          .value;

  Future<void> routeAll() async {
    for (final work in await pending()) {
      await rooms.markOutboundRouted(operationId: work.operationId);
    }
  }

  Future<void> close() => database.close();
}
