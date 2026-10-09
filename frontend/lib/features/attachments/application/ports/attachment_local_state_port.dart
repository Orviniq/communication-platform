import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/result.dart';

/// The states the database keeps for an attachment (ADR-089 D9).
///
/// `queued` means "not downloaded". Every other state of a transfer —
/// encrypting, uploading, downloading, a failure — lives in memory with the
/// transfer, and a process that dies forgets it.
const persistedAttachmentStates = {
  AttachmentTransferState.queued,
  AttachmentTransferState.ready,
  AttachmentTransferState.expired,
};

/// What this device keeps about one attachment.
///
/// [state] is one of [persistedAttachmentStates]. [cacheId] and [expiresAt]
/// are set exactly when it is `ready`: the cache id names the directory of the
/// decrypted file, and the expiry is its last open plus the cache's lifetime.
final class AttachmentLocalState {
  const AttachmentLocalState({
    required this.messageId,
    required this.descriptor,
    required this.state,
    this.cacheId,
    this.expiresAt,
  });

  final String messageId;
  final EncryptedAttachmentDescriptor descriptor;
  final AttachmentTransferState state;
  final String? cacheId;

  /// In UTC.
  final DateTime? expiresAt;

  @override
  String toString() => 'AttachmentLocalState(${state.name})';
}

/// One attachment that claims a decrypted file.
///
/// [cacheId] and [expiresAt] are null when the claim cannot be read: a row in
/// another state than `ready`, a cache id of the wrong form, or no expiry. The
/// sweep clears such a row.
final class CachedAttachmentEntry {
  const CachedAttachmentEntry({
    required this.attachmentId,
    required this.cacheId,
    required this.expiresAt,
  });

  final String attachmentId;
  final String? cacheId;

  /// In UTC.
  final DateTime? expiresAt;

  @override
  String toString() => 'CachedAttachmentEntry(<redacted>)';
}

/// The durable state of one attachment on this device (ADR-089 D8, D9).
///
/// Each write leaves the row in one of [persistedAttachmentStates], with a
/// cache id and an expiry when it is `ready` and with neither otherwise.
/// A write that names an attachment with no row fails with
/// `ValidationFailure(conflict)` when it needs the row — [markCached] and
/// [touch] — and succeeds having done nothing when it only takes a file away.
abstract interface class AttachmentLocalStatePort implements RepositoryPort {
  /// The attachment [attachmentId], or null when no row names it or its
  /// descriptor cannot be read.
  Future<Result<AttachmentLocalState?>> read(String attachmentId);

  /// Records the decrypted file in directory [cacheId] and sets `ready`.
  Future<Result<void>> markCached({
    required String attachmentId,
    required String cacheId,
    required DateTime expiresAt,
  });

  /// Moves the expiry of a `ready` attachment, at an open.
  Future<Result<void>> touch({
    required String attachmentId,
    required DateTime expiresAt,
  });

  /// Forgets the decrypted file: no cache id, no expiry, and `queued`.
  Future<Result<void>> clearCache(String attachmentId);

  /// Forgets the decrypted file because the server no longer holds the
  /// attachment: no cache id, no expiry, and `expired`.
  Future<Result<void>> markExpired(String attachmentId);

  /// Every attachment that claims a decrypted file.
  Future<Result<List<CachedAttachmentEntry>>> listCached();
}
