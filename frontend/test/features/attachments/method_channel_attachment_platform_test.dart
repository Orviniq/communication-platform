import 'dart:io';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/method_channel_attachment_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `MethodChannelAttachmentPlatform` against a mocked `AttachmentChannel.kt`.
///
/// The native side cannot run in a host test, so what is pinned here is the
/// Dart half of the contract: the arguments each method sends, the failure
/// each error code becomes, and the answers that are refused.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const root = '/data/user/0/com.example.app/cache/secure_attachment_cache';
  const id = '0123456789abcdef0123456789abcdef';
  const copyPath = '$root/outgoing/$id/holiday.jpg';
  const channel = MethodChannel(MethodChannelAttachmentPlatform.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) reply;
  late Object? cacheDirectory;

  setUp(() {
    calls = [];
    reply = (_) => null;
    cacheDirectory = root;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'privateCacheDirectory') {
        return cacheDirectory;
      }
      return reply(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Map<String, Object?> imageAnswer({
    Object? path = copyPath,
    Object? name = 'holiday.jpg',
    Object? mime = 'image/jpeg',
    Object? size = 1200,
    Object? kind = 'image',
    Object? width = 2048,
    Object? height = 1536,
  }) => {
    'path': ?path,
    'name': ?name,
    'mime': ?mime,
    'size': ?size,
    'kind': ?kind,
    'width': ?width,
    'height': ?height,
  };

  Never refuse(String code) => throw PlatformException(code: code);

  Future<Result<PickedAttachment>> pick({
    AttachmentPickKind kind = AttachmentPickKind.photo,
    int maxBytes = 4096,
  }) => MethodChannelAttachmentPlatform().pick(kind: kind, maxBytes: maxBytes);

  Failure failureOf(Result<Object?> result) => switch (result) {
    FailureResult(:final failure) => failure,
    Success() => fail('expected a failure, got a success'),
  };

  final malformed = isA<SecurityFailure>().having(
    (failure) => failure.kind,
    'kind',
    SecurityFailureKind.malformedServerResponse,
  );

  group('the arguments', () {
    test('a pick sends the kind and the byte limit', () async {
      reply = (_) => null;
      final platform = MethodChannelAttachmentPlatform();
      for (final kind in AttachmentPickKind.values) {
        await platform.pick(kind: kind, maxBytes: 67091366);
      }
      final picks = calls.where((call) => call.method == 'pick').toList();
      expect(picks.map((call) => call.arguments), [
        {'kind': 'photo', 'maxBytes': 67091366},
        {'kind': 'file', 'maxBytes': 67091366},
        {'kind': 'camera', 'maxBytes': 67091366},
      ]);
    });

    test('a pick with no room is refused before the platform', () async {
      final result = await pick(maxBytes: 0);
      expect(
        failureOf(result),
        isA<SecurityFailure>().having(
          (failure) => failure.kind,
          'kind',
          SecurityFailureKind.policyBlocked,
        ),
      );
      expect(calls, isEmpty);
    });

    test(
      'open, save and share send the path, the name and a safe type',
      () async {
        reply = (call) => call.method == 'saveVerifiedFile' ? true : null;
        final platform = MethodChannelAttachmentPlatform();
        final file = File('$root/plain/$id/report.pdf');
        await platform.open(file: file, mimeType: ' Application/PDF ');
        await platform.save(
          file: file,
          name: '../drafts/report.pdf',
          mimeType: 'text/html',
        );
        await platform.share(file: file, mimeType: 'IMAGE/PNG');
        expect(calls.map((call) => call.method), [
          'openVerifiedFile',
          'saveVerifiedFile',
          'shareVerifiedFile',
        ]);
        expect(calls.map((call) => call.arguments), [
          {'path': file.path, 'mime': 'application/pdf'},
          {
            'path': file.path,
            'name': 'report.pdf',
            'mime': 'application/octet-stream',
          },
          {'path': file.path, 'mime': 'image/png'},
        ]);
      },
    );
  });

  group('the outcomes', () {
    test('a pick that answers nothing was cancelled', () async {
      reply = (_) => null;
      expect(
        failureOf(await pick()),
        isA<CancellationFailure>().having(
          (failure) => failure.kind,
          'kind',
          CancellationFailureKind.requestedByUser,
        ),
      );
    });

    test('each pick error code is its own failure', () async {
      final expected = <String, Matcher>{
        'busy': isA<ValidationFailure>().having(
          (failure) => failure.kind,
          'kind',
          ValidationFailureKind.conflict,
        ),
        'tooLarge': isA<ValidationFailure>().having(
          (failure) => failure.kind,
          'kind',
          ValidationFailureKind.limitExceeded,
        ),
        'unsupportedImage': isA<ValidationFailure>().having(
          (failure) => failure.kind,
          'kind',
          ValidationFailureKind.invalidInput,
        ),
        'unreadable': isA<StorageFailure>().having(
          (failure) => failure.kind,
          'kind',
          StorageFailureKind.unavailable,
        ),
        'noCameraApp': isA<UnsupportedProtocolFailure>().having(
          (failure) => failure.kind,
          'kind',
          UnsupportedProtocolFailureKind.capability,
        ),
        'noApp': isA<UnsupportedProtocolFailure>().having(
          (failure) => failure.kind,
          'kind',
          UnsupportedProtocolFailureKind.capability,
        ),
        'invalid_argument': isA<SecurityFailure>().having(
          (failure) => failure.kind,
          'kind',
          SecurityFailureKind.policyBlocked,
        ),
        // A code another method gives, and a code nothing gives.
        'writeFailed': malformed,
        'surprise': malformed,
      };
      for (final MapEntry(key: code, value: matcher) in expected.entries) {
        reply = (_) => refuse(code);
        expect(failureOf(await pick()), matcher, reason: code);
      }
    });

    test('a cancelled save is told apart from a failed one', () async {
      final platform = MethodChannelAttachmentPlatform();
      final file = File('$root/plain/$id/report.pdf');
      Future<Result<void>> save() =>
          platform.save(file: file, name: 'report.pdf', mimeType: 'text/plain');

      reply = (_) => true;
      expect(await save(), isA<Success<void>>());
      reply = (_) => false;
      expect(failureOf(await save()), isA<CancellationFailure>());
      reply = (_) => refuse('writeFailed');
      expect(
        failureOf(await save()),
        isA<StorageFailure>().having(
          (failure) => failure.kind,
          'kind',
          StorageFailureKind.unavailable,
        ),
      );
      reply = (_) => refuse('busy');
      expect(
        failureOf(await save()),
        isA<ValidationFailure>().having(
          (failure) => failure.kind,
          'kind',
          ValidationFailureKind.conflict,
        ),
      );
      reply = (_) => refuse('noApp');
      expect(failureOf(await save()), isA<UnsupportedProtocolFailure>());
      reply = (_) => 'saved';
      expect(failureOf(await save()), malformed);
    });

    test('open and share name what stopped them', () async {
      final platform = MethodChannelAttachmentPlatform();
      final file = File('$root/plain/$id/report.pdf');

      reply = (_) => null;
      expect(
        await platform.open(file: file, mimeType: 'application/pdf'),
        isA<Success<void>>(),
      );
      expect(
        await platform.share(file: file, mimeType: 'application/pdf'),
        isA<Success<void>>(),
      );

      reply = (_) => refuse('noApp');
      expect(
        failureOf(await platform.open(file: file, mimeType: 'text/plain')),
        isA<UnsupportedProtocolFailure>().having(
          (failure) => failure.kind,
          'kind',
          UnsupportedProtocolFailureKind.capability,
        ),
      );
      for (final code in ['invalid_argument', 'share_failed']) {
        reply = (_) => refuse(code);
        expect(
          failureOf(await platform.share(file: file, mimeType: 'text/plain')),
          isA<SecurityFailure>().having(
            (failure) => failure.kind,
            'kind',
            SecurityFailureKind.policyBlocked,
          ),
          reason: code,
        );
      }
      reply = (_) => refuse('busy');
      expect(
        failureOf(await platform.open(file: file, mimeType: 'text/plain')),
        malformed,
      );
      reply = (_) => true;
      expect(
        failureOf(await platform.share(file: file, mimeType: 'text/plain')),
        malformed,
      );
    });

    test('a build without the channel has no capability', () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(
        failureOf(await pick()),
        isA<UnsupportedProtocolFailure>().having(
          (failure) => failure.kind,
          'kind',
          UnsupportedProtocolFailureKind.capability,
        ),
      );
    });
  });

  group('a pick answer', () {
    test('becomes the outgoing copy it describes', () async {
      reply = (_) => imageAnswer();
      final result = await pick(kind: AttachmentPickKind.camera);
      final picked = (result as Success<PickedAttachment>).value;
      expect(picked.file.path, copyPath);
      expect(picked.displayName, 'holiday.jpg');
      expect(picked.mimeType, 'image/jpeg');
      expect(picked.length, 1200);
      expect(picked.mediaKind, AttachmentMediaKind.image);
      expect((picked.width, picked.height), (2048, 1536));
    });

    test('of a file needs no dimensions', () async {
      reply = (_) => imageAnswer(
        path: '$root/outgoing/$id/notes.txt',
        name: 'notes.txt',
        mime: 'text/plain',
        kind: 'file',
        width: null,
        height: null,
      );
      final result = await pick(kind: AttachmentPickKind.file);
      final picked = (result as Success<PickedAttachment>).value;
      expect(picked.mediaKind, AttachmentMediaKind.file);
      expect(picked.width, isNull);
      expect(picked.height, isNull);
    });

    test('passes its name and its type through the safe forms', () async {
      reply = (_) => imageAnswer(
        name: '../../holiday\u0000 \t photo.html',
        mime: 'TEXT/HTML',
        kind: 'file',
      );
      final result = await pick(kind: AttachmentPickKind.file);
      final picked = (result as Success<PickedAttachment>).value;
      expect(picked.displayName, 'holiday_ _ photo.html');
      expect(picked.mimeType, 'application/octet-stream');

      reply = (_) => imageAnswer(mime: ' IMAGE/JPEG ');
      final photo = (await pick() as Success<PickedAttachment>).value;
      expect(photo.mimeType, 'image/jpeg');
    });

    test('is refused when a field is missing or of the wrong type', () async {
      final answers = <String, Object?>{
        'no path': imageAnswer(path: null),
        'no name': imageAnswer(name: null),
        'no type': imageAnswer(mime: null),
        'no size': imageAnswer(size: null),
        'no kind': imageAnswer(kind: null),
        'a number for a path': imageAnswer(path: 42),
        'a string for a size': imageAnswer(size: '1200'),
        'a string for a width': imageAnswer(width: '2048'),
        'not a map': copyPath,
      };
      for (final MapEntry(key: label, value: answer) in answers.entries) {
        reply = (_) => answer;
        expect(failureOf(await pick()), malformed, reason: label);
      }
    });

    test('is refused when its path is not an outgoing copy', () async {
      final paths = <String>[
        '$root/plain/$id/holiday.jpg',
        '$root/$id/holiday.jpg',
        '$root/outgoing/holiday.jpg',
        '$root/outgoing/$id/nested/holiday.jpg',
        '$root/outgoing/$id/..',
        '$root/outgoing/$id/',
        '$root/outgoing/0123456789ABCDEF0123456789ABCDEF/holiday.jpg',
        '$root/outgoing/0123456789abcdef/holiday.jpg',
        '$root/outgoing/../outgoing/$id/holiday.jpg',
        '/data/user/0/other/cache/secure_attachment_cache/outgoing/$id/a.jpg',
        'holiday.jpg',
      ];
      for (final path in paths) {
        reply = (_) => imageAnswer(path: path);
        expect(failureOf(await pick()), malformed, reason: path);
      }
    });

    test('is refused when it breaks what was asked for', () async {
      final answers = <String, (AttachmentPickKind, Object?)>{
        'above the limit': (AttachmentPickKind.photo, imageAnswer(size: 4097)),
        'a negative size': (AttachmentPickKind.photo, imageAnswer(size: -1)),
        'a file for a photo': (
          AttachmentPickKind.photo,
          imageAnswer(kind: 'file'),
        ),
        'an image for a file': (AttachmentPickKind.file, imageAnswer()),
        'an image with no size in pixels': (
          AttachmentPickKind.camera,
          imageAnswer(width: null, height: null),
        ),
        'one dimension': (
          AttachmentPickKind.file,
          imageAnswer(kind: 'file', height: null),
        ),
        'a dimension the descriptor refuses': (
          AttachmentPickKind.photo,
          imageAnswer(width: 8193),
        ),
        'a zero dimension': (AttachmentPickKind.photo, imageAnswer(height: 0)),
        'an image that is not a picture type': (
          AttachmentPickKind.photo,
          imageAnswer(mime: 'application/pdf'),
        ),
      };
      for (final MapEntry(key: label, value: (kind, answer))
          in answers.entries) {
        reply = (_) => answer;
        expect(failureOf(await pick(kind: kind)), malformed, reason: label);
      }
    });

    test('is refused when the private cache cannot be named', () async {
      reply = (_) => imageAnswer();
      for (final directory in <Object?>[null, '', 'relative/cache', 7]) {
        cacheDirectory = directory;
        expect(failureOf(await pick()), malformed, reason: '$directory');
      }
    });
  });

  group('nothing is written down', () {
    const canary = 'canary-7f3a';

    test('a picked attachment says nothing about itself', () {
      final picked = PickedAttachment(
        file: File('$root/outgoing/$id/$canary.jpg'),
        displayName: '$canary.jpg',
        mimeType: 'image/$canary',
        length: 1234567,
        mediaKind: AttachmentMediaKind.image,
        width: 4321,
        height: 3210,
      );
      final text = picked.toString();
      for (final secret in [canary, 'outgoing', '1234567', '4321', 'image']) {
        expect(text, isNot(contains(secret)));
      }
    });

    test('no failure carries the answer that caused it', () async {
      final answers = <Object? Function(MethodCall)>[
        (_) => imageAnswer(path: '/elsewhere/$canary.jpg'),
        (_) => imageAnswer(name: canary, mime: 'image/$canary', size: 99999),
        (_) => throw PlatformException(
          code: 'tooLarge',
          message: canary,
          details: '$root/outgoing/$id/$canary.jpg',
        ),
        (_) => throw PlatformException(code: canary),
      ];
      for (final answer in answers) {
        reply = answer;
        final failure = failureOf(await pick());
        expect(failure.toString(), isNot(contains(canary)));
        expect(failure.toString(), isNot(contains('outgoing')));
      }
    });
  });
}
