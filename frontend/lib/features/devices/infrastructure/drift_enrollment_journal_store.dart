import 'dart:convert';

import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/infrastructure/secure_session_token_adapter.dart';
import 'package:communication_platform/features/devices/application/ports/device_enrollment_ports.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/local_storage/infrastructure/local_storage_runtime.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:drift/drift.dart';

final class DriftEnrollmentJournalStore
    implements EnrollmentJournalStore, NewAccountEnrollmentMarkerPort {
  const DriftEnrollmentJournalStore({
    required this.runtime,
    required this.tokens,
  });

  static const _newAccountMarker = 'authentication.new_account.v1';
  static const _formatVersion = 1;
  static const _deviceSecretId = 'current-device-key-state-v1';
  static const _identitySecretId = 'account-cross-signing-state-v1';

  final SecureLocalStorageRuntime runtime;
  final SecureSessionTokenAdapter tokens;

  @override
  Future<Result<EnrollmentJournal?>> read({required String userId}) async {
    final database = await _database();
    if (database == null) {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    try {
      final row = await (database.select(
        database.enrollmentIntents,
      )..where((entry) => entry.userId.equals(userId))).getSingleOrNull();
      if (row == null) {
        return const Result.success(null);
      }
      final flow = _enumAt(EnrollmentFlow.values, row.flow);
      var phase = _enumAt(EnrollmentPhase.values, row.phase);
      var message = row.message == null
          ? null
          : _enumAt(EnrollmentMessage.values, row.message!);
      final devicePackage = DeviceKeyPackage.fromNative(row.deviceState);
      if (!_same(devicePackage.public.fingerprint, row.fingerprint)) {
        throw const EnrollmentCryptoFormatException();
      }
      final identityPackage = row.identityState == null
          ? null
          : IdentityKeyPackage.fromNative(row.identityState!);
      if (phase == EnrollmentPhase.registrationInFlight) {
        phase = EnrollmentPhase.registrationOutcomeUnknown;
        message = EnrollmentMessage.ambiguousRegistration;
        await (database.update(
          database.enrollmentIntents,
        )..where((entry) => entry.userId.equals(userId))).write(
          EnrollmentIntentsCompanion(
            phase: Value(phase.index),
            message: Value(EnrollmentMessage.ambiguousRegistration.index),
          ),
        );
      }
      return Result.success(
        EnrollmentJournal(
          userId: row.userId,
          flow: flow,
          phase: phase,
          fingerprint: Uint8List.fromList(row.fingerprint),
          devicePackage: devicePackage,
          deviceId: row.deviceId,
          identityPackage: identityPackage,
          backup: row.backup == null ? null : Uint8List.fromList(row.backup!),
          backupVersion: row.backupVersion,
          identityVersion: row.identityVersion,
          expectedSequence: row.expectedSequence,
          previousHash: row.previousHash == null
              ? null
              : Uint8List.fromList(row.previousHash!),
          pendingLogRecord: row.pendingLogRecord == null
              ? null
              : Uint8List.fromList(row.pendingLogRecord!),
          message: message,
          recoverySecretDisplayed: row.recoverySecretDisplayed,
          recoveryConfirmed: row.recoveryConfirmed,
        ),
      );
    } on EnrollmentCryptoFormatException {
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
  Future<Result<void>> persistPrepared(EnrollmentJournal journal) =>
      _write(journal);

  @override
  Future<Result<void>> persistRegistrationResult({
    required EnrollmentJournal journal,
    required DeviceRegistrationResponse response,
  }) async {
    final sessionTokens = SessionTokens(
      accessToken: AccessToken(
        value: response.accessToken,
        expiresAt: response.accessExpiresAt,
        scope: SessionScope.full,
      ),
      userId: response.userId,
      deviceId: response.deviceId,
    );
    final registered = journal.copyWith(
      phase: EnrollmentPhase.registeredUnsigned,
      deviceId: response.deviceId,
      clearMessage: true,
    );
    try {
      await tokens.replaceWithAtomicMutation(
        sessionTokens,
        (database) => _upsert(database, registered),
      );
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> update(EnrollmentJournal journal) {
    if (journal.phase == EnrollmentPhase.complete) {
      return _complete(journal);
    }
    return _write(journal);
  }

  @override
  Future<Result<void>> clear({required String userId}) async {
    final database = await _database();
    if (database == null) {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    try {
      await (database.delete(
        database.enrollmentIntents,
      )..where((entry) => entry.userId.equals(userId))).go();
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> markNewAccount({required String userId}) async {
    final database = await _database();
    if (database == null) {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    try {
      await database
          .into(database.localPreferences)
          .insertOnConflictUpdate(
            LocalPreferencesCompanion.insert(
              preferenceKey: _newAccountMarker,
              valueCiphertext: Uint8List.fromList(
                utf8.encode(
                  jsonEncode({'version': _formatVersion, 'user_id': userId}),
                ),
              ),
              valueVersion: _formatVersion,
            ),
          );
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<bool>> isNewAccount({required String userId}) async {
    final database = await _database();
    if (database == null) {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    try {
      final row =
          await (database.select(database.localPreferences)..where(
                (entry) => entry.preferenceKey.equals(_newAccountMarker),
              ))
              .getSingleOrNull();
      if (row == null || row.valueVersion != _formatVersion) {
        return const Result.success(false);
      }
      final value = jsonDecode(utf8.decode(row.valueCiphertext));
      return Result.success(
        value is Map<String, Object?> &&
            value['version'] == _formatVersion &&
            value['user_id'] == userId,
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<String?>> currentFullSessionDeviceId() async {
    try {
      final session = await tokens.read();
      return Result.success(
        session?.accessToken.scope == SessionScope.full
            ? session?.deviceId
            : null,
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<IdentityKeyPackage?>> readCompletedIdentity() async {
    final database = await _database();
    if (database == null) {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    try {
      final row =
          await (database.select(database.secureSecrets)
                ..where((entry) => entry.secretId.equals(_identitySecretId)))
              .getSingleOrNull();
      return Result.success(
        row == null
            ? null
            : IdentityKeyPackage.fromNative(
                row.wrappedCiphertextOrOpaqueHandle,
              ),
      );
    } on EnrollmentCryptoFormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  Future<Result<void>> _write(EnrollmentJournal journal) async {
    final database = await _database();
    if (database == null) {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    try {
      await _upsert(database, journal);
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  Future<void> _upsert(
    LocalDatabase database,
    EnrollmentJournal journal,
  ) => database
      .into(database.enrollmentIntents)
      .insertOnConflictUpdate(
        EnrollmentIntentsCompanion.insert(
          userId: journal.userId,
          flow: journal.flow.index,
          phase: journal.phase.index,
          fingerprint: Uint8List.fromList(journal.fingerprint),
          deviceState: Uint8List.fromList(journal.devicePackage.opaqueBytes),
          deviceId: Value(journal.deviceId),
          identityState: Value(
            journal.identityPackage == null
                ? null
                : Uint8List.fromList(journal.identityPackage!.opaqueBytes),
          ),
          backup: Value(
            journal.backup == null ? null : Uint8List.fromList(journal.backup!),
          ),
          backupVersion: Value(journal.backupVersion),
          identityVersion: Value(journal.identityVersion),
          expectedSequence: Value(journal.expectedSequence),
          previousHash: Value(
            journal.previousHash == null
                ? null
                : Uint8List.fromList(journal.previousHash!),
          ),
          pendingLogRecord: Value(
            journal.pendingLogRecord == null
                ? null
                : Uint8List.fromList(journal.pendingLogRecord!),
          ),
          message: Value(journal.message?.index),
          recoverySecretDisplayed: Value(journal.recoverySecretDisplayed),
          recoveryConfirmed: Value(journal.recoveryConfirmed),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

  Future<Result<void>> _complete(EnrollmentJournal journal) async {
    final database = await _database();
    final identity = journal.identityPackage;
    final deviceId = journal.deviceId;
    if (database == null || identity == null || deviceId == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    try {
      final publicIdentity = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': journal.identityVersion,
            'master_pub': base64Encode(identity.masterPub),
            'self_signing_pub': base64Encode(identity.selfSigningPub),
            'user_signing_pub': base64Encode(identity.userSigningPub),
            'master_sig': base64Encode(identity.masterSig),
          }),
        ),
      );
      // `devices.public_bundle` has exactly one reader - DriftContactRepository,
      // which every send reaches through resolveLiveDevices - and it rejects a
      // bundle that is not in this shape. Enrolment used to write the wire
      // field names here (`version`, `ik_pub`, `registration_id`), so the row
      // this transaction created could never be decoded again: reading the
      // account's own devices threw, `_refresh` of the local user failed
      // integrityCheckFailed, and every outbound message was refused from the
      // moment enrolment finished. Peer rows were always written by the
      // repository's own encoder, which is why only the local account broke.
      // `cross` and `bundle_version` are deliberately absent: the cross
      // signature belongs to the second enrolment phase and does not exist
      // yet here, and PeerPublicDevice rejects one without the other. The row
      // only has to survive being read - the first refresh of this account
      // replaces it with the server's signed bundle.
      final publicDevice = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 1,
            'device_id': deviceId,
            'ik': base64Encode(journal.devicePackage.public.ikPub),
            'registration': journal.devicePackage.public.registrationId,
          }),
        ),
      );
      await database.writeTransaction<void>(() async {
        await database
            .into(database.secureSecrets)
            .insertOnConflictUpdate(
              SecureSecretsCompanion.insert(
                secretId: _deviceSecretId,
                kind: 0,
                wrappedCiphertextOrOpaqueHandle: Uint8List.fromList(
                  journal.devicePackage.opaqueBytes,
                ),
                formatVersion: 1,
              ),
            );
        await database
            .into(database.secureSecrets)
            .insertOnConflictUpdate(
              SecureSecretsCompanion.insert(
                secretId: _identitySecretId,
                kind: 1,
                wrappedCiphertextOrOpaqueHandle: Uint8List.fromList(
                  identity.opaqueBytes,
                ),
                formatVersion: 1,
              ),
            );
        await database
            .into(database.users)
            .insertOnConflictUpdate(
              UsersCompanion.insert(
                userId: journal.userId,
                activated: true,
                directoryEntryCiphertext: Uint8List.fromList(
                  utf8.encode(journal.userId),
                ),
                localState: 0,
              ),
            );
        await database
            .into(database.accountIdentities)
            .insertOnConflictUpdate(
              AccountIdentitiesCompanion.insert(
                // See `SecureSessionTokenAdapter`: a singleton rowid alias is
                // auto-assigned when an insert omits it, so the column default
                // never applies and the second write to this table would fail
                // its own check.
                singletonId: const Value(1),
                verifiedPublicStateCiphertext: publicIdentity,
                backupVersion: Value(journal.backupVersion),
                recoveryStatus: 4,
              ),
            );
        await database
            .into(database.devices)
            .insertOnConflictUpdate(
              DevicesCompanion.insert(
                deviceId: deviceId,
                userId: journal.userId,
                publicBundle: publicDevice,
                revocationState: 0,
                bundleVersion: const Value(1),
                lastSignedPrekeyRotationUnixDay: Value(
                  DateTime.now().toUtc().millisecondsSinceEpoch ~/
                      Duration.millisecondsPerDay,
                ),
              ),
            );
        await (database.delete(
          database.enrollmentIntents,
        )..where((entry) => entry.userId.equals(journal.userId))).go();
        await (database.delete(database.localPreferences)
              ..where((entry) => entry.preferenceKey.equals(_newAccountMarker)))
            .go();
      });
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  Future<LocalDatabase?> _database() async {
    final result = await runtime.open();
    return result.fold(
      onSuccess: (database) => database,
      onFailure: (_) => null,
    );
  }

  T _enumAt<T>(List<T> values, int index) {
    if (index < 0 || index >= values.length) {
      throw const EnrollmentCryptoFormatException();
    }
    return values[index];
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
}
