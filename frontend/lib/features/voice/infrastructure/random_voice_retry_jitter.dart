import 'dart:math';

import 'package:communication_platform/features/voice/application/ports/voice_call_ports.dart';

/// The retry schedule's jitter, drawn the way the delivery cycle draws its own.
final class RandomVoiceRetryJitter implements VoiceRetryJitterPort {
  RandomVoiceRetryJitter([Random? random])
    : _random = random ?? Random.secure();

  final Random _random;

  @override
  double next() => _random.nextDouble();
}
