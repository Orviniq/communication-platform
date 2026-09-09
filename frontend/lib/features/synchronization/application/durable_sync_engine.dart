// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';

final class SyncEngineLimits {
  const SyncEngineLimits({
    this.drainPageSize = 100,
    this.acknowledgementBatchSize = 200,
    this.maximumDrainPagesPerRun = 100,
    this.maximumInspectionsPerRun = 1000,
    this.maximumAcknowledgementBatchesPerRun = 100,
    this.maximumOutboxBatchesPerRun = 100,
    this.maximumSendPreparationsPerRun = 32,
    this.maximumStaleRefreshesPerRun = 32,
    this.maximumInspectionAttempts = 8,
    this.minimumInspectionRetry = const Duration(seconds: 1),
  }) : assert(drainPageSize >= 1),
       assert(acknowledgementBatchSize >= 1),
       assert(maximumDrainPagesPerRun > 0),
       assert(maximumInspectionsPerRun > 0),
       assert(maximumAcknowledgementBatchesPerRun > 0),
       assert(maximumOutboxBatchesPerRun > 0),
       assert(maximumSendPreparationsPerRun > 0),
       assert(maximumStaleRefreshesPerRun > 0),
       assert(maximumInspectionAttempts > 0);

  /// How many envelopes one page asks for, and how many ids one
  /// acknowledgement carries.
  ///
  /// Both are what this run *wants*, not what the deployment permits. The
  /// deployment's own ceilings — `drain_page_max` and `ack_max` — are held
  /// against these by the adapters that can see them, so a run that asks for
  /// more than an operator allows is cut down rather than refused, and this
  /// layer needs to know none of those numbers. They stay separate settings so
  /// a run with reason to take smaller bites — a background catch-up on a
  /// metered connection — still can.
  final int drainPageSize;
  final int acknowledgementBatchSize;

  final int maximumDrainPagesPerRun;
  final int maximumInspectionsPerRun;
  final int maximumAcknowledgementBatchesPerRun;
  final int maximumOutboxBatchesPerRun;

  /// How many echoed sends one run will seal.
  ///
  /// Lower than the outbox budget because a preparation is the expensive half:
  /// two authenticated device lookups, possibly a prekey claim, and one ratchet
  /// step per recipient device, against a batch send that is one request. A run
  /// that hits this reports itself deferred and the next one continues.
  final int maximumSendPreparationsPerRun;
  final int maximumStaleRefreshesPerRun;

  /// How many times inspecting one envelope may fail for a cause that will not
  /// resolve itself before the envelope is quarantined and acknowledged.
  ///
  /// Without a ceiling there is no terminal state for an envelope this device
  /// can never open: it is re-served by the server on every drain, re-fetched,
  /// re-inspected, re-failed, and counted forever in `pending_inbound`. Eight
  /// is generous for a cause that is already known not to be transient, and it
  /// is a field rather than a constant so a test can set it to two.
  final int maximumInspectionAttempts;

  /// The shortest time an envelope left for later may become due again.
  ///
  /// [SyncRetryPolicy] draws uniformly from `[0, cap]` and so returns zero on a
  /// real fraction of draws. That is harmless for a batch the run will not look
  /// at again, and wrong for an envelope the same pass is about to re-read from
  /// the head of the queue: a zero backoff on the lowest-sequence row is a
  /// pass that inspects one envelope a thousand times and never reaches the
  /// second. A floor is what makes "leave it for later" mean later.
  final Duration minimumInspectionRetry;
}

final class SyncRetryPolicy {
  const SyncRetryPolicy({
    this.baseDelay = const Duration(seconds: 1),
    this.maximumDelay = const Duration(minutes: 15),
  });

  final Duration baseDelay;
  final Duration maximumDelay;

  Duration delayFor({
    required int attempt,
    required Failure failure,
    required JitterSource jitter,
  }) {
    if (failure case BackendFailure(
      code: BackendFailureCode.rateLimited,
      retryAfter: final retryAfter?,
    )) {
      return retryAfter;
    }
    final exponent = (attempt - 1).clamp(0, 20);
    final multiplier = 1 << exponent;
    final uncapped = baseDelay.inMilliseconds * multiplier;
    final capMilliseconds = uncapped > maximumDelay.inMilliseconds
        ? maximumDelay.inMilliseconds
        : uncapped;
    if (capMilliseconds <= 0) {
      return Duration.zero;
    }
    return Duration(milliseconds: jitter.nextInt(capMilliseconds + 1));
  }
}

/// Crash-safe coordinator for the durable queue only.
///
/// All network requests are preceded by a Drift journal transition. A response is
/// recorded in a second transaction. Consequently process death can only cause an
/// idempotent acknowledgement or exact-ciphertext send to be retried.
final class DurableSyncEngine {
  DurableSyncEngine({
    required DurableSyncStore store,
    required SyncRemotePort remote,
    required OpaqueEnvelopeInspector inspector,
    required StaleDeviceRefreshPort staleDeviceRefresh,
    required TimeSource clock,
    required JitterSource jitter,
    PostInboxCommitWorkPort? postInboxCommitWork,
    SendPreparationPort? sendPreparation,
    DeliveryStandDownSignal standDown = const NeverStandsDown(),
    this.retryPolicy = const SyncRetryPolicy(),
    this.limits = const SyncEngineLimits(),
  }) : _store = store,
       _remote = remote,
       _inspector = inspector,
       _staleDeviceRefresh = staleDeviceRefresh,
       _clock = clock,
       _jitter = jitter,
       _postInboxCommitWork = postInboxCommitWork,
       _sendPreparation = sendPreparation,
       _standDown = standDown;

  final DurableSyncStore _store;
  final SyncRemotePort _remote;
  final OpaqueEnvelopeInspector _inspector;
  final StaleDeviceRefreshPort _staleDeviceRefresh;
  final TimeSource _clock;
  final JitterSource _jitter;
  final PostInboxCommitWorkPort? _postInboxCommitWork;
  final SendPreparationPort? _sendPreparation;

  /// Read between units of work, never in the middle of one. A cycle that is
  /// asked to give way finishes the envelope, batch or transaction it is
  /// holding and then reports `deferred`, which is the same thing it reports
  /// when it hits a per-run limit: work remains, and the next owner does it.
  final DeliveryStandDownSignal _standDown;

  final SyncRetryPolicy retryPolicy;
  final SyncEngineLimits limits;

  Future<Result<SyncRunReport>>? _activeRun;

  Future<Result<void>> queuePreparedOperation({
    required String operationId,
    required String eventId,
    required List<PreparedOutboxTarget> targets,
  }) => _store.queuePreparedOperation(
    operationId: operationId,
    eventId: eventId,
    targets: targets,
  );

  Future<Result<SyncRunReport>> synchronize() {
    final active = _activeRun;
    if (active != null) {
      return active;
    }
    final run = _run();
    _activeRun = run;
    return run.whenComplete(() {
      if (identical(_activeRun, run)) {
        _activeRun = null;
      }
    });
  }

  Future<Result<SyncRunReport>> _run() async {
    final phaseResult = await _store.markConnectionPhase(
      SyncConnectionPhase.draining,
    );
    if (phaseResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }

    final progress = _RunProgress();

    // The outbox goes first now, and it goes again at the end.
    //
    // It used to go last, behind the whole inbound half of the cycle, and every
    // stage of that half ended the run on its first failure. One envelope this
    // device could not open was therefore enough to stop a message the user had
    // already sent from ever leaving the process. Nothing a queued outbox row
    // needs comes from the inbox: its per-recipient ciphertext is sealed and
    // durable before the row exists, so the only thing this ordering decides is
    // who waits for whom. The second pass exists because the inbound half
    // queues rows of its own — delivery receipts, group Commits, eviction
    // fan-out — and they are ready by the time it finishes.
    // Before the outbox, because a send the user has already made is not in
    // the outbox yet. Its event is committed and on their screen; what it is
    // waiting for is the fan-out that seals it, and doing that here means the
    // same cycle carries it all the way to the wire.
    final firstPreparation = await _prepareSends(progress);
    if (firstPreparation case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }

    final firstOutbox = await _flushOutbox(progress);
    if (firstOutbox case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }

    final existingInbox = await _processInbox(progress);
    if (existingInbox case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    await _runPostInboxWork();

    final existingAcks = await _flushAcknowledgements(progress);
    if (existingAcks case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }

    final drained = await _drainPages(progress);
    if (drained case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }

    // Only while the cycle is still healthy. A transport that has already
    // refused one batch will refuse this one, and the rows the inbound half
    // queued are durable — the next cycle sends them.
    if (progress.failure == null) {
      // The inbound half queues sends of its own — a delivered receipt is an
      // application event like any other — so the second pass owes them the
      // same preparation.
      final finalPreparation = await _prepareSends(progress);
      if (finalPreparation case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final finalOutbox = await _flushOutbox(progress);
      if (finalOutbox case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
    }

    final refreshes = await _refreshStaleDevices();
    if (refreshes case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }

    // Carried, rather than returned at the point it happened. A drain the
    // server refused or a batch the transport could not deliver still means
    // this cycle failed, and the supervisor still has to be told so it can back
    // off — but the local half of the cycle runs to completion first, which is
    // the whole point of the reordering above. Per-envelope failures are never
    // carried here: they belong to their envelope, they are counted in the
    // report, and a mailbox holding one is still a healthy session.
    final carried = progress.failure;
    if (carried != null) {
      return Result.failure(carried);
    }

    final finishedAt = _clock.now();
    final recordedSync = await _store.recordSuccessfulSync(finishedAt);
    if (recordedSync case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final online = await _store.markConnectionPhase(SyncConnectionPhase.online);
    if (online case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(progress.report());
  }

  /// Drains authoritative pages until the server says there are none left.
  ///
  /// Returns failure only when the store itself could not be written. A page
  /// the transport could not fetch, or one that violated a server invariant, is
  /// carried out through [progress] so that the rest of the run still happens.
  Future<Result<void>> _drainPages(_RunProgress progress) async {
    for (
      var pageIndex = 0;
      pageIndex < limits.maximumDrainPagesPerRun;
      pageIndex += 1
    ) {
      if (_standDown.standDownRequested) {
        progress.deferred = true;
        return const Result.success(null);
      }
      final drain = await _remote.drain(limit: limits.drainPageSize);
      if (drain case FailureResult(failure: final failure)) {
        progress.fail(failure);
        return const Result.success(null);
      }
      final page = (drain as Success<DrainPage>).value;
      progress.drainedPages += 1;
      final persisted = await _store.persistDrainPage(page);
      if (persisted case FailureResult(failure: final failure)) {
        if (failure is StorageFailure) {
          return Result.failure(failure);
        }
        // A re-served envelope whose ciphertext or sequence disagrees with the
        // stored one is a server invariant violation, not an envelope fault. It
        // ends the drain and is reported, and the local half of the cycle still
        // finishes.
        progress.fail(failure);
        return const Result.success(null);
      }

      final inspectedBefore = progress.inspected;
      final inbox = await _processInbox(progress);
      if (inbox case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      await _runPostInboxWork();

      final acknowledgedBefore = progress.acknowledged;
      final acks = await _flushAcknowledgements(progress);
      if (acks case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }

      if (!page.hasMore) {
        return const Result.success(null);
      }
      if (progress.inspected == inspectedBefore &&
          progress.acknowledged == acknowledgedBefore) {
        progress.deferred = true;
        return const Result.success(null);
      }
      if (pageIndex + 1 == limits.maximumDrainPagesPerRun) {
        progress.deferred = true;
      }
    }
    return const Result.success(null);
  }

  /// Seals every echoed send whose fan-out is due.
  ///
  /// The shape is the outbox's, and deliberately so: a cause that says this
  /// device cannot reach the server ends the stage and is carried out through
  /// [progress], because the next preparation would fail the same way and the
  /// rows are durable. A cause that is settled — a peer with no device this
  /// build can encrypt to, a claim the server refused on its contents — is
  /// retired against that one send, and the stage continues to the next.
  ///
  /// A retired send is not silence. It leaves the message on screen in the one
  /// state the timeline offers a retry from, which is the only honest thing to
  /// show for bytes that will never be sealed.
  ///
  /// The two classes are the ones [_isTransientEnvelopeFailure] already draws.
  /// The question is the same one: has this device learned anything about the
  /// work in hand, or only about its own connection? A device that is offline,
  /// rate limited, out of storage or momentarily out of entropy has learned
  /// nothing, and retiring a send on that would tell somebody their message
  /// failed because their train went into a tunnel.
  ///
  /// Returns failure only when the store itself could not be written.
  Future<Result<void>> _prepareSends(_RunProgress progress) async {
    final preparer = _sendPreparation;
    if (preparer == null) {
      return const Result.success(null);
    }
    for (
      var index = 0;
      index < limits.maximumSendPreparationsPerRun;
      index += 1
    ) {
      if (_standDown.standDownRequested) {
        progress.deferred = true;
        return const Result.success(null);
      }
      final now = _clock.now();
      final owedResult = await _store.beginNextSendPreparation(now: now);
      if (owedResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final owed = (owedResult as Success<PendingSendPreparation?>).value;
      if (owed == null) {
        return const Result.success(null);
      }
      final prepared = await preparer.prepare(owed);
      if (prepared case FailureResult(failure: final failure)) {
        if (!_isTransientEnvelopeFailure(failure)) {
          final retired = await _store.recordSendPreparationFailure(
            preparation: owed,
          );
          if (retired case FailureResult(failure: final storageFailure)) {
            return Result.failure(storageFailure);
          }
          continue;
        }
        final retry = await _store.recordSendPreparationRetry(
          preparation: owed,
          retryAt: now.add(
            retryPolicy.delayFor(
              attempt: owed.attempt,
              failure: failure,
              jitter: _jitter,
            ),
          ),
        );
        if (retry case FailureResult(failure: final storageFailure)) {
          return Result.failure(storageFailure);
        }
        progress.fail(failure);
        return const Result.success(null);
      }
      progress.prepared += 1;
    }
    progress.deferred = true;
    return const Result.success(null);
  }

  /// Sends every outbox batch that is due.
  ///
  /// Returns failure only when the store itself could not be written. A batch
  /// the server refused permanently is retired against that batch; one the
  /// transport could not deliver is left in retry-wait and the failure is
  /// carried out through [progress].
  Future<Result<void>> _flushOutbox(_RunProgress progress) async {
    for (var index = 0; index < limits.maximumOutboxBatchesPerRun; index += 1) {
      if (_standDown.standDownRequested) {
        progress.deferred = true;
        return const Result.success(null);
      }
      final now = _clock.now();
      final batchResult = await _store.beginNextOutboxBatch(now: now);
      if (batchResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final batch = (batchResult as Success<OutboxBatch?>).value;
      if (batch == null) {
        return const Result.success(null);
      }
      final response = await _remote.send(batch);
      if (response case FailureResult(failure: final failure)) {
        if (_isPermanentSendFailure(failure)) {
          final recorded = await _store.recordOutboxPermanentFailure(
            batch: batch,
            now: now,
          );
          if (recorded case FailureResult(failure: final storageFailure)) {
            return Result.failure(storageFailure);
          }
          continue;
        }
        final retry = await _store.recordOutboxRetry(
          batch: batch,
          retryAt: now.add(
            retryPolicy.delayFor(
              attempt: batch.attempt,
              failure: failure,
              jitter: _jitter,
            ),
          ),
        );
        if (retry case FailureResult(failure: final storageFailure)) {
          return Result.failure(storageFailure);
        }
        progress.fail(failure);
        return const Result.success(null);
      }
      final acceptance = (response as Success<OutboxAcceptance>).value;
      if (!_isValidAcceptance(batch, acceptance)) {
        const failure = SecurityFailure(
          SecurityFailureKind.malformedServerResponse,
        );
        final retry = await _store.recordOutboxRetry(
          batch: batch,
          retryAt: now.add(
            retryPolicy.delayFor(
              attempt: batch.attempt,
              failure: failure,
              jitter: _jitter,
            ),
          ),
        );
        if (retry case FailureResult(failure: final storageFailure)) {
          return Result.failure(storageFailure);
        }
        progress.fail(failure);
        return const Result.success(null);
      }
      final recorded = await _store.recordOutboxAcceptance(
        batch: batch,
        acceptance: acceptance,
        now: now,
        // A full mailbox is cleared by its owner collecting their post and by
        // nothing this device can do, so the item waits out the ordinary
        // backoff rather than being re-offered on the next pass of this run.
        // The attempt is the batch's, so a device that stays full backs off
        // further each time instead of spending the run on refusals.
        retryFullAt: now.add(
          retryPolicy.delayFor(
            attempt: batch.attempt,
            failure: const StorageFailure(StorageFailureKind.capacityExceeded),
            jitter: _jitter,
          ),
        ),
      );
      if (recorded case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      progress.sent += acceptance.accepted;
    }
    progress.deferred = true;
    return const Result.success(null);
  }

  Future<void> _runPostInboxWork() async {
    try {
      await _postInboxCommitWork?.run();
    } on Object {
      // Delivery receipts are best effort and remain in their durable local
      // work table. They never block acknowledgement of an applied envelope.
    }
  }

  Future<Result<void>> _processInbox(_RunProgress progress) async {
    // Read once per pass, not once per envelope.
    //
    // The gap flag is one column on the singleton checkpoint row, and only
    // `persistDrainPage` sets it — which happens between calls to this method,
    // never inside one. Nothing this loop does can clear it either: while a gap
    // is open the inspector is forbidden from advancing MLS state, so the
    // authenticated re-admission that retires the obligation cannot be
    // committed from here. Reading it per envelope re-ran a three-subquery
    // aggregate over the two largest tables in the database up to
    // `maximumInspectionsPerRun` times per pass, for an answer that cannot
    // change while the pass runs.
    final gapResult = await _store.readQueueGapState();
    if (gapResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final gapBlocked =
        (gapResult as Success<QueueGapState>).value ==
        QueueGapState.recoveryRequired;

    // Every envelope this pass has already been handed. Only a deferred one can
    // come back — an applied envelope advances and a blocked one moves out of
    // the due set — and the retry floor below ordinarily keeps even that from
    // happening inside the same pass. But a pass working through a large
    // mailbox can outlive the floor, and the row it deferred first is also the
    // lowest-sequence one, so without this it would return to the head of the
    // queue and be handed out again in place of everything behind it.
    final handled = <String>{};

    for (var index = 0; index < limits.maximumInspectionsPerRun; index += 1) {
      if (_standDown.standDownRequested) {
        progress.deferred = true;
        return const Result.success(null);
      }
      final envelopeResult = await _store.beginNextEnvelopeInspection(
        now: _clock.now(),
      );
      if (envelopeResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final envelope = (envelopeResult as Success<SyncEnvelope?>).value;
      if (envelope == null) {
        return const Result.success(null);
      }
      if (!handled.add(envelope.id)) {
        // The head of the queue is something this pass has already dealt with,
        // so there is nothing new here. The pass ends; the drain, the
        // acknowledgements and the outbox all still run, and the next cycle
        // picks this up.
        progress.deferred = true;
        return const Result.success(null);
      }
      final inspection = await _inspector.inspect(
        envelopeId: envelope.id,
        exactCiphertext: envelope.exactCiphertext,
        allowPotentiallyMls: !gapBlocked,
      );
      if (inspection case FailureResult(failure: final failure)) {
        final recorded = await _recordEnvelopeFailure(
          envelope: envelope,
          failure: failure,
          progress: progress,
        );
        if (recorded case FailureResult(failure: final storageFailure)) {
          return Result.failure(storageFailure);
        }
        continue;
      }
      final inspectedEnvelope =
          (inspection as Success<OpaqueEnvelopeInspection>).value;
      if (gapBlocked &&
          inspectedEnvelope.dependency == EnvelopeDependency.potentiallyMls) {
        final blockedResult = await _store.blockEnvelopeForQueueGap(
          envelope.id,
        );
        if (blockedResult case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        progress.blocked += 1;
        continue;
      }
      final committed = await _store.commitOpaqueInspection(
        envelopeId: envelope.id,
        inspection: inspectedEnvelope,
      );
      if (committed case FailureResult(failure: final failure)) {
        // A commit that could not be written at all is the store being
        // unavailable, and that ends the run. Anything else — a row that moved
        // underneath this inspection, a projection the transaction refused —
        // belongs to this envelope exactly as an inspection failure does.
        if (failure is StorageFailure) {
          return Result.failure(failure);
        }
        final recorded = await _recordEnvelopeFailure(
          envelope: envelope,
          failure: failure,
          progress: progress,
        );
        if (recorded case FailureResult(failure: final storageFailure)) {
          return Result.failure(storageFailure);
        }
        continue;
      }
      progress.inspected += 1;
      if (index + 1 == limits.maximumInspectionsPerRun) {
        progress.deferred = true;
      }
    }
    return const Result.success(null);
  }

  /// Records one envelope's failure against that envelope, and returns.
  ///
  /// It returns failure only when the store could not record the outcome, which
  /// is the single condition under which continuing is unsafe: a run that
  /// cannot write cannot make progress, and would spin. Everything else stays
  /// where it belongs — on the envelope — so a mailbox holding one unopenable
  /// message still drains, still acknowledges, and still sends.
  Future<Result<void>> _recordEnvelopeFailure({
    required SyncEnvelope envelope,
    required Failure failure,
    required _RunProgress progress,
  }) {
    if (_isRejectableEnvelopeFailure(failure)) {
      return _quarantineEnvelope(
        envelope: envelope,
        failure: failure,
        progress: progress,
      );
    }
    final transient = _isTransientEnvelopeFailure(failure);
    if (!transient &&
        envelope.inspectionFailures + 1 >= limits.maximumInspectionAttempts) {
      // A cause that will not succeed on a retry, tried as often as this engine
      // is willing to try it. Without a budget the envelope was re-served by
      // the server, re-fetched, re-inspected and re-failed forever, which is
      // what a frozen `pending_inbound` beside `quarantined_input=0` looks like
      // from outside the process. Quarantining marks it terminal locally; the
      // acknowledgement that follows is what makes the server stop serving it.
      return _quarantineEnvelope(
        envelope: envelope,
        failure: failure,
        progress: progress,
      );
    }
    progress.failedInspections += 1;
    final backoff = retryPolicy.delayFor(
      attempt: envelope.attempt,
      failure: failure,
      jitter: _jitter,
    );
    return _store.recordEnvelopeInspectionRetry(
      envelopeId: envelope.id,
      retryAt: _clock.now().add(
        backoff < limits.minimumInspectionRetry
            ? limits.minimumInspectionRetry
            : backoff,
      ),
      countsAgainstBudget: !transient,
    );
  }

  Future<Result<void>> _quarantineEnvelope({
    required SyncEnvelope envelope,
    required Failure failure,
    required _RunProgress progress,
  }) async {
    final rejected = await _store.recordEnvelopeRejection(
      envelopeId: envelope.id,
      reasonCode: _rejectionReason(failure),
    );
    if (rejected case FailureResult(failure: final storageFailure)) {
      return Result.failure(storageFailure);
    }
    progress.quarantined += 1;
    return const Result.success(null);
  }

  Future<Result<void>> _flushAcknowledgements(_RunProgress progress) async {
    for (
      var index = 0;
      index < limits.maximumAcknowledgementBatchesPerRun;
      index += 1
    ) {
      final now = _clock.now();
      final batchResult = await _store.beginAcknowledgementBatch(
        now: now,
        maximumIds: limits.acknowledgementBatchSize,
      );
      if (batchResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final batch = (batchResult as Success<AcknowledgementBatch?>).value;
      if (batch == null) {
        return const Result.success(null);
      }
      final response = await _remote.acknowledge(batch.envelopeIds);
      if (response case FailureResult(failure: final failure)) {
        final retry = await _store.recordAcknowledgementFailure(
          batch: batch,
          retryAt: now.add(
            retryPolicy.delayFor(
              attempt: batch.attempt,
              failure: failure,
              jitter: _jitter,
            ),
          ),
        );
        if (retry case FailureResult(failure: final storageFailure)) {
          return Result.failure(storageFailure);
        }
        progress.fail(failure);
        return const Result.success(null);
      }
      final recorded = await _store.recordAcknowledgementSuccess(
        batch: batch,
        now: now,
      );
      if (recorded case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      progress.acknowledged += batch.envelopeIds.length;
    }
    return const Result.success(null);
  }

  Future<Result<void>> _refreshStaleDevices() async {
    final pending = await _store.pendingStaleDeviceRefreshes(now: _clock.now());
    if (pending case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    var count = 0;
    for (final work
        in (pending as Success<List<StaleDeviceRefreshWork>>).value) {
      if (count >= limits.maximumStaleRefreshesPerRun) {
        break;
      }
      count += 1;
      final refreshed = await _staleDeviceRefresh.refreshUserDevices(
        work.userId,
      );
      if (refreshed case FailureResult(failure: final failure)) {
        final retryAt = _clock.now().add(
          retryPolicy.delayFor(
            attempt: work.attempt,
            failure: failure,
            jitter: _jitter,
          ),
        );
        final recorded = await _store.retryStaleDeviceRefresh(
          userId: work.userId,
          retryAt: retryAt,
        );
        if (recorded case FailureResult(failure: final storageFailure)) {
          return Result.failure(storageFailure);
        }
        continue;
      }
      final completed = await _store.completeStaleDeviceRefresh(work.userId);
      if (completed case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
    }
    return const Result.success(null);
  }

  /// Whether one answer accounts for exactly the batch that was sent.
  ///
  /// Every device the server names must be one this batch addressed, and
  /// `accepted` must be the batch less the two kinds it did not write: the
  /// stale devices, which are gone, and the full ones, which are live and out
  /// of room. An answer that does not add up is not a partial success to
  /// record — it is a response this client cannot act on, so the batch is
  /// retried whole.
  bool _isValidAcceptance(OutboxBatch batch, OutboxAcceptance acceptance) {
    final targetIds = batch.targets
        .map((target) => target.recipientDeviceId)
        .toSet();
    return targetIds.containsAll(acceptance.staleDeviceIds) &&
        targetIds.containsAll(acceptance.fullDeviceIds) &&
        acceptance.accepted ==
            batch.targets.length -
                acceptance.staleDeviceIds.length -
                acceptance.fullDeviceIds.length;
  }

  bool _isPermanentSendFailure(Failure failure) {
    if (failure is ValidationFailure) {
      return true;
    }
    return failure is BackendFailure &&
        const {
          BackendFailureCode.invalidRequest,
          BackendFailureCode.badRequest,
          BackendFailureCode.badBucket,
        }.contains(failure.code);
  }

  bool _isRejectableEnvelopeFailure(Failure failure) =>
      failure is ValidationFailure ||
      (failure is SecurityFailure &&
          failure.kind != SecurityFailureKind.policyBlocked);

  /// Whether a cause may succeed later without anything about the envelope
  /// changing.
  ///
  /// A transient cause never consumes the attempt budget. A device that is
  /// offline, rate limited, out of storage or momentarily out of entropy has
  /// learned nothing about the bytes in hand, and spending the budget on it
  /// would quarantine messages this device could have opened. Everything not
  /// listed here has already been decided: the native core refused these bytes,
  /// policy rejected them, or the protocol is one this build does not
  /// implement — and no later attempt changes any of those.
  bool _isTransientEnvelopeFailure(Failure failure) => switch (failure) {
    TransportFailure() => true,
    StorageFailure() => true,
    CancellationFailure() => true,
    AuthenticationFailure() => true,
    BackendFailure(:final code) =>
      code == BackendFailureCode.rateLimited ||
          code == BackendFailureCode.quotaExceeded ||
          // Every 5xx the backend mapper cannot name arrives as `unknown`.
          code == BackendFailureCode.unknown,
    CryptoCoreFailure(:final code) =>
      code == CryptoCoreFailureCode.resourceExhausted ||
          code == CryptoCoreFailureCode.entropyUnavailable,
    ValidationFailure() ||
    SecurityFailure() ||
    UnsupportedProtocolFailure() => false,
  };

  int _rejectionReason(Failure failure) => switch (failure.category) {
    FailureCategory.validation => 1,
    FailureCategory.security => 2,
    FailureCategory.unsupportedProtocol => 3,
    _ => 4,
  };
}

/// What one run has done so far, and the one failure it will report.
///
/// A run used to return the moment any stage failed, which is why a device with
/// an unopenable envelope in its inbox never reached its own outbox. Progress
/// accumulates here instead and the run finishes; a failure that says the
/// session rather than one envelope is unhealthy is held in [failure] and
/// returned at the end, so the supervisor still backs off on a transport that
/// will not carry a request.
final class _RunProgress {
  int drainedPages = 0;
  int inspected = 0;
  int blocked = 0;
  int acknowledged = 0;
  int sent = 0;
  int prepared = 0;
  int quarantined = 0;
  int failedInspections = 0;
  bool deferred = false;
  Failure? failure;

  /// Keeps the first such failure. A later one is a consequence of the first
  /// far more often than it is new information.
  void fail(Failure value) => failure ??= value;

  SyncRunReport report() => SyncRunReport(
    drainedPages: drainedPages,
    inspectedEnvelopes: inspected,
    acknowledgedEnvelopes: acknowledged,
    sentTargets: sent,
    deferred: deferred,
    quarantinedEnvelopes: quarantined,
    failedInspections: failedInspections,
    preparedSends: prepared,
  );
}
