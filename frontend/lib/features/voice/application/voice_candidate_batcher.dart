import 'dart:async';

import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// Sends one batch of candidates.
///
/// [end] is set on the last batch of a negotiation: no candidate will follow
/// it until an ICE restart begins another.
typedef VoiceCandidateFlush =
    Future<void> Function(
      List<VoiceIceCandidate> candidates, {
      required bool end,
    });

/// Gathers one negotiation's ICE candidates into batches for one peer
/// (`voice-signalling-v1.md`, "The socket limits").
///
/// A batch goes when gathering reaches `complete`, or 500 ms after the first
/// candidate it holds, whichever comes first, and `end` is set on the last.
/// Relay-only ICE with BUNDLE gathers one candidate for each TURN URL, so a
/// negotiation is usually one frame; trickling one candidate to a frame would
/// multiply the count for nothing. A batch holds at most eight, and more go as
/// consecutive frames with `end` on the final one only.
///
/// It knows nothing of WebRTC: the connection feeds it candidates and tells it
/// when gathering is complete or restarts.
final class VoiceCandidateBatcher {
  VoiceCandidateBatcher({
    required this.flush,
    required this.timer,
    this.window = defaultWindow,
  });

  static const defaultWindow = Duration(milliseconds: 500);

  final Duration window;
  final VoiceCandidateFlush flush;
  final VoiceSignalTimerPort timer;

  final _held = <VoiceIceCandidate>[];
  var _windowOpen = false;
  var _complete = false;

  /// Moves on every [complete] and [restart], so that a window opened before
  /// either cannot send what came after.
  var _negotiation = 0;
  Future<void> _sending = Future<void>.value();

  /// Holds [candidate] for the next batch. A candidate after [complete] and
  /// before [restart] belongs to no negotiation and is dropped.
  void add(VoiceIceCandidate candidate) {
    if (_complete) {
      return;
    }
    _held.add(candidate);
    if (!_windowOpen) {
      _windowOpen = true;
      unawaited(_closeWindowAfterDelay(_negotiation));
    }
  }

  /// Gathering is complete: whatever is held goes now, the last batch with
  /// `end` set. With nothing held, one empty batch carries `end` alone.
  Future<void> complete() {
    if (_complete) {
      return _sending;
    }
    _complete = true;
    _negotiation += 1;
    _windowOpen = false;
    return _send(end: true);
  }

  /// An ICE restart: a fresh negotiation with a window and an `end` of its
  /// own. Nothing held from the last one is sent.
  void restart() {
    _negotiation += 1;
    _held.clear();
    _windowOpen = false;
    _complete = false;
  }

  Future<void> _closeWindowAfterDelay(int negotiation) async {
    await timer.wait(window);
    if (negotiation != _negotiation) {
      return;
    }
    _windowOpen = false;
    await _send(end: false);
  }

  Future<void> _send({required bool end}) {
    final candidates = List<VoiceIceCandidate>.of(_held);
    _held.clear();
    final batches = <List<VoiceIceCandidate>>[
      for (
        var start = 0;
        start < candidates.length;
        start += VoiceSignalLimits.maximumCandidates
      )
        candidates.sublist(
          start,
          start + VoiceSignalLimits.maximumCandidates < candidates.length
              ? start + VoiceSignalLimits.maximumCandidates
              : candidates.length,
        ),
    ];
    if (batches.isEmpty) {
      if (!end) {
        return _sending;
      }
      batches.add(const []);
    }
    // One after another, so that a timed batch still in flight when gathering
    // completes arrives before the batch that ends the negotiation.
    _sending = _sending.then((_) async {
      for (var index = 0; index < batches.length; index += 1) {
        await flush(batches[index], end: end && index == batches.length - 1);
      }
    });
    return _sending;
  }
}
