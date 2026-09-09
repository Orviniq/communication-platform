import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/server_config/application/ports/server_config_ports.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/server_config/infrastructure/server_config_api_dtos.dart';
import 'package:drift/drift.dart';

/// The published limits, in the encrypted preference table.
///
/// One row holding the `ConfigOut` object verbatim. It is a row rather than a
/// table because it is one small singleton fact about the deployment, and
/// because a table would be a schema migration for something the operator can
/// change between two restarts.
///
/// It is durable so that the application starts offline on the operator's
/// numbers instead of on this build's defaults. Nothing here is a secret — the
/// route is authenticated only because none of it is anyone's business before
/// they hold a session — but it lives behind the same non-exportable
/// Keystore-wrapped key as every other durable fact, so the logout wipe takes
/// it with everything else rather than leaving one deployment's limits behind
/// for the next account on the phone.
///
/// A row this build cannot parse is read as no record at all, never as a
/// current one: the failure direction that falls back to a known-good constant
/// is always safer than the one that refuses to start.
final class DriftServerConfigStore implements ServerConfigStore {
  const DriftServerConfigStore(this.database);

  static const configKey = 'server_config.published_limits.v1';

  final LocalDatabase database;

  @override
  Future<ServerConfig> read() async {
    try {
      final row =
          await (database.select(database.localPreferences)
                ..where((entry) => entry.preferenceKey.equals(configKey)))
              .getSingleOrNull();
      return _decode(row?.valueCiphertext);
    } on Object {
      return ServerConfig.fallback;
    }
  }

  @override
  Stream<ServerConfig> watch() =>
      (database.select(database.localPreferences)
            ..where((entry) => entry.preferenceKey.equals(configKey)))
          .watchSingleOrNull()
          .map((row) => _decode(row?.valueCiphertext));

  @override
  Future<Result<void>> write(ServerConfig config) async {
    try {
      final encoded = utf8.encode(
        jsonEncode(ServerConfigResponseDto(config).toJson()),
      );
      await database.writeTransaction<void>(() async {
        await database
            .into(database.localPreferences)
            .insertOnConflictUpdate(
              LocalPreferencesCompanion.insert(
                preferenceKey: configKey,
                valueCiphertext: Uint8List.fromList(encoded),
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

  ServerConfig _decode(Uint8List? stored) {
    if (stored == null) {
      return ServerConfig.fallback;
    }
    try {
      return ServerConfigResponseDto.fromJson(
        jsonDecode(utf8.decode(stored)),
      ).config;
    } on Object {
      return ServerConfig.fallback;
    }
  }
}
