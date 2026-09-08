import 'package:communication_platform/app/dependencies/linked_device_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Linked Devices (§16): this device, the others, and what removing one costs.
///
/// There is deliberately no "Add device" button that goes anywhere. §16.1's
/// flow starts on the *other* device — install, sign in, enter the recovery
/// secret — and there is nothing for this one to start; what it can do is stay
/// online afterwards so it can send its history across, because the server has
/// none to send. A button here would have been a control that cannot succeed.
final class LinkedDevicesPage extends ConsumerStatefulWidget {
  const LinkedDevicesPage({
    this.onRefresh,
    this.onRelabel,
    this.onRevoke,
    super.key,
  });

  final Future<void> Function()? onRefresh;
  final Future<void> Function(String deviceId, String label)? onRelabel;
  final Future<void> Function(String deviceId)? onRevoke;

  @override
  ConsumerState<LinkedDevicesPage> createState() => _LinkedDevicesPageState();
}

final class _LinkedDevicesPageState extends ConsumerState<LinkedDevicesPage> {
  var _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    if (widget.onRefresh case final callback?) {
      await callback();
    } else {
      final manager = await ref.read(linkedDeviceManagerProvider.future);
      await manager.refresh();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _relabel(LinkedDevice device) async {
    final label = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDeviceDialog(initial: device.label ?? ''),
    );
    if (label == null || label.isEmpty) return;
    if (widget.onRelabel case final callback?) {
      await callback(device.deviceId, label);
    } else {
      final manager = await ref.read(linkedDeviceManagerProvider.future);
      await manager.relabel(deviceId: device.deviceId, label: label);
    }
  }

  Future<void> _revoke(LinkedDevice device) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showAppDialog<bool>(
      context: context,
      title: device.thisDevice
          ? l10n.linkedDevicesRemoveSelfTitle
          : l10n.linkedDevicesRemoveTitle,
      body: device.thisDevice
          ? l10n.linkedDevicesRemoveSelfBody
          : l10n.linkedDevicesRemoveBody,
      actions: [
        AppButton(
          label: l10n.settingsCancelAction,
          kind: AppButtonKind.ghost,
          onPressed: () => Navigator.pop(context, false),
        ),
        AppButton(
          key: const ValueKey('linked-device-remove-confirm'),
          label: l10n.linkedDevicesRemoveAction,
          kind: AppButtonKind.danger,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (confirmed != true) return;
    if (widget.onRevoke case final callback?) {
      await callback(device.deviceId);
    } else {
      final manager = await ref.read(linkedDeviceManagerProvider.future);
      await manager.revoke(deviceId: device.deviceId);
    }
    if (device.thisDevice && mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final devices = ref.watch(linkedDevicesProvider);
    return Scaffold(
      key: const ValueKey('linked-devices-screen'),
      appBar: AppBar(
        title: Text(l10n.settingsLinkedDevicesTitle),
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: l10n.authBackAction,
          onPressed: () => context.go('/settings'),
          kind: AppButtonKind.ghost,
        ),
        actions: [
          AppIconButton(
            icon: AppIcons.retry,
            semanticLabel: l10n.linkedDevicesRefreshAction,
            onPressed: _busy ? null : _refresh,
            kind: AppButtonKind.ghost,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppContentWidths.readable,
          ),
          child: devices.when(
            loading: () =>
                AppStatePanel.loading(title: l10n.linkedDevicesLoadingTitle),
            // The failure classification never reaches the user. A raw
            // exception here would put backend detail on a screen this
            // repository requires to carry reviewed, localized copy only.
            error: (_, _) => AppStatePanel.error(
              title: l10n.linkedDevicesUnavailableTitle,
              message: l10n.linkedDevicesUnavailableMessage,
              actionLabel: l10n.retryAction,
              onAction: _busy ? null : _refresh,
            ),
            data: (rows) => RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.x4),
                children: [
                  AppStatusBadge(
                    kind: AppStatusKind.information,
                    label: l10n.linkedDevicesLabelsEncrypted,
                  ),
                  const SizedBox(height: AppSpacing.x4),
                  if (rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.x4),
                      child: Text(
                        l10n.linkedDevicesEmptyTitle,
                        style: context.tokens.typography.body,
                      ),
                    ),
                  for (final row in rows)
                    _DeviceRow(
                      device: row,
                      onRename: () => _relabel(row),
                      onRemove: () => _revoke(row),
                    ),
                  const SizedBox(height: AppSpacing.x6),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.linkedDevicesAddTitle,
                      style: context.tokens.typography.section,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x2),
                  Text(
                    l10n.linkedDevicesAddBody,
                    style: context.tokens.typography.body.copyWith(
                      color: context.tokens.colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.onRename,
    required this.onRemove,
  });

  final LinkedDevice device;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      child: ListTile(
        key: ValueKey('linked-device-${device.deviceId}'),
        leading: AppIcon(
          device.thisDevice ? AppIcons.devices : AppIcons.devices,
          decorative: true,
        ),
        title: Text(
          device.label ??
              (device.thisDevice
                  ? l10n.linkedDevicesThisDevice
                  : l10n.linkedDevicesUnnamed),
        ),
        subtitle: Text(
          device.thisDevice
              ? l10n.linkedDevicesCurrentSubtitle
              : _added(l10n, device.createdDate),
        ),
        trailing: PopupMenuButton<_DeviceAction>(
          key: ValueKey('linked-device-menu-${device.deviceId}'),
          onSelected: (action) => switch (action) {
            _DeviceAction.rename => onRename(),
            _DeviceAction.remove => onRemove(),
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _DeviceAction.rename,
              child: Text(l10n.linkedDevicesRenameAction),
            ),
            PopupMenuItem(
              value: _DeviceAction.remove,
              child: Text(l10n.linkedDevicesRemoveAction),
            ),
          ],
        ),
      ),
    );
  }

  /// The day the device was added, which is the only date the server still
  /// reports about one. It is not a last-seen day and is not labelled as one:
  /// nothing records when a device was last used, here or on the server.
  ///
  /// The backend reports a calendar day and no time zone, so the day is
  /// rendered exactly as it was reported.
  ///
  /// It used to go through `toLocal()`, which turned a coarse UTC day into the
  /// previous day for every reader west of UTC — a wrong date, and a value
  /// finer than the one the server actually holds.
  static String _added(AppLocalizations l10n, DateTime date) {
    final utc = date.toUtc();
    final year = utc.year.toString().padLeft(4, '0');
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    return l10n.linkedDevicesAdded('$year-$month-$day');
  }
}

enum _DeviceAction { rename, remove }

final class _RenameDeviceDialog extends StatefulWidget {
  const _RenameDeviceDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

final class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.linkedDevicesRenameTitle),
      // A plain field rather than the app-owned one: this dialog is pushed
      // on the root navigator, outside `AppDesignSystem`, and the design
      // system's own field reads a scope that does not exist there.
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 64,
        decoration: InputDecoration(labelText: l10n.linkedDevicesRenameLabel),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.settingsCancelAction),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: Text(l10n.linkedDevicesSaveAction),
        ),
      ],
    );
  }
}
