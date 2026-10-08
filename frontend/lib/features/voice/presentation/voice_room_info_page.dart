import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_service_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_components.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Signs one change to a room and commits it with the copies it owes.
typedef MutateVoiceRoomCallback =
    Future<Result<RoomState>> Function(RoomControlOperation operation);

/// Voice Room Info (`ui-specification.md` §13.2): the room outside a call.
///
/// Every active member may rename, invite and remove (ADR-077 D1), so nothing
/// here is gated by a role; what gates an action is the room's own state.
class VoiceRoomInfoPage extends StatelessWidget {
  const VoiceRoomInfoPage({required this.roomId, super.key});

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
        final room = ref.watch(voiceRoomProvider(normalized));
        if (scope == null || (!room.hasValue && !room.hasError)) {
          return voiceLoadingPage(context);
        }
        final state = room.value;
        if (state == null) {
          return voiceRoomMissingPage(context);
        }
        final contacts =
            ref.watch(contactListProvider(scope.userId)).value ??
            const <ContactProjection>[];
        final useCases = ref.watch(roomUseCasesProvider).value;
        final call = ref.watch(voiceCallMirrorProvider);
        final controller = ref.watch(voiceCallControllerProvider(scope)).value;
        return VoiceRoomInfoView(
          room: state,
          people: VoiceRoomPeople.fromContacts(scope.userId, contacts),
          voiceAvailable: ref.watch(voiceAvailabilityProvider),
          offline: ref.watch(voiceOfflineProvider),
          callRoomId: call.roomId,
          callDevices: call.devices,
          // The join asks for the microphone; the call screen it opens shows
          // the question and its answer.
          onStartCall: controller == null
              ? null
              : () => unawaited(controller.join(normalized)),
          onMutate: useCases == null
              ? null
              : (operation) => useCases.mutate(
                  roomId: normalized,
                  actorUserId: scope.userId,
                  actorDeviceId: scope.deviceId,
                  operation: operation,
                ),
        );
      },
    );
  }
}

class VoiceRoomInfoView extends StatefulWidget {
  const VoiceRoomInfoView({
    required this.room,
    required this.people,
    required this.onStartCall,
    required this.onMutate,
    this.voiceAvailable = true,
    this.offline = false,
    this.callRoomId,
    this.callDevices = 0,
    super.key,
  });

  final RoomState room;
  final VoiceRoomPeople people;
  final bool voiceAvailable;
  final bool offline;

  /// The room of the call this device is in, or null.
  final String? callRoomId;
  final int callDevices;

  /// Starts a join in this room. Null while the call is not composed yet.
  final VoidCallback? onStartCall;

  /// Null while the room use cases are not composed yet.
  final MutateVoiceRoomCallback? onMutate;

  @override
  State<VoiceRoomInfoView> createState() => _VoiceRoomInfoViewState();
}

class _VoiceRoomInfoViewState extends State<VoiceRoomInfoView> {
  var _busy = false;
  String? _failure;

  RoomState get _room => widget.room;

  String get _self => widget.people.currentUserId;

  bool get _mayAct => RoomAuthorization.mayAct(_room, _self);

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final inThisCall = widget.callRoomId == _room.roomId;
    final members =
        [
          for (final member in _room.activeMembers)
            if (!widget.people.isCurrentUser(member.userId)) member.userId,
        ]..sort(
          (left, right) => widget.people
              .nameOf(left)
              .toLowerCase()
              .compareTo(widget.people.nameOf(right).toLowerCase()),
        );
    final selfIsMember = _room.isActiveMember(_self);
    final canInvite =
        _mayAct &&
        widget.onMutate != null &&
        _room.activeMembers.length < RoomState.maximumMembers;
    return Scaffold(
      key: const ValueKey('voice-room-info-screen'),
      appBar: AppBar(
        title: Text(strings.voiceRoomInfoTitle),
        actions: [
          if (_mayAct && widget.onMutate != null)
            AppIconButton(
              key: const ValueKey('voice-room-rename'),
              icon: AppIcons.edit,
              semanticLabel: strings.voiceRoomRenameAction,
              kind: AppButtonKind.ghost,
              onPressed: _busy ? null : _rename,
            ),
        ],
      ),
      body: VoiceResponsiveBody(
        child: ListView(
          padding: AppInsets.belowAppBar(context, AppSpacing.x4),
          children: [
            if (_room.lifecycle != RoomLifecycle.active) ...[
              VoiceRoomLifecycleNotice(room: _room, people: widget.people),
              const SizedBox(height: AppSpacing.x4),
            ],
            _Header(
              room: _room,
              state: switch (_room.lifecycle) {
                RoomLifecycle.active when inThisCall => VoiceRoomRowState.live,
                RoomLifecycle.active => VoiceRoomRowState.empty,
                RoomLifecycle.stateRecoveryRequired =>
                  VoiceRoomRowState.waiting,
                RoomLifecycle.forkQuarantined ||
                RoomLifecycle.controlQuarantined => VoiceRoomRowState.conflict,
                RoomLifecycle.left => VoiceRoomRowState.left,
                RoomLifecycle.removed => VoiceRoomRowState.removed,
              },
              devices: inThisCall ? widget.callDevices : 0,
            ),
            const SizedBox(height: AppSpacing.x6),
            ..._callAction(context, strings, inThisCall),
            const SizedBox(height: AppSpacing.x6),
            Semantics(
              header: true,
              child: Text(
                strings.voiceRoomMembersCount(_room.activeMembers.length),
                style: context.tokens.typography.section,
              ),
            ),
            const SizedBox(height: AppSpacing.x2),
            if (selfIsMember)
              _MemberRow(
                userId: _self,
                name: strings.voiceRoomYou,
                verified: null,
                onTap: null,
              ),
            for (final userId in members)
              _MemberRow(
                userId: userId,
                name: widget.people.nameOf(userId),
                verified: widget.people.isVerified(userId),
                onTap: () => _showMember(userId),
              ),
            if (canInvite)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.x3),
                child: AppButton(
                  key: const ValueKey('voice-room-invite'),
                  label: strings.voiceRoomInviteAction,
                  leading: AppIcons.invite,
                  kind: AppButtonKind.outline,
                  onPressed: _busy
                      ? null
                      : () =>
                            context.push('/voice-rooms/${_room.roomId}/invite'),
                ),
              ),
            const SizedBox(height: AppSpacing.x4),
            VoiceNotice(message: strings.voiceRoomPrivacyNote),
            if (_busy) ...[
              const SizedBox(height: AppSpacing.x4),
              const LinearProgressIndicator(),
            ],
            if (_failure case final failure?) ...[
              const SizedBox(height: AppSpacing.x4),
              VoiceNotice(
                message: failure,
                kind: AppStatusKind.danger,
                live: true,
              ),
            ],
            if (_mayAct && widget.onMutate != null) ...[
              const SizedBox(height: AppSpacing.x6),
              AppButton(
                key: const ValueKey('voice-room-leave'),
                label: strings.voiceRoomLeaveAction,
                leading: AppIcons.leaveCall,
                kind: AppButtonKind.danger,
                onPressed: _busy ? null : _confirmLeave,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The call action and, when it is withheld, the reason beside it: a
  /// control that cannot succeed is never offered bare.
  List<Widget> _callAction(
    BuildContext context,
    AppLocalizations strings,
    bool inThisCall,
  ) {
    if (inThisCall) {
      return [
        AppButton(
          key: const ValueKey('voice-room-return-to-call'),
          label: strings.voiceRoomReturnToCallAction,
          leading: AppIcons.voiceRooms,
          onPressed: () => context.go('/voice-rooms/${_room.roomId}/call'),
        ),
      ];
    }
    if (!widget.voiceAvailable) {
      return [
        VoiceNotice(
          key: const ValueKey('voice-room-no-voice'),
          message: strings.voiceRoomNoVoiceNotice,
          kind: AppStatusKind.warning,
        ),
      ];
    }
    final String? withheld = switch (_room.lifecycle) {
      RoomLifecycle.left || RoomLifecycle.removed => null,
      RoomLifecycle.stateRecoveryRequired => strings.voiceRoomJoinWaits,
      RoomLifecycle.forkQuarantined ||
      RoomLifecycle.controlQuarantined => strings.voiceRoomJoinPaused,
      RoomLifecycle.active when widget.offline => strings.voiceRoomJoinOffline,
      RoomLifecycle.active when widget.callRoomId != null =>
        strings.voiceRoomJoinOtherCall,
      RoomLifecycle.active => null,
    };
    if (!_mayAct && withheld == null) {
      // Left or removed: the notice above says why, and there is no call.
      return const [];
    }
    final start = widget.onStartCall;
    return [
      AppButton(
        key: const ValueKey('voice-room-start-call'),
        label: strings.voiceRoomStartCallAction,
        leading: AppIcons.microphone,
        onPressed: withheld != null || start == null
            ? null
            : () {
                start();
                context.go('/voice-rooms/${_room.roomId}/call');
              },
      ),
      if (withheld != null) ...[
        const SizedBox(height: AppSpacing.x2),
        VoiceNotice(
          key: const ValueKey('voice-room-call-withheld'),
          message: withheld,
          kind: AppStatusKind.warning,
        ),
      ],
    ];
  }

  Future<void> _showMember(String userId) {
    final strings = AppLocalizations.of(context);
    final name = widget.people.nameOf(userId);
    final verified = widget.people.isVerified(userId);
    final canRemove =
        widget.onMutate != null &&
        RoomAuthorization.canRemove(
          _room,
          actorUserId: _self,
          targetUserId: userId,
        );
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
          const SizedBox(height: AppSpacing.x4),
          AppButton(
            label: strings.voiceRoomVerifyAction,
            leading: AppIcons.security,
            kind: AppButtonKind.outline,
            onPressed: () {
              popAppModal(context);
              unawaited(context.push('/contacts/$userId/safety'));
            },
          ),
          if (canRemove) ...[
            const SizedBox(height: AppSpacing.x2),
            AppButton(
              key: const ValueKey('voice-room-remove-member'),
              label: strings.voiceRoomRemoveMemberAction,
              kind: AppButtonKind.danger,
              onPressed: () {
                popAppModal(context);
                unawaited(_confirmRemove(userId, name));
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmRemove(String userId, String name) {
    final strings = AppLocalizations.of(context);
    return showAppDialog<void>(
      context: context,
      title: strings.voiceRoomRemoveMemberTitle(name),
      body: strings.voiceRoomRemoveMemberBody(name),
      actions: [
        AppButton(
          label: strings.voiceRoomCancelAction,
          kind: AppButtonKind.ghost,
          onPressed: () => popAppModal(context),
        ),
        AppButton(
          label: strings.voiceRoomRemoveMemberAction,
          kind: AppButtonKind.danger,
          onPressed: () {
            popAppModal(context);
            unawaited(_mutate(RemoveRoomMemberOperation(userId)));
          },
        ),
      ],
    );
  }

  Future<void> _confirmLeave() {
    final strings = AppLocalizations.of(context);
    return showAppDialog<void>(
      context: context,
      title: strings.voiceRoomLeaveTitle,
      body: strings.voiceRoomLeaveBody,
      actions: [
        AppButton(
          label: strings.voiceRoomCancelAction,
          kind: AppButtonKind.ghost,
          onPressed: () => popAppModal(context),
        ),
        AppButton(
          key: const ValueKey('voice-room-leave-confirm'),
          label: strings.voiceRoomLeaveAction,
          kind: AppButtonKind.danger,
          onPressed: () {
            popAppModal(context);
            // Leaving is removing yourself, signed like any other removal.
            unawaited(_mutate(RemoveRoomMemberOperation(_self)));
          },
        ),
      ],
    );
  }

  Future<void> _rename() async {
    final strings = AppLocalizations.of(context);
    final name = await showVoiceModal<String>(
      context: context,
      title: strings.voiceRoomRenameTitle,
      child: _RenameForm(initial: _room.name),
    );
    if (name == null || !mounted || name.trim() == _room.name) {
      return;
    }
    await _mutate(
      RenameRoomOperation(name),
      failure: strings.voiceRoomRenameFailed,
    );
  }

  Future<void> _mutate(
    RoomControlOperation operation, {
    String? failure,
  }) async {
    final onMutate = widget.onMutate;
    if (onMutate == null) {
      return;
    }
    final strings = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _failure = null;
    });
    final result = await onMutate(operation);
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _failure = result is FailureResult<RoomState>
          ? failure ?? strings.voiceRoomChangeFailed
          : null;
    });
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.room,
    required this.state,
    required this.devices,
  });

  final RoomState room;
  final VoiceRoomRowState state;
  final int devices;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      VoiceAvatar(name: room.name, seed: room.roomId, radius: 44),
      const SizedBox(height: AppSpacing.x3),
      VoiceUserText(
        room.name,
        style: context.tokens.typography.title,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: AppSpacing.x2),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: VoiceRoomStateLine(state: state, devices: devices),
          ),
        ],
      ),
    ],
  );
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.userId,
    required this.name,
    required this.verified,
    required this.onTap,
  });

  final String userId;
  final String name;

  /// Null for this account itself, which has nothing to verify.
  final bool? verified;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final status = switch (verified) {
      true => strings.voiceRoomVerified,
      false => strings.voiceRoomNotVerified,
      null => null,
    };
    return Semantics(
      key: ValueKey('voice-room-member-$userId'),
      button: onTap != null,
      label: status == null ? name : '$name, $status',
      excludeSemantics: true,
      child: ListTile(
        minTileHeight: AppFocus.minimumTarget,
        leading: VoiceAvatar(name: name, seed: userId),
        title: VoiceUserText(name, maxLines: 2),
        subtitle: verified == null
            ? null
            : VoiceVerificationLine(verified: verified!),
        onTap: onTap,
      ),
    );
  }
}

/// Whether a person's safety number is verified, as an icon and a word.
class VoiceVerificationLine extends StatelessWidget {
  const VoiceVerificationLine({required this.verified, super.key});

  final bool verified;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    return Row(
      children: [
        AppIcon(
          verified ? AppIcons.security : AppIcons.warning,
          color: verified ? colors.success : colors.warning,
          size: 16,
        ),
        const SizedBox(width: AppSpacing.x1),
        Flexible(
          child: Text(
            verified ? strings.voiceRoomVerified : strings.voiceRoomNotVerified,
            style: context.tokens.typography.label.copyWith(
              color: verified ? colors.success : colors.warning,
            ),
          ),
        ),
      ],
    );
  }
}

/// The rename field, with the 100-scalar limit stated as it is crossed. It
/// answers the new name, or nothing when cancelled.
class _RenameForm extends StatefulWidget {
  const _RenameForm({required this.initial});

  final String initial;

  @override
  State<_RenameForm> createState() => _RenameFormState();
}

class _RenameFormState extends State<_RenameForm> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final tooLong = _name.text.trim().runes.length > RoomNames.maximumScalars;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          strings.voiceRoomRenameBody,
          style: context.tokens.typography.body,
        ),
        const SizedBox(height: AppSpacing.x4),
        AppField(
          key: const ValueKey('voice-room-rename-field'),
          label: strings.voiceRoomNameLabel,
          controller: _name,
          error: tooLong ? strings.voiceRoomNameTooLong : null,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.x4),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpacing.x2,
          runSpacing: AppSpacing.x2,
          children: [
            AppButton(
              label: strings.voiceRoomCancelAction,
              kind: AppButtonKind.ghost,
              onPressed: () => popAppModal(context),
            ),
            AppButton(
              key: const ValueKey('voice-room-rename-save'),
              label: strings.voiceRoomSaveAction,
              onPressed: RoomNames.isValid(_name.text)
                  ? () => popAppModal(context, _name.text)
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}
