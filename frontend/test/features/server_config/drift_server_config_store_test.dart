import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/server_config/infrastructure/drift_server_config_store.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where the operator's limits live between starts.
///
/// The point of keeping them at all is that the client must start with no
/// network, on this deployment's numbers rather than on this build's. These
/// tests hold that, and the direction the store fails in when it cannot.
void main() {
  late LocalDatabase database;
  late DriftServerConfigStore store;

  const published = ServerConfig(
    envelopeTtlDays: 14,
    attachmentTtlDays: 60,
    attachmentDailyBytes: 536870912,
    mailboxMaxBytes: 67108864,
    maxDevicesPerUser: 4,
    maxDeviceLogRecords: 5000,
    sessionTokenDays: 90,
    sendBatchMax: 128,
    ackMax: 64,
    drainPageMax: 50,
    claimMax: 25,
    envelopeBuckets: {1024, 4096},
    attachmentBuckets: {65536, 262144},
    signalBuckets: {1024},
    voiceConfigured: true,
    // A stored row is a row the route once answered, so what comes back out of
    // it says so — which is what lets the one number with no other observable
    // be stated to a user.
    fromDeployment: true,
  );

  /// A second answer, so that "replaced" is not confused with "forgotten": the
  /// fallback would read back as the deployment's own, and correctly, because a
  /// stored row is one the route answered whatever its values happen to be.
  const republished = ServerConfig(
    envelopeTtlDays: 3,
    attachmentTtlDays: 10,
    attachmentDailyBytes: 1048576,
    mailboxMaxBytes: 2097152,
    maxDevicesPerUser: 2,
    maxDeviceLogRecords: 100,
    sessionTokenDays: 7,
    sendBatchMax: 16,
    ackMax: 8,
    drainPageMax: 4,
    claimMax: 2,
    envelopeBuckets: {1024},
    attachmentBuckets: {65536},
    signalBuckets: {1024},
    voiceConfigured: false,
    fromDeployment: true,
  );

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    store = DriftServerConfigStore(database);
  });

  tearDown(() => database.close());

  Future<void> putRow(String contents) => database
      .into(database.localPreferences)
      .insertOnConflictUpdate(
        LocalPreferencesCompanion.insert(
          preferenceKey: DriftServerConfigStore.configKey,
          valueCiphertext: Uint8List.fromList(utf8.encode(contents)),
          valueVersion: 1,
        ),
      );

  group('the stored answer', () {
    test('an installation that has stored nothing reads the fallback', () {
      expect(store.read(), completion(ServerConfig.fallback));
    });

    test('what the deployment published survives a round trip', () async {
      final written = await store.write(published);

      expect(written, isA<Success<void>>());
      expect(await store.read(), published);
    });

    test('a later answer replaces the earlier one', () async {
      await store.write(published);
      await store.write(republished);

      expect(await store.read(), republished);
    });

    test('it is one row, whatever the answer is', () async {
      await store.write(published);
      await store.write(republished);

      final rows = await database.select(database.localPreferences).get();

      expect(rows, hasLength(1));
      expect(rows.single.preferenceKey, DriftServerConfigStore.configKey);
    });
  });

  group('a row this build cannot read', () {
    test('is not JSON at all', () async {
      await putRow('not json');

      expect(await store.read(), ServerConfig.fallback);
    });

    test('is JSON but not a ConfigOut object', () async {
      await putRow('[]');

      expect(await store.read(), ServerConfig.fallback);
    });

    test('has lost a field', () async {
      // A stored row is parsed by the same parser as a wire body, so it fails
      // the same way: as no record, never as a current one. Falling back to a
      // known-good constant is always safer than refusing to start.
      await putRow(jsonEncode(const {'envelope_ttl_days': 7}));

      expect(await store.read(), ServerConfig.fallback);
    });

    test('states an impossible limit', () async {
      await putRow(jsonEncode({'send_batch_max': 0}));

      expect(await store.read(), ServerConfig.fallback);
    });
  });

  group('the projection', () {
    test('starts on what is in force and follows every write', () async {
      final seen = <ServerConfig>[];
      final subscription = store.watch().listen(seen.add);
      addTearDown(subscription.cancel);

      await pumpEventQueue();
      await store.write(published);
      await pumpEventQueue();

      expect(seen.first, ServerConfig.fallback);
      expect(seen.last, published);
    });
  });
}
