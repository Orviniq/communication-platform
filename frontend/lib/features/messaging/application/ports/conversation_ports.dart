import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';

abstract interface class ConversationRepositoryPort implements RepositoryPort {
  Stream<List<ConversationSummary>> watchConversations(String currentUserId);

  /// One bounded page of a conversation, re-emitted whenever it changes.
  ///
  /// The window is a range and not a count, so a message arriving at the top
  /// joins the page without displacing the one at the bottom. Every emission
  /// costs the same number of statements whatever the conversation's length.
  Stream<ConversationMessagePage> watchMessages({
    required String currentUserId,
    required String conversationId,
    required ConversationMessageWindow window,
  });

  /// The key [count] messages older than [before], for the next page.
  ///
  /// Null when nothing older exists. This reads [count] keys and stops, which
  /// is what makes paging backwards cost the page rather than everything
  /// skipped to reach it.
  Future<Result<ConversationMessageCursor?>> olderMessageCursor({
    required String conversationId,
    required ConversationMessageCursor before,
    required int count,
  });

  /// Where [messageId] sits in the conversation's order, or null if it is gone.
  ///
  /// This is what makes a jump to something outside the loaded window resolve
  /// instead of doing nothing: the target's key says how far back the window
  /// has to open.
  Future<Result<ConversationMessageCursor?>> messageCursor({
    required String conversationId,
    required String messageId,
  });

  Future<Result<int>> reserveSenderCounter(String deviceId);

  Future<Result<int>> nextEditRevision({
    required String messageId,
    required String senderUserId,
  });

  Future<Result<void>> requireOriginalSender({
    required String messageId,
    required String senderUserId,
  });

  Future<Result<ConversationSummary?>> readConversation(String conversationId);

  Future<Result<void>> saveDraft({
    required String conversationId,
    required String? text,
  });

  Future<Result<void>> setMutedUntil({
    required String conversationId,
    required DateTime? mutedUntil,
  });

  Future<Result<void>> setConversationPinned({
    required String conversationId,
    required bool pinned,
  });

  Future<Result<void>> deleteForMe(String messageId);

  Future<Result<void>> setStar({
    required String messageId,
    required bool starred,
  });

  Future<Result<void>> deleteConversationForMe(String conversationId);

  Future<Result<List<String>>> markConversationRead(String conversationId);

  Future<Result<void>> markConversationUnread({
    required String conversationId,
    required String currentUserId,
  });

  Future<Result<List<PendingDeliveredReceipt>>> readPendingDeliveredReceipts({
    required int limit,
  });

  Future<Result<void>> completePendingDeliveredReceipts({
    required String localDeviceId,
    required List<String> messageIds,
  });
}

abstract interface class ApplicationConversationResolverPort implements Port {
  Future<Result<ResolvedApplicationConversation>> resolve({
    required ApplicationEventRecord event,
    required String currentUserId,
  });
}

/// Admits application events into group conversations.
abstract interface class GroupConversationMembershipPort implements Port {
  /// Succeeds when [senderUserId] is an active member of the group [groupId]
  /// names and [currentUserId] is one too. A group, or a member, this device
  /// has not been told about yet is asked for, and the event is refused for
  /// now.
  Future<Result<void>> authorizeGroupEvent({
    required String groupId,
    required String senderUserId,
    required String currentUserId,
  });
}

abstract interface class ApplicationFanoutPort implements Port {
  /// Commits the event locally, and records that its recipients are still owed.
  ///
  /// Returning does not mean anything has been encrypted for anybody. It means
  /// the event is durable, the timeline can see it, and a durable record exists
  /// of the fan-out the delivery cycle now owes it. Everything that needs the
  /// network happens against that record.
  Future<Result<void>> commitLocalEcho({
    required String operationId,
    required String eventId,
    required String currentUserId,
    required String currentDeviceId,
    required String peerUserId,
    required Uint8List openedPayload,
    required ApplicationEventCommit applicationEvent,
  });

  /// Re-arms a send that failed, and answers whether there was one to re-arm.
  Future<Result<bool>> retryFailedSend(String operationId);
}

abstract interface class VolatileConversationStatePort implements Port {
  Stream<List<TypingProjection>> watchTyping(String conversationId);

  Stream<PresenceProjection> watchPresence(String userId);

  void applyTyping({
    required String conversationId,
    required String userId,
    required String deviceId,
    required bool isTyping,
    required DateTime expiresAt,
    required DateTime authenticatedAt,
  });

  void applyPresence({
    required String userId,
    required String deviceId,
    required bool socketOnline,
  });

  void clearDisconnected();
}
