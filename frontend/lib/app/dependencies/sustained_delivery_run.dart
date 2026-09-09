import 'dart:async';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/application_runtime.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/deferred_delivery_catch_up.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/message_alerts.dart';
import 'package:communication_platform/app/dependencies/message_delivery.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/dependencies/sync_providers.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/notifications/application/reconcile_message_alerts.dart';
import 'package:communication_platform/features/notifications/infrastructure/drift_message_alert_store.dart';
import 'package:communication_platform/features/synchronization/application/sync_lifecycle_supervisor.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sustained_delivery_store.dart';
import 'package:communication_platform/features/synchronization/infrastructure/gateway_realtime_sync_adapter.dart';
import 'package:communication_platform/features/synchronization/infrastructure/platform_deferred_delivery_scheduler.dart';
import 'package:communication_platform/features/synchronization/infrastructure/sustained_delivery_handshake.dart';
import 'package:communication_platform/features/synchronization/infrastructure/sync_platform_adapters.dart';
import 'package:communication_platform/shared/infrastructure/time/system_time_source.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What one sustained-delivery run concluded.
///
/// Every value is a fact about this run and none is a promise about the next
/// one. Three of them stop the service, and each of those is a state that is
/// stable until the user does something: the capability is off, there is
/// nobody to deliver to, or this build cannot deliver at all.
enum SustainedRunOutcome {
  /// Ran, held the connection, and gave way when a foreground engine attached
  /// or the service stopped.
  held,

  /// The durable choice says off. Nothing was composed and the service is asked
  /// to stop, because a service running for a capability nobody chose is a
  /// permanent entry displayed for nothing.
  notChosen,

  /// There is no device-bound session to deliver to. The service stops; signing
  /// in is what starts it again.
  noSession,

  /// Protected local state could not be opened, so nothing was read, nothing
  /// was written and nothing was announced.
  storageUnavailable,

  /// This build carries no provisioning, so it has no server to reach.
  unprovisioned,

  /// Composition failed. Durable state is whatever the last committed
  /// transaction left, and the deferred catch-up is what tries next.
  unavailable,
}

/// How often a held connection proves it is still alive.
///
/// Four minutes is a compromise between two costs that pull in opposite
/// directions. Shorter wakes the radio more often for no message; longer leaves
/// more room for a carrier's NAT to drop the connection silently, and a socket
/// that is dead and believed-good is precisely what a permanent "kept open"
/// notice must never be displayed over. `dart:io` closes the connection when a
/// ping goes unanswered for the same interval, so a dead connection is noticed
/// within eight minutes at worst and repaired by the supervisor's ordinary
/// reconnect — behind which the deferred catch-up is still the floor.
const sustainedKeepAlive = Duration(minutes: 4);

/// Whether an outcome means the foreground service should stop with the run.
///
/// A run that could not open storage is deliberately not in this set: a locked
/// or briefly unavailable database says nothing about the next attempt, and
/// stopping the service there would turn a transient condition into a
/// capability the user has to notice and re-enable.
bool sustainedRunStopsService(SustainedRunOutcome outcome) =>
    outcome == SustainedRunOutcome.notChosen ||
    outcome == SustainedRunOutcome.noSession ||
    outcome == SustainedRunOutcome.unprovisioned;

/// One sustained-delivery run: open protected state, hold the connection, tell
/// the user what arrives, and give way when somebody starts looking.
///
/// It is not a second delivery implementation. The engine, the store, the
/// inspector, the group stack, the socket and the alert reconciliation are the
/// same objects the foreground composes, resolved from the same
/// [ApplicationRuntime], so this path cannot drift away from that one or
/// quietly compose a weaker posture than it — no second token coordinator, no
/// second trust context, no crypto core without the compiled environment's
/// permit.
///
/// What it does differently is exactly one thing: it reports the application
/// lifecycle as *backgrounded* and the connection policy as *may hold*, because
/// the foreground service that started it is what keeps this process out of the
/// cached state. If that service is not running, this isolate does not exist.
Future<SustainedRunOutcome> runSustainedDelivery(
  AppEnvironment environment,
  SustainedDeliveryHandshake handshake,
) async {
  final runtime = await ApplicationRuntime.create(
    environment,
    platform: BootstrapPlatform.android,
  );
  if (runtime.authentication == null) {
    await runtime.close();
    return SustainedRunOutcome.unprovisioned;
  }
  final container = runtime.container(standDown: handshake);
  try {
    return await _hold(runtime, handshake, container);
  } on Object {
    // A headless entry point may never propagate. Anything that escaped the
    // paths below is reported as the one thing certainly true: this run is not
    // holding anything.
    return SustainedRunOutcome.unavailable;
  } finally {
    container.dispose();
    await runtime.close();
  }
}

Future<SustainedRunOutcome> _hold(
  ApplicationRuntime runtime,
  SustainedDeliveryHandshake handshake,
  ProviderContainer container,
) async {
  if (handshake.standDownRequested) {
    return SustainedRunOutcome.held;
  }
  // The durable choice is re-read before anything is composed, so a service the
  // platform restarted after a low-memory kill can never resurrect a capability
  // the user has since turned off.
  final database = await container.read(localDatabaseProvider.future);
  final chosen = await DriftSustainedDeliveryStore(database).readEnabled();
  switch (chosen) {
    case Success(value: false):
      return SustainedRunOutcome.notChosen;
    case FailureResult():
      return SustainedRunOutcome.storageUnavailable;
    case Success():
      break;
  }
  final restored = await runtime.authentication!.useCases.restore();
  final refusal = _refusal(restored);
  if (refusal != null) {
    return refusal;
  }
  final boundary = (restored as Success<AccountSessionBoundary>).value;
  final scope = (userId: boundary.userId, deviceId: boundary.deviceId!);
  if (handshake.standDownRequested) {
    return SustainedRunOutcome.held;
  }

  final scheduler = PlatformDeferredDeliveryScheduler();
  final network = await ConnectivityNetworkAvailabilityPort.create();
  final realtime = GatewayRealtimeSyncAdapter();
  final alerts = _SustainedAlertReconciler(container, database);
  SyncLifecycleSupervisor? supervisor;
  try {
    final store = await container.read(durableSyncStoreProvider.future);
    final engine = await container.read(
      durableSyncEngineProvider(scope).future,
    );
    realtime.attach(
      container
          .read(networkingFoundationProvider)
          .realtimeGateway(
            realtime,
            config: container.read(serverConfigSnapshotProvider),
            keepAlive: sustainedKeepAlive,
          ),
    );
    supervisor = SyncLifecycleSupervisor(
      engine: engine,
      store: store,
      realtime: realtime,
      network: network,
      // Truthfully backgrounded, and permitted to hold anyway. Those are two
      // separate facts and this is the only composition in the application
      // where they differ.
      lifecycle: const BackgroundedExecution(),
      backgroundConnection: const AlwaysHoldsInBackground(),
      // The deferred catch-up stays armed while this runs and its ticks are
      // delivered here, because a socket that has died silently is exactly what
      // a periodic wake-up is a floor for. Nothing here schedules or cancels
      // it: that belongs to whoever owns the signed-in session.
      polling: AndroidBestEffortPollingPort(scheduler),
      clock: container.read(timeSourceProvider),
      jitter: FullJitterSource(),
      delay: const TimerDelayPort(),
    );
    await supervisor.start();
    alerts.start();
    // Ends when a foreground engine attaches, when the service stops, or when
    // the session this is delivering to ends. Never on a timer: the whole point
    // of this run is that it lasts.
    //
    // Which of those happened decides whether the *service* ends with the run.
    // A displaced run hands delivery to a foreground the user is looking at and
    // the service goes on keeping this process alive for when they leave again;
    // a run whose session ended has nothing left to deliver to, and a permanent
    // entry for an account nobody is signed into announces the account rather
    // than a message.
    final terminated = Completer<void>();
    final terminations = runtime.authentication!.lifecycle.terminations.listen((
      _,
    ) {
      if (!terminated.isCompleted) {
        terminated.complete();
      }
    });
    try {
      await Future.any<void>([handshake.displaced, terminated.future]);
    } finally {
      await terminations.cancel();
    }
    return terminated.isCompleted
        ? SustainedRunOutcome.noSession
        : SustainedRunOutcome.held;
  } finally {
    await alerts.dispose();
    await supervisor?.dispose();
    await realtime.dispose();
    await network.dispose();
    await scheduler.dispose();
  }
}

/// What a restored session means for a sustained run, before it holds anything.
///
/// Null means the run may proceed. Every decision is here, in one pure
/// function, so all of them are decided by a host test rather than by a device
/// nobody has. None of them degrades: a run that cannot establish a full,
/// device-bound, set-up session holds nothing rather than reaching for a weaker
/// path.
SustainedRunOutcome? _refusal(Result<AccountSessionBoundary> restored) {
  final AccountSessionBoundary boundary;
  switch (restored) {
    case Success(value: final value):
      boundary = value;
    case FailureResult(failure: final failure):
      return switch (failure) {
        StorageFailure() => SustainedRunOutcome.storageUnavailable,
        // A server that could not be reached is not a reason to give up the
        // process: the supervisor reconnects when the network returns, which is
        // the entire reason this run is allowed to last.
        TransportFailure() => null,
        _ => SustainedRunOutcome.noSession,
      };
  }
  if (boundary.scope != AccountSessionScope.full ||
      !boundary.securitySetupComplete ||
      boundary.deviceId == null) {
    return SustainedRunOutcome.noSession;
  }
  return null;
}

/// Keeps the shade in agreement with committed local state for the life of a
/// sustained run.
///
/// The same reconciliation the foreground and the deferred catch-up use, driven
/// by the same durable signal. It reports no visible conversation and no
/// foreground, which is true and which is also what keeps this run from
/// spending the one automatic notification prompt in a context with no activity
/// to show it in.
final class _SustainedAlertReconciler {
  _SustainedAlertReconciler(this._container, this._database);

  final ProviderContainer _container;
  final LocalDatabase _database;
  StreamSubscription<void>? _changes;
  Future<void> _passes = Future<void>.value();
  bool _posted = true;
  bool _stopped = false;

  void start() {
    final store = DriftMessageAlertStore(_database);
    _changes = store.changes.listen((_) => _schedule(store));
    _schedule(store);
  }

  void _schedule(DriftMessageAlertStore store) {
    _passes = _passes.then((_) async {
      if (_stopped) {
        return;
      }
      try {
        final outcome = await ReconcileMessageAlerts(
          store: store,
          presenter: _container.read(messageAlertPresenterProvider),
          visible: const BackgroundVisibleConversation(),
          clock: const SystemTimeSource(),
        ).call(alertPosted: _posted);
        if (outcome.shown) {
          _posted = true;
        } else if (outcome.hidden) {
          _posted = false;
        }
      } on Object {
        // Alerting is the least important thing this run does, and a failure
        // spends no durable marker, so the next pass reaches the same
        // conclusion.
      }
    });
  }

  Future<void> dispose() async {
    _stopped = true;
    await _changes?.cancel();
    _changes = null;
    await _passes;
  }
}

/// Runs one sustained delivery isolate and reports to the platform when it ends.
///
/// This is what the foreground service's headless Dart entry point calls, and
/// it is deliberately the only thing that reports completion: the platform keeps
/// the engine hosting this isolate alive until it does.
Future<SustainedRunOutcome> runSustainedDeliveryEntryPoint(
  AppEnvironment environment, {
  SustainedDeliveryHandshake? handshake,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final channel = handshake ?? SustainedDeliveryHandshake();
  // Before any work begins, so that a foreground engine attaching one
  // millisecond later is heard rather than missed.
  channel.listen();
  var outcome = SustainedRunOutcome.unavailable;
  try {
    outcome = await runSustainedDelivery(environment, channel);
    return outcome;
  } finally {
    channel.release();
    if (sustainedRunStopsService(outcome)) {
      await channel.stopService();
    }
    await channel.reportFinished();
  }
}
