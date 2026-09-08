import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/device_enrollment_coordinator.dart';
import 'package:communication_platform/features/devices/application/ports/device_enrollment_ports.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('device enrollment coordinator', () {
    test(
      'first device completes all phases and withholds until notice',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: true);

        final started = await fixture.coordinator.loadOrStart(userId: userId);
        expect(
          (started as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.recoverySecret,
        );
        expect(started.value.isMessagingWithheld, isTrue);

        await fixture.coordinator.markRecoverySecretDisplayed(userId: userId);
        final confirmed = await fixture.coordinator.confirmRecoverySecret(
          userId: userId,
        );
        expect(
          (confirmed as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.securityNotice,
        );
        expect(
          fixture.repository.calls,
          containsAll(<String>[
            'register',
            'identity',
            'prekeys',
            'backup',
            'log',
          ]),
        );
        expect(fixture.repository.registrationBodyHadCrossSignature, isFalse);

        final complete = await fixture.coordinator.acceptSecurityNotice(
          userId: userId,
        );
        expect(
          (complete as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.complete,
        );
        expect(complete.value.isMessagingWithheld, isFalse);
      },
    );

    test(
      'later device restores identity, never persists the entered secret, and completes',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: false);
        final started = await fixture.coordinator.loadOrStart(userId: userId);
        expect(
          (started as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.awaitingRecoverySecret,
        );

        final secret = Uint8List.fromList('secret'.codeUnits);
        final restored = await fixture.coordinator.restoreWithRecoverySecret(
          userId: userId,
          recoverySecret: secret,
        );
        expect(secret, everyElement(0));
        expect(
          (restored as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.securityNotice,
        );
        expect(fixture.store.lastJournal?.backup, isNull);
        expect(
          fixture.repository.calls,
          containsAll(<String>[
            'register',
            'backup-fetch',
            'identity-fetch',
            'prekeys',
            'log',
          ]),
        );
      },
    );

    test(
      'wrong recovery secret is generic, resumable, and cleaned immediately',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: false)
          ..crypto.restoreFailure = const CryptoCoreFailure(
            CryptoCoreFailureCode.authenticationFailed,
          );
        await fixture.coordinator.loadOrStart(userId: userId);

        final secret = Uint8List.fromList('wrong secret'.codeUnits);
        final result = await fixture.coordinator.restoreWithRecoverySecret(
          userId: userId,
          recoverySecret: secret,
        );

        expect(secret, everyElement(0));
        final journal = (result as Success<EnrollmentJournal>).value;
        expect(journal.phase, EnrollmentPhase.awaitingRecoverySecret);
        expect(journal.message, EnrollmentMessage.wrongRecoverySecret);
        expect(result.toString(), isNot(contains('wrong secret')));
      },
    );

    test(
      'transport loss is ambiguous and never blindly retries registration',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: true)
          ..repository.registerFailure = const TransportFailure(
            TransportFailureKind.timeout,
          )
          ..repository.registerCreatesOrphan = true;

        final result = await fixture.coordinator.loadOrStart(userId: userId);
        expect(
          (result as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.registrationOutcomeUnknown,
        );
        expect(fixture.repository.registerCount, 1);

        final retry = await fixture.coordinator.retry(userId: userId);
        expect(
          (retry as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.registrationOutcomeUnknown,
        );
        expect(fixture.repository.registerCount, 1);
      },
    );

    test(
      'ambiguous orphan is reconciled and adopted when the full session owns it',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: true)
          ..repository.registerFailure = const TransportFailure(
            TransportFailureKind.timeout,
          )
          ..repository.registerCreatesOrphan = true
          ..store.sessionDeviceId = deviceId;
        await fixture.coordinator.loadOrStart(userId: userId);

        final result = await fixture.coordinator.reconcileAmbiguousRegistration(
          userId: userId,
        );

        expect(
          (result as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.recoverySecret,
        );
        expect(fixture.repository.registerCount, 1);
        expect(fixture.repository.revokeCount, 0);
      },
    );

    test(
      'ambiguous unsigned orphan is revoked before a controlled new registration',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: true)
          ..repository.registerFailure = const TransportFailure(
            TransportFailureKind.timeout,
          )
          ..repository.registerCreatesOrphan = true
          ..store.sessionDeviceId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
        await fixture.coordinator.loadOrStart(userId: userId);
        fixture.repository.registerFailure = null;

        final result = await fixture.coordinator.reconcileAmbiguousRegistration(
          userId: userId,
        );

        expect(
          (result as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.recoverySecret,
        );
        expect(fixture.repository.revokeCount, 1);
        expect(fixture.repository.registerCount, 2);
      },
    );

    test(
      'identity_required and device cap block with reviewed messages',
      () async {
        final identityRequired = _EnrollmentFixture(firstDevice: true)
          ..repository.registerFailure = const BackendFailure(
            BackendFailureCode.identityRequired,
          );
        final first = await identityRequired.coordinator.loadOrStart(
          userId: userId,
        );
        expect(
          (first as Success<EnrollmentJournal>).value.message,
          EnrollmentMessage.identityRequired,
        );
        expect(first.value.phase, EnrollmentPhase.blocked);

        final cap = _EnrollmentFixture(firstDevice: true)
          ..repository.registerFailure = const BackendFailure(
            BackendFailureCode.deviceLimit,
          );
        final capped = await cap.coordinator.loadOrStart(userId: userId);
        expect(
          (capped as Success<EnrollmentJournal>).value.message,
          EnrollmentMessage.deviceLimit,
        );
        expect(capped.value.phase, EnrollmentPhase.registrationReady);
      },
    );

    test(
      'stale backup is accepted only when the exact blob and version match',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: true)
          ..repository.staleBackupOnce = true;
        await fixture.coordinator.loadOrStart(userId: userId);
        await fixture.coordinator.markRecoverySecretDisplayed(userId: userId);

        final result = await fixture.coordinator.confirmRecoverySecret(
          userId: userId,
        );
        expect(
          (result as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.securityNotice,
        );
        expect(fixture.repository.backupUploadCount, 1);
      },
    );

    test('stale backup mismatch blocks instead of assuming success', () async {
      final fixture = _EnrollmentFixture(firstDevice: true)
        ..repository.staleBackupOnce = true
        ..repository.staleBackupMismatch = true;
      await fixture.coordinator.loadOrStart(userId: userId);
      await fixture.coordinator.markRecoverySecretDisplayed(userId: userId);

      final result = await fixture.coordinator.confirmRecoverySecret(
        userId: userId,
      );

      expect(
        (result as Success<EnrollmentJournal>).value.phase,
        EnrollmentPhase.blocked,
      );
      expect(result.value.message, EnrollmentMessage.staleVersion);
    });

    test(
      'stale identity is accepted only after exact public reconciliation',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: true)
          ..repository.staleIdentityOnce = true;

        final result = await fixture.coordinator.loadOrStart(userId: userId);

        expect(
          (result as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.recoverySecret,
        );
        expect(fixture.repository.calls, contains('identity-fetch'));
      },
    );

    test('stale identity mismatch blocks without signing the device', () async {
      final fixture = _EnrollmentFixture(firstDevice: true)
        ..repository.staleIdentityOnce = true
        ..repository.staleIdentityMismatch = true;

      final result = await fixture.coordinator.loadOrStart(userId: userId);

      expect(
        (result as Success<EnrollmentJournal>).value.phase,
        EnrollmentPhase.blocked,
      );
      expect(fixture.repository.calls, isNot(contains('prekeys')));
    });

    test('prekey retry resumes without another registration', () async {
      final fixture = _EnrollmentFixture(firstDevice: true)
        ..repository.prekeyFailureOnce = true;
      await fixture.coordinator.loadOrStart(userId: userId);
      await fixture.coordinator.markRecoverySecretDisplayed(userId: userId);
      final paused = await fixture.coordinator.confirmRecoverySecret(
        userId: userId,
      );
      expect(
        (paused as Success<EnrollmentJournal>).value.phase,
        EnrollmentPhase.finishingSecureSetup,
      );

      final resumed = await fixture.coordinator.retry(userId: userId);
      expect(
        (resumed as Success<EnrollmentJournal>).value.phase,
        EnrollmentPhase.securityNotice,
      );
      expect(fixture.repository.registerCount, 1);
    });

    test(
      'device-log response loss reconciles the exact persisted record',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: true)
          ..repository.logResponseLossOnce = true;
        await fixture.coordinator.loadOrStart(userId: userId);
        await fixture.coordinator.markRecoverySecretDisplayed(userId: userId);
        final paused = await fixture.coordinator.confirmRecoverySecret(
          userId: userId,
        );
        expect(
          (paused as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.appendingDeviceLog,
        );
        expect(fixture.repository.logs, hasLength(1));

        final reconciled = await fixture.coordinator.retry(userId: userId);
        expect(
          (reconciled as Success<EnrollmentJournal>).value.phase,
          EnrollmentPhase.securityNotice,
        );
        expect(fixture.repository.logs, hasLength(1));
      },
    );

    test(
      'missing backup blocks a later device without requesting a secret',
      () async {
        final fixture = _EnrollmentFixture(firstDevice: false)
          ..repository.backupMissing = true;
        final result = await fixture.coordinator.loadOrStart(userId: userId);

        final journal = (result as Success<EnrollmentJournal>).value;
        expect(journal.phase, EnrollmentPhase.blocked);
        expect(journal.message, EnrollmentMessage.backupMissing);
      },
    );

    test('process death while unwrapping returns to recovery input', () async {
      final fixture = _EnrollmentFixture(firstDevice: false);
      final started = await fixture.coordinator.loadOrStart(userId: userId);
      fixture.store.lastJournal = (started as Success<EnrollmentJournal>).value
          .copyWith(phase: EnrollmentPhase.restoringIdentity);

      final restored = await fixture.coordinator.loadOrStart(userId: userId);
      expect(
        (restored as Success<EnrollmentJournal>).value.phase,
        EnrollmentPhase.awaitingRecoverySecret,
      );
    });

    test('invalid live-set vectors block before a device-log append', () async {
      final fixture = _EnrollmentFixture(firstDevice: true)
        ..repository.injectInvalidDevice = true;
      await fixture.coordinator.loadOrStart(userId: userId);
      await fixture.coordinator.markRecoverySecretDisplayed(userId: userId);

      final result = await fixture.coordinator.confirmRecoverySecret(
        userId: userId,
      );
      final journal = (result as Success<EnrollmentJournal>).value;
      expect(journal.phase, EnrollmentPhase.appendingDeviceLog);
      expect(journal.message, EnrollmentMessage.invalidVector);
      expect(fixture.repository.calls, isNot(contains('log')));
    });
  });
}

const userId = '6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10';
const deviceId = '9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611';

final class _EnrollmentFixture {
  _EnrollmentFixture({required bool firstDevice})
    : store = _MemoryEnrollmentStore(firstDevice: firstDevice),
      repository = _MemoryEnrollmentRepository(),
      crypto = _FakeEnrollmentCrypto() {
    if (!firstDevice) {
      repository.identity = PublishedIdentity(
        masterPub: crypto.cleanIdentity.masterPub,
        selfSigningPub: crypto.cleanIdentity.selfSigningPub,
        userSigningPub: crypto.cleanIdentity.userSigningPub,
        masterSig: crypto.cleanIdentity.masterSig,
        version: 1,
      );
    }
    coordinator = DeviceEnrollmentCoordinator(
      repository: repository,
      store: store,
      crypto: crypto,
      clock: const _FixedClock(),
    );
  }

  final _MemoryEnrollmentStore store;
  final _MemoryEnrollmentRepository repository;
  final _FakeEnrollmentCrypto crypto;
  late DeviceEnrollmentCoordinator coordinator;
}

final class _FixedClock implements TimeSource {
  const _FixedClock();

  @override
  DateTime now() => DateTime.utc(2026, 1, 2);
}

final class _FakeEnrollmentCrypto implements EnrollmentCryptoPort {
  _FakeEnrollmentCrypto()
    : device = DeviceKeyPackage.fromNative(_deviceBytes()),
      displayIdentity = IdentityKeyPackage.fromNative(
        _identityBytes(display: true),
      ),
      cleanIdentity = IdentityKeyPackage.fromNative(
        _identityBytes(display: false),
      );

  final DeviceKeyPackage device;
  final IdentityKeyPackage displayIdentity;
  final IdentityKeyPackage cleanIdentity;
  Failure? restoreFailure;

  @override
  Future<Result<DeviceKeyPackage>> prepareDevice({required Uint8List userId}) =>
      Future.value(Result.success(device));

  @override
  Future<Result<IdentityKeyPackage>> rotateRecoverySecret({
    required IdentityKeyPackage package,
  }) => Future.value(Result.success(displayIdentity));

  @override
  Future<Result<IdentityKeyPackage>> prepareFirstIdentity({
    required Uint8List userId,
  }) => Future.value(Result.success(displayIdentity));

  @override
  Future<Result<IdentityKeyPackage>> restoreIdentity({
    required Uint8List userId,
    required Uint8List recoverySecret,
    required Uint8List backup,
  }) => Future.value(
    restoreFailure == null
        ? Result.success(cleanIdentity)
        : Result.failure(restoreFailure!),
  );

  @override
  Future<Result<IdentityKeyPackage>> sanitizeIdentity({
    required IdentityKeyPackage package,
  }) => Future.value(Result.success(cleanIdentity));

  @override
  Future<Result<Uint8List>> crossSignDevice({
    required DeviceKeyPackage device,
    required IdentityKeyPackage identity,
    required Uint8List deviceId,
    required int bundleVersion,
  }) => Future.value(Result.success(Uint8List(64)));

  @override
  Future<Result<Uint8List>> createDeviceLogRecord({
    required IdentityKeyPackage identity,
    required Uint8List userId,
    required int sequence,
    required Uint8List previousHash,
    required Uint8List canonicalLiveSet,
    required int identityVersion,
    required int coarseUnixDay,
  }) {
    final record = Uint8List(256);
    ByteData.sublistView(record)
      ..setUint64(8, sequence)
      ..setUint32(16, identityVersion);
    record.setRange(
      24,
      56,
      previousHash.length == 32 ? previousHash : Uint8List(32),
    );
    record.fillRange(56, 88, 7);
    return Future.value(Result.success(record));
  }

  @override
  Future<Result<DeviceLogInspection>> inspectDeviceLogRecord({
    required IdentityKeyPackage identity,
    required Uint8List userId,
    required Uint8List record,
  }) {
    final data = ByteData.sublistView(record);
    return Future.value(
      Result.success(
        DeviceLogInspection(
          sequence: data.getUint64(8),
          previousHash: record.sublist(24, 56),
          recordHash: record.sublist(56, 88),
        ),
      ),
    );
  }
}

final class _MemoryEnrollmentStore implements EnrollmentJournalStore {
  _MemoryEnrollmentStore({required bool firstDevice})
    : _newAccount = firstDevice;

  final bool _newAccount;
  EnrollmentJournal? lastJournal;
  String? sessionDeviceId;

  @override
  Future<Result<EnrollmentJournal?>> read({required String userId}) =>
      Future.value(Result.success(lastJournal));

  @override
  Future<Result<void>> persistPrepared(EnrollmentJournal journal) {
    lastJournal = journal;
    return Future.value(const Result.success(null));
  }

  @override
  Future<Result<void>> persistRegistrationResult({
    required EnrollmentJournal journal,
    required DeviceRegistrationResponse response,
  }) {
    sessionDeviceId = response.deviceId;
    lastJournal = journal.copyWith(deviceId: response.deviceId);
    return Future.value(const Result.success(null));
  }

  @override
  Future<Result<void>> update(EnrollmentJournal journal) {
    lastJournal = journal;
    return Future.value(const Result.success(null));
  }

  @override
  Future<Result<void>> clear({required String userId}) {
    lastJournal = null;
    return Future.value(const Result.success(null));
  }

  @override
  Future<Result<void>> markNewAccount({required String userId}) =>
      Future.value(const Result.success(null));

  @override
  Future<Result<bool>> isNewAccount({required String userId}) =>
      Future.value(Result.success(_newAccount));

  @override
  Future<Result<String?>> currentFullSessionDeviceId() =>
      Future.value(Result.success(sessionDeviceId));

  @override
  Future<Result<IdentityKeyPackage?>> readCompletedIdentity() =>
      Future.value(const Result.success(null));
}

final class _MemoryEnrollmentRepository implements DeviceEnrollmentRepository {
  final calls = <String>[];
  final devices = <PublicDevice>[];
  final logs = <DeviceLogRecord>[];
  PublishedIdentity? identity;
  Failure? registerFailure;
  bool registerCreatesOrphan = false;
  bool staleBackupOnce = false;
  bool staleBackupMismatch = false;
  bool staleIdentityOnce = false;
  bool staleIdentityMismatch = false;
  bool prekeyFailureOnce = false;
  bool logResponseLossOnce = false;
  bool backupMissing = false;
  bool injectInvalidDevice = false;
  int registerCount = 0;
  int revokeCount = 0;
  int backupUploadCount = 0;
  bool registrationBodyHadCrossSignature = false;
  Uint8List? uploadedBackup;

  @override
  Future<Result<DeviceRegistrationResponse>> registerDevice({
    required String userId,
    required DeviceRegistrationPublic public,
  }) {
    calls.add('register');
    registerCount += 1;
    registrationBodyHadCrossSignature = false;
    if (registerFailure != null) {
      if (registerCreatesOrphan) {
        devices.add(_unsignedDevice(public));
      }
      return Future.value(Result.failure(registerFailure!));
    }
    devices.add(_unsignedDevice(public));
    return Future.value(
      Result.success(
        DeviceRegistrationResponse(
          deviceId: deviceId,
          userId: userId,
          accessToken: 'access',
          accessExpiresAt: nullDate,
        ),
      ),
    );
  }

  @override
  Future<Result<void>> publishIdentity({required PublishedIdentity identity}) {
    calls.add('identity');
    this.identity = identity;
    if (staleIdentityOnce) {
      staleIdentityOnce = false;
      if (staleIdentityMismatch) {
        this.identity = PublishedIdentity(
          masterPub: Uint8List(32),
          selfSigningPub: identity.selfSigningPub,
          userSigningPub: identity.userSigningPub,
          masterSig: identity.masterSig,
          version: identity.version,
        );
      }
      return Future.value(
        const Result.failure(BackendFailure(BackendFailureCode.staleVersion)),
      );
    }
    return Future.value(const Result.success(null));
  }

  @override
  Future<Result<PublishedIdentity>> fetchIdentity({required String userId}) {
    calls.add('identity-fetch');
    return Future.value(
      identity == null
          ? const Result.failure(BackendFailure(BackendFailureCode.notFound))
          : Result.success(identity!),
    );
  }

  @override
  Future<Result<void>> finishPrekeys({
    required String deviceId,
    required Uint8List crossSignature,
    required int bundleVersion,
  }) {
    calls.add('prekeys');
    if (prekeyFailureOnce) {
      prekeyFailureOnce = false;
      return Future.value(
        const Result.failure(TransportFailure(TransportFailureKind.offline)),
      );
    }
    final index = devices.indexWhere((device) => device.deviceId == deviceId);
    if (index >= 0) {
      final previous = devices[index];
      devices[index] = PublicDevice(
        deviceId: previous.deviceId,
        ikPub: previous.ikPub,
        registrationId: previous.registrationId,
        crossSignature: Uint8List.fromList(crossSignature),
        bundleVersion: bundleVersion,
      );
    }
    return Future.value(const Result.success(null));
  }

  @override
  Future<Result<KeyBackup>> fetchBackup() {
    calls.add('backup-fetch');
    if (backupMissing) {
      return Future.value(
        const Result.failure(BackendFailure(BackendFailureCode.notFound)),
      );
    }
    final blob = uploadedBackup ?? Uint8List(4096);
    return Future.value(Result.success(KeyBackup(blob: blob, version: 1)));
  }

  @override
  Future<Result<void>> uploadBackup({
    required Uint8List blob,
    required int version,
  }) {
    calls.add('backup');
    backupUploadCount += 1;
    if (staleBackupOnce) {
      staleBackupOnce = false;
      uploadedBackup = Uint8List.fromList(blob);
      if (staleBackupMismatch) {
        uploadedBackup![0] ^= 1;
      }
      return Future.value(
        const Result.failure(BackendFailure(BackendFailureCode.staleVersion)),
      );
    }
    uploadedBackup = Uint8List.fromList(blob);
    return Future.value(const Result.success(null));
  }

  @override
  Future<Result<PublicDeviceList>> fetchPublicDevices({
    required String userId,
  }) {
    final values = <PublicDevice>[...devices];
    if (injectInvalidDevice) {
      values.add(
        PublicDevice(
          deviceId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          ikPub: Uint8List(63),
          registrationId: 2,
          crossSignature: Uint8List(64),
          bundleVersion: 1,
        ),
      );
    }
    return Future.value(
      Result.success(
        PublicDeviceList(
          devices: values,
          logHeadSequence: logs.isEmpty ? null : logs.last.sequence,
          etag: 'fixture',
        ),
      ),
    );
  }

  @override
  Future<Result<DeviceLogPage>> fetchDeviceLog({
    required String userId,
    int? after,
  }) => Future.value(
    Result.success(
      DeviceLogPage(
        records: List.unmodifiable(logs),
        hasMore: false,
        headSequence: logs.isEmpty ? null : logs.last.sequence,
      ),
    ),
  );

  @override
  Future<Result<DeviceLogAppendResult>> appendDeviceLog({
    required Uint8List record,
  }) {
    calls.add('log');
    final sequence = logs.length;
    logs.add(DeviceLogRecord(sequence: sequence, blob: record));
    if (logResponseLossOnce) {
      logResponseLossOnce = false;
      return Future.value(
        const Result.failure(TransportFailure(TransportFailureKind.timeout)),
      );
    }
    return Future.value(
      Result.success(
        DeviceLogAppendResult(firstSequence: sequence, lastSequence: sequence),
      ),
    );
  }

  @override
  Future<Result<void>> revokeDevice({required String deviceId}) {
    revokeCount += 1;
    devices.removeWhere((device) => device.deviceId == deviceId);
    return Future.value(const Result.success(null));
  }

  PublicDevice _unsignedDevice(DeviceRegistrationPublic public) => PublicDevice(
    deviceId: deviceId,
    ikPub: public.ikPub,
    registrationId: public.registrationId,
    crossSignature: null,
    bundleVersion: null,
  );
}

final nullDate = DateTime.utc(2030);

Uint8List _deviceBytes() {
  final bytes = BytesBuilder();
  bytes.add('CPDVV001'.codeUnits);
  bytes.add(_uuidBytes(userId));
  _u32(bytes, 1);
  _u32(bytes, 1);
  _u32(bytes, 1);
  _u16(bytes, 1);
  _u16(bytes, 1);
  bytes.add(Uint8List.fromList(List<int>.filled(64, 1)));
  bytes.add(Uint8List.fromList(List<int>.filled(32, 2)));
  bytes.add(Uint8List.fromList(List<int>.filled(64, 3)));
  bytes.add(Uint8List.fromList(List<int>.filled(1184, 4)));
  bytes.add(Uint8List.fromList(List<int>.filled(64, 5)));
  bytes.add(Uint8List.fromList(List<int>.filled(32, 6)));
  _u32(bytes, 1);
  bytes.add(Uint8List.fromList(List<int>.filled(32, 7)));
  _u32(bytes, 1);
  bytes.add(Uint8List.fromList(List<int>.filled(1184, 8)));
  bytes.add(Uint8List.fromList(List<int>.filled(1, 9)));
  return bytes.takeBytes();
}

Uint8List _identityBytes({required bool display}) {
  final recovery = display
      ? Uint8List.fromList('RECOVERY'.codeUnits)
      : Uint8List(0);
  final backup = display ? Uint8List(4096) : Uint8List(0);
  final bytes = BytesBuilder();
  bytes.add('CPIDV001'.codeUnits);
  bytes.addByte(display ? 3 : 0);
  bytes.add(_uuidBytes(userId));
  bytes.add(Uint8List.fromList(List<int>.filled(32, 11)));
  bytes.add(Uint8List.fromList(List<int>.filled(32, 12)));
  bytes.add(Uint8List.fromList(List<int>.filled(32, 13)));
  bytes.add(Uint8List.fromList(List<int>.filled(64, 14)));
  _u16(bytes, recovery.length);
  _u32(bytes, backup.length);
  bytes.add(Uint8List(96));
  bytes.add(recovery);
  bytes.add(backup);
  return bytes.takeBytes();
}

Uint8List _uuidBytes(String value) {
  final compact = value.replaceAll('-', '');
  return Uint8List.fromList([
    for (var index = 0; index < compact.length; index += 2)
      int.parse(compact.substring(index, index + 2), radix: 16),
  ]);
}

void _u16(BytesBuilder bytes, int value) {
  final data = ByteData(2)..setUint16(0, value);
  bytes.add(data.buffer.asUint8List());
}

void _u32(BytesBuilder bytes, int value) {
  final data = ByteData(4)..setUint32(0, value);
  bytes.add(data.buffer.asUint8List());
}
