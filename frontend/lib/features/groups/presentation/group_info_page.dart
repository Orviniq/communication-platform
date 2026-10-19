import 'dart:async';

import 'package:communication_platform/app/dependencies/group_member_name_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_components.dart';
import 'package:communication_platform/features/groups/presentation/group_member_labels.dart';
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
    this.injectedMemberNames,
    super.key,
  });

  final String groupId;
  final GroupState? injectedState;
  final String? currentUserId;
  final MutateGroupCallback? onMutate;

  /// The names an injected page shows, as the contacts store would hand them
  /// to the routed page. Null: this phone names nobody.
  final GroupMemberNames? injectedMemberNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (injectedState != null && onMutate != null) {
      return GroupInfoView(
        state: injectedState!,
        memberNames: injectedMemberNames ?? const GroupMemberNames.empty(),
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
        // Left, or removed, on this device or another of this account's: the
        // group and its history are gone from this phone (ADR-096 D3).
        if (groupGoneFromThisPhone(group)) return groupGonePage(context);
        final names = ref.watch(
          groupMemberNamesProvider(
            GroupMemberNamesRequest(
              group.members.map((member) => member.userId),
            ),
          ),
        );
        return device.when(
          loading: () => groupLoadingPage(context),
          error: (_, _) => groupErrorPage(context),
          data: (deviceId) => useCases.when(
            loading: () => groupLoadingPage(context),
            error: (_, _) => groupErrorPage(context),
            data: (resolved) {
              GroupInfoView view(GroupMemberNames memberNames) => GroupInfoView(
                state: group,
                memberNames: memberNames,
                currentUserId: userId,
                onMutate: (operation) => resolved.mutate(
                  groupId: groupId,
                  actorUserId: userId,
                  actorDeviceId: deviceId,
                  operation: operation,
                ),
                onLeft: () => context.go('/chats'),
              );
              return names.when(
                loading: () => groupLoadingPage(context),
                // A failed read names nobody: every member is "Unknown
                // member", which is true, and the page stays usable.
                error: (_, _) => view(const GroupMemberNames.empty()),
                data: view,
              );
            },
          ),
        );
      },
    );
  }
}

class GroupInfoView extends StatefulWidget {
  const GroupInfoView({
    required this.state,
    required this.memberNames,
    required this.currentUserId,
    required this.onMutate,
    this.onLeft,
    this.embedded = false,
    super.key,
  });

  final GroupState state;

  /// What this phone calls each member. The group holds user ids and roles
  /// only.
  final GroupMemberNames memberNames;
  final String currentUserId;
  final MutateGroupCallback onMutate;

  /// Called once a Leave this page asked for has committed: the group is
  /// then gone from this phone, and the page returns to Chats (ADR-096 D3).
  final VoidCallback? onLeft;
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
        padding: AppInsets.belowAppBar(context, AppSpacing.x4),
        children: [
          if (state.lifecycle != GroupLifecycle.active) ...[
            const SizedBox(height: AppSpacing.x3),
            GroupLifecycleNotice(lifecycle: state.lifecycle),
          ],
          const SizedBox(height: AppSpacing.x6),
          GroupInfoSummary(state: state),
          const SizedBox(height: AppSpacing.x6),
          Text(
            strings.groupMembersSection,
            style: context.tokens.typography.section,
          ),
          const SizedBox(height: AppSpacing.x2),
          for (final member in state.members.where((member) => member.isActive))
            _MemberRow(
              member: member,
              name: widget.memberNames.labelOf(member.userId, strings),
              verified: widget.memberNames.isVerified(member.userId),
              onTap: () => _showMember(member),
            ),
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
          const SizedBox(height: AppSpacing.x4),
          const GroupFanoutNotice(),
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

  Future<void> _showMember(GroupMember member) {
    final name = widget.memberNames.labelOf(
      member.userId,
      AppLocalizations.of(context),
    );
    return showAppSheet<void>(
      context: context,
      semanticLabel: name,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(name, style: context.tokens.typography.section),
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
                // Handing the group over is one role change: the member
                // becomes the owner and this owner becomes an admin.
                unawaited(
                  _mutate(
                    ChangeGroupRoleOperation(
                      targetUserId: member.userId,
                      role: GroupRole.owner,
                    ),
                  ),
                );
              },
              kind: AppButtonKind.outline,
            ),
          ],
        ],
      ),
    );
  }

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
            // Leaving is removing yourself, signed like any other removal.
            unawaited(
              _mutate(RemoveGroupMemberOperation(widget.currentUserId)),
            );
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
    if (result is Success<GroupState> &&
        operation is RemoveGroupMemberOperation &&
        operation.targetUserId == widget.currentUserId.toLowerCase()) {
      widget.onLeft?.call();
      return;
    }
    setState(() {
      _busy = false;
      _failed = result is FailureResult<GroupState>;
    });
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.name,
    required this.verified,
    required this.onTap,
  });

  final GroupMember member;

  /// What this phone calls the member: never blank, never the user id.
  final String name;

  /// This phone's trust state of the member, not the group's.
  final bool verified;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Semantics(
      key: ValueKey('group-member-${member.userId}'),
      button: true,
      label: '$name, ${_roleLabel(strings, member.role)}',
      child: ListTile(
        minTileHeight: AppFocus.minimumTarget,
        leading: ContactAvatar(
          username: name,
          semanticLabel: name,
          authenticatedSeed: groupAvatarSeed(member.userId),
        ),
        title: Text(name),
        subtitle: verified ? Text(strings.groupVerifiedMember) : null,
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
