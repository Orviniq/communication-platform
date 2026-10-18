import 'dart:async';

import 'package:communication_platform/app/dependencies/group_member_name_providers.dart';
import 'package:communication_platform/app/dependencies/group_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_sheet.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/presentation/group_callbacks.dart';
import 'package:communication_platform/features/groups/presentation/group_components.dart';
import 'package:communication_platform/features/groups/presentation/group_member_labels.dart';
import 'package:communication_platform/features/messaging/application/conversation_timeline.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_composer_builder.dart';
import 'package:communication_platform/features/messaging/presentation/chat_forward.dart';
import 'package:communication_platform/features/messaging/presentation/chat_message_readers.dart';
import 'package:communication_platform/features/messaging/presentation/chat_timeline_adapter.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_model_mapper.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/conversation_search.dart';
import 'package:communication_platform/features/messaging/presentation/visible_conversation.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    this.onReaction,
    this.watchReaders,
    this.injectedMemberNames,
    super.key,
  });

  final String groupId;
  final GroupState? injectedState;

  /// The names an injected page shows, as the contacts store would hand them
  /// to the routed page. Null: this phone names nobody.
  final GroupMemberNames? injectedMemberNames;

  /// The messages an injected page shows, as local storage would hand them to
  /// the routed page: the same rows go through the same projection.
  final List<ConversationMessage>? injectedMessages;
  final String? currentUserId;
  final SendGroupMessageCallback? onSend;
  final RetryGroupMessageCallback? onRetry;
  final SetGroupReactionCallback? onReaction;

  /// What an injected page reads of who read a message. Null: no reader row.
  final WatchGroupMessageReadersCallback? watchReaders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (injectedState != null && injectedMessages != null && onSend != null) {
      return GroupChatView(
        state: injectedState!,
        memberNames: injectedMemberNames ?? const GroupMemberNames.empty(),
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
        onReaction: onReaction,
        watchReaders: watchReaders,
      );
    }
    final auth = ref.watch(authenticationControllerProvider);
    final userId = currentUserId ?? auth.userId;
    if (userId == null) return groupErrorPage(context);
    return _GroupChatSession(
      key: ValueKey(userId),
      groupId: groupId,
      currentUserId: userId,
    );
  }
}

/// The routed group chat: one group, read and written as this account.
///
/// Owns what a direct chat's page owns (ADR-090 D5, D6): the group's place in
/// the registry of what is on screen, the marking of its messages read, and
/// the local state of its messages and its draft.
class _GroupChatSession extends ConsumerStatefulWidget {
  const _GroupChatSession({
    required this.groupId,
    required this.currentUserId,
    super.key,
  });

  final String groupId;
  final String currentUserId;

  @override
  ConsumerState<_GroupChatSession> createState() => _GroupChatSessionState();
}

class _GroupChatSessionState extends ConsumerState<_GroupChatSession> {
  VisibleConversationReadMarker? _readMarker;

  /// The last names the contacts store answered with. Null until the first
  /// answer.
  GroupMemberNames? _memberNames;

  /// The group's own conversation, read as a direct chat reads its own
  /// (ADR-090 D1): the conversation id of a group is the group id.
  ConversationMessagesRequest get _request =>
      (currentUserId: widget.currentUserId, conversationId: widget.groupId);

  @override
  void initState() {
    super.initState();
    // Subscribed and not watched, as in a direct chat: the forward picker
    // reads the list at the moment it opens, and nothing else here draws it.
    ref.listenManual(
      conversationSummariesProvider(widget.currentUserId),
      (_, _) {},
    );
    _localStateSubscription = ref.listenManual(
      manageLocalConversationStateProvider.future,
      (_, _) {},
    );
    _readMarker = VisibleConversationReadMarker(
      registry: ref.read(visibleConversationProvider),
      conversationId: widget.groupId,
      markRead: _markRead,
    );
    // After the first frame, once the scope built below has told the registry
    // that this group is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _readMarker?.start());
    // A message that lands in the group the user is looking at has been read
    // by them.
    ref.listenManual(conversationMessagesProvider(_request), (_, next) {
      final page = next.value?.page;
      if (page != null && page.messages.any((message) => message.unread)) {
        _readMarker?.notify();
      }
    });
  }

  @override
  void dispose() {
    _readMarker?.dispose();
    _readMarker = null;
    super.dispose();
  }

  /// Clears the group's unread state on this phone, as a direct chat does, and
  /// tells the sender of each message read that it was read (ADR-091).
  Future<void> _markRead() async {
    try {
      final deviceId = await ref.read(currentMessagingDeviceIdProvider.future);
      final markRead = await ref.read(
        markConversationVisiblyReadProvider((
          userId: widget.currentUserId,
          deviceId: deviceId,
        )).future,
      );
      await markRead(
        currentUserId: widget.currentUserId,
        currentDeviceId: deviceId,
        conversationId: widget.groupId,
        allowReadReceipts: await _mayReportReads(),
      );
    } on Object {
      // Reading a screen is not a place to raise a failure, and the next time
      // the group becomes visible this runs again.
    }
  }

  /// Whether a read here is reported to the senders: only while this account
  /// may send into the group. A group it left, or one waiting for its state,
  /// is read on this phone alone.
  Future<bool> _mayReportReads() async {
    try {
      final group = await ref.read(groupProvider(widget.groupId).future);
      return group != null &&
          GroupAuthorization.allows(
            group,
            widget.currentUserId,
            GroupPermission.sendMessages,
          );
    } on Object {
      return false;
    }
  }

  /// The local state of the group's messages and draft.
  ///
  /// A subscription rather than a `ref.read`, because the composer writes its
  /// draft as it leaves the tree, and by then this element is deactivated and
  /// `ref.read` can no longer find the provider scope above it. The
  /// subscription reads its container directly until this state is disposed,
  /// which is after the composer.
  late final ProviderSubscription<Future<ManageLocalConversationState>>
  _localStateSubscription;

  Future<ManageLocalConversationState> _localState() =>
      _localStateSubscription.read();

  /// The readers of one message of this group, from local storage. Opened
  /// when a message sheet asks, and only for the sender of that message.
  Stream<List<MessageReader>> _watchReaders(String messageId) =>
      Stream.fromFuture(
        ref.read(conversationRepositoryProvider.future),
      ).asyncExpand((repository) => repository.watchMessageReaders(messageId));

  @override
  Widget build(BuildContext context) {
    final groupId = widget.groupId;
    final userId = widget.currentUserId;
    final group = ref.watch(groupProvider(groupId));
    final messages = ref.watch(conversationMessagesProvider(_request));
    final device = ref.watch(currentMessagingDeviceIdProvider);
    final useCases = ref.watch(groupUseCasesProvider);
    final draft = ref.watch(conversationDraftProvider(groupId)).value;
    Future<ConversationTimelineWindow> window() =>
        ref.read(conversationTimelineWindowProvider(_request).future);
    final page = group.when(
      loading: () => groupLoadingPage(context),
      error: (_, _) => groupErrorPage(context),
      data: (state) {
        if (state == null) return groupErrorPage(context);
        final names = ref.watch(
          groupMemberNamesProvider(
            GroupMemberNamesRequest(
              state.members.map((member) => member.userId),
            ),
          ),
        );
        // The roster changing makes a new request, and the answer to it takes
        // a moment: the names of the last answer stay until it comes, so the
        // composer is not replaced by a spinner while someone is added.
        final answered = names.value;
        if (answered != null) _memberNames = answered;
        // A failed read names nobody: every member is "Unknown member",
        // which is true, and the chat stays usable.
        if (names.hasError) _memberNames ??= const GroupMemberNames.empty();
        final memberNames = _memberNames;
        if (memberNames == null) return groupLoadingPage(context);
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
                memberNames: memberNames,
                timeline: timeline,
                currentUserId: userId,
                initialDraft: draft,
                onSend: (text, {replyToMessageId, quoteFallback}) =>
                    resolved.sendMessage(
                      groupId: groupId,
                      senderUserId: userId,
                      senderDeviceId: deviceId,
                      text: text,
                      replyToMessageId: replyToMessageId,
                      quoteFallback: quoteFallback,
                    ),
                onRetry: (messageId, text, {replyToMessageId, quoteFallback}) =>
                    resolved.retryMessage(
                      groupId: groupId,
                      senderUserId: userId,
                      senderDeviceId: deviceId,
                      messageId: messageId,
                      text: text,
                      replyToMessageId: replyToMessageId,
                      quoteFallback: quoteFallback,
                    ),
                onReaction: (messageId, emoji) => resolved.setReaction(
                  groupId: groupId,
                  senderUserId: userId,
                  senderDeviceId: deviceId,
                  messageId: messageId,
                  emoji: emoji,
                ),
                onSaveDraft: (text) async => (await _localState()).saveDraft(
                  conversationId: groupId,
                  text: text,
                ),
                onStar: (messageId, starred) async => (await _localState())
                    .setStar(messageId: messageId, starred: starred),
                onDeleteForMe: (messageId) async =>
                    (await _localState()).deleteForMe(messageId),
                forwardTargets: () => chatForwardTargets(
                  ref,
                  currentUserId: userId,
                  conversationId: groupId,
                  savedMessages: false,
                  strings: AppLocalizations.of(context),
                ),
                onForward: (message, targets) => forwardChatMessage(
                  ref,
                  currentUserId: userId,
                  message: message,
                  targets: targets,
                ),
                onLoadOlder: () async => (await window()).loadOlder(),
                onReveal: (messageId) async =>
                    (await window()).reveal(messageId),
                watchReaders: _watchReaders,
              ),
            ),
          ),
        );
      },
    );
    // The alert layer reads this, so it does not announce a message into the
    // group the user is looking at.
    return VisibleConversationScope(
      registry: ref.watch(visibleConversationProvider),
      conversationId: groupId,
      child: page,
    );
  }
}

class GroupChatView extends StatefulWidget {
  const GroupChatView({
    required this.state,
    required this.memberNames,
    required this.timeline,
    required this.currentUserId,
    required this.onSend,
    this.onRetry,
    this.onReaction,
    this.initialDraft,
    this.onSaveDraft,
    this.onStar,
    this.onDeleteForMe,
    this.forwardTargets,
    this.onForward,
    this.onLoadOlder,
    this.onReveal,
    this.watchReaders,
    super.key,
  });

  final GroupState state;

  /// What this phone calls each member. The group holds user ids and roles
  /// only.
  final GroupMemberNames memberNames;
  final ConversationTimelineState timeline;
  final String currentUserId;
  final SendGroupMessageCallback onSend;

  /// Null where the view has no retry path: a retry is then reported as
  /// failed, never as made.
  final RetryGroupMessageCallback? onRetry;

  /// Null where the view has no reaction path: a reaction is then reported as
  /// failed, never as made.
  final SetGroupReactionCallback? onReaction;

  /// The draft the composer was left with, read once when the group opens.
  final String? initialDraft;

  /// Null where the view keeps no draft.
  final SaveGroupDraftCallback? onSaveDraft;

  /// Null where the view has no local state: a star or a delete for me is
  /// then reported as failed, never as made.
  final SetGroupStarCallback? onStar;
  final DeleteGroupMessageForMeCallback? onDeleteForMe;

  /// Where a forward may go, resolved when the picker opens: every other
  /// conversation and Saved Messages.
  final ValueGetter<List<ChatListItemViewModel>>? forwardTargets;

  /// Null where the view has no forward path: a forward is then reported as
  /// failed, never as made.
  final ForwardGroupMessageCallback? onForward;

  /// Opens the window further back, for the timeline's older-messages marker.
  final Future<void> Function()? onLoadOlder;

  /// Opens the window far enough back to hold a message, for a jump to it.
  final Future<void> Function(String messageId)? onReveal;

  /// Follows who read one message. Null where the view has no reader list:
  /// the message sheet then shows no reader row.
  final WatchGroupMessageReadersCallback? watchReaders;

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

  /// One for the life of the page: the scope that hands it to the bubbles
  /// compares it by identity, and an open sheet follows it. It reads the
  /// members from the widget as they are when an answer arrives.
  ChatMessageReaders? _readers;

  ChatMessageReaders? get _readersOrNull {
    if (widget.watchReaders == null) return null;
    return _readers ??= _GroupMessageReaders(
      source: (messageId) =>
          widget.watchReaders?.call(messageId) ?? const Stream.empty(),
      memberOf: (userId) => widget.state.member(userId),
      nameOf: (userId) => widget.memberNames.labelOf(userId, _strings),
    );
  }

  /// For the reader list, which words a name when an answer arrives and has
  /// no context of its own.
  late AppLocalizations _strings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _strings = AppLocalizations.of(context);
  }

  /// The message a search result or a reply quote asked for. The timeline
  /// scrolls and pulses when this changes, and every tap makes a new request.
  ChatJumpRequest? _jump;
  var _jumpSerial = 0;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final state = widget.state;
    final gate = _chatGate(state.lifecycle);
    final viewMessages = _projection.mapGroup(
      widget.timeline.page.messages,
      currentUserId: widget.currentUserId,
      currentUserName: strings.chatYouAuthor,
      memberName: (userId) => widget.memberNames.labelOf(userId, strings),
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
      jump: _jump,
    );
    final readers = _readersOrNull;
    final timelineView = ChatTimelineAdapter(
      model: timeline,
      onIntent: _handleIntent,
    );
    final chat = Column(
      children: [
        if (state.lifecycle != GroupLifecycle.active)
          GroupLifecycleNotice(lifecycle: state.lifecycle),
        if (_sendFailed) GroupInlineError(message: strings.groupSendFailed),
        if (_retryFailed)
          GroupInlineError(message: strings.chatActionFailedMessage),
        Expanded(
          // The sheet of an own message reads who read it from here.
          child: readers == null
              ? timelineView
              : ChatReadersScope(readers: readers, child: timelineView),
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
          initialDraft: widget.initialDraft,
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
    if (intent case SendTextIntent(
      :final text,
      :final replyToMessageId,
      :final quoteFallback,
    )) {
      unawaited(_send(text, replyToMessageId, quoteFallback));
    } else if (intent case RetryMessageIntent(:final message)) {
      unawaited(_retry(message));
    } else if (intent case SetReactionIntent(:final messageId, :final emoji)) {
      unawaited(_react(messageId, emoji));
    } else if (intent case CopyMessageIntent(:final text)) {
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    } else if (intent case SetStarIntent(:final messageId, :final starred)) {
      unawaited(_local(widget.onStar?.call(messageId, starred)));
    } else if (intent case DeleteForMeIntent(:final messageId)) {
      unawaited(_local(widget.onDeleteForMe?.call(messageId)));
    } else if (intent case SaveDraftIntent(:final text)) {
      // Also sent as the composer leaves the tree, so nothing here may touch
      // this view's state. A draft that cannot be written says nothing, as in
      // a direct chat.
      unawaited(widget.onSaveDraft?.call(text));
    } else if (intent case ForwardMessageIntent(:final message)) {
      unawaited(_showForwardPicker(message));
    } else if (intent is LoadOlderMessagesIntent) {
      unawaited(widget.onLoadOlder?.call());
    } else if (intent case JumpToMessageIntent(:final messageId)) {
      // A search result or a reply quote. The window opens far enough back to
      // hold the message, and the timeline jumps once it is there.
      setState(() => _jump = ChatJumpRequest(messageId, ++_jumpSerial));
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

  Future<void> _send(
    String text,
    String? replyToMessageId,
    String? quoteFallback,
  ) async {
    setState(() => _sendFailed = false);
    final result = await widget.onSend(
      text,
      replyToMessageId: replyToMessageId,
      quoteFallback: quoteFallback,
    );
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
    final result = await onRetry(
      message.id,
      message.text ?? '',
      replyToMessageId: message.replyToMessageId,
      quoteFallback: message.replyQuote,
    );
    if (!mounted) return;
    setState(() => _retryFailed = result is FailureResult<void>);
  }

  /// Sets or, with a null [emoji], removes this user's reaction.
  Future<void> _react(String messageId, String? emoji) =>
      _local(widget.onReaction?.call(messageId, emoji));

  /// The shared picker, over every other conversation. An attachment message
  /// lists no group, because a group sends no attachment (ADR-089 D1).
  Future<void> _showForwardPicker(ChatMessageViewModel message) =>
      showChatForwardPicker(
        context: context,
        message: message,
        targets:
            widget.forwardTargets?.call() ?? const <ChatListItemViewModel>[],
        onForward: (targets) {
          final onForward = widget.onForward;
          unawaited(_local(onForward?.call(message, targets)));
        },
      );

  /// Waits for an action the user asked for, and says so when it was refused,
  /// in the words a direct chat uses for a refused action. A null [action]
  /// is one this view has no path for, which is a refusal too.
  Future<void> _local(Future<Result<void>>? action) async {
    final Result<void> result =
        await action ??
        const Result.failure(
          ValidationFailure(ValidationFailureKind.invalidInput),
        );
    if (!mounted || result is! FailureResult<void>) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).chatActionFailedMessage),
      ),
    );
  }
}

/// The readers of a group's messages, named as the timeline names the authors.
final class _GroupMessageReaders implements ChatMessageReaders {
  const _GroupMessageReaders({
    required this.source,
    required this.memberOf,
    required this.nameOf,
  });

  final WatchGroupMessageReadersCallback source;
  final GroupMember? Function(String userId) memberOf;

  /// What this phone calls a member: never blank, never the user id.
  final String Function(String userId) nameOf;

  @override
  Stream<List<ChatMessageReader>> watch(String messageId) =>
      source(messageId).map(
        (readers) => [
          for (final reader in readers)
            ChatMessageReader(
              userId: reader.userId,
              name: nameOf(reader.userId),
              // The seed Group Info gives the same member.
              avatarSeed: groupAvatarSeed(
                memberOf(reader.userId)?.userId ?? reader.userId,
              ),
              readAt: switch (reader.readAtMs) {
                final ms? => DateTime.fromMillisecondsSinceEpoch(
                  ms,
                  isUtc: true,
                ).toLocal(),
                null => null,
              },
            ),
        ],
      );
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
