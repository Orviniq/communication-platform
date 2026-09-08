import 'dart:convert';

import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/ports/linked_device_ports.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart';

/// Drift is the source of truth for the Linked Devices screen.  The server
/// response is only projected here after the caller has authenticated its
/// device list and log extension.
final class DriftLinkedDeviceRepository implements LinkedDeviceLocalPort {
  const DriftLinkedDeviceRepository(this.database);

  static const _etagPrefix = 'own.devices.etag.v1.';
  static const _identitySecretId = 'account-cross-signing-state-v1';
  final LocalDatabase database;

  @override
  Stream<List<LinkedDevice>> watchOwnDevices(String userId) =>
      (database.select(database.devices)
            ..where(
              (d) => d.userId.equals(userId) & d.ownerListing.equals(true),
            )
            ..orderBy([(d) => OrderingTerm.asc(d.deviceId)]))
          .watch()
          .map((rows) => rows.map(_device).toList(growable: false));

  @override
  Future<Result<List<LinkedDevice>>> readOwnDevices(String userId) async {
    try {
      final rows =
          await (database.select(database.devices)
                ..where(
                  (d) => d.userId.equals(userId) & d.ownerListing.equals(true),
                )
                ..orderBy([(d) => OrderingTerm.asc(d.deviceId)]))
              .get();
      return Result.success(rows.map(_device).toList(growable: false));
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<String?>> readOwnDevicesEtag(String userId) async {
    try {
      final row =
          await (database.select(database.localPreferences)
                ..where((p) => p.preferenceKey.equals('$_etagPrefix$userId')))
              .getSingleOrNull();
      return Result.success(
        row == null ? null : utf8.decode(row.valueCiphertext),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> replaceOwnDevices({
    required String userId,
    required String etag,
    required List<LinkedDevice> devices,
  }) async {
    try {
      await database.writeTransaction(() async {
        final existing = await (database.select(
          database.devices,
        )..where((d) => d.userId.equals(userId))).get();
        final byId = {for (final row in existing) row.deviceId: row};
        for (final device in devices) {
          final old = byId[device.deviceId];
          await database
              .into(database.devices)
              .insertOnConflictUpdate(
                DevicesCompanion.insert(
                  deviceId: device.deviceId,
                  userId: userId,
                  publicBundle: old?.publicBundle ?? Uint8List(0),
                  etagCiphertext: Value(Uint8List.fromList(utf8.encode(etag))),
                  labelCiphertext: Value(device.encryptedLabel),
                  decryptedLabel: Value(device.label),
                  revocationState: old?.revocationState ?? 0,
                  bundleVersion: Value(old?.bundleVersion),
                  lastSignedPrekeyRotationUnixDay: Value(
                    old?.lastSignedPrekeyRotationUnixDay ?? 0,
                  ),
                  createdDate: Value(
                    device.createdDate.toIso8601String().substring(0, 10),
                  ),
                  isCurrentDevice: Value(device.thisDevice),
                  ownerListing: const Value(true),
                ),
              );
        }
        final currentIds = devices.map((d) => d.deviceId).toSet();
        await (database.update(database.devices)..where(
              (d) =>
                  d.userId.equals(userId) &
                  d.ownerListing.equals(true) &
                  d.deviceId.isNotIn(currentIds),
            ))
            .write(const DevicesCompanion(ownerListing: Value(false)));
        await database
            .into(database.localPreferences)
            .insertOnConflictUpdate(
              LocalPreferencesCompanion.insert(
                preferenceKey: '$_etagPrefix$userId',
                valueCiphertext: Uint8List.fromList(utf8.encode(etag)),
                valueVersion: 1,
              ),
            );
      });
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> updateEncryptedLabel({
    required String deviceId,
    required String label,
    required Uint8List encryptedLabel,
  }) async {
    try {
      await (database.update(
        database.devices,
      )..where((d) => d.deviceId.equals(deviceId))).write(
        DevicesCompanion(
          labelCiphertext: Value(encryptedLabel),
          decryptedLabel: Value(label),
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
  Future<Result<void>> markMissingHistorySources(
    Set<String> liveDeviceIds,
  ) async {
    try {
      final normalized = liveDeviceIds.map((id) => id.toLowerCase()).toSet();
      await (database.update(database.historyTransfers)..where(
            (transfer) =>
                transfer.direction.equals(0) &
                transfer.state.isIn(const [1, 2, 3]) &
                transfer.sourceDeviceId.isNotIn(normalized),
          ))
          .write(
            HistoryTransfersCompanion(
              state: const Value(4),
              updatedAt: Value(DateTime.now().toUtc()),
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
  Future<Result<(String, String, IdentityKeyPackage)>>
  readLocalIdentity() async {
    try {
      final session = await database
          .select(database.accountSessions)
          .getSingle();
      final secret = await (database.select(
        database.secureSecrets,
      )..where((s) => s.secretId.equals(_identitySecretId))).getSingle();
      final deviceId = session.deviceIdCiphertext;
      if (deviceId == null) throw const EnrollmentCryptoFormatException();
      return Result.success((
        utf8.decode(session.userIdCiphertext),
        utf8.decode(deviceId),
        IdentityKeyPackage.fromNative(secret.wrappedCiphertextOrOpaqueHandle),
      ));
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
  Future<Result<GlobalSecurityState>> readGlobalSecurityState() async {
    try {
      final row = await database
          .select(database.securityPostures)
          .getSingleOrNull();
      return Result.success(_securityState(row?.state ?? 0));
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<void>> setGlobalSecurityState(
    GlobalSecurityState state, {
    DeviceLogEvidenceKind? evidence,
  }) async {
    try {
      await database
          .into(database.securityPostures)
          .insertOnConflictUpdate(
            SecurityPosturesCompanion.insert(
              singletonId: const Value(1),
              state: state.index,
              evidenceKind: Value(evidence?.index),
              detectedAt: Value(DateTime.now().toUtc()),
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
  Future<Result<PendingDeviceLogMutation?>> readPendingMutation() async {
    try {
      final row =
          await (database.select(database.deviceLogMutations)
                ..orderBy([(m) => OrderingTerm.desc(m.updatedAt)])
                ..limit(1))
              .getSingleOrNull();
      if (row == null) return const Result.success(null);
      return Result.success(
        PendingDeviceLogMutation(
          operationId: row.operationId,
          userId: row.userId,
          kind: DeviceLogMutationKind.values[row.mutationKind],
          targetDeviceId: row.targetDeviceId,
          expectedSequence: row.expectedSequence,
          previousHeadHash: row.previousHeadHash,
          exactRecord: row.exactRecord,
          state: DeviceLogMutationState.values[row.state],
        ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<AuthenticatedDeviceLogRecord?>> readAuthenticatedLogHead(
    String userId,
  ) async {
    try {
      final row =
          await (database.select(database.deviceLogRecords)
                ..where((entry) => entry.userId.equals(userId))
                ..orderBy([(entry) => OrderingTerm.desc(entry.sequence)])
                ..limit(1))
              .getSingleOrNull();
      return Result.success(
        row == null
            ? null
            : AuthenticatedDeviceLogRecord(
                sequence: row.sequence,
                record: row.signedOpaqueRecord,
                hash: row.recordHash,
              ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<void>> appendAuthenticatedLogRecords({
    required String userId,
    required List<AuthenticatedDeviceLogRecord> records,
  }) async {
    try {
      await database.writeTransaction(() async {
        for (final record in records) {
          final existing =
              await (database.select(database.deviceLogRecords)..where(
                    (entry) =>
                        entry.userId.equals(userId) &
                        entry.sequence.equals(record.sequence),
                  ))
                  .getSingleOrNull();
          if (existing != null) {
            if (!_same(existing.recordHash, record.hash) ||
                !_same(existing.signedOpaqueRecord, record.record)) {
              throw const _LinkedDeviceLogConflict();
            }
            continue;
          }
          await database
              .into(database.deviceLogRecords)
              .insert(
                DeviceLogRecordsCompanion.insert(
                  userId: userId,
                  sequence: record.sequence,
                  signedOpaqueRecord: record.record,
                  recordHash: record.hash,
                  forkState: 0,
                  gossipState: 0,
                ),
              );
        }
      });
      return const Result.success(null);
    } on _LinkedDeviceLogConflict {
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
  Future<Result<void>> writePendingMutation(
    PendingDeviceLogMutation mutation,
  ) async {
    try {
      await database
          .into(database.deviceLogMutations)
          .insertOnConflictUpdate(
            DeviceLogMutationsCompanion.insert(
              operationId: mutation.operationId,
              userId: mutation.userId,
              mutationKind: mutation.kind.index,
              targetDeviceId: Value(mutation.targetDeviceId),
              expectedSequence: mutation.expectedSequence,
              previousHeadHash: mutation.previousHeadHash,
              exactRecord: mutation.exactRecord,
              state: mutation.state.index,
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
  Future<Result<void>> clearPendingMutation(String operationId) async {
    try {
      await (database.delete(
        database.deviceLogMutations,
      )..where((m) => m.operationId.equals(operationId))).go();
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  LinkedDevice _device(Device row) => LinkedDevice(
    deviceId: row.deviceId,
    label: row.decryptedLabel,
    labelState: row.decryptedLabel == null
        ? (row.labelCiphertext == null
              ? LinkedDeviceLabelState.notSet
              : LinkedDeviceLabelState.unreadable)
        : LinkedDeviceLabelState.available,
    createdDate:
        DateTime.tryParse(row.createdDate ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    thisDevice: row.isCurrentDevice,
    encryptedLabel: row.labelCiphertext,
  );

  GlobalSecurityState _securityState(int value) => value >= 2
      ? GlobalSecurityState.pendingDeviceChange
      : value == 1
      ? GlobalSecurityState.deviceLogFork
      : GlobalSecurityState.normal;

  bool _same(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index += 1) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}

final class _LinkedDeviceLogConflict implements Exception {
  const _LinkedDeviceLogConflict();
}
