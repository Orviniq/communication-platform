import 'dart:convert';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';

/// The bounds of a caption (ADR-089 D5).
abstract final class AttachmentCaptionLimits {
  /// The most characters a caption has. A character here is a Unicode scalar
  /// value, the unit the protocol reader counts text in.
  static const maximumCharacters = 1024;

  /// The most bytes a descriptor's authenticated metadata has: the name, the
  /// type, the size in pixels, the media kind and the caption, joined.
  static const maximumMetadataBytes =
      AttachmentCryptoProtocolV1.maximumMetadataBytes;

  /// The share of a limit from which a counter is shown.
  static const counterFrom = 0.9;
}

/// The most UTF-8 bytes of a name a descriptor carries.
///
/// The protocol reads a descriptor's name as at most 128 bytes and 128 scalar
/// values, in the Rust core and in this client's own reader. The picker's safe
/// name is at most 128 characters, which is up to 512 bytes, so a longer name
/// would make the core refuse the whole message after the upload.
const attachmentDescriptorNameBytes = 128;

/// The name a descriptor carries for [name]: [safeAttachmentName], cut to
/// [attachmentDescriptorNameBytes] of UTF-8 on whole scalar values.
///
/// The result is its own safe name, so the crypto service, which makes the
/// name safe again, keeps it as it is.
String attachmentDescriptorName(String name) {
  final safe = safeAttachmentName(name);
  if (utf8.encode(safe).length <= attachmentDescriptorNameBytes) {
    return safe;
  }
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in safe.runes) {
    final character = String.fromCharCode(rune);
    bytes += utf8.encode(character).length;
    if (bytes > attachmentDescriptorNameBytes) {
      break;
    }
    buffer.write(character);
  }
  return safeAttachmentName(buffer.toString());
}

/// The characters of [caption], counted as [AttachmentCaptionLimits] counts
/// them.
int attachmentCaptionCharacters(String caption) => caption.runes.length;

/// The caption a message carries for what the user typed: trimmed, and null
/// when nothing is left.
String? attachmentCaptionOf(String? typed) {
  final trimmed = typed?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// The bytes of the authenticated metadata a descriptor of [attachment] with
/// [caption] has, on the formula of
/// `EncryptedAttachmentDescriptor.authenticatedMetadata`.
int attachmentMetadataBytes(PickedAttachment attachment, String? caption) =>
    utf8
        .encode(
          '${attachmentDescriptorName(attachment.displayName)}\u0000'
          '${safeMimeType(attachment.mimeType)}\u0000'
          '${attachment.width ?? 0}\u0000${attachment.height ?? 0}\u0000'
          '${attachment.mediaKind.index}\u0000${caption ?? ''}',
        )
        .length;

/// Why a caption cannot be sent with an attachment.
enum AttachmentCaptionProblem {
  /// More than [AttachmentCaptionLimits.maximumCharacters].
  tooManyCharacters,

  /// The metadata would pass [AttachmentCaptionLimits.maximumMetadataBytes].
  metadataTooLarge,
}

/// What stops [caption] from going with [attachment], or null when nothing
/// does. [caption] is what the message carries ([attachmentCaptionOf]).
AttachmentCaptionProblem? attachmentCaptionProblem(
  PickedAttachment attachment,
  String? caption,
) {
  if (caption != null &&
      attachmentCaptionCharacters(caption) >
          AttachmentCaptionLimits.maximumCharacters) {
    return AttachmentCaptionProblem.tooManyCharacters;
  }
  if (attachmentMetadataBytes(attachment, caption) >
      AttachmentCaptionLimits.maximumMetadataBytes) {
    return AttachmentCaptionProblem.metadataTooLarge;
  }
  return null;
}

/// The bucket [length] bytes of plaintext are uploaded in, or null when no
/// bucket holds them.
int? attachmentUploadBucket(int length) {
  try {
    return attachmentBucketFor(length);
  } on FormatException {
    return null;
  }
}

/// The largest bucket that both [published] and the crypto protocol hold, or
/// null when they share none: the bucket a pick's byte limit comes from.
int? largestUsableAttachmentBucket(Set<int> published) {
  int? largest;
  for (final bucket in published) {
    if (AttachmentCryptoProtocolV1.buckets.contains(bucket) &&
        (largest == null || bucket > largest)) {
      largest = bucket;
    }
  }
  return largest;
}

/// What an upload of one picked file costs, and whether today has room for it
/// (ADR-089 D5, D6).
final class AttachmentUploadQuote {
  const AttachmentUploadQuote({
    required this.fileBytes,
    required this.uploadBytes,
    required this.published,
    required this.remainingBytes,
    required this.resetsAt,
  });

  /// The length of the file.
  final int fileBytes;

  /// The bucket the file is uploaded in, or null when no bucket holds it.
  final int? uploadBytes;

  /// Whether the deployment takes uploads of [uploadBytes].
  final bool published;

  /// What is left of today's allowance on this device's count.
  final int remainingBytes;

  /// When the server's UTC day turns and the allowance is whole again, in
  /// UTC.
  final DateTime resetsAt;

  /// Whether the upload is larger than what is left of today.
  bool get overRemainder {
    final upload = uploadBytes;
    return upload != null && upload > remainingBytes;
  }

  /// Whether the upload can start: a bucket the deployment takes, and room
  /// for it today.
  bool get sendable => uploadBytes != null && published && !overRemainder;

  @override
  String toString() => 'AttachmentUploadQuote(<redacted>)';
}

/// Where the message of an upload goes: a direct chat with [peerUserId], or
/// Saved Messages when it is null.
final class AttachmentUploadTarget {
  const AttachmentUploadTarget.direct(String this.peerUserId);

  const AttachmentUploadTarget.saved() : peerUserId = null;

  final String? peerUserId;

  bool get savedMessages => peerUserId == null;

  @override
  String toString() => 'AttachmentUploadTarget(<redacted>)';
}

/// Where an upload job is (ADR-089 D5). A finished job and a cancelled one
/// leave the list, so neither is a state.
enum AttachmentUploadState { waiting, encrypting, uploading, sending, failed }

/// Why an upload job failed, as the tray names it.
enum AttachmentUploadFailureKind {
  /// Today's allowance has no room for the upload, by this device's count or
  /// by the server's `413 quota_exceeded`.
  allowanceSpent,

  /// The server takes no upload of this size: a bucket the deployment does
  /// not publish, `413 payload_too_large`, or `400 bad_bucket`. A retry would
  /// meet the same answer, so there is none.
  tooLarge,

  /// `503 storage_full`: the server's disk.
  storageFull,

  /// `429 throttled`.
  throttled,

  /// No connection to the server.
  offline,

  /// Anything else, including a message that could not be committed after
  /// the upload.
  failed,
}

/// One attachment on its way from its outgoing copy to a committed message.
///
/// Immutable: the queue replaces a job to change it. [progress] runs from 0
/// to 1 in the encrypting and the uploading state. [descriptor] is set once
/// the upload succeeded, and a retry then only sends the message.
/// [resetsAt] is the UTC turn of the day an [AttachmentUploadFailureKind.allowanceSpent]
/// failure waits for.
final class AttachmentUploadJob {
  const AttachmentUploadJob({
    required this.id,
    required this.conversationId,
    required this.target,
    required this.attachment,
    required this.caption,
    required this.state,
    this.progress = 0,
    this.failure,
    this.descriptor,
    this.resetsAt,
  });

  /// A local random id: it names the job in this process and nowhere else.
  final String id;
  final String conversationId;
  final AttachmentUploadTarget target;
  final PickedAttachment attachment;
  final String? caption;
  final AttachmentUploadState state;
  final double progress;
  final AttachmentUploadFailureKind? failure;
  final AttachmentDescriptor? descriptor;
  final DateTime? resetsAt;

  /// Whether Retry is offered: a failed job the server could take.
  bool get canRetry =>
      state == AttachmentUploadState.failed &&
      failure != AttachmentUploadFailureKind.tooLarge;

  AttachmentUploadJob copyWith({
    AttachmentUploadState? state,
    double? progress,
    AttachmentUploadFailureKind? failure,
    bool clearFailure = false,
    AttachmentDescriptor? descriptor,
    DateTime? resetsAt,
  }) => AttachmentUploadJob(
    id: id,
    conversationId: conversationId,
    target: target,
    attachment: attachment,
    caption: caption,
    state: state ?? this.state,
    progress: progress ?? this.progress,
    failure: clearFailure ? null : failure ?? this.failure,
    descriptor: descriptor ?? this.descriptor,
    resetsAt: clearFailure ? null : resetsAt ?? this.resetsAt,
  );

  @override
  String toString() => 'AttachmentUploadJob(${state.name})';
}
