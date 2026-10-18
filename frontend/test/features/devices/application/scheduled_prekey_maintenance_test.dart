import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/scheduled_prekey_maintenance.dart';
import 'package:communication_platform/features/devices/domain/prekey_maintenance_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Clock clock;
  late int runs;
  late Future<Result<PrekeyMaintenanceReport>> Function() answer;
  late ScheduledPrekeyMaintenance schedule;

  setUp(() {
    clock = _Clock(DateTime.utc(2026, 10, 18, 9));
    runs = 0;
    answer = () async => const Result.success(_report);
    schedule = ScheduledPrekeyMaintenance(
      clock: clock,
      maintain: () {
        runs += 1;
        return answer();
      },
    );
  });

  test('the first turn of a process runs maintenance', () async {
    final result = await schedule.runIfDue();

    expect(result, isA<Success<PrekeyMaintenanceReport>>());
    expect(runs, 1);
  });

  test(
    'after a run that worked, the next waits for the check interval',
    () async {
      await schedule.runIfDue();

      clock.advance(const Duration(hours: 5, minutes: 59));
      expect(await schedule.runIfDue(), isNull);
      expect(runs, 1, reason: 'every cycle offers a turn; few of them run');

      clock.advance(const Duration(minutes: 1));
      await schedule.runIfDue();
      expect(runs, 2);
    },
  );

  test('after a failed run, the next waits only the retry interval', () async {
    answer = () async =>
        const Result.failure(TransportFailure(TransportFailureKind.offline));
    await schedule.runIfDue();

    clock.advance(const Duration(minutes: 4));
    expect(await schedule.runIfDue(), isNull);
    expect(runs, 1);

    clock.advance(const Duration(minutes: 1));
    answer = () async => const Result.success(_report);
    await schedule.runIfDue();
    expect(runs, 2, reason: 'a plan left pending is resumed this soon');
  });

  test(
    'a service that cannot be composed is a failed run, not a throw',
    () async {
      answer = () => throw StateError('not the current full device');

      final result = await schedule.runIfDue();

      expect(result, isA<FailureResult<PrekeyMaintenanceReport>>());
      clock.advance(const Duration(minutes: 5));
      answer = () async => const Result.success(_report);
      await schedule.runIfDue();
      expect(runs, 2);
    },
  );

  test('no two runs overlap: a turn during a run joins it', () async {
    final release = Completer<Result<PrekeyMaintenanceReport>>();
    answer = () => release.future;

    final first = schedule.runIfDue();
    final second = schedule.runIfDue();
    final third = schedule.runIfDue();
    expect(runs, 1, reason: 'one plan per device state at a time');

    release.complete(const Result.success(_report));
    final results = await Future.wait([first, second, third]);

    expect(results.every((result) => result is Success), isTrue);
    expect(runs, 1);
    expect(await schedule.runIfDue(), isNull, reason: 'the run counted');
  });

  test('a clock set back does not hold maintenance off', () async {
    await schedule.runIfDue();

    clock.advance(const Duration(days: -3));
    await schedule.runIfDue();

    expect(runs, 2);
  });
}

const _report = PrekeyMaintenanceReport(
  counts: PrekeyCounts(classical: 150, postQuantum: 75),
  uploaded: false,
  rotated: false,
);

final class _Clock implements TimeSource {
  _Clock(this.value);

  DateTime value;

  void advance(Duration duration) => value = value.add(duration);

  @override
  DateTime now() => value;
}
