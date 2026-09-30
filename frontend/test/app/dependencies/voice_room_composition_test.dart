import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/voice/support/room_fakes.dart';

/// The application layer reads a room through one read port and its streams,
/// projected from the database the delivery cycle writes.
void main() {
  late LocalDatabase database;
  late ProviderContainer container;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        localDatabaseProvider.overrideWith((ref) => Future.value(database)),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('the read port is the stored rooms, and nothing that writes', () async {
    final port = await container.read(roomStateReadPortProvider.future);

    expect(port, isA<RoomStateReadPort>());
    expect(port, isA<DriftRoomRepository>());
  });

  test('the room streams follow what the delivery cycle commits', () async {
    final roomId = 'ab' * 32;
    final rooms = <List<RoomState>>[];
    final room = <RoomState?>[];
    final listSubscription = container.listen(
      voiceRoomsProvider,
      (_, next) => next.whenData(rooms.add),
    );
    final roomSubscription = container.listen(
      voiceRoomProvider(roomId),
      (_, next) => next.whenData(room.add),
    );
    addTearDown(listSubscription.close);
    addTearDown(roomSubscription.close);
    await _settle();

    final create = await signRoomEvent(
      signerUserId: roomAlice,
      signerDeviceId: roomAlicePhone,
      roomId: roomId,
      revision: 1,
      previous: null,
      operation: CreateRoomOperation(
        name: 'Standup',
        memberUserIds: [roomAlice, roomBob],
      ),
      eventMarker: 1,
    );
    final created =
        (const RoomControlStateMachine().apply(
                  previous: null,
                  signedControl: create,
                  localUserId: roomBob,
                )
                as RoomControlAccepted)
            .state;
    await DriftRoomRepository(database).commitTransition(
      expectedPrevious: null,
      next: created,
      prepared: PreparedRoomTransition(controls: [create]),
    );
    await _settle();
    await DriftRoomRepository(
      database,
    ).openStateRequest(roomId: roomId, peerUserId: roomAlice);
    await _settle();

    expect(rooms.first, isEmpty);
    expect(rooms.last.single.roomId, roomId);
    expect(room.first, isNull);
    expect(
      room.map((value) => value?.lifecycle),
      containsAllInOrder([
        null,
        RoomLifecycle.active,
        RoomLifecycle.stateRecoveryRequired,
      ]),
    );
  });
}

Future<void> _settle() async {
  for (var turn = 0; turn < 20; turn += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
