import 'dart:async';

import 'package:communication_platform/app/dependencies/recovery_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/rotate_recovery_secret.dart';
import 'package:communication_platform/features/devices/presentation/sensitive_screen_control.dart';
import 'package:communication_platform/features/settings/presentation/settings_components.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Which of the four things this screen can be showing.
enum RecoveryRotationStage { explain, working, shown, failed }

/// Replacing the recovery secret (§15.2), and the one screen it is shown on.
///
/// Three properties are what make this safe to offer, and all three are visible
/// here rather than assumed:
///
/// * Screen capture is blocked for as long as this route is mounted, and
///   released when it is not, so the protection does not leak into the rest of
///   the application (a required control in the threat model).
/// * A copy goes through the clipboard path that expires, and a build without
///   that path says copying is unavailable rather than silently using an
///   ordinary clipboard that never clears.
/// * The new secret is shown **only** after the server accepted the new backup.
///   A failure says the current secret still works, because it does.
final class RecoveryRotationPage extends ConsumerStatefulWidget {
  const RecoveryRotationPage({
    this.control = const SensitiveScreenControl(),
    super.key,
  });

  final SensitiveScreenControl control;

  @override
  ConsumerState<RecoveryRotationPage> createState() =>
      _RecoveryRotationPageState();
}

class _RecoveryRotationPageState extends ConsumerState<RecoveryRotationPage> {
  var _stage = RecoveryRotationStage.explain;
  RotatedRecoverySecret? _rotated;
  String? _copyMessage;

  @override
  void initState() {
    super.initState();
    // Enabled for the whole route, not only while the secret is on screen: the
    // explanation names what the next tap produces, and a capture taken a
    // moment early is a capture of the same screen.
    unawaited(widget.control.setEnabled(true));
  }

  @override
  void dispose() {
    unawaited(widget.control.setEnabled(false));
    super.dispose();
  }

  Future<void> _rotate() async {
    setState(() {
      _stage = RecoveryRotationStage.working;
      _copyMessage = null;
    });
    final result = await ref
        .read(rotateRecoverySecretProvider.future)
        .then(
          (useCase) => useCase.call(),
          onError: (Object _) =>
              const Result<RotatedRecoverySecret>.failure(_unavailable),
        );
    if (!mounted) return;
    setState(() {
      switch (result) {
        case Success(value: final rotated):
          _rotated = rotated;
          _stage = RecoveryRotationStage.shown;
        case FailureResult():
          _stage = RecoveryRotationStage.failed;
      }
    });
  }

  Future<void> _copy() async {
    final secret = _rotated?.secret;
    if (secret == null) return;
    final l10n = AppLocalizations.of(context);
    final copied = await widget.control.copyText(secret);
    if (!mounted) return;
    setState(
      () => _copyMessage = copied
          ? l10n.recoveryRotationCopiedMessage
          : l10n.recoveryRotationCopyUnavailable,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('recovery-rotation-screen'),
      appBar: AppBar(
        leading: AppIconButton(
          icon: AppIcons.back,
          semanticLabel: l10n.authBackAction,
          onPressed: () => context.go('/settings/security'),
          kind: AppButtonKind.ghost,
        ),
        title: Text(l10n.recoveryRotationTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppContentWidths.readable,
          ),
          child: ListView(
            padding: AppInsets.belowAppBar(context, AppSpacing.x6),
            children: switch (_stage) {
              RecoveryRotationStage.explain => _explain(l10n),
              RecoveryRotationStage.working => [
                AppStatePanel.loading(title: l10n.recoveryRotationWorking),
              ],
              RecoveryRotationStage.shown => _shown(l10n),
              RecoveryRotationStage.failed => _failed(l10n),
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _explain(AppLocalizations l10n) => [
    Text(l10n.recoveryRotationExplain, style: context.tokens.typography.body),
    const SizedBox(height: AppSpacing.x4),
    AppStatusBadge(
      kind: AppStatusKind.warning,
      label: l10n.recoveryRotationCost,
    ),
    const SizedBox(height: AppSpacing.x4),
    SettingsNote(l10n.recoveryRotationNoHistoryNotice),
    SettingsNote(l10n.recoveryRotationScreenshotNotice),
    const SizedBox(height: AppSpacing.x6),
    AppButton(
      key: const ValueKey('recovery-rotation-start'),
      label: l10n.recoveryRotationStartAction,
      leading: AppIcons.retry,
      onPressed: _rotate,
    ),
  ];

  List<Widget> _shown(AppLocalizations l10n) {
    final secret = _rotated?.secret ?? '';
    final message = _copyMessage;
    return [
      Semantics(
        header: true,
        child: Text(
          l10n.recoveryRotationDoneTitle,
          style: context.tokens.typography.title,
        ),
      ),
      const SizedBox(height: AppSpacing.x3),
      AppStatusBadge(
        kind: AppStatusKind.warning,
        label: l10n.recoveryRotationShownOnce,
      ),
      const SizedBox(height: AppSpacing.x4),
      DecoratedBox(
        decoration: BoxDecoration(
          color: context.tokens.colors.surfaceRaised,
          borderRadius: AppRadii.card,
          border: Border.all(color: context.tokens.colors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x4),
          child: SelectableText(
            secret,
            key: const ValueKey('recovery-rotation-secret'),
            textAlign: TextAlign.center,
            // Left-to-right whatever the interface language is: the
            // secret is a Crockford-base32 value, and rendering it in a
            // right-to-left paragraph would reverse the order a person
            // copies it in.
            textDirection: TextDirection.ltr,
            style: context.tokens.typography.section.copyWith(
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.x4),
      AppButton(
        key: const ValueKey('recovery-rotation-copy'),
        label: l10n.recoveryRotationCopyAction,
        leading: AppIcons.copy,
        kind: AppButtonKind.outline,
        onPressed: _copy,
      ),
      if (message != null)
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.x2),
          child: Semantics(
            liveRegion: true,
            child: Text(
              message,
              style: context.tokens.typography.compact.copyWith(
                color: context.tokens.colors.textMuted,
              ),
            ),
          ),
        ),
      SettingsNote(l10n.recoveryRotationScreenshotNotice),
      const SizedBox(height: AppSpacing.x6),
      AppButton(
        key: const ValueKey('recovery-rotation-finish'),
        label: l10n.recoveryRotationFinishAction,
        onPressed: () => context.go('/settings/security'),
      ),
    ];
  }

  List<Widget> _failed(AppLocalizations l10n) => [
    AppStatePanel.error(
      title: l10n.recoveryRotationFailedTitle,
      message: l10n.recoveryRotationFailedBody,
      actionLabel: l10n.retryAction,
      onAction: _rotate,
    ),
    SettingsNote(l10n.recoveryRotationUnavailableBody),
  ];
}

/// The failure used when the rotation use case itself cannot be composed.
///
/// The screen shows one message for every failure — the current secret still
/// works — so the classification only has to exist, not to be
/// distinguishable.
const _unavailable = StorageFailure(StorageFailureKind.unavailable);
