import 'dart:math';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';

typedef AttachmentDescriptor = EncryptedAttachmentDescriptor;

final class AttachmentHeaderV1 {
  const AttachmentHeaderV1({
    required this.chunkSize,
    required this.plaintextSize,
    required this.streamSize,
    required this.bucketSize,
    required this.metadataHash,
  });

  factory AttachmentHeaderV1.parse(Uint8List bytes) {
    if (bytes.length != 66 ||
        String.fromCharCodes(bytes.sublist(0, 8)) != 'CPAFV001' ||
        bytes[8] != 1 ||
        bytes[9] != 0) {
      throw const FormatException('invalid attachment header');
    }
    final data = ByteData.sublistView(bytes);
    final chunkSize = data.getUint32(10, Endian.big);
    final plaintextSize = data.getUint64(14, Endian.big);
    final streamSize = data.getUint64(22, Endian.big);
    final bucketSize = data.getUint32(30, Endian.big);
    if (chunkSize != AttachmentCryptoProtocolV1.chunkBytes ||
        !AttachmentCryptoProtocolV1.buckets.contains(bucketSize) ||
        encryptedStreamSize(plaintextSize, chunkSize) != streamSize ||
        streamSize + 66 + 24 > bucketSize) {
      throw const FormatException('invalid attachment header bounds');
    }
    return AttachmentHeaderV1(
      chunkSize: chunkSize,
      plaintextSize: plaintextSize,
      streamSize: streamSize,
      bucketSize: bucketSize,
      metadataHash: Uint8List.fromList(bytes.sublist(34, 66)),
    );
  }

  final int chunkSize;
  final int plaintextSize;
  final int streamSize;
  final int bucketSize;
  final Uint8List metadataHash;
}

int encryptedStreamSize(int plaintextSize, int chunkSize) {
  if (plaintextSize < 0 || chunkSize <= 0) {
    throw const FormatException('invalid attachment size');
  }
  final chunks = plaintextSize == 0
      ? 1
      : (plaintextSize + chunkSize - 1) ~/ chunkSize;
  return plaintextSize + chunks * 17;
}

int attachmentBucketFor(int plaintextSize) {
  final streamSize = encryptedStreamSize(
    plaintextSize,
    AttachmentCryptoProtocolV1.chunkBytes,
  );
  final required = streamSize + AttachmentCryptoProtocolV1.headerBytes + 24;
  for (final bucket in AttachmentCryptoProtocolV1.buckets.toList()..sort()) {
    if (required <= bucket) return bucket;
  }
  throw const FormatException('attachment exceeds largest bucket');
}

/// The largest plaintext length that [attachmentBucketFor] fits into
/// [bucketSize], on the same formula: the byte limit of a pick (ADR-089 D3).
///
/// The caller passes the largest bucket that both the deployment publishes
/// (`ServerConfig.largestAttachmentBucket`) and
/// [AttachmentCryptoProtocolV1.buckets] hold.
int attachmentPlaintextLimit(int bucketSize) {
  if (!AttachmentCryptoProtocolV1.buckets.contains(bucketSize)) {
    throw ArgumentError.value(bucketSize, 'bucketSize', 'not a bucket');
  }
  const chunkBytes = AttachmentCryptoProtocolV1.chunkBytes;
  // The secretstream overhead of each chunk, as [encryptedStreamSize] adds.
  const chunkOverhead = 17;
  final streamBudget = bucketSize - AttachmentCryptoProtocolV1.headerBytes - 24;
  // The most chunks a plaintext can fill and still fit, then the most bytes
  // that many chunks carry within the budget.
  final chunks =
      (streamBudget + chunkBytes - 1) ~/ (chunkBytes + chunkOverhead);
  return min(chunks * chunkBytes, streamBudget - chunks * chunkOverhead);
}

String safeAttachmentName(String value) {
  final normalized = value.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '_');
  final basename = normalized.replaceAll('\\', '/').split('/').last;
  final trimmed = basename.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
    return 'attachment';
  }
  return trimmed.length > 128 ? trimmed.substring(0, 128) : trimmed;
}

String safeMimeType(String value) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(
    r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$',
  ).hasMatch(normalized)) {
    return 'application/octet-stream';
  }
  const safeInline = {
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'audio/mpeg',
    'audio/ogg',
    'audio/wav',
    'text/plain',
    'application/pdf',
  };
  return safeInline.contains(normalized)
      ? normalized
      : 'application/octet-stream';
}
