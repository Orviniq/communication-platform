import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_probe_ledger.dart';
import 'package:communication_platform/features/signals/infrastructure/presence_adapters.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-098 D6: P1 and P2 at their limits, and their resets.
void main() {
  const device = PresenceDevice(
    userId: '00000000-0000-4000-8000-000000001001',
    deviceId: '00000000-0000-4000-8000-000000000901',
  );
  final start = DateTime.utc(2026, 10, 19, 12);

  late MemoryPresenceLedger store;
  late PresenceProbeLedger ledger;

  setUp(() {
    store = MemoryPresenceLedger();
    ledger = PresenceProbeLedger(store);
  });

  /// Probes [device] at [at] if the ledger allows it, and says whether it
  /// did.
  Future<bool> probe(DateTime at) async {
    if (!await ledger.allows(device, at)) {
      return false;
    }
    await ledger.recordProbe(device, at);
    return true;
  }

  test('P1: four probes after the last frame heard, then none until the '
      'device is heard again', () async {
    // Six hours apart, so neither the bucket nor the minute binds.
    for (var index = 0; index < 4; index += 1) {
      expect(
        await probe(start.add(Duration(hours: 6 * index))),
        isTrue,
        reason: 'probe ${index + 1}',
      );
    }
    expect(await probe(start.add(const Duration(hours: 24))), isFalse);
    expect(await probe(start.add(const Duration(days: 30))), isFalse);

    await ledger.heard(device);

    expect(await probe(start.add(const Duration(days: 30))), isTrue);
  });

  test('P2: a bucket of four, one more every six hours, and at most one a '
      'minute', () async {
    // Heard after each probe, so P1 never binds.
    Future<bool> probeHeard(DateTime at) async {
      final sent = await probe(at);
      await ledger.heard(device);
      return sent;
    }

    expect(await probeHeard(start), isTrue);
    expect(
      await probeHeard(start.add(const Duration(seconds: 59))),
      isFalse,
      reason: 'one a minute',
    );
    expect(await probeHeard(start.add(const Duration(minutes: 1))), isTrue);
    expect(await probeHeard(start.add(const Duration(minutes: 2))), isTrue);
    expect(await probeHeard(start.add(const Duration(minutes: 3))), isTrue);
    expect(
      await probeHeard(start.add(const Duration(minutes: 4))),
      isFalse,
      reason: 'the bucket is empty, and hearing the device refills nothing',
    );
    expect(
      await probeHeard(start.add(const Duration(hours: 5, minutes: 59))),
      isFalse,
    );
    expect(await probeHeard(start.add(const Duration(hours: 6))), isTrue);
    expect(
      await probeHeard(start.add(const Duration(hours: 6, minutes: 1))),
      isFalse,
    );
  });

  test('P2: at most eight in any 24 hours, asked every minute for three '
      'days by a device heard after each', () async {
    final sent = <DateTime>[];
    for (var minute = 0; minute <= 3 * 24 * 60; minute += 1) {
      final at = start.add(Duration(minutes: minute));
      if (await probe(at)) {
        sent.add(at);
      }
      await ledger.heard(device);
    }

    for (final from in sent) {
      final window = sent.where(
        (at) =>
            !at.isBefore(from) &&
            at.isBefore(from.add(const Duration(hours: 24))),
      );
      expect(window.length, lessThanOrEqualTo(8), reason: 'from $from');
    }
    expect(
      sent.where((at) => !at.isAfter(start.add(const Duration(hours: 24)))),
      hasLength(8),
      reason: 'the bucket, and a token at 6, 12, 18 and 24 hours',
    );
  });

  test('a ledger that cannot be read allows no probe', () async {
    final refusing = PresenceProbeLedger(_UnreadableLedger());

    expect(await refusing.allows(device, start), isFalse);
  });

  test('hearing a device with no probe outstanding writes nothing', () async {
    final counting = _CountingLedger();
    final counted = PresenceProbeLedger(counting);

    await counted.heard(device);
    await counted.recordProbe(device, start);
    await counted.heard(device);
    await counted.heard(device);

    expect(counting.writes, 2, reason: 'the probe, then the first hearing');
  });
}

final class _UnreadableLedger implements PresenceLedgerPort {
  @override
  Future<Result<PresenceLedgerEntry?>> read({
    required String userId,
    required String deviceId,
  }) async =>
      const Result.failure(StorageFailure(StorageFailureKind.unavailable));

  @override
  Future<Result<void>> write(PresenceLedgerEntry entry) async =>
      const Result.failure(StorageFailure(StorageFailureKind.unavailable));
}

final class _CountingLedger implements PresenceLedgerPort {
  final _inner = MemoryPresenceLedger();
  var writes = 0;

  @override
  Future<Result<PresenceLedgerEntry?>> read({
    required String userId,
    required String deviceId,
  }) => _inner.read(userId: userId, deviceId: deviceId);

  @override
  Future<Result<void>> write(PresenceLedgerEntry entry) {
    writes += 1;
    return _inner.write(entry);
  }
}
