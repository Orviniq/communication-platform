import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/ports/prekey_maintenance_ports.dart';
import 'package:communication_platform/features/devices/domain/prekey_maintenance_model.dart';

/// Resumable prekey maintenance. Every network attempt follows a durable exact plan.
final class PrekeyMaintenanceService {
  const PrekeyMaintenanceService({
    required this.remote,
    required this.crypto,
    required this.store,
    required this.rotationLog,
    required this.clock,
    this.heldEnvelopes,
  });

  final DevicePrekeyRemotePort remote;
  final PrekeyMaintenanceCryptoPort crypto;
  final PrekeyMaintenanceStore store;
  final RotationDeviceLogPort rotationLog;
  final TimeSource clock;

  /// The earliest hold day of an envelope kept for a verification of its
  /// sender. Without it, or with nothing held, maintenance runs on today
  /// alone (ADR-093 D17).
  final HeldEnvelopeRetentionPort? heldEnvelopes;

  Future<Result<PrekeyMaintenanceReport>> maintain({
    required String deviceId,
  }) async {
    final pendingResult = await store.readPending(deviceId: deviceId);
    if (pendingResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    var pending = (pendingResult as Success<PrekeyMaintenancePlan?>).value;
    if (pending != null) {
      return _resume(pending);
    }

    final countsResult = await remote.fetchCounts(deviceId: deviceId);
    if (countsResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final counts = (countsResult as Success<PrekeyCounts>).value;
    final day = _unixDay(clock.now());
    final heldDayResult = await _earliestHoldDay();
    if (heldDayResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final heldDay = (heldDayResult as Success<int?>).value;

    var contextResult = await store.readContext(deviceId: deviceId);
    if (contextResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    var context = (contextResult as Success<PrekeyMaintenanceContext>).value;

    // A held envelope stays openable until it expires (ADR-093 D6), so no
    // retired pair whose last day is on or after its hold day is erased.
    final pruneResult = await crypto.pruneRetainedSignedPrekeys(
      deviceState: context.opaqueDeviceState,
      unixDay: heldDay != null && heldDay < day ? heldDay : day,
    );
    if (pruneResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final prune = (pruneResult as Success<PrekeyPruneResult>).value;
    if (prune.bundleVersion != context.bundleVersion ||
        prune.currentSignedPrekeyCreatedUnixDay > day) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final persistedSummary = await store.persistNativeSummary(
      deviceId: deviceId,
      expectedStateRevision: context.stateRevision,
      nextDeviceState: prune.nextDeviceState,
      stateChanged: prune.stateChanged,
      bundleVersion: prune.bundleVersion,
      currentSignedPrekeyCreatedUnixDay:
          prune.currentSignedPrekeyCreatedUnixDay,
      erasedSignedPrekeys: prune.erasedSignedPrekeys,
    );
    if (persistedSummary case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    contextResult = await store.readContext(deviceId: deviceId);
    if (contextResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    context = (contextResult as Success<PrekeyMaintenanceContext>).value;
    if (context.bundleVersion != prune.bundleVersion ||
        context.lastSignedPrekeyRotationUnixDay !=
            prune.currentSignedPrekeyCreatedUnixDay) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }

    final rotate =
        context.rotationDue(day) &&
        !_rotationWouldEraseHeldPair(
          today: day,
          lastRotationDay: context.lastSignedPrekeyRotationUnixDay,
          heldDay: heldDay,
        );
    if (!counts.needsReplenishment && !rotate) {
      return Result.success(
        PrekeyMaintenanceReport(
          counts: counts,
          uploaded: false,
          rotated: false,
        ),
      );
    }

    // Native pending-state rules permit one exact batch at a time. A due signed
    // prekey rotation therefore completes (including its device-log append) before
    // a later pass prepares any one-time-prekey refill.
    final classicalToGenerate = rotate ? 0 : counts.classicalReplenishment;
    final pqToGenerate = rotate ? 0 : counts.pqReplenishment;
    final targetClassical = counts.classical + classicalToGenerate;
    final targetPq = counts.postQuantum + pqToGenerate;

    final preparedResult = await crypto.prepare(
      context: context,
      serverCounts: counts,
      targetClassicalCount: targetClassical,
      targetPqCount: targetPq,
      rotateSignedPrekeys: rotate,
      unixDay: day,
    );
    if (preparedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    pending = (preparedResult as Success<PrekeyMaintenancePlan>).value;
    if (!_matchesRequest(
      pending,
      context,
      classicalToGenerate,
      pqToGenerate,
      rotate,
      day,
    )) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final persisted = await store.persistPrepared(pending);
    if (persisted case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return _resume(pending);
  }

  Future<Result<PrekeyMaintenanceReport>> _resume(
    PrekeyMaintenancePlan plan,
  ) async {
    if (plan.stage == PrekeyMaintenanceStage.prepared) {
      final uploaded = await remote.upload(
        deviceId: plan.deviceId,
        upload: plan.upload,
      );
      if (uploaded case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      if (plan.rotatesSignedPrekeys) {
        plan = plan.awaitingDeviceLogPreparation();
        final checkpoint = await store.markUploadAccepted(plan: plan);
        if (checkpoint case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
      }
    }

    if (plan.rotatesSignedPrekeys) {
      if (plan.stage ==
          PrekeyMaintenanceStage.uploadAcceptedAwaitingDeviceLogPreparation) {
        final preparedLog = await rotationLog.prepareOwnRotation(plan);
        if (preparedLog case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        plan = plan.withPreparedDeviceLog(
          (preparedLog as Success<PreparedRotationDeviceLog>).value,
        );
        final storedLog = await store.persistRotationLogPrepared(plan: plan);
        if (storedLog case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
      }
      final logged = await rotationLog.appendOrReconcile(
        plan.rotationDeviceLog!,
      );
      if (logged case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
    }

    final committed = await crypto.commitPendingUpload(
      pendingDeviceState: plan.pendingDeviceState,
      batchId: plan.batchId,
      unixDay: plan.preparedUnixDay,
      rotationLogAppended: plan.rotatesSignedPrekeys,
    );
    if (committed case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final committedSummary = (committed as Success<PrekeyCommitResult>).value;
    if (committedSummary.bundleVersion != plan.bundleVersion ||
        committedSummary.currentSignedPrekeyCreatedUnixDay !=
            plan.currentSignedPrekeyCreatedUnixDay) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }

    final confirmedResult = await remote.fetchCounts(deviceId: plan.deviceId);
    if (confirmedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final confirmed = (confirmedResult as Success<PrekeyCounts>).value;
    final completed = await store.complete(
      plan: plan,
      confirmedCounts: confirmed,
      committed: committedSummary,
    );
    if (completed case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(
      PrekeyMaintenanceReport(
        counts: confirmed,
        uploaded: true,
        rotated: plan.rotatesSignedPrekeys,
      ),
    );
  }

  Future<Result<int?>> _earliestHoldDay() async {
    final port = heldEnvelopes;
    if (port == null) {
      return const Result.success(null);
    }
    return port.earliestHoldUnixDay();
  }

  /// Whether a due rotation must wait for a held envelope (ADR-093 D17).
  ///
  /// The core's rotation prunes with today before it retires the current pair,
  /// and the Rust core does not change, so the wait is the only way to keep a
  /// pair a held envelope may need. The pair retired at the last rotation
  /// lasts through its day plus the retention; every older retired pair
  /// through its day plus one at most, because rotations are at least
  /// [PrekeyMaintenancePolicy.signedPrekeyRotationDays] apart. Replenishment
  /// still runs while a rotation waits.
  bool _rotationWouldEraseHeldPair({
    required int today,
    required int lastRotationDay,
    required int? heldDay,
  }) {
    if (heldDay == null) {
      return false;
    }
    const retention = PrekeyMaintenancePolicy.signedPrekeyRetentionThroughDay;
    const olderRetention =
        retention - PrekeyMaintenancePolicy.signedPrekeyRotationDays;
    return heldDay <= lastRotationDay + olderRetention ||
        (today > lastRotationDay + retention &&
            heldDay <= lastRotationDay + retention);
  }

  bool _matchesRequest(
    PrekeyMaintenancePlan plan,
    PrekeyMaintenanceContext context,
    int classicalCount,
    int pqCount,
    bool rotate,
    int day,
  ) {
    final rotation = plan.upload.rotation;
    return plan.deviceId == context.deviceId &&
        plan.expectedStateRevision == context.stateRevision &&
        plan.preparedUnixDay == day &&
        plan.bundleVersion == context.bundleVersion + (rotate ? 1 : 0) &&
        plan.currentSignedPrekeyCreatedUnixDay ==
            (rotate ? day : context.lastSignedPrekeyRotationUnixDay) &&
        plan.stage == PrekeyMaintenanceStage.prepared &&
        plan.upload.classicalOneTimePrekeys.length == classicalCount &&
        plan.upload.pqOneTimePrekeys.length == pqCount &&
        (rotation != null) == rotate &&
        (!rotate || rotation!.bundleVersion == context.bundleVersion + 1);
  }

  int _unixDay(DateTime value) =>
      value.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
}
