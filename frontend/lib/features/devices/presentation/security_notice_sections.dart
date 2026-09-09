import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The body of the one security notice, shared by the mandatory enrollment
/// step, by the one-time re-presentation, and by every place the notice is
/// re-opened.
///
/// There is exactly one copy of this content. Before ADR-045 the enrollment
/// gate and the pre-login link rendered two different notices under two
/// different titles, so what a user was required to acknowledge and what a user
/// could go back and re-read were not the same statement.
///
/// The first two sections are permanent: they describe the protocol's threat
/// boundary and stay true in a production release. They therefore name no
/// feature — ADR-052 removed "files" and "voice audio" from the first, because
/// the artifact carrying that sentence can send neither, and a permanent
/// section that enumerates capabilities goes stale every time the feature set
/// does. The third describes the build that is running and appears only in a
/// build that is handed to someone else, so temporary wording cannot survive
/// into a release that no longer deserves it.
final class SecurityNoticeSections extends ConsumerWidget {
  const SecurityNoticeSections({this.changedPoints = const {}, super.key});

  /// Points to mark as new or different, when this is being shown to somebody
  /// who accepted an earlier revision. Empty everywhere else, including the
  /// first showing — marking every point on a statement nobody has seen before
  /// marks nothing (ADR-052).
  final Set<DisclosurePoint> changedPoints;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final disclosure = ref.watch(appEnvironmentProvider).deploymentDisclosure;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          heading: l10n.enrollmentProtectsHeading,
          body: l10n.enrollmentProtectsBody,
        ),
        const SizedBox(height: AppSpacing.x6),
        _Section(
          heading: l10n.enrollmentDoesNotProtectHeading,
          body: l10n.enrollmentDoesNotProtectBody,
          headingColor: context.tokens.colors.danger,
        ),
        if (disclosure != null) ...[
          const SizedBox(height: AppSpacing.x6),
          _BuildDisclosure(
            disclosure: disclosure,
            changed: changedPoints,
            limits: ref.watch(publishedLimitsProvider),
          ),
        ],
      ],
    );
  }
}

final class _Section extends StatelessWidget {
  const _Section({
    required this.heading,
    required this.body,
    this.headingColor,
  });

  final String heading;
  final String body;
  final Color? headingColor;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        heading,
        style: context.tokens.typography.section.copyWith(color: headingColor),
      ),
      const SizedBox(height: AppSpacing.x2),
      Text(body, style: context.tokens.typography.body),
    ],
  );
}

/// What the running build is, as an ordered list of consequences.
///
/// Each point is one fact that an ordinary expectation of a chat application
/// would otherwise get wrong. They are rendered as separate items rather than
/// one paragraph because a reader who stops early should still have read the
/// most consequential ones.
final class _BuildDisclosure extends StatelessWidget {
  const _BuildDisclosure({
    required this.disclosure,
    required this.changed,
    required this.limits,
  });

  final DeploymentDisclosure disclosure;
  final Set<DisclosurePoint> changed;

  /// The deployment's published limits, for the one point that states a number.
  final ServerConfig limits;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.tokens.colors;

    return DecoratedBox(
      key: const ValueKey('deployment-disclosure'),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.10),
        borderRadius: AppRadii.compact,
        border: Border.all(color: colors.warning),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppStatusBadge(
                kind: AppStatusKind.warning,
                label: SurfaceMaturity.experimental.label(l10n),
              ),
            ),
            const SizedBox(height: AppSpacing.x3),
            Text(
              disclosure.title(l10n),
              style: context.tokens.typography.section,
            ),
            for (final point in disclosure.points) ...[
              const SizedBox(height: AppSpacing.x3),
              _DisclosureItem(
                text: point.text(l10n, limits),
                changed: changed.contains(point),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _DisclosureItem extends StatelessWidget {
  const _DisclosureItem({required this.text, required this.changed});

  final String text;
  final bool changed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(
          AppIcons.warning,
          color: context.tokens.colors.warning,
          size: 16,
          decorative: true,
        ),
        const SizedBox(width: AppSpacing.x2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The mark is a labelled badge, not a colour or an icon. A
              // reader using a screen reader, and a reader who cannot
              // distinguish the accent, both have to be told which points
              // moved, because that is the entire reason this screen exists.
              if (changed) ...[
                AppStatusBadge(
                  kind: AppStatusKind.information,
                  label: l10n.disclosureChangedLabel,
                ),
                const SizedBox(height: AppSpacing.x1),
              ],
              Text(text, style: context.tokens.typography.body),
            ],
          ),
        ),
      ],
    );
  }
}
