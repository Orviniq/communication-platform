import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/dio_sync_remote_port.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'drain uses the authoritative device endpoint and decodes opaque buckets',
    () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'envelopes': [
            {'id': uuid(1), 'seq': 8, 'blob': base64Encode(blob(8))},
          ],
          'has_more': true,
          'pruned_through': 7,
        }),
      ]);
      final remote = DioSyncRemotePort(
        client(adapter),
        const FixedServerConfig.fallback(),
      );

      final result = await remote.drain(limit: 100);

      expect(result, isA<Success<DrainPage>>());
      final page = (result as Success<DrainPage>).value;
      expect(page.envelopes.single.exactCiphertext, blob(8));
      expect(page.prunedThrough, 7);
      expect(adapter.requests.single.path, '/api/v1/me/envelopes');
      expect(adapter.requests.single.queryParameters, {'limit': 100});
    },
  );

  test('non-idempotent send is never transport-replayed by Dio', () async {
    final adapter = QueueAdapter([connectionFailure]);
    final remote = DioSyncRemotePort(
      client(adapter),
      const FixedServerConfig.fallback(),
    );
    final exact = blob(44);
    final batch = OutboxBatch(
      operationId: 'operation',
      eventId: 'event',
      batchIndex: 0,
      attempt: 1,
      targets: [
        OutboxTarget(
          recipientUserId: 'user',
          recipientDeviceId: uuid(44),
          exactCiphertext: exact,
        ),
      ],
    );

    final result = await remote.send(batch);

    expect(result, isA<FailureResult<OutboxAcceptance>>());
    expect(adapter.calls, 1);
    final body =
        jsonDecode(adapter.requests.single.data as String)
            as Map<String, Object?>;
    final messages = body['messages']! as List<Object?>;
    final message = messages.single! as Map<String, Object?>;
    expect(base64Decode(message['blob']! as String), exact);
  });

  test(
    'idempotent acknowledgement retries response loss with the exact ids',
    () async {
      final adapter = QueueAdapter([
        connectionFailure,
        jsonResponse(200, {'deleted': 0}),
      ]);
      final remote = DioSyncRemotePort(
        client(adapter),
        const FixedServerConfig.fallback(),
      );
      final ids = [uuid(51), uuid(52)];

      final result = await remote.acknowledge(ids);

      expect(result, isA<Success<int>>());
      expect((result as Success<int>).value, 0);
      expect(adapter.calls, 2);
      final bodies = adapter.requests
          .map(
            (request) =>
                jsonDecode(request.data as String) as Map<String, Object?>,
          )
          .toList();
      expect(bodies[0], {'ids': ids});
      expect(bodies[1], bodies[0]);
    },
  );

  test('sync diagnostics contain no token, UUID, ciphertext, or URL', () async {
    final diagnostics = CapturingDiagnostics();
    final adapter = QueueAdapter([
      jsonResponse(202, {
        'accepted': 1,
        'stale_devices': <Object?>[],
        'full_devices': <Object?>[],
      }),
    ]);
    final remote = DioSyncRemotePort(
      client(adapter, diagnostics: diagnostics),
      const FixedServerConfig.fallback(),
    );
    final secretBlob = blob(93);
    const token = 'sensitive-access-token';
    final targetId = uuid(93);

    final result = await remote.send(
      OutboxBatch(
        operationId: 'private-operation',
        eventId: 'private-event',
        batchIndex: 0,
        attempt: 1,
        targets: [
          OutboxTarget(
            recipientUserId: 'private-user',
            recipientDeviceId: targetId,
            exactCiphertext: secretBlob,
          ),
        ],
      ),
    );

    expect(result, isA<Success<OutboxAcceptance>>());
    final diagnostic = formatRedactedDiagnostic(diagnostics.events.single);
    expect(diagnostic, contains('operation=syncSend'));
    expect(diagnostic, isNot(contains(token)));
    expect(diagnostic, isNot(contains(targetId)));
    expect(diagnostic, isNot(contains(base64Encode(secretBlob))));
    expect(diagnostic, isNot(contains('/api/v1/envelopes')));
  });

  test(
    'a page larger than the deployment allows is cut, not refused',
    () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'envelopes': <Object?>[],
          'has_more': false,
          'pruned_through': 0,
        }),
      ]);
      final remote = DioSyncRemotePort(client(adapter), _narrow);

      // The caller's own budget is 100. Refusing it would leave envelopes
      // undrained over a number the caller has no business knowing.
      final result = await remote.drain(limit: 100);

      expect(result, isA<Success<DrainPage>>());
      expect(adapter.requests.single.queryParameters, {'limit': 4});
    },
  );

  test('a page under the ceiling is asked for as it stands', () async {
    final adapter = QueueAdapter([
      jsonResponse(200, {
        'envelopes': <Object?>[],
        'has_more': false,
        'pruned_through': 0,
      }),
    ]);
    final remote = DioSyncRemotePort(client(adapter), _narrow);

    await remote.drain(limit: 2);

    expect(adapter.requests.single.queryParameters, {'limit': 2});
  });

  test('a page past the published ceiling is a malformed answer', () async {
    final adapter = QueueAdapter([
      jsonResponse(200, {
        'envelopes': [
          for (var index = 0; index < 5; index += 1)
            {
              'id': uuid(index + 1),
              'seq': index + 1,
              'blob': base64Encode(blob(index + 1)),
            },
        ],
        'has_more': false,
        'pruned_through': 0,
      }),
    ]);
    final remote = DioSyncRemotePort(client(adapter), _narrow);

    expect(await remote.drain(limit: 4), isA<FailureResult<DrainPage>>());
  });

  test('an envelope outside the published buckets is refused', () async {
    final adapter = QueueAdapter([
      jsonResponse(200, {
        'envelopes': [
          // A length this build was born believing in, and one this deployment
          // no longer publishes.
          {'id': uuid(1), 'seq': 1, 'blob': base64Encode(Uint8List(65536))},
        ],
        'has_more': false,
        'pruned_through': 0,
      }),
    ]);
    final remote = DioSyncRemotePort(client(adapter), _narrow);

    expect(await remote.drain(limit: 4), isA<FailureResult<DrainPage>>());
  });

  test('a batch past what the routes accept never reaches the wire', () {
    final adapter = QueueAdapter([]);
    final remote = DioSyncRemotePort(client(adapter), _narrow);

    expect(
      () => remote.acknowledge([uuid(1), uuid(2), uuid(3), uuid(4)]),
      throwsArgumentError,
    );
    expect(() => remote.send(_batchOf(3)), throwsArgumentError);
    expect(adapter.requests, isEmpty);
  });

  test('an acceptance counting more than the batch is malformed', () async {
    final adapter = QueueAdapter([
      jsonResponse(202, {
        'accepted': 3,
        'stale_devices': <Object?>[],
        'full_devices': <Object?>[],
      }),
    ]);
    final remote = DioSyncRemotePort(client(adapter), _narrow);

    expect(
      await remote.send(_batchOf(2)),
      isA<FailureResult<OutboxAcceptance>>(),
    );
  });

  test('a full device is read apart from a stale one', () async {
    final adapter = QueueAdapter([
      jsonResponse(202, {
        'accepted': 0,
        'stale_devices': [uuid(1)],
        'full_devices': [uuid(2)],
      }),
    ]);
    final remote = DioSyncRemotePort(client(adapter), _narrow);

    final result = await remote.send(_batchOf(2));

    expect(result, isA<Success<OutboxAcceptance>>());
    final acceptance = (result as Success<OutboxAcceptance>).value;
    expect(acceptance.accepted, 0);
    expect(acceptance.staleDeviceIds, {uuid(1)});
    expect(acceptance.fullDeviceIds, {uuid(2)});
  });

  test(
    'a body without full_devices is not a send this client accepts',
    () async {
      final adapter = QueueAdapter([
        jsonResponse(202, {'accepted': 1, 'stale_devices': <Object?>[]}),
      ]);
      final remote = DioSyncRemotePort(client(adapter), _narrow);

      expect(
        await remote.send(_batchOf(1)),
        isA<FailureResult<OutboxAcceptance>>(),
      );
    },
  );

  test('one device cannot be both gone and merely out of room', () async {
    final adapter = QueueAdapter([
      jsonResponse(202, {
        'accepted': 0,
        'stale_devices': [uuid(1)],
        'full_devices': [uuid(1)],
      }),
    ]);
    final remote = DioSyncRemotePort(client(adapter), _narrow);

    expect(
      await remote.send(_batchOf(1)),
      isA<FailureResult<OutboxAcceptance>>(),
    );
  });

  test(
    'an item no mailbox could hold is refused rather than retried',
    () async {
      final adapter = QueueAdapter([]);
      // A ceiling of one mebibyte against an item of four. The device would be
      // reported full on every attempt however patiently its owner collected.
      final remote = DioSyncRemotePort(client(adapter), _narrow);
      final batch = OutboxBatch(
        operationId: 'operation',
        eventId: 'event',
        batchIndex: 0,
        attempt: 1,
        targets: [
          OutboxTarget(
            recipientUserId: 'user',
            recipientDeviceId: uuid(1),
            exactCiphertext: Uint8List(4194304),
          ),
        ],
      );

      final result = await remote.send(batch);

      expect(result, isA<FailureResult<OutboxAcceptance>>());
      expect(
        (result as FailureResult<OutboxAcceptance>).failure,
        isA<ValidationFailure>(),
      );
      expect(adapter.requests, isEmpty);
    },
  );
}

/// A deployment whose operator moved every ceiling this port measures against.
const _narrow = FixedServerConfig(
  ServerConfig(
    envelopeTtlDays: 3,
    attachmentTtlDays: 10,
    attachmentDailyBytes: 1048576,
    mailboxMaxBytes: 1048576,
    maxDevicesPerUser: 2,
    maxDeviceLogRecords: 100,
    sessionTokenDays: 1,
    sendBatchMax: 2,
    ackMax: 3,
    drainPageMax: 4,
    claimMax: 2,
    envelopeBuckets: {1024, 4096},
    attachmentBuckets: {65536},
    signalBuckets: {1024},
    voiceConfigured: false,
  ),
);

OutboxBatch _batchOf(int targets) => OutboxBatch(
  operationId: 'operation',
  eventId: 'event',
  batchIndex: 0,
  attempt: 1,
  targets: [
    for (var index = 0; index < targets; index += 1)
      OutboxTarget(
        recipientUserId: 'user',
        recipientDeviceId: uuid(index + 1),
        exactCiphertext: blob(index + 1),
      ),
  ],
);

typedef AdapterHandler =
    Future<ResponseBody> Function(
      RequestOptions options,
      Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture,
    );

final class QueueAdapter implements HttpClientAdapter {
  QueueAdapter(this.handlers);

  final List<AdapterHandler> handlers;
  final List<RequestOptions> requests = [];
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    final handler = handlers[calls];
    calls += 1;
    return handler(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

AdapterHandler jsonResponse(int statusCode, Object body) =>
    (options, requestStream, cancelFuture) async => ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );

Future<ResponseBody> connectionFailure(
  RequestOptions options,
  Stream<Uint8List>? requestStream,
  Future<void>? cancelFuture,
) => throw DioException(
  requestOptions: options,
  type: DioExceptionType.connectionError,
);

DioRestClient client(
  QueueAdapter adapter, {
  NetworkDiagnostics diagnostics = const NoopNetworkDiagnostics(),
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  final result = DioRestClient(
    serverOrigin: Uri.parse('https://chat.example.test'),
    dio: dio,
    diagnostics: diagnostics,
    retryScheduler: const ImmediateRetry(),
  );
  result.bindTokenCoordinator(const FullTokenCoordinator());
  return result;
}

final class ImmediateRetry implements RetryScheduler {
  const ImmediateRetry();

  @override
  Future<void> wait(Duration delay) async {}
}

final class FullTokenCoordinator implements AccessTokenCoordinator {
  const FullTokenCoordinator();

  @override
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false}) async =>
      Result.success(
        AccessToken(
          value: 'sensitive-access-token',
          expiresAt: DateTime.utc(2100),
          scope: SessionScope.full,
        ),
      );

  @override
  Future<Result<AccessToken>> recoverAfterUnauthorized(String rejectedToken) =>
      accessToken();

  @override
  Future<void> handleRevocation() async {}

  @override
  Future<void> logout() async {}
}

final class CapturingDiagnostics implements NetworkDiagnostics {
  final List<NetworkDiagnosticEvent> events = [];

  @override
  void record(NetworkDiagnosticEvent event) => events.add(event);
}

String uuid(int value) =>
    '00000000-0000-0000-0000-${value.toRadixString(16).padLeft(12, '0')}';

Uint8List blob(int marker) =>
    Uint8List.fromList(List<int>.filled(1024, marker));
