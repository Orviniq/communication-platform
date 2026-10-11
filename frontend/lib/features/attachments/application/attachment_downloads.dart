import 'dart:async';
import 'dart:io';

import 'package:communication_platform/core/application/cancellation_signal.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_crypto_service.dart';
import 'package:communication_platform/features/attachments/application/attachment_outgoing_holds.dart';
import 'package:communication_platform/features/attachments/application/attachment_transfer_service.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_download_ports.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_transfer_ports.dart';
import 'package:communication_platform/features/attachments/domain/attachment_download_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';

/// The downloads of one session, in memory (ADR-089 D7, D8, D9).
///
/// A job fetches one received attachment the user tapped, then verifies and
/// decrypts it. There is one job for each attachment id, the jobs run one at
/// a time, the oldest first, and none starts without a tap. A job:
///
/// 1. waits for the file cache's first sweep;
/// 2. stops with no network call when the attachment's row is gone, its
///    message deleted, or says the server copy expired;
/// 3. downloads, verifies and decrypts (`downloadAndDecrypt`);
/// 4. hands the decrypted file to the cache, which marks the row `ready`
///    with an expiry seven days on and then holds its bound.
///
/// What a job that did not finish leaves:
///
/// | Outcome | The row | The job |
/// |---|---|---|
/// | `404`, or a tag that moved: the server copy is gone | `expired` | leaves |
/// | bytes that arrived and did not verify | not downloaded | *damaged* |
/// | anything else the download met | not downloaded | *failed* |
/// | a cancel, or the end of the session | not downloaded | leaves |
///
/// A damaged or failed job stays until a [retry], or until the process ends.
/// No decrypted file outlives a job that did not finish, and none outlives one
/// whose message was deleted while it ran.
///
/// Nothing here logs. A job's `toString` names its state and nothing else.
final class AttachmentDownloads {
  AttachmentDownloads({
    required this.holds,
    required this.files,
    required this.states,
    required this.transfer,
  });

  /// The outgoing copies of the process, which the first sweep must keep.
  final AttachmentOutgoingHolds holds;

  /// The parts of the pipeline, resolved when a job needs them: each belongs
  /// to the session, and some cannot be composed on every device.
  final Future<AttachmentDecryptedFilesPort> Function() files;
  final Future<AttachmentLocalStatePort> Function() states;
  final Future<AttachmentTransferService> Function() transfer;

  /// Every job, the oldest first.
  final _jobs = <AttachmentDownloadJob>[];

  /// The cancellation of the job that runs, by its attachment id.
  final _signals = <String, CancellationSignal>{};

  final _changes = StreamController<void>.broadcast();
  var _running = false;
  var _closed = false;

  /// Every job, the oldest first.
  List<AttachmentDownloadJob> get jobs => List.unmodifiable(_jobs);

  /// The job of [attachmentId], or null when it has none.
  AttachmentDownloadJob? jobOf(String attachmentId) =>
      _jobs.where((job) => job.attachmentId == attachmentId).firstOrNull;

  /// The job of [attachmentId]: now, then each time it changes, and null
  /// while it has none.
  ///
  /// One attachment's stream is told nothing of another's change, so a
  /// percent that moves redraws one tile.
  Stream<AttachmentDownloadJob?> watch(String attachmentId) =>
      Stream.multi((controller) {
        var last = jobOf(attachmentId);
        controller.add(last);
        final subscription = _changes.stream.listen((_) {
          final next = jobOf(attachmentId);
          if (!identical(last, next)) {
            last = next;
            controller.add(next);
          }
        }, onDone: controller.close);
        controller.onCancel = subscription.cancel;
      });

  /// Adds a job for [descriptor], carried by message [messageId], and starts
  /// it when no other job runs.
  ///
  /// Does nothing when the attachment already has a job, whatever its state:
  /// a failed or damaged one comes back through [retry].
  void download({
    required String messageId,
    required AttachmentDescriptor descriptor,
  }) {
    if (_closed || jobOf(descriptor.capabilityId) != null) {
      return;
    }
    _jobs.add(
      AttachmentDownloadJob(
        messageId: messageId,
        descriptor: descriptor,
        state: AttachmentDownloadState.waiting,
      ),
    );
    _emit();
    _pump();
  }

  /// Puts the failed or damaged job of [attachmentId] back in the queue.
  void retry(String attachmentId) {
    final job = jobOf(attachmentId);
    if (_closed ||
        job == null ||
        (job.state != AttachmentDownloadState.failed &&
            job.state != AttachmentDownloadState.damaged)) {
      return;
    }
    _set(
      attachmentId,
      job.copyWith(state: AttachmentDownloadState.waiting, progress: 0),
    );
    _pump();
  }

  /// Stops the job of [attachmentId]: at once when it waits, failed or was
  /// damaged, and at its next check when it runs. The row stays as it was:
  /// not downloaded.
  ///
  /// The transport keeps what a large download fetched, and the next
  /// download of the same attachment in this session goes on from there
  /// (ADR-083).
  void cancel(String attachmentId) {
    final signal = _signals[attachmentId];
    if (signal != null) {
      signal.cancel();
      return;
    }
    _drop(attachmentId);
  }

  /// The decrypted file of the ready attachment [attachmentId], for Open,
  /// Save or Share, with its expiry moved to seven days from now.
  ///
  /// Null when there is none to give: a file that expired or went missing
  /// returns its row to "not downloaded" here, and so does one the session
  /// has no cache for.
  Future<File?> open(String attachmentId) async {
    if (_closed) {
      return null;
    }
    try {
      return await (await files()).open(attachmentId);
    } on Object {
      return null;
    }
  }

  /// The decrypted file of the ready attachment [attachmentId] as it is, for
  /// a picture shown in its message, or null when there is none. Moves no
  /// expiry and writes nothing.
  Future<File?> peek(String attachmentId) async {
    if (_closed) {
      return null;
    }
    try {
      return await (await files()).peek(attachmentId);
    } on Object {
      return null;
    }
  }

  /// Ends the queue with its session: every job is cancelled, and nothing can
  /// be added afterwards. A job that was running deletes what it decrypted.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    // A cancel can run a job to its end before it returns, and the job then
    // removes its own signal: the loop walks a copy.
    for (final signal in [..._signals.values]) {
      signal.cancel();
    }
    _jobs.clear();
    _emit();
    await _changes.close();
  }

  void _pump() {
    if (_closed || _running) {
      return;
    }
    final next = _jobs
        .where((job) => job.state == AttachmentDownloadState.waiting)
        .firstOrNull;
    if (next == null) {
      return;
    }
    _running = true;
    unawaited(
      _run(next.attachmentId).whenComplete(() {
        _running = false;
        _pump();
      }),
    );
  }

  Future<void> _run(String attachmentId) async {
    final signal = CancellationSignal();
    _signals[attachmentId] = signal;
    try {
      await _attempt(attachmentId, signal);
    } on Object {
      // A part of the pipeline that could not be composed, or one that threw
      // where it should have answered a failure.
      if (!_closed) {
        _settle(attachmentId, AttachmentDownloadState.failed);
      }
    } finally {
      _signals.remove(attachmentId);
    }
  }

  Future<void> _attempt(String attachmentId, CancellationSignal signal) async {
    final job = jobOf(attachmentId);
    if (job == null) {
      return;
    }
    final cache = await files();
    await cache.beforeTransfer(liveOutgoing: holds.live);
    if (_stopped(attachmentId, signal)) {
      return;
    }
    final row = await (await states()).read(attachmentId);
    if (row
        case Success(value: null) ||
            Success(
              value: AttachmentLocalState(
                state: AttachmentTransferState.expired,
              ),
            )) {
      // The message is gone, or the server copy is: nothing to fetch.
      _drop(attachmentId);
      return;
    }
    _update(
      attachmentId,
      (current) => current.copyWith(
        state: AttachmentDownloadState.downloading,
        progress: 0,
      ),
    );
    final service = await transfer();
    if (_stopped(attachmentId, signal)) {
      return;
    }
    final result = await service.downloadAndDecrypt(
      descriptor: job.descriptor,
      cancellation: signal,
      onProgress: (progress) => _progress(attachmentId, progress),
    );
    switch (result) {
      case AttachmentDownloaded(:final file):
        // A cancel that arrived after the last chunk still stops the job,
        // and the file it was too late to stop goes with it.
        if (_stopped(attachmentId, signal)) {
          await service.storage.delete(file);
          return;
        }
        try {
          await _adopt(job, file, cache, service.storage);
        } on Object {
          // Whatever stopped the adoption, the plaintext goes with it.
          await service.storage.delete(file);
          rethrow;
        }
      case AttachmentDownloadFailed(:final failure, :final stage):
        if (_stopped(attachmentId, signal)) {
          return;
        }
        await _fail(job, failure, stage);
    }
  }

  /// Hands [file] to the cache as the decrypted copy of [job]'s attachment.
  ///
  /// The row is read first: a message deleted while the job ran took its row
  /// with it, and its file goes too. Should the row go between this read and
  /// the cache's mark, the cache deletes the file it moved.
  Future<void> _adopt(
    AttachmentDownloadJob job,
    File file,
    AttachmentDecryptedFilesPort cache,
    AttachmentStoragePort storage,
  ) async {
    final attachmentId = job.attachmentId;
    final row = await (await states()).read(attachmentId);
    if (row case Success(value: null)) {
      await storage.delete(file);
      _drop(attachmentId);
      return;
    }
    final adopted = await cache.adoptDecrypted(
      attachmentId: attachmentId,
      file: file,
      name: job.descriptor.displayName,
    );
    if (adopted case FailureResult(:final failure)) {
      // Not moved, or moved and deleted again: either way nothing is kept.
      await storage.delete(file);
      if (failure case ValidationFailure(
        kind: ValidationFailureKind.conflict,
      )) {
        // The row went while the file was moved in: the message is gone.
        _drop(attachmentId);
      } else {
        _settle(attachmentId, AttachmentDownloadState.failed);
      }
      return;
    }
    _drop(attachmentId);
  }

  /// What a download that gave no file leaves, by its [failure] and the
  /// [stage] it came from.
  Future<void> _fail(
    AttachmentDownloadJob job,
    Failure failure,
    AttachmentDownloadStage stage,
  ) async {
    final attachmentId = job.attachmentId;
    switch ((failure, stage)) {
      case (CancellationFailure(), _):
        _drop(attachmentId);
      case (
        BackendFailure(code: BackendFailureCode.notFound),
        AttachmentDownloadStage.download,
      ):
        // The retention sweep deleted it: no download can bring it back, and
        // the row says so from now on.
        await (await states()).markExpired(attachmentId);
        _drop(attachmentId);
      case (StorageFailure(), AttachmentDownloadStage.verification):
        // This device's disk, not the bytes.
        _settle(attachmentId, AttachmentDownloadState.failed);
      case (_, AttachmentDownloadStage.verification):
        _settle(attachmentId, AttachmentDownloadState.damaged);
      case (_, AttachmentDownloadStage.download):
        _settle(attachmentId, AttachmentDownloadState.failed);
    }
  }

  /// Whether the job stops here: the queue closed, which already dropped
  /// every job, or the job was cancelled, which drops it now.
  bool _stopped(String attachmentId, CancellationSignal signal) {
    if (_closed) {
      return true;
    }
    if (!signal.isCancelled) {
      return false;
    }
    _drop(attachmentId);
    return true;
  }

  void _progress(String attachmentId, AttachmentProgress progress) {
    final state = switch (progress.state) {
      AttachmentTransferState.downloading =>
        AttachmentDownloadState.downloading,
      AttachmentTransferState.verifying => AttachmentDownloadState.verifying,
      _ => null,
    };
    final job = jobOf(attachmentId);
    if (state == null || job == null || _closed) {
      return;
    }
    // Whole percents: a 64 MiB file reports a thousand chunks, and a tile
    // needs only a hundred steps.
    final fraction = (progress.fraction * 100).floor() / 100;
    if (job.state == state && job.progress == fraction) {
      return;
    }
    _set(attachmentId, job.copyWith(state: state, progress: fraction));
  }

  void _settle(String attachmentId, AttachmentDownloadState state) =>
      _update(attachmentId, (job) => job.copyWith(state: state, progress: 0));

  void _drop(String attachmentId) {
    final before = _jobs.length;
    _jobs.removeWhere((job) => job.attachmentId == attachmentId);
    if (_jobs.length != before) {
      _emit();
    }
  }

  void _update(
    String attachmentId,
    AttachmentDownloadJob Function(AttachmentDownloadJob job) change,
  ) {
    final job = jobOf(attachmentId);
    if (job != null) {
      _set(attachmentId, change(job));
    }
  }

  void _set(String attachmentId, AttachmentDownloadJob job) {
    final index = _jobs.indexWhere(
      (candidate) => candidate.attachmentId == attachmentId,
    );
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

  @override
  String toString() => 'AttachmentDownloads(<redacted>)';
}
