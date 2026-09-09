import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/server_config/application/ports/server_config_ports.dart';
import 'package:communication_platform/features/server_config/application/read_published_configuration.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// One read, at the start of a full-scope session, and what it leaves behind.
///
/// The rule the whole feature turns on is that nothing waits for this. The
/// client is already running on the stored answer, or on its own constants, so
/// a read that does not land changes nothing and blocks nobody.
void main() {
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

  test('what the deployment publishes is kept and answered', () async {
    final store = _RecordingStore();
    final read = ReadPublishedConfiguration(
      remote: const _Answering(published),
      store: store,
    );

    final outcome = await read.refresh();

    expect(outcome.config, published);
    expect(outcome.stored, isTrue);
    expect(store.written, [published]);
  });

  test('a read that does not land keeps what was already held', () async {
    final store = _RecordingStore(held: published);
    final read = ReadPublishedConfiguration(
      remote: const _Unreachable(),
      store: store,
    );

    final outcome = await read.refresh();

    expect(outcome.config, published);
    expect(outcome.stored, isFalse);
    expect(store.written, isEmpty);
  });

  test('a first start with no network runs on the fallback', () async {
    final store = _RecordingStore();
    final read = ReadPublishedConfiguration(
      remote: const _Unreachable(),
      store: store,
    );

    final outcome = await read.refresh();

    expect(outcome.config, ServerConfig.fallback);
    expect(outcome.stored, isFalse);
  });

  test('an answer that cannot be written is not reported as kept', () async {
    // The value is in force for this session either way, but the next start
    // begins on the previous answer again, so the read did not land.
    final read = ReadPublishedConfiguration(
      remote: const _Answering(published),
      store: _UnwritableStore(),
    );

    final outcome = await read.refresh();

    expect(outcome.config, published);
    expect(outcome.stored, isFalse);
  });

  test('the store is not read when the route answers', () async {
    final store = _RecordingStore();
    final read = ReadPublishedConfiguration(
      remote: const _Answering(published),
      store: store,
    );

    await read.refresh();

    expect(store.reads, 0);
  });
}

final class _Answering implements ServerConfigReadPort {
  const _Answering(this.config);

  final ServerConfig config;

  @override
  Future<Result<ServerConfig>> fetchPublishedConfig() async =>
      Result.success(config);
}

final class _Unreachable implements ServerConfigReadPort {
  const _Unreachable();

  @override
  Future<Result<ServerConfig>> fetchPublishedConfig() async =>
      const Result.failure(TransportFailure(TransportFailureKind.offline));
}

final class _RecordingStore implements ServerConfigStore {
  _RecordingStore({this.held = ServerConfig.fallback});

  final ServerConfig held;
  final List<ServerConfig> written = [];
  int reads = 0;

  @override
  Future<ServerConfig> read() async {
    reads += 1;
    return written.isEmpty ? held : written.last;
  }

  @override
  Stream<ServerConfig> watch() => Stream<ServerConfig>.value(held);

  @override
  Future<Result<void>> write(ServerConfig config) async {
    written.add(config);
    return const Result.success(null);
  }
}

final class _UnwritableStore implements ServerConfigStore {
  @override
  Future<ServerConfig> read() async => ServerConfig.fallback;

  @override
  Stream<ServerConfig> watch() =>
      Stream<ServerConfig>.value(ServerConfig.fallback);

  @override
  Future<Result<void>> write(ServerConfig config) async =>
      const Result.failure(StorageFailure(StorageFailureKind.unavailable));
}
