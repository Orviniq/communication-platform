import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/presentation/create_voice_room_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_components.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_info_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The invite picker (`ui-specification.md` §13.3): verified contacts who are
/// not members, chosen and invited in one signed `add members` event. Each new
/// member is sent the whole signed transcript, so a room whose transcript no
/// longer fits one payload adds nobody.
class VoiceRoomInvitePage extends StatelessWidget {
  const VoiceRoomInvitePage({required this.roomId, super.key});

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
        final contacts = ref.watch(contactListProvider(scope.userId));
        final useCases = ref.watch(roomUseCasesProvider).value;
        return VoiceRoomInviteView(
          room: state,
          people: VoiceRoomPeople.fromContacts(
            scope.userId,
            contacts.value ?? const <ContactProjection>[],
          ),
          contactsLoading: !contacts.hasValue,
          onInvite: useCases == null
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

class VoiceRoomInviteView extends StatefulWidget {
  const VoiceRoomInviteView({
    required this.room,
    required this.people,
    required this.onInvite,
    this.contactsLoading = false,
    super.key,
  });

  final RoomState room;
  final VoiceRoomPeople people;
  final bool contactsLoading;

  /// Null while the room use cases are not composed yet.
  final MutateVoiceRoomCallback? onInvite;

  @override
  State<VoiceRoomInviteView> createState() => _VoiceRoomInviteViewState();
}

class _VoiceRoomInviteViewState extends State<VoiceRoomInviteView> {
  final _search = TextEditingController();
  final _selected = <String>{};
  var _busy = false;
  String? _failure;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final room = widget.room;
    final mayInvite = RoomAuthorization.mayAct(
      room,
      widget.people.currentUserId,
    );
    final remaining = RoomState.maximumMembers - room.activeMembers.length;
    final candidates = widget.people.verifiedContacts(
      excluding: [for (final member in room.activeMembers) member.userId],
    );
    final query = _search.text.trim().toLowerCase();
    final shown = [
      for (final candidate in candidates)
        if (query.isEmpty || candidate.name.toLowerCase().contains(query))
          candidate,
    ];
    final List<Widget> content;
    if (!mayInvite) {
      content = [VoiceRoomLifecycleNotice(room: room, people: widget.people)];
    } else if (remaining <= 0) {
      content = [
        VoiceNotice(
          message: strings.voiceRoomInviteRoomFull,
          kind: AppStatusKind.warning,
        ),
      ];
    } else if (widget.contactsLoading) {
      content = [AppStatePanel.loading(title: strings.contactsLoadingTitle)];
    } else if (candidates.isEmpty) {
      content = [
        AppStatePanel.empty(
          key: const ValueKey('voice-invite-none-left'),
          title: strings.voiceRoomInviteNoneLeftTitle,
          message: strings.voiceRoomInviteNoneLeftBody,
          actionLabel: strings.voiceRoomVerifyContactAction,
          onAction: () => context.go('/chats/new'),
        ),
      ];
    } else {
      content = [
        VoiceInvitePicker(
          candidates: shown,
          search: _search,
          selected: _selected,
          maximum: remaining,
          enabled: !_busy,
          onChanged: () => setState(() => _failure = null),
        ),
        const SizedBox(height: AppSpacing.x4),
        VoiceNotice(message: strings.voiceRoomInviteNote),
        const SizedBox(height: AppSpacing.x6),
        if (_busy)
          AppStatePanel.loading(title: strings.voiceRoomInvitingState)
        else
          AppButton(
            key: const ValueKey('voice-invite-submit'),
            label: strings.voiceRoomInviteSubmit(_selected.length),
            leading: AppIcons.invite,
            onPressed: _selected.isEmpty || widget.onInvite == null
                ? null
                : _invite,
          ),
      ];
    }
    return Scaffold(
      key: const ValueKey('voice-room-invite-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: strings.authBackAction,
          kind: AppButtonKind.ghost,
          onPressed: _busy ? null : _close,
        ),
        title: VoiceUserText(
          strings.voiceRoomInviteTitle(room.name),
          maxLines: 2,
        ),
      ),
      body: VoiceResponsiveBody(
        child: ListView(
          padding: AppInsets.belowAppBar(context, AppSpacing.x4),
          children: [
            ...content,
            if (_failure case final failure?) ...[
              const SizedBox(height: AppSpacing.x4),
              VoiceNotice(
                message: failure,
                kind: AppStatusKind.danger,
                live: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/voice-rooms/${widget.room.roomId}');
    }
  }

  Future<void> _invite() async {
    final onInvite = widget.onInvite;
    if (onInvite == null || _selected.isEmpty) {
      return;
    }
    final strings = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _failure = null;
    });
    final result = await onInvite(AddRoomMembersOperation(_selected));
    if (!mounted) {
      return;
    }
    switch (result) {
      case Success():
        _close();
      case FailureResult(
        failure: ValidationFailure(kind: ValidationFailureKind.limitExceeded),
      ):
        setState(() {
          _busy = false;
          _failure = strings.voiceRoomInviteTooLong;
        });
      case FailureResult():
        setState(() {
          _busy = false;
          _failure = strings.voiceRoomInviteFailed;
        });
    }
  }
}
