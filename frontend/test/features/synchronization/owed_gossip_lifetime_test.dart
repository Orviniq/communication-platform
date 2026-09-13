import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/owed_device_log_gossip.dart';
import 'package:communication_platform/features/devices/infrastructure/device_log_gossip_coordinator.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/synchronization/application/durable_sync_engine.dart';
import 'package:communication_platform/features/synchronization/application/ports/sync_ports.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where device-log gossip sits in a delivery cycle, and what happens to it
/// when the cycle ends.
///
/// It used to be awaited by `PairwiseSendPreparationAdapter.prepare`, which put
/// a whole second fan-out — its own two device lookups, its own ratchet steps,
/// its own commit — between a sealed envelope and its `POST`. A detached future
/// was not the alternative: a delivery cycle can be a headless catch-up that
/// disposes its container and closes its database the instant `synchronize()`
/// returns, so anything still running then is running against a closed
/// database or racing the next cycle. Gossip is now a debt the cycle records
/// and pays inside itself.
void main() {
  late LocalDatabase database;
  late DriftSyncStore store;
  late _Remote remote;
  late _Clock clock;
  late _Gossip gossip;
  late OwedDeviceLogGossip owed;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    store = DriftSyncStore(database);
    remote = _Remote();
    clock = _Clock(DateTime.utc(2026, 8, 28));
    gossip = _Gossip(remote);
    owed = OwedDeviceLogGossip(advertise: gossip.advertise, clock: clock);
  });

  tearDown(() async {
    await database.close();
  });

  DurableSyncEngine engineWith(SendPreparationPort preparer) =>
      DurableSyncEngine(
        store: store,
        remote: remote,
        inspector: const _NeverInspects(),
        staleDeviceRefresh: const _NoStaleRefresh(),
        clock: clock,
        jitter: const _ZeroJitter(),
        sendPreparation: preparer,
        postInboxCommitWork: DeviceLogGossipPostInboxWork(owed),
      );

  Future<void> owe(String operationId, String peerUserId) => database
      .into(database.pendingSendPreparations)
      .insert(
        PendingSendPreparationsCompanion.insert(
          operationId: operationId,
          eventId: operationId,
          localUserId: _uuid(1),
          localDeviceId: _uuid(11),
          peerUserId: peerUserId,
        ),
      );

  test('the message is on the wire before gossip runs', () async {
    await owe('application:aa', _uuid(2));
    final preparer = _Preparer(database, store, gossip, owed.owe);

    final report = await engineWith(preparer).synchronize();

    expect(report, isA<Success<SyncRunReport>>());
    // The preparation returned with nothing gossiped: the debt was recorded,
    // not paid.
    expect(preparer.gossipedWhenPrepared, [0]);
    // And the batch it sealed had already gone when gossip ran.
    expect(gossip.sentWhenAdvertised, [1]);
    expect(gossip.advertised, [_uuid(2)]);
  });

  test('gossip is finished when the cycle returns', () async {
    await owe('application:bb', _uuid(2));
    final preparer = _Preparer(database, store, gossip, owed.owe);

    await engineWith(preparer).synchronize();

    // A headless catch-up closes its database on the next line after this. If
    // anything were still owed or still running, this is where it would be
    // lost.
    expect(owed.owed, isEmpty);
    expect(gossip.running, isFalse);
    expect(gossip.advertised, [_uuid(2)]);
  });

  test('two sends to one peer in a cycle gossip once', () async {
    await owe('application:cc', _uuid(2));
    await owe('application:dd', _uuid(2));
    final preparer = _Preparer(database, store, gossip, owed.owe);

    final report = await engineWith(preparer).synchronize();

    expect(report, isA<Success<SyncRunReport>>());
    expect(preparer.prepared, ['application:cc', 'application:dd']);
    expect(gossip.advertised, [_uuid(2)]);
  });

  test('a second cycle moments later gossips no further', () async {
    await owe('application:ee', _uuid(2));
    final preparer = _Preparer(database, store, gossip, owed.owe);
    final engine = engineWith(preparer);

    await engine.synchronize();
    await owe('application:ff', _uuid(2));
    clock.advance(const Duration(seconds: 5));
    await engine.synchronize();

    // Nothing about a device-log head can have moved in five seconds that this
    // device has not already advertised.
    expect(preparer.prepared, ['application:ee', 'application:ff']);
    expect(gossip.advertised, [_uuid(2)]);
  });

  test('a cycle past the window gossips again', () async {
    await owe('application:01', _uuid(2));
    final preparer = _Preparer(database, store, gossip, owed.owe);
    final engine = engineWith(preparer);

    await engine.synchronize();
    await owe('application:02', _uuid(2));
    clock.advance(defaultGossipCoalescingWindow);
    await engine.synchronize();

    expect(gossip.advertised, [_uuid(2), _uuid(2)]);
  });

  test('distinct peers are each owed their own round', () async {
    await owe('application:03', _uuid(2));
    await owe('application:04', _uuid(3));
    final preparer = _Preparer(database, store, gossip, owed.owe);

    await engineWith(preparer).synchronize();

    expect(gossip.advertised, unorderedEquals([_uuid(2), _uuid(3)]));
  });

  test('gossip failing is not the cycle failing', () async {
    await owe('application:05', _uuid(2));
    final preparer = _Preparer(database, store, gossip, owed.owe);
    gossip.failure = const TransportFailure(TransportFailureKind.timeout);

    final report = await engineWith(preparer).synchronize();

    expect(report, isA<Success<SyncRunReport>>());
    expect((report as Success<SyncRunReport>).value.preparedSends, 1);
    // The preparation was retired by the transaction that sealed it, and a
    // gossip round this device could not perform did not put it back.
    expect(
      await database.select(database.pendingSendPreparations).get(),
      isEmpty,
    );
    expect(remote.sentBatches, hasLength(1));
  });

  test('gossip throwing is not the cycle failing', () async {
    await owe('application:06', _uuid(2));
    final preparer = _Preparer(database, store, gossip, owed.owe);
    gossip.throws = true;

    final report = await engineWith(preparer).synchronize();

    expect(report, isA<Success<SyncRunReport>>());
    expect(
      await database.select(database.pendingSendPreparations).get(),
      isEmpty,
    );
  });

  test('a gossip round that failed is owed by the next send', () async {
    await owe('application:07', _uuid(2));
    final preparer = _Preparer(database, store, gossip, owed.owe);
    final engine = engineWith(preparer);
    gossip.failure = const TransportFailure(TransportFailureKind.timeout);

    await engine.synchronize();
    gossip.failure = null;
    await owe('application:08', _uuid(2));
    await engine.synchronize();

    // Nothing recorded a success that did not happen, so the coalescing window
    // never opened and the next send caught it up.
    expect(gossip.advertised, [_uuid(2), _uuid(2)]);
  });

  test('a preparation that failed owes nothing', () async {
    await owe('application:09', _uuid(2));
    const preparer = _RefusingPreparer(
      SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );

    await engineWith(preparer).synchronize();

    expect(gossip.advertised, isEmpty);
    expect(owed.owed, isEmpty);
  });
}

/// Seals a send the way the real preparation does — the outbox rows and the
/// retirement of the request in one transaction — and records what had already
/// been gossiped when it did.
final class _Preparer implements SendPreparationPort {
  _Preparer(this.database, this.store, this.gossip, this.onPreparedForPeer);

  final LocalDatabase database;
  final DriftSyncStore store;
  final _Gossip gossip;
  final void Function(String peerUserId) onPreparedForPeer;
  final List<String> prepared = [];
  final List<int> gossipedWhenPrepared = [];

  @override
  Future<Result<void>> prepare(PendingSendPreparation preparation) async {
    prepared.add(preparation.operationId);
    gossipedWhenPrepared.add(gossip.advertised.length);
    await store.queuePreparedOperation(
      operationId: preparation.operationId,
      eventId: preparation.eventId,
      targets: [
        PreparedOutboxTarget(
          recipientUserId: preparation.peerUserId,
          recipientDeviceId: _uuid(21),
          exactCiphertext: Uint8List.fromList(List<int>.filled(1024, 7)),
        ),
      ],
    );
    await (database.delete(
      database.pendingSendPreparations,
    )..where((row) => row.operationId.equals(preparation.operationId))).go();
    onPreparedForPeer(preparation.peerUserId);
    return const Result.success(null);
  }
}

final class _RefusingPreparer implements SendPreparationPort {
  const _RefusingPreparer(this.failure);

  final Failure failure;

  @override
  Future<Result<void>> prepare(PendingSendPreparation preparation) async =>
      Result.failure(failure);
}

/// Stands in for the whole gossip fan-out, and records where in the cycle it
/// ran relative to the wire.
final class _Gossip {
  _Gossip(this.remote);

  final _Remote remote;
  final List<String> advertised = [];
  final List<int> sentWhenAdvertised = [];
  Failure? failure;
  bool throws = false;
  bool running = false;

  Future<Result<void>> advertise(String peerUserId) async {
    running = true;
    await Future<void>.delayed(Duration.zero);
    try {
      if (throws) {
        throw StateError('gossip');
      }
      advertised.add(peerUserId);
      sentWhenAdvertised.add(remote.sentBatches.length);
      final held = failure;
      return held == null ? const Result.success(null) : Result.failure(held);
    } finally {
      running = false;
    }
  }
}

final class _Remote implements SyncRemotePort {
  final List<OutboxBatch> sentBatches = [];

  @override
  Future<Result<DrainPage>> drain({required int limit}) async => Result.success(
    DrainPage(envelopes: const [], hasMore: false, prunedThrough: 0),
  );

  @override
  Future<Result<int>> acknowledge(List<String> envelopeIds) async =>
      Result.success(envelopeIds.length);

  @override
  Future<Result<OutboxAcceptance>> send(OutboxBatch batch) async {
    sentBatches.add(batch);
    return Result.success(
      OutboxAcceptance(
        accepted: batch.targets.length,
        staleDeviceIds: const {},
      ),
    );
  }
}

final class _NeverInspects implements OpaqueEnvelopeInspector {
  const _NeverInspects();

  @override
  Future<Result<OpaqueEnvelopeInspection>> inspect({
    required String envelopeId,
    required Uint8List exactCiphertext,
  }) async =>
      const Result.failure(SecurityFailure(SecurityFailureKind.policyBlocked));
}

final class _NoStaleRefresh implements StaleDeviceRefreshPort {
  const _NoStaleRefresh();

  @override
  Future<Result<void>> refreshUserDevices(String userId) async =>
      const Result.success(null);
}

final class _ZeroJitter implements JitterSource {
  const _ZeroJitter();

  @override
  int nextInt(int upperBoundExclusive) => 0;
}

final class _Clock implements TimeSource {
  _Clock(this._now);

  DateTime _now;

  void advance(Duration by) => _now = _now.add(by);

  @override
  DateTime now() => _now;
}

String _uuid(int value) =>
    '00000000-0000-0000-0000-${value.toRadixString(16).padLeft(12, '0')}';
