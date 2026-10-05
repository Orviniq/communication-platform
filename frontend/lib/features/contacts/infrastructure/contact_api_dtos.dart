import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';

final class DirectoryResponseDto {
  const DirectoryResponseDto(this.users);

  factory DirectoryResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final values = json['users'];
    if (values is! List<Object?> || values.length > 10000) {
      throw const MalformedApiBody();
    }
    final users = <DirectoryUser>[];
    final ids = <String>{};
    String? previous;
    for (final value in values) {
      final row = requireJsonObject(value);
      final userId = row['user_id'];
      final username = row['username'];
      if (row.length != 2 ||
          userId is! String ||
          !_uuid.hasMatch(userId) ||
          username is! String ||
          !_username.hasMatch(username) ||
          username != username.toLowerCase() ||
          !ids.add(userId) ||
          (previous != null && previous.compareTo(username) > 0)) {
        throw const MalformedApiBody();
      }
      users.add(DirectoryUser(userId: userId, username: username));
      previous = username;
    }
    return DirectoryResponseDto(List.unmodifiable(users));
  }

  final List<DirectoryUser> users;
}

final class ProfileResponseDto {
  const ProfileResponseDto(this.profile);

  factory ProfileResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final blob = json['blob'];
    final version = json['version'];
    if (blob is! String || version is! int || version <= 0) {
      throw const MalformedApiBody();
    }
    final bytes = _base64(blob);
    if (bytes == null || (bytes.length != 1024 && bytes.length != 4096)) {
      throw const MalformedApiBody();
    }
    return ProfileResponseDto(ProfileCiphertext(blob: bytes, version: version));
  }

  final ProfileCiphertext profile;
}

final class PeerIdentityResponseDto {
  const PeerIdentityResponseDto(this.refresh);

  factory PeerIdentityResponseDto.fromJson(Object? value) {
    if (value == null) {
      return const PeerIdentityResponseDto(PeerIdentityNotModified());
    }
    final (:identity, :etag) = _identity(value);
    return PeerIdentityResponseDto(
      PeerIdentityUpdated(identity: identity, etag: etag),
    );
  }

  final PeerIdentityRefresh refresh;
}

final class PeerDevicesResponseDto {
  const PeerDevicesResponseDto(this.refresh);

  factory PeerDevicesResponseDto.fromJson(Object? value) {
    if (value == null) {
      return const PeerDevicesResponseDto(PeerDevicesNotModified());
    }
    final json = requireJsonObject(value);
    final etag = json['etag'];
    if (etag is! String || etag.isEmpty) {
      throw const MalformedApiBody();
    }
    return PeerDevicesResponseDto(
      PeerDevicesUpdated(
        devices: _devices(json['devices']),
        etag: etag,
        logHeadSequence: _logHead(json['log_head_seq']),
      ),
    );
  }

  final PeerDeviceRefresh refresh;
}

/// What `POST /api/v1/peers` answered for the peers one request named.
///
/// Items are matched to [requested] by `user_id`, never by position or count:
/// a user that does not exist, is not activated or was deactivated is left out
/// of the answer, and is [PeerStateAbsent] here. A full item is read by the
/// same code that reads the per-user identity and device-list answers, because
/// it is the same bytes.
final class PeerStatesResponseDto {
  const PeerStatesResponseDto(this.peers);

  factory PeerStatesResponseDto.fromJson(
    Object? value, {
    required List<PeerStateQuery> requested,
  }) {
    final json = requireJsonObject(value);
    final values = json['peers'];
    if (values is! List<Object?> || values.length > requested.length) {
      throw const MalformedApiBody();
    }
    final queries = {
      for (final query in requested) query.userId.toLowerCase(): query,
    };
    final answered = <String, PeerStateRead>{};
    for (final value in values) {
      final item = requireJsonObject(value);
      final userId = item['user_id'];
      final etag = item['etag'];
      final query = userId is String && _uuid.hasMatch(userId)
          ? queries[userId.toLowerCase()]
          : null;
      if (query == null ||
          answered.containsKey(query.userId) ||
          etag is! String ||
          etag.isEmpty ||
          etag.length > ApiContractLimits.maximumPeerStateEtagCharacters) {
        throw const MalformedApiBody();
      }
      // The shape is decided by whether `unchanged` is there at all. Its value
      // is always `true`, and anything else is a broken answer rather than the
      // other shape.
      answered[query.userId] = item.containsKey('unchanged')
          ? _unchangedPeer(item, query: query, etag: etag)
          : _updatedPeer(item, etag: etag);
    }
    return PeerStatesResponseDto(
      Map.unmodifiable({
        for (final query in requested)
          query.userId: answered[query.userId] ?? const PeerStateAbsent(),
      }),
    );
  }

  final Map<String, PeerStateRead> peers;

  /// `unchanged` says the tag the request carried still holds, so it can only
  /// answer a request that carried one, and only with that same tag.
  static PeerStateUnchanged _unchangedPeer(
    Map<String, Object?> item, {
    required PeerStateQuery query,
    required String etag,
  }) {
    if (item['unchanged'] != true ||
        item.containsKey('identity') ||
        item.containsKey('devices') ||
        item.containsKey('log_head_seq') ||
        query.etag != etag) {
      throw const MalformedApiBody();
    }
    return PeerStateUnchanged(etag: etag);
  }

  static PeerStateUpdated _updatedPeer(
    Map<String, Object?> item, {
    required String etag,
  }) {
    if (!item.containsKey('identity') || !item.containsKey('log_head_seq')) {
      throw const MalformedApiBody();
    }
    final identityValue = item['identity'];
    final identity = identityValue == null ? null : _identity(identityValue);
    return PeerStateUpdated(
      identity: identity?.identity,
      identityEtag: identity?.etag,
      devices: _devices(item['devices']),
      logHeadSequence: _logHead(item['log_head_seq']),
      etag: etag,
    );
  }
}

/// The body of `GET /api/v1/users/{user_id}/identity`, wherever it is served,
/// with that route's own tag for it.
({PeerIdentityPublic identity, String etag}) _identity(Object? value) {
  final json = requireJsonObject(value);
  final version = json['version'];
  final master = _base64(json['master_pub'], length: 32);
  final selfSigning = _base64(json['self_signing_pub'], length: 32);
  final userSigning = _base64(json['user_signing_pub'], length: 32);
  final signature = _base64(json['master_sig'], length: 64);
  final etag = json['etag'];
  if (version is! int ||
      version <= 0 ||
      master == null ||
      selfSigning == null ||
      userSigning == null ||
      signature == null ||
      etag is! String ||
      etag.isEmpty) {
    throw const MalformedApiBody();
  }
  return (
    identity: PeerIdentityPublic(
      masterPublic: master,
      selfSigningPublic: selfSigning,
      userSigningPublic: userSigning,
      masterSignature: signature,
      version: version,
    ),
    etag: etag,
  );
}

/// The items of `GET /api/v1/users/{user_id}/devices`, wherever they are
/// served.
///
/// The server stores a device's `bundle_version` as 0 until the device
/// cross-signs itself, and lists it verbatim, so an unsigned device arrives as
/// `cross_sig: null, bundle_version: 0`. That pair, and only that pair, is read
/// as unsigned, which the domain holds as no version at all. A signature covers
/// a version of 1 or more, and every other pair is malformed, a version past 0
/// with no signature included (ADR-081).
List<PeerPublicDevice> _devices(Object? values) {
  if (values is! List<Object?> || values.length > 100) {
    throw const MalformedApiBody();
  }
  return values
      .map((value) {
        final row = requireJsonObject(value);
        final id = row['device_id'];
        final ik = _base64(row['ik_pub'], length: 64);
        final registration = row['registration_id'];
        final crossValue = row['cross_sig'];
        final cross = crossValue == null
            ? null
            : _base64(crossValue, length: 64);
        final version = row['bundle_version'];
        if (id is! String ||
            !_uuid.hasMatch(id) ||
            ik == null ||
            registration is! int ||
            registration < 0 ||
            (crossValue != null && cross == null) ||
            version is! int ||
            (cross == null ? version != 0 : version <= 0)) {
          throw const MalformedApiBody();
        }
        return PeerPublicDevice(
          deviceId: id,
          identityPublic: ik,
          registrationId: registration,
          crossSignature: cross,
          bundleVersion: cross == null ? null : version,
        );
      })
      .toList(growable: false);
}

/// A device-log head, which is null for an empty log.
int? _logHead(Object? head) {
  if (head != null && (head is! int || head < 0)) {
    throw const MalformedApiBody();
  }
  return head as int?;
}

final class ClaimedBundlesResponseDto {
  const ClaimedBundlesResponseDto(this.bundles);

  factory ClaimedBundlesResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final values = json['bundles'];
    if (values is! List<Object?> || values.length > 100) {
      throw const MalformedApiBody();
    }
    return ClaimedBundlesResponseDto(
      values.map(_bundle).toList(growable: false),
    );
  }

  final List<ClaimedPrekeyBundle> bundles;

  static ClaimedPrekeyBundle _bundle(Object? value) {
    final row = requireJsonObject(value);
    final deviceId = row['device_id'];
    final registrationId = row['registration_id'];
    final ik = _base64(row['ik_pub'], length: 64);
    final spkId = row['spk_id'];
    final spk = _base64(row['spk_pub'], length: 32);
    final spkSig = _base64(row['spk_sig'], length: 64);
    final cross = _base64(row['cross_sig'], length: 64);
    final bundleVersion = row['bundle_version'];
    final pqId = row['pq_spk_id'];
    final pq = row['pq_spk_pub'] == null
        ? null
        : _base64(row['pq_spk_pub'], length: 1184);
    final pqSig = row['pq_spk_sig'] == null
        ? null
        : _base64(row['pq_spk_sig'], length: 64);
    if (deviceId is! String ||
        !_uuid.hasMatch(deviceId) ||
        registrationId is! int ||
        registrationId < 0 ||
        ik == null ||
        spkId is! int ||
        spkId < 0 ||
        spk == null ||
        spkSig == null ||
        cross == null ||
        bundleVersion is! int ||
        bundleVersion <= 0 ||
        ((pqId != null || pq != null || pqSig != null) &&
            (pqId is! int || pqId < 0 || pq == null || pqSig == null))) {
      throw const MalformedApiBody();
    }
    final otpk = _optionalPrekey(row['otpk'], 32);
    final pqOtpk = _optionalPrekey(row['pq_otpk'], 1184);
    return ClaimedPrekeyBundle(
      deviceId: deviceId,
      registrationId: registrationId,
      identityPublic: ik,
      signedPrekeyId: spkId,
      signedPrekeyPublic: spk,
      signedPrekeySignature: spkSig,
      crossSignature: cross,
      bundleVersion: bundleVersion,
      pqSignedPrekeyId: pqId as int?,
      pqSignedPrekeyPublic: pq,
      pqSignedPrekeySignature: pqSig,
      oneTimePrekeyId: otpk?.$1,
      oneTimePrekeyPublic: otpk?.$2,
      pqOneTimePrekeyId: pqOtpk?.$1,
      pqOneTimePrekeyPublic: pqOtpk?.$2,
    );
  }
}

final class PeerDeviceLogPageDto {
  const PeerDeviceLogPageDto(this.page);

  factory PeerDeviceLogPageDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final values = json['records'];
    final hasMore = json['has_more'];
    final head = json['head_seq'];
    if (values is! List<Object?> ||
        values.length > 200 ||
        hasMore is! bool ||
        (head != null && (head is! int || head < 0))) {
      throw const MalformedApiBody();
    }
    final records = <PeerDeviceLogRecord>[];
    for (final item in values) {
      final row = requireJsonObject(item);
      final sequence = row['seq'];
      final blob = _base64(row['blob']);
      if (sequence is! int ||
          sequence < 0 ||
          blob == null ||
          (blob.length != 256 && blob.length != 1024)) {
        throw const MalformedApiBody();
      }
      records.add(PeerDeviceLogRecord(sequence: sequence, blob: blob));
    }
    return PeerDeviceLogPageDto(
      PeerDeviceLogPage(
        records: records,
        hasMore: hasMore,
        headSequence: head as int?,
      ),
    );
  }

  final PeerDeviceLogPage page;
}

(int, Uint8List)? _optionalPrekey(Object? value, int length) {
  if (value == null) {
    return null;
  }
  final row = requireJsonObject(value);
  final keyId = row['key_id'];
  final public = _base64(row['pub'], length: length);
  if (keyId is! int || keyId < 0 || public == null) {
    throw const MalformedApiBody();
  }
  return (keyId, public);
}

Uint8List? _base64(Object? value, {int? length}) {
  if (value is! String || value.isEmpty || value.length % 4 != 0) {
    return null;
  }
  try {
    final bytes = base64Decode(value);
    if (base64Encode(bytes) != value ||
        (length != null && bytes.length != length)) {
      return null;
    }
    return Uint8List.fromList(bytes);
  } on FormatException {
    return null;
  }
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _username = RegExp(r'^[a-z0-9_]{3,32}$');
