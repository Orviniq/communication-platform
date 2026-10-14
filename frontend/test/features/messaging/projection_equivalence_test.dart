import 'dart:math';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/application_event_harness.dart';
import '../../support/local_send_harness.dart';

/// The full rebuild is the definition of a correct projection. This proves the
/// incremental path is the same function.
///
/// Every authenticated application event used to re-fold its whole conversation
/// from the whole event log, which made "is the projection right" and "is the
/// projection cheap" the same question. Making the normal path incremental
/// separates them, and this is where the first one is answered: an adversarial
/// event sequence is applied incrementally, and the answer is compared against
/// what folding the same log from nothing produces.
///
/// Two comparisons, because they catch different mistakes.
///
/// **Step by step**, a second database applies the same event and then runs the
/// recovery path over it. If the incremental apply is right the rebuild is a
/// no-op and the two databases agree; if it is wrong in anything a rebuild
/// re-derives, the rebuild corrects it and they diverge on the event that did
/// it, which is what makes the failure legible.
///
/// **From nothing**, a third database throws its projection away at the end and
/// rebuilds it from the log alone. That is the only comparison that says
/// anything about the *preserved* columns — `unread`, `deleted_for_me`,
/// `status` and the one-shot markers — because a rebuild over an existing row
/// carries those through and would carry an incremental mistake through with
/// them.
void main() {
  // Three databases at once is the point of this file, not an accident.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  for (var seed = 0; seed < 24; seed += 1) {
    test('an incremental projection equals a rebuilt one (seed $seed)', () {
      return _assertEquivalent(seed);
    });
  }

  // Read receipts in a group, with their read times (ADR-091 D8 and D9): two
  // members, one of them on two devices, on clocks the projector keeps, moves
  // forward and cannot place.
  for (var seed = 0; seed < 12; seed += 1) {
    test("a group's read times are the same both ways (seed $seed)", () {
      return _assertSequenceEquivalent(
        _groupReceiptSequence(seed),
        'group seed $seed',
        expectProjected: (database) async {
          // The comparison means something only if the rows hold times, and
          // the one row whose only read had an implausible clock holds none.
          final times = await database
              .customSelect('SELECT read_at_ms FROM receipts')
              .map((row) => row.read<int?>('read_at_ms'))
              .get();
          expect(times, hasLength(7));
          expect(times.whereType<int>(), hasLength(6));
        },
      );
    });
  }

  test('a receipt for many messages projects each of them', () async {
    final database = LocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final ids = [
      for (var index = 0; index < 24; index += 1) sequentialId(index),
    ];
    for (var index = 0; index < ids.length; index += 1) {
      await applyCommit(
        database,
        applicationCommit(
          eventId: ids[index],
          kind: ApplicationEventKind.messageCreate,
          senderUser: localUserId,
          senderDevice: localDeviceId,
          counter: index + 1,
          localOrigin: true,
          body: MessageCreateBody(messageId: ids[index], text: 'm$index'),
        ),
      );
    }
    await applyCommit(
      database,
      applicationCommit(
        eventId: sequentialId(900),
        kind: ApplicationEventKind.receiptRead,
        senderUser: peerUserId,
        senderDevice: peerDeviceId,
        counter: 1,
        references: ids,
        body: ReceiptBody(messageIds: ids),
      ),
    );

    final before = await projectionSnapshot(database);
    expect(
      await database.select(database.receipts).get(),
      hasLength(ids.length),
    );
    await rebuildConversation(database, harnessConversationId);
    expect(await projectionSnapshot(database), before);
  });
}

Future<void> _assertEquivalent(int seed) =>
    _assertSequenceEquivalent(_adversarialSequence(seed), 'seed $seed');

Future<void> _assertSequenceEquivalent(
  List<ApplicationEventCommit> sequence,
  String label, {
  Future<void> Function(LocalDatabase database)? expectProjected,
}) async {
  final incremental = LocalDatabase(NativeDatabase.memory());
  final rebuilt = LocalDatabase(NativeDatabase.memory());
  final fromNothing = LocalDatabase(NativeDatabase.memory());
  addTearDown(incremental.close);
  addTearDown(rebuilt.close);
  addTearDown(fromNothing.close);

  for (var step = 0; step < sequence.length; step += 1) {
    final commit = sequence[step];
    final applied = await applyCommit(incremental, commit);
    final mirrored = await applyCommit(rebuilt, commit);
    await applyCommit(fromNothing, commit);
    await rebuildConversation(rebuilt, harnessConversationId);

    final reason =
        '$label, step $step, '
        '${ApplicationEventKind.fromWireValue(commit.event.kindValue)?.name}, '
        'event ${protocolBytesToHex(commit.event.eventId).substring(0, 8)}';
    expect(mirrored.disposition, applied.disposition, reason: reason);
    expect(
      await projectionSnapshot(incremental),
      await projectionSnapshot(rebuilt),
      reason: reason,
    );
    await expectAggregatesRecomputed(incremental);
  }

  // And the same log folded from nothing at all, which is the only run whose
  // preserved columns were derived rather than carried.
  await discardProjection(fromNothing, harnessConversationId);
  await rebuildConversation(fromNothing, harnessConversationId);
  expect(
    await projectionSnapshot(incremental),
    await projectionSnapshot(fromNothing),
    reason: '$label, rebuilt from the log alone',
  );
  await expectProjected?.call(incremental);
}

/// A group conversation whose own messages two members read, shuffled.
///
/// The second member reads on two devices, and one of those devices reads the
/// same message twice. The clocks are plausible, behind the conversation by
/// less than the correction and by more, and too far ahead to place, so a row
/// holds each kind of read time. A reaction lands after some of the reads.
List<ApplicationEventCommit> _groupReceiptSequence(int seed) {
  const memberUserId = '00000000-0000-0000-0000-000000000003';
  const memberDeviceId = '00000000-0000-0000-0000-000000000033';
  const sentMs = 1700000000000;
  final messages = [
    for (var index = 0; index < 3; index += 1) sequentialId(index),
  ];
  final counters = <String, int>{};
  var event = 200;

  ApplicationEventCommit build({
    required ApplicationEventKind kind,
    required String senderUser,
    required String senderDevice,
    required ApplicationEventBody body,
    required int createdMs,
    List<Uint8List> references = const [],
  }) {
    final counter = (counters[senderDevice] ?? 0) + 1;
    counters[senderDevice] = counter;
    return applicationCommit(
      eventId: sequentialId(event++),
      kind: kind,
      senderUser: senderUser,
      senderDevice: senderDevice,
      counter: counter,
      references: references,
      conversationKind: ConversationKind.group,
      peer: null,
      localOrigin: senderDevice == localDeviceId,
      createdMs: createdMs,
      body: body,
    );
  }

  ApplicationEventCommit read(
    String user,
    String device,
    List<Uint8List> ids,
    int createdMs,
  ) => build(
    kind: ApplicationEventKind.receiptRead,
    senderUser: user,
    senderDevice: device,
    references: ids,
    body: ReceiptBody(messageIds: ids),
    createdMs: createdMs,
  );

  final creates = [
    for (var index = 0; index < messages.length; index += 1)
      build(
        kind: ApplicationEventKind.messageCreate,
        senderUser: localUserId,
        senderDevice: localDeviceId,
        body: MessageCreateBody(messageId: messages[index], text: 'm$index'),
        createdMs: sentMs + index * 1000,
      ),
  ];
  final reads = [
    // Plausible, and the same device again, earlier.
    read(peerUserId, peerDeviceId, messages, sentMs + 9000),
    read(peerUserId, peerDeviceId, [messages[0]], sentMs + 4000),
    // Behind by less than the correction, and by more.
    read(peerUserId, secondPeerDeviceId, [
      messages[0],
      messages[1],
    ], sentMs - 20000),
    read(memberUserId, memberDeviceId, [messages[2]], sentMs - 180000),
    // Too far ahead to place.
    read(memberUserId, memberDeviceId, [messages[0]], sentMs + 3600000),
    build(
      kind: ApplicationEventKind.reactionSet,
      senderUser: memberUserId,
      senderDevice: memberDeviceId,
      references: [messages[0]],
      body: ReactionSetBody(targetMessageId: messages[0], emoji: '\u{1F44D}'),
      createdMs: sentMs + 12000,
    ),
  ];
  return [...creates, ...reads]..shuffle(Random(seed));
}

/// A deliberately hostile delivery order over a deliberately hostile log.
///
/// Fixed content, shuffled arrival, so every seed is the same set of facts
/// reaching the device in a different order — which is the property the
/// projector claims and the one an incremental fold is most likely to break.
/// Sender counters are allocated when the events are built, not when they are
/// delivered, because a counter is a fact about the sender and arriving out of
/// order is ordinary.
List<ApplicationEventCommit> _adversarialSequence(int seed) {
  final messages = [
    for (var index = 0; index < 6; index += 1) sequentialId(index),
  ];
  final counters = <String, int>{};
  var event = 100;

  ApplicationEventCommit build({
    required ApplicationEventKind kind,
    required String senderUser,
    required String senderDevice,
    required ApplicationEventBody body,
    List<Uint8List> references = const [],
    Uint8List? eventId,
  }) {
    final counter = (counters[senderDevice] ?? 0) + 1;
    counters[senderDevice] = counter;
    return applicationCommit(
      eventId: eventId ?? sequentialId(event++),
      kind: kind,
      senderUser: senderUser,
      senderDevice: senderDevice,
      counter: counter,
      references: references,
      localOrigin: senderDevice == localDeviceId,
      body: body,
    );
  }

  final ours = [messages[0], messages[2], messages[4]];
  final theirs = [messages[1], messages[3], messages[5]];
  final creates = <ApplicationEventCommit>[
    for (final id in ours)
      build(
        kind: ApplicationEventKind.messageCreate,
        senderUser: localUserId,
        senderDevice: localDeviceId,
        body: MessageCreateBody(
          messageId: id,
          text: 'ours ${protocolBytesToHex(id)}',
        ),
      ),
    for (final id in theirs)
      build(
        kind: ApplicationEventKind.messageCreate,
        senderUser: peerUserId,
        senderDevice: peerDeviceId,
        body: MessageCreateBody(
          messageId: id,
          text: 'theirs ${protocolBytesToHex(id)}',
        ),
      ),
  ];

  // A second create claiming a message id that already has one. Neither is
  // trustworthy after that, so the message stops being projectable — which an
  // incremental apply has to do explicitly, because it runs no sweep.
  final collision = build(
    kind: ApplicationEventKind.messageCreate,
    senderUser: peerUserId,
    senderDevice: secondPeerDeviceId,
    body: MessageCreateBody(messageId: messages[5], text: 'forged'),
  );

  final mutations = <ApplicationEventCommit>[
    // Two edits at the same revision from the same sender: the tie is broken by
    // sender counter and then by event id, and only one of them wins.
    build(
      kind: ApplicationEventKind.messageEdit,
      senderUser: localUserId,
      senderDevice: localDeviceId,
      references: [messages[0]],
      body: MessageEditBody(
        targetMessageId: messages[0],
        replacementText: 'edit a',
        revision: 2,
      ),
    ),
    build(
      kind: ApplicationEventKind.messageEdit,
      senderUser: localUserId,
      senderDevice: localDeviceId,
      references: [messages[0]],
      body: MessageEditBody(
        targetMessageId: messages[0],
        replacementText: 'edit b',
        revision: 2,
      ),
    ),
    // An edit from somebody who did not write the message, which never wins
    // however high the revision it claims.
    build(
      kind: ApplicationEventKind.messageEdit,
      senderUser: peerUserId,
      senderDevice: peerDeviceId,
      references: [messages[0]],
      body: MessageEditBody(
        targetMessageId: messages[0],
        replacementText: 'forged edit',
        revision: 99,
      ),
    ),
    // An edit whose references do not carry its target: rejected as a fact,
    // whichever order it arrives in.
    build(
      kind: ApplicationEventKind.messageEdit,
      senderUser: localUserId,
      senderDevice: localDeviceId,
      body: MessageEditBody(
        targetMessageId: messages[2],
        replacementText: 'unreferenced',
        revision: 5,
      ),
    ),
    // An edit, then a delete over the top of it.
    build(
      kind: ApplicationEventKind.messageEdit,
      senderUser: localUserId,
      senderDevice: localDeviceId,
      references: [messages[2]],
      body: MessageEditBody(
        targetMessageId: messages[2],
        replacementText: 'edited then deleted',
        revision: 3,
      ),
    ),
    build(
      kind: ApplicationEventKind.messageDelete,
      senderUser: localUserId,
      senderDevice: localDeviceId,
      references: [messages[2]],
      body: MessageDeleteBody(targetMessageId: messages[2]),
    ),
    // A delete of somebody else's message, which is not theirs to delete.
    build(
      kind: ApplicationEventKind.messageDelete,
      senderUser: peerUserId,
      senderDevice: peerDeviceId,
      references: [messages[4]],
      body: MessageDeleteBody(targetMessageId: messages[4]),
    ),
    // One user replacing their own reaction twice, and a third that clears it.
    build(
      kind: ApplicationEventKind.reactionSet,
      senderUser: peerUserId,
      senderDevice: peerDeviceId,
      references: [messages[0]],
      body: ReactionSetBody(targetMessageId: messages[0], emoji: '\u{1F44D}'),
    ),
    build(
      kind: ApplicationEventKind.reactionSet,
      senderUser: peerUserId,
      senderDevice: secondPeerDeviceId,
      references: [messages[0]],
      body: ReactionSetBody(targetMessageId: messages[0], emoji: '\u{1F389}'),
    ),
    build(
      kind: ApplicationEventKind.reactionSet,
      senderUser: localUserId,
      senderDevice: localDeviceId,
      references: [messages[0]],
      body: ReactionSetBody(targetMessageId: messages[0], emoji: '\u{2764}'),
    ),
    build(
      kind: ApplicationEventKind.reactionSet,
      senderUser: localUserId,
      senderDevice: secondLocalDeviceId,
      references: [messages[0]],
      body: ReactionSetBody(targetMessageId: messages[0], emoji: null),
    ),
    // A reaction on a message this device has not been told about yet, unless
    // the shuffle happens to deliver the create first.
    build(
      kind: ApplicationEventKind.reactionSet,
      senderUser: peerUserId,
      senderDevice: peerDeviceId,
      references: [messages[4]],
      body: ReactionSetBody(targetMessageId: messages[4], emoji: '\u{1F440}'),
    ),
    // Pinned, then unpinned, then a pin that stands.
    build(
      kind: ApplicationEventKind.pinSet,
      senderUser: peerUserId,
      senderDevice: peerDeviceId,
      references: [messages[1]],
      body: PinSetBody(targetMessageId: messages[1], pinned: true),
    ),
    build(
      kind: ApplicationEventKind.pinSet,
      senderUser: peerUserId,
      senderDevice: peerDeviceId,
      references: [messages[1]],
      body: PinSetBody(targetMessageId: messages[1], pinned: false),
    ),
    build(
      kind: ApplicationEventKind.pinSet,
      senderUser: localUserId,
      senderDevice: localDeviceId,
      references: [messages[3]],
      body: PinSetBody(targetMessageId: messages[3], pinned: true),
    ),
    // One receipt carrying every message in the conversation, which is the
    // shape that makes an affected set a set rather than one id.
    build(
      kind: ApplicationEventKind.receiptDelivered,
      senderUser: peerUserId,
      senderDevice: peerDeviceId,
      references: messages,
      body: ReceiptBody(messageIds: messages),
    ),
    build(
      kind: ApplicationEventKind.receiptRead,
      senderUser: peerUserId,
      senderDevice: secondPeerDeviceId,
      references: [messages[0], messages[2], messages[4]],
      body: ReceiptBody(messageIds: [messages[0], messages[2], messages[4]]),
    ),
    // This account's other device reading a message the peer sent, which is
    // what clears `unread` on a row whose `unread` a rebuild otherwise carries.
    build(
      kind: ApplicationEventKind.receiptRead,
      senderUser: localUserId,
      senderDevice: secondLocalDeviceId,
      references: [messages[1], messages[3]],
      body: ReceiptBody(messageIds: [messages[1], messages[3]]),
    ),
    // A receipt naming a message that does not exist in this conversation.
    build(
      kind: ApplicationEventKind.receiptDelivered,
      senderUser: peerUserId,
      senderDevice: secondPeerDeviceId,
      references: [sequentialId(77)],
      body: ReceiptBody(messageIds: [sequentialId(77)]),
    ),
  ];

  final shuffled = [...creates, collision, ...mutations]..shuffle(Random(seed));

  // One message whose every fact arrives before it does, guaranteed rather than
  // left to the shuffle: a mutation for a message this device has not received
  // is ordinary, and it is the case an incremental fold most obviously misses.
  final lateCreate = shuffled.removeAt(
    shuffled.indexWhere(
      (commit) =>
          commit.event.kindValue ==
              ApplicationEventKind.messageCreate.wireValue &&
          protocolBytesToHex(
                (commit.event.body as MessageCreateBody).messageId,
              ) ==
              protocolBytesToHex(messages[4]),
    ),
  );
  return [
    ...shuffled,
    lateCreate,
    // The same event presented twice, which the sync engine does after a crash
    // between commit and acknowledgement.
    shuffled[seed % shuffled.length],
    lateCreate,
  ];
}
