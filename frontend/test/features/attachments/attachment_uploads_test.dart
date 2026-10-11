import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_crypto_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_outgoing_holds.dart';
import 'package:communication_platform/features/attachments/application/attachment_transfer_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_uploads.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_upload_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_file_cache.dart';
import 'package:communication_platform/features/attachments/infrastructure/attachment_storage.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_local_state.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/application/ports/attachment_sweep_port.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:communication_platform/features/messaging/infrastructure/pairwise_application_fanout_adapter.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/attachment_crypto_fake.dart';
import '../../support/attachment_descriptor_fixture.dart';
import '../../support/attachment_platform_fake.dart';
import '../../support/local_send_harness.dart';

/// ADR-089 D5 and D6: the uploads of one session, one at a time, in memory.
void main() {
  const allBuckets = <int>{65536, 262144, 1048576, 4194304, 16777216, 67108864};
  const dailyBytes = 268435456;
  late Directory root;
  late LocalDatabase database;
  late FakeAttachmentPlatform platform;
  late AttachmentOutgoingHolds holds;
  late _Clock clock;
  late FakeAttachmentCryptoPort crypto;
  late _Transport transport;
  late _Allowance allowance;
  late _Messages messages;
  late AttachmentLocalStatePort states;
  late AttachmentFileCache cache;
  late AttachmentUploadLimits limits;
  var copies = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cp_uploads_');
    database = LocalDatabase(NativeDatabase.memory());
    platform = FakeAttachmentPlatform();
    holds = AttachmentOutgoingHolds();
    clock = _Clock(DateTime.utc(2026, 10, 10, 21, 30));
    crypto = FakeAttachmentCryptoPort();
    transport = _Transport();
    allowance = _Allowance();
    messages = _Messages();
    states = DriftAttachmentLocalState(database);
    cache = AttachmentFileCache(root: root, states: states, clock: clock);
    limits = (buckets: allBuckets, dailyBytes: dailyBytes);
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  AttachmentUploads queue({AttachmentMessagePort? sender}) => AttachmentUploads(
    platform: platform,
    holds: holds,
    limits: () => limits,
    clock: clock,
    files: () async => cache,
    allowance: () async => allowance,
    states: () async => states,
    transfer: () async => AttachmentTransferService(
      crypto: AttachmentCryptoService(crypto),
      transport: transport,
      storage: PrivateAttachmentStorage(root: root),
    ),
    messages: () async => sender ?? messages,
  );

  /// An outgoing copy, as the picker leaves one.
  Future<PickedAttachment> picked({
    String name = 'minutes.pdf',
    String mimeType = 'application/pdf',
    int length = 1000,
    AttachmentMediaKind mediaKind = AttachmentMediaKind.file,
    int? width,
    int? height,
  }) async {
    copies += 1;
    final file = File(
      [
        root.path,
        'outgoing',
        copies.toRadixString(16).padLeft(32, '0'),
        name,
      ].join(Platform.pathSeparator),
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(length, 7));
    return PickedAttachment(
      file: file,
      displayName: name,
      mimeType: mimeType,
      length: length,
      mediaKind: mediaKind,
      width: width,
      height: height,
    );
  }

  AttachmentUploadJob enqueue(
    AttachmentUploads uploads,
    PickedAttachment attachment, {
    String? caption,
    String conversationId = 'c-1',
  }) =>
      (uploads.enqueue(
                conversationId: conversationId,
                target: const AttachmentUploadTarget.direct(peerUserId),
                attachment: attachment,
                caption: caption,
              )
              as Success<AttachmentUploadJob>)
          .value;

  AttachmentUploadJob? jobOf(AttachmentUploads uploads, String id) =>
      uploads.jobs.where((job) => job.id == id).firstOrNull;

  group('a job', () {
    test('runs one at a time, the oldest first, through each state', () async {
      final uploads = queue();
      final first = await picked(name: 'first.pdf');
      final second = await picked(name: 'second.pdf');
      final seen = <AttachmentUploadState>[];
      final subscription = uploads.watch('c-1').listen((jobs) {
        final state = jobs.firstOrNull?.state;
        if (jobs.firstOrNull?.attachment == first &&
            state != null &&
            (seen.isEmpty || seen.last != state)) {
          seen.add(state);
        }
      });
      addTearDown(subscription.cancel);
      transport.gate = Completer<void>();

      final a = enqueue(uploads, first);
      final b = enqueue(uploads, second);
      await _until(
        () => jobOf(uploads, a.id)?.state == AttachmentUploadState.uploading,
      );

      expect(transport.uploads, hasLength(1));
      expect(jobOf(uploads, b.id)!.state, AttachmentUploadState.waiting);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.uploads, hasLength(1));

      transport.gate!.complete();
      await _until(() => uploads.jobs.isEmpty);

      expect(seen, [
        AttachmentUploadState.waiting,
        AttachmentUploadState.encrypting,
        AttachmentUploadState.uploading,
        AttachmentUploadState.sending,
      ]);
      expect(transport.uploads, [65536, 65536]);
      expect(
        [for (final sent in messages.sent) sent.descriptor.displayName],
        ['first.pdf', 'second.pdf'],
      );
      expect(holds.live, isEmpty);
    });

    test('hands sendAttachments the descriptor and the caption', () async {
      final uploads = queue();
      final photo = await picked(
        name: 'photo.jpg',
        mimeType: 'image/jpeg',
        length: 200000,
        mediaKind: AttachmentMediaKind.image,
        width: 2048,
        height: 1536,
      );

      enqueue(uploads, photo, caption: '  the view  ');
      await _until(() => uploads.jobs.isEmpty);

      final sent = messages.sent.single;
      expect(sent.target.peerUserId, peerUserId);
      expect(sent.caption, 'the view');
      expect(sent.imageMessage, isTrue);
      expect(sent.descriptor.capabilityId, testCapability(1));
      expect(sent.descriptor.bucketSize, 262144);
      expect(sent.descriptor.plaintextSize, 200000);
      expect(sent.descriptor.caption, 'the view');
      expect(sent.descriptor.width, 2048);
      expect(
        utf8.decode(crypto.lastMetadata),
        utf8.decode(sent.descriptor.authenticatedMetadata()),
      );
    });

    test('a file is not an image message', () async {
      final uploads = queue();
      enqueue(uploads, await picked());
      await _until(() => uploads.jobs.isEmpty);

      expect(messages.sent.single.imageMessage, isFalse);
      expect(messages.sent.single.caption, isNull);
    });

    test('carries a name the protocol can read, whatever its length', () async {
      // Ninety Persian letters are 180 bytes of UTF-8. The core reads at most
      // 128, and would refuse the message after the upload.
      final name = '${'م' * 90}.pdf';
      final uploads = queue();
      enqueue(uploads, await picked(name: name));
      await _until(() => uploads.jobs.isEmpty);

      final carried = messages.sent.single.descriptor.displayName;
      expect(carried, attachmentDescriptorName(name));
      expect(utf8.encode(carried).length, lessThanOrEqualTo(128));
      expect(carried, startsWith('م'));
    });
  });

  test('the committed message names the attachment, and the copy becomes '
      'the cached file', () async {
    final sender = SendConversationEvents(
      repository: DriftConversationDomainRepository(database),
      protocol: _Protocol(),
      fanout: PairwiseApplicationFanoutAdapter(
        PairwiseFanoutCoordinator(
          store: DriftPairwiseTransportStore(database),
          liveDevices: _Unused(),
          claims: _Unused(),
          crypto: _Unused(),
          clock: clock,
        ),
      ),
      clock: clock,
      attachments: const _NoSweep(),
    );
    final probe = _RowProbe(_SendAttachments(sender), states);
    final uploads = queue(sender: probe);
    final copy = await picked(name: 'minutes.pdf', length: 1000);

    enqueue(uploads, copy, caption: 'for Monday');
    await _until(() => uploads.jobs.isEmpty);

    // The row was there the moment sendAttachments answered.
    expect(probe.rowsWhenCommitted, [AttachmentTransferState.queued]);
    final row =
        (await states.read(testCapability(1)) as Success<AttachmentLocalState?>)
            .value!;
    expect(row.state, AttachmentTransferState.ready);
    expect(row.expiresAt, clock.now().add(const Duration(days: 7)));
    expect(row.descriptor.caption, 'for Monday');
    final cached = await cache.resolve(row.cacheId!);
    expect(cached, isNotNull);
    expect(cached!.path, endsWith('minutes.pdf'));
    expect(await cached.readAsBytes(), List<int>.filled(1000, 7));
    expect(await copy.file.parent.exists(), isFalse);
    expect(holds.live, isEmpty);
    final message = await database.select(database.messages).getSingle();
    expect(message.messageId, row.messageId);
  });

  test('a commit that names no row leaves the copy for the sweep', () async {
    // The fake send commits nothing, so no row names the capability. The
    // copy is not adopted, which would delete it, and nothing holds it.
    final uploads = queue();
    final copy = await picked();

    enqueue(uploads, copy);
    await _until(() => uploads.jobs.isEmpty);

    expect(await copy.file.exists(), isTrue);
    expect(holds.live, isEmpty);
    await cache.sweep(liveOutgoing: holds.live);
    expect(await copy.file.parent.exists(), isFalse);
  });

  group('refuses locally, with no network call,', () {
    test('a bucket the deployment does not publish', () async {
      limits = (buckets: const {65536}, dailyBytes: dailyBytes);
      final uploads = queue();

      final job = enqueue(uploads, await picked(length: 100000));
      await _until(
        () => jobOf(uploads, job.id)?.state == AttachmentUploadState.failed,
      );

      final failed = jobOf(uploads, job.id)!;
      expect(failed.failure, AttachmentUploadFailureKind.tooLarge);
      expect(failed.canRetry, isFalse);
      expect(crypto.pushCalls, 0);
      expect(transport.uploads, isEmpty);
    });

    test('a bucket larger than what is left of today', () async {
      allowance.spent = dailyBytes - 1000;
      final uploads = queue();

      final job = enqueue(uploads, await picked(length: 10));
      await _until(
        () => jobOf(uploads, job.id)?.state == AttachmentUploadState.failed,
      );

      final failed = jobOf(uploads, job.id)!;
      expect(failed.failure, AttachmentUploadFailureKind.allowanceSpent);
      expect(failed.resetsAt, DateTime.utc(2026, 10, 11));
      expect(failed.canRetry, isTrue);
      expect(crypto.pushCalls, 0);
      expect(transport.uploads, isEmpty);
    });
  });

  test('each upload failure gives its kind', () async {
    final cases = <(Failure, AttachmentUploadFailureKind)>[
      (
        const BackendFailure(BackendFailureCode.quotaExceeded),
        AttachmentUploadFailureKind.allowanceSpent,
      ),
      (
        const BackendFailure(BackendFailureCode.payloadTooLarge),
        AttachmentUploadFailureKind.tooLarge,
      ),
      (
        const BackendFailure(BackendFailureCode.storageFull),
        AttachmentUploadFailureKind.storageFull,
      ),
      (
        const BackendFailure(BackendFailureCode.throttled),
        AttachmentUploadFailureKind.throttled,
      ),
      (
        const TransportFailure(TransportFailureKind.offline),
        AttachmentUploadFailureKind.offline,
      ),
      (
        const TransportFailure(TransportFailureKind.trustRejected),
        AttachmentUploadFailureKind.failed,
      ),
      (
        const SecurityFailure(SecurityFailureKind.malformedServerResponse),
        AttachmentUploadFailureKind.failed,
      ),
    ];
    for (final (failure, kind) in cases) {
      transport.answer = (_) => Result.failure(failure);
      final uploads = queue();
      final job = enqueue(uploads, await picked());
      await _until(
        () => jobOf(uploads, job.id)?.state == AttachmentUploadState.failed,
        reason: '$kind',
      );

      final failed = jobOf(uploads, job.id)!;
      expect(failed.failure, kind, reason: '$failure');
      expect(failed.descriptor, isNull, reason: '$failure');
      expect(
        failed.resetsAt,
        kind == AttachmentUploadFailureKind.allowanceSpent
            ? DateTime.utc(2026, 10, 11)
            : isNull,
      );
      expect(messages.sent, isEmpty);
      await uploads.close();
    }
  });

  test('a failure after the upload keeps the descriptor, and Retry does not '
      'upload again', () async {
    messages.answers.add(
      const Result.failure(StorageFailure(StorageFailureKind.unavailable)),
    );
    final uploads = queue();
    final copy = await picked();

    final job = enqueue(uploads, copy);
    await _until(
      () => jobOf(uploads, job.id)?.state == AttachmentUploadState.failed,
    );

    final failed = jobOf(uploads, job.id)!;
    expect(failed.failure, AttachmentUploadFailureKind.failed);
    expect(failed.descriptor?.capabilityId, testCapability(1));
    expect(transport.uploads, hasLength(1));
    expect(await copy.file.exists(), isTrue);
    expect(holds.live, [copy.file]);

    uploads.retry(job.id);
    await _until(() => uploads.jobs.isEmpty);

    expect(transport.uploads, hasLength(1));
    expect(crypto.pushCalls, 1);
    expect(messages.sent, hasLength(2));
    expect(
      messages.sent.last.descriptor.capabilityId,
      messages.sent.first.descriptor.capabilityId,
    );
  });

  test('a retry of a refusal runs the checks again', () async {
    allowance.spent = dailyBytes;
    final uploads = queue();
    final job = enqueue(uploads, await picked());
    await _until(
      () => jobOf(uploads, job.id)?.state == AttachmentUploadState.failed,
    );

    // The day turns, and the allowance with it.
    clock.now_ = DateTime.utc(2026, 10, 11, 0, 5);
    uploads.retry(job.id);
    await _until(() => uploads.jobs.isEmpty);

    expect(transport.uploads, [65536]);
    expect(messages.sent, hasLength(1));
  });

  group('cancel', () {
    test('during encryption deletes the copy and the job', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      crypto.beforePush = () {
        if (!started.isCompleted) {
          started.complete();
        }
        return release.future;
      };
      final uploads = queue();
      final copy = await picked(length: 200000);

      final job = enqueue(uploads, copy);
      await started.future;
      expect(jobOf(uploads, job.id)!.state, AttachmentUploadState.encrypting);
      await uploads.cancel(job.id);
      release.complete();
      await _until(() => uploads.jobs.isEmpty);

      await _until(() => !copy.file.parent.existsSync());
      expect(transport.uploads, isEmpty);
      expect(messages.sent, isEmpty);
      expect(holds.live, isEmpty);
    });

    test('during upload deletes the copy and the job', () async {
      transport.gate = Completer<void>();
      final uploads = queue();
      final copy = await picked();

      final job = enqueue(uploads, copy);
      await _until(
        () => jobOf(uploads, job.id)?.state == AttachmentUploadState.uploading,
      );
      await uploads.cancel(job.id);
      await _until(() => uploads.jobs.isEmpty);

      await _until(() => !copy.file.parent.existsSync());
      expect(transport.cancelled, 1);
      expect(messages.sent, isEmpty);
      expect(holds.live, isEmpty);
    });

    test('of a waiting job deletes it at once', () async {
      transport.gate = Completer<void>();
      final uploads = queue();
      final first = enqueue(uploads, await picked());
      final waiting = await picked();
      final second = enqueue(uploads, waiting);
      await _until(
        () =>
            jobOf(uploads, first.id)?.state == AttachmentUploadState.uploading,
      );

      await uploads.cancel(second.id);

      expect(jobOf(uploads, second.id), isNull);
      expect(await waiting.file.parent.exists(), isFalse);
      transport.gate!.complete();
      await _until(() => uploads.jobs.isEmpty);
      expect(transport.uploads, hasLength(1));
    });

    test('after the commit has started has no effect', () async {
      messages.gate = Completer<void>();
      final uploads = queue();
      final job = enqueue(uploads, await picked());
      await _until(
        () => jobOf(uploads, job.id)?.state == AttachmentUploadState.sending,
      );

      await uploads.cancel(job.id);
      expect(jobOf(uploads, job.id)!.state, AttachmentUploadState.sending);

      messages.gate!.complete();
      await _until(() => uploads.jobs.isEmpty);
      expect(messages.sent, hasLength(1));
    });
  });

  test('discard deletes a failed job and its copy', () async {
    limits = (buckets: const {65536}, dailyBytes: dailyBytes);
    final uploads = queue();
    final copy = await picked(length: 100000);
    final job = enqueue(uploads, copy);
    await _until(
      () => jobOf(uploads, job.id)?.state == AttachmentUploadState.failed,
    );

    await uploads.discard(job.id);

    expect(uploads.jobs, isEmpty);
    expect(await copy.file.parent.exists(), isFalse);
    expect(holds.live, isEmpty);
  });

  test('the end of the session cancels each job and deletes each copy, an '
      'open preview step too', () async {
    transport.gate = Completer<void>();
    final uploads = queue();
    final running = await picked(name: 'running.pdf');
    final waiting = await picked(name: 'waiting.pdf');
    final preview = await picked(name: 'preview.pdf');
    platform.enqueuePick(Result.success(preview));
    final emitted = <List<AttachmentUploadJob>>[];
    final watching = uploads.watch('c-1').listen(emitted.add);
    addTearDown(watching.cancel);

    final first = enqueue(uploads, running);
    enqueue(uploads, waiting);
    expect(
      await uploads.pick(AttachmentPickKind.file),
      isA<Success<PickedAttachment>>(),
    );
    await _until(
      () => jobOf(uploads, first.id)?.state == AttachmentUploadState.uploading,
    );

    await uploads.close();
    await _until(() => transport.cancelled == 1);

    expect(uploads.jobs, isEmpty);
    expect(emitted.last, isEmpty);
    for (final copy in [running, waiting, preview]) {
      expect(await copy.file.parent.exists(), isFalse, reason: copy.file.path);
    }
    expect(holds.live, isEmpty);
    expect(messages.sent, isEmpty);
    expect(
      uploads.enqueue(
        conversationId: 'c-1',
        target: const AttachmentUploadTarget.saved(),
        attachment: await picked(),
      ),
      isA<FailureResult<AttachmentUploadJob>>(),
    );
  });

  group('the preview step', () {
    test('a pick asks for the limit of the largest usable bucket, after the '
        'first sweep, and holds the copy', () async {
      final stray = File(
        [
          root.path,
          'outgoing',
          'ab' * 16,
          'old.pdf',
        ].join(Platform.pathSeparator),
      );
      await stray.parent.create(recursive: true);
      await stray.writeAsString('left by a process that died');
      final answer = Completer<Result<PickedAttachment>>();
      platform.enqueuePick(answer.future);
      final uploads = queue();

      final picking = uploads.pick(AttachmentPickKind.photo);
      await _until(() => platform.picks.isNotEmpty);
      expect(holds.pickOpen, isTrue);
      expect(await stray.parent.exists(), isFalse);
      // The picker writes its copy while it is open.
      final copy = await picked();
      answer.complete(Result.success(copy));
      final result = await picking;

      expect((result as Success<PickedAttachment>).value, same(copy));
      expect(platform.picks.single.kind, AttachmentPickKind.photo);
      expect(
        platform.picks.single.maxBytes,
        attachmentPlaintextLimit(67108864),
      );
      expect(holds.pickOpen, isFalse);
      expect(holds.live, [copy.file]);
      // The sweep after a deletion keeps it.
      await cache.sweep(liveOutgoing: holds.live);
      expect(await copy.file.exists(), isTrue);

      await uploads.discardPreview(copy);
      expect(await copy.file.parent.exists(), isFalse);
      expect(holds.live, isEmpty);
    });

    test('the limit follows the buckets the deployment publishes', () async {
      limits = (buckets: const {65536, 262144, 999}, dailyBytes: dailyBytes);
      final uploads = queue();

      await uploads.pick(AttachmentPickKind.file);

      expect(platform.picks.single.maxBytes, attachmentPlaintextLimit(262144));
      expect(holds.live, isEmpty);
    });

    test(
      'a quote gives the sizes, the remainder and the turn of the day',
      () async {
        allowance.spent = dailyBytes - 100000;
        final uploads = queue();

        final fits = await uploads.quote(await picked(length: 1000));
        final over = await uploads.quote(await picked(length: 200000));

        expect(fits.fileBytes, 1000);
        expect(fits.uploadBytes, 65536);
        expect(fits.remainingBytes, 100000);
        expect(fits.sendable, isTrue);
        expect(fits.resetsAt, DateTime.utc(2026, 10, 11));
        expect(over.uploadBytes, 262144);
        expect(over.overRemainder, isTrue);
        expect(over.sendable, isFalse);
      },
    );

    test('a caption above either limit is refused', () async {
      final uploads = queue();
      final copy = await picked();

      Result<AttachmentUploadJob> send(String caption) => uploads.enqueue(
        conversationId: 'c-1',
        target: const AttachmentUploadTarget.saved(),
        attachment: copy,
        caption: caption,
      );

      expect(send('x' * 1025), isA<FailureResult<AttachmentUploadJob>>());
      // 1,020 emoji are within the characters and past the bytes.
      expect(
        send('\u{1F600}' * 1020),
        isA<FailureResult<AttachmentUploadJob>>(),
      );
      expect(uploads.jobs, isEmpty);
      expect(send('x' * 1024), isA<Success<AttachmentUploadJob>>());
    });
  });

  test("a job's text names its state and nothing else", () async {
    final copy = await picked(name: 'secret-plan.pdf');
    final job = enqueue(queue(), copy, caption: 'private caption');

    expect(job.toString(), 'AttachmentUploadJob(waiting)');
    expect(job.attachment.toString(), isNot(contains('secret')));
    expect(job.target.toString(), isNot(contains(peerUserId)));
  });
}

Future<void> _until(bool Function() condition, {String? reason}) async {
  for (var attempt = 0; attempt < 600; attempt += 1) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting${reason == null ? '' : ' for $reason'}');
}

final class _Clock implements TimeSource {
  _Clock(this.now_);

  // ignore: non_constant_identifier_names
  DateTime now_;

  @override
  DateTime now() => now_;
}

/// What the day of the tests, 2026-10-10 UTC, has spent.
final class _Allowance implements AttachmentAllowancePort {
  int spent = 0;

  @override
  Future<AttachmentDailyAllowance> read(DateTime now) async =>
      AttachmentDailyAllowance(
        day: DateTime.utc(2026, 10, 10),
        spentBytes: spent,
      );

  @override
  Future<void> record({required int bytes, required DateTime now}) async =>
      spent += bytes;
}

/// Answers every upload with a new capability, after [gate] when one is set.
final class _Transport implements AttachmentTransportPort {
  final uploads = <int>[];
  var cancelled = 0;
  Completer<void>? gate;
  Result<AttachmentUploadResponse> Function(int bucket)? answer;

  @override
  Future<Result<AttachmentUploadResponse>> upload({
    required File encryptedFile,
    required int bucketSize,
    CancellationSignal? cancellation,
    void Function(int sent, int total)? onProgress,
  }) async {
    uploads.add(bucketSize);
    expect(await encryptedFile.length(), bucketSize);
    final total = bucketSize + 200;
    onProgress?.call(0, total);
    final waiting = gate;
    if (waiting != null) {
      final stopped = Completer<void>();
      final subscription = cancellation?.whenCancelled.listen((_) {
        if (!stopped.isCompleted) {
          stopped.complete();
        }
      });
      await Future.any([waiting.future, stopped.future]);
      await subscription?.cancel();
      if (cancellation?.isCancelled ?? false) {
        cancelled += 1;
        return const Result.failure(
          CancellationFailure(CancellationFailureKind.requestedByUser),
        );
      }
    }
    onProgress?.call(total ~/ 2, total);
    onProgress?.call(total, total);
    return answer?.call(bucketSize) ??
        Result.success(
          AttachmentUploadResponse(
            capabilityId: testCapability(uploads.length),
            bucketSize: bucketSize,
          ),
        );
  }

  @override
  Future<Result<File>> download({
    required String capabilityId,
    required int expectedBucketSize,
    CancellationSignal? cancellation,
    void Function(int bytes)? onProgress,
  }) => throw UnimplementedError('this test only uploads');
}

typedef _Sent = ({
  AttachmentUploadTarget target,
  AttachmentDescriptor descriptor,
  String? caption,
  bool imageMessage,
});

/// Records each message, and commits nothing.
final class _Messages implements AttachmentMessagePort {
  final sent = <_Sent>[];
  final answers = <Result<void>>[];
  Completer<void>? gate;

  @override
  Future<Result<void>> send({
    required AttachmentUploadTarget target,
    required AttachmentDescriptor descriptor,
    required String? caption,
    required bool imageMessage,
  }) async {
    sent.add((
      target: target,
      descriptor: descriptor,
      caption: caption,
      imageMessage: imageMessage,
    ));
    await gate?.future;
    return answers.isEmpty ? const Result.success(null) : answers.removeAt(0);
  }
}

/// The send path the application composes: `sendAttachments` of the session.
final class _SendAttachments implements AttachmentMessagePort {
  const _SendAttachments(this.sender);

  final SendConversationEvents sender;

  @override
  Future<Result<void>> send({
    required AttachmentUploadTarget target,
    required AttachmentDescriptor descriptor,
    required String? caption,
    required bool imageMessage,
  }) async {
    final sent = await sender.sendAttachments(
      currentUserId: localUserId,
      currentDeviceId: localDeviceId,
      target: DirectConversationTarget(target.peerUserId!),
      attachments: [descriptor],
      caption: caption,
      imageMessage: imageMessage,
    );
    return sent.fold(
      onSuccess: (_) => const Result.success(null),
      onFailure: Result.failure,
    );
  }
}

/// Reads the attachment's row the moment the send answers.
final class _RowProbe implements AttachmentMessagePort {
  _RowProbe(this.inner, this.states);

  final AttachmentMessagePort inner;
  final AttachmentLocalStatePort states;
  final rowsWhenCommitted = <AttachmentTransferState?>[];

  @override
  Future<Result<void>> send({
    required AttachmentUploadTarget target,
    required AttachmentDescriptor descriptor,
    required String? caption,
    required bool imageMessage,
  }) async {
    final sent = await inner.send(
      target: target,
      descriptor: descriptor,
      caption: caption,
      imageMessage: imageMessage,
    );
    final row = await states.read(descriptor.capabilityId);
    rowsWhenCommitted.add((row as Success<AttachmentLocalState?>).value?.state);
    return sent;
  }
}

final class _Protocol implements ApplicationProtocolPort {
  var _events = 0;

  @override
  Future<Result<Uint8List>> encode(ApplicationEventRecord event) async =>
      Result.success(Uint8List.fromList([1, 2, 3, ...event.eventId]));

  @override
  Future<Result<DecodedApplicationEvent>> decode(Uint8List bytes) =>
      throw UnimplementedError('this test only sends');

  @override
  Future<Result<Uint8List>> generateEventId() async {
    _events += 1;
    return Result.success(seededBytes(40 + _events, 16));
  }

  @override
  Future<Result<Uint8List>> deriveDirectConversationId({
    required Uint8List firstUserId,
    required Uint8List secondUserId,
  }) async => Result.success(seededBytes(9, 32));

  @override
  Future<Result<Uint8List>> deriveSavedConversationId(Uint8List userId) async =>
      Result.success(seededBytes(10, 32));
}

final class _NoSweep implements AttachmentSweepPort {
  const _NoSweep();

  @override
  Future<void> sweepAfterDeletion() async {}
}

final class _Unused
    implements
        PairwiseLiveDeviceResolverPort,
        PairwiseSelectiveClaimPort,
        PairwiseOutboundPreparationPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
