import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';

/// Own-account device-log fakes for the live-set checks of ADR-084.
///
/// The native core answers an inspection with `requireCurrentLiveSet` only by
/// comparing the hash of the canonical set it is handed with the one the
/// signed record carries. [HeadLiveSetCrypto] keeps the set the head record
/// covers in the clear instead, and answers the same question: is this
/// candidate, field for field and in any order, that set?
const ownUserId = '10000000-0000-4000-8000-000000000001';
const currentDeviceId = '10000000-0000-4000-8000-000000000002';
const otherDeviceId = '10000000-0000-4000-8000-000000000003';
const newcomerId = '10000000-0000-4000-8000-000000000004';
const secondNewcomerId = '10000000-0000-4000-8000-000000000005';
const thirdNewcomerId = '10000000-0000-4000-8000-000000000006';

/// This account's identity, as the core's package encoding carries it.
IdentityKeyPackage ownIdentityPackage() {
  final compact = ownUserId.replaceAll('-', '');
  final bytes = BytesBuilder(copy: false)
    ..add('CPIDV001'.codeUnits)
    ..addByte(0)
    ..add([
      for (var index = 0; index < compact.length; index += 2)
        int.parse(compact.substring(index, index + 2), radix: 16),
    ])
    ..add(Uint8List(32))
    ..add(Uint8List(32))
    ..add(Uint8List(32))
    ..add(Uint8List(64))
    ..add([0, 0])
    ..add([0, 0, 0, 0])
    ..add(Uint8List(96));
  return IdentityKeyPackage.fromNative(bytes.toBytes());
}

PublicDevice signedDevice(
  String deviceId, {
  required int key,
  int registrationId = 7,
  int version = 1,
}) => PublicDevice(
  deviceId: deviceId,
  ikPub: Uint8List(64)..fillRange(0, 64, key),
  registrationId: registrationId,
  crossSignature: Uint8List(64)..fillRange(0, 64, key + version),
  bundleVersion: version,
);

PublicDevice unsignedDevice(
  String deviceId, {
  required int key,
  int registrationId = 7,
}) => PublicDevice(
  deviceId: deviceId,
  ikPub: Uint8List(64)..fillRange(0, 64, key),
  registrationId: registrationId,
  crossSignature: null,
  bundleVersion: null,
);

final class HeadLiveSetCrypto implements IdentityCryptoPort {
  HeadLiveSetCrypto(List<PublicDevice> head)
    : _head = _canonical(head.map(_entryOfPublic));

  final List<String> _head;
  var inspections = 0;

  @override
  Future<Result<PeerDeviceLogInspection>> inspectPeerDeviceLog({
    required Uint8List userId,
    required Uint8List selfSigningPublic,
    required List<PeerPublicDevice> liveDevices,
    required bool requireCurrentLiveSet,
    required Uint8List record,
  }) async {
    inspections += 1;
    final candidate = _canonical(liveDevices.map(_entryOfPeer));
    if (!requireCurrentLiveSet ||
        candidate.length != _head.length ||
        Iterable<int>.generate(
          candidate.length,
        ).any((index) => candidate[index] != _head[index])) {
      return const Result.failure(
        CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
      );
    }
    return Result.success(
      PeerDeviceLogInspection(
        sequence: 0,
        previousHash: Uint8List(32),
        recordHash: Uint8List.fromList(List<int>.filled(32, 11)),
        liveDeviceSetHash: Uint8List(32),
        identityVersion: 1,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  static List<String> _canonical(Iterable<String> entries) =>
      entries.toList()..sort();

  // An unsigned device is canonically an empty signature at version 0.
  static String _entryOfPublic(PublicDevice device) => _entry(
    device.deviceId,
    device.ikPub,
    device.registrationId,
    device.crossSignature,
    device.bundleVersion,
  );

  static String _entryOfPeer(PeerPublicDevice device) => _entry(
    device.deviceId,
    device.identityPublic,
    device.registrationId,
    device.crossSignature,
    device.bundleVersion,
  );

  static String _entry(
    String deviceId,
    Uint8List identityPublic,
    int registrationId,
    Uint8List? crossSignature,
    int? bundleVersion,
  ) =>
      '$deviceId|${identityPublic.join(',')}|$registrationId|'
      '${crossSignature?.join(',') ?? ''}|${bundleVersion ?? 0}';
}
