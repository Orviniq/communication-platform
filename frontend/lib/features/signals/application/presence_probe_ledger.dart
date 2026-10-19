import 'dart:math' as math;

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';

/// The probe rules of ADR-098 D6, kept by the sender for each peer device. A
/// probe is a watch to a device not heard from in 40 s, which the server
/// drops whenever that device has no socket, and each drop leaves a dead
/// skipped key on its session for good. These rules are what bound that.
///
/// - **P1.** After the last frame committed from a device, at most
///   [probesPerSilence] probes go to it, then none until it is heard again.
/// - **P2.** A probe takes a token from that device's bucket of
///   [bucketCapacity], which gains one every [refillInterval], and at most
///   one probe a [minimumProbeInterval] goes to one device: at most 8 in any
///   24 hours.
///
/// A committed frame resets P1, never P2. A store that cannot be read or
/// written allows no probe.
final class PresenceProbeLedger {
  const PresenceProbeLedger(this.store);

  static const probesPerSilence = 4;
  static const bucketCapacity = 4;
  static const refillInterval = Duration(hours: 6);
  static const minimumProbeInterval = Duration(minutes: 1);

  final PresenceLedgerPort store;

  /// Whether a probe may go to [device] at [now].
  Future<bool> allows(PresenceDevice device, DateTime now) async {
    final read = await store.read(
      userId: device.userId,
      deviceId: device.deviceId,
    );
    if (read case FailureResult()) {
      return false;
    }
    final entry = (read as Success<PresenceLedgerEntry?>).value;
    if (entry == null) {
      return true;
    }
    final nowMs = now.millisecondsSinceEpoch;
    final lastProbe = entry.lastProbeMs;
    return entry.probesSinceHeard < probesPerSilence &&
        (lastProbe == null ||
            nowMs - lastProbe >= minimumProbeInterval.inMilliseconds) &&
        _refilled(entry, nowMs).tokens >= 1;
  }

  /// Spends one probe on [device], at [now]. Run only for a probe that was
  /// sealed.
  Future<void> recordProbe(PresenceDevice device, DateTime now) async {
    final read = await store.read(
      userId: device.userId,
      deviceId: device.deviceId,
    );
    if (read case FailureResult()) {
      return;
    }
    final nowMs = now.millisecondsSinceEpoch;
    final entry =
        (read as Success<PresenceLedgerEntry?>).value ??
        PresenceLedgerEntry(
          userId: device.userId.toLowerCase(),
          deviceId: device.key,
          probesSinceHeard: 0,
          tokens: bucketCapacity,
          tokensAtMs: nowMs,
          lastProbeMs: null,
        );
    final refilled = _refilled(entry, nowMs);
    await store.write(
      refilled.copyWith(
        probesSinceHeard: entry.probesSinceHeard + 1,
        tokens: math.max(0, refilled.tokens - 1),
        lastProbeMs: nowMs,
      ),
    );
  }

  /// A frame from [device] was committed. Writes only when probes are
  /// outstanding (ADR-098 D8).
  Future<void> heard(PresenceDevice device) async {
    final read = await store.read(
      userId: device.userId,
      deviceId: device.deviceId,
    );
    if (read case Success(
      value: final entry?,
    ) when entry.probesSinceHeard > 0) {
      await store.write(entry.copyWith(probesSinceHeard: 0));
    }
  }

  /// [entry]'s bucket at [nowMs]. A full bucket starts its refill clock
  /// again, so that it never banks the time it spent full.
  static PresenceLedgerEntry _refilled(PresenceLedgerEntry entry, int nowMs) {
    final interval = refillInterval.inMilliseconds;
    if (entry.tokens >= bucketCapacity) {
      return entry.copyWith(tokens: bucketCapacity, tokensAtMs: nowMs);
    }
    final elapsed = nowMs - entry.tokensAtMs;
    if (elapsed < interval) {
      return entry;
    }
    final gained = elapsed ~/ interval;
    final tokens = math.min(bucketCapacity, entry.tokens + gained);
    return entry.copyWith(
      tokens: tokens,
      tokensAtMs: tokens >= bucketCapacity
          ? nowMs
          : entry.tokensAtMs + gained * interval,
    );
  }
}
