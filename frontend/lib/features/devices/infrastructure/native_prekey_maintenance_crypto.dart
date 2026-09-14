import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/pairwise_crypto_port.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/ports/prekey_maintenance_ports.dart';
import 'package:communication_platform/features/devices/domain/prekey_maintenance_model.dart';

final class NativePrekeyMaintenanceCrypto
    implements PrekeyMaintenanceCryptoPort {
  const NativePrekeyMaintenanceCrypto(this.crypto);

  final PairwiseCryptoPort crypto;

  @override
  Future<Result<PrekeyMaintenancePlan>> prepare({
    required PrekeyMaintenanceContext context,
    required PrekeyCounts serverCounts,
    required int targetClassicalCount,
    required int targetPqCount,
    required bool rotateSignedPrekeys,
    required int unixDay,
  }) async {
    try {
      if (unixDay < 0 ||
          targetClassicalCount < serverCounts.classical ||
          targetClassicalCount > PrekeyMaintenancePolicy.maximumClassicalPool ||
          targetPqCount < serverCounts.postQuantum ||
          targetPqCount > PrekeyMaintenancePolicy.maximumPqPool ||
          (rotateSignedPrekeys &&
              (targetClassicalCount != serverCounts.classical ||
                  targetPqCount != serverCounts.postQuantum))) {
        return _integrityFailure();
      }
      final writer = _Writer()
        ..frame(context.opaqueDeviceState)
        ..u32(unixDay);
      final operation = rotateSignedPrekeys
          ? PairwiseCryptoOperation.prepareSignedPrekeyRotation
          : PairwiseCryptoOperation.prepareReplenishment;
      if (rotateSignedPrekeys) {
        writer
          ..frame(context.opaqueIdentityState)
          ..bytes(context.rawDeviceId)
          ..u32(unixDay);
      } else {
        writer
          ..u16(serverCounts.classical)
          ..u16(serverCounts.postQuantum)
          ..u16(targetClassicalCount)
          ..u16(targetPqCount);
      }
      final result = await crypto.pairwiseOperation(
        operation: operation,
        payload: writer.takeBytes(),
      );
      if (result case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final response = (result as Success<PairwiseCryptoResponse>).value;
      if (response.outcome != PairwiseCryptoOutcome.ok) {
        return _integrityFailure();
      }
      return Result.success(
        rotateSignedPrekeys
            ? _rotationPlan(response.body, context, unixDay)
            : _replenishmentPlan(
                response.body,
                context,
                unixDay,
                targetClassicalCount - serverCounts.classical,
                targetPqCount - serverCounts.postQuantum,
              ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
  }

  @override
  Future<Result<PrekeyCommitResult>> commitPendingUpload({
    required Uint8List pendingDeviceState,
    required Uint8List batchId,
    required int unixDay,
    required bool rotationLogAppended,
  }) async {
    try {
      if (batchId.length != 16 || unixDay < 0) {
        return _integrityFailure();
      }
      final payload =
          (_Writer()
                ..frame(pendingDeviceState)
                ..u32(unixDay)
                ..bytes(batchId)
                ..boolean(rotationLogAppended))
              .takeBytes();
      return await _stateOperation(
        PairwiseCryptoOperation.commitPendingUpload,
        payload,
        maximumUnixDay: unixDay,
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
  }

  @override
  Future<Result<PrekeyPruneResult>> pruneRetainedSignedPrekeys({
    required Uint8List deviceState,
    required int unixDay,
  }) async {
    try {
      if (unixDay < 0) {
        return _integrityFailure();
      }
      final payload =
          (_Writer()
                ..frame(deviceState)
                ..u32(unixDay)
                ..u32(unixDay))
              .takeBytes();
      final responseResult = await crypto.pairwiseOperation(
        operation: PairwiseCryptoOperation.pruneRetainedSignedPrekeys,
        payload: payload,
      );
      if (responseResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final response =
          (responseResult as Success<PairwiseCryptoResponse>).value;
      if (response.outcome != PairwiseCryptoOutcome.ok) {
        return _integrityFailure();
      }
      final reader = _Reader(response.body);
      final state = reader.frame();
      final privateClassicalCount = reader.u16();
      final privatePqCount = reader.u16();
      final bundleVersion = reader.u32();
      final currentSignedPrekeyCreatedUnixDay = reader.u32();
      final erasedCount = reader.u8();
      final erased = <ErasedSignedPrekeyPair>[];
      var previousId = -1;
      for (var index = 0; index < erasedCount; index += 1) {
        final classicalId = reader.u32();
        final pqId = reader.u32();
        if (classicalId <= previousId ||
            classicalId > 0x7fffffff ||
            pqId < 0 ||
            pqId > 0x7fffffff) {
          return _integrityFailure();
        }
        previousId = classicalId;
        erased.add(
          ErasedSignedPrekeyPair(
            classicalSignedPrekeyId: classicalId,
            pqSignedPrekeyId: pqId,
          ),
        );
      }
      if (!reader.finished ||
          privateClassicalCount > 400 ||
          privatePqCount > 240 ||
          bundleVersion == 0 ||
          currentSignedPrekeyCreatedUnixDay > unixDay ||
          (_same(state, deviceState) && erased.isNotEmpty)) {
        return _integrityFailure();
      }
      return Result.success(
        PrekeyPruneResult(
          nextDeviceState: state,
          stateChanged: !_same(state, deviceState),
          bundleVersion: bundleVersion,
          currentSignedPrekeyCreatedUnixDay: currentSignedPrekeyCreatedUnixDay,
          erasedSignedPrekeys: erased,
        ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
  }

  Future<Result<PrekeyCommitResult>> _stateOperation(
    PairwiseCryptoOperation operation,
    Uint8List payload, {
    required int maximumUnixDay,
  }) async {
    final result = await crypto.pairwiseOperation(
      operation: operation,
      payload: payload,
    );
    if (result case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final response = (result as Success<PairwiseCryptoResponse>).value;
    if (response.outcome != PairwiseCryptoOutcome.ok) {
      return _integrityFailure();
    }
    try {
      final reader = _Reader(response.body);
      final state = reader.frame();
      final privateClassicalCount = reader.u16();
      final privatePqCount = reader.u16();
      final bundleVersion = reader.u32();
      final currentSignedPrekeyCreatedUnixDay = reader.u32();
      if (!reader.finished ||
          privateClassicalCount > 400 ||
          privatePqCount > 240 ||
          bundleVersion == 0 ||
          currentSignedPrekeyCreatedUnixDay > maximumUnixDay) {
        return _integrityFailure();
      }
      return Result.success(
        PrekeyCommitResult(
          nextDeviceState: state,
          bundleVersion: bundleVersion,
          currentSignedPrekeyCreatedUnixDay: currentSignedPrekeyCreatedUnixDay,
        ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
  }

  PrekeyMaintenancePlan _replenishmentPlan(
    Uint8List body,
    PrekeyMaintenanceContext context,
    int unixDay,
    int expectedClassical,
    int expectedPq,
  ) {
    final reader = _Reader(body);
    final state = reader.frame();
    final batchId = reader.take(16);
    final projectionBytes = reader.frame();
    final privateClassicalCount = reader.u16();
    final privatePqCount = reader.u16();
    final currentSignedPrekeyCreatedUnixDay = reader.u32();
    if (!reader.finished ||
        privateClassicalCount > 400 ||
        privatePqCount > 240 ||
        currentSignedPrekeyCreatedUnixDay > unixDay) {
      throw const PrekeyMaintenanceFormatException();
    }
    final projection = _parseReplenishmentProjection(
      projectionBytes,
      batchId,
      context.bundleVersion,
      expectedClassical,
      expectedPq,
    );
    return PrekeyMaintenancePlan(
      deviceId: context.deviceId,
      expectedStateRevision: context.stateRevision,
      preparedUnixDay: unixDay,
      bundleVersion: context.bundleVersion,
      currentSignedPrekeyCreatedUnixDay: currentSignedPrekeyCreatedUnixDay,
      batchId: batchId,
      nativeUploadProjection: projectionBytes,
      pendingDeviceState: state,
      upload: projection,
    );
  }

  PrekeyMaintenancePlan _rotationPlan(
    Uint8List body,
    PrekeyMaintenanceContext context,
    int unixDay,
  ) {
    final reader = _Reader(body);
    final state = reader.frame();
    final batchId = reader.take(16);
    final projectionBytes = reader.frame();
    final bundleVersion = reader.u32();
    final currentSignedPrekeyCreatedUnixDay = reader.u32();
    if (!reader.finished ||
        bundleVersion != context.bundleVersion + 1 ||
        currentSignedPrekeyCreatedUnixDay != unixDay) {
      throw const PrekeyMaintenanceFormatException();
    }
    final projection = _parseRotationProjection(
      projectionBytes,
      batchId,
      bundleVersion,
    );
    return PrekeyMaintenancePlan(
      deviceId: context.deviceId,
      expectedStateRevision: context.stateRevision,
      preparedUnixDay: unixDay,
      bundleVersion: bundleVersion,
      currentSignedPrekeyCreatedUnixDay: currentSignedPrekeyCreatedUnixDay,
      batchId: batchId,
      nativeUploadProjection: projectionBytes,
      pendingDeviceState: state,
      upload: projection,
    );
  }
}

PrekeyUploadProjection _parseReplenishmentProjection(
  Uint8List bytes,
  Uint8List expectedBatchId,
  int expectedBundleVersion,
  int expectedClassical,
  int expectedPq,
) {
  final reader = _Reader(bytes);
  if (!_same(reader.take(8), ascii.encode('CPKUV001')) ||
      !_same(reader.take(16), expectedBatchId) ||
      reader.u8() != 1 ||
      reader.u32() != expectedBundleVersion) {
    throw const PrekeyMaintenanceFormatException();
  }
  final classicalCount = reader.u16();
  if (classicalCount != expectedClassical || classicalCount > 200) {
    throw const PrekeyMaintenanceFormatException();
  }
  final classical = <PrekeyUploadEntry>[];
  for (var index = 0; index < classicalCount; index += 1) {
    classical.add(
      PrekeyUploadEntry.classical(
        keyId: reader.u32(),
        publicKey: reader.take(32),
      ),
    );
  }
  final pqCount = reader.u16();
  if (pqCount != expectedPq || pqCount > 100) {
    throw const PrekeyMaintenanceFormatException();
  }
  final pq = <PrekeyUploadEntry>[];
  for (var index = 0; index < pqCount; index += 1) {
    pq.add(
      PrekeyUploadEntry.postQuantum(
        keyId: reader.u32(),
        publicKey: reader.take(1184),
      ),
    );
  }
  if (!reader.finished) {
    throw const PrekeyMaintenanceFormatException();
  }
  return PrekeyUploadProjection(
    classicalOneTimePrekeys: classical,
    pqOneTimePrekeys: pq,
  );
}

PrekeyUploadProjection _parseRotationProjection(
  Uint8List bytes,
  Uint8List expectedBatchId,
  int expectedBundleVersion,
) {
  final reader = _Reader(bytes);
  if (!_same(reader.take(8), ascii.encode('CPKUV001')) ||
      !_same(reader.take(16), expectedBatchId) ||
      reader.u8() != 2 ||
      reader.u32() != expectedBundleVersion) {
    throw const PrekeyMaintenanceFormatException();
  }
  final classical = SignedPrekeyUpload.classical(
    keyId: reader.u32(),
    publicKey: reader.take(32),
    signature: reader.take(64),
  );
  final pq = SignedPrekeyUpload.postQuantum(
    keyId: reader.u32(),
    publicKey: reader.take(1184),
    signature: reader.take(64),
  );
  final crossSignature = reader.take(64);
  if (!reader.finished) {
    throw const PrekeyMaintenanceFormatException();
  }
  return PrekeyUploadProjection(
    classicalOneTimePrekeys: const [],
    pqOneTimePrekeys: const [],
    rotation: SignedPrekeyRotationUpload(
      classical: classical,
      postQuantum: pq,
      crossSignature: crossSignature,
      bundleVersion: expectedBundleVersion,
    ),
  );
}

Result<T> _integrityFailure<T>() => const Result.failure(
  SecurityFailure(SecurityFailureKind.integrityCheckFailed),
);

final class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void bytes(List<int> value) => _builder.add(value);

  void boolean(bool value) => _builder.addByte(value ? 1 : 0);

  void u16(int value) {
    if (value < 0 || value > 0xffff) {
      throw const PrekeyMaintenanceFormatException();
    }
    final encoded = Uint8List(2);
    ByteData.sublistView(encoded).setUint16(0, value);
    bytes(encoded);
  }

  void u32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw const PrekeyMaintenanceFormatException();
    }
    final encoded = Uint8List(4);
    ByteData.sublistView(encoded).setUint32(0, value);
    bytes(encoded);
  }

  void frame(Uint8List value) {
    if (value.length > 2 * 1024 * 1024) {
      throw const PrekeyMaintenanceFormatException();
    }
    u32(value.length);
    bytes(value);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

final class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;

  bool get finished => _offset == _bytes.length;

  int u8() => take(1).first;

  int u16() => ByteData.sublistView(take(2)).getUint16(0);

  int u32() => ByteData.sublistView(take(4)).getUint32(0);

  Uint8List frame() {
    final length = u32();
    if (length > 2 * 1024 * 1024) {
      throw const PrekeyMaintenanceFormatException();
    }
    return take(length);
  }

  Uint8List take(int length) {
    final end = _offset + length;
    if (length < 0 || end < _offset || end > _bytes.length) {
      throw const PrekeyMaintenanceFormatException();
    }
    final value = Uint8List.fromList(_bytes.sublist(_offset, end));
    _offset = end;
    return value;
  }
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
