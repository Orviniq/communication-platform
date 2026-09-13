import 'dart:typed_data';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';

enum ConversationKind { direct, group, saved }

enum MessageTransportState {
  localOnly,
  queued,
  sending,
  relayAccepted,
  partiallyAccepted,
  permanentlyFailed,
  received,

  /// Committed on this device, with no per-recipient ciphertext yet.
  ///
  /// Appended rather than ordered with the rest, because the ordinal is what is
  /// written to `messages.status` and every value before it is already on a
  /// device. It is a real state and not a synonym for [queued]: [queued] says
  /// sealed bytes are waiting for the transport, while this says the recipient
  /// set has not been resolved and nothing has been sealed at all. The
  /// difference is what the user is being told, and it is the one the timeline
  /// has always had a word for and never been able to reach.
  preparing,
}

enum MessageReceiptState { none, delivered, read }

enum MessageTimestampState { plausible, skewed }

enum PresenceMeaning { offline, socketOnline }

final class ConversationSummary {
  const ConversationSummary({
    required this.conversationId,
    required this.kind,
    required this.peerUserId,
    required this.lastMessage,
    required this.lastActivityMs,
    required this.unreadCount,
    required this.mutedUntil,
    required this.draft,
    required this.pinnedMessageIds,
    this.pinned = false,
    this.displayTitle,
  });

  final String conversationId;
  final ConversationKind kind;
  final String? peerUserId;
  final String? lastMessage;
  final int lastActivityMs;
  final int unreadCount;
  final DateTime? mutedUntil;
  final String? draft;
  final Set<String> pinnedMessageIds;
  final bool pinned;
  final String? displayTitle;

  bool isMutedAt(DateTime now) =>
      mutedUntil != null && mutedUntil!.isAfter(now);
}

final class MessageReaction {
  const MessageReaction({required this.reactingUserId, required this.emoji});

  final String reactingUserId;
  final String emoji;
}

final class ConversationMessage {
  const ConversationMessage({
    required this.messageId,
    required this.conversationId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.text,
    this.attachments = const [],
    this.attachmentStates = const [],
    required this.replyToMessageId,
    required this.quoteFallback,
    required this.createdMs,
    required this.orderingMs,
    this.orderingEventId = '',
    required this.timestampState,
    required this.revision,
    required this.edited,
    required this.deletedForEveryone,
    required this.deletedForMe,
    required this.pinned,
    this.starred = false,
    required this.unread,
    required this.transportState,
    required this.receiptState,
    required this.reactions,
  });

  final String messageId;
  final String conversationId;
  final String senderUserId;
  final String senderDeviceId;
  final String? text;
  final List<EncryptedAttachmentDescriptor> attachments;
  final List<AttachmentTransferState> attachmentStates;
  final String? replyToMessageId;
  final String? quoteFallback;
  final int createdMs;
  final int orderingMs;

  /// The second component of the ordering key, carried so that a message can
  /// name its own position in the timeline's total order without a second read.
  final String orderingEventId;
  final MessageTimestampState timestampState;
  final int revision;
  final bool edited;
  final bool deletedForEveryone;
  final bool deletedForMe;
  final bool pinned;
  final bool starred;
  final bool unread;
  final MessageTransportState transportState;
  final MessageReceiptState receiptState;
  final List<MessageReaction> reactions;
}

/// One message's position in the timeline's total order.
///
/// The three columns the timeline sorts by, in that order, which is what makes
/// a window a range rather than a count. Ordering is by `orderingMs`, then
/// `orderingEventId`, then `messageId`; the last two are tie-breaks that exist
/// because two devices can stamp the same millisecond and the order still has
/// to be the same on both of them.
final class ConversationMessageCursor
    implements Comparable<ConversationMessageCursor> {
  const ConversationMessageCursor({
    required this.orderingMs,
    required this.orderingEventId,
    required this.messageId,
  });

  final int orderingMs;
  final String orderingEventId;
  final String messageId;

  @override
  int compareTo(ConversationMessageCursor other) {
    final byTime = orderingMs.compareTo(other.orderingMs);
    if (byTime != 0) return byTime;
    final byEvent = orderingEventId.compareTo(other.orderingEventId);
    if (byEvent != 0) return byEvent;
    return messageId.compareTo(other.messageId);
  }

  @override
  bool operator ==(Object other) =>
      other is ConversationMessageCursor &&
      other.orderingMs == orderingMs &&
      other.orderingEventId == orderingEventId &&
      other.messageId == messageId;

  @override
  int get hashCode => Object.hash(orderingMs, orderingEventId, messageId);

  @override
  String toString() =>
      'ConversationMessageCursor($orderingMs, $orderingEventId, $messageId)';
}

/// How much of a conversation the timeline is asking for.
///
/// Deliberately not an offset and not a page number. [NewestConversationMessages]
/// is the first read, before anything is known; every read after it is
/// [ConversationMessagesFrom], an open-ended range anchored at the oldest
/// message already on screen. Anchoring at the bottom rather than counting from
/// the top is what lets a message arriving at the top join the window without
/// pushing the message the user is reading out of the other end of it.
sealed class ConversationMessageWindow {
  const ConversationMessageWindow();
}

final class NewestConversationMessages extends ConversationMessageWindow {
  const NewestConversationMessages(this.count);

  final int count;

  @override
  bool operator ==(Object other) =>
      other is NewestConversationMessages && other.count == count;

  @override
  int get hashCode => count.hashCode;
}

final class ConversationMessagesFrom extends ConversationMessageWindow {
  const ConversationMessagesFrom(this.oldest);

  final ConversationMessageCursor oldest;

  @override
  bool operator ==(Object other) =>
      other is ConversationMessagesFrom && other.oldest == oldest;

  @override
  int get hashCode => oldest.hashCode;
}

/// One emission of a windowed conversation.
///
/// [messages] is oldest-first, the order the timeline renders in. [pinned] is
/// not a subset of it: pins are a small, complete set for the whole
/// conversation, because the surface that lists them counts them too and a
/// banner that says three while the sheet behind it lists one is not a narrower
/// answer, it is a wrong one.
final class ConversationMessagePage {
  const ConversationMessagePage({
    required this.messages,
    required this.pinned,
    required this.hasMoreBefore,
  });

  static const empty = ConversationMessagePage(
    messages: [],
    pinned: [],
    hasMoreBefore: false,
  );

  final List<ConversationMessage> messages;
  final List<ConversationMessage> pinned;

  /// Whether this conversation holds anything older than [oldest].
  final bool hasMoreBefore;

  /// The lower bound of this window, or null when it holds nothing.
  ConversationMessageCursor? get oldest => messages.isEmpty
      ? null
      : ConversationMessageCursor(
          orderingMs: messages.first.orderingMs,
          orderingEventId: messages.first.orderingEventId,
          messageId: messages.first.messageId,
        );
}

sealed class ConversationTarget {
  const ConversationTarget();
}

final class DirectConversationTarget extends ConversationTarget {
  const DirectConversationTarget(this.peerUserId);

  final String peerUserId;
}

final class SavedConversationTarget extends ConversationTarget {
  const SavedConversationTarget();
}

/// A group this device already holds. Its identifier is the conversation
/// identifier every member's events carry.
final class GroupConversationTarget extends ConversationTarget {
  const GroupConversationTarget(this.groupId);

  final String groupId;
}

final class ResolvedApplicationConversation {
  const ResolvedApplicationConversation({
    required this.kind,
    required this.peerUserId,
  });

  final ConversationKind kind;
  final String? peerUserId;
}

final class SendMessageOutcome {
  SendMessageOutcome({
    required Uint8List eventId,
    required Uint8List conversationId,
    required this.transportState,
  }) : eventId = Uint8List.fromList(eventId),
       conversationId = Uint8List.fromList(conversationId);

  final Uint8List eventId;
  final Uint8List conversationId;
  final MessageTransportState transportState;
}

final class PendingDeliveredReceipt {
  const PendingDeliveredReceipt({
    required this.messageId,
    required this.conversationId,
    required this.targetUserId,
    required this.localDeviceId,
  });

  final String messageId;
  final String conversationId;
  final String targetUserId;
  final String localDeviceId;
}

final class TypingProjection {
  const TypingProjection({
    required this.conversationId,
    required this.userId,
    required this.deviceId,
    required this.expiresAt,
  });

  final String conversationId;
  final String userId;
  final String deviceId;
  final DateTime expiresAt;
}

final class PresenceProjection {
  const PresenceProjection({
    required this.userId,
    required this.onlineDeviceCount,
  });

  final String userId;
  final int onlineDeviceCount;

  PresenceMeaning get meaning => onlineDeviceCount > 0
      ? PresenceMeaning.socketOnline
      : PresenceMeaning.offline;
}
