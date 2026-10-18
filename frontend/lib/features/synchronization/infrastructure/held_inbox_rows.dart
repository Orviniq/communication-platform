import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:drift/drift.dart';

/// What a committed receive writes to its inbox row (ADR-093 D15).
///
/// An ordinary envelope waits for its acknowledgement. A released held
/// envelope was acknowledged when it was held and its server copy is gone,
/// so its commit marks it acknowledged and clears the hold: a second
/// acknowledgement would delete nothing, and it would tell the server the
/// moment an old envelope opened. The contiguity walk has already passed the
/// row, and the next acknowledgement deletes it.
InboxEnvelopesCompanion committedInboxRow(
  InboxEnvelope envelope, {
  required String opaqueEventId,
  required EnvelopeDependency dependency,
}) {
  if (isHeldMarked(envelope)) {
    return InboxEnvelopesCompanion(
      opaqueEventId: Value(opaqueEventId),
      dependencyClass: Value(dependency.index),
      processingState: Value(InboxProcessingState.acknowledged.index),
      readyToAcknowledge: const Value(false),
      nextAttemptAt: const Value(null),
      heldSenderUserId: const Value(null),
      heldSessionId: const Value(null),
      heldInitial: const Value(null),
      heldAt: const Value(null),
    );
  }
  return InboxEnvelopesCompanion(
    opaqueEventId: Value(opaqueEventId),
    dependencyClass: Value(dependency.index),
    processingState: Value(InboxProcessingState.readyToAcknowledge.index),
    readyToAcknowledge: const Value(true),
    nextAttemptAt: const Value(null),
  );
}

/// Whether [envelope] is held, or released and not yet opened (ADR-093 D11).
bool isHeldMarked(InboxEnvelope envelope) => envelope.heldSenderUserId != null;

/// Whether the server still holds a copy of a held-marked row: its
/// acknowledgement is owed or in flight. A row held and acknowledged, or
/// released, has none.
bool heldRowAwaitsAcknowledgement(InboxEnvelope envelope) =>
    envelope.processingState == InboxProcessingState.readyToAcknowledge.index ||
    envelope.processingState ==
        InboxProcessingState.acknowledgementSending.index;
