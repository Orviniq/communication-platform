import 'dart:async';

import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
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
