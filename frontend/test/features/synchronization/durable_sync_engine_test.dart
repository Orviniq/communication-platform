import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/synchronization/application/durable_sync_engine.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LocalDatabase database;
  late DriftSyncStore store;
  late FakeSyncRemote remote;
  late FixtureInspector inspector;
  late FakeClock clock;
  late RecordingStaleRefresh staleRefresh;
  late DisplaceableOwner owner;
  late DurableSyncEngine engine;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    store = DriftSyncStore(database);
    remote = FakeSyncRemote();
    inspector = FixtureInspector();
    clock = FakeClock(DateTime.utc(2026, 7, 29));
    staleRefresh = RecordingStaleRefresh();
    owner = DisplaceableOwner();
    engine = DurableSyncEngine(
      store: store,
      remote: remote,
      inspector: inspector,
      staleDeviceRefresh: staleRefresh,
      clock: clock,
      jitter: const ZeroJitter(),
      standDown: owner,
    );
  });

  tearDown(() async {
    await database.close();
  });

  group('sealing what the user already sent', () {
    Future<void> owe(String operationId, String eventId) => database
        .into(database.pendingSendPreparations)
        .insert(
          PendingSendPreparationsCompanion.insert(
            operationId: operationId,
            eventId: eventId,
            localUserId: uuid(1),
            localDeviceId: uuid(11),
            peerUserId: uuid(2),
          ),
        );

    DurableSyncEngine engineWith(SendPreparationPort preparer) =>
        DurableSyncEngine(
          store: store,
          remote: remote,
          inspector: inspector,
          staleDeviceRefresh: staleRefresh,
          clock: clock,
          jitter: const ZeroJitter(),
          standDown: owner,
          sendPreparation: preparer,
        );

    test('a send is sealed before anything is sent', () async {
      await owe('application:aa', 'aa');
      final preparer = RecordingPreparer(database, remote);

      final report = await engineWith(preparer).synchronize();

      expect(report, isA<Success<SyncRunReport>>());
      expect((report as Success<SyncRunReport>).value.preparedSends, 1);
      expect(preparer.prepared.map((work) => work.operationId), [
        'application:aa',
      ]);
      // Nothing had gone to the wire when the fan-out ran, which is the whole
      // reason the stage sits where it does: the batch this seals is meant to
      // leave in the same cycle rather than the next one.
      expect(preparer.sentWhenPrepared, [0]);
      expect(
        await database.select(database.pendingSendPreparations).get(),
        isEmpty,
      );
    });

    test('a core that will not seal for this peer retires the send', () async {
      await owe('application:ff', 'ff');
      final preparer = FailingPreparer(
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );

      final report = await engineWith(preparer).synchronize();

      // A device set that changed under the claim is a settled answer about
      // this send, not about this connection.
      expect(report, isA<Success<SyncRunReport>>());
      expect(
        (await database.select(database.pendingSendPreparations).getSingle())
            .state,
        1,
      );
      expect(preparer.attempts, 1);
    });

    test('a device out of storage keeps the send owed', () async {
      await owe('application:gg', 'gg');
      final preparer = FailingPreparer(
        const StorageFailure(StorageFailureKind.unavailable),
      );

      final report = await engineWith(preparer).synchronize();

      // Nothing has been learned about the message, only about the device, so
      // retiring it here would say a send failed because a disk filled up.
      expect(report, isA<FailureResult<SyncRunReport>>());
      expect(
        (await database.select(database.pendingSendPreparations).getSingle())
            .state,
        0,
      );
    });

    test('a transport that will not answer leaves the send owed', () async {
      await owe('application:bb', 'bb');
      final preparer = FailingPreparer(
        const TransportFailure(TransportFailureKind.offline),
      );

      final report = await engineWith(preparer).synchronize();

      expect(report, isA<FailureResult<SyncRunReport>>());
      final owed = await database
          .select(database.pendingSendPreparations)
          .getSingle();
      expect(owed.state, 0);
      expect(owed.attemptCount, 1);
      expect(owed.nextAttemptAt, isA<DateTime>());
      // One attempt, not thirty-two: a transport that refused this one will
      // refuse the next, and the rows are durable.
      expect(preparer.attempts, 1);
    });

    test('a peer this build can never seal for is retired, and the send behind '
        'it still goes', () async {
      await owe('application:cc', 'cc');
      await owe('application:dd', 'dd');
      final preparer = SelectivePreparer(
        database,
        refuse: 'application:cc',
        failure: const ValidationFailure(ValidationFailureKind.invalidInput),
      );

      final report = await engineWith(preparer).synchronize();

      expect(report, isA<Success<SyncRunReport>>());
      expect((report as Success<SyncRunReport>).value.preparedSends, 1);
      final rows = await database
          .select(database.pendingSendPreparations)
          .get();
      // Retired rather than retried, and the stage carried on past it — which
      // is what makes one unsendable message not a stuck queue. The row stays
      // because it is the only durable record that a message the user can see
      // has no route to the wire.
      expect(rows, hasLength(1));
      expect(rows.single.operationId, 'application:cc');
      expect(rows.single.state, 1);
      expect(rows.single.nextAttemptAt, isNull);
    });

    test(
      'an engine with no preparer is the engine that was there before',
      () async {
        await owe('application:ee', 'ee');

        final report = await engine.synchronize();

        expect(report, isA<Success<SyncRunReport>>());
        expect((report as Success<SyncRunReport>).value.preparedSends, 0);
        expect(
          await database.select(database.pendingSendPreparations).get(),
          hasLength(1),
        );
      },
    );
  });

  group('giving delivery up between units of work', () {
    test(
      'a cycle displaced mid-drain stops after the envelope it holds',
      () async {
        // Three envelopes are waiting. The owner is displaced as soon as the
        // first one has been inspected, which is the moment the foreground
        // engine attached in the artifact.
        await store.persistDrainPage(
          DrainPage(
            envelopes: [
              SyncEnvelope(id: uuid(41), sequence: 1, exactCiphertext: blob(1)),
              SyncEnvelope(id: uuid(42), sequence: 2, exactCiphertext: blob(2)),
              SyncEnvelope(id: uuid(43), sequence: 3, exactCiphertext: blob(3)),
            ],
            hasMore: false,
            prunedThrough: 0,
          ),
        );
        inspector.onInspected = (calls) {
          if (calls == 1) {
            owner.displaced = true;
          }
        };

        final result = await engine.synchronize();

        expect(result, isA<Success<SyncRunReport>>());
        final report = (result as Success<SyncRunReport>).value;
        expect(
          report.inspectedEnvelopes,
          1,
          reason:
              'the envelope in hand is finished, and no further one is begun',
        );
        expect(
          report.deferred,
          isTrue,
          reason: 'work remains, which is what the next owner is told',
        );

        // The one it did commit is committed and acknowledged, so its row is
        // gone. The two it did not are exactly as they were, ready for whoever
        // runs next - not half-processed, not lost, and not left carrying a
        // spent attempt.
        final rows = await database.select(database.inboxEnvelopes).get();
        expect(rows.map((row) => row.sequence), [2, 3]);
        expect(rows.every((row) => row.processingState == 0), isTrue);
        expect(rows.every((row) => row.attemptCount == 0), isTrue);
        expect(rows.every((row) => row.nextAttemptAt == null), isTrue);
      },
    );

    test('a displaced cycle drains no further page', () async {
      remote.pages
        ..add(
          DrainPage(
            envelopes: [
              SyncEnvelope(id: uuid(44), sequence: 1, exactCiphertext: blob(1)),
            ],
            hasMore: true,
            prunedThrough: 0,
          ),
        )
        ..add(
          DrainPage(
            envelopes: [
              SyncEnvelope(id: uuid(45), sequence: 2, exactCiphertext: blob(2)),
            ],
            hasMore: false,
            prunedThrough: 0,
          ),
        );
      inspector.onInspected = (calls) => owner.displaced = true;

      final result = await engine.synchronize();

      expect(result, isA<Success<SyncRunReport>>());
      final report = (result as Success<SyncRunReport>).value;
      expect(report.drainedPages, 1);
      expect(report.deferred, isTrue);
      expect(remote.pages, hasLength(1), reason: 'the second page is untaken');
    });

    test('an owner nothing displaces runs the whole cycle', () async {
      // The cost of the signal when nobody is contending, which is the normal
      // case: nothing at all beyond a boolean read per unit of work.
      await store.persistDrainPage(
        DrainPage(
          envelopes: [
            SyncEnvelope(id: uuid(46), sequence: 1, exactCiphertext: blob(1)),
            SyncEnvelope(id: uuid(47), sequence: 2, exactCiphertext: blob(2)),
          ],
          hasMore: false,
          prunedThrough: 0,
        ),
      );

      final result = await engine.synchronize();

      final report = (result as Success<SyncRunReport>).value;
      expect(report.inspectedEnvelopes, 2);
      expect(report.deferred, isFalse);
    });
  });

  test(
    '>256 targets use deterministic UUID-byte batches and exact retry bytes',
    () async {
      final targets = List.generate(513, (index) {
        final reversed = 513 - index;
        return PreparedOutboxTarget(
          recipientUserId: 'user-${reversed % 3}',
          recipientDeviceId: uuid(reversed),
          exactCiphertext: blob(reversed % 251),
        );
      });
      final queued = await engine.queuePreparedOperation(
        operationId: 'operation-513',
        eventId: 'event-513',
        targets: targets,
      );
      expect(queued, isA<Success<void>>());
      remote.sendFailuresRemaining = 1;

      final lostResponse = await engine.synchronize();
      expect(lostResponse, isA<FailureResult<SyncRunReport>>());
      final firstAttempt = remote.sentBatches.single;
      expect(firstAttempt.targets, hasLength(256));

      final completed = await engine.synchronize();
      expect(completed, isA<Success<SyncRunReport>>());
      expect(remote.sentBatches, hasLength(4));
      final retry = remote.sentBatches[1];
      expect(retry.targets, hasLength(256));
      expect(
        retry.targets.map((target) => target.recipientDeviceId),
        firstAttempt.targets.map((target) => target.recipientDeviceId),
      );
      for (var index = 0; index < firstAttempt.targets.length; index += 1) {
        expect(
          retry.targets[index].exactCiphertext,
          firstAttempt.targets[index].exactCiphertext,
        );
      }
      expect(remote.sentBatches[2].targets, hasLength(256));
      expect(remote.sentBatches[3].targets, hasLength(1));
      final allTargets = remote.sentBatches
          .skip(1)
          .expand((batch) => batch.targets)
          .map((target) => target.recipientDeviceId)
          .toList();
      expect(allTargets, List.generate(513, (index) => uuid(index + 1)));
    },
  );

  test(
    'duplicate and reordered deliveries commit one opaque event and advance contiguous ack',
    () async {
      await store.persistDrainPage(
        DrainPage(
          envelopes: [
            SyncEnvelope(id: uuid(22), sequence: 2, exactCiphertext: blob(7)),
            SyncEnvelope(id: uuid(21), sequence: 1, exactCiphertext: blob(7)),
          ],
          hasMore: false,
          prunedThrough: 0,
        ),
      );
      await store.persistDrainPage(
        DrainPage(
          envelopes: [
            SyncEnvelope(id: uuid(22), sequence: 2, exactCiphertext: blob(7)),
          ],
          hasMore: false,
          prunedThrough: 0,
        ),
      );

      final result = await engine.synchronize();

      expect(result, isA<Success<SyncRunReport>>());
      expect(inspector.calls, 2);
      expect(
        await database.select(database.inboxEventDeduplications).get(),
        hasLength(1),
      );
      expect(remote.acknowledgedIds.single, [uuid(21), uuid(22)]);
      final projection =
          await store.readProjection() as Success<SyncProjection>;
      expect(projection.value.highestContiguousAcknowledgedSequence, 2);
      expect(await database.select(database.inboxEnvelopes).get(), isEmpty);
    },
  );

  test(
    'drain pages are processed and acknowledged before the next page',
    () async {
      remote.pages
        ..add(
          DrainPage(
            envelopes: [
              SyncEnvelope(id: uuid(23), sequence: 1, exactCiphertext: blob(1)),
            ],
            hasMore: true,
            prunedThrough: 0,
          ),
        )
        ..add(
          DrainPage(
            envelopes: [
              SyncEnvelope(id: uuid(24), sequence: 2, exactCiphertext: blob(2)),
            ],
            hasMore: false,
            prunedThrough: 0,
          ),
        );

      final result = await engine.synchronize();

      expect(result, isA<Success<SyncRunReport>>());
      expect((result as Success<SyncRunReport>).value.drainedPages, 2);
      expect(remote.acknowledgedIds, [
        [uuid(23)],
        [uuid(24)],
      ]);
      expect(
        (await store.readProjection() as Success<SyncProjection>)
            .value
            .highestContiguousAcknowledgedSequence,
        2,
      );
    },
  );

  test('backoff honors Retry-After and caps exponential full-jitter range', () {
    const policy = SyncRetryPolicy(
      baseDelay: Duration(seconds: 2),
      maximumDelay: Duration(minutes: 1),
    );
    final retryAfter = policy.delayFor(
      attempt: 8,
      failure: const BackendFailure(
        BackendFailureCode.throttled,
        retryAfter: Duration(minutes: 2),
      ),
      jitter: const MaximumJitter(),
    );
    final capped = policy.delayFor(
      attempt: 20,
      failure: const TransportFailure(TransportFailureKind.timeout),
      jitter: const MaximumJitter(),
    );

    expect(retryAfter, const Duration(minutes: 2));
    expect(capped, const Duration(minutes: 1));
  });

  test(
    'REST success does not reset realtime backoff before socket stability',
    () async {
      await store.scheduleReconnect(
        dueAt: clock.now().add(const Duration(seconds: 5)),
      );

      final result = await engine.synchronize();

      expect(result, isA<Success<SyncRunReport>>());
      expect(
        (await store.readReconnectState() as Success<DurableReconnectState>)
            .value
            .attempt,
        1,
      );
      await store.clearReconnect(syncedAt: null);
      expect(
        (await store.readReconnectState() as Success<DurableReconnectState>)
            .value
            .attempt,
        0,
      );
    },
  );

  test(
    'seven-day prune gap blocks possible MLS before recovery and resumes at safe baseline',
    () async {
      await database
          .into(database.mlsGroups)
          .insert(
            MlsGroupsCompanion.insert(
              groupId: 'opaque-group',
              opaqueCryptoStateHandle: Uint8List.fromList([1]),
              acceptedEpoch: 4,
              stateVersion: 1,
            ),
          );
      remote.prunedThrough = 5;
      remote.pages.add(
        DrainPage(
          envelopes: [
            SyncEnvelope(id: uuid(31), sequence: 6, exactCiphertext: blob(9)),
          ],
          hasMore: false,
          prunedThrough: 5,
        ),
      );

      final blocked = await engine.synchronize();

      expect(blocked, isA<Success<SyncRunReport>>());
      expect(inspector.allowMlsValues, [false]);
      expect(remote.acknowledgedIds, isEmpty);
      final blockedProjection =
          await store.readProjection() as Success<SyncProjection>;
      expect(
        blockedProjection.value.queueGapState,
        QueueGapState.recoveryRequired,
      );
      expect(
        (await database.select(database.mlsGroups).getSingle())
            .queueGapRecoveryState,
        1,
      );

      await store.markGroupRecovered('opaque-group');
      final recovered = await engine.synchronize();

      expect(recovered, isA<Success<SyncRunReport>>());
      expect(inspector.allowMlsValues, [false, true]);
      final projection =
          await store.readProjection() as Success<SyncProjection>;
      expect(projection.value.queueGapState, QueueGapState.clear);
      expect(projection.value.highestContiguousAcknowledgedSequence, 6);
      expect(remote.acknowledgedIds.single, [uuid(31)]);
    },
  );

  test(
    'stale targets are terminal, invalidate sessions, and queue refresh',
    () async {
      await database
          .into(database.pairwiseSessions)
          .insert(
            PairwiseSessionsCompanion.insert(
              localDeviceId: uuid(1),
              remoteDeviceId: uuid(40),
              opaqueCryptoStateHandle: Uint8List.fromList([4]),
              stateVersion: 1,
            ),
          );
      await engine.queuePreparedOperation(
        operationId: 'stale-operation',
        eventId: 'stale-event',
        targets: [
          PreparedOutboxTarget(
            recipientUserId: 'stale-user',
            recipientDeviceId: uuid(40),
            exactCiphertext: blob(40),
          ),
          PreparedOutboxTarget(
            recipientUserId: 'live-user',
            recipientDeviceId: uuid(41),
            exactCiphertext: blob(41),
          ),
        ],
      );
      remote.staleDeviceIds.add(uuid(40));

      final result = await engine.synchronize();

      expect(result, isA<Success<SyncRunReport>>());
      final rows = await database.select(database.outboxOperations).get();
      expect(
        rows
            .singleWhere((row) => row.recipientDeviceId == uuid(40))
            .attemptState,
        OutboxAttemptState.stale.index,
      );
      expect(
        rows
            .singleWhere((row) => row.recipientDeviceId == uuid(41))
            .attemptState,
        OutboxAttemptState.accepted.index,
      );
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      expect(staleRefresh.users, ['stale-user']);
      expect(
        await database.select(database.staleDeviceRefreshRequests).get(),
        isEmpty,
      );
    },
  );

  test('a full mailbox keeps the device, its session and its item', () async {
    // A full device is live. Recording it as stale would delete a working
    // pairwise session and drop a member out of a conversation over an
    // inbox its owner has simply not emptied.
    await database
        .into(database.pairwiseSessions)
        .insert(
          PairwiseSessionsCompanion.insert(
            localDeviceId: uuid(1),
            remoteDeviceId: uuid(60),
            opaqueCryptoStateHandle: Uint8List.fromList([7]),
            stateVersion: 1,
          ),
        );
    await engine.queuePreparedOperation(
      operationId: 'full-operation',
      eventId: 'full-event',
      targets: [
        PreparedOutboxTarget(
          recipientUserId: 'full-user',
          recipientDeviceId: uuid(60),
          exactCiphertext: blob(60),
        ),
        PreparedOutboxTarget(
          recipientUserId: 'live-user',
          recipientDeviceId: uuid(61),
          exactCiphertext: blob(61),
        ),
      ],
    );
    remote.fullDeviceIds.add(uuid(60));

    expect(await engine.synchronize(), isA<Success<SyncRunReport>>());

    final rows = await database.select(database.outboxOperations).get();
    final held = rows.singleWhere((row) => row.recipientDeviceId == uuid(60));
    expect(held.attemptState, OutboxAttemptState.retryWait.index);
    expect(held.nextAttemptAt, isA<DateTime>());
    expect(held.terminalAt, isNull);
    expect(
      rows.singleWhere((row) => row.recipientDeviceId == uuid(61)).attemptState,
      OutboxAttemptState.accepted.index,
    );
    // Neither the session nor the owner's device list is touched: nothing
    // about this device has changed.
    expect(
      await database.select(database.pairwiseSessions).get(),
      hasLength(1),
    );
    expect(staleRefresh.users, isEmpty);
    expect(
      await database.select(database.staleDeviceRefreshRequests).get(),
      isEmpty,
    );
  });

  test(
    'an answer that does not account for the batch is not recorded',
    () async {
      await engine.queuePreparedOperation(
        operationId: 'unaccounted-operation',
        eventId: 'unaccounted-event',
        targets: [
          PreparedOutboxTarget(
            recipientUserId: 'user',
            recipientDeviceId: uuid(62),
            exactCiphertext: blob(62),
          ),
        ],
      );
      // Counted as written *and* reported full: the two cannot both be true,
      // and a client that took the count would report a delivery that did not
      // happen.
      remote.overstatedAcceptance = true;

      // The run reports the malformed answer rather than swallowing it, and
      // the batch is left waiting rather than recorded as delivered.
      expect(await engine.synchronize(), isA<FailureResult<SyncRunReport>>());

      final row = await database.select(database.outboxOperations).getSingle();
      expect(row.attemptState, OutboxAttemptState.retryWait.index);
      expect(row.terminalAt, isNull);
    },
  );

  test(
    'bounded queues reject new work without dropping existing rows',
    () async {
      final bounded = DriftSyncStore(
        database,
        maximumInboxEntries: 1,
        maximumOutboxTargets: 1,
      );
      final firstInbox = await bounded.persistDrainPage(
        DrainPage(
          envelopes: [
            SyncEnvelope(id: uuid(51), sequence: 1, exactCiphertext: blob(1)),
          ],
          hasMore: false,
          prunedThrough: 0,
        ),
      );
      final overflowInbox = await bounded.persistDrainPage(
        DrainPage(
          envelopes: [
            SyncEnvelope(id: uuid(52), sequence: 2, exactCiphertext: blob(2)),
          ],
          hasMore: false,
          prunedThrough: 0,
        ),
      );
      expect(firstInbox, isA<Success<void>>());
      expect(overflowInbox, isA<FailureResult<void>>());
      expect(
        await database.select(database.inboxEnvelopes).get(),
        hasLength(1),
      );

      final firstOutbox = await bounded.queuePreparedOperation(
        operationId: 'bounded-1',
        eventId: 'event-1',
        targets: [
          PreparedOutboxTarget(
            recipientUserId: 'user',
            recipientDeviceId: uuid(61),
            exactCiphertext: blob(1),
          ),
        ],
      );
      final overflowOutbox = await bounded.queuePreparedOperation(
        operationId: 'bounded-2',
        eventId: 'event-2',
        targets: [
          PreparedOutboxTarget(
            recipientUserId: 'user',
            recipientDeviceId: uuid(62),
            exactCiphertext: blob(2),
          ),
        ],
      );
      expect(firstOutbox, isA<Success<void>>());
      expect(overflowOutbox, isA<FailureResult<void>>());
      expect(
        await database.select(database.outboxOperations).get(),
        hasLength(1),
      );
    },
  );

  test(
    'transaction faults publish no partial inspection, ack, or stale state',
    () async {
      await store.persistDrainPage(
        DrainPage(
          envelopes: [
            SyncEnvelope(id: uuid(71), sequence: 1, exactCiphertext: blob(1)),
          ],
          hasMore: false,
          prunedThrough: 0,
        ),
      );
      final envelope =
          (await store.beginNextEnvelopeInspection(now: clock.now())
                  as Success<SyncEnvelope?>)
              .value!;
      await database.customStatement(
        "CREATE TRIGGER fail_dedup BEFORE INSERT ON inbox_event_deduplication "
        "BEGIN SELECT RAISE(ABORT, 'fault'); END",
      );
      final failedCommit = await store.commitOpaqueInspection(
        envelopeId: envelope.id,
        inspection: const OpaqueEnvelopeInspection(
          opaqueEventId: 'event-fault',
          dependency: EnvelopeDependency.directOrLocal,
        ),
      );
      expect(failedCommit, isA<FailureResult<bool>>());
      expect(
        await database.select(database.inboxEventDeduplications).get(),
        isEmpty,
      );
      expect(
        (await database.select(database.inboxEnvelopes).getSingle())
            .processingState,
        InboxProcessingState.inspecting.index,
      );
      await database.customStatement('DROP TRIGGER fail_dedup');
      await store.commitOpaqueInspection(
        envelopeId: envelope.id,
        inspection: const OpaqueEnvelopeInspection(
          opaqueEventId: 'event-fault',
          dependency: EnvelopeDependency.directOrLocal,
        ),
      );
      final ack =
          (await store.beginAcknowledgementBatch(
                    now: clock.now(),
                    maximumIds: 200,
                  )
                  as Success<AcknowledgementBatch?>)
              .value!;
      await database.customStatement(
        "CREATE TRIGGER fail_checkpoint BEFORE UPDATE OF "
        "highest_contiguous_acked_sequence ON sync_checkpoint "
        "BEGIN SELECT RAISE(ABORT, 'fault'); END",
      );
      final failedAck = await store.recordAcknowledgementSuccess(
        batch: ack,
        now: clock.now(),
      );
      expect(failedAck, isA<FailureResult<void>>());
      expect(
        (await database.select(database.inboxEnvelopes).getSingle())
            .processingState,
        InboxProcessingState.acknowledgementSending.index,
      );
      expect(
        (await store.readProjection() as Success<SyncProjection>)
            .value
            .highestContiguousAcknowledgedSequence,
        0,
      );
      await database.customStatement('DROP TRIGGER fail_checkpoint');

      await store.queuePreparedOperation(
        operationId: 'fault-stale',
        eventId: 'fault-event',
        targets: [
          PreparedOutboxTarget(
            recipientUserId: 'fault-user',
            recipientDeviceId: uuid(72),
            exactCiphertext: blob(2),
          ),
        ],
      );
      await database
          .into(database.pairwiseSessions)
          .insert(
            PairwiseSessionsCompanion.insert(
              localDeviceId: uuid(1),
              remoteDeviceId: uuid(72),
              opaqueCryptoStateHandle: Uint8List.fromList([1]),
              stateVersion: 1,
            ),
          );
      final outbox =
          (await store.beginNextOutboxBatch(now: clock.now())
                  as Success<OutboxBatch?>)
              .value!;
      await database.customStatement(
        "CREATE TRIGGER fail_refresh BEFORE INSERT ON stale_device_refresh_requests "
        "BEGIN SELECT RAISE(ABORT, 'fault'); END",
      );
      final failedStale = await store.recordOutboxAcceptance(
        batch: outbox,
        acceptance: OutboxAcceptance(accepted: 0, staleDeviceIds: {uuid(72)}),
        now: clock.now(),
        retryFullAt: clock.now().add(const Duration(minutes: 5)),
      );
      expect(failedStale, isA<FailureResult<void>>());
      expect(
        (await database.select(database.outboxOperations).getSingle())
            .attemptState,
        OutboxAttemptState.sending.index,
      );
      expect(
        await database.select(database.pairwiseSessions).get(),
        hasLength(1),
      );
    },
  );

  test(
    'retry state and exact ciphertext survive an offline process restart',
    () async {
      await database.close();
      final directory = await Directory.systemTemp.createTemp('sync-restart-');
      final file = File('${directory.path}/sync.sqlite');
      try {
        var restartedDatabase = LocalDatabase(NativeDatabase(file));
        var restartedStore = DriftSyncStore(restartedDatabase);
        final exact = blob(88);
        await restartedStore.queuePreparedOperation(
          operationId: 'restart-operation',
          eventId: 'restart-event',
          targets: [
            PreparedOutboxTarget(
              recipientUserId: 'restart-user',
              recipientDeviceId: uuid(88),
              exactCiphertext: exact,
            ),
          ],
        );
        final batch =
            (await restartedStore.beginNextOutboxBatch(now: clock.now())
                    as Success<OutboxBatch?>)
                .value!;
        await restartedStore.recordOutboxRetry(
          batch: batch,
          retryAt: clock.now().add(const Duration(hours: 1)),
        );
        await restartedDatabase.close();

        restartedDatabase = LocalDatabase(NativeDatabase(file));
        restartedStore = DriftSyncStore(restartedDatabase);
        final tooEarly = await restartedStore.beginNextOutboxBatch(
          now: clock.now(),
        );
        expect((tooEarly as Success<OutboxBatch?>).value, isNull);
        clock.advance(const Duration(hours: 1));
        final due =
            (await restartedStore.beginNextOutboxBatch(now: clock.now())
                    as Success<OutboxBatch?>)
                .value!;
        expect(due.targets.single.exactCiphertext, exact);
        expect(due.attempt, 2);
        await restartedDatabase.close();
      } finally {
        await directory.delete(recursive: true);
        database = LocalDatabase(NativeDatabase.memory());
      }
    },
  );
}

/// A delivery owner that can be told, mid-cycle, that it no longer owns
/// delivery.
///
/// This is the losing half of ADR-050. The deferred catch-up gives way to the
/// application the user has just opened, and it must do that *between* units of
/// work: not by being killed part-way through a ratchet step, and not only
/// after a whole drain it has no reason left to finish.
final class DisplaceableOwner implements DeliveryStandDownSignal {
  bool displaced = false;

  @override
  bool get standDownRequested => displaced;
}

final class FakeSyncRemote implements SyncRemotePort {
  final List<DrainPage> pages = [];
  final List<OutboxBatch> sentBatches = [];
  final List<List<String>> acknowledgedIds = [];
  final Set<String> staleDeviceIds = {};
  final Set<String> fullDeviceIds = {};
  int sendFailuresRemaining = 0;
  int acknowledgementFailuresRemaining = 0;
  bool overstatedAcceptance = false;
  int prunedThrough = 0;

  @override
  Future<Result<DrainPage>> drain({required int limit}) async => Result.success(
    pages.isEmpty
        ? DrainPage(
            envelopes: const [],
            hasMore: false,
            prunedThrough: prunedThrough,
          )
        : pages.removeAt(0),
  );

  @override
  Future<Result<int>> acknowledge(List<String> envelopeIds) async {
    acknowledgedIds.add(List.of(envelopeIds));
    if (acknowledgementFailuresRemaining > 0) {
      acknowledgementFailuresRemaining -= 1;
      return const Result.failure(
        TransportFailure(TransportFailureKind.timeout),
      );
    }
    return Result.success(envelopeIds.length);
  }

  @override
  Future<Result<OutboxAcceptance>> send(OutboxBatch batch) async {
    sentBatches.add(batch);
    if (sendFailuresRemaining > 0) {
      sendFailuresRemaining -= 1;
      return const Result.failure(
        TransportFailure(TransportFailureKind.timeout),
      );
    }
    final targets = batch.targets
        .map((target) => target.recipientDeviceId)
        .toSet();
    final stale = targets.where(staleDeviceIds.contains).toSet();
    final full = targets
        .where(fullDeviceIds.contains)
        .toSet()
        .difference(stale);
    return Result.success(
      OutboxAcceptance(
        accepted: overstatedAcceptance
            ? batch.targets.length
            : batch.targets.length - stale.length - full.length,
        staleDeviceIds: stale,
        fullDeviceIds: overstatedAcceptance
            ? batch.targets.map((target) => target.recipientDeviceId).toSet()
            : full,
      ),
    );
  }
}

final class FixtureInspector implements OpaqueEnvelopeInspector {
  int calls = 0;
  final List<bool> allowMlsValues = [];

  /// Called with the running inspection count, so a test can change the world
  /// at an exact point inside a cycle.
  void Function(int calls)? onInspected;

  @override
  Future<Result<OpaqueEnvelopeInspection>> inspect({
    required String envelopeId,
    required Uint8List exactCiphertext,
    required bool allowPotentiallyMls,
  }) async {
    calls += 1;
    allowMlsValues.add(allowPotentiallyMls);
    onInspected?.call(calls);
    final marker = exactCiphertext.first;
    return Result.success(
      OpaqueEnvelopeInspection(
        opaqueEventId: 'opaque-event-$marker',
        dependency: marker == 9
            ? EnvelopeDependency.potentiallyMls
            : EnvelopeDependency.directOrLocal,
      ),
    );
  }
}

final class RecordingStaleRefresh implements StaleDeviceRefreshPort {
  final List<String> users = [];

  @override
  Future<Result<void>> refreshUserDevices(String userId) async {
    users.add(userId);
    return const Result.success(null);
  }
}

final class FakeClock implements TimeSource {
  FakeClock(this.value);

  DateTime value;

  void advance(Duration duration) {
    value = value.add(duration);
  }

  @override
  DateTime now() => value;
}

final class ZeroJitter implements JitterSource {
  const ZeroJitter();

  @override
  int nextInt(int upperBoundExclusive) => 0;
}

final class MaximumJitter implements JitterSource {
  const MaximumJitter();

  @override
  int nextInt(int upperBoundExclusive) => upperBoundExclusive - 1;
}

String uuid(int value) {
  final suffix = value.toRadixString(16).padLeft(12, '0');
  return '00000000-0000-0000-0000-$suffix';
}

Uint8List blob(int marker) =>
    Uint8List.fromList(List<int>.filled(1024, marker));

/// Stands in for the pairwise commit, and records when it was asked.
///
/// Deleting the row is not test convenience: it is the port's contract. The
/// real implementation retires the request in the same transaction that writes
/// the ciphertext, which is what stops a send being queued twice.
final class RecordingPreparer implements SendPreparationPort {
  RecordingPreparer(this.database, this.remote);

  final LocalDatabase database;
  final FakeSyncRemote remote;
  final List<PendingSendPreparation> prepared = [];
  final List<int> sentWhenPrepared = [];

  @override
  Future<Result<void>> prepare(PendingSendPreparation preparation) async {
    prepared.add(preparation);
    sentWhenPrepared.add(remote.sentBatches.length);
    await (database.delete(
      database.pendingSendPreparations,
    )..where((row) => row.operationId.equals(preparation.operationId))).go();
    return const Result.success(null);
  }
}

/// Refuses exactly one operation, and retires every other.
final class SelectivePreparer implements SendPreparationPort {
  SelectivePreparer(
    this.database, {
    required this.refuse,
    required this.failure,
  });

  final LocalDatabase database;
  final String refuse;
  final Failure failure;

  @override
  Future<Result<void>> prepare(PendingSendPreparation preparation) async {
    if (preparation.operationId == refuse) {
      return Result.failure(failure);
    }
    await (database.delete(
      database.pendingSendPreparations,
    )..where((row) => row.operationId.equals(preparation.operationId))).go();
    return const Result.success(null);
  }
}

final class FailingPreparer implements SendPreparationPort {
  FailingPreparer(this.failure);

  final Failure failure;
  int attempts = 0;

  @override
  Future<Result<void>> prepare(PendingSendPreparation preparation) async {
    attempts += 1;
    return Result.failure(failure);
  }
}
