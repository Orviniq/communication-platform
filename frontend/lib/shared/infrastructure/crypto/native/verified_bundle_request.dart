import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/identity_protocol_model.dart';

/// Canonical native Authentication-Service input for pairwise sessions.
Uint8List encodeVerifiedClaimedBundleRequest({
  required Uint8List userId,
  required Uint8List deviceId,
  required Uint8List selfSigningPublic,
  required ClaimedPrekeyBundle bundle,
}) {
  final pqId = bundle.pqSignedPrekeyId;
  final pqPublic = bundle.pqSignedPrekeyPublic;
  final pqSignature = bundle.pqSignedPrekeySignature;
  if (userId.length != 16 ||
      deviceId.length != 16 ||
      selfSigningPublic.length != 32 ||
      bundle.bundleVersion <= 0 ||
      !_validKeyId(bundle.signedPrekeyId) ||
      bundle.signedPrekeyPublic.length != 32 ||
      pqId == null ||
      !_validKeyId(pqId) ||
      pqPublic == null ||
      pqPublic.length != 1184 ||
      pqSignature == null) {
    throw const VerifiedBundleRequestFormatException();
  }
  return (_Writer()
        ..bytes(ascii.encode('CPBRV001'))
        ..bytes(userId)
        ..bytes(deviceId)
        ..bytes(selfSigningPublic)
        ..bytes(bundle.identityPublic)
        ..u32(bundle.signedPrekeyId)
        ..frame(bundle.signedPrekeyPublic)
        ..bytes(bundle.signedPrekeySignature)
        ..boolean(true)
        ..u32(pqId)
        ..frame(pqPublic)
        ..bytes(pqSignature)
        ..u32(bundle.registrationId)
        ..u32(bundle.bundleVersion)
        ..bytes(bundle.crossSignature))
      .takeBytes();
}

Uint8List uuidProtocolBytes(String value) {
  final compact = value.replaceAll('-', '');
  if (compact.length != 32 || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(compact)) {
    throw const VerifiedBundleRequestFormatException();
  }
  return Uint8List.fromList([
    for (var index = 0; index < compact.length; index += 2)
      int.parse(compact.substring(index, index + 2), radix: 16),
  ]);
}

final class VerifiedBundleRequestFormatException implements Exception {
  const VerifiedBundleRequestFormatException();
}

bool _validKeyId(int value) => value >= 0 && value <= 0x7fffffff;

final class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void bytes(List<int> value) => _builder.add(value);

  void boolean(bool value) => _builder.addByte(value ? 1 : 0);

  void u32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw const VerifiedBundleRequestFormatException();
    }
    final bytes = ByteData(4)..setUint32(0, value);
    _builder.add(bytes.buffer.asUint8List());
  }

  void frame(List<int> value) {
    u32(value.length);
    bytes(value);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}
