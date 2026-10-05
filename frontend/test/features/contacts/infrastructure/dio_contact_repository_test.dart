import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/infrastructure/dio_contact_repository.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fetchPeerStates', () {
    test('names every peer with the tag it holds, in one call', () async {
      final adapter = _QueueAdapter([
        _jsonResponse(200, {
          'peers': [
            {'user_id': _user(1), 'etag': '"held"', 'unchanged': true},
            {
              'user_id': _user(2),
              'etag': '"new"',
              'identity': null,
              'devices': <Object?>[],
              'log_head_seq': null,
            },
          ],
        }),
      ]);

      final result = await _repository(adapter).fetchPeerStates([
        PeerStateQuery(userId: _user(1), etag: '"held"'),
        PeerStateQuery(userId: _user(2)),
        PeerStateQuery(userId: _user(3)),
      ]);

      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/v1/peers');
      // A peer this client holds no tag for is sent without one.
      expect(_body(request), {
        'peers': [
          {'user_id': _user(1), 'etag': '"held"'},
          {'user_id': _user(2)},
          {'user_id': _user(3)},
        ],
      });
      final peers = (result as Success<Map<String, PeerStateRead>>).value;
      expect(peers[_user(1)], isA<PeerStateUnchanged>());
      expect(peers[_user(2)], isA<PeerStateUpdated>());
      expect(peers[_user(3)], isA<PeerStateAbsent>());
    });

    test('a larger fan-out is several calls of at most 64', () async {
      final adapter = _QueueAdapter([
        _jsonResponse(200, {'peers': <Object?>[]}),
        _jsonResponse(200, {'peers': <Object?>[]}),
      ]);

      final result = await _repository(adapter).fetchPeerStates([
        for (var index = 1; index <= 65; index += 1)
          PeerStateQuery(userId: _user(index)),
      ]);

      expect(adapter.requests.map((request) => _peersIn(request).length), [
        64,
        1,
      ]);
      expect(_peersIn(adapter.requests.last).single, {'user_id': _user(65)});
      final peers = (result as Success<Map<String, PeerStateRead>>).value;
      expect(peers, hasLength(65));
      expect(peers.values, everyElement(isA<PeerStateAbsent>()));
    });

    test(
      'a lost answer is asked for again, because the read is safe',
      () async {
        final adapter = _QueueAdapter([
          _jsonResponse(503, {'code': 'unavailable', 'detail': 'Busy.'}),
          _jsonResponse(200, {'peers': <Object?>[]}),
        ]);

        final result = await _repository(
          adapter,
        ).fetchPeerStates([PeerStateQuery(userId: _user(1))]);

        expect(result, isA<Success<Map<String, PeerStateRead>>>());
        expect(adapter.requests, hasLength(2));
      },
    );

    test('a repeated peer is refused before anything is sent', () async {
      final adapter = _QueueAdapter([]);

      final result = await _repository(adapter).fetchPeerStates([
        PeerStateQuery(userId: _user(10)),
        PeerStateQuery(userId: _user(10).toUpperCase()),
      ]);

      expect(
        (result as FailureResult<Map<String, PeerStateRead>>).failure,
        const ValidationFailure(ValidationFailureKind.invalidInput),
      );
      expect(adapter.requests, isEmpty);
    });

    test('an answer about a peer it did not name is refused whole', () async {
      final adapter = _QueueAdapter([
        _jsonResponse(200, {
          'peers': [
            {'user_id': _user(9), 'etag': '"x"', 'unchanged': true},
          ],
        }),
      ]);

      final result = await _repository(
        adapter,
      ).fetchPeerStates([PeerStateQuery(userId: _user(1), etag: '"x"')]);

      expect(
        (result as FailureResult<Map<String, PeerStateRead>>).failure,
        const SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    });
  });
}

String _user(int number) =>
    '00000000-0000-4000-8000-${number.toRadixString(16).padLeft(12, '0')}';

DioContactRepository _repository(_QueueAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  final client = DioRestClient(
    serverOrigin: Uri.parse('https://chat.example.test'),
    dio: dio,
  )..bindTokenCoordinator(const _TokenCoordinator());
  return DioContactRepository(client, const FixedServerConfig.fallback());
}

Map<String, Object?> _body(RequestOptions request) =>
    jsonDecode(request.data as String) as Map<String, Object?>;

List<Object?> _peersIn(RequestOptions request) =>
    _body(request)['peers']! as List<Object?>;

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
