import 'dart:io';
import 'dart:math';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/domain/attachment_cache_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_file_cache.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_storage.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_local_state.dart';
import 'package:communication_platform/features/attachments/infrastructure/method_channel_attachment_platform.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/application_event_harness.dart';
import '../../support/attachment_descriptor_fixture.dart';
import '../../support/local_send_harness.dart';

/// ADR-089 D8: every decrypted file lives under the private cache, in a
/// directory named by a random id that its row holds, inside the bounds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final separator = Platform.pathSeparator;
  final start = DateTime.utc(2026, 10, 10, 8);
  late Directory temporary;
  late Directory root;
  late LocalDatabase database;
  late DriftAttachmentLocalState states;
  late _Clock clock;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('cp_file_cache_');
    root = await Directory(
      '${temporary.path}$separator$privateAttachmentCacheName',
    ).create();
    database = LocalDatabase(NativeDatabase.memory());
    states = DriftAttachmentLocalState(database);
    clock = _Clock(start);
  });

  tearDown(() async {
    await database.close();
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  AttachmentFileCache cache({int? maximumBytes, int seed = 7}) =>
      AttachmentFileCache(
        root: root,
        states: states,
        clock: clock,
        random: Random(seed),
        maximumBytes: maximumBytes ?? AttachmentCacheLimits.maximumBytes,
      );

  /// A received attachment message for each capability, as the projector
  /// writes it: one row each, not downloaded.
  Future<void> receive(List<String> capabilities) async {
    var seed = 0;
    for (final capability in capabilities) {
      seed += 1;
      await applyCommit(
        database,
        applicationCommit(
          eventId: sequentialId(seed),
          kind: ApplicationEventKind.messageCreate,
          senderUser: peerUserId,
          senderDevice: peerDeviceId,
          counter: seed,
          body: MessageCreateBody(
            messageId: sequentialId(500 + seed),
            text: '',
            contentType: MessageContentType.attachment,
            attachments: [testAttachmentDescriptor(capability: capability)],
          ),
        ),
      );
    }
  }

  Future<AttachmentLocalState> stateOf(String capability) async =>
      (await states.read(capability) as Success<AttachmentLocalState?>).value!;

  String path(List<String> segments) =>
      [root.path, ...segments].join(separator);

  Future<File> writeFile(List<String> segments, int bytes) async {
    final file = File(path(segments));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(List<int>.filled(bytes, 7));
  }

  Future<String> download(
    AttachmentFileCache cache,
    String capability, {
    int bytes = 40,
    String name = 'file.txt',
  }) async {
    final storage = PrivateAttachmentStorage(root: root, random: Random(99));
    final temporary = await storage.createDecryptedTemp();
    await temporary.writeAsBytes(List<int>.filled(bytes, 1));
    final adopted = await cache.adoptDecrypted(
      attachmentId: capability,
      file: temporary,
      name: name,
    );
    return (adopted as Success<String>).value;
  }

  group('the layout', () {
    test('temporary files have random names at the top level', () async {
      final storage = PrivateAttachmentStorage(root: root);
      final names = <String>{
        for (final file in [
          await storage.createEncryptedTemp(),
          await storage.createDecryptedTemp(),
          await storage.createDecryptedTemp(),
        ])
          file.path,
      };

      expect(names, hasLength(3));
      for (final name in names) {
        expect(name.startsWith('${root.path}$separator'), isTrue);
        final base = name.substring(root.path.length + 1);
        expect(base, matches(RegExp(r'^[0-9a-f]{32}\.tmp$')));
      }
    });

    test('a decrypted file moves to plain/<random id>/<safe name>, and its '
        'row names the id', () async {
      final capability = testCapability(1);
      await receive([capability]);
      final files = cache();
      final storage = PrivateAttachmentStorage(root: root);
      final temporary = await storage.createDecryptedTemp();
      await temporary.writeAsString('minutes of the board');

      final adopted = await files.adoptDecrypted(
        attachmentId: capability,
        file: temporary,
        name: 'Board minutes.pdf',
      );

      final id = (adopted as Success<String>).value;
      expect(isAttachmentCacheId(id), isTrue);
      expect(id, isNot(contains(capability.substring(0, 8))));
      expect(id, isNot(contains('minutes')));
      final placed = File(path(['plain', id, 'Board minutes.pdf']));
      expect(await placed.readAsString(), 'minutes of the board');
      expect(await temporary.exists(), isFalse);
      expect((await files.resolve(id))!.path, placed.path);

      final state = await stateOf(capability);
      expect(state.state, AttachmentTransferState.ready);
      expect(state.cacheId, id);
      expect(state.expiresAt, start.add(AttachmentCacheLimits.lifetime));
    });

    test('an outgoing copy moves whole into plain/ under a new id', () async {
      final capability = testCapability(1);
      await receive([capability]);
      const outgoingId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final copy = await writeFile(['outgoing', outgoingId, 'photo.jpg'], 64);
      await writeFile(['outgoing', outgoingId, 'capture.jpg'], 8);
      final files = cache();

      final adopted = await files.adoptOutgoing(
        attachmentId: capability,
        copy: copy,
      );

      final id = (adopted as Success<String>).value;
      expect(id, isNot(outgoingId));
      expect(await Directory(path(['outgoing', outgoingId])).exists(), isFalse);
      final moved = await Directory(
        path(['plain', id]),
      ).list().map((entity) => entity.path).toList();
      expect(moved, [
        path(['plain', id, 'photo.jpg']),
      ]);
      expect((await stateOf(capability)).cacheId, id);
    });

    test('refuses a file outside its place and leaves it there', () async {
      final capability = testCapability(1);
      await receive([capability]);
      final files = cache();
      final nested = await writeFile(['plain', 'x.bin'], 4);
      final stranger = await writeFile(['elsewhere', 'photo.jpg'], 4);

      expect(
        await files.adoptDecrypted(
          attachmentId: capability,
          file: nested,
          name: 'x.bin',
        ),
        _failure(SecurityFailureKind.policyBlocked),
      );
      expect(
        await files.adoptOutgoing(attachmentId: capability, copy: stranger),
        _failure(SecurityFailureKind.policyBlocked),
      );
      expect(await nested.exists(), isTrue);
      expect(await stranger.exists(), isTrue);
      expect((await stateOf(capability)).state, AttachmentTransferState.queued);
    });

    test(
      'a file whose row is gone is deleted, not left without a name',
      () async {
        final files = cache();
        final storage = PrivateAttachmentStorage(root: root);
        final temporary = await storage.createDecryptedTemp();
        await temporary.writeAsString('plaintext');

        final adopted = await files.adoptDecrypted(
          attachmentId: testCapability(5),
          file: temporary,
          name: 'notes.txt',
        );

        expect(
          adopted,
          isA<FailureResult<String>>().having(
            (result) => result.failure,
            'failure',
            isA<ValidationFailure>(),
          ),
        );
        expect(await temporary.exists(), isFalse);
        expect(await Directory(path(['plain'])).list().toList(), isEmpty);
      },
    );

    test(
      'a second download of an attachment replaces the first file',
      () async {
        final capability = testCapability(1);
        await receive([capability]);
        final files = cache();

        final first = await download(files, capability);
        final second = await download(files, capability);

        expect(second, isNot(first));
        expect(await Directory(path(['plain', first])).exists(), isFalse);
        expect(await files.resolve(second), isNotNull);
      },
    );

    test('remove deletes the directory of an id', () async {
      final capability = testCapability(1);
      await receive([capability]);
      final files = cache();
      final id = await download(files, capability);

      await files.remove(id);

      expect(await Directory(path(['plain', id])).exists(), isFalse);
      expect(await files.resolve(id), isNull);
    });

    test('a file name is safe and fits one name of the file system', () {
      expect(plainAttachmentFileName('../../etc/passwd'), 'passwd');
      expect(plainAttachmentFileName('a\u0000b'), 'a_b');
      expect(plainAttachmentFileName('..'), 'attachment');
      final long = plainAttachmentFileName('é' * 200);
      expect(long.length, 127);
      expect(long.codeUnits.every((unit) => unit == 0xe9), isTrue);
    });
  });

  group('the bounds', () {
    test('over the limit, the earliest expiry is evicted first and its row '
        'returns to not downloaded', () async {
      final capabilities = [for (var i = 1; i <= 4; i += 1) testCapability(i)];
      await receive(capabilities);
      final files = cache(maximumBytes: 100);

      final first = await download(files, capabilities[0]);
      clock.advance(const Duration(hours: 1));
      final second = await download(files, capabilities[1]);
      clock.advance(const Duration(hours: 1));
      expect(await files.resolve(first), isNotNull);

      final third = await download(files, capabilities[2]);

      expect(await Directory(path(['plain', first])).exists(), isFalse);
      final evicted = await stateOf(capabilities[0]);
      expect(evicted.state, AttachmentTransferState.queued);
      expect(evicted.cacheId, isNull);
      expect(await files.resolve(second), isNotNull);
      expect(await files.resolve(third), isNotNull);

      // Opening the second makes it the most recently opened, so the third is
      // the one the next download pushes out.
      clock.advance(const Duration(hours: 1));
      expect(await files.open(capabilities[1]), isNotNull);
      expect(
        (await stateOf(capabilities[1])).expiresAt,
        clock.now().add(AttachmentCacheLimits.lifetime),
      );
      clock.advance(const Duration(hours: 1));
      await download(files, capabilities[3]);

      expect(await files.resolve(third), isNull);
      expect(
        (await stateOf(capabilities[2])).state,
        AttachmentTransferState.queued,
      );
      expect(await files.resolve(second), isNotNull);
    });

    test('an expired entry and a missing file return the row to not '
        'downloaded', () async {
      final expired = testCapability(1);
      final missing = testCapability(2);
      final swept = testCapability(3);
      await receive([expired, missing, swept]);
      final files = cache();
      final expiredId = await download(files, expired);
      final missingId = await download(files, missing);
      final sweptId = await download(files, swept);

      await File(path(['plain', missingId, 'file.txt'])).delete();
      expect(await files.open(missing), isNull);
      expect((await stateOf(missing)).state, AttachmentTransferState.queued);

      clock.advance(AttachmentCacheLimits.lifetime);
      expect(await files.open(expired), isNull);
      expect((await stateOf(expired)).state, AttachmentTransferState.queued);
      expect(await Directory(path(['plain', expiredId])).exists(), isFalse);

      await files.sweep(liveOutgoing: const []);
      expect((await stateOf(swept)).state, AttachmentTransferState.queued);
      expect(await Directory(path(['plain', sweptId])).exists(), isFalse);
    });
  });

  group('the sweep', () {
    test('deletes plain/ entries no row names and outgoing copies nothing '
        'holds', () async {
      final capability = testCapability(1);
      await receive([capability]);
      final files = cache();
      final named = await download(files, capability);
      final unnamed = await writeFile([
        'plain',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'old.pdf',
      ], 4);
      final stray = await writeFile(['plain', 'stray.bin'], 4);
      final live = await writeFile([
        'outgoing',
        'cccccccccccccccccccccccccccccccc',
        'sending.jpg',
      ], 4);
      final orphan = await writeFile([
        'outgoing',
        'dddddddddddddddddddddddddddddddd',
        'dropped.jpg',
      ], 4);

      await files.sweep(liveOutgoing: [live]);

      expect(await files.resolve(named), isNotNull);
      expect(await unnamed.parent.exists(), isFalse);
      expect(await stray.exists(), isFalse);
      expect(await live.exists(), isTrue);
      expect(await orphan.parent.exists(), isFalse);
      expect((await stateOf(capability)).state, AttachmentTransferState.ready);
    });

    test('only the first sweep deletes the files at the top level', () async {
      final files = cache();
      final before = await writeFile(['${'e' * 32}.tmp'], 4);
      final keptDirectory = await Directory(path(['unknown'])).create();

      await files.sweep(liveOutgoing: const []);
      expect(await before.exists(), isFalse);
      expect(await keptDirectory.exists(), isTrue);

      final during = await writeFile(['${'f' * 32}.tmp'], 4);
      await files.sweep(liveOutgoing: const []);
      await files.beforeTransfer(liveOutgoing: const []);
      expect(await during.exists(), isTrue);
    });

    test('the first transfer runs the first sweep, and later ones wait for '
        'the same one', () async {
      final files = cache();
      final before = await writeFile(['${'e' * 32}.tmp'], 4);

      final first = files.beforeTransfer(liveOutgoing: const []);
      final second = files.beforeTransfer(liveOutgoing: const []);
      expect(identical(first, second), isTrue);
      await first;
      expect(await before.exists(), isFalse);

      final after = await writeFile(['${'f' * 32}.tmp'], 4);
      await files.beforeTransfer(liveOutgoing: const []);
      expect(await after.exists(), isTrue);
    });
  });

  group('no private cache, no attachments', () {
    const channel = MethodChannel(MethodChannelAttachmentPlatform.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    void answer(Object? Function() reply) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'privateCacheDirectory');
        return reply();
      });
    }

    test('only the private cache the platform names is a root', () async {
      const valid =
          '/data/user/0/com.example.app/cache/secure_attachment_cache';
      answer(() => valid);
      expect((await privateAttachmentCacheRoot())!.path, valid);
      expect(await PrivateAttachmentStorage.forPlatform(), isNotNull);

      for (final reply in <Object? Function()>[
        () => null,
        () => '',
        () => 42,
        () => 'cache/secure_attachment_cache',
        () => '/data/user/0/com.example.app/cache',
        () => '/data/user/0/com.example.app/cache/secure_attachment_cache/',
        () => '/data/user/0/com.example.app/../secure_attachment_cache',
        () => '/data//secure_attachment_cache',
        () => throw PlatformException(code: 'unavailable'),
      ]) {
        answer(reply);
        expect(await privateAttachmentCacheRoot(), isNull);
        expect(await PrivateAttachmentStorage.forPlatform(), isNull);
      }

      messenger.setMockMethodCallHandler(channel, null);
      expect(await privateAttachmentCacheRoot(), isNull);
    });

    test('nothing in the attachment feature falls back to another '
        'directory', () {
      final offenders = <String>[];
      for (final entity in Directory(
        'lib/features/attachments',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        for (final fallback in [
          'systemTemp',
          'getTemporaryDirectory',
          'getApplicationDocumentsDirectory',
        ]) {
          if (source.contains(fallback)) {
            offenders.add('${entity.path}: $fallback');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  test('says nothing about its files when printed', () {
    final printed = [
      cache().toString(),
      PrivateAttachmentStorage(root: root).toString(),
    ].join('\n');

    expect(printed, isNot(contains(root.path)));
    expect(printed, isNot(contains(privateAttachmentCacheName)));
  });
}

Matcher _failure(SecurityFailureKind kind) =>
    isA<FailureResult<String>>().having(
      (result) => result.failure,
      'failure',
      isA<SecurityFailure>().having((failure) => failure.kind, 'kind', kind),
    );

final class _Clock implements TimeSource {
  _Clock(this._now);

  DateTime _now;

  void advance(Duration by) => _now = _now.add(by);

  @override
  DateTime now() => _now;
}
