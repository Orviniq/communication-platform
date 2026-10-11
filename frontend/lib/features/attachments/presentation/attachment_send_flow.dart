import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/application/attachment_uploads.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_formatting.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_preview_sheet.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_sheet.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// Sends one attachment from a direct chat or Saved Messages (ADR-089 D5):
/// the choice, the pick, the preview step, then an upload job in [uploads].
///
/// The choice closes its sheet before the picker opens. A cancelled pick
/// says nothing, and a failed one says why in a snack bar. Cancelling the
/// preview step deletes the copy the pick made. Send adds the job and returns
/// at once: the tray above the composer follows it from there.
///
/// It reads no provider: the page hands it [session], which answers the
/// session's queue, or null when there is none to be had. It is asked only
/// once a choice is made, so the sheet opens at once.
Future<void> runAttachmentSendFlow({
  required BuildContext context,
  required Future<AttachmentUploads?> Function() session,
  required String conversationId,
  required AttachmentUploadTarget target,
}) async {
  final strings = AppLocalizations.of(context);
  final kind = await showAppSheet<AttachmentPickKind>(
    context: context,
    semanticLabel: strings.chatAttachAction,
    child: const AttachmentSheet.choose(),
  );
  if (kind == null || !context.mounted) {
    return;
  }
  final uploads = await session();
  if (!context.mounted) {
    return;
  }
  if (uploads == null) {
    _tell(context, strings.chatActionFailedMessage);
    return;
  }
  final picked = await uploads.pick(kind);
  final PickedAttachment attachment;
  switch (picked) {
    case FailureResult(:final failure):
      final message = attachmentPickFailureMessage(
        strings,
        failure,
        limitBytes: uploads.pickLimit(),
      );
      if (message != null && context.mounted) {
        _tell(context, message);
      }
      return;
    case Success(:final value):
      attachment = value;
  }
  final quote = await uploads.quote(attachment);
  if (!context.mounted) {
    await uploads.discardPreview(attachment);
    return;
  }
  final caption = await showAppSheet<String>(
    context: context,
    semanticLabel: strings.attachmentPreviewTitle,
    child: AttachmentPreviewSheet(
      model: AttachmentPreviewViewModel.of(attachment, quote),
    ),
  );
  if (caption == null) {
    await uploads.discardPreview(attachment);
    return;
  }
  final queued = uploads.enqueue(
    conversationId: conversationId,
    target: target,
    attachment: attachment,
    caption: caption,
  );
  if (queued case FailureResult()) {
    await uploads.discardPreview(attachment);
    if (context.mounted) {
      _tell(context, strings.attachmentEnqueueFailed);
    }
  }
}

void _tell(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));
