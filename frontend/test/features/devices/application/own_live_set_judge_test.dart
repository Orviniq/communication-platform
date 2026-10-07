import 'dart:typed_data';

import 'package:communication_platform/features/devices/application/own_live_set_judge.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/own_live_set_fakes.dart';

void main() {
  final current = signedDevice(currentDeviceId, key: 1);
  final other = signedDevice(otherDeviceId, key: 2);

  Future<(OwnLiveSetVerdict, int)> judge({
    required List<PublicDevice> head,
    required List<PublicDevice> listed,
  }) async {
    final crypto = HeadLiveSetCrypto(head);
    final verdict = await OwnLiveSetJudge(crypto).judge(
      userId: Uint8List(16),
      selfSigningPublic: Uint8List(32),
      listed: listed,
      headRecord: Uint8List(256),
    );
    return (verdict, crypto.inspections);
  }

  test('the set the head covers is authenticated in one inspection', () async {
    final (verdict, inspections) = await judge(
      head: [current, other],
      listed: [other, current],
    );

    expect(verdict, OwnLiveSetVerdict.authenticated);
    expect(inspections, 1);
  });

  group('pending', () {
    test('a device registered since the head, still unsigned', () async {
      final (verdict, _) = await judge(
        head: [current, other],
        listed: [current, other, unsignedDevice(newcomerId, key: 3)],
      );

      expect(verdict, OwnLiveSetVerdict.pending);
    });

    test('a device registered since the head, signed but not logged', () async {
      final (verdict, _) = await judge(
        head: [current, other],
        listed: [current, other, signedDevice(newcomerId, key: 3)],
      );

      expect(verdict, OwnLiveSetVerdict.pending);
    });

    test(
      'a device the head covers unsigned, cross-signed since and not logged',
      () async {
        final (verdict, _) = await judge(
          head: [current, other, unsignedDevice(newcomerId, key: 3)],
          listed: [current, other, signedDevice(newcomerId, key: 3)],
        );

        expect(verdict, OwnLiveSetVerdict.pending);
      },
    );

    test(
      'a device a signed removal left out, whose revocation has not landed',
      () async {
        final (verdict, _) = await judge(
          head: [current],
          listed: [current, other],
        );

        expect(verdict, OwnLiveSetVerdict.pending);
      },
    );

    test('two devices in flight at once', () async {
      final (verdict, _) = await judge(
        head: [current, other, unsignedDevice(secondNewcomerId, key: 4)],
        listed: [
          current,
          other,
          unsignedDevice(newcomerId, key: 3),
          signedDevice(secondNewcomerId, key: 4),
        ],
      );

      expect(verdict, OwnLiveSetVerdict.pending);
    });
  });

  group('mismatch', () {
    test('a third device in flight', () async {
      final (verdict, _) = await judge(
        head: [current, other],
        listed: [
          current,
          other,
          unsignedDevice(newcomerId, key: 3),
          signedDevice(secondNewcomerId, key: 4),
          unsignedDevice(thirdNewcomerId, key: 5),
        ],
      );

      expect(verdict, OwnLiveSetVerdict.mismatch);
    });

    test('a logged device gone from the list with no record', () async {
      final (verdict, _) = await judge(
        head: [current, other],
        listed: [current],
      );

      expect(verdict, OwnLiveSetVerdict.mismatch);
    });

    test('a logged device gone while another is in flight', () async {
      final (verdict, _) = await judge(
        head: [current, other],
        listed: [current, unsignedDevice(newcomerId, key: 3)],
      );

      expect(verdict, OwnLiveSetVerdict.mismatch);
    });

    test('a changed identity key', () async {
      final (verdict, _) = await judge(
        head: [current, other],
        listed: [current, signedDevice(otherDeviceId, key: 9)],
      );

      expect(verdict, OwnLiveSetVerdict.mismatch);
    });

    test('a changed registration id', () async {
      final (verdict, _) = await judge(
        head: [current, other],
        listed: [
          current,
          signedDevice(otherDeviceId, key: 2, registrationId: 8),
        ],
      );

      expect(verdict, OwnLiveSetVerdict.mismatch);
    });

    test(
      'a changed identity key on a device the head covers unsigned',
      () async {
        final (verdict, _) = await judge(
          head: [current, unsignedDevice(newcomerId, key: 3)],
          listed: [current, signedDevice(newcomerId, key: 9)],
        );

        expect(verdict, OwnLiveSetVerdict.mismatch);
      },
    );

    test(
      'a new signature and version on a device the head covers signed',
      () async {
        // The prekey-rotation gap: left open by ADR-084, so still a mismatch.
        final (verdict, _) = await judge(
          head: [current, other],
          listed: [current, signedDevice(otherDeviceId, key: 2, version: 2)],
        );

        expect(verdict, OwnLiveSetVerdict.mismatch);
      },
    );

    test('a device with half a signature pair', () async {
      final (verdict, inspections) = await judge(
        head: [current, other],
        listed: [
          current,
          PublicDevice(
            deviceId: otherDeviceId,
            ikPub: Uint8List(64)..fillRange(0, 64, 2),
            registrationId: 7,
            crossSignature: Uint8List(64),
            bundleVersion: null,
          ),
        ],
      );

      expect(verdict, OwnLiveSetVerdict.mismatch);
      expect(inspections, 0);
    });
  });

  test('a mismatch over the largest own list costs at most 2n² + 1', () async {
    final listed = [
      for (var index = 0; index < 10; index += 1)
        signedDevice(
          '10000000-0000-4000-8000-0000000001${index.toString().padLeft(2, '0')}',
          key: 20 + index,
        ),
    ];
    final (verdict, inspections) = await judge(
      head: [signedDevice(currentDeviceId, key: 1)],
      listed: listed,
    );

    expect(verdict, OwnLiveSetVerdict.mismatch);
    expect(inspections, 2 * 10 * 10 + 1);
  });
}
