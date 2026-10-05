import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LocalDatabase database;
  late DriftPairwiseTransportStore store;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    store = DriftPairwiseTransportStore(database);
    await database
        .into(database.secureSecrets)
        .insert(
          SecureSecretsCompanion.insert(
            secretId: 'current-device-key-state-v1',
            kind: 0,
            wrappedCiphertextOrOpaqueHandle: bytes(8, 1),
            formatVersion: 2,
          ),
        );
  });

  tearDown(() => database.close());

  group('a volatile seal', () {
    test(
      'advances every session in one commit and writes no outbox row',
      () async {
        await seedSession(database, 1);
        await seedSession(database, 2);

        final committed = await store.commitVolatileSeal(
          sealCommit([advance(1, from: 1), advance(2, from: 1)]),
        );

        expect(committed, isA<Success<void>>());
        final sessions = await sessionsByDevice(database);
        expect(sessions[uuid(1)]!.stateVersion, 2);
        expect(sessions[uuid(2)]!.stateVersion, 2);
        expect(sessions[uuid(1)]!.opaqueCryptoStateHandle, bytes(32, 0x81));
        expect(await database.select(database.outboxOperations).get(), isEmpty);
        expect(
          await database.select(database.pairwiseLocalApplications).get(),
          isEmpty,
        );
        expect(
          await database.select(database.pendingSendPreparations).get(),
          isEmpty,
        );
      },
    );

    test('one stale revision commits nothing at all', () async {
      await seedSession(database, 1);
      await seedSession(database, 2, stateVersion: 3);

      final committed = await store.commitVolatileSeal(
        sealCommit([advance(1, from: 1), advance(2, from: 1)]),
      );

      expect(
        (committed as FailureResult<void>).failure,
        isA<ValidationFailure>().having(
          (failure) => failure.kind,
          'kind',
          ValidationFailureKind.conflict,
        ),
      );
      final sessions = await sessionsByDevice(database);
      expect(sessions[uuid(1)]!.stateVersion, 1);
      expect(sessions[uuid(1)]!.opaqueCryptoStateHandle, bytes(32, 1));
      expect(sessions[uuid(2)]!.stateVersion, 3);
    });

    test('a device state that moved commits nothing', () async {
      await seedSession(database, 1);

      final committed = await store.commitVolatileSeal(
        sealCommit([advance(1, from: 1)], expectedDeviceStateVersion: 2),
      );

      expect(committed, isA<FailureResult<void>>());
      expect((await sessionsByDevice(database))[uuid(1)]!.stateVersion, 1);
    });

    test('never starts, repairs or duplicates a session', () async {
      await seedSession(database, 1);
      final refused = <String, PairwiseVolatileSealCommit>{
        'a new session': sealCommit([advance(1, from: null)]),
        'a repair request': sealCommit([
          advance(
            1,
            from: 1,
            repairState: PairwiseRepairState.authenticatedRequestPending,
          ),
        ]),
        'a receive-only session': sealCommit([
          advance(
            1,
            from: 1,
            disposition: PairwiseSessionDisposition.alternateReceiveOnly,
          ),
        ]),
        'this device itself': sealCommit([advance(900, from: 1)]),
        'one device twice': sealCommit([
          advance(1, from: 1),
          advance(1, from: 1),
        ]),
        'nobody': sealCommit(const []),
      };
      for (final entry in refused.entries) {
        final committed = await store.commitVolatileSeal(entry.value);
        expect(
          (committed as FailureResult<void>).failure,
          isA<ValidationFailure>().having(
            (failure) => failure.kind,
            'kind',
            ValidationFailureKind.invalidInput,
          ),
          reason: entry.key,
        );
      }
      final sessions = await database.select(database.pairwiseSessions).get();
      expect(sessions.single.stateVersion, 1);
    });
  });

  group('a volatile open', () {
    test('advances its session and writes no inbox row', () async {
      await seedSession(database, 5);

      final committed = await store.commitVolatileOpen(
        PairwiseVolatileOpenCommit(sessionTransition: advance(5, from: 1)),
      );

      expect(committed, isA<Success<void>>());
      expect((await sessionsByDevice(database))[uuid(5)]!.stateVersion, 2);
      await expectNoInboxRows(database);
      expect(
        await database.select(database.pairwiseReplayMarkers).get(),
        isEmpty,
        reason: 'the ratchet refuses a reused message number by itself',
      );
    });

    test('an initial one writes the session, the device state, the prekeys '
        'it consumed and its marker, and nothing else', () async {
      for (final (kind, keyId) in const [(1, 7), (3, 8)]) {
        await database
            .into(database.prekeys)
            .insert(
              PrekeysCompanion.insert(
                kind: kind,
                keyId: keyId,
                privateStateHandle: bytes(8, keyId),
                uploadState: 0,
                useState: 0,
              ),
            );
      }
      final commit = initialCommit();

      final committed = await store.commitVolatileOpen(commit);

      expect(committed, isA<Success<void>>());
      final session = (await sessionsByDevice(database))[uuid(6)]!;
      expect(session.stateVersion, 1);
      expect(session.sessionId, sessionId(6));
      final secret = await database.select(database.secureSecrets).getSingle();
      expect(secret.stateRevision, 2);
      expect(secret.wrappedCiphertextOrOpaqueHandle, bytes(8, 2));
      expect(await database.select(database.prekeys).get(), isEmpty);
      final tombstones = await database
          .select(database.pairwiseConsumedPrekeys)
          .get();
      expect(tombstones.map((row) => row.keyId).toSet(), {7, 8});
      expect(
        tombstones.every(
          (row) =>
              row.firstEnvelopeId == DriftPairwiseTransportStore.volatileOrigin,
        ),
        isTrue,
      );
      final marker = await database
          .select(database.pairwiseReplayMarkers)
          .getSingle();
      expect(marker.replayMarker, bytes(32, 0x99));
      expect(marker.signedPrekeyId, 3);
      expect(marker.pqSignedPrekeyId, 4);
      await expectNoInboxRows(database);

      final replayed = await store.commitVolatileOpen(commit);
      expect(
        (replayed as FailureResult<void>).failure,
        isA<SecurityFailure>().having(
          (failure) => failure.kind,
          'kind',
          SecurityFailureKind.integrityCheckFailed,
        ),
      );
      expect(
        (await database.select(database.secureSecrets).getSingle())
            .stateRevision,
        2,
        reason: 'a replay changes nothing',
      );
    });

    test('a regular one carries nothing an initial one does', () async {
      await seedSession(database, 5);

      final committed = await store.commitVolatileOpen(
        PairwiseVolatileOpenCommit(
          sessionTransition: advance(5, from: 1),
          replayMarker: bytes(32, 0x99),
        ),
      );

      expect(committed, isA<FailureResult<void>>());
      expect((await sessionsByDevice(database))[uuid(5)]!.stateVersion, 1);
    });
  });
}

PairwiseVolatileSealCommit sealCommit(
  List<PairwiseSessionTransition> transitions, {
  int expectedDeviceStateVersion = 1,
}) => PairwiseVolatileSealCommit(
  currentDeviceId: uuid(900),
  expectedDeviceStateVersion: expectedDeviceStateVersion,
  transitions: transitions,
);

PairwiseSessionTransition advance(
  int device, {
  required int? from,
  PairwiseRepairState repairState = PairwiseRepairState.ready,
  PairwiseSessionDisposition disposition =
      PairwiseSessionDisposition.primaryBidirectional,
}) => PairwiseSessionTransition(
  localDeviceId: uuid(900),
  remoteUserId: 'peer-user',
  remoteDeviceId: uuid(device),
  sessionId: sessionId(device),
  nextOpaqueState: bytes(32, 0x80 + device),
  expectedStateVersion: from,
  nextStateVersion: (from ?? 0) + 1,
  nextSkippedKeyCount: 0,
  disposition: disposition,
  repairState: repairState,
);

PairwiseVolatileOpenCommit initialCommit() => PairwiseVolatileOpenCommit(
  sessionTransition: advance(6, from: null),
  deviceStateTransition: PairwiseDeviceStateTransition(
    nextOpaqueState: bytes(8, 2),
    expectedStateVersion: 1,
    nextStateVersion: 2,
  ),
  consumedOneTimePrekeys: const [
    ConsumedPairwiseOneTimePrekey(
      kind: PairwiseOneTimePrekeyKind.classicalX25519,
      keyId: 7,
    ),
    ConsumedPairwiseOneTimePrekey(
      kind: PairwiseOneTimePrekeyKind.postQuantumMlKem768,
      keyId: 8,
    ),
  ],
  replayMarker: bytes(32, 0x99),
  signedPrekeyId: 3,
  pqSignedPrekeyId: 4,
);

Future<void> seedSession(
  LocalDatabase database,
  int device, {
  int stateVersion = 1,
}) => database
    .into(database.pairwiseSessions)
    .insert(
      PairwiseSessionsCompanion.insert(
        localDeviceId: uuid(900),
        remoteUserId: const Value('peer-user'),
        remoteDeviceId: uuid(device),
        sessionId: Value(sessionId(device)),
        opaqueCryptoStateHandle: bytes(32, 1),
        stateVersion: stateVersion,
      ),
    );

Future<Map<String, PairwiseSession>> sessionsByDevice(
  LocalDatabase database,
) async => {
  for (final row in await database.select(database.pairwiseSessions).get())
    row.remoteDeviceId: row,
};

Future<void> expectNoInboxRows(LocalDatabase database) async {
  expect(await database.select(database.inboxEnvelopes).get(), isEmpty);
  expect(await database.select(database.pairwiseOpenedPayloads).get(), isEmpty);
  expect(
    await database.select(database.inboxEventDeduplications).get(),
    isEmpty,
  );
}

String uuid(int value) =>
    '00000000-0000-0000-0000-${value.toRadixString(16).padLeft(12, '0')}';

Uint8List sessionId(int marker) => bytes(16, marker);

Uint8List bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker & 0xff));
