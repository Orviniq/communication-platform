import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_components.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The Voice Rooms tab (`ui-specification.md` §13.0).
///
/// It reads the rooms this device holds and the call it is in, and asks for
/// nothing: no microphone, no credential and no connection. A row opens the
/// room's info, whatever the room's state, so a tap never starts a call.
class VoiceRoomsPage extends StatelessWidget {
  const VoiceRoomsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Shell and route harnesses render without the production ProviderScope,
    // exactly as they do for the chat list.
    try {
      ProviderScope.containerOf(context);
    } on StateError {
      return const VoiceRoomsView(rows: []);
    }
    return Consumer(
      builder: (context, ref, _) {
        final rooms = ref.watch(voiceRoomsProvider);
        final call = ref.watch(voiceCallMirrorProvider);
        return VoiceRoomsView(
          rows: VoiceRoomRow.fromRooms(
            rooms.value ?? const [],
            callRoomId: call.roomId,
            callDevices: call.devices,
          ),
          loading: !rooms.hasValue && !rooms.hasError,
          failed: !rooms.hasValue && rooms.hasError,
          offline: ref.watch(voiceOfflineProvider),
          voiceAvailable: ref.watch(voiceAvailabilityProvider),
        );
      },
    );
  }
}

class VoiceRoomsView extends StatelessWidget {
  const VoiceRoomsView({
    required this.rows,
    this.loading = false,
    this.failed = false,
    this.offline = false,
    this.voiceAvailable = true,
    super.key,
  });

  final List<VoiceRoomRow> rows;
  final bool loading;
  final bool failed;
  final bool offline;

  /// Whether this deployment serves voice. When it does not, the screen says
  /// so and offers no way to create a room, and the shell hides its compose
  /// button too.
  final bool voiceAvailable;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final Widget body;
    if (loading) {
      body = AppStatePanel.loading(
        title: strings.voiceRoomsLoadingTitle,
        message: strings.voiceRoomsLoadingBody,
      );
    } else if (failed) {
      body = AppStatePanel.error(
        title: strings.voiceRoomsErrorTitle,
        message: strings.voiceRoomsErrorBody,
      );
    } else if (rows.isEmpty) {
      body = voiceAvailable
          ? AppStatePanel.empty(
              key: const ValueKey('voice-rooms-empty'),
              title: strings.voiceRoomsEmptyTitle,
              message: strings.voiceRoomsEmptyBody,
              actionLabel: strings.voiceRoomsCreateAction,
              onAction: () => context.go('/voice-rooms/new'),
            )
          : AppStatePanel.empty(
              key: const ValueKey('voice-rooms-no-voice'),
              title: strings.voiceRoomsNoVoiceTitle,
              message: strings.voiceRoomsNoVoiceBody,
            );
    } else {
      body = VoiceResponsiveBody(
        child: ListView(
          key: const PageStorageKey('voice-rooms-list'),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
          children: [
            if (!voiceAvailable)
              _Padded(
                child: VoiceNotice(
                  key: const ValueKey('voice-rooms-no-voice'),
                  message: strings.voiceRoomsNoVoiceBody,
                  kind: AppStatusKind.warning,
                ),
              ),
            for (final row in rows) _RoomRow(row: row),
          ],
        ),
      );
    }
    return Scaffold(
      key: const ValueKey('voice-rooms-screen'),
      appBar: AppBar(title: Text(strings.voiceRoomsDestination)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (offline)
            _Padded(
              child: VoiceNotice(
                key: const ValueKey('voice-rooms-offline'),
                message: strings.voiceRoomsOfflineNotice,
                kind: AppStatusKind.warning,
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _RoomRow extends StatelessWidget {
  const _RoomRow({required this.row});

  final VoiceRoomRow row;

  @override
  Widget build(BuildContext context) {
    final state = VoiceRoomStateLine.label(
      AppLocalizations.of(context),
      row.state,
      row.devices,
    );
    return Semantics(
      key: ValueKey('voice-room-row-${row.roomId}'),
      button: true,
      label: '${row.name}, $state',
      excludeSemantics: true,
      child: ListTile(
        minTileHeight: 64,
        leading: VoiceAvatar(name: row.name, seed: row.roomId),
        title: VoiceUserText(row.name, maxLines: 2),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.x1),
          child: VoiceRoomStateLine(state: row.state, devices: row.devices),
        ),
        onTap: () => context.go('/voice-rooms/${row.roomId}'),
      ),
    );
  }
}

class _Padded extends StatelessWidget {
  const _Padded({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.x4,
      AppSpacing.x3,
      AppSpacing.x4,
      AppSpacing.x2,
    ),
    child: child,
  );
}
