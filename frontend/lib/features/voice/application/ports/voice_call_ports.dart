import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';

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
