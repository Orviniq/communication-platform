import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/application/room_call_sessions.dart';
import 'package:communication_platform/features/voice/application/room_outbound_dispatcher.dart';
import 'package:communication_platform/features/voice/application/room_session_starter.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

final _roomId = 'ab' * 32;

void main() {
  late LocalDatabase database;
  late DriftRoomRepository rooms;
  late FakeRoomSessions sessions;
  late _RecordingEnvelopes envelopes;
  late RoomCallSessions preparation;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    rooms = DriftRoomRepository(database);
    sessions = FakeRoomSessions();
    envelopes = _RecordingEnvelopes();
    preparation = RoomCallSessions(
      starter: RoomSessionStarter(
        repository: rooms,
        liveDevices: FakeRoomLiveDevices({
          roomAlice: [roomAlicePhone, roomAliceTablet],
          roomBob: [roomBobPhone],
          roomCarol: [roomCarolPhone],
        }),
        sessions: sessions,
        clock: FakeRoomClock(),
        currentUserId: roomBob,
        currentDeviceId: roomBobPhone,
      ),
      dispatcher: RoomOutboundDispatcher(
        repository: rooms,
        envelopes: envelopes,
      ),
      currentUserId: roomBob,
      currentDeviceId: roomBobPhone,
    );
  });

  tearDown(() => database.close());

  test('the check before a join starts every missing session and routes '
      'its requests into the pairwise outbox', () async {
    final create = await signRoomEvent(
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
    // Alice's phone started its session with Bob's when it sent the create.
    sessions.establish(roomBobPhone, roomAlicePhone);

    final prepared = await preparation.prepareSessionsForCall(_roomId);

    expect(prepared, isA<Success<void>>());
    // Whichever id sorts lower: the call's check starts every one.
    expect([
      for (final queued in envelopes.queued) queued.onlyRecipientDeviceId,
    ], unorderedEquals([roomAliceTablet, roomCarolPhone]));
    final pending = await rooms.readPendingOutbound();
    expect((pending as Success<List<RoomOutboundWork>>).value, isEmpty);
  });

  test('a room this device may not call in starts nothing', () async {
    final prepared = await preparation.prepareSessionsForCall(_roomId);

    expect(
      prepared,
      isA<FailureResult<void>>().having(
        (result) => result.failure,
        'failure',
        const SecurityFailure(SecurityFailureKind.policyBlocked),
      ),
    );
    expect(envelopes.queued, isEmpty);
  });
}

final class _Queued {
  const _Queued(this.targetUserId, this.onlyRecipientDeviceId);

  final String targetUserId;
  final String? onlyRecipientDeviceId;
}

final class _RecordingEnvelopes implements RoomOutboundEnvelopePort {
  final queued = <_Queued>[];

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
    queued.add(_Queued(targetUserId, onlyRecipientDeviceId));
    return const Result.success(null);
  }
}
