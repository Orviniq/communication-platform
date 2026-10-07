import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/features/devices/infrastructure/device_enrollment_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('piece 10 contract DTOs', () {
    test(
      'registration contains all hybrid material and no completion fields',
      () {
        final json = RegisterDeviceRequestDto(_public()).toJson();

        expect(json.keys, <String>[
          'ik_pub',
          'spk_id',
          'spk_pub',
          'spk_sig',
          'registration_id',
          'pq_spk',
          'otpks',
          'pq_otpks',
        ]);
        expect(json, isNot(containsPair('cross_sig', anything)));
        expect(json, isNot(containsPair('bundle_version', anything)));
        expect((json['otpks']! as List<Object?>), hasLength(2));
        expect((json['pq_otpks']! as List<Object?>), hasLength(1));
        // `RegisterDeviceIn` has no `keypackages` field at all, so sending one
        // is not a courtesy the route ignores.
        expect(json, isNot(containsPair('keypackages', anything)));
      },
    );

    test('registration response requires full scope and one token', () {
      final receivedAt = DateTime.utc(2026, 9, 8, 12);
      final decoded = RegisterDeviceResponseDto.fromJson({
        'device_id': deviceId,
        'token': _jwt(2000000000),
        'expires_in': 2592000,
        'scope': 'full',
      }).toDomain(userId, receivedAt: receivedAt);

      expect(decoded.deviceId, deviceId);
      expect(decoded.userId, userId);
      expect(decoded.accessToken, _jwt(2000000000));
      expect(decoded.accessExpiresAt, receivedAt.add(const Duration(days: 30)));
      // The one route a register token reaches answers a session token; a
      // register scope back would mean it minted no device.
      expect(
        () => RegisterDeviceResponseDto.fromJson({
          'device_id': deviceId,
          'token': _jwt(2000000000),
          'expires_in': 2592000,
          'scope': 'register',
        }),
        throwsA(isA<MalformedApiBody>()),
      );
      expect(
        () => RegisterDeviceResponseDto.fromJson({
          'device_id': deviceId,
          'token': _jwt(2000000000),
          'scope': 'full',
        }),
        throwsA(isA<MalformedApiBody>()),
      );
    });

    test('backup accepts only exact documented opaque buckets', () {
      final valid = BackupResponseDto.fromJson({
        'blob': base64Encode(Uint8List(4096)),
        'version': 1,
      });
      expect(valid.blob, hasLength(4096));

      for (final length in <int>[0, 4095, 4097, 1048577]) {
        expect(
          () => BackupResponseDto.fromJson({
            'blob': base64Encode(Uint8List(length)),
            'version': 1,
          }),
          throwsA(isA<MalformedApiBody>()),
        );
      }
    });

    test('an own device that has not cross-signed itself is read as unsigned '
        'from the pair the server lists it with', () {
      final list = PublicDevicesResponseDto.fromJson({
        'devices': [
          {..._signedDeviceJson, 'bundle_version': 1},
          _unsignedDeviceJson,
        ],
        'etag': 'fixture',
        'log_head_seq': 0,
      }).toDomain();

      // 1 is the first version a signature can cover.
      expect(list.devices.first.isUnsigned, isFalse);
      expect(list.devices.first.bundleVersion, 1);
      // The 0 beside no signature is no version at all to the domain.
      expect(list.devices.last.isUnsigned, isTrue);
      expect(list.devices.last.crossSignature, isNull);
      expect(list.devices.last.bundleVersion, isNull);
    });

    test('an own device list refuses every other pairing of signature and '
        'version', () {
      for (final device in <Map<String, Object?>>[
        // A signature covers the version beside it, which starts at 1.
        {..._signedDeviceJson, 'bundle_version': 0},
        {..._signedDeviceJson, 'bundle_version': -1},
        {..._signedDeviceJson, 'bundle_version': null},
        // No signature at a version past 0, which is how a device that
        // withdrew its signature is listed, is not read as unsigned.
        {..._unsignedDeviceJson, 'bundle_version': 1},
        {..._unsignedDeviceJson, 'bundle_version': 3},
        // The version is always there, a number and never a negative one.
        {..._unsignedDeviceJson, 'bundle_version': -1},
        {..._unsignedDeviceJson, 'bundle_version': null},
        {..._unsignedDeviceJson, 'bundle_version': '0'},
        {..._unsignedDeviceJson, 'bundle_version': 0.5},
        {..._unsignedDeviceJson}..remove('bundle_version'),
      ]) {
        expect(
          () => PublicDevicesResponseDto.fromJson({
            'devices': [device],
            'etag': 'fixture',
            'log_head_seq': 0,
          }),
          throwsA(isA<MalformedApiBody>()),
          reason: '$device',
        );
      }
    });

    test(
      'device-log response binds outer sequence and exact record buckets',
      () {
        final page = DeviceLogPageDto.fromJson({
          'records': [
            {'seq': 0, 'blob': base64Encode(Uint8List(256))},
            {'seq': 1, 'blob': base64Encode(Uint8List(1024))},
          ],
          'has_more': false,
          'head_seq': 1,
        }).toDomain();
        expect(page.records.map((record) => record.sequence), <int>[0, 1]);

        expect(
          () => DeviceLogPageDto.fromJson({
            'records': [
              {'seq': 0, 'blob': base64Encode(Uint8List(255))},
            ],
            'has_more': false,
            'head_seq': 0,
          }),
          throwsA(isA<MalformedApiBody>()),
        );
      },
    );
  });
}

const userId = '6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10';
const deviceId = '9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611';

final _signedDeviceJson = <String, Object?>{
  'device_id': '55555555-5555-4555-8555-555555555555',
  'ik_pub': base64Encode(Uint8List(64)),
  'registration_id': 7,
  'cross_sig': base64Encode(Uint8List(64)),
  'bundle_version': 2,
};

/// A device between its registration and its cross-signature, as
/// `GET /api/v1/users/{user_id}/devices` serves it for this account: the
/// server stores 0 until the follow-up `PUT` names a version, and lists the
/// column verbatim.
final _unsignedDeviceJson = <String, Object?>{
  'device_id': deviceId,
  'ik_pub': base64Encode(Uint8List(64)),
  'registration_id': 8,
  'cross_sig': null,
  'bundle_version': 0,
};

DeviceRegistrationPublic _public() => DeviceRegistrationPublic(
  userId: Uint8List(16),
  registrationId: 7,
  spkId: 1,
  spkPub: Uint8List(32),
  spkSig: Uint8List(64),
  ikPub: Uint8List(64),
  pqSpkId: 1,
  pqSpkPub: Uint8List(1184),
  pqSpkSig: Uint8List(64),
  otpks: <DeviceOneTimePrekey>[
    DeviceOneTimePrekey(keyId: 1, publicKey: Uint8List(32)),
    DeviceOneTimePrekey(keyId: 2, publicKey: Uint8List(32)),
  ],
  pqOtpks: <DeviceOneTimePrekey>[
    DeviceOneTimePrekey(keyId: 1, publicKey: Uint8List(1184)),
  ],
  fingerprint: Uint8List(32),
);

String _jwt(int expiry) {
  final header = base64Url.encode(utf8.encode('{}')).replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'exp': expiry})))
      .replaceAll('=', '');
  return '$header.$payload.signature';
}
