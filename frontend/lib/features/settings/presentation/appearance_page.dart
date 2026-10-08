import 'package:communication_platform/app/dependencies/settings.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/settings/domain/appearance_model.dart';
import 'package:communication_platform/features/settings/presentation/settings_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Theme and language, and nothing else.
///
/// Both are client-only: they are not sent anywhere, they describe no content,
/// and they say so on the screen. High contrast deliberately has no control
/// here — Android owns that switch and `MaterialApp` follows it, and a second
/// control beside the system one could only disagree with it.
final class AppearancePage extends ConsumerStatefulWidget {
  const AppearancePage({super.key});

  @override
  ConsumerState<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends ConsumerState<AppearancePage> {
  var _notStored = false;

  Future<void> _apply(AppearancePreferences next) async {
    final result = await ref
        .read(appearancePreferencesProvider.notifier)
        .update(next);
    if (!mounted) return;
    setState(() => _notStored = result is FailureResult<void>);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final preferences = ref.watch(appearancePreferencesProvider);
    return Scaffold(
      key: const ValueKey('appearance-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: l10n.authBackAction,
          onPressed: () => context.go('/settings'),
          kind: AppButtonKind.ghost,
        ),
        title: Text(l10n.appearanceTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppContentWidths.readable,
          ),
          child: ListView(
            padding: AppInsets.belowAppBar(context, AppSpacing.x4),
            children: [
              SettingsNote(l10n.appearanceLocalOnlyNotice),
              if (_notStored)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x2,
                    vertical: AppSpacing.x2,
                  ),
                  child: Semantics(
                    liveRegion: true,
                    child: AppStatusBadge(
                      kind: AppStatusKind.warning,
                      label: l10n.appearanceNotStoredNotice,
                    ),
                  ),
                ),
              SettingsSectionHeader(l10n.appearanceThemeSection),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.x2),
                  child: Column(
                    children: [
                      for (final theme in AppThemePreference.values)
                        SettingsChoiceRow<AppThemePreference>(
                          rowKey: ValueKey('appearance-theme-${theme.name}'),
                          label: _themeLabel(l10n, theme),
                          value: theme,
                          groupValue: preferences.theme,
                          onSelected: (value) =>
                              _apply(preferences.copyWith(theme: value)),
                        ),
                    ],
                  ),
                ),
              ),
              SettingsNote(l10n.appearanceContrastNotice),
              SettingsSectionHeader(l10n.appearanceLanguageSection),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.x2),
                  child: Column(
                    children: [
                      for (final language in AppLanguagePreference.values)
                        SettingsChoiceRow<AppLanguagePreference>(
                          rowKey: ValueKey(
                            'appearance-language-${language.name}',
                          ),
                          label: _languageLabel(l10n, language),
                          value: language,
                          groupValue: preferences.language,
                          onSelected: (value) =>
                              _apply(preferences.copyWith(language: value)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _themeLabel(AppLocalizations l10n, AppThemePreference theme) =>
      switch (theme) {
        AppThemePreference.system => l10n.appearanceThemeSystem,
        AppThemePreference.light => l10n.appearanceThemeLight,
        AppThemePreference.dark => l10n.appearanceThemeDark,
      };

  /// The two language names are written in their own language rather than
  /// translated. A person looking for Persian in an English interface is
  /// looking for the word they know, not for "Persian".
  static String _languageLabel(
    AppLocalizations l10n,
    AppLanguagePreference language,
  ) => switch (language) {
    AppLanguagePreference.system => l10n.appearanceLanguageSystem,
    AppLanguagePreference.english => l10n.appearanceLanguageEnglish,
    AppLanguagePreference.persian => l10n.appearanceLanguagePersian,
  };
}
