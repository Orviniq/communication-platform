import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';

/// A 43-character capability, distinct for each [seed] below 62.
String testCapability(int seed) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  return alphabet[seed % alphabet.length] * 43;
}

/// A descriptor every check of [EncryptedAttachmentDescriptor] accepts, for a
/// file of [plaintextSize] bytes in the smallest bucket that holds it.
EncryptedAttachmentDescriptor testAttachmentDescriptor({
  String? capability,
  String displayName = 'file.txt',
  String mimeType = 'text/plain',
  int plaintextSize = 10,
  AttachmentMediaKind mediaKind = AttachmentMediaKind.file,
}) {
  final streamSize = encryptedStreamSize(plaintextSize, 65536);
  final bucket = attachmentBucketFor(plaintextSize);
  final header = Uint8List(66)..setAll(0, ascii.encode('CPAFV001'));
  header[8] = 1;
  ByteData.sublistView(header)
    ..setUint32(10, 65536, Endian.big)
    ..setUint64(14, plaintextSize, Endian.big)
    ..setUint64(22, streamSize, Endian.big)
    ..setUint32(30, bucket, Endian.big);
  return EncryptedAttachmentDescriptor(
    capabilityId: capability ?? testCapability(0),
    key: Uint8List(32),
    header: header,
    secretstreamHeader: Uint8List(24),
    encryptedSize: streamSize,
    bucketSize: bucket,
    plaintextSize: plaintextSize,
    displayName: displayName,
    mimeType: mimeType,
    mediaKind: mediaKind,
  );
}
