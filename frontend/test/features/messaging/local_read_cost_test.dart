import 'dart:convert';

import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/attachment_descriptor_fixture.dart';
import '../../support/conversation_history_harness.dart';
import '../../support/counting_interceptor.dart';

/// What one emission of the timeline costs, and what it used to cost.
///
/// `watchMessages` had no `LIMIT` and issued a reaction, a receipt and an
/// attachment query for every message in the conversation, re-running all of
/// them whenever any one message changed. Reading a conversation therefore cost
/// what had been said in it, three times over, on every keystroke that landed a
/// draft and every receipt that arrived.
///
/// These assertions are against two conversations of very different lengths and
/// they are *equal* assertions rather than bounds, so an N+1 finding its way
/// back onto this path fails here loudly and immediately.
void main() {
  late CountingInterceptor counter;
  late LocalDatabase database;
  late DriftConversationDomainRepository repository;

  setUp(() async {
    counter = CountingInterceptor();
    database = LocalDatabase(NativeDatabase.memory().interceptWith(counter));
    repository = DriftConversationDomainRepository(database);
    await database.customSelect('SELECT 1').getSingle();
  });

  tearDown(() => database.close());

  Future<_ReadCost> measure(int history) async {
    const conversationId = 'conversation';
    await seedConversationHistory(
      database,
      conversationId: conversationId,
      messages: history,
      pinnedEvery: 50,
    );

    counter.reset();
    final page = await repository
        .watchMessages(
          currentUserId: 'self',
          conversationId: conversationId,
          window: const NewestConversationMessages(120),
        )
        .first;
    final emission = counter.statements;

    counter.reset();
    final cursor = await repository.olderMessageCursor(
      conversationId: conversationId,
      before: page.oldest!,
      count: 120,
    );
    final olderPage = counter.statements;

    counter.reset();
    final anchored = await repository
        .watchMessages(
          currentUserId: 'self',
          conversationId: conversationId,
          window: ConversationMessagesFrom(switch (cursor) {
            Success(value: final value?) => value,
            _ => page.oldest!,
          }),
        )
        .first;
    final anchoredEmission = counter.statements;

    counter.reset();
    await repository.watchConversations('self').first;
    final conversations = counter.statements;

    // What this path used to do, run against the same rows through the same
    // counter, so the comparison below is between two numbers this suite
    // produced rather than between a number and an estimate. Three queries per
    // message, which is exactly what the `asyncMap` loop issued.
    counter.reset();
    final rows = await (database.select(
      database.messages,
    )..where((row) => row.conversationId.equals(conversationId))).get();
    for (final row in rows) {
      await (database.select(
        database.messageReactions,
      )..where((item) => item.messageId.equals(row.messageId))).get();
      await (database.select(
        database.receipts,
      )..where((item) => item.messageId.equals(row.messageId))).get();
      await (database.select(
        database.attachments,
      )..where((item) => item.messageId.equals(row.messageId))).get();
    }
    final unwindowed = counter.statements;

    return _ReadCost(
      emission: emission,
      olderPage: olderPage,
      anchoredEmission: anchoredEmission,
      conversations: conversations,
      unwindowed: unwindowed,
      loaded: page.messages.length,
      anchoredLoaded: anchored.messages.length,
      pinned: page.pinned.length,
    );
  }

  test('one emission of the timeline costs the same in a long conversation as '
      'in a short one', () async {
    final shortHistory = await measure(8);
    await database.close();

    counter = CountingInterceptor();
    database = LocalDatabase(NativeDatabase.memory().interceptWith(counter));
    repository = DriftConversationDomainRepository(database);
    await database.customSelect('SELECT 1').getSingle();
    final longHistory = await measure(1200);

    // The window bounds what is read, so the long conversation hands back one
    // page and the short one hands back all of itself.
    expect(shortHistory.loaded, 8);
    expect(longHistory.loaded, 120);
    expect(longHistory.anchoredLoaded, 240);

    // The whole point, as equalities.
    expect(longHistory.emission, shortHistory.emission);
    expect(longHistory.anchoredEmission, shortHistory.anchoredEmission);
    expect(longHistory.olderPage, shortHistory.olderPage);
    expect(longHistory.conversations, shortHistory.conversations);

    // And absolutely, so that a change making every emission uniformly
    // expensive would still fail here. One statement for the page, one for
    // whether anything older exists, one each for the reactions, receipts and
    // attachments of the whole page, and one for the conversation's pins.
    expect(longHistory.emission, 6);
    expect(longHistory.anchoredEmission, 6);
    // A page of older messages is one keyset lookup, which reads the page and
    // stops rather than re-scanning everything newer than it.
    expect(longHistory.olderPage, 1);
    // The conversation list is one query for the rows and one for every
    // conversation's pins together, not one per conversation.
    expect(longHistory.conversations, 2);

    // The pins are complete rather than page-scoped: the banner counts them and
    // the sheet lists them, and 24 of these 1200 messages are pinned while only
    // the newest 120 are loaded.
    expect(longHistory.pinned, 24);

    // And the comparison the change is for. The old shape is still linear in
    // the conversation, and this is what it costs at 1200 messages.
    expect(longHistory.unwindowed, 3 * 1200 + 1);
    expect(shortHistory.unwindowed, 3 * 8 + 1);
    expect(longHistory.emission * 100, lessThan(longHistory.unwindowed));
  });

  test('a message arriving is one more emission, not a longer one', () async {
    const conversationId = 'conversation';
    await seedConversationHistory(
      database,
      conversationId: conversationId,
      messages: 400,
    );
    final emissions = <ConversationMessagePage>[];
    final subscription = repository
        .watchMessages(
          currentUserId: 'self',
          conversationId: conversationId,
          window: const NewestConversationMessages(120),
        )
        .listen(emissions.add);
    addTearDown(subscription.cancel);
    await pumpEventQueue();
    expect(emissions, hasLength(1));

    counter.reset();
    await appendConversationMessage(
      database,
      conversationId: conversationId,
      index: 400,
    );
    await pumpEventQueue();
    final arrival = counter.statements;

    expect(emissions, hasLength(2));
    expect(emissions.last.messages.last.text, 'newly arrived');
    // One insert plus one emission, and the emission is the same six
    // statements it would be in an empty conversation.
    expect(arrival, 7);
  });

  group('an attachment row written without its message', () {
    const conversationId = 'conversation';
    late List<ConversationMessagePage> emissions;
    late String newest;

    setUp(() async {
      await seedConversationHistory(
        database,
        conversationId: conversationId,
        messages: 400,
      );
      newest = conversationMessageId(conversationId, 399);
      // The seeded descriptors are there to be counted, not read: this one
      // decodes, so the page shows its state.
      final descriptor = testAttachmentDescriptor();
      await (database.update(
        database.attachments,
      )..where((row) => row.attachmentId.equals('attachment-$newest'))).write(
        AttachmentsCompanion(
          encryptedDescriptor: Value(
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'capability': descriptor.capabilityId,
                  'key': base64Url.encode(descriptor.key),
                  'header': base64Url.encode(descriptor.header),
                  'stream_header': base64Url.encode(
                    descriptor.secretstreamHeader,
                  ),
                  'encrypted_size': descriptor.encryptedSize,
                  'bucket_size': descriptor.bucketSize,
                  'plaintext_size': descriptor.plaintextSize,
                  'name': descriptor.displayName,
                  'mime': descriptor.mimeType,
                  'media_kind': descriptor.mediaKind.index,
                }),
              ),
            ),
          ),
        ),
      );
      emissions = <ConversationMessagePage>[];
      final subscription = repository
          .watchMessages(
            currentUserId: 'self',
            conversationId: conversationId,
            window: const NewestConversationMessages(120),
          )
          .listen(emissions.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();
      expect(emissions, hasLength(1));
    });

    Future<void> markExpired() =>
        (database.update(
          database.attachments,
        )..where((row) => row.attachmentId.equals('attachment-$newest'))).write(
          AttachmentsCompanion(
            transferState: Value(AttachmentTransferState.expired.index),
          ),
        );

    test('is one more emission, which reads no message again', () async {
      expect(emissions.single.messages.last.attachmentStates, [
        AttachmentTransferState.queued,
      ]);
      counter.reset();
      await markExpired();
      await pumpEventQueue();

      // A download, an open and an eviction write the row alone (ADR-089
      // D9), and the tile has to follow it.
      expect(emissions, hasLength(2));
      expect(emissions.last.messages.last.attachmentStates, [
        AttachmentTransferState.expired,
      ]);
      // The update, then the page's five statements over the rows the last
      // emission read.
      expect(counter.statements, 6);
    });

    test('in one transaction with its message is still one emission', () async {
      await database.transaction(() async {
        await (database.update(database.messages)
              ..where((row) => row.messageId.equals(newest)))
            .write(const MessagesCompanion(starred: Value(true)));
        await markExpired();
      });
      await pumpEventQueue();

      expect(emissions, hasLength(2));
      expect(emissions.last.messages.last.starred, isTrue);
      expect(emissions.last.messages.last.attachmentStates, [
        AttachmentTransferState.expired,
      ]);
    });
  });
}

final class _ReadCost {
  const _ReadCost({
    required this.emission,
    required this.olderPage,
    required this.anchoredEmission,
    required this.conversations,
    required this.unwindowed,
    required this.loaded,
    required this.anchoredLoaded,
    required this.pinned,
  });

  /// One emission of the newest page.
  final int emission;

  /// Resolving the lower bound of the next page back.
  final int olderPage;

  /// One emission of a window anchored two pages back.
  final int anchoredEmission;

  /// One emission of the conversation list.
  final int conversations;

  /// The same rows, read the way this path read them before: no window, and
  /// three queries per message.
  final int unwindowed;

  final int loaded;
  final int anchoredLoaded;
  final int pinned;
}
