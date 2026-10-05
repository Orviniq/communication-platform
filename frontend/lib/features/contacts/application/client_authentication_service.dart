import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';

/// Authentication Service used by profile handling and by pairwise messaging.
///
/// Backend listings are treated as untrusted inputs. A successful result chains exact
/// response bytes through master, self-signing, device, prekey, and device-log checks.
///
/// Every entry point asks the server, every time. Nothing here or under
/// [remote] remembers an answer, so a send is verified against the state its
/// recipients hold when it is made, and a safety number or a `stale_devices`
/// refresh reads exactly what a fan-out reads.
final class ClientAuthenticationService
    implements
        PeerAuthenticationService,
        SelectivePeerPrekeyClaimPort,
        VerifiedLiveDeviceResolverPort {
  const ClientAuthenticationService({
    required this.remote,
    required this.local,
    required this.crypto,
  });

  final PeerIdentityRemotePort remote;
  final ContactLocalPort local;
  final IdentityCryptoPort crypto;

  @override
  Future<Result<AuthenticatedPeer>> refreshPeer({
    required String userId,
    required bool requirePrekeys,
  }) => _refresh(
    userId: userId,
    requirePrekeys: requirePrekeys,
    claimDeviceIds: null,
    allowMasterReplacement: false,
  );

  @override
  Future<Result<AuthenticatedPeer>> refreshPeerForDevices({
    required String userId,
    required List<String> deviceIds,
  }) {
    if (deviceIds.isEmpty ||
        deviceIds.length > 100 ||
        deviceIds.toSet().length != deviceIds.length ||
        deviceIds.any((value) => _uuidBytes(value) == null)) {
      return Future.value(
        const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        ),
      );
    }
    return _refresh(
      userId: userId,
      requirePrekeys: true,
      claimDeviceIds: List.unmodifiable(deviceIds),
      allowMasterReplacement: false,
    );
  }

  @override
  Future<Result<AuthenticatedPeer>> resolveLiveDevices({
    required String userId,
  }) async {
    final gate = await _forkGate();
    if (gate case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return _refresh(
      userId: userId,
      requirePrekeys: false,
      claimDeviceIds: null,
      allowMasterReplacement: false,
    );
  }

  /// One read of every user in [userIds], then [resolveLiveDevices]'s checks
  /// for each of them in turn.
  ///
  /// The read is `POST /api/v1/peers`, which answers with the bytes the
  /// per-user identity and device-list reads serve, so `_refresh` judges them
  /// unchanged: what this saves is round trips, never a check. The device log
  /// is still read page by page, and only for a peer whose head moved.
  ///
  /// Users are verified in the order asked, each behind the global fork gate
  /// [resolveLiveDevices] puts in front of one user, so a fork found in one
  /// withholds every user after it exactly as it did when each was a call of
  /// its own.
  @override
  Future<Result<Map<String, Result<AuthenticatedPeer>>>>
  resolveLiveDevicesForUsers({required List<String> userIds}) async {
    if (userIds.isEmpty ||
        userIds.map((userId) => userId.toLowerCase()).toSet().length !=
            userIds.length ||
        userIds.any((userId) => _uuidBytes(userId) == null)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final gate = await _forkGate();
    if (gate case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    // Read before the request, because the request carries each record's tag
    // and the answer is a statement about that tag: every peer is judged
    // against the record its tag came from.
    final previous = <String, ContactTrustRecord?>{};
    for (final userId in userIds) {
      final read = await local.readTrust(userId);
      if (read case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      previous[userId] = (read as Success<ContactTrustRecord?>).value;
    }
    final answered = await remote.fetchPeerStates([
      for (final userId in userIds)
        PeerStateQuery(userId: userId, etag: _peerStateTag(previous[userId])),
    ]);
    if (answered case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final reads = (answered as Success<Map<String, PeerStateRead>>).value;
    final peers = <String, Result<AuthenticatedPeer>>{};
    for (final userId in userIds) {
      final read = reads[userId];
      final gate = await _forkGate();
      if (gate case FailureResult(failure: final failure)) {
        peers[userId] = Result.failure(failure);
      } else if (read == null) {
        peers[userId] = const Result.failure(
          SecurityFailure(SecurityFailureKind.malformedServerResponse),
        );
      } else {
        peers[userId] = await _refresh(
          userId: userId,
          requirePrekeys: false,
          claimDeviceIds: null,
          allowMasterReplacement: false,
          batched: (previous: previous[userId], read: read),
        );
      }
    }
    return Result.success(Map.unmodifiable(peers));
  }

  /// The global device-log fork gate (CLIENT_CONTRACT.md §E): while any fork
  /// is recorded, no resolution feeds a send.
  Future<Result<void>> _forkGate() async {
    final globalFork = await local.hasAnyDeviceLogFork();
    if (globalFork case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    if ((globalFork as Success<bool>).value) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    return const Result.success(null);
  }

  /// Resolves one peer from its identity and device-list answers.
  ///
  /// With [batched] absent, the answers are the per-user reads, made here in
  /// the order they always were. With it, they are what the batched read
  /// already said about this peer, judged against the record that read was
  /// asked with. Everything between and after the two reads is one code path.
  Future<Result<AuthenticatedPeer>> _refresh({
    required String userId,
    required bool requirePrekeys,
    required List<String>? claimDeviceIds,
    required bool allowMasterReplacement,
    _BatchedRead? batched,
  }) async {
    if (requirePrekeys) {
      final gate = await _forkGate();
      if (gate case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
    }
    final userBytes = _uuidBytes(userId);
    if (userBytes == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final localIdentityResult = await local.readLocalIdentity();
    if (localIdentityResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final localIdentity =
        (localIdentityResult as Success<LocalAccountIdentity>).value;
    final ContactTrustRecord? previous;
    if (batched != null) {
      previous = batched.previous;
    } else {
      final previousResult = await local.readTrust(userId);
      if (previousResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      previous = (previousResult as Success<ContactTrustRecord?>).value;
    }
    final identityResult = batched == null
        ? await remote.fetchIdentity(userId: userId)
        : _batchedIdentity(batched);
    if (identityResult case FailureResult(failure: final failure)) {
      await _persistBlocked(
        previous,
        userId,
        ContactTrustState.identityUnavailable,
      );
      return Result.failure(failure);
    }
    final identity = (identityResult as Success<PeerIdentityPublic>).value;
    final verifiedIdentity = await crypto.verifyIdentity(
      userId: userBytes,
      identity: identity,
    );
    if (verifiedIdentity case FailureResult(failure: final failure)) {
      await _persistBlocked(
        previous,
        userId,
        ContactTrustState.identityUnavailable,
        identity: identity,
      );
      return Result.failure(failure);
    }
    if (localIdentity.userId == userId &&
        (!_same(
              localIdentity.identityPackage.masterPub,
              identity.masterPublic,
            ) ||
            !_same(
              localIdentity.identityPackage.selfSigningPub,
              identity.selfSigningPublic,
            ) ||
            !_same(
              localIdentity.identityPackage.userSigningPub,
              identity.userSigningPublic,
            ) ||
            !_same(
              localIdentity.identityPackage.masterSig,
              identity.masterSignature,
            ))) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final confirmedMaster = previous?.confirmedMasterPublic;
    if (confirmedMaster != null &&
        !_same(confirmedMaster, identity.masterPublic) &&
        !allowMasterReplacement) {
      final changed =
          (previous ??
                  ContactTrustRecord(
                    userId: userId,
                    state: ContactTrustState.masterKeyChanged,
                  ))
              .copyWith(
                state: ContactTrustState.masterKeyChanged,
                identity: identity,
              );
      await local.writeTrust(changed);
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }

    final cachedDevicesResult = await local.readDevices(userId);
    if (cachedDevicesResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final cachedDevices =
        (cachedDevicesResult as Success<List<PeerPublicDevice>>).value;
    final deviceRead = batched == null
        ? await _readDeviceList(userId, previous, cachedDevices)
        : _batchedDevices(batched, cachedDevices);
    if (deviceRead case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final (:devices, :advertisedHead, :listChanged, :tag) =
        (deviceRead as Success<_DeviceRead>).value;
    if (devices.isEmpty || devices.any((device) => device.isUnsigned)) {
      await _persistBlocked(
        previous,
        userId,
        ContactTrustState.invalidDevice,
        identity: identity,
      );
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    if (advertisedHead == null ||
        (previous?.logHeadSequence != null &&
            advertisedHead < previous!.logHeadSequence!)) {
      return _fork(previous, userId, identity);
    }
    if (!_isValidDeviceTransition(cachedDevices, devices)) {
      return _invalidDevice(previous, userId, identity);
    }
    if (listChanged && advertisedHead == previous?.logHeadSequence) {
      // Device registration, revocation, and prekey rotation are separate
      // server mutations from the signed append. A same-head device-set change
      // is therefore a bounded pending window, not fork evidence. The list is
      // never exposed as authenticated until the extending record arrives.
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }

    var expectedPrevious = previous?.logHeadHash ?? Uint8List(32);
    var after = previous?.logHeadSequence;
    var expectedSequence = (after ?? -1) + 1;
    final verifiedRecords = <VerifiedDeviceLogRecord>[];
    if (after == null || advertisedHead > after) {
      var hasMore = true;
      while (hasMore) {
        final pageResult = await remote.fetchDeviceLog(
          userId: userId,
          after: after,
        );
        if (pageResult case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        final page = (pageResult as Success<PeerDeviceLogPage>).value;
        if (page.headSequence != advertisedHead ||
            (page.records.isEmpty && expectedSequence <= advertisedHead)) {
          return _fork(previous, userId, identity);
        }
        for (final record in page.records) {
          if (record.sequence != expectedSequence) {
            return _fork(previous, userId, identity);
          }
          final inspectedResult = await crypto.inspectPeerDeviceLog(
            userId: userBytes,
            selfSigningPublic: identity.selfSigningPublic,
            liveDevices: devices,
            requireCurrentLiveSet: record.sequence == advertisedHead,
            record: record.blob,
          );
          if (inspectedResult case FailureResult(failure: final failure)) {
            await _persistBlocked(
              previous,
              userId,
              ContactTrustState.deviceLogFork,
              identity: identity,
            );
            return Result.failure(failure);
          }
          final inspected =
              (inspectedResult as Success<PeerDeviceLogInspection>).value;
          if (inspected.sequence != record.sequence ||
              !_same(inspected.previousHash, expectedPrevious) ||
              (record.sequence == advertisedHead &&
                  inspected.identityVersion != identity.version)) {
            return _fork(previous, userId, identity);
          }
          verifiedRecords.add(
            VerifiedDeviceLogRecord(
              sequence: record.sequence,
              blob: record.blob,
              hash: inspected.recordHash,
            ),
          );
          expectedPrevious = inspected.recordHash;
          after = record.sequence;
          expectedSequence += 1;
        }
        hasMore = page.hasMore;
      }
      if (after != advertisedHead) {
        return _fork(previous, userId, identity);
      }
    }

    var claimed = const <ClaimedPrekeyBundle>[];
    if (requirePrekeys) {
      final requestedDeviceIds =
          claimDeviceIds ??
          devices.map((device) => device.deviceId).toList(growable: false);
      final liveDeviceIds = devices.map((device) => device.deviceId).toSet();
      if (requestedDeviceIds.any(
        (deviceId) => !liveDeviceIds.contains(deviceId),
      )) {
        return _invalidDevice(previous, userId, identity);
      }
      final claimResult = await remote.claimPrekeyBundles(
        userId: userId,
        deviceIds: requestedDeviceIds,
      );
      if (claimResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      claimed = (claimResult as Success<List<ClaimedPrekeyBundle>>).value;
      if (claimed.length != requestedDeviceIds.length) {
        return _invalidDevice(previous, userId, identity);
      }
      for (final deviceId in requestedDeviceIds) {
        final device = devices.singleWhere(
          (candidate) => candidate.deviceId == deviceId,
        );
        final matches = claimed
            .where((bundle) => bundle.deviceId == device.deviceId)
            .toList(growable: false);
        if (matches.length != 1 ||
            !matches.single.hasPostQuantumSignedPrekey ||
            !_bundleMatches(device, matches.single)) {
          return _invalidDevice(previous, userId, identity);
        }
        final verified = await crypto.verifyClaimedBundle(
          userId: userBytes,
          deviceId: _uuidBytes(device.deviceId)!,
          selfSigningPublic: identity.selfSigningPublic,
          bundle: matches.single,
        );
        if (verified case FailureResult()) {
          return _invalidDevice(previous, userId, identity);
        }
      }
    }

    var nextState = ContactTrustState.unverified;
    if (confirmedMaster != null &&
        _same(confirmedMaster, identity.masterPublic) &&
        previous?.attestation != null) {
      final attestation = await crypto.verifyUserAttestation(
        signerUserId: _uuidBytes(localIdentity.userId)!,
        signerUserSigningPublic: localIdentity.identityPackage.userSigningPub,
        peerUserId: userBytes,
        peerMasterPublic: identity.masterPublic,
        attestation: previous!.attestation!,
      );
      if (attestation case Success()) {
        nextState = ContactTrustState.verified;
      }
    }
    // Each tag vouches for the stored state it was read with, and goes back
    // only to the route that issued it. The route that just answered writes
    // its own. The other route's tag survives only when this answer left the
    // stored identity, device list and log head exactly as they were: kept
    // past a change, it would name a state this client no longer holds, and
    // its route could confirm that state rather than send the new one.
    final stateHeld =
        !_isBlocked(previous?.state) &&
        !listChanged &&
        advertisedHead == previous?.logHeadSequence &&
        _sameIdentity(previous?.identity, identity);
    final trust = ContactTrustRecord(
      userId: userId,
      state: nextState,
      identity: identity,
      confirmedMasterPublic: confirmedMaster,
      attestation: previous?.attestation,
      etag: batched == null ? tag : (stateHeld ? previous?.etag : null),
      peerStateEtag: batched == null
          ? (stateHeld ? previous?.peerStateEtag : null)
          : tag,
      logHeadSequence: advertisedHead,
      logHeadHash: verifiedRecords.isEmpty
          ? previous?.logHeadHash
          : verifiedRecords.last.hash,
    );
    final storedDevices = await local.replaceDevices(userId, devices);
    if (storedDevices case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final storedRecords = await local.appendVerifiedLogRecords(
      userId,
      verifiedRecords,
    );
    if (storedRecords case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final storedTrust = await local.writeTrust(trust);
    if (storedTrust case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(
      AuthenticatedPeer(
        trust: trust,
        devices: devices,
        claimedBundles: claimed,
      ),
    );
  }

  @override
  Future<Result<ContactTrustRecord>> confirmOutOfBand({
    required String userId,
    required Uint8List exactMasterPublic,
  }) async {
    final refreshed = await _refresh(
      userId: userId,
      requirePrekeys: false,
      claimDeviceIds: null,
      allowMasterReplacement: true,
    );
    if (refreshed case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final peer = (refreshed as Success<AuthenticatedPeer>).value;
    final identity = peer.trust.identity;
    if (identity == null || !_same(identity.masterPublic, exactMasterPublic)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final localIdentityResult = await local.readLocalIdentity();
    if (localIdentityResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final localIdentity =
        (localIdentityResult as Success<LocalAccountIdentity>).value;
    final attested = await crypto.attestPeerMaster(
      localIdentity: localIdentity.identityPackage,
      peerUserId: _uuidBytes(userId)!,
      peerMasterPublic: identity.masterPublic,
    );
    if (attested case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final trust = ContactTrustRecord(
      userId: userId,
      state: ContactTrustState.verified,
      identity: identity,
      confirmedMasterPublic: identity.masterPublic,
      attestation: (attested as Success<UserSigningAttestation>).value,
      etag: peer.trust.etag,
      peerStateEtag: peer.trust.peerStateEtag,
      logHeadSequence: peer.trust.logHeadSequence,
      logHeadHash: peer.trust.logHeadHash,
    );
    final written = await local.writeTrust(trust);
    return written.fold(
      onSuccess: (_) => Result.success(trust),
      onFailure: Result.failure,
    );
  }

  @override
  Future<Result<SafetyFingerprint>> safetyFingerprint(String userId) async {
    final peerResult = await local.readTrust(userId);
    final localResult = await local.readLocalIdentity();
    if (peerResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    if (localResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final peer = (peerResult as Success<ContactTrustRecord?>).value;
    final identity = peer?.identity;
    if (identity == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final localIdentity = (localResult as Success<LocalAccountIdentity>).value;
    return crypto.safetyFingerprint(
      localUserId: _uuidBytes(localIdentity.userId)!,
      localMasterPublic: localIdentity.identityPackage.masterPub,
      peerUserId: _uuidBytes(userId)!,
      peerMasterPublic: identity.masterPublic,
    );
  }

  Future<Result<AuthenticatedPeer>> _fork(
    ContactTrustRecord? previous,
    String userId,
    PeerIdentityPublic identity,
  ) async {
    await _persistBlocked(
      previous,
      userId,
      ContactTrustState.deviceLogFork,
      identity: identity,
    );
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  }

  Future<Result<AuthenticatedPeer>> _invalidDevice(
    ContactTrustRecord? previous,
    String userId,
    PeerIdentityPublic identity,
  ) async {
    await _persistBlocked(
      previous,
      userId,
      ContactTrustState.invalidDevice,
      identity: identity,
    );
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );
  }

  /// Whether this record names an answer this client read and refused.
  static bool _isBlocked(ContactTrustState? state) => switch (state) {
    null || ContactTrustState.unverified || ContactTrustState.verified => false,
    ContactTrustState.invalidDevice ||
    ContactTrustState.masterKeyChanged ||
    ContactTrustState.deviceLogFork ||
    ContactTrustState.identityUnavailable => true,
  };

  /// Records why this peer is blocked, and forgets both cache validators.
  ///
  /// An `ETag` is a claim about the answer a client is *holding*. Every caller
  /// here refused the answer it read and left the stored device list alone, so
  /// keeping that answer's tag pointed a later `If-None-Match` at a copy this
  /// client does not have: the server replied `304`, the refused list came back
  /// out of local storage, and it was refused again. Nothing else changed for
  /// as long as the deployment served that representation — which, for an own
  /// device blocked over its first cross-signature, is forever. The batched
  /// read's tag would do the same through `unchanged`.
  ///
  /// Dropping the tags costs one full answer the next time this peer is
  /// resolved, and is what lets a client that has already blocked itself read
  /// the corrected list and recover.
  Future<void> _persistBlocked(
    ContactTrustRecord? previous,
    String userId,
    ContactTrustState state, {
    PeerIdentityPublic? identity,
  }) async {
    await local.writeTrust(
      ContactTrustRecord(
        userId: userId,
        state: state,
        identity: identity ?? previous?.identity,
        confirmedMasterPublic: previous?.confirmedMasterPublic,
        attestation: previous?.attestation,
        logHeadSequence: previous?.logHeadSequence,
        logHeadHash: previous?.logHeadHash,
      ),
    );
  }

  /// The per-user device-list read, conditional on the stored tag.
  Future<Result<_DeviceRead>> _readDeviceList(
    String userId,
    ContactTrustRecord? previous,
    List<PeerPublicDevice> stored,
  ) async {
    // Only a peer whose last answer this client accepted may be revalidated
    // conditionally. A blocked record names an answer that was read and
    // refused, while the stored device list is the one from before it — so a
    // `304` hands back the copy that is already known to be wrong, and the
    // record blocks itself again on it forever. Records written before
    // [_persistBlocked] stopped keeping the tag still carry one, and this is
    // what lets those installs read the corrected list on their first attempt
    // rather than their second.
    final devicesResult = await remote.fetchDevices(
      userId: userId,
      etag: _isBlocked(previous?.state) ? null : previous?.etag,
    );
    if (devicesResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(switch ((devicesResult as Success<PeerDeviceRefresh>)
        .value) {
      PeerDevicesNotModified() => (
        devices: stored,
        advertisedHead: previous?.logHeadSequence,
        listChanged: false,
        tag: previous?.etag,
      ),
      PeerDevicesUpdated(:final devices, :final etag, :final logHeadSequence) =>
        (
          devices: devices,
          advertisedHead: logHeadSequence,
          listChanged: !_sameDevices(stored, devices),
          tag: etag,
        ),
    });
  }

  /// The identity the batched read gave, as the per-user identity read would
  /// have answered it.
  ///
  /// That read answers `404` alike for a user with no published identity, an
  /// unknown user and a deactivated one. The batched read says the first with
  /// `identity: null` and the other two by leaving the user out, so all three
  /// become that `404` here and are blocked exactly as it is.
  Result<PeerIdentityPublic> _batchedIdentity(_BatchedRead batched) =>
      switch (batched.read) {
        PeerStateUpdated(identity: final identity?) => Result.success(identity),
        // A tag is only ever sent beside the identity it was stored with.
        PeerStateUnchanged() => switch (batched.previous?.identity) {
          final identity? => Result.success(identity),
          null => const Result.failure(
            SecurityFailure(SecurityFailureKind.malformedServerResponse),
          ),
        },
        PeerStateUpdated() || PeerStateAbsent() => const Result.failure(
          BackendFailure(BackendFailureCode.notFound),
        ),
      };

  /// The device list the batched read gave. `unchanged` is the stored list
  /// and head, exactly as a `304` from the device-list read is.
  Result<_DeviceRead> _batchedDevices(
    _BatchedRead batched,
    List<PeerPublicDevice> stored,
  ) => switch (batched.read) {
    PeerStateUnchanged(:final etag) => Result.success((
      devices: stored,
      advertisedHead: batched.previous?.logHeadSequence,
      listChanged: false,
      tag: etag,
    )),
    PeerStateUpdated(:final devices, :final logHeadSequence, :final etag) =>
      Result.success((
        devices: devices,
        advertisedHead: logHeadSequence,
        listChanged: !_sameDevices(stored, devices),
        tag: etag,
      )),
    // Not reached: a user left out has no identity, and stops there.
    PeerStateAbsent() => const Result.failure(
      BackendFailure(BackendFailureCode.notFound),
    ),
  };

  /// The tag a batched read sends for this peer: the one stored beside the
  /// state it vouches for, and none for a record this client refused, whose
  /// stored state is not the one that tag was read with.
  static String? _peerStateTag(ContactTrustRecord? previous) =>
      previous == null ||
          _isBlocked(previous.state) ||
          previous.identity == null
      ? null
      : previous.peerStateEtag;

  bool _sameIdentity(PeerIdentityPublic? left, PeerIdentityPublic right) =>
      left != null &&
      left.version == right.version &&
      _same(left.masterPublic, right.masterPublic) &&
      _same(left.selfSigningPublic, right.selfSigningPublic) &&
      _same(left.userSigningPublic, right.userSigningPublic) &&
      _same(left.masterSignature, right.masterSignature);

  bool _bundleMatches(PeerPublicDevice device, ClaimedPrekeyBundle bundle) =>
      device.deviceId == bundle.deviceId &&
      device.registrationId == bundle.registrationId &&
      device.bundleVersion == bundle.bundleVersion &&
      _same(device.identityPublic, bundle.identityPublic) &&
      _same(device.crossSignature!, bundle.crossSignature);

  bool _sameDevices(List<PeerPublicDevice> left, List<PeerPublicDevice> right) {
    if (left.length != right.length) {
      return false;
    }
    final a = [...left]..sort((x, y) => x.deviceId.compareTo(y.deviceId));
    final b = [...right]..sort((x, y) => x.deviceId.compareTo(y.deviceId));
    for (var index = 0; index < a.length; index += 1) {
      if (a[index].deviceId != b[index].deviceId ||
          a[index].registrationId != b[index].registrationId ||
          a[index].bundleVersion != b[index].bundleVersion ||
          !_same(a[index].identityPublic, b[index].identityPublic) ||
          !_nullableSame(a[index].crossSignature, b[index].crossSignature)) {
        return false;
      }
    }
    return true;
  }

  bool _isValidDeviceTransition(
    List<PeerPublicDevice> previous,
    List<PeerPublicDevice> current,
  ) {
    final oldById = {for (final device in previous) device.deviceId: device};
    for (final device in current) {
      final old = oldById[device.deviceId];
      if (old == null) {
        continue;
      }
      if (old.registrationId != device.registrationId ||
          !_same(old.identityPublic, device.identityPublic)) {
        return false;
      }
      final signatureChanged = !_nullableSame(
        old.crossSignature,
        device.crossSignature,
      );
      final versionChanged = old.bundleVersion != device.bundleVersion;
      if (signatureChanged != versionChanged) {
        return false;
      }
      if (signatureChanged) {
        final version = device.bundleVersion;
        final previousVersion = old.bundleVersion;
        // A device is registered unsigned — registration assigns the device id
        // the canonical bundle covers, so no signature made before the response
        // can be over the right bytes — and cross-signs itself afterwards. Its
        // first signature therefore arrives against no version at all, and a
        // rule that demanded one refused the one transition every device in
        // this deployment makes, this account's own device included.
        //
        // A signature that replaces one this client already read is a different
        // claim, and still has to move the version on by exactly one: that is
        // what stops an old bundle being served back in place of a new one.
        if (version == null ||
            (previousVersion != null && version != previousVersion + 1)) {
          return false;
        }
      }
    }
    return true;
  }

  bool _nullableSame(Uint8List? left, Uint8List? right) =>
      left == null || right == null
      ? left == null && right == null
      : _same(left, right);

  bool _same(List<int> left, List<int> right) {
    if (left.length != right.length) {
      return false;
    }
    var difference = 0;
    for (var index = 0; index < left.length; index += 1) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  Uint8List? _uuidBytes(String value) {
    final compact = value.replaceAll('-', '');
    if (compact.length != 32 ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(compact)) {
      return null;
    }
    return Uint8List.fromList([
      for (var index = 0; index < compact.length; index += 2)
        int.parse(compact.substring(index, index + 2), radix: 16),
    ]);
  }
}

/// What the batched read said about one peer, and the record whose tag the
/// request carried for it.
typedef _BatchedRead = ({ContactTrustRecord? previous, PeerStateRead read});

/// One peer's live devices as a read gave them, with the tag of the route that
/// read them.
typedef _DeviceRead = ({
  List<PeerPublicDevice> devices,
  int? advertisedHead,
  bool listChanged,
  String? tag,
});
