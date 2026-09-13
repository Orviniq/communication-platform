import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/networking/application/ports/realtime_gateway.dart';
import 'package:communication_platform/features/networking/domain/realtime_event.dart';
import 'package:communication_platform/features/synchronization/application/durable_sync_engine.dart';
import 'package:communication_platform/features/synchronization/application/ports/sustained_delivery_ports.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/application/sync_lifecycle_supervisor.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:communication_platform/features/synchronization/infrastructure/gateway_realtime_sync_adapter.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'foreground socket events are hints followed by REST drain; lifecycle and network transitions are safe',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      final store = DriftSyncStore(database);
      final remote = CountingRemote();
      final realtime = FakeRealtimeSyncPort();
      final network = FakeNetworkPort(NetworkAvailability.available);
      final lifecycle = FakeLifecyclePort(ApplicationExecutionState.foreground);
      final polling = FakePollingPort();
      final clock = SupervisorClock();
      final engine = DurableSyncEngine(
        store: store,
        remote: remote,
        inspector: const RetainingInspector(),
        staleDeviceRefresh: const NoopStaleRefresh(),
        clock: clock,
        jitter: const SupervisorJitter(),
      );
      final supervisor = SyncLifecycleSupervisor(
        engine: engine,
        store: store,
        realtime: realtime,
        network: network,
        lifecycle: lifecycle,
        polling: polling,
        clock: clock,
        jitter: const SupervisorJitter(),
        delay: const ImmediateDelay(),
      );

      await supervisor.start();
      expect(realtime.connects, 1);
      expect(remote.drains, 1);

      realtime.hint();
      await pumpEvents();
      expect(remote.drains, 2);
      expect(
        remote.receivedSocketPayloads,
        isEmpty,
        reason: 'the realtime port exposes no envelope payload to the engine',
      );

      lifecycle.set(ApplicationExecutionState.background);
      await pumpEvents();
      expect(realtime.closes, greaterThanOrEqualTo(1));
      expect(
        polling.schedules,
        0,
        reason:
            'the supervisor does not arm the deferred catch-up: a periodic '
            'platform job restarts its window every time it is registered, so '
            'arming it on each background transition would mean a user who '
            'opens the app more often than the interval never gets one',
      );

      polling.trigger();
      await pumpEvents();
      expect(remote.drains, 3);
      expect(
        polling.acknowledged,
        1,
        reason:
            'a deferred wake-up is a bounded moment the platform granted, and '
            'an unacknowledged tick is a catch-up it stops mid-drain',
      );

      network.set(NetworkAvailability.unavailable);
      polling.trigger();
      await pumpEvents();
      expect(remote.drains, 3);
      expect(
        polling.acknowledged,
        2,
        reason:
            'a tick refused for want of a network is still acknowledged: the '
            'scheduler is asking whether the process may be let go, not '
            'whether delivery succeeded',
      );
      final offline = await store.readProjection() as Success<SyncProjection>;
      expect(offline.value.connectionPhase, SyncConnectionPhase.offline);

      network.set(NetworkAvailability.available);
      lifecycle.set(ApplicationExecutionState.foreground);
      await pumpEvents();
      expect(realtime.connects, greaterThanOrEqualTo(2));
      expect(remote.drains, greaterThanOrEqualTo(4));

      await supervisor.dispose();
      await database.close();
    },
  );

  test(
    'revoked, protocol, and origin closes persist terminal projections',
    () async {
      for (final entry in const [
        (
          RealtimeDisconnectKind.revoked,
          RealtimeRecoveryAction.stopRevoked,
          SyncConnectionPhase.revoked,
        ),
        (
          RealtimeDisconnectKind.protocolViolation,
          RealtimeRecoveryAction.openCircuit,
          SyncConnectionPhase.protocolCircuitOpen,
        ),
        (
          RealtimeDisconnectKind.originRejected,
          RealtimeRecoveryAction.stopOriginRejected,
          SyncConnectionPhase.originRejected,
        ),
      ]) {
        final database = LocalDatabase(NativeDatabase.memory());
        final store = DriftSyncStore(database);
        final realtime = FakeRealtimeSyncPort();
        final supervisor = SyncLifecycleSupervisor(
          engine: DurableSyncEngine(
            store: store,
            remote: CountingRemote(),
            inspector: const RetainingInspector(),
            staleDeviceRefresh: const NoopStaleRefresh(),
            clock: SupervisorClock(),
            jitter: const SupervisorJitter(),
          ),
          store: store,
          realtime: realtime,
          network: FakeNetworkPort(NetworkAvailability.available),
          lifecycle: FakeLifecyclePort(ApplicationExecutionState.foreground),
          polling: FakePollingPort(),
          clock: SupervisorClock(),
          jitter: const SupervisorJitter(),
          delay: const ImmediateDelay(),
        );
        await supervisor.start();

        realtime.disconnect(
          RealtimeDisconnect(kind: entry.$1, action: entry.$2),
        );
        await pumpEvents();

        final projection =
            await store.readProjection() as Success<SyncProjection>;
        expect(projection.value.connectionPhase, entry.$3);
        await supervisor.dispose();
        await database.close();
      }
    },
  );

  test(
    'a durable retry time is a wake-up, so a poison envelope retires with no '
    'other stimulus',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      final store = DriftSyncStore(database, projectionWindow: Duration.zero);
      final remote = SilentRemote();
      final inspector = RefusingInspector();
      final clock = AdvancingClock();
      final engine = DurableSyncEngine(
        store: store,
        remote: remote,
        inspector: inspector,
        staleDeviceRefresh: const NoopStaleRefresh(),
        clock: clock,
        jitter: const ZeroJitter(),
        limits: const SyncEngineLimits(maximumInspectionAttempts: 3),
      );
      final supervisor = SyncLifecycleSupervisor(
        engine: engine,
        store: store,
        realtime: FakeRealtimeSyncPort(),
        network: FakeNetworkPort(NetworkAvailability.available),
        lifecycle: FakeLifecyclePort(ApplicationExecutionState.foreground),
        polling: FakePollingPort(),
        clock: clock,
        jitter: const ZeroJitter(),
        // Waiting is what this test is about, so the wait is where the clock
        // moves: the supervisor asks for a delay, and the delay happens.
        delay: ClockAdvancingDelay(clock),
      );

      await store.persistDrainPage(
        DrainPage(
          envelopes: [
            SyncEnvelope(
              id: '00000000-0000-4000-8000-0000000000aa',
              sequence: 1,
              exactCiphertext: Uint8List(1024),
            ),
          ],
          hasMore: false,
          prunedThrough: 0,
        ),
      );

      await supervisor.start();
      for (var index = 0; index < 40; index += 1) {
        await pumpEvents();
      }

      // Nothing arrived, nothing was sent, no socket event happened and nobody
      // touched the application. The only thing that moved is time, and the
      // envelope is gone.
      expect(
        inspector.calls,
        greaterThanOrEqualTo(3),
        reason: 'the retry time is what brought the engine back',
      );
      expect(remote.sends, 0);
      expect(
        await database.select(database.quarantineRecords).get(),
        hasLength(1),
        reason: 'the budget ran out and the envelope was retired',
      );
      expect(
        remote.acknowledged.expand((batch) => batch),
        contains('00000000-0000-4000-8000-0000000000aa'),
        reason: 'and the server is told, so it stops serving these bytes',
      );

      await supervisor.dispose();
      await database.close();
    },
  );

  test(
    'a growing durable outbox drives a cycle; a stalled one does not spin',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      final store = DriftSyncStore(database);
      final remote = RefusingSendRemote();
      // A frozen clock plus maximum jitter puts a failed target's next attempt
      // firmly in the future, which is what lets this test distinguish "the
      // queue grew" from "the queue is merely non-empty".
      final engine = DurableSyncEngine(
        store: store,
        remote: remote,
        inspector: const RetainingInspector(),
        staleDeviceRefresh: const NoopStaleRefresh(),
        clock: SupervisorClock(),
        jitter: const MaximumJitter(),
      );
      final supervisor = SyncLifecycleSupervisor(
        engine: engine,
        store: store,
        realtime: FakeRealtimeSyncPort(),
        network: FakeNetworkPort(NetworkAvailability.available),
        lifecycle: FakeLifecyclePort(ApplicationExecutionState.foreground),
        polling: FakePollingPort(),
        clock: SupervisorClock(),
        jitter: const MaximumJitter(),
        delay: const ImmediateDelay(),
      );
      await supervisor.start();
      await pumpEvents();
      expect(remote.sends, 0);

      // What a send does: durable rows inside a Drift transaction, and no call
      // into the supervisor at all.
      final queued = await store.queuePreparedOperation(
        operationId: 'operation',
        eventId: 'event',
        targets: [
          PreparedOutboxTarget(
            recipientUserId: 'user',
            recipientDeviceId: '00000000-0000-4000-8000-000000000001',
            exactCiphertext: Uint8List(1024),
          ),
        ],
      );
      expect(queued, isA<Success<void>>());
      for (var index = 0; index < 6; index += 1) {
        await pumpEvents();
      }

      expect(
        remote.sends,
        1,
        reason: 'the queue growing is what asked for transmission',
      );

      // The send failed, so the target is still counted while it waits out its
      // backoff, and every later engine run rewrites the connection phase and
      // re-emits this projection. A supervisor that reacted to "depth is
      // non-zero" would run forever here; this asserts it does not.
      final settledDrains = remote.drains;
      for (var index = 0; index < 6; index += 1) {
        await pumpEvents();
      }
      final projection =
          await store.readProjection() as Success<SyncProjection>;
      expect(projection.value.outboxDepth, 1);
      expect(remote.drains, settledDrains);
      expect(remote.sends, 1);

      await supervisor.dispose();
      await database.close();
    },
  );

  test(
    'gateway adapter maps all close codes and drops socket envelope bytes',
    () async {
      final adapter = GatewayRealtimeSyncAdapter();
      final gateway = FakeGateway();
      adapter.attach(gateway);
      final hints = <void>[];
      final hintSubscription = adapter.durableEnvelopeHints.listen(hints.add);
      gateway.add(
        RealtimeEnvelope(
          id: '00000000-0000-0000-0000-000000000001',
          sequence: 1,
          blob: 'opaque-socket-bytes-never-forwarded',
        ),
      );
      await pumpEvents();
      expect(hints, hasLength(1));

      const cases = [
        (
          RealtimeCloseReason.authenticationFailed,
          ReconnectAction.refreshThenReconnectOnce,
          RealtimeDisconnectKind.authenticationFailed,
          RealtimeRecoveryAction.refreshThenReconnectOnce,
        ),
        (
          RealtimeCloseReason.revoked,
          ReconnectAction.stopRevoked,
          RealtimeDisconnectKind.revoked,
          RealtimeRecoveryAction.stopRevoked,
        ),
        (
          RealtimeCloseReason.protocolViolation,
          ReconnectAction.openCircuit,
          RealtimeDisconnectKind.protocolViolation,
          RealtimeRecoveryAction.openCircuit,
        ),
        (
          RealtimeCloseReason.originRejected,
          ReconnectAction.stopOriginRejected,
          RealtimeDisconnectKind.originRejected,
          RealtimeRecoveryAction.stopOriginRejected,
        ),
        (
          RealtimeCloseReason.transportLost,
          ReconnectAction.reconnectWithBackoff,
          RealtimeDisconnectKind.transportLost,
          RealtimeRecoveryAction.reconnectWithBackoff,
        ),
      ];
      for (final entry in cases) {
        final event = adapter.disconnects.first;
        await adapter.onDisconnected(reason: entry.$1, action: entry.$2);
        final mapped = await event;
        expect(mapped.kind, entry.$3);
        expect(mapped.action, entry.$4);
      }
      await hintSubscription.cancel();
      await adapter.dispose();
      await gateway.dispose();
    },
  );

  test('the connection outlives the foreground only while something holds the '
      'process open', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    final store = DriftSyncStore(database);
    final remote = CountingRemote();
    final realtime = FakeRealtimeSyncPort();
    final network = FakeNetworkPort(NetworkAvailability.available);
    final lifecycle = FakeLifecyclePort(ApplicationExecutionState.foreground);
    final polling = FakePollingPort();
    final holding = MutableBackgroundConnectionPolicy();
    final clock = SupervisorClock();
    final supervisor = SyncLifecycleSupervisor(
      engine: DurableSyncEngine(
        store: store,
        remote: remote,
        inspector: const RetainingInspector(),
        staleDeviceRefresh: const NoopStaleRefresh(),
        clock: clock,
        jitter: const SupervisorJitter(),
      ),
      store: store,
      realtime: realtime,
      network: network,
      lifecycle: lifecycle,
      polling: polling,
      backgroundConnection: holding,
      clock: clock,
      jitter: const SupervisorJitter(),
      delay: const ImmediateDelay(),
    );

    await supervisor.start();
    expect(realtime.connects, 1);

    // The default, and the composition of every application nobody has
    // turned sustained delivery on in: backgrounding gives up the socket,
    // because a cached process is frozen and the platform terminates its
    // TCP sockets.
    lifecycle.set(ApplicationExecutionState.background);
    await pumpEvents();
    final closedOnBackground = realtime.closes;
    expect(closedOnBackground, greaterThanOrEqualTo(1));
    realtime.hint();
    await pumpEvents();
    expect(
      realtime.connects,
      1,
      reason: 'a backgrounded session with no service does not reconnect',
    );

    // The user turns it on while the application is already backgrounded.
    // The supervisor is woken by the policy itself rather than waiting for
    // an unrelated lifecycle event that may never come.
    holding.set(true);
    await pumpEvents();
    expect(realtime.connects, 2);
    final drainsWhileHolding = remote.drains;
    realtime.hint();
    await pumpEvents();
    expect(
      remote.drains,
      greaterThan(drainsWhileHolding),
      reason: 'a hint on a held socket still triggers an authoritative drain',
    );

    // And the platform takes it away again - the exemption is withdrawn, or
    // the service is killed. The socket goes with it rather than being
    // retried against a process the system is about to freeze.
    holding.set(false);
    await pumpEvents();
    expect(realtime.closes, greaterThan(closedOnBackground));
    realtime.hint();
    await pumpEvents();
    expect(realtime.connects, 2);

    // Detached is never held: the process is going away.
    holding.set(true);
    lifecycle.set(ApplicationExecutionState.detached);
    await pumpEvents();
    final connectsWhenDetached = realtime.connects;
    realtime.hint();
    await pumpEvents();
    expect(realtime.connects, connectsWhenDetached);

    await supervisor.dispose();
    await database.close();
  });
}

final class CountingRemote implements SyncRemotePort {
  int drains = 0;
  final List<Uint8List> receivedSocketPayloads = [];

  @override
  Future<Result<DrainPage>> drain({required int limit}) async {
    drains += 1;
    return Result.success(
      DrainPage(envelopes: const [], hasMore: false, prunedThrough: 0),
    );
  }

  @override
  Future<Result<int>> acknowledge(List<String> envelopeIds) async =>
      Result.success(envelopeIds.length);

  @override
  Future<Result<OutboxAcceptance>> send(OutboxBatch batch) async =>
      Result.success(
        OutboxAcceptance(accepted: batch.targets.length, staleDeviceIds: {}),
      );
}

/// Drains cleanly and refuses every send, so a queued target stays durable and
/// keeps the outbox depth pinned above zero.
/// A clock a test moves, unlike [SupervisorClock], which is frozen.
final class AdvancingClock implements TimeSource {
  DateTime value = DateTime.utc(2026, 8, 26);

  @override
  DateTime now() => value;
}

/// Waiting, made observable: the delay a caller asked for is exactly how far
/// the clock moves, so a durable retry time genuinely falls due.
final class ClockAdvancingDelay implements DelayPort {
  ClockAdvancingDelay(this.clock);

  final AdvancingClock clock;

  @override
  Future<void> wait(Duration delay) async {
    clock.value = clock.value.add(delay);
  }
}

final class ZeroJitter implements JitterSource {
  const ZeroJitter();

  @override
  int nextInt(int upperBoundExclusive) => 0;
}

/// A server with nothing to say: no envelopes, and every acknowledgement
/// accepted.
final class SilentRemote implements SyncRemotePort {
  int sends = 0;
  final List<List<String>> acknowledged = [];

  @override
  Future<Result<DrainPage>> drain({required int limit}) async => Result.success(
    DrainPage(envelopes: const [], hasMore: false, prunedThrough: 0),
  );

  @override
  Future<Result<int>> acknowledge(List<String> envelopeIds) async {
    acknowledged.add(List.of(envelopeIds));
    return Result.success(envelopeIds.length);
  }

  @override
  Future<Result<OutboxAcceptance>> send(OutboxBatch batch) async {
    sends += 1;
    return Result.success(
      OutboxAcceptance(
        accepted: batch.targets.length,
        staleDeviceIds: const {},
      ),
    );
  }
}

/// The native core refusing bytes it will refuse every time.
final class RefusingInspector implements OpaqueEnvelopeInspector {
  int calls = 0;

  @override
  Future<Result<OpaqueEnvelopeInspection>> inspect({
    required String envelopeId,
    required Uint8List exactCiphertext,
  }) async {
    calls += 1;
    return const Result.failure(
      CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
    );
  }
}

final class RefusingSendRemote implements SyncRemotePort {
  int drains = 0;
  int sends = 0;

  @override
  Future<Result<DrainPage>> drain({required int limit}) async {
    drains += 1;
    return Result.success(
      DrainPage(envelopes: const [], hasMore: false, prunedThrough: 0),
    );
  }

  @override
  Future<Result<int>> acknowledge(List<String> envelopeIds) async =>
      Result.success(envelopeIds.length);

  @override
  Future<Result<OutboxAcceptance>> send(OutboxBatch batch) async {
    sends += 1;
    return const Result.failure(TransportFailure(TransportFailureKind.offline));
  }
}

final class FakeRealtimeSyncPort implements RealtimeSyncPort {
  final StreamController<void> hints = StreamController<void>.broadcast();
  final StreamController<RealtimeDisconnect> disconnectEvents =
      StreamController<RealtimeDisconnect>.broadcast();
  int connects = 0;
  int closes = 0;

  @override
  Stream<void> get durableEnvelopeHints => hints.stream;

  @override
  Stream<RealtimeDisconnect> get disconnects => disconnectEvents.stream;

  void hint() => hints.add(null);

  void disconnect(RealtimeDisconnect event) => disconnectEvents.add(event);

  @override
  Future<Result<void>> connect() async {
    connects += 1;
    return const Result.success(null);
  }

  @override
  void markStableConnection() {}

  @override
  Future<void> close() async {
    closes += 1;
  }
}

final class FakeNetworkPort implements NetworkAvailabilityPort {
  FakeNetworkPort(this._current);

  final StreamController<NetworkAvailability> controller =
      StreamController<NetworkAvailability>.broadcast();
  NetworkAvailability _current;

  @override
  NetworkAvailability get current => _current;

  @override
  Stream<NetworkAvailability> get changes => controller.stream;

  void set(NetworkAvailability value) {
    _current = value;
    controller.add(value);
  }
}

final class FakeLifecyclePort implements ApplicationLifecyclePort {
  FakeLifecyclePort(this._current);

  final StreamController<ApplicationExecutionState> controller =
      StreamController<ApplicationExecutionState>.broadcast();
  ApplicationExecutionState _current;

  @override
  ApplicationExecutionState get current => _current;

  @override
  Stream<ApplicationExecutionState> get changes => controller.stream;

  void set(ApplicationExecutionState value) {
    _current = value;
    controller.add(value);
  }
}

final class FakePollingPort implements BestEffortPollingPort {
  final StreamController<BestEffortDeliveryTick> controller =
      StreamController<BestEffortDeliveryTick>.broadcast();
  int schedules = 0;
  int acknowledged = 0;

  @override
  Stream<BestEffortDeliveryTick> get triggers => controller.stream;

  void trigger() => controller.add(
    BestEffortDeliveryTick(onComplete: () => acknowledged += 1),
  );

  @override
  Future<void> schedule({required Duration minimumInterval}) async {
    schedules += 1;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> awaitExclusiveOwnership() async {}
}

/// A [BackgroundConnectionPolicy] a test can flip, standing in for the user
/// turning sustained delivery on and for the platform taking it away again.
final class MutableBackgroundConnectionPolicy
    implements BackgroundConnectionPolicy {
  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool _holding = false;

  @override
  bool get mayHoldWhileBackgrounded => _holding;

  @override
  Stream<void> get changes => _changes.stream;

  void set(bool holding) {
    _holding = holding;
    _changes.add(null);
  }
}

final class FakeGateway implements RealtimeGateway {
  final StreamController<RealtimeEvent> controller =
      StreamController<RealtimeEvent>.broadcast();

  @override
  Stream<RealtimeEvent> get events => controller.stream;

  void add(RealtimeEvent event) => controller.add(event);

  @override
  Future<Result<void>> connect() async => const Result.success(null);

  @override
  void markStableConnection() {}

  @override
  Future<Result<void>> send(Map<String, Object?> frame) async =>
      const Result.success(null);

  @override
  Future<void> close() async {}

  Future<void> dispose() => controller.close();
}

final class RetainingInspector implements OpaqueEnvelopeInspector {
  const RetainingInspector();

  @override
  Future<Result<OpaqueEnvelopeInspection>> inspect({
    required String envelopeId,
    required Uint8List exactCiphertext,
  }) async => const Result.success(
    OpaqueEnvelopeInspection(
      opaqueEventId: 'fixture',
      dependency: EnvelopeDependency.directOrLocal,
    ),
  );
}

final class NoopStaleRefresh implements StaleDeviceRefreshPort {
  const NoopStaleRefresh();

  @override
  Future<Result<void>> refreshUserDevices(String userId) async =>
      const Result.success(null);
}

final class SupervisorClock implements TimeSource {
  @override
  DateTime now() => DateTime.utc(2026, 7, 29);
}

/// The opposite bound of [SupervisorJitter]: a full-jitter draw that lands on
/// the cap, so a scheduled retry is genuinely in the future.
final class MaximumJitter implements JitterSource {
  const MaximumJitter();

  @override
  int nextInt(int upperBoundExclusive) => upperBoundExclusive - 1;
}

final class SupervisorJitter implements JitterSource {
  const SupervisorJitter();

  @override
  int nextInt(int upperBoundExclusive) => 0;
}

final class ImmediateDelay implements DelayPort {
  const ImmediateDelay();

  @override
  Future<void> wait(Duration delay) async {}
}

Future<void> pumpEvents() async {
  for (var index = 0; index < 8; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
