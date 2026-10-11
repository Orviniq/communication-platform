import 'dart:io';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_platform_port.dart';

/// What Open, Save and Share of a ready attachment can end in, as the details
/// sheet names it (ADR-089 D7).
enum AttachmentFileOutcome {
  /// The platform took the file.
  done,

  /// The user closed the save dialog: nothing to say.
  cancelled,

  /// No app on the phone opens this type. Save still works.
  noApp,

  /// The copy could not be written where the user chose.
  saveFailed,

  /// The cache no longer holds the file: evicted, expired or gone. Its row is
  /// "not downloaded" again, and a download brings it back while the server
  /// keeps it.
  missing,

  /// Anything else the platform refused.
  failed,
}

/// Open, Save and Share of a ready attachment, each through the cache's open
/// first: it gives the file and moves its expiry, so a file that is used
/// stays (ADR-089 D8).
final class AttachmentFileActions {
  const AttachmentFileActions({required this.platform, required this.files});

  final AttachmentPlatformPort platform;

  /// The download queue's open: the cached file of an attachment id, or
  /// null.
  final Future<File?> Function(String attachmentId) files;

  Future<AttachmentFileOutcome> open(
    EncryptedAttachmentDescriptor attachment,
  ) => _with(
    attachment,
    (file) => platform.open(file: file, mimeType: attachment.mimeType),
  );

  Future<AttachmentFileOutcome> save(
    EncryptedAttachmentDescriptor attachment,
  ) => _with(
    attachment,
    (file) => platform.save(
      file: file,
      name: attachment.displayName,
      mimeType: attachment.mimeType,
    ),
  );

  Future<AttachmentFileOutcome> share(
    EncryptedAttachmentDescriptor attachment,
  ) => _with(
    attachment,
    (file) => platform.share(file: file, mimeType: attachment.mimeType),
  );

  Future<AttachmentFileOutcome> _with(
    EncryptedAttachmentDescriptor attachment,
    Future<Result<void>> Function(File file) use,
  ) async {
    final file = await files(attachment.capabilityId);
    if (file == null) {
      return AttachmentFileOutcome.missing;
    }
    return switch (await use(file)) {
      Success() => AttachmentFileOutcome.done,
      FailureResult(:final failure) => switch (failure) {
        CancellationFailure() => AttachmentFileOutcome.cancelled,
        UnsupportedProtocolFailure() => AttachmentFileOutcome.noApp,
        StorageFailure() => AttachmentFileOutcome.saveFailed,
        _ => AttachmentFileOutcome.failed,
      },
    };
  }

  @override
  String toString() => 'AttachmentFileActions(<redacted>)';
}
