import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/config/app_environment_banner.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

enum AppConnectionState { connected, connecting, offline }

@immutable
class AppShellStatus {
  const AppShellStatus({
    this.connection = AppConnectionState.connected,
    this.activeVoiceRoomId,
    this.activeVoiceRoomName,
    this.activeVoiceMuted = false,
    this.voiceRoomsComposeAvailable = true,
  });

  final AppConnectionState connection;

  /// The room of the call in progress: what the banner returns to. The banner
  /// shows while it is set, and only then.
  final String? activeVoiceRoomId;

  /// The room's name, once this device has read it.
  final String? activeVoiceRoomName;

  /// Whether the call's microphone is muted, which the banner shows.
  final bool activeVoiceMuted;

  /// Whether the Voice Rooms tab offers to create a room. False when the
  /// deployment serves no voice (`ui-specification.md` §13.0).
  final bool voiceRoomsComposeAvailable;

  AppShellStatus copyWith({AppConnectionState? connection}) => AppShellStatus(
    connection: connection ?? this.connection,
    activeVoiceRoomId: activeVoiceRoomId,
    activeVoiceRoomName: activeVoiceRoomName,
    activeVoiceMuted: activeVoiceMuted,
    voiceRoomsComposeAvailable: voiceRoomsComposeAvailable,
  );
}

enum AppDestination { chats, voiceRooms, settings }

extension on AppDestination {
  /// The branch's own route. Anything longer is a page pushed on top of it.
  String get rootLocation => switch (this) {
    AppDestination.chats => '/chats',
    AppDestination.voiceRooms => '/voice-rooms',
    AppDestination.settings => '/settings',
  };

  String label(AppLocalizations l10n) => switch (this) {
    AppDestination.chats => l10n.chatsDestination,
    AppDestination.voiceRooms => l10n.voiceRoomsDestination,
    AppDestination.settings => l10n.settingsDestination,
  };

  AppIconData get icon => switch (this) {
    AppDestination.chats => AppIcons.chats,
    AppDestination.voiceRooms => AppIcons.voiceRooms,
    AppDestination.settings => AppIcons.settings,
  };
}

class AppShell extends StatefulWidget {
  const AppShell({
    required this.environment,
    required this.navigationShell,
    required this.location,
    this.status = const AppShellStatus(),
    super.key,
  });

  final AppEnvironment environment;
  final StatefulNavigationShell navigationShell;

  /// Path of the route currently on screen, branch sub-routes included.
  final String location;

  final AppShellStatus status;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final List<FocusScopeNode> _destinationFocusScopes;

  @override
  void initState() {
    super.initState();
    _destinationFocusScopes = List.generate(
      AppDestination.values.length,
      (index) => FocusScopeNode(debugLabel: 'destination-$index'),
    );
  }

  @override
  void dispose() {
    for (final node in _destinationFocusScopes) {
      node.dispose();
    }
    super.dispose();
  }

  void _selectDestination(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _destinationFocusScopes[index].requestFocus();
      }
    });
  }

  void _compose() {
    switch (AppDestination.values[widget.navigationShell.currentIndex]) {
      case AppDestination.chats:
        context.go('/chats/new');
      case AppDestination.voiceRooms:
        context.go('/voice-rooms/new');
      case AppDestination.settings:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final environmentBanner = widget.environment.configurationBanner(l10n);
    final selected = widget.navigationShell.currentIndex;
    final destination = AppDestination.values[selected];
    // Compose belongs to the destination's own screen. On a page pushed above
    // it — a conversation, a room, a contact — the shell has nothing to compose
    // and its button only gets in the way of the page's own controls: the
    // narrow layout floats it directly over the chat composer's send button.
    final onCompose =
        destination == AppDestination.settings ||
            widget.location != destination.rootLocation ||
            (destination == AppDestination.voiceRooms &&
                !widget.status.voiceRoomsComposeAvailable)
        ? null
        : _compose;
    // The banner returns to the call, so the call's own screen does not show
    // it: everywhere else it stays until the call ends.
    final callRoomId = widget.status.activeVoiceRoomId;
    final banner =
        callRoomId == null || widget.location == '/voice-rooms/$callRoomId/call'
        ? null
        : _VoiceRoomBanner(
            roomId: callRoomId,
            roomName: widget.status.activeVoiceRoomName,
            muted: widget.status.activeVoiceMuted,
          );
    final widthClass = AppBreakpoints.of(MediaQuery.sizeOf(context).width);
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.digit1, alt: true): () =>
          _selectDestination(0),
      const SingleActivator(LogicalKeyboardKey.digit2, alt: true): () =>
          _selectDestination(1),
      const SingleActivator(LogicalKeyboardKey.digit3, alt: true): () =>
          _selectDestination(2),
    };

    Widget content = FocusScope(
      node: _destinationFocusScopes[selected],
      child: widget.navigationShell,
    );
    content = Column(
      children: [
        if (environmentBanner != null)
          _EnvironmentBanner(label: environmentBanner),
        if (widget.status.connection != AppConnectionState.connected)
          _ConnectionStrip(connection: widget.status.connection),
        Expanded(child: content),
      ],
    );

    final shell = switch (widthClass) {
      AppWidthClass.narrow => _NarrowShell(
        selected: selected,
        banner: banner,
        onSelect: _selectDestination,
        onCompose: onCompose,
        child: content,
      ),
      AppWidthClass.medium => _TwoPaneShell(
        compact: true,
        selected: selected,
        banner: banner,
        onSelect: _selectDestination,
        onCompose: onCompose,
        child: content,
      ),
      AppWidthClass.wide => _TwoPaneShell(
        compact: false,
        selected: selected,
        banner: banner,
        onSelect: _selectDestination,
        onCompose: onCompose,
        child: content,
      ),
    };

    return RepaintBoundary(
      key: const ValueKey('app-shell-golden'),
      child: CallbackShortcuts(
        bindings: shortcuts,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Semantics(
            container: true,
            label: l10n.keyboardNavigationHint,
            child: shell,
          ),
        ),
      ),
    );
  }
}

class _NarrowShell extends StatelessWidget {
  const _NarrowShell({
    required this.selected,
    required this.banner,
    required this.onSelect,
    required this.onCompose,
    required this.child,
  });

  final int selected;
  final Widget? banner;
  final ValueChanged<int> onSelect;
  final VoidCallback? onCompose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('shell-narrow'),
      backgroundColor: context.tokens.colors.canvas,
      body: SafeArea(bottom: false, child: child),
      floatingActionButton: onCompose == null
          ? null
          : _ComposeButton(
              label: selected == AppDestination.chats.index
                  ? l10n.composeChat
                  : l10n.composeVoiceRoom,
              onPressed: onCompose!,
            ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: context.tokens.colors.surface,
          border: Border(top: BorderSide(color: context.tokens.colors.border)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?banner,
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x2,
                  vertical: AppSpacing.x2,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final destination in AppDestination.values)
                      Expanded(
                        child: _DestinationControl(
                          destination: destination,
                          selected: selected == destination.index,
                          compact: true,
                          onPressed: () => onSelect(destination.index),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TwoPaneShell extends StatelessWidget {
  const _TwoPaneShell({
    required this.compact,
    required this.selected,
    required this.banner,
    required this.onSelect,
    required this.onCompose,
    required this.child,
  });

  final bool compact;
  final int selected;
  final Widget? banner;
  final ValueChanged<int> onSelect;
  final VoidCallback? onCompose;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: ValueKey(compact ? 'shell-medium' : 'shell-wide'),
    backgroundColor: context.tokens.colors.canvas,
    body: SafeArea(
      child: Row(
        children: [
          SizedBox(
            width: compact
                ? AppContentWidths.navigationMedium
                : AppContentWidths.navigationWide,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.tokens.colors.surface,
                border: BorderDirectional(
                  end: BorderSide(color: context.tokens.colors.border),
                ),
              ),
              child: _DestinationRail(
                compact: compact,
                selected: selected,
                banner: banner,
                onSelect: onSelect,
                onCompose: onCompose,
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    ),
  );
}

class _DestinationRail extends StatelessWidget {
  const _DestinationRail({
    required this.compact,
    required this.selected,
    required this.banner,
    required this.onSelect,
    required this.onCompose,
  });

  final bool compact;
  final int selected;
  final Widget? banner;
  final ValueChanged<int> onSelect;
  final VoidCallback? onCompose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?banner,
        Padding(
          padding: const EdgeInsets.all(AppSpacing.x3),
          child: compact
              ? AppIcon(AppIcons.security, color: context.tokens.colors.accent)
              : Text(
                  l10n.appTitle,
                  style: context.tokens.typography.section,
                  maxLines: 2,
                ),
        ),
        for (final destination in AppDestination.values)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x2,
              vertical: AppSpacing.x1,
            ),
            child: _DestinationControl(
              destination: destination,
              selected: selected == destination.index,
              compact: compact,
              onPressed: () => onSelect(destination.index),
            ),
          ),
        if (onCompose != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x3),
            child: _ComposeButton(
              label: selected == AppDestination.chats.index
                  ? l10n.composeChat
                  : l10n.composeVoiceRoom,
              onPressed: onCompose!,
              compact: compact,
            ),
          ),
        const Spacer(),
        // The navigation rail carried a permanent "Structural placeholder - not
        // for shipping" footer here, in every build including production, where
        // it was simply false. The build's identity belongs to the environment
        // banner at the top of the shell, which production correctly omits, and
        // a second permanent label repeated beside it only competes with the
        // per-surface labels that do carry a consequence (ADR-045).
      ],
    );
  }
}

class _DestinationControl extends StatefulWidget {
  const _DestinationControl({
    required this.destination,
    required this.selected,
    required this.compact,
    required this.onPressed,
  });

  final AppDestination destination;
  final bool selected;
  final bool compact;
  final VoidCallback onPressed;

  @override
  State<_DestinationControl> createState() => _DestinationControlState();
}

class _DestinationControlState extends State<_DestinationControl> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    final l10n = AppLocalizations.of(context);
    final label = widget.destination.label(l10n);
    final active = widget.selected || _hovered;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onFocusChange: (focused) => setState(() => _focused = focused),
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (intent) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: AppMotion.effective(context, AppMotion.press),
            curve: AppMotion.enter,
            constraints: const BoxConstraints(
              minHeight: AppFocus.minimumTarget,
            ),
            padding: const EdgeInsets.all(AppSpacing.x2),
            decoration: BoxDecoration(
              color: active ? colors.accentSoft : Colors.transparent,
              border: Border.all(
                color: _focused
                    ? colors.accent
                    : widget.selected
                    ? colors.border
                    : Colors.transparent,
                width: _focused ? AppFocus.ringWidth : 1,
              ),
              borderRadius: AppRadii.compact,
            ),
            child: widget.compact
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(
                        widget.destination.icon,
                        color: widget.selected
                            ? colors.accent
                            : colors.textMuted,
                      ),
                      const SizedBox(height: AppSpacing.x1),
                      Text(
                        label,
                        style: context.tokens.typography.label.copyWith(
                          color: widget.selected
                              ? colors.accent
                              : colors.textMuted,
                        ),
                        textAlign: TextAlign.center,
                        softWrap: true,
                      ),
                    ],
                  )
                : Row(
                    children: [
                      AppIcon(
                        widget.destination.icon,
                        color: widget.selected
                            ? colors.accent
                            : colors.textMuted,
                      ),
                      const SizedBox(width: AppSpacing.x3),
                      Expanded(
                        child: Text(
                          label,
                          style: context.tokens.typography.body.copyWith(
                            color: widget.selected
                                ? colors.accent
                                : colors.textPrimary,
                            fontWeight: widget.selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _ComposeButton extends StatelessWidget {
  const _ComposeButton({
    required this.label,
    required this.onPressed,
    this.compact = true,
  });

  final String label;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Tooltip(
      message: label,
      child: Material(
        color: context.tokens.colors.accent,
        borderRadius: AppRadii.control,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.control,
          focusColor: context.tokens.colors.accentSoft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: AppFocus.minimumTarget,
              minHeight: AppFocus.minimumTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppIcon(AppIcons.add, color: context.tokens.colors.canvas),
                  if (!compact) ...[
                    const SizedBox(width: AppSpacing.x2),
                    Flexible(
                      child: Text(
                        label,
                        style: context.tokens.typography.compact.copyWith(
                          color: context.tokens.colors.canvas,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _EnvironmentBanner extends StatelessWidget {
  const _EnvironmentBanner({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    child: ColoredBox(
      color: context.tokens.colors.warning.withValues(alpha: 0.16),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x3,
          vertical: AppSpacing.x1,
        ),
        child: Text(
          label,
          style: context.tokens.typography.label,
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}

class _ConnectionStrip extends StatelessWidget {
  const _ConnectionStrip({required this.connection});

  final AppConnectionState connection;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = connection == AppConnectionState.connecting
        ? l10n.connectingStatus
        : l10n.offlineStatus;
    return Semantics(
      container: true,
      liveRegion: true,
      label: label,
      child: ColoredBox(
        color: context.tokens.colors.warning,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(
                AppIcons.warning,
                color: context.tokens.colors.canvas,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.x2),
              Flexible(
                child: Text(
                  label,
                  style: context.tokens.typography.compact.copyWith(
                    color: context.tokens.colors.canvas,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoiceRoomBanner extends StatelessWidget {
  const _VoiceRoomBanner({
    required this.roomId,
    required this.roomName,
    required this.muted,
  });

  final String roomId;

  /// Null until this device has read the room's name.
  final String? roomName;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = switch (roomName) {
      final name? => l10n.returnToVoiceRoom(name),
      null => l10n.voiceCallReturnBanner,
    };
    final microphone = muted ? l10n.voiceTileMuted : l10n.voiceTileMicOn;
    final colors = context.tokens.colors;
    return Semantics(
      key: const ValueKey('active-voice-banner'),
      button: true,
      label: '$label, $microphone',
      excludeSemantics: true,
      child: Material(
        color: colors.accentSoft,
        child: InkWell(
          onTap: () => context.go('/voice-rooms/$roomId/call'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppFocus.minimumTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppIcon(
                    muted ? AppIcons.microphoneOff : AppIcons.microphone,
                    color: colors.accent,
                    size: 18,
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Flexible(
                    child: Text(
                      label,
                      style: context.tokens.typography.compact.copyWith(
                        color: colors.accent,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
