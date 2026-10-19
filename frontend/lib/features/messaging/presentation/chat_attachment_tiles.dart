import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/attachments/domain/attachment_download_model.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_formatting.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// What one attachment tile shows (ADR-089 D7, D9).
///
/// A presentation value, read from three things: the state the database keeps,
/// what the cache holds, and the download job in memory. It is not an
/// `AttachmentTransferState`: that one's index is what the database stores,
/// and its CHECK allows nothing past 8.
enum ChatAttachmentTileState {
  notDownloaded,
  waiting,
  downloading,
  verifying,
  ready,
  expired,
  damaged,
  failed,
}

/// The tile state of an attachment whose row keeps [persisted], whose file
/// the cache was last found to hold ([cached] true), not to hold (false), or
/// was not asked about (null), and whose download job is in [job], or has
/// none.
///
/// A job is the newest thing known, so it decides while it exists. Without
/// one, the row decides: `expired` is expired, and `ready` is ready unless the
/// cache was found not to hold the file, which makes it "not downloaded" again
/// (D8). Every other value, the ones the client never writes included, is
/// "not downloaded".
ChatAttachmentTileState chatAttachmentTileState({
  required AttachmentTransferState persisted,
  required bool? cached,
  required AttachmentDownloadState? job,
}) => switch (job) {
  AttachmentDownloadState.waiting => ChatAttachmentTileState.waiting,
  AttachmentDownloadState.downloading => ChatAttachmentTileState.downloading,
  AttachmentDownloadState.verifying => ChatAttachmentTileState.verifying,
  AttachmentDownloadState.damaged => ChatAttachmentTileState.damaged,
  AttachmentDownloadState.failed => ChatAttachmentTileState.failed,
  null => switch (persisted) {
    AttachmentTransferState.expired => ChatAttachmentTileState.expired,
    AttachmentTransferState.ready when cached != false =>
      ChatAttachmentTileState.ready,
    _ => ChatAttachmentTileState.notDownloaded,
  },
};

/// What the timeline's attachment tiles read beside their messages: the
/// session's download jobs and the files of ready pictures.
///
/// Read-only. A tile changes nothing through it; what a tap asks for leaves
/// as a [ChatIntent].
abstract interface class ChatAttachmentTransfers {
  /// The job of [attachmentId] now, or null.
  AttachmentDownloadJob? jobOf(String attachmentId);

  /// The job of [attachmentId]: each time it changes, and null once it has
  /// none. Tells one attachment nothing of another's change.
  Stream<AttachmentDownloadJob?> watch(String attachmentId);

  /// The decrypted file of the ready picture [attachmentId], or null when the
  /// cache does not hold one. A look, not an open: it moves no expiry.
  Future<File?> picture(String attachmentId);
}

/// The attachment context of one conversation's timeline.
///
/// Provided above the timeline of a direct chat and of Saved Messages. A
/// timeline without one draws each tile from its row alone, as a group
/// chat's would.
final class ChatAttachmentScope extends InheritedWidget {
  const ChatAttachmentScope({
    required this.transfers,
    required this.retentionDays,
    required super.child,
    super.key,
  });

  final ChatAttachmentTransfers transfers;

  /// How many days the server keeps an attachment after it was sent.
  final int retentionDays;

  static ChatAttachmentScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatAttachmentScope>();

  @override
  bool updateShouldNotify(ChatAttachmentScope oldWidget) =>
      !identical(transfers, oldWidget.transfers) ||
      retentionDays != oldWidget.retentionDays;
}

/// Whether [attachment] is a video: a `file` with a video type the sanitiser
/// keeps (ADR-097 V3, V4). Such a tile draws a video icon and nothing more:
/// no thumbnail, and Open hands the file to the system player.
bool isChatVideoAttachment(EncryptedAttachmentDescriptor attachment) =>
    attachment.mediaKind == AttachmentMediaKind.file &&
    attachment.mimeType.startsWith('video/');

/// The widest a tile is, and the largest a picture is drawn, in logical
/// pixels.
const chatAttachmentTileMaxWidth = 260.0;
const chatAttachmentPictureMaxHeight = 320.0;

/// The widest a picture is decoded, in device pixels.
const chatAttachmentDecodeMaxWidth = 1024;

/// One attachment of a message: its kind, name, size and state, and for a
/// ready inline picture the picture itself.
///
/// It listens to its own download job, so a percent that moves redraws this
/// tile and not the bubble around it (ADR-064). One semantic node, whose
/// label holds the kind, the name, the size and the state, and whose hint
/// names what a tap does.
class ChatAttachmentTile extends StatefulWidget {
  const ChatAttachmentTile({
    required this.messageId,
    required this.attachment,
    required this.persisted,
    required this.onIntent,
    super.key,
  });

  final String messageId;
  final EncryptedAttachmentDescriptor attachment;
  final AttachmentTransferState persisted;
  final ChatIntentCallback onIntent;

  @override
  State<ChatAttachmentTile> createState() => _ChatAttachmentTileState();
}

class _ChatAttachmentTileState extends State<ChatAttachmentTile> {
  ChatAttachmentTransfers? _transfers;
  StreamSubscription<AttachmentDownloadJob?>? _subscription;
  AttachmentDownloadJob? _job;

  /// The ready picture's file, and whether the last look found one.
  File? _picture;
  bool? _cached;

  /// Which look an answer belongs to: a later look makes an earlier answer
  /// stale.
  var _look = 0;

  String get _id => widget.attachment.capabilityId;

  bool get _inlinePicture => widget.attachment.isInlineImage;

  bool get _video => isChatVideoAttachment(widget.attachment);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final transfers = ChatAttachmentScope.maybeOf(context)?.transfers;
    if (!identical(transfers, _transfers)) {
      _transfers = transfers;
      _follow();
      _lookAgain();
    }
  }

  @override
  void didUpdateWidget(ChatAttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.capabilityId != _id) {
      _follow();
      _lookAgain();
    } else if (oldWidget.persisted != widget.persisted) {
      _lookAgain();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _follow() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    final transfers = _transfers;
    _job = transfers?.jobOf(_id);
    if (transfers == null) {
      return;
    }
    _subscription = transfers.watch(_id).listen((job) {
      if (mounted && !identical(job, _job)) {
        setState(() => _job = job);
      }
    });
  }

  /// Asks the cache for a ready picture's file. Only a picture is asked
  /// about: a file's tile needs nothing from the cache until it is opened,
  /// and the open answers for itself.
  void _lookAgain() {
    final look = ++_look;
    _picture = null;
    _cached = null;
    final transfers = _transfers;
    if (transfers == null ||
        !_inlinePicture ||
        widget.persisted != AttachmentTransferState.ready) {
      return;
    }
    unawaited(
      transfers.picture(_id).then((file) {
        if (mounted && look == _look) {
          setState(() {
            _picture = file;
            _cached = file != null;
          });
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final state = chatAttachmentTileState(
      persisted: widget.persisted,
      cached: _cached,
      job: _job?.state,
    );
    final attachment = widget.attachment;
    final action = switch (state) {
      ChatAttachmentTileState.notDownloaded => DownloadAttachmentIntent(
        messageId: widget.messageId,
        attachment: attachment,
      ),
      ChatAttachmentTileState.failed => RetryAttachmentDownloadIntent(
        attachment,
      ),
      ChatAttachmentTileState.waiting ||
      ChatAttachmentTileState.downloading ||
      ChatAttachmentTileState.verifying => CancelAttachmentDownloadIntent(
        attachment,
      ),
      ChatAttachmentTileState.ready => OpenAttachmentIntent(
        attachment: attachment,
      ),
      ChatAttachmentTileState.expired ||
      ChatAttachmentTileState.damaged => null,
    };
    final hint = switch (state) {
      ChatAttachmentTileState.notDownloaded => strings.attachmentDownloadHint,
      ChatAttachmentTileState.failed => strings.attachmentRetryDownloadHint,
      ChatAttachmentTileState.waiting ||
      ChatAttachmentTileState.downloading ||
      ChatAttachmentTileState.verifying => strings.attachmentCancelDownloadHint,
      ChatAttachmentTileState.ready => strings.attachmentDetailsHint,
      ChatAttachmentTileState.expired ||
      ChatAttachmentTileState.damaged => null,
    };
    final percent = ((_job?.progress ?? 0) * 100).floor();
    final stateText = switch (state) {
      ChatAttachmentTileState.notDownloaded => strings.attachmentNotDownloaded,
      ChatAttachmentTileState.waiting => strings.attachmentDownloadWaiting,
      ChatAttachmentTileState.downloading => strings.attachmentDownloading(
        percent,
      ),
      ChatAttachmentTileState.verifying => strings.attachmentVerifying(percent),
      ChatAttachmentTileState.ready => strings.attachmentReady,
      ChatAttachmentTileState.expired => strings.attachmentExpired,
      ChatAttachmentTileState.damaged => strings.attachmentDamaged,
      ChatAttachmentTileState.failed => strings.attachmentDownloadFailed,
    };
    final kind = _inlinePicture
        ? strings.attachmentImageLabel
        : _video
        ? strings.attachmentVideoLabel
        : strings.attachmentFileLabel;
    final size = formatAttachmentSize(strings, attachment.plaintextSize);
    final onTap = action == null ? null : () => widget.onIntent(action);
    return Semantics(
      container: true,
      button: onTap != null,
      label: strings.attachmentTileSemantics(
        kind,
        attachment.displayName,
        size,
        stateText,
      ),
      hint: hint,
      // The ink well's own tap goes with `excludeSemantics`, so the node
      // carries it.
      onTap: onTap,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final picture = _inlinePicture
              ? chatAttachmentPictureSize(
                  width: attachment.width,
                  height: attachment.height,
                  maxWidth: constraints.maxWidth,
                )
              : null;
          final width =
              picture?.width ??
              math.min(chatAttachmentTileMaxWidth, constraints.maxWidth);
          final details = _Details(
            picture: _inlinePicture,
            video: _video,
            name: attachment.displayName,
            size: size,
            stateText: stateText,
            state: state,
            progress: _job?.progress ?? 0,
          );
          return _Frame(
            width: width,
            // A tile with nothing to do takes the tap, so that it does
            // nothing rather than open the message's menu.
            onTap: onTap ?? () {},
            ink: onTap != null,
            child: _inlinePicture
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _PictureBox(
                        size: picture!,
                        file: state == ChatAttachmentTileState.ready
                            ? _picture
                            : null,
                      ),
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.x2),
                        child: details,
                      ),
                    ],
                  )
                : Padding(
                    padding: const EdgeInsets.all(AppSpacing.x2),
                    child: details,
                  ),
          );
        },
      ),
    );
  }
}

/// The tile's box: its border, its width, at least one touch target high,
/// and the tap.
class _Frame extends StatelessWidget {
  const _Frame({
    required this.width,
    required this.onTap,
    required this.ink,
    required this.child,
  });

  final double width;
  final VoidCallback onTap;
  final bool ink;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    final box = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: width,
        maxWidth: width,
        minHeight: AppFocus.minimumTarget,
      ),
      child: child,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x1),
      child: Material(
        color: colors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.control,
          side: BorderSide(color: colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: ink
            ? InkWell(onTap: onTap, child: box)
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: box,
              ),
      ),
    );
  }
}

/// The kind's icon, the name, the size and the state, and a bar while the
/// download runs.
class _Details extends StatelessWidget {
  const _Details({
    required this.picture,
    required this.video,
    required this.name,
    required this.size,
    required this.stateText,
    required this.state,
    required this.progress,
  });

  final bool picture;
  final bool video;
  final String name;
  final String size;
  final String stateText;
  final ChatAttachmentTileState state;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colors = tokens.colors;
    final problem =
        state == ChatAttachmentTileState.expired ||
        state == ChatAttachmentTileState.damaged ||
        state == ChatAttachmentTileState.failed;
    final (AppIconData? actionIcon, Color actionColor) = switch (state) {
      ChatAttachmentTileState.notDownloaded => (
        AppIcons.download,
        colors.accent,
      ),
      ChatAttachmentTileState.failed => (AppIcons.retry, colors.danger),
      ChatAttachmentTileState.waiting ||
      ChatAttachmentTileState.downloading ||
      ChatAttachmentTileState.verifying => (AppIcons.close, colors.textMuted),
      ChatAttachmentTileState.expired => (AppIcons.expired, colors.textMuted),
      ChatAttachmentTileState.damaged => (AppIcons.damaged, colors.danger),
      ChatAttachmentTileState.ready => (null, colors.textMuted),
    };
    final running =
        state == ChatAttachmentTileState.downloading ||
        state == ChatAttachmentTileState.verifying;
    return Row(
      children: [
        AppIcon(
          picture
              ? AppIcons.photo
              : video
              ? AppIcons.video
              : AppIcons.file,
          color: colors.accent,
        ),
        const SizedBox(width: AppSpacing.x2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: tokens.typography.compact.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '$size · $stateText',
                style: tokens.typography.label.copyWith(
                  color: problem ? colors.danger : colors.textMuted,
                ),
              ),
              if (running || state == ChatAttachmentTileState.waiting)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.x1),
                  // Determinate even while it waits, at 0, as the upload
                  // tray's: an indeterminate bar animates for as long as a
                  // queue is long, on every tile that waits in it.
                  child: LinearProgressIndicator(
                    value: state == ChatAttachmentTileState.waiting
                        ? 0
                        : progress,
                  ),
                ),
            ],
          ),
        ),
        if (actionIcon != null) ...[
          const SizedBox(width: AppSpacing.x1),
          AppIcon(actionIcon, color: actionColor, size: 20),
        ],
      ],
    );
  }
}

/// A picture's place in its tile: the picture once it is ready and decoded,
/// and until then a placeholder of the same size, so that the timeline does
/// not jump when the picture arrives.
class _PictureBox extends StatelessWidget {
  const _PictureBox({required this.size, required this.file});

  final Size size;
  final File? file;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    final file = this.file;
    final placeholder = ColoredBox(
      color: colors.surface,
      child: Center(child: AppIcon(AppIcons.photo, color: colors.textMuted)),
    );
    return SizedBox(
      width: size.width,
      height: size.height,
      child: file == null
          ? placeholder
          : Image.file(
              file,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // Decoded no wider than it is drawn, and never wider than
              // 1,024 px (ADR-089 D7): a 2048 px photo costs a quarter of
              // the memory, and one from a file pick no more.
              cacheWidth: math.min(
                math.max(
                  1,
                  (size.width * MediaQuery.devicePixelRatioOf(context)).ceil(),
                ),
                chatAttachmentDecodeMaxWidth,
              ),
              frameBuilder: (context, child, frame, synchronous) =>
                  frame == null && !synchronous ? placeholder : child,
              errorBuilder: (context, error, stackTrace) => ColoredBox(
                color: colors.surface,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.x2),
                    child: Text(
                      AppLocalizations.of(context).attachmentPictureUnavailable,
                      textAlign: TextAlign.center,
                      style: context.tokens.typography.compact.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// The size a picture of [width] by [height] pixels is drawn at, at most
/// [maxWidth] (and [chatAttachmentTileMaxWidth]) wide and
/// [chatAttachmentPictureMaxHeight] high.
///
/// The ratio is kept between 1:2 and 2:1, so that a sliver of a panorama or
/// of a screenshot still has a size to tap; the picture covers the box. A
/// descriptor with no size is drawn square.
Size chatAttachmentPictureSize({
  required int? width,
  required int? height,
  required double maxWidth,
}) {
  final ratio = width == null || height == null || width <= 0 || height <= 0
      ? 1.0
      : (width / height).clamp(0.5, 2.0);
  var boxWidth = math.min(maxWidth, chatAttachmentTileMaxWidth);
  var boxHeight = boxWidth / ratio;
  if (boxHeight > chatAttachmentPictureMaxHeight) {
    boxHeight = chatAttachmentPictureMaxHeight;
    boxWidth = boxHeight * ratio;
  }
  return Size(boxWidth, boxHeight);
}
