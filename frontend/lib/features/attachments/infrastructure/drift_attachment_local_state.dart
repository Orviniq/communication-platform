import 'dart:convert';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/ports/attachment_local_state_port.dart';
import 'package:communication_platform/features/attachments/domain/attachment_cache_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/stored_attachment_descriptor.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// [AttachmentLocalStatePort] over the `attachments` table, schema 23.
///
/// The cache id is kept in `bounded_cache_handle_ciphertext` as UTF-8, and
/// the expiry in `cache_expires_at`. Both columns are inside SQLCipher, like
/// the rest of the row. No column and no CHECK changes: the table's CHECK
/// allows 0 to 8, and the three states this writes are 0, 6 and 7.
///
/// A row that says more than it should — `ready` with no cache id, a cache id
/// of the wrong form, a state the client does not persist — reads as
/// `queued`, which is the answer that costs a second download rather than
/// one that hands out a file nobody can find.
final class DriftAttachmentLocalState implements AttachmentLocalStatePort {
  const DriftAttachmentLocalState(this.database);

  final LocalDatabase database;

  @override
  Future<Result<AttachmentLocalState?>> read(String attachmentId) async {
    try {
      final row =
          await (database.select(database.attachments)
                ..where((row) => row.attachmentId.equals(attachmentId)))
              .getSingleOrNull();
      if (row == null) {
        return const Result.success(null);
      }
      final descriptor = decodeStoredAttachmentDescriptor(
        row.encryptedDescriptor,
      );
      if (descriptor == null) {
        return const Result.success(null);
      }
      final claim = _claimOf(row);
      return Result.success(
        AttachmentLocalState(
          messageId: row.messageId,
          descriptor: descriptor,
          state: claim == null
              ? row.transferState == AttachmentTransferState.expired.index
                    ? AttachmentTransferState.expired
                    : AttachmentTransferState.queued
              : AttachmentTransferState.ready,
          cacheId: claim?.cacheId,
          expiresAt: claim?.expiresAt,
        ),
      );
    } on Object {
      return const Result.failure(_unavailable);
    }
  }

  @override
  Future<Result<void>> markCached({
    required String attachmentId,
    required String cacheId,
    required DateTime expiresAt,
  }) => write(
    attachmentId,
    state: AttachmentTransferState.ready,
    cacheId: cacheId,
    expiresAt: expiresAt,
  );

  @override
  Future<Result<void>> touch({
    required String attachmentId,
    required DateTime expiresAt,
  }) => _update(
    (database.update(database.attachments)..where(
      (row) =>
          row.attachmentId.equals(attachmentId) &
          row.transferState.equals(AttachmentTransferState.ready.index) &
          row.boundedCacheHandleCiphertext.isNotNull(),
    )),
    AttachmentsCompanion(cacheExpiresAt: Value(expiresAt.toUtc())),
    needsRow: true,
  );

  @override
  Future<Result<void>> clearCache(String attachmentId) =>
      write(attachmentId, state: AttachmentTransferState.queued);

  @override
  Future<Result<void>> markExpired(String attachmentId) =>
      write(attachmentId, state: AttachmentTransferState.expired);

  @override
  Future<Result<List<CachedAttachmentEntry>>> listCached() async {
    try {
      final rows =
          await (database.select(database.attachments)..where(
                (row) =>
                    row.transferState.equals(
                      AttachmentTransferState.ready.index,
                    ) |
                    row.boundedCacheHandleCiphertext.isNotNull() |
                    row.cacheExpiresAt.isNotNull(),
              ))
              .get();
      return Result.success(
        List.unmodifiable([
          for (final row in rows)
            switch (_claimOf(row)) {
              final claim? => CachedAttachmentEntry(
                attachmentId: row.attachmentId,
                cacheId: claim.cacheId,
                expiresAt: claim.expiresAt,
              ),
              null => CachedAttachmentEntry(
                attachmentId: row.attachmentId,
                cacheId: null,
                expiresAt: null,
              ),
            },
        ]),
      );
    } on Object {
      return const Result.failure(_unavailable);
    }
  }

  /// The one way a state is written.
  ///
  /// Throws an [ArgumentError], before anything is written, for a state the
  /// client does not persist (ADR-089 D9), for `ready` without a cache id of
  /// the right form and an expiry, and for another state with either of them.
  /// A rejected value is a defect in the caller, not a condition to report.
  @visibleForTesting
  Future<Result<void>> write(
    String attachmentId, {
    required AttachmentTransferState state,
    String? cacheId,
    DateTime? expiresAt,
  }) {
    if (!persistedAttachmentStates.contains(state)) {
      throw ArgumentError.value(state, 'state', 'is not persisted');
    }
    final ready = state == AttachmentTransferState.ready;
    if (ready != (cacheId != null) || ready != (expiresAt != null)) {
      throw ArgumentError(
        'A cache id and an expiry go with ready and only with ready.',
      );
    }
    if (cacheId != null && !isAttachmentCacheId(cacheId)) {
      throw ArgumentError.value('<redacted>', 'cacheId', 'is not a cache id');
    }
    return _update(
      database.update(database.attachments)
        ..where((row) => row.attachmentId.equals(attachmentId)),
      AttachmentsCompanion(
        transferState: Value(state.index),
        boundedCacheHandleCiphertext: Value(
          cacheId == null ? null : Uint8List.fromList(utf8.encode(cacheId)),
        ),
        cacheExpiresAt: Value(expiresAt?.toUtc()),
      ),
      needsRow: ready,
    );
  }

  Future<Result<void>> _update(
    UpdateStatement<$AttachmentsTable, Attachment> statement,
    AttachmentsCompanion values, {
    required bool needsRow,
  }) async {
    final int updated;
    try {
      updated = await statement.write(values);
    } on Object {
      return const Result.failure(_unavailable);
    }
    return updated == 0 && needsRow
        ? const Result.failure(
            ValidationFailure(ValidationFailureKind.conflict),
          )
        : const Result.success(null);
  }

  static const _unavailable = StorageFailure(StorageFailureKind.unavailable);
}

/// The decrypted file [row] holds, or null unless it is `ready` with a cache
/// id of the right form and an expiry.
({String cacheId, DateTime expiresAt})? _claimOf(Attachment row) {
  final handle = row.boundedCacheHandleCiphertext;
  final expiresAt = row.cacheExpiresAt;
  if (row.transferState != AttachmentTransferState.ready.index ||
      handle == null ||
      expiresAt == null) {
    return null;
  }
  final String cacheId;
  try {
    cacheId = utf8.decode(handle, allowMalformed: false);
  } on FormatException {
    return null;
  }
  return isAttachmentCacheId(cacheId)
      ? (cacheId: cacheId, expiresAt: expiresAt.toUtc())
      : null;
}
