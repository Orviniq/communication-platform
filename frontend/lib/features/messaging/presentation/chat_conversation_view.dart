import 'dart:async';

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/messaging/presentation/chat_attachment_tiles.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_composer_builder.dart';
import 'package:communication_platform/features/messaging/presentation/chat_forward.dart';
import 'package:communication_platform/features/messaging/presentation/chat_pinned_banner.dart';
import 'package:communication_platform/features/messaging/presentation/chat_timeline_adapter.dart';
import 'package:communication_platform/features/messaging/presentation/chat_undelivered_hint.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/conversation_search.dart';
import 'package:communication_platform/features/signals/domain/peer_status_model.dart';
import 'package:communication_platform/features/signals/presentation/peer_status_line.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ChatConversationView extends StatefulWidget {
  const ChatConversationView({
    required this.model,
    required this.onIntent,
    this.peerUserId,
    this.peerStatus = const PeerStatusNone(),
    this.initialDraft,
    this.forwardTargets,
    this.attachments = ChatAttachmentAvailability.notBuilt,
    this.uploads,
    this.attachmentTransfers,
    this.attachmentRetentionDays = 30,
    this.undeliveredHintPeer,
    this.now = DateTime.now,
    super.key,
  });

  final ChatTimelineViewModel model;
  final ChatIntentCallback onIntent;
  final String? peerUserId;

  /// What this phone knows of the peer's online status, drawn under the name
  /// when the peer is verified (ADR-098 D11). Nothing for Saved Messages.
  final PeerStatus peerStatus;
  final String? initialDraft;

  /// What the composer's paperclip does here.
  final ChatAttachmentAvailability attachments;

  /// The uploads of this conversation, drawn between the timeline and the
  /// composer. A slot rather than a list, so that a percent that moves
  /// rebuilds the tray and not the timeline above it.
  final Widget? uploads;

  /// The downloads and the ready pictures the timeline's attachment tiles
  /// read, or null where attachments are not built: a tile then shows its row
  /// alone.
  final ChatAttachmentTransfers? attachmentTransfers;

  /// How many days the server keeps an attachment after it was sent, which
  /// the delete dialog of an attachment message states.
  final int attachmentRetentionDays;

  /// How the peer is named in the line under an own direct message that no
  /// receipt has answered for an hour (ADR-093 D19): `@username`, or the short
  /// identity without the `@`. Null shows no such line, as in Saved Messages.
  /// A group chat has its own page and never draws it.
  final String? undeliveredHintPeer;

  /// The clock the line's hour is counted against.
  final DateTime Function() now;

  /// Where a forward may go, resolved when the sheet opens.
  ///
  /// A callback rather than a list because that is when it is needed. As a
  /// field it was a whole conversation list mapped into view models on every
  /// build of a screen that draws none of them.
  final ValueGetter<List<ChatListItemViewModel>>? forwardTargets;

  @override
  State<ChatConversationView> createState() => _ChatConversationViewState();
}

class _ChatConversationViewState extends State<ChatConversationView> {
  final GlobalKey<ChatComposerBuilderState> _composerKey = GlobalKey();

  /// The last jump a tap here asked for. Every tap makes a new request, so a
  /// second tap on the same quote scrolls and pulses again.
  ChatJumpRequest? _jump;
  var _jumpSerial = 0;

  void _handleIntent(ChatIntent intent) {
    if (intent is ReplyToMessageIntent || intent is BeginEditMessageIntent) {
      _composerKey.currentState?.handleIntent(intent);
    }
    if (intent case JumpToMessageIntent(:final messageId)) {
      setState(() => _jump = ChatJumpRequest(messageId, ++_jumpSerial));
    }
    if (intent case ForwardMessageIntent(:final message)) {
      unawaited(_showForwardPicker(message));
      return;
    }
    widget.onIntent(intent);
  }

  /// The line under the peer's name, or null for none. Typing wins over
  /// online, which wins over a last seen. Saved Messages has no peer, and a
  /// peer this user has not verified shows no status (T2, T4).
  Widget? _statusLine(BuildContext context, AppLocalizations strings) {
    if (widget.model.savedMessages) {
      return null;
    }
    final verified = widget.model.securityGate == ChatSecurityGate.ready;
    final text = widget.model.typing
        ? strings.chatTypingStatus
        : verified
        ? peerStatusLine(context, widget.peerStatus, now: widget.now())
        : null;
    if (text == null) {
      return null;
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.tokens.typography.label.copyWith(
        color: widget.model.typing || widget.peerStatus is PeerStatusOnline
            ? context.tokens.colors.accent
            : context.tokens.colors.textMuted,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final model = ChatTimelineViewModel(
      state: widget.model.state,
      conversationId: widget.model.conversationId,
      title: widget.model.title,
      savedMessages: widget.model.savedMessages,
      securityGate: widget.model.securityGate,
      offline: widget.model.offline,
      hasMoreBefore: widget.model.hasMoreBefore,
      loadingBefore: widget.model.loadingBefore,
      olderLoadFailed: widget.model.olderLoadFailed,
      typing: widget.model.typing,
      pinnedMessages: widget.model.pinnedMessages,
      messages: widget.model.messages,
      errorCode: widget.model.errorCode,
      jump: _jump ?? widget.model.jump,
    );
    return RepaintBoundary(
      key: const ValueKey('chat-interface-golden'),
      child: Scaffold(
        key: ValueKey(
          widget.model.savedMessages
              ? 'saved-messages-screen'
              : 'direct-chat-screen',
        ),
        appBar: AppBar(
          leading: AppIconButton(
            icon: AppIcons.back,
            semanticLabel: strings.authBackAction,
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/chats'),
            kind: AppButtonKind.ghost,
          ),
          titleSpacing: 0,
          title: Semantics(
            button: !widget.model.savedMessages,
            label: widget.model.title,
            child: InkWell(
              onTap: widget.model.savedMessages || widget.peerUserId == null
                  ? null
                  : () => context.push('/contacts/${widget.peerUserId}'),
              child: Row(
                children: [
                  if (widget.model.savedMessages)
                    CircleAvatar(
                      backgroundColor: context.tokens.colors.accentSoft,
                      foregroundColor: context.tokens.colors.accent,
                      child: const AppIcon(AppIcons.saved),
                    )
                  else
                    ContactAvatar(
                      username: widget.model.title,
                      semanticLabel: widget.model.title,
                      radius: 20,
                    ),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.model.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // Typing, else online, else last seen, else nothing
                        // (ADR-098 D11). Every claim here is one this phone
                        // heard from the peer in a `signal` frame; the server
                        // holds no presence (server ADR-0022), so a peer this
                        // phone has not heard from says nothing rather than
                        // "offline".
                        ?_statusLine(context, strings),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            AppIconButton(
              icon: AppIcons.search,
              semanticLabel: strings.chatSearchAction,
              onPressed: _showSearch,
              kind: AppButtonKind.ghost,
            ),
            AppIconButton(
              icon: AppIcons.more,
              semanticLabel: strings.chatMoreAction,
              onPressed: _showConversationMenu,
              kind: AppButtonKind.ghost,
            ),
          ],
        ),
        body: Column(
          children: [
            if (widget.model.pinnedMessages.isNotEmpty)
              ChatPinnedBanner(
                count: widget.model.pinnedMessages.length,
                onJump: () => _handleIntent(
                  JumpToMessageIntent(widget.model.pinnedMessages.first.id),
                ),
                onExpand: _showPinnedMessages,
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppContentWidths.readable,
                  ),
                  child: switch (widget.attachmentTransfers) {
                    final transfers? => ChatAttachmentScope(
                      transfers: transfers,
                      retentionDays: widget.attachmentRetentionDays,
                      child: ChatTimelineAdapter(
                        model: model,
                        onIntent: _handleIntent,
                      ),
                    ),
                    null => ChatTimelineAdapter(
                      model: model,
                      onIntent: _handleIntent,
                    ),
                  },
                ),
              ),
            ),
            if (!widget.model.savedMessages && widget.peerUserId != null)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppContentWidths.readable,
                  ),
                  child: ChatUndeliveredHint(
                    messages: widget.model.messages,
                    peer: widget.undeliveredHintPeer,
                    now: widget.now,
                  ),
                ),
              ),
            if (widget.uploads case final uploads?)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppContentWidths.readable,
                  ),
                  child: uploads,
                ),
              ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppContentWidths.readable,
                ),
                child: ChatComposerBuilder(
                  key: _composerKey,
                  securityGate: widget.model.securityGate,
                  offline: widget.model.offline,
                  savedMessages: widget.model.savedMessages,
                  initialDraft: widget.initialDraft,
                  attachments: widget.attachments,
                  onIntent: _handleIntent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSearch() => showConversationSearch(
    context: context,
    messages: widget.model.messages,
    onJumpToMessage: (id) => _handleIntent(JumpToMessageIntent(id)),
  );

  Future<void> _showPinnedMessages() => showChatPinnedMessages(
    context: context,
    pinned: widget.model.pinnedMessages,
    onIntent: _handleIntent,
  );

  Future<void> _showForwardPicker(ChatMessageViewModel message) =>
      showChatForwardPicker(
        context: context,
        message: message,
        // Resolved here, once, because here is where it is wanted.
        targets:
            widget.forwardTargets?.call() ?? const <ChatListItemViewModel>[],
        onForward: (targets) => widget.onIntent(
          ForwardToConversationsIntent(message: message, targets: targets),
        ),
      );

  /// Clearing is local, and the dialog says so.
  ///
  /// It removes this device's copy of the conversation and nothing else:
  /// the peer keeps theirs, this account's other devices keep theirs, and no
  /// request is sent asking anybody to forget anything. Wording that implied
  /// otherwise would be the promise §17 forbids a destructive dialog from
  /// making.
  Future<void> _confirmClearHistory() async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showAppDialog<bool>(
      context: context,
      title: strings.chatClearHistoryTitle,
      body: strings.chatClearHistoryBody,
      actions: [
        AppButton(
          label: strings.chatCancelAction,
          kind: AppButtonKind.ghost,
          onPressed: () => popAppModal<bool>(context, false),
        ),
        AppButton(
          key: const ValueKey('chat-clear-history-confirm'),
          label: strings.chatClearHistoryAction,
          kind: AppButtonKind.danger,
          onPressed: () => popAppModal<bool>(context, true),
        ),
      ],
    );
    if (confirmed ?? false) {
      _handleIntent(const ClearConversationHistoryIntent());
    }
  }

  Future<void> _showConversationMenu() async {
    final strings = AppLocalizations.of(context);
    await showAppSheet<void>(
      context: context,
      semanticLabel: strings.chatMoreAction,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.model.savedMessages)
            ChatMenuRow(
              label: strings.contactVerifyAction,
              icon: AppIcons.security,
              onTap: () {
                popAppModal(context);
                if (widget.peerUserId != null) {
                  unawaited(
                    context.push('/contacts/${widget.peerUserId}/safety'),
                  );
                }
              },
            ),
          ChatMenuRow(
            label: strings.chatPinnedMessagesTitle,
            icon: AppIcons.pin,
            onTap: () {
              popAppModal(context);
              unawaited(_showPinnedMessages());
            },
          ),
          ChatMenuRow(
            label: strings.contactClearHistoryAction,
            icon: AppIcons.delete,
            danger: true,
            onTap: () {
              popAppModal(context);
              unawaited(_confirmClearHistory());
            },
          ),
        ],
      ),
    );
  }
}
