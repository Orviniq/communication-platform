import 'dart:convert';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_probe_ledger.dart';
import 'package:drift/drift.dart';

/// The probe ledger and the last seen of each peer device, one row per
/// device in `presence_devices` (schema 26, ADR-098 D8).
///
/// The table lives in the encrypted database and goes with it at logout and on
/// erase. Nothing here is synced, and no row is ever sent anywhere. A row made
/// for a last seen alone holds a full bucket and no probe, which the ledger
/// reads exactly as no row.
final class DriftPresenceDevices
    implements PresenceLedgerPort, PresenceLastSeenPort {
  const DriftPresenceDevices(this.database);

  final LocalDatabase database;

  @override
  Future<Result<PresenceLedgerEntry?>> read({
    required String userId,
    required String deviceId,
  }) async {
    try {
      final row =
          await (database.select(database.presenceDevices)..where(
                (row) => row.peerDeviceId.equals(deviceId.toLowerCase()),
              ))
              .getSingleOrNull();
      if (row == null || row.peerUserId != userId.toLowerCase()) {
        return const Result.success(null);
      }
      return Result.success(
        PresenceLedgerEntry(
          userId: row.peerUserId,
          deviceId: row.peerDeviceId,
          probesSinceHeard: row.probesSinceHeard,
          tokens: row.tokens,
          tokensAtMs: row.tokensAtMs,
          lastProbeMs: row.lastProbeMs,
        ),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> write(PresenceLedgerEntry entry) => _guard(
    () => database
        .into(database.presenceDevices)
        .insert(
          PresenceDevicesCompanion.insert(
            peerUserId: entry.userId.toLowerCase(),
            peerDeviceId: entry.deviceId.toLowerCase(),
            probesSinceHeard: entry.probesSinceHeard,
            tokens: entry.tokens,
            tokensAtMs: entry.tokensAtMs,
            lastProbeMs: Value(entry.lastProbeMs),
          ),
          // The last seen is the other rule's, and stays as it is.
          onConflict: DoUpdate(
            (_) => PresenceDevicesCompanion(
              peerUserId: Value(entry.userId.toLowerCase()),
              probesSinceHeard: Value(entry.probesSinceHeard),
              tokens: Value(entry.tokens),
              tokensAtMs: Value(entry.tokensAtMs),
              lastProbeMs: Value(entry.lastProbeMs),
            ),
          ),
        ),
  );

  @override
  Future<Result<List<PresenceLastSeen>>> readLastSeen(
    Set<String> userIds,
  ) async {
    if (userIds.isEmpty) {
      return const Result.success([]);
    }
    try {
      final rows =
          await (database.select(database.presenceDevices)..where(
                (row) =>
                    row.peerUserId.isIn([
                      for (final user in userIds) user.toLowerCase(),
                    ]) &
                    row.lastSeenMs.isNotNull(),
              ))
              .get();
      return Result.success([
        for (final row in rows)
          PresenceLastSeen(
            userId: row.peerUserId,
            deviceId: row.peerDeviceId,
            lastSeenMs: row.lastSeenMs!,
          ),
      ]);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> writeLastSeen(PresenceDevice device, int lastSeenMs) =>
      _guard(
        () => database
            .into(database.presenceDevices)
            .insert(
              PresenceDevicesCompanion.insert(
                peerUserId: device.userId.toLowerCase(),
                peerDeviceId: device.key,
                probesSinceHeard: 0,
                tokens: PresenceProbeLedger.bucketCapacity,
                tokensAtMs: lastSeenMs,
                lastSeenMs: Value(lastSeenMs),
              ),
              // The ledger is the other rule's, and stays as it is.
              onConflict: DoUpdate(
                (_) => PresenceDevicesCompanion(
                  peerUserId: Value(device.userId.toLowerCase()),
                  lastSeenMs: Value(lastSeenMs),
                ),
              ),
            ),
      );

  @override
  Future<Result<void>> forgetLastSeen([PresenceDevice? device]) => _guard(() {
    final update = database.update(database.presenceDevices);
    if (device != null) {
      update.where((row) => row.peerDeviceId.equals(device.key));
    }
    return update.write(
      const PresenceDevicesCompanion(lastSeenMs: Value(null)),
    );
  });

  static Future<Result<void>> _guard(Future<Object?> Function() write) async {
    try {
      await write();
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }
}

/// "Show my online status" in the encrypted preference table, under
/// [sharingKey] (ADR-098 D9). It belongs to this phone and is not synced to
/// the user's other devices.
///
/// On is the default, so a missing row, a row this build cannot read and a
/// store that cannot be read all read as on (T3). Only `off` turns it off.
final class DriftPresenceSharePreference implements PresenceSharePort {
  const DriftPresenceSharePreference(this.database);

  static const sharingKey = 'presence.share.v1';

  final LocalDatabase database;

  @override
  Future<bool> readSharing() async {
    try {
      final row =
          await (database.select(database.localPreferences)
                ..where((entry) => entry.preferenceKey.equals(sharingKey)))
              .getSingleOrNull();
      if (row == null) {
        return true;
      }
      return utf8.decode(row.valueCiphertext, allowMalformed: true) != 'off';
    } on Object {
      return true;
    }
  }

  @override
  Future<Result<void>> writeSharing({required bool sharing}) async {
    try {
      await database
          .into(database.localPreferences)
          .insertOnConflictUpdate(
            LocalPreferencesCompanion.insert(
              preferenceKey: sharingKey,
              valueCiphertext: Uint8List.fromList(
                utf8.encode(sharing ? 'on' : 'off'),
              ),
              valueVersion: 1,
            ),
          );
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }
}
