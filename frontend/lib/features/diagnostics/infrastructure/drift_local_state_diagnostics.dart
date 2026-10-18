import 'package:communication_platform/features/diagnostics/application/ports/diagnostics_ports.dart';
import 'package:communication_platform/features/diagnostics/domain/diagnostics_report.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:drift/drift.dart';

/// What the encrypted database can say about itself without saying anything
/// that is in it.
///
/// Every value here is a schema number, a bucketed row count or a state flag.
/// No conversation, message, contact, device, envelope or quarantine record is
/// read — only counted — so the query itself has nothing to leak, and a caller
/// cannot widen it without adding a [DiagnosticField].
final class DriftLocalStateDiagnostics implements DiagnosticsSourcePort {
  const DriftLocalStateDiagnostics(this.database);

  final LocalDatabase database;

  @override
  Future<List<DiagnosticEntry>> collect() async {
    final entries = <DiagnosticEntry>[
      const DiagnosticEntry(
        DiagnosticField.databaseSchema,
        DiagnosticValue.number(LocalDatabase.currentSchemaVersion),
      ),
    ];
    try {
      final conversationTotal = countAll();
      final conversationQuery = database.selectOnly(database.conversations)
        ..addColumns([conversationTotal])
        ..where(database.conversations.tombstoned.equals(false));
      final conversations =
          (await conversationQuery.getSingle()).read(conversationTotal) ?? 0;

      final outboundTotal = countAll();
      final outboundQuery = database.selectOnly(database.outboxOperations)
        ..addColumns([outboundTotal])
        ..where(
          database.outboxOperations.attemptState.isIn([
            OutboxAttemptState.queued.index,
            OutboxAttemptState.sending.index,
            OutboxAttemptState.retryWait.index,
          ]),
        );
      final pendingOutbound =
          (await outboundQuery.getSingle()).read(outboundTotal) ?? 0;

      // A held envelope is not work the engine can do: it waits for a
      // verification (ADR-093 D11, D20), so it is counted apart.
      final inboundTotal = countAll();
      final inboundQuery = database.selectOnly(database.inboxEnvelopes)
        ..addColumns([inboundTotal])
        ..where(
          database.inboxEnvelopes.processingState.isNotIn([
            InboxProcessingState.acknowledged.index,
            InboxProcessingState.held.index,
          ]),
        );
      final pendingInbound =
          (await inboundQuery.getSingle()).read(inboundTotal) ?? 0;

      final heldTotal = countAll();
      final heldQuery = database.selectOnly(database.inboxEnvelopes)
        ..addColumns([heldTotal])
        ..where(
          database.inboxEnvelopes.processingState.equals(
            InboxProcessingState.held.index,
          ),
        );
      final heldInbound = (await heldQuery.getSingle()).read(heldTotal) ?? 0;

      final quarantineTotal = countAll();
      final quarantineQuery = database.selectOnly(database.quarantineRecords)
        ..addColumns([quarantineTotal]);
      final quarantined =
          (await quarantineQuery.getSingle()).read(quarantineTotal) ?? 0;

      final checkpoint = await (database.select(
        database.syncCheckpoints,
      )..limit(1)).getSingleOrNull();

      entries.addAll([
        const DiagnosticEntry(
          DiagnosticField.protectedStorage,
          DiagnosticValue.term(DiagnosticWord.available),
        ),
        DiagnosticEntry(
          DiagnosticField.conversationCount,
          DiagnosticValue.quantity(DiagnosticQuantity.of(conversations)),
        ),
        DiagnosticEntry(
          DiagnosticField.pendingOutbound,
          DiagnosticValue.quantity(DiagnosticQuantity.of(pendingOutbound)),
        ),
        DiagnosticEntry(
          DiagnosticField.pendingInbound,
          DiagnosticValue.quantity(DiagnosticQuantity.of(pendingInbound)),
        ),
        DiagnosticEntry(
          DiagnosticField.heldInbound,
          DiagnosticValue.quantity(DiagnosticQuantity.of(heldInbound)),
        ),
        DiagnosticEntry(
          DiagnosticField.quarantinedInput,
          DiagnosticValue.quantity(DiagnosticQuantity.of(quarantined)),
        ),
        DiagnosticEntry(
          DiagnosticField.queueGapDetected,
          DiagnosticValue.flag(
            checkpoint != null &&
                checkpoint.queueGapState ==
                    QueueGapState.recoveryRequired.index,
          ),
        ),
      ]);
    } on Object {
      // A database that cannot be read is exactly the fault this screen exists
      // to describe, so it is reported as a state rather than as an absence.
      entries.add(
        const DiagnosticEntry(
          DiagnosticField.protectedStorage,
          DiagnosticValue.term(DiagnosticWord.unavailable),
        ),
      );
    }
    return entries;
  }
}
