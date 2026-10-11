import 'package:communication_platform/core/application/ports/port.dart';

/// Deletes the decrypted attachment files a deletion left without a message
/// (ADR-089 D8, D10).
///
/// Deleting a message for me or for everyone, or clearing a conversation,
/// deletes the attachment rows of the messages it took. A downloaded file is
/// named only by its row, so the file is then unnamed, and this is what
/// deletes it. Messaging asks for it through this port, so the messaging
/// feature does not depend on how the attachment cache keeps its files.
abstract interface class AttachmentSweepPort implements Port {
  /// Deletes every decrypted file no attachment row names.
  ///
  /// Never fails: a file it could not delete waits for the next sweep, and
  /// the wipe at logout deletes them all.
  Future<void> sweepAfterDeletion();
}
