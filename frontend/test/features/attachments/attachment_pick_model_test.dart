import 'dart:io';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/attachment_platform_fake.dart';

void main() {
  group('the plaintext limit of a bucket', () {
    final buckets = AttachmentCryptoProtocolV1.buckets.toList()..sort();

    test('is the largest plaintext attachmentBucketFor puts in it', () {
      for (final bucket in buckets) {
        final limit = attachmentPlaintextLimit(bucket);
        expect(attachmentBucketFor(limit), bucket, reason: '$bucket');
        expect(
          encryptedStreamSize(limit, AttachmentCryptoProtocolV1.chunkBytes) +
              AttachmentCryptoProtocolV1.headerBytes +
              AttachmentCryptoProtocolV1.secretstreamHeaderBytes,
          lessThanOrEqualTo(bucket),
          reason: '$bucket',
        );
      }
    });

    test('one byte more needs the next bucket, or none', () {
      for (final bucket in buckets) {
        final above = attachmentPlaintextLimit(bucket) + 1;
        if (bucket == buckets.last) {
          expect(() => attachmentBucketFor(above), throwsFormatException);
        } else {
          expect(
            attachmentBucketFor(above),
            buckets[buckets.indexOf(bucket) + 1],
            reason: '$bucket',
          );
        }
      }
    });

    test('fills the bucket exactly at each size', () {
      // Worked by hand from the header (66 bytes), the secretstream header
      // (24) and 17 bytes of overhead per 64 KiB chunk.
      expect(buckets.map(attachmentPlaintextLimit), [
        65429,
        261986,
        1048214,
        4193126,
        16772774,
        67091366,
      ]);
    });

    test('is asked only of a bucket', () {
      for (final size in [0, -1, 65535, 65537, 128 * 1024 * 1024]) {
        expect(
          () => attachmentPlaintextLimit(size),
          throwsArgumentError,
          reason: '$size',
        );
      }
    });
  });

  group('the fake platform', () {
    test('records each call and answers in order', () async {
      final directory = await Directory.systemTemp.createTemp('pick_fake_');
      addTearDown(() => directory.delete(recursive: true));
      final copy = File('${directory.path}/notes.txt')
        ..writeAsStringSync('twelve bytes');
      final platform = FakeAttachmentPlatform()
        ..pickFile(copy, displayName: 'notes.txt', mimeType: 'text/plain')
        ..enqueueSave(
          const Result.failure(StorageFailure(StorageFailureKind.unavailable)),
        );

      final first = await platform.pick(
        kind: AttachmentPickKind.file,
        maxBytes: 100,
      );
      final second = await platform.pick(
        kind: AttachmentPickKind.camera,
        maxBytes: 50,
      );
      final saved = await platform.save(
        file: copy,
        name: 'notes.txt',
        mimeType: 'text/plain',
      );
      final savedAgain = await platform.save(
        file: copy,
        name: 'notes.txt',
        mimeType: 'text/plain',
      );

      final picked = (first as Success<PickedAttachment>).value;
      expect(picked.length, 12);
      expect(picked.mediaKind, AttachmentMediaKind.file);
      expect(second, isA<FailureResult<PickedAttachment>>());
      expect(saved, isA<FailureResult<void>>());
      expect(savedAgain, isA<Success<void>>());
      expect(platform.picks.map((call) => (call.kind, call.maxBytes)), [
        (AttachmentPickKind.file, 100),
        (AttachmentPickKind.camera, 50),
      ]);
      expect(platform.saves, hasLength(2));
      expect(platform.calls, hasLength(4));
    });
  });
}
