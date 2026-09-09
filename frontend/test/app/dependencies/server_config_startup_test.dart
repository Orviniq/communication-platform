import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/server_config/infrastructure/drift_server_config_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Starting with nothing: no stored answer from the deployment, and no way to
/// ask for one.
///
/// This is the first start of every installation, and it is every start after
/// a log-out wipe. It is also the start of a phone with no working network,
/// which is the case the whole feature is shaped around: the read of
/// `GET /api/v1/config` needs a full-scope token, so on a first start there is
/// no session to make it with and nothing to wait for.
///
/// The property under test is that no limit can stop the client from starting.
/// Every reader gets a complete configuration synchronously, from the first
/// call, whether or not the store has opened and whether or not it ever will.
void main() {
  late LocalDatabase database;

  setUp(() => database = LocalDatabase(NativeDatabase.memory()));
  tearDown(() => database.close());

  ProviderContainer containerOn(LocalDatabase open) {
    final container = ProviderContainer(
      overrides: [
        localDatabaseProvider.overrideWith((ref) => Future.value(open)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('an installation with no stored row answers before the store opens', () {
    final container = containerOn(database);

    // Synchronously, on the first read, with the database future still
    // pending: the callers are a socket frame being validated as it arrives
    // and a response inside a `decode` callback, and neither can await.
    final snapshot = container.read(serverConfigSnapshotProvider);

    expect(snapshot.current, ServerConfig.fallback);
    expect(snapshot.current.fromDeployment, isFalse);
  });

  test('it still answers once the empty store has opened', () async {
    final container = containerOn(database);
    final snapshot = container.read(serverConfigSnapshotProvider);

    await container.read(serverConfigStoreProvider.future);
    await pumpEventQueue();

    expect(snapshot.current, ServerConfig.fallback);
  });

  test('the numbers a screen reads are there from the first build', () {
    final container = containerOn(database);

    // The widget-facing provider unwraps its own loading state rather than
    // handing a screen an absence it would have to render something for.
    expect(container.read(publishedLimitsProvider), ServerConfig.fallback);
  });

  test('a start that cannot open storage at all still answers', () async {
    // Most plausibly protected storage: the database could not be opened, so
    // the row this follows does not exist and never will during this run.
    final follower = LatestServerConfig(
      Stream<ServerConfig>.error(StateError('protected storage unavailable')),
    );
    addTearDown(follower.close);

    await pumpEventQueue();

    // A limit is the server's to enforce in any case, so refusing to answer
    // would take down every caller that only wanted a number — for an outcome
    // the server would have produced anyway.
    expect(follower.current, ServerConfig.fallback);
  });

  test('the deployment\'s answer replaces it without a rebuild', () async {
    final container = containerOn(database);
    final snapshot = container.read(serverConfigSnapshotProvider);
    expect(snapshot.current, ServerConfig.fallback);

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
    );
    await DriftServerConfigStore(database).write(published);
    await pumpEventQueue();

    // The same object a socket and a delivery cycle are already holding, so
    // the session that started offline picks the operator's numbers up without
    // anything being torn down around it.
    expect(snapshot.current.sendBatchMax, published.sendBatchMax);
    expect(snapshot.current.fromDeployment, isTrue);
  });
}
