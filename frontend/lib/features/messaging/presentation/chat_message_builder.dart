import 'dart:async';

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_emoji_picker.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_text_direction.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

/// The reactions the floating selector offers, in this order.
///
/// Presentation only, and deliberately so: `message-protocol.md` carries "one
/// normalized emoji grapheme or null", every layer below this one takes whatever
/// grapheme it is handed, and nothing outside this file knows which twenty-four
/// are on the panel. Each entry is one grapheme cluster - `❤️` and `🕊️` are a
/// base plus U+FE0F, the rest are single scalars - which is what
/// `SendConversationEvents.setReaction` requires before it will encode one.
const chatQuickReactions = <String>[
  '👍',
  '👎',
  '❤️',
  '🔥',
  '🥰',
  '👏',
  '😁',
  '🤔',
  '🤯',
  '😱',
  '🤬',
  '😢',
  '🎉',
  '🤩',
  '🤮',
  '💩',
  '🙏',
  '👌',
  '🕊️',
  '🤡',
  '🥱',
  '😍',
  '🐳',
  '💯',
];

/// The one reaction a double tap sets, and the one it removes when it is
/// already this user's. It is the first entry of [chatQuickReactions] and has to
/// stay in that list, because the selector marks the active reaction as selected
/// and a double tap must be undoable from the panel as well.
const chatDoubleTapReaction = '👍';

class ChatMessageBuilder extends StatelessWidget {
  const ChatMessageBuilder({
    required this.message,
    required this.highlighted,
    required this.onIntent,
    required this.onJumpToReply,
    super.key,
  });

  final ChatMessageViewModel message;
  final bool highlighted;
  final ChatIntentCallback onIntent;
  final ValueChanged<String> onJumpToReply;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    final strings = AppLocalizations.of(context);
    final stateLabel = _deliveryLabel(strings, message.delivery);
    final semanticLabel = strings.chatMessageSemantics(
      message.authorName,
      message.deleted
          ? strings.chatDeletedMessage
          : message.kind == ChatTimelineContentKind.unsupported
          ? strings.chatUnsupportedMessage
          : message.text ?? '',
      stateLabel,
    );
    final bubble = Semantics(
      container: true,
      button: true,
      label: semanticLabel,
      customSemanticsActions: {
        CustomSemanticsAction(label: strings.chatReplyAction): () =>
            onIntent(ReplyToMessageIntent(message)),
        CustomSemanticsAction(label: strings.chatMessageActionsLabel): () =>
            _showActions(context),
      },
      child: FocusableActionDetector(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.f10, shift: true):
              _OpenMessageMenuIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              unawaited(_showActions(context));
              return null;
            },
          ),
          _OpenMessageMenuIntent: CallbackAction<_OpenMessageMenuIntent>(
            onInvoke: (_) {
              unawaited(_showActions(context));
              return null;
            },
          ),
        },
        // The gap around a bubble stays outside the gesture detector, so the
        // press target is the bubble itself and not the blank column beside it.
        child: AnimatedPadding(
          duration: AppMotion.effective(context, AppMotion.state),
          curve: AppMotion.enter,
          padding: EdgeInsetsDirectional.only(
            start: message.outgoing ? AppSpacing.x12 : 0,
            end: message.outgoing ? 0 : AppSpacing.x12,
            top: message.firstInAuthorGroup ? AppSpacing.x3 : AppSpacing.x1,
            bottom: message.lastInAuthorGroup ? AppSpacing.x2 : AppSpacing.x1,
          ),
          child: GestureDetector(
            // The whole bubble is the target, not the glyphs inside it. Under
            // the default `deferToChild` a press only counts where a descendant
            // answers the hit test, so the bubble's own padding and the gaps
            // between its rows silently swallowed the press.
            //
            // `opaque` decides what happens where no descendant answers; it
            // does not take a press away from one that does. The reply quote,
            // the attachment tile, the reaction chips and the failed-send retry
            // each keep their own recognizer, and a recognizer nested inside
            // this one is entered into the gesture arena first, so it wins.
            // What they do lose is immediacy: `onDoubleTap` holds the arena for
            // `kDoubleTapTimeout` before a single tap can be awarded, and that
            // hold is per pointer rather than per detector. Telegram's model
            // costs the same.
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_showActions(context)),
            onDoubleTap: () => _toggleReaction(chatDoubleTapReaction),
            onSecondaryTapUp: (_) => unawaited(_showActions(context)),
            child: AnimatedContainer(
              key: ValueKey('message-${message.id}'),
              duration: AppMotion.effective(context, AppMotion.state),
              curve: AppMotion.enter,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x3,
                vertical: AppSpacing.x2,
              ),
              decoration: BoxDecoration(
                color: message.outgoing ? colors.accentSoft : colors.surface,
                border: Border.all(
                  color: highlighted
                      ? colors.accent
                      : message.delivery == ChatDeliveryViewState.failed
                      ? colors.danger
                      : colors.border,
                  width: highlighted ? 3 : 1,
                ),
                borderRadius: _bubbleRadius(message),
              ),
              child: _content(context),
            ),
          ),
        ),
      ),
    );
    // A fraction of the row is the bubble's *limit*, not its size.
    // `FractionallySizedBox` passes a tight width down, so every bubble was
    // exactly 82% of the row whatever it held, and a two-word message drew a
    // reaction row and a timestamp across empty space. A maximum leaves the
    // width to the content and keeps the long-message behaviour identical.
    return LayoutBuilder(
      builder: (context, constraints) {
        final widthClass = AppBreakpoints.of(MediaQuery.sizeOf(context).width);
        final limit = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return Align(
          alignment: message.outgoing
              ? AlignmentDirectional.centerEnd
              : AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth:
                  limit * (widthClass == AppWidthClass.narrow ? 0.82 : 0.70),
            ),
            child: bubble,
          ),
        );
      },
    );
  }

  Widget _content(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    // `stretch` is what forced a bubble to fill whatever width it was given:
    // a stretched column takes `constraints.maxWidth`, so the maximum set
    // above would have been the size again. Aligning to the message's own side
    // lets every row size to itself, which is the whole point of the change.
    final align = message.outgoing
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: align,
      children: [
        if (message.firstInAuthorGroup && !message.outgoing)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.x1),
            child: Text(
              message.authorName,
              style: context.tokens.typography.label.copyWith(
                color: colors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (message.replyQuote != null)
          InkWell(
            onTap: message.replyToMessageId == null
                ? null
                : () => onJumpToReply(message.replyToMessageId!),
            child: Container(
              margin: const EdgeInsets.only(bottom: AppSpacing.x2),
              padding: const EdgeInsetsDirectional.only(
                start: AppSpacing.x2,
                top: AppSpacing.x1,
                bottom: AppSpacing.x1,
              ),
              decoration: BoxDecoration(
                border: BorderDirectional(
                  start: BorderSide(color: colors.accent, width: 3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.replyAuthor ?? strings.chatReplyQuote,
                    style: context.tokens.typography.label.copyWith(
                      color: colors.accent,
                    ),
                  ),
                  Text(
                    message.replyQuote!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.tokens.typography.compact,
                  ),
                ],
              ),
            ),
          ),
        switch (message.kind) {
          ChatTimelineContentKind.text => Text(
            message.deleted ? strings.chatDeletedMessage : message.text ?? '',
            textDirection: resolveFirstStrongDirection(message.text),
            style: context.tokens.typography.body.copyWith(
              color: message.deleted ? colors.textMuted : colors.textPrimary,
              fontStyle: message.deleted ? FontStyle.italic : FontStyle.normal,
            ),
          ),
          ChatTimelineContentKind.image ||
          ChatTimelineContentKind.attachment => _AttachmentMessageContent(
            message: message,
            onOpen: () => onIntent(
              OpenAttachmentIntent(
                attachment: message.attachments.isEmpty
                    ? null
                    : message.attachments.first,
              ),
            ),
          ),
          ChatTimelineContentKind.system => _SystemMessageContent(
            text: message.text ?? strings.chatSystemMessage,
          ),
          ChatTimelineContentKind.unsupported =>
            const _UnsupportedMessageContent(),
        },
        // This row is the one the reader called out: under `stretch` it was
        // handed the bubble's full width whatever it held, so a single chip sat
        // in a box the size of the message. Under a column that no longer
        // stretches the `Wrap` takes the width of its chips and opens a new run
        // once the bubble's width is used up.
        if (message.reactions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.x2),
            child: Wrap(
              spacing: AppSpacing.x1,
              runSpacing: AppSpacing.x1,
              children: [
                for (final reaction in message.reactions)
                  _ReactionChip(
                    reaction: reaction,
                    onPressed: () => onIntent(
                      SetReactionIntent(
                        messageId: message.id,
                        emoji: reaction.selectedByCurrentUser
                            ? null
                            : reaction.emoji,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.x1),
        // The metadata keeps a row of its own rather than joining the last line
        // of text. Beside the text it fits at one width and not at the next, so
        // a bubble's height would start depending on the viewport, and a resize
        // would hand the reading anchor a height change it cannot correct in
        // one pass. On its own row the height is the same at every width, and
        // the row follows the column: trailing on this user's own messages,
        // leading on the other side's.
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.x1,
          children: [
            if (message.pinned)
              AppIcon(AppIcons.pin, color: colors.textMuted, size: 14),
            if (message.starred)
              AppIcon(AppIcons.star, color: colors.warning, size: 14),
            if (message.edited)
              Text(
                strings.chatEditedLabel,
                style: context.tokens.typography.label.copyWith(
                  color: colors.textMuted,
                ),
              ),
            if (message.timestampSkewed)
              Tooltip(
                message: strings.chatTimestampSkewed,
                child: AppIcon(
                  AppIcons.warning,
                  color: colors.warning,
                  size: 14,
                ),
              ),
            Text(
              MaterialLocalizations.of(
                context,
              ).formatTimeOfDay(TimeOfDay.fromDateTime(message.timestamp)),
              style: context.tokens.typography.label.copyWith(
                color: colors.textMuted,
              ),
            ),
            _DeliveryIndicator(state: message.delivery),
          ],
        ),
        // No `Align` around the retry: an `Align` takes the width it is offered
        // and would put the bubble back at its maximum. A failed send is always
        // this user's own, so the column's trailing alignment is already the
        // alignment this button wants.
        if (message.delivery == ChatDeliveryViewState.failed)
          TextButton.icon(
            onPressed: () => onIntent(RetryMessageIntent(message)),
            icon: AppIcon(AppIcons.retry, color: colors.danger, size: 16),
            label: Text(strings.chatRetrySendAction),
            style: TextButton.styleFrom(foregroundColor: colors.danger),
          ),
      ],
    );
  }

  /// The reaction this user has set on this message, or null.
  ///
  /// A reaction is a set operation per `(target, reacting_user)`, so at most one
  /// chip can carry `selectedByCurrentUser`.
  String? get _ownReaction {
    for (final reaction in message.reactions) {
      if (reaction.selectedByCurrentUser) {
        return reaction.emoji;
      }
    }
    return null;
  }

  /// Sets [emoji], or removes it when it is already this user's.
  ///
  /// The same rule the reaction chips have always used, reached from the
  /// selector and from the double tap so that all three agree.
  void _toggleReaction(String emoji) => onIntent(
    SetReactionIntent(
      messageId: message.id,
      emoji: _ownReaction == emoji ? null : emoji,
    ),
  );

  /// This bubble's rectangle in global coordinates, for the selector to sit
  /// above. Null when the element has no attached box - which a modal opened
  /// from a semantics action can reach - and the selector then parks itself
  /// directly above the sheet instead.
  Rect? _anchor(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return null;
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _showActions(BuildContext context) async {
    final strings = AppLocalizations.of(context);
    await showAppAnchoredSheet<void>(
      context: context,
      semanticLabel: strings.chatMessageActionsLabel,
      anchor: _anchor(context),
      anchored: _ReactionSelector(
        selected: _ownReaction,
        onSelected: (emoji) {
          popAppModal(context);
          _toggleReaction(emoji);
        },
        onExpand: () => unawaited(_expandReactions(context)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _MessageAction(
                label: strings.chatReplyAction,
                icon: AppIcons.reply,
                onPressed: () {
                  popAppModal(context);
                  onIntent(ReplyToMessageIntent(message));
                },
              ),
              if (message.canEdit)
                _MessageAction(
                  label: strings.chatEditAction,
                  icon: AppIcons.edit,
                  onPressed: () {
                    popAppModal(context);
                    onIntent(BeginEditMessageIntent(message));
                  },
                ),
              if (!message.deleted && message.text?.trim().isNotEmpty == true)
                _MessageAction(
                  label: strings.chatForwardAction,
                  icon: AppIcons.forward,
                  onPressed: () {
                    popAppModal(context);
                    onIntent(ForwardMessageIntent(message));
                  },
                ),
              if (!message.deleted && message.text != null)
                _MessageAction(
                  label: strings.chatCopyAction,
                  icon: AppIcons.copy,
                  onPressed: () {
                    popAppModal(context);
                    onIntent(CopyMessageIntent(message.text!));
                  },
                ),
              _MessageAction(
                label: message.starred
                    ? strings.chatUnstarAction
                    : strings.chatStarAction,
                icon: AppIcons.star,
                onPressed: () {
                  popAppModal(context);
                  onIntent(
                    SetStarIntent(
                      messageId: message.id,
                      starred: !message.starred,
                    ),
                  );
                },
              ),
              _MessageAction(
                label: message.pinned
                    ? strings.chatUnpinAction
                    : strings.chatPinAction,
                icon: AppIcons.pin,
                onPressed: () {
                  popAppModal(context);
                  onIntent(
                    SetPinIntent(
                      messageId: message.id,
                      pinned: !message.pinned,
                    ),
                  );
                },
              ),
              _MessageAction(
                label: strings.chatDeleteAction,
                icon: AppIcons.delete,
                danger: true,
                onPressed: () {
                  popAppModal(context);
                  unawaited(_showDeleteDialog(context));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the full picker over the selector, and sets whatever comes back.
  ///
  /// Not a toggle: the panel is where a reaction is removed, and picking an
  /// emoji out of 1500 is an act of choosing rather than of undoing. Dismissing
  /// the picker leaves the message surface open, because the user has not
  /// finished with it.
  Future<void> _expandReactions(BuildContext context) async {
    final emoji = await showAppEmojiPicker(context);
    if (emoji == null || !context.mounted) {
      return;
    }
    popAppModal(context);
    onIntent(SetReactionIntent(messageId: message.id, emoji: emoji));
  }

  Future<void> _showDeleteDialog(BuildContext context) async {
    final strings = AppLocalizations.of(context);
    await showAppDialog<void>(
      context: context,
      title: strings.chatDeleteTitle,
      body: strings.chatDeleteHonestMessage,
      actions: [
        AppButton(
          label: strings.chatCancelAction,
          kind: AppButtonKind.ghost,
          onPressed: () => popAppModal(context),
        ),
        AppButton(
          label: strings.chatDeleteForMeAction,
          kind: AppButtonKind.outline,
          onPressed: () {
            popAppModal(context);
            onIntent(DeleteForMeIntent(message.id));
          },
        ),
        if (message.canDeleteForEveryone)
          AppButton(
            label: strings.chatDeleteForEveryoneAction,
            kind: AppButtonKind.danger,
            onPressed: () {
              popAppModal(context);
              onIntent(DeleteForEveryoneIntent(message.id));
            },
          ),
      ],
    );
  }
}

final class _AttachmentMessageContent extends StatelessWidget {
  const _AttachmentMessageContent({
    required this.message,
    required this.onOpen,
  });

  final ChatMessageViewModel message;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    final state = message.attachmentStates.isEmpty
        ? AttachmentTransferState.ready
        : message.attachmentStates.first;
    final ready = state == AttachmentTransferState.ready;
    final typeLabel = message.kind == ChatTimelineContentKind.image
        ? strings.attachmentImageLabel
        : strings.attachmentFileLabel;
    return Semantics(
      button: true,
      label: '$typeLabel: ${_attachmentStateLabel(strings, state)}',
      hint: ready ? strings.attachmentOpenHint : null,
      child: InkWell(
        onTap: message.attachments.isEmpty || !ready ? null : onOpen,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceRaised,
            borderRadius: AppRadii.control,
            border: Border.all(color: colors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(
                  message.kind == ChatTimelineContentKind.image
                      ? AppIcons.attach
                      : AppIcons.attach,
                  color: colors.accent,
                ),
                const SizedBox(width: AppSpacing.x1),
                Flexible(
                  child: Text(
                    message.attachments.isEmpty || !ready
                        ? _attachmentStateLabel(strings, state)
                        : message.attachments.first.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenMessageMenuIntent extends Intent {
  const _OpenMessageMenuIntent();
}

class _MessageAction extends StatelessWidget {
  const _MessageAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.danger = false,
  });

  final String label;
  final AppIconData icon;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: ListTile(
      minTileHeight: AppFocus.minimumTarget,
      leading: AppIcon(
        icon,
        color: danger
            ? context.tokens.colors.danger
            : context.tokens.colors.textPrimary,
      ),
      title: Text(
        label,
        style: context.tokens.typography.body.copyWith(
          color: danger
              ? context.tokens.colors.danger
              : context.tokens.colors.textPrimary,
        ),
      ),
      onTap: onPressed,
    ),
  );
}

/// The floating panel of quick reactions that opens with the message actions.
///
/// One horizontally scrollable row on a raised rounded surface, ending in the
/// control that opens the full picker. It is a sibling of the action sheet
/// inside one route, which is what makes it keyboard reachable and traversable
/// by a screen reader; see [showAppAnchoredSheet].
class _ReactionSelector extends StatelessWidget {
  const _ReactionSelector({
    required this.selected,
    required this.onSelected,
    required this.onExpand,
  });

  /// The reaction this user has already set, marked as selected in the row.
  final String? selected;

  /// Called with the chosen emoji. Whether that sets or removes belongs to the
  /// caller, which is the only place that knows the current reaction.
  final ValueChanged<String> onSelected;

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: strings.chatReactionSelectorLabel,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: AppRadii.pill,
            border: Border.all(color: colors.border),
            boxShadow: AppElevation.level2,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x1),
              child: Row(
                children: [
                  // Only the reactions scroll. The control that opens the full
                  // picker stays pinned to the trailing edge, because twenty-four
                  // targets are wider than any phone and an expand button a
                  // thousand pixels away is one nobody finds.
                  Flexible(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final emoji in chatQuickReactions)
                            _ReactionOption(
                              emoji: emoji,
                              selected: emoji == selected,
                              onPressed: () => onSelected(emoji),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    height: AppSpacing.x6,
                    margin: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x1,
                    ),
                    color: colors.border,
                  ),
                  _ReactionExpandOption(onPressed: onExpand),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReactionOption extends StatelessWidget {
  const _ReactionOption({
    required this.emoji,
    required this.selected,
    required this.onPressed,
  });

  final String emoji;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    return Semantics(
      button: true,
      selected: selected,
      excludeSemantics: true,
      label: selected
          ? strings.chatReactionRemoveAction(emoji)
          : strings.chatReactionAddAction(emoji),
      child: InkResponse(
        onTap: onPressed,
        radius: AppFocus.minimumTarget / 2,
        containedInkWell: true,
        customBorder: const CircleBorder(),
        child: Container(
          width: AppFocus.minimumTarget,
          height: AppFocus.minimumTarget,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? colors.accentSoft : null,
            border: selected
                ? Border.all(color: colors.accent, width: 2)
                : null,
          ),
          // The glyph is a glyph in either direction; only the row around it
          // follows the locale.
          child: Text(
            emoji,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 24),
          ),
        ),
      ),
    );
  }
}

class _ReactionExpandOption extends StatelessWidget {
  const _ReactionExpandOption({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).chatMoreReactionsAction;
    final colors = context.tokens.colors;
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: onPressed,
          radius: AppFocus.minimumTarget / 2,
          containedInkWell: true,
          customBorder: const CircleBorder(),
          child: Container(
            width: AppFocus.minimumTarget,
            height: AppFocus.minimumTarget,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.surfaceRaised,
            ),
            child: AppIcon(AppIcons.add, color: colors.textPrimary, size: 20),
          ),
        ),
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.reaction, required this.onPressed});

  final ChatReactionViewModel reaction;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: reaction.selectedByCurrentUser,
    label: AppLocalizations.of(
      context,
    ).chatReactionSemantics(reaction.emoji, reaction.count),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadii.pill,
        child: Container(
          constraints: const BoxConstraints(minHeight: 32, minWidth: 40),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x2),
          decoration: BoxDecoration(
            color: reaction.selectedByCurrentUser
                ? context.tokens.colors.accentSoft
                : context.tokens.colors.surfaceRaised,
            border: Border.all(
              color: reaction.selectedByCurrentUser
                  ? context.tokens.colors.accent
                  : context.tokens.colors.border,
            ),
            borderRadius: AppRadii.pill,
          ),
          // No `alignment`: a `Container` given one wraps its child in an
          // `Align`, which takes every pixel it is offered, and that is what
          // drew one chip as a pill the width of the whole message. The minimum
          // width reaches the text through the container's constraints instead,
          // so `textAlign` centres a short label inside a chip that is still
          // only as wide as it needs to be.
          child: Text(
            '${reaction.emoji} ${reaction.count}',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}

class _DeliveryIndicator extends StatelessWidget {
  const _DeliveryIndicator({required this.state});

  final ChatDeliveryViewState state;

  @override
  Widget build(BuildContext context) {
    if (state == ChatDeliveryViewState.received) {
      return const SizedBox.shrink();
    }
    final strings = AppLocalizations.of(context);
    final (icon, color) = switch (state) {
      ChatDeliveryViewState.localOnly => (
        AppIcons.saved,
        context.tokens.colors.textMuted,
      ),
      ChatDeliveryViewState.queued => (
        AppIcons.offlineQueue,
        context.tokens.colors.warning,
      ),
      ChatDeliveryViewState.encrypting => (
        AppIcons.security,
        context.tokens.colors.warning,
      ),
      ChatDeliveryViewState.sending => (
        AppIcons.clock,
        context.tokens.colors.textMuted,
      ),
      ChatDeliveryViewState.accepted => (
        AppIcons.accepted,
        context.tokens.colors.textMuted,
      ),
      ChatDeliveryViewState.delivered => (
        AppIcons.delivered,
        context.tokens.colors.success,
      ),
      ChatDeliveryViewState.read => (
        AppIcons.read,
        context.tokens.colors.accent,
      ),
      ChatDeliveryViewState.failed => (
        AppIcons.error,
        context.tokens.colors.danger,
      ),
      ChatDeliveryViewState.received => (
        AppIcons.info,
        context.tokens.colors.textMuted,
      ),
    };
    final label = _deliveryLabel(strings, state);
    return Tooltip(
      message: label,
      child: AppIcon(
        icon,
        color: color,
        size: 15,
        decorative: false,
        semanticLabel: label,
      ),
    );
  }
}

class _SystemMessageContent extends StatelessWidget {
  const _SystemMessageContent({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      AppIcon(AppIcons.info, color: context.tokens.colors.textMuted, size: 16),
      const SizedBox(width: AppSpacing.x2),
      Flexible(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: context.tokens.typography.compact.copyWith(
            color: context.tokens.colors.textMuted,
          ),
        ),
      ),
    ],
  );
}

class _UnsupportedMessageContent extends StatelessWidget {
  const _UnsupportedMessageContent();

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).chatUnsupportedMessage;
    return Row(
      children: [
        AppIcon(AppIcons.unsupported, color: context.tokens.colors.warning),
        const SizedBox(width: AppSpacing.x2),
        Expanded(child: Text(label, style: context.tokens.typography.compact)),
      ],
    );
  }
}

BorderRadius _bubbleRadius(ChatMessageViewModel message) {
  const regular = Radius.circular(20);
  const grouped = Radius.circular(8);
  if (!message.lastInAuthorGroup) return AppRadii.message;
  return message.outgoing
      ? const BorderRadius.only(
          topLeft: regular,
          topRight: regular,
          bottomLeft: regular,
          bottomRight: grouped,
        )
      : const BorderRadius.only(
          topLeft: regular,
          topRight: regular,
          bottomLeft: grouped,
          bottomRight: regular,
        );
}

String _attachmentStateLabel(
  AppLocalizations strings,
  AttachmentTransferState state,
) => switch (state) {
  AttachmentTransferState.queued => strings.attachmentQueuedState,
  AttachmentTransferState.encrypting => strings.chatStateEncrypting,
  AttachmentTransferState.uploading => strings.chatStateSending,
  AttachmentTransferState.sending => strings.chatStateSending,
  AttachmentTransferState.downloading => strings.attachmentDownloadingState,
  AttachmentTransferState.verifying => strings.attachmentVerifyingState,
  AttachmentTransferState.ready => strings.attachmentReadyState,
  AttachmentTransferState.expired => strings.attachmentExpiredState,
  AttachmentTransferState.cancelled => strings.attachmentCancelledState,
  AttachmentTransferState.quotaExceeded => strings.attachmentQuotaState,
  AttachmentTransferState.unsupported => strings.attachmentUnsupportedState,
  AttachmentTransferState.corrupt => strings.attachmentCorruptState,
  AttachmentTransferState.failed => strings.attachmentFailedState,
};

String _deliveryLabel(AppLocalizations strings, ChatDeliveryViewState state) =>
    switch (state) {
      ChatDeliveryViewState.localOnly => strings.chatStateLocalOnly,
      ChatDeliveryViewState.queued => strings.chatStateQueued,
      ChatDeliveryViewState.encrypting => strings.chatStateEncrypting,
      ChatDeliveryViewState.sending => strings.chatStateSending,
      ChatDeliveryViewState.accepted => strings.chatStateAccepted,
      ChatDeliveryViewState.delivered => strings.chatStateDelivered,
      ChatDeliveryViewState.read => strings.chatStateRead,
      ChatDeliveryViewState.failed => strings.chatStateFailed,
      ChatDeliveryViewState.received => strings.chatStateReceived,
    };
