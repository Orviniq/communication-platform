import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/application_event_harness.dart';
import '../../support/local_send_harness.dart';

/// The read time of a receipt row (ADR-091 D8 and D9), and the reader list
/// built from it (D7).
void main() {
  const memberUserId = '00000000-0000-0000-0000-000000000003';
  const memberDeviceId = '00000000-0000-0000-0000-000000000033';

  // The harness authenticates every event at this instant, so a clock up to
  // five minutes past it is plausible and one further ahead is not.
  const authenticatedMs = 1700000100000;
  const sentMs = 1700000000000;

  late LocalDatabase database;
  late Uint8List messageId;
  var eventSeed = 0;
  final counters = <String, int>{};

  ApplicationEventCommit commit({
    required ApplicationEventKind kind,
    required String user,
    required String device,
    required ApplicationEventBody body,
    List<Uint8List> references = const [],
    int? createdMs,
    ConversationKind conversationKind = ConversationKind.group,
  }) {
    final counter = (counters[device] ?? 0) + 1;
    counters[device] = counter;
    return applicationCommit(
      eventId: sequentialId(1000 + eventSeed++),
      kind: kind,
      senderUser: user,
      senderDevice: device,
      counter: counter,
      body: body,
      references: references,
      conversationKind: conversationKind,
      peer: conversationKind == ConversationKind.group ? null : peerUserId,
      localOrigin: device == localDeviceId,
      createdMs: createdMs,
    );
  }

  Future<void> send({
    ConversationKind conversationKind = ConversationKind.group,
  }) async {
    final applied = await applyCommit(
      database,
      commit(
        kind: ApplicationEventKind.messageCreate,
        user: localUserId,
        device: localDeviceId,
        body: MessageCreateBody(messageId: messageId, text: 'to the group'),
        createdMs: sentMs,
        conversationKind: conversationKind,
      ),
    );
    expect(applied.disposition, ApplicationApplyDisposition.applied);
  }

  Future<void> read(
    String user,
    String device,
    int createdMs, {
    ApplicationEventKind kind = ApplicationEventKind.receiptRead,
    ConversationKind conversationKind = ConversationKind.group,
  }) async {
    final applied = await applyCommit(
      database,
      commit(
        kind: kind,
        user: user,
        device: device,
        body: ReceiptBody(messageIds: [messageId]),
        references: [messageId],
        createdMs: createdMs,
        conversationKind: conversationKind,
      ),
    );
    expect(applied.disposition, ApplicationApplyDisposition.applied);
  }

  Future<List<Receipt>> rows() =>
      (database.select(database.receipts)..orderBy([
            (row) => OrderingTerm.asc(row.userId),
            (row) => OrderingTerm.asc(row.deviceId),
          ]))
          .get();

  Future<int?> readAtOf(String device) async =>
      (await rows()).singleWhere((row) => row.deviceId == device).readAtMs;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    messageId = sequentialId(1);
    eventSeed = 0;
    counters.clear();
  });

  tearDown(() => database.close());

  group('the projector', () {
    test('a read with a plausible clock keeps its ordering time', () async {
      await send();
      await read(peerUserId, peerDeviceId, sentMs + 5000);

      expect(await readAtOf(peerDeviceId), sentMs + 5000);
      final event = await (database.select(
        database.storedApplicationEvents,
      )..orderBy([(row) => OrderingTerm.desc(row.orderingMs)])).get();
      expect(
        event.first.orderingMs,
        sentMs + 5000,
        reason: 'the read time is the ordering time of the receipt event',
      );
    });

    test('two reads from one device keep the earlier time', () async {
      await send();
      await read(peerUserId, peerDeviceId, sentMs + 9000);
      await read(peerUserId, peerDeviceId, sentMs + 4000);

      expect(await readAtOf(peerDeviceId), sentMs + 4000);
    });

    test('a slow clock is moved forward as a message time is', () async {
      await send();
      // Thirty seconds behind the message, inside the 60-second correction.
      await read(peerUserId, peerDeviceId, sentMs - 30000);

      expect(await readAtOf(peerDeviceId), sentMs + 1);
    });

    test('a clock further behind is stored as it came (ADR-091 D8)', () async {
      await send();
      await read(peerUserId, peerDeviceId, sentMs - 120000);

      expect(await readAtOf(peerDeviceId), sentMs - 120000);
    });

    test('an implausible clock gives no time, and a plausible read from the '
        'same device later gives its own', () async {
      await send();
      await read(peerUserId, peerDeviceId, authenticatedMs + 600000);

      final row = (await rows()).single;
      expect(row.receiptState, MessageReceiptState.read.index);
      expect(row.readAtMs, isNull);

      await read(peerUserId, peerDeviceId, sentMs + 7000);
      expect(await readAtOf(peerDeviceId), sentMs + 7000);
    });

    test('a delivered receipt gives no time', () async {
      await send(conversationKind: ConversationKind.direct);
      await read(
        peerUserId,
        peerDeviceId,
        sentMs + 2000,
        kind: ApplicationEventKind.receiptDelivered,
        conversationKind: ConversationKind.direct,
      );

      final row = (await rows()).single;
      expect(row.receiptState, MessageReceiptState.delivered.index);
      expect(row.readAtMs, isNull);
    });

    test(
      'a delivered receipt before a read does not move the read time',
      () async {
        await send(conversationKind: ConversationKind.direct);
        await read(
          peerUserId,
          peerDeviceId,
          sentMs + 1000,
          kind: ApplicationEventKind.receiptDelivered,
          conversationKind: ConversationKind.direct,
        );
        await read(
          peerUserId,
          peerDeviceId,
          sentMs + 8000,
          conversationKind: ConversationKind.direct,
        );

        expect(await readAtOf(peerDeviceId), sentMs + 8000);
      },
    );

    test(
      'a reaction on the message after the receipt keeps the time',
      () async {
        await send();
        await read(peerUserId, peerDeviceId, sentMs + 5000);
        final applied = await applyCommit(
          database,
          commit(
            kind: ApplicationEventKind.reactionSet,
            user: memberUserId,
            device: memberDeviceId,
            body: ReactionSetBody(
              targetMessageId: messageId,
              emoji: '\u{1F44D}',
            ),
            references: [messageId],
            createdMs: sentMs + 20000,
          ),
        );
        expect(applied.disposition, ApplicationApplyDisposition.applied);
        expect(
          await database.select(database.messageReactions).get(),
          isNotEmpty,
        );

        expect(await readAtOf(peerDeviceId), sentMs + 5000);
      },
    );

    test('a rebuild writes the times the apply wrote', () async {
      await send();
      await read(peerUserId, peerDeviceId, sentMs + 9000);
      await read(peerUserId, secondPeerDeviceId, sentMs - 20000);
      await read(memberUserId, memberDeviceId, authenticatedMs + 600000);
      final applied = await rows();

      await rebuildConversation(database, harnessConversationId);

      final rebuilt = await rows();
      expect(
        rebuilt.map((row) => (row.deviceId, row.receiptState, row.readAtMs)),
        applied.map((row) => (row.deviceId, row.receiptState, row.readAtMs)),
      );
      expect(rebuilt.map((row) => row.readAtMs), [
        sentMs + 9000,
        sentMs + 1,
        null,
      ]);
    });
  });

  group('the readers of one message', () {
    late DriftConversationDomainRepository repository;
    late List<List<MessageReader>> emissions;

    Future<void> untilEmitted(int count) async {
      for (var turn = 0; turn < 500 && emissions.length < count; turn += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(emissions, hasLength(greaterThanOrEqualTo(count)));
    }

    void watch() {
      emissions = [];
      final subscription = repository
          .watchMessageReaders(protocolBytesToHex(messageId))
          .listen(emissions.add);
      addTearDown(subscription.cancel);
    }

    setUp(() {
      repository = DriftConversationDomainRepository(database);
    });

    test('one entry for each reader, at the earliest time over their devices, '
        'the newest first and the unknown times last', () async {
      const lateUserId = '00000000-0000-0000-0000-000000000004';
      const lateDeviceId = '00000000-0000-0000-0000-000000000044';
      const unknownUserId = '00000000-0000-0000-0000-000000000005';
      const unknownDeviceId = '00000000-0000-0000-0000-000000000055';
      await send();
      await read(peerUserId, peerDeviceId, sentMs + 9000);
      await read(peerUserId, secondPeerDeviceId, sentMs + 3000);
      await read(memberUserId, memberDeviceId, sentMs + 6000);
      await read(lateUserId, lateDeviceId, sentMs + 40000);
      await read(unknownUserId, unknownDeviceId, authenticatedMs + 600000);

      watch();
      await untilEmitted(1);

      expect(emissions.last, const [
        MessageReader(userId: lateUserId, readAtMs: sentMs + 40000),
        MessageReader(userId: memberUserId, readAtMs: sentMs + 6000),
        MessageReader(userId: peerUserId, readAtMs: sentMs + 3000),
        MessageReader(userId: unknownUserId, readAtMs: null),
      ]);
    });

    test('a member whose devices only delivered the message is not a '
        'reader', () async {
      await send(conversationKind: ConversationKind.direct);
      await read(
        peerUserId,
        peerDeviceId,
        sentMs + 2000,
        kind: ApplicationEventKind.receiptDelivered,
        conversationKind: ConversationKind.direct,
      );
      expect(await rows(), hasLength(1));

      watch();
      await untilEmitted(1);

      expect(emissions.last, isEmpty);
    });

    test('a read time is never before the message (the owner, '
        '2026-10-14)', () async {
      await send();
      // Two minutes behind: past the projector's correction, so the row
      // keeps the reader's clock.
      await read(peerUserId, peerDeviceId, sentMs - 120000);
      expect(await readAtOf(peerDeviceId), sentMs - 120000);

      watch();
      await untilEmitted(1);

      expect(emissions.last, const [
        MessageReader(userId: peerUserId, readAtMs: sentMs),
      ]);
    });

    test('a new receipt gives a new value, and an unrelated write does '
        'not', () async {
      await send();
      watch();
      await untilEmitted(1);
      expect(emissions.single, isEmpty);

      await read(peerUserId, peerDeviceId, sentMs + 5000);
      await untilEmitted(2);
      expect(emissions.last, const [
        MessageReader(userId: peerUserId, readAtMs: sentMs + 5000),
      ]);

      await read(memberUserId, memberDeviceId, sentMs + 8000);
      await untilEmitted(3);
      expect(emissions.last, const [
        MessageReader(userId: memberUserId, readAtMs: sentMs + 8000),
        MessageReader(userId: peerUserId, readAtMs: sentMs + 5000),
      ]);

      // Another message, which rewrites the messages table and no receipt
      // of this one.
      final other = await applyCommit(
        database,
        commit(
          kind: ApplicationEventKind.messageCreate,
          user: peerUserId,
          device: peerDeviceId,
          body: MessageCreateBody(messageId: sequentialId(2), text: 'later'),
          createdMs: sentMs + 30000,
        ),
      );
      expect(other.disposition, ApplicationApplyDisposition.applied);
      for (var turn = 0; turn < 50; turn += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(emissions, hasLength(3));
    });
  });
}
