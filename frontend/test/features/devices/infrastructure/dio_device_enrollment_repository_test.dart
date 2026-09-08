import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:communication_platform/features/devices/infrastructure/dio_device_enrollment_repository.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// `POST /api/v1/me/devices` as it actually leaves this client.
///
/// The DTO tests next door prove the two shapes in isolation. These prove the
/// route: the body the server receives, and the `201` it answers.
void main() {
  group('device registration over the wire', () {
    test('the registration body holds no keypackages key', () async {
      final adapter = RecordingAdapter([
        jsonResponse(201, {
          'device_id': deviceId,
          'token': _jwt(2000000000),
          'expires_in': 2592000,
          'scope': 'full',
        }),
      ]);
      final repository = DioDeviceEnrollmentRepository(client(adapter));

      await repository.registerDevice(userId: userId, public: _public());

      final sent =
          jsonDecode(adapter.requests.single.data as String)
              as Map<String, Object?>;
      // `RegisterDeviceIn` is `additionalProperties: false` and has no
      // `keypackages` field, so an extra key is a `400`, not a courtesy the
      // route ignores. The gates in `docs/mls-profile.md` are closed and this
      // client generates no production KeyPackage to put here in any case.
      expect(sent.containsKey('keypackages'), isFalse);
      expect(sent.keys, <String>[
        'ik_pub',
        'spk_id',
        'spk_pub',
        'spk_sig',
        'registration_id',
        'pq_spk',
        'otpks',
        'pq_otpks',
      ]);
      expect(adapter.requests.single.path, '/api/v1/me/devices');
      expect(adapter.requests.single.method, 'POST');
    });

    test('a 201 body with token and expires_in parses', () async {
      final adapter = RecordingAdapter([
        jsonResponse(201, {
          'device_id': deviceId,
          'token': _jwt(2000000000),
          'expires_in': 2592000,
          'scope': 'full',
        }),
      ]);
      final repository = DioDeviceEnrollmentRepository(client(adapter));

      final result = await repository.registerDevice(
        userId: userId,
        public: _public(),
      );

      final registration =
          (result as Success<DeviceRegistrationResponse>).value;
      expect(registration.deviceId, deviceId);
      expect(registration.userId, userId);
      // One token, and the lifetime beside it. This route is where a register
      // token is spent: the session token it answers is what replaces it.
      expect(registration.accessToken, _jwt(2000000000));
      expect(
        registration.accessExpiresAt.difference(DateTime.now().toUtc()),
        greaterThan(const Duration(days: 29)),
      );
      // The register-scope token this call was authorized with is the one it
      // presented; nothing about the answer is read out of the header.
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer register-token',
      );
    });

    test('a 201 body missing the lifetime fails closed', () async {
      final adapter = RecordingAdapter([
        jsonResponse(201, {
          'device_id': deviceId,
          'token': _jwt(2000000000),
          'scope': 'full',
        }),
      ]);
      final repository = DioDeviceEnrollmentRepository(client(adapter));

      final result = await repository.registerDevice(
        userId: userId,
        public: _public(),
      );

      expect(result, isA<FailureResult<DeviceRegistrationResponse>>());
    });
  });
}

const userId = '6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10';
const deviceId = '9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611';

typedef Handler =
    Future<ResponseBody> Function(
      RequestOptions options,
      Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture,
    );

final class RecordingAdapter implements HttpClientAdapter {
  RecordingAdapter(this.handlers);

  final List<Handler> handlers;
  final List<RequestOptions> requests = [];
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handlers[_index++](options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

Handler jsonResponse(int status, Object? body) =>
    (options, requestStream, cancelFuture) async => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );

DioRestClient client(RecordingAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return DioRestClient(
    serverOrigin: Uri.parse('https://chat.example.test'),
    dio: dio,
  )..bindTokenCoordinator(const RegisterScopeCoordinator());
}

/// The only scope this route accepts before a device exists.
final class RegisterScopeCoordinator implements AccessTokenCoordinator {
  const RegisterScopeCoordinator();

  @override
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false}) async =>
      Result.success(
        AccessToken(
          value: 'register-token',
          expiresAt: DateTime.utc(2100),
          scope: SessionScope.register,
        ),
      );

  @override
  Future<Result<AccessToken>> recoverAfterUnauthorized(
    String rejectedToken,
  ) async => const Result.failure(
    AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
  );

  @override
  Future<void> handleRevocation() async {}

  @override
  Future<void> logout() async {}
}

DeviceRegistrationPublic _public() => DeviceRegistrationPublic(
  userId: Uint8List(16),
  registrationId: 7,
  spkId: 1,
  spkPub: Uint8List(32),
  spkSig: Uint8List(64),
  ikPub: Uint8List(64),
  pqSpkId: 1,
  pqSpkPub: Uint8List(1184),
  pqSpkSig: Uint8List(64),
  otpks: <DeviceOneTimePrekey>[
    DeviceOneTimePrekey(keyId: 1, publicKey: Uint8List(32)),
    DeviceOneTimePrekey(keyId: 2, publicKey: Uint8List(32)),
  ],
  pqOtpks: <DeviceOneTimePrekey>[
    DeviceOneTimePrekey(keyId: 1, publicKey: Uint8List(1184)),
  ],
  fingerprint: Uint8List(32),
);

String _jwt(int expiry) {
  final header = base64Url.encode(utf8.encode('{}')).replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'exp': expiry})))
      .replaceAll('=', '');
  return '$header.$payload.signature';
}
