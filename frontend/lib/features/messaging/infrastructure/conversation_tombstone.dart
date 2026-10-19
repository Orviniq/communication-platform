import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/drift.dart';

/// Takes a conversation out of Chats, with what this phone kept beside its
/// messages: the draft, the unread count, and the attachment rows of its
/// messages, whose files the next sweep of the cache deletes (ADR-089 D10).
///
/// What happens to the messages is the caller's: Delete chat keeps them,
/// deleted for me, and leaving a group deletes them (ADR-096 D1). Runs inside
/// a transaction the caller owns, and is false when no conversation has
/// [conversationId].
Future<bool> tombstoneConversationInsideTransaction(
  LocalDatabase database,
  String conversationId,
) async {
  final updated =
      await (database.update(
        database.conversations,
      )..where((row) => row.conversationId.equals(conversationId))).write(
        const ConversationsCompanion(
          tombstoned: Value(true),
          unreadCount: Value(0),
          draftCiphertext: Value(null),
        ),
      );
  if (updated != 1) return false;
  await (database.delete(database.attachments)..where(
        (row) => row.messageId.isInQuery(
          database.selectOnly(database.messages)
            ..addColumns([database.messages.messageId])
            ..where(database.messages.conversationId.equals(conversationId)),
        ),
      ))
      .go();
  return true;
}
