import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/beta_mls_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_key_package_model.dart';
import 'package:communication_platform/features/groups/infrastructure/dio_group_key_package_repository.dart';
import 'package:communication_platform/features/groups/infrastructure/group_key_package_api_dtos.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _device = '10000000-0000-4000-8000-000000000001';
const _peerDevice = '20000000-0000-4000-8000-000000000002';
const _peerUser = '30000000-0000-4000-8000-000000000003';

void main() {
  test('strict DTOs accept only canonical bucketed unique claims', () {
    final blob = base64Encode(Uint8List(4096));
    final decoded = ClaimedGroupKeyPackagesResponseDto.fromJson({
      'keypackages': [
        {'device_id': _peerDevice, 'blob': blob},
      ],
    });
    expect(decoded.packages.single.deviceId, _peerDevice);
    expect(decoded.packages.single.wrappedKeyPackage, hasLength(4096));

    expect(
      () => ClaimedGroupKeyPackagesResponseDto.fromJson({
        'keypackages': [
          {'device_id': _peerDevice, 'blob': blob},
          {'device_id': _peerDevice.toUpperCase(), 'blob': blob},
        ],
      }),
      throwsA(isA<MalformedApiBody>()),
    );
    expect(
      () => ClaimedGroupKeyPackagesResponseDto.fromJson({
        'keypackages': [
          {'device_id': _peerDevice, 'blob': base64Encode(Uint8List(4095))},
        ],
      }),
      throwsA(isA<MalformedApiBody>()),
    );
    expect(
      () => GroupKeyPackageCountResponseDto.fromJson({'keypackage_count': 101}),
      throwsA(isA<MalformedApiBody>()),
    );
  });

  test(
    'uses the exact backend count, upload, last-resort, and claim contract',
    () async {
      final package = Uint8List(4096)..fillRange(0, 4096, 0x5a);
      final adapter = _QueueAdapter([
        _jsonResponse(200, {'keypackage_count': 7}),
        _jsonResponse(200, {'keypackage_count': 8}),
        _jsonResponse(200, {'keypackage_count': 8}),
        _jsonResponse(200, {
          'keypackages': [
            {'device_id': _peerDevice, 'blob': base64Encode(package)},
          ],
        }),
      ]);
      final repository = DioGroupKeyPackageRepository(
        _client(adapter),
        const FixedServerConfig.fallback(),
      );

      expect(
        (await repository.fetchConsumableCount(deviceId: _device)
                as Success<int>)
            .value,
        7,
      );
      expect(
        (await repository.upload(
                  deviceId: _device,
                  upload: GroupKeyPackageUpload(
                    kind: MlsKeyPackageKind.consumable,
                    wrappedKeyPackages: [package],
                  ),
                )
                as Success<int>)
            .value,
        8,
      );
      expect(
        (await repository.upload(
                  deviceId: _device,
                  upload: GroupKeyPackageUpload(
                    kind: MlsKeyPackageKind.lastResort,
                    wrappedKeyPackages: [package],
                  ),
                )
                as Success<int>)
            .value,
        8,
      );
      final claims = await repository.claim(
        userId: _peerUser,
        deviceIds: const [_peerDevice],
      );
      expect(
        (claims as Success<List<ClaimedGroupKeyPackage>>).value,
        hasLength(1),
      );

      expect(adapter.requests.map((request) => request.method), [
        'GET',
        'PUT',
        'PUT',
        'POST',
      ]);
      expect(adapter.requests.map((request) => request.path), [
        '/api/v1/me/devices/$_device/keypackages/count',
        '/api/v1/me/devices/$_device/keypackages',
        '/api/v1/me/devices/$_device/keypackages',
        '/api/v1/users/$_peerUser/keypackages/claim',
      ]);
      expect(
        (jsonDecode(adapter.requests[1].data! as String)
            as Map<String, Object?>)['is_last_resort'],
        isFalse,
      );
      expect(
        (jsonDecode(adapter.requests[2].data! as String)
            as Map<String, Object?>)['is_last_resort'],
        isTrue,
      );
      expect(jsonDecode(adapter.requests[3].data! as String), {
        'device_ids': [_peerDevice],
      });
    },
  );

  test(
    'never replays consumable upload but retries last-resort replacement',
    () async {
      final package = Uint8List(4096);
      final consumableAdapter = _QueueAdapter([
        _jsonResponse(503, {'code': 'temporarily_unavailable'}),
        _jsonResponse(200, {'keypackage_count': 1}),
      ]);
      final consumable =
          await DioGroupKeyPackageRepository(
            _client(consumableAdapter),
            const FixedServerConfig.fallback(),
          ).upload(
            deviceId: _device,
            upload: GroupKeyPackageUpload(
              kind: MlsKeyPackageKind.consumable,
              wrappedKeyPackages: [package],
            ),
          );
      expect(consumable, isA<FailureResult<int>>());
      expect(consumableAdapter.requests, hasLength(1));

      final lastResortAdapter = _QueueAdapter([
        _jsonResponse(503, {'code': 'temporarily_unavailable'}),
        _jsonResponse(200, {'keypackage_count': 0}),
      ]);
      final lastResort =
          await DioGroupKeyPackageRepository(
            _client(lastResortAdapter),
            const FixedServerConfig.fallback(),
          ).upload(
            deviceId: _device,
            upload: GroupKeyPackageUpload(
              kind: MlsKeyPackageKind.lastResort,
              wrappedKeyPackages: [package],
            ),
          );
      expect(lastResort, isA<Success<int>>());
      expect(lastResortAdapter.requests, hasLength(2));
    },
  );

  test('claim request rejects duplicate or malformed target ids locally', () {
    expect(
      () => groupKeyPackageClaimJson(const [
        _peerDevice,
        _peerDevice,
      ], claimMax: ServerConfig.fallback.claimMax),
      throwsA(isA<GroupKeyPackageFormatException>()),
    );
    expect(
      () => groupKeyPackageClaimJson(const [
        'not-a-device',
      ], claimMax: ServerConfig.fallback.claimMax),
      throwsA(isA<GroupKeyPackageFormatException>()),
    );
  });
}

DioRestClient _client(_QueueAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return DioRestClient(
    serverOrigin: Uri.parse('https://chat.example.test'),
    dio: dio,
    retryScheduler: const _ImmediateRetry(),
  )..bindTokenCoordinator(const _TokenCoordinator());
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

final class _ImmediateRetry implements RetryScheduler {
  const _ImmediateRetry();

  @override
  Future<void> wait(Duration delay) async {}
}

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
