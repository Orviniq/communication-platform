import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_outbound_dispatcher.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/development_in_memory_group_mls.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/groups/infrastructure/pairwise_group_outbound_envelope_adapter.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/storage_fault_injection.dart';

/// Crash and transaction-failure coverage for the leg between the piece-18
/// compare-and-swap commit and the network, run against the real Drift group
/// repository, the real durable pairwise outbox, and the real fan-out
/// coordinator. Only the device resolver, the prekey claim, and the native
/// encryption call are stand-ins, and the encryption stand-in counts its own
/// invocations, which is how "the retry never advanced the ratchet twice"
/// becomes an assertion instead of a claim.
///
/// The design ordering under test, from `docs/local-data-model.md` and
/// `docs/sync-engine.md`:
///
///   T1  opaque MLS state + accepted fact + projections + exact prepared
///       outbound object, one compare-and-swap transaction
///   T2  per-recipient Double Ratchet envelopes into the durable outbox, one
///       transaction per recipient user, idempotent on the operation id
///   T3  the group object is marked routed
///   T4  network I/O over the persisted exact ciphertext
///
/// Every gap between those steps is a place a process can die, and every one
/// of them must leave work that the next run either finishes or discards
/// whole. None of the steps may be merged: T2 and T3 cannot join T1 because
/// encryption must not run inside a write transaction, and T4 cannot join
/// anything because it is not transactional at all.
const _owner = '10000000-0000-4000-8000-000000000001';
const _ownerDevice = '20000000-0000-4000-8000-000000000001';
const _ownerSecondDevice = '20000000-0000-4000-8000-000000000002';
const _member = '30000000-0000-4000-8000-000000000001';
const _memberDevice = '40000000-0000-4000-8000-000000000001';
const _second = '50000000-0000-4000-8000-000000000001';
const _secondDevice = '60000000-0000-4000-8000-000000000001';
const _deviceStateSecretId = 'current-device-key-state-v1';

void main() {
  late LocalDatabase database;
  late DriftGroupRepository groups;
  late DriftPairwiseTransportStore pairwise;
  late _Resolver resolver;
  late _Crypto crypto;
  late GroupOutboundDispatcher dispatcher;
  late StorageFaultInjector faults;

  Future<void> wire(LocalDatabase open) async {
    database = open;
    groups = DriftGroupRepository(open);
    pairwise = DriftPairwiseTransportStore(open);
    faults = StorageFaultInjector(open);
    dispatcher = GroupOutboundDispatcher(
      repository: groups,
      envelopes: PairwiseGroupOutboundEnvelopeAdapter(
        PairwiseFanoutCoordinator(
          store: pairwise,
          liveDevices: resolver,
          claims: _Claims(resolver),
          crypto: crypto,
          clock: const _Clock(),
        ),
      ),
    );
  }

  Future<Result<GroupOutboundDispatchReport>> dispatch() => dispatcher
      .dispatchPending(currentUserId: _owner, currentDeviceId: _ownerDevice);

  setUp(() async {
    resolver = _Resolver({
      _owner: [
        _device(_owner, _ownerDevice),
        _device(_owner, _ownerSecondDevice),
      ],
      _member: [_device(_member, _memberDevice)],
      _second: [_device(_second, _secondDevice)],
    });
    crypto = _Crypto();
    await wire(LocalDatabase(NativeDatabase.memory()));
    await _seed(database);
  });

  tearDown(() => database.close());

  test(
    'a group created but never dispatched stays exactly dispatchable',
    () async {
      await _create(groups, [_member]);

      // Nothing ran after T1. The object is durable, unrouted, and untouched.
      final pending =
          await groups.readPendingOutbound()
              as Success<List<GroupOutboundWork>>;
      expect(pending.value, hasLength(1));
      expect(await database.select(database.outboxOperations).get(), isEmpty);
      expect(crypto.calls, isEmpty);

      expect(await dispatch(), isA<Success<GroupOutboundDispatchReport>>());
      expect(
        await database.select(database.outboxOperations).get(),
        hasLength(2),
      );
      expect(await _deliveryState(database), 2);
    },
  );

  test('an interruption before the routing marker never re-encrypts', () async {
    await _create(groups, [_member]);
    // T2 completes, then the process dies before T3. This is the widest
    // window in the whole path: the envelopes are already durable and the
    // group object still looks unrouted, so the next run walks it again.
    await faults.failOn('group_outbound_objects', InjectedWrite.update);

    final interrupted = await dispatch();

    expect(
      (interrupted as FailureResult<GroupOutboundDispatchReport>).failure,
      const StorageFailure(StorageFailureKind.unavailable),
    );
    expect(await _deliveryState(database), 1);
    final queued = await _outbox(database);
    expect(queued, hasLength(2));
    expect(crypto.calls, hasLength(2));

    await faults.repair();
    final resumed = await dispatch();

    expect(resumed, isA<Success<GroupOutboundDispatchReport>>());
    expect(await _deliveryState(database), 2);
    // The exact bytes, the same rows, and no second ratchet step.
    expect(crypto.calls, hasLength(2));
    final after = await _outbox(database);
    expect(after.map((row) => row.recipientDeviceId), [
      _ownerSecondDevice,
      _memberDevice,
    ]);
    for (var index = 0; index < after.length; index += 1) {
      expect(
        after[index].exactRecipientCiphertext,
        orderedEquals(queued[index].exactRecipientCiphertext),
      );
    }
    expect(
      (await database.select(database.pairwiseSessions).get()).map(
        (row) => row.stateVersion,
      ),
      everyElement(1),
    );
  });

  test('a part-way fan-out failure resumes without duplicating work', () async {
    await _create(groups, [_member, _second]);
    resolver.failFor = _second;

    final interrupted = await dispatch();

    expect(interrupted, isA<FailureResult<GroupOutboundDispatchReport>>());
    expect(await _deliveryState(database), 1);
    // The first recipient's envelopes are durable; the second has none.
    expect((await _outbox(database)).map((row) => row.recipientDeviceId), [
      _ownerSecondDevice,
      _memberDevice,
    ]);
    expect(crypto.calls, hasLength(2));

    resolver.failFor = null;
    final resumed = await dispatch();

    expect(resumed, isA<Success<GroupOutboundDispatchReport>>());
    expect(await _deliveryState(database), 2);
    expect((await _outbox(database)).map((row) => row.recipientDeviceId), [
      _ownerSecondDevice,
      _memberDevice,
      _secondDevice,
    ]);
    // Two devices were already encrypted for; only the third one was new.
    expect(crypto.calls, hasLength(3));
  });

  test('a group with two remote recipients reaches both of them', () async {
    // One logical group object becomes one pairwise operation per recipient
    // user, so nothing about the send may be keyed on the group event id
    // alone. Two remote members is the smallest case that proves it.
    await _create(groups, [_member, _second]);

    final result = await dispatch();

    expect(result, isA<Success<GroupOutboundDispatchReport>>());
    expect(await _deliveryState(database), 2);
    expect((await _outbox(database)).map((row) => row.recipientDeviceId), [
      _ownerSecondDevice,
      _memberDevice,
      _secondDevice,
    ]);
    expect(crypto.calls, hasLength(3));
  });

  test(
    'a failed outbox transaction queues nothing and rolls the ratchet back',
    () async {
      await _create(groups, [_member]);
      await faults.failOn('outbox_operations', InjectedWrite.insert);

      final interrupted = await dispatch();

      expect(interrupted, isA<FailureResult<GroupOutboundDispatchReport>>());
      expect(await database.select(database.outboxOperations).get(), isEmpty);
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      expect(
        await database.select(database.pairwiseLocalApplications).get(),
        isEmpty,
      );
      expect(await _deliveryState(database), 1);

      await faults.repair();

      expect(await dispatch(), isA<Success<GroupOutboundDispatchReport>>());
      expect(await _deliveryState(database), 2);
      expect(
        await database.select(database.outboxOperations).get(),
        hasLength(2),
      );
    },
  );

  test(
    'a re-dispatch after the relay accepted the batch sends nothing new',
    () async {
      await _create(groups, [_member]);
      await faults.failOn('group_outbound_objects', InjectedWrite.update);
      expect(
        await dispatch(),
        isA<FailureResult<GroupOutboundDispatchReport>>(),
      );
      await faults.repair();

      // T4 ran on the envelopes T2 persisted, even though T3 never did. The
      // accepted targets must still satisfy the next dispatch pass, or the
      // group object would be stuck unrouted while its ciphertext is long gone.
      final sync = DriftSyncStore(database);
      final now = DateTime.utc(2026, 8, 18, 10);
      var sentTargets = 0;
      while (true) {
        final next = await sync.beginNextOutboxBatch(now: now);
        final batch = (next as Success<OutboxBatch?>).value;
        if (batch == null) break;
        sentTargets += batch.targets.length;
        await sync.recordOutboxAcceptance(
          batch: batch,
          acceptance: OutboxAcceptance(
            accepted: batch.targets.length,
            staleDeviceIds: const {},
          ),
          now: now,
          retryFullAt: now.add(const Duration(minutes: 5)),
        );
      }
      expect(sentTargets, 2);

      final resumed = await dispatch();

      expect(resumed, isA<Success<GroupOutboundDispatchReport>>());
      expect(await _deliveryState(database), 2);
      expect(crypto.calls, hasLength(2));
      expect(
        (await _outbox(database)).map((row) => row.attemptState),
        everyElement(OutboxAttemptState.accepted.index),
      );
    },
  );

  test('one unroutable group never blocks another', () async {
    // Ordered by creation, so the stuck one is walked first every pass. If a
    // failure ended the pass, the healthy group would never be transmitted -
    // durable, resumable in principle, and permanently stalled in practice.
    final blocked = await _create(groups, [_second], seed: 810);
    final healthy = await _create(groups, [_member], seed: 820);
    await _orderWork(database, blocked, healthy);
    resolver.failFor = _second;

    final result = await dispatch();

    expect(result, isA<FailureResult<GroupOutboundDispatchReport>>());
    expect(await _deliveryStateOf(database, blocked), 1);
    expect(await _deliveryStateOf(database, healthy), 2);
    expect((await _outbox(database)).map((row) => row.recipientDeviceId), [
      _ownerSecondDevice,
      _memberDevice,
    ]);
  });

  test('routed work is never dispatched again after a restart', () async {
    final restartable = await RestartableDatabase.create('group-outbound-');
    addTearDown(restartable.dispose);
    await wire(restartable.database);
    await _seed(restartable.database);
    await _create(groups, [_member]);
    expect(await dispatch(), isA<Success<GroupOutboundDispatchReport>>());

    await wire(await restartable.restart());

    expect(
      (await groups.readPendingOutbound() as Success<List<GroupOutboundWork>>)
          .value,
      isEmpty,
    );
    expect(await dispatch(), isA<Success<GroupOutboundDispatchReport>>());
    expect(crypto.calls, hasLength(2));
    expect(
      await restartable.database
          .select(restartable.database.outboxOperations)
          .get(),
      hasLength(2),
    );
  });

  test('unrouted work survives a restart and finishes exactly once', () async {
    final restartable = await RestartableDatabase.create('group-unrouted-');
    addTearDown(restartable.dispose);
    await wire(restartable.database);
    await _seed(restartable.database);
    await _create(groups, [_member]);
    await faults.failOn('group_outbound_objects', InjectedWrite.update);
    expect(await dispatch(), isA<FailureResult<GroupOutboundDispatchReport>>());

    // The injected fault lives on the connection, so the restart is also the
    // recovery: durable state alone has to carry the unfinished operation.
    await wire(await restartable.restart());

    expect(
      (await groups.readPendingOutbound() as Success<List<GroupOutboundWork>>)
          .value,
      hasLength(1),
    );
    expect(await dispatch(), isA<Success<GroupOutboundDispatchReport>>());
    expect(await _deliveryState(restartable.database), 2);
    expect(crypto.calls, hasLength(2));
    expect(
      await restartable.database
          .select(restartable.database.outboxOperations)
          .get(),
      hasLength(2),
    );
  });
}

Future<GroupState> _create(
  DriftGroupRepository repository,
  List<String> members, {
  int seed = 800,
}) async {
  final created =
      await CreateGroup(
            repository: repository,
            crypto: DevelopmentInMemoryGroupMls.forTests(seed: seed),
            clock: const _Clock(),
            developmentPreviewOnly: false,
          )(
            currentUserId: _owner,
            currentDeviceId: _ownerDevice,
            ownerDisplayName: 'Owner',
            metadata: GroupMetadata(name: 'Beta $seed'),
            selectedMembers: [
              for (final member in members)
                GroupMember(
                  userId: member,
                  displayName: 'Member',
                  role: GroupRole.member,
                  deviceIds: [
                    member == _member ? _memberDevice : _secondDevice,
                  ],
                ),
            ],
          )
          as Success<GroupState>;
  return created.value;
}

Future<void> _seed(LocalDatabase database) async {
  for (final userId in const [_owner, _member, _second]) {
    await database
        .into(database.users)
        .insert(
          UsersCompanion.insert(
            userId: userId,
            activated: true,
            directoryEntryCiphertext: Uint8List.fromList([1]),
            localState: 0,
          ),
        );
  }
  await database
      .into(database.secureSecrets)
      .insert(
        SecureSecretsCompanion.insert(
          secretId: _deviceStateSecretId,
          kind: 0,
          wrappedCiphertextOrOpaqueHandle: Uint8List.fromList([7]),
          formatVersion: 2,
        ),
      );
}

/// Forces the pending-work order so the stuck group is always walked first.
Future<void> _orderWork(
  LocalDatabase database,
  GroupState first,
  GroupState second,
) async {
  var offset = 0;
  for (final group in [first, second]) {
    await (database.update(
      database.groupOutboundObjects,
    )..where((row) => row.groupId.equals(group.groupId))).write(
      GroupOutboundObjectsCompanion(
        createdAt: Value(
          DateTime.utc(2026, 8, 18).add(Duration(minutes: offset)),
        ),
      ),
    );
    offset += 1;
  }
}

Future<int> _deliveryState(LocalDatabase database) async =>
    (await database.select(database.groupOutboundObjects).getSingle())
        .deliveryState;

Future<int> _deliveryStateOf(LocalDatabase database, GroupState group) async =>
    (await (database.select(
          database.groupOutboundObjects,
        )..where((row) => row.groupId.equals(group.groupId))).getSingle())
        .deliveryState;

Future<List<OutboxOperation>> _outbox(LocalDatabase database) =>
    (database.select(
      database.outboxOperations,
    )..orderBy([(row) => OrderingTerm.asc(row.recipientDeviceId)])).get();

VerifiedPairwiseLiveDevice _device(String userId, String deviceId) =>
    VerifiedPairwiseLiveDevice(
      userId: userId,
      device: PeerPublicDevice(
        deviceId: deviceId,
        identityPublic: _bytes(64, 1),
        registrationId: 1,
        bundleVersion: 1,
        crossSignature: _bytes(64, 2),
      ),
      selfSigningPublic: _bytes(32, 3),
    );

Uint8List _bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker & 0xff));

final class _Resolver implements PairwiseLiveDeviceResolverPort {
  _Resolver(this.devices);

  final Map<String, List<VerifiedPairwiseLiveDevice>> devices;
  String? failFor;

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async => userId == failFor
      ? const Result.failure(TransportFailure(TransportFailureKind.timeout))
      : Result.success(devices[userId]!);
}

final class _Claims implements PairwiseSelectiveClaimPort {
  const _Claims(this.resolver);

  final _Resolver resolver;

  @override
  Future<Result<VerifiedPairwiseClaims>> claimVerifiedDevices({
    required String userId,
    required List<String> deviceIds,
  }) async {
    final live = resolver.devices[userId]!;
    return Result.success(
      VerifiedPairwiseClaims(
        liveDevices: live,
        claims: {
          for (final deviceId in deviceIds)
            deviceId: VerifiedPairwiseClaim(
              device: live.singleWhere((device) => device.deviceId == deviceId),
              bundle: _bundle(deviceId),
            ),
        },
      ),
    );
  }
}

ClaimedPrekeyBundle _bundle(String deviceId) => ClaimedPrekeyBundle(
  deviceId: deviceId,
  registrationId: 1,
  identityPublic: _bytes(64, 1),
  signedPrekeyId: 1,
  signedPrekeyPublic: _bytes(32, 2),
  signedPrekeySignature: _bytes(64, 3),
  crossSignature: _bytes(64, 4),
  bundleVersion: 1,
  pqSignedPrekeyId: 2,
  pqSignedPrekeyPublic: _bytes(1184, 5),
  pqSignedPrekeySignature: _bytes(64, 6),
);

/// Stands in for the reviewed native ratchet step and records every call, so a
/// retry that quietly re-encrypted would show up as an extra invocation rather
/// than as identical-looking bytes.
final class _Crypto implements PairwiseOutboundPreparationPort {
  final calls = <String>[];

  @override
  Future<Result<PairwisePreparedOutbound>> prepareOutbound({
    required String currentDeviceId,
    required VerifiedPairwiseLiveDevice recipient,
    required Uint8List openedOpaquePayload,
    required int migrationUnixDay,
    required PairwisePreparationContext context,
    required VerifiedPairwiseClaim? claim,
  }) async {
    calls.add(recipient.deviceId);
    final marker = calls.length;
    return Result.success(
      PairwisePreparedOutbound(
        exactCiphertext: _bytes(1024, marker),
        sessionId: _bytes(16, marker),
        nextOpaqueSessionState: _bytes(32, marker),
        nextSkippedKeyCount: 0,
        disposition: PairwiseSessionDisposition.primaryBidirectional,
      ),
    );
  }
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 8, 18, 9);
}
