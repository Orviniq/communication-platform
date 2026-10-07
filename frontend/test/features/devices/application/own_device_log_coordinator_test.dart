import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/own_device_log_coordinator.dart';
import 'package:communication_platform/features/devices/application/ports/device_enrollment_ports.dart';
import 'package:communication_platform/features/devices/application/ports/linked_device_ports.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/own_live_set_fakes.dart';

void main() {
  final current = signedDevice(currentDeviceId, key: 1);
  final other = signedDevice(otherDeviceId, key: 2);

  // Removing [other], the one own device-set mutation this client makes.
  Future<Result<void>> remove(
    _Local local,
    _Repository repository,
    HeadLiveSetCrypto crypto,
  ) =>
      OwnDeviceLogCoordinator(
        repository: repository,
        local: local,
        crypto: _EnrollmentCrypto(),
        identityCrypto: crypto,
        userId: ownUserId,
      ).appendLiveSetMutation(
        kind: DeviceLogMutationKind.remove,
        targetDeviceId: otherDeviceId,
        liveDevices: const [],
        identityVersion: 1,
      );

  void expectRefusedUntouched(
    Result<void> result,
    _Local local,
    _Repository repository,
    Failure failure,
  ) {
    expect(
      result,
      isA<FailureResult<void>>().having(
        (value) => value.failure,
        'failure',
        failure,
      ),
    );
    expect(local.securityState, GlobalSecurityState.normal);
    expect(local.evidence, isNull);
    expect(local.pending, isNull);
    expect(repository.appended, isEmpty);
  }

  test('the set the head covers lets the removal append', () async {
    final local = _Local();
    final repository = _Repository(listed: [current, other]);

    final result = await remove(
      local,
      repository,
      HeadLiveSetCrypto([current, other]),
    );

    expect(result, isA<Success<void>>());
    expect(repository.appended, hasLength(1));
    expect(local.pending?.state, DeviceLogMutationState.logConfirmed);
    expect(local.securityState, GlobalSecurityState.pendingDeviceChange);
  });

  test('another own device, unsigned and not logged, refuses the removal '
      'without latching a fork', () async {
    final local = _Local();
    final repository = _Repository(
      listed: [current, other, unsignedDevice(newcomerId, key: 3)],
    );

    final result = await remove(
      local,
      repository,
      HeadLiveSetCrypto([current, other]),
    );

    expectRefusedUntouched(
      result,
      local,
      repository,
      const SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  });

  test('another own device, signed but not logged, refuses the removal '
      'without latching a fork', () async {
    final local = _Local();
    final repository = _Repository(
      listed: [current, other, signedDevice(newcomerId, key: 3)],
    );

    final result = await remove(
      local,
      repository,
      HeadLiveSetCrypto([current, other]),
    );

    expectRefusedUntouched(
      result,
      local,
      repository,
      const SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  });

  test(
    'a list read past the verified head is a conflict, not a fork',
    () async {
      final local = _Local();
      final repository = _Repository(listed: [current, other], listedHead: 1);

      final result = await remove(
        local,
        repository,
        HeadLiveSetCrypto([current, other]),
      );

      expectRefusedUntouched(
        result,
        local,
        repository,
        const ValidationFailure(ValidationFailureKind.conflict),
      );
    },
  );

  test('a changed identity key still latches the fork', () async {
    final local = _Local();
    final repository = _Repository(
      listed: [current, signedDevice(otherDeviceId, key: 9)],
    );

    final result = await remove(
      local,
      repository,
      HeadLiveSetCrypto([current, other]),
    );

    expect(result, isA<FailureResult<void>>());
    expect(local.securityState, GlobalSecurityState.deviceLogFork);
    expect(local.evidence, DeviceLogEvidenceKind.liveSetMismatch);
    expect(local.pending, isNull);
    expect(repository.appended, isEmpty);
  });

  test('a logged device gone with no record still latches the fork', () async {
    final local = _Local();
    final repository = _Repository(
      listed: [current, unsignedDevice(newcomerId, key: 3)],
    );

    final result = await remove(
      local,
      repository,
      HeadLiveSetCrypto([current, other]),
    );

    expect(result, isA<FailureResult<void>>());
    expect(local.securityState, GlobalSecurityState.deviceLogFork);
    expect(local.evidence, DeviceLogEvidenceKind.liveSetMismatch);
    expect(repository.appended, isEmpty);
  });
}

final class _Local implements LinkedDeviceLocalPort {
  final identity = ownIdentityPackage();
  PendingDeviceLogMutation? pending;
  GlobalSecurityState securityState = GlobalSecurityState.normal;
  DeviceLogEvidenceKind? evidence;

  @override
  Future<Result<PendingDeviceLogMutation?>> readPendingMutation() async =>
      Result.success(pending);

  @override
  Future<Result<void>> writePendingMutation(
    PendingDeviceLogMutation mutation,
  ) async {
    pending = mutation;
    return const Result.success(null);
  }

  @override
  Future<Result<(String, String, IdentityKeyPackage)>>
  readLocalIdentity() async =>
      Result.success((ownUserId, currentDeviceId, identity));

  @override
  Future<Result<GlobalSecurityState>> readGlobalSecurityState() async =>
      Result.success(securityState);

  @override
  Future<Result<void>> setGlobalSecurityState(
    GlobalSecurityState state, {
    DeviceLogEvidenceKind? evidence,
  }) async {
    securityState = state;
    this.evidence = evidence;
    return const Result.success(null);
  }

  @override
  Future<Result<AuthenticatedDeviceLogRecord?>> readAuthenticatedLogHead(
    String userId,
  ) async => const Result.success(null);

  @override
  Future<Result<void>> appendAuthenticatedLogRecords({
    required String userId,
    required List<AuthenticatedDeviceLogRecord> records,
  }) async => const Result.success(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The server: one record at sequence 0, a listed set, and the head number the
/// list names beside it.
final class _Repository implements DeviceEnrollmentRepository {
  _Repository({required this.listed, this.listedHead = 0});

  final List<PublicDevice> listed;
  final int listedHead;
  final records = [Uint8List(256)];
  final appended = <Uint8List>[];

  @override
  Future<Result<PublicDeviceList>> fetchPublicDevices({
    required String userId,
  }) async => Result.success(
    PublicDeviceList(
      devices: listed,
      logHeadSequence: listedHead,
      etag: '"public-v1"',
    ),
  );

  @override
  Future<Result<DeviceLogPage>> fetchDeviceLog({
    required String userId,
    int? after,
  }) async => Result.success(
    DeviceLogPage(
      records: [
        for (var sequence = 0; sequence < records.length; sequence += 1)
          if (after == null || sequence > after)
            DeviceLogRecord(sequence: sequence, blob: records[sequence]),
      ],
      hasMore: false,
      headSequence: records.length - 1,
    ),
  );

  @override
  Future<Result<DeviceLogAppendResult>> appendDeviceLog({
    required Uint8List record,
  }) async {
    appended.add(record);
    records.add(record);
    return Result.success(
      DeviceLogAppendResult(
        firstSequence: records.length - 1,
        lastSequence: records.length - 1,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _EnrollmentCrypto implements EnrollmentCryptoPort {
  @override
  Future<Result<DeviceLogInspection>> inspectDeviceLogRecord({
    required IdentityKeyPackage identity,
    required Uint8List userId,
    required Uint8List record,
  }) async => Result.success(
    DeviceLogInspection(
      sequence: 0,
      previousHash: Uint8List(32),
      recordHash: Uint8List.fromList(List<int>.filled(32, 11)),
    ),
  );

  @override
  Future<Result<Uint8List>> createDeviceLogRecord({
    required IdentityKeyPackage identity,
    required Uint8List userId,
    required int sequence,
    required Uint8List previousHash,
    required Uint8List canonicalLiveSet,
    required int identityVersion,
    required int coarseUnixDay,
  }) async => Result.success(Uint8List(256)..fillRange(0, 256, 5));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
