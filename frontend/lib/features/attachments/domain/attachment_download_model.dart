import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';

/// Where a download job is (ADR-089 D7). Every one lives in memory only
/// (D9): a finished job, an expired attachment and a cancelled job leave the
/// list, and what they leave behind is the row's own state.
enum AttachmentDownloadState {
  /// In the queue, behind the download that runs.
  waiting,

  /// Fetching the ciphertext, with the share of the bucket fetched.
  downloading,

  /// Checking and decrypting what arrived, with the share of the plaintext
  /// checked.
  verifying,

  /// The bytes arrived whole and are not the file the descriptor describes.
  /// Nothing is kept, and fetching the same bytes again would give the same
  /// verdict, so the state stays until a retry or a restart.
  damaged,

  /// The download did not finish: no connection, `429`, a server error, the
  /// server unavailable, a token the server refused, or an answer that broke
  /// the length or the range rules. A retry can clear each of them.
  failed,
}

/// One received attachment on its way from the server to the file cache.
///
/// Immutable: the queue replaces a job to change it. [progress] runs from 0
/// to 1 in the downloading and the verifying state, in whole percents.
final class AttachmentDownloadJob {
  const AttachmentDownloadJob({
    required this.messageId,
    required this.descriptor,
    required this.state,
    this.progress = 0,
  });

  /// The message that carries the attachment. A job whose message is gone
  /// when it ends keeps no file.
  final String messageId;
  final EncryptedAttachmentDescriptor descriptor;
  final AttachmentDownloadState state;
  final double progress;

  /// The attachment's id: its capability, which names its row.
  String get attachmentId => descriptor.capabilityId;

  /// Whether the job is waiting or running, which a cancel stops.
  bool get active =>
      state == AttachmentDownloadState.waiting ||
      state == AttachmentDownloadState.downloading ||
      state == AttachmentDownloadState.verifying;

  AttachmentDownloadJob copyWith({
    AttachmentDownloadState? state,
    double? progress,
  }) => AttachmentDownloadJob(
    messageId: messageId,
    descriptor: descriptor,
    state: state ?? this.state,
    progress: progress ?? this.progress,
  );

  @override
  String toString() => 'AttachmentDownloadJob(${state.name})';
}
