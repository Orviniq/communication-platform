import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class EditGroupPage extends ConsumerWidget {
  const EditGroupPage({required this.groupId, super.key});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authenticationControllerProvider);
    final userId = auth.userId;
    if (userId == null) return groupErrorPage(context);
    final group = ref.watch(groupProvider(groupId));
    final device = ref.watch(currentMessagingDeviceIdProvider);
    final useCases = ref.watch(groupUseCasesProvider);
    return group.when(
      loading: () => groupLoadingPage(context),
      error: (_, _) => groupErrorPage(context),
      data: (state) {
        if (state == null) return groupErrorPage(context);
        return device.when(
          loading: () => groupLoadingPage(context),
          error: (_, _) => groupErrorPage(context),
          data: (deviceId) => useCases.when(
            loading: () => groupLoadingPage(context),
            error: (_, _) => groupErrorPage(context),
            data: (resolved) => GroupEditView(
              state: state,
              currentUserId: userId,
              onMutate: (operation) => resolved.mutate(
                groupId: groupId,
                actorUserId: userId,
                actorDeviceId: deviceId,
                operation: operation,
              ),
            ),
          ),
        );
      },
    );
  }
}

class GroupEditView extends StatefulWidget {
  const GroupEditView({
    required this.state,
    required this.currentUserId,
    required this.onMutate,
    super.key,
  });

  final GroupState state;
  final String currentUserId;
  final MutateGroupCallback onMutate;

  @override
  State<GroupEditView> createState() => _GroupEditViewState();
}

class _GroupEditViewState extends State<GroupEditView> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  var _busy = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.state.metadata.name);
    _description = TextEditingController(
      text: widget.state.metadata.description,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final canEdit = GroupAuthorization.allows(
      widget.state,
      widget.currentUserId,
      GroupPermission.editMetadata,
    );
    return Scaffold(
      key: const ValueKey('group-edit-screen'),
      appBar: AppBar(title: Text(strings.groupEditTitle)),
      body: GroupResponsiveBody(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.x4),
          children: [
            if (!canEdit)
              GroupInlineError(message: strings.groupPermissionChanged),
            AppField(
              label: strings.groupNameLabel,
              controller: _name,
              enabled: canEdit && !_busy,
              maxLength: GroupMetadata.maximumNameScalars,
            ),
            const SizedBox(height: AppSpacing.x4),
            AppField(
              label: strings.groupDescriptionLabel,
              controller: _description,
              enabled: canEdit && !_busy,
              maxLength: GroupMetadata.maximumDescriptionScalars,
            ),
            const SizedBox(height: AppSpacing.x6),
            // A group's policies are fixed by the event that created it: no
            // control event changes them, so they are shown and not offered.
            Text(
              strings.groupInvitePolicyLabel,
              style: context.tokens.typography.compact,
            ),
            DropdownButtonFormField<GroupInvitationPolicy>(
              key: const ValueKey('group-invite-policy'),
              initialValue: widget.state.invitationPolicy,
              items: [
                for (final policy in GroupInvitationPolicy.values)
                  DropdownMenuItem(
                    value: policy,
                    child: Text(_invitationLabel(strings, policy)),
                  ),
              ],
              onChanged: null,
            ),
            const SizedBox(height: AppSpacing.x4),
            AppCheckboxRow(
              value:
                  widget.state.historySharingPolicy ==
                  GroupHistorySharingPolicy.reshareAvailable,
              label: strings.groupHistorySharingLabel,
              onChanged: null,
            ),
            Text(
              strings.groupHistorySharingNote,
              style: context.tokens.typography.compact.copyWith(
                color: context.tokens.colors.textMuted,
              ),
            ),
            if (_failed) ...[
              const SizedBox(height: AppSpacing.x4),
              GroupInlineError(message: strings.groupActionFailed),
            ],
            const SizedBox(height: AppSpacing.x6),
            if (_busy)
              const LinearProgressIndicator()
            else
              Wrap(
                spacing: AppSpacing.x2,
                runSpacing: AppSpacing.x2,
                alignment: WrapAlignment.end,
                children: [
                  AppButton(
                    label: strings.groupCancelAction,
                    kind: AppButtonKind.ghost,
                    onPressed: () => context.pop(),
                  ),
                  AppButton(
                    key: const ValueKey('group-save'),
                    label: strings.groupSaveAction,
                    onPressed: canEdit ? _save : null,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    final metadata = GroupMetadata(
      name: _name.text,
      description: _description.text,
    ).normalized();
    final result = await widget.onMutate(RenameGroupOperation(metadata));
    if (!mounted) return;
    if (result is Success<GroupState>) {
      context.pop();
    } else {
      setState(() {
        _busy = false;
        _failed = true;
      });
    }
  }
}

String _invitationLabel(
  AppLocalizations strings,
  GroupInvitationPolicy policy,
) => switch (policy) {
  GroupInvitationPolicy.ownerOnly => strings.groupInviteOwnerOnly,
  GroupInvitationPolicy.ownerAndAdmins => strings.groupInviteAdmins,
  GroupInvitationPolicy.allMembers => strings.groupInviteEveryone,
};
