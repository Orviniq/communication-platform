import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/device_control_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:drift/drift.dart';

final class DriftPairwiseTransportStore implements PairwiseTransportStore {
  const DriftPairwiseTransportStore(
    this.database, {
    this.config = const FixedServerConfig.fallback(),
    this.maximumOutboxTargets = 50000,
    this.maximumReplayMarkers = 50000,
    this.maximumOpenedPayloads = 10000,
    this.maximumConsumedPrekeyTombstones = 50000,
    this.maximumLocalApplications = 50000,
    this.maximumPendingSendPreparations = 10000,
  }) : assert(maximumOutboxTargets > 0),
       assert(maximumReplayMarkers > 0),
       assert(maximumOpenedPayloads > 0),
       assert(maximumConsumedPrekeyTombstones > 0),
       assert(maximumLocalApplications > 0),
       assert(maximumPendingSendPreparations > 0);

  /// The deployment's own limits. Only the envelope bucket set is read here:
  /// a sealed target whose length is off-bucket is one the upload route would
  /// refuse with `400 bad_bucket`, so it must not reach the outbox.
  final ServerConfigSnapshot config;

  static const int maximumSkippedKeysPerSession = 2000;
  static const int maximumSkippedKeysPerAccount = 20000;
  static const Duration replayRetention = Duration(days: 16);
  static const String _deviceStateSecretId = 'current-device-key-state-v1';

  /// The persisted ordinals of `pending_send_preparations.state`.
  static const int preparationOwedState = 0;
  static const int preparationFailedState = 1;

  // These values are the local prekeys table's v1 role registry.
  static const int _classicalOneTimePrekeyKind = 1;
  static const int _postQuantumOneTimePrekeyKind = 3;

  final LocalDatabase database;
  final int maximumOutboxTargets;
  final int maximumReplayMarkers;
  final int maximumOpenedPayloads;
  final int maximumConsumedPrekeyTombstones;
  final int maximumLocalApplications;
  final int maximumPendingSendPreparations;

  @override
  Future<Result<PairwisePreparationContext>> readPreparationContext({
    required String localDeviceId,
    required String remoteUserId,
    required String remoteDeviceId,
  }) async {
    if (!_isUuid(localDeviceId) ||
        !_isUuid(remoteDeviceId) ||
        remoteUserId.isEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final primary = await _readPrimary(localDeviceId, remoteDeviceId);
      final alternate = await _readAlternate(localDeviceId, remoteDeviceId);
      final secret =
          await (database.select(database.secureSecrets)
                ..where((row) => row.secretId.equals(_deviceStateSecretId)))
              .getSingleOrNull();
      if (secret == null || secret.stateRevision <= 0) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      }
      if ((primary != null && primary.remoteUserId != remoteUserId) ||
          (alternate != null && alternate.remoteUserId != remoteUserId)) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      final total = await _skippedKeyTotal();
      final other = total - (primary?.skippedKeyCount ?? 0);
      if (other < 0 || total > maximumSkippedKeysPerAccount) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      return Result.success(
        PairwisePreparationContext(
          primary: primary,
          alternate: alternate,
          deviceState: PairwiseDeviceStateSnapshot(
            opaqueState: secret.wrappedCiphertextOrOpaqueHandle,
            stateVersion: secret.stateRevision,
          ),
          otherSessionsSkippedKeyCount: other,
        ),
      );
    } on _PairwiseIntegrity {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<PairwiseInboundPreparationContext>> readInboundContext({
    required String localDeviceId,
    Uint8List? sessionId,
  }) async {
    if (!_isUuid(localDeviceId) ||
        (sessionId != null && sessionId.length != 16)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final secret =
          await (database.select(database.secureSecrets)
                ..where((row) => row.secretId.equals(_deviceStateSecretId)))
              .getSingleOrNull();
      if (secret == null) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      }
      final session = sessionId == null
          ? null
          : await _readSessionById(localDeviceId, sessionId);
      final total = await _skippedKeyTotal();
      final other = total - (session?.skippedKeyCount ?? 0);
      if (other < 0 || total > maximumSkippedKeysPerAccount) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      return Result.success(
        PairwiseInboundPreparationContext(
          session: session,
          deviceState: PairwiseDeviceStateSnapshot(
            opaqueState: secret.wrappedCiphertextOrOpaqueHandle,
            stateVersion: secret.stateRevision,
          ),
          otherSessionsSkippedKeyCount: other,
        ),
      );
    } on _PairwiseIntegrity {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<DurablePairwiseOperation?>> readPreparedOperation(
    String operationId,
  ) async {
    if (operationId.isEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final rows =
          await (database.select(database.outboxOperations)
                ..where((row) => row.operationId.equals(operationId))
                ..orderBy([
                  (row) => OrderingTerm.asc(row.batchIndex),
                  (row) => OrderingTerm.asc(row.recipientDeviceId),
                ]))
              .get();
      final local = await (database.select(
        database.pairwiseLocalApplications,
      )..where((row) => row.operationId.equals(operationId))).getSingleOrNull();
      if (rows.isEmpty && local == null) {
        return const Result.success(null);
      }
      if (local == null || rows.any((row) => row.eventId != local.eventId)) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      return Result.success(
        DurablePairwiseOperation(
          operationId: operationId,
          eventId: local.eventId,
          currentDeviceId: local.localDeviceId,
          openedLocalPayload: local.openedOpaquePayload,
          targets: [
            for (final row in rows)
              DurablePairwiseTarget(
                recipientUserId: row.recipientUserId,
                recipientDeviceId: row.recipientDeviceId,
                exactCiphertext: row.exactRecipientCiphertext,
              ),
          ],
        ),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> commitPreparedSend(PairwiseSendCommit commit) async {
    final sorted = List<PreparedPairwiseSendTarget>.of(commit.targets)
      ..sort(
        (left, right) =>
            _compareUuidBytes(left.recipientDeviceId, right.recipientDeviceId),
      );
    if (!_validSend(commit, sorted)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      await database.writeTransaction(() async {
        final existingRows = await (database.select(
          database.outboxOperations,
        )..where((row) => row.operationId.equals(commit.operationId))).get();
        final existingLocal =
            await (database.select(database.pairwiseLocalApplications)
                  ..where((row) => row.operationId.equals(commit.operationId)))
                .getSingleOrNull();
        // Already queued. The local application row is not a sufficient test of
        // that any more: the echo writes it before there is any ciphertext at
        // all, so a preparation being run for the first time arrives here with
        // one already present. The outbox rows are the fact that matters.
        if (existingRows.isNotEmpty) {
          if (!_samePreparedSend(existingRows, existingLocal, commit, sorted)) {
            throw const _PairwiseConflict();
          }
          await _settlePreparationInTransaction(commit.operationId);
          return;
        }
        if (existingLocal != null &&
            !_sameLocalApplication(existingLocal, commit)) {
          throw const _PairwiseConflict();
        }

        final currentCount = await _outboxCount();
        if (currentCount + sorted.length > maximumOutboxTargets) {
          throw const _PairwiseCapacity();
        }
        if (existingLocal == null &&
            await _tableCount(database.pairwiseLocalApplications) >=
                maximumLocalApplications) {
          throw const _PairwiseCapacity();
        }
        final deviceState =
            await (database.select(database.secureSecrets)
                  ..where((row) => row.secretId.equals(_deviceStateSecretId)))
                .getSingleOrNull();
        if (deviceState == null ||
            deviceState.stateRevision != commit.expectedDeviceStateVersion) {
          throw const _PairwiseConflict();
        }
        for (final target in sorted) {
          final demoted = target.demotedExistingSessionTransition;
          if (demoted != null) {
            await _applyDemotedExistingTransition(demoted);
          }
          await _applySessionTransition(target.sessionTransition);
        }
        if (await _skippedKeyTotal() > maximumSkippedKeysPerAccount) {
          throw const _PairwiseCapacity();
        }
        if (existingLocal == null) {
          await database
              .into(database.pairwiseLocalApplications)
              .insert(
                PairwiseLocalApplicationsCompanion.insert(
                  operationId: commit.operationId,
                  eventId: commit.eventId,
                  localDeviceId: commit.currentDeviceId.toLowerCase(),
                  openedOpaquePayload: commit.openedLocalPayload,
                ),
              );
        }
        for (var index = 0; index < sorted.length; index += 1) {
          final target = sorted[index];
          await database
              .into(database.outboxOperations)
              .insert(
                OutboxOperationsCompanion.insert(
                  operationId: commit.operationId,
                  eventId: commit.eventId,
                  recipientDeviceId: target.recipientDeviceId.toLowerCase(),
                  recipientUserId: Value(target.recipientUserId),
                  batchIndex: index ~/ 256,
                  exactRecipientCiphertext: target.exactCiphertext,
                  attemptState: OutboxAttemptState.queued.index,
                ),
              );
        }
        await _settlePreparationInTransaction(commit.operationId);
      });
      return const Result.success(null);
    } on _PairwiseConflict {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    } on _PairwiseCapacity {
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
  Future<Result<void>> commitLocalEcho({
    required String operationId,
    required String eventId,
    required String currentUserId,
    required String currentDeviceId,
    required String peerUserId,
    required Uint8List openedLocalPayload,
    required ApplicationEventCommit applicationEvent,
  }) async {
    if (operationId.isEmpty ||
        eventId.isEmpty ||
        !_isUuid(currentUserId) ||
        !_isUuid(currentDeviceId) ||
        !_isUuid(peerUserId) ||
        openedLocalPayload.isEmpty ||
        openedLocalPayload.length > 262144 ||
        eventId != protocolBytesToHex(applicationEvent.event.eventId) ||
        !applicationEvent.localOrigin ||
        protocolUuidString(applicationEvent.event.senderDeviceId) !=
            currentDeviceId.toLowerCase()) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      await database.writeTransaction(() async {
        final existing =
            await (database.select(database.pairwiseLocalApplications)
                  ..where((row) => row.operationId.equals(operationId)))
                .getSingleOrNull();
        if (existing != null) {
          // A repeated send of the same event converges rather than writing a
          // second one. The projector is idempotent on its own account, but a
          // preparation is not: re-arming one that has already been settled
          // would put the same message on the wire twice.
          if (existing.eventId != eventId ||
              existing.localDeviceId != currentDeviceId.toLowerCase() ||
              !_bytesEqual(existing.openedOpaquePayload, openedLocalPayload)) {
            throw const _PairwiseConflict();
          }
          return;
        }
        if (await _tableCount(database.pairwiseLocalApplications) >=
                maximumLocalApplications ||
            await _tableCount(database.pendingSendPreparations) >=
                maximumPendingSendPreparations) {
          throw const _PairwiseCapacity();
        }
        await database
            .into(database.pairwiseLocalApplications)
            .insert(
              PairwiseLocalApplicationsCompanion.insert(
                operationId: operationId,
                eventId: eventId,
                localDeviceId: currentDeviceId.toLowerCase(),
                openedOpaquePayload: openedLocalPayload,
                applicationApplied: const Value(true),
              ),
            );
        // Written before the projection, because the projection reads it. A
        // message whose recipients are still owed is not a message that stayed
        // on this device, and the row saying so has to exist by the time the
        // projector decides what to tell the user.
        await database
            .into(database.pendingSendPreparations)
            .insert(
              PendingSendPreparationsCompanion.insert(
                operationId: operationId,
                eventId: eventId,
                localUserId: currentUserId.toLowerCase(),
                localDeviceId: currentDeviceId.toLowerCase(),
                peerUserId: peerUserId.toLowerCase(),
              ),
            );
        await DriftApplicationEventProjector(
          database,
        ).applyInsideTransaction(applicationEvent);
      });
      return const Result.success(null);
    } on _PairwiseConflict {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    } on _PairwiseCapacity {
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
  Future<Result<void>> settleSendPreparation(String operationId) async {
    if (operationId.isEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      await database.writeTransaction(
        () => _settlePreparationInTransaction(operationId),
      );
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<bool>> rearmFailedSend(String operationId) async {
    if (operationId.isEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final rearmed = await database.writeTransaction(() async {
        final preparation =
            await (database.select(database.pendingSendPreparations)..where(
                  (row) =>
                      row.operationId.equals(operationId) &
                      row.state.equals(preparationFailedState),
                ))
                .getSingleOrNull();
        if (preparation != null) {
          await (database.update(
            database.pendingSendPreparations,
          )..where((row) => row.operationId.equals(operationId))).write(
            const PendingSendPreparationsCompanion(
              state: Value(preparationOwedState),
              attemptCount: Value(0),
              nextAttemptAt: Value(null),
            ),
          );
          await DriftApplicationEventProjector(
            database,
          ).refreshTransportForEventInsideTransaction(preparation.eventId);
          return true;
        }
        // Nothing was owed, so the failure is on the wire side: ciphertext this
        // device sealed and the relay refused for good. Re-arming those rows is
        // the same repair schema 14 applied to every stranded outbox row at
        // once, asked for one operation at a time by the person whose message
        // it is.
        final failed =
            await (database.select(database.outboxOperations)..where(
                  (row) =>
                      row.operationId.equals(operationId) &
                      row.attemptState.equals(
                        OutboxAttemptState.permanentlyFailed.index,
                      ),
                ))
                .get();
        if (failed.isEmpty) {
          return false;
        }
        await (database.update(database.outboxOperations)..where(
              (row) =>
                  row.operationId.equals(operationId) &
                  row.attemptState.equals(
                    OutboxAttemptState.permanentlyFailed.index,
                  ),
            ))
            .write(
              OutboxOperationsCompanion(
                attemptState: Value(OutboxAttemptState.queued.index),
                attemptCount: const Value(0),
                nextAttemptAt: const Value(null),
                terminalAt: const Value(null),
              ),
            );
        await DriftApplicationEventProjector(
          database,
        ).refreshTransportForEventInsideTransaction(failed.first.eventId);
        return true;
      });
      return Result.success(rearmed);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  /// Removes an owed preparation and tells its message it is no longer owed.
  ///
  /// Both statements are skipped when nothing was owed, which is every caller
  /// that never had a preparation: device-log gossip, group envelopes and
  /// history transfer all queue ciphertext for events this projection knows
  /// nothing about.
  Future<void> _settlePreparationInTransaction(String operationId) async {
    final owed = await (database.select(
      database.pendingSendPreparations,
    )..where((row) => row.operationId.equals(operationId))).getSingleOrNull();
    if (owed == null) {
      return;
    }
    await (database.delete(
      database.pendingSendPreparations,
    )..where((row) => row.operationId.equals(operationId))).go();
    await DriftApplicationEventProjector(
      database,
    ).refreshTransportForEventInsideTransaction(owed.eventId);
  }

  @override
  Future<Result<bool>> commitPreparedReceive(PairwiseReceiveCommit commit) =>
      _commitPreparedReceive(
        commit,
        dependency: EnvelopeDependency.directOrLocal,
      );

  Future<Result<bool>> commitPreparedReceiveWithAdditionalTransaction({
    required PairwiseReceiveCommit commit,
    required EnvelopeDependency dependency,
    required Future<void> Function() additionalCommit,
  }) {
    if (dependency != EnvelopeDependency.potentiallyMls) {
      return Future.value(
        const Result.failure(
          ValidationFailure(ValidationFailureKind.invalidInput),
        ),
      );
    }
    return _commitPreparedReceive(
      commit,
      dependency: dependency,
      additionalCommit: additionalCommit,
    );
  }

  Future<Result<bool>> _commitPreparedReceive(
    PairwiseReceiveCommit commit, {
    required EnvelopeDependency dependency,
    Future<void> Function()? additionalCommit,
  }) async {
    if (!_validReceive(commit)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final applied = await database.writeTransaction(() async {
        final envelope =
            await (database.select(database.inboxEnvelopes)
                  ..where((row) => row.envelopeId.equals(commit.envelopeId)))
                .getSingleOrNull();
        if (envelope == null ||
            envelope.processingState != InboxProcessingState.inspecting.index) {
          throw const _PairwiseConflict();
        }

        final replay =
            await (database.select(
                  database.pairwiseReplayMarkers,
                )..where((row) => row.replayMarker.equals(commit.replayMarker)))
                .getSingleOrNull();
        if (replay != null) {
          throw const _PairwiseReplay();
        }
        if (await _tableCount(database.pairwiseReplayMarkers) >=
                maximumReplayMarkers ||
            await _tableCount(database.pairwiseOpenedPayloads) >=
                maximumOpenedPayloads ||
            await _tableCount(database.pairwiseConsumedPrekeys) +
                    commit.consumedOneTimePrekeys.length >
                maximumConsumedPrekeyTombstones) {
          throw const _PairwiseCapacity();
        }

        final demoted = commit.demotedExistingSessionTransition;
        if (demoted != null) {
          await _applyDemotedExistingTransition(demoted);
        }
        final replacedSessionId = commit.replacedSessionId;
        if (replacedSessionId != null) {
          await _eraseAuthenticatedRepairSession(
            commit.sessionTransition,
            replacedSessionId,
          );
        }
        await _applySessionTransition(commit.sessionTransition);
        if (await _skippedKeyTotal() > maximumSkippedKeysPerAccount) {
          throw const _PairwiseCapacity();
        }
        final deviceTransition = commit.deviceStateTransition;
        if (deviceTransition != null) {
          final pendingMaintenance =
              await (database.select(database.prekeyMaintenancePlans)..where(
                    (row) => row.deviceId.equals(
                      commit.sessionTransition.localDeviceId.toLowerCase(),
                    ),
                  ))
                  .getSingleOrNull();
          if (pendingMaintenance != null) {
            // A pending plan owns a candidate native device state. Accepting an
            // initial concurrently could otherwise let completion resurrect a
            // one-time private key consumed by this envelope.
            throw const _PairwiseConflict();
          }
          final updated =
              await (database.update(database.secureSecrets)..where(
                    (row) =>
                        row.secretId.equals(_deviceStateSecretId) &
                        row.stateRevision.equals(
                          deviceTransition.expectedStateVersion,
                        ),
                  ))
                  .write(
                    SecureSecretsCompanion(
                      wrappedCiphertextOrOpaqueHandle: Value(
                        deviceTransition.nextOpaqueState,
                      ),
                      formatVersion: const Value(2),
                      stateRevision: Value(deviceTransition.nextStateVersion),
                    ),
                  );
          if (updated != 1) {
            throw const _PairwiseConflict();
          }
        }

        for (final consumed in commit.consumedOneTimePrekeys) {
          await database
              .into(database.pairwiseConsumedPrekeys)
              .insert(
                PairwiseConsumedPrekeysCompanion.insert(
                  localDeviceId: commit.sessionTransition.localDeviceId,
                  algorithm: consumed.kind.index,
                  keyId: consumed.keyId,
                  firstEnvelopeId: commit.envelopeId,
                ),
              );
          final storageKind = switch (consumed.kind) {
            PairwiseOneTimePrekeyKind.classicalX25519 =>
              _classicalOneTimePrekeyKind,
            PairwiseOneTimePrekeyKind.postQuantumMlKem768 =>
              _postQuantumOneTimePrekeyKind,
          };
          await (database.delete(database.prekeys)..where(
                (row) =>
                    row.kind.equals(storageKind) &
                    row.keyId.equals(consumed.keyId),
              ))
              .go();
        }

        await database
            .into(database.pairwiseReplayMarkers)
            .insert(
              PairwiseReplayMarkersCompanion.insert(
                replayMarker: commit.replayMarker,
                sessionId: commit.sessionTransition.sessionId,
                signedPrekeyId: Value(commit.signedPrekeyId),
                pqSignedPrekeyId: Value(commit.pqSignedPrekeyId),
                firstEnvelopeId: commit.envelopeId,
              ),
            );
        final eventInserted = await database
            .into(database.inboxEventDeduplications)
            .insert(
              InboxEventDeduplicationsCompanion.insert(
                opaqueEventId: commit.opaqueEventId,
                firstEnvelopeId: commit.envelopeId,
                dependencyClass: dependency.index,
              ),
              mode: InsertMode.insertOrIgnore,
            );
        await database
            .into(database.pairwiseOpenedPayloads)
            .insert(
              PairwiseOpenedPayloadsCompanion.insert(
                envelopeId: commit.envelopeId,
                opaqueEventId: commit.opaqueEventId,
                senderUserId: commit.senderUserId,
                senderDeviceId: commit.senderDeviceId.toLowerCase(),
                sessionId: commit.sessionTransition.sessionId,
                replayMarker: commit.replayMarker,
                openedOpaquePayload: commit.openedOpaquePayload,
                applicationApplied: const Value(true),
              ),
            );
        final applicationEvent = commit.applicationEvent;
        if (applicationEvent != null) {
          await DriftApplicationEventProjector(
            database,
          ).applyInsideTransaction(applicationEvent);
        }
        final unsupported = commit.unsupportedApplicationEvent;
        if (unsupported != null) {
          await DriftApplicationEventProjector(
            database,
          ).retainUnsupportedInsideTransaction(unsupported);
        }
        await _commitDeviceControl(commit);
        await additionalCommit?.call();
        await (database.update(
          database.inboxEnvelopes,
        )..where((row) => row.envelopeId.equals(commit.envelopeId))).write(
          InboxEnvelopesCompanion(
            opaqueEventId: Value(commit.opaqueEventId),
            dependencyClass: Value(dependency.index),
            processingState: Value(
              InboxProcessingState.readyToAcknowledge.index,
            ),
            readyToAcknowledge: const Value(true),
            nextAttemptAt: const Value(null),
          ),
        );
        return eventInserted > 0;
      });
      return Result.success(applied);
    } on _PairwiseReplay {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on _PairwiseConflict {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    } on _PairwiseCapacity {
      return const Result.failure(
        StorageFailure(StorageFailureKind.capacityExceeded),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  Future<void> _commitDeviceControl(PairwiseReceiveCommit commit) async {
    final control = commit.deviceControlEvent;
    if (control == null) {
      if (commit.historyApplicationEvents.isNotEmpty) {
        throw const _PairwiseIntegrity();
      }
      return;
    }
    if (protocolUuidString(control.senderUserId) !=
            commit.senderUserId.toLowerCase() ||
        protocolUuidString(control.senderDeviceId) !=
            commit.senderDeviceId.toLowerCase()) {
      throw const _PairwiseIntegrity();
    }
    switch (control) {
      case DeviceHeadGossipEvent(:final heads):
        if (commit.historyApplicationEvents.isNotEmpty) {
          throw const _PairwiseIntegrity();
        }
        for (final head in heads) {
          final userId = protocolUuidString(head.userId);
          final local =
              await (database.select(database.deviceLogRecords)..where(
                    (row) =>
                        row.userId.equals(userId) &
                        row.sequence.equals(head.sequence),
                  ))
                  .getSingleOrNull();
          if (local != null && !_bytesEqual(local.recordHash, head.hash)) {
            await database
                .into(database.securityPostures)
                .insertOnConflictUpdate(
                  SecurityPosturesCompanion.insert(
                    singletonId: const Value(1),
                    state: 1,
                    evidenceKind: const Value(2),
                    detectedAt: Value(DateTime.now().toUtc()),
                  ),
                );
          }
        }
      case HistoryTransferRequestEvent():
        if (commit.senderUserId != commit.sessionTransition.remoteUserId ||
            commit.historyApplicationEvents.isNotEmpty) {
          throw const _PairwiseIntegrity();
        }
        final transferId = protocolBytesToHex(control.transferId!);
        final existing = await (database.select(
          database.historyTransfers,
        )..where((row) => row.transferId.equals(transferId))).getSingleOrNull();
        if (existing == null) {
          await database
              .into(database.historyTransfers)
              .insert(
                HistoryTransfersCompanion.insert(
                  transferId: transferId,
                  manifestCiphertext: control.eventId,
                  sourceDeviceId: Value(
                    commit.sessionTransition.localDeviceId.toLowerCase(),
                  ),
                  targetDeviceId: Value(commit.senderDeviceId.toLowerCase()),
                  direction: const Value(1),
                  state: const Value(1),
                  nextBatchIndex: Value(control.resumeAfterBatch),
                  sourceCompleteness: 0,
                ),
              );
        } else if (existing.targetDeviceId !=
                commit.senderDeviceId.toLowerCase() ||
            existing.sourceDeviceId !=
                commit.sessionTransition.localDeviceId.toLowerCase() ||
            existing.nextBatchIndex != control.resumeAfterBatch ||
            existing.direction != 1) {
          throw const _PairwiseConflict();
        }
      case HistoryTransferBatchEvent():
        if (commit.historyApplicationEvents.length !=
            control.canonicalEvents.length) {
          throw const _PairwiseIntegrity();
        }
        final transferId = protocolBytesToHex(control.transferId!);
        final transfer = await (database.select(
          database.historyTransfers,
        )..where((row) => row.transferId.equals(transferId))).getSingleOrNull();
        if (transfer == null ||
            transfer.direction != 0 ||
            transfer.sourceDeviceId != commit.senderDeviceId.toLowerCase() ||
            transfer.targetDeviceId !=
                commit.sessionTransition.localDeviceId.toLowerCase()) {
          throw const _PairwiseConflict();
        }
        final existing =
            await (database.select(database.historyTransferBatches)..where(
                  (row) =>
                      row.transferId.equals(transferId) &
                      row.batchIndex.equals(control.batchIndex),
                ))
                .getSingleOrNull();
        if (existing != null) {
          if (existing.controlEventId != protocolBytesToHex(control.eventId)) {
            throw const _PairwiseIntegrity();
          }
          return;
        }
        if (control.batchIndex != transfer.nextBatchIndex) {
          throw const _PairwiseConflict();
        }
        for (final application in commit.historyApplicationEvents) {
          await DriftApplicationEventProjector(
            database,
          ).applyInsideTransaction(application);
        }
        await database
            .into(database.historyTransferBatches)
            .insert(
              HistoryTransferBatchesCompanion.insert(
                transferId: transferId,
                batchIndex: control.batchIndex,
                controlEventId: protocolBytesToHex(control.eventId),
                eventCount: control.canonicalEvents.length,
                finalBatch: control.finalBatch,
              ),
            );
        await (database.update(
          database.historyTransfers,
        )..where((row) => row.transferId.equals(transferId))).write(
          HistoryTransfersCompanion(
            nextBatchIndex: Value(control.batchIndex + 1),
            eventProgress: Value(
              transfer.eventProgress + control.canonicalEvents.length,
            ),
            sourceCompleteness: Value(control.sourceCompleteness.index),
            state: Value(
              control.sourceCompleteness == HistorySourceCompleteness.partial
                  ? 3
                  : control.finalBatch
                  ? 7
                  : 2,
            ),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
      case HistoryTransferCompleteEvent(:final confirmedBatches):
        if (commit.historyApplicationEvents.isNotEmpty) {
          throw const _PairwiseIntegrity();
        }
        final transferId = protocolBytesToHex(control.transferId!);
        final transfer = await (database.select(
          database.historyTransfers,
        )..where((row) => row.transferId.equals(transferId))).getSingleOrNull();
        final sender = commit.senderDeviceId.toLowerCase();
        if (transfer == null ||
            transfer.nextBatchIndex != confirmedBatches ||
            (transfer.direction == 0 && transfer.sourceDeviceId != sender) ||
            (transfer.direction == 1 && transfer.targetDeviceId != sender)) {
          throw const _PairwiseConflict();
        }
        await (database.update(
          database.historyTransfers,
        )..where((row) => row.transferId.equals(transferId))).write(
          HistoryTransfersCompanion(
            state: const Value(7),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
      case HistoryTransferUnavailableEvent(:final reason):
        if (commit.historyApplicationEvents.isNotEmpty) {
          throw const _PairwiseIntegrity();
        }
        final transferId = protocolBytesToHex(control.transferId!);
        final transfer = await (database.select(
          database.historyTransfers,
        )..where((row) => row.transferId.equals(transferId))).getSingleOrNull();
        if (transfer == null ||
            transfer.direction != 0 ||
            transfer.sourceDeviceId != commit.senderDeviceId.toLowerCase()) {
          throw const _PairwiseConflict();
        }
        await (database.update(
          database.historyTransfers,
        )..where((row) => row.transferId.equals(transferId))).write(
          HistoryTransfersCompanion(
            state: Value(
              reason == HistoryUnavailableReason.sourcePartial ? 3 : 4,
            ),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
    }
  }

  @override
  Future<Result<void>> invalidateRemoteDevices({
    required String remoteUserId,
    required Set<String> remoteDeviceIds,
  }) async {
    final ids = remoteDeviceIds.map((id) => id.toLowerCase()).toSet();
    if (remoteUserId.isEmpty || ids.isEmpty || ids.any((id) => !_isUuid(id))) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      await database.writeTransaction(() async {
        await _invalidateRemoteDevicesInTransaction(remoteUserId, ids);
      });
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> reconcileRemoteLiveDevices({
    required String remoteUserId,
    required Set<String> liveDeviceIds,
  }) async {
    final live = liveDeviceIds.map((id) => id.toLowerCase()).toSet();
    if (remoteUserId.isEmpty || live.any((id) => !_isUuid(id))) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      await database.writeTransaction(() async {
        final known = <String>{};
        final primaryRows = await (database.select(
          database.pairwiseSessions,
        )..where((row) => row.remoteUserId.equals(remoteUserId))).get();
        known.addAll(primaryRows.map((row) => row.remoteDeviceId));
        final alternateRows = await (database.select(
          database.pairwiseSessionAlternates,
        )..where((row) => row.remoteUserId.equals(remoteUserId))).get();
        known.addAll(alternateRows.map((row) => row.remoteDeviceId));
        final outboxRows = await (database.select(
          database.outboxOperations,
        )..where((row) => row.recipientUserId.equals(remoteUserId))).get();
        known.addAll(
          outboxRows
              .where(
                (row) =>
                    row.attemptState == OutboxAttemptState.queued.index ||
                    row.attemptState == OutboxAttemptState.sending.index ||
                    row.attemptState == OutboxAttemptState.retryWait.index,
              )
              .map((row) => row.recipientDeviceId),
        );
        final stale = known.difference(live);
        if (stale.isNotEmpty) {
          await _invalidateRemoteDevicesInTransaction(remoteUserId, stale);
        }
      });
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> pruneRetainedMetadata({
    required DateTime now,
    List<ErasedPairwiseSignedPrekeyPair> erasedSignedPrekeys = const [],
  }) async {
    if (erasedSignedPrekeys.any(
      (pair) =>
          pair.signedPrekeyId < 0 ||
          pair.signedPrekeyId > 0x7fffffff ||
          pair.pqSignedPrekeyId < 0 ||
          pair.pqSignedPrekeyId > 0x7fffffff,
    )) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final utcNow = now.toUtc();
    final cutoff = utcNow.subtract(replayRetention);
    try {
      await database.writeTransaction(() async {
        await (database.delete(database.pairwiseReplayMarkers)..where(
              (row) =>
                  row.signedPrekeyId.isNull() &
                  row.committedAt.isSmallerThanValue(cutoff),
            ))
            .go();
        for (final erased in erasedSignedPrekeys) {
          await (database.delete(database.pairwiseReplayMarkers)..where(
                (row) =>
                    row.signedPrekeyId.equals(erased.signedPrekeyId) &
                    row.pqSignedPrekeyId.equals(erased.pqSignedPrekeyId),
              ))
              .go();
        }
        await (database.delete(
          database.pairwiseConsumedPrekeys,
        )..where((row) => row.consumedAt.isSmallerThanValue(cutoff))).go();
        await (database.delete(database.pairwiseOpenedPayloads)..where(
              (row) =>
                  row.applicationApplied.equals(true) &
                  row.committedAt.isSmallerThanValue(cutoff),
            ))
            .go();
        // Never the payload of a send that is still owed. Sixteen days of
        // owing one is pathological — a device that has been offline that long
        // with a message in hand — but discarding the bytes would leave a
        // message on screen that nothing can ever seal, and the projection
        // would settle it as one the user chose to keep locally.
        final owed = await database
            .customSelect('SELECT operation_id FROM pending_send_preparations')
            .map((row) => row.read<String>('operation_id'))
            .get();
        await (database.delete(database.pairwiseLocalApplications)..where(
              (row) =>
                  row.applicationApplied.equals(true) &
                  row.committedAt.isSmallerThanValue(cutoff) &
                  row.operationId.isNotIn(owed),
            ))
            .go();
      });
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  Future<void> _invalidateRemoteDevicesInTransaction(
    String remoteUserId,
    Set<String> remoteDeviceIds,
  ) async {
    await (database.delete(database.pairwiseSessions)..where(
          (row) =>
              row.remoteUserId.equals(remoteUserId) &
              row.remoteDeviceId.isIn(remoteDeviceIds),
        ))
        .go();
    await (database.delete(database.pairwiseSessionAlternates)..where(
          (row) =>
              row.remoteUserId.equals(remoteUserId) &
              row.remoteDeviceId.isIn(remoteDeviceIds),
        ))
        .go();
    await (database.update(database.outboxOperations)..where(
          (row) =>
              row.recipientUserId.equals(remoteUserId) &
              row.recipientDeviceId.isIn(remoteDeviceIds) &
              row.attemptState.isIn([
                OutboxAttemptState.queued.index,
                OutboxAttemptState.sending.index,
                OutboxAttemptState.retryWait.index,
              ]),
        ))
        .write(
          OutboxOperationsCompanion(
            attemptState: Value(OutboxAttemptState.stale.index),
            nextAttemptAt: const Value(null),
            terminalAt: Value(DateTime.now().toUtc()),
          ),
        );
  }

  Future<void> _applySessionTransition(
    PairwiseSessionTransition transition,
  ) async {
    if (!_validTransition(transition)) {
      throw const _PairwiseConflict();
    }
    await _assertNoSessionIdCollision(transition);
    if (transition.disposition ==
        PairwiseSessionDisposition.primaryBidirectional) {
      await _applyPrimaryTransition(transition);
    } else {
      await _applyAlternateTransition(transition);
    }
  }

  Future<void> _eraseAuthenticatedRepairSession(
    PairwiseSessionTransition replacement,
    Uint8List replacedSessionId,
  ) async {
    final existing =
        await (database.select(database.pairwiseSessions)..where(
              (row) =>
                  row.localDeviceId.equals(replacement.localDeviceId) &
                  row.remoteDeviceId.equals(replacement.remoteDeviceId),
            ))
            .getSingleOrNull();
    if (existing == null ||
        existing.remoteUserId != replacement.remoteUserId ||
        existing.sessionId == null ||
        !_bytesEqual(existing.sessionId!, replacedSessionId) ||
        existing.repairState !=
            PairwiseRepairState.authenticatedRequestPending.index) {
      throw const _PairwiseConflict();
    }
    final deleted =
        await (database.delete(database.pairwiseSessions)..where(
              (row) =>
                  row.localDeviceId.equals(replacement.localDeviceId) &
                  row.remoteDeviceId.equals(replacement.remoteDeviceId) &
                  row.stateVersion.equals(existing.stateVersion),
            ))
            .go();
    if (deleted != 1) {
      throw const _PairwiseConflict();
    }
  }

  Future<void> _applyPrimaryTransition(
    PairwiseSessionTransition transition,
  ) async {
    final existing =
        await (database.select(database.pairwiseSessions)..where(
              (row) =>
                  row.localDeviceId.equals(transition.localDeviceId) &
                  row.remoteDeviceId.equals(transition.remoteDeviceId),
            ))
            .getSingleOrNull();
    final expected = transition.expectedStateVersion;
    if (expected != null) {
      if (existing == null ||
          existing.stateVersion != expected ||
          existing.remoteUserId != transition.remoteUserId) {
        throw const _PairwiseConflict();
      }
      final updated =
          await (database.update(database.pairwiseSessions)..where(
                (row) =>
                    row.localDeviceId.equals(transition.localDeviceId) &
                    row.remoteDeviceId.equals(transition.remoteDeviceId) &
                    row.stateVersion.equals(expected),
              ))
              .write(
                PairwiseSessionsCompanion(
                  remoteUserId: Value(transition.remoteUserId),
                  sessionId: Value(transition.sessionId),
                  opaqueCryptoStateHandle: Value(transition.nextOpaqueState),
                  stateVersion: Value(transition.nextStateVersion),
                  skippedKeyCount: Value(transition.nextSkippedKeyCount),
                  disposition: Value(transition.disposition.index),
                  repairState: Value(transition.repairState.index),
                  repairAuthorization: Value(transition.repairAuthorization),
                  lastAuthenticatedAt: Value(DateTime.now().toUtc()),
                ),
              );
      if (updated != 1) {
        throw const _PairwiseConflict();
      }
      await (database.delete(database.pairwiseSessionAlternates)..where(
            (row) =>
                row.localDeviceId.equals(transition.localDeviceId) &
                row.remoteDeviceId.equals(transition.remoteDeviceId),
          ))
          .go();
      return;
    }

    if (existing != null) {
      if (existing.sessionId == null || existing.sessionId!.length != 16) {
        await (database.delete(database.pairwiseSessions)..where(
              (row) =>
                  row.localDeviceId.equals(transition.localDeviceId) &
                  row.remoteDeviceId.equals(transition.remoteDeviceId),
            ))
            .go();
      } else {
        if (existing.remoteUserId != transition.remoteUserId) {
          throw const _PairwiseConflict();
        }
        final alternate = await _readAlternateRow(
          transition.localDeviceId,
          transition.remoteDeviceId,
        );
        if (alternate != null) {
          throw const _PairwiseConflict();
        }
        await database
            .into(database.pairwiseSessionAlternates)
            .insert(
              PairwiseSessionAlternatesCompanion.insert(
                sessionId: existing.sessionId!,
                localDeviceId: existing.localDeviceId,
                remoteUserId: existing.remoteUserId,
                remoteDeviceId: existing.remoteDeviceId,
                opaqueCryptoStateHandle: existing.opaqueCryptoStateHandle,
                stateVersion: existing.stateVersion,
                skippedKeyCount: existing.skippedKeyCount,
                repairState: existing.repairState,
                repairAuthorization: Value(existing.repairAuthorization),
                lastAuthenticatedAt: Value(existing.lastAuthenticatedAt),
              ),
            );
        await (database.delete(database.pairwiseSessions)..where(
              (row) =>
                  row.localDeviceId.equals(transition.localDeviceId) &
                  row.remoteDeviceId.equals(transition.remoteDeviceId),
            ))
            .go();
      }
    }
    await database
        .into(database.pairwiseSessions)
        .insert(
          PairwiseSessionsCompanion.insert(
            localDeviceId: transition.localDeviceId,
            remoteUserId: Value(transition.remoteUserId),
            remoteDeviceId: transition.remoteDeviceId,
            sessionId: Value(transition.sessionId),
            opaqueCryptoStateHandle: transition.nextOpaqueState,
            stateVersion: transition.nextStateVersion,
            skippedKeyCount: Value(transition.nextSkippedKeyCount),
            disposition: Value(transition.disposition.index),
            repairState: Value(transition.repairState.index),
            repairAuthorization: Value(transition.repairAuthorization),
            lastAuthenticatedAt: Value(DateTime.now().toUtc()),
          ),
        );
  }

  Future<void> _applyAlternateTransition(
    PairwiseSessionTransition transition,
  ) async {
    if (transition.expectedStateVersion != null ||
        await _readAlternateRow(
              transition.localDeviceId,
              transition.remoteDeviceId,
            ) !=
            null) {
      throw const _PairwiseConflict();
    }
    final primary =
        await (database.select(database.pairwiseSessions)..where(
              (row) =>
                  row.localDeviceId.equals(transition.localDeviceId) &
                  row.remoteDeviceId.equals(transition.remoteDeviceId),
            ))
            .getSingleOrNull();
    if (primary != null && primary.remoteUserId != transition.remoteUserId) {
      throw const _PairwiseConflict();
    }
    await database
        .into(database.pairwiseSessionAlternates)
        .insert(
          PairwiseSessionAlternatesCompanion.insert(
            sessionId: transition.sessionId,
            localDeviceId: transition.localDeviceId,
            remoteUserId: transition.remoteUserId,
            remoteDeviceId: transition.remoteDeviceId,
            opaqueCryptoStateHandle: transition.nextOpaqueState,
            stateVersion: transition.nextStateVersion,
            skippedKeyCount: transition.nextSkippedKeyCount,
            repairState: transition.repairState.index,
            repairAuthorization: Value(transition.repairAuthorization),
            lastAuthenticatedAt: Value(DateTime.now().toUtc()),
          ),
        );
  }

  Future<void> _assertNoSessionIdCollision(
    PairwiseSessionTransition transition,
  ) async {
    final primaries = await database.select(database.pairwiseSessions).get();
    for (final row in primaries) {
      final id = row.sessionId;
      if (id != null && _bytesEqual(id, transition.sessionId)) {
        final isExpectedPrimaryUpdate =
            transition.disposition ==
                PairwiseSessionDisposition.primaryBidirectional &&
            transition.expectedStateVersion != null &&
            row.localDeviceId == transition.localDeviceId &&
            row.remoteDeviceId == transition.remoteDeviceId;
        if (!isExpectedPrimaryUpdate) {
          throw const _PairwiseConflict();
        }
      }
    }
    final alternates = await database
        .select(database.pairwiseSessionAlternates)
        .get();
    for (final row in alternates) {
      if (_bytesEqual(row.sessionId, transition.sessionId)) {
        throw const _PairwiseConflict();
      }
    }
  }

  Future<void> _applyDemotedExistingTransition(
    PairwiseSessionTransition transition,
  ) async {
    if (!_validTransition(transition) ||
        transition.disposition !=
            PairwiseSessionDisposition.alternateReceiveOnly ||
        transition.expectedStateVersion == null ||
        await _readAlternateRow(
              transition.localDeviceId,
              transition.remoteDeviceId,
            ) !=
            null) {
      throw const _PairwiseConflict();
    }
    final existing =
        await (database.select(database.pairwiseSessions)..where(
              (row) =>
                  row.localDeviceId.equals(transition.localDeviceId) &
                  row.remoteDeviceId.equals(transition.remoteDeviceId) &
                  row.stateVersion.equals(transition.expectedStateVersion!),
            ))
            .getSingleOrNull();
    if (existing == null ||
        existing.remoteUserId != transition.remoteUserId ||
        existing.sessionId == null ||
        !_bytesEqual(existing.sessionId!, transition.sessionId)) {
      throw const _PairwiseConflict();
    }
    await (database.delete(database.pairwiseSessions)..where(
          (row) =>
              row.localDeviceId.equals(transition.localDeviceId) &
              row.remoteDeviceId.equals(transition.remoteDeviceId) &
              row.stateVersion.equals(transition.expectedStateVersion!),
        ))
        .go();
    await database
        .into(database.pairwiseSessionAlternates)
        .insert(
          PairwiseSessionAlternatesCompanion.insert(
            sessionId: transition.sessionId,
            localDeviceId: transition.localDeviceId,
            remoteUserId: transition.remoteUserId,
            remoteDeviceId: transition.remoteDeviceId,
            opaqueCryptoStateHandle: transition.nextOpaqueState,
            stateVersion: transition.nextStateVersion,
            skippedKeyCount: transition.nextSkippedKeyCount,
            repairState: transition.repairState.index,
            repairAuthorization: Value(transition.repairAuthorization),
            lastAuthenticatedAt: Value(DateTime.now().toUtc()),
          ),
        );
  }

  Future<PairwiseSessionSnapshot?> _readPrimary(
    String localDeviceId,
    String remoteDeviceId,
  ) async {
    final row =
        await (database.select(database.pairwiseSessions)..where(
              (item) =>
                  item.localDeviceId.equals(localDeviceId) &
                  item.remoteDeviceId.equals(remoteDeviceId),
            ))
            .getSingleOrNull();
    if (row == null || row.sessionId == null) {
      return null;
    }
    return _primarySnapshot(row);
  }

  PairwiseSessionSnapshot _primarySnapshot(PairwiseSession row) {
    final sessionId = row.sessionId;
    if (sessionId == null ||
        sessionId.length != 16 ||
        row.remoteUserId.isEmpty ||
        row.disposition !=
            PairwiseSessionDisposition.primaryBidirectional.index ||
        row.skippedKeyCount < 0 ||
        row.skippedKeyCount > maximumSkippedKeysPerSession ||
        row.repairState < 0 ||
        row.repairState >= PairwiseRepairState.values.length) {
      throw const _PairwiseIntegrity();
    }
    return PairwiseSessionSnapshot(
      localDeviceId: row.localDeviceId,
      remoteUserId: row.remoteUserId,
      remoteDeviceId: row.remoteDeviceId,
      sessionId: sessionId,
      opaqueState: row.opaqueCryptoStateHandle,
      stateVersion: row.stateVersion,
      skippedKeyCount: row.skippedKeyCount,
      disposition: PairwiseSessionDisposition.primaryBidirectional,
      repairState: PairwiseRepairState.values[row.repairState],
      repairAuthorization: row.repairAuthorization,
    );
  }

  Future<PairwiseSessionSnapshot?> _readAlternate(
    String localDeviceId,
    String remoteDeviceId,
  ) async {
    final row = await _readAlternateRow(localDeviceId, remoteDeviceId);
    return row == null ? null : _alternateSnapshot(row);
  }

  Future<PairwiseSessionAlternate?> _readAlternateRow(
    String localDeviceId,
    String remoteDeviceId,
  ) =>
      (database.select(database.pairwiseSessionAlternates)..where(
            (item) =>
                item.localDeviceId.equals(localDeviceId) &
                item.remoteDeviceId.equals(remoteDeviceId),
          ))
          .getSingleOrNull();

  Future<PairwiseSessionSnapshot?> _readSessionById(
    String localDeviceId,
    Uint8List sessionId,
  ) async {
    final primaries = await (database.select(
      database.pairwiseSessions,
    )..where((row) => row.localDeviceId.equals(localDeviceId))).get();
    final primaryMatches = primaries
        .where(
          (row) =>
              row.sessionId != null && _bytesEqual(row.sessionId!, sessionId),
        )
        .toList(growable: false);
    final alternates = await (database.select(
      database.pairwiseSessionAlternates,
    )..where((row) => row.localDeviceId.equals(localDeviceId))).get();
    final alternateMatches = alternates
        .where((row) => _bytesEqual(row.sessionId, sessionId))
        .toList(growable: false);
    if (primaryMatches.length + alternateMatches.length > 1) {
      throw const _PairwiseIntegrity();
    }
    if (primaryMatches.isNotEmpty) {
      return _primarySnapshot(primaryMatches.single);
    }
    return alternateMatches.isEmpty
        ? null
        : _alternateSnapshot(alternateMatches.single);
  }

  PairwiseSessionSnapshot _alternateSnapshot(PairwiseSessionAlternate row) =>
      _validAlternateRow(row)
      ? PairwiseSessionSnapshot(
          localDeviceId: row.localDeviceId,
          remoteUserId: row.remoteUserId,
          remoteDeviceId: row.remoteDeviceId,
          sessionId: row.sessionId,
          opaqueState: row.opaqueCryptoStateHandle,
          stateVersion: row.stateVersion,
          skippedKeyCount: row.skippedKeyCount,
          disposition: PairwiseSessionDisposition.alternateReceiveOnly,
          repairState: PairwiseRepairState.values[row.repairState],
          repairAuthorization: row.repairAuthorization,
        )
      : throw const _PairwiseIntegrity();

  bool _validAlternateRow(PairwiseSessionAlternate row) =>
      row.sessionId.length == 16 &&
      row.remoteUserId.isNotEmpty &&
      row.skippedKeyCount >= 0 &&
      row.skippedKeyCount <= maximumSkippedKeysPerSession &&
      row.repairState >= 0 &&
      row.repairState < PairwiseRepairState.values.length &&
      _validRepairAuthorization(
        PairwiseRepairState.values[row.repairState],
        row.repairAuthorization,
      );

  Future<int> _skippedKeyTotal() async {
    final row = await database.customSelect('''
SELECT
  COALESCE((SELECT SUM(skipped_key_count) FROM pairwise_sessions), 0) +
  COALESCE((SELECT SUM(skipped_key_count) FROM pairwise_session_alternates), 0)
  AS skipped_total
''').getSingle();
    return row.read<int>('skipped_total');
  }

  Future<int> _outboxCount() async {
    final count = database.outboxOperations.operationId.count();
    final row = await (database.selectOnly(
      database.outboxOperations,
    )..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> _tableCount(TableInfo<Table, Object?> table) async {
    final count = table.$columns.first.count();
    final row = await (database.selectOnly(
      table,
    )..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  bool _validSend(
    PairwiseSendCommit commit,
    List<PreparedPairwiseSendTarget> sorted,
  ) {
    if (commit.operationId.isEmpty ||
        commit.eventId.isEmpty ||
        !_isUuid(commit.currentDeviceId) ||
        commit.expectedDeviceStateVersion <= 0 ||
        commit.openedLocalPayload.isEmpty ||
        commit.openedLocalPayload.length > 262144 ||
        sorted.isEmpty) {
      return false;
    }
    final ids = <String>{};
    for (final target in sorted) {
      final id = target.recipientDeviceId.toLowerCase();
      if (!_isUuid(id) ||
          id == commit.currentDeviceId.toLowerCase() ||
          target.recipientUserId.isEmpty ||
          !config.current.envelopeBuckets.contains(
            target.exactCiphertext.length,
          ) ||
          !ids.add(id) ||
          target.sessionTransition.localDeviceId.toLowerCase() !=
              commit.currentDeviceId.toLowerCase() ||
          target.sessionTransition.remoteUserId != target.recipientUserId ||
          target.sessionTransition.remoteDeviceId.toLowerCase() != id ||
          target.sessionTransition.disposition !=
              PairwiseSessionDisposition.primaryBidirectional) {
        return false;
      }
      final demoted = target.demotedExistingSessionTransition;
      if (demoted != null &&
          !_validDemotedTransition(demoted, target.sessionTransition)) {
        return false;
      }
    }
    return true;
  }

  bool _validReceive(PairwiseReceiveCommit commit) {
    final transition = commit.sessionTransition;
    final consumed = <String>{};
    final application = commit.applicationEvent;
    final unsupported = commit.unsupportedApplicationEvent;
    return _isUuid(commit.envelopeId) &&
        commit.opaqueEventId.isNotEmpty &&
        commit.senderUserId.isNotEmpty &&
        _isUuid(commit.senderDeviceId) &&
        commit.replayMarker.length == 32 &&
        commit.openedOpaquePayload.isNotEmpty &&
        commit.openedOpaquePayload.length <= 262144 &&
        !(application != null && unsupported != null) &&
        (commit.deviceControlEvent == null ||
            (application == null && unsupported == null)) &&
        (commit.historyApplicationEvents.isEmpty ||
            (commit.deviceControlEvent is HistoryTransferBatchEvent &&
                commit.historyApplicationEvents.length ==
                    (commit.deviceControlEvent as HistoryTransferBatchEvent)
                        .canonicalEvents
                        .length)) &&
        (application == null ||
            (!application.localOrigin &&
                protocolUuidString(application.event.senderUserId) ==
                    commit.senderUserId.toLowerCase() &&
                protocolUuidString(application.event.senderDeviceId) ==
                    commit.senderDeviceId.toLowerCase())) &&
        (unsupported == null ||
            (unsupported.senderUserId == commit.senderUserId.toLowerCase() &&
                unsupported.senderDeviceId ==
                    commit.senderDeviceId.toLowerCase())) &&
        transition.remoteUserId == commit.senderUserId &&
        transition.remoteDeviceId.toLowerCase() ==
            commit.senderDeviceId.toLowerCase() &&
        (commit.signedPrekeyId == null ||
            (commit.signedPrekeyId! >= 0 &&
                commit.signedPrekeyId! <= 0x7fffffff)) &&
        (commit.pqSignedPrekeyId == null ||
            (commit.pqSignedPrekeyId! >= 0 &&
                commit.pqSignedPrekeyId! <= 0x7fffffff)) &&
        ((commit.signedPrekeyId == null) ==
            (commit.pqSignedPrekeyId == null)) &&
        _validTransition(transition) &&
        (commit.demotedExistingSessionTransition == null ||
            _validDemotedTransition(
              commit.demotedExistingSessionTransition!,
              transition,
            )) &&
        (commit.replacedSessionId == null ||
            (commit.replacedSessionId!.length == 16 &&
                commit.demotedExistingSessionTransition == null &&
                transition.expectedStateVersion == null &&
                transition.disposition ==
                    PairwiseSessionDisposition.primaryBidirectional &&
                transition.repairState == PairwiseRepairState.ready)) &&
        (commit.deviceStateTransition == null ||
            _validDeviceTransition(commit.deviceStateTransition!)) &&
        commit.consumedOneTimePrekeys.every(
          (key) =>
              key.keyId >= 0 &&
              key.keyId <= 0x7fffffff &&
              consumed.add('${key.kind.index}:${key.keyId}'),
        ) &&
        (commit.consumedOneTimePrekeys.isEmpty ||
            commit.deviceStateTransition != null);
  }

  bool _validTransition(PairwiseSessionTransition transition) {
    final expected = transition.expectedStateVersion;
    return _isUuid(transition.localDeviceId) &&
        transition.remoteUserId.isNotEmpty &&
        _isUuid(transition.remoteDeviceId) &&
        transition.sessionId.length == 16 &&
        transition.nextOpaqueState.isNotEmpty &&
        transition.nextOpaqueState.length <= 2 * 1024 * 1024 &&
        (expected == null
            ? transition.nextStateVersion == 1
            : expected > 0 && transition.nextStateVersion == expected + 1) &&
        transition.nextSkippedKeyCount >= 0 &&
        transition.nextSkippedKeyCount <= maximumSkippedKeysPerSession &&
        _validRepairAuthorization(
          transition.repairState,
          transition.repairAuthorization,
        );
  }

  bool _validDemotedTransition(
    PairwiseSessionTransition demoted,
    PairwiseSessionTransition replacement,
  ) =>
      _validTransition(demoted) &&
      demoted.disposition == PairwiseSessionDisposition.alternateReceiveOnly &&
      demoted.expectedStateVersion != null &&
      replacement.disposition ==
          PairwiseSessionDisposition.primaryBidirectional &&
      replacement.expectedStateVersion == null &&
      demoted.localDeviceId == replacement.localDeviceId &&
      demoted.remoteUserId == replacement.remoteUserId &&
      demoted.remoteDeviceId == replacement.remoteDeviceId &&
      !_bytesEqual(demoted.sessionId, replacement.sessionId);

  bool _validRepairAuthorization(
    PairwiseRepairState state,
    Uint8List? authorization,
  ) => authorization == null
      ? state != PairwiseRepairState.replacementPending
      : state == PairwiseRepairState.replacementPending &&
            authorization.length == 88;

  bool _validDeviceTransition(PairwiseDeviceStateTransition transition) =>
      transition.expectedStateVersion > 0 &&
      transition.nextStateVersion == transition.expectedStateVersion + 1 &&
      transition.nextOpaqueState.isNotEmpty &&
      transition.nextOpaqueState.length <= 2 * 1024 * 1024;

  bool _sameLocalApplication(
    PairwiseLocalApplication local,
    PairwiseSendCommit commit,
  ) =>
      local.eventId == commit.eventId &&
      local.localDeviceId == commit.currentDeviceId.toLowerCase() &&
      _bytesEqual(local.openedOpaquePayload, commit.openedLocalPayload);

  bool _samePreparedSend(
    List<OutboxOperation> rows,
    PairwiseLocalApplication? local,
    PairwiseSendCommit commit,
    List<PreparedPairwiseSendTarget> sorted,
  ) {
    if (local == null ||
        !_sameLocalApplication(local, commit) ||
        rows.length != sorted.length ||
        rows.any((row) => row.eventId != commit.eventId)) {
      return false;
    }
    final existing = List<OutboxOperation>.of(rows)
      ..sort(
        (left, right) =>
            _compareUuidBytes(left.recipientDeviceId, right.recipientDeviceId),
      );
    for (var index = 0; index < sorted.length; index += 1) {
      final row = existing[index];
      final target = sorted[index];
      if (row.recipientUserId != target.recipientUserId ||
          row.recipientDeviceId != target.recipientDeviceId.toLowerCase() ||
          !_bytesEqual(row.exactRecipientCiphertext, target.exactCiphertext)) {
        return false;
      }
    }
    return true;
  }
}

final class _PairwiseConflict implements Exception {
  const _PairwiseConflict();
}

final class _PairwiseCapacity implements Exception {
  const _PairwiseCapacity();
}

final class _PairwiseReplay implements Exception {
  const _PairwiseReplay();
}

final class _PairwiseIntegrity implements Exception {
  const _PairwiseIntegrity();
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
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
