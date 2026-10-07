import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';

/// How the device set the server lists for this account stands against the
/// head record of the account's own verified device log.
enum OwnLiveSetVerdict {
  /// The head record covers exactly the listed set.
  authenticated,

  /// The head record covers the listed set less changes to at most two
  /// devices that have not reached the log yet. The listed set is not
  /// authenticated, and it is not evidence of a fork either.
  pending,

  /// No reading of the listed set is the one the head record covers.
  mismatch,
}

/// Judges this account's listed device set against its head log record
/// (ADR-084).
///
/// A record commits to its live set only by a hash, so the set it covers can
/// be found only by rebuilding candidates from the list and asking the core
/// whether one is the set the signed record covers. A candidate keeps every
/// listed key byte as it is, and undoes only a change a device makes before
/// an append covers it:
///
/// - a device the record does not cover is dropped: it registered after the
///   record, unsigned or already cross-signed, or a signed removal names it
///   and its revocation has not landed yet;
/// - a signed device is put back unsigned, with the same identity key and
///   registration id: another device's append covered it before it
///   cross-signed itself.
///
/// At most two devices are undone, fewest first, so a list of n devices costs
/// at most 2n² + 1 inspections. A device that left the list with no record, a
/// changed identity key or registration id, a changed signature or version on
/// a device the record covers signed, and a third device in flight have no
/// candidate, and stay a mismatch.
final class OwnLiveSetJudge {
  const OwnLiveSetJudge(this.crypto);

  final IdentityCryptoPort crypto;

  Future<OwnLiveSetVerdict> judge({
    required Uint8List userId,
    required Uint8List selfSigningPublic,
    required List<PublicDevice> listed,
    required Uint8List headRecord,
  }) async {
    final List<PeerPublicDevice> devices;
    try {
      devices = listed.map(_peerDevice).toList(growable: false);
    } on IdentityProtocolFormatException {
      // Malformed device fields are unauthenticated server input.
      return OwnLiveSetVerdict.mismatch;
    }
    Future<bool> covers(List<PeerPublicDevice> candidate) async {
      final inspected = await crypto.inspectPeerDeviceLog(
        userId: userId,
        selfSigningPublic: selfSigningPublic,
        liveDevices: candidate,
        requireCurrentLiveSet: true,
        record: headRecord,
      );
      return inspected is Success<PeerDeviceLogInspection>;
    }

    if (await covers(devices)) {
      return OwnLiveSetVerdict.authenticated;
    }
    for (final candidate in _candidates(devices)) {
      if (await covers(candidate)) {
        return OwnLiveSetVerdict.pending;
      }
    }
    return OwnLiveSetVerdict.mismatch;
  }

  /// Every reading of [devices] with one device undone, then every reading
  /// with two.
  Iterable<List<PeerPublicDevice>> _candidates(
    List<PeerPublicDevice> devices,
  ) sync* {
    for (var first = 0; first < devices.length; first += 1) {
      for (final undone in _undo(devices[first])) {
        yield _with(devices, {first: undone});
      }
    }
    for (var first = 0; first < devices.length; first += 1) {
      for (var second = first + 1; second < devices.length; second += 1) {
        for (final firstUndone in _undo(devices[first])) {
          for (final secondUndone in _undo(devices[second])) {
            yield _with(devices, {first: firstUndone, second: secondUndone});
          }
        }
      }
    }
  }

  /// What [device] was before a change no append covers yet: not in the
  /// record at all (`null`) or, for a signed device, unsigned.
  List<PeerPublicDevice?> _undo(PeerPublicDevice device) => [
    null,
    if (!device.isUnsigned)
      PeerPublicDevice(
        deviceId: device.deviceId,
        identityPublic: device.identityPublic,
        registrationId: device.registrationId,
        bundleVersion: null,
      ),
  ];

  List<PeerPublicDevice> _with(
    List<PeerPublicDevice> devices,
    Map<int, PeerPublicDevice?> undone,
  ) => [
    for (var index = 0; index < devices.length; index += 1)
      if (!undone.containsKey(index)) devices[index] else ?undone[index],
  ];

  PeerPublicDevice _peerDevice(PublicDevice device) => PeerPublicDevice(
    deviceId: device.deviceId,
    identityPublic: device.ikPub,
    registrationId: device.registrationId,
    bundleVersion: device.bundleVersion,
    crossSignature: device.crossSignature,
  );
}
