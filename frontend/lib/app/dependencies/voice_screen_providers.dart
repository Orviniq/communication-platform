import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/dependencies/sync_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the voice screens read, beside the room state and the call.
///
/// Each is small and separately overridable, so a screen test supplies the
/// few facts a screen shows rather than a composed application.

/// The signed-in account and this device, or null while nobody is signed in.
final voiceScopeProvider = FutureProvider<MessagingScope?>((ref) async {
  final userId = ref.watch(
    authenticationControllerProvider.select((state) => state.userId),
  );
  if (userId == null) {
    return null;
  }
  final deviceId = await ref.watch(currentMessagingDeviceIdProvider.future);
  return (userId: userId, deviceId: deviceId);
});

/// Whether a call may be offered at all: the deployment publishes
/// `voice_configured` true, and no join has met `503 voice_unconfigured`
/// since this process started (`voice-signalling-v1.md`, The credential).
///
/// Until `GET /api/v1/config` has answered, the published value is the
/// stored one or the fallback, and the fallback is false: no call control is
/// offered before the deployment has said it serves voice.
final voiceAvailabilityProvider = Provider<bool>(
  (ref) =>
      ref.watch(publishedLimitsProvider).voiceConfigured &&
      !ref.watch(
        voiceCallMirrorProvider.select((call) => call.voiceRefusedByServer),
      ),
);

/// Whether the connection a call's signalling rides is up, as the delivery
/// session reports it.
///
/// While it is down the audio already flowing carries on, and room text,
/// joins and leaves do not (`voice-room-states.md` §5.4). A phase not read
/// yet is taken as up: there is nothing to warn about before anything is
/// known.
final voiceSignallingConnectedProvider = Provider<bool>((ref) {
  final phase = ref.watch(syncProjectionProvider).value?.connectionPhase;
  return switch (phase) {
    null || SyncConnectionPhase.online || SyncConnectionPhase.draining => true,
    _ => false,
  };
});

/// Whether this session started with no route to the server: the screens
/// show the rooms this device holds and offer no call until it connects.
final voiceOfflineProvider = Provider<bool>(
  (ref) => ref.watch(
    authenticationControllerProvider.select(
      (state) => state.access == AuthenticationRouteAccess.offlineFullScope,
    ),
  ),
);
