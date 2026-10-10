import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// What the attachment sheet is for (ADR-089 D1).
enum AttachmentSheetMode {
  /// Photo, File and Camera: a direct chat and Saved Messages.
  choose,

  /// The "not built" notice and its badge: a group chat, which sends no
  /// attachment in this phase.
  notBuilt,

  /// A received descriptor's name and details.
  details,
}

/// The sheet the paperclip opens, and the one a received attachment opens.
///
/// It is opened through `showAppSheet`. In [AttachmentSheetMode.choose] a
/// choice closes the sheet with the [AttachmentPickKind] chosen as its result,
/// and Cancel closes it with none.
final class AttachmentSheet extends StatelessWidget {
  const AttachmentSheet.choose({super.key})
    : mode = AttachmentSheetMode.choose,
      descriptor = null;

  const AttachmentSheet.notBuilt({super.key})
    : mode = AttachmentSheetMode.notBuilt,
      descriptor = null;

  const AttachmentSheet.details({
    required EncryptedAttachmentDescriptor this.descriptor,
    super.key,
  }) : mode = AttachmentSheetMode.details;

  final AttachmentSheetMode mode;
  final EncryptedAttachmentDescriptor? descriptor;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    final descriptor = this.descriptor;
    // The margin and the system insets are the sheet's (`showAppSheet`).
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          descriptor?.displayName ?? strings.chatAttachAction,
          style: context.tokens.typography.title,
        ),
        const SizedBox(height: AppSpacing.x1),
        Text(
          switch (mode) {
            AttachmentSheetMode.choose => strings.attachmentChoosePrompt,
            AttachmentSheetMode.notBuilt => strings.attachmentsNotBuiltNotice,
            AttachmentSheetMode.details => strings.attachmentDetails(
              descriptor!.mimeType,
              descriptor.plaintextSize,
            ),
          },
          style: context.tokens.typography.compact.copyWith(
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: AppSpacing.x2),
        ...switch (mode) {
          AttachmentSheetMode.choose => [
            for (final (kind, icon, label) in [
              (
                AttachmentPickKind.photo,
                AppIcons.photo,
                strings.attachmentPhotoOption,
              ),
              (
                AttachmentPickKind.file,
                AppIcons.file,
                strings.attachmentFileOption,
              ),
              (
                AttachmentPickKind.camera,
                AppIcons.camera,
                strings.attachmentCameraOption,
              ),
            ])
              _AttachmentChoice(
                icon: icon,
                label: label,
                onPressed: () => popAppModal(context, kind),
              ),
          ],
          AttachmentSheetMode.notBuilt => [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppStatusBadge(
                kind: AppStatusKind.warning,
                label: SurfaceMaturity.notBuilt.label(strings),
              ),
            ),
          ],
          // Prompt 4 of the phase adds Open, Save and Share.
          AttachmentSheetMode.details => [
            AppButton(
              label: strings.chatAttachmentsUnavailable,
              kind: AppButtonKind.outline,
              onPressed: null,
            ),
          ],
        },
        const SizedBox(height: AppSpacing.x1),
        AppButton(
          label: strings.chatCancelAction,
          kind: AppButtonKind.ghost,
          onPressed: () => popAppModal(context),
        ),
      ],
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
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    // The tile's own tap action goes with `excludeSemantics`, so the node
    // carries it.
    onTap: onPressed,
    excludeSemantics: true,
    child: ListTile(
      minTileHeight: AppFocus.minimumTarget,
      leading: AppIcon(icon, decorative: true),
      title: Text(label),
      onTap: onPressed,
    ),
  );
}
