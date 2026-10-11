import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/application/ports/attachment_crypto_port.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';

final class AttachmentSource {
  const AttachmentSource({
    required this.length,
    required this.displayName,
    required this.mimeType,
    required this.openRead,
    this.mediaKind = AttachmentMediaKind.file,
    this.width,
    this.height,
  });

  final int length;
  final String displayName;
  final String mimeType;
  final Stream<List<int>> Function() openRead;
  final AttachmentMediaKind mediaKind;
  final int? width;
  final int? height;
}

final class AttachmentProgress {
  const AttachmentProgress({
    required this.state,
    required this.completedBytes,
    required this.totalBytes,
  });

  final AttachmentTransferState state;
  final int completedBytes;
  final int totalBytes;

  double get fraction =>
      totalBytes <= 0 ? 0 : (completedBytes / totalBytes).clamp(0, 1);
}

/// Creates and verifies encrypted attachment files without retaining the
/// complete plaintext/ciphertext in memory.
final class AttachmentCryptoService {
  const AttachmentCryptoService(this.crypto);

  final AttachmentCryptoPort crypto;

  Future<Result<AttachmentDescriptor>> encryptToFile({
    required AttachmentSource source,
    required File destination,
    String? caption,
    CancellationSignal? cancellation,
    void Function(AttachmentProgress progress)? onProgress,
  }) async {
    if (source.length < 0) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final name = safeAttachmentName(source.displayName);
    final mime = safeMimeType(source.mimeType);
    final bucket = _safeBucket(source.length);
    if (bucket == null) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    final metadata = Uint8List.fromList(
      utf8.encode(
        '$name\u0000$mime\u0000${source.width ?? 0}\u0000${source.height ?? 0}\u0000${source.mediaKind.index}\u0000${caption ?? ''}',
      ),
    );
    final sessionResult = await crypto.createPush(
      plaintextSize: source.length,
      bucketSize: bucket,
      metadata: metadata,
    );
    if (sessionResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    if (sessionResult is! Success<AttachmentCryptoPushSession>) {
      return Result.failure(
        (sessionResult as FailureResult<AttachmentCryptoPushSession>).failure,
      );
    }
    final session = sessionResult.value;
    IOSink? sink;
    var completed = 0;
    var succeeded = false;
    try {
      if (cancellation?.isCancelled ?? false) {
        return const Result.failure(
          CancellationFailure(CancellationFailureKind.requestedByUser),
        );
      }
      await destination.parent.create(recursive: true);
      sink = destination.openWrite();
      sink
        ..add(session.header)
        ..add(session.secretstreamHeader);
      onProgress?.call(
        AttachmentProgress(
          state: AttachmentTransferState.encrypting,
          completedBytes: 0,
          totalBytes: source.length,
        ),
      );
      final pending = BytesBuilder(copy: false);
      await for (final input in source.openRead()) {
        if (cancellation?.isCancelled ?? false) {
          return const Result.failure(
            CancellationFailure(CancellationFailureKind.requestedByUser),
          );
        }
        var offset = 0;
        while (offset < input.length) {
          final remaining =
              AttachmentCryptoPortChunkLimit.value - pending.length;
          final take = math.min(input.length - offset, remaining);
          pending.add(input.sublist(offset, offset + take));
          offset += take;
          if (pending.length == AttachmentCryptoPortChunkLimit.value) {
            final chunk = pending.takeBytes();
            final finalChunk = completed + chunk.length == source.length;
            final encrypted = await crypto.pushChunk(
              session: session,
              plaintext: chunk,
              finalChunk: finalChunk,
            );
            if (encrypted case FailureResult(failure: final failure)) {
              return Result.failure(failure);
            }
            sink.add((encrypted as Success<Uint8List>).value);
            completed += chunk.length;
            onProgress?.call(
              AttachmentProgress(
                state: AttachmentTransferState.encrypting,
                completedBytes: completed,
                totalBytes: source.length,
              ),
            );
          }
        }
      }
      if (completed != source.length ||
          pending.length > 0 ||
          source.length == 0) {
        final chunk = pending.takeBytes();
        final finalChunk = true;
        final encrypted = await crypto.pushChunk(
          session: session,
          plaintext: chunk,
          finalChunk: finalChunk,
        );
        if (encrypted case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        sink.add((encrypted as Success<Uint8List>).value);
        completed += chunk.length;
      }
      if (completed != source.length) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.integrityCheckFailed),
        );
      }
      final writtenStream = encryptedStreamSize(
        source.length,
        AttachmentCryptoPortChunkLimit.value,
      );
      final padding = bucket - 66 - 24 - writtenStream;
      if (padding < 0) {
        return const Result.failure(
          ValidationFailure(ValidationFailureKind.limitExceeded),
        );
      }
      var left = padding;
      while (left > 0) {
        final take = math.min(left, AttachmentCryptoPortChunkLimit.value);
        final random = await crypto.randomBytes(take);
        if (random case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        sink.add((random as Success<Uint8List>).value);
        left -= take;
      }
      await sink.flush();
      await crypto.closeSession(handle: session.handle);
      succeeded = true;
      return Result.success(
        AttachmentDescriptor(
          capabilityId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          key: session.key,
          header: session.header,
          secretstreamHeader: session.secretstreamHeader,
          encryptedSize: writtenStream,
          bucketSize: bucket,
          plaintextSize: source.length,
          displayName: name,
          mimeType: mime,
          mediaKind: source.mediaKind,
          width: source.width,
          height: source.height,
          caption: caption,
        ),
      );
    } finally {
      await sink?.close();
      if (!succeeded) {
        destination.deleteIfExists();
      }
      if (session.handle != 0) {
        // Abort is idempotent only while the native handle exists; a completed
        // close returns invalid-handle and is intentionally ignored here.
        await crypto.closeSession(handle: session.handle, abort: true);
      }
      session.wipe();
    }
  }

  Future<Result<void>> decryptStreamToFile({
    required AttachmentDescriptor descriptor,
    required Stream<List<int>> ciphertext,
    required File destination,
    CancellationSignal? cancellation,
    void Function(AttachmentProgress progress)? onProgress,
  }) async {
    if (!AttachmentCryptoProtocolV1Buckets.isBucket(descriptor.bucketSize) ||
        descriptor.plaintextSize < 0) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final reader = _AttachmentStreamReader(ciphertext);
    AttachmentCryptoPullSession? session;
    IOSink? sink;
    var verified = false;
    try {
      final headerBytes = await reader.take(66);
      final streamHeader = await reader.take(24);
      final header = AttachmentHeaderV1.parse(headerBytes);
      if (header.bucketSize != descriptor.bucketSize ||
          header.plaintextSize != descriptor.plaintextSize ||
          header.streamSize != descriptor.encryptedSize ||
          header.streamSize + 66 + 24 > descriptor.bucketSize) {
        throw const FormatException();
      }
      final pullResult = await crypto.createPull(
        key: descriptor.key,
        header: headerBytes,
        secretstreamHeader: streamHeader,
        metadata: descriptor.authenticatedMetadata(),
      );
      if (pullResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      if (pullResult is! Success<AttachmentCryptoPullSession>) {
        return Result.failure(
          (pullResult as FailureResult<AttachmentCryptoPullSession>).failure,
        );
      }
      session = pullResult.value;
      await destination.parent.create(recursive: true);
      sink = destination.openWrite();
      var plainSeen = 0;
      var streamSeen = 0;
      final chunkCount = descriptor.plaintextSize == 0
          ? 1
          : (descriptor.plaintextSize + 65535) ~/ 65536;
      for (var index = 0; index < chunkCount; index += 1) {
        if (cancellation?.isCancelled ?? false) {
          return const Result.failure(
            CancellationFailure(CancellationFailureKind.requestedByUser),
          );
        }
        final plainChunk = descriptor.plaintextSize == 0
            ? 0
            : math.min(descriptor.plaintextSize - plainSeen, 65536);
        final encryptedChunk = await reader.take(plainChunk + 17);
        streamSeen += encryptedChunk.length;
        final decrypted = await crypto.pullChunk(
          session: session,
          ciphertext: encryptedChunk,
        );
        if (decrypted case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        final value = (decrypted as Success<AttachmentDecryptedChunk>).value;
        if (value.finalChunk != (index + 1 == chunkCount) ||
            value.plaintext.length != plainChunk) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.integrityCheckFailed),
          );
        }
        sink.add(value.plaintext);
        plainSeen += value.plaintext.length;
        onProgress?.call(
          AttachmentProgress(
            state: AttachmentTransferState.verifying,
            completedBytes: plainSeen,
            totalBytes: descriptor.plaintextSize,
          ),
        );
      }
      final remainingPadding = descriptor.bucketSize - 66 - 24 - streamSeen;
      if (remainingPadding < 0) throw const FormatException();
      await reader.discard(remainingPadding);
      if (await reader.hasMore) throw const FormatException();
      await sink.flush();
      await crypto.closeSession(handle: session.handle);
      session = null;
      verified = true;
      return const Result<void>.success(null);
    } on _AttachmentCorrupt {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    } finally {
      // A failure stops reading part-way, and the source stays open until its
      // subscription is cancelled: a file that cannot be deleted on some
      // platforms, and a handle that outlives the call on every one.
      await reader.cancel();
      await sink?.close();
      if (session != null) {
        await crypto.closeSession(handle: session.handle, abort: true);
      }
      if (!verified && !File(destination.path).deleteIfExists()) {
        // Best effort cleanup; the file remains private and is never presented
        // after an authentication failure.
      }
    }
  }

  int? _safeBucket(int size) {
    try {
      return attachmentBucketFor(size);
    } on FormatException {
      return null;
    }
  }
}

abstract final class AttachmentCryptoPortChunkLimit {
  static const value = 64 * 1024;
}

abstract final class AttachmentCryptoProtocolV1Buckets {
  static bool isBucket(int value) => const {
    65536,
    262144,
    1048576,
    4194304,
    16777216,
    67108864,
  }.contains(value);
}

final class _AttachmentCorrupt implements Exception {
  const _AttachmentCorrupt();
}

final class _AttachmentStreamReader {
  _AttachmentStreamReader(Stream<List<int>> stream)
    : _iterator = StreamIterator(stream);

  final StreamIterator<List<int>> _iterator;
  List<int>? _current;
  int _offset = 0;
  bool _done = false;

  Future<Uint8List> take(int length) async {
    if (length < 0) throw const _AttachmentCorrupt();
    final output = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (!await _ensureCurrent()) {
        throw const _AttachmentCorrupt();
      }
      final current = _current!;
      final available = current.length - _offset;
      final count = math.min(length - written, available);
      output.setRange(written, written + count, current, _offset);
      written += count;
      _offset += count;
      if (_offset == current.length) {
        _current = null;
        _offset = 0;
      }
    }
    return output;
  }

  Future<void> discard(int length) async {
    var left = length;
    while (left > 0) {
      final takeLength = math.min(left, 64 * 1024);
      await take(takeLength);
      left -= takeLength;
    }
  }

  Future<bool> get hasMore => _ensureCurrent();

  /// Stops reading the source, wherever the reader is in it.
  Future<void> cancel() async {
    _done = true;
    _current = null;
    await _iterator.cancel();
  }

  Future<bool> _ensureCurrent() async {
    while ((_current == null || _offset == _current!.length) && !_done) {
      if (!await _iterator.moveNext()) {
        _done = true;
        _current = null;
        return false;
      }
      final next = _iterator.current;
      if (next.isEmpty) {
        continue;
      }
      _current = next;
      _offset = 0;
    }
    return _current != null && _offset < _current!.length;
  }
}

extension on File {
  bool deleteIfExists() {
    if (!existsSync()) return true;
    try {
      deleteSync();
      return true;
    } on Object {
      return false;
    }
  }
}
