import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';

/// Starts, on the durable path, the pairwise sessions a call will need, and
/// routes the requests that start them into the pairwise outbox
/// (`voice-signalling-v1.md`, Starting the sessions a call needs).
///
/// A call's frames are volatile and never start a session, so the call runs
/// this before its first frame. A device whose request is committed but not
/// yet fetched drops the first frames it is sent and takes a later attempt.
abstract interface class VoiceCallSessionsPort implements Port {
  Future<Result<void>> prepareSessionsForCall(String roomId);
}

/// The jitter of the retry schedule: a value in `[0, 1)` for each wait. It
/// spreads the retries of devices that joined together; it is not a secret.
abstract interface class VoiceRetryJitterPort implements Port {
  double next();
}

/// This device's call, one at a time for the process: what the join and the
/// screens drive. `VoiceCallEngine` is the implementation.
abstract interface class VoiceCallPort implements Port {
  VoiceCallState get state;

  /// The state now, then every change.
  Stream<VoiceCallState> get states;

  /// Joins a call in the room whose hex id is [roomId]. The microphone
  /// permission must already have been asked for.
  Future<VoiceJoinOutcome> join(String roomId);

  Future<void> leave();

  Future<Result<void>> sendRoomText(String text);

  /// Announces this device again to one peer that is not reachable.
  Future<void> tryAgain(String deviceId);

  Future<void> setMuted(bool muted);
}

/// Whether a call may be offered at all: the deployment publishes
/// `voice_configured` true, and the relay route has not answered
/// `503 voice_unconfigured` since this process started.
abstract interface class VoiceAvailabilityPort implements Port {
  bool get isVoiceAvailable;
}
