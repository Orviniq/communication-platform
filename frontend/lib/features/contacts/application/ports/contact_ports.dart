import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';

abstract interface class DirectoryRemotePort implements Port {
  Future<Result<List<DirectoryUser>>> fetchActivatedUsers();
}

abstract interface class ProfileRemotePort implements Port {
  Future<Result<ProfileCiphertext?>> fetchProfile({required String userId});

  Future<Result<ProfileCiphertext?>> fetchOwnProfile();

  Future<Result<void>> publishOwnProfile(ProfileCiphertext profile);
}

abstract interface class PeerIdentityRemotePort implements Port {
  Future<Result<PeerIdentityPublic>> fetchIdentity({required String userId});

  Future<Result<PeerDeviceRefresh>> fetchDevices({
    required String userId,
    String? etag,
  });

  Future<Result<List<ClaimedPrekeyBundle>>> claimPrekeyBundles({
    required String userId,
    required List<String> deviceIds,
  });

  Future<Result<PeerDeviceLogPage>> fetchDeviceLog({
    required String userId,
    int? after,
  });

  /// Reads the identity, live devices and log head of every peer in [peers]
  /// through `POST /api/v1/peers`, in as few calls as its 64-peer ceiling
  /// allows.
  ///
  /// Every queried user has an entry, keyed as it was asked. A user the route
  /// left out is [PeerStateAbsent].
  Future<Result<Map<String, PeerStateRead>>> fetchPeerStates(
    List<PeerStateQuery> peers,
  );
}

abstract interface class ContactLocalPort implements Port {
  Stream<List<ContactProjection>> watchContacts({required String ownUserId});

  Stream<ContactProjection?> watchContact(String userId);

  Future<Result<void>> replaceDirectory(List<DirectoryUser> users);

  Future<Result<ContactTrustRecord?>> readTrust(String userId);

  Future<Result<bool>> hasAnyDeviceLogFork();

  Future<Result<void>> writeTrust(ContactTrustRecord trust);

  Future<Result<List<PeerPublicDevice>>> readDevices(String userId);

  Future<Result<void>> replaceDevices(
    String userId,
    List<PeerPublicDevice> devices,
  );

  Future<Result<void>> appendVerifiedLogRecords(
    String userId,
    List<VerifiedDeviceLogRecord> records,
  );

  Future<Result<void>> writeProfile(
    String userId,
    ProfileCiphertext ciphertext,
    AuthenticatedProfile? authenticated,
  );

  Future<Result<LocalAccountIdentity>> readLocalIdentity();
}

abstract interface class PeerAuthenticationService implements Port {
  Future<Result<AuthenticatedPeer>> refreshPeer({
    required String userId,
    required bool requirePrekeys,
  });

  Future<Result<ContactTrustRecord>> confirmOutOfBand({
    required String userId,
    required Uint8List exactMasterPublic,
  });

  Future<Result<SafetyFingerprint>> safetyFingerprint(String userId);
}

/// Claims consumable prekeys only for the explicitly missing/repairing sessions.
/// The full live device list and device log are still authenticated before claim.
abstract interface class SelectivePeerPrekeyClaimPort implements Port {
  Future<Result<AuthenticatedPeer>> refreshPeerForDevices({
    required String userId,
    required List<String> deviceIds,
  });
}

/// Authenticates and returns the complete live device set without consuming keys.
abstract interface class VerifiedLiveDeviceResolverPort implements Port {
  Future<Result<AuthenticatedPeer>> resolveLiveDevices({
    required String userId,
  });

  /// [resolveLiveDevices] for each of [userIds], from one read of all of them.
  ///
  /// A failure belongs to the read itself, and nobody was verified. Otherwise
  /// every user has a result of its own, keyed as it was asked, reached in the
  /// order asked by the same checks [resolveLiveDevices] applies.
  Future<Result<Map<String, Result<AuthenticatedPeer>>>>
  resolveLiveDevicesForUsers({required List<String> userIds});
}

/// Control over whatever remembers a peer's server answers for a short while.
///
/// An implementation of this sits *below* [PeerIdentityRemotePort] and never
/// above it, so nothing it does can shorten the authentication that reads those
/// answers: every signature, hash-chain link, sequence and transition check runs
/// again, against the same bytes. What it removes is the round trip, not the
/// verification.
///
/// [live] exists because two callers must never be served a remembered answer.
/// A user asking to verify a contact, and the sync engine acting on a
/// `stale_devices` response, are both saying *this device's idea of that peer
/// may be wrong* — which is exactly the belief a cache would confirm.
abstract interface class PeerResolutionCachePort implements Port {
  /// Forgets everything remembered about [userId], including answers already
  /// in flight, which no later caller may join.
  void invalidate(String userId);

  /// Forgets everything remembered about everybody.
  void invalidateAll();

  /// Runs [resolve] with [userId] forgotten, and kept forgotten throughout.
  ///
  /// Bypassing for the whole of [resolve] rather than only at its first
  /// request is what makes this a *live resolution* instead of a cache miss:
  /// an identity, a device set and a device-log page fetched under it are all
  /// from this moment, and no concurrent resolution of the same user can be
  /// served an answer that predates the reason [resolve] was asked for.
  Future<T> live<T>(String userId, Future<T> Function() resolve);
}

/// The composition of [PeerResolutionCachePort] that remembers nothing.
///
/// Every round trip happens exactly where the code makes it. This is the
/// default a [PeerAuthenticationService] is constructed with, so a build or a
/// test that composes no cache behaves as though none existed.
final class NoPeerResolutionCache implements PeerResolutionCachePort {
  const NoPeerResolutionCache();

  @override
  void invalidate(String userId) {}

  @override
  void invalidateAll() {}

  @override
  Future<T> live<T>(String userId, Future<T> Function() resolve) => resolve();
}

final class VerifiedDeviceLogRecord {
  VerifiedDeviceLogRecord({
    required this.sequence,
    required Uint8List blob,
    required Uint8List hash,
  }) : blob = Uint8List.fromList(blob),
       hash = Uint8List.fromList(hash);

  final int sequence;
  final Uint8List blob;
  final Uint8List hash;
}

abstract interface class ProfileProtectionPort implements Port {
  bool get isProductionReady;

  Future<Result<(ProfileCiphertext, ProfileKeyMaterial)>> seal({
    required ProfileDraft profile,
    required String authorUserId,
    required String authorDeviceId,
    required int revision,
  });

  Future<Result<OpenedProfile>> open({
    required ProfileCiphertext ciphertext,
    required ProfileKeyMaterial key,
  });
}

abstract interface class ProfileKeyDistributionPort implements Port {
  bool get isProductionReady;

  Future<Result<void>> publish({
    required String ownerUserId,
    required int profileVersion,
    required ProfileKeyMaterial key,
  });

  Future<Result<ProfileKeyMaterial?>> receive({
    required String ownerUserId,
    required int profileVersion,
  });
}
