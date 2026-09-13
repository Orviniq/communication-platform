import 'dart:convert';
import 'dart:io';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/features/diagnostics/application/collect_diagnostics.dart';
import 'package:communication_platform/features/diagnostics/application/ports/diagnostics_ports.dart';
import 'package:communication_platform/features/diagnostics/domain/diagnostics_report.dart';
import 'package:communication_platform/features/diagnostics/infrastructure/drift_local_state_diagnostics.dart';
import 'package:communication_platform/features/diagnostics/infrastructure/network_diagnostics_source.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The string every adversarial fixture below is stuffed with.
///
/// Deliberately shaped like something that *could* pass a naive filter — no
/// spaces, no punctuation a token check would reject — so that the export
/// having none of it is a property of what the sources read, not of a sanitizer
/// downstream of them.
const _canary = 'CANARYb9f4c2DoNotExport';

void main() {
  group('what a report can physically hold', () {
    test('every value renders inside one narrow grammar', () {
      // The export's whole safety argument is that a value is a boolean, an
      // enumeration name, a bucket, a bounded integer or a declared constant.
      // If a token could be arbitrary text, everything else here is decoration.
      final token = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+\-]*$');
      final values = <DiagnosticValue>[
        const DiagnosticValue.flag(true),
        const DiagnosticValue.flag(false),
        const DiagnosticValue.number(0),
        const DiagnosticValue.number(999999),
        const DiagnosticValue.number(-1),
        const DiagnosticValue.number(1000000),
        for (final word in DiagnosticWord.values) DiagnosticValue.term(word),
        for (final quantity in DiagnosticQuantity.values)
          DiagnosticValue.quantity(quantity),
        for (final outcome in NetworkOutcome.values)
          DiagnosticValue.term(outcome),
        for (final operation in NetworkOperation.values)
          DiagnosticValue.term(operation),
      ];
      for (final value in values) {
        expect(
          token.hasMatch(value.token),
          isTrue,
          reason: 'rendered "${value.token}"',
        );
      }
    });

    test('every field key is a stable lower-case token', () {
      final token = RegExp(r'^[a-z][a-z0-9_]*$');
      for (final field in DiagnosticField.values) {
        expect(token.hasMatch(field.token), isTrue, reason: field.name);
      }
      // Keys are unique within a section, so a reader parsing the export by
      // section and key cannot get two answers to one question.
      for (final section in DiagnosticSection.values) {
        final keys = DiagnosticField.values
            .where((field) => field.section == section)
            .map((field) => field.token)
            .toList();
        expect(keys.toSet(), hasLength(keys.length), reason: section.name);
      }
    });

    test('a constant that is not a short safe token becomes unknown', () {
      // `DiagnosticValue.constant` is the only constructor that takes a string
      // at all, and it exists for compile-time values such as the packaged
      // version. The shape check bounds what it can emit; the architecture test
      // bounds where it may be called from.
      for (final rejected in <String>[
        'a b',
        'user@example.test',
        '../../etc/passwd',
        'Bearer abcdefghij',
        '',
        'x' * 65,
        'صبح',
        'line\nbreak',
        '[section]',
      ]) {
        expect(
          DiagnosticValue.constant(rejected).token,
          DiagnosticWord.unknown.token,
          reason: 'accepted "$rejected"',
        );
      }
      expect(DiagnosticValue.constant('0.1.0+1').token, '0.1.0+1');
      expect(
        DiagnosticValue.constant('2026-08-25T14Z').token,
        '2026-08-25T14Z',
      );
    });

    test('an out-of-range number is refused rather than widened', () {
      expect(const DiagnosticValue.number(-1).token, 'unknown');
      expect(const DiagnosticValue.number(1000000).token, 'unknown');
      expect(const DiagnosticValue.number(12).token, '12');
    });

    test('counts leave as orders of magnitude, never exactly', () {
      expect(DiagnosticQuantity.of(0), DiagnosticQuantity.none);
      expect(DiagnosticQuantity.of(-5), DiagnosticQuantity.none);
      expect(DiagnosticQuantity.of(1), DiagnosticQuantity.upToNine);
      expect(DiagnosticQuantity.of(9), DiagnosticQuantity.upToNine);
      expect(DiagnosticQuantity.of(10), DiagnosticQuantity.upToNinetyNine);
      expect(
        DiagnosticQuantity.of(999),
        DiagnosticQuantity.upToNineHundredNinetyNine,
      );
      expect(DiagnosticQuantity.of(41231), DiagnosticQuantity.thousandOrMore);
    });
  });

  group('the rendered export', () {
    test('is ordered, grouped, and answers each field once', () {
      // A source that answers twice must not put two contradictory lines in a
      // document somebody is about to hand to a stranger; the later answer wins
      // and the order is the declaration order, so two reports of the same
      // state are byte-identical.
      final report = DiagnosticsReport([
        const DiagnosticEntry(
          DiagnosticField.networkSucceeded,
          DiagnosticValue.quantity(DiagnosticQuantity.upToNine),
        ),
        const DiagnosticEntry(
          DiagnosticField.applicationVersion,
          DiagnosticValue.term(DiagnosticWord.unknown),
        ),
        DiagnosticEntry(
          DiagnosticField.applicationVersion,
          DiagnosticValue.constant('0.1.0+1'),
        ),
      ]);

      expect(
        report.render(),
        '[application]\nversion=0.1.0+1\n\n[network]\nsucceeded=1-9\n',
      );
    });

    test('renders one line per entry and nothing else', () {
      final report = DiagnosticsReport([
        const DiagnosticEntry(
          DiagnosticField.reportFormat,
          DiagnosticValue.number(DiagnosticsReport.formatVersion),
        ),
        const DiagnosticEntry(
          DiagnosticField.queueGapDetected,
          DiagnosticValue.flag(true),
        ),
      ]);
      expect(const LineSplitter().convert(report.render()), [
        '[application]',
        'report_format=2',
        '',
        '[delivery]',
        'queue_gap_detected=yes',
      ]);
    });
  });

  group('under adversarial content', () {
    test(
      'a database full of canaries produces a report containing none',
      () async {
        final database = LocalDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        await _fillWithCanaries(database);

        final report = await CollectDiagnostics(
          sources: [DriftLocalStateDiagnostics(database)],
          time: const _FixedTime(),
        ).call();
        final rendered = report.render();

        expect(rendered, isNot(contains(_canary)));
        expect(rendered.toUpperCase(), isNot(contains('CANARY')));
        // And it still says the useful thing, bucketed.
        expect(rendered, contains('protected_storage=available'));
        expect(rendered, contains('conversations=1-9'));
        expect(rendered, contains('pending_outbound=1-9'));
        expect(rendered, contains('pending_inbound=1-9'));
        expect(rendered, contains('quarantined_input=1-9'));
        expect(rendered, contains('queue_gap_detected=no'));
      },
    );

    test(
      'an unopenable database is a stated state, not a blank screen',
      () async {
        // A directory is not a database file, so every query against this
        // executor fails - which is exactly the fault a person opens this
        // screen to describe.
        final database = LocalDatabase(
          NativeDatabase(File(Directory.systemTemp.path)),
        );
        addTearDown(() async {
          try {
            await database.close();
          } on Object {
            // Closing something that never opened is not a test failure.
          }
        });

        final report = await CollectDiagnostics(
          sources: [DriftLocalStateDiagnostics(database)],
          time: const _FixedTime(),
        ).call();

        expect(report.render(), contains('protected_storage=unavailable'));
        expect(report.render(), contains('database_schema='));
        expect(report.render(), isNot(contains('conversations=')));
      },
    );

    test(
      'a source that throws contributes nothing and fails no report',
      () async {
        final report = await CollectDiagnostics(
          sources: const [_ThrowingSource()],
          time: const _FixedTime(),
        ).call();

        expect(report.render(), contains('report_format=2'));
      },
    );

    test('the generation stamp is an hour, never a moment', () async {
      final report = await CollectDiagnostics(
        sources: const [],
        time: const _FixedTime(),
      ).call();
      expect(report.render(), contains('generated_utc_hour=2026-08-25T14Z'));
      expect(report.render(), isNot(contains('37')));
    });
  });

  group('the network section', () {
    test('counts outcomes without keeping a single event', () async {
      final recorder = RecordingNetworkDiagnostics();
      for (var index = 0; index < 12; index += 1) {
        recorder.record(
          const NetworkDiagnosticEvent(
            operation: NetworkOperation.syncDrain,
            outcome: NetworkOutcome.transportFailed,
            duration: DurationBucket.over2Seconds,
            attempt: 3,
            statusCode: 503,
          ),
        );
      }
      recorder.record(
        const NetworkDiagnosticEvent(
          operation: NetworkOperation.health,
          outcome: NetworkOutcome.succeeded,
          duration: DurationBucket.under100Ms,
          attempt: 1,
        ),
      );

      final rendered = DiagnosticsReport(
        await NetworkDiagnosticsSource(recorder).collect(),
      ).render();

      expect(rendered, contains('transport_failed=10-99'));
      expect(rendered, contains('succeeded=1-9'));
      expect(rendered, contains('slowest_response=over2Seconds'));
      expect(rendered, contains('most_failed_operation=syncDrain'));
      // The status code and the attempt number were in the event and are not
      // in the export: no per-request value leaves.
      expect(rendered, isNot(contains('503')));
      expect(rendered, isNot(contains('attempt')));
    });

    test(
      'a quiet process says so rather than inventing a worst case',
      () async {
        final rendered = DiagnosticsReport(
          await NetworkDiagnosticsSource(
            RecordingNetworkDiagnostics(),
          ).collect(),
        ).render();

        expect(rendered, contains('succeeded=0'));
        expect(rendered, contains('slowest_response=none'));
        expect(rendered, contains('most_failed_operation=none'));
      },
    );

    test('a tie between two operations resolves the same way every time', () {
      final recorder = RecordingNetworkDiagnostics();
      recorder.record(
        const NetworkDiagnosticEvent(
          operation: NetworkOperation.syncSend,
          outcome: NetworkOutcome.cancelled,
          duration: DurationBucket.under500Ms,
          attempt: 1,
        ),
      );
      recorder.record(
        const NetworkDiagnosticEvent(
          operation: NetworkOperation.health,
          outcome: NetworkOutcome.cancelled,
          duration: DurationBucket.under500Ms,
          attempt: 1,
        ),
      );
      // Declaration order, not insertion order, so two reports of the same
      // state are byte-identical.
      expect(recorder.snapshot().mostFailedOperation, NetworkOperation.health);
    });
  });
}

Future<void> _fillWithCanaries(LocalDatabase database) async {
  final canaryBytes = Uint8List.fromList(utf8.encode(_canary));
  await database
      .into(database.conversations)
      .insert(
        ConversationsCompanion.insert(
          conversationId: _canary,
          kind: 0,
          listProjectionCiphertext: canaryBytes,
          sortKey: 1,
          peerUserId: const Value(_canary),
          displayTitleCiphertext: Value(canaryBytes),
          draftCiphertext: Value(canaryBytes),
        ),
      );
  await database
      .into(database.messages)
      .insert(
        MessagesCompanion.insert(
          messageId: '$_canary-message',
          conversationId: _canary,
          currentEventId: _canary,
          projectionCiphertext: canaryBytes,
          status: 0,
          revision: 0,
          createdAt: DateTime.utc(2026),
          senderUserId: const Value(_canary),
          senderDeviceId: const Value(_canary),
        ),
      );
  await database
      .into(database.outboxOperations)
      .insert(
        OutboxOperationsCompanion.insert(
          operationId: _canary,
          eventId: _canary,
          recipientDeviceId: _canary,
          recipientUserId: const Value(_canary),
          batchIndex: 0,
          exactRecipientCiphertext: canaryBytes,
          attemptState: 0,
        ),
      );
  await database
      .into(database.inboxEnvelopes)
      .insert(
        InboxEnvelopesCompanion.insert(
          envelopeId: _canary,
          sequence: 1,
          envelopeCiphertext: canaryBytes,
          processingState: 0,
          opaqueEventId: const Value(_canary),
        ),
      );
  await database
      .into(database.quarantineRecords)
      .insert(
        QuarantineRecordsCompanion.insert(
          reasonCode: 1,
          opaqueDigest: canaryBytes,
        ),
      );
  await database
      .into(database.localPreferences)
      .insert(
        LocalPreferencesCompanion.insert(
          preferenceKey: _canary,
          valueCiphertext: canaryBytes,
          valueVersion: 1,
        ),
      );
}

final class _FixedTime implements TimeSource {
  const _FixedTime();

  @override
  DateTime now() => DateTime.utc(2026, 8, 25, 14, 37, 12);
}

final class _ThrowingSource implements DiagnosticsSourcePort {
  const _ThrowingSource();

  @override
  Future<List<DiagnosticEntry>> collect() async =>
      throw StateError('the subsystem this describes is the broken one');
}
