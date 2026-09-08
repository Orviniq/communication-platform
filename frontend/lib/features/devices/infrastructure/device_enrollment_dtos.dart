import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';

final class RegisterDeviceRequestDto {
  const RegisterDeviceRequestDto(this.public);

  final DeviceRegistrationPublic public;

  Map<String, Object?> toJson() => {
    'ik_pub': base64Encode(public.ikPub),
    'spk_id': public.spkId,
    'spk_pub': base64Encode(public.spkPub),
    'spk_sig': base64Encode(public.spkSig),
    'registration_id': public.registrationId,
    'pq_spk': {
      'spk_id': public.pqSpkId,
      'pub': base64Encode(public.pqSpkPub),
      'sig': base64Encode(public.pqSpkSig),
    },
    'otpks': [
      for (final prekey in public.otpks)
        {'key_id': prekey.keyId, 'pub': base64Encode(prekey.publicKey)},
    ],
    'pq_otpks': [
      for (final prekey in public.pqOtpks)
        {'key_id': prekey.keyId, 'pub': base64Encode(prekey.publicKey)},
    ],
  };
}

final class RegisterDeviceResponseDto {
  const RegisterDeviceResponseDto({
    required this.deviceId,
    required this.token,
    required this.expiresIn,
  });

  factory RegisterDeviceResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final deviceId = json['device_id'];
    final token = json['token'];
    final scope = json['scope'];
    if (deviceId is! String ||
        !_uuid.hasMatch(deviceId) ||
        token is! String ||
        token.isEmpty ||
        scope != 'full') {
      throw const MalformedApiBody();
    }
    return RegisterDeviceResponseDto(
      deviceId: deviceId,
      token: token,
      expiresIn: readExpiresIn(json['expires_in']),
    );
  }

  final String deviceId;

  /// The new device's session token, and what this client cross-signs with.
  final String token;
  final Duration expiresIn;

  /// [receivedAt] anchors [expiresIn], which the server states relative to the
  /// moment it issued the token.
  DeviceRegistrationResponse toDomain(String userId, {DateTime? receivedAt}) =>
      DeviceRegistrationResponse(
        deviceId: deviceId,
        userId: userId,
        accessToken: token,
        accessExpiresAt: (receivedAt ?? DateTime.now()).toUtc().add(expiresIn),
      );
}

final class IdentityRequestDto {
  const IdentityRequestDto(this.identity);

  final PublishedIdentity identity;

  Map<String, Object?> toJson() => {
    'master_pub': base64Encode(identity.masterPub),
    'self_signing_pub': base64Encode(identity.selfSigningPub),
    'user_signing_pub': base64Encode(identity.userSigningPub),
    'master_sig': base64Encode(identity.masterSig),
    'version': identity.version,
  };
}

final class IdentityResponseDto {
  const IdentityResponseDto({
    required this.masterPub,
    required this.selfSigningPub,
    required this.userSigningPub,
    required this.masterSig,
    required this.version,
  });

  factory IdentityResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final masterPub = _requiredBase64(json['master_pub'], 32);
    final selfSigningPub = _requiredBase64(json['self_signing_pub'], 32);
    final userSigningPub = _requiredBase64(json['user_signing_pub'], 32);
    final masterSig = _requiredBase64(json['master_sig'], 64);
    final version = json['version'];
    if (version is! int || version <= 0) {
      throw const MalformedApiBody();
    }
    return IdentityResponseDto(
      masterPub: masterPub,
      selfSigningPub: selfSigningPub,
      userSigningPub: userSigningPub,
      masterSig: masterSig,
      version: version,
    );
  }

  final Uint8List masterPub;
  final Uint8List selfSigningPub;
  final Uint8List userSigningPub;
  final Uint8List masterSig;
  final int version;

  PublishedIdentity toDomain() => PublishedIdentity(
    masterPub: masterPub,
    selfSigningPub: selfSigningPub,
    userSigningPub: userSigningPub,
    masterSig: masterSig,
    version: version,
  );
}

final class PrekeyFollowUpRequestDto {
  const PrekeyFollowUpRequestDto({
    required this.crossSignature,
    required this.bundleVersion,
  });

  final Uint8List crossSignature;
  final int bundleVersion;

  Map<String, Object?> toJson() => {
    'cross_sig': base64Encode(crossSignature),
    'bundle_version': bundleVersion,
  };
}

final class BackupResponseDto {
  const BackupResponseDto({required this.blob, required this.version});

  factory BackupResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final blobValue = json['blob'];
    final version = json['version'];
    if (blobValue is! String ||
        version is! int ||
        version <= 0 ||
        !_isBucketBase64(blobValue, const {
          4096,
          16384,
          65536,
          262144,
          1048576,
        })) {
      throw const MalformedApiBody();
    }
    return BackupResponseDto(
      blob: Uint8List.fromList(base64Decode(blobValue)),
      version: version,
    );
  }

  final Uint8List blob;
  final int version;

  KeyBackup toDomain() => KeyBackup(blob: blob, version: version);
}

final class BackupRequestDto {
  const BackupRequestDto({required this.blob, required this.version});

  final Uint8List blob;
  final int version;

  Map<String, Object?> toJson() => {
    'blob': base64Encode(blob),
    'version': version,
  };
}

final class PublicDevicesResponseDto {
  const PublicDevicesResponseDto({
    required this.devices,
    required this.etag,
    required this.logHeadSequence,
  });

  factory PublicDevicesResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final values = json['devices'];
    final etag = json['etag'];
    final head = json['log_head_seq'];
    if (values is! List<Object?> ||
        values.length > 10 ||
        (etag != null && etag is! String) ||
        (head != null && (head is! int || head < 0))) {
      throw const MalformedApiBody();
    }
    return PublicDevicesResponseDto(
      devices: values.map(PublicDeviceDto.fromJson).toList(growable: false),
      etag: etag as String?,
      logHeadSequence: head as int?,
    );
  }

  final List<PublicDeviceDto> devices;
  final String? etag;
  final int? logHeadSequence;

  PublicDeviceList toDomain() => PublicDeviceList(
    devices: devices.map((value) => value.toDomain()).toList(growable: false),
    logHeadSequence: logHeadSequence,
    etag: etag,
  );
}

final class PublicDeviceDto {
  const PublicDeviceDto({
    required this.deviceId,
    required this.ikPub,
    required this.registrationId,
    required this.crossSignature,
    required this.bundleVersion,
  });

  factory PublicDeviceDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final deviceId = json['device_id'];
    final registrationId = json['registration_id'];
    final ikPub = _requiredBase64(json['ik_pub'], 64);
    final cross = json['cross_sig'];
    final bundleVersion = json['bundle_version'];
    if (deviceId is! String ||
        !_uuid.hasMatch(deviceId) ||
        registrationId is! int ||
        registrationId < 0 ||
        (cross != null &&
            (cross is! String || !_isCanonicalBase64(cross, 64))) ||
        (bundleVersion != null &&
            (bundleVersion is! int || bundleVersion <= 0)) ||
        (cross == null) != (bundleVersion == null)) {
      throw const MalformedApiBody();
    }
    return PublicDeviceDto(
      deviceId: deviceId,
      ikPub: ikPub,
      registrationId: registrationId,
      crossSignature: cross == null ? null : base64Decode(cross as String),
      bundleVersion: bundleVersion as int?,
    );
  }

  final String deviceId;
  final Uint8List ikPub;
  final int registrationId;
  final Uint8List? crossSignature;
  final int? bundleVersion;

  PublicDevice toDomain() => PublicDevice(
    deviceId: deviceId,
    ikPub: ikPub,
    registrationId: registrationId,
    crossSignature: crossSignature,
    bundleVersion: bundleVersion,
  );
}

final class DeviceLogPageDto {
  const DeviceLogPageDto({
    required this.records,
    required this.hasMore,
    required this.headSequence,
  });

  factory DeviceLogPageDto.fromJson(Object? value) {
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
    final records = <DeviceLogRecord>[];
    for (final item in values) {
      final record = requireJsonObject(item);
      final blob = record['blob'];
      final sequence = record['seq'];
      if (blob is! String ||
          sequence is! int ||
          sequence < 0 ||
          !_isBucketBase64(blob, const {256, 1024})) {
        throw const MalformedApiBody();
      }
      records.add(
        DeviceLogRecord(
          sequence: sequence,
          blob: Uint8List.fromList(base64Decode(blob)),
        ),
      );
    }
    return DeviceLogPageDto(
      records: records,
      hasMore: hasMore,
      headSequence: head as int?,
    );
  }

  final List<DeviceLogRecord> records;
  final bool hasMore;
  final int? headSequence;

  DeviceLogPage toDomain() => DeviceLogPage(
    records: records,
    hasMore: hasMore,
    headSequence: headSequence,
  );
}

final class DeviceLogAppendResponseDto {
  const DeviceLogAppendResponseDto({
    required this.firstSequence,
    required this.lastSequence,
  });

  factory DeviceLogAppendResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final first = json['first_seq'];
    final last = json['last_seq'];
    if (first is! int || last is! int || first < 0 || last < first) {
      throw const MalformedApiBody();
    }
    return DeviceLogAppendResponseDto(firstSequence: first, lastSequence: last);
  }

  final int firstSequence;
  final int lastSequence;

  DeviceLogAppendResult toDomain() => DeviceLogAppendResult(
    firstSequence: firstSequence,
    lastSequence: lastSequence,
  );
}

Uint8List _requiredBase64(Object? value, int length) {
  if (value is! String || !_isCanonicalBase64(value, length)) {
    throw const MalformedApiBody();
  }
  return Uint8List.fromList(base64Decode(value));
}

bool _isCanonicalBase64(String value, int length) {
  if (value.isEmpty ||
      value.length % 4 != 0 ||
      !_base64.hasMatch(value) ||
      base64Decode(value).length != length) {
    return false;
  }
  return base64Encode(base64Decode(value)) == value;
}

bool _isBucketBase64(String value, Set<int> buckets) {
  if (value.isEmpty || value.length % 4 != 0 || !_base64.hasMatch(value)) {
    return false;
  }
  try {
    final decoded = base64Decode(value);
    return buckets.contains(decoded.length) && base64Encode(decoded) == value;
  } on FormatException {
    return false;
  }
}

final _base64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);
final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
