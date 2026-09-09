// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/message_delivery.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/networking_foundation.dart';
import 'package:communication_platform/core/application/ports/crypto_core_port.dart';
import 'package:communication_platform/core/application/ports/pairwise_crypto_port.dart';
import 'package:communication_platform/core/protocol/crypto_core_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/authentication_use_cases.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/infrastructure/coordinated_authentication_session.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/realtime/socket_connector.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:communication_platform/shared/infrastructure/time/system_time_source.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Composition-level proof that the delivery path exists in the application,
/// not merely in `lib/`.
///
/// Everything between the authentication state and the wire is the real thing:
/// the real [MessageDeliveryController], the real session composition, the real
/// `SyncLifecycleSupervisor`, `DurableSyncEngine`, `DriftSyncStore`,
/// `DioWebSocketGateway`, `TokenCoordinator` and `DioRestClient`, resolved
/// through the same providers `bootstrap` installs. Only four things are
/// substituted, and each is a genuine platform edge a host test cannot have: the
/// HTTP transport, the socket transport, the connectivity/lifecycle channels,
/// and the native crypto core.
void main() {
  test(
    'a full session composes the path, opens the socket, and drains authoritatively',
    () async {
      final harness = await DeliveryHarness.create();
      addTearDown(harness.dispose);

      expect(harness.stage, MessageDeliveryStage.idle);
      expect(harness.sockets.connections, isEmpty);

      await harness.signIn();

      expect(harness.stage, MessageDeliveryStage.running);
      expect(
        harness.sockets.connections,
        hasLength(1),
        reason: 'the composed application opens exactly one socket',
      );
      expect(
        harness.sockets.connections.single.uri.toString(),
        'wss://chat.example.test/ws',
      );
      expect(
        harness.http.pathsFor(RestMethodProbe.get),
        contains('/api/v1/me/envelopes'),
        reason: 'startup performs the authoritative REST drain',
      );
    },
  );

  test('the socket presents the token the shared coordinator owns', () async {
    final harness = await DeliveryHarness.create();
    addTearDown(harness.dispose);

    await harness.signIn();

    expect(
      harness.sockets.connections.single.accessToken,
      harness.tokens.current!.accessToken.value,
    );
    expect(
      harness.http.authorizationHeaders.toSet(),
      {'Bearer ${harness.tokens.current!.accessToken.value}'},
      reason:
          'one coordinator serves REST and the socket; a second one would '
          'rotate the refresh token behind the first',
    );
  });

  test(
    'a socket close 4003 revokes the one session the whole application shares',
    () async {
      final harness = await DeliveryHarness.create();
      addTearDown(harness.dispose);
      await harness.signIn();

      await harness.sockets.connections.single.serverClose(4003);
      await pumpEvents();

      expect(harness.termination.reasons, [SessionTerminationReason.revoked]);
      expect(
        harness.tokens.current,
        isNull,
        reason: 'the socket revocation cleared the shared token store',
      );
    },
  );

  test(
    'an outbox row queued while running is transmitted with no other stimulus',
    () async {
      final harness = await DeliveryHarness.create();
      addTearDown(harness.dispose);
      await harness.signIn();
      final drainsBefore = harness.http.pathsFor(RestMethodProbe.get).length;

      // Exactly what the messaging fan-out does when a user sends: durable
      // per-recipient ciphertext rows in `outbox_operations`, and nothing else.
      await harness.queueOutbox(operationId: 'operation-1', marker: 7);
      await pumpEvents();

      expect(
        harness.http.sends,
        hasLength(1),
        reason: 'the durable outbox row left the device',
      );
      expect(harness.http.sends.single.deviceIds, [
        DeliveryHarness.peerDeviceId,
      ]);
      expect(harness.http.sends.single.blobs.single, exactBlob(7));
      expect(
        await harness.outboxDepth(),
        0,
        reason: 'acceptance is recorded against the durable row',
      );
      expect(
        harness.http.pathsFor(RestMethodProbe.get).length,
        greaterThan(drainsBefore),
      );
    },
  );

  test('a row queued before the session existed is sent on startup', () async {
    final harness = await DeliveryHarness.create();
    addTearDown(harness.dispose);

    // The state a process death leaves behind: prepared ciphertext committed,
    // no engine alive to transmit it.
    await harness.queueOutbox(operationId: 'operation-before', marker: 11);
    expect(harness.http.sends, isEmpty);

    await harness.signIn();
    await pumpEvents();

    expect(harness.http.sends, hasLength(1));
    expect(harness.http.sends.single.blobs.single, exactBlob(11));
    expect(await harness.outboxDepth(), 0);
  });

  test(
    'a socket envelope frame is a hint: it drains over REST and its bytes are dropped',
    () async {
      final harness = await DeliveryHarness.create();
      addTearDown(harness.dispose);
      await harness.signIn();
      final drainsBefore = harness.http.pathsFor(RestMethodProbe.get).length;
      harness.http.enqueueDrain([
        (id: envelopeUuid(3), sequence: 3, blob: exactBlob(3)),
      ]);

      harness.sockets.connections.single.emitEnvelope(
        id: envelopeUuid(9),
        sequence: 9,
        blob: exactBlob(99),
      );
      await pumpEvents();

      expect(
        harness.http.pathsFor(RestMethodProbe.get).length,
        greaterThan(drainsBefore),
      );
      final stored = await harness.inboxEnvelopeIds();
      expect(
        stored,
        contains(envelopeUuid(3)),
        reason: 'what the REST drain returned is what was persisted',
      );
      expect(
        stored,
        isNot(contains(envelopeUuid(9))),
        reason: 'the socket payload is never treated as an envelope',
      );
    },
  );

  test(
    'a drained envelope is persisted, processed, and acknowledged after commit',
    () async {
      final harness = await DeliveryHarness.create();
      addTearDown(harness.dispose);
      harness.http.enqueueDrain([
        (id: envelopeUuid(21), sequence: 21, blob: exactBlob(21)),
      ]);

      await harness.signIn();
      await pumpEvents();

      expect(await harness.inboxEnvelopeIds(), contains(envelopeUuid(21)));
      expect(
        harness.http.acknowledgedIds,
        contains(envelopeUuid(21)),
        reason: 'acknowledgement follows the durable commit, never precedes it',
      );
      final projection = await harness.projection();
      expect(projection.lastSuccessfulSyncAt, isNotNull);
    },
  );

  test(
    'an envelope the device cannot process is kept, never acknowledged away',
    () async {
      final harness = await DeliveryHarness.create(
        core: FakeCoreBehaviour.unavailable,
      );
      addTearDown(harness.dispose);
      harness.http.enqueueDrain([
        (id: envelopeUuid(31), sequence: 31, blob: exactBlob(31)),
      ]);

      await harness.signIn();
      await pumpEvents();

      expect(await harness.inboxEnvelopeIds(), contains(envelopeUuid(31)));
      expect(
        harness.http.acknowledgedIds,
        isEmpty,
        reason:
            'acknowledgement deletes the server copy; an envelope that could '
            'not be processed must survive for a later attempt',
      );
      expect((await harness.projection()).inboxDepth, 1);
    },
  );

  test('logout stops the path and closes the socket', () async {
    final harness = await DeliveryHarness.create();
    addTearDown(harness.dispose);
    await harness.signIn();
    final connection = harness.sockets.connections.single;

    await harness.signOut();

    expect(harness.stage, MessageDeliveryStage.idle);
    expect(connection.closedByClient, isTrue);
    expect(harness.sockets.connections, hasLength(1));
  });

  test(
    'a session arms the deferred catch-up once, for its whole life',
    () async {
      final harness = await DeliveryHarness.create();
      addTearDown(harness.dispose);

      await harness.signIn();

      expect(
        harness.deferred.scheduled,
        [deferredCatchUpInterval],
        reason:
            'armed once when the session starts, at the platform floor, and not '
            'again on any lifecycle transition',
      );
      expect(harness.deferred.cancels, 0);

      // Every background and foreground transition the application will ever
      // make. A periodic platform job restarts its window each time it is
      // registered, so re-arming here would mean a user who opens the app more
      // often than the interval never receives a single wake-up.
      harness.lifecycleState = ApplicationExecutionState.background;
      await harness.settle();
      harness.lifecycleState = ApplicationExecutionState.foreground;
      await harness.settle();

      expect(harness.deferred.scheduled, hasLength(1));
      expect(harness.deferred.cancels, 0);
    },
  );

  test('logout disarms it, so nothing wakes for a signed-out device', () async {
    final harness = await DeliveryHarness.create();
    addTearDown(harness.dispose);
    await harness.signIn();

    await harness.signOut();

    expect(harness.deferred.cancels, 1);
  });

  test('a session waits for a catch-up that already owns delivery', () async {
    // What this proves, exactly: a *session* composes nothing while another
    // owner holds delivery. It does not prove that the application does
    // nothing, and an earlier version of this comment claimed it did — the
    // harness overrides `restore` with a fake session, so the real
    // `TokenCoordinator` never runs here, and in the composed application that
    // restore is itself a rotation of the shared refresh token and happens
    // before any session composes (ADR-050). The entry-point gate is asserted
    // in `test/architecture/background_delivery_policy_test.dart`, and real
    // contention over a real shared store in
    // `test/features/networking/delivery_owner_contention_test.dart`.
    final harness = await DeliveryHarness.create(holdOwnership: true);
    addTearDown(harness.dispose);

    unawaited(harness.signIn());
    await pumpEvents();

    expect(harness.deferred.ownershipWaits, 1);
    expect(
      harness.stage,
      MessageDeliveryStage.starting,
      reason: 'composition is held at the ownership question',
    );
    expect(
      harness.http.requests,
      isEmpty,
      reason:
          'this session issues nothing authenticated while another owner is '
          'running - which is a statement about the session, not about the '
          'application',
    );
    expect(harness.sockets.connections, isEmpty);

    harness.deferred.releaseOwnership();
    await harness.settle();
    await pumpEvents();

    expect(harness.stage, MessageDeliveryStage.running);
    expect(harness.sockets.connections, hasLength(1));
  });

  testWidgets('the application root is what instantiates the controller', (
    tester,
  ) async {
    final observer = RecordingObserver();
    final harness = await DeliveryHarness.create(
      attachContainer: false,
      observer: observer,
    );
    addTearDown(harness.dispose);

    // Deliberately parked on a route that has nothing to do with messaging.
    // Delivery is owned by the root, so which screen is on top must not decide
    // whether the application composes a delivery path.
    await tester.pumpWidget(
      harness.scope(
        const CommunicationPlatformApp(
          environment: AppEnvironment.production,
          locale: Locale('en'),
          authenticationEnabled: true,
          initialLocation: '/login',
        ),
      ),
    );

    expect(
      observer.initialized,
      contains(messageDeliveryControllerProvider),
      reason:
          'building the application root — before any test reads it — is what '
          'creates the delivery controller; if the root stops holding it, this '
          'is the assertion that fails',
    );
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(CommunicationPlatformApp)),
      ).read(messageDeliveryControllerProvider),
      MessageDeliveryStage.idle,
      reason: 'a signed-out application composes no session',
    );
    expect(harness.sockets.connections, isEmpty);
  });

  test('an unprovisioned build composes no delivery path at all', () async {
    final harness = await DeliveryHarness.create(installNetworking: false);
    addTearDown(harness.dispose);

    await harness.signIn();

    expect(harness.stage, MessageDeliveryStage.unavailable);
    expect(harness.sockets.connections, isEmpty);
    expect(
      harness.http.sends,
      isEmpty,
      reason: 'nothing is transmitted and nothing durable is discarded',
    );
    expect(await harness.outboxDepth(), 0);
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

typedef DrainEnvelope = ({String id, int sequence, Uint8List blob});

final class DeliveryHarness {
  DeliveryHarness._({
    required this.scope,
    required this.database,
    required this.http,
    required this.sockets,
    required this.tokens,
    required this.termination,
    required this.lifecycle,
    required this.platformPorts,
    ProviderContainer? container,
  }) : _owned = container,
       _container = container;

  static const userId = '11111111-1111-4111-8111-111111111111';
  static const deviceId = '22222222-2222-4222-8222-222222222222';
  static const peerDeviceId = '33333333-3333-4333-8333-333333333333';

  static Future<DeliveryHarness> create({
    bool installNetworking = true,
    bool attachContainer = true,
    bool holdOwnership = false,
    RecordingObserver? observer,
    FakeCoreBehaviour core = FakeCoreBehaviour.unauthenticated,
  }) async {
    final database = LocalDatabase(NativeDatabase.memory());
    final http = FakeBackend();
    final sockets = FakeSocketConnector();
    final tokens = InMemoryTokenStore();
    final termination = RecordingTermination();
    final lifecycle = AuthenticationLifecycleBus();
    final foundation = NetworkingFoundation.create(
      serverOrigin: Uri.parse('https://chat.example.test'),
      tokenStore: tokens,
      terminationHandler: termination,
      timeSource: const SystemTimeSource(),
      dio: Dio()..httpClientAdapter = http,
      socketConnector: sockets,
    );
    final session = FakeAuthenticationSession();
    final platformPorts = <FakeDeliveryPlatformPorts>[];
    final overrides = [
      appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
      localDatabaseProvider.overrideWith((ref) => Future.value(database)),
      cryptoCoreFactoryProvider.overrideWithValue(() => _FakeCore(core)),
      // The delivery path resolves its device from protected storage, which
      // is a Keystore-backed platform channel. The identity is fixed here so
      // the composition under test is the delivery path, not enrollment.
      currentMessagingDeviceIdProvider.overrideWith(
        (ref) => Future.value(deviceId),
      ),
      authenticationUseCasesProvider.overrideWithValue(
        AuthenticationUseCases(
          register: RegisterAccount(FakeAccountRepository()),
          login: LoginAccount(FakeAccountRepository(), session),
          restore: RestoreAccountSession(session),
          logout: LogoutAccount(session),
          erase: EraseAccount(FakeAccountRepository(), session),
          lifecycle: lifecycle,
        ),
      ),
      deliveryPlatformPortsProvider.overrideWithValue(() async {
        final ports = FakeDeliveryPlatformPorts(holdOwnership: holdOwnership);
        platformPorts.add(ports);
        return ports;
      }),
      if (installNetworking) ...[
        authenticatedRestClientProvider.overrideWithValue(
          foundation.restClient,
        ),
        networkingFoundationProvider.overrideWithValue(foundation),
      ],
    ];
    ProviderContainer? container;
    if (attachContainer) {
      container = ProviderContainer(overrides: overrides, retry: _noRetry);
      // What `CommunicationPlatformApp` does at the root: instantiate the
      // controller and hold it, without a widget deciding when it may run.
      container.listen(
        messageDeliveryControllerProvider,
        (previous, next) {},
        fireImmediately: true,
      );
    }
    return DeliveryHarness._(
      scope: (child) => ProviderScope(
        overrides: overrides,
        retry: _noRetry,
        observers: observer == null ? null : [observer],
        child: child,
      ),
      container: container,
      database: database,
      http: http,
      sockets: sockets,
      tokens: tokens,
      termination: termination,
      lifecycle: lifecycle,
      platformPorts: platformPorts,
    );
  }

  /// Wraps a widget in the same provider scope `bootstrap` would install.
  final Widget Function(Widget child) scope;
  final LocalDatabase database;
  final FakeBackend http;
  final FakeSocketConnector sockets;
  final InMemoryTokenStore tokens;
  final RecordingTermination termination;
  final AuthenticationLifecycleBus lifecycle;

  /// Every platform-edge bundle a session resolved, newest last. One per
  /// session, so a second entry means a second session was composed.
  final List<FakeDeliveryPlatformPorts> platformPorts;

  RecordingPolling get deferred => platformPorts.last.deferred;

  /// Reports a platform lifecycle transition to the running session.
  set lifecycleState(ApplicationExecutionState state) =>
      platformPorts.last.lifecycleControl.set(state);

  /// Lets every queued transition and cycle finish.
  Future<void> settle() async {
    await controller.settled;
    await pumpEvents();
    await controller.settled;
  }

  /// The container this harness created and must dispose, if any. A container
  /// belonging to a pumped `ProviderScope` is owned by the widget tree.
  final ProviderContainer? _owned;
  ProviderContainer? _container;

  /// The scope the delivery path was composed in — the harness's own, or the
  /// one the pumped application root created.
  ProviderContainer get container => _container!;

  set container(ProviderContainer value) => _container = value;

  MessageDeliveryStage get stage =>
      container.read(messageDeliveryControllerProvider);

  MessageDeliveryController get controller =>
      container.read(messageDeliveryControllerProvider.notifier);

  Future<void> signIn() async {
    tokens.install();
    await container.read(authenticationControllerProvider.notifier).restore();
    await controller.settled;
    await pumpEvents();
    await controller.settled;
    await pumpEvents();
  }

  Future<void> signOut() async {
    await container.read(authenticationControllerProvider.notifier).logout();
    await controller.settled;
    await pumpEvents();
  }

  Future<void> queueOutbox({
    required String operationId,
    required int marker,
  }) async {
    final store = DriftSyncStore(database);
    final result = await store.queuePreparedOperation(
      operationId: operationId,
      eventId: 'event-$operationId',
      targets: [
        PreparedOutboxTarget(
          recipientUserId: userId,
          recipientDeviceId: peerDeviceId,
          exactCiphertext: exactBlob(marker),
        ),
      ],
    );
    expect(result, isA<Success<void>>());
  }

  Future<int> outboxDepth() async => (await projection()).outboxDepth;

  Future<SyncProjection> projection() async {
    final result = await DriftSyncStore(database).readProjection();
    return (result as Success<SyncProjection>).value;
  }

  Future<List<String>> inboxEnvelopeIds() async {
    final rows = await database.select(database.inboxEnvelopes).get();
    return rows.map((row) => row.envelopeId).toList(growable: false);
  }

  Future<void> dispose() async {
    _owned?.dispose();
    // Microtask yields only: `Future.delayed` runs on the fake clock inside
    // `testWidgets`, and a tear-down cannot advance it.
    for (var index = 0; index < 32; index += 1) {
      await Future<void>.value();
    }
    await lifecycle.close();
    await database.close();
  }
}

// ---------------------------------------------------------------------------
// Platform edges
// ---------------------------------------------------------------------------

enum RestMethodProbe { get, post }

typedef SendProbe = ({List<String> deviceIds, List<Uint8List> blobs});

/// The backend as this test needs it: the two envelope endpoints and the ack.
final class FakeBackend implements HttpClientAdapter {
  final List<({RestMethodProbe method, String path})> requests = [];
  final List<String> authorizationHeaders = [];
  final List<SendProbe> sends = [];
  final List<String> acknowledgedIds = [];
  final List<List<DrainEnvelope>> _drains = [];

  void enqueueDrain(List<DrainEnvelope> envelopes) => _drains.add(envelopes);

  List<String> pathsFor(RestMethodProbe method) => requests
      .where((request) => request.method == method)
      .map((request) => request.path)
      .toList(growable: false);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final method = options.method == 'GET'
        ? RestMethodProbe.get
        : RestMethodProbe.post;
    requests.add((method: method, path: options.path));
    final authorization = options.headers['Authorization'];
    if (authorization is String) {
      authorizationHeaders.add(authorization);
    }
    switch (options.path) {
      case '/api/v1/me/envelopes':
        final page = _drains.isEmpty
            ? const <DrainEnvelope>[]
            : _drains.removeAt(0);
        return _json(200, {
          'envelopes': page
              .map(
                (envelope) => {
                  'id': envelope.id,
                  'seq': envelope.sequence,
                  'blob': base64Encode(envelope.blob),
                },
              )
              .toList(growable: false),
          'has_more': false,
          'pruned_through': 0,
        });
      case '/api/v1/me/envelopes/ack':
        final body = _body(options);
        final ids = (body['ids']! as List<Object?>).cast<String>();
        acknowledgedIds.addAll(ids);
        return _json(200, {'deleted': ids.length});
      case '/api/v1/envelopes':
        final body = _body(options);
        final messages = (body['messages']! as List<Object?>)
            .cast<Map<String, Object?>>();
        sends.add((
          deviceIds: messages
              .map((message) => message['device_id']! as String)
              .toList(growable: false),
          blobs: messages
              .map((message) => base64Decode(message['blob']! as String))
              .toList(growable: false),
        ));
        return _json(202, {
          'accepted': messages.length,
          'stale_devices': <Object?>[],
          'full_devices': <Object?>[],
        });
      default:
        return _json(404, {'code': 'not_found', 'detail': 'unrouted'});
    }
  }

  @override
  void close({bool force = false}) {}

  Map<String, Object?> _body(RequestOptions options) =>
      jsonDecode(options.data! as String) as Map<String, Object?>;

  ResponseBody _json(int status, Object body) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      'content-type': ['application/json'],
    },
  );
}

final class FakeSocketConnector implements SocketConnector {
  final List<FakeSocketConnection> connections = [];

  @override
  Future<SocketConnection> connect({
    required Uri uri,
    required String accessToken,
    required Duration timeout,
    Duration? keepAlive,
  }) async {
    final connection = FakeSocketConnection(uri: uri, accessToken: accessToken);
    connections.add(connection);
    return connection;
  }
}

final class FakeSocketConnection implements SocketConnection {
  FakeSocketConnection({required this.uri, required this.accessToken});

  final Uri uri;
  final String accessToken;
  final List<Object> sent = [];
  final StreamController<Object?> _frames = StreamController<Object?>();
  int? _closeCode;
  bool closedByClient = false;

  @override
  Stream<Object?> get messages => _frames.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void add(Object message) => sent.add(message);

  @override
  Future<void> close([int? code]) async {
    closedByClient = true;
    _closeCode ??= code;
    if (!_frames.isClosed) {
      await _frames.close();
    }
  }

  void emitEnvelope({
    required String id,
    required int sequence,
    required Uint8List blob,
  }) => _frames.add(
    jsonEncode({
      'type': 'envelope',
      'id': id,
      'seq': sequence,
      'blob': base64Encode(blob),
    }),
  );

  Future<void> serverClose(int code) async {
    _closeCode = code;
    if (!_frames.isClosed) {
      await _frames.close();
    }
  }
}

final class FakeDeliveryPlatformPorts implements DeliveryPlatformPorts {
  FakeDeliveryPlatformPorts({bool holdOwnership = false})
    : _polling = RecordingPolling(holdOwnership: holdOwnership);

  final FakeNetworkPort _network = FakeNetworkPort();
  final FakeLifecyclePort _lifecycle = FakeLifecyclePort();
  final RecordingPolling _polling;

  RecordingPolling get deferred => _polling;

  FakeLifecyclePort get lifecycleControl => _lifecycle;

  @override
  NetworkAvailabilityPort get network => _network;

  @override
  ApplicationLifecyclePort get lifecycle => _lifecycle;

  @override
  BestEffortPollingPort get polling => _polling;

  @override
  DelayPort get delay => const _ImmediateDelay();

  @override
  Future<void> dispose() async {
    await _network.dispose();
    await _lifecycle.dispose();
  }
}

final class FakeNetworkPort implements NetworkAvailabilityPort {
  final StreamController<NetworkAvailability> _changes =
      StreamController<NetworkAvailability>.broadcast();

  @override
  NetworkAvailability get current => NetworkAvailability.available;

  @override
  Stream<NetworkAvailability> get changes => _changes.stream;

  Future<void> dispose() => _changes.close();
}

final class FakeLifecyclePort implements ApplicationLifecyclePort {
  final StreamController<ApplicationExecutionState> _changes =
      StreamController<ApplicationExecutionState>.broadcast();
  ApplicationExecutionState _current = ApplicationExecutionState.foreground;

  @override
  ApplicationExecutionState get current => _current;

  @override
  Stream<ApplicationExecutionState> get changes => _changes.stream;

  void set(ApplicationExecutionState state) {
    if (_current == state) {
      return;
    }
    _current = state;
    _changes.add(state);
  }

  Future<void> dispose() => _changes.close();
}

/// No real timer, so a widget test never has one pending at teardown and a
/// container test never waits out reconnect backoff.
final class _ImmediateDelay implements DelayPort {
  const _ImmediateDelay();

  @override
  Future<void> wait(Duration delay) async {}
}

/// Records what the session asks of the deferred scheduler without a platform.
///
/// [holdOwnership] stands in for the one race this design has to survive: a
/// headless catch-up already in flight when the user opens the application.
final class RecordingPolling implements BestEffortPollingPort {
  RecordingPolling({bool holdOwnership = false})
    : _owned = holdOwnership ? Completer<void>() : null;

  final Completer<void>? _owned;
  final List<Duration> scheduled = [];
  int cancels = 0;
  int ownershipWaits = 0;

  void releaseOwnership() {
    if (_owned != null && !_owned.isCompleted) {
      _owned.complete();
    }
  }

  @override
  Stream<BestEffortDeliveryTick> get triggers =>
      const Stream<BestEffortDeliveryTick>.empty();

  @override
  Future<void> schedule({required Duration minimumInterval}) async =>
      scheduled.add(minimumInterval);

  @override
  Future<void> cancel() async => cancels += 1;

  @override
  Future<void> awaitExclusiveOwnership() async {
    ownershipWaits += 1;
    await _owned?.future;
  }
}

// ---------------------------------------------------------------------------
// Authentication doubles
// ---------------------------------------------------------------------------

final class InMemoryTokenStore implements SessionTokenStore {
  SessionTokens? current;

  void install() => current = SessionTokens(
    accessToken: AccessToken(
      value: 'access-token-value',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      scope: SessionScope.full,
    ),
    userId: DeliveryHarness.userId,
    deviceId: DeliveryHarness.deviceId,
  );

  @override
  Future<SessionTokens?> read() async => current;

  @override
  Future<SessionTokens?> readDurable() async => current;

  @override
  Future<void> replace(SessionTokens tokens) async => current = tokens;

  @override
  Future<void> clear() async => current = null;
}

final class RecordingTermination implements SessionTerminationHandler {
  final List<SessionTerminationReason> reasons = [];

  @override
  Future<void> terminate(SessionTerminationReason reason) async =>
      reasons.add(reason);
}

final class FakeAuthenticationSession implements AuthenticationSessionPort {
  @override
  Future<LoginHint> readLoginHint() async => const LoginHint();

  @override
  Future<Result<AccountSessionBoundary>> acceptLogin({
    required String username,
    required AccountSessionGrant grant,
    required bool replacedKnownDevice,
  }) => restore();

  @override
  Future<Result<AccountSessionBoundary>> restore() async =>
      const Result<AccountSessionBoundary>.success(
        AccountSessionBoundary(
          userId: DeliveryHarness.userId,
          deviceId: DeliveryHarness.deviceId,
          scope: AccountSessionScope.full,
          offline: false,
        ),
      );

  @override
  Future<void> logout() async {}

  @override
  Future<void> forgetErasedAccount() async {}
}

final class FakeAccountRepository implements AccountAuthenticationRepository {
  @override
  Future<Result<AccountRegistration>> register({
    required String username,
    required String password,
  }) async => throw UnimplementedError();

  @override
  Future<Result<AccountSessionGrant>> login({
    required String username,
    required String password,
    String? deviceId,
  }) async => throw UnimplementedError();

  @override
  Future<Result<void>> eraseAccount({required String password}) async =>
      throw UnimplementedError();
}

/// A crypto core that answers the one pairwise operation the inbox reaches,
/// and nothing else.
///
/// [FakeCoreBehaviour.unauthenticated] is a native core that ran and refused
/// the bytes, which is what a forged or corrupted envelope produces.
/// [FakeCoreBehaviour.unavailable] is a core that cannot perform the operation
/// at all. The two must lead to opposite acknowledgement behaviour.
enum FakeCoreBehaviour { unauthenticated, unavailable }

final class _FakeCore implements CryptoCorePort, PairwiseCryptoPort {
  _FakeCore(this.behaviour);

  final FakeCoreBehaviour behaviour;

  @override
  Future<Result<PairwiseCryptoResponse>> pairwiseOperation({
    required PairwiseCryptoOperation operation,
    required Uint8List payload,
  }) async => switch (behaviour) {
    FakeCoreBehaviour.unauthenticated => Result.success(
      PairwiseCryptoResponse(
        operation: operation,
        outcome: PairwiseCryptoOutcome.repairRequired,
        body: Uint8List(0),
      ),
    ),
    FakeCoreBehaviour.unavailable => const Result.failure(
      UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
    ),
  };

  @override
  Future<Result<CryptoCoreCapabilities>> capabilities() async => Result.success(
    CryptoCoreCapabilities(
      abiVersion: 1,
      featureBits: CryptoCoreProtocolV1.knownFeatureBits,
      maxInputBytes: 1048576,
      maxCborDepth: 32,
      maxCborItems: 4096,
    ),
  );

  @override
  Future<void> close() async {}

  @override
  Future<Result<void>> selfTest() async => const Result.success(null);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Records which providers a scope initialized, so a test can tell "the
/// application root created this" from "the test created it by reading it".
final class RecordingObserver extends ProviderObserver {
  final List<Object> initialized = [];

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    initialized.add(context.provider);
  }
}

/// Riverpod 3 retries a failing provider on a timer by default. This test is
/// about composition, not about that policy, and a scheduled retry outlives the
/// widget tree and fails the binding's timer invariant.
Duration? _noRetry(int retryCount, Object error) => null;

Uint8List exactBlob(int marker) =>
    Uint8List.fromList(List<int>.filled(1024, marker));

String envelopeUuid(int marker) {
  final tail = marker.toRadixString(16).padLeft(12, '0');
  return '44444444-4444-4444-8444-$tail';
}

Future<void> pumpEvents() async {
  for (var index = 0; index < 24; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
