import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/device_control_crypto_port.dart';
import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/linked_device_manager.dart';
import 'package:communication_platform/features/devices/application/ports/device_enrollment_ports.dart';
import 'package:communication_platform/features/devices/application/ports/linked_device_ports.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/own_live_set_fakes.dart';

const _userId = '10000000-0000-4000-8000-000000000001';
const _currentDeviceId = '10000000-0000-4000-8000-000000000002';
const _otherDeviceId = '10000000-0000-4000-8000-000000000003';

void main() {
  test(
    'process death after signed self-removal still wipes local state',
    () async {
      final local = _Local()
        ..pending = PendingDeviceLogMutation(
          operationId: 'remove-self',
          userId: _userId,
          kind: DeviceLogMutationKind.remove,
          targetDeviceId: _currentDeviceId,
          expectedSequence: 1,
          previousHeadHash: Uint8List(32),
          exactRecord: Uint8List(256),
          state: DeviceLogMutationState.logConfirmed,
        );
      final remote = _Remote(const OwnDevicesNotModified());
      final cleanup = _Cleanup();
      final manager = _manager(local: local, remote: remote, cleanup: cleanup);

      final result = await manager.refresh();

      expect(result, isA<Success<List<LinkedDevice>>>());
      expect(remote.revoked, [_currentDeviceId]);
      expect(local.pending, isNull);
      expect(local.securityState, GlobalSecurityState.normal);
      expect(cleanup.calls, 1);
    },
  );

  test(
    'remote self-revocation cleans up only after signed live-set proof',
    () async {
      final local = _Local();
      final remote = _Remote.failure();
      final cleanup = _Cleanup();
      final manager = _manager(
        local: local,
        remote: remote,
        cleanup: cleanup,
        enrollment: _Enrollment(),
        enrollmentCrypto: _EnrollmentCrypto(),
        identityCrypto: _IdentityCrypto(),
      );

      final result = await manager.refresh();

      expect(result, isA<FailureResult<List<LinkedDevice>>>());
      expect(
        (result as FailureResult<List<LinkedDevice>>).failure,
        isA<SecurityFailure>().having(
          (failure) => failure.kind,
          'kind',
          SecurityFailureKind.policyBlocked,
        ),
      );
      expect(cleanup.calls, 1);
    },
  );

  group('a Linked Devices refresh against the head record (ADR-084)', () {
    final current = signedDevice(_currentDeviceId, key: 1);
    final other = signedDevice(_otherDeviceId, key: 2);

    Future<(Result<List<LinkedDevice>>, _Local)> refresh({
      required List<PublicDevice> head,
      required List<PublicDevice> listed,
    }) async {
      final local = _Local();
      final manager = _manager(
        local: local,
        remote: _Remote(
          OwnDevicesUpdated(
            devices: [for (final device in listed) _row(device.deviceId)],
            etag: '"own-v2"',
            logHeadSequence: 0,
          ),
        ),
        cleanup: _Cleanup(),
        enrollment: _Enrollment(devices: listed),
        enrollmentCrypto: _EnrollmentCrypto(),
        identityCrypto: HeadLiveSetCrypto(head),
      );
      return (await manager.refresh(), local);
    }

    test('the set the head covers is stored', () async {
      final (result, local) = await refresh(
        head: [current, other],
        listed: [current, other],
      );

      expect(result, isA<Success<List<LinkedDevice>>>());
      expect(local.replaced?.map((row) => row.deviceId), [
        _currentDeviceId,
        _otherDeviceId,
      ]);
      expect(local.securityState, GlobalSecurityState.normal);
    });

    for (final (name, newcomer) in [
      ('unsigned and not logged', unsignedDevice(newcomerId, key: 3)),
      ('signed but not logged', signedDevice(newcomerId, key: 3)),
    ]) {
      test('another own device $name is pending, not a fork', () async {
        final (result, local) = await refresh(
          head: [current, other],
          listed: [current, other, newcomer],
        );

        expect(
          result,
          isA<FailureResult<List<LinkedDevice>>>().having(
            (value) => value.failure,
            'failure',
            const SecurityFailure(SecurityFailureKind.policyBlocked),
          ),
        );
        expect(local.securityState, GlobalSecurityState.normal);
        expect(local.evidence, isNull);
        expect(local.replaced, isNull);
      });
    }

    test('a changed identity key still latches the fork', () async {
      final (result, local) = await refresh(
        head: [current, other],
        listed: [current, signedDevice(_otherDeviceId, key: 9)],
      );

      expect(result, isA<FailureResult<List<LinkedDevice>>>());
      expect(local.securityState, GlobalSecurityState.deviceLogFork);
      expect(local.evidence, DeviceLogEvidenceKind.liveSetMismatch);
      expect(local.replaced, isNull);
    });
  });
}

LinkedDevice _row(String deviceId) => LinkedDevice(
  deviceId: deviceId,
  label: null,
  labelState: LinkedDeviceLabelState.notSet,
  createdDate: DateTime.utc(2026, 10, 7),
  thisDevice: deviceId == _currentDeviceId,
);

LinkedDeviceManager _manager({
  required _Local local,
  required _Remote remote,
  required _Cleanup cleanup,
  DeviceEnrollmentRepository? enrollment,
  EnrollmentCryptoPort? enrollmentCrypto,
  IdentityCryptoPort? identityCrypto,
}) => LinkedDeviceManager(
  remote: remote,
  local: local,
  enrollment: enrollment ?? _UnusedEnrollment(),
  controlCrypto: _UnusedControlCrypto(),
  enrollmentCrypto: enrollmentCrypto ?? _UnusedEnrollmentCrypto(),
  identityCrypto: identityCrypto ?? _UnusedIdentityCrypto(),
  cleanup: cleanup,
  userId: _userId,
);

final class _Remote implements LinkedDeviceRemotePort {
  _Remote(this.refresh) : failure = null;
  _Remote.failure()
    : refresh = null,
      failure = const TransportFailure(TransportFailureKind.offline);

  final OwnDeviceRefresh? refresh;
  final Failure? failure;
  final revoked = <String>[];

  @override
  Future<Result<OwnDeviceRefresh>> fetchOwnDevices({String? etag}) async =>
      failure == null ? Result.success(refresh!) : Result.failure(failure!);

  @override
  Future<Result<void>> revokeDevice({required String deviceId}) async {
    revoked.add(deviceId);
    return const Result.success(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Local implements LinkedDeviceLocalPort {
  _Local() : identity = IdentityKeyPackage.fromNative(_identityPackage());

  final IdentityKeyPackage identity;
  PendingDeviceLogMutation? pending;
  GlobalSecurityState securityState = GlobalSecurityState.normal;
  DeviceLogEvidenceKind? evidence;
  List<LinkedDevice>? replaced;

  @override
  Future<Result<PendingDeviceLogMutation?>> readPendingMutation() async =>
      Result.success(pending);

  @override
  Future<Result<(String, String, IdentityKeyPackage)>>
  readLocalIdentity() async =>
      Result.success((_userId, _currentDeviceId, identity));

  @override
  Future<Result<void>> clearPendingMutation(String operationId) async {
    pending = null;
    return const Result.success(null);
  }

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
  Future<Result<String?>> readOwnDevicesEtag(String userId) async =>
      const Result.success(null);

  @override
  Future<Result<void>> replaceOwnDevices({
    required String userId,
    required String etag,
    required List<LinkedDevice> devices,
  }) async {
    replaced = devices;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> markMissingHistorySources(
    Set<String> liveDeviceIds,
  ) async => const Result.success(null);

  @override
  Future<Result<List<LinkedDevice>>> readOwnDevices(String userId) async =>
      const Result.success([]);

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

final class _Cleanup implements SelfRevocationCleanupPort {
  var calls = 0;

  @override
  Future<void> cleanupAfterSelfRevocation() async {
    calls += 1;
  }
}

final class _Enrollment implements DeviceEnrollmentRepository {
  _Enrollment({List<PublicDevice>? devices})
    : devices =
          devices ??
          [
            PublicDevice(
              deviceId: _otherDeviceId,
              ikPub: Uint8List(64),
              registrationId: 7,
              crossSignature: Uint8List(64),
              bundleVersion: 1,
            ),
          ];

  final List<PublicDevice> devices;
  final record = Uint8List(256);

  @override
  Future<Result<PublicDeviceList>> fetchPublicDevices({
    required String userId,
  }) async => Result.success(
    PublicDeviceList(devices: devices, logHeadSequence: 0, etag: '"public-v1"'),
  );

  @override
  Future<Result<DeviceLogPage>> fetchDeviceLog({
    required String userId,
    int? after,
  }) async => Result.success(
    DeviceLogPage(
      records: [DeviceLogRecord(sequence: 0, blob: record)],
      hasMore: false,
      headSequence: 0,
    ),
  );

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _IdentityCrypto implements IdentityCryptoPort {
  @override
  Future<Result<PeerDeviceLogInspection>> inspectPeerDeviceLog({
    required Uint8List userId,
    required Uint8List selfSigningPublic,
    required List<PeerPublicDevice> liveDevices,
    required bool requireCurrentLiveSet,
    required Uint8List record,
  }) async => Result.success(
    PeerDeviceLogInspection(
      sequence: 0,
      previousHash: Uint8List(32),
      recordHash: Uint8List.fromList(List<int>.filled(32, 11)),
      liveDeviceSetHash: Uint8List(32),
      identityVersion: 1,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnusedEnrollment implements DeviceEnrollmentRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnusedEnrollmentCrypto implements EnrollmentCryptoPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnusedIdentityCrypto implements IdentityCryptoPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnusedControlCrypto implements DeviceControlCryptoPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _identityPackage() {
  final user = _uuidBytes(_userId);
  final bytes = BytesBuilder(copy: false)
    ..add('CPIDV001'.codeUnits)
    ..addByte(0)
    ..add(user)
    ..add(Uint8List(32))
    ..add(Uint8List(32))
    ..add(Uint8List(32))
    ..add(Uint8List(64))
    ..add([0, 0])
    ..add([0, 0, 0, 0])
    ..add(Uint8List(96));
  return bytes.toBytes();
}

Uint8List _uuidBytes(String value) {
  final compact = value.replaceAll('-', '');
  return Uint8List.fromList([
    for (var index = 0; index < compact.length; index += 2)
      int.parse(compact.substring(index, index + 2), radix: 16),
  ]);
}
