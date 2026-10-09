import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_text_direction.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// A bordered statement with an icon, so that its kind is never carried by
/// colour alone. [live] makes a screen reader announce it as it appears.
class VoiceNotice extends StatelessWidget {
  const VoiceNotice({
    required this.message,
    this.kind = AppStatusKind.neutral,
    this.icon,
    this.live = false,
    super.key,
  });

  final String message;
  final AppStatusKind kind;
  final AppIconData? icon;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    final (color, fallbackIcon) = switch (kind) {
      AppStatusKind.neutral => (colors.textMuted, AppIcons.info),
      AppStatusKind.information => (colors.accent, AppIcons.info),
      AppStatusKind.success => (colors.success, AppIcons.success),
      AppStatusKind.warning => (colors.warning, AppIcons.warning),
      AppStatusKind.danger => (colors.danger, AppIcons.error),
    };
    return Semantics(
      container: true,
      liveRegion: live,
      label: message,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceRaised,
          borderRadius: AppRadii.card,
          border: Border.all(
            color: kind == AppStatusKind.neutral ? colors.border : color,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(icon ?? fallbackIcon, color: color, size: 18),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Text(message, style: context.tokens.typography.compact),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A room's or a person's avatar: initials on a colour [seed] chooses, which
/// is the room's or the account's id, so one has one colour everywhere.
class VoiceAvatar extends StatelessWidget {
  const VoiceAvatar({
    required this.name,
    required this.seed,
    this.radius = 24,
    super.key,
  });

  final String name;
  final String seed;
  final double radius;

  @override
  Widget build(BuildContext context) => ContactAvatar(
    username: name,
    semanticLabel: name,
    authenticatedSeed: voiceAvatarSeed(seed),
    radius: radius,
  );
}

/// The stable colour seed an identifier gets, so one room or one person has
/// one colour on every voice screen.
int voiceAvatarSeed(String value) => value.codeUnits.fold<int>(
  0,
  (seed, unit) => ((seed * 31) + unit) & 0x7fffffff,
);

/// Text a member chose - a room's name, a person's name, a line of room text
/// - in the direction its own first strong character sets, whatever the
/// language around it.
class VoiceUserText extends StatelessWidget {
  const VoiceUserText(
    this.text, {
    this.style,
    this.maxLines,
    this.textAlign,
    super.key,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: style,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    textAlign: textAlign,
    textDirection: resolveFirstStrongDirection(text),
  );
}

/// A room's state in the list and in its info, as words and an icon.
class VoiceRoomStateLine extends StatelessWidget {
  const VoiceRoomStateLine({required this.state, this.devices = 0, super.key});

  final VoiceRoomRowState state;
  final int devices;

  static String label(
    AppLocalizations strings,
    VoiceRoomRowState state,
    int devices,
  ) => switch (state) {
    VoiceRoomRowState.live => strings.voiceRoomStateLive(devices),
    VoiceRoomRowState.empty => strings.voiceRoomStateEmpty,
    VoiceRoomRowState.waiting => strings.voiceRoomStateWaiting,
    VoiceRoomRowState.conflict => strings.voiceRoomStateConflict,
    VoiceRoomRowState.left => strings.voiceRoomStateLeft,
    VoiceRoomRowState.removed => strings.voiceRoomStateRemoved,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    final (icon, color) = switch (state) {
      VoiceRoomRowState.live => (AppIcons.connected, colors.accent),
      VoiceRoomRowState.empty => (AppIcons.voiceRooms, colors.textMuted),
      VoiceRoomRowState.waiting => (AppIcons.clock, colors.warning),
      VoiceRoomRowState.conflict => (AppIcons.warning, colors.warning),
      VoiceRoomRowState.left ||
      VoiceRoomRowState.removed => (AppIcons.info, colors.textMuted),
    };
    return Row(
      children: [
        AppIcon(icon, color: color, size: 16),
        const SizedBox(width: AppSpacing.x1),
        Flexible(
          child: Text(
            label(AppLocalizations.of(context), state, devices),
            style: context.tokens.typography.label.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// What a room that is not active says, on its info and in its call: why
/// joining, inviting, renaming or leaving waits, or why it has ended for this
/// device.
class VoiceRoomLifecycleNotice extends StatelessWidget {
  const VoiceRoomLifecycleNotice({
    required this.room,
    required this.people,
    super.key,
  });

  final RoomState room;
  final VoiceRoomPeople people;

  static String? message(
    AppLocalizations strings,
    RoomState room,
    VoiceRoomPeople people,
  ) => switch (room.lifecycle) {
    RoomLifecycle.active => null,
    RoomLifecycle.stateRecoveryRequired => strings.voiceRoomWaitingNotice,
    RoomLifecycle.forkQuarantined => strings.voiceRoomConflictNotice,
    RoomLifecycle.controlQuarantined =>
      strings.voiceRoomControlQuarantineNotice,
    RoomLifecycle.left => strings.voiceRoomLeftNotice,
    RoomLifecycle.removed => switch (room.removedByUserId) {
      final remover? => strings.voiceRoomRemovedByNotice(
        people.nameOf(remover),
      ),
      null => strings.voiceRoomRemovedNotice,
    },
  };

  @override
  Widget build(BuildContext context) {
    final text = message(AppLocalizations.of(context), room, people);
    if (text == null) {
      return const SizedBox.shrink();
    }
    return VoiceNotice(
      key: const ValueKey('voice-room-lifecycle-notice'),
      message: text,
      kind: AppStatusKind.warning,
      live: true,
    );
  }
}

/// Caps a voice screen's body at a readable measure on a wide window.
class VoiceResponsiveBody extends StatelessWidget {
  const VoiceResponsiveBody({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppContentWidths.readable),
      child: child,
    ),
  );
}

/// A sheet on a narrow window and a dialog on a wider one
/// (`voice-room-states.md` §7). Both scroll - the sheet by [showAppSheet], the
/// dialog by [showAppContentDialog] - so a large text scale never pushes an
/// action off the screen; both restore focus to what opened them when they
/// close.
Future<T?> showVoiceModal<T>({
  required BuildContext context,
  required String title,
  required Widget child,
}) {
  final narrow =
      AppBreakpoints.of(MediaQuery.sizeOf(context).width) ==
      AppWidthClass.narrow;
  if (!narrow) {
    return showAppContentDialog<T>(
      context: context,
      title: title,
      content: child,
    );
  }
  return showAppSheet<T>(
    context: context,
    semanticLabel: title,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: context.tokens.typography.section),
        ),
        const SizedBox(height: AppSpacing.x3),
        child,
      ],
    ),
  );
}

/// What a voice route shows while its providers resolve.
Widget voiceLoadingPage(BuildContext context) => Scaffold(
  body: Center(
    child: AppStatePanel.loading(
      title: AppLocalizations.of(context).voiceRoomsLoadingTitle,
    ),
  ),
);

/// What a voice route shows when its room is not on this device.
Widget voiceRoomMissingPage(BuildContext context) {
  final strings = AppLocalizations.of(context);
  return Scaffold(
    key: const ValueKey('voice-room-missing'),
    appBar: AppBar(),
    body: AppStatePanel.error(
      title: strings.voiceRoomNotFoundTitle,
      message: strings.voiceRoomNotFoundBody,
    ),
  );
}

/// Whether [roomId] can name a room at all: 32 bytes, as lowercase hex.
bool isVoiceRoomId(String roomId) =>
    roomId.length == RoomState.roomIdBytes * 2 &&
    RegExp(r'^[0-9a-f]+$').hasMatch(roomId);
