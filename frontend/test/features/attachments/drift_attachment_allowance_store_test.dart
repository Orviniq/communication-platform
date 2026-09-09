import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/features/attachments/domain/attachment_allowance_model.dart';
import 'package:communication_platform/features/attachments/infrastructure/drift_attachment_allowance_store.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// What this device has uploaded today, kept so that a restart does not hand
/// the whole allowance back.
///
/// The server publishes the ceiling and never the balance, so this count is the
/// only way a client can say what is left before it sends rather than after it
/// is refused. It is a lower bound by construction — another device's uploads
/// are missing from it — and that is the safe direction.
void main() {
  late LocalDatabase database;
  late DriftAttachmentAllowanceStore store;

  final noon = DateTime.utc(2026, 9, 9, 12);
  final laterSameDay = DateTime.utc(2026, 9, 9, 23, 59);
  final nextDay = DateTime.utc(2026, 9, 10, 0, 1);

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    store = DriftAttachmentAllowanceStore(database);
  });

  tearDown(() => database.close());

  Future<void> putRow(String contents) => database
      .into(database.localPreferences)
      .insertOnConflictUpdate(
        LocalPreferencesCompanion.insert(
          preferenceKey: DriftAttachmentAllowanceStore.allowanceKey,
          valueCiphertext: Uint8List.fromList(utf8.encode(contents)),
          valueVersion: 1,
        ),
      );

  test('an installation that has uploaded nothing has spent nothing', () async {
    final allowance = await store.read(noon);

    expect(allowance.spentBytes, 0);
    expect(allowance.remaining(dailyBytes: 1000, now: noon), 1000);
  });

  test('what was uploaded survives a restart', () async {
    await store.record(bytes: 65536, now: noon);

    expect((await store.read(laterSameDay)).spentBytes, 65536);
  });

  test('uploads through the day accumulate', () async {
    await store.record(bytes: 65536, now: noon);
    await store.record(bytes: 262144, now: laterSameDay);

    expect((await store.read(laterSameDay)).spentBytes, 327680);
  });

  test('a new UTC day starts on the whole allowance again', () async {
    // The server counts per UTC day and keeps no lifetime total, so nothing
    // carries over. UTC and not local time, because a client counting in local
    // time would reset on the wrong side of the server's boundary.
    await store.record(bytes: 65536, now: laterSameDay);

    final allowance = await store.read(nextDay);

    expect(allowance.remaining(dailyBytes: 100000, now: nextDay), 100000);
  });

  test(
    'a spend on a new day replaces the old count rather than adding',
    () async {
      await store.record(bytes: 65536, now: noon);
      await store.record(bytes: 1024, now: nextDay);

      expect((await store.read(nextDay)).spentBytes, 1024);
    },
  );

  test('an exhausted day has nothing left, never a negative amount', () async {
    await store.record(bytes: 2000, now: noon);

    expect((await store.read(noon)).remaining(dailyBytes: 1000, now: noon), 0);
  });

  test('a row this build cannot read counts as nothing spent', () async {
    // The failure direction that lets the server refuse is safer than the one
    // that refuses on this client's guess: an upload this lets through may
    // still be answered `413`, and nothing is lost but a round trip.
    for (final contents in const [
      'not json',
      '[]',
      '{"day":"2026-09-09T00:00:00.000Z"}',
      '{"day":"2026-09-09T00:00:00.000Z","spent_bytes":-1}',
      '{"day":"not a day","spent_bytes":10}',
    ]) {
      await putRow(contents);

      expect(
        (await store.read(noon)).spentBytes,
        0,
        reason: 'stored as $contents',
      );
    }
  });

  test('it is one row, however many uploads there were', () async {
    await store.record(bytes: 1024, now: noon);
    await store.record(bytes: 1024, now: laterSameDay);
    await store.record(bytes: 1024, now: nextDay);

    final rows = await database.select(database.localPreferences).get();

    expect(rows, hasLength(1));
    expect(
      rows.single.preferenceKey,
      DriftAttachmentAllowanceStore.allowanceKey,
    );
  });

  test('a local-time reading of a moment lands on the same UTC day', () {
    expect(utcDayOf(noon.toLocal()), DateTime.utc(2026, 9, 9));
  });
}
