import 'dart:async';

import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// What every caller that measures against a server limit reads.
///
/// The whole point is that it answers synchronously and always. A socket frame
/// is validated as it arrives and a widget builds without awaiting anything, so
/// "no answer yet" is not one of the states a caller can be handed.
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

  test('a fixed configuration answers exactly what it was given', () {
    expect(const FixedServerConfig(published).current, published);
    expect(const FixedServerConfig.fallback().current, ServerConfig.fallback);
  });

  test('this build own constants are in force before anything arrives', () {
    final configurations = StreamController<ServerConfig>();
    addTearDown(configurations.close);

    final snapshot = LatestServerConfig(configurations.stream);
    addTearDown(snapshot.close);

    expect(snapshot.current, ServerConfig.fallback);
  });

  test(
    'the deployment answer replaces them without anything rebuilding',
    () async {
      final configurations = StreamController<ServerConfig>();
      addTearDown(configurations.close);
      final snapshot = LatestServerConfig(configurations.stream);
      addTearDown(snapshot.close);

      configurations.add(published);
      await pumpEventQueue();

      expect(snapshot.current, published);
    },
  );

  test('a stream failure leaves the last good answer in force', () async {
    final configurations = StreamController<ServerConfig>();
    addTearDown(configurations.close);
    final snapshot = LatestServerConfig(configurations.stream);
    addTearDown(snapshot.close);

    configurations
      ..add(published)
      ..addError(StateError('the row could not be read'));
    await pumpEventQueue();

    // Refusing to answer would take down every caller that only wanted a number
    // the server is enforcing in any case.
    expect(snapshot.current, published);
  });

  test('following stops when the owner closes it', () async {
    final configurations = StreamController<ServerConfig>();
    addTearDown(configurations.close);
    final snapshot = LatestServerConfig(configurations.stream);

    await snapshot.close();
    configurations.add(published);
    await pumpEventQueue();

    expect(snapshot.current, ServerConfig.fallback);
  });
}
