import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/client_authentication_service.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

const _ownUserId = '00000000-0000-4000-8000-0000000000a1';
const _ownDeviceId = '00000000-0000-4000-8000-0000000000a2';
const _peerUserId = '00000000-0000-4000-8000-0000000000b1';
const _peerDeviceId = '00000000-0000-4000-8000-0000000000b2';
const _peerSecondDeviceId = '00000000-0000-4000-8000-0000000000b3';

/// A send verifies its recipients against what the server holds when it is
/// made, with nothing between the two.
///
/// The real fan-out coordinator runs over the real authentication service,
/// and the service talks straight to a fake server whose tags move with its
/// state, so `unchanged` answers a tag only while that tag still holds. Each
/// change below happens on the server alone: no `stale_devices` response, no
/// envelope from a new device, no safety number and no time passing. The next
/// send has nothing to go on but its own read, and the devices it seals
/// ciphertext for are the answer.
void main() {
  group('every send reads its recipients from the server', () {
    test('two sends to one peer read it twice', () async {
      final harness = _Harness()..establishedSession();

      await harness.send('application:01');
      await harness.send('application:02');

      // The second read is a request like the first. It carries the tags the
      // first one stored, so the server answers `unchanged` with no body.
      expect(harness.remote.batches, hasLength(2));
      expect(harness.remote.batches.last.map((query) => query.etag), [
        harness.remote.peerStateTagOf(_peerUserId),
        harness.remote.peerStateTagOf(_ownUserId),
      ]);
      expect(
        harness.remote.answered.last.values,
        everyElement(isA<PeerStateUnchanged>()),
      );
      expect(harness.encryptedTo, [_peerDeviceId, _peerDeviceId]);
    });

    test('a device revoked since the last send is not encrypted to', () async {
      final harness = _Harness()..establishedSession(peerDevices: 2);
      await harness.send('application:03');
      expect(harness.encryptedTo, [_peerDeviceId, _peerSecondDeviceId]);

      harness.remote.revokeSecondPeerDevice();
      harness.outbound.calls.clear();
      await harness.send('application:04');

      expect(
        harness.remote.answered.last[_peerUserId],
        isA<PeerStateUpdated>(),
      );
      expect(harness.encryptedTo, [_peerDeviceId]);
    });

    test('a device added since the last send is encrypted to', () async {
      final harness = _Harness()..establishedSession();
      await harness.send('application:05');
      expect(harness.encryptedTo, [_peerDeviceId]);

      harness.remote.addSecondPeerDevice();
      harness.outbound.calls.clear();
      await harness.send('application:06');

      expect(harness.encryptedTo, [_peerDeviceId, _peerSecondDeviceId]);
    });

    test('a master key replaced since the last send withholds it', () async {
      final harness = _Harness()..establishedSession();
      await harness.send('application:07');

      harness.remote.replacePeerMaster();
      harness.outbound.calls.clear();
      final blocked = await harness.send('application:08');

      expect(blocked, isA<FailureResult<DurablePairwiseOperation>>());
      expect(
        harness.local.trustOf(_peerUserId)?.state,
        ContactTrustState.masterKeyChanged,
      );
      expect(harness.encryptedTo, isEmpty);
    });

    test('a fork recorded since the last send withholds it unread', () async {
      final harness = _Harness()..establishedSession();
      await harness.send('application:09');

      harness.local.anyFork = true;
      harness.outbound.calls.clear();
      final blocked = await harness.send('application:10');

      expect(blocked, isA<FailureResult<DurablePairwiseOperation>>());
      expect(harness.remote.batches, hasLength(1));
      expect(harness.encryptedTo, isEmpty);
    });
  });

  group('a send that must start a session', () {
    test('reads the peer again for every claim', () async {
      final harness = _Harness()..noSession();

      await harness.send('application:11');
      await harness.gossip('device-head-gossip:11');

      // Each establishment resolves the peer through the per-user reads
      // before it claims, and the second is asked of the server as the first
      // was. A memory of the first used to answer it.
      expect(harness.remote.batches, hasLength(2));
      expect(harness.remote.identityCalls, {_peerUserId: 2});
      expect(harness.remote.deviceCalls, {_peerUserId: 2});
      expect(harness.remote.claimCalls, {_peerUserId: 2});
    });

    test('asks again with the tags it holds, and is told 304', () async {
      final harness = _Harness()..noSession();

      await harness.send('application:14');
      await harness.gossip('device-head-gossip:14');

      // The send's batched read stored the identity read's tag beside the
      // identity it carried, so each claim asks for the identity with that
      // tag, and the device list with its own. Nothing moved, so all four
      // answers are a `304` with no body: the server was asked every time,
      // and paid for a body none of the times.
      final identityTag = harness.remote.identityTagOf(_peerUserId);
      expect(harness.remote.identityTagsSent[_peerUserId], [
        identityTag,
        identityTag,
      ]);
      expect(harness.remote.identityNotModified, {_peerUserId: 2});
      expect(harness.remote.devicesNotModified, {_peerUserId: 2});
      expect(
        harness.remote.batches.last.map((query) => query.etag),
        isNot(contains(identityTag)),
      );
    });

    test('claims nothing for a device revoked since the last claim', () async {
      final harness = _Harness()..noSession(peerDevices: 2);
      await harness.send('application:12');
      expect(harness.remote.claimedDeviceIds.single, [
        _peerDeviceId,
        _peerSecondDeviceId,
      ]);

      harness.remote.revokeSecondPeerDevice();
      harness.outbound.calls.clear();
      await harness.send('application:13');

      expect(harness.remote.claimedDeviceIds.last, [_peerDeviceId]);
      expect(harness.encryptedTo, [_peerDeviceId]);
    });
  });
}

/// The composed send path, from the server up to the ciphertext.
final class _Harness {
  _Harness() {
    service = ClientAuthenticationService(
      remote: remote,
      local: local,
      crypto: crypto,
    );
    fanout = PairwiseFanoutCoordinator(
      store: store,
      liveDevices: ContactPairwiseLiveDeviceResolverAdapter(
        delegate: service,
        currentUserId: _ownUserId,
      ),
      claims: ContactSelectivePairwiseClaimAdapter(
        delegate: service,
        currentUserId: _ownUserId,
      ),
      crypto: outbound,
      clock: clock,
    );
  }

  final _Remote remote = _Remote();
  final _Local local = _Local();
  final _Crypto crypto = _Crypto();
  final _Clock clock = _Clock();
  final _Store store = _Store();
  final _Outbound outbound = _Outbound();
  late final ClientAuthenticationService service;
  late final PairwiseFanoutCoordinator fanout;

  /// The device ids this harness actually sealed ciphertext for.
  List<String> get encryptedTo =>
      outbound.calls.map((call) => call.deviceId).toList(growable: false);

  /// A conversation already under way: both accounts known, both device sets
  /// stored as the device-list read last gave them, and a live session with
  /// every peer device.
  void establishedSession({int peerDevices = 1}) {
    remote.peerDeviceCount = peerDevices;
    _seedTrust();
    store.sessionEstablished = true;
  }

  /// The same conversation before its first message, which is the only shape
  /// that claims prekeys.
  void noSession({int peerDevices = 1}) {
    remote.peerDeviceCount = peerDevices;
    _seedTrust();
    store.sessionEstablished = false;
  }

  void _seedTrust() {
    local
      ..devices[_peerUserId] = remote.devicesOf(_peerUserId)
      ..devices[_ownUserId] = remote.devicesOf(_ownUserId)
      ..trust[_peerUserId] = ContactTrustRecord(
        userId: _peerUserId,
        state: ContactTrustState.verified,
        identity: remote.identityOf(_peerUserId),
        confirmedMasterPublic: remote.identityOf(_peerUserId).masterPublic,
        attestation: UserSigningAttestation(_bytes(64, 5)),
        etag: remote.deviceTagOf(_peerUserId),
        logHeadSequence: 0,
        logHeadHash: _bytes(32, 11),
      )
      ..trust[_ownUserId] = ContactTrustRecord(
        userId: _ownUserId,
        state: ContactTrustState.unverified,
        identity: remote.identityOf(_ownUserId),
        etag: remote.deviceTagOf(_ownUserId),
        logHeadSequence: 0,
        logHeadHash: _bytes(32, 11),
      );
  }

  Future<Result<DurablePairwiseOperation>> send(String operationId) =>
      fanout.prepareAndQueue(
        operationId: operationId,
        eventId: operationId.split(':').last,
        currentUserId: _ownUserId,
        currentDeviceId: _ownDeviceId,
        peerUserId: _peerUserId,
        openedOpaquePayload: _bytes(8, 3),
      );

  /// The device-log advertisement a send owes its peer, which is a second
  /// fan-out asking the server the same questions.
  Future<Result<DurablePairwiseOperation>> gossip(String operationId) =>
      fanout.prepareAndQueue(
        operationId: operationId,
        eventId: operationId.split(':').last,
        currentUserId: _ownUserId,
        currentDeviceId: _ownDeviceId,
        peerUserId: _peerUserId,
        openedOpaquePayload: _bytes(8, 4),
      );
}

/// The server: one peer whose devices, head and master key the test moves,
/// and this account, which stays put.
final class _Remote implements PeerIdentityRemotePort {
  final Map<String, int> identityCalls = {};
  final Map<String, int> deviceCalls = {};
  final Map<String, int> claimCalls = {};
  final List<List<String>> claimedDeviceIds = [];

  /// The tag each identity read carried, by user.
  final Map<String, List<String?>> identityTagsSent = {};

  /// Reads answered `304` with no body, by user and route.
  final Map<String, int> identityNotModified = {};
  final Map<String, int> devicesNotModified = {};

  /// Every batched read, by the queries it carried, and what it answered.
  final List<List<PeerStateQuery>> batches = [];
  final List<Map<String, PeerStateRead>> answered = [];

  int peerDeviceCount = 1;

  /// The peer's device-log head. A device set only ever changes together with
  /// an extending signed record — the service refuses a same-head change as a
  /// pending window — so every mutation below advances it.
  int peerLogHead = 0;
  Uint8List _peerMaster = _bytes(32, 21);

  void revokeSecondPeerDevice() {
    peerDeviceCount = 1;
    peerLogHead += 1;
  }

  void addSecondPeerDevice() {
    peerDeviceCount = 2;
    peerLogHead += 1;
  }

  void replacePeerMaster() => _peerMaster = _bytes(32, 77);

  int _headOf(String userId) => userId == _ownUserId ? 0 : peerLogHead;

  PeerIdentityPublic identityOf(String userId) => userId == _ownUserId
      ? PeerIdentityPublic(
          masterPublic: _bytes(32, 1),
          selfSigningPublic: _bytes(32, 2),
          userSigningPublic: _bytes(32, 3),
          masterSignature: _bytes(64, 4),
          version: 1,
        )
      : PeerIdentityPublic(
          masterPublic: _peerMaster,
          selfSigningPublic: _bytes(32, 23),
          userSigningPublic: _bytes(32, 24),
          masterSignature: _bytes(64, 25),
          version: 1,
        );

  List<PeerPublicDevice> devicesOf(String userId) => userId == _ownUserId
      ? [
          PeerPublicDevice(
            deviceId: _ownDeviceId,
            identityPublic: _bytes(64, 12),
            registrationId: 1,
            crossSignature: _bytes(64, 13),
            bundleVersion: 1,
          ),
        ]
      : [
          PeerPublicDevice(
            deviceId: _peerDeviceId,
            identityPublic: _bytes(64, 22),
            registrationId: 2,
            crossSignature: _bytes(64, 23),
            bundleVersion: 1,
          ),
          if (peerDeviceCount > 1)
            PeerPublicDevice(
              deviceId: _peerSecondDeviceId,
              identityPublic: _bytes(64, 32),
              registrationId: 3,
              crossSignature: _bytes(64, 33),
              bundleVersion: 1,
            ),
        ];

  /// The device-list read's tag, which moves with the live set and the head.
  String deviceTagOf(String userId) =>
      '"devices-${userId == _ownUserId ? 'own' : 'peer-$peerDeviceCount'}-'
      '${_headOf(userId)}"';

  /// The batched read's tag, which moves whenever anything either per-user
  /// read would serve for that user moves.
  String peerStateTagOf(String userId) => userId == _ownUserId
      ? '"peers-own"'
      : '"peers-${_peerMaster.first}-$peerDeviceCount-$peerLogHead"';

  /// The identity read's tag, which moves with the key bytes and the version
  /// and with nothing else.
  String identityTagOf(String userId) => userId == _ownUserId
      ? '"identity-own"'
      : '"identity-${_peerMaster.first}"';

  @override
  Future<Result<PeerIdentityRefresh>> fetchIdentity({
    required String userId,
    String? etag,
  }) async {
    identityCalls.update(userId, (count) => count + 1, ifAbsent: () => 1);
    (identityTagsSent[userId] ??= []).add(etag);
    if (etag == identityTagOf(userId)) {
      identityNotModified.update(
        userId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      return const Result.success(PeerIdentityNotModified());
    }
    return Result.success(
      PeerIdentityUpdated(
        identity: identityOf(userId),
        etag: identityTagOf(userId),
      ),
    );
  }

  @override
  Future<Result<PeerDeviceRefresh>> fetchDevices({
    required String userId,
    String? etag,
  }) async {
    deviceCalls.update(userId, (count) => count + 1, ifAbsent: () => 1);
    if (etag == deviceTagOf(userId)) {
      devicesNotModified.update(
        userId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      return const Result.success(PeerDevicesNotModified());
    }
    return Result.success(
      PeerDevicesUpdated(
        devices: devicesOf(userId),
        etag: deviceTagOf(userId),
        logHeadSequence: _headOf(userId),
      ),
    );
  }

  @override
  Future<Result<List<ClaimedPrekeyBundle>>> claimPrekeyBundles({
    required String userId,
    required List<String> deviceIds,
  }) async {
    claimCalls.update(userId, (count) => count + 1, ifAbsent: () => 1);
    claimedDeviceIds.add(List.unmodifiable(deviceIds));
    final devices = {
      for (final device in devicesOf(userId)) device.deviceId: device,
    };
    return Result.success([
      for (final deviceId in deviceIds) _bundleFor(devices[deviceId]!),
    ]);
  }

  @override
  Future<Result<PeerDeviceLogPage>> fetchDeviceLog({
    required String userId,
    int? after,
  }) async {
    final head = _headOf(userId);
    return Result.success(
      PeerDeviceLogPage(
        records: [
          for (var sequence = (after ?? -1) + 1; sequence <= head; sequence++)
            PeerDeviceLogRecord(sequence: sequence, blob: _bytes(8, sequence)),
        ],
        hasMore: false,
        headSequence: head,
      ),
    );
  }

  @override
  Future<Result<Map<String, PeerStateRead>>> fetchPeerStates(
    List<PeerStateQuery> peers,
  ) async {
    batches.add(List.unmodifiable(peers));
    final reads = <String, PeerStateRead>{
      for (final peer in peers)
        peer.userId: peer.etag == peerStateTagOf(peer.userId)
            ? PeerStateUnchanged(etag: peer.etag!)
            : PeerStateUpdated(
                identity: identityOf(peer.userId),
                identityEtag: identityTagOf(peer.userId),
                devices: devicesOf(peer.userId),
                logHeadSequence: _headOf(peer.userId),
                etag: peerStateTagOf(peer.userId),
              ),
    };
    answered.add(reads);
    return Result.success(reads);
  }
}

ClaimedPrekeyBundle _bundleFor(PeerPublicDevice device) => ClaimedPrekeyBundle(
  deviceId: device.deviceId,
  registrationId: device.registrationId,
  identityPublic: device.identityPublic,
  signedPrekeyId: 1,
  signedPrekeyPublic: _bytes(32, 2),
  signedPrekeySignature: _bytes(64, 3),
  crossSignature: device.crossSignature!,
  bundleVersion: device.bundleVersion!,
  pqSignedPrekeyId: 2,
  pqSignedPrekeyPublic: _bytes(1184, 5),
  pqSignedPrekeySignature: _bytes(64, 6),
);

final class _Local implements ContactLocalPort {
  final Map<String, ContactTrustRecord> trust = {};
  final Map<String, List<PeerPublicDevice>> devices = {};
  bool anyFork = false;

  ContactTrustRecord? trustOf(String userId) => trust[userId];

  @override
  Future<Result<bool>> hasAnyDeviceLogFork() async => Result.success(anyFork);

  @override
  Future<Result<ContactTrustRecord?>> readTrust(String userId) async =>
      Result.success(trust[userId]);

  @override
  Future<Result<void>> writeTrust(ContactTrustRecord record) async {
    trust[record.userId] = record;
    return const Result.success(null);
  }

  @override
  Future<Result<List<PeerPublicDevice>>> readDevices(String userId) async =>
      Result.success(devices[userId] ?? const []);

  @override
  Future<Result<void>> replaceDevices(
    String userId,
    List<PeerPublicDevice> replacement,
  ) async {
    devices[userId] = replacement;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> appendVerifiedLogRecords(
    String userId,
    List<VerifiedDeviceLogRecord> appended,
  ) async => const Result.success(null);

  @override
  Future<Result<LocalAccountIdentity>> readLocalIdentity() async =>
      Result.success(
        LocalAccountIdentity(
          userId: _ownUserId,
          deviceId: _ownDeviceId,
          username: 'own',
          identityPackage: IdentityKeyPackage.fromNative(_identityPackage()),
        ),
      );

  @override
  Future<Result<void>> replaceDirectory(List<DirectoryUser> users) async =>
      const Result.success(null);

  @override
  Stream<ContactProjection?> watchContact(String userId) =>
      const Stream.empty();

  @override
  Stream<List<ContactProjection>> watchContacts({required String ownUserId}) =>
      const Stream.empty();

  @override
  Future<Result<void>> writeProfile(
    String userId,
    ProfileCiphertext ciphertext,
    AuthenticatedProfile? authenticated,
  ) async => const Result.success(null);
}

final class _Crypto implements IdentityCryptoPort {
  @override
  Future<Result<void>> verifyIdentity({
    required Uint8List userId,
    required PeerIdentityPublic identity,
  }) async => const Result.success(null);

  @override
  Future<Result<void>> verifyClaimedBundle({
    required Uint8List userId,
    required Uint8List deviceId,
    required Uint8List selfSigningPublic,
    required ClaimedPrekeyBundle bundle,
  }) async => const Result.success(null);

  @override
  Future<Result<PeerDeviceLogInspection>> inspectPeerDeviceLog({
    required Uint8List userId,
    required Uint8List selfSigningPublic,
    required List<PeerPublicDevice> liveDevices,
    required bool requireCurrentLiveSet,
    required Uint8List record,
  }) async {
    // The blob carries its own sequence, so one chain serves every head this
    // harness advances to.
    final sequence = record.first;
    return Result.success(
      PeerDeviceLogInspection(
        sequence: sequence,
        previousHash: sequence == 0 ? Uint8List(32) : _bytes(32, 10 + sequence),
        recordHash: _bytes(32, 11 + sequence),
        liveDeviceSetHash: _bytes(32, 12),
        identityVersion: 1,
      ),
    );
  }

  @override
  Future<Result<UserSigningAttestation>> attestPeerMaster({
    required IdentityKeyPackage localIdentity,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
  }) async => Result.success(UserSigningAttestation(_bytes(64, 5)));

  @override
  Future<Result<void>> verifyUserAttestation({
    required Uint8List signerUserId,
    required Uint8List signerUserSigningPublic,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
    required UserSigningAttestation attestation,
  }) async => const Result.success(null);

  @override
  Future<Result<SafetyFingerprint>> safetyFingerprint({
    required Uint8List localUserId,
    required Uint8List localMasterPublic,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
  }) async => Result.success(SafetyFingerprint(_bytes(32, 42)));
}

final class _Store implements PairwiseTransportStore {
  final Map<String, DurablePairwiseOperation> durable = {};
  bool sessionEstablished = true;

  @override
  Future<Result<DurablePairwiseOperation?>> readPreparedOperation(
    String operationId,
  ) async => Result.success(durable[operationId]);

  @override
  Future<Result<void>> reconcileRemoteLiveDevices({
    required String remoteUserId,
    required Set<String> liveDeviceIds,
  }) async => const Result.success(null);

  @override
  Future<Result<PairwisePreparationContext>> readPreparationContext({
    required String localDeviceId,
    required String remoteUserId,
    required String remoteDeviceId,
  }) async => Result.success(
    PairwisePreparationContext(
      primary: sessionEstablished
          ? PairwiseSessionSnapshot(
              localDeviceId: localDeviceId,
              remoteUserId: remoteUserId,
              remoteDeviceId: remoteDeviceId,
              sessionId: _bytes(16, 9),
              opaqueState: _bytes(32, 9),
              stateVersion: 1,
              skippedKeyCount: 0,
              disposition: PairwiseSessionDisposition.primaryBidirectional,
              repairState: PairwiseRepairState.ready,
            )
          : null,
      alternate: null,
      deviceState: PairwiseDeviceStateSnapshot(
        opaqueState: _bytes(32, 7),
        stateVersion: 7,
      ),
      otherSessionsSkippedKeyCount: 0,
    ),
  );

  @override
  Future<Result<void>> commitPreparedSend(PairwiseSendCommit commit) async {
    durable[commit.operationId] = DurablePairwiseOperation(
      operationId: commit.operationId,
      eventId: commit.eventId,
      currentDeviceId: commit.currentDeviceId,
      openedLocalPayload: commit.openedLocalPayload,
      targets: [
        for (final target in commit.targets)
          DurablePairwiseTarget(
            recipientUserId: target.recipientUserId,
            recipientDeviceId: target.recipientDeviceId,
            exactCiphertext: target.exactCiphertext,
          ),
      ],
    );
    return const Result.success(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Outbound implements PairwiseOutboundPreparationPort {
  final List<VerifiedPairwiseLiveDevice> calls = [];

  @override
  Future<Result<PairwisePreparedOutbound>> prepareOutbound({
    required String currentDeviceId,
    required VerifiedPairwiseLiveDevice recipient,
    required Uint8List openedOpaquePayload,
    required int migrationUnixDay,
    required PairwisePreparationContext context,
    required VerifiedPairwiseClaim? claim,
  }) async {
    calls.add(recipient);
    return Result.success(
      PairwisePreparedOutbound(
        exactCiphertext: _bytes(1024, 1),
        sessionId: _bytes(16, 1),
        nextOpaqueSessionState: _bytes(32, 1),
        nextSkippedKeyCount: 0,
        disposition: PairwiseSessionDisposition.primaryBidirectional,
      ),
    );
  }
}

final class _Clock implements TimeSource {
  @override
  DateTime now() => DateTime.utc(2026, 10, 6);
}

Uint8List _bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker & 0xff));

Uint8List _identityPackage() {
  final recovery = Uint8List(0);
  final backup = Uint8List(0);
  final bytes = BytesBuilder(copy: false)
    ..add('CPIDV001'.codeUnits)
    ..addByte(0)
    ..add(_bytes(16, 3))
    ..add(_bytes(32, 1))
    ..add(_bytes(32, 2))
    ..add(_bytes(32, 3))
    ..add(_bytes(64, 4))
    ..add([0, recovery.length])
    ..add([0, 0, 0, backup.length])
    ..add(_bytes(96, 5))
    ..add(recovery)
    ..add(backup);
  return bytes.toBytes();
}
