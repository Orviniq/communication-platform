import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/voice/application/room_inbound_coordinator.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

final _roomId = 'ab' * 32;
const _envelope = '90000000-0000-4000-8000-000000000001';

/// Bob's phone receiving room payloads from the other members' devices.
void main() {
  late LocalDatabase database;
  late DriftRoomRepository rooms;
  late FakeRoomLiveDevices devices;
  late RoomInboundCoordinator coordinator;
  late SignedRoomControlEvent create;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    rooms = DriftRoomRepository(database);
    devices = FakeRoomLiveDevices({
      roomAlice: [roomAlicePhone],
      roomBob: [roomBobPhone],
      roomCarol: [roomCarolPhone],
      roomDave: [roomDavePhone],
    });
    coordinator = RoomInboundCoordinator(
      repository: rooms,
      crypto: FakeRoomControlCore(localDeviceId: roomBobPhone),
      liveDevices: devices,
      clock: FakeRoomClock(),
      localUserId: roomBob,
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
  });

  tearDown(() => database.close());

  Future<Result<RoomInboundPreparation>> receive(
    RoomSyncPayload payload, {
    String from = roomAlice,
    String fromDevice = roomAlicePhone,
    String envelopeId = _envelope,
  }) => coordinator.prepare(
    envelopeId: envelopeId,
    senderUserId: from,
    senderDeviceId: fromDevice,
    payload: RoomSyncPayloadCodec.encode(payload),
  );

  /// Commits a prepared change the way the sync store does, inside one
  /// transaction.
  Future<void> commit(Result<RoomInboundPreparation> prepared) async {
    final change =
        (prepared as Success<RoomInboundPreparation>).value
            as RoomInboundChange;
    await database.transaction(
      () => switch (change.commit) {
        PreparedRoomInboxTransition(
          :final expectedPrevious,
          :final next,
          :final prepared,
        ) =>
          rooms.commitTransitionInsideTransaction(
            expectedPrevious: expectedPrevious,
            next: next,
            prepared: prepared,
          ),
        PreparedRoomInboxQuarantine(
          :final record,
          :final retainLifecycle,
          :final completesStateRequest,
        ) =>
          rooms.quarantineInsideTransaction(
            record,
            retainLifecycle: retainLifecycle,
            completesStateRequest: completesStateRequest,
          ),
        PreparedRoomInboxStateRequest(:final roomId, :final peerUserId) =>
          rooms.recordStateRequestInsideTransaction(
            roomId: roomId,
            peerUserId: peerUserId,
          ),
        PreparedRoomInboxOutbound(:final work) =>
          rooms.queueOutboundInsideTransaction(work),
        PreparedRoomInboxStateCurrent(
          :final roomId,
          :final controlRevision,
          :final controlStateHash,
        ) =>
          rooms.confirmStateCurrentInsideTransaction(
            roomId: roomId,
            controlRevision: controlRevision,
            controlStateHash: controlStateHash,
          ),
      },
    );
  }

  Future<RoomState> stored() async =>
      (await rooms.readStoredRoom(_roomId) as Success<RoomState?>).value!;

  Future<SignedRoomControlEvent> next(
    SignedRoomControlEvent previous,
    RoomControlOperation operation, {
    String signer = roomAlice,
    String signerDevice = roomAlicePhone,
    int? marker,
  }) => signRoomEvent(
    signerUserId: signer,
    signerDeviceId: signerDevice,
    roomId: _roomId,
    revision: previous.event.revision + 1,
    previous: previous,
    operation: operation,
    eventMarker: marker ?? previous.event.revision + 1,
  );

  RoomControlDelivery delivery(SignedRoomControlEvent signed) =>
      RoomControlDelivery(RoomSignedControlBytes.fromSigned(signed));

  test('an event with a bad signature is refused', () async {
    final tampered = Uint8List.fromList(create.canonicalBytes)..[20] ^= 0x01;
    final forged = Uint8List.fromList(create.signature)..[0] ^= 0x01;
    final byAnotherDevice = RoomSignedControlBytes(
      signerUserId: roomAlice,
      signerDeviceId: roomAlicePhone,
      canonicalBytes: create.canonicalBytes,
      // Carol's device signed these bytes, and they claim Alice's.
      signature: fakeRoomSignature(
        roomDeviceKey(roomCarolPhone),
        create.canonicalBytes,
      ),
    );

    for (final control in [
      RoomSignedControlBytes(
        signerUserId: roomAlice,
        signerDeviceId: roomAlicePhone,
        canonicalBytes: tampered,
        signature: create.signature,
      ),
      RoomSignedControlBytes(
        signerUserId: roomAlice,
        signerDeviceId: roomAlicePhone,
        canonicalBytes: create.canonicalBytes,
        signature: forged,
      ),
      byAnotherDevice,
    ]) {
      final result = await receive(RoomControlDelivery(control));
      expect(
        (result as FailureResult<RoomInboundPreparation>).failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    // Inside a transcript the same bytes are refused the same way.
    final inTranscript = await receive(
      RoomTranscriptPayload(
        roomId: _roomId,
        baseRevision: 0,
        baseStateHash: null,
        entries: [byAnotherDevice],
      ),
    );
    expect(inTranscript, isA<FailureResult<RoomInboundPreparation>>());
    expect(await database.select(database.roomStates).get(), isEmpty);
  });

  test(
    'an event from a device not in its account\'s list is refused',
    () async {
      devices.devicesByUser[roomAlice] = [roomAliceTablet];

      expect(
        ((await receive(delivery(create)))
                as FailureResult<RoomInboundPreparation>)
            .failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    },
  );

  test('a delivery comes only from the device that signed it', () async {
    expect(
      ((await receive(
                delivery(create),
                from: roomCarol,
                fromDevice: roomCarolPhone,
              ))
              as FailureResult<RoomInboundPreparation>)
          .failure,
      const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );
  });

  test('a create is taken by a member and ignored by anybody else', () async {
    final prepared = await receive(delivery(create));
    await commit(prepared);
    expect((await stored()).isActiveMember(roomBob), isTrue);

    final outsider = RoomInboundCoordinator(
      repository: DriftRoomRepository(LocalDatabase(NativeDatabase.memory())),
      crypto: FakeRoomControlCore(localDeviceId: roomDavePhone),
      liveDevices: devices,
      clock: FakeRoomClock(),
      localUserId: roomDave,
    );
    final ignored = await outsider.prepare(
      envelopeId: _envelope,
      senderUserId: roomAlice,
      senderDeviceId: roomAlicePhone,
      payload: RoomSyncPayloadCodec.encode(delivery(create)),
    );
    expect(
      (ignored as Success<RoomInboundPreparation>).value,
      isA<RoomInboundNoChange>(),
    );
  });

  test('an event past a gap asks its sender for the room', () async {
    await commit(await receive(delivery(create)));
    final rename = await next(create, const RenameRoomOperation('Daily'));
    final add = await next(rename, AddRoomMembersOperation([roomDave]));

    final prepared = await receive(delivery(add));

    final change =
        (prepared as Success<RoomInboundPreparation>).value
            as RoomInboundChange;
    expect(
      change.commit,
      isA<PreparedRoomInboxStateRequest>().having(
        (commit) => commit.peerUserId,
        'peer',
        roomAlice,
      ),
    );
  });

  test(
    'a removal takes the member out, and their later events are refused',
    () async {
      await commit(await receive(delivery(create)));
      final removal = await next(create, RemoveRoomMemberOperation(roomCarol));
      await commit(await receive(delivery(removal)));
      expect((await stored()).isActiveMember(roomCarol), isFalse);

      // Carol signs as though she were still in the room.
      final late = await next(
        removal,
        const RenameRoomOperation('Still here'),
        signer: roomCarol,
        signerDevice: roomCarolPhone,
      );
      final prepared = await receive(
        delivery(late),
        from: roomCarol,
        fromDevice: roomCarolPhone,
      );
      final change =
          (prepared as Success<RoomInboundPreparation>).value
              as RoomInboundChange;
      expect(
        change.commit,
        isA<PreparedRoomInboxQuarantine>()
            .having(
              (commit) => commit.record.reason,
              'reason',
              RoomQuarantineReason.unauthorizedControl,
            )
            .having((commit) => commit.retainLifecycle, 'retained', isTrue),
      );
      await commit(prepared);
      final room = await stored();
      expect(room.name, 'Standup');
      expect(room.controlRevision, 2);
      expect(room.lifecycle, RoomLifecycle.active);

      // Nor is she told anything about the room from here on.
      final asked = await receive(
        RoomStateRequestPayload(
          roomId: _roomId,
          haveRevision: 1,
          haveStateHash: create.controlStateHash,
        ),
        from: roomCarol,
        fromDevice: roomCarolPhone,
      );
      expect(
        (asked as Success<RoomInboundPreparation>).value,
        isA<RoomInboundNoChange>(),
      );
    },
  );

  test('two events at one revision quarantine the room', () async {
    await commit(await receive(delivery(create)));
    await commit(
      await receive(
        delivery(await next(create, const RenameRoomOperation('A'))),
      ),
    );
    final sibling = await next(
      create,
      const RenameRoomOperation('B'),
      signer: roomCarol,
      signerDevice: roomCarolPhone,
      marker: 40,
    );

    await commit(
      await receive(
        delivery(sibling),
        from: roomCarol,
        fromDevice: roomCarolPhone,
      ),
    );

    expect((await stored()).lifecycle, RoomLifecycle.forkQuarantined);
  });

  group('state requests', () {
    Future<RoomSyncPayload> answerTo(RoomStateRequestPayload request) async {
      final prepared = await receive(
        request,
        from: roomCarol,
        fromDevice: roomCarolPhone,
      );
      final change =
          (prepared as Success<RoomInboundPreparation>).value
              as RoomInboundChange;
      final work = (change.commit as PreparedRoomInboxOutbound).work;
      expect(work.recipientUserIds, [roomCarol]);
      expect(work.recipientDeviceId, roomCarolPhone);
      return RoomSyncPayloadCodec.decode(work.payload);
    }

    test('an active member is told what came after its state', () async {
      await commit(await receive(delivery(create)));
      final rename = await next(create, const RenameRoomOperation('Daily'));
      await commit(await receive(delivery(rename)));

      final behind =
          await answerTo(
                RoomStateRequestPayload(
                  roomId: _roomId,
                  haveRevision: 1,
                  haveStateHash: create.controlStateHash,
                ),
              )
              as RoomTranscriptPayload;
      expect(behind.baseRevision, 1);
      expect(behind.entries, hasLength(1));

      final current =
          await answerTo(
                RoomStateRequestPayload(
                  roomId: _roomId,
                  haveRevision: 2,
                  haveStateHash: rename.controlStateHash,
                ),
              )
              as RoomTranscriptPayload;
      expect(current.entries, isEmpty);

      final forked =
          await answerTo(
                RoomStateRequestPayload(
                  roomId: _roomId,
                  haveRevision: 1,
                  haveStateHash: 'ee' * 32,
                ),
              )
              as RoomTranscriptPayload;
      expect(forked.baseRevision, 0);
      expect(forked.entries, hasLength(2));
    });

    test('a request for a room this device does not hold asks back', () async {
      // How a member's new device learns its rooms: a member device starts
      // a session with it by asking, and it asks back.
      final prepared = await receive(
        RoomStateRequestPayload(
          roomId: _roomId,
          haveRevision: 1,
          haveStateHash: create.controlStateHash,
        ),
      );
      final change =
          (prepared as Success<RoomInboundPreparation>).value
              as RoomInboundChange;
      expect(
        change.commit,
        isA<PreparedRoomInboxStateRequest>()
            .having((commit) => commit.roomId, 'room', _roomId)
            .having((commit) => commit.peerUserId, 'peer', roomAlice),
      );
      await commit(prepared);
      expect(
        (await database.select(database.roomStateRequests).getSingle()).reason,
        1,
      );
    });

    test('a request naming a later state asks back', () async {
      await commit(await receive(delivery(create)));

      final prepared = await receive(
        RoomStateRequestPayload(
          roomId: _roomId,
          haveRevision: 3,
          haveStateHash: 'aa' * 32,
        ),
        from: roomCarol,
        fromDevice: roomCarolPhone,
      );

      expect(
        ((prepared as Success<RoomInboundPreparation>).value
                as RoomInboundChange)
            .commit,
        isA<PreparedRoomInboxStateRequest>().having(
          (commit) => commit.peerUserId,
          'peer',
          roomCarol,
        ),
      );
    });

    test('a device outside the room is told nothing', () async {
      await commit(await receive(delivery(create)));

      final prepared = await receive(
        RoomStateRequestPayload(
          roomId: _roomId,
          haveRevision: 0,
          haveStateHash: null,
        ),
        from: roomDave,
        fromDevice: roomDavePhone,
      );

      expect(
        (prepared as Success<RoomInboundPreparation>).value,
        isA<RoomInboundNoChange>(),
      );
    });
  });

  group('transcripts', () {
    RoomTranscriptPayload whole(List<SignedRoomControlEvent> events) =>
        RoomTranscriptPayload(
          roomId: _roomId,
          baseRevision: 0,
          baseStateHash: null,
          entries: events.map(RoomSignedControlBytes.fromSigned),
        );

    test('a transcript gives a member the room, from a member only', () async {
      final removal = await next(create, RemoveRoomMemberOperation(roomCarol));

      // Carol hands over the room as it stood after her own removal.
      final fromRemoved = await receive(
        whole([create, removal]),
        from: roomCarol,
        fromDevice: roomCarolPhone,
      );
      expect(
        (fromRemoved as Success<RoomInboundPreparation>).value,
        isA<RoomInboundNoChange>(),
      );

      final prepared = await receive(whole([create, removal]));
      await commit(prepared);
      final room = await stored();
      expect(room.controlRevision, 2);
      expect(room.isActiveMember(roomBob), isTrue);
    });

    test('only a sender holding exactly this state confirms it', () async {
      await commit(await receive(delivery(create)));
      final rename = await next(create, const RenameRoomOperation('Daily'));
      await commit(await receive(delivery(rename)));
      await rooms.openStateRequest(roomId: _roomId, peerUserId: roomAlice);

      // A copy from a member who is itself behind retires nothing.
      final stale = await receive(whole([create]));
      expect(
        (stale as Success<RoomInboundPreparation>).value,
        isA<RoomInboundNoChange>(),
      );
      expect(
        await database.select(database.roomStateRequests).get(),
        isNotEmpty,
      );

      final exact = await receive(whole([create, rename]));
      expect(
        ((exact as Success<RoomInboundPreparation>).value as RoomInboundChange)
            .commit,
        isA<PreparedRoomInboxStateCurrent>(),
      );
      await commit(exact);
      expect(await database.select(database.roomStateRequests).get(), isEmpty);
    });

    test('a transcript that carries this device further applies it', () async {
      await commit(await receive(delivery(create)));
      final rename = await next(create, const RenameRoomOperation('Daily'));
      final add = await next(rename, AddRoomMembersOperation([roomDave]));

      await commit(await receive(whole([create, rename, add])));

      final room = await stored();
      expect(room.controlRevision, 3);
      expect(room.name, 'Daily');
      expect(room.isActiveMember(roomDave), isTrue);
    });
  });
}
