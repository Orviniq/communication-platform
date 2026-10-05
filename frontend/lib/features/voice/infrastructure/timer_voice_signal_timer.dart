import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';

/// Waits on the platform clock.
final class TimerVoiceSignalTimer implements VoiceSignalTimerPort {
  const TimerVoiceSignalTimer();

  @override
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);
}
