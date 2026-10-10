import 'dart:convert';
import 'dart:io';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/attachment_descriptor_fixture.dart';

/// ADR-089 D5: the caption limits and the name a descriptor carries.
void main() {
  PickedAttachment picked({
    String name = 'minutes.pdf',
    String mimeType = 'application/pdf',
    int? width,
    int? height,
    AttachmentMediaKind mediaKind = AttachmentMediaKind.file,
  }) => PickedAttachment(
    file: File('unused'),
    displayName: name,
    mimeType: mimeType,
    length: 10,
    mediaKind: mediaKind,
    width: width,
    height: height,
  );

  group('the name a descriptor carries', () {
    test('is the safe name when it fits 128 bytes', () {
      expect(attachmentDescriptorName('../minutes.pdf'), 'minutes.pdf');
      final ascii = '${'a' * 124}.pdf';
      expect(attachmentDescriptorName(ascii), ascii);
    });

    test('is cut to 128 bytes on whole characters', () {
      // Two bytes each: 64 fit.
      final persian = '${'م' * 90}.pdf';
      expect(attachmentDescriptorName(persian), 'م' * 64);
      // Four bytes each, and never half of one.
      final emoji = '\u{1F600}' * 40;
      final cut = attachmentDescriptorName(emoji);
      expect(cut, '\u{1F600}' * 32);
      expect(utf8.encode(cut).length, 128);
    });

    test('is its own safe name, so the crypto service keeps it', () {
      final spaced = '${'a' * 60} ${'م' * 40}';
      final cut = attachmentDescriptorName(spaced);
      expect(safeAttachmentName(cut), cut);
      expect(cut, isNot(endsWith(' ')));
    });
  });

  test('the metadata is counted as the descriptor counts it', () {
    final attachment = picked(
      name: 'photo.jpg',
      mimeType: 'image/jpeg',
      width: 2048,
      height: 1536,
      mediaKind: AttachmentMediaKind.image,
    );
    final descriptor = testAttachmentDescriptor(
      displayName: 'photo.jpg',
      mimeType: 'image/jpeg',
      mediaKind: AttachmentMediaKind.image,
    );
    final withSize = EncryptedAttachmentDescriptor(
      capabilityId: descriptor.capabilityId,
      key: descriptor.key,
      header: descriptor.header,
      secretstreamHeader: descriptor.secretstreamHeader,
      encryptedSize: descriptor.encryptedSize,
      bucketSize: descriptor.bucketSize,
      plaintextSize: descriptor.plaintextSize,
      displayName: 'photo.jpg',
      mimeType: 'image/jpeg',
      mediaKind: AttachmentMediaKind.image,
      width: 2048,
      height: 1536,
      caption: 'the view از پنجره',
    );

    expect(
      attachmentMetadataBytes(attachment, withSize.caption),
      withSize.authenticatedMetadata().length,
    );
  });

  group('a caption', () {
    test('is trimmed, and an empty one is none', () {
      expect(attachmentCaptionOf('  hello  '), 'hello');
      expect(attachmentCaptionOf('   '), isNull);
      expect(attachmentCaptionOf(null), isNull);
    });

    test('has at most 1,024 characters', () {
      final attachment = picked();
      expect(attachmentCaptionProblem(attachment, 'x' * 1024), isNull);
      expect(
        attachmentCaptionProblem(attachment, 'x' * 1025),
        AttachmentCaptionProblem.tooManyCharacters,
      );
      // A character is a scalar value, so an emoji is one.
      expect(attachmentCaptionCharacters('\u{1F600}'), 1);
    });

    test('keeps the metadata at or below 4,096 bytes', () {
      final attachment = picked();
      final fixed = attachmentMetadataBytes(attachment, '');
      // Four bytes a character, so the bytes run out before the characters.
      final room = 4096 - fixed;
      final fits = '\u{1F600}' * (room ~/ 4) + 'x' * (room % 4);
      expect(attachmentMetadataBytes(attachment, fits), 4096);
      expect(attachmentCaptionProblem(attachment, fits), isNull);
      expect(
        attachmentCaptionProblem(attachment, '\u{1F600}' * 1020),
        AttachmentCaptionProblem.metadataTooLarge,
      );
    });
  });

  test('the largest usable bucket is one both sides hold', () {
    expect(
      largestUsableAttachmentBucket(AttachmentCryptoProtocolV1.buckets),
      67108864,
    );
    expect(largestUsableAttachmentBucket({65536, 262144, 5000000}), 262144);
    expect(largestUsableAttachmentBucket({123}), isNull);
    expect(attachmentUploadBucket(10), 65536);
    expect(attachmentUploadBucket(70000000), isNull);
  });

  test('the allowance resets at the next midnight UTC', () {
    expect(
      allowanceResetsAt(DateTime.utc(2026, 10, 10, 23, 59)),
      DateTime.utc(2026, 10, 11),
    );
    expect(
      allowanceResetsAt(DateTime.utc(2026, 10, 11)),
      DateTime.utc(2026, 10, 12),
    );
  });

  test('no value names what it holds', () {
    final quote = AttachmentUploadQuote(
      fileBytes: 10,
      uploadBytes: 65536,
      published: true,
      remainingBytes: 1,
      resetsAt: DateTime.utc(2026),
    );
    expect(quote.toString(), 'AttachmentUploadQuote(<redacted>)');
    expect(
      const AttachmentUploadTarget.direct('peer').toString(),
      'AttachmentUploadTarget(<redacted>)',
    );
  });
}
