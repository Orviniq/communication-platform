import 'dart:async';

import 'package:communication_platform/app/dependencies/signal_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// "Show my online status" (ADR-098 D9): one switch in Settings, on by
/// default, that belongs to this phone.
///
/// A route or shell harness renders Settings without the production
/// container. There is no stored choice to read or write then, so the row is
/// left out rather than drawn as a switch that does nothing.
class OnlineStatusSettingsEntry extends StatelessWidget {
  const OnlineStatusSettingsEntry({super.key});

  @override
  Widget build(BuildContext context) {
    try {
      ProviderScope.containerOf(context);
    } on StateError {
      return const SizedBox.shrink();
    }
    return const _LiveOnlineStatusEntry();
  }
}

class _LiveOnlineStatusEntry extends ConsumerWidget {
  const _LiveOnlineStatusEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // Until the stored choice is read the switch shows the default, and takes
    // no tap: a tap on a value that was not read yet would write its opposite.
    final sharing = ref.watch(presenceSharingProvider);
    final value = sharing.value;
    return AppSwitchRow(
      key: const ValueKey('settings-online-status'),
      value: value ?? true,
      title: l10n.settingsOnlineStatusTitle,
      summary: l10n.settingsOnlineStatusSummary,
      onChanged: value == null
          ? null
          : (next) => unawaited(_set(context, ref, next)),
    );
  }

  Future<void> _set(BuildContext context, WidgetRef ref, bool sharing) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = AppLocalizations.of(context).settingsOnlineStatusSaveFailed;
    final setting = await ref.read(presenceShareSettingProvider.future);
    final result = await setting.set(sharing: sharing);
    if (result is FailureResult<void>) {
      messenger?.showSnackBar(SnackBar(content: Text(failed)));
    }
  }
}
