import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/attachment_descriptor_fixture.dart';

/// The type allowlist of an attachment (ADR-089, ADR-097 V4). The Dart side
/// has two copies, one for a picked file and one for a received descriptor,
/// and `test/architecture/attachment_platform_policy_test.dart` keeps both
/// equal to the Kotlin one.
void main() {
  const videos = ['video/mp4', 'video/webm', 'video/3gpp', 'video/quicktime'];

  test('safeMimeType keeps each video type, in any case', () {
    for (final type in videos) {
      expect(safeMimeType(type), type);
      expect(safeMimeType(' ${type.toUpperCase()} '), type);
    }
  });

  test('safeMimeType maps any other type to an octet stream', () {
    for (final type in const [
      'video/x-matroska',
      'video/avi',
      'video/*',
      'video/',
      'video',
      'text/html',
      'application/x-msdownload',
      '',
    ]) {
      expect(safeMimeType(type), 'application/octet-stream', reason: type);
    }
  });

  test('safeMimeType still keeps what it kept before', () {
    for (final type in const [
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
      'audio/mpeg',
      'audio/ogg',
      'audio/wav',
      'text/plain',
      'application/pdf',
    ]) {
      expect(safeMimeType(type), type);
    }
  });

  test('a received descriptor keeps the same video types', () {
    for (final type in videos) {
      expect(testAttachmentDescriptor(mimeType: type).mimeType, type);
    }
    expect(
      testAttachmentDescriptor(mimeType: 'video/x-matroska').mimeType,
      'application/octet-stream',
    );
  });
}
