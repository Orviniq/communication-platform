import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/settings/presentation/settings_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Security & recovery (§15.2): the recovery secret, the verified contacts, and
/// the honest boundary statement.
///
/// The recovery text carries the whole reason replacement exists — an
/// already-saved secret is never re-shown, because the application does not
/// keep one — so a user who came here looking for their secret leaves knowing
/// why they cannot have it and what to do instead.
final class SecuritySettingsPage extends StatelessWidget {
  const SecuritySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('security-settings-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: l10n.authBackAction,
          onPressed: () => context.go('/settings'),
          kind: AppButtonKind.ghost,
        ),
        title: Text(l10n.securitySettingsTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppContentWidths.readable,
          ),
          child: ListView(
            padding: AppInsets.belowAppBar(context, AppSpacing.x4),
            children: [
              SettingsSectionHeader(l10n.securityRecoveryTitle),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.securityRecoveryBody,
                        style: context.tokens.typography.body,
                      ),
                      const SizedBox(height: AppSpacing.x4),
                      AppButton(
                        key: const ValueKey('security-rotate-recovery'),
                        label: l10n.securityRecoveryAction,
                        leading: AppIcons.retry,
                        kind: AppButtonKind.outline,
                        onPressed: () =>
                            context.go('/settings/security/recovery'),
                      ),
                    ],
                  ),
                ),
              ),
              SettingsSectionHeader(l10n.securitySafetyNumbersTitle),
              SettingsEntry(
                entryKey: const ValueKey('security-safety-numbers'),
                icon: AppIcons.security,
                title: l10n.securitySafetyNumbersTitle,
                summary: l10n.securitySafetyNumbersSummary,
                onTap: () => context.go('/settings/security/safety-numbers'),
              ),
              SettingsEntry(
                entryKey: const ValueKey('security-notice-link'),
                icon: AppIcons.info,
                title: l10n.authSecurityNoticeAction,
                onTap: () => context.push('/security-notice'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
