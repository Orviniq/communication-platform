import 'dart:async';

import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/voice_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/features/voice/application/room_call_sessions.dart';
import 'package:communication_platform/features/voice/application/voice_call_engine.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/infrastructure/pairwise_room_adapters.dart';
import 'package:communication_platform/features/voice/infrastructure/random_voice_retry_jitter.dart';
import 'package:communication_platform/features/voice/infrastructure/timer_voice_signal_timer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The call engine for one signed-in device: one for the process, because a
/// call is one for the process.
///
/// It reads the room through [roomStateReadPortProvider] and writes nothing
/// to it, signals over [voiceSignallingProvider], and mints through the
/// process's one [relayCredentialServiceProvider]. Composing it starts
/// nothing but listening: no credential is minted and no microphone is
/// opened until a join.
final voiceCallEngineProvider =
    FutureProvider.family<VoiceCallEngine, MessagingScope>((ref, scope) async {
      final engine = VoiceCallEngine(
        currentUserId: scope.userId,
        currentDeviceId: scope.deviceId,
        rooms: await ref.watch(roomStateReadPortProvider.future),
        liveDevices: await ref.watch(
          roomLiveDeviceResolverProvider(scope).future,
        ),
        sessions: RoomCallSessions(
          starter: await ref.watch(roomSessionStarterProvider(scope).future),
          dispatcher: await ref.watch(
            roomOutboundDispatcherProvider(scope).future,
          ),
          currentUserId: scope.userId,
          currentDeviceId: scope.deviceId,
        ),
        credentials: ref.watch(relayCredentialServiceProvider),
        signalling: await ref.watch(voiceSignallingProvider(scope).future),
        media: ref.watch(voicePeerMediaProvider),
        localAudio: ref.watch(voiceLocalAudioProvider),
        identity: NativeRoomIdentity(ref.watch(applicationProtocolProvider)),
        clock: ref.watch(timeSourceProvider),
        timer: const TimerVoiceSignalTimer(),
        jitter: RandomVoiceRetryJitter(),
      )..start();
      ref.onDispose(() => unawaited(engine.dispose()));
      return engine;
    });

/// The call as the application layer sees it: the state now, then every
/// change.
final voiceCallStateProvider =
    StreamProvider.family<VoiceCallState, MessagingScope>((ref, scope) async* {
      final engine = await ref.watch(voiceCallEngineProvider(scope).future);
      yield* engine.states;
    });
