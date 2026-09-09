import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('typed Dio REST client', () {
    test(
      'accepts documented success, empty, and not-modified statuses',
      () async {
        final adapter = QueueAdapter([
          jsonResponse(200, {'status': 'ok'}),
          jsonResponse(201, const <String, Object?>{}),
          jsonResponse(202, const <String, Object?>{}),
          jsonResponse(204, null),
          jsonResponse(205, null),
          jsonResponse(304, null),
        ]);
        final client = testClient(adapter);

        final health = await client.send(
          request<HealthResponseDto>(
            decode: HealthResponseDto.fromJson,
            acceptedStatusCodes: const {200},
          ),
        );
        expect(health, isA<Success<HealthResponseDto>>());
        for (final status in const [201, 202]) {
          final response = await client.send(
            request<Object?>(
              decode: (json) => json,
              acceptedStatusCodes: {status},
            ),
          );
          expect(response, isA<Success<Object?>>());
        }
        for (final status in const [204, 205, 304]) {
          final response = await client.send(
            request<EmptyResponseDto>(
              decode: EmptyResponseDto.fromJson,
              acceptedStatusCodes: {status},
            ),
          );
          expect(response, isA<Success<EmptyResponseDto>>());
        }
      },
    );

    test('maps every documented backend error code without detail', () async {
      const cases = <(int, String, BackendFailureCode)>[
        (400, 'invalid_request', BackendFailureCode.invalidRequest),
        (400, 'bad_bucket', BackendFailureCode.badBucket),
        (400, 'identity_required', BackendFailureCode.identityRequired),
        (401, 'unauthenticated', BackendFailureCode.invalidToken),
        (401, 'invalid_token', BackendFailureCode.invalidToken),
        (401, 'token_revoked', BackendFailureCode.tokenRevoked),
        (401, 'invalid_credentials', BackendFailureCode.invalidCredentials),
        (403, 'account_inactive', BackendFailureCode.accountInactive),
        (403, 'scope_forbidden', BackendFailureCode.scopeForbidden),
        (403, 'forbidden', BackendFailureCode.forbidden),
        (404, 'not_found', BackendFailureCode.notFound),
        (405, 'method_not_allowed', BackendFailureCode.methodNotAllowed),
        (409, 'username_taken', BackendFailureCode.usernameTaken),
        (409, 'stale_version', BackendFailureCode.staleVersion),
        (409, 'device_limit', BackendFailureCode.deviceLimit),
        (409, 'prekey_limit', BackendFailureCode.prekeyLimit),
        (409, 'devicelog_limit', BackendFailureCode.deviceLogLimit),
        (413, 'payload_too_large', BackendFailureCode.payloadTooLarge),
        (413, 'quota_exceeded', BackendFailureCode.quotaExceeded),
        (429, 'throttled', BackendFailureCode.throttled),
        (500, 'server_error', BackendFailureCode.serverError),
        (503, 'storage_full', BackendFailureCode.storageFull),
        (503, 'unavailable', BackendFailureCode.unavailable),
        (503, 'voice_unconfigured', BackendFailureCode.voiceUnconfigured),
      ];
      final adapter = QueueAdapter([
        for (final entry in cases)
          jsonResponse(
            entry.$1,
            {'code': entry.$2, 'detail': 'banned raw backend detail'},
            headers: entry.$1 == 429
                ? {
                    'retry-after': ['17'],
                  }
                : null,
          ),
      ]);
      final client = testClient(adapter);

      for (final entry in cases) {
        final result = await client.send(
          request<EmptyResponseDto>(decode: EmptyResponseDto.fromJson),
        );
        expect(result, isA<FailureResult<EmptyResponseDto>>());
        final failure = (result as FailureResult<EmptyResponseDto>).failure;
        expect(failure, isA<BackendFailure>());
        expect((failure as BackendFailure).code, entry.$3);
        if (entry.$1 == 429) {
          expect(failure.retryAfter, const Duration(seconds: 17));
        }
      }
    });

    test('rejects malformed JSON and a structurally malformed body', () async {
      final adapter = QueueAdapter([
        response(200, '{not-json'),
        jsonResponse(200, {'status': 7}),
      ]);
      final client = testClient(adapter);

      for (var index = 0; index < 2; index += 1) {
        final result = await client.send(
          request<HealthResponseDto>(
            decode: HealthResponseDto.fromJson,
            acceptedStatusCodes: const {200},
          ),
        );
        final failure = (result as FailureResult<HealthResponseDto>).failure;
        expect(failure, isA<SecurityFailure>());
        expect(
          (failure as SecurityFailure).kind,
          SecurityFailureKind.malformedServerResponse,
        );
      }
    });

    test('maps timeout and explicit cancellation', () async {
      final adapter = QueueAdapter([
        (options, requestStream, cancelFuture) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        ),
        (options, requestStream, cancelFuture) async {
          await cancelFuture;
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
          );
        },
      ]);
      final client = testClient(adapter);

      final timeout = await client.send(
        request<EmptyResponseDto>(
          method: RestMethod.post,
          decode: EmptyResponseDto.fromJson,
        ),
      );
      expect(
        (timeout as FailureResult<EmptyResponseDto>).failure,
        isA<TransportFailure>().having(
          (failure) => failure.kind,
          'kind',
          TransportFailureKind.timeout,
        ),
      );

      final cancellation = CancellationSignal();
      final pending = client.send(
        request<EmptyResponseDto>(
          method: RestMethod.post,
          decode: EmptyResponseDto.fromJson,
        ),
        cancellation: cancellation,
      );
      cancellation.cancel();
      final cancelled = await pending;
      expect(
        (cancelled as FailureResult<EmptyResponseDto>).failure,
        isA<CancellationFailure>(),
      );
    });

    test('enforces request and response byte budgets', () async {
      final requestAdapter = QueueAdapter([jsonResponse(200, null)]);
      final requestClient = testClient(requestAdapter);
      final tooLargeRequest = await requestClient.send(
        request<EmptyResponseDto>(
          method: RestMethod.post,
          body: {'blob': '0123456789'},
          limits: const PayloadLimits(
            maximumRequestBytes: 4,
            maximumResponseBytes: 32,
          ),
          decode: EmptyResponseDto.fromJson,
        ),
      );
      expect(requestAdapter.calls, 0);
      expect(
        (tooLargeRequest as FailureResult<EmptyResponseDto>).failure,
        isA<TransportFailure>().having(
          (failure) => failure.kind,
          'kind',
          TransportFailureKind.requestTooLarge,
        ),
      );

      final responseAdapter = QueueAdapter([
        jsonResponse(200, {'value': '0123456789'}),
      ]);
      final responseClient = testClient(responseAdapter);
      final tooLargeResponse = await responseClient.send(
        request<EmptyResponseDto>(
          limits: const PayloadLimits(
            maximumRequestBytes: 32,
            maximumResponseBytes: 4,
          ),
          decode: EmptyResponseDto.fromJson,
        ),
      );
      expect(
        (tooLargeResponse as FailureResult<EmptyResponseDto>).failure,
        isA<TransportFailure>().having(
          (failure) => failure.kind,
          'kind',
          TransportFailureKind.responseTooLarge,
        ),
      );
    });

    test(
      'retries a safe read once but never automatically replays POST',
      () async {
        final adapter = QueueAdapter([
          jsonResponse(503, {'code': 'temporary'}),
          jsonResponse(200, {'status': 'ok'}),
          jsonResponse(503, {'code': 'temporary'}),
        ]);
        final scheduler = ImmediateRetryScheduler();
        final client = testClient(adapter, retryScheduler: scheduler);

        final read = await client.send(
          request<HealthResponseDto>(
            decode: HealthResponseDto.fromJson,
            acceptedStatusCodes: const {200},
            replaySafety: ReplaySafety.readOnly,
          ),
        );
        expect(read, isA<Success<HealthResponseDto>>());
        expect(adapter.calls, 2);
        expect(scheduler.calls, 1);

        final write = await client.send(
          request<EmptyResponseDto>(
            method: RestMethod.post,
            decode: EmptyResponseDto.fromJson,
          ),
        );
        expect(write, isA<FailureResult<EmptyResponseDto>>());
        expect(adapter.calls, 3);
      },
    );

    test(
      'performs one authenticated retry only for replay-safe requests',
      () async {
        final adapter = QueueAdapter([
          jsonResponse(401, {'code': 'token_not_valid'}),
          jsonResponse(200, {'status': 'ok'}),
          jsonResponse(401, {'code': 'token_not_valid'}),
        ]);
        final coordinator = FakeAccessTokenCoordinator();
        final client = testClient(adapter)..bindTokenCoordinator(coordinator);

        final read = await client.send(
          request<HealthResponseDto>(
            decode: HealthResponseDto.fromJson,
            acceptedStatusCodes: const {200},
            authentication: AuthenticationRequirement.full,
            replaySafety: ReplaySafety.readOnly,
          ),
        );
        expect(read, isA<Success<HealthResponseDto>>());
        expect(coordinator.recoveries, 1);
        expect(
          adapter.requests[0].headers['Authorization'],
          'Bearer old-access',
        );
        expect(
          adapter.requests[1].headers['Authorization'],
          'Bearer new-access',
        );

        final write = await client.send(
          request<EmptyResponseDto>(
            method: RestMethod.post,
            decode: EmptyResponseDto.fromJson,
            authentication: AuthenticationRequirement.full,
          ),
        );
        expect(write, isA<FailureResult<EmptyResponseDto>>());
        expect(coordinator.recoveries, 2);
        expect(adapter.calls, 3);
      },
    );

    test(
      'diagnostics contain no payload, token, identifier, or capability URL',
      () async {
        final diagnostics = CapturingDiagnostics();
        final adapter = QueueAdapter([
          jsonResponse(400, {
            'code': 'bad_request',
            'detail': 'plaintext-secret-token-key-ciphertext-device-id',
          }),
        ]);
        final client = testClient(adapter, diagnostics: diagnostics);
        await client.send(
          request<EmptyResponseDto>(
            method: RestMethod.post,
            body: {
              'token': 'access-secret',
              'blob': 'ciphertext-secret',
              'attachment_id': 'capability-secret',
            },
            decode: EmptyResponseDto.fromJson,
          ),
        );

        final output = diagnostics.events
            .map(formatRedactedDiagnostic)
            .join('\n');
        for (final banned in const [
          'plaintext-secret',
          'access-secret',
          'token',
          'key',
          'ciphertext-secret',
          'device-id',
          'capability-secret',
          '/api/',
        ]) {
          expect(output, isNot(contains(banned)));
        }
      },
    );
  });

  group('DTO contract boundaries', () {
    test('renew DTO requires one token and anchors the stated lifetime', () {
      final token = jwt(expirySeconds: 2000000000);
      final receivedAt = DateTime.utc(2026, 9, 8, 12);
      final dto = SessionTokenResponseDto.fromJson({
        'token': token,
        'expires_in': 2592000,
      });
      final domain = dto.toDomain(receivedAt: receivedAt);
      expect(domain.accessToken.scope, SessionScope.full);
      expect(domain.accessToken.value, token);
      // The lifetime is stated relative to the moment the server issued the
      // token, not read out of the claims: the claim set is the server's and
      // `expires_in` is published so that no client has to decode one.
      expect(
        domain.accessToken.expiresAt,
        receivedAt.add(const Duration(days: 30)),
      );
      expect(
        () => SessionTokenResponseDto.fromJson({'token': token}),
        throwsA(isA<MalformedApiBody>()),
      );
      expect(
        () =>
            SessionTokenResponseDto.fromJson({'token': token, 'expires_in': 0}),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    test('drain DTO enforces authoritative page shape and maximum', () {
      final parsed = DrainEnvelopesResponseDto.fromJson(<String, Object?>{
        'envelopes': [
          {
            'id': 'e4f8a1c2-9b3d-4e5f-8a70-6c1d2e3f4a5b',
            'seq': 12,
            'blob': envelopeBlob(),
          },
        ],
        'has_more': false,
        'pruned_through': 0,
      }, ServerConfig.fallback);
      expect(parsed.envelopes.single.sequence, 12);
      expect(parsed.prunedThrough, 0);

      expect(
        () => DrainEnvelopesResponseDto.fromJson(<String, Object?>{
          'envelopes': [
            {
              'id': 'e4f8a1c2-9b3d-4e5f-8a70-6c1d2e3f4a5b',
              'seq': 12,
              'blob': base64.encode(List<int>.filled(1023, 0)),
            },
          ],
          'has_more': false,
          'pruned_through': 0,
        }, ServerConfig.fallback),
        throwsA(isA<MalformedApiBody>()),
      );

      expect(
        () => DrainEnvelopesResponseDto.fromJson(<String, Object?>{
          'envelopes': List<Object?>.filled(
            ServerConfig.fallback.drainPageMax + 1,
            const <String, Object?>{},
          ),
          'has_more': true,
          'pruned_through': 0,
        }, ServerConfig.fallback),
        throwsA(isA<MalformedApiBody>()),
      );
    });
  });
}

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

AdapterHandler jsonResponse(
  int statusCode,
  Object? body, {
  Map<String, List<String>>? headers,
}) => response(
  statusCode,
  body == null ? '' : jsonEncode(body),
  headers: headers,
);

AdapterHandler response(
  int statusCode,
  String body, {
  Map<String, List<String>>? headers,
}) =>
    (options, requestStream, cancelFuture) async => ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        'content-type': ['application/json'],
        ...?headers,
      },
    );

DioRestClient testClient(
  QueueAdapter adapter, {
  NetworkDiagnostics diagnostics = const NoopNetworkDiagnostics(),
  RetryScheduler? retryScheduler,
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return DioRestClient(
    serverOrigin: Uri.parse('https://chat.example.test'),
    dio: dio,
    diagnostics: diagnostics,
    retryScheduler: retryScheduler ?? ImmediateRetryScheduler(),
  );
}

ApiRequest<T> request<T>({
  RestMethod method = RestMethod.get,
  required T Function(Object?) decode,
  Set<int> acceptedStatusCodes = const {200},
  AuthenticationRequirement authentication = AuthenticationRequirement.none,
  ReplaySafety replaySafety = ReplaySafety.never,
  PayloadLimits limits = ApiContractLimits.smallJson,
  Object? body,
}) => ApiRequest<T>(
  method: method,
  path: '/api/v1/health',
  decode: decode,
  acceptedStatusCodes: acceptedStatusCodes,
  authentication: authentication,
  replaySafety: replaySafety,
  limits: limits,
  body: body,
);

final class ImmediateRetryScheduler implements RetryScheduler {
  int calls = 0;

  @override
  Future<void> wait(Duration delay) async {
    calls += 1;
  }
}

final class FakeAccessTokenCoordinator implements AccessTokenCoordinator {
  int recoveries = 0;

  @override
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false}) async =>
      Result.success(token('old-access'));

  @override
  Future<Result<AccessToken>> recoverAfterUnauthorized(
    String rejectedToken,
  ) async {
    recoveries += 1;
    return Result.success(token('new-access'));
  }

  @override
  Future<void> handleRevocation() async {}

  @override
  Future<void> logout() async {}
}

AccessToken token(String value) => AccessToken(
  value: value,
  expiresAt: DateTime.utc(2100),
  scope: SessionScope.full,
);

final class CapturingDiagnostics implements NetworkDiagnostics {
  final List<NetworkDiagnosticEvent> events = [];

  @override
  void record(NetworkDiagnosticEvent event) => events.add(event);
}

String jwt({required int expirySeconds}) {
  final header = base64Url.encode(utf8.encode('{}')).replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'exp': expirySeconds})))
      .replaceAll('=', '');
  return '$header.$payload.signature';
}

String envelopeBlob() => base64.encode(List<int>.filled(1024, 0));
