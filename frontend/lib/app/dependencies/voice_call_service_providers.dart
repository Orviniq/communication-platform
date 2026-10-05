import 'dart:async';

import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/app/dependencies/voice_providers.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
import 'package:communication_platform/features/voice/application/voice_call_controller.dart';
import 'package:communication_platform/features/voice/application/voice_call_service_guard.dart';
import 'package:communication_platform/features/voice/infrastructure/platform_voice_call_channel.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The call entry's text, in the locale the application itself runs in.
///
/// Resolved through Flutter's own supported-locale resolution rather than left
/// to Android string resources, so that one catalogue is reviewed, one
/// catalogue is translated, and the shade can never speak a different language
/// from the screen behind it.
Future<VoiceCallServiceStrings> resolveVoiceCallServiceStrings() async {
  final locale = basicLocaleListResolution(
    WidgetsBinding.instance.platformDispatcher.locales,
    AppLocalizations.supportedLocales,
  );
  final l10n = await AppLocalizations.delegate.load(locale);
  return VoiceCallServiceStrings(
    title: l10n.voiceCallNotificationTitle,
    channelName: l10n.voiceCallChannelName,
    channelDescription: l10n.voiceCallChannelDescription,
  );
}

/// The microphone permission. Composing it asks for nothing: the join asks,
/// and nothing else does (`backend/CLIENT_CONTRACT.md` §N rule 11).
final microphonePermissionProvider = Provider<MicrophonePermissionPort>(
  (ref) => const PlatformMicrophonePermission(),
);

/// The platform's call service, unguarded. Overridden by tests, which have no
/// platform channel; everything else reads [voiceCallServiceProvider].
final voiceCallServicePlatformProvider = Provider<VoiceCallServicePort>(
  (ref) => PlatformVoiceCallService(
    microphone: ref.watch(microphonePermissionProvider),
    strings: resolveVoiceCallServiceStrings,
  ),
);

/// The call service for one signed-in device, held to its call: started by
/// the join, and stopped when the call ends or this is disposed.
final voiceCallServiceProvider =
    FutureProvider.family<VoiceCallServicePort, MessagingScope>((
      ref,
      scope,
    ) async {
      final engine = await ref.watch(voiceCallEngineProvider(scope).future);
      final guard = VoiceCallServiceGuard(
        service: ref.watch(voiceCallServicePlatformProvider),
        calls: engine.states,
      );
      ref.onDispose(() => unawaited(guard.dispose()));
      return guard;
    });

/// Whether the session [scope] belongs to is still the one running: false from
/// the moment a logout or an erasure begins, and once a revocation or any other
/// end of the session has signed the account out.
final voiceSessionActiveProvider = Provider.family<bool, MessagingScope>((
  ref,
  scope,
) {
  final session = ref.watch(authenticationControllerProvider);
  return !session.isTearingDown && session.userId == scope.userId;
});

/// The join and the leave for one signed-in device: the microphone, then the
/// call service, then the call (`backend/CLIENT_CONTRACT.md` §N rule 11).
///
/// The one place the microphone permission is put to use. Composing it asks
/// for nothing: only a join the user asked for does. It also keeps
/// [voiceCallMirrorProvider] in step with the call, which is how the shell
/// learns of a call without composing one.
///
/// **A call ends with its session.** Nothing else would end it: the engine
/// outlives the screens, and a logout, an erasure or a revocation closes the
/// database without telling the call, whose connections and capture would
/// carry on with nobody signed in. So the session's end is a leave, which
/// closes every connection, gives the microphone back and stops the service.
final voiceCallControllerProvider =
    FutureProvider.family<VoiceCallController, MessagingScope>((
      ref,
      scope,
    ) async {
      final engine = await ref.watch(voiceCallEngineProvider(scope).future);
      final service = await ref.watch(voiceCallServiceProvider(scope).future);
      final controller = VoiceCallController(
        call: engine,
        microphone: ref.watch(microphonePermissionProvider),
        service: service,
        availability: ref.watch(relayCredentialServiceProvider),
      );
      final mirror = ref.read(voiceCallMirrorProvider.notifier);
      final following = engine.states.listen(mirror.follow);
      ref.listen(voiceSessionActiveProvider(scope), (_, active) {
        if (!active) {
          unawaited(controller.leave());
        }
      });
      ref.onDispose(() {
        unawaited(following.cancel());
        unawaited(controller.dispose());
      });
      return controller;
    });
