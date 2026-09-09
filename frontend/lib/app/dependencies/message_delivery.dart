// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/networking_foundation.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/dependencies/sustained_delivery.dart';
import 'package:communication_platform/app/dependencies/sync_providers.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/application/sync_lifecycle_supervisor.dart';
import 'package:communication_platform/features/synchronization/infrastructure/gateway_realtime_sync_adapter.dart';
import 'package:communication_platform/features/synchronization/infrastructure/platform_deferred_delivery_scheduler.dart';
import 'package:communication_platform/features/synchronization/infrastructure/sync_platform_adapters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The one networking foundation, installed by `bootstrap` from the same
/// assembly that owns the REST client every other feature already uses.
///
/// It is an override rather than a constructed default so that a build with no
/// provisioned configuration composes no transport at all, instead of silently
/// falling back to one that trusts the public root store.
final networkingFoundationProvider = Provider<NetworkingFoundation>(
  (ref) => throw StateError('Networking foundation is not installed.'),
);

typedef DeliveryPlatformPortsFactory = Future<DeliveryPlatformPorts> Function();

/// The interval a session asks the platform for.
///
/// It is the documented floor and not a promise: `JobInfo.getMinPeriodMillis()`
/// is fifteen minutes and a shorter request is silently raised to it, while
/// Doze, the app standby buckets and the Android 16 job quota all defer even
/// that. Asking for the floor is asking for the best the platform allows; what
/// the user is told is what the platform guarantees, which is less.
const deferredCatchUpInterval = Duration(minutes: 15);

/// How a delivery session reaches connectivity, the application lifecycle and
/// the deferred scheduler. Overridden by tests, which have neither a platform
/// channel nor a device.
final deliveryPlatformPortsProvider = Provider<DeliveryPlatformPortsFactory>(
  (ref) => () {
    // Only the Android artifact has a deferred scheduler behind it. Every other
    // target composes no scheduler at all rather than one that would look armed
    // and never fire.
    final scheduler = defaultTargetPlatform == TargetPlatform.android
        ? PlatformDeferredDeliveryScheduler()
        : null;
    return FlutterDeliveryPlatformPorts.create(
      scheduler: scheduler,
      releaseScheduler: scheduler?.dispose,
    );
  },
);

/// What the composed delivery path is doing, as application state.
enum MessageDeliveryStage {
  /// No session is signed in far enough to deliver, or one has just stopped.
  idle,

  /// Dependencies are being resolved for a signed-in device.
  starting,

  /// The supervisor is running: it owns the socket, reacts to lifecycle,
  /// network and durable-queue transitions, and drives the engine.
  running,

  /// The path could not be composed for this session. Nothing is delivered and
  /// nothing pretends otherwise; durable state is untouched and a later
  /// session start tries again.
  unavailable,
}

/// One running delivery session: the socket, the engine, and the supervisor
/// that owns both, for exactly one signed-in device.
///
/// The engine, the store and the inspector come from `sync_providers.dart`
/// unchanged — this adds no second implementation of any of them. What it adds
/// is the wiring that was missing: the socket is built from the application's
/// one token coordinator, the realtime adapter is attached to it, the platform
/// edges are resolved, and the supervisor is handed all of them and started.
final class MessageDeliverySession {
  MessageDeliverySession._({
    required SyncLifecycleSupervisor supervisor,
    required GatewayRealtimeSyncAdapter realtime,
    required DeliveryPlatformPorts platform,
  }) : _supervisor = supervisor,
       _realtime = realtime,
       _platform = platform;

  static Future<MessageDeliverySession> compose(
    Ref ref, {
    required PairwiseSyncScope scope,
  }) async {
    final platform = await ref.read(deliveryPlatformPortsProvider)();
    final realtime = GatewayRealtimeSyncAdapter();
    try {
      // Before anything is opened, and before any token is read: a deferred
      // catch-up the platform started a moment ago is a second delivery owner
      // in this process, and two owners hold two token coordinators against one
      // rotating refresh token. This waits for it instead of racing it, and
      // returns immediately in the ordinary case where nothing is running.
      await platform.polling.awaitExclusiveOwnership();
      final store = await ref.read(durableSyncStoreProvider.future);
      final engine = await ref.read(durableSyncEngineProvider(scope).future);
      // The gateway comes from the shared foundation, so this socket presents
      // the same access token, refreshes through the same single-flight
      // coordinator, and terminates its TLS chain at the same provisioned
      // authority as every REST call the application makes.
      realtime.attach(
        ref
            .read(networkingFoundationProvider)
            .realtimeGateway(
              realtime,
              config: ref.read(serverConfigSnapshotProvider),
            ),
      );
      return MessageDeliverySession._(
        realtime: realtime,
        platform: platform,
        supervisor: SyncLifecycleSupervisor(
          engine: engine,
          store: store,
          realtime: realtime,
          network: platform.network,
          lifecycle: platform.lifecycle,
          // Whether this socket may outlive the foreground. It answers *no*
          // for every application that has not turned sustained delivery on,
          // which is every application until somebody does, and it is read
          // from above the session so that a session composed after the user
          // made that choice sees it and one composed before is woken by it.
          backgroundConnection: ref.read(sustainedConnectionPolicyProvider),
          polling: platform.polling,
          clock: ref.read(timeSourceProvider),
          jitter: FullJitterSource(),
          delay: platform.delay,
        ),
      );
    } on Object {
      await realtime.dispose();
      await platform.dispose();
      rethrow;
    }
  }

  final SyncLifecycleSupervisor _supervisor;
  final GatewayRealtimeSyncAdapter _realtime;
  final DeliveryPlatformPorts _platform;

  /// Starts the supervisor and arms the deferred catch-up for the whole
  /// session.
  ///
  /// Arming is a property of being signed in, not of being backgrounded. A
  /// periodic platform job restarts its window every time it is registered, so
  /// arming on each background transition would mean a user who opens the
  /// application more often than the interval never receives one wake-up, and a
  /// process that dies while foregrounded would leave nothing scheduled at all.
  Future<void> start() async {
    await _supervisor.start();
    await _platform.polling.schedule(minimumInterval: deferredCatchUpInterval);
  }

  /// Stops the session, and disarms the deferred catch-up with it.
  ///
  /// A session stops because there is no longer a signed-in device to deliver
  /// to, so leaving the job armed would wake the process every interval to
  /// discover exactly that.
  Future<void> dispose() async {
    await _supervisor.dispose();
    // Before the platform ports are released, because releasing them takes the
    // channel handler with them.
    try {
      await _platform.polling.cancel();
    } on Object {
      // The job outliving a session costs one wasted wake-up, which the
      // headless entry point then disarms for itself. Failing to stop is never
      // a reason to leave the rest of the session running.
    }
    await _realtime.dispose();
    await _platform.dispose();
  }
}

/// Starts and stops the delivery path across the session lifecycle.
///
/// Ownership sits here, above every screen, because delivery is not a property
/// of any screen: a supervisor bound to a route would stop when the route was
/// popped, and one bound to a `ref.watch` in a widget would be *paused* by
/// Riverpod whenever that widget left the view. The application root keeps this
/// alive through `listenManual`, whose subscriptions are not ticker-mode
/// managed, so the only thing that starts and stops a session is the session
/// itself.
///
/// Exactly one session runs at a time. Transitions are serialized onto one
/// future chain so a stop that arrives while a start is still resolving cannot
/// interleave with it, and the started scope is re-checked after every await:
/// two supervisors would mean two sockets, and two engines racing the same
/// durable queue.
final messageDeliveryControllerProvider =
    NotifierProvider<MessageDeliveryController, MessageDeliveryStage>(
      MessageDeliveryController.new,
    );

final class MessageDeliveryController extends Notifier<MessageDeliveryStage> {
  Future<void> _transitions = Future<void>.value();
  MessageDeliverySession? _session;
  String? _wantedUserId;
  String? _startedUserId;
  bool _closed = false;

  /// The transition queue, so a test can await composition instead of pumping
  /// for it.
  @visibleForTesting
  Future<void> get settled => _transitions;

  @override
  MessageDeliveryStage build() {
    ref.onDispose(() {
      _closed = true;
      final session = _session;
      _session = null;
      _wantedUserId = null;
      if (session != null) {
        unawaited(session.dispose());
      }
    });
    ref.listen(
      authenticationControllerProvider,
      (previous, next) => _enqueue(next),
      fireImmediately: true,
    );
    return MessageDeliveryStage.idle;
  }

  void _enqueue(AuthenticationViewState view) {
    final userId = _deliverableUserId(view);
    _wantedUserId = userId;
    _transitions = _transitions.then((_) => _apply(userId));
  }

  /// Delivery requires a device-bound full session, and stops the moment a
  /// teardown *begins* — a logout, or the account erasing itself.
  ///
  /// Stopping on the intent rather than on the completed termination matters:
  /// `TokenCoordinator.logout` wipes protected storage and closes the database
  /// before it emits the termination this controller would otherwise wait for,
  /// so waiting would leave the engine running transactions against storage
  /// that is being erased. An erasure reaches the same wipe by a shorter road,
  /// skipping only the `POST /auth/logout` a logout sends first. A revocation
  /// the server initiates has no such warning; there the engine's storage
  /// failures and the immediate signed-out transition are what stop it.
  String? _deliverableUserId(AuthenticationViewState view) {
    if (view.isTearingDown) {
      return null;
    }
    return switch (view.access) {
      AuthenticationRouteAccess.fullScope ||
      AuthenticationRouteAccess.offlineFullScope => view.userId,
      _ => null,
    };
  }

  Future<void> _apply(String? userId) async {
    if (_closed) {
      return;
    }
    if (userId == null) {
      await _stop();
      return;
    }
    if (_session != null && _startedUserId == userId) {
      return;
    }
    await _stop();
    await _start(userId);
  }

  Future<void> _start(String userId) async {
    _setStage(MessageDeliveryStage.starting);
    MessageDeliverySession? session;
    try {
      final deviceId = await ref.read(currentMessagingDeviceIdProvider.future);
      session = await MessageDeliverySession.compose(
        ref,
        scope: (userId: userId, deviceId: deviceId),
      );
      if (_closed || _wantedUserId != userId) {
        await session.dispose();
        return;
      }
      _session = session;
      _startedUserId = userId;
      await session.start();
      _setStage(MessageDeliveryStage.running);
    } on Object {
      // Composition failed — most plausibly because protected storage is
      // unavailable. Nothing durable is lost and nothing is claimed: queued
      // work stays in Drift for the next session that composes successfully.
      if (identical(_session, session)) {
        _session = null;
        _startedUserId = null;
      }
      await session?.dispose();
      _setStage(MessageDeliveryStage.unavailable);
    }
  }

  Future<void> _stop() async {
    final session = _session;
    _session = null;
    _startedUserId = null;
    if (session != null) {
      await session.dispose();
    }
    _setStage(MessageDeliveryStage.idle);
  }

  void _setStage(MessageDeliveryStage stage) {
    if (!_closed) {
      state = stage;
    }
  }
}
