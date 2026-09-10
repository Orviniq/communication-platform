import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:flutter/foundation.dart';

enum ChatTimelineContentKind { text, image, attachment, system, unsupported }

enum ChatDeliveryViewState {
  localOnly,
  queued,
  encrypting,
  sending,
  accepted,
  delivered,
  read,
  failed,
  received,
}

enum ChatSecurityGate {
  /// The peer's trust state has not been read yet. Distinct from
  /// [unverifiedIdentity]: nothing is known, so nothing may be claimed. Holds
  /// the composer closed without telling the user their peer failed a check.
  checking,
  ready,
  unverifiedIdentity,
  unverifiedDevice,
  masterKeyChanged,
  deviceLogFork,
  postQuantumUnavailable,
  groupUpdating,
  groupRemoved,
  groupQueueGap,
  groupConflict,
}

enum ChatTimelineLoadState { loading, data, empty, error }

enum ChatComposerMode { compose, reply, edit }

@immutable
final class ChatReactionViewModel {
  const ChatReactionViewModel({
    required this.emoji,
    required this.count,
    required this.selectedByCurrentUser,
  });

  final String emoji;
  final int count;
  final bool selectedByCurrentUser;
}

@immutable
final class ChatMessageViewModel {
  ChatMessageViewModel({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.outgoing,
    required this.kind,
    required this.text,
    this.attachments = const [],
    this.attachmentStates = const [],
    required this.timestamp,
    required this.delivery,
    required this.firstInAuthorGroup,
    required this.lastInAuthorGroup,
    required this.edited,
    required this.deleted,
    required this.pinned,
    required this.starred,
    required this.unread,
    required this.timestampSkewed,
    required this.canEdit,
    required this.canDeleteForEveryone,
    this.replyToMessageId,
    this.replyAuthor,
    this.replyQuote,
    Iterable<ChatReactionViewModel> reactions = const [],
  }) : reactions = List.unmodifiable(reactions);

  final String id;
  final String authorId;
  final String authorName;
  final bool outgoing;
  final ChatTimelineContentKind kind;
  final String? text;
  final List<EncryptedAttachmentDescriptor> attachments;
  final List<AttachmentTransferState> attachmentStates;
  final DateTime timestamp;
  final ChatDeliveryViewState delivery;
  final bool firstInAuthorGroup;
  final bool lastInAuthorGroup;
  final bool edited;
  final bool deleted;
  final bool pinned;
  final bool starred;
  final bool unread;
  final bool timestampSkewed;
  final bool canEdit;
  final bool canDeleteForEveryone;
  final String? replyToMessageId;
  final String? replyAuthor;
  final String? replyQuote;
  final List<ChatReactionViewModel> reactions;
}

@immutable
final class ChatTimelineViewModel {
  ChatTimelineViewModel({
    required this.state,
    required this.conversationId,
    required this.title,
    required this.savedMessages,
    required this.securityGate,
    required this.offline,
    required this.hasMoreBefore,
    required this.loadingBefore,
    required this.olderLoadFailed,
    required this.typing,
    required Iterable<ChatMessageViewModel> pinnedMessages,
    required Iterable<ChatMessageViewModel> messages,
    this.errorCode,
    this.highlightedMessageId,
  }) : pinnedMessages = List.unmodifiable(pinnedMessages),
       messages = List.unmodifiable(messages);

  final ChatTimelineLoadState state;
  final String conversationId;
  final String title;
  final bool savedMessages;
  final ChatSecurityGate securityGate;
  final bool offline;
  final bool hasMoreBefore;
  final bool loadingBefore;
  final bool olderLoadFailed;
  final bool typing;

  /// Every pinned message in the conversation, not only the loaded ones.
  ///
  /// Complete rather than page-scoped because the banner counts them and the
  /// sheet lists them, and a banner reading three above a sheet listing one is
  /// a wrong answer rather than a narrower one. [messages] is the window;
  /// this is not a subset of it.
  final List<ChatMessageViewModel> pinnedMessages;
  final List<ChatMessageViewModel> messages;
  final String? errorCode;
  final String? highlightedMessageId;

  bool get composerEnabled => securityGate == ChatSecurityGate.ready;
}

@immutable
final class ChatListItemViewModel {
  const ChatListItemViewModel({
    required this.conversationId,
    required this.title,
    required this.preview,
    required this.timestamp,
    required this.unreadCount,
    required this.muted,
    required this.pinned,
    required this.savedMessages,
    required this.peerUserId,
    this.delivery,
    this.group = false,
  });

  final String conversationId;
  final String title;
  final String preview;
  final DateTime timestamp;
  final int unreadCount;
  final bool muted;
  final bool pinned;
  final bool savedMessages;
  final String? peerUserId;
  final ChatDeliveryViewState? delivery;
  final bool group;
}

/// What the delivery engine is doing, as far as a screen is allowed to say.
///
/// Content-free by construction: four states, no counts, no identifiers, no
/// timings. It exists because a jammed engine and a slow network were
/// indistinguishable from the outside — the application looked identical in
/// both cases, which is how a stall that lasted twenty-seven minutes went
/// unnoticed by the person it was happening to.
enum ChatDeliveryIndicator {
  /// Nothing to say. The session is connected and the last cycle completed.
  settled,

  /// A socket is being opened.
  connecting,

  /// A cycle is in flight.
  syncing,

  /// There is no usable connection, or the session is waiting to retry one.
  waiting,
}

@immutable
final class ChatListViewModel {
  ChatListViewModel({
    required Iterable<ChatListItemViewModel> items,
    required this.loading,
    required this.offline,
    required this.failed,
    this.delivery = ChatDeliveryIndicator.settled,
  }) : items = List.unmodifiable(items);

  final List<ChatListItemViewModel> items;
  final bool loading;
  final bool offline;
  final bool failed;
  final ChatDeliveryIndicator delivery;
}

typedef ChatIntentCallback = void Function(ChatIntent intent);

sealed class ChatIntent {
  const ChatIntent();
}

final class SendTextIntent extends ChatIntent {
  const SendTextIntent({
    required this.text,
    this.replyToMessageId,
    this.quoteFallback,
  });

  final String text;
  final String? replyToMessageId;
  final String? quoteFallback;
}

final class EditMessageIntent extends ChatIntent {
  const EditMessageIntent({required this.messageId, required this.text});

  final String messageId;
  final String text;
}

final class ReplyToMessageIntent extends ChatIntent {
  const ReplyToMessageIntent(this.message);

  final ChatMessageViewModel message;
}

final class BeginEditMessageIntent extends ChatIntent {
  const BeginEditMessageIntent(this.message);

  final ChatMessageViewModel message;
}

final class SetReactionIntent extends ChatIntent {
  const SetReactionIntent({required this.messageId, required this.emoji});

  final String messageId;
  final String? emoji;
}

final class SetPinIntent extends ChatIntent {
  const SetPinIntent({required this.messageId, required this.pinned});

  final String messageId;
  final bool pinned;
}

final class SetStarIntent extends ChatIntent {
  const SetStarIntent({required this.messageId, required this.starred});

  final String messageId;
  final bool starred;
}

final class DeleteForMeIntent extends ChatIntent {
  const DeleteForMeIntent(this.messageId);

  final String messageId;
}

final class DeleteForEveryoneIntent extends ChatIntent {
  const DeleteForEveryoneIntent(this.messageId);

  final String messageId;
}

final class RetryMessageIntent extends ChatIntent {
  const RetryMessageIntent(this.message);

  final ChatMessageViewModel message;
}

final class CopyMessageIntent extends ChatIntent {
  const CopyMessageIntent(this.text);

  final String text;
}

final class ForwardMessageIntent extends ChatIntent {
  const ForwardMessageIntent(this.message);

  final ChatMessageViewModel message;
}

final class ForwardToConversationsIntent extends ChatIntent {
  ForwardToConversationsIntent({
    required this.message,
    required Iterable<ChatListItemViewModel> targets,
  }) : targets = List.unmodifiable(targets);

  final ChatMessageViewModel message;
  final List<ChatListItemViewModel> targets;
}

final class LoadOlderMessagesIntent extends ChatIntent {
  const LoadOlderMessagesIntent();
}

final class JumpToMessageIntent extends ChatIntent {
  const JumpToMessageIntent(this.messageId);

  final String messageId;
}

final class SaveDraftIntent extends ChatIntent {
  const SaveDraftIntent(this.text);

  final String? text;
}

final class OpenAttachmentIntent extends ChatIntent {
  const OpenAttachmentIntent({this.attachment});

  final EncryptedAttachmentDescriptor? attachment;
}

/// Remove this device's copy of the whole conversation.
///
/// Dispatched only after the confirmation that states the consequence. It
/// carries no identifier: the surface that handles it already knows which
/// conversation it resolved, and a message identifier travelling through an
/// intent is one more place a caller could clear the wrong one.
final class ClearConversationHistoryIntent extends ChatIntent {
  const ClearConversationHistoryIntent();
}
