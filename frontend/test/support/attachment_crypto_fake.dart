import 'dart:convert';

import 'package:communication_platform/core/application/ports/attachment_crypto_port.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:flutter/foundation.dart';

/// A version-1 attachment header for a plaintext of [plaintextSize] bytes in
/// [bucketSize], or the smallest bucket that holds it.
Uint8List fakeAttachmentHeader({
  required int plaintextSize,
  int? bucketSize,
  int metadataHashByte = 0,
}) {
  final streamSize = encryptedStreamSize(plaintextSize, 65536);
  final bucket = bucketSize ?? attachmentBucketFor(plaintextSize);
  final bytes = Uint8List(66);
  bytes.setAll(0, ascii.encode('CPAFV001'));
  bytes[8] = 1;
  final data = ByteData.sublistView(bytes);
  data.setUint32(10, 65536, Endian.big);
  data.setUint64(14, plaintextSize, Endian.big);
  data.setUint64(22, streamSize, Endian.big);
  data.setUint32(30, bucket, Endian.big);
  bytes.fillRange(34, 66, metadataHashByte);
  return bytes;
}

/// An [AttachmentCryptoPort] with no cryptography in it, for the host tests
/// the Rust core is not in.
///
/// A chunk is its plaintext, a sequence byte, fifteen checksum bytes and a
/// final flag, so a pull notices a chunk that was changed, reordered or cut,
/// and a pull refuses metadata other than the push's. [beforePush], when set,
/// is awaited before each chunk is pushed: a test holds it to catch the
/// pipeline in the middle of encrypting.
final class FakeAttachmentCryptoPort implements AttachmentCryptoPort {
  FakeAttachmentCryptoPort({this.beforePush});

  Future<void> Function()? beforePush;

  Uint8List _metadata = Uint8List(0);
  int _pushSequence = 0;
  int _pullSequence = 0;
  int maximumPushBytes = 0;
  int maximumPullBytes = 0;
  int pushCalls = 0;
  bool lastPullWasFinal = false;

  /// The metadata of the last push.
  Uint8List get lastMetadata => Uint8List.fromList(_metadata);

  @override
  Future<Result<AttachmentCryptoPushSession>> createPush({
    required int plaintextSize,
    required int bucketSize,
    required Uint8List metadata,
  }) async {
    _metadata = Uint8List.fromList(metadata);
    _pushSequence = 0;
    final streamSize = encryptedStreamSize(plaintextSize, 65536);
    return Result.success(
      AttachmentCryptoPushSession(
        handle: 1,
        key: Uint8List(32),
        header: fakeAttachmentHeader(
          plaintextSize: plaintextSize,
          bucketSize: bucketSize,
        ),
        secretstreamHeader: Uint8List(24),
        plaintextSize: plaintextSize,
        streamSize: streamSize,
        bucketSize: bucketSize,
      ),
    );
  }

  @override
  Future<Result<Uint8List>> pushChunk({
    required AttachmentCryptoPushSession session,
    required Uint8List plaintext,
    required bool finalChunk,
  }) async {
    await beforePush?.call();
    maximumPushBytes = maximumPushBytes < plaintext.length
        ? plaintext.length
        : maximumPushBytes;
    pushCalls += 1;
    final output = Uint8List(plaintext.length + 17)
      ..setRange(0, plaintext.length, plaintext)
      ..[plaintext.length] = _pushSequence & 0xff
      ..fillRange(
        plaintext.length + 1,
        plaintext.length + 16,
        _checksum(plaintext),
      )
      ..[plaintext.length + 16] = finalChunk ? 1 : 0;
    _pushSequence += 1;
    return Result.success(output);
  }

  @override
  Future<Result<AttachmentCryptoPullSession>> createPull({
    required Uint8List key,
    required Uint8List header,
    required Uint8List secretstreamHeader,
    required Uint8List metadata,
  }) async {
    if (!listEquals(metadata, _metadata)) {
      return const Result.failure(
        CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
      );
    }
    _pullSequence = 0;
    lastPullWasFinal = false;
    return const Result.success(AttachmentCryptoPullSession(2));
  }

  @override
  Future<Result<AttachmentDecryptedChunk>> pullChunk({
    required AttachmentCryptoPullSession session,
    required Uint8List ciphertext,
  }) async {
    maximumPullBytes = maximumPullBytes < ciphertext.length
        ? ciphertext.length
        : maximumPullBytes;
    if (ciphertext.length < 17) {
      return const Result.failure(
        CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
      );
    }
    final plaintextLength = ciphertext.length - 17;
    final plaintext = ciphertext.sublist(0, plaintextLength);
    if (ciphertext[plaintextLength] != (_pullSequence & 0xff)) {
      return const Result.failure(
        CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
      );
    }
    final checksum = _checksum(plaintext);
    for (
      var index = plaintextLength + 1;
      index < plaintextLength + 16;
      index += 1
    ) {
      if (ciphertext[index] != checksum) {
        return const Result.failure(
          CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
        );
      }
    }
    final finalChunk = ciphertext.last == 1;
    lastPullWasFinal = finalChunk;
    _pullSequence += 1;
    return Result.success(
      AttachmentDecryptedChunk(plaintext: plaintext, finalChunk: finalChunk),
    );
  }

  @override
  Future<Result<void>> closeSession({
    required int handle,
    bool abort = false,
  }) async => const Result.success(null);

  @override
  Future<Result<Uint8List>> randomBytes(int length) async =>
      Result.success(Uint8List(length));
}

int _checksum(List<int> bytes) {
  var value = 0;
  for (final byte in bytes) {
    value = (value + byte) & 0xff;
  }
  return value;
}
