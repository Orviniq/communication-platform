import 'dart:async';

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_composer_builder.dart';
import 'package:communication_platform/features/messaging/presentation/chat_timeline_adapter.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/conversation_search.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ChatConversationView extends StatefulWidget {
  const ChatConversationView({
    required this.model,
    required this.onIntent,
    this.peerUserId,
    this.initialDraft,
    this.forwardTargets,
    super.key,
  });

  final ChatTimelineViewModel model;
  final ChatIntentCallback onIntent;
  final String? peerUserId;
  final String? initialDraft;

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
  String? _highlightedMessageId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onIntent(const MarkConversationReadIntent());
    });
  }

  void _handleIntent(ChatIntent intent) {
    if (intent is ReplyToMessageIntent || intent is BeginEditMessageIntent) {
      _composerKey.currentState?.handleIntent(intent);
    }
    if (intent case JumpToMessageIntent(:final messageId)) {
      setState(() => _highlightedMessageId = messageId);
    }
    if (intent case ForwardMessageIntent(:final message)) {
      unawaited(_showForwardPicker(message));
      return;
    }
    widget.onIntent(intent);
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
      highlightedMessageId:
          _highlightedMessageId ?? widget.model.highlightedMessageId,
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
                        // Only while somebody is actually typing.
                        //
                        // This line used to fall through to a presence claim,
                        // and the claim was structurally false: the server
                        // holds no presence at all (server ADR-0022), so there
                        // is nothing for it to emit and every peer read as
                        // offline forever — including one holding a live socket
                        // in the same conversation. Presence between members is
                        // client protocol over `signal` frames if it is ever
                        // built; until then, saying nothing is the honest state.
                        if (!widget.model.savedMessages && widget.model.typing)
                          Text(
                            strings.chatTypingStatus,
                            style: context.tokens.typography.label.copyWith(
                              color: context.tokens.colors.accent,
                            ),
                          ),
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
              _PinnedBanner(
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
                  child: ChatTimelineAdapter(
                    model: model,
                    onIntent: _handleIntent,
                  ),
                ),
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

  Future<void> _showPinnedMessages() async {
    final strings = AppLocalizations.of(context);
    final pinned = widget.model.pinnedMessages;
    await showAppSheet<void>(
      context: context,
      semanticLabel: strings.chatPinnedMessagesTitle,
      child: SizedBox(
        height: mathMin(MediaQuery.sizeOf(context).height * .65, 520),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              strings.chatPinnedMessagesTitle,
              style: context.tokens.typography.section,
            ),
            const SizedBox(height: AppSpacing.x3),
            Expanded(
              child: ListView.builder(
                itemCount: pinned.length,
                itemBuilder: (context, index) {
                  final message = pinned[index];
                  return ListTile(
                    leading: const AppIcon(AppIcons.pin),
                    title: Text(
                      message.text ?? strings.chatDeletedMessage,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: TextButton(
                      onPressed: () => _handleIntent(
                        SetPinIntent(messageId: message.id, pinned: false),
                      ),
                      child: Text(strings.chatUnpinAction),
                    ),
                    onTap: () {
                      popAppModal(context);
                      _handleIntent(JumpToMessageIntent(message.id));
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showForwardPicker(ChatMessageViewModel message) async {
    final strings = AppLocalizations.of(context);
    final selected = <String>{};
    // Resolved here, once, because here is where it is wanted.
    final forwardTargets =
        widget.forwardTargets?.call() ?? const <ChatListItemViewModel>[];
    await showAppSheet<void>(
      context: context,
      semanticLabel: strings.chatForwardAction,
      child: StatefulBuilder(
        builder: (context, setModalState) => SizedBox(
          height: mathMin(MediaQuery.sizeOf(context).height * .7, 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                strings.chatForwardAction,
                style: context.tokens.typography.section,
              ),
              const SizedBox(height: AppSpacing.x2),
              Expanded(
                child: forwardTargets.isEmpty
                    ? AppStatePanel.empty(
                        title: strings.chatsEmptyTitle,
                        message: strings.chatsEmptyMessage,
                      )
                    : ListView.builder(
                        itemCount: forwardTargets.length,
                        itemBuilder: (context, index) {
                          final target = forwardTargets[index];
                          final selectionKey = target.savedMessages
                              ? 'saved'
                              : target.conversationId;
                          return CheckboxListTile(
                            value: selected.contains(selectionKey),
                            title: Text(target.title),
                            secondary: target.savedMessages
                                ? const AppIcon(AppIcons.saved)
                                : ContactAvatar(
                                    username: target.title,
                                    semanticLabel: target.title,
                                    radius: 18,
                                  ),
                            onChanged: (value) {
                              setModalState(() {
                                if (value ?? false) {
                                  selected.add(selectionKey);
                                } else {
                                  selected.remove(selectionKey);
                                }
                              });
                            },
                          );
                        },
                      ),
              ),
              AppButton(
                label: strings.chatForwardAction,
                onPressed: selected.isEmpty
                    ? null
                    : () {
                        final targets = forwardTargets.where((target) {
                          final key = target.savedMessages
                              ? 'saved'
                              : target.conversationId;
                          return selected.contains(key);
                        });
                        popAppModal(context);
                        widget.onIntent(
                          ForwardToConversationsIntent(
                            message: message,
                            targets: targets,
                          ),
                        );
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

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

class _PinnedBanner extends StatelessWidget {
  const _PinnedBanner({
    required this.count,
    required this.onJump,
    required this.onExpand,
  });

  final int count;
  final VoidCallback onJump;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final label = strings.chatPinnedBanner(count);
    return Semantics(
      container: true,
      button: true,
      label: label,
      child: Material(
        color: context.tokens.colors.accentSoft,
        child: InkWell(
          onTap: onJump,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x2,
            ),
            child: Row(
              children: [
                AppIcon(AppIcons.pin, color: context.tokens.colors.accent),
                const SizedBox(width: AppSpacing.x2),
                Expanded(
                  child: Text(
                    label,
                    style: context.tokens.typography.compact.copyWith(
                      color: context.tokens.colors.accent,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onExpand,
                  child: Text(strings.chatPinnedExpandAction),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

double mathMin(double left, double right) => left < right ? left : right;
