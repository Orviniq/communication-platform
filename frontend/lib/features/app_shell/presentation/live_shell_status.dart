import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/features/app_shell/presentation/app_shell.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The shell's status with the call in progress laid over it: the banner's
/// room, its name and its microphone, and whether the Voice Rooms tab offers
/// to create a room.
///
/// It reads the call's mirror, which composes nothing, and the room's name
/// only while a call runs, so the shell opens no database and no signalling
/// to learn that no call is in progress. Shell and route harnesses that render
/// without the production ProviderScope get [base] unchanged, as the chat list
/// falls back for them.
class LiveShellStatus extends StatelessWidget {
  const LiveShellStatus({
    required this.base,
    required this.location,
    required this.builder,
    super.key,
  });

  final AppShellStatus base;
  final String location;
  final Widget Function(AppShellStatus status) builder;

  @override
  Widget build(BuildContext context) {
    try {
      ProviderScope.containerOf(context);
    } on StateError {
      return builder(base);
    }
    return Consumer(
      builder: (context, ref, _) {
        final call = ref.watch(voiceCallMirrorProvider);
        final roomId = call.roomId;
        final roomName = roomId == null
            ? null
            : ref.watch(voiceRoomProvider(roomId)).value?.name;
        // Read only where the compose button can show it.
        final composeAvailable =
            !location.startsWith('/voice-rooms') ||
            ref.watch(voiceAvailabilityProvider);
        return builder(
          AppShellStatus(
            connection: base.connection,
            activeVoiceRoomId: roomId ?? base.activeVoiceRoomId,
            activeVoiceRoomName: roomId == null
                ? base.activeVoiceRoomName
                : roomName,
            activeVoiceMuted: roomId == null
                ? base.activeVoiceMuted
                : call.muted,
            voiceRoomsComposeAvailable:
                base.voiceRoomsComposeAvailable && composeAvailable,
          ),
        );
      },
    );
  }
}
