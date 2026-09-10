import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:communication_platform/features/messaging/infrastructure/memory_volatile_conversation_state.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'draft, mute, star, unread, delete, and clear remain local projections',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = DriftConversationDomainRepository(database);
      await database
          .into(database.conversations)
          .insert(
            ConversationsCompanion.insert(
              conversationId: 'conversation',
              kind: ConversationKind.direct.index,
              peerUserId: const Value('peer'),
              listProjectionCiphertext: Uint8List.fromList('preview'.codeUnits),
              sortKey: 10,
              unreadCount: const Value(1),
            ),
          );
      await database
          .into(database.messages)
          .insert(
            MessagesCompanion.insert(
              messageId: 'message',
              conversationId: 'conversation',
              currentEventId: 'event',
              projectionCiphertext: Uint8List.fromList('content'.codeUnits),
              status: MessageTransportState.received.index,
              revision: 0,
              createdAt: DateTime.utc(2026, 7, 29),
              senderUserId: const Value('peer'),
              senderDeviceId: const Value('peer-device'),
              orderingMs: const Value(10),
              orderingEventId: const Value('event'),
              unread: const Value(true),
            ),
          );
      await database
          .into(database.attachments)
          .insert(
            AttachmentsCompanion.insert(
              attachmentId: 'attachment',
              messageId: 'message',
              encryptedDescriptor: Uint8List.fromList([1]),
              transferState: 1,
              boundedCacheHandleCiphertext: Value(Uint8List.fromList([2])),
              cacheExpiresAt: Value(DateTime.utc(2026, 8)),
            ),
          );
      final mutedUntil = DateTime.utc(2026, 8, 1);

      expect(
        await repository.saveDraft(
          conversationId: 'conversation',
          text: 'draft',
        ),
        isA<Success<void>>(),
      );
      expect(
        await repository.setMutedUntil(
          conversationId: 'conversation',
          mutedUntil: mutedUntil,
        ),
        isA<Success<void>>(),
      );
      expect(
        await repository.setConversationPinned(
          conversationId: 'conversation',
          pinned: true,
        ),
        isA<Success<void>>(),
      );
      expect(
        await repository.markConversationRead('conversation'),
        isA<Success<List<String>>>(),
      );
      expect(
        await repository.markConversationUnread(
          conversationId: 'conversation',
          currentUserId: 'current',
        ),
        isA<Success<void>>(),
      );
      expect(
        (await database.select(database.messages).getSingle()).unread,
        isTrue,
      );
      expect(await repository.deleteForMe('message'), isA<Success<void>>());
      expect(
        await repository.setStar(messageId: 'message', starred: true),
        isA<Success<void>>(),
      );

      final summary =
          (await repository.watchConversations('current').first).single;
      final message =
          (await repository
                  .watchMessages(
                    currentUserId: 'current',
                    conversationId: 'conversation',
                    window: const NewestConversationMessages(80),
                  )
                  .first)
              .messages
              .single;
      final attachment = await database
          .select(database.attachments)
          .getSingle();
      expect(summary.draft, 'draft');
      expect(summary.mutedUntil, mutedUntil);
      expect(summary.pinned, isTrue);
      expect(summary.unreadCount, 0);
      expect(message.deletedForMe, isTrue);
      expect(message.starred, isTrue);
      expect(message.unread, isFalse);
      expect(attachment.boundedCacheHandleCiphertext, isNull);
      expect(attachment.cacheExpiresAt, isNull);

      expect(
        await repository.deleteConversationForMe('conversation'),
        isA<Success<void>>(),
      );
      expect(await repository.watchConversations('current').first, isEmpty);
    },
  );

  test('marking a conversation read again writes nothing at all', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftConversationDomainRepository(database);
    await database
        .into(database.conversations)
        .insert(
          ConversationsCompanion.insert(
            conversationId: 'conversation',
            kind: ConversationKind.direct.index,
            peerUserId: const Value('peer'),
            listProjectionCiphertext: Uint8List.fromList('preview'.codeUnits),
            sortKey: 10,
            unreadCount: const Value(1),
          ),
        );
    await database
        .into(database.messages)
        .insert(
          MessagesCompanion.insert(
            messageId: 'message',
            conversationId: 'conversation',
            currentEventId: 'event',
            projectionCiphertext: Uint8List.fromList('content'.codeUnits),
            status: MessageTransportState.received.index,
            revision: 0,
            createdAt: DateTime.utc(2026, 9, 10),
            senderUserId: const Value('peer'),
            senderDeviceId: const Value('peer-device'),
            orderingMs: const Value(10),
            orderingEventId: const Value('event'),
            unread: const Value(true),
          ),
        );

    final writes = <Set<TableUpdate>>[];
    final observed = database
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            database.conversations,
            database.messages,
          ]),
        )
        .listen(writes.add);
    addTearDown(observed.cancel);

    expect(
      await repository.markConversationRead('conversation'),
      isA<Success<List<String>>>().having(
        (result) => result.value,
        'cleared',
        ['message'],
      ),
    );
    await pumpEventQueue();
    expect(writes, isNotEmpty);

    // The conversation on screen asks for this every time it becomes visible
    // and every time anything lands in it. A repeat that rewrote a count that
    // was already zero would re-derive every summary in the chat list, and
    // would answer the very observer that provoked it.
    writes.clear();
    expect(
      await repository.markConversationRead('conversation'),
      isA<Success<List<String>>>().having(
        (result) => result.value,
        'cleared',
        isEmpty,
      ),
    );
    await pumpEventQueue();
    expect(writes, isEmpty);

    // The aggregate drifting above the rows is still worth one write, because
    // nothing else will ever bring it back down.
    await database.customStatement(
      'UPDATE conversations SET unread_count = 3 '
      "WHERE conversation_id = 'conversation'",
    );
    writes.clear();
    expect(
      await repository.markConversationRead('conversation'),
      isA<Success<List<String>>>(),
    );
    await pumpEventQueue();
    expect(writes, isNotEmpty);
    expect(
      (await database.select(database.conversations).getSingle()).unreadCount,
      0,
    );
  });

  test(
    'typing expires conservatively and presence means socket count only',
    () async {
      final state = MemoryVolatileConversationState();
      addTearDown(state.dispose);
      final now = DateTime.now().toUtc();

      state.applyTyping(
        conversationId: 'conversation',
        userId: 'USER',
        deviceId: 'DEVICE',
        isTyping: true,
        expiresAt: now.add(const Duration(seconds: 10)),
        authenticatedAt: now,
      );
      var typing = await state.watchTyping('conversation').first;
      expect(typing, hasLength(1));
      expect(typing.single.userId, 'user');

      state.applyTyping(
        conversationId: 'conversation',
        userId: 'user',
        deviceId: 'other-device',
        isTyping: true,
        expiresAt: now.add(const Duration(minutes: 1)),
        authenticatedAt: now,
      );
      typing = await state.watchTyping('conversation').first;
      expect(typing, hasLength(1), reason: 'overlong signals are ignored');

      state.applyPresence(userId: 'USER', deviceId: 'one', socketOnline: true);
      state.applyPresence(userId: 'USER', deviceId: 'two', socketOnline: true);
      var presence = await state.watchPresence('user').first;
      expect(presence.meaning, PresenceMeaning.socketOnline);
      expect(presence.onlineDeviceCount, 2);

      state.clearDisconnected();
      expect(await state.watchTyping('conversation').first, isEmpty);
      presence = await state.watchPresence('user').first;
      expect(presence.meaning, PresenceMeaning.offline);
    },
  );
}
