import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:communication_platform/features/devices/infrastructure/linked_device_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('piece 17 own-device ETag contract', () {
    test('decodes exact encrypted-label buckets and response ETag', () {
      final result = OwnDeviceListResponseDto.fromResponse(
        {
          'devices': [
            {
              'device_id': deviceId,
              'label_blob': base64Encode(Uint8List(256)),
              'created_date': '2026-08-01',
              'this_device': true,
            },
          ],
          'log_head_seq': 4,
        },
        const {
          'etag': ['"devices-v4"'],
        },
      ).refresh;

      expect(result, isA<OwnDevicesUpdated>());
      final updated = result as OwnDevicesUpdated;
      expect(updated.etag, '"devices-v4"');
      expect(updated.logHeadSequence, 4);
      expect(updated.devices.single.encryptedLabel, hasLength(256));
      expect(
        updated.devices.single.labelState,
        LinkedDeviceLabelState.unreadable,
      );
    });

    test('304 is a not-modified signal and carries no authorization', () {
      expect(
        OwnDeviceListResponseDto.fromResponse(null, const {}).refresh,
        isA<OwnDevicesNotModified>(),
      );
    });

    test('rejects missing ETag, duplicate current device, and bad labels', () {
      final validDevice = {
        'device_id': deviceId,
        'label_blob': null,
        'created_date': '2026-08-01',
        'this_device': true,
      };
      expect(
        () => OwnDeviceListResponseDto.fromResponse({
          'devices': [validDevice],
          'log_head_seq': 0,
        }, const {}),
        throwsA(isA<MalformedApiBody>()),
      );
      expect(
        () => OwnDeviceListResponseDto.fromResponse(
          {
            'devices': [validDevice, validDevice],
            'log_head_seq': 0,
          },
          const {
            'etag': ['"devices"'],
          },
        ),
        throwsA(isA<MalformedApiBody>()),
      );
      expect(
        () => OwnDeviceListResponseDto.fromResponse(
          {
            'devices': [
              {...validDevice, 'label_blob': base64Encode(Uint8List(255))},
            ],
            'log_head_seq': 0,
          },
          const {
            'etag': ['"devices"'],
          },
        ),
        throwsA(isA<MalformedApiBody>()),
      );
    });
  });
}

const deviceId = '00000000-0000-0000-0000-000000000017';
