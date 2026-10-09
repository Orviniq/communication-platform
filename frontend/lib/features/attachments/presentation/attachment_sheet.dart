import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

final class AttachmentSheet extends StatelessWidget {
  const AttachmentSheet({this.descriptor, this.onCancelled, super.key});

  final EncryptedAttachmentDescriptor? descriptor;
  final VoidCallback? onCancelled;

  /// Whether a picker is wired behind the compose choices.
  ///
  /// No composition root installs an attachment picker or transfer service, so
  /// in the running app this is false and the sheet says attachments are not
  /// built instead of offering three options that do nothing when tapped
  /// (ADR-045).
  bool get _pickerAvailable => onCancelled != null;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    final composing = descriptor == null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              composing ? strings.chatAttachAction : descriptor!.displayName,
              style: context.tokens.typography.title,
            ),
            const SizedBox(height: AppSpacing.x1),
            Text(
              switch ((composing, _pickerAvailable)) {
                (true, true) => strings.attachmentChoosePrompt,
                (true, false) => strings.attachmentsNotBuiltNotice,
                (false, _) => strings.attachmentDetails(
                  descriptor!.mimeType,
                  descriptor!.plaintextSize,
                ),
              },
              style: context.tokens.typography.compact.copyWith(
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.x2),
            if (composing && !_pickerAvailable)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: AppStatusBadge(
                  kind: AppStatusKind.warning,
                  label: SurfaceMaturity.notBuilt.label(strings),
                ),
              )
            else if (composing) ...[
              _AttachmentChoice(
                icon: AppIcons.attach,
                label: strings.attachmentPhotoOption,
                onPressed: onCancelled,
              ),
              _AttachmentChoice(
                icon: AppIcons.attach,
                label: strings.attachmentFileOption,
                onPressed: onCancelled,
              ),
              _AttachmentChoice(
                icon: AppIcons.attach,
                label: strings.attachmentCameraOption,
                onPressed: onCancelled,
              ),
            ] else
              AppButton(
                label: strings.chatAttachmentsUnavailable,
                kind: AppButtonKind.outline,
                onPressed: onCancelled,
              ),
            const SizedBox(height: AppSpacing.x1),
            AppButton(
              label: strings.chatCancelAction,
              kind: AppButtonKind.ghost,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

final class _AttachmentChoice extends StatelessWidget {
  const _AttachmentChoice({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final AppIconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    // The tile's own tap action goes with `excludeSemantics`, so the node
    // carries it.
    onTap: onPressed,
    excludeSemantics: true,
    child: ListTile(
      leading: AppIcon(icon, decorative: true),
      title: Text(label),
      onTap: onPressed,
    ),
  );
}
