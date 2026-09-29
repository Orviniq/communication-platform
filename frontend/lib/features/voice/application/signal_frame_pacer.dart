import 'dart:math' as math;

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';

/// Paces outbound `signal` frames: a bucket of 32 that refills at 24 a second
/// (`voice-signalling-v1.md`, "The socket limits").
///
/// A ten-device join sends 27 frames, so it leaves at once. The worst second
/// this can produce is a full bucket and a second's refill, 56 frames, which
/// leaves the socket's 100-frame rolling second with room for everything
/// else a later version sends.
///
/// Frames leave in the order they asked, and the arithmetic is in whole
/// micro-tokens so that it never drifts.
final class SignalFramePacer {
  SignalFramePacer({
    required this.clock,
    required this.timer,
    this.capacity = defaultCapacity,
    this.refillPerSecond = defaultRefillPerSecond,
  }) : assert(capacity > 0),
       assert(refillPerSecond > 0),
       _credit = capacity * _unit;

  static const defaultCapacity = 32;
  static const defaultRefillPerSecond = 24;

  /// One frame's worth of credit.
  static const _unit = 1000000;

  final int capacity;
  final int refillPerSecond;
  final TimeSource clock;
  final VoiceSignalTimerPort timer;

  int _credit;
  DateTime? _refilledAt;
  Future<void> _tail = Future<void>.value();

  /// Completes when one frame may leave.
  Future<void> acquire() {
    final turn = _tail.then((_) => _take());
    _tail = turn;
    return turn;
  }

  Future<void> _take() async {
    while (true) {
      _refill();
      if (_credit >= _unit) {
        _credit -= _unit;
        return;
      }
      // Credit accrues at refillPerSecond units a microsecond.
      final missing = _unit - _credit;
      await timer.wait(
        Duration(
          microseconds: (missing + refillPerSecond - 1) ~/ refillPerSecond,
        ),
      );
    }
  }

  void _refill() {
    final now = clock.now();
    final last = _refilledAt;
    _refilledAt = now;
    if (last == null) {
      return;
    }
    final elapsed = now.difference(last).inMicroseconds;
    if (elapsed > 0) {
      _credit = math.min(capacity * _unit, _credit + elapsed * refillPerSecond);
    }
  }
}
