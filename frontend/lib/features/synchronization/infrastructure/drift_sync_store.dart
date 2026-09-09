import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:drift/drift.dart';

/// The persisted ordinals of `pending_send_preparations.state`.
const int _preparationOwed = 0;
const int _preparationFailed = 1;

final class DriftSyncStore implements DurableSyncStore {
  const DriftSyncStore(
    this.database, {
    this.config = const FixedServerConfig.fallback(),
    this.maximumInboxEntries = 10000,
    this.maximumOutboxTargets = 50000,
    this.projectionWindow = const Duration(milliseconds: 250),
  }) : assert(maximumInboxEntries > 0),
       assert(maximumOutboxTargets > 0),
       assert(projectionWindow >= Duration.zero);

  final LocalDatabase database;

  /// The deployment's ceilings, which this store measures the server's answers
  /// against and cuts its own batches to.
  ///
  /// It holds the same numbers the transport does, and must: a page the
  /// transport accepted and this refused would be an envelope lost between two
  /// copies of one limit.
  final ServerConfigSnapshot config;

  final int maximumInboxEntries;
  final int maximumOutboxTargets;

  /// How long [watchProjection] holds a value before re-emitting.
  ///
  /// A knob so a test can collapse it to one turn of the event loop rather than
  /// wait out a real timer. In the application it is a quarter of a second,
  /// which is invisible next to the socket and REST round trips either side of
  /// it and short enough that a queued send is still signalled promptly: a
  /// window is only ever open because the engine just wrote something, and an
  /// idle process has no open window to wait out.
  final Duration projectionWindow;

  @override
  Stream<SyncProjection> watchProjection() async* {
    await _ensureCheckpoint();
    final query = database.customSelect(
      '''
SELECT
  c.highest_contiguous_acked_sequence,
  c.pruned_through,
  c.queue_gap_state,
  c.connection_phase,
  c.reconnect_at,
  c.last_successful_sync_at,
  (SELECT COUNT(*) FROM inbox_envelopes WHERE processing_state != 4) AS inbox_depth,
  (SELECT COUNT(*) FROM (
    SELECT operation_id FROM outbox_operations WHERE attempt_state IN (0, 1, 2)
    UNION
    SELECT operation_id FROM pending_send_preparations WHERE state = 0
  )) AS outbox_depth,
  (SELECT MIN(candidate) FROM (
    SELECT next_attempt_at AS candidate FROM inbox_envelopes
      WHERE processing_state IN (0, 1, 2, 3) AND next_attempt_at IS NOT NULL
    UNION ALL
    SELECT next_attempt_at AS candidate FROM outbox_operations
      WHERE attempt_state IN (0, 1, 2) AND next_attempt_at IS NOT NULL
    UNION ALL
    SELECT next_attempt_at AS candidate FROM pending_send_preparations
      WHERE state = 0 AND next_attempt_at IS NOT NULL
    UNION ALL
    SELECT reconnect_at AS candidate FROM sync_checkpoint
      WHERE reconnect_at IS NOT NULL
  )) AS next_retry_at
FROM sync_checkpoint c
WHERE c.singleton_id = 1
''',
      readsFrom: {
        database.syncCheckpoints,
        database.inboxEnvelopes,
        database.outboxOperations,
        database.pendingSendPreparations,
      },
    );
    yield* _conflated(
      query.watchSingle().map(_projectionFromRow),
      // Growth of the durable outbox is never held back. It is the one
      // transition in this projection that somebody is waiting on — a message
      // the user has already sent, whose only route out of this process is a
      // listener noticing the depth rise — so it goes out the moment it
      // happens, and the window governs everything else.
      urgent: (previous, next) => next.outboxDepth > previous.outboxDepth,
    );
  }

  /// One projection at a time, and never more often than [projectionWindow].
  ///
  /// The query above is a three-subquery aggregate over `sync_checkpoint`,
  /// `inbox_envelopes` and `outbox_operations` — precisely the three tables the
  /// engine writes on every state transition — so an unconflated watch re-runs
  /// the whole aggregate once per write and re-delivers it to every listener.
  ///
  /// Every property a listener depends on survives. The first value is emitted
  /// immediately, which is what lets a restart replay the durable outbox depth
  /// and drain what was queued before the process died. The last value of every
  /// window is always emitted, so no state is skipped — only the intermediate
  /// values a writer passed through on its way there. And a value [urgent]
  /// accepts bypasses an open window entirely, so conflation can never cost a
  /// send its latency.
  Stream<T> _conflated<T>(
    Stream<T> source, {
    required bool Function(T previous, T next) urgent,
  }) {
    late StreamController<T> controller;
    StreamSubscription<T>? subscription;
    Timer? timer;
    var hasPending = false;
    late T pending;
    T? emitted;
    var closed = false;

    void emit(T value) {
      emitted = value;
      if (!controller.isClosed) {
        controller.add(value);
      }
    }

    void openWindow() {
      timer = Timer(projectionWindow, () {
        timer = null;
        if (!hasPending) {
          return;
        }
        hasPending = false;
        emit(pending);
        openWindow();
      });
    }

    controller = StreamController<T>(
      onListen: () {
        subscription = source.listen(
          (value) {
            final previous = emitted;
            if (timer == null ||
                (previous != null && urgent(previous, value))) {
              // Whatever was waiting is superseded: this value is newer, and it
              // is going out now. The window restarts from here so an urgent
              // value does not become a way to bypass conflation entirely.
              timer?.cancel();
              hasPending = false;
              emit(value);
              openWindow();
              return;
            }
            pending = value;
            hasPending = true;
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!controller.isClosed) {
              controller.addError(error, stackTrace);
            }
          },
          onDone: () {
            closed = true;
            // A trailing value is never dropped: the source ending is the last
            // chance to deliver it.
            if (hasPending) {
              hasPending = false;
              emit(pending);
            }
            timer?.cancel();
            timer = null;
            unawaited(controller.close());
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        timer?.cancel();
        timer = null;
        hasPending = false;
        if (!closed) {
          await subscription?.cancel();
        }
        subscription = null;
      },
    );
    return controller.stream;
  }

  @override
  Future<Result<QueueGapState>> readQueueGapState() async {
    try {
      final checkpoint = await _checkpoint();
      return Result.success(
        checkpoint.queueGapState == QueueGapState.clear.index
            ? QueueGapState.clear
            : QueueGapState.recoveryRequired,
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<SyncProjection>> readProjection() async {
    try {
      await _ensureCheckpoint();
      final row = await database.customSelect('''
SELECT
  c.highest_contiguous_acked_sequence,
  c.pruned_through,
  c.queue_gap_state,
  c.connection_phase,
  c.reconnect_at,
  c.last_successful_sync_at,
  (SELECT COUNT(*) FROM inbox_envelopes WHERE processing_state != 4) AS inbox_depth,
  (SELECT COUNT(*) FROM (
    SELECT operation_id FROM outbox_operations WHERE attempt_state IN (0, 1, 2)
    UNION
    SELECT operation_id FROM pending_send_preparations WHERE state = 0
  )) AS outbox_depth,
  (SELECT MIN(candidate) FROM (
    SELECT next_attempt_at AS candidate FROM inbox_envelopes
      WHERE processing_state IN (0, 1, 2, 3) AND next_attempt_at IS NOT NULL
    UNION ALL
    SELECT next_attempt_at AS candidate FROM outbox_operations
      WHERE attempt_state IN (0, 1, 2) AND next_attempt_at IS NOT NULL
    UNION ALL
    SELECT next_attempt_at AS candidate FROM pending_send_preparations
      WHERE state = 0 AND next_attempt_at IS NOT NULL
    UNION ALL
    SELECT reconnect_at AS candidate FROM sync_checkpoint
      WHERE reconnect_at IS NOT NULL
  )) AS next_retry_at
FROM sync_checkpoint c
WHERE c.singleton_id = 1
''').getSingle();
      return Result.success(_projectionFromRow(row));
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> queuePreparedOperation({
    required String operationId,
    required String eventId,
    required List<PreparedOutboxTarget> targets,
  }) async {
    if (operationId.isEmpty ||
        eventId.isEmpty ||
        targets.isEmpty ||
        targets.any(
          (target) =>
              !_isUuid(target.recipientDeviceId) ||
              target.recipientUserId.isEmpty ||
              !config.current.envelopeBuckets.contains(
                target.exactCiphertext.length,
              ),
        )) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final sorted = List<PreparedOutboxTarget>.of(targets)
      ..sort(
        (left, right) =>
            _compareUuidBytes(left.recipientDeviceId, right.recipientDeviceId),
      );
    if (sorted
            .map((target) => target.recipientDeviceId.toLowerCase())
            .toSet()
            .length !=
        sorted.length) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    }
    try {
      await database.writeTransaction(() async {
        final existing = await (database.select(
          database.outboxOperations,
        )..where((row) => row.operationId.equals(operationId))).get();
        if (existing.isNotEmpty) {
          if (existing.any((row) => row.eventId != eventId) ||
              !_samePreparedTargets(existing, sorted)) {
            throw const _SyncConflict();
          }
          return;
        }
        final currentCount = await _count(database.outboxOperations);
        if (currentCount + sorted.length > maximumOutboxTargets) {
          throw const _SyncCapacity();
        }
        for (var index = 0; index < sorted.length; index += 1) {
          final target = sorted[index];
          await database
              .into(database.outboxOperations)
              .insert(
                OutboxOperationsCompanion.insert(
                  operationId: operationId,
                  eventId: eventId,
                  recipientDeviceId: target.recipientDeviceId.toLowerCase(),
                  recipientUserId: Value(target.recipientUserId),
                  batchIndex: index ~/ config.current.sendBatchMax,
                  exactRecipientCiphertext: target.exactCiphertext,
                  attemptState: OutboxAttemptState.queued.index,
                ),
              );
        }
      });
      return const Result.success(null);
    } on _SyncConflict {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    } on _SyncCapacity {
      return const Result.failure(
        StorageFailure(StorageFailureKind.capacityExceeded),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> requestAuthoritativeDrain() => _write(() async {
    await _ensureCheckpointInTransaction();
    await (database.update(database.syncCheckpoints)
          ..where((row) => row.singletonId.equals(1)))
        .write(const SyncCheckpointsCompanion(drainRequested: Value(true)));
  });

  @override
  Future<Result<void>> persistDrainPage(DrainPage page) async {
    if (page.envelopes.length > config.current.drainPageMax ||
        page.prunedThrough < 0 ||
        page.envelopes.any(
          (envelope) =>
              !_isUuid(envelope.id) ||
              envelope.sequence < 1 ||
              !config.current.envelopeBuckets.contains(
                envelope.exactCiphertext.length,
              ),
        )) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    try {
      await database.writeTransaction(() async {
        final checkpoint = await _checkpointInTransaction();
        if (page.prunedThrough < checkpoint.prunedThrough) {
          throw const _ServerInvariant();
        }
        final candidates = page.envelopes
            .where(
              (envelope) =>
                  envelope.sequence > checkpoint.highestContiguousAckedSequence,
            )
            .toList(growable: false);

        // Two set-based reads for the whole page, not two per envelope.
        //
        // A page the server re-serves is the ordinary case, not the exception:
        // an envelope stays in the mailbox until this device acknowledges it,
        // so every drain during a backlog returns rows that are already here.
        // Asking about each one individually meant roughly two hundred
        // statements inside one write transaction to establish that nothing had
        // changed. The invariant they check is unchanged — a re-served envelope
        // whose sequence or ciphertext disagrees with the stored row is still a
        // hard violation, and so is a second envelope claiming a taken
        // sequence.
        final ids = candidates
            .map((envelope) => envelope.id)
            .toList(growable: false);
        final sequences = candidates
            .map((envelope) => envelope.sequence)
            .toList(growable: false);
        final storedById = <String, InboxEnvelope>{};
        final storedBySequence = <int, InboxEnvelope>{};
        if (candidates.isNotEmpty) {
          for (final row in await (database.select(
            database.inboxEnvelopes,
          )..where((row) => row.envelopeId.isIn(ids))).get()) {
            storedById[row.envelopeId] = row;
          }
          for (final row in await (database.select(
            database.inboxEnvelopes,
          )..where((row) => row.sequence.isIn(sequences))).get()) {
            storedBySequence[row.sequence] = row;
          }
        }

        final fresh = <SyncEnvelope>[];
        for (final envelope in candidates) {
          final byId = storedById[envelope.id];
          if (byId != null) {
            if (byId.sequence != envelope.sequence ||
                !_bytesEqual(
                  byId.envelopeCiphertext,
                  envelope.exactCiphertext,
                )) {
              throw const _ServerInvariant();
            }
            continue;
          }
          if (storedBySequence.containsKey(envelope.sequence)) {
            throw const _ServerInvariant();
          }
          fresh.add(envelope);
        }

        if (fresh.isNotEmpty) {
          if (fresh.length > maximumInboxEntries ||
              await _isAtOrOverCapacity(maximumInboxEntries - fresh.length)) {
            throw const _SyncCapacity();
          }
          for (final envelope in fresh) {
            await database
                .into(database.inboxEnvelopes)
                .insert(
                  InboxEnvelopesCompanion.insert(
                    envelopeId: envelope.id,
                    sequence: envelope.sequence,
                    envelopeCiphertext: envelope.exactCiphertext,
                    processingState: InboxProcessingState.received.index,
                  ),
                  mode: InsertMode.insertOrIgnore,
                );
          }
        }
        final gapDetected =
            checkpoint.highestContiguousAckedSequence < page.prunedThrough;
        await (database.update(
          database.syncCheckpoints,
        )..where((row) => row.singletonId.equals(1))).write(
          SyncCheckpointsCompanion(
            prunedThrough: Value(page.prunedThrough),
            queueGapState: gapDetected
                ? Value(QueueGapState.recoveryRequired.index)
                : const Value.absent(),
            drainRequested: Value(page.hasMore),
          ),
        );
        if (gapDetected) {
          // Every group this device still follows is potentially affected: a
          // lost envelope may have carried any group's Commit. A group this
          // device was already removed from or has left is not, and must not
          // be flagged — it can never produce a re-admission, so flagging it
          // would leave the device permanently blocked with no way out.
          await (database.update(database.mlsGroups)..where(
                (row) => row.lifecycle.isNotIn([
                  GroupLifecycle.removed.index,
                  GroupLifecycle.left.index,
                ]),
              ))
              .write(const MlsGroupsCompanion(queueGapRecoveryState: Value(1)));
        }
      });
      return const Result.success(null);
    } on _ServerInvariant {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    } on _SyncCapacity {
      return const Result.failure(
        StorageFailure(StorageFailureKind.capacityExceeded),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  /// Whether the inbox already holds more than [headroom] rows.
  ///
  /// A `COUNT(*)` answers a question nobody asked. The ceiling is ten thousand
  /// rows and the only thing that matters is whether one more page fits, so
  /// this reads a single primary-key value past the headroom and stops: it
  /// touches at most `headroom + 1` index entries where the count scanned the
  /// whole table on every page of every drain.
  Future<bool> _isAtOrOverCapacity(int headroom) async {
    if (headroom < 0) {
      return true;
    }
    final probe = database.selectOnly(database.inboxEnvelopes)
      ..addColumns([database.inboxEnvelopes.envelopeId])
      ..limit(1, offset: headroom);
    return (await probe.get()).isNotEmpty;
  }

  @override
  Future<Result<SyncEnvelope?>> beginNextEnvelopeInspection({
    required DateTime now,
  }) async {
    try {
      final envelope = await database.writeTransaction(() async {
        // Oldest due envelope first, which is what keeps healthy delivery in
        // order. It is safe to leave it that way now that an envelope that will
        // not open carries a retry time after every failure and a terminal
        // state after `maximumInspectionAttempts` of them: the row stops being
        // due instead of being picked ahead of everything else on every pass.
        final query = database.select(database.inboxEnvelopes)
          ..where(
            (row) =>
                (row.processingState.equals(
                      InboxProcessingState.received.index,
                    ) |
                    row.processingState.equals(
                      InboxProcessingState.inspecting.index,
                    )) &
                (row.nextAttemptAt.isNull() |
                    row.nextAttemptAt.isSmallerOrEqualValue(now)),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.sequence)])
          ..limit(1);
        final row = await query.getSingleOrNull();
        if (row == null) {
          return null;
        }
        final attempt = row.attemptCount + 1;
        await (database.update(
          database.inboxEnvelopes,
        )..where((item) => item.envelopeId.equals(row.envelopeId))).write(
          InboxEnvelopesCompanion(
            processingState: Value(InboxProcessingState.inspecting.index),
            attemptCount: Value(attempt),
            nextAttemptAt: const Value(null),
          ),
        );
        return SyncEnvelope(
          id: row.envelopeId,
          sequence: row.sequence,
          attempt: attempt,
          inspectionFailures: row.inspectionFailures,
          exactCiphertext: row.envelopeCiphertext,
        );
      });
      return Result.success(envelope);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<bool>> commitOpaqueInspection({
    required String envelopeId,
    required OpaqueEnvelopeInspection inspection,
  }) async {
    if (inspection.opaqueEventId.isEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final pairwise = inspection.pairwiseCommit;
    final rawGroup = inspection.groupCommit;
    if (rawGroup != null && rawGroup is! PreparedGroupInboxCommit) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final group = rawGroup as PreparedGroupInboxCommit?;
    if ((group != null) !=
        (pairwise != null &&
            inspection.dependency == EnvelopeDependency.potentiallyMls)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    if (pairwise != null) {
      final expectedDependency = group == null
          ? EnvelopeDependency.directOrLocal
          : EnvelopeDependency.potentiallyMls;
      if (inspection.dependency != expectedDependency ||
          pairwise.envelopeId != envelopeId ||
          pairwise.opaqueEventId != inspection.opaqueEventId ||
          (group != null &&
              (group.opaqueEventId != inspection.opaqueEventId ||
                  group.senderUserId != pairwise.senderUserId ||
                  group.senderDeviceId != pairwise.senderDeviceId)) ||
          pairwise.sessionTransition.disposition < 0 ||
          pairwise.sessionTransition.disposition >=
              PairwiseSessionDisposition.values.length ||
          pairwise.sessionTransition.repairState < 0 ||
          pairwise.sessionTransition.repairState >=
              PairwiseRepairState.values.length ||
          pairwise.consumedOneTimePrekeys.any(
            (key) =>
                key.algorithm < 0 ||
                key.algorithm >= PairwiseOneTimePrekeyKind.values.length,
          )) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.malformedServerResponse),
        );
      }
      final receiveCommit = PairwiseReceiveCommit(
        envelopeId: pairwise.envelopeId,
        opaqueEventId: pairwise.opaqueEventId,
        senderUserId: pairwise.senderUserId,
        senderDeviceId: pairwise.senderDeviceId,
        replayMarker: pairwise.replayMarker,
        openedOpaquePayload: pairwise.openedOpaquePayload,
        signedPrekeyId: pairwise.signedPrekeyId,
        pqSignedPrekeyId: pairwise.pqSignedPrekeyId,
        sessionTransition: PairwiseSessionTransition(
          localDeviceId: pairwise.sessionTransition.localDeviceId,
          remoteUserId: pairwise.sessionTransition.remoteUserId,
          remoteDeviceId: pairwise.sessionTransition.remoteDeviceId,
          sessionId: pairwise.sessionTransition.sessionId,
          nextOpaqueState: pairwise.sessionTransition.nextOpaqueState,
          expectedStateVersion: pairwise.sessionTransition.expectedStateVersion,
          nextStateVersion: pairwise.sessionTransition.nextStateVersion,
          nextSkippedKeyCount: pairwise.sessionTransition.nextSkippedKeyCount,
          disposition: PairwiseSessionDisposition
              .values[pairwise.sessionTransition.disposition],
          repairState: PairwiseRepairState
              .values[pairwise.sessionTransition.repairState],
          repairAuthorization: pairwise.sessionTransition.repairAuthorization,
        ),
        demotedExistingSessionTransition:
            pairwise.demotedExistingSessionTransition == null
            ? null
            : PairwiseSessionTransition(
                localDeviceId:
                    pairwise.demotedExistingSessionTransition!.localDeviceId,
                remoteUserId:
                    pairwise.demotedExistingSessionTransition!.remoteUserId,
                remoteDeviceId:
                    pairwise.demotedExistingSessionTransition!.remoteDeviceId,
                sessionId: pairwise.demotedExistingSessionTransition!.sessionId,
                nextOpaqueState:
                    pairwise.demotedExistingSessionTransition!.nextOpaqueState,
                expectedStateVersion: pairwise
                    .demotedExistingSessionTransition!
                    .expectedStateVersion,
                nextStateVersion:
                    pairwise.demotedExistingSessionTransition!.nextStateVersion,
                nextSkippedKeyCount: pairwise
                    .demotedExistingSessionTransition!
                    .nextSkippedKeyCount,
                disposition:
                    PairwiseSessionDisposition.values[pairwise
                        .demotedExistingSessionTransition!
                        .disposition],
                repairState:
                    PairwiseRepairState.values[pairwise
                        .demotedExistingSessionTransition!
                        .repairState],
                repairAuthorization: pairwise
                    .demotedExistingSessionTransition!
                    .repairAuthorization,
              ),
        replacedSessionId: pairwise.replacedSessionId,
        deviceStateTransition: pairwise.deviceStateTransition == null
            ? null
            : PairwiseDeviceStateTransition(
                nextOpaqueState:
                    pairwise.deviceStateTransition!.nextOpaqueState,
                expectedStateVersion:
                    pairwise.deviceStateTransition!.expectedStateVersion,
                nextStateVersion:
                    pairwise.deviceStateTransition!.nextStateVersion,
              ),
        consumedOneTimePrekeys: [
          for (final key in pairwise.consumedOneTimePrekeys)
            ConsumedPairwiseOneTimePrekey(
              kind: PairwiseOneTimePrekeyKind.values[key.algorithm],
              keyId: key.keyId,
            ),
        ],
        applicationEvent: pairwise.applicationEvent,
        unsupportedApplicationEvent: pairwise.unsupportedApplicationEvent,
        deviceControlEvent: pairwise.deviceControlEvent,
        historyApplicationEvents: pairwise.historyApplicationEvents,
      );
      final pairwiseStore = DriftPairwiseTransportStore(
        database,
        config: config,
      );
      if (group == null) {
        return pairwiseStore.commitPreparedReceive(receiveCommit);
      }
      final groupRepository = DriftGroupRepository(database);
      return pairwiseStore.commitPreparedReceiveWithAdditionalTransaction(
        commit: receiveCommit,
        dependency: EnvelopeDependency.potentiallyMls,
        additionalCommit: () => switch (group) {
          PreparedGroupInboxTransition(
            :final expectedPrevious,
            :final next,
            :final prepared,
          ) =>
            groupRepository.commitTransitionInsideTransaction(
              expectedPrevious: expectedPrevious,
              next: next,
              prepared: prepared,
              developmentPreviewOnly: false,
            ),
          PreparedGroupInboxMessage(:final expectedGroup, :final prepared) =>
            groupRepository.commitMessageInsideTransaction(
              expectedGroup: expectedGroup,
              prepared: prepared,
              developmentPreviewOnly: false,
            ),
          PreparedGroupInboxForkResolution(
            :final record,
            :final localBranchRetained,
          ) =>
            groupRepository.quarantineInsideTransaction(
              record,
              retainLifecycle: localBranchRetained,
            ),
          // The re-admission and the end of that group's queue-gap obligation
          // are one fact. Committing them separately would leave a window in
          // which a rejoined group still reads as unrecoverable, or worse, a
          // cleared obligation with no group behind it.
          PreparedGroupInboxRejoin(
            :final supersededLocal,
            :final next,
            :final prepared,
          ) =>
            () async {
              await groupRepository.rejoinInsideTransaction(
                supersededLocal: supersededLocal,
                next: next,
                prepared: prepared,
              );
              await _completeGroupRecoveryInsideTransaction(
                next.groupId,
                left: false,
              );
            }(),
        },
      );
    }
    try {
      final applied = await database.writeTransaction(() async {
        final envelope = await (database.select(
          database.inboxEnvelopes,
        )..where((row) => row.envelopeId.equals(envelopeId))).getSingleOrNull();
        if (envelope == null ||
            envelope.processingState != InboxProcessingState.inspecting.index) {
          throw const _SyncConflict();
        }
        final inserted = await database
            .into(database.inboxEventDeduplications)
            .insert(
              InboxEventDeduplicationsCompanion.insert(
                opaqueEventId: inspection.opaqueEventId,
                firstEnvelopeId: envelopeId,
                dependencyClass: inspection.dependency.index,
              ),
              mode: InsertMode.insertOrIgnore,
            );
        await (database.update(
          database.inboxEnvelopes,
        )..where((row) => row.envelopeId.equals(envelopeId))).write(
          InboxEnvelopesCompanion(
            opaqueEventId: Value(inspection.opaqueEventId),
            dependencyClass: Value(inspection.dependency.index),
            processingState: Value(
              InboxProcessingState.readyToAcknowledge.index,
            ),
            readyToAcknowledge: const Value(true),
            nextAttemptAt: const Value(null),
          ),
        );
        return inserted > 0;
      });
      return Result.success(applied);
    } on _SyncConflict {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> blockEnvelopeForQueueGap(String envelopeId) => _write(
    () async {
      await (database.update(
        database.inboxEnvelopes,
      )..where((row) => row.envelopeId.equals(envelopeId))).write(
        InboxEnvelopesCompanion(
          processingState: Value(InboxProcessingState.blockedByQueueGap.index),
          nextAttemptAt: const Value(null),
        ),
      );
    },
  );

  @override
  Future<Result<void>> recordEnvelopeInspectionRetry({
    required String envelopeId,
    required DateTime retryAt,
    required bool countsAgainstBudget,
  }) => _write(() async {
    // Read-modify-write inside the caller's transaction rather than a bare
    // increment expression, so the value the budget is checked against is the
    // value this row actually holds.
    final row = await (database.select(
      database.inboxEnvelopes,
    )..where((item) => item.envelopeId.equals(envelopeId))).getSingleOrNull();
    if (row == null) {
      return;
    }
    await (database.update(
      database.inboxEnvelopes,
    )..where((item) => item.envelopeId.equals(envelopeId))).write(
      InboxEnvelopesCompanion(
        processingState: Value(InboxProcessingState.received.index),
        inspectionFailures: countsAgainstBudget
            ? Value(row.inspectionFailures + 1)
            : const Value.absent(),
        nextAttemptAt: Value(retryAt),
      ),
    );
  });

  @override
  Future<Result<void>> recordEnvelopeRejection({
    required String envelopeId,
    required int reasonCode,
  }) => _write(() async {
    await database
        .into(database.quarantineRecords)
        .insert(
          QuarantineRecordsCompanion.insert(
            reasonCode: reasonCode,
            opaqueDigest: Uint8List(0),
          ),
        );
    await (database.update(
      database.inboxEnvelopes,
    )..where((row) => row.envelopeId.equals(envelopeId))).write(
      InboxEnvelopesCompanion(
        processingState: Value(InboxProcessingState.readyToAcknowledge.index),
        readyToAcknowledge: const Value(true),
        nextAttemptAt: const Value(null),
      ),
    );
    await database.customStatement(
      'DELETE FROM quarantine WHERE id NOT IN '
      '(SELECT id FROM quarantine ORDER BY received_at DESC, id DESC LIMIT 256)',
    );
  });

  @override
  Future<Result<AcknowledgementBatch?>> beginAcknowledgementBatch({
    required DateTime now,
    required int maximumIds,
  }) async {
    if (maximumIds < 1) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    // The caller's budget, held against what one `POST /me/envelopes/ack` body
    // may carry. A batch past `ack_max` is refused whole, and a refused batch
    // is envelopes the server keeps re-serving.
    final ackMax = config.current.ackMax;
    final batchSize = maximumIds < ackMax ? maximumIds : ackMax;
    try {
      final batch = await database.writeTransaction(() async {
        final interrupted = database.select(database.inboxEnvelopes)
          ..where(
            (row) =>
                row.processingState.equals(
                  InboxProcessingState.acknowledgementSending.index,
                ) &
                (row.nextAttemptAt.isNull() |
                    row.nextAttemptAt.isSmallerOrEqualValue(now)),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.sequence)])
          ..limit(batchSize);
        var rows = await interrupted.get();
        if (rows.isEmpty) {
          final ready = database.select(database.inboxEnvelopes)
            ..where(
              (row) =>
                  row.processingState.equals(
                    InboxProcessingState.readyToAcknowledge.index,
                  ) &
                  (row.nextAttemptAt.isNull() |
                      row.nextAttemptAt.isSmallerOrEqualValue(now)),
            )
            ..orderBy([(row) => OrderingTerm.asc(row.sequence)])
            ..limit(batchSize);
          rows = await ready.get();
        }
        if (rows.isEmpty) {
          return null;
        }
        final ids = rows.map((row) => row.envelopeId).toList(growable: false);
        final attempt =
            rows
                .map((row) => row.attemptCount)
                .fold<int>(0, (left, right) => left > right ? left : right) +
            1;
        await (database.update(
          database.inboxEnvelopes,
        )..where((row) => row.envelopeId.isIn(ids))).write(
          InboxEnvelopesCompanion(
            processingState: Value(
              InboxProcessingState.acknowledgementSending.index,
            ),
            attemptCount: Value(attempt),
            nextAttemptAt: const Value(null),
          ),
        );
        return AcknowledgementBatch(envelopeIds: ids, attempt: attempt);
      });
      return Result.success(batch);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> recordAcknowledgementSuccess({
    required AcknowledgementBatch batch,
    required DateTime now,
  }) => _write(() async {
    await (database.update(
      database.inboxEnvelopes,
    )..where((row) => row.envelopeId.isIn(batch.envelopeIds))).write(
      InboxEnvelopesCompanion(
        processingState: Value(InboxProcessingState.acknowledged.index),
        readyToAcknowledge: const Value(false),
        nextAttemptAt: const Value(null),
      ),
    );
    final checkpoint = await _checkpointInTransaction();
    var contiguous = checkpoint.highestContiguousAckedSequence;
    final acknowledgedRows =
        await (database.select(database.inboxEnvelopes)
              ..where(
                (row) =>
                    row.processingState.equals(
                      InboxProcessingState.acknowledged.index,
                    ) &
                    row.sequence.isBiggerThanValue(contiguous),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.sequence)]))
            .get();
    for (final row in acknowledgedRows) {
      if (row.sequence != contiguous + 1) {
        break;
      }
      contiguous = row.sequence;
    }
    await (database.update(
      database.syncCheckpoints,
    )..where((row) => row.singletonId.equals(1))).write(
      SyncCheckpointsCompanion(
        highestContiguousAckedSequence: Value(contiguous),
      ),
    );
    await (database.delete(database.inboxEnvelopes)..where(
          (row) =>
              row.processingState.equals(
                InboxProcessingState.acknowledged.index,
              ) &
              row.sequence.isSmallerOrEqualValue(contiguous),
        ))
        .go();
  });

  @override
  Future<Result<void>> recordAcknowledgementFailure({
    required AcknowledgementBatch batch,
    required DateTime retryAt,
  }) => _write(() async {
    await (database.update(
      database.inboxEnvelopes,
    )..where((row) => row.envelopeId.isIn(batch.envelopeIds))).write(
      InboxEnvelopesCompanion(
        processingState: Value(InboxProcessingState.readyToAcknowledge.index),
        nextAttemptAt: Value(retryAt),
      ),
    );
  });

  @override
  Future<Result<PendingSendPreparation?>> beginNextSendPreparation({
    required DateTime now,
  }) async {
    try {
      final row =
          await (database.select(database.pendingSendPreparations)
                ..where(
                  (item) =>
                      item.state.equals(_preparationOwed) &
                      (item.nextAttemptAt.isNull() |
                          item.nextAttemptAt.isSmallerOrEqualValue(now)),
                )
                ..orderBy([
                  (item) => OrderingTerm.asc(item.createdAt),
                  (item) => OrderingTerm.asc(item.operationId),
                ])
                ..limit(1))
              .getSingleOrNull();
      if (row == null) {
        return const Result.success(null);
      }
      return Result.success(
        PendingSendPreparation(
          operationId: row.operationId,
          eventId: row.eventId,
          localUserId: row.localUserId,
          localDeviceId: row.localDeviceId,
          peerUserId: row.peerUserId,
          attempt: row.attemptCount + 1,
        ),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  /// Nothing is marked in-flight, and nothing needs to be.
  ///
  /// An outbox row is marked `sending` because the bytes have left this device
  /// and the record of that has to survive the answer. A preparation has sent
  /// nothing: it either commits — in the transaction that also retires it — or
  /// it does not, and a process that dies mid-attempt comes back to a row that
  /// is still exactly owed. What stops the same run picking it up twice is the
  /// due time written here.
  @override
  Future<Result<void>> recordSendPreparationRetry({
    required PendingSendPreparation preparation,
    required DateTime retryAt,
  }) => _write(() async {
    await (database.update(database.pendingSendPreparations)..where(
          (row) =>
              row.operationId.equals(preparation.operationId) &
              row.state.equals(_preparationOwed),
        ))
        .write(
          PendingSendPreparationsCompanion(
            attemptCount: Value(preparation.attempt),
            nextAttemptAt: Value(retryAt),
          ),
        );
  });

  @override
  Future<Result<void>> recordSendPreparationFailure({
    required PendingSendPreparation preparation,
  }) => _write(() async {
    final updated =
        await (database.update(database.pendingSendPreparations)..where(
              (row) =>
                  row.operationId.equals(preparation.operationId) &
                  row.state.equals(_preparationOwed),
            ))
            .write(
              PendingSendPreparationsCompanion(
                state: const Value(_preparationFailed),
                attemptCount: Value(preparation.attempt),
                nextAttemptAt: const Value(null),
              ),
            );
    if (updated == 0) {
      return;
    }
    // The row outlives its work here, alone among the queues in this file,
    // because it is the only durable record that a message the user can see has
    // no route to the wire. Deleting it would make that message read as one
    // that never left this device on purpose.
    await DriftApplicationEventProjector(
      database,
    ).refreshTransportForEventInsideTransaction(preparation.eventId);
  });

  @override
  Future<Result<OutboxBatch?>> beginNextOutboxBatch({
    required DateTime now,
  }) async {
    try {
      final batch = await database.writeTransaction(() async {
        var first =
            await (database.select(database.outboxOperations)
                  ..where(
                    (row) => row.attemptState.equals(
                      OutboxAttemptState.sending.index,
                    ),
                  )
                  ..orderBy([
                    (row) => OrderingTerm.asc(row.operationId),
                    (row) => OrderingTerm.asc(row.batchIndex),
                    (row) => OrderingTerm.asc(row.recipientDeviceId),
                  ])
                  ..limit(1))
                .getSingleOrNull();
        first ??=
            await (database.select(database.outboxOperations)
                  ..where(
                    (row) =>
                        (row.attemptState.equals(
                              OutboxAttemptState.queued.index,
                            ) |
                            row.attemptState.equals(
                              OutboxAttemptState.retryWait.index,
                            )) &
                        (row.nextAttemptAt.isNull() |
                            row.nextAttemptAt.isSmallerOrEqualValue(now)),
                  )
                  ..orderBy([
                    (row) => OrderingTerm.asc(row.operationId),
                    (row) => OrderingTerm.asc(row.batchIndex),
                    (row) => OrderingTerm.asc(row.recipientDeviceId),
                  ])
                  ..limit(1))
                .getSingleOrNull();
        if (first == null) {
          return null;
        }
        final rows =
            await (database.select(database.outboxOperations)
                  ..where(
                    (row) =>
                        row.operationId.equals(first!.operationId) &
                        row.batchIndex.equals(first.batchIndex) &
                        (row.attemptState.equals(
                              OutboxAttemptState.queued.index,
                            ) |
                            row.attemptState.equals(
                              OutboxAttemptState.sending.index,
                            ) |
                            row.attemptState.equals(
                              OutboxAttemptState.retryWait.index,
                            )),
                  )
                  ..orderBy([(row) => OrderingTerm.asc(row.recipientDeviceId)]))
                .get();
        final dueRows = rows
            .where(
              (row) =>
                  row.attemptState == OutboxAttemptState.sending.index ||
                  row.nextAttemptAt == null ||
                  !row.nextAttemptAt!.isAfter(now),
            )
            .toList(growable: false);
        if (dueRows.isEmpty) {
          return null;
        }
        final ids = dueRows
            .map((row) => row.recipientDeviceId)
            .toList(growable: false);
        final attempt =
            dueRows
                .map((row) => row.attemptCount)
                .fold<int>(0, (left, right) => left > right ? left : right) +
            1;
        await (database.update(database.outboxOperations)..where(
              (row) =>
                  row.operationId.equals(first!.operationId) &
                  row.recipientDeviceId.isIn(ids),
            ))
            .write(
              OutboxOperationsCompanion(
                attemptState: Value(OutboxAttemptState.sending.index),
                attemptCount: Value(attempt),
                nextAttemptAt: const Value(null),
                lastAttemptAt: Value(now),
              ),
            );
        await DriftApplicationEventProjector(
          database,
        ).refreshTransportForEventInsideTransaction(first.eventId);
        return OutboxBatch(
          operationId: first.operationId,
          eventId: first.eventId,
          batchIndex: first.batchIndex,
          attempt: attempt,
          targets: dueRows
              .map(
                (row) => OutboxTarget(
                  recipientUserId: row.recipientUserId,
                  recipientDeviceId: row.recipientDeviceId,
                  exactCiphertext: row.exactRecipientCiphertext,
                ),
              )
              .toList(growable: false),
        );
      });
      return Result.success(batch);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  /// Three outcomes, one row each, and the two that are not `accepted` are not
  /// the same thing.
  ///
  /// A **stale** device is gone: its row is terminal, its pairwise sessions are
  /// deleted, and its owner's device list is queued for a refresh. A **full**
  /// device is live and merely out of room, so its row goes back to waiting
  /// with a due time, its sessions are untouched, and nothing about its owner
  /// is re-read. Recording a full device as stale would tear down a working
  /// session and drop a live participant out of a conversation
  /// (`backend/CLIENT_CONTRACT.md` §F).
  @override
  Future<Result<void>> recordOutboxAcceptance({
    required OutboxBatch batch,
    required OutboxAcceptance acceptance,
    required DateTime now,
    required DateTime retryFullAt,
  }) => _write(() async {
    for (final target in batch.targets) {
      final stale = acceptance.staleDeviceIds.contains(
        target.recipientDeviceId,
      );
      final full =
          !stale && acceptance.fullDeviceIds.contains(target.recipientDeviceId);
      await (database.update(database.outboxOperations)..where(
            (row) =>
                row.operationId.equals(batch.operationId) &
                row.recipientDeviceId.equals(target.recipientDeviceId),
          ))
          .write(
            full
                ? OutboxOperationsCompanion(
                    attemptState: Value(OutboxAttemptState.retryWait.index),
                    nextAttemptAt: Value(retryFullAt),
                    lastAttemptAt: Value(now),
                  )
                : OutboxOperationsCompanion(
                    attemptState: Value(
                      stale
                          ? OutboxAttemptState.stale.index
                          : OutboxAttemptState.accepted.index,
                    ),
                    nextAttemptAt: const Value(null),
                    terminalAt: Value(now),
                  ),
          );
      if (!stale) {
        continue;
      }
      await (database.delete(database.pairwiseSessions)..where(
            (row) => row.remoteDeviceId.equals(target.recipientDeviceId),
          ))
          .go();
      await (database.delete(database.pairwiseSessionAlternates)..where(
            (row) => row.remoteDeviceId.equals(target.recipientDeviceId),
          ))
          .go();
      await database
          .into(database.staleDeviceRefreshRequests)
          .insert(
            StaleDeviceRefreshRequestsCompanion.insert(
              userId: target.recipientUserId,
              staleDeviceId: target.recipientDeviceId,
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
    await DriftApplicationEventProjector(
      database,
    ).refreshTransportForEventInsideTransaction(batch.eventId);
  });

  @override
  Future<Result<void>> recordOutboxRetry({
    required OutboxBatch batch,
    required DateTime retryAt,
  }) => _updateOutboxBatch(
    batch,
    OutboxOperationsCompanion(
      attemptState: Value(OutboxAttemptState.retryWait.index),
      nextAttemptAt: Value(retryAt),
    ),
  );

  @override
  Future<Result<void>> recordOutboxPermanentFailure({
    required OutboxBatch batch,
    required DateTime now,
  }) => _updateOutboxBatch(
    batch,
    OutboxOperationsCompanion(
      attemptState: Value(OutboxAttemptState.permanentlyFailed.index),
      nextAttemptAt: const Value(null),
      terminalAt: Value(now),
    ),
  );

  @override
  Future<Result<List<StaleDeviceRefreshWork>>> pendingStaleDeviceRefreshes({
    required DateTime now,
  }) async {
    try {
      final work = await database.writeTransaction(() async {
        final rows =
            await (database.select(database.staleDeviceRefreshRequests)
                  ..where(
                    (row) =>
                        row.state.isIn(const [0, 1, 2]) &
                        (row.nextAttemptAt.isNull() |
                            row.nextAttemptAt.isSmallerOrEqualValue(now)),
                  )
                  ..orderBy([(row) => OrderingTerm.asc(row.userId)]))
                .get();
        final attempts = <String, int>{};
        for (final row in rows) {
          final attempt = row.attemptCount + 1;
          final previous = attempts[row.userId] ?? 0;
          if (attempt > previous) {
            attempts[row.userId] = attempt;
          }
          await (database.update(database.staleDeviceRefreshRequests)..where(
                (item) =>
                    item.userId.equals(row.userId) &
                    item.staleDeviceId.equals(row.staleDeviceId),
              ))
              .write(
                StaleDeviceRefreshRequestsCompanion(
                  state: const Value(1),
                  attemptCount: Value(attempt),
                  nextAttemptAt: const Value(null),
                ),
              );
        }
        return attempts.entries
            .map(
              (entry) => StaleDeviceRefreshWork(
                userId: entry.key,
                attempt: entry.value,
              ),
            )
            .toList(growable: false);
      });
      return Result.success(List.unmodifiable(work));
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> completeStaleDeviceRefresh(String userId) =>
      _write(() async {
        await (database.delete(
          database.staleDeviceRefreshRequests,
        )..where((row) => row.userId.equals(userId))).go();
      });

  @override
  Future<Result<void>> retryStaleDeviceRefresh({
    required String userId,
    required DateTime retryAt,
  }) => _write(() async {
    await (database.update(
      database.staleDeviceRefreshRequests,
    )..where((row) => row.userId.equals(userId))).write(
      StaleDeviceRefreshRequestsCompanion(
        state: const Value(2),
        nextAttemptAt: Value(retryAt),
      ),
    );
  });

  @override
  Future<Result<void>> markConnectionPhase(SyncConnectionPhase phase) => _write(
    () async {
      await _ensureCheckpointInTransaction();
      await (database.update(database.syncCheckpoints)
            ..where((row) => row.singletonId.equals(1)))
          .write(SyncCheckpointsCompanion(connectionPhase: Value(phase.index)));
    },
  );

  @override
  Future<Result<DurableReconnectState>> scheduleReconnect({
    required DateTime dueAt,
  }) async {
    try {
      final state = await database.writeTransaction(() async {
        final checkpoint = await _checkpointInTransaction();
        final attempt = checkpoint.reconnectAttempt + 1;
        await (database.update(
          database.syncCheckpoints,
        )..where((row) => row.singletonId.equals(1))).write(
          SyncCheckpointsCompanion(
            connectionPhase: Value(SyncConnectionPhase.reconnectWaiting.index),
            reconnectAttempt: Value(attempt),
            reconnectAt: Value(dueAt),
          ),
        );
        return DurableReconnectState(
          attempt: attempt,
          dueAt: dueAt,
          phase: SyncConnectionPhase.reconnectWaiting,
        );
      });
      return Result.success(state);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<DurableReconnectState>> readReconnectState() async {
    try {
      final checkpoint = await _checkpoint();
      return Result.success(
        DurableReconnectState(
          attempt: checkpoint.reconnectAttempt,
          dueAt: checkpoint.reconnectAt,
          phase: _connectionPhase(checkpoint.connectionPhase),
        ),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> clearReconnect({required DateTime? syncedAt}) =>
      _write(() async {
        await _ensureCheckpointInTransaction();
        await (database.update(
          database.syncCheckpoints,
        )..where((row) => row.singletonId.equals(1))).write(
          SyncCheckpointsCompanion(
            reconnectAttempt: const Value(0),
            reconnectAt: const Value(null),
            lastSuccessfulSyncAt: syncedAt == null
                ? const Value.absent()
                : Value(syncedAt),
          ),
        );
      });

  @override
  Future<Result<void>> recordSuccessfulSync(DateTime syncedAt) =>
      _write(() async {
        await _ensureCheckpointInTransaction();
        await (database.update(
          database.syncCheckpoints,
        )..where((row) => row.singletonId.equals(1))).write(
          SyncCheckpointsCompanion(lastSuccessfulSyncAt: Value(syncedAt)),
        );
      });

  @override
  Future<Result<void>> markGroupRecovered(String groupId) =>
      _completeGroupRecovery(groupId, left: false);

  /// Abandons a group whose queue-gap obligation the user chose not to wait
  /// out.
  ///
  /// This is deliberately local. A desynced device cannot sign a leave
  /// announcement at an epoch it no longer holds, so the remaining members
  /// must still evict the stale leaf themselves; nothing here claims otherwise.
  /// It is refused for any group that is not actually blocked, so it can never
  /// become a path that deletes a live group or retires an obligation this
  /// device has not discharged.
  @override
  Future<Result<void>> markGroupLeft(String groupId) =>
      _completeGroupRecovery(groupId, left: true);

  Future<Result<void>> _completeGroupRecovery(
    String groupId, {
    required bool left,
  }) async {
    try {
      await database.writeTransaction(
        () => _completeGroupRecoveryInsideTransaction(groupId, left: left),
      );
      return const Result.success(null);
    } on _SyncConflict {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  /// Retires one group's queue-gap obligation inside the caller's transaction.
  ///
  /// The device stays blocked until the last affected group is either rejoined
  /// through an authenticated re-admission or explicitly abandoned. Only then
  /// is the permanent loss acknowledged: the baseline advances through the
  /// observed `pruned_through`, so the same gap cannot reopen on every drain,
  /// and the envelopes retained because they might have depended on the lost
  /// MLS state are released for ordinary processing.
  Future<void> _completeGroupRecoveryInsideTransaction(
    String groupId, {
    required bool left,
  }) async {
    if (left) {
      final blocked =
          await (database.select(database.mlsGroups)..where(
                (row) =>
                    row.groupId.equals(groupId) &
                    row.queueGapRecoveryState.equals(1),
              ))
              .getSingleOrNull();
      if (blocked == null) throw const _SyncConflict();
      await (database.delete(
        database.mlsGroups,
      )..where((row) => row.groupId.equals(groupId))).go();
    } else {
      await (database.update(database.mlsGroups)
            ..where((row) => row.groupId.equals(groupId)))
          .write(const MlsGroupsCompanion(queueGapRecoveryState: Value(0)));
    }
    final remaining =
        await (database.selectOnly(database.mlsGroups)
              ..addColumns([database.mlsGroups.groupId.count()])
              ..where(database.mlsGroups.queueGapRecoveryState.equals(1)))
            .getSingle();
    final count = remaining.read(database.mlsGroups.groupId.count()) ?? 0;
    if (count == 0) {
      final checkpoint = await _checkpointInTransaction();
      await (database.update(
        database.syncCheckpoints,
      )..where((row) => row.singletonId.equals(1))).write(
        SyncCheckpointsCompanion(
          highestContiguousAckedSequence: Value(
            checkpoint.prunedThrough > checkpoint.highestContiguousAckedSequence
                ? checkpoint.prunedThrough
                : checkpoint.highestContiguousAckedSequence,
          ),
          queueGapState: Value(QueueGapState.clear.index),
          drainRequested: const Value(true),
        ),
      );
      await (database.update(database.inboxEnvelopes)..where(
            (row) => row.processingState.equals(
              InboxProcessingState.blockedByQueueGap.index,
            ),
          ))
          .write(
            InboxEnvelopesCompanion(
              processingState: Value(InboxProcessingState.received.index),
            ),
          );
    }
  }

  Future<Result<void>> _updateOutboxBatch(
    OutboxBatch batch,
    OutboxOperationsCompanion companion,
  ) => _write(() async {
    final ids = batch.targets
        .map((target) => target.recipientDeviceId)
        .toList(growable: false);
    await (database.update(database.outboxOperations)..where(
          (row) =>
              row.operationId.equals(batch.operationId) &
              row.recipientDeviceId.isIn(ids),
        ))
        .write(companion);
    await DriftApplicationEventProjector(
      database,
    ).refreshTransportForEventInsideTransaction(batch.eventId);
  });

  Future<Result<void>> _write(Future<void> Function() operation) async {
    try {
      await database.writeTransaction(operation);
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  /// Reads first, and writes only when the singleton row is genuinely absent.
  ///
  /// This is on the path of every projection read, every phase transition and
  /// every checkpoint read, so an unconditional `INSERT OR IGNORE` here is an
  /// insert statement against `sync_checkpoint` several times per envelope —
  /// and `sync_checkpoint` is one of the three tables the projection watch
  /// reads from, so each one is also a reason to re-run that aggregate.
  Future<void> _ensureCheckpoint() async {
    if (await _existingCheckpoint() != null) {
      return;
    }
    await database
        .into(database.syncCheckpoints)
        .insert(
          SyncCheckpointsCompanion.insert(
            etagsCiphertext: Uint8List(0),
            retryState: 0,
            protocolVersion: 1,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> _ensureCheckpointInTransaction() => _ensureCheckpoint();

  Future<SyncCheckpoint?> _existingCheckpoint() => (database.select(
    database.syncCheckpoints,
  )..where((row) => row.singletonId.equals(1))).getSingleOrNull();

  Future<SyncCheckpoint> _checkpoint() async {
    final existing = await _existingCheckpoint();
    if (existing != null) {
      return existing;
    }
    await _ensureCheckpoint();
    return (database.select(
      database.syncCheckpoints,
    )..where((row) => row.singletonId.equals(1))).getSingle();
  }

  Future<SyncCheckpoint> _checkpointInTransaction() => _checkpoint();

  SyncProjection _projectionFromRow(QueryRow row) => SyncProjection(
    connectionPhase: _connectionPhase(row.read<int>('connection_phase')),
    queueGapState: row.read<int>('queue_gap_state') == 0
        ? QueueGapState.clear
        : QueueGapState.recoveryRequired,
    highestContiguousAcknowledgedSequence: row.read<int>(
      'highest_contiguous_acked_sequence',
    ),
    prunedThrough: row.read<int>('pruned_through'),
    inboxDepth: row.read<int>('inbox_depth'),
    outboxDepth: row.read<int>('outbox_depth'),
    nextRetryAt: row.readNullable<DateTime>('next_retry_at'),
    lastSuccessfulSyncAt: row.readNullable<DateTime>('last_successful_sync_at'),
  );

  SyncConnectionPhase _connectionPhase(int index) =>
      index >= 0 && index < SyncConnectionPhase.values.length
      ? SyncConnectionPhase.values[index]
      : SyncConnectionPhase.protocolCircuitOpen;

  Future<int> _count(TableInfo<Table, Object?> table) async {
    final count = table.$columns.first.count();
    final row = await (database.selectOnly(
      table,
    )..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  bool _samePreparedTargets(
    List<OutboxOperation> existing,
    List<PreparedOutboxTarget> prepared,
  ) {
    if (existing.length != prepared.length) {
      return false;
    }
    final sortedExisting = List<OutboxOperation>.of(existing)
      ..sort(
        (left, right) =>
            _compareUuidBytes(left.recipientDeviceId, right.recipientDeviceId),
      );
    for (var index = 0; index < prepared.length; index += 1) {
      final row = sortedExisting[index];
      final target = prepared[index];
      if (row.recipientDeviceId != target.recipientDeviceId.toLowerCase() ||
          row.recipientUserId != target.recipientUserId ||
          !_bytesEqual(row.exactRecipientCiphertext, target.exactCiphertext)) {
        return false;
      }
    }
    return true;
  }
}

final class _SyncConflict implements Exception {
  const _SyncConflict();
}

final class _SyncCapacity implements Exception {
  const _SyncCapacity();
}

final class _ServerInvariant implements Exception {
  const _ServerInvariant();
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

bool _isUuid(String value) => _uuid.hasMatch(value);

int _compareUuidBytes(String left, String right) {
  final leftHex = left.replaceAll('-', '').toLowerCase();
  final rightHex = right.replaceAll('-', '').toLowerCase();
  for (var index = 0; index < 32; index += 2) {
    final leftByte = int.parse(leftHex.substring(index, index + 2), radix: 16);
    final rightByte = int.parse(
      rightHex.substring(index, index + 2),
      radix: 16,
    );
    final comparison = leftByte.compareTo(rightByte);
    if (comparison != 0) {
      return comparison;
    }
  }
  return 0;
}

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
