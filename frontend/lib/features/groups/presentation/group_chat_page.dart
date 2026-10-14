import 'dart:async';

import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_sheet.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_components.dart';
import 'package:communication_platform/features/messaging/application/conversation_timeline.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_composer_builder.dart';
import 'package:communication_platform/features/messaging/presentation/chat_timeline_adapter.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_model_mapper.dart';
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
    this.onRetry,
    super.key,
  });

  final String groupId;
  final GroupState? injectedState;

  /// The messages an injected page shows, as local storage would hand them to
  /// the routed page: the same rows go through the same projection.
  final List<ConversationMessage>? injectedMessages;
  final String? currentUserId;
  final SendGroupMessageCallback? onSend;
  final RetryGroupMessageCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (injectedState != null && injectedMessages != null && onSend != null) {
      return GroupChatView(
        state: injectedState!,
        timeline: ConversationTimelineState(
          page: ConversationMessagePage(
            messages: injectedMessages!,
            pinned: const [],
            hasMoreBefore: false,
          ),
          loadingBefore: false,
          olderLoadFailed: false,
        ),
        currentUserId: currentUserId ?? injectedState!.members.first.userId,
        onSend: onSend!,
        onRetry: onRetry,
      );
    }
    final auth = ref.watch(authenticationControllerProvider);
    final userId = currentUserId ?? auth.userId;
    if (userId == null) return groupErrorPage(context);
    final group = ref.watch(groupProvider(groupId));
    // The group's own conversation, read as a direct chat reads its own
    // (ADR-090 D1): the conversation id of a group is the group id.
    final request = (currentUserId: userId, conversationId: groupId);
    final messages = ref.watch(conversationMessagesProvider(request));
    final device = ref.watch(currentMessagingDeviceIdProvider);
    final useCases = ref.watch(groupUseCasesProvider);
    Future<ConversationTimelineWindow> window() =>
        ref.read(conversationTimelineWindowProvider(request).future);
    return group.when(
      loading: () => groupLoadingPage(context),
      error: (_, _) => groupErrorPage(context),
      data: (state) {
        if (state == null) return groupErrorPage(context);
        return messages.when(
          loading: () => groupLoadingPage(context),
          error: (_, _) => groupErrorPage(context),
          data: (timeline) => device.when(
            loading: () => groupLoadingPage(context),
            error: (_, _) => groupErrorPage(context),
            data: (deviceId) => useCases.when(
              loading: () => groupLoadingPage(context),
              error: (_, _) => groupErrorPage(context),
              data: (resolved) => GroupChatView(
                state: state,
                timeline: timeline,
                currentUserId: userId,
                onSend: (text) => resolved.sendMessage(
                  groupId: groupId,
                  senderUserId: userId,
                  senderDeviceId: deviceId,
                  text: text,
                ),
                onRetry: (messageId, text) => resolved.retryMessage(
                  groupId: groupId,
                  senderUserId: userId,
                  senderDeviceId: deviceId,
                  messageId: messageId,
                  text: text,
                ),
                onLoadOlder: () async => (await window()).loadOlder(),
                onReveal: (messageId) async =>
                    (await window()).reveal(messageId),
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
    required this.timeline,
    required this.currentUserId,
    required this.onSend,
    this.onRetry,
    this.onLoadOlder,
    this.onReveal,
    super.key,
  });

  final GroupState state;
  final ConversationTimelineState timeline;
  final String currentUserId;
  final SendGroupMessageCallback onSend;

  /// Null where the view has no retry path: a retry is then reported as
  /// failed, never as made.
  final RetryGroupMessageCallback? onRetry;

  /// Opens the window further back, for the timeline's older-messages marker.
  final Future<void> Function()? onLoadOlder;

  /// Opens the window far enough back to hold a message, for a jump to it.
  final Future<void> Function(String messageId)? onReveal;

  @override
  State<GroupChatView> createState() => _GroupChatViewState();
}

class _GroupChatViewState extends State<GroupChatView> {
  final _composerKey = GlobalKey<ChatComposerBuilderState>();

  /// One for the life of the page, as a direct chat holds its own: what it
  /// returns for the messages that did not change is the same objects, which
  /// is what keeps the timeline from redrawing rows nothing happened to.
  final _projection = ChatMessageProjection();
  var _sendFailed = false;
  var _retryFailed = false;

  /// The message a search result or a reply quote asked for. The timeline
  /// scrolls when this changes.
  String? _highlightedMessageId;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final state = widget.state;
    final gate = _chatGate(state.lifecycle);
    final names = {
      for (final member in state.members) member.userId: member.displayName,
    };
    final viewMessages = _projection.mapGroup(
      widget.timeline.page.messages,
      currentUserId: widget.currentUserId,
      currentUserName: strings.chatYouAuthor,
      memberName: (userId) =>
          names[userId.toLowerCase()] ?? chatShortIdentity(userId),
    );
    final timeline = ChatTimelineViewModel(
      state: viewMessages.isEmpty
          ? ChatTimelineLoadState.empty
          : ChatTimelineLoadState.data,
      conversationId: state.groupId,
      title: state.metadata.name,
      savedMessages: false,
      securityGate: gate,
      offline: false,
      hasMoreBefore: widget.timeline.page.hasMoreBefore,
      loadingBefore: widget.timeline.loadingBefore,
      olderLoadFailed: widget.timeline.olderLoadFailed,
      typing: false,
      // A pin needs the member roles of the signed roster, which a group
      // does not read yet (ADR-090 D4).
      pinnedMessages: const [],
      messages: viewMessages,
      highlightedMessageId: _highlightedMessageId,
    );
    final chat = Column(
      children: [
        if (state.lifecycle != GroupLifecycle.active)
          GroupLifecycleNotice(lifecycle: state.lifecycle),
        if (_sendFailed) GroupInlineError(message: strings.groupSendFailed),
        if (_retryFailed)
          GroupInlineError(message: strings.chatActionFailedMessage),
        Expanded(
          child: ChatTimelineAdapter(model: timeline, onIntent: _handleIntent),
        ),
        // Always in the tree, as in a direct conversation. A send only queues
        // the message, and the timeline shows it the moment it is written, so
        // the composer has nothing to wait for. A field that left the tree
        // while a send ran took the keyboard with it.
        ChatComposerBuilder(
          key: _composerKey,
          securityGate: gate,
          offline: false,
          savedMessages: false,
          attachments: ChatAttachmentAvailability.notBuilt,
          onIntent: _handleIntent,
        ),
      ],
    );
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      key: const ValueKey('group-chat-screen'),
      appBar: AppBar(
        // The back button's slot is wider than the button, so the free span
        // starts inside the slot. A negative spacing starts the title there;
        // the header gives the width back at its end (`_GroupChatHeader`).
        titleSpacing: -_buttonSlotInset,
        title: _GroupChatHeader(
          state: state,
          onOpenInfo: () => context.push('/groups/${state.groupId}/info'),
        ),
        actions: [
          // The same sheet a direct conversation opens, over the same
          // list: the messages of the window this page has loaded.
          AppIconButton(
            icon: AppIcons.search,
            semanticLabel: strings.chatSearchAction,
            onPressed: () => unawaited(_search(viewMessages)),
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

  void _handleIntent(ChatIntent intent) {
    _composerKey.currentState?.handleIntent(intent);
    if (intent case SendTextIntent(:final text)) {
      unawaited(_send(text));
    } else if (intent case RetryMessageIntent(:final message)) {
      unawaited(_retry(message));
    } else if (intent is LoadOlderMessagesIntent) {
      unawaited(widget.onLoadOlder?.call());
    } else if (intent case JumpToMessageIntent(:final messageId)) {
      // A search result or a reply quote. The window opens far enough back to
      // hold the message, and the timeline jumps once it is there.
      setState(() => _highlightedMessageId = messageId);
      unawaited(widget.onReveal?.call(messageId));
    } else if (intent is OpenAttachmentIntent) {
      // A group chat sends no attachment in this phase, and its paperclip
      // says so rather than doing nothing (ADR-089 D1).
      unawaited(
        showAppSheet<void>(
          context: context,
          semanticLabel: AppLocalizations.of(context).chatAttachAction,
          child: const AttachmentSheet.notBuilt(),
        ),
      );
    }
  }

  Future<void> _send(String text) async {
    setState(() => _sendFailed = false);
    final result = await widget.onSend(text);
    if (!mounted) return;
    // Only a failure is recorded. Sends can overlap now, and one that went
    // through says nothing about another that was refused.
    if (result is FailureResult<void>) setState(() => _sendFailed = true);
  }

  /// Sends a failed message again, as the same message: its id and its text.
  Future<void> _retry(ChatMessageViewModel message) async {
    if (message.delivery != ChatDeliveryViewState.failed) return;
    final onRetry = widget.onRetry;
    if (onRetry == null) {
      // No retry path: a retry this view cannot make is never shown as made.
      setState(() => _retryFailed = true);
      return;
    }
    setState(() => _retryFailed = false);
    final result = await onRetry(message.id, message.text ?? '');
    if (!mounted) return;
    setState(() => _retryFailed = result is FailureResult<void>);
  }
}

/// What the 56 px slot of a 48 px bar button leaves on each side of it.
const _buttonSlotInset = (kToolbarHeight - AppFocus.minimumTarget) / 2;

/// The top bar's title: the group's avatar, name and member count, and one
/// target that opens Group Info.
///
/// The target is the whole bar between the back button and Search, and as high
/// as the bar, so a thumb needs no aim. The header used to be the `Column` of
/// two lines inside an `InkWell`, which shrank to its text: 108 by 44 px for
/// a short name at 360 px wide, with a dead gap beside it.
///
/// The bar starts the title `_buttonSlotInset` before the free span (see the
/// `titleSpacing` above), and lays it out that much wider, so the end padding
/// here is what stops the target at Search instead of under it.
///
/// One semantics node carries the tap, so a screen reader finds one control
/// and reads the name once. The avatar's own label is left out for that, and
/// so is the tap action of the `InkWell` with it (`excludeSemantics` drops the
/// action of a tappable child), which the node therefore carries itself.
class _GroupChatHeader extends StatelessWidget {
  const _GroupChatHeader({required this.state, required this.onOpenInfo});

  final GroupState state;
  final VoidCallback onOpenInfo;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final name = state.metadata.name;
    final members = strings.groupMemberCount(state.activeMembers.length);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: _buttonSlotInset),
      child: Semantics(
        button: true,
        label: '$name, $members',
        hint: strings.groupInfoTitle,
        onTap: onOpenInfo,
        excludeSemantics: true,
        child: InkWell(
          onTap: onOpenInfo,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kToolbarHeight),
            child: Row(
              children: [
                ContactAvatar(
                  username: name,
                  semanticLabel: name,
                  authenticatedSeed: groupAvatarSeed(state.groupId),
                  radius: 20,
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        members,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.tokens.typography.label,
                      ),
                    ],
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

ChatSecurityGate _chatGate(GroupLifecycle lifecycle) => switch (lifecycle) {
  GroupLifecycle.active => ChatSecurityGate.ready,
  GroupLifecycle.removed ||
  GroupLifecycle.left => ChatSecurityGate.groupRemoved,
  GroupLifecycle.stateRecoveryRequired => ChatSecurityGate.groupQueueGap,
  GroupLifecycle.forkQuarantined ||
  GroupLifecycle.controlQuarantined => ChatSecurityGate.groupConflict,
};
