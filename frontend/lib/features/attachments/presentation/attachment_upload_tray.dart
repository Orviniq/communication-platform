import 'dart:math' as math;

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_upload_model.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_formatting.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// One upload job, as the tray draws it (ADR-089 D5).
@immutable
final class AttachmentUploadRowViewModel {
  const AttachmentUploadRowViewModel({
    required this.id,
    required this.name,
    required this.picture,
    required this.state,
    required this.percent,
    this.failure,
    this.resetsAt,
  });

  factory AttachmentUploadRowViewModel.of(AttachmentUploadJob job) =>
      AttachmentUploadRowViewModel(
        id: job.id,
        name: attachmentDescriptorName(job.attachment.displayName),
        picture: job.attachment.mediaKind == AttachmentMediaKind.image,
        state: job.state,
        percent: switch (job.state) {
          AttachmentUploadState.encrypting ||
          AttachmentUploadState.uploading => (job.progress * 100).floor(),
          AttachmentUploadState.sending => 100,
          AttachmentUploadState.waiting || AttachmentUploadState.failed => 0,
        },
        failure: job.failure,
        resetsAt: job.resetsAt,
      );

  final String id;
  final String name;
  final bool picture;
  final AttachmentUploadState state;

  /// From 0 to 100.
  final int percent;
  final AttachmentUploadFailureKind? failure;

  /// The turn of the UTC day an allowance failure waits for.
  final DateTime? resetsAt;

  bool get failed => state == AttachmentUploadState.failed;

  /// Cancel acts until the message is being committed.
  bool get canCancel =>
      state != AttachmentUploadState.sending &&
      state != AttachmentUploadState.failed;

  /// Retry is offered for every failure but a size the server never takes.
  bool get canRetry =>
      failed && failure != AttachmentUploadFailureKind.tooLarge;

  @override
  String toString() => 'AttachmentUploadRowViewModel(${state.name})';
}

/// The rows of [jobs], the oldest first.
List<AttachmentUploadRowViewModel> attachmentUploadRows(
  List<AttachmentUploadJob> jobs,
) => List.unmodifiable(jobs.map(AttachmentUploadRowViewModel.of));

/// What a row of the tray asks for.
sealed class AttachmentUploadIntent {
  const AttachmentUploadIntent(this.id);

  /// The job's id.
  final String id;
}

final class CancelAttachmentUploadIntent extends AttachmentUploadIntent {
  const CancelAttachmentUploadIntent(super.id);
}

final class RetryAttachmentUploadIntent extends AttachmentUploadIntent {
  const RetryAttachmentUploadIntent(super.id);
}

final class DiscardAttachmentUploadIntent extends AttachmentUploadIntent {
  const DiscardAttachmentUploadIntent(super.id);
}

/// The uploads of a conversation, between its timeline and its composer
/// (ADR-089 D5).
///
/// It draws [rows] and sends [onIntent] for each action, and reads nothing
/// else. A row's state is a live region whose text changes with the state
/// and the failure and not with the percent, so a screen reader hears each
/// change once; the progress bar carries the percent.
final class AttachmentUploadTray extends StatelessWidget {
  const AttachmentUploadTray({
    required this.rows,
    required this.onIntent,
    super.key,
  });

  final List<AttachmentUploadRowViewModel> rows;
  final ValueChanged<AttachmentUploadIntent> onIntent;

  /// The most of the screen's height the tray takes; more rows scroll.
  static const heightShare = 0.3;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = context.tokens.colors;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: AppLocalizations.of(context).attachmentUploadsLabel,
      child: Material(
        key: const ValueKey('attachment-upload-tray'),
        color: colors.surface,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(
                AppFocus.minimumTarget * 2,
                MediaQuery.sizeOf(context).height * heightShare,
              ),
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
              children: [
                for (final row in rows)
                  _UploadRow(
                    key: ValueKey('attachment-upload-${row.id}'),
                    row: row,
                    onIntent: onIntent,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.row, required this.onIntent, super.key});

  final AttachmentUploadRowViewModel row;
  final ValueChanged<AttachmentUploadIntent> onIntent;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final tokens = context.tokens;
    final state = _stateText(context, strings);
    final shown = switch (row.state) {
      AttachmentUploadState.encrypting || AttachmentUploadState.uploading =>
        strings.attachmentUploadProgress(state, row.percent),
      _ => state,
    };
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.x3,
        end: AppSpacing.x1,
        top: AppSpacing.x1,
        bottom: AppSpacing.x1,
      ),
      child: Row(
        children: [
          AppIcon(row.picture ? AppIcons.photo : AppIcons.file),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.typography.body,
                  ),
                ),
                Semantics(
                  key: ValueKey('attachment-upload-state-${row.id}'),
                  // Its own node, or its text would merge into the row's
                  // and change with the percent of the bar beside it.
                  container: true,
                  liveRegion: true,
                  label: strings.attachmentUploadAnnouncement(row.name, state),
                  child: ExcludeSemantics(
                    child: Text(
                      shown,
                      style: tokens.typography.compact.copyWith(
                        color: row.failed
                            ? tokens.colors.danger
                            : tokens.colors.textMuted,
                      ),
                    ),
                  ),
                ),
                if (!row.failed)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.x1),
                    child: LinearProgressIndicator(
                      value: row.percent / 100,
                      semanticsLabel: row.name,
                      semanticsValue: '${row.percent}%',
                    ),
                  ),
              ],
            ),
          ),
          if (row.failed) ...[
            if (row.canRetry)
              AppIconButton(
                icon: AppIcons.retry,
                semanticLabel: strings.attachmentUploadRetryAction,
                kind: AppButtonKind.ghost,
                onPressed: () => onIntent(RetryAttachmentUploadIntent(row.id)),
              ),
            AppIconButton(
              icon: AppIcons.delete,
              semanticLabel: strings.attachmentUploadDiscardAction,
              kind: AppButtonKind.ghost,
              onPressed: () => onIntent(DiscardAttachmentUploadIntent(row.id)),
            ),
          ] else
            AppIconButton(
              icon: AppIcons.close,
              semanticLabel: strings.attachmentUploadCancelAction,
              kind: AppButtonKind.ghost,
              // Once the message is being committed a cancel has nothing
              // left to stop.
              onPressed: row.canCancel
                  ? () => onIntent(CancelAttachmentUploadIntent(row.id))
                  : null,
            ),
        ],
      ),
    );
  }

  /// The state in words: what the live region says.
  String _stateText(
    BuildContext context,
    AppLocalizations strings,
  ) => switch (row.state) {
    AttachmentUploadState.waiting => strings.attachmentUploadWaiting,
    AttachmentUploadState.encrypting => strings.attachmentUploadEncrypting,
    AttachmentUploadState.uploading => strings.attachmentUploadUploading,
    AttachmentUploadState.sending => strings.attachmentUploadSending,
    AttachmentUploadState.failed => switch (row.failure) {
      AttachmentUploadFailureKind.allowanceSpent when row.resetsAt != null =>
        strings.attachmentUploadAllowanceSpent(
          formatAttachmentTime(context, row.resetsAt!),
        ),
      AttachmentUploadFailureKind.tooLarge => strings.attachmentUploadTooLarge,
      AttachmentUploadFailureKind.storageFull =>
        strings.attachmentUploadStorageFull,
      AttachmentUploadFailureKind.throttled =>
        strings.attachmentUploadThrottled,
      AttachmentUploadFailureKind.offline => strings.attachmentUploadOffline,
      // The queue always gives an allowance failure its turn of the day.
      AttachmentUploadFailureKind.allowanceSpent ||
      AttachmentUploadFailureKind.failed ||
      null => strings.attachmentUploadFailed,
    },
  };
}
