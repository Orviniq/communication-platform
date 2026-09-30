import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

final _roomId = 'ab' * 32;
final _otherRoomId = 'ef' * 32;
const _machine = RoomControlStateMachine();

void main() {
  late LocalDatabase database;
  late DriftRoomRepository rooms;
  late SignedRoomControlEvent create;
  late RoomState created;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    rooms = DriftRoomRepository(database);
    create = await _create(_roomId);
    created = _apply(null, create);
    expect(
      await rooms.commitTransition(
        expectedPrevious: null,
        next: created,
        prepared: PreparedRoomTransition(controls: [create]),
      ),
      isA<Success<void>>(),
    );
  });

  tearDown(() => database.close());

  test('a committed room reads back with its transcript', () async {
    final stored = (await rooms.readStoredRoom(_roomId) as Success).value;
    expect(stored, isA<RoomState>());
    final room = stored as RoomState;
    expect(room.name, 'Standup');
    expect(room.members, created.members);
    expect(room.controlStateHash, create.controlStateHash);

    final transcript =
        (await rooms.readTranscript(_roomId)
                as Success<List<StoredRoomControl>>)
            .value;
    expect(transcript.single.canonicalBytes, create.canonicalBytes);
    expect(transcript.single.signature, create.signature);
    expect(
      (await database.select(database.roomControlEvents).getSingle())
          .operationKind,
      RoomControlKind.create.wireValue,
    );
    expect(await database.select(database.conversations).get(), isEmpty);
  });

  test('a transition built on a stale state is refused', () async {
    final rename = await _rename(create, 'Daily', marker: 2);
    final renamed = _apply(created, rename);
    expect(
      await rooms.commitTransition(
        expectedPrevious: created,
        next: renamed,
        prepared: PreparedRoomTransition(controls: [rename]),
      ),
      isA<Success<void>>(),
    );

    final sibling = await _rename(create, 'Other', marker: 3);
    final result = await rooms.commitTransition(
      expectedPrevious: created,
      next: _apply(created, sibling),
      prepared: PreparedRoomTransition(controls: [sibling]),
    );

    expect(
      (result as FailureResult<void>).failure,
      const ValidationFailure(ValidationFailureKind.conflict),
    );
    expect(
      ((await rooms.readStoredRoom(_roomId) as Success).value as RoomState)
          .name,
      'Daily',
    );
  });

  test('an open request reads as waiting until it is retired', () async {
    expect(
      await rooms.openStateRequest(roomId: _roomId, peerUserId: roomAlice),
      isA<Success<void>>(),
    );
    final waiting =
        (await rooms.readRoom(_roomId) as Success<RoomState?>).value!;
    expect(waiting.lifecycle, RoomLifecycle.stateRecoveryRequired);
    expect(RoomAuthorization.mayAct(waiting, roomBob), isFalse);
    final stored =
        (await rooms.readStoredRoom(_roomId) as Success<RoomState?>).value!;
    expect(stored.lifecycle, RoomLifecycle.active);
    expect(
      await rooms.watchRoom(_roomId).first,
      isA<RoomState>().having(
        (room) => room.lifecycle,
        'lifecycle',
        RoomLifecycle.stateRecoveryRequired,
      ),
    );

    await rooms.retireStateRequest(_roomId);

    expect(
      (await rooms.readRoom(_roomId) as Success<RoomState?>).value!.lifecycle,
      RoomLifecycle.active,
    );
  });

  test('a mailbox gap flags every active room and nothing else', () async {
    final other = await _create(_otherRoomId);
    await rooms.commitTransition(
      expectedPrevious: null,
      next: _apply(
        null,
        other,
        localUserId: roomCarol,
      ).copyWith(lifecycle: RoomLifecycle.removed),
      prepared: PreparedRoomTransition(controls: [other]),
    );

    await database.transaction(rooms.recordQueueGapInsideTransaction);

    final requests = await database.select(database.roomStateRequests).get();
    expect(requests.map((row) => row.roomId), [_roomId]);
    expect(requests.single.reason, 0);
    // The checkpoint's gap is the groups' to close; a room waits on its own.
    expect(await database.select(database.syncCheckpoints).get(), isEmpty);
  });

  test('outbound work is read by room and marked routed once', () async {
    final work = RoomOutboundWork(
      operationId: 'room-session:$_roomId:$roomCarolPhone:1',
      roomId: _roomId,
      eventId: 'room-session:$_roomId:$roomCarolPhone:1',
      payload: Uint8List.fromList(const [1, 2, 3]),
      recipientUserIds: const [roomCarol],
      recipientDeviceId: roomCarolPhone,
    );
    await database.transaction(
      () => rooms.queueOutboundInsideTransaction(work),
    );
    await database.transaction(
      () => rooms.queueOutboundInsideTransaction(work),
    );

    final forRoom =
        (await rooms.readPendingOutboundForRoom(_roomId)
                as Success<List<RoomOutboundWork>>)
            .value;
    expect(forRoom.single.recipientDeviceId, roomCarolPhone);
    expect(
      (await rooms.readPendingOutboundForRoom(_otherRoomId)
              as Success<List<RoomOutboundWork>>)
          .value,
      isEmpty,
    );

    expect(
      await rooms.markOutboundRouted(operationId: work.operationId),
      isA<Success<void>>(),
    );
    expect(
      await rooms.markOutboundRouted(operationId: work.operationId),
      isA<Success<void>>(),
    );
    expect(
      (await rooms.readPendingOutbound() as Success<List<RoomOutboundWork>>)
          .value,
      isEmpty,
    );
  });

  test('a fork quarantines the room; an unauthorized event does not', () async {
    await database.transaction(
      () => rooms.quarantineInsideTransaction(
        RoomQuarantineRecord(
          roomId: _roomId,
          reason: RoomQuarantineReason.unauthorizedControl,
          opaqueDigest: Uint8List(32),
          receivedAt: DateTime.utc(2026, 9, 30),
        ),
        retainLifecycle: true,
      ),
    );
    expect(
      ((await rooms.readStoredRoom(_roomId) as Success).value as RoomState)
          .lifecycle,
      RoomLifecycle.active,
    );

    await database.transaction(
      () => rooms.quarantineInsideTransaction(
        RoomQuarantineRecord(
          roomId: _roomId,
          reason: RoomQuarantineReason.siblingControl,
          opaqueDigest: Uint8List(32),
          receivedAt: DateTime.utc(2026, 9, 30),
        ),
        retainLifecycle: false,
      ),
    );

    final room = (await rooms.readRoom(_roomId) as Success<RoomState?>).value!;
    expect(room.lifecycle, RoomLifecycle.forkQuarantined);
    expect(room.quarantineReason, RoomQuarantineReason.siblingControl);
    final records = await database.select(database.quarantineRecords).get();
    expect(records.map((row) => row.reasonCode), [
      48 + RoomQuarantineReason.unauthorizedControl.index,
      48 + RoomQuarantineReason.siblingControl.index,
    ]);
  });

  group('session checks', () {
    final now = DateTime.utc(2026, 9, 30, 12);

    Future<List<RoomSessionCheck>> due([DateTime? checkedBefore]) async =>
        (await rooms.readDueSessionChecks(
                  checkedBefore:
                      checkedBefore ?? now.subtract(const Duration(hours: 24)),
                )
                as Success<List<RoomSessionCheck>>)
            .value;

    test('a room is due after it is created, and not after a check', () async {
      final check = (await due()).single;
      expect(check.roomId, _roomId);
      expect(check.followsAcceptedChange, isTrue);
      expect(check.controlStateHash, create.controlStateHash);

      final request = RoomOutboundWork(
        operationId: 'room-session:$_roomId:$roomCarolPhone:1',
        roomId: _roomId,
        eventId: 'room-session:$_roomId:$roomCarolPhone:1',
        payload: Uint8List.fromList(const [9]),
        recipientUserIds: const [roomCarol],
        recipientDeviceId: roomCarolPhone,
      );
      expect(
        await rooms.recordSessionCheck(
          check: check,
          work: [request],
          checkedAt: now,
        ),
        isA<Success<void>>(),
      );

      expect(await due(), isEmpty);
      expect(
        (await rooms.readPendingOutbound() as Success<List<RoomOutboundWork>>)
            .value
            .single
            .operationId,
        request.operationId,
      );
      final again = await due(now.add(const Duration(hours: 1)));
      expect(again.single.followsAcceptedChange, isFalse);
      expect(again.single.checkedAt, now);
    });

    test('an add makes the room due again and a rename does not', () async {
      await rooms.recordSessionCheck(
        check: (await due()).single,
        work: const [],
        checkedAt: now,
      );
      final rename = await _rename(create, 'Daily', marker: 2);
      final renamed = _apply(created, rename);
      await rooms.commitTransition(
        expectedPrevious: created,
        next: renamed,
        prepared: PreparedRoomTransition(controls: [rename]),
      );
      expect(await due(), isEmpty);

      final add = await signRoomEvent(
        signerUserId: roomAlice,
        signerDeviceId: roomAlicePhone,
        roomId: _roomId,
        revision: 3,
        previous: rename,
        operation: AddRoomMembersOperation([roomDave]),
        eventMarker: 4,
      );
      await rooms.commitTransition(
        expectedPrevious: renamed,
        next: _apply(renamed, add),
        prepared: PreparedRoomTransition(controls: [add]),
      );

      final check = (await due()).single;
      expect(check.followsAcceptedChange, isTrue);
      expect(check.controlRevision, 3);
    });

    test('a check read before a change leaves the room due', () async {
      final stale = (await due()).single;
      final add = await signRoomEvent(
        signerUserId: roomAlice,
        signerDeviceId: roomAlicePhone,
        roomId: _roomId,
        revision: 2,
        previous: create,
        operation: AddRoomMembersOperation([roomDave]),
        eventMarker: 5,
      );
      await rooms.commitTransition(
        expectedPrevious: created,
        next: _apply(created, add),
        prepared: PreparedRoomTransition(controls: [add]),
      );

      await rooms.recordSessionCheck(
        check: stale,
        work: const [],
        checkedAt: now,
      );

      final check = (await due()).single;
      expect(check.followsAcceptedChange, isTrue);
      expect(check.controlRevision, 2);
    });

    test('a room waiting on its state or not active is not due', () async {
      await rooms.openStateRequest(roomId: _roomId, peerUserId: roomAlice);
      expect(await due(), isEmpty);
      await rooms.retireStateRequest(_roomId);
      expect(await due(), hasLength(1));

      await (database.update(
        database.roomStates,
      )).write(RoomStatesCompanion(lifecycle: Value(RoomLifecycle.left.index)));
      expect(await due(), isEmpty);
    });
  });

  test('a stored transcript that does not chain is never handed out', () async {
    await (database.update(
      database.roomControlEvents,
    )).write(const RoomControlEventsCompanion(revision: Value(2)));

    expect(
      (await rooms.readTranscript(_roomId) as FailureResult).failure,
      const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );
  });
}

Future<SignedRoomControlEvent> _create(String roomId) => signRoomEvent(
  signerUserId: roomAlice,
  signerDeviceId: roomAlicePhone,
  roomId: roomId,
  revision: 1,
  previous: null,
  operation: CreateRoomOperation(
    name: 'Standup',
    memberUserIds: [roomAlice, roomBob, roomCarol],
  ),
  eventMarker: 1,
);

Future<SignedRoomControlEvent> _rename(
  SignedRoomControlEvent previous,
  String name, {
  required int marker,
}) => signRoomEvent(
  signerUserId: roomBob,
  signerDeviceId: roomBobPhone,
  roomId: previous.event.roomId,
  revision: previous.event.revision + 1,
  previous: previous,
  operation: RenameRoomOperation(name),
  eventMarker: marker,
);

RoomState _apply(
  RoomState? previous,
  SignedRoomControlEvent signed, {
  String localUserId = roomBob,
}) =>
    (_machine.apply(
              previous: previous,
              signedControl: signed,
              localUserId: localUserId,
            )
            as RoomControlAccepted)
        .state;
