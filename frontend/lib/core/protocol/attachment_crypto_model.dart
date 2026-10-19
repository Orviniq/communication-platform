import 'dart:convert';
import 'dart:typed_data';

/// Wire limits shared by the Android Rust attachment adapter.
abstract final class AttachmentCryptoProtocolV1 {
  static const version = 1;
  static const chunkBytes = 64 * 1024;
  static const headerBytes = 66;
  static const secretstreamHeaderBytes = 24;
  static const keyBytes = 32;
  static const maximumMetadataBytes = 4096;
  static const buckets = <int>{
    65536,
    262144,
    1048576,
    4194304,
    16777216,
    67108864,
  };
}

final class AttachmentCryptoPushSession {
  AttachmentCryptoPushSession.handleOnly(this.handle)
    : key = Uint8List(32),
      header = Uint8List(66),
      secretstreamHeader = Uint8List(24),
      plaintextSize = 0,
      streamSize = 0,
      bucketSize = 0;

  AttachmentCryptoPushSession({
    required this.handle,
    required Uint8List key,
    required Uint8List header,
    required Uint8List secretstreamHeader,
    required this.plaintextSize,
    required this.streamSize,
    required this.bucketSize,
  }) : key = Uint8List.fromList(key),
       header = Uint8List.fromList(header),
       secretstreamHeader = Uint8List.fromList(secretstreamHeader);

  final int handle;
  final Uint8List key;
  final Uint8List header;
  final Uint8List secretstreamHeader;
  final int plaintextSize;
  final int streamSize;
  final int bucketSize;

  void wipe() {
    key.fillRange(0, key.length, 0);
    header.fillRange(0, header.length, 0);
    secretstreamHeader.fillRange(0, secretstreamHeader.length, 0);
  }

  @override
  String toString() => 'AttachmentCryptoPushSession(<redacted>)';
}

final class AttachmentCryptoPullSession {
  const AttachmentCryptoPullSession(this.handle);

  final int handle;
}

enum AttachmentMediaKind { image, file }

enum AttachmentTransferState {
  queued,
  encrypting,
  uploading,
  sending,
  downloading,
  verifying,
  ready,
  expired,
  cancelled,
  quotaExceeded,
  unsupported,
  corrupt,
  failed,
}

/// Encrypted message payload carried only inside an authenticated application
/// event. Capability and key fields are never sent through REST diagnostics.
final class EncryptedAttachmentDescriptor {
  EncryptedAttachmentDescriptor({
    required this.capabilityId,
    required Uint8List key,
    required Uint8List header,
    required Uint8List secretstreamHeader,
    required this.encryptedSize,
    required this.bucketSize,
    required this.plaintextSize,
    required String displayName,
    required String mimeType,
    required this.mediaKind,
    this.width,
    this.height,
    this.caption,
    Uint8List? thumbnail,
  }) : key = _copyExact(key, 32),
       header = _copyExact(header, 66),
       secretstreamHeader = _copyExact(secretstreamHeader, 24),
       displayName = _safeName(displayName),
       mimeType = _safeMime(mimeType),
       thumbnail = thumbnail == null ? null : Uint8List.fromList(thumbnail) {
    if (plaintextSize < 0) {
      throw const FormatException('invalid encrypted attachment descriptor');
    }
    final chunks = plaintextSize == 0
        ? 1
        : (plaintextSize + AttachmentCryptoProtocolV1.chunkBytes - 1) ~/
              AttachmentCryptoProtocolV1.chunkBytes;
    final expectedEncryptedSize = plaintextSize + chunks * 17;
    final requiredBytes =
        expectedEncryptedSize +
        AttachmentCryptoProtocolV1.headerBytes +
        AttachmentCryptoProtocolV1.secretstreamHeaderBytes;
    int? expectedBucket;
    for (final value in AttachmentCryptoProtocolV1.buckets) {
      if (value >= requiredBytes &&
          (expectedBucket == null || value < expectedBucket)) {
        expectedBucket = value;
      }
    }
    final headerData = ByteData.sublistView(this.header);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(capabilityId) ||
        !AttachmentCryptoProtocolV1.buckets.contains(bucketSize) ||
        expectedBucket == null ||
        encryptedSize != expectedEncryptedSize ||
        bucketSize != expectedBucket ||
        String.fromCharCodes(this.header.sublist(0, 8)) != 'CPAFV001' ||
        this.header[8] != AttachmentCryptoProtocolV1.version ||
        this.header[9] != 0 ||
        headerData.getUint32(10, Endian.big) !=
            AttachmentCryptoProtocolV1.chunkBytes ||
        headerData.getUint64(14, Endian.big) != plaintextSize ||
        headerData.getUint64(22, Endian.big) != encryptedSize ||
        headerData.getUint32(30, Endian.big) != bucketSize ||
        (width != null && (width! < 1 || width! > 8192)) ||
        (height != null && (height! < 1 || height! > 8192)) ||
        (this.thumbnail?.length ?? 0) > 65536 ||
        authenticatedMetadata().length >
            AttachmentCryptoProtocolV1.maximumMetadataBytes) {
      throw const FormatException('invalid encrypted attachment descriptor');
    }
  }

  final String capabilityId;
  final Uint8List key;
  final Uint8List header;
  final Uint8List secretstreamHeader;

  /// Real secretstream length before outer bucket padding.
  final int encryptedSize;
  final int bucketSize;
  final int plaintextSize;
  final String displayName;
  final String mimeType;
  final AttachmentMediaKind mediaKind;
  final int? width;
  final int? height;
  final String? caption;
  final Uint8List? thumbnail;

  @override
  String toString() => 'EncryptedAttachmentDescriptor(<redacted>)';

  bool get isInlineImage =>
      mediaKind == AttachmentMediaKind.image &&
      const {
        'image/jpeg',
        'image/png',
        'image/webp',
        'image/gif',
      }.contains(mimeType);

  EncryptedAttachmentDescriptor withCapability(String value) =>
      EncryptedAttachmentDescriptor(
        capabilityId: value,
        key: key,
        header: header,
        secretstreamHeader: secretstreamHeader,
        encryptedSize: encryptedSize,
        bucketSize: bucketSize,
        plaintextSize: plaintextSize,
        displayName: displayName,
        mimeType: mimeType,
        mediaKind: mediaKind,
        width: width,
        height: height,
        caption: caption,
        thumbnail: thumbnail,
      );

  Uint8List authenticatedMetadata() => Uint8List.fromList(
    utf8.encode(
      '$displayName\u0000$mimeType\u0000${width ?? 0}\u0000${height ?? 0}\u0000${mediaKind.index}\u0000${caption ?? ''}',
    ),
  );
}

Uint8List _copyExact(Uint8List value, int length) {
  if (value.length != length) {
    throw const FormatException('invalid field length');
  }
  return Uint8List.fromList(value);
}

String _safeName(String value) {
  final normalized = value.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '_');
  final basename = normalized.replaceAll('\\', '/').split('/').last.trim();
  if (basename.isEmpty || basename == '.' || basename == '..') {
    return 'attachment';
  }
  return basename.length > 128 ? basename.substring(0, 128) : basename;
}

String _safeMime(String value) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(
    r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$',
  ).hasMatch(normalized)) {
    return 'application/octet-stream';
  }
  const allowlist = {
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'audio/mpeg',
    'audio/ogg',
    'audio/wav',
    'text/plain',
    'application/pdf',
    'video/mp4',
    'video/webm',
    'video/3gpp',
    'video/quicktime',
  };
  return allowlist.contains(normalized)
      ? normalized
      : 'application/octet-stream';
}
