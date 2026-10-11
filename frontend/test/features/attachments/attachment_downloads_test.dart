import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_crypto_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_downloads.dart';
import 'package:communication_platform/features/attachments/application/attachment_outgoing_holds.dart';
import 'package:communication_platform/features/attachments/application/attachment_transfer_service.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_download_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_file_cache.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_storage.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_local_state.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/application_event_harness.dart';
import '../../support/attachment_crypto_fake.dart';
import '../../support/attachment_descriptor_fixture.dart';
import '../../support/local_send_harness.dart';

/// ADR-089 D7, D8 and D9: the downloads of one session, one at a time, in
/// memory, each ending as a cached file, an expired row, or a state that
/// says why it did not.
void main() {
  final separator = Platform.pathSeparator;
  final start = DateTime.utc(2026, 10, 10, 8);
  late Directory temporary;
  late Directory root;
  late LocalDatabase database;
  late AttachmentLocalStatePort states;
  late _Clock clock;
  late FakeAttachmentCryptoPort crypto;
  late _Transport transport;
  late AttachmentFileCache cache;
  var messages = 0;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('cp_downloads_');
    root = await Directory(
      '${temporary.path}$separator$privateAttachmentCacheName',
    ).create();
    database = LocalDatabase(NativeDatabase.memory());
    states = DriftAttachmentLocalState(database);
    clock = _Clock(start);
    crypto = FakeAttachmentCryptoPort();
    transport = _Transport(PrivateAttachmentStorage(root: root));
    cache = AttachmentFileCache(
      root: root,
      states: states,
      clock: clock,
      random: Random(5),
    );
    messages = 0;
  });

  tearDown(() async {
    await database.close();
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  AttachmentDownloads queue({AttachmentFileCache? files}) =>
      AttachmentDownloads(
        holds: AttachmentOutgoingHolds(),
        files: () async => files ?? cache,
        states: () async => states,
        transfer: () async => AttachmentTransferService(
          crypto: AttachmentCryptoService(crypto),
          transport: transport,
          storage: PrivateAttachmentStorage(root: root),
        ),
      );

  /// A received attachment of [length] bytes: its ciphertext ready for the
  /// transport to hand out, and its message projected as the projector
  /// writes it, so the row exists and is not downloaded.
  Future<_Received> receive({
    int seed = 1,
    int length = 70000,
    String name = 'minutes.pdf',
  }) async {
    final plaintext = Uint8List(length);
    for (var index = 0; index < length; index += 1) {
      plaintext[index] = (index * seed) & 0xff;
    }
    final ciphertext = File('${temporary.path}${separator}cipher-$seed.bin');
    final encrypted = await AttachmentCryptoService(crypto).encryptToFile(
      source: AttachmentSource(
        length: length,
        displayName: name,
        mimeType: 'application/pdf',
        openRead: () => Stream.value(plaintext),
      ),
      destination: ciphertext,
    );
    final descriptor = (encrypted as Success<AttachmentDescriptor>).value
        .withCapability(testCapability(seed));
    messages += 1;
    final messageId = sequentialId(500 + messages);
    await applyCommit(
      database,
      applicationCommit(
        eventId: sequentialId(messages),
        kind: ApplicationEventKind.messageCreate,
        senderUser: peerUserId,
        senderDevice: peerDeviceId,
        counter: messages,
        body: MessageCreateBody(
          messageId: messageId,
          text: '',
          contentType: MessageContentType.attachment,
          attachments: [descriptor],
        ),
      ),
    );
    return _Received(
      messageId: protocolBytesToHex(messageId),
      descriptor: descriptor,
      plaintext: plaintext,
      ciphertext: await ciphertext.readAsBytes(),
    );
  }

  Future<AttachmentLocalState?> stateOf(_Received received) async =>
      (await states.read(received.descriptor.capabilityId)
              as Success<AttachmentLocalState?>)
          .value;

  void begin(AttachmentDownloads downloads, _Received received) => downloads
      .download(messageId: received.messageId, descriptor: received.descriptor);

  /// Every file under the cache root, as paths below it.
  List<String> files() => [
    for (final entity in root.listSync(recursive: true))
      if (entity is File) entity.path.substring(root.path.length + 1),
  ];

  group('a download that finishes', () {
    test(
      'is adopted by the cache, and its row is ready for seven days',
      () async {
        final received = await receive();
        final downloads = queue();
        transport.answer(received.ciphertext);
        final seen = <AttachmentDownloadState>[];
        final subscription = downloads
            .watch(received.descriptor.capabilityId)
            .listen((job) {
              if (job != null && (seen.isEmpty || seen.last != job.state)) {
                seen.add(job.state);
              }
            });
        addTearDown(subscription.cancel);

        begin(downloads, received);
        await _until(() => downloads.jobs.isEmpty);

        expect(seen, [
          AttachmentDownloadState.waiting,
          AttachmentDownloadState.downloading,
          AttachmentDownloadState.verifying,
        ]);
        final state = (await stateOf(received))!;
        expect(state.state, AttachmentTransferState.ready);
        expect(state.expiresAt, start.add(const Duration(days: 7)));
        final file = (await cache.peek(received.descriptor.capabilityId))!;
        expect(await file.readAsBytes(), received.plaintext);
        expect(file.path, endsWith('${separator}minutes.pdf'));
        // The decrypted file and nothing else: no ciphertext, no temporary.
        expect(files(), [
          ['plain', state.cacheId, 'minutes.pdf'].join(separator),
        ]);
      },
    );

    test('then holds the bound, evicting the least recently opened', () async {
      final first = await receive(seed: 1);
      final second = await receive(seed: 2);
      final bounded = AttachmentFileCache(
        root: root,
        states: states,
        clock: clock,
        random: Random(6),
        maximumBytes: 100000,
      );
      final downloads = queue(files: bounded);
      transport
        ..answer(first.ciphertext)
        ..answer(second.ciphertext);

      begin(downloads, first);
      await _until(() => downloads.jobs.isEmpty);
      clock.advance(const Duration(minutes: 1));
      begin(downloads, second);
      await _until(() => downloads.jobs.isEmpty);

      // Two files of 70,000 bytes pass 100,000: the older goes back to
      // "not downloaded".
      expect((await stateOf(first))!.state, AttachmentTransferState.queued);
      expect((await stateOf(second))!.state, AttachmentTransferState.ready);
      expect(files(), hasLength(1));
    });

    test('keeps no file when its message was deleted while it ran', () async {
      final received = await receive();
      final downloads = queue();
      final gate = transport.hold();
      transport.answer(received.ciphertext);

      begin(downloads, received);
      await _until(() => transport.requests == 1);
      final deleted = await DriftConversationDomainRepository(
        database,
      ).deleteForMe(received.messageId);
      expect(deleted, isA<Success<void>>());
      gate.complete();
      await _until(() => downloads.jobs.isEmpty);

      expect(await stateOf(received), isNull);
      expect(files(), isEmpty);
    });
  });

  group('a download that does not finish', () {
    test('marks the row expired when the server copy is gone', () async {
      final received = await receive();
      final downloads = queue();
      transport.fail(const BackendFailure(BackendFailureCode.notFound));

      begin(downloads, received);
      await _until(() => downloads.jobs.isEmpty);

      expect((await stateOf(received))!.state, AttachmentTransferState.expired);
      expect(files(), isEmpty);
    });

    test('is damaged when the bytes arrive and do not verify, and keeps '
        'nothing', () async {
      final received = await receive();
      final downloads = queue();
      final corrupt = Uint8List.fromList(received.ciphertext);
      corrupt[66 + 24 + 9] ^= 0x01;
      transport.answer(corrupt);

      begin(downloads, received);
      final id = received.descriptor.capabilityId;
      await _until(
        () => downloads.jobOf(id)?.state == AttachmentDownloadState.damaged,
      );

      expect((await stateOf(received))!.state, AttachmentTransferState.queued);
      expect(files(), isEmpty);
    });

    test('is damaged, not failed, though the verification answers the kind '
        'a broken transport answers', () async {
      final received = await receive();
      final downloads = queue();
      // A bucket of the right length whose header is not this file's.
      transport.answer(Uint8List(received.ciphertext.length));

      begin(downloads, received);
      final id = received.descriptor.capabilityId;
      await _until(
        () =>
            downloads.jobOf(id)?.state == AttachmentDownloadState.damaged ||
            downloads.jobOf(id)?.state == AttachmentDownloadState.failed,
      );

      expect(downloads.jobOf(id)!.state, AttachmentDownloadState.damaged);
      expect(files(), isEmpty);
    });

    for (final (name, failure) in [
      (
        'a dropped connection',
        const TransportFailure(TransportFailureKind.offline),
      ),
      ('429', const BackendFailure(BackendFailureCode.throttled)),
      ('500', const BackendFailure(BackendFailureCode.serverError)),
      ('503', const BackendFailure(BackendFailureCode.unavailable)),
      (
        'a token the server refused',
        const BackendFailure(BackendFailureCode.invalidToken),
      ),
      (
        'a wrong length',
        const SecurityFailure(SecurityFailureKind.malformedServerResponse),
      ),
    ]) {
      test('fails on $name, and a retry downloads it', () async {
        final received = await receive();
        final downloads = queue();
        transport
          ..fail(failure)
          ..answer(received.ciphertext);
        final id = received.descriptor.capabilityId;

        begin(downloads, received);
        await _until(
          () => downloads.jobOf(id)?.state == AttachmentDownloadState.failed,
        );
        expect(
          (await stateOf(received))!.state,
          AttachmentTransferState.queued,
        );
        expect(files(), isEmpty);

        downloads.retry(id);
        await _until(() => downloads.jobs.isEmpty);

        expect((await stateOf(received))!.state, AttachmentTransferState.ready);
        expect(transport.requests, 2);
      });
    }

    test('leaves the row not downloaded when it is cancelled', () async {
      final received = await receive();
      final downloads = queue();
      final gate = transport.hold();
      transport.answer(received.ciphertext);
      final id = received.descriptor.capabilityId;

      begin(downloads, received);
      await _until(() => transport.requests == 1);
      downloads.cancel(id);
      await _until(() => downloads.jobs.isEmpty);
      gate.complete();
      await pumpEventQueue();

      expect((await stateOf(received))!.state, AttachmentTransferState.queued);
      expect(transport.cancelled, 1);
      expect(files(), isEmpty);
    });
  });

  group('the queue', () {
    test('runs one download at a time, the oldest first', () async {
      final first = await receive(seed: 1);
      final second = await receive(seed: 2);
      final downloads = queue();
      final gate = transport.hold();
      transport
        ..answer(first.ciphertext)
        ..answer(second.ciphertext);

      begin(downloads, first);
      begin(downloads, second);
      await _until(() => transport.requests == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(transport.requests, 1);
      expect(transport.capabilities, [first.descriptor.capabilityId]);
      expect(
        downloads.jobOf(second.descriptor.capabilityId)!.state,
        AttachmentDownloadState.waiting,
      );
      gate.complete();
      await _until(() => downloads.jobs.isEmpty);

      expect(transport.capabilities, [
        first.descriptor.capabilityId,
        second.descriptor.capabilityId,
      ]);
    });

    test('keeps one job for an attachment, whatever is asked twice', () async {
      final received = await receive();
      final downloads = queue();
      final gate = transport.hold();
      transport.answer(received.ciphertext);

      begin(downloads, received);
      final first = downloads.jobs.single;
      begin(downloads, received);
      expect(downloads.jobs, [same(first)]);
      gate.complete();
      await _until(() => downloads.jobs.isEmpty);

      expect(transport.requests, 1);
    });

    test('a cancel of a waiting job removes it without a request', () async {
      final first = await receive(seed: 1);
      final second = await receive(seed: 2);
      final downloads = queue();
      final gate = transport.hold();
      transport.answer(first.ciphertext);

      begin(downloads, first);
      begin(downloads, second);
      downloads.cancel(second.descriptor.capabilityId);
      gate.complete();
      await _until(() => downloads.jobs.isEmpty);

      expect(transport.capabilities, [first.descriptor.capabilityId]);
    });

    test('asks nothing of the server for an expired attachment', () async {
      final received = await receive();
      await states.markExpired(received.descriptor.capabilityId);
      final downloads = queue();

      begin(downloads, received);
      await _until(() => downloads.jobs.isEmpty);

      expect(transport.requests, 0);
    });

    test('ends with its session: each job is cancelled', () async {
      final first = await receive(seed: 1);
      final second = await receive(seed: 2);
      final downloads = queue();
      final gate = transport.hold();
      transport
        ..answer(first.ciphertext)
        ..answer(second.ciphertext);
      final watched = <AttachmentDownloadJob?>[];
      final subscription = downloads
          .watch(first.descriptor.capabilityId)
          .listen(watched.add);
      addTearDown(subscription.cancel);

      begin(downloads, first);
      begin(downloads, second);
      await _until(() => transport.requests == 1);
      await downloads.close();

      expect(downloads.jobs, isEmpty);
      expect(watched.last, isNull);
      await _until(() => transport.cancelled == 1);
      gate.complete();
      await pumpEventQueue();
      begin(downloads, second);
      expect(downloads.jobs, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.requests, 1);
      expect(files(), isEmpty);
      expect((await stateOf(first))!.state, AttachmentTransferState.queued);
    });

    test('tells one attachment nothing of another\'s progress', () async {
      final first = await receive(seed: 1);
      final second = await receive(seed: 2);
      final downloads = queue();
      transport.answer(first.ciphertext);
      final secondSeen = <AttachmentDownloadJob?>[];
      final subscription = downloads
          .watch(second.descriptor.capabilityId)
          .listen(secondSeen.add);
      addTearDown(subscription.cancel);

      begin(downloads, first);
      await _until(() => downloads.jobs.isEmpty);

      expect(secondSeen, [null]);
    });

    test('names a job by its state and nothing else', () async {
      final received = await receive(name: 'secret-plans.pdf');
      final downloads = queue();
      transport.hold();
      transport.answer(received.ciphertext);

      begin(downloads, received);
      final text = '${downloads.jobs.single} $downloads';

      expect(
        text,
        'AttachmentDownloadJob(waiting) AttachmentDownloads(<redacted>)',
      );
      expect(text, isNot(contains(received.descriptor.capabilityId)));
      expect(text, isNot(contains('secret')));
    });
  });

  group('open', () {
    test('gives a ready file and moves its expiry to seven days on', () async {
      final received = await receive();
      final downloads = queue();
      transport.answer(received.ciphertext);
      begin(downloads, received);
      await _until(() => downloads.jobs.isEmpty);
      clock.advance(const Duration(days: 3));

      final opened = await downloads.open(received.descriptor.capabilityId);

      expect(await opened!.readAsBytes(), received.plaintext);
      expect(
        (await stateOf(received))!.expiresAt,
        start.add(const Duration(days: 10)),
      );
    });

    test('a look moves no expiry', () async {
      final received = await receive();
      final downloads = queue();
      transport.answer(received.ciphertext);
      begin(downloads, received);
      await _until(() => downloads.jobs.isEmpty);
      clock.advance(const Duration(days: 3));

      final seen = await downloads.peek(received.descriptor.capabilityId);

      expect(seen, isNotNull);
      expect(
        (await stateOf(received))!.expiresAt,
        start.add(const Duration(days: 7)),
      );
    });

    test(
      'clears the row of a file that went missing, and gives null',
      () async {
        final received = await receive();
        final downloads = queue();
        transport.answer(received.ciphertext);
        begin(downloads, received);
        await _until(() => downloads.jobs.isEmpty);
        final cacheId = (await stateOf(received))!.cacheId!;
        await Directory(
          [root.path, 'plain', cacheId].join(separator),
        ).delete(recursive: true);

        expect(await downloads.peek(received.descriptor.capabilityId), isNull);
        expect((await stateOf(received))!.state, AttachmentTransferState.ready);
        final opened = await downloads.open(received.descriptor.capabilityId);

        expect(opened, isNull);
        final state = (await stateOf(received))!;
        expect(state.state, AttachmentTransferState.queued);
        expect(state.cacheId, isNull);
        expect(state.expiresAt, isNull);
      },
    );

    test('gives null for an attachment that was never downloaded', () async {
      final received = await receive();

      expect(await queue().open(received.descriptor.capabilityId), isNull);
      expect((await stateOf(received))!.state, AttachmentTransferState.queued);
    });
  });
}

final class _Received {
  const _Received({
    required this.messageId,
    required this.descriptor,
    required this.plaintext,
    required this.ciphertext,
  });

  final String messageId;
  final AttachmentDescriptor descriptor;
  final Uint8List plaintext;
  final Uint8List ciphertext;
}

/// A transport that answers each download from a queue: the bytes of one
/// bucket, written to a temporary file as the real one writes them, or a
/// failure. [hold] makes the next downloads wait until the test lets them
/// go; a cancel while they wait answers as the real transport does.
final class _Transport implements AttachmentTransportPort {
  _Transport(this.storage);

  final AttachmentStoragePort storage;
  final _answers = <Object>[];
  Completer<void>? _gate;
  var requests = 0;
  var cancelled = 0;
  final capabilities = <String>[];

  void answer(Uint8List bytes) => _answers.add(bytes);

  void fail(Failure failure) => _answers.add(failure);

  Completer<void> hold() => _gate = Completer<void>();

  @override
  Future<Result<File>> download({
    required String capabilityId,
    required int expectedBucketSize,
    CancellationSignal? cancellation,
    void Function(int bytes)? onProgress,
  }) async {
    requests += 1;
    capabilities.add(capabilityId);
    final gate = _gate;
    if (gate != null) {
      await Future.any([
        gate.future,
        if (cancellation != null) cancellation.whenCancelled.first,
      ]);
    }
    if (cancellation?.isCancelled ?? false) {
      cancelled += 1;
      return const Result.failure(
        CancellationFailure(CancellationFailureKind.requestedByUser),
      );
    }
    final answer = _answers.removeAt(0);
    if (answer is Failure) {
      return Result.failure(answer);
    }
    final bytes = answer as Uint8List;
    final file = await storage.createEncryptedTemp();
    await file.writeAsBytes(bytes);
    onProgress?.call(bytes.length);
    return Result.success(file);
  }

  @override
  Future<Result<AttachmentUploadResponse>> upload({
    required File encryptedFile,
    required int bucketSize,
    CancellationSignal? cancellation,
    void Function(int sent, int total)? onProgress,
  }) => throw UnimplementedError('this test only downloads');
}

final class _Clock implements TimeSource {
  _Clock(this._now);

  DateTime _now;

  void advance(Duration by) => _now = _now.add(by);

  @override
  DateTime now() => _now;
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
