import 'package:communication_platform/app/dependencies/sustained_delivery.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/synchronization/domain/sustained_delivery_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The Settings row for receiving while the application is closed.
///
/// Route and app-shell harnesses render this surface without the production
/// container, so the row states what it can see rather than failing: with no
/// composition there is no implementation, and "not available" is the truthful
/// reading of that, not a fallback pretending to be one.
class SustainedDeliverySettingsEntry extends StatelessWidget {
  const SustainedDeliverySettingsEntry({super.key});

  @override
  Widget build(BuildContext context) {
    try {
      ProviderScope.containerOf(context);
    } on StateError {
      return const _SustainedRow(status: SustainedDeliveryStatus.unavailable);
    }
    return const _LiveSustainedSettingsEntry();
  }
}

class _LiveSustainedSettingsEntry extends ConsumerWidget {
  const _LiveSustainedSettingsEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _SustainedRow(status: ref.watch(sustainedDeliveryControllerProvider));
}

class _SustainedRow extends StatelessWidget {
  const _SustainedRow({required this.status});

  final SustainedDeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      child: ListTile(
        key: const ValueKey('settings-sustained-delivery'),
        leading: const AppIcon(AppIcons.settings),
        title: Text(l10n.settingsSustainedTitle),
        subtitle: Text(settingsSustainedSummary(l10n, status)),
        trailing: const AppIcon(AppIcons.forward, decorative: true),
        onTap: () => context.push('/settings/receiving-while-closed'),
      ),
    );
  }
}

/// The one-line summary, for the Settings list.
String settingsSustainedSummary(
  AppLocalizations l10n,
  SustainedDeliveryStatus status,
) => switch (status) {
  SustainedDeliveryStatus.unavailable => l10n.settingsSustainedUnavailable,
  SustainedDeliveryStatus.withheld => l10n.settingsSustainedWithheld,
  SustainedDeliveryStatus.off => l10n.settingsSustainedOff,
  SustainedDeliveryStatus.holding => l10n.settingsSustainedHolding,
  SustainedDeliveryStatus.alertsWithheld =>
    l10n.settingsSustainedAlertsWithheld,
  SustainedDeliveryStatus.exemptionWithdrawn =>
    l10n.settingsSustainedExemptionWithdrawn,
  SustainedDeliveryStatus.stopped => l10n.settingsSustainedStopped,
};

/// The full status sentence, for the screen itself.
String sustainedStatusText(
  AppLocalizations l10n,
  SustainedDeliveryStatus status,
) => switch (status) {
  SustainedDeliveryStatus.unavailable => l10n.sustainedStatusUnavailable,
  SustainedDeliveryStatus.withheld => l10n.sustainedStatusWithheld,
  SustainedDeliveryStatus.off => l10n.sustainedStatusOff,
  SustainedDeliveryStatus.holding => l10n.sustainedStatusHolding,
  SustainedDeliveryStatus.alertsWithheld => l10n.sustainedStatusAlertsWithheld,
  SustainedDeliveryStatus.exemptionWithdrawn =>
    l10n.sustainedStatusExemptionWithdrawn,
  SustainedDeliveryStatus.stopped => l10n.sustainedStatusStopped,
};

/// What the user is told when turning it on did not finish.
String sustainedRefusalText(
  AppLocalizations l10n,
  SustainedDeliveryRefusal refusal,
) => switch (refusal) {
  SustainedDeliveryRefusal.unavailable => l10n.sustainedRefusedUnavailable,
  SustainedDeliveryRefusal.withheld => l10n.sustainedRefusedWithheld,
  SustainedDeliveryRefusal.alertsRefused => l10n.sustainedRefusedAlerts,
  SustainedDeliveryRefusal.exemptionRefused => l10n.sustainedRefusedExemption,
  SustainedDeliveryRefusal.platformRefused => l10n.sustainedRefusedPlatform,
  SustainedDeliveryRefusal.notRecorded => l10n.sustainedRefusedNotRecorded,
};

/// The one screen that explains this capability, obtains what it needs, and
/// states its limits.
///
/// The order on the page is what it costs before what it does not promise,
/// and both before the switch. Nothing here nags: the vendor step is offered
/// once, as a button, and is never presented as something this application has
/// confirmed — because it cannot read those settings and never will.
class SustainedDeliveryPage extends ConsumerStatefulWidget {
  const SustainedDeliveryPage({super.key});

  @override
  ConsumerState<SustainedDeliveryPage> createState() =>
      _SustainedDeliveryPageState();
}

class _SustainedDeliveryPageState extends ConsumerState<SustainedDeliveryPage> {
  bool _busy = false;
  SustainedDeliveryRefusal? _refusal;

  Future<void> _turnOn() async {
    setState(() {
      _busy = true;
      _refusal = null;
    });
    final refusal = await ref
        .read(sustainedDeliveryControllerProvider.notifier)
        .enable();
    if (mounted) {
      setState(() {
        _busy = false;
        _refusal = refusal;
      });
    }
  }

  Future<void> _turnOff() async {
    setState(() {
      _busy = true;
      _refusal = null;
    });
    await ref.read(sustainedDeliveryControllerProvider.notifier).disable();
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(sustainedDeliveryControllerProvider);
    // Two states offer nothing: a build with no implementation, and a build
    // withholding one it has (ADR-053). Both leave the switch and the vendor
    // shortcut inert, because in neither would pressing anything change what
    // this phone does.
    final offersSwitch = status.offersSwitch;
    final on = status != SustainedDeliveryStatus.off && offersSwitch;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sustainedTitle)),
      body: ListView(
        padding: AppInsets.belowAppBar(context, AppSpacing.x4),
        children: [
          _Paragraph(l10n.sustainedWhatItDoes),
          _Paragraph(l10n.sustainedWhatItCosts),
          _Paragraph(l10n.sustainedWhatItCannotPromise),
          const SizedBox(height: AppSpacing.x2),
          Text(
            l10n.sustainedNeedsTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.x2),
          _Requirement(l10n.sustainedNeedsAlerts),
          _Requirement(l10n.sustainedNeedsExemption),
          _Requirement(l10n.sustainedNeedsVendor),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('sustained-vendor-settings'),
              onPressed: offersSwitch
                  ? () => ref
                        .read(sustainedDeliveryControllerProvider.notifier)
                        .openVendorSettings()
                  : null,
              child: Text(l10n.sustainedVendorAction),
            ),
          ),
          const SizedBox(height: AppSpacing.x4),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sustainedStatusText(l10n, status),
                    key: const ValueKey('sustained-status'),
                  ),
                  if (_refusal case final refusal?) ...[
                    const SizedBox(height: AppSpacing.x2),
                    Text(
                      sustainedRefusalText(l10n, refusal),
                      key: const ValueKey('sustained-refusal'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.x3),
                  FilledButton(
                    key: const ValueKey('sustained-toggle'),
                    onPressed: _busy || !offersSwitch
                        ? null
                        : (on ? _turnOff : _turnOn),
                    child: Text(
                      on ? l10n.sustainedTurnOff : l10n.sustainedTurnOn,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.x3),
    child: Text(text),
  );
}

class _Requirement extends StatelessWidget {
  const _Requirement(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.x2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsetsDirectional.only(end: AppSpacing.x2, top: 2),
          child: AppIcon(AppIcons.forward, decorative: true),
        ),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
