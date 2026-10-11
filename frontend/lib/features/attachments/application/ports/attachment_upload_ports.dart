import 'dart:io';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/domain/attachment_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';

/// What the upload queue needs of the attachment file cache (ADR-089 D5, D8).
abstract interface class AttachmentOutgoingFilesPort implements Port {
  /// Completes when the cache's first sweep has run, running it if nothing
  /// has yet. [liveOutgoing] is every outgoing copy this process holds.
  Future<void> beforeTransfer({required Iterable<File> liveOutgoing});

  /// Moves the outgoing [copy] in as the sender's cached copy of
  /// [attachmentId], whose row the committed message made, and marks the row
  /// ready. Answers the new cache id.
  Future<Result<String>> adoptOutgoing({
    required String attachmentId,
    required File copy,
  });

  /// Deletes the outgoing [copy] and its directory. Never fails: what it
  /// could not delete, the next sweep does.
  Future<void> discardOutgoing(File copy);
}

/// Commits the message that carries one uploaded attachment (ADR-089 D5).
///
/// Answers once the message and its projection are committed (ADR-061):
/// nothing about the network is known then.
abstract interface class AttachmentMessagePort implements Port {
  Future<Result<void>> send({
    required AttachmentUploadTarget target,
    required AttachmentDescriptor descriptor,
    required String? caption,
    required bool imageMessage,
  });
}
