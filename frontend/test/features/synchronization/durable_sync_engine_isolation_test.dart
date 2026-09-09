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

/// One unopenable envelope used to end the run that found it.
///
/// Every stage of a cycle propagated its first failure straight out of `_run`,
/// and the inbound stages ran first, so a mailbox holding a single envelope
/// this device could not decrypt meant the outbox was never reached: a message
/// the user had already sent stayed in local storage while the engine spent
/// every cycle failing on somebody else's bytes. These are the properties that
/// stop that from being possible again.
void main() {
  late LocalDatabase database;
  late DriftSyncStore store;
  late CountingStore countingStore;
  late FakeSyncRemote remote;
  late ScriptedInspector inspector;
  late FakeClock clock;

  DurableSyncEngine engineWith({
    SyncEngineLimits limits = const SyncEngineLimits(),
    DurableSyncStore? overrideStore,
  }) => DurableSyncEngine(
    store: overrideStore ?? countingStore,
    remote: remote,
    inspector: inspector,
    staleDeviceRefresh: const NoopStaleRefresh(),
    clock: clock,
    jitter: const ZeroJitter(),
    limits: limits,
  );

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    store = DriftSyncStore(database, projectionWindow: Duration.zero);
    countingStore = CountingStore(store);
    remote = FakeSyncRemote();
    inspector = ScriptedInspector();
    clock = FakeClock(DateTime.utc(2026, 8, 26));
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> queueOutbox() async {
    final queued = await store.queuePreparedOperation(
      operationId: 'operation-1',
      eventId: 'event-1',
      targets: [
        PreparedOutboxTarget(
          recipientUserId: 'peer',
          recipientDeviceId: uuid(900),
          exactCiphertext: blob(5),
        ),
      ],
    );
    expect(queued, isA<Success<void>>());
  }

  Future<void> seedInbox(List<int> sequences) async {
    final persisted = await store.persistDrainPage(
      DrainPage(
        envelopes: [
          for (final sequence in sequences)
            SyncEnvelope(
              id: uuid(sequence),
              sequence: sequence,
              exactCiphertext: blob(sequence),
            ),
        ],
        hasMore: false,
        prunedThrough: 0,
      ),
    );
    expect(persisted, isA<Success<void>>());
  }

  test(
    'a run reaches the outbox when every envelope fails inspection',
    () async {
      await seedInbox([1, 2, 3]);
      inspector.poison
        ..add(uuid(1))
        ..add(uuid(2))
        ..add(uuid(3));
      await queueOutbox();

      final result = await engineWith().synchronize();

      expect(
        remote.sentBatches,
        hasLength(1),
        reason: 'the message the user sent left the device',
      );
      expect(remote.sentBatches.single.targets.single.exactCiphertext, blob(5));
      expect(
        result,
        isA<Success<SyncRunReport>>(),
        reason: 'envelopes that would not open are not a failed session',
      );
      final report = (result as Success<SyncRunReport>).value;
      expect(report.sentTargets, 1);
      expect(report.failedInspections, greaterThan(0));
    },
  );

  test(
    'a run acknowledges what it did inspect even though a later envelope failed',
    () async {
      await seedInbox([1, 2]);
      inspector.poison.add(uuid(2));

      final result = await engineWith().synchronize();

      expect(result, isA<Success<SyncRunReport>>());
      expect(
        remote.acknowledgedIds,
        isNotEmpty,
        reason: 'the acknowledgement phase was reached at all',
      );
      expect(
        remote.acknowledgedIds.expand((batch) => batch),
        contains(uuid(1)),
        reason: 'the envelope that did open is retired with the server',
      );
      final rows = await database.select(database.inboxEnvelopes).get();
      expect(
        rows.map((row) => row.sequence),
        [2],
        reason: 'and the one that did not is still here, waiting',
      );
    },
  );

  test(
    'an envelope the native core refuses is quarantined once the budget runs '
    'out, and then acknowledged',
    () async {
      await seedInbox([1]);
      inspector.poison.add(uuid(1));
      inspector.failure = const CryptoCoreFailure(
        CryptoCoreFailureCode.authenticationFailed,
      );
      final engine = engineWith(
        limits: const SyncEngineLimits(maximumInspectionAttempts: 2),
      );

      final first = await engine.synchronize();
      expect(first, isA<Success<SyncRunReport>>());
      expect(
        (first as Success<SyncRunReport>).value.quarantinedEnvelopes,
        0,
        reason: 'one budgeted failure is not yet terminal',
      );
      expect(await pendingInbound(database), 1);
      expect(await quarantinedInput(database), 0);

      // The floor on inspection backoff is what keeps a poison envelope from
      // being handed to the same pass over and over, so reaching the second
      // attempt means moving the clock past it.
      clock.advance(const Duration(minutes: 30));
      final second = await engine.synchronize();

      expect(second, isA<Success<SyncRunReport>>());
      expect((second as Success<SyncRunReport>).value.quarantinedEnvelopes, 1);
      expect(
        await quarantinedInput(database),
        1,
        reason: 'quarantined_input is what a user can see this in',
      );
      expect(
        await pendingInbound(database),
        0,
        reason: 'pending_inbound falls, which is what was frozen before',
      );
      expect(
        remote.acknowledgedIds.expand((batch) => batch),
        contains(uuid(1)),
        reason: 'the server is told, so it stops serving these bytes',
      );
      final record = await database.select(database.quarantineRecords).get();
      expect(record.single.reasonCode, isPositive);
      expect(
        record.single.opaqueDigest,
        isEmpty,
        reason: 'a quarantine record carries a number and nothing else',
      );
    },
  );

  test(
    'a store that cannot commit still ends the run, and spends no budget',
    () async {
      await seedInbox([1]);
      inspector.poison.add(uuid(1));
      inspector.failure = const CryptoCoreFailure(
        CryptoCoreFailureCode.authenticationFailed,
      );
      countingStore.failInspectionRetry = true;

      final result = await engineWith(
        limits: const SyncEngineLimits(maximumInspectionAttempts: 2),
      ).synchronize();

      expect(
        result,
        isA<FailureResult<SyncRunReport>>(),
        reason: 'a run that cannot write anything down cannot make progress',
      );
      expect(
        (result as FailureResult<SyncRunReport>).failure,
        isA<StorageFailure>(),
      );
      final row = await database.select(database.inboxEnvelopes).getSingle();
      expect(
        row.inspectionFailures,
        0,
        reason: 'nothing was recorded, so nothing was spent',
      );
      expect(await quarantinedInput(database), 0);
    },
  );

  test(
    'a send queued behind a mailbox full of poison is transmitted in one cycle',
    () async {
      await seedInbox([1, 2, 3, 4, 5]);
      for (var sequence = 1; sequence <= 5; sequence += 1) {
        inspector.poison.add(uuid(sequence));
      }
      // Every envelope is already unopenable when the user sends.
      await queueOutbox();
      final before = clock.now();

      await engineWith().synchronize();

      expect(remote.sentBatches, hasLength(1));
      expect(
        clock.now().difference(before),
        Duration.zero,
        reason:
            'no wait was interposed: the fake clock never had to be advanced',
      );
      expect(
        await outboxDepth(database),
        0,
        reason: 'acceptance is recorded against the durable row',
      );
    },
  );

  test(
    'the queue-gap state is read once per inbox pass, not once per envelope',
    () async {
      await seedInbox([1, 2, 3, 4, 5, 6]);

      await engineWith().synchronize();

      expect(inspector.calls, 6);
      expect(
        countingStore.gapStateReads,
        2,
        reason:
            'one read per inbox pass — the pass before the drain and the pass '
            'over the single drained page — and not one per envelope',
      );
      expect(
        countingStore.projectionReads,
        0,
        reason:
            'the loop needs one column, and the projection is three aggregates',
      );
    },
  );
}

Future<int> pendingInbound(LocalDatabase database) async {
  final rows = await database.select(database.inboxEnvelopes).get();
  return rows
      .where(
        (row) => row.processingState != InboxProcessingState.acknowledged.index,
      )
      .length;
}

Future<int> quarantinedInput(LocalDatabase database) async =>
    (await database.select(database.quarantineRecords).get()).length;

Future<int> outboxDepth(LocalDatabase database) async {
  final rows = await database.select(database.outboxOperations).get();
  return rows.where((row) => const {0, 1, 2}.contains(row.attemptState)).length;
}

/// The real store, with the reads this suite asserts on counted and one write
/// that can be told to fail.
final class CountingStore implements DurableSyncStore {
  CountingStore(this._inner);

  final DurableSyncStore _inner;
  int gapStateReads = 0;
  int projectionReads = 0;
  bool failInspectionRetry = false;

  @override
  Future<Result<QueueGapState>> readQueueGapState() {
    gapStateReads += 1;
    return _inner.readQueueGapState();
  }

  @override
  Future<Result<SyncProjection>> readProjection() {
    projectionReads += 1;
    return _inner.readProjection();
  }

  @override
  Future<Result<void>> recordEnvelopeInspectionRetry({
    required String envelopeId,
    required DateTime retryAt,
    required bool countsAgainstBudget,
  }) async {
    if (failInspectionRetry) {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    return _inner.recordEnvelopeInspectionRetry(
      envelopeId: envelopeId,
      retryAt: retryAt,
      countsAgainstBudget: countsAgainstBudget,
    );
  }

  @override
  Stream<SyncProjection> watchProjection() => _inner.watchProjection();

  @override
  Future<Result<void>> queuePreparedOperation({
    required String operationId,
    required String eventId,
    required List<PreparedOutboxTarget> targets,
  }) => _inner.queuePreparedOperation(
    operationId: operationId,
    eventId: eventId,
    targets: targets,
  );

  @override
  Future<Result<void>> requestAuthoritativeDrain() =>
      _inner.requestAuthoritativeDrain();

  @override
  Future<Result<void>> persistDrainPage(DrainPage page) =>
      _inner.persistDrainPage(page);

  @override
  Future<Result<SyncEnvelope?>> beginNextEnvelopeInspection({
    required DateTime now,
  }) => _inner.beginNextEnvelopeInspection(now: now);

  @override
  Future<Result<bool>> commitOpaqueInspection({
    required String envelopeId,
    required OpaqueEnvelopeInspection inspection,
  }) => _inner.commitOpaqueInspection(
    envelopeId: envelopeId,
    inspection: inspection,
  );

  @override
  Future<Result<void>> blockEnvelopeForQueueGap(String envelopeId) =>
      _inner.blockEnvelopeForQueueGap(envelopeId);

  @override
  Future<Result<void>> recordEnvelopeRejection({
    required String envelopeId,
    required int reasonCode,
  }) => _inner.recordEnvelopeRejection(
    envelopeId: envelopeId,
    reasonCode: reasonCode,
  );

  @override
  Future<Result<AcknowledgementBatch?>> beginAcknowledgementBatch({
    required DateTime now,
    required int maximumIds,
  }) => _inner.beginAcknowledgementBatch(now: now, maximumIds: maximumIds);

  @override
  Future<Result<void>> recordAcknowledgementSuccess({
    required AcknowledgementBatch batch,
    required DateTime now,
  }) => _inner.recordAcknowledgementSuccess(batch: batch, now: now);

  @override
  Future<Result<void>> recordAcknowledgementFailure({
    required AcknowledgementBatch batch,
    required DateTime retryAt,
  }) => _inner.recordAcknowledgementFailure(batch: batch, retryAt: retryAt);

  @override
  Future<Result<PendingSendPreparation?>> beginNextSendPreparation({
    required DateTime now,
  }) => _inner.beginNextSendPreparation(now: now);

  @override
  Future<Result<void>> recordSendPreparationRetry({
    required PendingSendPreparation preparation,
    required DateTime retryAt,
  }) => _inner.recordSendPreparationRetry(
    preparation: preparation,
    retryAt: retryAt,
  );

  @override
  Future<Result<void>> recordSendPreparationFailure({
    required PendingSendPreparation preparation,
  }) => _inner.recordSendPreparationFailure(preparation: preparation);

  @override
  Future<Result<OutboxBatch?>> beginNextOutboxBatch({required DateTime now}) =>
      _inner.beginNextOutboxBatch(now: now);

  @override
  Future<Result<void>> recordOutboxAcceptance({
    required OutboxBatch batch,
    required OutboxAcceptance acceptance,
    required DateTime now,
    required DateTime retryFullAt,
  }) => _inner.recordOutboxAcceptance(
    batch: batch,
    acceptance: acceptance,
    now: now,
    retryFullAt: retryFullAt,
  );

  @override
  Future<Result<void>> recordOutboxRetry({
    required OutboxBatch batch,
    required DateTime retryAt,
  }) => _inner.recordOutboxRetry(batch: batch, retryAt: retryAt);

  @override
  Future<Result<void>> recordOutboxPermanentFailure({
    required OutboxBatch batch,
    required DateTime now,
  }) => _inner.recordOutboxPermanentFailure(batch: batch, now: now);

  @override
  Future<Result<List<StaleDeviceRefreshWork>>> pendingStaleDeviceRefreshes({
    required DateTime now,
  }) => _inner.pendingStaleDeviceRefreshes(now: now);

  @override
  Future<Result<void>> completeStaleDeviceRefresh(String userId) =>
      _inner.completeStaleDeviceRefresh(userId);

  @override
  Future<Result<void>> retryStaleDeviceRefresh({
    required String userId,
    required DateTime retryAt,
  }) => _inner.retryStaleDeviceRefresh(userId: userId, retryAt: retryAt);

  @override
  Future<Result<void>> markConnectionPhase(SyncConnectionPhase phase) =>
      _inner.markConnectionPhase(phase);

  @override
  Future<Result<DurableReconnectState>> scheduleReconnect({
    required DateTime dueAt,
  }) => _inner.scheduleReconnect(dueAt: dueAt);

  @override
  Future<Result<DurableReconnectState>> readReconnectState() =>
      _inner.readReconnectState();

  @override
  Future<Result<void>> clearReconnect({required DateTime? syncedAt}) =>
      _inner.clearReconnect(syncedAt: syncedAt);

  @override
  Future<Result<void>> recordSuccessfulSync(DateTime syncedAt) =>
      _inner.recordSuccessfulSync(syncedAt);

  @override
  Future<Result<void>> markGroupRecovered(String groupId) =>
      _inner.markGroupRecovered(groupId);

  @override
  Future<Result<void>> markGroupLeft(String groupId) =>
      _inner.markGroupLeft(groupId);
}

/// An inspector that opens everything except the envelopes named in [poison].
final class ScriptedInspector implements OpaqueEnvelopeInspector {
  final Set<String> poison = {};
  Failure failure = const SecurityFailure(SecurityFailureKind.policyBlocked);
  int calls = 0;

  @override
  Future<Result<OpaqueEnvelopeInspection>> inspect({
    required String envelopeId,
    required Uint8List exactCiphertext,
    required bool allowPotentiallyMls,
  }) async {
    calls += 1;
    if (poison.contains(envelopeId)) {
      return Result.failure(failure);
    }
    return Result.success(
      OpaqueEnvelopeInspection(
        opaqueEventId: 'opaque-$envelopeId',
        dependency: EnvelopeDependency.directOrLocal,
      ),
    );
  }
}

final class FakeSyncRemote implements SyncRemotePort {
  final List<DrainPage> pages = [];
  final List<OutboxBatch> sentBatches = [];
  final List<List<String>> acknowledgedIds = [];

  @override
  Future<Result<DrainPage>> drain({required int limit}) async => Result.success(
    pages.isEmpty
        ? DrainPage(envelopes: const [], hasMore: false, prunedThrough: 0)
        : pages.removeAt(0),
  );

  @override
  Future<Result<int>> acknowledge(List<String> envelopeIds) async {
    acknowledgedIds.add(List.of(envelopeIds));
    return Result.success(envelopeIds.length);
  }

  @override
  Future<Result<OutboxAcceptance>> send(OutboxBatch batch) async {
    sentBatches.add(batch);
    return Result.success(
      OutboxAcceptance(
        accepted: batch.targets.length,
        staleDeviceIds: const {},
      ),
    );
  }
}

final class NoopStaleRefresh implements StaleDeviceRefreshPort {
  const NoopStaleRefresh();

  @override
  Future<Result<void>> refreshUserDevices(String userId) async =>
      const Result.success(null);
}

final class FakeClock implements TimeSource {
  FakeClock(this.value);

  DateTime value;

  void advance(Duration duration) => value = value.add(duration);

  @override
  DateTime now() => value;
}

final class ZeroJitter implements JitterSource {
  const ZeroJitter();

  @override
  int nextInt(int upperBoundExclusive) => 0;
}

String uuid(int value) =>
    '00000000-0000-0000-0000-${value.toRadixString(16).padLeft(12, '0')}';

Uint8List blob(int marker) =>
    Uint8List.fromList(List<int>.filled(1024, marker));
