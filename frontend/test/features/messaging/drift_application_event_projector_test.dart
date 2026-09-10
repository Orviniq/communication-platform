import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const currentUser = '00000000-0000-0000-0000-000000000001';
  const peerUser = '00000000-0000-0000-0000-000000000002';
  const currentDevice = '00000000-0000-0000-0000-000000000011';
  const peerDevice = '00000000-0000-0000-0000-000000000022';
  const peerDeviceTwo = '00000000-0000-0000-0000-000000000023';
  final authenticatedAt = DateTime.fromMillisecondsSinceEpoch(
    1700000010000,
    isUtc: true,
  );

  test(
    'projection is identical across deterministic delivery permutations',
    () async {
      final messageId = _id(40, 16);
      final events = <ApplicationEventCommit>[
        _commit(
          eventSeed: 40,
          kind: ApplicationEventKind.messageCreate,
          senderUser: currentUser,
          senderDevice: currentDevice,
          counter: 1,
          body: MessageCreateBody(messageId: messageId, text: 'first'),
          localOrigin: true,
          authenticatedAt: authenticatedAt,
        ),
        _commit(
          eventSeed: 41,
          kind: ApplicationEventKind.messageEdit,
          senderUser: currentUser,
          senderDevice: currentDevice,
          counter: 2,
          references: [messageId],
          body: MessageEditBody(
            targetMessageId: messageId,
            replacementText: 'loser',
            revision: 2,
          ),
          localOrigin: true,
          authenticatedAt: authenticatedAt,
        ),
        _commit(
          eventSeed: 42,
          kind: ApplicationEventKind.messageEdit,
          senderUser: currentUser,
          senderDevice: currentDevice,
          counter: 3,
          references: [messageId],
          body: MessageEditBody(
            targetMessageId: messageId,
            replacementText: 'winner',
            revision: 2,
          ),
          localOrigin: true,
          authenticatedAt: authenticatedAt,
        ),
        _commit(
          eventSeed: 43,
          kind: ApplicationEventKind.reactionSet,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 1,
          references: [messageId],
          body: ReactionSetBody(targetMessageId: messageId, emoji: '👍'),
          authenticatedAt: authenticatedAt,
        ),
        _commit(
          eventSeed: 44,
          kind: ApplicationEventKind.pinSet,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 2,
          references: [messageId],
          body: PinSetBody(targetMessageId: messageId, pinned: true),
          authenticatedAt: authenticatedAt,
        ),
        _commit(
          eventSeed: 45,
          kind: ApplicationEventKind.receiptRead,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 3,
          references: [messageId],
          body: ReceiptBody(messageIds: [messageId]),
          authenticatedAt: authenticatedAt,
        ),
      ];

      String? expected;
      for (var seed = 0; seed < 32; seed += 1) {
        final database = LocalDatabase(NativeDatabase.memory());
        final shuffled = List<ApplicationEventCommit>.of(events)
          ..shuffle(Random(seed));
        for (final event in shuffled) {
          await _apply(database, event);
        }
        final snapshot = await _snapshot(database);
        expected ??= snapshot;
        expect(snapshot, expected, reason: 'delivery permutation seed $seed');
        await database.close();
      }
    },
  );

  test(
    'authorization, edit winner, and remote tombstone rules fail closed',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final messageId = _id(50, 16);
      await _apply(
        database,
        _commit(
          eventSeed: 50,
          kind: ApplicationEventKind.messageCreate,
          senderUser: currentUser,
          senderDevice: currentDevice,
          counter: 1,
          body: MessageCreateBody(messageId: messageId, text: 'original'),
          localOrigin: true,
          authenticatedAt: authenticatedAt,
        ),
      );
      for (final event in [
        _commit(
          eventSeed: 51,
          kind: ApplicationEventKind.messageEdit,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 1,
          references: [messageId],
          body: MessageEditBody(
            targetMessageId: messageId,
            replacementText: 'forged',
            revision: 999,
          ),
          authenticatedAt: authenticatedAt,
        ),
        _commit(
          eventSeed: 52,
          kind: ApplicationEventKind.messageDelete,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 2,
          references: [messageId],
          body: MessageDeleteBody(targetMessageId: messageId),
          authenticatedAt: authenticatedAt,
        ),
      ]) {
        await _apply(database, event);
      }
      var row = await database.select(database.messages).getSingle();
      expect(utf8.decode(row.projectionCiphertext), 'original');
      expect(row.deletedForEveryone, isFalse);

      await database
          .into(database.attachments)
          .insert(
            AttachmentsCompanion.insert(
              attachmentId: 'attachment',
              messageId: protocolBytesToHex(messageId),
              encryptedDescriptor: Uint8List.fromList([1]),
              transferState: 0,
              boundedCacheHandleCiphertext: Value(Uint8List.fromList([2])),
              cacheExpiresAt: Value(authenticatedAt),
            ),
          );
      await _apply(
        database,
        _commit(
          eventSeed: 53,
          kind: ApplicationEventKind.messageDelete,
          senderUser: currentUser,
          senderDevice: currentDevice,
          counter: 2,
          references: [messageId],
          body: MessageDeleteBody(targetMessageId: messageId),
          localOrigin: true,
          authenticatedAt: authenticatedAt,
        ),
      );
      row = await database.select(database.messages).getSingle();
      expect(row.deletedForEveryone, isTrue);
      expect(row.projectionCiphertext, isEmpty);
      final attachment = await database
          .select(database.attachments)
          .getSingle();
      expect(attachment.boundedCacheHandleCiphertext, isNull);
      expect(attachment.cacheExpiresAt, isNull);
    },
  );

  test('receipt projections retain authenticated device provenance', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final messageId = _id(54, 16);
    await _apply(
      database,
      _commit(
        eventSeed: 54,
        kind: ApplicationEventKind.messageCreate,
        senderUser: currentUser,
        senderDevice: currentDevice,
        counter: 1,
        body: MessageCreateBody(messageId: messageId, text: 'outgoing'),
        localOrigin: true,
        authenticatedAt: authenticatedAt,
      ),
    );
    await _apply(
      database,
      _commit(
        eventSeed: 55,
        kind: ApplicationEventKind.receiptDelivered,
        senderUser: peerUser,
        senderDevice: peerDevice,
        counter: 1,
        references: [messageId],
        body: ReceiptBody(messageIds: [messageId]),
        authenticatedAt: authenticatedAt,
      ),
    );
    await _apply(
      database,
      _commit(
        eventSeed: 56,
        kind: ApplicationEventKind.receiptRead,
        senderUser: peerUser,
        senderDevice: peerDeviceTwo,
        counter: 1,
        references: [messageId],
        body: ReceiptBody(messageIds: [messageId]),
        authenticatedAt: authenticatedAt,
      ),
    );

    final receipts = await (database.select(
      database.receipts,
    )..orderBy([(row) => OrderingTerm.asc(row.deviceId)])).get();
    expect(receipts, hasLength(2));
    expect(receipts.map((receipt) => receipt.userId), everyElement(peerUser));
    expect(receipts.map((receipt) => receipt.deviceId), [
      peerDevice,
      peerDeviceTwo,
    ]);
    expect(receipts.map((receipt) => receipt.receiptState), [
      MessageReceiptState.delivered.index,
      MessageReceiptState.read.index,
    ]);
  });

  test(
    'exact duplicates are idempotent and counter/event reuse is quarantined',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final first = _commit(
        eventSeed: 60,
        kind: ApplicationEventKind.messageCreate,
        senderUser: currentUser,
        senderDevice: currentDevice,
        counter: 1,
        body: MessageCreateBody(messageId: _id(60, 16), text: 'one'),
        localOrigin: true,
        authenticatedAt: authenticatedAt,
      );
      expect(
        (await _apply(database, first)).disposition,
        ApplicationApplyDisposition.applied,
      );
      expect(
        (await _apply(database, first)).disposition,
        ApplicationApplyDisposition.duplicate,
      );
      expect(await database.select(database.messages).get(), hasLength(1));

      final collision = _commit(
        eventSeed: 61,
        kind: ApplicationEventKind.messageCreate,
        senderUser: currentUser,
        senderDevice: currentDevice,
        counter: 1,
        body: MessageCreateBody(messageId: _id(61, 16), text: 'two'),
        localOrigin: true,
        authenticatedAt: authenticatedAt,
      );
      expect(
        (await _apply(database, collision)).disposition,
        ApplicationApplyDisposition.senderCounterRollback,
      );
      expect(await database.select(database.messages).get(), isEmpty);
      expect(
        await database.select(database.quarantineRecords).get(),
        isNotEmpty,
      );
    },
  );

  test(
    'lower delayed counters remain valid and skewed clocks are clamped',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      for (final commit in [
        _commit(
          eventSeed: 65,
          kind: ApplicationEventKind.messageCreate,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 10,
          body: MessageCreateBody(
            messageId: _id(65, 16),
            text: 'newer counter',
          ),
          authenticatedAt: authenticatedAt,
        ),
        _commit(
          eventSeed: 66,
          kind: ApplicationEventKind.messageCreate,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 2,
          body: MessageCreateBody(messageId: _id(66, 16), text: 'delayed'),
          createdMs: authenticatedAt
              .add(const Duration(days: 30))
              .millisecondsSinceEpoch,
          authenticatedAt: authenticatedAt,
        ),
      ]) {
        expect(
          (await _apply(database, commit)).disposition,
          ApplicationApplyDisposition.applied,
        );
      }
      final messages = await database.select(database.messages).get();
      expect(messages, hasLength(2));
      final delayed = messages.singleWhere(
        (message) => message.messageId == protocolBytesToHex(_id(66, 16)),
      );
      expect(delayed.orderingMs, 0);
      expect(delayed.timestampState, MessageTimestampState.skewed.index);
    },
  );

  test(
    "a peer's slow clock does not seat its reply above the message",
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = _id(70, 16);
      final reply = _id(71, 16);
      final sentAt = authenticatedAt.millisecondsSinceEpoch;
      await _apply(
        database,
        _commit(
          eventSeed: 70,
          kind: ApplicationEventKind.messageCreate,
          senderUser: currentUser,
          senderDevice: currentDevice,
          counter: 1,
          body: MessageCreateBody(messageId: sent, text: 'the remark'),
          createdMs: sentAt,
          localOrigin: true,
          authenticatedAt: authenticatedAt,
        ),
      );
      await _apply(
        database,
        _commit(
          eventSeed: 71,
          kind: ApplicationEventKind.messageCreate,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 1,
          body: MessageCreateBody(messageId: reply, text: 'the laugh'),
          // Written after the remark, stamped before it, because the phone
          // that wrote it runs thirty seconds behind.
          createdMs: sentAt - 30000,
          authenticatedAt: authenticatedAt.add(const Duration(seconds: 20)),
        ),
      );
      final rows = await database.select(database.messages).get();
      final remark = rows.singleWhere(
        (row) => row.messageId == protocolBytesToHex(sent),
      );
      final laugh = rows.singleWhere(
        (row) => row.messageId == protocolBytesToHex(reply),
      );
      expect(laugh.orderingMs, greaterThan(remark.orderingMs));
      // What a bubble shows never contradicts where the bubble sits.
      expect(
        laugh.createdAt.millisecondsSinceEpoch,
        greaterThanOrEqualTo(remark.createdAt.millisecondsSinceEpoch),
      );
    },
  );

  test('a message that really is late keeps the time it was written', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final sent = _id(72, 16);
    final late = _id(73, 16);
    final sentAt = authenticatedAt.millisecondsSinceEpoch;
    await _apply(
      database,
      _commit(
        eventSeed: 72,
        kind: ApplicationEventKind.messageCreate,
        senderUser: currentUser,
        senderDevice: currentDevice,
        counter: 1,
        body: MessageCreateBody(messageId: sent, text: 'the remark'),
        createdMs: sentAt,
        localOrigin: true,
        authenticatedAt: authenticatedAt,
      ),
    );
    await _apply(
      database,
      _commit(
        eventSeed: 73,
        kind: ApplicationEventKind.messageCreate,
        senderUser: peerUser,
        senderDevice: peerDevice,
        counter: 1,
        body: MessageCreateBody(messageId: late, text: 'from the tunnel'),
        createdMs: sentAt - const Duration(minutes: 10).inMilliseconds,
        authenticatedAt: authenticatedAt.add(const Duration(minutes: 10)),
      ),
    );
    final row =
        await (database.select(
              database.messages,
            )..where((item) => item.messageId.equals(protocolBytesToHex(late))))
            .getSingle();
    expect(row.orderingMs, sentAt - const Duration(minutes: 10).inMilliseconds);
  });

  test('a corrected sender keeps the order it wrote its messages in', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final sentAt = authenticatedAt.millisecondsSinceEpoch;
    await _apply(
      database,
      _commit(
        eventSeed: 74,
        kind: ApplicationEventKind.messageCreate,
        senderUser: currentUser,
        senderDevice: currentDevice,
        counter: 1,
        body: MessageCreateBody(messageId: _id(74, 16), text: 'the remark'),
        createdMs: sentAt,
        localOrigin: true,
        authenticatedAt: authenticatedAt,
      ),
    );
    for (final (seed, behind) in [(75, 30000), (76, 25000)]) {
      await _apply(
        database,
        _commit(
          eventSeed: seed,
          kind: ApplicationEventKind.messageCreate,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: seed,
          body: MessageCreateBody(
            messageId: _id(seed, 16),
            text: 'laugh $seed',
          ),
          createdMs: sentAt - behind,
          authenticatedAt: authenticatedAt.add(const Duration(seconds: 20)),
        ),
      );
    }
    final first =
        await (database.select(database.messages)..where(
              (item) => item.messageId.equals(protocolBytesToHex(_id(75, 16))),
            ))
            .getSingle();
    final second =
        await (database.select(database.messages)..where(
              (item) => item.messageId.equals(protocolBytesToHex(_id(76, 16))),
            ))
            .getSingle();
    expect(second.orderingMs, greaterThan(first.orderingMs));
  });

  test(
    'one event ID with different canonical bytes invalidates the fact',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final first = _commit(
        eventSeed: 68,
        kind: ApplicationEventKind.messageCreate,
        senderUser: currentUser,
        senderDevice: currentDevice,
        counter: 1,
        body: MessageCreateBody(messageId: _id(68, 16), text: 'first'),
        localOrigin: true,
        authenticatedAt: authenticatedAt,
      );
      await _apply(database, first);
      final conflict = ApplicationEventCommit(
        event: first.event,
        canonicalBytes: Uint8List.fromList([0xff, ...first.canonicalBytes]),
        currentUserId: first.currentUserId,
        currentDeviceId: first.currentDeviceId,
        conversationKind: first.conversationKind,
        peerUserId: first.peerUserId,
        localOrigin: first.localOrigin,
        authenticatedAt: first.authenticatedAt,
      );

      expect(
        (await _apply(database, conflict)).disposition,
        ApplicationApplyDisposition.eventIdConflict,
      );
      expect(await database.select(database.messages).get(), isEmpty);
    },
  );

  test(
    'transaction failure rolls back marker and every projection write',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final commit = _commit(
        eventSeed: 70,
        kind: ApplicationEventKind.messageCreate,
        senderUser: peerUser,
        senderDevice: peerDevice,
        counter: 1,
        body: MessageCreateBody(messageId: _id(70, 16), text: 'rollback'),
        authenticatedAt: authenticatedAt,
      );

      await expectLater(
        database.writeTransaction(() async {
          await DriftApplicationEventProjector(
            database,
          ).applyInsideTransaction(commit);
          throw StateError('injected transaction failure');
        }),
        throwsStateError,
      );
      expect(
        await database.select(database.storedApplicationEvents).get(),
        isEmpty,
      );
      expect(await database.select(database.conversations).get(), isEmpty);
      expect(await database.select(database.messages).get(), isEmpty);
      expect(
        await database.select(database.pendingApplicationReceipts).get(),
        isEmpty,
      );
    },
  );

  test('incoming direct messages queue delivery work after commit', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final messageId = _id(75, 16);
    await _apply(
      database,
      _commit(
        eventSeed: 75,
        kind: ApplicationEventKind.messageCreate,
        senderUser: peerUser,
        senderDevice: peerDevice,
        counter: 1,
        body: MessageCreateBody(messageId: messageId, text: 'incoming'),
        authenticatedAt: authenticatedAt,
      ),
    );

    final pending = await database
        .select(database.pendingApplicationReceipts)
        .getSingle();
    expect(pending.messageId, protocolBytesToHex(messageId));
    expect(pending.targetUserId, peerUser);
    expect(pending.localDeviceId, currentDevice);
  });

  test(
    'a delivered receipt is owed once, not once per projection rebuild',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final messageId = _id(76, 16);
      await _apply(
        database,
        _commit(
          eventSeed: 76,
          kind: ApplicationEventKind.messageCreate,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 1,
          body: MessageCreateBody(messageId: messageId, text: 'incoming'),
          authenticatedAt: authenticatedAt,
        ),
      );
      final hex = protocolBytesToHex(messageId);
      expect(
        await database.select(database.pendingApplicationReceipts).get(),
        hasLength(1),
      );

      // The receipt is sent, which is what the flush does when it succeeds.
      await DriftConversationDomainRepository(
        database,
      ).completePendingDeliveredReceipts(
        localDeviceId: currentDevice,
        messageIds: [hex],
      );
      expect(
        await database.select(database.pendingApplicationReceipts).get(),
        isEmpty,
      );

      // Anything at all in this conversation rebuilds its projection, and the
      // rebuild rewrites every message in it. Before the durable marker existed
      // this re-queued a receipt for every message the conversation had ever
      // received — and a receipt is an event at the far end, which rebuilds
      // that conversation and re-queues its own, so two devices in one
      // conversation sustained it indefinitely.
      await _apply(
        database,
        _commit(
          eventSeed: 77,
          kind: ApplicationEventKind.messageCreate,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 2,
          body: MessageCreateBody(messageId: _id(77, 16), text: 'and another'),
          authenticatedAt: authenticatedAt,
        ),
      );

      final pending = await database
          .select(database.pendingApplicationReceipts)
          .get();
      expect(
        pending.map((row) => row.messageId),
        [protocolBytesToHex(_id(77, 16))],
        reason: 'only the message nobody has been told about yet',
      );
      final sent = await (database.select(
        database.messages,
      )..where((row) => row.messageId.equals(hex))).getSingle();
      expect(
        sent.deliveredReceiptSent,
        isTrue,
        reason: 'and the rebuild preserved the marker rather than clearing it',
      );
    },
  );

  test(
    'Saved Messages is own-account-only, unread-free, and local-only',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final own = _commit(
        eventSeed: 80,
        kind: ApplicationEventKind.messageCreate,
        senderUser: currentUser,
        senderDevice: currentDevice,
        counter: 1,
        body: MessageCreateBody(messageId: _id(80, 16), text: 'saved'),
        conversationKind: ConversationKind.saved,
        peerUserId: null,
        localOrigin: true,
        authenticatedAt: authenticatedAt,
      );
      expect(
        (await _apply(database, own)).disposition,
        ApplicationApplyDisposition.applied,
      );
      final message = await database.select(database.messages).getSingle();
      expect(message.unread, isFalse);
      expect(message.status, MessageTransportState.localOnly.index);

      final remoteDelete = _commit(
        eventSeed: 82,
        kind: ApplicationEventKind.messageDelete,
        senderUser: currentUser,
        senderDevice: currentDevice,
        counter: 2,
        references: [_id(80, 16)],
        body: MessageDeleteBody(targetMessageId: _id(80, 16)),
        conversationKind: ConversationKind.saved,
        peerUserId: null,
        localOrigin: true,
        authenticatedAt: authenticatedAt,
      );
      expect(
        (await _apply(database, remoteDelete)).disposition,
        ApplicationApplyDisposition.policyRejected,
      );
      expect(
        (await database.select(database.messages).getSingle())
            .deletedForEveryone,
        isFalse,
      );

      final peer = _commit(
        eventSeed: 81,
        kind: ApplicationEventKind.messageCreate,
        senderUser: peerUser,
        senderDevice: peerDevice,
        counter: 1,
        body: MessageCreateBody(messageId: _id(81, 16), text: 'forged'),
        conversationKind: ConversationKind.saved,
        peerUserId: null,
        authenticatedAt: authenticatedAt,
      );
      expect(
        (await _apply(database, peer)).disposition,
        ApplicationApplyDisposition.policyRejected,
      );
      expect(await database.select(database.messages).get(), hasLength(1));
    },
  );

  test('future events are retained opaquely under the strict bound', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final projector = DriftApplicationEventProjector(database);
    await database.writeTransaction(() async {
      for (var index = 0; index < 257; index += 1) {
        await projector.retainUnsupportedInsideTransaction(
          UnsupportedApplicationCommit(
            recordKey: 'future:$index',
            version: 2,
            kindValue: null,
            senderUserId: peerUser,
            senderDeviceId: peerDevice,
            retainedBytes: Uint8List.fromList([0xa1, 0x00, 0x02, index & 0xff]),
            authenticatedAt: authenticatedAt.add(Duration(seconds: index)),
          ),
        );
      }
    });
    final rows = await database
        .select(database.unsupportedApplicationEvents)
        .get();
    expect(rows, hasLength(256));
    expect(rows.any((row) => row.recordKey == 'future:0'), isFalse);
    expect(rows.every((row) => row.retainedPayload.isNotEmpty), isTrue);
  });

  test(
    'unknown-kind headers still enforce event and sender-counter reuse',
    () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await _apply(
        database,
        _commit(
          eventSeed: 90,
          kind: ApplicationEventKind.messageCreate,
          senderUser: peerUser,
          senderDevice: peerDevice,
          counter: 1,
          body: MessageCreateBody(messageId: _id(90, 16), text: 'known'),
          authenticatedAt: authenticatedAt,
        ),
      );
      await database.writeTransaction(
        () => DriftApplicationEventProjector(database)
            .retainUnsupportedInsideTransaction(
              UnsupportedApplicationCommit(
                recordKey: 'unsupported-event:91',
                version: 1,
                kindValue: 99,
                senderUserId: peerUser,
                senderDeviceId: peerDevice,
                eventId: _id(91, 16),
                conversationId: _id(9, 32),
                senderCounter: 1,
                currentUserId: currentUser,
                retainedBytes: Uint8List.fromList([0xa1, 0x00, 0x01, 91]),
                authenticatedAt: authenticatedAt,
              ),
            ),
      );

      expect(await database.select(database.messages).get(), isEmpty);
      expect(
        (await database.select(database.storedApplicationEvents).getSingle())
            .applyState,
        2,
      );
      expect(
        (await database
                .select(database.unsupportedApplicationEvents)
                .getSingle())
            .applyState,
        2,
      );
    },
  );
}

Future<ApplicationApplyResult> _apply(
  LocalDatabase database,
  ApplicationEventCommit commit,
) {
  return database.writeTransaction(
    () =>
        DriftApplicationEventProjector(database).applyInsideTransaction(commit),
  );
}

ApplicationEventCommit _commit({
  required int eventSeed,
  required ApplicationEventKind kind,
  required String senderUser,
  required String senderDevice,
  required int counter,
  required ApplicationEventBody body,
  required DateTime authenticatedAt,
  List<Uint8List> references = const [],
  ConversationKind conversationKind = ConversationKind.direct,
  String? peerUserId = '00000000-0000-0000-0000-000000000002',
  bool localOrigin = false,
  int? createdMs,
}) {
  final event = ApplicationEventRecord(
    version: ApplicationMessageProtocolV1.version,
    eventId: _id(eventSeed, 16),
    conversationId: _id(9, 32),
    kindValue: kind.wireValue,
    senderUserId: protocolUuidBytes(senderUser),
    senderDeviceId: protocolUuidBytes(senderDevice),
    senderCounter: counter,
    createdMs: createdMs ?? 1700000000000 + eventSeed,
    references: references,
    body: body,
  );
  return ApplicationEventCommit(
    event: event,
    canonicalBytes: Uint8List.fromList([
      eventSeed,
      kind.wireValue,
      ...event.eventId,
    ]),
    currentUserId: '00000000-0000-0000-0000-000000000001',
    currentDeviceId: '00000000-0000-0000-0000-000000000011',
    conversationKind: conversationKind.index,
    peerUserId: peerUserId,
    localOrigin: localOrigin,
    authenticatedAt: authenticatedAt,
  );
}

Uint8List _id(int seed, int length) => Uint8List.fromList(
  List<int>.generate(length, (index) => (seed + index) & 0xff),
);

Future<String> _snapshot(LocalDatabase database) async {
  final conversations = await database
      .customSelect(
        'SELECT conversation_id, kind, peer_user_id, list_projection_ciphertext, '
        'sort_key, last_activity_event_id, unread_count '
        'FROM conversations ORDER BY conversation_id',
      )
      .get();
  final messages = await database
      .customSelect(
        'SELECT message_id, current_event_id, projection_ciphertext, status, '
        'revision, ordering_ms, ordering_event_id, deleted_for_everyone, '
        'deleted_for_me, pinned, unread FROM messages ORDER BY message_id',
      )
      .get();
  final reactions = await database
      .customSelect(
        'SELECT message_id, reacting_user_id, event_id, emoji_ciphertext '
        'FROM message_reactions ORDER BY message_id, reacting_user_id',
      )
      .get();
  final receipts = await database
      .customSelect(
        'SELECT message_id, receipt_state FROM receipts '
        'ORDER BY message_id, receipt_state',
      )
      .get();
  Object? normalize(Object? value) => value is Uint8List
      ? protocolBytesToHex(value)
      : value is DateTime
      ? value.toUtc().toIso8601String()
      : value;
  return jsonEncode({
    'conversations': [
      for (final row in conversations)
        row.data.map((key, value) => MapEntry(key, normalize(value))),
    ],
    'messages': [
      for (final row in messages)
        row.data.map((key, value) => MapEntry(key, normalize(value))),
    ],
    'reactions': [
      for (final row in reactions)
        row.data.map((key, value) => MapEntry(key, normalize(value))),
    ],
    'receipts': [
      for (final row in receipts)
        row.data.map((key, value) => MapEntry(key, normalize(value))),
    ],
  });
}
