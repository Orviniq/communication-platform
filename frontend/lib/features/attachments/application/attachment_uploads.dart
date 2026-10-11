import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_crypto_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_outgoing_holds.dart';
import 'package:communication_platform/features/attachments/application/attachment_transfer_service.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_platform_port.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_upload_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_cache_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';

/// The deployment's numbers an upload is measured against: the exact upload
/// sizes it takes, and its daily allowance in bytes.
typedef AttachmentUploadLimits = ({Set<int> buckets, int dailyBytes});

/// The uploads of one session, in memory (ADR-089 D5, D6).
///
/// A job holds one picked file on its way to a committed message. Jobs run
/// one at a time, the oldest first. A job:
///
/// 1. waits for the file cache's first sweep;
/// 2. checks that its bucket is one the deployment publishes and is not
///    larger than what is left of today, and fails with no network call when
///    either is not so;
/// 3. encrypts and uploads the outgoing copy (`createAndUpload`);
/// 4. commits the message with the one descriptor (`sendAttachments`);
/// 5. hands the outgoing copy to the cache as this device's copy of the file,
///    whose row the commit made.
///
/// A job that finished leaves the list, and so does a cancelled one, whose
/// copy is deleted. A failure after the upload keeps the descriptor, so Retry
/// commits the message again without a second upload: an upload is not
/// idempotent, and each one stores another copy on the server.
///
/// Nothing is durable. A process that dies drops every job, and the next
/// process's first sweep deletes the copies; the user sends again. The end of
/// the session ([close]) cancels every job and deletes every copy.
///
/// Nothing here logs. A job's `toString` names its state and nothing else.
final class AttachmentUploads {
  AttachmentUploads({
    required this.platform,
    required this.holds,
    required this.limits,
    required this.clock,
    required this.files,
    required this.allowance,
    required this.states,
    required this.transfer,
    required this.messages,
    Random? random,
  }) : _random = random ?? Random.secure();

  final AttachmentPlatformPort platform;
  final AttachmentOutgoingHolds holds;
  final AttachmentUploadLimits Function() limits;
  final TimeSource clock;

  /// The parts of the pipeline, resolved when a job needs them: each belongs
  /// to the session, and some cannot be composed on every device.
  final Future<AttachmentOutgoingFilesPort> Function() files;
  final Future<AttachmentAllowancePort> Function() allowance;
  final Future<AttachmentLocalStatePort> Function() states;
  final Future<AttachmentTransferService> Function() transfer;
  final Future<AttachmentMessagePort> Function() messages;
  final Random _random;

  /// Every job, the oldest first.
  final _jobs = <AttachmentUploadJob>[];

  /// The cancellation of the job that runs, by its id.
  final _signals = <String, CancellationSignal>{};

  /// The copies of open preview steps, which are not jobs yet.
  final _previews = <String, File>{};

  final _changes = StreamController<void>.broadcast();
  var _running = false;
  var _closed = false;

  static const _ended = CancellationFailure(
    CancellationFailureKind.lifecycleInterrupted,
  );

  /// Every job, the oldest first.
  List<AttachmentUploadJob> get jobs => List.unmodifiable(_jobs);

  /// The jobs of [conversationId], the oldest first: the list now, then a new
  /// list each time one of them changes.
  Stream<List<AttachmentUploadJob>> watch(String conversationId) =>
      Stream.multi((controller) {
        var last = _jobsOf(conversationId);
        controller.add(last);
        final subscription = _changes.stream.listen((_) {
          final next = _jobsOf(conversationId);
          if (!_sameJobs(last, next)) {
            last = next;
            controller.add(next);
          }
        }, onDone: controller.close);
        controller.onCancel = subscription.cancel;
      });

  /// Lets the user choose a file of [kind], and answers its outgoing copy for
  /// a preview step.
  ///
  /// The limit is the largest plaintext that fits the largest bucket both the
  /// deployment and the crypto protocol hold. The cache's first sweep runs
  /// before the picker opens, and no sweep runs while it is open, because
  /// until it answers nothing holds the copy it writes. The copy is held from
  /// the answer on, until [enqueue] or [discardPreview].
  Future<Result<PickedAttachment>> pick(AttachmentPickKind kind) async {
    if (_closed) {
      return const Result.failure(_ended);
    }
    final limit = pickLimit();
    if (limit == null) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    try {
      final outgoing = await files();
      await outgoing.beforeTransfer(liveOutgoing: holds.live);
    } on Object {
      // No private cache, or a session that ended: nowhere to copy to.
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    holds.beginPick();
    final Result<PickedAttachment> picked;
    try {
      picked = await platform.pick(kind: kind, maxBytes: limit);
    } finally {
      holds.endPick();
    }
    if (picked case Success(:final value)) {
      if (_closed) {
        await _discard(value.file);
        return const Result.failure(_ended);
      }
      holds.hold(value.file);
      _previews[value.file.path] = value.file;
    }
    return picked;
  }

  /// The most bytes a pick takes now: the largest plaintext that fits the
  /// largest bucket both the deployment and the crypto protocol hold, or null
  /// when they share none.
  int? pickLimit() {
    final bucket = largestUsableAttachmentBucket(limits().buckets);
    return bucket == null ? null : attachmentPlaintextLimit(bucket);
  }

  /// What the upload of [attachment] costs, and what is left of today.
  Future<AttachmentUploadQuote> quote(PickedAttachment attachment) async {
    final now = clock.now();
    final current = limits();
    final bucket = attachmentUploadBucket(attachment.length);
    var remaining = current.dailyBytes;
    try {
      remaining = (await (await allowance()).read(
        now,
      )).remaining(dailyBytes: current.dailyBytes, now: now);
    } on Object {
      // No database: the count this device keeps is a lower bound anyway,
      // and the server refuses what does not fit.
    }
    return AttachmentUploadQuote(
      fileBytes: attachment.length,
      uploadBytes: bucket,
      published: bucket != null && current.buckets.contains(bucket),
      remainingBytes: remaining,
      resetsAt: allowanceResetsAt(now),
    );
  }

  /// Deletes the copy of a preview step the user cancelled.
  Future<void> discardPreview(PickedAttachment attachment) async {
    _previews.remove(attachment.file.path);
    holds.release(attachment.file);
    await _discard(attachment.file);
  }

  /// Adds a job for [attachment] with [caption], which the preview step
  /// [pick] answered, and starts it when no other job runs.
  ///
  /// Refuses a caption above [AttachmentCaptionLimits]: the descriptor would
  /// refuse it after the upload. [caption] is trimmed, and an empty one is
  /// none.
  Result<AttachmentUploadJob> enqueue({
    required String conversationId,
    required AttachmentUploadTarget target,
    required PickedAttachment attachment,
    String? caption,
  }) {
    if (_closed) {
      return const Result.failure(_ended);
    }
    final carried = attachmentCaptionOf(caption);
    if (attachmentCaptionProblem(attachment, carried) != null) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    _previews.remove(attachment.file.path);
    holds.hold(attachment.file);
    final job = AttachmentUploadJob(
      id: newAttachmentCacheId(_random),
      conversationId: conversationId,
      target: target,
      attachment: attachment,
      caption: carried,
      state: AttachmentUploadState.waiting,
    );
    _jobs.add(job);
    _emit();
    _pump();
    return Result.success(job);
  }

  /// Stops job [id]: at once when it waits or failed, and at its next check
  /// when it runs. Its copy is deleted. A job that is committing its message
  /// is past the point a cancel can undo, and runs on.
  Future<void> cancel(String id) async {
    final job = _job(id);
    if (job == null || job.state == AttachmentUploadState.sending) {
      return;
    }
    final signal = _signals[id];
    if (signal != null) {
      signal.cancel();
      return;
    }
    await _drop(id);
  }

  /// Puts failed job [id] back in the queue, when its failure allows a retry.
  /// A job that keeps its descriptor commits the message without uploading
  /// again.
  void retry(String id) {
    final job = _job(id);
    if (job == null || !job.canRetry || _closed) {
      return;
    }
    _set(
      id,
      job.copyWith(
        state: AttachmentUploadState.waiting,
        progress: 0,
        clearFailure: true,
      ),
    );
    _pump();
  }

  /// Deletes failed or waiting job [id] and its copy. A running job is
  /// cancelled instead.
  Future<void> discard(String id) => cancel(id);

  /// Ends the queue with its session: every job is cancelled and every copy,
  /// a preview step's too, is deleted. Nothing can be added afterwards.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final signal in _signals.values) {
      signal.cancel();
    }
    final copies = [
      for (final job in _jobs) job.attachment.file,
      ..._previews.values,
    ];
    _jobs.clear();
    _previews.clear();
    for (final copy in copies) {
      holds.release(copy);
    }
    _emit();
    await _changes.close();
    for (final copy in copies) {
      await _discard(copy);
    }
  }

  void _pump() {
    if (_closed || _running) {
      return;
    }
    final next = _jobs
        .where((job) => job.state == AttachmentUploadState.waiting)
        .firstOrNull;
    if (next == null) {
      return;
    }
    _running = true;
    unawaited(
      _run(next.id).whenComplete(() {
        _running = false;
        _pump();
      }),
    );
  }

  Future<void> _run(String id) async {
    final signal = CancellationSignal();
    _signals[id] = signal;
    try {
      await _attempt(id, signal);
    } on Object {
      // A part of the pipeline that could not be composed, or one that threw
      // where it should have answered a failure.
      if (!_closed) {
        _fail(id, AttachmentUploadFailureKind.failed);
      }
    } finally {
      _signals.remove(id);
    }
  }

  Future<void> _attempt(String id, CancellationSignal signal) async {
    final job = _job(id);
    if (job == null) {
      return;
    }
    final outgoing = await files();
    final descriptor = job.descriptor ?? await _upload(outgoing, job, signal);
    if (descriptor == null || await _stopped(id, signal)) {
      return;
    }
    _update(
      id,
      (current) =>
          current.copyWith(state: AttachmentUploadState.sending, progress: 1),
    );
    final sender = await messages();
    final sent = await sender.send(
      target: job.target,
      descriptor: descriptor,
      caption: job.caption,
      imageMessage: descriptor.isInlineImage,
    );
    if (sent case FailureResult()) {
      if (!_closed) {
        _fail(id, AttachmentUploadFailureKind.failed);
      }
      return;
    }
    // Committed: the message is in the timeline, and this job is done. Nothing
    // after this point may fail the job, or a retry would send it twice.
    if (!_closed) {
      await _adopt(outgoing, job.attachment.file, descriptor);
    }
    _jobs.removeWhere((candidate) => candidate.id == id);
    _emit();
  }

  /// Checks, encrypts and uploads [job], and answers its descriptor, or null
  /// when the job failed or stopped.
  Future<AttachmentDescriptor?> _upload(
    AttachmentOutgoingFilesPort outgoing,
    AttachmentUploadJob job,
    CancellationSignal signal,
  ) async {
    final id = job.id;
    await outgoing.beforeTransfer(liveOutgoing: holds.live);
    if (await _stopped(id, signal) || await _refusedLocally(job)) {
      return null;
    }
    _update(
      id,
      (current) => current.copyWith(state: AttachmentUploadState.encrypting),
    );
    final service = await transfer();
    if (await _stopped(id, signal)) {
      return null;
    }
    final uploaded = await service.createAndUpload(
      source: _sourceOf(job.attachment),
      caption: job.caption,
      cancellation: signal,
      onProgress: (progress) => _progress(id, progress),
    );
    // A cancel that arrived after the bytes left still drops the job. The
    // server keeps that copy until it expires: there is no delete.
    if (await _stopped(id, signal)) {
      return null;
    }
    switch (uploaded) {
      case FailureResult(:final failure):
        _failFor(id, failure);
        return null;
      case Success(:final value):
        _update(id, (current) => current.copyWith(descriptor: value));
        return value;
    }
  }

  /// Whether the job stops here: the queue closed, which already deleted
  /// everything, or the job was cancelled, which deletes it and its copy now.
  Future<bool> _stopped(String id, CancellationSignal signal) async {
    if (_closed) {
      return true;
    }
    if (!signal.isCancelled) {
      return false;
    }
    await _drop(id);
    return true;
  }

  /// Fails [job] with no network call when the deployment takes no upload of
  /// its size or today has no room for it.
  Future<bool> _refusedLocally(AttachmentUploadJob job) async {
    final current = limits();
    final bucket = attachmentUploadBucket(job.attachment.length);
    if (bucket == null || !current.buckets.contains(bucket)) {
      _fail(job.id, AttachmentUploadFailureKind.tooLarge);
      return true;
    }
    final now = clock.now();
    final left = (await (await allowance()).read(
      now,
    )).remaining(dailyBytes: current.dailyBytes, now: now);
    if (bucket > left) {
      _fail(
        job.id,
        AttachmentUploadFailureKind.allowanceSpent,
        resetsAt: allowanceResetsAt(now),
      );
      return true;
    }
    if (attachmentCaptionProblem(job.attachment, job.caption) != null) {
      _fail(job.id, AttachmentUploadFailureKind.failed);
      return true;
    }
    return false;
  }

  /// Hands [copy] to the cache as the sender's copy of [descriptor]'s file.
  ///
  /// The commit wrote the message and its projection before it answered
  /// (ADR-061), so the attachment's row is there to mark. Should it not be,
  /// the copy is not adopted: it stays where it is, held by nothing, for the
  /// next sweep, because adopting it would delete it the moment the row
  /// could not be marked.
  ///
  /// A failure here leaves the copy to the sweep too, and never fails the
  /// job: its message is already committed.
  Future<void> _adopt(
    AttachmentOutgoingFilesPort outgoing,
    File copy,
    AttachmentDescriptor descriptor,
  ) async {
    try {
      final row = await (await states()).read(descriptor.capabilityId);
      if (row case Success(value: _?)) {
        await outgoing.adoptOutgoing(
          attachmentId: descriptor.capabilityId,
          copy: copy,
        );
      }
    } on Object {
      // The copy stays for the sweep, as when the row is missing.
    } finally {
      holds.release(copy);
    }
  }

  void _progress(String id, AttachmentProgress progress) {
    final state = switch (progress.state) {
      AttachmentTransferState.encrypting => AttachmentUploadState.encrypting,
      AttachmentTransferState.uploading => AttachmentUploadState.uploading,
      _ => null,
    };
    final job = _job(id);
    if (state == null || job == null) {
      return;
    }
    // Whole percents: a 64 MiB file reports a thousand chunks, and the tray
    // needs only a hundred steps.
    final fraction = (progress.fraction * 100).floor() / 100;
    if (job.state == state && job.progress == fraction) {
      return;
    }
    _set(id, job.copyWith(state: state, progress: fraction));
  }

  void _failFor(String id, Failure failure) {
    final kind = switch (failure) {
      BackendFailure(code: BackendFailureCode.quotaExceeded) =>
        AttachmentUploadFailureKind.allowanceSpent,
      BackendFailure(
        code: BackendFailureCode.payloadTooLarge ||
            BackendFailureCode.badBucket,
      ) ||
      ValidationFailure(
        kind: ValidationFailureKind.limitExceeded,
      ) => AttachmentUploadFailureKind.tooLarge,
      BackendFailure(code: BackendFailureCode.storageFull) =>
        AttachmentUploadFailureKind.storageFull,
      BackendFailure(code: BackendFailureCode.throttled) =>
        AttachmentUploadFailureKind.throttled,
      // A refused certificate is a security result, never "no connection".
      TransportFailure(kind: final transport)
          when transport != TransportFailureKind.trustRejected =>
        AttachmentUploadFailureKind.offline,
      _ => AttachmentUploadFailureKind.failed,
    };
    _fail(
      id,
      kind,
      resetsAt: kind == AttachmentUploadFailureKind.allowanceSpent
          ? allowanceResetsAt(clock.now())
          : null,
    );
  }

  void _fail(
    String id,
    AttachmentUploadFailureKind kind, {
    DateTime? resetsAt,
  }) => _update(
    id,
    (job) => job.copyWith(
      state: AttachmentUploadState.failed,
      progress: 0,
      failure: kind,
      resetsAt: resetsAt,
    ),
  );

  /// Removes job [id] and deletes its copy.
  Future<void> _drop(String id) async {
    final job = _job(id);
    if (job == null) {
      return;
    }
    _jobs.removeWhere((candidate) => candidate.id == id);
    holds.release(job.attachment.file);
    _emit();
    await _discard(job.attachment.file);
  }

  Future<void> _discard(File copy) async {
    try {
      await (await files()).discardOutgoing(copy);
    } on Object {
      // No cache to ask: the next process's first sweep deletes the copy, and
      // the wipe at logout deletes the whole cache.
    }
  }

  AttachmentSource _sourceOf(PickedAttachment attachment) => AttachmentSource(
    length: attachment.length,
    displayName: attachmentDescriptorName(attachment.displayName),
    mimeType: attachment.mimeType,
    openRead: attachment.file.openRead,
    mediaKind: attachment.mediaKind,
    width: attachment.width,
    height: attachment.height,
  );

  AttachmentUploadJob? _job(String id) =>
      _jobs.where((job) => job.id == id).firstOrNull;

  void _update(
    String id,
    AttachmentUploadJob Function(AttachmentUploadJob job) change,
  ) {
    final job = _job(id);
    if (job != null) {
      _set(id, change(job));
    }
  }

  void _set(String id, AttachmentUploadJob job) {
    final index = _jobs.indexWhere((candidate) => candidate.id == id);
    if (index < 0) {
      return;
    }
    _jobs[index] = job;
    _emit();
  }

  void _emit() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  List<AttachmentUploadJob> _jobsOf(String conversationId) => List.unmodifiable(
    _jobs.where((job) => job.conversationId == conversationId),
  );

  static bool _sameJobs(
    List<AttachmentUploadJob> left,
    List<AttachmentUploadJob> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (!identical(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }

  @override
  String toString() => 'AttachmentUploads(<redacted>)';
}
