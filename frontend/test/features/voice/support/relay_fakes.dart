import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/voice/application/ports/relay_credential_ports.dart';
import 'package:dio/dio.dart';

/// The user name and password every voice test answers with, and hunts for in
/// anything that could reach a log. Shaped like the route's own example: an
/// expiry, a colon and sixteen random bytes; and base64 of a SHA-1 HMAC.
const relayUsername = '1757352000:qkT2wR1mVbA4cJ7fKpN0Zg==';
const relayPassword = 'b0Zk9Qd4rXm2sT1uV7wY8aB3cD0=';

/// One URL for each transport, as the example deployment names them.
const relayUrls = [
  'turn:chat.orviniq.com:3478?transport=udp',
  'turn:chat.orviniq.com:3478?transport=tcp',
];

/// A `RelayCredentialOut` body with every field, the default lifetime.
Map<String, Object?> relayBody({int expiresIn = 21600}) => <String, Object?>{
  'urls': relayUrls,
  'username': relayUsername,
  'credential': relayPassword,
  'expires_in': expiresIn,
};

typedef RelayHandler = Future<ResponseBody> Function(RequestOptions options);

/// Answers requests in order, and records every one it was sent.
final class RelayAdapter implements HttpClientAdapter {
  RelayAdapter(List<RelayHandler> handlers) : _handlers = List.of(handlers);

  final List<RelayHandler> _handlers;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    if (_handlers.isEmpty) {
      throw StateError('No answer is queued for request ${requests.length}.');
    }
    return _handlers.removeAt(0)(options);
  }

  @override
  void close({bool force = false}) {}
}

RelayHandler relayJson(
  int status,
  Object? body, {
  Map<String, List<String>> headers = const {},
}) =>
    (options) async => ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      status,
      headers: {
        'content-type': ['application/json'],
        ...headers,
      },
    );

RelayHandler relayTimeout() =>
    (options) async => throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionTimeout,
    );

/// The reviewed client, on [adapter], signed in at full scope, replaying at
/// once instead of after its 100 ms.
DioRestClient relayRestClient(
  RelayAdapter adapter, {
  NetworkDiagnostics diagnostics = const NoopNetworkDiagnostics(),
}) => DioRestClient(
  serverOrigin: Uri.parse('https://chat.example.test'),
  dio: Dio()..httpClientAdapter = adapter,
  diagnostics: diagnostics,
  retryScheduler: const ImmediateRetries(),
)..bindTokenCoordinator(const FullScopeTokens());

final class ImmediateRetries implements RetryScheduler {
  const ImmediateRetries();

  @override
  Future<void> wait(Duration delay) async {}
}

final class FullScopeTokens implements AccessTokenCoordinator {
  const FullScopeTokens();

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

/// A clock a test moves by hand.
final class MutableClock implements TimeSource {
  MutableClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;

  void advance(Duration by) => current = current.add(by);
}

final class FixedVoiceDeployment implements VoiceDeploymentPort {
  const FixedVoiceDeployment({required this.voiceConfigured});

  @override
  final bool voiceConfigured;
}

final class CapturingDiagnostics implements NetworkDiagnostics {
  final events = <NetworkDiagnosticEvent>[];

  @override
  void record(NetworkDiagnosticEvent event) => events.add(event);
}
