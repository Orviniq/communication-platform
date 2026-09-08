import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/dio_token_endpoints.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/token_coordinator.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// `POST /api/v1/auth/renew` end to end: the coordinator, the reviewed client,
/// the exchange, and the wire.
void main() {
  group('renew token exchange', () {
    test('two renewals in sequence each answer a usable token', () async {
      // The point of the test. Under the retired pair a renewal spent a
      // refresh token and answered a new one, so a second renewal had to
      // present material the first call replaced; renewing off a token this
      // client had just been handed was the case that broke. Here a renewal
      // presents the ordinary session token and retires nothing, so the token
      // the first renewal issued must itself be renewable.
      final adapter = RecordingAdapter([
        jsonResponse(200, {'token': 'second-token', 'expires_in': 2592000}),
        jsonResponse(200, {'token': 'third-token', 'expires_in': 2592000}),
      ]);
      final store = MemoryTokenStore(
        session('first-token', DateTime.utc(2026, 9, 8, 12, 1)),
      );
      final client = testClient(adapter);
      final coordinator = TokenCoordinator(
        store: store,
        renewExchange: DioRenewTokenExchange(client),
        terminationHandler: RecordingTerminationHandler(),
        timeSource: FixedTimeSource(DateTime.utc(2026, 9, 8, 12)),
      );
      client.bindTokenCoordinator(coordinator);

      final first = await coordinator.accessToken(forceRefresh: true);
      final second = await coordinator.accessToken(forceRefresh: true);

      expect((first as Success<AccessToken>).value.value, 'second-token');
      expect((second as Success<AccessToken>).value.value, 'third-token');
      // Both are full-scope and both outlive the clock, so either could carry
      // the next authenticated request.
      for (final token in [first.value, second.value]) {
        expect(token.scope, SessionScope.full);
        expect(
          token.expiresAt.isAfter(DateTime.utc(2026, 9, 8, 12)),
          isTrue,
          reason: token.value,
        );
      }

      expect(adapter.requests, hasLength(2));
      for (final request in adapter.requests) {
        expect(request.path, '/api/v1/auth/renew');
        expect(request.method, 'POST');
        // The route takes no body at all: the token travels in the header.
        expect(request.data, isNull);
      }
      // The second call is authorized by what the first one issued, which is
      // the whole claim being made.
      expect(
        adapter.requests.map((request) => request.headers['Authorization']),
        ['Bearer first-token', 'Bearer second-token'],
      );
      expect(store.current?.accessToken.value, 'third-token');
      expect(store.replacements, 2);
    });

    test('a renewal body naming the old pair is refused, and the '
        'session it could not renew is kept', () async {
      final adapter = RecordingAdapter([
        jsonResponse(200, {'access': 'a', 'refresh': 'b'}),
      ]);
      final store = MemoryTokenStore(
        session('first-token', DateTime.utc(2026, 9, 8, 12, 1)),
      );
      final termination = RecordingTerminationHandler();
      final client = testClient(adapter);
      final coordinator = TokenCoordinator(
        store: store,
        renewExchange: DioRenewTokenExchange(client),
        terminationHandler: termination,
        timeSource: FixedTimeSource(DateTime.utc(2026, 9, 8, 12)),
      );
      client.bindTokenCoordinator(coordinator);

      final result = await coordinator.accessToken(forceRefresh: true);

      expect(
        (result as FailureResult<AccessToken>).failure,
        isA<SecurityFailure>().having(
          (failure) => failure.kind,
          'kind',
          SecurityFailureKind.malformedServerResponse,
        ),
      );
      // A body this client cannot read is the server's fault, not a refused
      // token, so the live session survives it. Nothing but a logout, a
      // revocation or a deactivated account ends a token before its own
      // expiry.
      expect(store.current?.accessToken.value, 'first-token');
      expect(store.replacements, 0);
      expect(termination.reasons, isEmpty);
    });
  });
}

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

DioRestClient testClient(RecordingAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return DioRestClient(
    serverOrigin: Uri.parse('https://chat.example.test'),
    dio: dio,
  );
}

final class FixedTimeSource implements TimeSource {
  const FixedTimeSource(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

final class MemoryTokenStore implements SessionTokenStore {
  MemoryTokenStore(this.current);

  SessionTokens? current;
  int replacements = 0;

  @override
  Future<void> clear() async {
    current = null;
  }

  @override
  Future<SessionTokens?> read() async => current;

  @override
  Future<SessionTokens?> readDurable() async => current;

  @override
  Future<void> replace(SessionTokens tokens) async {
    current = tokens;
    replacements += 1;
  }
}

final class RecordingTerminationHandler implements SessionTerminationHandler {
  final List<SessionTerminationReason> reasons = [];

  @override
  Future<void> terminate(SessionTerminationReason reason) async {
    reasons.add(reason);
  }
}

SessionTokens session(String token, DateTime expiresAt) => SessionTokens(
  accessToken: AccessToken(
    value: token,
    expiresAt: expiresAt,
    scope: SessionScope.full,
  ),
);
