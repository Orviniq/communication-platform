import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:communication_platform/features/devices/infrastructure/dio_linked_device_repository.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'uses only own-device endpoints for ETag refresh, relabel, and revoke',
    () async {
      final adapter = _QueueAdapter([
        _jsonResponse(304, null),
        _jsonResponse(
          200,
          {
            'devices': [
              {
                'device_id': '10000000-0000-4000-8000-000000000001',
                'label_blob': base64Encode(Uint8List(256)),
                'created_date': '2026-08-01',
                'this_device': true,
              },
            ],
            'log_head_seq': 7,
          },
          headers: {
            'etag': ['"devices-v7"'],
          },
        ),
        _jsonResponse(200, null),
        _jsonResponse(204, null),
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      final client = DioRestClient(
        serverOrigin: Uri.parse('https://chat.example.test'),
        dio: dio,
      )..bindTokenCoordinator(const _TokenCoordinator());
      final repository = DioLinkedDeviceRepository(client);

      final cached = await repository.fetchOwnDevices(etag: '"devices-v6"');
      expect(
        (cached as Success<OwnDeviceRefresh>).value,
        isA<OwnDevicesNotModified>(),
      );

      final refreshed = await repository.fetchOwnDevices();
      final updated = (refreshed as Success<OwnDeviceRefresh>).value;
      expect(updated, isA<OwnDevicesUpdated>());
      expect((updated as OwnDevicesUpdated).etag, '"devices-v7"');

      expect(
        await repository.relabelDevice(
          deviceId: '10000000-0000-4000-8000-000000000001',
          encryptedLabel: Uint8List(256),
        ),
        isA<Success<void>>(),
      );
      expect(
        await repository.revokeDevice(
          deviceId: '10000000-0000-4000-8000-000000000001',
        ),
        isA<Success<void>>(),
      );

      expect(adapter.requests[0].headers['If-None-Match'], '"devices-v6"');
      expect(adapter.requests.map((request) => request.method), [
        'GET',
        'GET',
        'PUT',
        'DELETE',
      ]);
      expect(adapter.requests.map((request) => request.path), [
        '/api/v1/me/devices',
        '/api/v1/me/devices',
        '/api/v1/me/devices/10000000-0000-4000-8000-000000000001',
        '/api/v1/me/devices/10000000-0000-4000-8000-000000000001',
      ]);
      expect(
        adapter.requests.any((request) => request.path.contains('history')),
        isFalse,
      );
    },
  );
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

_Handler _jsonResponse(
  int status,
  Object? body, {
  Map<String, List<String>>? headers,
}) =>
    (options, requestStream, cancelFuture) => Future.value(
      ResponseBody.fromString(
        body == null ? '' : jsonEncode(body),
        status,
        headers: {
          'content-type': ['application/json'],
          ...?headers,
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
