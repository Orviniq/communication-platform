import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/domain/prekey_maintenance_model.dart';

abstract interface class DevicePrekeyRemotePort implements Port {
  Future<Result<PrekeyCounts>> fetchCounts({required String deviceId});

  /// Retries must reuse the same immutable [upload] projection.
  Future<Result<int>> upload({
    required String deviceId,
    required PrekeyUploadProjection upload,
  });
}

/// The earliest *hold day* of an envelope kept, unopened, for a verification
/// of its sender: the UTC day it was first held (ADR-093 D17).
///
/// Null when nothing is held. A retired signed pair whose last day is on or
/// after it may still be needed to open that envelope.
abstract interface class HeldEnvelopeRetentionPort implements Port {
  Future<Result<int?>> earliestHoldUnixDay();
}

/// High-level adapter over Rust operations 2–5. Dart never creates private keys.
abstract interface class PrekeyMaintenanceCryptoPort implements Port {
  Future<Result<PrekeyMaintenancePlan>> prepare({
    required PrekeyMaintenanceContext context,
    required PrekeyCounts serverCounts,
    required int targetClassicalCount,
    required int targetPqCount,
    required bool rotateSignedPrekeys,
    required int unixDay,
  });

  Future<Result<PrekeyCommitResult>> commitPendingUpload({
    required Uint8List pendingDeviceState,
    required Uint8List batchId,
    required int unixDay,
    required bool rotationLogAppended,
  });

  Future<Result<PrekeyPruneResult>> pruneRetainedSignedPrekeys({
    required Uint8List deviceState,
    required int unixDay,
  });
}

/// Drift implementation must keep the exact prepared plan until completion.
abstract interface class PrekeyMaintenanceStore implements Port {
  Future<Result<PrekeyMaintenancePlan?>> readPending({
    required String deviceId,
  });

  Future<Result<PrekeyMaintenanceContext>> readContext({
    required String deviceId,
  });

  /// CAS-persist the native pending state and exact upload before network I/O.
  Future<Result<void>> persistPrepared(PrekeyMaintenancePlan plan);

  /// CAS-install the native committed state while retaining a rotation plan.
  Future<Result<void>> markUploadAccepted({
    required PrekeyMaintenancePlan plan,
  });

  /// Persists exact signed/padded log bytes before any append attempt.
  Future<Result<void>> persistRotationLogPrepared({
    required PrekeyMaintenancePlan plan,
  });

  /// CAS-install the native summary before making any rotation decision.
  ///
  /// This must run even when [stateChanged] is false: the native signed-key
  /// creation day is authoritative over a legacy database default.
  Future<Result<void>> persistNativeSummary({
    required String deviceId,
    required int expectedStateRevision,
    required Uint8List nextDeviceState,
    required bool stateChanged,
    required int bundleVersion,
    required int currentSignedPrekeyCreatedUnixDay,
    required List<ErasedSignedPrekeyPair> erasedSignedPrekeys,
  });

  /// Clear the pending plan and atomically finalize key upload/use projections.
  Future<Result<void>> complete({
    required PrekeyMaintenancePlan plan,
    required PrekeyCounts confirmedCounts,
    required PrekeyCommitResult committed,
  });
}

/// Rotation is not complete until the new canonical live set extends our own log.
/// Implementations reconcile an ambiguous append by inspecting the expected record.
abstract interface class RotationDeviceLogPort implements Port {
  Future<Result<PreparedRotationDeviceLog>> prepareOwnRotation(
    PrekeyMaintenancePlan plan,
  );

  Future<Result<void>> appendOrReconcile(PreparedRotationDeviceLog prepared);
}
