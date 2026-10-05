import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/client_authentication_service.dart';
import 'package:communication_platform/features/contacts/application/peer_resolution_cache.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/synchronization/infrastructure/stale_device_refresh_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

const _ownUserId = '00000000-0000-4000-8000-0000000000a1';
const _ownDeviceId = '00000000-0000-4000-8000-0000000000a2';
const _peerUserId = '00000000-0000-4000-8000-0000000000b1';
const _peerDeviceId = '00000000-0000-4000-8000-0000000000b2';
const _peerSecondDeviceId = '00000000-0000-4000-8000-0000000000b3';

/// What a delivery cycle asks the network about a peer, and what it may be told
/// without asking again.
///
/// The cache under test decorates [PeerIdentityRemotePort], which puts it
/// *below* every gate `ClientAuthenticationService` applies. That is the
/// property the whole phase turns on, so most of what is here asserts on the
/// devices a send is actually encrypted to rather than on whether a request
/// happened: the real fan-out coordinator runs, over the real authentication
/// service, and the recipients handed to `prepareOutbound` are the answer.
void main() {
  group('what one delivery cycle asks the network', () {
    test('preparing one send resolves each user once', () async {
      final harness = _Harness()..establishedSession();

      final prepared = await harness.send('application:aa');

      expect(prepared, isA<Success<DurablePairwiseOperation>>());
      // Two resolutions of two distinct users. Before the cache this was two
      // identity fetches and two device fetches for the peer alone, because the
      // peer is resolved by the fan-out and again by nothing else in this
      // shape; the equalities below are what stop that returning.
      expect(harness.remote.identityCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.remote.deviceCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.remote.logCalls, <String, int>{});
      expect(harness.encryptedTo, [_peerDeviceId]);
    });

    test('a send that must start a session still asks once', () async {
      // The claim path is a third full `_refresh` of the same peer inside one
      // preparation: identity, devices, log, and only then the claim. Only the
      // claim is unavoidable.
      final harness = _Harness()..noSession();

      final prepared = await harness.send('application:bb');

      expect(prepared, isA<Success<DurablePairwiseOperation>>());
      expect(harness.remote.identityCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.remote.deviceCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.remote.claimCalls, {_peerUserId: 1});
      expect(harness.encryptedTo, [_peerDeviceId]);
    });

    test('the gossip that follows reuses the send resolution', () async {
      final harness = _Harness()..establishedSession();

      await harness.send('application:cc');
      await harness.gossip('device-head-gossip:cc');

      // Gossip is a fan-out of its own, with its own two device lookups. It
      // asks the same questions about the same two people moments after the
      // send did, and now hears the same answers without a round trip.
      expect(harness.remote.identityCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.remote.deviceCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.remote.logCalls, <String, int>{});
    });

    test('a first contact and its gossip ask once each', () async {
      // The worst shape the RCA named: a send that must establish a session,
      // followed by the gossip it owes, which must establish one too. Fourteen
      // round trips became six, and the four that remain beyond the two claims
      // are one identity and one device answer per distinct user.
      final harness = _Harness()..noSession();

      await harness.send('application:25');
      await harness.gossip('device-head-gossip:25');

      expect(harness.remote.identityCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.remote.deviceCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.remote.logCalls, <String, int>{});
      expect(harness.remote.claimCalls, {_peerUserId: 2});
    });

    test('two sends to the same peer in quick succession ask once', () async {
      final harness = _Harness()..establishedSession();

      await harness.send('application:dd');
      harness.clock.advance(const Duration(seconds: 1));
      await harness.send('application:ee');

      expect(harness.remote.identityCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.remote.deviceCalls, {_peerUserId: 1, _ownUserId: 1});
      expect(harness.encryptedTo, [_peerDeviceId, _peerDeviceId]);
    });

    test('a send past the window asks again', () async {
      final harness = _Harness()..establishedSession();

      await harness.send('application:ff');
      harness.clock.advance(defaultPeerResolutionTtl);
      await harness.send('application:00');

      expect(harness.remote.identityCalls, {_peerUserId: 2, _ownUserId: 2});
      expect(harness.remote.deviceCalls, {_peerUserId: 2, _ownUserId: 2});
    });

    test('concurrent resolutions of one user share one round trip', () async {
      final harness = _Harness()
        ..establishedSession()
        ..remote.hold = true;

      final first = harness.service.resolveLiveDevices(userId: _peerUserId);
      final second = harness.service.resolveLiveDevices(userId: _peerUserId);
      await harness.remote.release();
      final results = await Future.wait([first, second]);

      expect(results, everyElement(isA<Success<AuthenticatedPeer>>()));
      expect(harness.remote.identityCalls, {_peerUserId: 1});
      expect(harness.remote.deviceCalls, {_peerUserId: 1});
    });

    test('a failed answer is never remembered', () async {
      final harness = _Harness()
        ..establishedSession()
        ..remote.identityFailure = true;

      final first = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );
      harness.remote.identityFailure = false;
      final second = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(first, isA<FailureResult<AuthenticatedPeer>>());
      expect(second, isA<Success<AuthenticatedPeer>>());
      expect(harness.remote.identityCalls, {_peerUserId: 2});
    });

    test('a 304 is only served back to the ETag that produced it', () async {
      final harness = _Harness()
        ..establishedSession()
        ..remote.notModified = true;

      await harness.service.resolveLiveDevices(userId: _peerUserId);
      harness.local.trustFor(_peerUserId, etag: '"devices-e1"');
      await harness.service.resolveLiveDevices(userId: _peerUserId);

      // The second resolution holds a different ETag, so the remembered "not
      // modified" says nothing about it and the server is asked.
      expect(harness.remote.deviceCalls, {_peerUserId: 2});
      expect(harness.remote.etags[_peerUserId], [
        '"devices-e0"',
        '"devices-e1"',
      ]);
    });
  });

  group('what the same cycle asked before', () {
    // The other half of every equality above. These are the numbers this phase
    // measured and removed, pinned here so the removal cannot quietly undo
    // itself.
    test('a send that starts a session asked three times', () async {
      final harness = _Harness(cached: false)..noSession();

      await harness.send('application:21');

      expect(harness.remote.identityCalls, {_peerUserId: 2, _ownUserId: 1});
      expect(harness.remote.deviceCalls, {_peerUserId: 2, _ownUserId: 1});
      expect(harness.remote.claimCalls, {_peerUserId: 1});
    });

    test('a send and its gossip asked twice over', () async {
      final harness = _Harness(cached: false)..establishedSession();

      await harness.send('application:22');
      await harness.gossip('device-head-gossip:22');

      expect(harness.remote.identityCalls, {_peerUserId: 2, _ownUserId: 2});
      expect(harness.remote.deviceCalls, {_peerUserId: 2, _ownUserId: 2});
    });

    test('a first contact and its gossip asked fourteen times', () async {
      final harness = _Harness(cached: false)..noSession();

      await harness.send('application:26');
      await harness.gossip('device-head-gossip:26');

      expect(harness.remote.identityCalls, {_peerUserId: 4, _ownUserId: 2});
      expect(harness.remote.deviceCalls, {_peerUserId: 4, _ownUserId: 2});
      expect(harness.remote.claimCalls, {_peerUserId: 2});
    });

    test('two sends to one peer asked twice over', () async {
      final harness = _Harness(cached: false)..establishedSession();

      await harness.send('application:23');
      await harness.send('application:24');

      expect(harness.remote.identityCalls, {_peerUserId: 2, _ownUserId: 2});
      expect(harness.remote.deviceCalls, {_peerUserId: 2, _ownUserId: 2});
    });
  });

  group('staleness never reaches the ciphertext', () {
    test('a revoked device is not encrypted to after the signal', () async {
      final harness = _Harness()..establishedSession(peerDevices: 2);

      await harness.send('application:11');
      expect(harness.encryptedTo, [_peerDeviceId, _peerSecondDeviceId]);

      // The peer revokes a device. Nothing about it is visible to this device
      // until something says so — and the thing that says so is the delivery
      // cycle acting on a `stale_devices` response.
      harness.remote.revokeSecondPeerDevice();
      await ContactStaleDeviceRefreshAdapter(
        harness.service,
      ).refreshUserDevices(_peerUserId);
      harness.outbound.calls.clear();
      await harness.send('application:12');

      expect(harness.encryptedTo, [_peerDeviceId]);
    });

    test('a stale refresh forces a live resolution', () async {
      final harness = _Harness()..establishedSession();

      await harness.send('application:13');
      final before = harness.remote.identityCalls[_peerUserId];
      await ContactStaleDeviceRefreshAdapter(
        harness.service,
      ).refreshUserDevices(_peerUserId);

      expect(harness.remote.identityCalls[_peerUserId], before! + 1);
      expect(harness.remote.deviceCalls[_peerUserId], 2);
    });

    test('an added device is encrypted to after the signal', () async {
      final harness = _Harness()..establishedSession();

      await harness.send('application:14');
      expect(harness.encryptedTo, [_peerDeviceId]);

      harness.remote.addSecondPeerDevice();
      await ContactStaleDeviceRefreshAdapter(
        harness.service,
      ).refreshUserDevices(_peerUserId);
      harness.outbound.calls.clear();
      await harness.send('application:15');

      expect(harness.encryptedTo, [_peerDeviceId, _peerSecondDeviceId]);
    });

    test('a changed master key blocks the next send', () async {
      final harness = _Harness()..establishedSession();

      await harness.send('application:16');
      harness.remote.replacePeerMaster();
      // A user looking at the safety number is the other path that may not be
      // served a remembered answer, and this is what it sees.
      await harness.service.refreshPeer(
        userId: _peerUserId,
        requirePrekeys: false,
      );
      harness.outbound.calls.clear();
      final blocked = await harness.send('application:17');

      expect(blocked, isA<FailureResult<DurablePairwiseOperation>>());
      expect(
        harness.local.trustOf(_peerUserId)?.state,
        ContactTrustState.masterKeyChanged,
      );
      expect(harness.encryptedTo, isEmpty);
    });

    test('a fork detected anywhere blocks every send', () async {
      final harness = _Harness()..establishedSession();

      await harness.send('application:18');
      harness.local.anyFork = true;
      harness.outbound.calls.clear();
      final blocked = await harness.send('application:19');

      // The global gate is a local read the cache has nothing to do with, and
      // a hit cannot skip it: it is in front of the resolution, not behind it.
      expect(blocked, isA<FailureResult<DurablePairwiseOperation>>());
      expect(harness.encryptedTo, isEmpty);
    });

    test('user verification is never served a remembered answer', () async {
      final harness = _Harness()..establishedSession();

      await harness.send('application:1a');
      final before = harness.remote.identityCalls[_peerUserId];
      await harness.service.confirmOutOfBand(
        userId: _peerUserId,
        exactMasterPublic: harness.remote.identityOf(_peerUserId).masterPublic,
      );

      expect(harness.remote.identityCalls[_peerUserId], before! + 1);
    });

    test('a live resolution is live for its whole length', () async {
      final harness = _Harness()
        ..establishedSession()
        ..remote.hold = true;

      // A concurrent fan-out asking the same question while a forced-live
      // refresh runs must not be handed the answer that refresh exists to
      // replace, so it does not join anything that started before it.
      final refresh = harness.service.refreshPeer(
        userId: _peerUserId,
        requirePrekeys: false,
      );
      await pumpEventQueue();
      final concurrent = harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );
      await harness.remote.release();
      await refresh;
      await concurrent;

      expect(harness.remote.identityCalls[_peerUserId], 2);
    });
  });

  group('every gate the live path applies is reached on a hit', () {
    test('an unsigned device is rejected on a hit', () async {
      final harness = _Harness()..establishedSession();
      harness.remote.unsignPeerDevice();
      // The first resolution is what puts the offending answer in the cache.
      // Everything after it is the same verdict reached without a round trip.
      await harness.service.resolveLiveDevices(userId: _peerUserId);
      harness.remote.deviceCalls.clear();

      final rejected = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(rejected, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.remote.deviceCalls, <String, int>{});
      expect(
        harness.local.trustOf(_peerUserId)?.state,
        ContactTrustState.invalidDevice,
      );
    });

    test('an invalid device transition is rejected on a hit', () async {
      final harness = _Harness()..establishedSession();
      // The identity key under a device id may never change. The remembered
      // answer is the one carrying the changed key, so the transition check has
      // to be what refuses it, every time it is served.
      harness.remote.rekeyPeerDevice();
      await harness.service.resolveLiveDevices(userId: _peerUserId);
      harness.remote.deviceCalls.clear();

      final rejected = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(rejected, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.remote.deviceCalls, <String, int>{});
      expect(
        harness.local.trustOf(_peerUserId)?.state,
        ContactTrustState.invalidDevice,
      );
    });

    test('a rewound log head is read as a fork on a hit', () async {
      final harness = _Harness()..establishedSession();
      await harness.service.resolveLiveDevices(userId: _peerUserId);
      harness.remote.deviceCalls.clear();
      harness.local.trustFor(_peerUserId, logHeadSequence: 4);

      final rejected = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(rejected, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.remote.deviceCalls, <String, int>{});
      expect(
        harness.local.trustOf(_peerUserId)?.state,
        ContactTrustState.deviceLogFork,
      );
    });

    test('a changed master key is refused on a hit', () async {
      final harness = _Harness()..establishedSession();
      await harness.service.resolveLiveDevices(userId: _peerUserId);
      harness.remote.identityCalls.clear();
      harness.local.trustFor(
        _peerUserId,
        confirmedMasterPublic: _bytes(32, 99),
      );

      final rejected = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(rejected, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.remote.identityCalls, <String, int>{});
      expect(
        harness.local.trustOf(_peerUserId)?.state,
        ContactTrustState.masterKeyChanged,
      );
    });

    test('the global fork gate is in front of the cache', () async {
      final harness = _Harness()..establishedSession();
      await harness.service.resolveLiveDevices(userId: _peerUserId);
      harness.remote.identityCalls.clear();
      harness.local.anyFork = true;

      final rejected = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(rejected, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.remote.identityCalls, <String, int>{});
    });

    test('a rejected identity signature is rejected on a hit', () async {
      final harness = _Harness()..establishedSession();
      await harness.service.resolveLiveDevices(userId: _peerUserId);
      harness.remote.identityCalls.clear();
      harness.crypto.rejectIdentity = true;

      final rejected = await harness.service.resolveLiveDevices(
        userId: _peerUserId,
      );

      expect(rejected, isA<FailureResult<AuthenticatedPeer>>());
      expect(harness.remote.identityCalls, <String, int>{});
      expect(
        harness.local.trustOf(_peerUserId)?.state,
        ContactTrustState.identityUnavailable,
      );
    });
  });

  group('the batched read', () {
    test('an answer asked before it landed is not remembered', () async {
      final harness = _Harness()..establishedSession();
      harness.remote.hold = true;
      final inFlight = harness.cache.fetchDevices(
        userId: _peerUserId,
        etag: '"devices-e0"',
      );
      await pumpEventQueue();
      harness.clock.advance(const Duration(seconds: 1));

      harness.remote.addSecondPeerDevice();
      await harness.cache.fetchPeerStates(const [
        PeerStateQuery(userId: _peerUserId),
      ]);
      await harness.remote.release();
      await inFlight;
      await harness.cache.fetchDevices(
        userId: _peerUserId,
        etag: '"devices-e0"',
      );

      // The answer that was in flight was asked before the read that moved
      // the peer landed, so it is not what the second ask is given.
      expect(harness.remote.deviceCalls[_peerUserId], 2);
    });

    test('a peer it found unchanged keeps what is remembered', () async {
      final harness = _Harness()..establishedSession();
      await harness.cache.fetchIdentity(userId: _peerUserId);

      await harness.cache.fetchPeerStates([
        PeerStateQuery(
          userId: _peerUserId,
          etag: harness.remote.peerStateTagOf(_peerUserId),
        ),
      ]);
      await harness.cache.fetchIdentity(userId: _peerUserId);

      expect(
        harness.remote.answered.single[_peerUserId],
        isA<PeerStateUnchanged>(),
      );
      expect(harness.remote.identityCalls, {_peerUserId: 1});
    });
  });

  group('the prekey claim', () {
    test('is claimed exactly once per session establishment', () async {
      final harness = _Harness()..noSession();

      await harness.send('application:20');

      expect(harness.remote.claimCalls, {_peerUserId: 1});
      expect(harness.remote.claimedDeviceIds, [
        [_peerDeviceId],
      ]);
    });

    test('is never served from the cache', () async {
      final harness = _Harness()..noSession();

      await harness.service.refreshPeerForDevices(
        userId: _peerUserId,
        deviceIds: const [_peerDeviceId],
      );
      await harness.service.refreshPeerForDevices(
        userId: _peerUserId,
        deviceIds: const [_peerDeviceId],
      );

      // Both identity and devices came from the cache the second time. The
      // claim did not, because it consumes one-time prekeys on the server.
      expect(harness.remote.identityCalls, {_peerUserId: 1});
      expect(harness.remote.deviceCalls, {_peerUserId: 1});
      expect(harness.remote.claimCalls, {_peerUserId: 2});
    });

    test('is never coalesced between concurrent callers', () async {
      final harness = _Harness()
        ..noSession()
        ..remote.hold = true;

      final first = harness.service.refreshPeerForDevices(
        userId: _peerUserId,
        deviceIds: const [_peerDeviceId],
      );
      final second = harness.service.refreshPeerForDevices(
        userId: _peerUserId,
        deviceIds: const [_peerDeviceId],
      );
      await harness.remote.release();
      await Future.wait([first, second]);

      expect(harness.remote.claimCalls, {_peerUserId: 2});
    });
  });
}

/// The composed send path, from the network up to the ciphertext.
final class _Harness {
  _Harness({bool cached = true}) {
    cache = PeerIdentityRoundTripCache(remote: remote, clock: clock);
    service = ClientAuthenticationService(
      remote: cached ? cache : remote,
      local: local,
      crypto: crypto,
      resolutionCache: cached ? cache : const NoPeerResolutionCache(),
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
  late final PeerIdentityRoundTripCache cache;
  late final ClientAuthenticationService service;
  late final PairwiseFanoutCoordinator fanout;

  /// The device ids this harness actually sealed ciphertext for.
  List<String> get encryptedTo =>
      outbound.calls.map((call) => call.deviceId).toList(growable: false);

  /// A conversation already under way: both accounts known, both device sets
  /// stored, and a live session with every peer device.
  void establishedSession({int peerDevices = 1}) {
    remote.peerDeviceCount = peerDevices;
    _seedTrust();
    store.sessionEstablished = true;
  }

  /// The same conversation before its first message, which is the only shape
  /// that claims prekeys.
  void noSession() {
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
        etag: '"devices-e0"',
        logHeadSequence: 0,
        logHeadHash: _bytes(32, 11),
      )
      ..trust[_ownUserId] = ContactTrustRecord(
        userId: _ownUserId,
        state: ContactTrustState.unverified,
        identity: remote.identityOf(_ownUserId),
        etag: '"devices-e0"',
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
  /// fan-out asking the network the same questions.
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

final class _Remote implements PeerIdentityRemotePort {
  final Map<String, int> identityCalls = {};
  final Map<String, int> deviceCalls = {};
  final Map<String, int> logCalls = {};
  final Map<String, int> claimCalls = {};
  final Map<String, List<String?>> etags = {};
  final List<List<String>> claimedDeviceIds = [];

  /// Every batched read, by the users it named, and what it answered.
  final List<List<String>> batches = [];
  final List<Map<String, PeerStateRead>> answered = [];

  int peerDeviceCount = 1;

  /// The peer's device-log head. A device set only ever changes together with
  /// an extending signed record — the service refuses a same-head change as a
  /// pending window — so every mutation below advances it.
  int logHead = 0;
  bool notModified = false;
  bool identityFailure = false;
  Uint8List _peerMaster = _bytes(32, 21);
  Uint8List _peerDeviceIdentity = _bytes(64, 22);
  bool _peerDeviceUnsigned = false;

  /// Holds every response until [release], so that concurrent callers are
  /// genuinely concurrent rather than merely interleaved.
  bool hold = false;
  final List<void Function()> _held = [];

  Future<void> release() async {
    hold = false;
    final waiting = List.of(_held);
    _held.clear();
    for (final resume in waiting) {
      resume();
    }
    await pumpEventQueue();
  }

  Future<void> _gate() async {
    if (!hold) {
      return;
    }
    final resumed = Completer<void>();
    _held.add(resumed.complete);
    await resumed.future;
  }

  void revokeSecondPeerDevice() {
    peerDeviceCount = 1;
    logHead += 1;
  }

  void addSecondPeerDevice() {
    peerDeviceCount = 2;
    logHead += 1;
  }

  void replacePeerMaster() => _peerMaster = _bytes(32, 77);

  /// An unsigned device, offered without the extending record that would make
  /// a changed set legitimate. This is what the cache is asked to remember.
  void unsignPeerDevice() => _peerDeviceUnsigned = true;

  /// The same device id under a different identity key, which no transition
  /// may ever produce.
  void rekeyPeerDevice() => _peerDeviceIdentity = _bytes(64, 88);

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
            identityPublic: _peerDeviceIdentity,
            registrationId: 2,
            crossSignature: _peerDeviceUnsigned ? null : _bytes(64, 23),
            bundleVersion: _peerDeviceUnsigned ? null : 1,
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

  @override
  Future<Result<PeerIdentityPublic>> fetchIdentity({
    required String userId,
  }) async {
    await _gate();
    identityCalls.update(userId, (count) => count + 1, ifAbsent: () => 1);
    if (identityFailure) {
      return const Result.failure(
        TransportFailure(TransportFailureKind.offline),
      );
    }
    return Result.success(identityOf(userId));
  }

  @override
  Future<Result<PeerDeviceRefresh>> fetchDevices({
    required String userId,
    String? etag,
  }) async {
    await _gate();
    deviceCalls.update(userId, (count) => count + 1, ifAbsent: () => 1);
    (etags[userId] ??= []).add(etag);
    if (notModified) {
      return const Result.success(PeerDevicesNotModified());
    }
    return Result.success(
      PeerDevicesUpdated(
        devices: devicesOf(userId),
        etag: '"devices-e\$logHead"',
        logHeadSequence: logHead,
      ),
    );
  }

  @override
  Future<Result<List<ClaimedPrekeyBundle>>> claimPrekeyBundles({
    required String userId,
    required List<String> deviceIds,
  }) async {
    await _gate();
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
    await _gate();
    logCalls.update(userId, (count) => count + 1, ifAbsent: () => 1);
    return Result.success(
      PeerDeviceLogPage(
        records: [
          for (
            var sequence = (after ?? -1) + 1;
            sequence <= logHead;
            sequence += 1
          )
            PeerDeviceLogRecord(sequence: sequence, blob: _bytes(8, sequence)),
        ],
        hasMore: false,
        headSequence: logHead,
      ),
    );
  }

  /// The batched read's tag, which moves whenever anything the per-user reads
  /// would serve for that user moves.
  String peerStateTagOf(String userId) => userId == _ownUserId
      ? '"peers-own-$logHead"'
      : '"peers-${_peerMaster.first}-$peerDeviceCount-$logHead-'
            '$_peerDeviceUnsigned-${_peerDeviceIdentity.first}"';

  /// Never held: the tests that hold use it to land between a per-user ask
  /// and its answer.
  @override
  Future<Result<Map<String, PeerStateRead>>> fetchPeerStates(
    List<PeerStateQuery> peers,
  ) async {
    batches.add([for (final peer in peers) peer.userId]);
    final reads = <String, PeerStateRead>{
      for (final peer in peers)
        peer.userId: peer.etag == peerStateTagOf(peer.userId)
            ? PeerStateUnchanged(etag: peer.etag!)
            : PeerStateUpdated(
                identity: identityOf(peer.userId),
                devices: devicesOf(peer.userId),
                logHeadSequence: logHead,
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
  final Map<String, List<VerifiedDeviceLogRecord>> records = {};
  bool anyFork = false;

  ContactTrustRecord? trustOf(String userId) => trust[userId];

  void trustFor(
    String userId, {
    String? etag,
    int? logHeadSequence,
    Uint8List? confirmedMasterPublic,
  }) {
    final held = trust[userId]!;
    trust[userId] = ContactTrustRecord(
      userId: userId,
      state: held.state,
      identity: held.identity,
      confirmedMasterPublic:
          confirmedMasterPublic ?? held.confirmedMasterPublic,
      attestation: held.attestation,
      etag: etag ?? held.etag,
      peerStateEtag: held.peerStateEtag,
      logHeadSequence: logHeadSequence ?? held.logHeadSequence,
      logHeadHash: held.logHeadHash,
    );
  }

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
  ) async {
    (records[userId] ??= []).addAll(appended);
    return const Result.success(null);
  }

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
  bool rejectIdentity = false;

  @override
  Future<Result<void>> verifyIdentity({
    required Uint8List userId,
    required PeerIdentityPublic identity,
  }) async => rejectIdentity
      ? const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        )
      : const Result.success(null);

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
  DateTime _now = DateTime.utc(2026, 8, 28);

  void advance(Duration by) => _now = _now.add(by);

  @override
  DateTime now() => _now;
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
