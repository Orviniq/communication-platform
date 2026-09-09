// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/synchronization/application/durable_sync_engine.dart';
import 'package:communication_platform/features/synchronization/application/ports/sustained_delivery_ports.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';

final class SyncLifecycleSupervisor {
  SyncLifecycleSupervisor({
    required DurableSyncEngine engine,
    required DurableSyncStore store,
    required RealtimeSyncPort realtime,
    required NetworkAvailabilityPort network,
    required ApplicationLifecyclePort lifecycle,
    required BestEffortPollingPort polling,
    required TimeSource clock,
    required JitterSource jitter,
    required DelayPort delay,
    BackgroundConnectionPolicy backgroundConnection =
        const NeverHoldsInBackground(),
    this.reconnectPolicy = const SyncRetryPolicy(
      baseDelay: Duration(seconds: 1),
      maximumDelay: Duration(minutes: 5),
    ),
    this.stableConnectionThreshold = const Duration(seconds: 30),
  }) : _engine = engine,
       _store = store,
       _realtime = realtime,
       _network = network,
       _lifecycle = lifecycle,
       _polling = polling,
       _clock = clock,
       _jitter = jitter,
       _delay = delay,
       _backgroundConnection = backgroundConnection;

  final DurableSyncEngine _engine;
  final DurableSyncStore _store;
  final RealtimeSyncPort _realtime;
  final NetworkAvailabilityPort _network;
  final ApplicationLifecyclePort _lifecycle;
  final BestEffortPollingPort _polling;
  final TimeSource _clock;
  final JitterSource _jitter;
  final DelayPort _delay;

  /// Whether the connection may outlive the foreground.
  ///
  /// It is a port and not a flag because the answer changes underneath a
  /// running session: the user turns sustained delivery on or off, or the
  /// platform withdraws what makes it possible, and either has to reach a
  /// supervisor that is already backgrounded and would otherwise never
  /// re-evaluate.
  final BackgroundConnectionPolicy _backgroundConnection;
  final SyncRetryPolicy reconnectPolicy;
  final Duration stableConnectionThreshold;

  final StreamController<SyncProjection> _projections =
      StreamController<SyncProjection>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  StreamSubscription<SyncProjection>? _projectionSubscription;
  bool _started = false;
  bool _disposed = false;
  Future<void>? _activeCycle;
  bool _cycleRequested = false;
  int _generation = 0;
  int _observedOutboxDepth = 0;

  /// Whether durable reconnect state may still be carrying an attempt counter
  /// or a due time from an earlier failure. True at start so the first
  /// successful cycle of a process retires whatever the previous one left.
  bool _reconnectPending = true;

  /// The durable retry time this session is currently waiting out, if any.
  DateTime? _retryWakeAt;

  Stream<SyncProjection> get projections => _projections.stream;

  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _projectionSubscription = _store.watchProjection().listen(
      _onProjection,
      onError: (_) {},
    );
    _subscriptions
      ..add(_network.changes.listen(_onNetworkChanged))
      ..add(_lifecycle.changes.listen(_onLifecycleChanged))
      ..add(_backgroundConnection.changes.listen((_) => _onHoldPolicyChanged()))
      ..add(_polling.triggers.listen(_onDeferredTick))
      ..add(
        _realtime.durableEnvelopeHints.listen((_) {
          unawaited(_recordHintAndDrain());
        }),
      )
      ..add(
        _realtime.disconnects.listen((event) {
          unawaited(_onRealtimeDisconnect(event));
        }),
      );

    if (_mayConnectNow) {
      await _resumeForeground();
    } else {
      await _enterBackground();
    }
  }

  /// Whether the application's current execution state permits a connection.
  ///
  /// Foreground always does. Backgrounded does only while something is keeping
  /// this process out of the cached state — a running foreground service —
  /// because a cached process is frozen and the platform terminates the TCP
  /// sockets of a frozen app, so a socket held without one is not a slow
  /// socket, it is a closed one. Detached never does: the process is going
  /// away.
  bool get _mayConnectNow => switch (_lifecycle.current) {
    ApplicationExecutionState.foreground => true,
    ApplicationExecutionState.background =>
      _backgroundConnection.mayHoldWhileBackgrounded,
    ApplicationExecutionState.detached => false,
  };

  /// Runs one cycle for a deferred platform wake-up and then acknowledges it.
  ///
  /// The acknowledgement is unconditional and happens exactly once, including
  /// when the cycle failed or was refused because the network is unavailable.
  /// The scheduler is not asking whether delivery succeeded — it is asking
  /// whether this process may be let go, and a tick that is never acknowledged
  /// holds the wake-up open until the platform's own deadline kills it.
  void _onDeferredTick(BestEffortDeliveryTick tick) {
    unawaited(_requestCycle().whenComplete(tick.complete));
  }

  /// Turns growth of the durable outbox into a delivery cycle.
  ///
  /// Sending is not a call into this supervisor. A composer writes exact
  /// per-recipient ciphertext rows inside a Drift transaction and returns; the
  /// rows are the request. Nothing else in the lifecycle would notice them —
  /// socket hints announce *inbound* envelopes, and a foregrounded application
  /// with a healthy connection has no other reason to run — so without this a
  /// queued message would sit in local storage until an unrelated event
  /// happened to wake the engine.
  ///
  /// The trigger is the durable queue's depth *increasing*, which is what makes
  /// it both crash-safe and loop-safe. Crash-safe, because a restart replays
  /// the depth as the stream's first value and drains what was queued before
  /// the process died. Loop-safe, because every run of the engine writes a
  /// connection phase and so re-emits this projection: reacting to "depth is
  /// non-zero" would spin against a row waiting out its retry backoff, while
  /// reacting to "depth grew" cannot, since only a new durable target grows it.
  ///
  /// That last clause is load-bearing and worth stating as the invariant it is:
  /// the engine's own writes only ever *retire* outbox rows — acceptance, stale
  /// device, permanent failure — and a retry leaves the row exactly as
  /// countable as it was, so no transition the engine makes can drive this
  /// trigger. The store conflates the stream it comes from, which changes
  /// nothing here: conflation keeps the first value and the last value of every
  /// window, and the only writer that raises the depth never lowers it again in
  /// the same breath.
  void _onProjection(SyncProjection projection) {
    _projections.add(projection);
    final previous = _observedOutboxDepth;
    _observedOutboxDepth = projection.outboxDepth;
    if (projection.outboxDepth > previous) {
      unawaited(_requestCycle());
    }
    unawaited(_armRetryWake(projection.nextRetryAt));
  }

  /// Wakes the engine when durable work becomes due again.
  ///
  /// Rows waiting out a backoff are the only work in this system that nothing
  /// else announces. A socket hint means an inbound envelope and a growing
  /// outbox means a new send — both are events, and both already have a
  /// trigger. A retry is a *time*, and it had none: the only thing that
  /// happened to re-run the engine on one was reconnect backoff firing on every
  /// failed cycle, which is to say, the bug. Taking that accidental wake-up away
  /// without putting a deliberate one in its place would leave a deferred
  /// envelope, or a batch in retry-wait, sitting until something unrelated woke
  /// the session.
  ///
  /// `nextRetryAt` is the earliest due time across the inbox, the outbox and
  /// the reconnect schedule, so one timer covers all three. It cannot spin: it
  /// arms only for a time in the future, only when that time is earlier than
  /// whatever it is already waiting for, and the cycle it eventually runs
  /// either finishes the work or pushes the due time further out.
  Future<void> _armRetryWake(DateTime? dueAt) async {
    if (_disposed || dueAt == null) {
      return;
    }
    final delay = dueAt.difference(_clock.now());
    if (delay <= Duration.zero) {
      return;
    }
    final pending = _retryWakeAt;
    if (pending != null && !dueAt.isBefore(pending)) {
      return;
    }
    _retryWakeAt = dueAt;
    await _delay.wait(delay);
    if (_disposed || _retryWakeAt != dueAt) {
      return;
    }
    _retryWakeAt = null;
    await _requestCycle();
  }

  Future<void> _recordHintAndDrain() async {
    final recorded = await _store.requestAuthoritativeDrain();
    if (recorded is Success<void>) {
      await _requestCycle();
    }
  }

  void _onNetworkChanged(NetworkAvailability availability) {
    if (availability == NetworkAvailability.unavailable) {
      _generation += 1;
      unawaited(_realtime.close());
      unawaited(_store.markConnectionPhase(SyncConnectionPhase.offline));
      return;
    }
    if (_mayConnectNow) {
      unawaited(_resumeForeground());
    } else {
      unawaited(_requestCycle());
    }
  }

  void _onLifecycleChanged(ApplicationExecutionState state) {
    if (_mayConnectNow) {
      unawaited(_resumeForeground());
    } else {
      unawaited(_enterBackground());
    }
  }

  /// Reacts to sustained delivery being turned on or off, or to the platform
  /// withdrawing what makes it possible, while this session is already running.
  ///
  /// Only the backgrounded case does anything: foregrounded, the connection is
  /// held either way, and re-establishing it would drop a working socket for no
  /// reason.
  void _onHoldPolicyChanged() {
    if (_disposed ||
        _lifecycle.current != ApplicationExecutionState.background) {
      return;
    }
    if (_backgroundConnection.mayHoldWhileBackgrounded) {
      unawaited(_resumeForeground());
    } else {
      unawaited(_enterBackground());
    }
  }

  Future<void> _resumeForeground() async {
    if (_disposed ||
        _network.current == NetworkAvailability.unavailable ||
        !_mayConnectNow) {
      return;
    }
    _generation += 1;
    final generation = _generation;
    final reconnect = await _store.readReconnectState();
    if (reconnect case Success(value: final state)) {
      final dueAt = state.dueAt;
      if (dueAt != null && dueAt.isAfter(_clock.now())) {
        unawaited(
          _waitThenReconnect(dueAt.difference(_clock.now()), generation),
        );
        return;
      }
    }
    await _connectAndDrain(generation);
  }

  /// Gives up the socket the moment this session may no longer hold one.
  ///
  /// Ordinarily that is the moment the application stops being foregrounded.
  /// While sustained delivery is holding the process out of the cached state it
  /// is not, and this is reached instead when that arrangement ends — the user
  /// turns it off, or the platform withdraws what makes it work.
  ///
  /// It does not arm or disarm the deferred catch-up. That is armed once for
  /// the whole signed-in session by whoever owns the session, because a
  /// periodic platform job restarts its window every time it is re-registered
  /// and a process that dies while foregrounded would otherwise leave nothing
  /// scheduled at all.
  Future<void> _enterBackground() async {
    _generation += 1;
    await _realtime.close();
    if (_lifecycle.current == ApplicationExecutionState.detached) {
      await _store.markConnectionPhase(SyncConnectionPhase.stopped);
    }
  }

  Future<void> _connectAndDrain(int generation) async {
    if (!_canUseRealtime(generation)) {
      return;
    }
    await _store.markConnectionPhase(SyncConnectionPhase.connecting);
    final connected = await _realtime.connect();
    if (!_canUseRealtime(generation)) {
      await _realtime.close();
      return;
    }
    if (connected case FailureResult(failure: final failure)) {
      await _requestCycle();
      await _scheduleReconnect(failure, generation);
      return;
    }
    unawaited(_markStableAfterDelay(generation));
    await _requestCycle();
  }

  Future<void> _markStableAfterDelay(int generation) async {
    await _delay.wait(stableConnectionThreshold);
    if (_canUseRealtime(generation)) {
      _realtime.markStableConnection();
      await _store.clearReconnect(syncedAt: null);
    }
  }

  /// Requests one delivery cycle, and completes when the work it asked for is
  /// over rather than when the request was accepted.
  ///
  /// A caller that already has a cycle in flight joins it instead of starting a
  /// second one, which is what lets a deferred platform wake-up wait for the
  /// real end of the drain even when a socket hint got there first.
  Future<void> _requestCycle() {
    if (_disposed || _network.current == NetworkAvailability.unavailable) {
      return Future<void>.value();
    }
    final active = _activeCycle;
    if (active != null) {
      _cycleRequested = true;
      return active;
    }
    final run = _runCycles();
    _activeCycle = run;
    return run;
  }

  /// Runs delivery cycles until nothing more has been asked for.
  ///
  /// The two things that can go wrong here are not the same thing, and treating
  /// them as one is what put a user-initiated send behind a random wait. A
  /// transport that will not carry a request needs reconnect backoff, and gets
  /// it. A cycle that failed locally — an envelope that would not open, a batch
  /// the server refused — needs nothing of the sort: the socket is up, the REST
  /// path is up, and the next request deserves to be serviced now rather than
  /// after a uniform draw of up to five minutes.
  Future<void> _runCycles() async {
    try {
      do {
        _cycleRequested = false;
        final result = await _engine.synchronize();
        if (result case FailureResult(failure: final failure)) {
          if (_isTransportUnhealthy(failure)) {
            if (_mayConnectNow) {
              await _scheduleReconnect(failure, _generation);
            }
            break;
          }
          // The durable queue moved even though the cycle reported a failure,
          // so a request that arrived while this one was running still gets its
          // own cycle. `continue` re-checks the loop condition, which means
          // this can only repeat while somebody is actually asking — it cannot
          // spin on its own.
          continue;
        }
        await _markCycleSucceeded();
      } while (_cycleRequested && !_disposed);
    } finally {
      // Cleared here rather than from a callback on the returned future, so
      // that a request arriving in the microtask after this run finishes starts
      // a new cycle instead of joining a completed one and being dropped.
      _activeCycle = null;
    }
  }

  /// Whether a failed cycle is evidence that the connection itself is unusable.
  ///
  /// Only the transport-shaped failures are. Everything else — a local storage
  /// fault, an envelope that would not open, a batch the server rejected on its
  /// contents — says nothing about whether the next request would arrive.
  bool _isTransportUnhealthy(Failure failure) =>
      failure is TransportFailure ||
      failure is AuthenticationFailure ||
      (failure is BackendFailure &&
          failure.code == BackendFailureCode.throttled);

  /// Retires the reconnect backoff after a cycle that demonstrably worked.
  ///
  /// It used to be retired only by [_markStableAfterDelay], thirty seconds
  /// after a socket opened, so an attempt counter raised by failures the
  /// transport had nothing to do with kept growing and kept lengthening the
  /// wait in front of the next connect. A completed cycle is stronger evidence
  /// than an open socket: it means the REST path carried a drain, an
  /// acknowledgement and a send.
  ///
  /// The flag keeps this to one write. It starts true so that the first
  /// successful cycle of a process clears whatever the previous process left
  /// behind, and is raised again whenever a reconnect is scheduled.
  Future<void> _markCycleSucceeded() async {
    if (!_reconnectPending) {
      return;
    }
    final cleared = await _store.clearReconnect(syncedAt: null);
    if (cleared is Success<void>) {
      _reconnectPending = false;
    }
  }

  Future<void> _onRealtimeDisconnect(RealtimeDisconnect event) async {
    if (_disposed) {
      return;
    }
    switch (event.action) {
      case RealtimeRecoveryAction.stopRevoked:
        _generation += 1;
        await _store.markConnectionPhase(SyncConnectionPhase.revoked);
      case RealtimeRecoveryAction.openCircuit:
        _generation += 1;
        await _store.markConnectionPhase(
          SyncConnectionPhase.protocolCircuitOpen,
        );
      case RealtimeRecoveryAction.stopOriginRejected:
        _generation += 1;
        await _store.markConnectionPhase(SyncConnectionPhase.originRejected);
      case RealtimeRecoveryAction.refreshThenReconnectOnce:
        await _scheduleReconnect(
          const AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
          _generation,
          immediate: true,
        );
      case RealtimeRecoveryAction.reconnectWithBackoff:
        await _scheduleReconnect(
          const TransportFailure(TransportFailureKind.connectionRejected),
          _generation,
        );
      case RealtimeRecoveryAction.none:
        if (event.kind == RealtimeDisconnectKind.normal) {
          await _store.markConnectionPhase(SyncConnectionPhase.stopped);
        }
    }
  }

  Future<void> _scheduleReconnect(
    Failure failure,
    int generation, {
    bool immediate = false,
  }) async {
    if (!_canUseRealtime(generation)) {
      return;
    }
    final current = await _store.readReconnectState();
    final nextAttempt = switch (current) {
      Success(value: final state) => state.attempt + 1,
      _ => 1,
    };
    final delay = immediate
        ? Duration.zero
        : reconnectPolicy.delayFor(
            attempt: nextAttempt,
            failure: failure,
            jitter: _jitter,
          );
    final dueAt = _clock.now().add(delay);
    final persisted = await _store.scheduleReconnect(dueAt: dueAt);
    if (persisted is FailureResult<DurableReconnectState>) {
      return;
    }
    _reconnectPending = true;
    unawaited(_waitThenReconnect(delay, generation));
  }

  Future<void> _waitThenReconnect(Duration delay, int generation) async {
    await _delay.wait(delay);
    if (_canUseRealtime(generation)) {
      await _connectAndDrain(generation);
    }
  }

  bool _canUseRealtime(int generation) =>
      !_disposed &&
      generation == _generation &&
      _network.current == NetworkAvailability.available &&
      _mayConnectNow;

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation += 1;
    _retryWakeAt = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _projectionSubscription?.cancel();
    _projectionSubscription = null;
    await _realtime.close();
    await _projections.close();
  }
}
