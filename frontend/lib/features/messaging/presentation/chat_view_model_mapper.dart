import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:flutter/foundation.dart';

abstract final class ChatViewModelMapper {
  /// Maps a peer's trust state onto the composer's gate.
  ///
  /// [resolved] separates "this contact has no verified identity" from "the
  /// contact projection has not arrived yet". Both leave [state] null, but only
  /// the first is a finding worth showing the user: reporting the second as
  /// unverified makes every chat open on a security warning that clears itself
  /// a moment later.
  static ChatSecurityGate securityGate(
    ContactTrustState? state, {
    bool resolved = true,
  }) => resolved
      ? switch (state) {
          ContactTrustState.verified => ChatSecurityGate.ready,
          null => ChatSecurityGate.unverifiedIdentity,
          ContactTrustState.unverified ||
          ContactTrustState.identityUnavailable =>
            ChatSecurityGate.unverifiedIdentity,
          ContactTrustState.invalidDevice => ChatSecurityGate.unverifiedDevice,
          ContactTrustState.masterKeyChanged =>
            ChatSecurityGate.masterKeyChanged,
          ContactTrustState.deviceLogFork => ChatSecurityGate.deviceLogFork,
        }
      : ChatSecurityGate.checking;

  static List<ChatListItemViewModel> summaries(
    List<ConversationSummary> summaries, {
    required DateTime now,
    required String savedMessagesTitle,
    required String Function(String peerUserId) peerTitle,
  }) {
    final items = [
      for (final summary in summaries)
        ChatListItemViewModel(
          conversationId: summary.conversationId,
          title: summary.kind == ConversationKind.saved
              ? savedMessagesTitle
              : summary.kind == ConversationKind.group
              ? summary.displayTitle ?? summary.conversationId
              : summary.peerUserId == null
              ? summary.conversationId
              : peerTitle(summary.peerUserId!),
          preview: summary.lastMessage ?? '',
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            summary.lastActivityMs,
            isUtc: true,
          ).toLocal(),
          unreadCount: summary.kind == ConversationKind.saved
              ? 0
              : summary.unreadCount,
          muted: summary.isMutedAt(now),
          pinned: summary.pinned,
          savedMessages: summary.kind == ConversationKind.saved,
          peerUserId: summary.peerUserId,
          group: summary.kind == ConversationKind.group,
        ),
    ];
    items.sort((left, right) {
      if (left.pinned != right.pinned) return left.pinned ? -1 : 1;
      return right.timestamp.compareTo(left.timestamp);
    });
    return List.unmodifiable(items);
  }

  /// Maps a whole page, deriving every element.
  ///
  /// The one-shot form, for a caller that has no page to compare against — a
  /// test, or a surface that renders a list once. A screen that re-renders the
  /// same conversation should hold a [ChatMessageProjection] instead: this
  /// allocates a fresh view model for every message on every call, and the
  /// timeline's rows follow the identity of those objects.
  static List<ChatMessageViewModel> messages(
    List<ConversationMessage> source, {
    required String currentUserId,
    required String currentUserName,
    required String peerName,
  }) => ChatMessageProjection().map(
    source,
    currentUserId: currentUserId,
    currentUserName: currentUserName,
    peerName: peerName,
  );

  /// One message, derived against the names its author and the author of the
  /// message it replies to have now.
  ///
  /// [group] applies the rules of a group (ADR-090): a message shows as sent
  /// only once none of its copies is owed, Edit is not offered (ADR-096 D8),
  /// and Pin waits for the member roles of the signed roster. Delete for
  /// everyone is offered on an own message, as in a direct chat (ADR-096 D4).
  static ChatMessageViewModel _message(
    ConversationMessage message, {
    required ConversationMessage? previous,
    required ConversationMessage? next,
    required ConversationMessage? reply,
    required String currentUserId,
    required String authorName,
    required String? replyAuthor,
    required bool group,
  }) {
    final outgoing =
        message.senderUserId.toLowerCase() == currentUserId.toLowerCase();
    final groupedWithPrevious = _grouped(previous, message);
    final groupedWithNext = _grouped(message, next);
    final reactionCounts = <String, int>{};
    final ownReactions = <String>{};
    for (final reaction in message.reactions) {
      reactionCounts.update(
        reaction.emoji,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      if (reaction.reactingUserId.toLowerCase() ==
          currentUserId.toLowerCase()) {
        ownReactions.add(reaction.emoji);
      }
    }
    return ChatMessageViewModel(
      id: message.messageId,
      authorId: message.senderUserId,
      authorName: authorName,
      outgoing: outgoing,
      kind: message.attachments.isEmpty
          ? ChatTimelineContentKind.text
          : message.attachments.every((attachment) => attachment.isInlineImage)
          ? ChatTimelineContentKind.image
          : ChatTimelineContentKind.attachment,
      text: message.text,
      attachments: message.attachments,
      attachmentStates: message.attachmentStates,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        message.createdMs,
        isUtc: true,
      ).toLocal(),
      delivery: _delivery(message, group: group),
      firstInAuthorGroup: !groupedWithPrevious,
      lastInAuthorGroup: !groupedWithNext,
      edited: message.edited,
      deleted: message.deletedForEveryone || message.deletedForMe,
      pinned: message.pinned,
      starred: message.starred,
      unread: !outgoing && message.unread,
      timestampSkewed: message.timestampState == MessageTimestampState.skewed,
      canEdit: !group && outgoing && !message.deletedForEveryone,
      // A group member deletes an own message for everyone (ADR-096 D4).
      canDeleteForEveryone: outgoing && !message.deletedForEveryone,
      canPin: !group,
      replyToMessageId: message.replyToMessageId,
      replyAuthor: replyAuthor,
      replyQuote: _quoteOf(reply) ?? message.quoteFallback,
      reactions: [
        for (final entry in reactionCounts.entries)
          ChatReactionViewModel(
            emoji: entry.key,
            count: entry.value,
            selectedByCurrentUser: ownReactions.contains(entry.key),
          ),
      ],
    );
  }

  /// What a reply quotes of [reply]: its text, or, for an attachment message
  /// with no caption, the name of its first attachment, which would otherwise
  /// quote nothing at all.
  static String? _quoteOf(ConversationMessage? reply) {
    if (reply == null) return null;
    final text = reply.text;
    if ((text == null || text.trim().isEmpty) && reply.attachments.isNotEmpty) {
      return reply.attachments.first.displayName;
    }
    return text;
  }

  static bool _grouped(
    ConversationMessage? first,
    ConversationMessage? second,
  ) {
    if (first == null || second == null) return false;
    return first.senderUserId == second.senderUserId &&
        (second.orderingMs - first.orderingMs).abs() <=
            const Duration(minutes: 5).inMilliseconds;
  }

  static ChatDeliveryViewState _delivery(
    ConversationMessage message, {
    required bool group,
  }) {
    if (message.transportState == MessageTransportState.received) {
      return ChatDeliveryViewState.received;
    }
    if (message.transportState == MessageTransportState.permanentlyFailed) {
      return ChatDeliveryViewState.failed;
    }
    // One member's read is enough for two ticks in a group, also while copies
    // for the others are owed; only a failure, which Retry answers, outranks
    // it (ADR-091 D1).
    if (message.receiptState == MessageReceiptState.read) {
      return ChatDeliveryViewState.read;
    }
    // A group sends no delivered receipt, and a delivered state there has no
    // mark of its own: the transport decides (ADR-091 D2).
    if (!group && message.receiptState == MessageReceiptState.delivered) {
      return ChatDeliveryViewState.delivered;
    }
    return switch (message.transportState) {
      MessageTransportState.localOnly => ChatDeliveryViewState.localOnly,
      // The one state this timeline has always had a word for and never been
      // able to reach: the message is committed and nothing is sealed yet.
      MessageTransportState.preparing => ChatDeliveryViewState.encrypting,
      MessageTransportState.queued => ChatDeliveryViewState.queued,
      MessageTransportState.sending => ChatDeliveryViewState.sending,
      // A group message is one copy for each device of each member, and it
      // is sent only once none of them is owed (ADR-075, ADR-088). A fan-out
      // the server has accepted part of is still on its way.
      MessageTransportState.partiallyAccepted when group =>
        ChatDeliveryViewState.sending,
      MessageTransportState.relayAccepted ||
      MessageTransportState.partiallyAccepted => ChatDeliveryViewState.accepted,
      MessageTransportState.permanentlyFailed => ChatDeliveryViewState.failed,
      MessageTransportState.received => ChatDeliveryViewState.received,
    };
  }
}

/// One open conversation's messages, re-derived only where they changed.
///
/// A page arrives from local storage as freshly allocated rows on every
/// emission, whatever changed in it — so mapping it produced a fresh view model
/// for every message, and the timeline, which follows the identity of those
/// objects, rebuilt every row it had mounted. One receipt landing cost the
/// whole window twice over: once to derive it and once to draw it.
///
/// This holds the last page it mapped and returns the *same* view model
/// instance for every message whose projection cannot have changed. What is
/// left to derive is the messages that actually moved — and the neighbours of
/// the ones that did, because grouping is positional.
///
/// It is bounded by construction: each call keeps only the entries the page it
/// was handed still names, so the cache is never larger than the window.
final class ChatMessageProjection {
  var _memoized = <String, _MemoizedMessage>{};
  String? _currentUserId;
  String? _currentUserName;
  String? _peerName;
  bool? _group;
  var _derivations = 0;

  /// How many elements this projection has derived since it was created.
  ///
  /// The number the cost tests assert on. A page that changed in one place
  /// must move this by the size of that change and not by the size of the page.
  @visibleForTesting
  int get derivations => _derivations;

  /// A direct conversation, or Saved Messages: every author that is not the
  /// current user is [peerName].
  List<ChatMessageViewModel> map(
    List<ConversationMessage> source, {
    required String currentUserId,
    required String currentUserName,
    required String peerName,
  }) {
    // The three names every element is derived against. A contact projection
    // arriving renames every author at once, and nothing memoized under the
    // old name is still true.
    _reset(
      currentUserId: currentUserId,
      currentUserName: currentUserName,
      peerName: peerName,
      group: false,
    );
    return _project(
      source,
      currentUserId: currentUserId,
      currentUserName: currentUserName,
      memberName: (_) => peerName,
      group: false,
    );
  }

  /// A group (ADR-090): each author that is not the current user is named by
  /// [memberName], and the rules of a group apply.
  ///
  /// A rename does not clear what is memoized. Each element remembers the
  /// names it was derived with, so a member who changes their display name
  /// re-derives their own messages and the replies that quote them, and no
  /// other.
  List<ChatMessageViewModel> mapGroup(
    List<ConversationMessage> source, {
    required String currentUserId,
    required String currentUserName,
    required String Function(String userId) memberName,
  }) {
    _reset(
      currentUserId: currentUserId,
      currentUserName: currentUserName,
      peerName: null,
      group: true,
    );
    return _project(
      source,
      currentUserId: currentUserId,
      currentUserName: currentUserName,
      memberName: memberName,
      group: true,
    );
  }

  void _reset({
    required String currentUserId,
    required String currentUserName,
    required String? peerName,
    required bool group,
  }) {
    if (_currentUserId != currentUserId ||
        _currentUserName != currentUserName ||
        _peerName != peerName ||
        _group != group) {
      _memoized = {};
      _currentUserId = currentUserId;
      _currentUserName = currentUserName;
      _peerName = peerName;
      _group = group;
    }
  }

  List<ChatMessageViewModel> _project(
    List<ConversationMessage> source, {
    required String currentUserId,
    required String currentUserName,
    required String Function(String userId) memberName,
    required bool group,
  }) {
    final currentUser = currentUserId.toLowerCase();
    String nameOf(String userId) => userId.toLowerCase() == currentUser
        ? currentUserName
        : memberName(userId);
    // Built only for a page that holds a reply, and then only once. It is the
    // one index the derivation needs, and a page of a long conversation is
    // usually a page nobody replied inside.
    Map<String, ConversationMessage>? byId;
    final views = <ChatMessageViewModel>[];
    for (var index = 0; index < source.length; index++) {
      final message = source[index];
      final previous = index == 0 ? null : source[index - 1];
      final next = index == source.length - 1 ? null : source[index + 1];
      if (message.replyToMessageId != null && byId == null) {
        byId = {for (final message in source) message.messageId: message};
      }
      final reply = message.replyToMessageId == null
          ? null
          : byId![message.replyToMessageId];
      final groupedWithPrevious = ChatViewModelMapper._grouped(
        previous,
        message,
      );
      final groupedWithNext = ChatViewModelMapper._grouped(message, next);
      final authorName = nameOf(message.senderUserId);
      final replyAuthor = reply == null ? null : nameOf(reply.senderUserId);
      final memoized = _memoized[message.messageId];
      if (memoized != null &&
          memoized.describes(
            message,
            groupedWithPrevious: groupedWithPrevious,
            groupedWithNext: groupedWithNext,
            reply: reply,
            authorName: authorName,
            replyAuthor: replyAuthor,
          )) {
        views.add(memoized.view);
        continue;
      }
      _derivations += 1;
      final view = ChatViewModelMapper._message(
        message,
        previous: previous,
        next: next,
        reply: reply,
        currentUserId: currentUserId,
        authorName: authorName,
        replyAuthor: replyAuthor,
        group: group,
      );
      _memoized[message.messageId] = _MemoizedMessage(
        source: message,
        groupedWithPrevious: groupedWithPrevious,
        groupedWithNext: groupedWithNext,
        reply: reply,
        view: view,
      );
      views.add(view);
    }
    // Every id in the page now has an entry, so anything beyond the page's own
    // length is a message that has left the window. Rebuilding the map is the
    // only way to find those, and the common emission — one more message at
    // the newest end — is not one of them.
    if (_memoized.length != source.length) {
      _memoized = {
        for (final message in source)
          message.messageId: _memoized[message.messageId]!,
      };
    }
    return List.unmodifiable(views);
  }
}

/// One message's view model and the exact inputs it was derived from.
final class _MemoizedMessage {
  _MemoizedMessage({
    required this.source,
    required this.groupedWithPrevious,
    required this.groupedWithNext,
    required ConversationMessage? reply,
    required this.view,
  }) : replyAuthorId = reply?.senderUserId,
       replyText = reply?.text;

  final ConversationMessage source;
  final bool groupedWithPrevious;
  final bool groupedWithNext;

  /// What the message being replied to contributed, rather than the message
  /// itself. A quote is re-read from its target on every derivation, so an
  /// edit to the target has to invalidate the quote that shows it.
  final String? replyAuthorId;
  final String? replyText;
  final ChatMessageViewModel view;

  /// The names, as well as the message, are inputs: in a group each author
  /// has a name of their own, which a roster change can rename.
  bool describes(
    ConversationMessage message, {
    required bool groupedWithPrevious,
    required bool groupedWithNext,
    required ConversationMessage? reply,
    required String authorName,
    required String? replyAuthor,
  }) =>
      this.groupedWithPrevious == groupedWithPrevious &&
      this.groupedWithNext == groupedWithNext &&
      replyAuthorId == reply?.senderUserId &&
      replyText == reply?.text &&
      view.authorName == authorName &&
      view.replyAuthor == replyAuthor &&
      _sameMessage(source, message);
}

/// Whether two reads of local storage describe the same message.
///
/// Every field of [ConversationMessage] is compared, not only the ones the view
/// model happens to read today: the question this answers is "is this the same
/// row", which stays true when somebody adds a field and starts drawing it.
/// Getting it wrong in the permissive direction is the one failure that would
/// be silent, so it errs the other way — an attachment list whose descriptors
/// cannot be compared is reported as changed rather than as equal.
bool _sameMessage(ConversationMessage left, ConversationMessage right) =>
    identical(left, right) ||
    (left.messageId == right.messageId &&
        left.conversationId == right.conversationId &&
        left.senderUserId == right.senderUserId &&
        left.senderDeviceId == right.senderDeviceId &&
        left.text == right.text &&
        left.replyToMessageId == right.replyToMessageId &&
        left.quoteFallback == right.quoteFallback &&
        left.createdMs == right.createdMs &&
        left.orderingMs == right.orderingMs &&
        left.orderingEventId == right.orderingEventId &&
        left.timestampState == right.timestampState &&
        left.revision == right.revision &&
        left.edited == right.edited &&
        left.deletedForEveryone == right.deletedForEveryone &&
        left.deletedForMe == right.deletedForMe &&
        left.pinned == right.pinned &&
        left.starred == right.starred &&
        left.unread == right.unread &&
        left.transportState == right.transportState &&
        left.receiptState == right.receiptState &&
        _sameReactions(left.reactions, right.reactions) &&
        _sameAttachmentStates(left.attachmentStates, right.attachmentStates) &&
        _sameAttachments(left.attachments, right.attachments));

bool _sameReactions(List<MessageReaction> left, List<MessageReaction> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index].reactingUserId != right[index].reactingUserId ||
        left[index].emoji != right[index].emoji) {
      return false;
    }
  }
  return true;
}

bool _sameAttachmentStates(
  List<AttachmentTransferState> left,
  List<AttachmentTransferState> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Two attachment lists, compared by capability.
///
/// A capability names one immutable stored object, and the descriptor around it
/// is decoded from bytes written beside the message — so the same capability in
/// the same position is the same descriptor. What does change under a stable
/// capability is the transfer state, which is a separate list and is compared
/// element by element.
bool _sameAttachments(
  List<EncryptedAttachmentDescriptor> left,
  List<EncryptedAttachmentDescriptor> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!identical(left[index], right[index]) &&
        left[index].capabilityId != right[index].capabilityId) {
      return false;
    }
  }
  return true;
}
