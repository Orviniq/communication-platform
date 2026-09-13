import 'dart:async';

import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_composer_builder.dart';
import 'package:communication_platform/features/messaging/presentation/chat_timeline_adapter.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/conversation_search.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class GroupChatPage extends ConsumerWidget {
  const GroupChatPage({
    required this.groupId,
    this.injectedState,
    this.injectedMessages,
    this.currentUserId,
    this.onSend,
    super.key,
  });

  final String groupId;
  final GroupState? injectedState;
  final List<GroupMessage>? injectedMessages;
  final String? currentUserId;
  final SendGroupMessageCallback? onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (injectedState != null && injectedMessages != null && onSend != null) {
      return GroupChatView(
        state: injectedState!,
        messages: injectedMessages!,
        currentUserId: currentUserId ?? injectedState!.members.first.userId,
        onSend: onSend!,
      );
    }
    final auth = ref.watch(authenticationControllerProvider);
    final userId = currentUserId ?? auth.userId;
    if (userId == null) return groupErrorPage(context);
    final group = ref.watch(groupProvider(groupId));
    final messages = ref.watch(groupMessagesProvider(groupId));
    final device = ref.watch(currentMessagingDeviceIdProvider);
    final useCases = ref.watch(groupUseCasesProvider);
    return group.when(
      loading: () => groupLoadingPage(context),
      error: (_, _) => groupErrorPage(context),
      data: (state) {
        if (state == null) return groupErrorPage(context);
        return messages.when(
          loading: () => groupLoadingPage(context),
          error: (_, _) => groupErrorPage(context),
          data: (items) => device.when(
            loading: () => groupLoadingPage(context),
            error: (_, _) => groupErrorPage(context),
            data: (deviceId) => useCases.when(
              loading: () => groupLoadingPage(context),
              error: (_, _) => groupErrorPage(context),
              data: (resolved) => GroupChatView(
                state: state,
                messages: items,
                currentUserId: userId,
                onSend: (text) => resolved.sendMessage(
                  groupId: groupId,
                  senderUserId: userId,
                  senderDeviceId: deviceId,
                  text: text,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class GroupChatView extends StatefulWidget {
  const GroupChatView({
    required this.state,
    required this.messages,
    required this.currentUserId,
    required this.onSend,
    super.key,
  });

  final GroupState state;
  final List<GroupMessage> messages;
  final String currentUserId;
  final SendGroupMessageCallback onSend;

  @override
  State<GroupChatView> createState() => _GroupChatViewState();
}

class _GroupChatViewState extends State<GroupChatView> {
  final _composerKey = GlobalKey<ChatComposerBuilderState>();
  var _sending = false;
  var _sendFailed = false;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final state = widget.state;
    final gate = _chatGate(state.lifecycle);
    final viewMessages = <ChatMessageViewModel>[
      for (var index = 0; index < widget.messages.length; index++)
        _messageView(widget.messages[index], index),
    ];
    final timeline = ChatTimelineViewModel(
      state: viewMessages.isEmpty
          ? ChatTimelineLoadState.empty
          : ChatTimelineLoadState.data,
      conversationId: state.groupId,
      title: state.metadata.name,
      savedMessages: false,
      securityGate: gate,
      offline: false,
      hasMoreBefore: false,
      loadingBefore: false,
      olderLoadFailed: false,
      typing: false,
      pinnedMessages: const [],
      messages: viewMessages,
    );
    final chat = Column(
      children: [
        if (state.lifecycle != GroupLifecycle.active)
          GroupLifecycleNotice(lifecycle: state.lifecycle),
        if (_sendFailed) GroupInlineError(message: strings.groupSendFailed),
        Expanded(
          child: ChatTimelineAdapter(model: timeline, onIntent: _handleIntent),
        ),
        if (_sending)
          const LinearProgressIndicator(minHeight: 2)
        else
          ChatComposerBuilder(
            key: _composerKey,
            securityGate: gate,
            offline: false,
            savedMessages: false,
            onIntent: _handleIntent,
          ),
      ],
    );
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      key: const ValueKey('group-chat-screen'),
      appBar: AppBar(
        title: InkWell(
          onTap: () => context.push('/groups/${state.groupId}/info'),
          child: Semantics(
            button: true,
            label: strings.groupInfoTitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(state.metadata.name, maxLines: 1),
                Text(
                  strings.groupMemberCount(state.activeMembers.length),
                  style: context.tokens.typography.label,
                ),
              ],
            ),
          ),
        ),
        actions: [
          // The same sheet a direct conversation opens, over the same
          // kind of list: `watchMessages` loads a group's local history
          // without a limit, so the scope this sheet states — everything
          // stored on this phone for this conversation — is true here
          // too.
          AppIconButton(
            icon: AppIcons.search,
            semanticLabel: strings.chatSearchAction,
            onPressed: () => unawaited(_search(viewMessages)),
            kind: AppButtonKind.ghost,
          ),
          AppIconButton(
            icon: AppIcons.info,
            semanticLabel: strings.groupInfoTitle,
            onPressed: () => context.push('/groups/${state.groupId}/info'),
            kind: AppButtonKind.ghost,
          ),
        ],
      ),
      body: width >= 1000
          ? Row(
              children: [
                Expanded(child: chat),
                SizedBox(
                  width: 360,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.tokens.colors.surface,
                      border: BorderDirectional(
                        start: BorderSide(color: context.tokens.colors.border),
                      ),
                    ),
                    child: GroupInfoSummary(state: state),
                  ),
                ),
              ],
            )
          : chat,
    );
  }

  Future<void> _search(List<ChatMessageViewModel> messages) =>
      showConversationSearch(
        context: context,
        messages: messages,
        onJumpToMessage: (id) => _handleIntent(JumpToMessageIntent(id)),
      );

  ChatMessageViewModel _messageView(GroupMessage message, int index) {
    final member = widget.state.member(message.senderUserId);
    final outgoing =
        message.senderUserId.toLowerCase() ==
        widget.currentUserId.toLowerCase();
    final previous = index == 0 ? null : widget.messages[index - 1];
    final next = index == widget.messages.length - 1
        ? null
        : widget.messages[index + 1];
    return ChatMessageViewModel(
      id: message.messageId,
      authorId: message.senderUserId,
      authorName: member?.displayName ?? message.senderUserId,
      outgoing: outgoing,
      kind: ChatTimelineContentKind.text,
      text: message.text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        message.createdMs,
        isUtc: true,
      ).toLocal(),
      delivery: message.localPreviewOnly
          ? ChatDeliveryViewState.localOnly
          : ChatDeliveryViewState.queued,
      firstInAuthorGroup:
          previous == null || previous.senderUserId != message.senderUserId,
      lastInAuthorGroup:
          next == null || next.senderUserId != message.senderUserId,
      edited: false,
      deleted: false,
      pinned: false,
      starred: false,
      unread: false,
      timestampSkewed: false,
      canEdit: false,
      canDeleteForEveryone: false,
    );
  }

  void _handleIntent(ChatIntent intent) {
    _composerKey.currentState?.handleIntent(intent);
    if (intent case SendTextIntent(:final text)) {
      unawaited(_send(text));
    }
  }

  Future<void> _send(String text) async {
    setState(() {
      _sending = true;
      _sendFailed = false;
    });
    final result = await widget.onSend(text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sendFailed = result is FailureResult<void>;
    });
  }
}

ChatSecurityGate _chatGate(GroupLifecycle lifecycle) => switch (lifecycle) {
  GroupLifecycle.active => ChatSecurityGate.ready,
  GroupLifecycle.removed ||
  GroupLifecycle.left => ChatSecurityGate.groupRemoved,
  GroupLifecycle.stateRecoveryRequired => ChatSecurityGate.groupQueueGap,
  GroupLifecycle.forkQuarantined ||
  GroupLifecycle.controlQuarantined => ChatSecurityGate.groupConflict,
};
