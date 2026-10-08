import 'package:communication_platform/app/dependencies/contact_providers.dart';
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

/// Creates a room from a name and the people invited, and answers the new
/// room's id.
typedef CreateVoiceRoomCallback =
    Future<Result<String>> Function(String name, List<String> memberUserIds);

/// Create Voice Room (`ui-specification.md` §13.1): room details, then who to
/// invite, then create. Nothing here calls the server: the create event is
/// signed on this device and fanned out as ordinary envelopes.
class CreateVoiceRoomPage extends StatelessWidget {
  const CreateVoiceRoomPage({super.key});

  @override
  Widget build(BuildContext context) {
    try {
      ProviderScope.containerOf(context);
    } on StateError {
      return const CreateVoiceRoomView(candidates: [], onCreate: null);
    }
    return Consumer(
      builder: (context, ref, _) {
        final scope = ref.watch(voiceScopeProvider).value;
        if (scope == null) {
          return voiceLoadingPage(context);
        }
        final contacts = ref.watch(contactListProvider(scope.userId));
        final useCases = ref.watch(roomUseCasesProvider).value;
        final people = VoiceRoomPeople.fromContacts(
          scope.userId,
          contacts.value ?? const <ContactProjection>[],
        );
        return CreateVoiceRoomView(
          candidates: people.verifiedContacts(),
          contactsLoading: !contacts.hasValue,
          voiceAvailable: ref.watch(voiceAvailabilityProvider),
          onCreate: useCases == null
              ? null
              : (name, members) async {
                  final created = await useCases.create(
                    currentUserId: scope.userId,
                    currentDeviceId: scope.deviceId,
                    name: name,
                    memberUserIds: members,
                  );
                  return created.fold(
                    onSuccess: (room) => Result.success(room.roomId),
                    onFailure: Result.failure,
                  );
                },
        );
      },
    );
  }
}

class CreateVoiceRoomView extends StatefulWidget {
  const CreateVoiceRoomView({
    required this.candidates,
    required this.onCreate,
    this.contactsLoading = false,
    this.voiceAvailable = true,
    super.key,
  });

  /// Verified contacts: the only people a room may invite.
  final List<VoiceInviteCandidate> candidates;
  final bool contactsLoading;
  final bool voiceAvailable;

  /// Null until the room use cases are composed, when Create stays disabled.
  final CreateVoiceRoomCallback? onCreate;

  @override
  State<CreateVoiceRoomView> createState() => _CreateVoiceRoomViewState();
}

class _CreateVoiceRoomViewState extends State<CreateVoiceRoomView> {
  final _name = TextEditingController();
  final _search = TextEditingController();
  final _selected = <String>{};
  var _step = 0;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  bool get _nameTooLong =>
      _name.text.trim().runes.length > RoomNames.maximumScalars;

  bool get _nameValid => RoomNames.isValid(_name.text);

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('create-voice-room-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: strings.authBackAction,
          kind: AppButtonKind.ghost,
          onPressed: _busy ? null : _back,
        ),
        title: Text(strings.voiceRoomCreateTitle),
      ),
      body: widget.voiceAvailable
          ? VoiceResponsiveBody(
              child: ListView(
                padding: AppInsets.belowAppBar(context, AppSpacing.x4),
                children: [
                  Text(
                    strings.voiceRoomCreateStep(_step + 1),
                    style: context.tokens.typography.label.copyWith(
                      color: context.tokens.colors.textMuted,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x2),
                  ...switch (_step) {
                    0 => _details(context, strings),
                    1 => _invite(context, strings),
                    _ => _review(context, strings),
                  },
                  if (_error case final error?) ...[
                    const SizedBox(height: AppSpacing.x4),
                    VoiceNotice(
                      message: error,
                      kind: AppStatusKind.danger,
                      live: true,
                    ),
                  ],
                ],
              ),
            )
          : AppStatePanel.empty(
              key: const ValueKey('create-voice-room-no-voice'),
              title: strings.voiceRoomsNoVoiceTitle,
              message: strings.voiceRoomsNoVoiceBody,
            ),
    );
  }

  List<Widget> _details(BuildContext context, AppLocalizations strings) => [
    Text(strings.voiceRoomNameLabel, style: context.tokens.typography.section),
    const SizedBox(height: AppSpacing.x4),
    AppField(
      key: const ValueKey('voice-room-name-field'),
      label: strings.voiceRoomNameLabel,
      controller: _name,
      description: strings.voiceRoomNamePrivacyNote,
      error: _nameTooLong ? strings.voiceRoomNameTooLong : null,
      textInputAction: TextInputAction.done,
      onChanged: (_) => setState(() => _error = null),
    ),
    const SizedBox(height: AppSpacing.x4),
    VoiceNotice(message: strings.voiceRoomStandaloneNote),
    const SizedBox(height: AppSpacing.x6),
    AppButton(
      key: const ValueKey('voice-room-details-continue'),
      label: strings.voiceRoomContinueAction,
      onPressed: _nameValid ? () => setState(() => _step = 1) : null,
    ),
  ];

  List<Widget> _invite(BuildContext context, AppLocalizations strings) {
    if (widget.contactsLoading) {
      return [AppStatePanel.loading(title: strings.contactsLoadingTitle)];
    }
    if (widget.candidates.isEmpty) {
      return [
        AppStatePanel.empty(
          key: const ValueKey('voice-room-no-verified'),
          title: strings.voiceRoomNoVerifiedTitle,
          message: strings.voiceRoomNoVerifiedBody,
          actionLabel: strings.voiceRoomVerifyContactAction,
          onAction: () => context.go('/chats/new'),
        ),
      ];
    }
    final query = _search.text.trim().toLowerCase();
    final shown = [
      for (final candidate in widget.candidates)
        if (query.isEmpty || candidate.name.toLowerCase().contains(query))
          candidate,
    ];
    return [
      Text(
        strings.voiceRoomInviteStepTitle,
        style: context.tokens.typography.section,
      ),
      const SizedBox(height: AppSpacing.x4),
      VoiceInvitePicker(
        candidates: shown,
        search: _search,
        selected: _selected,
        maximum: RoomState.maximumMembers - 1,
        onChanged: () => setState(() => _error = null),
      ),
      const SizedBox(height: AppSpacing.x6),
      AppButton(
        key: const ValueKey('voice-room-invite-continue'),
        label: strings.voiceRoomContinueAction,
        onPressed: _selected.isEmpty ? null : () => setState(() => _step = 2),
      ),
    ];
  }

  List<Widget> _review(BuildContext context, AppLocalizations strings) => [
    Text(
      strings.voiceRoomReviewTitle,
      style: context.tokens.typography.section,
    ),
    const SizedBox(height: AppSpacing.x4),
    Row(
      children: [
        VoiceAvatar(name: _name.text.trim(), seed: _name.text.trim()),
        const SizedBox(width: AppSpacing.x3),
        Expanded(
          child: VoiceUserText(
            _name.text.trim(),
            style: context.tokens.typography.body,
          ),
        ),
      ],
    ),
    const SizedBox(height: AppSpacing.x3),
    Text(
      strings.voiceRoomReviewMembers(_selected.length),
      style: context.tokens.typography.compact,
    ),
    const SizedBox(height: AppSpacing.x3),
    VoiceNotice(message: strings.voiceRoomReviewBody),
    const SizedBox(height: AppSpacing.x6),
    if (_busy)
      AppStatePanel.loading(title: strings.voiceRoomCreatingState)
    else
      AppButton(
        key: const ValueKey('voice-room-create'),
        label: strings.voiceRoomCreateAction,
        onPressed: widget.onCreate == null ? null : _create,
      ),
  ];

  void _back() {
    if (_step > 0) {
      setState(() {
        _step -= 1;
        _error = null;
      });
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/voice-rooms');
    }
  }

  Future<void> _create() async {
    final onCreate = widget.onCreate;
    if (onCreate == null || !_nameValid || _selected.isEmpty) {
      return;
    }
    final strings = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final created = await onCreate(_name.text, _selected.toList()..sort());
    if (!mounted) {
      return;
    }
    switch (created) {
      case Success(:final value):
        context.go('/voice-rooms/$value');
      case FailureResult():
        setState(() {
          _busy = false;
          _error = strings.voiceRoomCreateFailed;
        });
    }
  }
}

/// A searchable multi-select of verified contacts, shared by Create and the
/// invite picker. At most [maximum] may be chosen.
class VoiceInvitePicker extends StatelessWidget {
  const VoiceInvitePicker({
    required this.candidates,
    required this.search,
    required this.selected,
    required this.maximum,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final List<VoiceInviteCandidate> candidates;
  final TextEditingController search;

  /// Changed in place: the picker owns no state of its own, so a resize that
  /// rebuilds it loses no choice.
  final Set<String> selected;
  final int maximum;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppField(
          key: const ValueKey('voice-invite-search'),
          label: strings.contactsSearchLabel,
          controller: search,
          enabled: enabled,
          textInputAction: TextInputAction.search,
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: AppSpacing.x2),
        Semantics(
          liveRegion: true,
          child: Text(
            strings.voiceRoomSelectedCount(selected.length),
            style: context.tokens.typography.compact.copyWith(
              color: context.tokens.colors.textMuted,
            ),
          ),
        ),
        if (selected.length >= maximum)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.x2),
            child: VoiceNotice(
              message: strings.voiceRoomMemberLimit,
              kind: AppStatusKind.warning,
            ),
          ),
        const SizedBox(height: AppSpacing.x2),
        for (final candidate in candidates)
          CheckboxListTile(
            key: ValueKey('voice-invite-${candidate.userId}'),
            value: selected.contains(candidate.userId),
            controlAffinity: ListTileControlAffinity.leading,
            enabled: enabled,
            secondary: VoiceAvatar(
              name: candidate.name,
              seed: candidate.userId,
              radius: 20,
            ),
            title: VoiceUserText(candidate.name, maxLines: 2),
            subtitle: Row(
              children: [
                AppIcon(
                  AppIcons.security,
                  color: context.tokens.colors.success,
                  size: 16,
                ),
                const SizedBox(width: AppSpacing.x1),
                Flexible(child: Text(strings.voiceRoomVerified)),
              ],
            ),
            onChanged: (value) {
              if (value ?? false) {
                if (selected.length >= maximum) {
                  return;
                }
                selected.add(candidate.userId);
              } else {
                selected.remove(candidate.userId);
              }
              onChanged();
            },
          ),
      ],
    );
  }
}
