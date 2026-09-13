import 'dart:async';

import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class GroupInfoPage extends ConsumerWidget {
  const GroupInfoPage({
    required this.groupId,
    this.injectedState,
    this.currentUserId,
    this.onMutate,
    super.key,
  });

  final String groupId;
  final GroupState? injectedState;
  final String? currentUserId;
  final MutateGroupCallback? onMutate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (injectedState != null && onMutate != null) {
      return GroupInfoView(
        state: injectedState!,
        currentUserId: currentUserId ?? injectedState!.members.first.userId,
        onMutate: onMutate!,
      );
    }
    final auth = ref.watch(authenticationControllerProvider);
    final userId = currentUserId ?? auth.userId;
    if (userId == null) return groupErrorPage(context);
    final state = ref.watch(groupProvider(groupId));
    final device = ref.watch(currentMessagingDeviceIdProvider);
    final useCases = ref.watch(groupUseCasesProvider);
    return state.when(
      loading: () => groupLoadingPage(context),
      error: (_, _) => groupErrorPage(context),
      data: (group) {
        if (group == null) return groupErrorPage(context);
        return device.when(
          loading: () => groupLoadingPage(context),
          error: (_, _) => groupErrorPage(context),
          data: (deviceId) => useCases.when(
            loading: () => groupLoadingPage(context),
            error: (_, _) => groupErrorPage(context),
            data: (resolved) => GroupInfoView(
              state: group,
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

class GroupInfoView extends StatefulWidget {
  const GroupInfoView({
    required this.state,
    required this.currentUserId,
    required this.onMutate,
    this.embedded = false,
    super.key,
  });

  final GroupState state;
  final String currentUserId;
  final MutateGroupCallback onMutate;
  final bool embedded;

  @override
  State<GroupInfoView> createState() => _GroupInfoViewState();
}

class _GroupInfoViewState extends State<GroupInfoView> {
  var _busy = false;
  var _failed = false;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final state = widget.state;
    final canEdit = GroupAuthorization.allows(
      state,
      widget.currentUserId,
      GroupPermission.editMetadata,
    );
    final content = GroupResponsiveBody(
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.x4),
        children: [
          if (state.lifecycle != GroupLifecycle.active) ...[
            const SizedBox(height: AppSpacing.x3),
            GroupLifecycleNotice(lifecycle: state.lifecycle),
          ],
          const SizedBox(height: AppSpacing.x6),
          GroupInfoSummary(state: state),
          const SizedBox(height: AppSpacing.x6),
          Wrap(
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x2,
            children: [
              AppButton(
                label: strings.groupMuteAction,
                leading: AppIcons.muted,
                onPressed: null,
                kind: AppButtonKind.outline,
              ),
              AppButton(
                key: const ValueKey('group-info-search'),
                label: strings.groupSearchChatAction,
                leading: AppIcons.search,
                // Searching happens in the conversation, over the
                // messages it has loaded. A permanently disabled button
                // offering it here was a control that could never
                // succeed, which the UI specification's core rules
                // forbid.
                onPressed: () => context.go('/groups/${state.groupId}'),
                kind: AppButtonKind.outline,
              ),
              AppButton(
                label: strings.groupSharedMediaAction,
                leading: AppIcons.attach,
                onPressed: null,
                kind: AppButtonKind.outline,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x6),
          Text(
            strings.groupMembersSection,
            style: context.tokens.typography.section,
          ),
          const SizedBox(height: AppSpacing.x2),
          for (final member in state.members.where((member) => member.isActive))
            _MemberRow(member: member, onTap: () => _showMember(member)),
          if (GroupAuthorization.allows(
            state,
            widget.currentUserId,
            GroupPermission.inviteMembers,
          ))
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x3),
              child: AppButton(
                label: strings.groupAddMembersAction,
                leading: AppIcons.add,
                onPressed: () =>
                    context.push('/groups/${state.groupId}/add-members'),
                kind: AppButtonKind.outline,
              ),
            ),
          if (_busy) ...[
            const SizedBox(height: AppSpacing.x4),
            const LinearProgressIndicator(),
          ],
          if (_failed) ...[
            const SizedBox(height: AppSpacing.x3),
            GroupInlineError(message: strings.groupActionFailed),
          ],
          const SizedBox(height: AppSpacing.x6),
          AppButton(
            label: strings.groupLeaveAction,
            leading: AppIcons.delete,
            kind: AppButtonKind.danger,
            onPressed: GroupAuthorization.canLeave(state, widget.currentUserId)
                ? _confirmLeave
                : null,
          ),
          if (!GroupAuthorization.canLeave(state, widget.currentUserId) &&
              state.member(widget.currentUserId)?.role == GroupRole.owner)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x2),
              child: Text(
                strings.groupOwnerMustTransfer,
                style: context.tokens.typography.compact.copyWith(
                  color: context.tokens.colors.warning,
                ),
              ),
            ),
        ],
      ),
    );
    if (widget.embedded) return content;
    return Scaffold(
      key: const ValueKey('group-info-screen'),
      appBar: AppBar(
        title: Text(strings.groupInfoTitle),
        actions: [
          if (canEdit)
            AppIconButton(
              icon: AppIcons.edit,
              semanticLabel: strings.groupEditAction,
              kind: AppButtonKind.ghost,
              onPressed: () => context.push('/groups/${state.groupId}/edit'),
            ),
        ],
      ),
      body: content,
    );
  }

  Future<void> _showMember(GroupMember member) => showAppSheet<void>(
    context: context,
    semanticLabel: member.displayName,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(member.displayName, style: context.tokens.typography.section),
        const SizedBox(height: AppSpacing.x3),
        AppButton(
          label: AppLocalizations.of(context).contactMessageAction,
          onPressed: () {
            popAppModal(context);
            unawaited(context.push('/chats/direct/${member.userId}'));
          },
          kind: AppButtonKind.outline,
        ),
        if (GroupAuthorization.canRemove(
          widget.state,
          actorUserId: widget.currentUserId,
          targetUserId: member.userId,
        )) ...[
          const SizedBox(height: AppSpacing.x2),
          AppButton(
            label: AppLocalizations.of(context).groupRemoveAction,
            kind: AppButtonKind.danger,
            onPressed: () {
              popAppModal(context);
              unawaited(_confirmRemove(member));
            },
          ),
        ],
        if (GroupAuthorization.canChangeRole(
          widget.state,
          actorUserId: widget.currentUserId,
          targetUserId: member.userId,
          role: member.role == GroupRole.admin
              ? GroupRole.member
              : GroupRole.admin,
        )) ...[
          const SizedBox(height: AppSpacing.x2),
          AppButton(
            label: member.role == GroupRole.admin
                ? AppLocalizations.of(context).groupDemoteAction
                : AppLocalizations.of(context).groupPromoteAction,
            onPressed: () {
              popAppModal(context);
              unawaited(
                _mutate(
                  ChangeGroupRoleOperation(
                    targetUserId: member.userId,
                    role: member.role == GroupRole.admin
                        ? GroupRole.member
                        : GroupRole.admin,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: AppSpacing.x2),
          AppButton(
            label: AppLocalizations.of(context).groupTransferOwnerAction,
            onPressed: () {
              popAppModal(context);
              unawaited(
                _mutate(TransferGroupOwnershipOperation(member.userId)),
              );
            },
            kind: AppButtonKind.outline,
          ),
        ],
      ],
    ),
  );

  Future<void> _confirmRemove(GroupMember member) async {
    final strings = AppLocalizations.of(context);
    await showAppDialog<void>(
      context: context,
      title: strings.groupConfirmRemoveTitle,
      body: strings.groupConfirmRemoveBody,
      actions: [
        AppButton(
          label: strings.groupCancelAction,
          kind: AppButtonKind.ghost,
          onPressed: () => popAppModal(context),
        ),
        AppButton(
          label: strings.groupRemoveAction,
          kind: AppButtonKind.danger,
          onPressed: () {
            popAppModal(context);
            unawaited(_mutate(RemoveGroupMemberOperation(member.userId)));
          },
        ),
      ],
    );
  }

  Future<void> _confirmLeave() async {
    final strings = AppLocalizations.of(context);
    await showAppDialog<void>(
      context: context,
      title: strings.groupConfirmLeaveTitle,
      body: strings.groupConfirmLeaveBody,
      actions: [
        AppButton(
          label: strings.groupCancelAction,
          kind: AppButtonKind.ghost,
          onPressed: () => popAppModal(context),
        ),
        AppButton(
          label: strings.groupLeaveAction,
          kind: AppButtonKind.danger,
          onPressed: () {
            popAppModal(context);
            unawaited(_mutate(const LeaveGroupOperation()));
          },
        ),
      ],
    );
  }

  Future<void> _mutate(GroupControlOperation operation) async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    final result = await widget.onMutate(operation);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = result is FailureResult<GroupState>;
    });
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, required this.onTap});

  final GroupMember member;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Semantics(
      key: ValueKey('group-member-${member.userId}'),
      button: true,
      label: '${member.displayName}, ${_roleLabel(strings, member.role)}',
      child: ListTile(
        minTileHeight: AppFocus.minimumTarget,
        leading: ContactAvatar(
          username: member.displayName,
          semanticLabel: member.displayName,
          authenticatedSeed: groupAvatarSeed(member.userId),
        ),
        title: Text(member.displayName),
        subtitle: member.verified ? Text(strings.groupVerifiedMember) : null,
        trailing: AppStatusBadge(
          kind: member.role == GroupRole.owner
              ? AppStatusKind.information
              : AppStatusKind.neutral,
          label: _roleLabel(strings, member.role),
        ),
        onTap: onTap,
      ),
    );
  }
}

String _roleLabel(AppLocalizations strings, GroupRole role) => switch (role) {
  GroupRole.owner => strings.groupRoleOwner,
  GroupRole.admin => strings.groupRoleAdmin,
  GroupRole.member => strings.groupRoleMember,
};
