import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/server_config/infrastructure/dio_server_config_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one call this feature makes.
void main() {
  const body = {
    'envelope_ttl_days': 14,
    'attachment_ttl_days': 30,
    'attachment_daily_bytes': 268435456,
    'mailbox_max_bytes': 33554432,
    'max_devices_per_user': 10,
    'max_devicelog_records': 10000,
    'session_token_days': 30,
    'send_batch_max': 256,
    'ack_max': 200,
    'drain_page_max': 100,
    'claim_max': 100,
    'envelope_buckets': [1024, 4096, 16384, 65536, 262144],
    'attachment_buckets': [65536, 262144, 1048576, 4194304, 16777216, 67108864],
    'signal_buckets': [1024, 4096, 16384],
    'voice_configured': false,
  };

  DioServerConfigRepository repositoryOn(_QueueAdapter adapter) =>
      DioServerConfigRepository(
        DioRestClient(
          serverOrigin: Uri.parse('https://chat.example.test'),
          dio: Dio()..httpClientAdapter = adapter,
        )..bindTokenCoordinator(const _TokenCoordinator()),
      );

  test('reads the published limits with one authenticated GET', () async {
    final adapter = _QueueAdapter([_jsonResponse(200, body)]);

    final fetched = await repositoryOn(adapter).fetchPublishedConfig();

    expect((fetched as Success<ServerConfig>).value.envelopeTtlDays, 14);
    expect(adapter.requests.single.method, 'GET');
    expect(adapter.requests.single.path, '/api/v1/config');
    expect(
      adapter.requests.single.headers['Authorization'],
      'Bearer access-token',
    );
  });

  test('a refusal is a failure, not a set of limits', () async {
    // Every full-scope route can answer `429`, and this one names it. A client
    // that read a throttle as an answer would store nothing and believe it had.
    final adapter = _QueueAdapter([
      _jsonResponse(429, {
        'code': 'throttled',
        'detail': 'Request was throttled.',
      }),
    ]);

    final fetched = await repositoryOn(adapter).fetchPublishedConfig();

    expect(fetched, isA<FailureResult<ServerConfig>>());
    expect(
      (fetched as FailureResult<ServerConfig>).failure,
      isA<BackendFailure>().having(
        (failure) => failure.code,
        'code',
        BackendFailureCode.rateLimited,
      ),
    );
  });

  test('a body that is not a ConfigOut is a failure', () async {
    final adapter = _QueueAdapter([
      _jsonResponse(200, const {'envelope_ttl_days': 7}),
    ]);

    final fetched = await repositoryOn(adapter).fetchPublishedConfig();

    expect(fetched, isA<FailureResult<ServerConfig>>());
  });
}

typedef _Handler =
    Future<ResponseBody> Function(
      RequestOptions options,
      Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture,
    );

final class _QueueAdapter implements HttpClientAdapter {
  _QueueAdapter(this.handlers);

  final List<_Handler> handlers;
  final requests = <RequestOptions>[];
  var index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handlers[index++](options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

_Handler _jsonResponse(int status, Object? body) =>
    (options, requestStream, cancelFuture) => Future.value(
      ResponseBody.fromString(
        body == null ? '' : jsonEncode(body),
        status,
        headers: {
          'content-type': ['application/json'],
        },
      ),
    );

final class _TokenCoordinator implements AccessTokenCoordinator {
  const _TokenCoordinator();

  @override
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false}) async =>
      Result.success(
        AccessToken(
          value: 'access-token',
          expiresAt: DateTime.utc(2100),
          scope: SessionScope.full,
        ),
      );

  @override
  Future<void> handleRevocation() async {}

  @override
  Future<void> logout() async {}

  @override
  Future<Result<AccessToken>> recoverAfterUnauthorized(String rejectedToken) =>
      accessToken(forceRefresh: true);
}
