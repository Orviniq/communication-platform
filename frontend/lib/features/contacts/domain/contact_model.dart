import 'dart:typed_data';

import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';

enum ContactTrustState {
  unverified,
  verified,
  masterKeyChanged,
  invalidDevice,
  deviceLogFork,
  identityUnavailable,
}

final class DirectoryUser {
  const DirectoryUser({required this.userId, required this.username});

  final String userId;
  final String username;
}

final class ProfileDraft {
  const ProfileDraft({required this.displayName, required this.avatarSeed});

  final String displayName;
  final int avatarSeed;

  bool get isValid =>
      displayName.trim().isNotEmpty && displayName.trim().length <= 64;
}

final class AuthenticatedProfile {
  const AuthenticatedProfile({
    required this.displayName,
    required this.avatarSeed,
    required this.version,
    required this.authorDeviceId,
  });

  final String displayName;
  final int avatarSeed;
  final int version;
  final String authorDeviceId;
}

final class ContactProjection {
  const ContactProjection({
    required this.userId,
    required this.username,
    required this.trustState,
    this.authenticatedProfile,
  });

  final String userId;
  final String username;
  final ContactTrustState trustState;
  final AuthenticatedProfile? authenticatedProfile;

  bool get isVerified => trustState == ContactTrustState.verified;

  bool get canUseAuthenticatedProfile =>
      isVerified && authenticatedProfile != null;

  String get presentationName =>
      canUseAuthenticatedProfile ? authenticatedProfile!.displayName : username;

  int? get authenticatedAvatarSeed =>
      canUseAuthenticatedProfile ? authenticatedProfile!.avatarSeed : null;

  bool get sensitiveActionsBlocked => !isVerified;
}

final class DirectoryPage {
  const DirectoryPage({
    required this.contacts,
    required this.offset,
    required this.hasMore,
    required this.offline,
  });

  final List<ContactProjection> contacts;
  final int offset;
  final bool hasMore;
  final bool offline;
}

final class ContactTrustRecord {
  ContactTrustRecord({
    required this.userId,
    required this.state,
    this.identity,
    Uint8List? confirmedMasterPublic,
    this.attestation,
    this.etag,
    this.logHeadSequence,
    Uint8List? logHeadHash,
  }) : confirmedMasterPublic = confirmedMasterPublic == null
           ? null
           : Uint8List.fromList(confirmedMasterPublic),
       logHeadHash = logHeadHash == null
           ? null
           : Uint8List.fromList(logHeadHash);

  final String userId;
  final ContactTrustState state;
  final PeerIdentityPublic? identity;
  final Uint8List? confirmedMasterPublic;
  final UserSigningAttestation? attestation;
  final String? etag;
  final int? logHeadSequence;
  final Uint8List? logHeadHash;

  bool get isSensitiveActionAllowed => state == ContactTrustState.verified;

  ContactTrustRecord copyWith({
    ContactTrustState? state,
    PeerIdentityPublic? identity,
    Uint8List? confirmedMasterPublic,
    UserSigningAttestation? attestation,
    String? etag,
    int? logHeadSequence,
    Uint8List? logHeadHash,
  }) => ContactTrustRecord(
    userId: userId,
    state: state ?? this.state,
    identity: identity ?? this.identity,
    confirmedMasterPublic: confirmedMasterPublic ?? this.confirmedMasterPublic,
    attestation: attestation ?? this.attestation,
    etag: etag ?? this.etag,
    logHeadSequence: logHeadSequence ?? this.logHeadSequence,
    logHeadHash: logHeadHash ?? this.logHeadHash,
  );
}

final class LocalAccountIdentity {
  const LocalAccountIdentity({
    required this.userId,
    required this.deviceId,
    required this.username,
    required this.identityPackage,
  });

  final String userId;
  final String deviceId;
  final String username;
  final IdentityKeyPackage identityPackage;
}

final class ProfileCiphertext {
  ProfileCiphertext({required Uint8List blob, required this.version})
    : blob = Uint8List.fromList(blob);

  final Uint8List blob;
  final int version;
}

final class ProfileKeyMaterial {
  ProfileKeyMaterial(Uint8List bytes) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
}

final class OpenedProfile {
  const OpenedProfile({
    required this.draft,
    required this.authorUserId,
    required this.authorDeviceId,
    required this.revision,
  });

  final ProfileDraft draft;
  final String authorUserId;
  final String authorDeviceId;
  final int revision;
}

sealed class PeerDeviceRefresh {
  const PeerDeviceRefresh();
}

final class PeerDevicesNotModified extends PeerDeviceRefresh {
  const PeerDevicesNotModified();
}

final class PeerDevicesUpdated extends PeerDeviceRefresh {
  const PeerDevicesUpdated({
    required this.devices,
    required this.etag,
    required this.logHeadSequence,
  });

  final List<PeerPublicDevice> devices;
  final String etag;
  final int? logHeadSequence;
}

/// One peer named in a `POST /api/v1/peers` request.
final class PeerStateQuery {
  const PeerStateQuery({required this.userId, this.etag});

  final String userId;

  /// The tag this route gave for [userId] before, which is what lets it answer
  /// [PeerStateUnchanged].
  final String? etag;
}

/// What `POST /api/v1/peers` said about one peer.
sealed class PeerStateRead {
  const PeerStateRead();
}

/// The tag the request carried still holds: the identity, the live devices,
/// their bundle versions and the log head are as this client last read them
/// with it.
final class PeerStateUnchanged extends PeerStateRead {
  const PeerStateUnchanged({required this.etag});

  final String etag;
}

/// A peer's whole state: the bytes the per-user identity read and device-list
/// read serve, under this route's own tag.
final class PeerStateUpdated extends PeerStateRead {
  const PeerStateUpdated({
    required this.identity,
    required this.devices,
    required this.logHeadSequence,
    required this.etag,
  });

  /// Null when the peer has published none.
  final PeerIdentityPublic? identity;
  final List<PeerPublicDevice> devices;
  final int? logHeadSequence;
  final String etag;
}

/// Left out of the answer: the user does not exist, is not activated or was
/// deactivated, and the route does not say which.
final class PeerStateAbsent extends PeerStateRead {
  const PeerStateAbsent();
}

final class PeerDeviceLogPage {
  const PeerDeviceLogPage({
    required this.records,
    required this.hasMore,
    required this.headSequence,
  });

  final List<PeerDeviceLogRecord> records;
  final bool hasMore;
  final int? headSequence;
}

final class PeerDeviceLogRecord {
  PeerDeviceLogRecord({required this.sequence, required Uint8List blob})
    : blob = Uint8List.fromList(blob);

  final int sequence;
  final Uint8List blob;
}

final class AuthenticatedPeer {
  const AuthenticatedPeer({
    required this.trust,
    required this.devices,
    required this.claimedBundles,
  });

  final ContactTrustRecord trust;
  final List<PeerPublicDevice> devices;
  final List<ClaimedPrekeyBundle> claimedBundles;

  bool get canPerformSensitiveActions =>
      trust.isSensitiveActionAllowed && claimedBundles.length == devices.length;
}

final class PlaceholderAvatarStyle {
  const PlaceholderAvatarStyle({
    required this.initials,
    required this.paletteIndex,
  });

  factory PlaceholderAvatarStyle.fromUsername(String username) {
    final normalized = username.trim().toLowerCase();
    var hash = 0x811c9dc5;
    for (final byte in 'chat:v1:placeholder-avatar:$normalized'.codeUnits) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    final parts = normalized
        .split(RegExp(r'[_\s]+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    final initials = parts.isEmpty
        ? '?'
        : parts.length == 1
        ? parts.first.characters.take(2).join().toUpperCase()
        : '${parts.first.characters.first}${parts.last.characters.first}'
              .toUpperCase();
    return PlaceholderAvatarStyle(initials: initials, paletteIndex: hash % 8);
  }

  final String initials;
  final int paletteIndex;
}

extension _CodePointCharacters on String {
  Iterable<String> get characters sync* {
    for (final rune in runes) {
      yield String.fromCharCode(rune);
    }
  }
}
