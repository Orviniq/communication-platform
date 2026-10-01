import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';

/// The microphone permission, `RECORD_AUDIO`.
///
/// **[request] belongs to the join and to nothing else** (`backend/
/// CLIENT_CONTRACT.md` §N rule 11): never at start-up, and never because a
/// screen opened. It must come before the call's first capture, because the
/// capture asks for the permission by itself when it is missing (ADR-078).
abstract interface class MicrophonePermissionPort implements Port {
  /// Asks Android for the microphone and completes with its answer. Android
  /// shows its dialog when it has one to show; a grant already held shows
  /// nothing.
  Future<MicrophonePermission> request();

  /// Whether the microphone is granted now. A check: it shows nothing and
  /// asks nobody.
  Future<bool> isGranted();
}

/// The microphone-type foreground service that keeps a call's capture alive
/// while the user looks at another screen or another application (§N rule
/// 11).
///
/// The join starts it after the microphone grant and before the join itself,
/// while the application is in the foreground, which is the only time the
/// platform allows it. It stops when the call ends; it must never outlive the
/// call.
abstract interface class VoiceCallServicePort implements Port {
  /// Starts the service, and completes once it runs or has been refused. A
  /// refusal is a value, never a throw, and never a start that did not
  /// happen.
  Future<VoiceCallServiceStart> start();

  /// Stops it, and its entry goes with it. Harmless when nothing runs.
  Future<void> stop();
}
