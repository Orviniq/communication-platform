// ignore_for_file: prefer_initializing_formals

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_transport.dart';
import 'package:communication_platform/features/networking/application/ports/realtime_gateway.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/infrastructure/api/dio_rest_client.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/dio_token_endpoints.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/token_coordinator.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/features/networking/infrastructure/realtime/dio_websocket_gateway.dart';
import 'package:communication_platform/features/networking/infrastructure/realtime/socket_connector.dart';
import 'package:communication_platform/features/networking/infrastructure/tls/transport_security_native.dart';
import 'package:communication_platform/features/server_config/application/server_config_snapshot.dart';
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
    required TransportSecurity transportSecurity,
  }) : _serverOrigin = serverOrigin,
       _socketConnector = socketConnector,
       _diagnostics = diagnostics,
       _transportSecurity = transportSecurity;

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
      transportSecurity: transportSecurity,
    );
  }

  final DioRestClient restClient;
  final TokenCoordinator tokenCoordinator;
  final Uri _serverOrigin;
  final SocketConnector _socketConnector;
  final NetworkDiagnostics _diagnostics;

  /// The trust the REST client was built with, kept for the transports that
  /// cannot share the REST client's `Dio`.
  final TransportSecurity _transportSecurity;

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
  /// [config] is the ceilings a frame is measured against, read per frame so a
  /// socket outlives the configuration read that corrects them.
  DioWebSocketGateway realtimeGateway(
    RealtimeReconnectHook reconnectHook, {
    required ServerConfigSnapshot config,
    Duration? keepAlive,
  }) => DioWebSocketGateway(
    serverOrigin: _serverOrigin,
    connector: _socketConnector,
    tokenCoordinator: tokenCoordinator,
    reconnectHook: reconnectHook,
    config: config,
    diagnostics: _diagnostics,
    keepAlive: keepAlive,
  );

  /// Builds the attachment transport for one session (ADR-089 D12).
  ///
  /// An attachment streams a multipart body up and a byte stream down, which
  /// the REST client's JSON-envelope path cannot carry, so it gets a `Dio` of
  /// its own: on the adapter of the same provisioned trust, on the same
  /// origin, following no redirect. It is not given its own tokens: it asks
  /// the one coordinator the whole application shares, so a renewal, a logout
  /// and a revocation decide its session with everything else's.
  ///
  /// Throws a [StateError] when this foundation holds the platform's default
  /// trust, which the client's own transport never uses (ADR-043): there is no
  /// attachment transport then rather than one that trusts the public root
  /// store. The transport owns its `Dio`, and closing it closes that.
  DioAttachmentTransport attachmentTransport({
    required ServerConfigSnapshot config,
    required AttachmentAllowancePort allowance,
    required TimeSource clock,
    required AttachmentStoragePort storage,
  }) {
    final adapter = _transportSecurity.httpClientAdapter;
    if (adapter == null) {
      throw StateError('Attachments need the provisioned trust.');
    }
    return DioAttachmentTransport(
      tokens: tokenCoordinator,
      config: config,
      allowance: allowance,
      clock: clock,
      storage: storage,
      dio: Dio(
        BaseOptions(
          baseUrl: _serverOrigin.toString(),
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
        ),
      )..httpClientAdapter = adapter,
    );
  }
}
