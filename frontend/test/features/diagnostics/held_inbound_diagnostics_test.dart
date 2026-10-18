import 'package:communication_platform/features/diagnostics/domain/diagnostics_report.dart';
import 'package:communication_platform/features/diagnostics/infrastructure/drift_local_state_diagnostics.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _heldSender = '00000000-0000-0000-0000-0000000000a1';

/// A held envelope is not work the engine can do, so Diagnostics counts it
/// apart from the pending ones, by a bucket and never by its sender
/// (ADR-093 D20).
void main() {
  late LocalDatabase database;

  setUp(() => database = LocalDatabase(NativeDatabase.memory()));
  tearDown(() => database.close());

  Future<void> insert(int sequence, InboxProcessingState state) => database
      .into(database.inboxEnvelopes)
      .insert(
        InboxEnvelopesCompanion.insert(
          envelopeId: 'envelope-$sequence',
          sequence: sequence,
          envelopeCiphertext: Uint8List(1024),
          processingState: state.index,
          heldSenderUserId: Value(
            state == InboxProcessingState.held ? _heldSender : null,
          ),
        ),
      );

  Future<String> rendered() async => DiagnosticsReport(
    await DriftLocalStateDiagnostics(database).collect(),
  ).render();

  test('pending_inbound leaves held envelopes out, and held_inbound counts '
      'them', () async {
    await insert(1, InboxProcessingState.held);
    await insert(2, InboxProcessingState.held);
    await insert(3, InboxProcessingState.acknowledged);

    final report = await rendered();

    expect(report, contains('pending_inbound=0'));
    expect(report, contains('held_inbound=1-9'));
    expect(report, isNot(contains(_heldSender)));
  });

  test('an envelope still to inspect is pending, not held', () async {
    await insert(1, InboxProcessingState.received);

    final report = await rendered();

    expect(report, contains('pending_inbound=1-9'));
    expect(report, contains('held_inbound=0'));
  });
}
