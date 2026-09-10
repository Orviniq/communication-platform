import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/attachments/presentation/attachment_sheet.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_conversation_view.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_model_mapper.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/visible_conversation.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DirectChatPage extends ConsumerWidget {
  const DirectChatPage({
    required this.peerUserId,
    this.conversationId,
    this.injectedModel,
    this.onIntent,
    super.key,
  });

  final String peerUserId;
  final String? conversationId;
  final ChatTimelineViewModel? injectedModel;
  final ChatIntentCallback? onIntent;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ConversationBoundary(
    peerUserId: peerUserId,
    conversationId: conversationId,
    savedMessages: false,
    injectedModel: injectedModel,
    onIntent: onIntent,
  );
}

class SavedMessagesPage extends ConsumerWidget {
  const SavedMessagesPage({
    this.conversationId,
    this.injectedModel,
    this.onIntent,
    super.key,
  });

  final String? conversationId;
  final ChatTimelineViewModel? injectedModel;
  final ChatIntentCallback? onIntent;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ConversationBoundary(
    conversationId: conversationId,
    savedMessages: true,
    injectedModel: injectedModel,
    onIntent: onIntent,
  );
}

class _ConversationBoundary extends ConsumerWidget {
  const _ConversationBoundary({
    required this.savedMessages,
    this.peerUserId,
    this.conversationId,
    this.injectedModel,
    this.onIntent,
  });

  final bool savedMessages;
  final String? peerUserId;
  final String? conversationId;
  final ChatTimelineViewModel? injectedModel;
  final ChatIntentCallback? onIntent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (injectedModel case final model?) {
      return ChatConversationView(
        model: model,
        onIntent: onIntent ?? (_) {},
        peerUserId: peerUserId,
      );
    }
    final auth = ref.watch(authenticationControllerProvider);
    final currentUserId = auth.userId;
    if (currentUserId == null) {
      return _ConversationFailurePage(savedMessages: savedMessages);
    }
    final identity = conversationId == null
        ? ref.watch(
            conversationIdentityProvider((
              currentUserId: currentUserId,
              peerUserId: peerUserId,
              savedMessages: savedMessages,
            )),
          )
        : AsyncValue.data(conversationId!);
    return identity.when(
      data: (id) => _ProjectedConversationPage(
        currentUserId: currentUserId,
        conversationId: id,
        peerUserId: peerUserId,
        savedMessages: savedMessages,
        offline: auth.access == AuthenticationRouteAccess.offlineFullScope,
      ),
      loading: () => _ConversationLoadingPage(savedMessages: savedMessages),
      error: (_, _) => _ConversationFailurePage(savedMessages: savedMessages),
    );
  }
}

class _ProjectedConversationPage extends ConsumerStatefulWidget {
  const _ProjectedConversationPage({
    required this.currentUserId,
    required this.conversationId,
    required this.peerUserId,
    required this.savedMessages,
    required this.offline,
  });

  final String currentUserId;
  final String conversationId;
  final String? peerUserId;
  final bool savedMessages;
  final bool offline;

  @override
  ConsumerState<_ProjectedConversationPage> createState() =>
      _ProjectedConversationPageState();
}

class _ProjectedConversationPageState
    extends ConsumerState<_ProjectedConversationPage> {
  /// The two projections this page draws through, one per list.
  ///
  /// They live for as long as the conversation is open, which is what makes
  /// them worth anything: the page they are handed on the next emission is
  /// mostly the page they were handed on this one, and what they return for
  /// the unchanged part of it is the same objects, which is what stops the
  /// timeline redrawing rows nothing happened to.
  final ChatMessageProjection _timelineProjection = ChatMessageProjection();
  final ChatMessageProjection _pinnedProjection = ChatMessageProjection();

  /// Reading, as distinct from opening. Owned here rather than by the view
  /// because this is the layer that resolved a conversation identity, and the
  /// same layer that registers the identity as on screen.
  VisibleConversationReadMarker? _readMarker;

  @override
  void initState() {
    super.initState();
    // Subscribed, and deliberately not watched. The forward sheet is the only
    // thing on this screen that reads the conversation list, it reads it at
    // the moment it opens, and watching it here is what put a draft write —
    // which touches the `conversations` row — on a path back to a rebuild of
    // this page and a re-derivation of the whole window.
    ref.listenManual(
      conversationSummariesProvider(widget.currentUserId),
      (_, _) {},
    );
    _readMarker = VisibleConversationReadMarker(
      registry: ref.read(visibleConversationProvider),
      conversationId: widget.conversationId,
      markRead: _markRead,
    );
    // After the first frame, because the scope that tells the registry this
    // conversation is on screen is created in `build`, and until it has run
    // the registry is still naming whatever was on screen before.
    WidgetsBinding.instance.addPostFrameCallback((_) => _readMarker?.start());
    // A message that lands in the conversation the user is looking at has been
    // read by them. Only the window is inspected, which is all this needs to
    // decide: anything unread outside it is cleared by the same call.
    ref.listenManual(
      conversationMessagesProvider((
        currentUserId: widget.currentUserId,
        conversationId: widget.conversationId,
      )),
      (_, next) {
        final page = next.value?.page;
        if (page != null && page.messages.any((message) => message.unread)) {
          _readMarker?.notify();
        }
      },
    );
  }

  @override
  void dispose() {
    _readMarker?.dispose();
    _readMarker = null;
    super.dispose();
  }

  /// Clears this conversation's unread state, silently.
  ///
  /// Silence is the point: this runs because the user looked at a screen, not
  /// because they asked for anything, and storage that cannot be written to
  /// has nothing to say to them here. The unread state simply stays, and the
  /// next time the conversation becomes visible this runs again.
  Future<void> _markRead() async {
    final manager = await ref.read(manageLocalConversationStateProvider.future);
    await manager.markRead(widget.conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final peerUserId = widget.peerUserId;
    final conversationId = widget.conversationId;
    final savedMessages = widget.savedMessages;
    final contact = peerUserId == null
        ? const AsyncValue<ContactProjection?>.data(null)
        : ref.watch(contactProvider(peerUserId));
    final peerName =
        contact.value?.presentationName ??
        (peerUserId == null
            ? strings.savedMessagesTitle
            : chatShortIdentity(peerUserId));
    final messages = ref.watch(
      conversationMessagesProvider((
        currentUserId: widget.currentUserId,
        conversationId: conversationId,
      )),
    );
    // Narrowed to the one bit of it the header draws. The projection list is
    // rebuilt on every typing heartbeat and its identity changes with it;
    // whether anybody is typing does not.
    final typing = ref.watch(
      typingProjectionsProvider(
        conversationId,
      ).select((projections) => projections.value?.isNotEmpty ?? false),
    );
    final draft = ref.watch(conversationDraftProvider(conversationId)).value;
    // One gate for every load state. The projection is only allowed to speak
    // about trust once it has an answer to give: a first read that is still in
    // flight has neither a value nor an error, and reading that as "unverified"
    // opened every conversation on a security warning that cleared itself.
    // An error resolves closed, through the null branch of the mapper.
    final securityGate = savedMessages
        ? ChatSecurityGate.ready
        : ChatViewModelMapper.securityGate(
            contact.value?.trustState,
            resolved: contact.hasValue || contact.hasError,
          );
    final model = messages.when(
      data: (timeline) => ChatTimelineViewModel(
        state: timeline.page.messages.isEmpty
            ? ChatTimelineLoadState.empty
            : ChatTimelineLoadState.data,
        conversationId: conversationId,
        title: savedMessages ? strings.savedMessagesTitle : peerName,
        savedMessages: savedMessages,
        securityGate: securityGate,
        offline: widget.offline,
        hasMoreBefore: timeline.page.hasMoreBefore,
        loadingBefore: timeline.loadingBefore,
        olderLoadFailed: timeline.olderLoadFailed,
        typing: typing,
        pinnedMessages: _pinnedProjection.map(
          timeline.page.pinned,
          currentUserId: widget.currentUserId,
          currentUserName: strings.chatYouAuthor,
          peerName: peerName,
        ),
        messages: _timelineProjection.map(
          timeline.page.messages,
          currentUserId: widget.currentUserId,
          currentUserName: strings.chatYouAuthor,
          peerName: peerName,
        ),
      ),
      loading: () => ChatTimelineViewModel(
        state: ChatTimelineLoadState.loading,
        conversationId: conversationId,
        title: savedMessages ? strings.savedMessagesTitle : peerName,
        savedMessages: savedMessages,
        securityGate: securityGate,
        offline: widget.offline,
        hasMoreBefore: false,
        loadingBefore: false,
        olderLoadFailed: false,
        typing: false,
        pinnedMessages: const [],
        messages: const [],
      ),
      error: (_, _) => ChatTimelineViewModel(
        state: ChatTimelineLoadState.error,
        conversationId: conversationId,
        title: savedMessages ? strings.savedMessagesTitle : peerName,
        savedMessages: savedMessages,
        securityGate: securityGate,
        offline: widget.offline,
        hasMoreBefore: false,
        loadingBefore: false,
        olderLoadFailed: false,
        typing: false,
        pinnedMessages: const [],
        messages: const [],
        errorCode: 'local_history_unavailable',
      ),
    );
    // Registering visibility here rather than inside the view keeps it tied to
    // the route that actually resolved a conversation identity, and to the
    // identity it resolved. A message arriving into the conversation on screen
    // has already made the user aware of itself; the alert path reads this so
    // it does not announce what they are looking at.
    return VisibleConversationScope(
      registry: ref.watch(visibleConversationProvider),
      conversationId: conversationId,
      child: ChatConversationView(
        model: model,
        peerUserId: peerUserId,
        initialDraft: draft,
        forwardTargets: () => _forwardTargets(strings),
        onIntent: (intent) => _dispatch(context, intent),
      ),
    );
  }

  /// Where a message may be forwarded to, resolved when the sheet asks.
  ///
  /// It was a list mapped and re-identified on every build of this page, for a
  /// sheet almost every build never opens — every conversation on the device
  /// mapped again to draw one conversation's timeline.
  List<ChatListItemViewModel> _forwardTargets(AppLocalizations strings) {
    final summaries =
        ref.read(conversationSummariesProvider(widget.currentUserId)).value ??
        const <ConversationSummary>[];
    final targets = ChatViewModelMapper.summaries(
      summaries,
      now: DateTime.now(),
      savedMessagesTitle: strings.savedMessagesTitle,
      peerTitle: chatShortIdentity,
    ).where((item) => item.conversationId != widget.conversationId).toList();
    if (!widget.savedMessages &&
        !targets.any((target) => target.savedMessages)) {
      targets.insert(
        0,
        ChatListItemViewModel(
          conversationId: '',
          title: strings.savedMessagesTitle,
          preview: '',
          timestamp: DateTime.fromMillisecondsSinceEpoch(0),
          unreadCount: 0,
          muted: false,
          pinned: false,
          savedMessages: true,
          peerUserId: null,
        ),
      );
    }
    return targets;
  }

  Future<void> _dispatch(BuildContext context, ChatIntent intent) async {
    final conversationId = widget.conversationId;
    final currentUserId = widget.currentUserId;
    final savedMessages = widget.savedMessages;
    final peerUserId = widget.peerUserId;
    if (intent case CopyMessageIntent(:final text)) {
      await Clipboard.setData(ClipboardData(text: text));
      return;
    }
    if (intent case SaveDraftIntent(:final text)) {
      final manager = await ref.read(
        manageLocalConversationStateProvider.future,
      );
      await manager.saveDraft(conversationId: conversationId, text: text);
      return;
    }
    if (intent is ClearConversationHistoryIntent) {
      final manager = await ref.read(
        manageLocalConversationStateProvider.future,
      );
      await manager.deleteConversationForMe(conversationId);
      return;
    }
    if (intent case OpenAttachmentIntent(:final attachment)) {
      if (context.mounted) {
        await showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (_) => AttachmentSheet(descriptor: attachment),
        );
      }
      return;
    }
    if (intent is LoadOlderMessagesIntent) {
      final window = await ref.read(
        conversationTimelineWindowProvider((
          currentUserId: currentUserId,
          conversationId: conversationId,
        )).future,
      );
      await window.loadOlder();
      return;
    }
    if (intent case JumpToMessageIntent(:final messageId)) {
      // A jump can name a message older than anything loaded — a search hit, a
      // reply quote, or the oldest pin in the thread. The window opens far
      // enough back to contain it, and the timeline jumps when it arrives.
      final window = await ref.read(
        conversationTimelineWindowProvider((
          currentUserId: currentUserId,
          conversationId: conversationId,
        )).future,
      );
      await window.reveal(messageId);
      return;
    }
    if (intent is ReplyToMessageIntent ||
        intent is BeginEditMessageIntent ||
        intent is ForwardMessageIntent) {
      return;
    }
    final deviceId = await ref.read(currentMessagingDeviceIdProvider.future);
    if (!context.mounted) return;
    final sender = await ref.read(
      sendConversationEventsProvider((
        userId: currentUserId,
        deviceId: deviceId,
      )).future,
    );
    Result<void>? result;
    switch (intent) {
      case SendTextIntent(
        :final text,
        :final replyToMessageId,
        :final quoteFallback,
      ):
        final sent = await sender.sendText(
          currentUserId: currentUserId,
          currentDeviceId: deviceId,
          target: savedMessages
              ? const SavedConversationTarget()
              : DirectConversationTarget(peerUserId!),
          text: text,
          replyToMessageId: replyToMessageId,
          quoteFallback: quoteFallback,
        );
        result = sent.fold(
          onSuccess: (_) => const Result.success(null),
          onFailure: Result.failure,
        );
      case EditMessageIntent(:final messageId, :final text):
        result = await sender.editMessage(
          currentUserId: currentUserId,
          currentDeviceId: deviceId,
          conversationId: conversationId,
          messageId: messageId,
          replacementText: text,
        );
      case SetReactionIntent(:final messageId, :final emoji):
        result = await sender.setReaction(
          currentUserId: currentUserId,
          currentDeviceId: deviceId,
          conversationId: conversationId,
          messageId: messageId,
          emoji: emoji,
        );
      case SetPinIntent(:final messageId, :final pinned):
        result = await sender.setPin(
          currentUserId: currentUserId,
          currentDeviceId: deviceId,
          conversationId: conversationId,
          messageId: messageId,
          pinned: pinned,
        );
      case DeleteForMeIntent(:final messageId):
        final manager = await ref.read(
          manageLocalConversationStateProvider.future,
        );
        result = await manager.deleteForMe(messageId);
      case SetStarIntent(:final messageId, :final starred):
        final manager = await ref.read(
          manageLocalConversationStateProvider.future,
        );
        result = await manager.setStar(messageId: messageId, starred: starred);
      case DeleteForEveryoneIntent(:final messageId):
        result = await sender.deleteForEveryone(
          currentUserId: currentUserId,
          currentDeviceId: deviceId,
          conversationId: conversationId,
          messageId: messageId,
        );
      case RetryMessageIntent(:final message):
        result = await sender.retrySend(
          currentUserId: currentUserId,
          currentDeviceId: deviceId,
          target: savedMessages
              ? const SavedConversationTarget()
              : DirectConversationTarget(peerUserId!),
          messageId: message.id,
          text: message.text ?? '',
          replyToMessageId: message.replyToMessageId,
          quoteFallback: message.replyQuote,
        );
      case ForwardToConversationsIntent(:final message, :final targets):
        if (message.text == null || message.text!.trim().isEmpty) {
          result = const Result.failure(
            ValidationFailure(ValidationFailureKind.invalidInput),
          );
          break;
        }
        for (final target in targets) {
          final sent = await sender.sendText(
            currentUserId: currentUserId,
            currentDeviceId: deviceId,
            target: target.savedMessages
                ? const SavedConversationTarget()
                : DirectConversationTarget(target.peerUserId!),
            text: message.text!,
            quoteFallback: message.replyQuote,
          );
          if (sent case FailureResult(failure: final failure)) {
            result = Result.failure(failure);
            break;
          }
        }
        result ??= const Result.success(null);
      default:
        break;
    }
    if (result case FailureResult()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).chatActionFailedMessage),
          ),
        );
      }
    }
  }
}

class _ConversationLoadingPage extends StatelessWidget {
  const _ConversationLoadingPage({required this.savedMessages});

  final bool savedMessages;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        savedMessages
            ? AppLocalizations.of(context).savedMessagesTitle
            : AppLocalizations.of(context).chatTitle,
      ),
    ),
    body: AppStatePanel.loading(
      title: AppLocalizations.of(context).chatHistoryLoading,
    ),
  );
}

class _ConversationFailurePage extends StatelessWidget {
  const _ConversationFailurePage({required this.savedMessages});

  final bool savedMessages;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        savedMessages
            ? AppLocalizations.of(context).savedMessagesTitle
            : AppLocalizations.of(context).chatTitle,
      ),
    ),
    body: AppStatePanel.error(
      title: AppLocalizations.of(context).chatHistoryErrorTitle,
      message: AppLocalizations.of(context).chatHistoryErrorMessage,
    ),
  );
}
