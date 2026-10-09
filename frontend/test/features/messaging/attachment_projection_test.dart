import 'dart:convert';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/application_event_harness.dart';
import '../../support/attachment_descriptor_fixture.dart';
import '../../support/local_send_harness.dart';

/// ADR-089 D10: an attachment row keeps what this device knows about its file
/// across a re-fold, and a deleted message keeps no row.
void main() {
  late LocalDatabase database;
  late DriftConversationDomainRepository repository;
  var counter = 0;
  var localCounter = 0;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    repository = DriftConversationDomainRepository(database);
    counter = 0;
    localCounter = 0;
  });

  tearDown(() => database.close());

  final cachedAt = DateTime.utc(2026, 10, 17, 12);
  const cacheId = '0123456789abcdef0123456789abcdef';

  Future<Uint8List> peerSends({
    required int seed,
    required List<EncryptedAttachmentDescriptor> attachments,
    String text = '',
  }) async {
    final messageId = sequentialId(1000 + seed);
    counter += 1;
    await applyCommit(
      database,
      applicationCommit(
        eventId: sequentialId(seed),
        kind: ApplicationEventKind.messageCreate,
        senderUser: peerUserId,
        senderDevice: peerDeviceId,
        counter: counter,
        body: MessageCreateBody(
          messageId: messageId,
          text: text,
          contentType: attachments.isEmpty
              ? MessageContentType.text
              : MessageContentType.attachment,
          attachments: attachments,
        ),
      ),
    );
    return messageId;
  }

  Future<void> peerMutates(
    int seed,
    Uint8List messageId,
    ApplicationEventKind kind,
    ApplicationEventBody body,
  ) {
    counter += 1;
    return applyCommit(
      database,
      applicationCommit(
        eventId: sequentialId(seed),
        kind: kind,
        senderUser: peerUserId,
        senderDevice: peerDeviceId,
        counter: counter,
        references: [messageId],
        body: body,
      ),
    );
  }

  Future<void> react(int seed, Uint8List messageId, String emoji) {
    localCounter += 1;
    return applyCommit(
      database,
      applicationCommit(
        eventId: sequentialId(seed),
        kind: ApplicationEventKind.reactionSet,
        senderUser: localUserId,
        senderDevice: localDeviceId,
        counter: localCounter,
        references: [messageId],
        body: ReactionSetBody(targetMessageId: messageId, emoji: emoji),
        localOrigin: true,
      ),
    );
  }

  Future<void> markDownloaded(String capability) async {
    final updated =
        await (database.update(
          database.attachments,
        )..where((row) => row.attachmentId.equals(capability))).write(
          AttachmentsCompanion(
            transferState: Value(AttachmentTransferState.ready.index),
            boundedCacheHandleCiphertext: Value(
              Uint8List.fromList(utf8.encode(cacheId)),
            ),
            cacheExpiresAt: Value(cachedAt),
          ),
        );
    expect(updated, 1);
  }

  Future<List<Attachment>> rows() => (database.select(
    database.attachments,
  )..orderBy([(row) => OrderingTerm.asc(row.attachmentId)])).get();

  void expectDownloaded(Attachment row) {
    expect(row.transferState, AttachmentTransferState.ready.index);
    expect(utf8.decode(row.boundedCacheHandleCiphertext!), cacheId);
    expect(row.cacheExpiresAt!.toUtc(), cachedAt);
  }

  void expectNotDownloaded(Attachment row) {
    expect(row.transferState, AttachmentTransferState.queued.index);
    expect(row.boundedCacheHandleCiphertext, isNull);
    expect(row.cacheExpiresAt, isNull);
  }

  test('a re-fold after a reaction, a pin, a receipt and an edit keeps a '
      'downloaded file', () async {
    final capability = testCapability(1);
    final messageId = await peerSends(
      seed: 1,
      attachments: [testAttachmentDescriptor(capability: capability)],
      text: 'caption',
    );
    expectNotDownloaded((await rows()).single);
    await markDownloaded(capability);

    await react(2, messageId, '👍');
    expectDownloaded((await rows()).single);

    await peerMutates(
      3,
      messageId,
      ApplicationEventKind.pinSet,
      PinSetBody(targetMessageId: messageId, pinned: true),
    );
    expectDownloaded((await rows()).single);

    await applyCommit(
      database,
      applicationCommit(
        eventId: sequentialId(4),
        kind: ApplicationEventKind.receiptRead,
        senderUser: localUserId,
        senderDevice: secondLocalDeviceId,
        counter: 1,
        references: [messageId],
        body: ReceiptBody(messageIds: [messageId]),
      ),
    );
    expectDownloaded((await rows()).single);

    await peerMutates(
      5,
      messageId,
      ApplicationEventKind.messageEdit,
      MessageEditBody(
        targetMessageId: messageId,
        replacementText: 'edited caption',
        revision: 1,
      ),
    );
    final message = await database.select(database.messages).getSingle();
    expect(utf8.decode(message.projectionCiphertext), 'edited caption');
    expectDownloaded((await rows()).single);

    // The recovery path folds the whole conversation again and keeps it too.
    await rebuildConversation(database, harnessConversationId);
    expectDownloaded((await rows()).single);
  });

  test('an id that leaves the message loses its row, and a new id starts as '
      'not downloaded', () async {
    final kept = testCapability(1);
    final left = testCapability(2);
    final messageId = await peerSends(
      seed: 1,
      attachments: [testAttachmentDescriptor(capability: kept)],
    );
    await markDownloaded(kept);
    // A row this message no longer names, as an earlier projection of it
    // would have left behind.
    await database
        .into(database.attachments)
        .insert(
          AttachmentsCompanion.insert(
            attachmentId: left,
            messageId: protocolBytesToHex(messageId),
            encryptedDescriptor: Uint8List.fromList([1]),
            transferState: AttachmentTransferState.ready.index,
            boundedCacheHandleCiphertext: Value(
              Uint8List.fromList(utf8.encode(cacheId)),
            ),
            cacheExpiresAt: Value(cachedAt),
          ),
        );

    await react(2, messageId, '👍');

    final remaining = await rows();
    expect(remaining.map((row) => row.attachmentId), [kept]);
    expectDownloaded(remaining.single);

    // A capability first seen under another message is new to this one: the
    // primary key holds one row per capability, and the state it had belonged
    // to the other message's copy.
    final shared = testCapability(3);
    final first = await peerSends(
      seed: 3,
      attachments: [testAttachmentDescriptor(capability: shared)],
    );
    await markDownloaded(shared);
    final second = await peerSends(
      seed: 4,
      attachments: [testAttachmentDescriptor(capability: shared)],
    );
    final moved = await (database.select(
      database.attachments,
    )..where((row) => row.attachmentId.equals(shared))).getSingle();
    expect(moved.messageId, protocolBytesToHex(second));
    expect(moved.messageId, isNot(protocolBytesToHex(first)));
    expectNotDownloaded(moved);
  });

  test('a message deleted for everyone keeps no row, and a re-fold inserts '
      'none', () async {
    final capability = testCapability(1);
    final messageId = await peerSends(
      seed: 1,
      attachments: [testAttachmentDescriptor(capability: capability)],
    );
    await markDownloaded(capability);

    await peerMutates(
      2,
      messageId,
      ApplicationEventKind.messageDelete,
      MessageDeleteBody(targetMessageId: messageId),
    );
    expect(await rows(), isEmpty);

    await react(3, messageId, '👍');
    expect(await rows(), isEmpty);
    await rebuildConversation(database, harnessConversationId);
    expect(await rows(), isEmpty);
  });

  test(
    'a message deleted for me keeps no row, and a re-fold inserts none',
    () async {
      final capability = testCapability(1);
      final messageId = await peerSends(
        seed: 1,
        attachments: [testAttachmentDescriptor(capability: capability)],
      );
      await markDownloaded(capability);

      expect(
        await repository.deleteForMe(protocolBytesToHex(messageId)),
        isA<Success<void>>(),
      );
      expect(await rows(), isEmpty);

      await peerMutates(
        2,
        messageId,
        ApplicationEventKind.pinSet,
        PinSetBody(targetMessageId: messageId, pinned: true),
      );
      expect(await rows(), isEmpty);
      await rebuildConversation(database, harnessConversationId);
      expect(await rows(), isEmpty);
    },
  );

  test('clearing the history keeps no row for any message, and a re-fold '
      'inserts none', () async {
    final first = await peerSends(
      seed: 1,
      attachments: [testAttachmentDescriptor(capability: testCapability(1))],
    );
    await peerSends(
      seed: 2,
      attachments: [testAttachmentDescriptor(capability: testCapability(2))],
    );
    expect(await rows(), hasLength(2));

    expect(
      await repository.deleteConversationForMe(
        protocolBytesToHex(harnessConversationId),
      ),
      isA<Success<void>>(),
    );
    expect(await rows(), isEmpty);

    await react(3, first, '👍');
    expect(await rows(), isEmpty);
  });

  test('a captionless attachment message shows its file name in the Chats '
      'list, and a caption stays the preview', () async {
    await peerSends(
      seed: 1,
      attachments: [
        testAttachmentDescriptor(
          capability: testCapability(1),
          displayName: 'quarterly report.pdf',
          mimeType: 'application/pdf',
        ),
      ],
    );
    Future<String?> preview() async =>
        (await repository.watchConversations(localUserId).first)
            .single
            .lastMessage;

    expect(await preview(), 'quarterly report.pdf');
    await expectAggregatesRecomputed(database);

    final captioned = await peerSends(
      seed: 2,
      attachments: [
        testAttachmentDescriptor(
          capability: testCapability(2),
          displayName: 'photo.jpg',
          mimeType: 'image/jpeg',
        ),
      ],
      text: 'from the trip',
    );
    expect(await preview(), 'from the trip');
    await expectAggregatesRecomputed(database);

    // A re-fold of the newest message reads the same preview again.
    await react(3, captioned, '👍');
    expect(await preview(), 'from the trip');

    // The recovery path computes the same preview for the same rows.
    await rebuildConversation(database, harnessConversationId);
    expect(await preview(), 'from the trip');
    await expectAggregatesRecomputed(database);
  });
}
