import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/infrastructure/contact_api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('activated directory accepts canonical sorted pages', () {
    final dto = DirectoryResponseDto.fromJson({
      'users': [
        {
          'user_id': '11111111-1111-4111-8111-111111111111',
          'username': 'alice',
        },
        {'user_id': '22222222-2222-4222-8222-222222222222', 'username': 'bob'},
      ],
    });

    expect(dto.users.map((user) => user.username), ['alice', 'bob']);
  });

  test(
    'activated directory rejects duplicate, unsorted, or noncanonical data',
    () {
      expect(
        () => DirectoryResponseDto.fromJson({
          'users': [
            {
              'user_id': '11111111-1111-4111-8111-111111111111',
              'username': 'bob',
            },
            {
              'user_id': '11111111-1111-4111-8111-111111111111',
              'username': 'Alice',
            },
          ],
        }),
        throwsA(isA<MalformedApiBody>()),
      );
    },
  );

  test('304 device response maps only to the explicit ETag cache state', () {
    final dto = PeerDevicesResponseDto.fromJson(null);

    expect(dto.refresh.runtimeType.toString(), 'PeerDevicesNotModified');
  });

  group('the identity read', () {
    test('a 304 with no body is the not-modified answer', () {
      final dto = PeerIdentityResponseDto.fromJson(null);

      expect(dto.refresh, isA<PeerIdentityNotModified>());
    });

    test('carries the tag it was served with', () {
      final dto = PeerIdentityResponseDto.fromJson(_identityJson);

      final updated = dto.refresh as PeerIdentityUpdated;
      expect(updated.etag, '"identity-tag"');
      expect(updated.identity.version, 3);
    });

    test('is refused without its tag', () {
      for (final body in <Map<String, Object?>>[
        {..._identityJson}..remove('etag'),
        {..._identityJson, 'etag': ''},
        {..._identityJson, 'etag': 7},
      ]) {
        expect(
          () => PeerIdentityResponseDto.fromJson(body),
          throwsA(isA<MalformedApiBody>()),
          reason: '$body',
        );
      }
    });
  });

  group('the batched peer-state answer', () {
    const requested = [
      PeerStateQuery(userId: _first, etag: _firstTag),
      PeerStateQuery(userId: _second),
      PeerStateQuery(userId: _missing, etag: '"left-out"'),
    ];

    test('is matched to the request by user id, never by position', () {
      final dto = PeerStatesResponseDto.fromJson({
        'peers': [
          // Out of request order, and in the server's lower case.
          _full(_second.toLowerCase()),
          {'user_id': _first, 'etag': _firstTag, 'unchanged': true},
        ],
      }, requested: requested);

      expect(dto.peers.keys, [_first, _second, _missing]);
      expect(dto.peers[_first], isA<PeerStateUnchanged>());
      final updated = dto.peers[_second]! as PeerStateUpdated;
      expect(updated.etag, _secondTag);
      expect(updated.identity?.version, 3);
      expect(updated.devices.single.bundleVersion, 2);
      expect(updated.logHeadSequence, 4);
      // Fewer items than were asked for: the one left out is absent.
      expect(dto.peers[_missing], isA<PeerStateAbsent>());
    });

    test('reads an empty state as the per-user reads do', () {
      final dto = PeerStatesResponseDto.fromJson({
        'peers': [
          {
            'user_id': _second,
            'etag': _secondTag,
            'identity': null,
            'devices': <Object?>[],
            'log_head_seq': null,
          },
        ],
      }, requested: requested);

      final updated = dto.peers[_second]! as PeerStateUpdated;
      expect(updated.identity, isNull);
      expect(updated.identityEtag, isNull);
      expect(updated.devices, isEmpty);
      expect(updated.logHeadSequence, isNull);
    });

    test('keeps the identity tag apart from the answer tag', () {
      final dto = PeerStatesResponseDto.fromJson({
        'peers': [_full(_second)],
      }, requested: requested);

      final updated = dto.peers[_second]! as PeerStateUpdated;
      expect(updated.etag, _secondTag);
      expect(updated.identityEtag, '"identity-tag"');
    });

    test('takes `unchanged` only as the echo of the tag that was sent', () {
      for (final item in <Map<String, Object?>>[
        // Its value is always true; anything else is a broken answer, not
        // the other shape.
        {'user_id': _first, 'etag': _firstTag, 'unchanged': false},
        {'user_id': _first, 'etag': _firstTag, 'unchanged': null},
        // No tag was sent for this user, so none can still hold.
        {'user_id': _second, 'etag': _secondTag, 'unchanged': true},
        // A tag other than the one sent.
        {'user_id': _first, 'etag': _secondTag, 'unchanged': true},
        // Both shapes at once.
        {..._full(_first), 'etag': _firstTag, 'unchanged': true},
      ]) {
        expect(
          () => PeerStatesResponseDto.fromJson({
            'peers': [item],
          }, requested: requested),
          throwsA(isA<MalformedApiBody>()),
          reason: '$item',
        );
      }
    });

    test('refuses an answer about anybody it was not asked about', () {
      for (final peers in <List<Object?>>[
        [_full(_unasked)],
        [_full(_second), _full(_second)],
        [_full(_second), _full(_second.toLowerCase())],
        [_full(_second), _full(_first), _full(_missing), _full(_unasked)],
      ]) {
        expect(
          () => PeerStatesResponseDto.fromJson({
            'peers': peers,
          }, requested: requested),
          throwsA(isA<MalformedApiBody>()),
        );
      }
    });

    test('refuses a full item the per-user reads would refuse', () {
      for (final item in <Map<String, Object?>>[
        {..._full(_second)}..remove('identity'),
        {..._full(_second)}..remove('log_head_seq'),
        {..._full(_second)}..remove('devices'),
        {..._full(_second), 'etag': ''},
        {..._full(_second), 'etag': '"${'a' * 64}"'},
        {..._full(_second), 'log_head_seq': -1},
        {
          ..._full(_second),
          'identity': {..._identityJson, 'master_sig': 'AAAA'},
        },
        {
          ..._full(_second),
          'identity': {..._identityJson}..remove('etag'),
        },
        {
          ..._full(_second),
          'devices': [
            {..._deviceJson, 'ik_pub': base64Encode(Uint8List(63))},
          ],
        },
      ]) {
        expect(
          () => PeerStatesResponseDto.fromJson({
            'peers': [item],
          }, requested: requested),
          throwsA(isA<MalformedApiBody>()),
          reason: '$item',
        );
      }
    });
  });

  group('a device that has not cross-signed itself', () {
    test('is read as unsigned from the pair the server lists it with', () {
      final devices = [
        {..._deviceJson, 'bundle_version': 1},
        _unsignedDeviceJson,
      ];
      final listed =
          PeerDevicesResponseDto.fromJson({
                'devices': devices,
                'etag': _secondTag,
                'log_head_seq': 4,
              }).refresh
              as PeerDevicesUpdated;
      final batched =
          PeerStatesResponseDto.fromJson(
                {
                  'peers': [
                    {..._full(_second), 'devices': devices},
                  ],
                },
                requested: const [PeerStateQuery(userId: _second)],
              ).peers[_second]!
              as PeerStateUpdated;

      for (final read in [listed.devices, batched.devices]) {
        // 1 is the first version a signature can cover.
        expect(read.first.isUnsigned, isFalse);
        expect(read.first.bundleVersion, 1);
        // The 0 beside no signature is no version at all to the domain.
        expect(read.last.isUnsigned, isTrue);
        expect(read.last.crossSignature, isNull);
        expect(read.last.bundleVersion, isNull);
      }
    });

    test('refuses every other pairing of signature and version', () {
      for (final device in <Map<String, Object?>>[
        // A signature covers the version beside it, which starts at 1.
        {..._deviceJson, 'bundle_version': 0},
        {..._deviceJson, 'bundle_version': -1},
        {..._deviceJson, 'bundle_version': null},
        // No signature at a version past 0, which is how a device that
        // withdrew its signature is listed, is not read as unsigned.
        {..._unsignedDeviceJson, 'bundle_version': 1},
        {..._unsignedDeviceJson, 'bundle_version': 3},
        // The version is always there, a number and never a negative one.
        {..._unsignedDeviceJson, 'bundle_version': -1},
        {..._unsignedDeviceJson, 'bundle_version': null},
        {..._unsignedDeviceJson, 'bundle_version': '0'},
        {..._unsignedDeviceJson}..remove('bundle_version'),
      ]) {
        expect(
          () => PeerDevicesResponseDto.fromJson({
            'devices': [device],
            'etag': _secondTag,
            'log_head_seq': 4,
          }),
          throwsA(isA<MalformedApiBody>()),
          reason: '$device',
        );
        expect(
          () => PeerStatesResponseDto.fromJson(
            {
              'peers': [
                {
                  ..._full(_second),
                  'devices': [device],
                },
              ],
            },
            requested: const [PeerStateQuery(userId: _second)],
          ),
          throwsA(isA<MalformedApiBody>()),
          reason: '$device',
        );
      }
    });
  });
}

const _first = '11111111-1111-4111-8111-111111111111';
const _second = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _missing = '33333333-3333-4333-8333-333333333333';
const _unasked = '44444444-4444-4444-8444-444444444444';
const _firstTag = '"0f1e2d3c4b5a69788796a5b4c3d2e1f0"';
const _secondTag = '"9f2c4b7a1e6d3058c4a1b2e7f0d93a65"';

final _identityJson = <String, Object?>{
  'master_pub': base64Encode(Uint8List(32)),
  'self_signing_pub': base64Encode(Uint8List(32)),
  'user_signing_pub': base64Encode(Uint8List(32)),
  'master_sig': base64Encode(Uint8List(64)),
  'version': 3,
  // The identity read's own tag, which is not the batched read's.
  'etag': '"identity-tag"',
};

final _deviceJson = <String, Object?>{
  'device_id': '55555555-5555-4555-8555-555555555555',
  'ik_pub': base64Encode(Uint8List(64)),
  'registration_id': 7,
  'cross_sig': base64Encode(Uint8List(64)),
  'bundle_version': 2,
};

/// A device between its registration and its cross-signature, as both device
/// routes serve it: the server stores 0 until the follow-up `PUT` names a
/// version, and lists the column verbatim.
final _unsignedDeviceJson = <String, Object?>{
  'device_id': '66666666-6666-4666-8666-666666666666',
  'ik_pub': base64Encode(Uint8List(64)),
  'registration_id': 8,
  'cross_sig': null,
  'bundle_version': 0,
};

Map<String, Object?> _full(String userId) => {
  'user_id': userId,
  'etag': _secondTag,
  'identity': _identityJson,
  'devices': [_deviceJson],
  'log_head_seq': 4,
};
