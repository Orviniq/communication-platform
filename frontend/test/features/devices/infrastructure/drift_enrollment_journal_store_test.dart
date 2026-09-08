import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/infrastructure/secure_session_token_adapter.dart';
import 'package:communication_platform/features/contacts/infrastructure/drift_contact_repository.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:communication_platform/features/devices/infrastructure/drift_enrollment_journal_store.dart';
import 'package:communication_platform/features/local_storage/application/ports/local_storage_ports.dart';
import 'package:communication_platform/features/local_storage/domain/local_storage_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/local_storage_runtime.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File databaseFile;
  late _ProtectedStorage protectedStorage;
  late _Cleanup cleanup;
  late SecureLocalStorageRuntime runtime;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('enrollment-journal-');
    databaseFile = File('${directory.path}/android-state.sqlite');
    protectedStorage = _ProtectedStorage();
    cleanup = _Cleanup();
    runtime = _runtime(databaseFile, protectedStorage, cleanup);
  });

  tearDown(() async {
    await runtime.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  test(
    'process death converts an in-flight POST into explicit reconciliation',
    () async {
      final store = _store(runtime);
      final ready = _journal(EnrollmentPhase.registrationReady);
      await store.persistPrepared(ready);
      await store.update(
        ready.copyWith(phase: EnrollmentPhase.registrationInFlight),
      );
      await runtime.close();

      runtime = _runtime(databaseFile, protectedStorage, cleanup);
      final restored = await _store(runtime).read(userId: userId);
      final journal = (restored as Success<EnrollmentJournal?>).value!;

      expect(journal.phase, EnrollmentPhase.registrationOutcomeUnknown);
      expect(journal.message, EnrollmentMessage.ambiguousRegistration);
      expect(journal.deviceId, isNull);
      expect(journal.devicePackage.public.fingerprint, everyElement(6));
    },
  );

  test(
    'device ID, refresh tokens, and unsigned journal commit together and survive restart',
    () async {
      final tokens = SecureSessionTokenAdapter(runtime);
      final store = DriftEnrollmentJournalStore(
        runtime: runtime,
        tokens: tokens,
      );
      await tokens.replace(
        SessionTokens(
          accessToken: AccessToken(
            value: 'register-access',
            expiresAt: DateTime.utc(2030),
            scope: SessionScope.register,
          ),
          userId: userId,
          username: 'alice',
        ),
      );
      final ready = _journal(EnrollmentPhase.registrationInFlight);
      await store.persistPrepared(ready);

      final persisted = await store.persistRegistrationResult(
        journal: ready,
        response: DeviceRegistrationResponse(
          deviceId: deviceId,
          userId: userId,
          accessToken: 'durable-session-token',
          accessExpiresAt: DateTime.utc(2030),
        ),
      );
      expect(persisted, isA<Success<void>>());
      await runtime.close();

      runtime = _runtime(databaseFile, protectedStorage, cleanup);
      final restartedTokens = SecureSessionTokenAdapter(runtime);
      final restartedStore = DriftEnrollmentJournalStore(
        runtime: runtime,
        tokens: restartedTokens,
      );
      final session = await restartedTokens.read();
      final restored = await restartedStore.read(userId: userId);

      expect(session?.accessToken.value, 'durable-session-token');
      expect(session?.accessToken.expiresAt, DateTime.utc(2030));
      expect(session?.deviceId, deviceId);
      expect(
        (restored as Success<EnrollmentJournal?>).value?.phase,
        EnrollmentPhase.registeredUnsigned,
      );
      expect(await restartedTokens.hasCompletedSecureSetup(), isFalse);
    },
  );

  test(
    'completion moves opaque keys to secure storage and removes resumable display state',
    () async {
      final tokens = SecureSessionTokenAdapter(runtime);
      final store = DriftEnrollmentJournalStore(
        runtime: runtime,
        tokens: tokens,
      );
      final complete = _journal(
        EnrollmentPhase.complete,
        deviceId: deviceId,
        identity: IdentityKeyPackage.fromNative(_identityBytes()),
      );
      await store.persistPrepared(complete);

      final result = await store.update(complete);
      expect(result, isA<Success<void>>());
      final database = runtime.openedDatabase!;
      expect(await database.select(database.enrollmentIntents).get(), isEmpty);
      expect(await database.select(database.secureSecrets).get(), hasLength(2));
      final identity = await store.readCompletedIdentity();
      expect(
        (identity as Success<IdentityKeyPackage?>).value?.recoverySecret,
        isNull,
      );
    },
  );

  test(
    'the device bundle enrolment writes is one the reader accepts',
    () async {
      final store = _store(runtime);
      final complete = _journal(
        EnrollmentPhase.complete,
        deviceId: deviceId,
        identity: IdentityKeyPackage.fromNative(_identityBytes()),
      );
      await store.persistPrepared(complete);
      expect(await store.update(complete), isA<Success<void>>());

      // `devices.public_bundle` is written here and read only by
      // DriftContactRepository, which every send reaches when it resolves the
      // local account's own devices. Enrolment wrote the wire field names, so
      // this read threw and no message could leave the device - a break neither
      // component's own tests could see, because each one used its own fake.
      final devices = await DriftContactRepository(
        runtime.openedDatabase!,
      ).readDevices(userId);

      final stored = (devices as Success<List<PeerPublicDevice>>).value;
      expect(stored, hasLength(1));
      expect(stored.single.deviceId, deviceId);
      expect(stored.single.identityPublic, hasLength(64));
    },
  );
}

const userId = '6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10';
const deviceId = '9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611';

SecureLocalStorageRuntime _runtime(
  File file,
  _ProtectedStorage protectedStorage,
  _Cleanup cleanup,
) => SecureLocalStorageRuntime(
  protectedStorage: protectedStorage,
  cleanup: cleanup,
  executorFactory: (_) => NativeDatabase(file),
);

DriftEnrollmentJournalStore _store(SecureLocalStorageRuntime runtime) =>
    DriftEnrollmentJournalStore(
      runtime: runtime,
      tokens: SecureSessionTokenAdapter(runtime),
    );

EnrollmentJournal _journal(
  EnrollmentPhase phase, {
  String? deviceId,
  IdentityKeyPackage? identity,
}) {
  final device = DeviceKeyPackage.fromNative(_deviceBytes());
  return EnrollmentJournal(
    userId: userId,
    flow: EnrollmentFlow.firstDevice,
    phase: phase,
    fingerprint: device.public.fingerprint,
    devicePackage: device,
    deviceId: deviceId,
    identityPackage: identity,
  );
}

final class _ProtectedStorage implements PlatformProtectedStoragePort {
  @override
  Future<void> destroyWrappingKey() async {}

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<PlatformStorageUnlock> loadOrCreateStorageKey() async =>
      PlatformStorageUnlock(
        status: PlatformStorageKeyStatus.ready,
        protection: PlatformStorageProtection.tee,
        databaseKey: Uint8List(32),
      );
}

final class _Cleanup implements LocalArtifactCleanupPort {
  @override
  Future<CleanupReport> cleanupBounded({required int maximumEntries}) async =>
      const CleanupReport(removedEntries: 0, hasMore: false);

  @override
  Future<void> clearVolatilePlaintext() async {}

  @override
  Future<void> erasePersistentArtifacts() async {}
}

Uint8List _deviceBytes() {
  final bytes = BytesBuilder()
    ..add('CPDVV001'.codeUnits)
    ..add(_uuidBytes(userId));
  _u32(bytes, 1);
  _u32(bytes, 1);
  _u32(bytes, 1);
  _u16(bytes, 1);
  _u16(bytes, 1);
  bytes
    ..add(Uint8List.fromList(List<int>.filled(64, 1)))
    ..add(Uint8List.fromList(List<int>.filled(32, 2)))
    ..add(Uint8List.fromList(List<int>.filled(64, 3)))
    ..add(Uint8List.fromList(List<int>.filled(1184, 4)))
    ..add(Uint8List.fromList(List<int>.filled(64, 5)))
    ..add(Uint8List.fromList(List<int>.filled(32, 6)));
  _u32(bytes, 1);
  bytes.add(Uint8List.fromList(List<int>.filled(32, 7)));
  _u32(bytes, 1);
  bytes
    ..add(Uint8List.fromList(List<int>.filled(1184, 8)))
    ..addByte(9);
  return bytes.takeBytes();
}

Uint8List _identityBytes() {
  final bytes = BytesBuilder()
    ..add('CPIDV001'.codeUnits)
    ..addByte(0)
    ..add(_uuidBytes(userId))
    ..add(Uint8List.fromList(List<int>.filled(32, 11)))
    ..add(Uint8List.fromList(List<int>.filled(32, 12)))
    ..add(Uint8List.fromList(List<int>.filled(32, 13)))
    ..add(Uint8List.fromList(List<int>.filled(64, 14)));
  _u16(bytes, 0);
  _u32(bytes, 0);
  bytes.add(Uint8List(96));
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
  bytes.add((ByteData(2)..setUint16(0, value)).buffer.asUint8List());
}

void _u32(BytesBuilder bytes, int value) {
  bytes.add((ByteData(4)..setUint32(0, value)).buffer.asUint8List());
}
