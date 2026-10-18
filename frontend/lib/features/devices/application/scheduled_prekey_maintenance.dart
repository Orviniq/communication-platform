// ignore_for_file: prefer_initializing_formals

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/domain/prekey_maintenance_model.dart';

/// When prekey maintenance runs, and that it never runs twice at once
/// (ADR-095).
///
/// The delivery cycle offers it a turn at the end of every healthy cycle, which
/// can be many times a minute; this decides which of those turns does any
/// work. The first turn of a process runs, then one every [checkInterval] after
/// a run that succeeded, or every [retryInterval] after one that failed. A
/// failed run includes a plan left pending (ADR-095 D4), so the shorter wait is
/// also what bounds how long a pending plan defers a first message.
///
/// The schedule is memory only. A new process starts due, so the deferred
/// catch-up, which starts a process of its own, checks once per run: one count
/// request when nothing is due.
final class ScheduledPrekeyMaintenance {
  ScheduledPrekeyMaintenance({
    required Future<Result<PrekeyMaintenanceReport>> Function() maintain,
    required TimeSource clock,
    this.checkInterval = const Duration(hours: 6),
    this.retryInterval = const Duration(minutes: 5),
  }) : _maintain = maintain,
       _clock = clock;

  final Future<Result<PrekeyMaintenanceReport>> Function() _maintain;
  final TimeSource _clock;
  final Duration checkInterval;
  final Duration retryInterval;

  DateTime? _nextDueAt;
  Future<Result<PrekeyMaintenanceReport>?>? _active;

  /// Runs maintenance if it is due, and answers null when it was not.
  ///
  /// A call while a run is in flight joins that run instead of starting a
  /// second: two runs would prepare two plans against one device state, and
  /// the store refuses the second only after its keys were generated.
  Future<Result<PrekeyMaintenanceReport>?> runIfDue() {
    final active = _active;
    if (active != null) {
      return active;
    }
    if (!_isDue(_clock.now())) {
      return Future.value();
    }
    final run = _run();
    _active = run;
    return run.whenComplete(() {
      if (identical(_active, run)) {
        _active = null;
      }
    });
  }

  bool _isDue(DateTime now) {
    final dueAt = _nextDueAt;
    if (dueAt == null || !now.isBefore(dueAt)) {
      return true;
    }
    // A clock set back would otherwise hold maintenance off for as long as it
    // was moved. No wait is longer than the check interval, so a due time
    // further away than that can only come from a clock that went backwards.
    return dueAt.difference(now) > checkInterval;
  }

  Future<Result<PrekeyMaintenanceReport>> _run() async {
    Result<PrekeyMaintenanceReport> result;
    try {
      result = await _maintain();
    } on Object {
      // Composing the service can throw: storage that will not open, or a
      // session that is no longer the current full device. Either is a failed
      // run, retried on the shorter wait like any other.
      result = const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    _nextDueAt = _clock.now().add(
      result is Success<PrekeyMaintenanceReport>
          ? checkInterval
          : retryInterval,
    );
    return result;
  }
}
