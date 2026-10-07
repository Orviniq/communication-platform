import 'dart:typed_data';

import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/protocol/pairwise_sync_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:communication_platform/features/voice/application/room_inbound_coordinator.dart';
import 'package:communication_platform/features/voice/application/room_outbound_dispatcher.dart';
import 'package:communication_platform/features/voice/application/room_session_starter.dart';
import 'package:communication_platform/features/voice/application/room_use_cases.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';
import 'package:communication_platform/features/voice/infrastructure/drift_room_repository.dart';
import 'package:communication_platform/features/voice/infrastructure/pairwise_room_adapters.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

/// Room events between devices, each with its own database, over the real
/// room stores, the real pairwise fan-out and outbox, and the real inbox
/// transaction (`backend/CLIENT_CONTRACT.md` §N; `voice-signalling-v1.md`,
/// Part 1).
///
/// Only the ratchet step, the prekey claim and the native signing call are
/// stand-ins: a "ciphertext" here is the payload framed with its session id and
/// padded to a bucket, which is what lets one device's outbox be read by the
/// other's inbox.
void main() {
  late _Network network;
  late _Device alice;
  late _Device bob;

  setUp(() async {
    network = _Network({
      roomAlice: [roomAlicePhone],
      roomBob: [roomBobPhone],
      roomCarol: [roomCarolPhone],
    });
    alice = await _Device.start(roomAlice, roomAlicePhone, network);
    bob = await _Device.start(roomBob, roomBobPhone, network);
  });

  tearDown(() async {
    await alice.database.close();
    await bob.database.close();
  });

  test(
    'a room event round-trips over the fan-out between two devices',
    () async {
      final created =
          (await alice.create(
                    currentUserId: roomAlice,
                    currentDeviceId: roomAlicePhone,
                    name: 'Standup',
                    memberUserIds: const [roomBob],
                  )
                  as Success<RoomState>)
              .value;
      await alice.dispatch();

      // The create's own copy started the pair's session: Bob's bundle was
      // claimed for it, on the durable path.
      expect(network.claimedDevices, [roomBobPhone]);
      expect(await bob.receiveFrom(alice), 1);
      final held = (await bob.room(created.roomId))!;
      expect(held.name, 'Standup');
      expect(held.members, created.members);
      expect(held.controlStateHash, created.controlStateHash);

      final renamed =
          (await bob.mutate(
                    roomId: created.roomId,
                    actorUserId: roomBob,
                    actorDeviceId: roomBobPhone,
                    operation: const RenameRoomOperation('Daily'),
                  )
                  as Success<RoomState>)
              .value;
      await bob.dispatch();
      expect(await alice.receiveFrom(bob), 1);

      final onAlice = (await alice.room(created.roomId))!;
      final onBob = (await bob.room(created.roomId))!;
      expect(onAlice.name, 'Daily');
      expect(onAlice.controlRevision, 2);
      expect(onAlice.controlStateHash, renamed.controlStateHash);
      expect(onAlice.members, onBob.members);
      expect(onAlice.controlStateHash, onBob.controlStateHash);
      // Bob answered on the session Alice's first message started.
      expect(network.claimedDevices, [roomBobPhone]);
      expect(
        await alice.database.select(alice.database.roomControlEvents).get(),
        hasLength(2),
      );
    },
  );

  test(
    'a missing session is started by a room request, and answered',
    () async {
      // Carol's device receives the create too; she and Bob have never
      // exchanged a message. Carol's phone sorts above Bob's, so Bob starts it.
      final carol = await _Device.start(roomCarol, roomCarolPhone, network);
      addTearDown(carol.database.close);
      final created =
          (await alice.create(
                    currentUserId: roomAlice,
                    currentDeviceId: roomAlicePhone,
                    name: 'Standup',
                    memberUserIds: const [roomBob, roomCarol],
                  )
                  as Success<RoomState>)
              .value;
      await alice.dispatch();
      await bob.receiveFrom(alice);
      await carol.receiveFrom(alice);
      network.claimedDevices.clear();

      expect(await bob.startDueSessions(), 1);
      expect(await carol.startDueSessions(), 0);
      await bob.dispatch();

      expect(network.claimedDevices, [roomCarolPhone]);
      expect(await carol.receiveFrom(bob), 1);
      final request = carol.lastReceived!;
      expect(
        RoomSyncPayloadCodec.decode(request),
        isA<RoomStateRequestPayload>()
            .having((payload) => payload.roomId, 'room', created.roomId)
            .having((payload) => payload.haveRevision, 'revision', 1),
      );

      // Carol answers on the session Bob's request started: no second claim.
      await carol.dispatch();
      expect(network.claimedDevices, [roomCarolPhone]);
      expect(await bob.receiveFrom(carol), 1);
      final answer = RoomSyncPayloadCodec.decode(bob.lastReceived!);
      expect(answer, isA<RoomTranscriptPayload>());
      expect((answer as RoomTranscriptPayload).entries, isEmpty);
      expect(await bob.hasSessionWith(roomCarol, roomCarolPhone), isTrue);
      expect(await carol.hasSessionWith(roomBob, roomBobPhone), isTrue);
    },
  );
}

/// Who each account's devices are, and every bundle anybody claimed.
final class _Network {
  _Network(this.devicesByUser);

  final Map<String, List<String>> devicesByUser;
  final claimedDevices = <String>[];

  late final resolver = _Resolver(this);
  late final claims = _Claims(this);

  VerifiedPairwiseLiveDevice device(String userId, String deviceId) =>
      VerifiedPairwiseLiveDevice(
        userId: userId,
        device: PeerPublicDevice(
          deviceId: deviceId,
          // `ik_pub`: the device signing key, then the identity key.
          identityPublic: Uint8List.fromList([
            ...roomDeviceKey(deviceId),
            ...List<int>.filled(32, 9),
          ]),
          registrationId: 1,
          bundleVersion: 1,
          crossSignature: Uint8List(64),
        ),
        selfSigningPublic: Uint8List(32),
      );
}

final class _Resolver implements PairwiseLiveDeviceResolverPort {
  const _Resolver(this.network);

  final _Network network;

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async => Result.success(_devicesOf(userId));

  @override
  Future<Result<Map<String, List<VerifiedPairwiseLiveDevice>>>>
  resolveVerifiedLiveDevicesForUsers(List<String> userIds) async =>
      Result.success({
        for (final userId in userIds) userId: _devicesOf(userId),
      });

  List<VerifiedPairwiseLiveDevice> _devicesOf(String userId) => [
    for (final deviceId in network.devicesByUser[userId] ?? const <String>[])
      network.device(userId, deviceId),
  ];
}

final class _Claims implements PairwiseSelectiveClaimPort {
  const _Claims(this.network);

  final _Network network;

  @override
  Future<Result<VerifiedPairwiseClaims>> claimVerifiedDevices({
    required String userId,
    required List<String> deviceIds,
  }) async {
    network.claimedDevices.addAll(deviceIds);
    final live = [
      for (final deviceId in network.devicesByUser[userId]!)
        network.device(userId, deviceId),
    ];
    return Result.success(
      VerifiedPairwiseClaims(
        liveDevices: live,
        claims: {
          for (final deviceId in deviceIds)
            deviceId: VerifiedPairwiseClaim(
              device: live.singleWhere((device) => device.deviceId == deviceId),
              bundle: ClaimedPrekeyBundle(
                deviceId: deviceId,
                registrationId: 1,
                identityPublic: Uint8List(64),
                signedPrekeyId: 1,
                signedPrekeyPublic: Uint8List(32),
                signedPrekeySignature: Uint8List(64),
                crossSignature: Uint8List(64),
                bundleVersion: 1,
                pqSignedPrekeyId: 2,
                pqSignedPrekeyPublic: Uint8List(1184),
                pqSignedPrekeySignature: Uint8List(64),
              ),
            ),
        },
      ),
    );
  }
}

/// Stands in for the reviewed ratchet step: the "ciphertext" is the session id,
/// the payload's length and the payload, padded to the smallest bucket.
final class _PlainSeal implements PairwiseOutboundPreparationPort {
  _PlainSeal(this.deviceId);

  final String deviceId;
  var _sessions = 0;

  @override
  Future<Result<PairwisePreparedOutbound>> prepareOutbound({
    required String currentDeviceId,
    required VerifiedPairwiseLiveDevice recipient,
    required Uint8List openedOpaquePayload,
    required int migrationUnixDay,
    required PairwisePreparationContext context,
    required VerifiedPairwiseClaim? claim,
  }) async {
    final sessionId =
        context.primary?.sessionId ??
        Uint8List.fromList([
          ...deviceId.codeUnits.take(8),
          ...recipient.deviceId.codeUnits.take(7),
          _sessions += 1,
        ]);
    final framed = BytesBuilder()
      ..add(sessionId)
      ..add(
        Uint8List(4)
          ..buffer.asByteData().setUint32(0, openedOpaquePayload.length),
      )
      ..add(openedOpaquePayload);
    final bucket = [
      1024,
      4096,
      16384,
      65536,
    ].firstWhere((size) => size >= framed.length);
    final ciphertext = Uint8List(bucket)..setAll(0, framed.takeBytes());
    return Result.success(
      PairwisePreparedOutbound(
        exactCiphertext: ciphertext,
        sessionId: sessionId,
        nextOpaqueSessionState: Uint8List.fromList([
          ...sessionId,
          (context.primary?.stateVersion ?? 0) + 1,
        ]),
        nextSkippedKeyCount: 0,
        disposition: PairwiseSessionDisposition.primaryBidirectional,
      ),
    );
  }
}

final class _Device {
  _Device._(this.userId, this.deviceId, this.network, this.database);

  static Future<_Device> start(
    String userId,
    String deviceId,
    _Network network,
  ) async {
    final device = _Device._(
      userId,
      deviceId,
      network,
      LocalDatabase(NativeDatabase.memory()),
    );
    await device.database
        .into(device.database.secureSecrets)
        .insert(
          SecureSecretsCompanion.insert(
            secretId: 'current-device-key-state-v1',
            kind: 0,
            wrappedCiphertextOrOpaqueHandle: Uint8List.fromList([7]),
            formatVersion: 2,
          ),
        );
    return device;
  }

  final String userId;
  final String deviceId;
  final _Network network;
  final LocalDatabase database;
  final clock = FakeRoomClock();
  final _handedOut = <String>{};
  var _sequence = 0;
  Uint8List? lastReceived;

  late final rooms = DriftRoomRepository(database);
  late final pairwise = DriftPairwiseTransportStore(database);
  late final sync = DriftSyncStore(database);
  late final fanout = PairwiseFanoutCoordinator(
    store: pairwise,
    liveDevices: network.resolver,
    claims: network.claims,
    crypto: _PlainSeal(deviceId),
    clock: clock,
  );
  late final roomDevices = PairwiseRoomLiveDeviceAdapter(network.resolver);
  late final _crypto = FakeRoomControlCore(localDeviceId: deviceId);
  late final create = CreateRoom(
    repository: rooms,
    crypto: _crypto,
    identity: FakeRoomIdentity(deviceId.codeUnitAt(0)),
    clock: clock,
  );
  late final mutate = MutateRoom(
    repository: rooms,
    crypto: _crypto,
    identity: FakeRoomIdentity(deviceId.codeUnitAt(1)),
    clock: clock,
  );
  late final inbound = RoomInboundCoordinator(
    repository: rooms,
    crypto: _crypto,
    liveDevices: roomDevices,
    clock: clock,
    localUserId: userId,
  );
  late final starter = RoomSessionStarter(
    repository: rooms,
    liveDevices: roomDevices,
    sessions: StoredRoomPairwiseSessions(pairwise),
    clock: clock,
    currentUserId: userId,
    currentDeviceId: deviceId,
  );

  Future<void> dispatch() async {
    final report = await RoomOutboundDispatcher(
      repository: rooms,
      envelopes: PairwiseRoomOutboundEnvelopeAdapter(fanout),
    ).dispatchPending(currentUserId: userId, currentDeviceId: deviceId);
    expect(report, isA<Success<RoomOutboundDispatchReport>>());
  }

  Future<int> startDueSessions() async =>
      (await starter.startDueSessions() as Success<int>).value;

  Future<RoomState?> room(String roomId) async =>
      (await rooms.readStoredRoom(roomId) as Success<RoomState?>).value;

  Future<bool> hasSessionWith(
    String remoteUserId,
    String remoteDeviceId,
  ) async =>
      (await StoredRoomPairwiseSessions(pairwise).hasSession(
                localDeviceId: deviceId,
                remoteUserId: remoteUserId,
                remoteDeviceId: remoteDeviceId,
              )
              as Success<bool>)
          .value;

  /// Takes every copy [from] queued for this device and commits each the way
  /// the delivery cycle does: persisted, inspected, then one transaction for
  /// the ratchet step and the room change together.
  Future<int> receiveFrom(_Device from) async {
    final rows =
        await (from.database.select(from.database.outboxOperations)
              ..where((row) => row.recipientDeviceId.equals(deviceId))
              ..orderBy([(row) => OrderingTerm.asc(row.operationId)]))
            .get();
    var received = 0;
    for (final row in rows) {
      if (!from._handedOut.add(row.operationId)) continue;
      final bytes = row.exactRecipientCiphertext;
      final sessionId = Uint8List.sublistView(bytes, 0, 16);
      final length = ByteData.sublistView(bytes, 16, 20).getUint32(0);
      final payload = Uint8List.fromList(bytes.sublist(20, 20 + length));
      await _commitReceive(from, sessionId, payload, bytes);
      lastReceived = payload;
      received += 1;
    }
    return received;
  }

  Future<void> _commitReceive(
    _Device from,
    Uint8List sessionId,
    Uint8List payload,
    Uint8List ciphertext,
  ) async {
    _sequence += 1;
    final envelopeId =
        '9${deviceId.substring(1, 8)}-0000-4000-8000-'
        '${_sequence.toRadixString(16).padLeft(12, '0')}';
    await sync.persistDrainPage(
      DrainPage(
        envelopes: [
          SyncEnvelope(
            id: envelopeId,
            sequence: _sequence,
            exactCiphertext: ciphertext,
          ),
        ],
        hasMore: false,
        prunedThrough: 0,
      ),
    );
    await sync.beginNextEnvelopeInspection(now: clock.now());
    final prepared =
        (await inbound.prepare(
                  envelopeId: envelopeId,
                  senderUserId: from.userId,
                  senderDeviceId: from.deviceId,
                  payload: payload,
                )
                as Success<RoomInboundPreparation>)
            .value;
    final context =
        (await pairwise.readPreparationContext(
                  localDeviceId: deviceId,
                  remoteUserId: from.userId,
                  remoteDeviceId: from.deviceId,
                )
                as Success<PairwisePreparationContext>)
            .value;
    final version = context.primary?.stateVersion;
    final commit = switch (prepared) {
      RoomInboundChange(:final commit) => commit,
      RoomInboundNoChange() => null,
    };
    final committed = await sync.commitOpaqueInspection(
      envelopeId: envelopeId,
      inspection: OpaqueEnvelopeInspection(
        opaqueEventId: prepared.opaqueEventId,
        dependency: commit == null
            ? EnvelopeDependency.directOrLocal
            : EnvelopeDependency.groupState,
        roomCommit: commit,
        pairwiseCommit: PairwiseSyncReceiveCommit(
          envelopeId: envelopeId,
          opaqueEventId: prepared.opaqueEventId,
          senderUserId: from.userId,
          senderDeviceId: from.deviceId,
          replayMarker: Uint8List.fromList(
            List<int>.generate(32, (index) => (_sequence * 31 + index) & 0xff),
          ),
          openedOpaquePayload: payload,
          sessionTransition: PairwiseSyncSessionTransition(
            localDeviceId: deviceId,
            remoteUserId: from.userId,
            remoteDeviceId: from.deviceId,
            sessionId: sessionId,
            nextOpaqueState: Uint8List.fromList([...sessionId, _sequence]),
            expectedStateVersion: version,
            nextStateVersion: (version ?? 0) + 1,
            nextSkippedKeyCount: 0,
            disposition: PairwiseSessionDisposition.primaryBidirectional.index,
            repairState: PairwiseRepairState.ready.index,
          ),
        ),
      ),
    );
    expect(committed, isA<Success<bool>>());
  }
}
