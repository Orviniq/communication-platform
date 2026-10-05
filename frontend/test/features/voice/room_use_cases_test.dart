import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/application/room_outbound_dispatcher.dart';
import 'package:communication_platform/features/voice/application/room_use_cases.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

void main() {
  late LocalDatabase database;
  late DriftRoomRepository rooms;
  late CreateRoom create;
  late MutateRoom mutate;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    rooms = DriftRoomRepository(database);
    final clock = FakeRoomClock();
    create = CreateRoom(
      repository: rooms,
      crypto: FakeRoomControlCore(localDeviceId: roomAlicePhone),
      identity: FakeRoomIdentity(1),
      clock: clock,
    );
    mutate = MutateRoom(
      repository: rooms,
      crypto: FakeRoomControlCore(localDeviceId: roomAlicePhone),
      identity: FakeRoomIdentity(2),
      clock: clock,
    );
  });

  tearDown(() => database.close());

  Future<RoomState> created() async =>
      (await create(
                currentUserId: roomAlice,
                currentDeviceId: roomAlicePhone,
                name: '  Standup ',
                memberUserIds: [roomCarol, roomBob],
              )
              as Success<RoomState>)
          .value;

  Future<List<RoomOutboundWork>> pending() async =>
      (await rooms.readPendingOutbound() as Success<List<RoomOutboundWork>>)
          .value;

  test(
    'a room is created with one signed event owed to every member',
    () async {
      final room = await created();

      expect(room.name, 'Standup');
      expect(room.controlRevision, 1);
      expect(room.activeMembers.map((member) => member.userId), [
        roomAlice,
        roomBob,
        roomCarol,
      ]);
      expect(room.lifecycle, RoomLifecycle.active);
      final work = (await pending()).single;
      expect(work.recipientUserIds, [roomBob, roomCarol]);
      expect(work.includeOwnDevices, isTrue);
      expect(work.recipientDeviceId, isNull);
      final payload = RoomSyncPayloadCodec.decode(work.payload);
      expect(payload, isA<RoomControlDelivery>());
      final transcript =
          (await rooms.readTranscript(room.roomId)
                  as Success<List<StoredRoomControl>>)
              .value;
      expect(
        (payload as RoomControlDelivery).control.canonicalBytes,
        transcript.single.canonicalBytes,
      );
    },
  );

  test('a create is refused before anything is signed', () async {
    final crypto = FakeRoomControlCore(localDeviceId: roomAlicePhone);
    final refusing = CreateRoom(
      repository: rooms,
      crypto: crypto,
      identity: FakeRoomIdentity(3),
      clock: FakeRoomClock(),
    );
    Future<Failure> refused(String name, List<String> members) async =>
        (await refusing(
                  currentUserId: roomAlice,
                  currentDeviceId: roomAlicePhone,
                  name: name,
                  memberUserIds: members,
                )
                as FailureResult<RoomState>)
            .failure;

    expect(
      await refused(' ', [roomBob]),
      const ValidationFailure(ValidationFailureKind.invalidInput),
    );
    expect(
      await refused('x' * 101, [roomBob]),
      const ValidationFailure(ValidationFailureKind.invalidInput),
    );
    expect(
      await refused('Alone', const []),
      const ValidationFailure(ValidationFailureKind.limitExceeded),
    );
    expect(
      await refused('Twice', [roomBob, roomBob]),
      const ValidationFailure(ValidationFailureKind.limitExceeded),
    );
    expect(
      await refused('Crowded', [
        for (var index = 1; index <= 50; index += 1)
          '50000000-0000-4000-8000-${index.toRadixString(16).padLeft(12, '0')}',
      ]),
      const ValidationFailure(ValidationFailureKind.limitExceeded),
    );
    expect(crypto.seals, 0);
    expect(await rooms.watchRooms().first, isEmpty);
  });

  test(
    'an add owes the event to the members and the room to the added',
    () async {
      final room = await created();
      await _routeAll(rooms);

      final added =
          (await mutate(
                    roomId: room.roomId,
                    actorUserId: roomAlice,
                    actorDeviceId: roomAlicePhone,
                    operation: AddRoomMembersOperation([roomDave]),
                  )
                  as Success<RoomState>)
              .value;

      expect(added.isActiveMember(roomDave), isTrue);
      final work = await pending();
      expect(work, hasLength(2));
      final control = work.singleWhere(
        (item) => item.operationId.startsWith('room-control:'),
      );
      expect(control.recipientUserIds, [roomBob, roomCarol]);
      final transcript = work.singleWhere(
        (item) => item.operationId.startsWith('room-transcript:'),
      );
      expect(transcript.recipientUserIds, [roomDave]);
      final payload =
          RoomSyncPayloadCodec.decode(transcript.payload)
              as RoomTranscriptPayload;
      expect(payload.baseRevision, 0);
      expect(payload.entries, hasLength(2));
    },
  );

  test('a removal is owed to the member it removes, too', () async {
    final room = await created();
    await _routeAll(rooms);

    await mutate(
      roomId: room.roomId,
      actorUserId: roomAlice,
      actorDeviceId: roomAlicePhone,
      operation: RemoveRoomMemberOperation(roomCarol),
    );

    final control = (await pending()).single;
    expect(control.recipientUserIds, [roomBob, roomCarol]);
    final stored =
        (await rooms.readStoredRoom(room.roomId) as Success<RoomState?>).value!;
    expect(stored.member(roomCarol)!.membership, RoomMembershipState.removed);
  });

  test('a waiting room, and a non-member, sign nothing', () async {
    final room = await created();
    await rooms.openStateRequest(roomId: room.roomId, peerUserId: roomBob);

    final waiting = await mutate(
      roomId: room.roomId,
      actorUserId: roomAlice,
      actorDeviceId: roomAlicePhone,
      operation: const RenameRoomOperation('Renamed'),
    );
    expect(
      (waiting as FailureResult<RoomState>).failure,
      const SecurityFailure(SecurityFailureKind.policyBlocked),
    );

    await rooms.retireStateRequest(room.roomId);
    final outsider = MutateRoom(
      repository: rooms,
      crypto: FakeRoomControlCore(localDeviceId: roomDavePhone),
      identity: FakeRoomIdentity(4),
      clock: FakeRoomClock(),
    );
    final refused = await outsider(
      roomId: room.roomId,
      actorUserId: roomDave,
      actorDeviceId: roomDavePhone,
      operation: const RenameRoomOperation('Mine now'),
    );
    expect(
      (refused as FailureResult<RoomState>).failure,
      const SecurityFailure(SecurityFailureKind.policyBlocked),
    );
    expect(
      (await rooms.readStoredRoom(room.roomId) as Success<RoomState?>)
          .value!
          .controlRevision,
      1,
    );
  });

  test('the dispatcher routes each payload and marks it routed', () async {
    final room = await created();
    final session = RoomOutboundWork(
      operationId: 'room-session:${room.roomId}:$roomCarolPhone:1',
      roomId: room.roomId,
      eventId: 'room-session:${room.roomId}:$roomCarolPhone:1',
      payload: Uint8List.fromList(const [7]),
      recipientUserIds: const [roomCarol],
      recipientDeviceId: roomCarolPhone,
    );
    await database.transaction(
      () => rooms.queueOutboundInsideTransaction(session),
    );
    final envelopes = _Envelopes()..refuse.add(roomBob);

    final first =
        await RoomOutboundDispatcher(
          repository: rooms,
          envelopes: envelopes,
        ).dispatchPending(
          currentUserId: roomAlice,
          currentDeviceId: roomAlicePhone,
        );

    // Bob's copy could not be sealed yet; Carol's session start still went.
    expect(first, isA<FailureResult<RoomOutboundDispatchReport>>());
    expect(
      envelopes.calls.map((call) => (call.target, call.onlyDevice)),
      containsAll([(roomBob, null), (roomCarol, roomCarolPhone)]),
    );
    expect((await pending()).map((work) => work.operationId), [
      startsWith('room-control:'),
    ]);

    envelopes.refuse.clear();
    final second =
        await RoomOutboundDispatcher(
          repository: rooms,
          envelopes: envelopes,
        ).dispatchPending(
          currentUserId: roomAlice,
          currentDeviceId: roomAlicePhone,
        );
    expect(second, isA<Success<RoomOutboundDispatchReport>>());
    expect(await pending(), isEmpty);
    final own = envelopes.calls.where((call) => call.includeOwnDevices);
    expect(own.map((call) => call.target).toSet(), {roomBob});
  });
}

Future<void> _routeAll(DriftRoomRepository rooms) async {
  for (final work
      in (await rooms.readPendingOutbound() as Success<List<RoomOutboundWork>>)
          .value) {
    await rooms.markOutboundRouted(operationId: work.operationId);
  }
}

final class _Call {
  const _Call({
    required this.operationId,
    required this.target,
    required this.onlyDevice,
    required this.includeOwnDevices,
  });

  final String operationId;
  final String target;
  final String? onlyDevice;
  final bool includeOwnDevices;
}

final class _Envelopes implements RoomOutboundEnvelopePort {
  final calls = <_Call>[];
  final refuse = <String>{};

  @override
  Future<Result<void>> prepareAndQueue({
    required String operationId,
    required String eventId,
    required String currentUserId,
    required String currentDeviceId,
    required String targetUserId,
    required Uint8List payload,
    required bool includeOwnDevices,
    String? onlyRecipientDeviceId,
  }) async {
    calls.add(
      _Call(
        operationId: operationId,
        target: targetUserId,
        onlyDevice: onlyRecipientDeviceId,
        includeOwnDevices: includeOwnDevices,
      ),
    );
    return refuse.contains(targetUserId)
        ? const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          )
        : const Result.success(null);
  }
}
