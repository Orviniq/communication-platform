import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// The group's identity block: avatar, name, description and member count.
///
/// Shared by the info screen and the wide-layout side panel the group
/// conversation shows beside its timeline, so the two cannot drift into
/// describing the same group differently.
class GroupInfoSummary extends StatelessWidget {
  const GroupInfoSummary({required this.state, super.key});
  final GroupState state;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label:
          '${state.metadata.name}, '
          '${strings.groupMemberCount(state.activeMembers.length)}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ContactAvatar(
            username: state.metadata.name,
            semanticLabel: state.metadata.name,
            authenticatedSeed: groupAvatarSeed(state.groupId),
            radius: 44,
          ),
          const SizedBox(height: AppSpacing.x3),
          Text(
            state.metadata.name,
            style: context.tokens.typography.title,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.x1),
          Text(
            state.metadata.description.isEmpty
                ? strings.groupNoDescription
                : state.metadata.description,
            style: context.tokens.typography.body.copyWith(
              color: context.tokens.colors.textMuted,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.x2),
          AppStatusBadge(
            kind: AppStatusKind.neutral,
            label: strings.groupMemberCount(state.activeMembers.length),
          ),
        ],
      ),
    );
  }
}

/// The banner a group raises when its lifecycle is anything but active.
///
/// Shared by the conversation and the info screen so that a removed, left,
/// gapped or quarantined group states the same reason on both, and so that the
/// reason is always a live region a screen reader announces.
class GroupLifecycleNotice extends StatelessWidget {
  const GroupLifecycleNotice({required this.lifecycle, super.key});
  final GroupLifecycle lifecycle;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final message = switch (lifecycle) {
      GroupLifecycle.active => '',
      GroupLifecycle.removed => strings.groupRemovedState,
      GroupLifecycle.left => strings.groupLeftState,
      GroupLifecycle.stateRecoveryRequired => strings.groupQueueGapState,
      GroupLifecycle.forkQuarantined => strings.groupForkState,
      GroupLifecycle.controlQuarantined => strings.groupControlQuarantineState,
    };
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: ColoredBox(
        color: context.tokens.colors.warning.withValues(alpha: 0.16),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x3),
          child: Text(message, style: context.tokens.typography.compact),
        ),
      ),
    );
  }
}

/// What every message in a group costs, said where a group is made and where
/// its members are listed.
///
/// A group is a set of pairwise sessions (`backend/CLIENT_CONTRACT.md` §F), so
/// one message is one encrypted copy for each device of each member. Saying so
/// keeps a slow send in a large group from looking like a broken one.
class GroupFanoutNotice extends StatelessWidget {
  const GroupFanoutNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    return DecoratedBox(
      key: const ValueKey('group-fanout-notice'),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: AppRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon(AppIcons.info, color: colors.textMuted, size: 18),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: Text(
                AppLocalizations.of(context).groupFanoutCostNote,
                style: context.tokens.typography.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one-line failure a group screen shows in place, without a dialog.
///
/// Named for the feature rather than `InlineError`, because the chat and
/// contact surfaces carry their own equivalents and the three are imported
/// together often enough that a bare name would collide.
class GroupInlineError extends StatelessWidget {
  const GroupInlineError({required this.message, super.key});
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: context.tokens.typography.compact.copyWith(
        color: context.tokens.colors.danger,
      ),
    ),
  );
}

/// Caps a group screen's body at a readable measure on a wide window.
///
/// Named for the feature for the same reason as [GroupInlineError].
class GroupResponsiveBody extends StatelessWidget {
  const GroupResponsiveBody({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: child,
    ),
  );
}

/// The placeholder every group route shows while its providers resolve.
Widget groupLoadingPage(BuildContext context) => Scaffold(
  body: Center(
    child: AppStatePanel.loading(
      title: AppLocalizations.of(context).contactsLoadingTitle,
    ),
  ),
);

/// The screen every group route shows when a provider fails or a group that
/// was routed to is not there.
Widget groupErrorPage(BuildContext context) => Scaffold(
  body: Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.x6),
      child: AppStatePanel.error(
        title: AppLocalizations.of(context).chatsErrorTitle,
        message: AppLocalizations.of(context).groupActionFailed,
      ),
    ),
  ),
);

/// The stable colour seed an identifier gets in a group avatar.
///
/// Shared so that one user, one group and one member row all derive the same
/// colour from the same identifier no matter which screen draws them.
int groupAvatarSeed(String value) => value.codeUnits.fold<int>(
  0,
  (seed, unit) => ((seed * 31) + unit) & 0x7fffffff,
);
