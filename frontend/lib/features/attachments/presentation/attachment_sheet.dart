import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/application/attachment_file_actions.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_formatting.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// What the attachment sheet is for (ADR-089 D1).
enum AttachmentSheetMode {
  /// Photo, File and Camera: a direct chat and Saved Messages.
  choose,

  /// The "not built" notice and its badge: a group chat, which sends no
  /// attachment in this phase.
  notBuilt,

  /// A ready attachment's name and details, with Open, Save and Share.
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
      descriptor = null,
      retentionDays = null,
      actions = null;

  const AttachmentSheet.notBuilt({super.key})
    : mode = AttachmentSheetMode.notBuilt,
      descriptor = null,
      retentionDays = null,
      actions = null;

  /// [retentionDays] is how long the server keeps an attachment after it was
  /// sent (`attachment_ttl_days`), and [actions] hands the cached file to the
  /// platform.
  const AttachmentSheet.details({
    required EncryptedAttachmentDescriptor this.descriptor,
    required int this.retentionDays,
    required AttachmentFileActions this.actions,
    super.key,
  }) : mode = AttachmentSheetMode.details;

  final AttachmentSheetMode mode;
  final EncryptedAttachmentDescriptor? descriptor;
  final int? retentionDays;
  final AttachmentFileActions? actions;

  @override
  Widget build(BuildContext context) {
    if (mode == AttachmentSheetMode.details) {
      return _AttachmentDetails(
        descriptor: descriptor!,
        retentionDays: retentionDays!,
        actions: actions!,
      );
    }
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    // The margin and the system insets are the sheet's (`showAppSheet`).
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(strings.chatAttachAction, style: context.tokens.typography.title),
        const SizedBox(height: AppSpacing.x1),
        Text(
          mode == AttachmentSheetMode.notBuilt
              ? strings.attachmentsNotBuiltNotice
              : strings.attachmentChoosePrompt,
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
          AttachmentSheetMode.details => const <Widget>[],
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

/// The details of a ready attachment: its name, type and size, how long the
/// server keeps it, and Open, Save and Share (ADR-089 D7).
///
/// Each action asks the cache for the file first, which moves its expiry. A
/// failure stays on the sheet, in a live region, until the next action.
final class _AttachmentDetails extends StatefulWidget {
  const _AttachmentDetails({
    required this.descriptor,
    required this.retentionDays,
    required this.actions,
  });

  final EncryptedAttachmentDescriptor descriptor;
  final int retentionDays;
  final AttachmentFileActions actions;

  @override
  State<_AttachmentDetails> createState() => _AttachmentDetailsState();
}

class _AttachmentDetailsState extends State<_AttachmentDetails> {
  /// The last action's outcome, or null before the first.
  AttachmentFileOutcome? _outcome;

  /// Whether an action is with the platform: the others wait for it.
  var _busy = false;

  Future<void> _run(
    Future<AttachmentFileOutcome> Function(EncryptedAttachmentDescriptor) act,
  ) async {
    setState(() {
      _busy = true;
      _outcome = null;
    });
    final outcome = await act(widget.descriptor);
    if (mounted) {
      setState(() {
        _busy = false;
        _outcome = outcome;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final tokens = context.tokens;
    final descriptor = widget.descriptor;
    final problem = switch (_outcome) {
      AttachmentFileOutcome.noApp => strings.attachmentOpenNoApp,
      AttachmentFileOutcome.saveFailed => strings.attachmentSaveFailed,
      AttachmentFileOutcome.missing => strings.attachmentFileMissing,
      AttachmentFileOutcome.failed => strings.attachmentActionFailed,
      AttachmentFileOutcome.done ||
      AttachmentFileOutcome.cancelled ||
      null => null,
    };
    final actions = widget.actions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(descriptor.displayName, style: tokens.typography.title),
        const SizedBox(height: AppSpacing.x1),
        Text(
          strings.attachmentDetailsLine(
            descriptor.mimeType,
            formatAttachmentSize(strings, descriptor.plaintextSize),
          ),
          style: tokens.typography.compact.copyWith(
            color: tokens.colors.textMuted,
          ),
        ),
        const SizedBox(height: AppSpacing.x1),
        Text(
          strings.attachmentServerRetention(widget.retentionDays),
          style: tokens.typography.compact.copyWith(
            color: tokens.colors.textMuted,
          ),
        ),
        const SizedBox(height: AppSpacing.x2),
        for (final (icon, label, act) in [
          (AppIcons.openFile, strings.attachmentOpenAction, actions.open),
          (AppIcons.saveFile, strings.attachmentSaveAction, actions.save),
          (AppIcons.share, strings.attachmentShareAction, actions.share),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.x1),
            child: AppButton(
              label: label,
              leading: icon,
              kind: AppButtonKind.outline,
              onPressed: _busy ? null : () => _run(act),
            ),
          ),
        Semantics(
          container: true,
          liveRegion: true,
          child: problem == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
                  child: Text(
                    problem,
                    style: tokens.typography.compact.copyWith(
                      color: tokens.colors.danger,
                    ),
                  ),
                ),
        ),
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
