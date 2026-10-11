import 'dart:io';

import 'package:communication_platform/features/attachments/infrastructure/method_channel_attachment_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parts of the attachment boundary (ADR-089) that only exist in the
/// Android artifact.
///
/// No Kotlin runs in a host test and no device is used here, so what is pinned
/// is what the sources may and may not contain: the system intents the
/// pickers, the camera, Open and Save start, the permissions the artifact does
/// not ask for, and the one Dart class on each side of the channel.
void main() {
  const kotlinRoot =
      'android/app/src/main/kotlin/com/example/communication_platform';
  const channelName = 'communication_platform/attachments';
  final attachmentChannel = _code(
    File('$kotlinRoot/AttachmentChannel.kt').readAsStringSync(),
  );
  final activity = _code(
    File('$kotlinRoot/MainActivity.kt').readAsStringSync(),
  );

  test('only the adapter names the channel, and the private storage '
      'reaches it by the adapter\'s name', () {
    expect(MethodChannelAttachmentPlatform.channelName, channelName);
    final naming = <String>[
      for (final entry in Directory('lib').listSync(recursive: true))
        if (entry is File &&
            entry.path.endsWith('.dart') &&
            entry.readAsStringSync().contains(channelName))
          entry.path.replaceAll(r'\', '/'),
    ]..sort();
    expect(naming, [
      'lib/features/attachments/infrastructure/method_channel_attachment_platform.dart',
    ]);
    expect(
      File(
        'lib/features/attachments/infrastructure/attachment_storage.dart',
      ).readAsStringSync(),
      contains('MethodChannelAttachmentPlatform.channelName'),
      reason: 'privateCacheDirectory is asked on the same channel',
    );
    expect(attachmentChannel, contains('NAME = "$channelName"'));
    expect(
      activity,
      isNot(contains(channelName)),
      reason: 'the channel lives in AttachmentChannel.kt and nowhere else',
    );
  });

  group('the native side', () {
    test(
      'starts a system intent for each picker, the camera, Open and Save',
      () {
        for (final action in const [
          'MediaStore.ACTION_PICK_IMAGES',
          'Intent.ACTION_GET_CONTENT',
          'Intent.ACTION_OPEN_DOCUMENT',
          'MediaStore.ACTION_IMAGE_CAPTURE',
          'Intent.ACTION_CREATE_DOCUMENT',
          'Intent.ACTION_VIEW',
          'Intent.ACTION_SEND',
        ]) {
          expect(attachmentChannel, contains(action));
        }
      },
    );

    test('offers the photo picker only where the device has it', () {
      expect(
        attachmentChannel,
        contains('Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU'),
      );
      expect(
        attachmentChannel,
        contains(
          'SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2',
        ),
      );
    });

    test('hands the capture URI to the camera with its grant', () {
      expect(attachmentChannel, contains('MediaStore.EXTRA_OUTPUT'));
      expect(attachmentChannel, contains('ClipData.newRawUri'));
      expect(attachmentChannel, contains('FLAG_GRANT_WRITE_URI_PERMISSION'));
      expect(attachmentChannel, contains('ActivityNotFoundException'));
    });

    test('re-encodes a photo bounded, upright and without metadata', () {
      expect(attachmentChannel, contains('MAX_IMAGE_SIDE = 2048'));
      expect(attachmentChannel, contains('JPEG_QUALITY = 82'));
      expect(attachmentChannel, contains('Bitmap.CompressFormat.JPEG'));
      expect(attachmentChannel, contains('Color.WHITE'));
      expect(attachmentChannel, contains('ImageDecoder.ALLOCATOR_SOFTWARE'));
      expect(attachmentChannel, contains('inSampleSize'));
      // Read once, below API 28 only: `ImageDecoder` applies it itself.
      expect(
        RegExp(r'ExifInterface\(').allMatches(attachmentChannel),
        hasLength(1),
      );
      expect(attachmentChannel, isNot(contains('setAttribute')));
      expect(attachmentChannel, isNot(contains('saveAttributes')));
    });

    test('shows the outside only files in the plain cache', () {
      expect(attachmentChannel, contains('PLAIN_DIRECTORY = "plain"'));
      expect(attachmentChannel, contains('canonicalFile'));
      expect(attachmentChannel, contains('SecureRandom'));
    });

    test('logs nothing', () {
      for (final call in const ['Log.', 'println', 'printStackTrace']) {
        expect(attachmentChannel, isNot(contains(call)), reason: call);
      }
    });

    test('takes results after the embedding has seen them', () {
      final override = RegExp(
        r'override fun onActivityResult\([^)]*\) \{(.*?)\n    \}',
        dotAll: true,
      ).firstMatch(activity);
      expect(override, isNotNull);
      final body = override!.group(1)!;
      final forward = body.indexOf('attachments.onActivityResult(');
      expect(body.indexOf('super.onActivityResult('), isNonNegative);
      expect(forward, greaterThan(body.indexOf('super.onActivityResult(')));
    });
  });

  group('the artifact', () {
    final manifests = [
      for (final variant in const ['main', 'debug', 'profile'])
        File('android/app/src/$variant/AndroidManifest.xml')
            .readAsStringSync()
            .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ''),
    ];

    test('asks for no camera, media or storage permission', () {
      final permissions = [
        for (final manifest in manifests)
          for (final match in RegExp(
            r'<uses-permission\b[^>]*android:name="([^"]+)"[^>]*>',
          ).allMatches(manifest))
            if (!match.group(0)!.contains('tools:node="remove"'))
              match.group(1)!,
      ];
      expect(permissions, isNotEmpty);
      for (final permission in permissions) {
        for (final forbidden in const [
          'CAMERA',
          'READ_MEDIA_',
          'READ_EXTERNAL_STORAGE',
          'WRITE_EXTERNAL_STORAGE',
          'MANAGE_EXTERNAL_STORAGE',
          'ACCESS_MEDIA_LOCATION',
        ]) {
          expect(permission, isNot(contains(forbidden)), reason: permission);
        }
      }
    });

    test('queries for no picker: a missing app is caught, not looked up', () {
      final queries = RegExp(
        r'<queries>(.*?)</queries>',
        dotAll: true,
      ).allMatches(manifests.join()).map((match) => match.group(1)!).join();
      for (final action in const [
        'PICK_IMAGES',
        'GET_CONTENT',
        'OPEN_DOCUMENT',
        'CREATE_DOCUMENT',
        'IMAGE_CAPTURE',
        'android.intent.action.VIEW',
        'android.intent.action.SEND',
      ]) {
        expect(queries, isNot(contains(action)), reason: action);
      }
    });

    test('exposes the private cache to the provider and nothing else', () {
      final paths = File(
        'android/app/src/main/res/xml/file_paths.xml',
      ).readAsStringSync();
      final elements = RegExp(r'<(\w+-path)\b[^>]*>').allMatches(paths);
      expect(elements.map((match) => match.group(1)), ['cache-path']);
      expect(paths, contains('path="secure_attachment_cache/"'));
    });
  });
}

/// The Kotlin source without its comments, so an assertion reads what the
/// code does rather than what a comment says about it.
String _code(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');
