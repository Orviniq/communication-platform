import 'dart:io';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';

/// What the download queue needs of the attachment file cache (ADR-089 D7,
/// D8).
abstract interface class AttachmentDecryptedFilesPort implements Port {
  /// Completes when the cache's first sweep has run, running it if nothing
  /// has yet. [liveOutgoing] is every outgoing copy this process holds.
  Future<void> beforeTransfer({required Iterable<File> liveOutgoing});

  /// Moves the decrypted, verified temporary [file] in as the cached copy of
  /// [attachmentId] under [name], marks the row ready with an expiry of the
  /// cache's lifetime from now, then holds the cache's bound. Answers the new
  /// cache id. A failure after the move deletes the file; one before it
  /// leaves [file] where it was.
  Future<Result<String>> adoptDecrypted({
    required String attachmentId,
    required File file,
    required String name,
  });

  /// The decrypted file of [attachmentId], with its expiry moved to the
  /// cache's lifetime from now, or null when it has none. A file that expired
  /// or went missing is forgotten, and its row returns to "not downloaded".
  Future<File?> open(String attachmentId);

  /// The decrypted file of [attachmentId] as it is, or null when it has none.
  /// Writes nothing: a look is not an open, and moves no expiry.
  Future<File?> peek(String attachmentId);
}
