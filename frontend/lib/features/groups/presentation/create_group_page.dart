import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_components.dart';
import 'package:communication_platform/features/groups/presentation/group_member_picker.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class CreateGroupPage extends ConsumerWidget {
  const CreateGroupPage({
    this.injectedContacts,
    this.currentUserId,
    this.currentDeviceId,
    this.ownerDisplayName,
    this.onCreate,
    super.key,
  });

  final List<GroupPickerContact>? injectedContacts;
  final String? currentUserId;
  final String? currentDeviceId;
  final String? ownerDisplayName;
  final CreateGroupCallback? onCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (injectedContacts != null && onCreate != null) {
      return _CreateGroupFlow(contacts: injectedContacts!, onCreate: onCreate!);
    }
    final auth = ref.watch(authenticationControllerProvider);
    final userId = currentUserId ?? auth.userId;
    if (userId == null) {
      return groupErrorPage(context);
    }
    final contacts = ref.watch(contactListProvider(userId));
    final device = ref.watch(currentMessagingDeviceIdProvider);
    final useCases = ref.watch(groupUseCasesProvider);
    return contacts.when(
      loading: () => groupLoadingPage(context),
      error: (_, _) => groupErrorPage(context),
      data: (values) => device.when(
        loading: () => groupLoadingPage(context),
        error: (_, _) => groupErrorPage(context),
        data: (resolvedDevice) => useCases.when(
          loading: () => groupLoadingPage(context),
          error: (_, _) => groupErrorPage(context),
          data: (resolvedUseCases) => _CreateGroupFlow(
            contacts: values
                .map(GroupPickerContact.fromContact)
                .toList(growable: false),
            onCreate: (metadata, selected) => resolvedUseCases.create(
              currentUserId: userId,
              currentDeviceId: currentDeviceId ?? resolvedDevice,
              ownerDisplayName: ownerDisplayName ?? auth.username ?? userId,
              metadata: metadata,
              selectedMembers: selected,
            ),
          ),
        ),
      ),
    );
  }
}

class _CreateGroupFlow extends StatefulWidget {
  const _CreateGroupFlow({required this.contacts, required this.onCreate});

  final List<GroupPickerContact> contacts;
  final CreateGroupCallback onCreate;

  @override
  State<_CreateGroupFlow> createState() => _CreateGroupFlowState();
}

class _CreateGroupFlowState extends State<_CreateGroupFlow> {
  final _selected = <String>{};
  final _name = TextEditingController();
  final _description = TextEditingController();
  var _details = false;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('create-group-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: strings.authBackAction,
          onPressed: () {
            if (_details) {
              setState(() {
                _details = false;
                _error = null;
              });
            } else if (context.canPop()) {
              context.pop();
            } else {
              context.go('/chats/new');
            }
          },
          kind: AppButtonKind.ghost,
        ),
        title: Text(strings.groupCreateTitle),
      ),
      body: GroupResponsiveBody(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.x4),
          children: [
            Text(
              _details
                  ? strings.groupDetailsTitle
                  : strings.groupPickMembersTitle,
              style: context.tokens.typography.section,
            ),
            const SizedBox(height: AppSpacing.x4),
            if (_details) ...[
              AppField(
                key: const ValueKey('group-name-field'),
                label: strings.groupNameLabel,
                controller: _name,
                maxLength: GroupMetadata.maximumNameScalars,
                enabled: !_busy,
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: AppSpacing.x4),
              AppField(
                key: const ValueKey('group-description-field'),
                label: strings.groupDescriptionLabel,
                controller: _description,
                maxLength: GroupMetadata.maximumDescriptionScalars,
                enabled: !_busy,
              ),
            ] else
              GroupMemberPicker(
                contacts: widget.contacts,
                selectedUserIds: _selected,
                maximumSelection: GroupState.maximumMembers - 1,
                onSelectionChanged: (next) => setState(() {
                  _selected
                    ..clear()
                    ..addAll(next);
                  _error = null;
                }),
              ),
            if (_error case final error?) ...[
              const SizedBox(height: AppSpacing.x4),
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: context.tokens.typography.compact.copyWith(
                    color: context.tokens.colors.danger,
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.x6),
            if (_busy)
              AppStatePanel.loading(title: strings.groupCreatingState)
            else
              AppButton(
                key: ValueKey(_details ? 'group-create' : 'group-next'),
                label: _details
                    ? strings.groupCreateAction
                    : strings.groupNextAction,
                onPressed: _details ? _create : _next,
              ),
          ],
        ),
      ),
    );
  }

  void _next() {
    final strings = AppLocalizations.of(context);
    if (_selected.isEmpty) {
      setState(() => _error = strings.groupSelectMemberMessage);
      return;
    }
    if (_selected.length >= GroupState.maximumMembers) {
      setState(() => _error = strings.groupMemberLimitMessage);
      return;
    }
    setState(() {
      _details = true;
      _error = null;
    });
  }

  Future<void> _create() async {
    final strings = AppLocalizations.of(context);
    final metadata = GroupMetadata(
      name: _name.text,
      description: _description.text,
    ).normalized();
    if (!metadata.isValid) {
      setState(() => _error = strings.groupNameLabel);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final members = [
      for (final contact in widget.contacts)
        if (_selected.contains(contact.userId))
          GroupMember(
            userId: contact.userId,
            displayName: contact.name,
            role: GroupRole.member,
            verified: contact.verified,
          ),
    ];
    final result = await widget.onCreate(metadata, members);
    if (!mounted) return;
    switch (result) {
      case Success(:final value):
        context.go('/groups/${value.groupId}');
      case FailureResult():
        setState(() {
          _busy = false;
          _error = strings.groupCreateFailed;
        });
    }
  }
}
