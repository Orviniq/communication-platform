import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/dependencies/voice_call_service_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/voice/application/voice_call_controller.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_components.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_info_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_text_panel.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The Live Voice Room (`ui-specification.md` §10,
/// `voice-room-states.md` §5).
///
/// Opening it asks for nothing. The microphone is asked for by a join the
/// user starts - here, or from the room's info - and by nothing else.
class VoiceCallPage extends StatelessWidget {
  const VoiceCallPage({required this.roomId, super.key});

  final String roomId;

  @override
  Widget build(BuildContext context) {
    final normalized = roomId.toLowerCase();
    if (!isVoiceRoomId(normalized)) {
      return voiceRoomMissingPage(context);
    }
    try {
      ProviderScope.containerOf(context);
    } on StateError {
      return voiceLoadingPage(context);
    }
    return Consumer(
      builder: (context, ref, _) {
        final scope = ref.watch(voiceScopeProvider).value;
        final controller = scope == null
            ? null
            : ref.watch(voiceCallControllerProvider(scope)).value;
        final room = ref.watch(voiceRoomProvider(normalized));
        if (scope == null ||
            controller == null ||
            (!room.hasValue && !room.hasError)) {
          return voiceLoadingPage(context);
        }
        final contacts =
            ref.watch(contactListProvider(scope.userId)).value ??
            const <ContactProjection>[];
        return VoiceCallView(
          roomId: normalized,
          room: room.value,
          controller: controller,
          people: VoiceRoomPeople.fromContacts(scope.userId, contacts),
          voiceAvailable: ref.watch(voiceAvailabilityProvider),
          signallingConnected: ref.watch(voiceSignallingConnectedProvider),
          offline: ref.watch(voiceOfflineProvider),
          signalBuckets: ref.watch(publishedLimitsProvider).signalBuckets,
        );
      },
    );
  }
}

/// What the live room shows for one room, from the call and the join.
enum VoiceCallScreen {
  /// This device holds no such room.
  missing,

  /// The deployment serves no voice.
  unavailable,

  /// A call runs in another room.
  otherCall,

  /// The room cannot hold a call now: waiting for its state, forked, or
  /// this account is no longer a member.
  roomPaused,

  /// Nothing has been asked yet.
  preJoin,
  askingForMicrophone,
  startingService,
  connecting,
  inCall,
  microphoneRefused,
  serviceRefused,

  /// The call ended, or refused the join, for a reason the screen states.
  ended,
}

class VoiceCallView extends StatefulWidget {
  const VoiceCallView({
    required this.roomId,
    required this.room,
    required this.controller,
    required this.people,
    required this.signalBuckets,
    this.voiceAvailable = true,
    this.signallingConnected = true,
    this.offline = false,
    super.key,
  });

  /// The room's hex id, lowercase.
  final String roomId;

  /// Null when this device holds no such room.
  final RoomState? room;
  final VoiceCallController controller;
  final VoiceRoomPeople people;
  final Set<int> signalBuckets;
  final bool voiceAvailable;

  /// Whether the connection the signalling rides is up. While it is down the
  /// audio carries on, and room text, joins and leaves do not.
  final bool signallingConnected;
  final bool offline;

  @override
  State<VoiceCallView> createState() => _VoiceCallViewState();
}

class _VoiceCallViewState extends State<VoiceCallView> {
  late VoiceCallState _call;
  late VoiceJoinStatus _join;
  StreamSubscription<VoiceCallState>? _calls;
  StreamSubscription<VoiceJoinStatus>? _joins;

  /// The room text draft, held here so that moving the panel between a tab
  /// and a side panel keeps it.
  final _draft = TextEditingController();
  var _chatTab = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(VoiceCallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      unawaited(_calls?.cancel());
      unawaited(_joins?.cancel());
      _follow();
    }
  }

  void _follow() {
    _call = widget.controller.callState;
    _join = widget.controller.status;
    _calls = widget.controller.callStates.listen(
      (call) => setState(() => _call = call),
    );
    _joins = widget.controller.statuses.listen(
      (join) => setState(() => _join = join),
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_calls?.cancel());
    unawaited(_joins?.cancel());
    _draft.dispose();
    super.dispose();
  }

  bool get _here => _call.roomId == widget.roomId;

  bool get _joinHere => _join.roomId == widget.roomId;

  VoiceCallScreen get _screen {
    if (_call.isActive && _here) {
      return _call.phase == VoiceCallPhase.inCall
          ? VoiceCallScreen.inCall
          : VoiceCallScreen.connecting;
    }
    if (_call.isActive) {
      return VoiceCallScreen.otherCall;
    }
    if (_join.isJoining && _joinHere) {
      return switch (_join.step) {
        VoiceJoinStep.askingForMicrophone =>
          VoiceCallScreen.askingForMicrophone,
        VoiceJoinStep.startingService => VoiceCallScreen.startingService,
        _ => VoiceCallScreen.connecting,
      };
    }
    final room = widget.room;
    if (room == null) {
      return VoiceCallScreen.missing;
    }
    if (_endReason case final reason?) {
      return reason == VoiceCallEndReason.voiceUnavailable
          ? VoiceCallScreen.unavailable
          : VoiceCallScreen.ended;
    }
    if (_joinHere) {
      switch (_join.outcome) {
        case VoiceJoinMicrophoneRefused():
          return VoiceCallScreen.microphoneRefused;
        case VoiceJoinServiceRefused():
          return VoiceCallScreen.serviceRefused;
        default:
          break;
      }
    }
    if (!widget.voiceAvailable) {
      return VoiceCallScreen.unavailable;
    }
    if (!RoomAuthorization.mayAct(room, widget.people.currentUserId)) {
      return VoiceCallScreen.roomPaused;
    }
    return VoiceCallScreen.preJoin;
  }

  /// Why the last call in this room ended, or why its join was refused, when
  /// the screen has a reason to state: not the user's own leave.
  VoiceCallEndReason? get _endReason {
    VoiceCallEndReason? reason;
    if (_joinHere) {
      switch (_join.outcome) {
        case VoiceJoinCallRefused(reason: final refused):
          reason = refused;
        case VoiceJoinStarted() when _here:
          reason = _call.endReason;
        default:
          break;
      }
    } else if (_here) {
      reason = _call.endReason;
    }
    return reason == VoiceCallEndReason.left ? null : reason;
  }

  DateTime? get _retryAt => switch (_join.outcome) {
    VoiceJoinCallRefused(:final retryAt) when _joinHere => retryAt,
    _ => _here ? _call.retryAt : null,
  };

  @override
  Widget build(BuildContext context) {
    final screen = _screen;
    final strings = AppLocalizations.of(context);
    final inCall = screen == VoiceCallScreen.inCall;
    final controls = inCall || screen == VoiceCallScreen.connecting;
    return Scaffold(
      key: const ValueKey('voice-call-screen'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(
            key: const ValueKey('voice-call-top-bar'),
            name: widget.room?.name ?? strings.voiceRoomNotFoundTitle,
            count: controls
                ? (widget.signallingConnected
                      ? strings.voiceCallCount(_call.devicesInCall)
                      : strings.voiceCallCountStale(_call.devicesInCall))
                : null,
            roomId: widget.room == null ? null : widget.roomId,
            onMinimize: _minimize,
          ),
          // The page covers the whole screen (ui-specification.md §0.1). The
          // top bar takes the top inset, and the control bar the bottom one
          // when it shows; the body keeps clear of the rest.
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              removeBottom: controls,
              child: SafeArea(child: _body(context, strings, screen)),
            ),
          ),
          if (controls)
            _ControlBar(
              key: const ValueKey('voice-call-control-bar'),
              muted: _call.muted,
              connecting: !inCall,
              onMute: inCall
                  ? () => unawaited(widget.controller.setMuted(!_call.muted))
                  : null,
              onInvite: () =>
                  context.push('/voice-rooms/${widget.roomId}/invite'),
              onLeave: _leave,
            ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations strings,
    VoiceCallScreen screen,
  ) {
    switch (screen) {
      case VoiceCallScreen.inCall:
        return _inCall(context, strings);
      case VoiceCallScreen.connecting:
        return _CallPanel(
          key: const ValueKey('voice-call-connecting'),
          icon: AppIcons.connecting,
          title: strings.voiceCallConnectingTitle,
          message: strings.voiceCallConnectingBody,
          busy: true,
          footer: VoiceNotice(
            message: strings.voiceCallRelayNote,
            icon: AppIcons.relay,
          ),
        );
      case VoiceCallScreen.askingForMicrophone:
        return _CallPanel(
          key: const ValueKey('voice-call-asking'),
          icon: AppIcons.microphone,
          title: strings.voiceCallAskingMicrophone,
          busy: true,
        );
      case VoiceCallScreen.startingService:
        return _CallPanel(
          key: const ValueKey('voice-call-starting'),
          icon: AppIcons.microphone,
          title: strings.voiceCallStartingService,
          busy: true,
        );
      case VoiceCallScreen.preJoin:
        return _CallPanel(
          key: const ValueKey('voice-call-pre-join'),
          icon: AppIcons.microphone,
          title: strings.voiceCallPreJoinTitle,
          message: strings.voiceCallPreJoinBody,
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VoiceNotice(
                message: strings.voiceCallRelayNote,
                icon: AppIcons.relay,
              ),
              if (widget.offline) ...[
                const SizedBox(height: AppSpacing.x2),
                VoiceNotice(
                  key: const ValueKey('voice-call-offline'),
                  message: strings.voiceRoomJoinOffline,
                  kind: AppStatusKind.warning,
                ),
              ],
            ],
          ),
          actions: [
            AppButton(
              key: const ValueKey('voice-call-join'),
              label: strings.voiceCallJoinAction,
              leading: AppIcons.microphone,
              onPressed: widget.offline ? null : _joinCall,
            ),
            AppButton(
              label: strings.voiceCallNotNowAction,
              kind: AppButtonKind.ghost,
              onPressed: _minimize,
            ),
          ],
        );
      case VoiceCallScreen.microphoneRefused:
        final permanently = switch (_join.outcome) {
          VoiceJoinMicrophoneRefused(:final permanently) => permanently,
          _ => false,
        };
        return _CallPanel(
          key: const ValueKey('voice-call-microphone-refused'),
          icon: AppIcons.microphoneOff,
          title: strings.voiceCallMicDeniedTitle,
          message: permanently
              ? strings.voiceCallMicDeniedPermanentlyBody
              : strings.voiceCallMicDeniedBody,
          error: true,
          actions: [
            if (permanently)
              AppButton(
                key: const ValueKey('voice-call-open-settings'),
                label: strings.voiceCallOpenSettingsAction,
                onPressed: () =>
                    unawaited(widget.controller.openMicrophoneSettings()),
              ),
            AppButton(
              key: const ValueKey('voice-call-try-again'),
              label: strings.voiceCallTryAgainAction,
              kind: permanently ? AppButtonKind.outline : AppButtonKind.primary,
              onPressed: _joinCall,
            ),
            _backToRooms(strings),
          ],
        );
      case VoiceCallScreen.serviceRefused:
        final notInForeground = switch (_join.outcome) {
          VoiceJoinServiceRefused(:final reason) =>
            reason == VoiceCallServiceRefusal.notInForeground,
          _ => false,
        };
        return _CallPanel(
          key: const ValueKey('voice-call-service-refused'),
          icon: AppIcons.error,
          title: strings.voiceCallServiceRefusedTitle,
          message: notInForeground
              ? strings.voiceCallServiceNotInForegroundBody
              : strings.voiceCallServiceRefusedBody,
          error: true,
          actions: [
            AppButton(
              key: const ValueKey('voice-call-try-again'),
              label: strings.voiceCallTryAgainAction,
              onPressed: _joinCall,
            ),
            _backToRooms(strings),
          ],
        );
      case VoiceCallScreen.ended:
        return _ended(context, strings, _endReason!);
      case VoiceCallScreen.unavailable:
        return _CallPanel(
          key: const ValueKey('voice-call-no-voice'),
          icon: AppIcons.warning,
          title: strings.voiceCallNoVoiceTitle,
          message: strings.voiceCallNoVoiceBody,
          error: true,
          actions: [_backToRooms(strings)],
        );
      case VoiceCallScreen.otherCall:
        return _CallPanel(
          key: const ValueKey('voice-call-other-call'),
          icon: AppIcons.info,
          title: strings.voiceCallAlreadyInCallTitle,
          message: strings.voiceCallAlreadyInCallBody,
          actions: [
            if (_call.roomId case final other?)
              AppButton(
                label: strings.voiceRoomReturnToCallAction,
                onPressed: () => context.go('/voice-rooms/$other/call'),
              ),
            _backToRooms(strings),
          ],
        );
      case VoiceCallScreen.roomPaused:
        final room = widget.room!;
        final (title, message) = switch (room.lifecycle) {
          RoomLifecycle.stateRecoveryRequired => (
            strings.voiceCallWaitingTitle,
            strings.voiceCallWaitingBody,
          ),
          RoomLifecycle.forkQuarantined || RoomLifecycle.controlQuarantined => (
            strings.voiceCallConflictTitle,
            strings.voiceCallConflictBody,
          ),
          RoomLifecycle.left => (strings.voiceCallLeftRoomTitle, null),
          _ => (strings.voiceCallRemovedTitle, null),
        };
        return _CallPanel(
          key: const ValueKey('voice-call-room-paused'),
          icon: AppIcons.warning,
          title: title,
          message: message,
          footer: VoiceRoomLifecycleNotice(room: room, people: widget.people),
          actions: [_backToRooms(strings)],
        );
      case VoiceCallScreen.missing:
        return _CallPanel(
          icon: AppIcons.error,
          title: strings.voiceRoomNotFoundTitle,
          message: strings.voiceRoomNotFoundBody,
          error: true,
          actions: [_backToRooms(strings)],
        );
    }
  }

  Widget _ended(
    BuildContext context,
    AppLocalizations strings,
    VoiceCallEndReason reason,
  ) {
    final retryAt = _retryAt;
    final wait = reason == VoiceCallEndReason.throttled && retryAt != null
        ? retryAt.difference(DateTime.now())
        : Duration.zero;
    if (wait > Duration.zero) {
      // The countdown moves once a second and stops when it reaches zero.
      _tick ??= Timer(const Duration(seconds: 1), () {
        _tick = null;
        if (mounted) {
          setState(() {});
        }
      });
    }
    final (title, message, retryable) = switch (reason) {
      VoiceCallEndReason.callFull => (
        strings.voiceCallFullTitle,
        strings.voiceCallFullBody,
        true,
      ),
      VoiceCallEndReason.throttled => (
        strings.voiceCallThrottledTitle,
        strings.voiceCallThrottledBody,
        true,
      ),
      VoiceCallEndReason.credentialFailed => (
        strings.voiceCallOfflineTitle,
        strings.voiceCallOfflineBody,
        true,
      ),
      VoiceCallEndReason.localFailure => (
        strings.voiceCallLocalFailureTitle,
        strings.voiceCallLocalFailureBody,
        true,
      ),
      VoiceCallEndReason.roomWaitingForState => (
        strings.voiceCallWaitingTitle,
        strings.voiceCallWaitingBody,
        false,
      ),
      VoiceCallEndReason.roomQuarantined => (
        strings.voiceCallConflictTitle,
        strings.voiceCallConflictBody,
        false,
      ),
      VoiceCallEndReason.removedFromRoom => (
        strings.voiceCallRemovedTitle,
        strings.voiceCallEndedChatDropped,
        false,
      ),
      VoiceCallEndReason.leftRoom => (
        strings.voiceCallLeftRoomTitle,
        strings.voiceCallEndedChatDropped,
        false,
      ),
      VoiceCallEndReason.roomUnavailable => (
        strings.voiceRoomNotFoundTitle,
        strings.voiceRoomNotFoundBody,
        false,
      ),
      VoiceCallEndReason.alreadyInCall => (
        strings.voiceCallAlreadyInCallTitle,
        strings.voiceCallAlreadyInCallBody,
        true,
      ),
      VoiceCallEndReason.voiceUnavailable => (
        strings.voiceCallNoVoiceTitle,
        strings.voiceCallNoVoiceBody,
        false,
      ),
      VoiceCallEndReason.left => (strings.voiceCallPreJoinTitle, null, true),
    };
    final mayRetry =
        retryable &&
        widget.voiceAvailable &&
        widget.room != null &&
        RoomAuthorization.mayAct(widget.room!, widget.people.currentUserId);
    return _CallPanel(
      key: ValueKey('voice-call-ended-${reason.name}'),
      icon: reason == VoiceCallEndReason.callFull
          ? AppIcons.people
          : AppIcons.warning,
      title: title,
      message: message,
      error: true,
      actions: [
        if (mayRetry)
          AppButton(
            key: const ValueKey('voice-call-try-again'),
            label: wait > Duration.zero
                ? strings.voiceCallTryAgainIn(
                    (wait.inMilliseconds / 1000).ceil(),
                  )
                : strings.voiceCallTryAgainAction,
            onPressed: wait > Duration.zero ? null : _joinCall,
          ),
        _backToRooms(strings),
      ],
    );
  }

  Widget _inCall(BuildContext context, AppLocalizations strings) {
    final notificationHidden = switch (_join.outcome) {
      VoiceJoinStarted(:final notificationVisible) when _joinHere =>
        !notificationVisible,
      _ => false,
    };
    final people = _PeoplePane(
      call: _call,
      people: widget.people,
      onTile: _showParticipant,
      onTryAgain: (deviceId) => unawaited(widget.controller.tryAgain(deviceId)),
      onInvite: () => context.push('/voice-rooms/${widget.roomId}/invite'),
    );
    final chat = VoiceRoomTextPanel(
      entries: _call.roomText,
      people: widget.people,
      draft: _draft,
      signalBuckets: widget.signalBuckets,
      stale: !widget.signallingConnected,
      onSend: (text) async =>
          (await widget.controller.sendRoomText(text)) is Success<void>,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.signallingConnected)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.x4,
              AppSpacing.x3,
              AppSpacing.x4,
              0,
            ),
            child: VoiceNotice(
              key: const ValueKey('voice-call-socket-degraded'),
              message: strings.voiceCallSocketDegraded,
              icon: AppIcons.reconnecting,
              live: true,
            ),
          ),
        if (notificationHidden)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.x4,
              AppSpacing.x3,
              AppSpacing.x4,
              0,
            ),
            child: VoiceNotice(
              key: const ValueKey('voice-call-notification-hidden'),
              message: strings.voiceCallNotificationHidden,
              icon: AppIcons.notifications,
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // A side panel where it leaves the tiles a usable width; a tab
              // below that.
              if (constraints.maxWidth >= 720) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: people),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: BorderDirectional(
                          start: BorderSide(
                            color: context.tokens.colors.border,
                          ),
                        ),
                      ),
                      child: SizedBox(width: 360, child: chat),
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Tabs(
                    chat: _chatTab,
                    onSelect: (chat) => setState(() => _chatTab = chat),
                  ),
                  Expanded(child: _chatTab ? chat : people),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _backToRooms(AppLocalizations strings) => AppButton(
    key: const ValueKey('voice-call-back'),
    label: strings.voiceCallBackToRoomsAction,
    kind: AppButtonKind.ghost,
    onPressed: () => context.go('/voice-rooms'),
  );

  void _joinCall() => unawaited(widget.controller.join(widget.roomId));

  Future<void> _leave() async {
    await widget.controller.leave();
    if (!mounted) {
      return;
    }
    _minimize();
  }

  void _minimize() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/voice-rooms/${widget.roomId}');
    }
  }

  Future<void> _showParticipant(VoiceCallParticipant participant, String name) {
    final strings = AppLocalizations.of(context);
    final verified = widget.people.isVerified(participant.userId);
    final explanation = _TileStatus(participant).body(strings, name);
    return showVoiceModal<void>(
      context: context,
      title: name,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VoiceVerificationLine(verified: verified),
          if (!verified) ...[
            const SizedBox(height: AppSpacing.x2),
            Text(
              strings.voiceRoomNotVerifiedNote,
              style: context.tokens.typography.compact,
            ),
          ],
          const SizedBox(height: AppSpacing.x3),
          Text(explanation, style: context.tokens.typography.body),
          const SizedBox(height: AppSpacing.x4),
          if (participant.status == VoiceParticipantStatus.notReachable) ...[
            AppButton(
              label: strings.voiceCallTryAgainAction,
              onPressed: () {
                popAppModal(context);
                unawaited(widget.controller.tryAgain(participant.deviceId));
              },
            ),
            const SizedBox(height: AppSpacing.x2),
          ],
          if (!verified ||
              participant.status == VoiceParticipantStatus.identityBlocked)
            AppButton(
              label: strings.voiceRoomVerifyAction,
              leading: AppIcons.security,
              kind: AppButtonKind.outline,
              onPressed: () {
                popAppModal(context);
                unawaited(
                  context.push('/contacts/${participant.userId}/safety'),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Room name, the count of devices this one knows in the call, and the two
/// ways out: the room's info and minimizing to the shell's banner. It grows
/// with the text rather than truncating the count.
///
/// Its colour runs up under the status bar, and its controls stay below it.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.name,
    required this.count,
    required this.roomId,
    required this.onMinimize,
    super.key,
  });

  final String name;
  final String? count;

  /// Null when this device holds no such room, which has no info to open.
  final String? roomId;
  final VoidCallback onMinimize;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    return Material(
      color: colors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.border)),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x2,
              vertical: AppSpacing.x2,
            ),
            child: Row(
              children: [
                AppIconButton(
                  key: const ValueKey('voice-call-minimize'),
                  icon: AppIcons.minimize,
                  semanticLabel: strings.voiceCallMinimizeAction,
                  kind: AppButtonKind.ghost,
                  onPressed: onMinimize,
                ),
                const SizedBox(width: AppSpacing.x2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        header: true,
                        child: VoiceUserText(
                          name,
                          style: context.tokens.typography.section,
                          maxLines: 2,
                        ),
                      ),
                      if (count != null)
                        Text(
                          count!,
                          key: const ValueKey('voice-call-count'),
                          style: context.tokens.typography.label.copyWith(
                            color: colors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (roomId case final id?)
                  AppIconButton(
                    key: const ValueKey('voice-call-info'),
                    icon: AppIcons.info,
                    semanticLabel: strings.voiceRoomInfoTitle,
                    kind: AppButtonKind.ghost,
                    onPressed: () => context.go('/voice-rooms/$id'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One state of the call screen: an icon, a title, a statement, and what can
/// be done about it. A live region, so a screen reader hears the change.
class _CallPanel extends StatelessWidget {
  const _CallPanel({
    required this.icon,
    required this.title,
    this.message,
    this.actions = const [],
    this.footer,
    this.busy = false,
    this.error = false,
    super.key,
  });

  final AppIconData icon;
  final String title;
  final String? message;
  final List<Widget> actions;
  final Widget? footer;
  final bool busy;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.x6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                container: true,
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppIcon(
                      icon,
                      color: error ? colors.danger : colors.accent,
                      size: 36,
                    ),
                    const SizedBox(height: AppSpacing.x4),
                    Text(
                      title,
                      style: context.tokens.typography.section,
                      textAlign: TextAlign.center,
                    ),
                    if (message != null) ...[
                      const SizedBox(height: AppSpacing.x2),
                      Text(
                        message!,
                        style: context.tokens.typography.body.copyWith(
                          color: colors.textMuted,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
              if (busy) ...[
                const SizedBox(height: AppSpacing.x4),
                const LinearProgressIndicator(),
              ],
              if (footer != null) ...[
                const SizedBox(height: AppSpacing.x4),
                footer!,
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.x6),
                actions.first,
                for (final action in actions.skip(1)) ...[
                  const SizedBox(height: AppSpacing.x2),
                  action,
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// People and Room chat, as two tabs on a narrow layout. The selected one is
/// marked by a bar and by weight as well as by colour.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.chat, required this.onSelect});

  final bool chat;
  final ValueChanged<bool> onSelect;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: _Tab(
            key: const ValueKey('voice-call-tab-people'),
            icon: AppIcons.people,
            label: strings.voiceCallPeopleTab,
            selected: !chat,
            onTap: () => onSelect(false),
          ),
        ),
        Expanded(
          child: _Tab(
            key: const ValueKey('voice-call-tab-chat'),
            icon: AppIcons.roomChat,
            label: strings.voiceCallChatTab,
            selected: chat,
            onTap: () => onSelect(true),
          ),
        ),
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final AppIconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    final color = selected ? colors.accent : colors.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      // The InkWell's own tap action goes with `excludeSemantics`, so the node
      // carries it.
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppFocus.minimumTarget),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x2,
            vertical: AppSpacing.x2,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.accent : colors.border,
                width: selected ? 3 : 1,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(icon, color: color, size: 18),
              const SizedBox(width: AppSpacing.x2),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: context.tokens.typography.compact.copyWith(
                    color: color,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// This device and every peer of the call, one tile each, and the call's
/// quiet statement that its audio crosses a relay.
class _PeoplePane extends StatelessWidget {
  const _PeoplePane({
    required this.call,
    required this.people,
    required this.onTile,
    required this.onTryAgain,
    required this.onInvite,
  });

  final VoiceCallState call;
  final VoiceRoomPeople people;
  final Future<void> Function(VoiceCallParticipant participant, String name)
  onTile;
  final ValueChanged<String> onTryAgain;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final seated = call.participants.where((peer) => peer.isSeated).length;
    final names = _tileNames(strings);
    return ListView(
      key: const ValueKey('voice-call-people'),
      padding: const EdgeInsets.all(AppSpacing.x4),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = (constraints.maxWidth / 170).floor().clamp(1, 4);
            final width =
                (constraints.maxWidth - (columns - 1) * AppSpacing.x3) /
                columns;
            return Wrap(
              spacing: AppSpacing.x3,
              runSpacing: AppSpacing.x3,
              children: [
                SizedBox(
                  width: width,
                  child: _OwnTile(
                    name: strings.voiceRoomYou,
                    seed: people.currentUserId,
                    muted: call.muted,
                  ),
                ),
                for (final participant in call.participants)
                  SizedBox(
                    width: width,
                    child: _ParticipantTile(
                      participant: participant,
                      name: names[participant.deviceId]!,
                      onTap: () => unawaited(
                        onTile(participant, names[participant.deviceId]!),
                      ),
                      onTryAgain: () => onTryAgain(participant.deviceId),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.x4),
        if (seated == 0 && call.announcing)
          Text(
            strings.voiceCallWaitingForOthers,
            key: const ValueKey('voice-call-waiting-for-others'),
            textAlign: TextAlign.center,
            style: context.tokens.typography.compact.copyWith(
              color: context.tokens.colors.textMuted,
            ),
          )
        else if (seated == 0) ...[
          Semantics(
            container: true,
            liveRegion: true,
            child: Column(
              key: const ValueKey('voice-call-alone'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  strings.voiceCallAloneTitle,
                  textAlign: TextAlign.center,
                  style: context.tokens.typography.section,
                ),
                const SizedBox(height: AppSpacing.x1),
                Text(
                  strings.voiceCallAloneBody,
                  textAlign: TextAlign.center,
                  style: context.tokens.typography.compact.copyWith(
                    color: context.tokens.colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          AppButton(
            label: strings.voiceRoomInviteAction,
            leading: AppIcons.invite,
            kind: AppButtonKind.outline,
            onPressed: onInvite,
          ),
        ],
        const SizedBox(height: AppSpacing.x4),
        VoiceNotice(
          key: const ValueKey('voice-call-relay-note'),
          message: strings.voiceCallRelayNote,
          icon: AppIcons.relay,
        ),
      ],
    );
  }

  /// Each tile's name. A person on two devices is two tiles, and the second
  /// says so rather than repeating the name; no device id is ever shown.
  Map<String, String> _tileNames(AppLocalizations strings) {
    final seen = <String>{people.currentUserId};
    return {
      for (final participant in call.participants)
        participant.deviceId: () {
          final userId = participant.userId.toLowerCase();
          final name = people.isCurrentUser(userId)
              ? strings.voiceRoomYou
              : people.nameOf(userId);
          return seen.add(userId) ? name : strings.voiceTileAnotherDevice(name);
        }(),
    };
  }
}

/// How one peer's tile reads: an icon and a word for each status, so colour
/// is never the only signal.
final class _TileStatus {
  const _TileStatus(this.participant);

  final VoiceCallParticipant participant;

  bool get restarting =>
      participant.restartingIce &&
      participant.status == VoiceParticipantStatus.connected;

  AppIconData get icon => restarting
      ? AppIcons.reconnecting
      : switch (participant.status) {
          VoiceParticipantStatus.connecting => AppIcons.connecting,
          VoiceParticipantStatus.connected => AppIcons.connected,
          VoiceParticipantStatus.reconnecting => AppIcons.reconnecting,
          VoiceParticipantStatus.notReachable => AppIcons.notReachable,
          VoiceParticipantStatus.identityBlocked => AppIcons.identityChanged,
          VoiceParticipantStatus.incompatibleVersion => AppIcons.incompatible,
        };

  String label(AppLocalizations strings) => restarting
      ? strings.voiceTileRestartingIce
      : switch (participant.status) {
          VoiceParticipantStatus.connecting => strings.voiceTileConnecting,
          VoiceParticipantStatus.connected => strings.voiceTileConnected,
          VoiceParticipantStatus.reconnecting => strings.voiceTileReconnecting,
          VoiceParticipantStatus.notReachable => strings.voiceTileNotReachable,
          VoiceParticipantStatus.identityBlocked =>
            strings.voiceTileIdentityBlocked,
          VoiceParticipantStatus.incompatibleVersion =>
            strings.voiceTileIncompatible,
        };

  String body(AppLocalizations strings, String name) => restarting
      ? strings.voiceTileRestartingIceBody(name)
      : switch (participant.status) {
          VoiceParticipantStatus.connecting => strings.voiceTileConnectingBody(
            name,
          ),
          VoiceParticipantStatus.connected => strings.voiceTileConnectedBody(
            name,
          ),
          VoiceParticipantStatus.reconnecting =>
            strings.voiceTileReconnectingBody(name),
          VoiceParticipantStatus.notReachable =>
            strings.voiceTileNotReachableBody(name),
          VoiceParticipantStatus.identityBlocked =>
            strings.voiceTileIdentityBlockedBody(name),
          VoiceParticipantStatus.incompatibleVersion =>
            strings.voiceTileIncompatibleBody(name),
        };

  /// Audio with this one person has stopped: announced as it happens, and
  /// never as the call being broken.
  bool get stopped =>
      participant.status == VoiceParticipantStatus.notReachable ||
      participant.status == VoiceParticipantStatus.identityBlocked ||
      participant.status == VoiceParticipantStatus.incompatibleVersion;

  Color color(AppColorTokens colors) {
    if (restarting) {
      return colors.warning;
    }
    return switch (participant.status) {
      VoiceParticipantStatus.connected => colors.accent,
      VoiceParticipantStatus.connecting => colors.textMuted,
      VoiceParticipantStatus.reconnecting => colors.warning,
      VoiceParticipantStatus.notReachable ||
      VoiceParticipantStatus.identityBlocked ||
      VoiceParticipantStatus.incompatibleVersion => colors.danger,
    };
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.participant,
    required this.name,
    required this.onTap,
    required this.onTryAgain,
  });

  final VoiceCallParticipant participant;
  final String name;
  final VoidCallback onTap;
  final VoidCallback onTryAgain;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final status = _TileStatus(participant);
    final label = status.label(strings);
    final colors = context.tokens.colors;
    final color = status.color(colors);
    return _TileFrame(
      key: ValueKey('voice-call-tile-${participant.deviceId}'),
      semanticLabel: '$name, $label',
      live: status.stopped || status.restarting,
      onTap: onTap,
      dashed: participant.status != VoiceParticipantStatus.connected,
      avatar: VoiceAvatar(name: name, seed: participant.userId, radius: 28),
      name: name,
      status: _StatusLine(icon: status.icon, label: label, color: color),
      action: switch (participant.status) {
        VoiceParticipantStatus.notReachable => AppButton(
          key: ValueKey('voice-call-tile-try-${participant.deviceId}'),
          label: strings.voiceCallTryAgainAction,
          kind: AppButtonKind.outline,
          onPressed: onTryAgain,
        ),
        VoiceParticipantStatus.identityBlocked => AppButton(
          key: ValueKey('voice-call-tile-verify-${participant.deviceId}'),
          label: strings.voiceRoomVerifyAction,
          kind: AppButtonKind.outline,
          onPressed: () =>
              context.push('/contacts/${participant.userId}/safety'),
        ),
        _ => null,
      },
    );
  }
}

/// This device's own tile: its mute state, which is the one microphone state
/// this device knows. A peer's mute crosses no frame in this version.
class _OwnTile extends StatelessWidget {
  const _OwnTile({required this.name, required this.seed, required this.muted});

  final String name;
  final String seed;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    final label = muted ? strings.voiceTileMuted : strings.voiceTileMicOn;
    return _TileFrame(
      key: const ValueKey('voice-call-own-tile'),
      semanticLabel: '$name, $label',
      live: false,
      onTap: null,
      dashed: false,
      avatar: VoiceAvatar(name: name, seed: seed, radius: 28),
      name: name,
      status: _StatusLine(
        icon: muted ? AppIcons.microphoneOff : AppIcons.microphone,
        label: label,
        color: muted ? colors.textMuted : colors.accent,
      ),
    );
  }
}

class _TileFrame extends StatelessWidget {
  const _TileFrame({
    required this.semanticLabel,
    required this.live,
    required this.onTap,
    required this.dashed,
    required this.avatar,
    required this.name,
    required this.status,
    this.action,
    super.key,
  });

  final String semanticLabel;
  final bool live;
  final VoidCallback? onTap;
  final bool dashed;
  final Widget avatar;
  final String name;
  final Widget status;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    return Semantics(
      container: true,
      button: onTap != null,
      liveRegion: live,
      label: semanticLabel,
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.card,
          side: BorderSide(color: colors.border, width: dashed ? 1 : 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(child: avatar),
                const SizedBox(height: AppSpacing.x2),
                ExcludeSemantics(
                  child: VoiceUserText(
                    name,
                    style: context.tokens.typography.compact,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: AppSpacing.x1),
                ExcludeSemantics(child: status),
                if (action != null) ...[
                  const SizedBox(height: AppSpacing.x2),
                  action!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.label,
    required this.color,
  });

  final AppIconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      AppIcon(icon, color: color, size: 16),
      const SizedBox(width: AppSpacing.x1),
      Flexible(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: context.tokens.typography.label.copyWith(color: color),
        ),
      ),
    ],
  );
}

/// Mute, Invite and Leave, each an icon and a word. The labels wrap at a large
/// text scale rather than truncate, so Mute and Leave always stay on screen.
///
/// Its colour runs down under the gesture bar or the navigation buttons, and
/// its controls stay above them.
class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.muted,
    required this.connecting,
    required this.onMute,
    required this.onInvite,
    required this.onLeave,
    super.key,
  });

  final bool muted;
  final bool connecting;
  final VoidCallback? onMute;
  final VoidCallback onInvite;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    return Material(
      color: colors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x3),
            // One height for the three, the tallest label's, so a label that
            // wraps at a large text size never leaves its neighbours short.
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _Control(
                      key: const ValueKey('voice-call-mute'),
                      icon: muted
                          ? AppIcons.microphoneOff
                          : AppIcons.microphone,
                      label: muted
                          ? strings.voiceCallUnmuteAction
                          : strings.voiceCallMuteAction,
                      state: muted
                          ? strings.voiceCallMicMuted
                          : strings.voiceCallMicOn,
                      autofocus: !connecting,
                      onPressed: onMute,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    child: _Control(
                      key: const ValueKey('voice-call-invite'),
                      icon: AppIcons.invite,
                      label: strings.voiceCallInviteAction,
                      onPressed: onInvite,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    child: _Control(
                      key: const ValueKey('voice-call-leave'),
                      icon: AppIcons.leaveCall,
                      label: strings.voiceCallLeaveAction,
                      danger: true,
                      onPressed: onLeave,
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

class _Control extends StatelessWidget {
  const _Control({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.state,
    this.danger = false,
    this.autofocus = false,
    super.key,
  });

  final AppIconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// What the control's state is, read after its action: the microphone's.
  final String? state;
  final bool danger;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    final enabled = onPressed != null;
    final foreground = danger
        ? colors.canvas
        : (enabled ? colors.textPrimary : colors.textMuted);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      value: state,
      // The InkWell's own tap action goes with `excludeSemantics`, so the node
      // carries it, and a control that is not enabled has none.
      onTap: onPressed,
      excludeSemantics: true,
      child: Material(
        color: danger ? colors.danger : colors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.control,
          side: danger ? BorderSide.none : BorderSide(color: colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          autofocus: autofocus,
          focusColor: colors.accentSoft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x1,
                vertical: AppSpacing.x2,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppIcon(icon, color: foreground, size: 22),
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: context.tokens.typography.label.copyWith(
                      color: foreground,
                      fontWeight: danger ? FontWeight.w600 : FontWeight.w500,
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
