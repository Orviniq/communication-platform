import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_probe_ledger.dart';
import 'package:communication_platform/features/signals/infrastructure/drift_presence_stores.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/presence_fakes.dart';

/// Schema 26's `presence_devices` and the "Show my online status" row
/// (ADR-098 D8, D9): what survives a process, and what reads as what.
void main() {
  final bob = uuid(0x1001);
  final b1 = uuid(0x901);
  final b2 = uuid(0x902);
  final carol = uuid(0x1002);
  final c1 = uuid(0x911);
  final bobPhone = PresenceDevice(userId: bob, deviceId: b1);
  final bobTablet = PresenceDevice(userId: bob, deviceId: b2);
  final carolPhone = PresenceDevice(userId: carol, deviceId: c1);

  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('presence-devices-');
    file = File('${directory.path}/presence.sqlite');
  });

  tearDown(() => directory.delete(recursive: true));

  Future<PresenceLedgerEntry?> ledgerOf(
    DriftPresenceDevices store,
    PresenceDevice device,
  ) async =>
      (await store.read(userId: device.userId, deviceId: device.deviceId)
              as Success<PresenceLedgerEntry?>)
          .value;

  Future<Map<String, int>> lastSeenOf(
    DriftPresenceDevices store,
    Set<String> users,
  ) async => {
    for (final seen
        in (await store.readLastSeen(users) as Success<List<PresenceLastSeen>>)
            .value)
      seen.deviceId: seen.lastSeenMs,
  };

  test('the ledger and the last seen survive a new database handle', () async {
    var database = LocalDatabase(NativeDatabase(file));
    var store = DriftPresenceDevices(database);
    final ledger = PresenceProbeLedger(store);
    final t0 = DateTime.utc(2026, 10, 19, 12);
    for (var probe = 0; probe < 4; probe += 1) {
      expect(
        await ledger.allows(bobPhone, t0.add(Duration(minutes: probe))),
        isTrue,
      );
      await ledger.recordProbe(bobPhone, t0.add(Duration(minutes: probe)));
    }
    await store.writeLastSeen(carolPhone, 1234);
    await database.close();

    database = LocalDatabase(NativeDatabase(file));
    addTearDown(database.close);
    store = DriftPresenceDevices(database);
    final restarted = PresenceProbeLedger(store);

    final entry = (await ledgerOf(store, bobPhone))!;
    expect(entry.probesSinceHeard, 4);
    expect(entry.tokens, 0);
    expect(
      await restarted.allows(bobPhone, t0.add(const Duration(hours: 1))),
      isFalse,
      reason: 'a restart refills nothing (P1, P2)',
    );
    expect(await lastSeenOf(store, {carol}), {c1: 1234});
  });

  test('a durable envelope from a probed device lifts the silence rule, and '
      'from any other writes nothing', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = DriftPresenceDevices(database);
    final ledger = PresenceProbeLedger(store);
    final t0 = DateTime.utc(2026, 10, 19, 12);
    for (var probe = 0; probe < 4; probe += 1) {
      await ledger.recordProbe(bobPhone, t0.add(Duration(minutes: probe)));
    }
    expect(
      await ledger.allows(bobPhone, t0.add(const Duration(hours: 7))),
      isFalse,
    );

    // What the inbox pass reports for each envelope it commits.
    await ledger.heard(bobPhone);
    await ledger.heard(carolPhone);

    expect((await ledgerOf(store, bobPhone))!.probesSinceHeard, 0);
    expect(
      await ledger.allows(bobPhone, t0.add(const Duration(hours: 7))),
      isTrue,
    );
    expect(
      await database.select(database.presenceDevices).get(),
      hasLength(1),
      reason: 'a device with no probe outstanding gains no row',
    );
  });

  test('the ledger and the last seen share a row and leave each other '
      'alone', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = DriftPresenceDevices(database);

    await store.writeLastSeen(bobPhone, 5000);
    final fresh = (await ledgerOf(store, bobPhone))!;
    expect(fresh.probesSinceHeard, 0);
    expect(fresh.tokens, PresenceProbeLedger.bucketCapacity);
    expect(fresh.lastProbeMs, isNull);

    await store.write(
      fresh.copyWith(probesSinceHeard: 2, tokens: 1, lastProbeMs: 6000),
    );
    expect(await lastSeenOf(store, {bob}), {b1: 5000});

    await store.writeLastSeen(bobPhone, 7000);
    final kept = (await ledgerOf(store, bobPhone))!;
    expect(kept.probesSinceHeard, 2);
    expect(kept.tokens, 1);
    expect(kept.lastProbeMs, 6000);
    expect(await lastSeenOf(store, {bob}), {b1: 7000});
  });

  test('the last seen is read for the accounts asked, and forgotten one '
      'device or every device at a time', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = DriftPresenceDevices(database);
    await store.writeLastSeen(bobPhone, 1);
    await store.writeLastSeen(bobTablet, 2);
    await store.writeLastSeen(carolPhone, 3);

    expect(await lastSeenOf(store, {bob.toUpperCase()}), {b1: 1, b2: 2});

    await store.forgetLastSeen(bobTablet);
    expect(await lastSeenOf(store, {bob, carol}), {b1: 1, c1: 3});

    await store.forgetLastSeen();
    expect(await lastSeenOf(store, {bob, carol}), isEmpty);
    expect(
      await database.select(database.presenceDevices).get(),
      hasLength(3),
      reason: 'forgetting a last seen keeps the ledger',
    );
  });

  group('"Show my online status"', () {
    test('a missing row reads as on', () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      expect(
        await DriftPresenceSharePreference(database).readSharing(),
        isTrue,
      );
    });

    test(
      'a row this build cannot read reads as on, and only off is off',
      () async {
        final database = LocalDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final store = DriftPresenceSharePreference(database);
        await database
            .into(database.localPreferences)
            .insertOnConflictUpdate(
              LocalPreferencesCompanion.insert(
                preferenceKey: DriftPresenceSharePreference.sharingKey,
                valueCiphertext: Uint8List.fromList(const [0xff, 0xfe]),
                valueVersion: 1,
              ),
            );
        expect(await store.readSharing(), isTrue);

        await store.writeSharing(sharing: false);
        expect(await store.readSharing(), isFalse);
        final row = await database
            .select(database.localPreferences)
            .getSingle();
        expect(row.preferenceKey, 'presence.share.v1');
        expect(utf8.decode(row.valueCiphertext), 'off');

        await store.writeSharing(sharing: true);
        expect(await store.readSharing(), isTrue);
      },
    );

    test('off survives a new database handle', () async {
      var database = LocalDatabase(NativeDatabase(file));
      await DriftPresenceSharePreference(database).writeSharing(sharing: false);
      await database.close();

      database = LocalDatabase(NativeDatabase(file));
      addTearDown(database.close);
      expect(
        await DriftPresenceSharePreference(database).readSharing(),
        isFalse,
      );
    });
  });
}
