// ignore_for_file: prefer_initializing_formals

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/features/networking/application/ports/realtime_gateway.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/dio_token_endpoints.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/token_coordinator.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/networking/infrastructure/realtime/dio_websocket_gateway.dart';
import 'package:communication_platform/features/networking/infrastructure/realtime/socket_connector.dart';
import 'package:communication_platform/features/networking/infrastructure/tls/transport_security_native.dart';
import 'package:dio/dio.dart';

/// Scope-owned composition for the single reviewed REST client, the single
/// token coordinator, and the socket origin they share.
///
/// Exactly one of these exists per running application, and
/// `AuthenticationAssembly` is what builds it. One client is what keeps every
/// request on the provisioned trust and inside the same reviewed transport,
/// and one coordinator is what keeps a renewal, a logout and a revocation
/// deciding the session together rather than three at a time. The socket is
/// therefore not given its own client or its own coordinator; it is built from
/// this one by [realtimeGateway].
final class NetworkingFoundation {
  NetworkingFoundation._({
    required this.restClient,
    required this.tokenCoordinator,
    required Uri serverOrigin,
    required SocketConnector socketConnector,
    required NetworkDiagnostics diagnostics,
  }) : _serverOrigin = serverOrigin,
       _socketConnector = socketConnector,
       _diagnostics = diagnostics;

  factory NetworkingFoundation.create({
    required Uri serverOrigin,
    required SessionTokenStore tokenStore,
    required SessionTerminationHandler terminationHandler,
    required TimeSource timeSource,
    Dio? dio,
    SocketConnector? socketConnector,
    TransportSecurity transportSecurity =
        const TransportSecurity.platformDefault(),
    NetworkDiagnostics diagnostics = const NoopNetworkDiagnostics(),
    RetryScheduler retryScheduler = const TimerRetryScheduler(),
  }) {
    final restClient = DioRestClient(
      serverOrigin: serverOrigin,
      dio: dio,
      transportSecurity: transportSecurity,
      diagnostics: diagnostics,
      retryScheduler: retryScheduler,
    );
    final tokenCoordinator = TokenCoordinator(
      store: tokenStore,
      renewExchange: DioRenewTokenExchange(restClient),
      logoutExchange: DioLogoutTokenExchange(restClient),
      terminationHandler: terminationHandler,
      timeSource: timeSource,
    );
    restClient.bindTokenCoordinator(tokenCoordinator);
    return NetworkingFoundation._(
      restClient: restClient,
      tokenCoordinator: tokenCoordinator,
      serverOrigin: serverOrigin,
      // Resolved once, from the same trust the REST client was built with, so
      // the socket can never terminate its chain at an authority the REST
      // client would refuse.
      socketConnector: socketConnector ?? transportSecurity.socketConnector,
      diagnostics: diagnostics,
    );
  }

  final DioRestClient restClient;
  final TokenCoordinator tokenCoordinator;
  final Uri _serverOrigin;
  final SocketConnector _socketConnector;
  final NetworkDiagnostics _diagnostics;

  /// Builds the authenticated gateway for one delivery session.
  ///
  /// The gateway is deliberately per-session rather than per-application: it
  /// holds one connection and one close-code recovery budget, and a delivery
  /// session that has stopped must not leave either behind. What it does *not*
  /// own is the coordinator: it recovers through the one the whole application
  /// shares, so a socket revocation terminates the REST session too.
  ///
  /// [keepAlive] is supplied only by a session that holds this connection
  /// while nobody is looking at the application, and is null for every other
  /// caller. See [DioWebSocketGateway.keepAlive].
  DioWebSocketGateway realtimeGateway(
    RealtimeReconnectHook reconnectHook, {
    Duration? keepAlive,
  }) => DioWebSocketGateway(
    serverOrigin: _serverOrigin,
    connector: _socketConnector,
    tokenCoordinator: tokenCoordinator,
    reconnectHook: reconnectHook,
    diagnostics: _diagnostics,
    keepAlive: keepAlive,
  );
}
