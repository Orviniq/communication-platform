import 'package:communication_platform/app/config/app_environment_banner.dart';
import 'package:communication_platform/app/config/build_identity.dart';
import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/settings/presentation/settings_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// About (§15.9): what this build is, read from this build.
///
/// Every value is a compile-time constant or a local read. Nothing is fetched,
/// which is both the privacy property and the operational one — this screen
/// works during an internet shutdown, which is when somebody is most likely to
/// be reading it in order to explain a problem to whoever runs their server.
///
/// The build is named once, in the reviewed application title, and the flavor
/// identifier is deliberately **not** shown. A row saying `Build: PRODUCTION`
/// beneath that title would give one artifact a second name, and a vocabulary
/// about builds of its own reaching users, which is the defect ADR-045 exists
/// to have removed. The technical value still travels, in the diagnostics
/// export, which is a document for an operator rather than a claim made to the
/// person holding the phone.
final class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final environment = ref.watch(appEnvironmentProvider);
    final disclosure = environment.deploymentDisclosure;
    return Scaffold(
      key: const ValueKey('about-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: l10n.authBackAction,
          onPressed: () => context.go('/settings'),
          kind: AppButtonKind.ghost,
        ),
        title: Text(l10n.settingsAboutTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppContentWidths.readable,
          ),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.x4),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        environment.userFacingTitle(l10n),
                        style: context.tokens.typography.section,
                      ),
                      const SizedBox(height: AppSpacing.x3),
                      _AboutRow(
                        rowKey: const ValueKey('about-version'),
                        label: l10n.aboutVersionLabel,
                        value: BuildIdentity.version,
                      ),
                      if (disclosure != null)
                        _AboutRow(
                          rowKey: const ValueKey('about-disclosure'),
                          label: l10n.aboutDisclosureLabel,
                          value: '${disclosure.revision}',
                        ),
                    ],
                  ),
                ),
              ),
              SettingsNote(l10n.aboutLocalOnlyNotice),
              SettingsEntry(
                entryKey: const ValueKey('about-security-notice'),
                icon: AppIcons.info,
                title: l10n.authSecurityNoticeAction,
                onTap: () => context.push('/security-notice'),
              ),
              SettingsEntry(
                entryKey: const ValueKey('about-diagnostics'),
                icon: AppIcons.unsupported,
                title: l10n.diagnosticsTitle,
                summary: l10n.diagnosticsSummary,
                onTap: () => context.go('/settings/about/diagnostics'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.label,
    required this.value,
    required this.rowKey,
  });

  final String label;
  final String value;
  final Key rowKey;

  @override
  Widget build(BuildContext context) => Padding(
    key: rowKey,
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: context.tokens.typography.compact.copyWith(
              color: context.tokens.colors.textMuted,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.x3),
        // A version string is a Latin-script technical value: it reads the same
        // way in both interface languages, so it is not mirrored with the
        // paragraph around it.
        Text(
          value,
          textDirection: TextDirection.ltr,
          style: context.tokens.typography.compact,
        ),
      ],
    ),
  );
}
