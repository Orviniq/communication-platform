import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/device_control_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
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

  test(
    'send commits CAS states, exact targets, and local marker atomically',
    () async {
      final commit = sendCommit(targets: [2, 1]);

      final first = await store.commitPreparedSend(commit);
      final retry = await store.commitPreparedSend(commit);

      expect(first, isA<Success<void>>());
      expect(retry, isA<Success<void>>());
      final sessions = await database.select(database.pairwiseSessions).get();
      expect(sessions, hasLength(2));
      expect(sessions.every((row) => row.stateVersion == 1), isTrue);
      final outbox = await (database.select(
        database.outboxOperations,
      )..orderBy([(row) => OrderingTerm.asc(row.recipientDeviceId)])).get();
      expect(outbox.map((row) => row.recipientDeviceId), [uuid(1), uuid(2)]);
      expect(outbox[0].exactRecipientCiphertext, envelope(1));
      expect(outbox[1].exactRecipientCiphertext, envelope(2));
      expect(
        await database.select(database.pairwiseLocalApplications).get(),
        hasLength(1),
      );

      final changed = sendCommit(targets: [2, 1], ciphertextOffset: 10);
      final conflict = await store.commitPreparedSend(changed);
      expect(
        (conflict as FailureResult<void>).failure,
        isA<ValidationFailure>(),
      );
      expect(
        await database.select(database.pairwiseSessions).get(),
        hasLength(2),
      );
    },
  );

  test(
    'optimistic transport state never turns relay acceptance into delivery',
    () async {
      final application = applicationCommit(
        eventNumber: 12,
        senderUserNumber: 1000,
        senderDeviceNumber: 900,
        localOrigin: true,
        peerUserNumber: 1001,
      );
      final echoed = await store.commitLocalEcho(
        operationId: 'pairwise-operation',
        eventId: protocolBytesToHex(application.event.eventId),
        currentUserId: uuid(1000),
        currentDeviceId: uuid(900),
        peerUserId: uuid(1001),
        openedLocalPayload: application.canonicalBytes,
        applicationEvent: application,
      );
      expect(echoed, isA<Success<void>>());
      var message = await database.select(database.messages).getSingle();
      expect(message.status, MessageTransportState.preparing.index);

      final committed = await store.commitPreparedSend(
        sendCommit(targets: [12], applicationEvent: application),
      );
      expect(committed, isA<Success<void>>());
      expect(
        await database.select(database.pendingSendPreparations).get(),
        isEmpty,
      );
      message = await database.select(database.messages).getSingle();
      expect(message.status, MessageTransportState.queued.index);

      final sync = DriftSyncStore(database);
      final batchResult = await sync.beginNextOutboxBatch(
        now: DateTime.utc(2026, 7, 29),
      );
      final batch = (batchResult as Success<OutboxBatch?>).value!;
      message = await database.select(database.messages).getSingle();
      expect(message.status, MessageTransportState.sending.index);

      await sync.recordOutboxAcceptance(
        batch: batch,
        acceptance: OutboxAcceptance(accepted: 1, staleDeviceIds: {}),
        now: DateTime.utc(2026, 7, 29, 0, 1),
        retryFullAt: DateTime.utc(2026, 7, 29, 1),
      );
      message = await database.select(database.messages).getSingle();
      expect(message.status, MessageTransportState.relayAccepted.index);
      expect(await database.select(database.receipts).get(), isEmpty);
    },
  );

  test(
    'a retry re-arms the message that failed, and writes no second one',
    () async {
      final application = applicationCommit(
        eventNumber: 13,
        senderUserNumber: 1000,
        senderDeviceNumber: 900,
        localOrigin: true,
        peerUserNumber: 1001,
      );
      final eventId = protocolBytesToHex(application.event.eventId);
      await store.commitLocalEcho(
        operationId: 'pairwise-operation',
        eventId: eventId,
        currentUserId: uuid(1000),
        currentDeviceId: uuid(900),
        peerUserId: uuid(1001),
        openedLocalPayload: application.canonicalBytes,
        applicationEvent: application,
      );
      final sync = DriftSyncStore(database);
      final owed = (await sync.beginNextSendPreparation(
        now: DateTime.utc(2026),
      )).fold(onSuccess: (work) => work, onFailure: (_) => null);
      await sync.recordSendPreparationFailure(preparation: owed!);
      expect(
        (await database.select(database.messages).getSingle()).status,
        MessageTransportState.permanentlyFailed.index,
      );

      final rearmed = await store.rearmFailedSend('pairwise-operation');

      expect((rearmed as Success<bool>).value, isTrue);
      // One message, back in the state that says it is on its way. A retry that
      // sent the text again would have left the failed row on screen and put a
      // second bubble beside it.
      expect(await database.select(database.messages).get(), hasLength(1));
      expect(
        (await database.select(database.messages).getSingle()).status,
        MessageTransportState.preparing.index,
      );
      final row = await database
          .select(database.pendingSendPreparations)
          .getSingle();
      expect(row.state, 0);
      expect(row.attemptCount, 0);
      expect(row.nextAttemptAt, isNull);
    },
  );

  test('a retry re-arms ciphertext the relay refused for good', () async {
    final application = applicationCommit(
      eventNumber: 14,
      senderUserNumber: 1000,
      senderDeviceNumber: 900,
      localOrigin: true,
      peerUserNumber: 1001,
    );
    await store.commitLocalEcho(
      operationId: 'pairwise-operation',
      eventId: protocolBytesToHex(application.event.eventId),
      currentUserId: uuid(1000),
      currentDeviceId: uuid(900),
      peerUserId: uuid(1001),
      openedLocalPayload: application.canonicalBytes,
      applicationEvent: application,
    );
    await store.commitPreparedSend(
      sendCommit(targets: [14], applicationEvent: application),
    );
    final sync = DriftSyncStore(database);
    final batch = (await sync.beginNextOutboxBatch(
      now: DateTime.utc(2026),
    )).fold(onSuccess: (batch) => batch, onFailure: (_) => null);
    await sync.recordOutboxPermanentFailure(
      batch: batch!,
      now: DateTime.utc(2026, 1, 2),
    );
    expect(
      (await database.select(database.messages).getSingle()).status,
      MessageTransportState.permanentlyFailed.index,
    );

    final rearmed = await store.rearmFailedSend('pairwise-operation');

    expect((rearmed as Success<bool>).value, isTrue);
    expect(await database.select(database.messages).get(), hasLength(1));
    expect(
      (await database.select(database.messages).getSingle()).status,
      MessageTransportState.queued.index,
    );
    final outbox = await database.select(database.outboxOperations).getSingle();
    expect(outbox.attemptState, OutboxAttemptState.queued.index);
    expect(outbox.attemptCount, 0);
    expect(outbox.terminalAt, isNull);
  });

  test('retention never discards the payload of a send still owed', () async {
    final owedCommit = applicationCommit(
      eventNumber: 15,
      senderUserNumber: 1000,
      senderDeviceNumber: 900,
      localOrigin: true,
      peerUserNumber: 1001,
    );
    final settledCommit = applicationCommit(
      eventNumber: 16,
      senderUserNumber: 1000,
      senderDeviceNumber: 900,
      localOrigin: true,
      peerUserNumber: 1001,
    );
    for (final entry in {
      'owed-operation': owedCommit,
      'settled-operation': settledCommit,
    }.entries) {
      await store.commitLocalEcho(
        operationId: entry.key,
        eventId: protocolBytesToHex(entry.value.event.eventId),
        currentUserId: uuid(1000),
        currentDeviceId: uuid(900),
        peerUserId: uuid(1001),
        openedLocalPayload: entry.value.canonicalBytes,
        applicationEvent: entry.value,
      );
    }
    await store.settleSendPreparation('settled-operation');
    await database.customStatement(
      "UPDATE pairwise_local_applications SET committed_at = 0",
    );

    expect(
      await store.pruneRetainedMetadata(now: DateTime.utc(2026, 7, 29)),
      isA<Success<void>>(),
    );

    // The settled one is ordinary retained metadata and goes. The owed one is
    // the bytes a queued fan-out is going to seal, and a message the user can
    // already see is waiting for it.
    final remaining = await database
        .select(database.pairwiseLocalApplications)
        .get();
    expect(remaining.map((row) => row.operationId), ['owed-operation']);
  });

  test('a retry with nothing failed re-arms nothing', () async {
    expect(
      ((await store.rearmFailedSend('pairwise-operation')) as Success<bool>)
          .value,
      isFalse,
    );
  });

  test('send fault rolls back session, local marker, and all targets', () async {
    await database.customStatement(
      "CREATE TRIGGER fail_pairwise_outbox BEFORE INSERT ON outbox_operations "
      "BEGIN SELECT RAISE(ABORT, 'fault'); END",
    );

    final result = await store.commitPreparedSend(sendCommit(targets: [1, 2]));

    expect(result, isA<FailureResult<void>>());
    expect(await database.select(database.pairwiseSessions).get(), isEmpty);
    expect(await database.select(database.outboxOperations).get(), isEmpty);
    expect(
      await database.select(database.pairwiseLocalApplications).get(),
      isEmpty,
    );
  });

  test('per-session and account skipped-key limits fail closed', () async {
    final invalid = sendCommit(targets: [1], skippedKeyCount: 2001);
    expect(
      (await store.commitPreparedSend(invalid) as FailureResult<void>).failure,
      isA<ValidationFailure>(),
    );

    for (var index = 10; index < 20; index += 1) {
      await database
          .into(database.pairwiseSessions)
          .insert(
            PairwiseSessionsCompanion.insert(
              localDeviceId: uuid(900),
              remoteUserId: const Value('account-limit-user'),
              remoteDeviceId: uuid(index),
              sessionId: Value(sessionId(index)),
              opaqueCryptoStateHandle: bytes(8, index),
              stateVersion: 1,
              skippedKeyCount: const Value(2000),
            ),
          );
    }

    final accountOverflow = await store.commitPreparedSend(
      sendCommit(targets: [30], skippedKeyCount: 1),
    );
    expect(
      (accountOverflow as FailureResult<void>).failure,
      isA<StorageFailure>().having(
        (failure) => failure.kind,
        'kind',
        StorageFailureKind.capacityExceeded,
      ),
    );
    expect(await database.select(database.outboxOperations).get(), isEmpty);
  });

  test(
    'receive atomically advances states, deletes OTPKs, records replay, and readies ack',
    () async {
      final sync = DriftSyncStore(database);
      await inspectEnvelope(sync, 50);
      await database
          .into(database.prekeys)
          .insert(
            PrekeysCompanion.insert(
              kind: 1,
              keyId: 5,
              privateStateHandle: bytes(8, 5),
              uploadState: 1,
              useState: 0,
            ),
          );
      await database
          .into(database.prekeys)
          .insert(
            PrekeysCompanion.insert(
              kind: 3,
              keyId: 7,
              privateStateHandle: bytes(8, 7),
              uploadState: 1,
              useState: 0,
            ),
          );
      final commit = receiveCommit(
        envelopeNumber: 50,
        stateMarker: 2,
        replayMarker: bytes(32, 9),
        deviceState: PairwiseDeviceStateTransition(
          nextOpaqueState: bytes(16, 2),
          expectedStateVersion: 1,
          nextStateVersion: 2,
        ),
        consumed: const [
          ConsumedPairwiseOneTimePrekey(
            kind: PairwiseOneTimePrekeyKind.classicalX25519,
            keyId: 5,
          ),
          ConsumedPairwiseOneTimePrekey(
            kind: PairwiseOneTimePrekeyKind.postQuantumMlKem768,
            keyId: 7,
          ),
        ],
        signedPrekeyId: 20,
        pqSignedPrekeyId: 21,
      );

      final result = await store.commitPreparedReceive(commit);

      expect(result, isA<Success<bool>>());
      expect((result as Success<bool>).value, isTrue);
      expect(
        (await database.select(database.pairwiseSessions).getSingle())
            .stateVersion,
        1,
      );
      final secret = await database.select(database.secureSecrets).getSingle();
      expect(secret.stateRevision, 2);
      expect(secret.wrappedCiphertextOrOpaqueHandle, bytes(16, 2));
      expect(await database.select(database.prekeys).get(), isEmpty);
      expect(
        await database.select(database.pairwiseConsumedPrekeys).get(),
        hasLength(2),
      );
      final replay = await database
          .select(database.pairwiseReplayMarkers)
          .getSingle();
      expect(replay.signedPrekeyId, 20);
      expect(replay.pqSignedPrekeyId, 21);
      expect(
        await database.select(database.pairwiseOpenedPayloads).get(),
        hasLength(1),
      );
      expect(
        (await database.select(database.inboxEnvelopes).getSingle())
            .readyToAcknowledge,
        isTrue,
      );
    },
  );

  test(
    'replay marker rejection does not advance state or ready the envelope',
    () async {
      final sync = DriftSyncStore(database);
      await inspectEnvelope(sync, 60);
      await store.commitPreparedReceive(
        receiveCommit(
          envelopeNumber: 60,
          stateMarker: 1,
          replayMarker: bytes(32, 8),
        ),
      );
      await inspectEnvelope(sync, 61);

      final replay = await store.commitPreparedReceive(
        receiveCommit(
          envelopeNumber: 61,
          stateMarker: 2,
          replayMarker: bytes(32, 8),
          expectedStateVersion: 1,
        ),
      );

      expect(
        (replay as FailureResult<bool>).failure,
        isA<SecurityFailure>().having(
          (failure) => failure.kind,
          'kind',
          SecurityFailureKind.integrityCheckFailed,
        ),
      );
      expect(
        (await database.select(database.pairwiseSessions).getSingle())
            .stateVersion,
        1,
      );
      final envelopeRow = await (database.select(
        database.inboxEnvelopes,
      )..where((row) => row.envelopeId.equals(uuid(61)))).getSingle();
      expect(
        envelopeRow.processingState,
        InboxProcessingState.inspecting.index,
      );
      expect(envelopeRow.readyToAcknowledge, isFalse);
    },
  );

  test(
    'additional MLS write failure rolls back the pairwise receive transaction',
    () async {
      final sync = DriftSyncStore(database);
      await inspectEnvelope(sync, 55);

      final result = await store.commitPreparedReceiveWithAdditionalTransaction(
        commit: receiveCommit(
          envelopeNumber: 55,
          stateMarker: 2,
          replayMarker: bytes(32, 55),
        ),
        dependency: EnvelopeDependency.potentiallyMls,
        additionalCommit: () async {
          await database
              .into(database.conversations)
              .insert(
                ConversationsCompanion.insert(
                  conversationId: 'must-roll-back',
                  kind: ConversationKind.group.index,
                  listProjectionCiphertext: bytes(1, 1),
                  sortKey: 1,
                ),
              );
          throw StateError('injected MLS transaction failure');
        },
      );

      expect(result, isA<FailureResult<bool>>());
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      expect(
        await database.select(database.pairwiseReplayMarkers).get(),
        isEmpty,
      );
      expect(
        await database.select(database.pairwiseOpenedPayloads).get(),
        isEmpty,
      );
      expect(await database.select(database.conversations).get(), isEmpty);
      expect(
        (await database.select(database.inboxEnvelopes).getSingle())
            .processingState,
        InboxProcessingState.inspecting.index,
      );
    },
  );

  test(
    'receive fault rolls back ratchet, device state, replay, and OTPK deletion',
    () async {
      final sync = DriftSyncStore(database);
      await inspectEnvelope(sync, 70);
      await database
          .into(database.prekeys)
          .insert(
            PrekeysCompanion.insert(
              kind: 1,
              keyId: 3,
              privateStateHandle: bytes(8, 3),
              uploadState: 1,
              useState: 0,
            ),
          );
      await database.customStatement(
        "CREATE TRIGGER fail_opened BEFORE INSERT ON pairwise_opened_payloads "
        "BEGIN SELECT RAISE(ABORT, 'fault'); END",
      );

      final result = await store.commitPreparedReceive(
        receiveCommit(
          envelopeNumber: 70,
          stateMarker: 3,
          replayMarker: bytes(32, 3),
          deviceState: PairwiseDeviceStateTransition(
            nextOpaqueState: bytes(16, 3),
            expectedStateVersion: 1,
            nextStateVersion: 2,
          ),
          consumed: const [
            ConsumedPairwiseOneTimePrekey(
              kind: PairwiseOneTimePrekeyKind.classicalX25519,
              keyId: 3,
            ),
          ],
        ),
      );

      expect(result, isA<FailureResult<bool>>());
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      expect(
        (await database.select(database.secureSecrets).getSingle())
            .stateRevision,
        1,
      );
      expect(await database.select(database.prekeys).get(), hasLength(1));
      expect(
        await database.select(database.pairwiseReplayMarkers).get(),
        isEmpty,
      );
      expect(
        (await database.select(database.inboxEnvelopes).getSingle())
            .processingState,
        InboxProcessingState.inspecting.index,
      );
    },
  );

  test(
    'application projection fault rolls back event marker and ratchet together',
    () async {
      final sync = DriftSyncStore(database);
      await inspectEnvelope(sync, 75);
      await database.customStatement(
        "CREATE TRIGGER fail_application_message BEFORE INSERT ON messages "
        "BEGIN SELECT RAISE(ABORT, 'fault'); END",
      );
      final application = applicationCommit(
        eventNumber: 75,
        senderUserNumber: 1001,
        senderDeviceNumber: 500,
      );

      final result = await store.commitPreparedReceive(
        receiveCommit(
          envelopeNumber: 75,
          stateMarker: 7,
          replayMarker: bytes(32, 7),
          senderUserId: uuid(1001),
          applicationEvent: application,
        ),
      );

      expect(result, isA<FailureResult<bool>>());
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      expect(
        await database.select(database.pairwiseReplayMarkers).get(),
        isEmpty,
      );
      expect(
        await database.select(database.storedApplicationEvents).get(),
        isEmpty,
      );
      expect(await database.select(database.conversations).get(), isEmpty);
      expect(
        (await database.select(database.inboxEnvelopes).getSingle())
            .processingState,
        InboxProcessingState.inspecting.index,
      );
    },
  );

  test(
    'simultaneous initiation retains one alternate until primary traffic',
    () async {
      await store.commitPreparedSend(sendCommit(targets: [80]));
      final sync = DriftSyncStore(database);
      await inspectEnvelope(sync, 81);
      await store.commitPreparedReceive(
        receiveCommit(
          envelopeNumber: 81,
          remoteDeviceNumber: 80,
          senderUserId: 'peer-user',
          sessionNumber: 81,
          stateMarker: 8,
          replayMarker: bytes(32, 8),
          deviceState: PairwiseDeviceStateTransition(
            nextOpaqueState: bytes(16, 8),
            expectedStateVersion: 1,
            nextStateVersion: 2,
          ),
          signedPrekeyId: 30,
          pqSignedPrekeyId: 31,
        ),
      );

      expect(
        (await database.select(database.pairwiseSessions).getSingle())
            .sessionId,
        sessionId(81),
      );
      expect(
        (await database.select(database.pairwiseSessionAlternates).getSingle())
            .sessionId,
        sessionId(80),
      );

      await inspectEnvelope(sync, 82);
      await store.commitPreparedReceive(
        receiveCommit(
          envelopeNumber: 82,
          remoteDeviceNumber: 80,
          senderUserId: 'peer-user',
          sessionNumber: 81,
          stateMarker: 9,
          replayMarker: bytes(32, 9),
          expectedStateVersion: 1,
        ),
      );
      expect(
        await database.select(database.pairwiseSessionAlternates).get(),
        isEmpty,
      );
    },
  );

  test(
    'authenticated repair replacement erases the exact old session',
    () async {
      await database
          .into(database.pairwiseSessions)
          .insert(
            PairwiseSessionsCompanion.insert(
              localDeviceId: uuid(900),
              remoteUserId: const Value('sender-user'),
              remoteDeviceId: uuid(500),
              sessionId: Value(sessionId(500)),
              opaqueCryptoStateHandle: bytes(32, 5),
              stateVersion: 3,
              repairState: Value(
                PairwiseRepairState.authenticatedRequestPending.index,
              ),
            ),
          );
      final sync = DriftSyncStore(database);
      await inspectEnvelope(sync, 83);

      final result = await store.commitPreparedReceive(
        receiveCommit(
          envelopeNumber: 83,
          sessionNumber: 501,
          stateMarker: 8,
          replayMarker: bytes(32, 8),
          replacedSessionId: sessionId(500),
          deviceState: PairwiseDeviceStateTransition(
            nextOpaqueState: bytes(16, 8),
            expectedStateVersion: 1,
            nextStateVersion: 2,
          ),
          signedPrekeyId: 40,
          pqSignedPrekeyId: 41,
        ),
      );

      expect(result, isA<Success<bool>>());
      expect(
        (await database.select(database.pairwiseSessions).getSingle())
            .sessionId,
        sessionId(501),
      );
      expect(
        await database.select(database.pairwiseSessionAlternates).get(),
        isEmpty,
      );
    },
  );

  test(
    'verified revocation removes sessions and stales pending targets',
    () async {
      await store.commitPreparedSend(sendCommit(targets: [90]));

      final result = await store.reconcileRemoteLiveDevices(
        remoteUserId: 'peer-user',
        liveDeviceIds: const {},
      );

      expect(result, isA<Success<void>>());
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      expect(
        (await database.select(database.outboxOperations).getSingle())
            .attemptState,
        OutboxAttemptState.stale.index,
      );
    },
  );

  test(
    'initial replay markers survive TTL until both signed keys are erased',
    () async {
      final old = DateTime.utc(2026, 7, 1);
      await database
          .into(database.pairwiseReplayMarkers)
          .insert(
            PairwiseReplayMarkersCompanion.insert(
              replayMarker: bytes(32, 1),
              sessionId: sessionId(1),
              signedPrekeyId: const Value(10),
              pqSignedPrekeyId: const Value(11),
              firstEnvelopeId: uuid(1),
              committedAt: Value(old),
            ),
          );
      await database
          .into(database.pairwiseReplayMarkers)
          .insert(
            PairwiseReplayMarkersCompanion.insert(
              replayMarker: bytes(32, 2),
              sessionId: sessionId(2),
              firstEnvelopeId: uuid(2),
              committedAt: Value(old),
            ),
          );

      await store.pruneRetainedMetadata(now: DateTime.utc(2026, 7, 29));
      var markers = await database.select(database.pairwiseReplayMarkers).get();
      expect(markers, hasLength(1));
      expect(markers.single.signedPrekeyId, 10);

      await store.pruneRetainedMetadata(
        now: DateTime.utc(2026, 7, 29),
        erasedSignedPrekeys: const [
          ErasedPairwiseSignedPrekeyPair(
            signedPrekeyId: 10,
            pqSignedPrekeyId: 11,
          ),
        ],
      );
      markers = await database.select(database.pairwiseReplayMarkers).get();
      expect(markers, isEmpty);
    },
  );

  test(
    'encrypted head gossip records global equivocation fail-closed',
    () async {
      final watchedUser = uuid(700);
      await database
          .into(database.users)
          .insert(
            UsersCompanion.insert(
              userId: watchedUser,
              activated: true,
              directoryEntryCiphertext: bytes(8, 1),
              localState: 0,
            ),
          );
      await database
          .into(database.deviceLogRecords)
          .insert(
            DeviceLogRecordsCompanion.insert(
              userId: watchedUser,
              sequence: 0,
              signedOpaqueRecord: bytes(256, 1),
              recordHash: bytes(32, 1),
              forkState: 0,
              gossipState: 0,
            ),
          );
      await inspectEnvelope(DriftSyncStore(database), 80);
      final gossip = DeviceHeadGossipEvent(
        eventId: bytes(16, 80),
        senderUserId: protocolUuidBytes(uuid(1000)),
        senderDeviceId: protocolUuidBytes(uuid(500)),
        heads: [
          DeviceLogHeadGossip(
            userId: protocolUuidBytes(watchedUser),
            sequence: 0,
            hash: bytes(32, 2),
          ),
        ],
      );
      final result = await store.commitPreparedReceive(
        receiveCommit(
          envelopeNumber: 80,
          stateMarker: 1,
          replayMarker: bytes(32, 80),
          senderUserId: uuid(1000),
          deviceControlEvent: gossip,
        ),
      );

      expect(result, isA<Success<bool>>());
      expect(
        (await database.select(database.securityPostures).getSingle()).state,
        1,
      );
    },
  );

  test('history batches resume and deduplicate transactionally', () async {
    final transferBytes = bytes(16, 44);
    final transferId = protocolBytesToHex(transferBytes);
    await database
        .into(database.historyTransfers)
        .insert(
          HistoryTransfersCompanion.insert(
            transferId: transferId,
            manifestCiphertext: bytes(16, 1),
            sourceDeviceId: Value(uuid(500)),
            targetDeviceId: Value(uuid(900)),
            direction: const Value(0),
            state: const Value(1),
            sourceCompleteness: 0,
          ),
        );
    final application = applicationCommit(
      eventNumber: 81,
      senderUserNumber: 2000,
      senderDeviceNumber: 2001,
      peerUserNumber: 2000,
    );
    final batch = HistoryTransferBatchEvent(
      eventId: bytes(16, 81),
      senderUserId: protocolUuidBytes(uuid(1000)),
      senderDeviceId: protocolUuidBytes(uuid(500)),
      targetDeviceId: protocolUuidBytes(uuid(900)),
      transferId: transferBytes,
      batchIndex: 0,
      finalBatch: true,
      sourceCompleteness: HistorySourceCompleteness.partial,
      canonicalEvents: [application.canonicalBytes],
    );
    final sync = DriftSyncStore(database);
    await inspectEnvelope(sync, 81);
    final first = await store.commitPreparedReceive(
      receiveCommit(
        envelopeNumber: 81,
        stateMarker: 1,
        replayMarker: bytes(32, 81),
        senderUserId: uuid(1000),
        deviceControlEvent: batch,
        historyApplicationEvents: [application],
      ),
    );

    expect(first, isA<Success<bool>>());
    expect(
      await database.select(database.storedApplicationEvents).get(),
      hasLength(1),
    );
    expect(
      await database.select(database.historyTransferBatches).get(),
      hasLength(1),
    );
    var progress = await database.select(database.historyTransfers).getSingle();
    expect(progress.eventProgress, 1);
    expect(progress.nextBatchIndex, 1);
    expect(progress.state, 3);
    expect(
      progress.sourceCompleteness,
      HistorySourceCompleteness.partial.index,
    );

    await inspectEnvelope(sync, 82);
    final duplicate = await store.commitPreparedReceive(
      receiveCommit(
        envelopeNumber: 82,
        stateMarker: 2,
        replayMarker: bytes(32, 82),
        expectedStateVersion: 1,
        senderUserId: uuid(1000),
        deviceControlEvent: batch,
        historyApplicationEvents: [application],
      ),
    );
    expect(duplicate, isA<Success<bool>>());
    progress = await database.select(database.historyTransfers).getSingle();
    expect(progress.eventProgress, 1);
    expect(
      await database.select(database.storedApplicationEvents).get(),
      hasLength(1),
    );
  });

  test('corrupt history batch shape rolls back ratchet and progress', () async {
    final transferBytes = bytes(16, 45);
    await database
        .into(database.historyTransfers)
        .insert(
          HistoryTransfersCompanion.insert(
            transferId: protocolBytesToHex(transferBytes),
            manifestCiphertext: bytes(16, 1),
            sourceDeviceId: Value(uuid(500)),
            targetDeviceId: Value(uuid(900)),
            direction: const Value(0),
            state: const Value(1),
            sourceCompleteness: 0,
          ),
        );
    final batch = HistoryTransferBatchEvent(
      eventId: bytes(16, 83),
      senderUserId: protocolUuidBytes(uuid(1000)),
      senderDeviceId: protocolUuidBytes(uuid(500)),
      targetDeviceId: protocolUuidBytes(uuid(900)),
      transferId: transferBytes,
      batchIndex: 0,
      finalBatch: false,
      sourceCompleteness: HistorySourceCompleteness.full,
      canonicalEvents: [bytes(128, 9)],
    );
    await inspectEnvelope(DriftSyncStore(database), 83);
    final corrupt = await store.commitPreparedReceive(
      receiveCommit(
        envelopeNumber: 83,
        stateMarker: 1,
        replayMarker: bytes(32, 83),
        senderUserId: uuid(1000),
        deviceControlEvent: batch,
      ),
    );

    expect(corrupt, isA<FailureResult<bool>>());
    expect(await database.select(database.pairwiseSessions).get(), isEmpty);
    expect(
      (await database.select(database.historyTransfers).getSingle())
          .eventProgress,
      0,
    );
  });
}

PairwiseSendCommit sendCommit({
  required List<int> targets,
  int ciphertextOffset = 0,
  int skippedKeyCount = 0,
  ApplicationEventCommit? applicationEvent,
}) => PairwiseSendCommit(
  operationId: 'pairwise-operation',
  eventId: applicationEvent == null
      ? 'pairwise-event'
      : protocolBytesToHex(applicationEvent.event.eventId),
  // The commit no longer carries the event itself. A locally originated send is
  // committed and projected by the echo, and what reaches here is only the
  // ciphertext it owed — matched to that echo by operation id and payload.
  currentDeviceId: uuid(900),
  expectedDeviceStateVersion: 1,
  openedLocalPayload: applicationEvent?.canonicalBytes ?? bytes(16, 4),
  targets: [
    for (final number in targets)
      PreparedPairwiseSendTarget(
        recipientUserId: applicationEvent?.peerUserId ?? 'peer-user',
        recipientDeviceId: uuid(number),
        exactCiphertext: envelope(number + ciphertextOffset),
        sessionTransition: PairwiseSessionTransition(
          localDeviceId: uuid(900),
          remoteUserId: applicationEvent?.peerUserId ?? 'peer-user',
          remoteDeviceId: uuid(number),
          sessionId: sessionId(number),
          nextOpaqueState: bytes(32, number),
          expectedStateVersion: null,
          nextStateVersion: 1,
          nextSkippedKeyCount: skippedKeyCount,
          disposition: PairwiseSessionDisposition.primaryBidirectional,
          repairState: PairwiseRepairState.ready,
        ),
      ),
  ],
);

PairwiseReceiveCommit receiveCommit({
  required int envelopeNumber,
  required int stateMarker,
  required Uint8List replayMarker,
  int remoteDeviceNumber = 500,
  String senderUserId = 'sender-user',
  int? sessionNumber,
  int? expectedStateVersion,
  PairwiseDeviceStateTransition? deviceState,
  List<ConsumedPairwiseOneTimePrekey> consumed = const [],
  int? signedPrekeyId,
  int? pqSignedPrekeyId,
  Uint8List? replacedSessionId,
  ApplicationEventCommit? applicationEvent,
  DeviceControlEvent? deviceControlEvent,
  List<ApplicationEventCommit> historyApplicationEvents = const [],
}) => PairwiseReceiveCommit(
  envelopeId: uuid(envelopeNumber),
  opaqueEventId: 'opaque-event-$envelopeNumber',
  senderUserId: senderUserId,
  senderDeviceId: uuid(remoteDeviceNumber),
  replayMarker: replayMarker,
  openedOpaquePayload:
      applicationEvent?.canonicalBytes ?? bytes(16, envelopeNumber),
  signedPrekeyId: signedPrekeyId,
  pqSignedPrekeyId: pqSignedPrekeyId,
  replacedSessionId: replacedSessionId,
  sessionTransition: PairwiseSessionTransition(
    localDeviceId: uuid(900),
    remoteUserId: senderUserId,
    remoteDeviceId: uuid(remoteDeviceNumber),
    sessionId: sessionId(sessionNumber ?? remoteDeviceNumber),
    nextOpaqueState: bytes(32, stateMarker),
    expectedStateVersion: expectedStateVersion,
    nextStateVersion: (expectedStateVersion ?? 0) + 1,
    nextSkippedKeyCount: 0,
    disposition: PairwiseSessionDisposition.primaryBidirectional,
    repairState: PairwiseRepairState.ready,
  ),
  deviceStateTransition: deviceState,
  consumedOneTimePrekeys: consumed,
  applicationEvent: applicationEvent,
  deviceControlEvent: deviceControlEvent,
  historyApplicationEvents: historyApplicationEvents,
);

ApplicationEventCommit applicationCommit({
  required int eventNumber,
  required int senderUserNumber,
  required int senderDeviceNumber,
  bool localOrigin = false,
  int peerUserNumber = 1001,
}) {
  final event = ApplicationEventRecord(
    version: 1,
    eventId: bytes(16, eventNumber),
    conversationId: bytes(32, 90),
    kindValue: ApplicationEventKind.messageCreate.wireValue,
    senderUserId: protocolUuidBytes(uuid(senderUserNumber)),
    senderDeviceId: protocolUuidBytes(uuid(senderDeviceNumber)),
    senderCounter: 1,
    createdMs: 1700000000000,
    references: const [],
    body: MessageCreateBody(
      messageId: bytes(16, eventNumber),
      text: 'authenticated projection',
    ),
  );
  return ApplicationEventCommit(
    event: event,
    canonicalBytes: bytes(128, eventNumber),
    currentUserId: uuid(1000),
    currentDeviceId: uuid(900),
    conversationKind: ConversationKind.direct.index,
    peerUserId: uuid(peerUserNumber),
    localOrigin: localOrigin,
    authenticatedAt: DateTime.fromMillisecondsSinceEpoch(
      1700000001000,
      isUtc: true,
    ),
  );
}

Future<void> inspectEnvelope(DriftSyncStore sync, int number) async {
  await sync.persistDrainPage(
    DrainPage(
      envelopes: [
        SyncEnvelope(
          id: uuid(number),
          sequence: number,
          exactCiphertext: envelope(number),
        ),
      ],
      hasMore: false,
      prunedThrough: 0,
    ),
  );
  await sync.beginNextEnvelopeInspection(now: DateTime.utc(2026, 7, 29));
}

String uuid(int value) =>
    '00000000-0000-0000-0000-${value.toRadixString(16).padLeft(12, '0')}';

Uint8List sessionId(int marker) => bytes(16, marker);

Uint8List envelope(int marker) => bytes(1024, marker);

Uint8List bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker & 0xff));
