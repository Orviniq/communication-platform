import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/infrastructure/dio_account_authentication_repository.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Dio account authentication repository', () {
    test('register sends the exact documented request once', () async {
      final adapter = RecordingAdapter([
        jsonResponse(201, {'user_id': userId}),
      ]);
      final repository = DioAccountAuthenticationRepository(client(adapter));

      final result = await repository.register(
        username: 'alice',
        password: 'correct horse battery staple',
      );

      expect(result, isA<Success<AccountRegistration>>());
      expect(adapter.requests.single.path, '/api/v1/auth/register');
      expect(adapter.requests.single.method, 'POST');
      expect(jsonDecode(adapter.requests.single.data as String), {
        'username': 'alice',
        'password': 'correct horse battery staple',
      });
      expect(adapter.requests, hasLength(1));
    });

    test(
      'login decodes register and full scope without inventing fields',
      () async {
        final adapter = RecordingAdapter([
          jsonResponse(200, {
            'token': jwt(2000000000),
            'expires_in': 600,
            'user_id': userId,
            'scope': 'register',
          }),
          jsonResponse(200, {
            'token': jwt(2000000001),
            'expires_in': 2592000,
            'user_id': userId,
            'device_id': deviceId,
            'scope': 'full',
          }),
        ]);
        final repository = DioAccountAuthenticationRepository(client(adapter));

        final first = await repository.login(
          username: 'alice',
          password: 'correct horse battery staple',
        );
        final returning = await repository.login(
          username: 'alice',
          password: 'correct horse battery staple',
          deviceId: deviceId,
        );

        final register = (first as Success<AccountSessionGrant>).value;
        expect(register.scope, AccountSessionScope.register);
        final full = (returning as Success<AccountSessionGrant>).value;
        expect(full.scope, AccountSessionScope.full);
        expect(full.deviceId, deviceId);
        expect(jsonDecode(adapter.requests.last.data as String), {
          'username': 'alice',
          'password': 'correct horse battery staple',
          'device_id': deviceId,
        });
      },
    );

    test(
      'inactive and rate-limit errors expose only stable classifications',
      () async {
        final adapter = RecordingAdapter([
          jsonResponse(403, {
            'code': 'account_inactive',
            'detail': 'raw detail must not escape',
          }),
          jsonResponse(
            429,
            {'detail': 'another raw detail'},
            headers: {
              'retry-after': ['31'],
            },
          ),
        ]);
        final repository = DioAccountAuthenticationRepository(client(adapter));

        final inactive = await repository.login(
          username: 'alice',
          password: 'correct horse battery staple',
        );
        final limited = await repository.register(
          username: 'alice',
          password: 'correct horse battery staple',
        );

        expect(
          (inactive as FailureResult<AccountSessionGrant>).failure,
          isA<BackendFailure>().having(
            (failure) => failure.code,
            'code',
            BackendFailureCode.accountInactive,
          ),
        );
        expect(
          (limited as FailureResult<AccountRegistration>).failure,
          isA<BackendFailure>()
              .having(
                (failure) => failure.code,
                'code',
                BackendFailureCode.throttled,
              )
              .having(
                (failure) => failure.retryAfter,
                'retryAfter',
                const Duration(seconds: 31),
              ),
        );
        expect(inactive.toString(), isNot(contains('raw detail')));
        expect(limited.toString(), isNot(contains('raw detail')));
      },
    );

    test('malformed login success fails closed', () async {
      final adapter = RecordingAdapter([
        jsonResponse(200, {
          'access': jwt(2000000000),
          'refresh': jwt(2000000100),
          'user_id': userId,
          'scope': 'full',
        }),
        jsonResponse(200, {
          'access': jwt(2000000000),
          'refresh': 'unexpected',
          'user_id': userId,
          'device_id': deviceId,
          'scope': 'register',
        }),
      ]);
      final repository = DioAccountAuthenticationRepository(client(adapter));

      for (var index = 0; index < 2; index += 1) {
        final result = await repository.login(
          username: 'alice',
          password: 'correct horse battery staple',
        );
        expect(
          (result as FailureResult<AccountSessionGrant>).failure,
          isA<SecurityFailure>().having(
            (failure) => failure.kind,
            'kind',
            SecurityFailureKind.malformedServerResponse,
          ),
        );
      }
    });

    test('erasure sends the password and nothing else, once', () async {
      final adapter = RecordingAdapter([emptyResponse(204)]);
      final repository = DioAccountAuthenticationRepository(
        authenticatedClient(adapter),
      );

      final result = await repository.eraseAccount(
        password: 'correct horse battery staple',
      );

      expect(result, isA<Success<void>>());
      expect(adapter.requests.single.path, '/api/v1/me');
      expect(adapter.requests.single.method, 'DELETE');
      expect(jsonDecode(adapter.requests.single.data as String), {
        'password': 'correct horse battery staple',
      });
      expect(
        adapter.requests.single.headers['authorization'],
        'Bearer access-token',
      );
    });

    test('an erasure refusal never replays and never leaks detail', () async {
      final adapter = RecordingAdapter([
        jsonResponse(401, {
          'code': 'invalid_credentials',
          'detail': 'raw detail must not escape',
        }),
      ]);
      final repository = DioAccountAuthenticationRepository(
        authenticatedClient(adapter),
      );

      final result = await repository.eraseAccount(password: 'wrong password');

      expect(
        (result as FailureResult<void>).failure,
        isA<BackendFailure>().having(
          (failure) => failure.code,
          'code',
          BackendFailureCode.invalidCredentials,
        ),
      );
      // A second attempt would spend another of the five tries the username
      // has, so the transport must not make one on its own.
      expect(adapter.requests, hasLength(1));
      expect(result.toString(), isNot(contains('raw detail')));
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

DioRestClient client(RecordingAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return DioRestClient(
    serverOrigin: Uri.parse('https://chat.example.test'),
    dio: dio,
  );
}

/// The client the authenticated routes need: one bound coordinator, so a
/// `full` request can be given an `Authorization` header at all.
DioRestClient authenticatedClient(RecordingAdapter adapter) =>
    client(adapter)..bindTokenCoordinator(const FullScopeCoordinator());

final class FullScopeCoordinator implements AccessTokenCoordinator {
  const FullScopeCoordinator();

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

Handler emptyResponse(int status) =>
    (options, requestStream, cancelFuture) async =>
        ResponseBody.fromString('', status);

Handler jsonResponse(
  int status,
  Object? body, {
  Map<String, List<String>>? headers,
}) =>
    (options, requestStream, cancelFuture) async => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        'content-type': ['application/json'],
        ...?headers,
      },
    );

String jwt(int expiry) {
  final header = base64Url.encode(utf8.encode('{}')).replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'exp': expiry})))
      .replaceAll('=', '');
  return '$header.$payload.signature';
}
