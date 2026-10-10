import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_text_direction.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_pick_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_formatting.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the preview step shows of one picked file (ADR-089 D5, D6).
@immutable
final class AttachmentPreviewViewModel {
  const AttachmentPreviewViewModel({
    required this.name,
    required this.picture,
    required this.file,
    required this.fileBytes,
    required this.uploadBytes,
    required this.remainingBytes,
    required this.resetsAt,
    required this.taken,
    required this.overRemainder,
    required this.fixedMetadataBytes,
  });

  factory AttachmentPreviewViewModel.of(
    PickedAttachment attachment,
    AttachmentUploadQuote quote,
  ) => AttachmentPreviewViewModel(
    name: attachmentDescriptorName(attachment.displayName),
    picture: attachment.mediaKind == AttachmentMediaKind.image,
    file: attachment.file,
    fileBytes: quote.fileBytes,
    uploadBytes: quote.uploadBytes,
    remainingBytes: quote.remainingBytes,
    resetsAt: quote.resetsAt,
    taken: quote.uploadBytes != null && quote.published,
    overRemainder: quote.overRemainder,
    fixedMetadataBytes: attachmentMetadataBytes(attachment, null),
  );

  /// The name the message carries.
  final String name;

  /// Whether the file is a picture this device re-encoded, shown as one.
  final bool picture;

  /// The outgoing copy, which the preview reads and never writes.
  final File file;
  final int fileBytes;

  /// The bucket, or null when no bucket holds the file.
  final int? uploadBytes;
  final int remainingBytes;

  /// The turn of the server's UTC day.
  final DateTime resetsAt;

  /// Whether the deployment takes an upload of this size.
  final bool taken;

  /// Whether the upload is larger than what is left of today.
  final bool overRemainder;

  /// The metadata's bytes with no caption: the caption's own bytes are added
  /// to it, because the caption comes last.
  final int fixedMetadataBytes;

  int metadataBytes(String? caption) =>
      fixedMetadataBytes + utf8.encode(caption ?? '').length;

  bool get sendable => taken && !overRemainder;

  @override
  String toString() => 'AttachmentPreviewViewModel(<redacted>)';
}

/// The preview step: the picture or the file, its sizes, today's remainder
/// and a caption (ADR-089 D5).
///
/// Opened through `showAppSheet`, which keeps it above the keyboard and the
/// gesture bar. Send closes it with the caption typed as its result; Cancel,
/// the barrier and Back close it with none, and the caller deletes the copy.
final class AttachmentPreviewSheet extends StatefulWidget {
  const AttachmentPreviewSheet({required this.model, super.key});

  final AttachmentPreviewViewModel model;

  /// The widest a preview is decoded, in device pixels.
  static const maximumDecodeWidth = 1024;

  /// The tallest the preview is drawn, in logical pixels.
  static const previewHeight = 200.0;

  @override
  State<AttachmentPreviewSheet> createState() => _AttachmentPreviewSheetState();
}

class _AttachmentPreviewSheetState extends State<AttachmentPreviewSheet> {
  final _caption = TextEditingController();

  @override
  void initState() {
    super.initState();
    _caption.addListener(_changed);
  }

  @override
  void dispose() {
    _caption
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final tokens = context.tokens;
    final model = widget.model;
    final caption = attachmentCaptionOf(_caption.text);
    final characters = attachmentCaptionCharacters(caption ?? '');
    final bytes = model.metadataBytes(caption);
    const characterLimit = AttachmentCaptionLimits.maximumCharacters;
    const byteLimit = AttachmentCaptionLimits.maximumMetadataBytes;
    final tooLong = bytes > byteLimit;
    final uploadBytes = model.uploadBytes;
    final muted = tokens.typography.compact.copyWith(
      color: tokens.colors.textMuted,
    );
    final warning = tokens.typography.compact.copyWith(
      color: tokens.colors.danger,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(strings.attachmentPreviewTitle, style: tokens.typography.title),
        const SizedBox(height: AppSpacing.x3),
        if (model.picture) ...[
          _PicturePreview(file: model.file),
          const SizedBox(height: AppSpacing.x2),
        ],
        Row(
          children: [
            AppIcon(model.picture ? AppIcons.photo : AppIcons.file),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: Text(
                model.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: tokens.typography.body,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x2),
        Text(
          strings.attachmentPreviewFileSize(
            formatAttachmentSize(strings, model.fileBytes),
          ),
          style: muted,
        ),
        if (uploadBytes != null)
          Text(
            strings.attachmentPreviewUploadSize(
              formatAttachmentSize(strings, uploadBytes),
            ),
            style: muted,
          ),
        Text(
          strings.attachmentPreviewRemaining(
            formatAttachmentSize(strings, model.remainingBytes),
          ),
          style: muted,
        ),
        if (!model.taken)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.x2),
            child: Text(strings.attachmentPreviewNotTaken, style: warning),
          )
        else if (model.overRemainder)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.x2),
            child: Text(
              strings.attachmentPreviewOverRemainder(
                formatAttachmentSize(strings, uploadBytes!),
                formatAttachmentSize(strings, model.remainingBytes),
                formatAttachmentTime(context, model.resetsAt),
              ),
              style: warning,
            ),
          ),
        const SizedBox(height: AppSpacing.x3),
        TextField(
          key: const ValueKey('attachment-caption-field'),
          controller: _caption,
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          // A caption reads in the direction its own first strong character
          // sets, as a message does.
          textDirection:
              resolveFirstStrongDirection(_caption.text) ??
              Directionality.of(context),
          inputFormatters: const [_ScalarLimit(characterLimit)],
          decoration: InputDecoration(
            labelText: strings.attachmentCaptionLabel,
            hintText: strings.attachmentCaptionHint,
          ),
        ),
        // A counter for each limit, once the caption is near it.
        if (characters >=
            (characterLimit * AttachmentCaptionLimits.counterFrom))
          _Counter(
            text: strings.attachmentCaptionCharacters(
              characters,
              characterLimit,
            ),
          ),
        if (bytes >= (byteLimit * AttachmentCaptionLimits.counterFrom))
          _Counter(text: strings.attachmentCaptionBytes(bytes, byteLimit)),
        if (tooLong)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x1),
              child: Text(
                strings.attachmentCaptionTooLong(byteLimit),
                style: warning,
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.x3),
        AppButton(
          key: const ValueKey('attachment-preview-send'),
          label: strings.attachmentSendAction,
          leading: AppIcons.send,
          onPressed: model.sendable && !tooLong
              ? () => popAppModal(context, _caption.text)
              : null,
        ),
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

/// The picture, decoded no wider than the sheet in device pixels and never
/// wider than [AttachmentPreviewSheet.maximumDecodeWidth].
class _PicturePreview extends StatelessWidget {
  const _PicturePreview({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cacheWidth = math.max(
          1,
          math.min(
            (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                .floor(),
            AttachmentPreviewSheet.maximumDecodeWidth,
          ),
        );
        return Semantics(
          image: true,
          label: strings.attachmentPreviewImageLabel,
          child: ExcludeSemantics(
            child: SizedBox(
              height: AttachmentPreviewSheet.previewHeight,
              child: Image.file(
                file,
                key: const ValueKey('attachment-preview-image'),
                cacheWidth: cacheWidth,
                fit: BoxFit.contain,
                errorBuilder: (context, _, _) =>
                    const Center(child: AppIcon(AppIcons.photo, size: 48)),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.x1),
    child: Text(
      text,
      textAlign: TextAlign.end,
      style: context.tokens.typography.label,
    ),
  );
}

/// Keeps a caption to [limit] Unicode scalar values, the unit the protocol
/// counts text in. A paste past the limit is cut to it.
final class _ScalarLimit extends TextInputFormatter {
  const _ScalarLimit(this.limit);

  final int limit;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final runes = newValue.text.runes;
    if (runes.length <= limit) {
      return newValue;
    }
    final kept = String.fromCharCodes(runes.take(limit));
    return TextEditingValue(
      text: kept,
      selection: TextSelection.collapsed(offset: kept.length),
    );
  }
}
