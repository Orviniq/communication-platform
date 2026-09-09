import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/counting_interceptor.dart';
import '../../support/local_send_harness.dart';

/// What a send costs, and what each of its transport transitions costs after it.
///
/// The transitions are the point. `queued → sending → relayAccepted` used to
/// re-read every event in the conversation, re-project every message in it and
/// rewrite every row, three times per send, to move one integer on one message.
/// The cost of telling somebody their message reached the relay was therefore
/// set by how long they had been talking to that person. These assertions are
/// against two conversations of very different lengths, and they are *equal*
/// assertions rather than bounds, so a rebuild finding its way back onto this
/// path fails here loudly and immediately.
void main() {
  late CountingInterceptor counter;
  late LocalDatabase database;
  late DriftPairwiseTransportStore pairwise;
  late DriftSyncStore sync;

  setUp(() async {
    counter = CountingInterceptor();
    database = LocalDatabase(NativeDatabase.memory().interceptWith(counter));
    pairwise = DriftPairwiseTransportStore(database);
    sync = DriftSyncStore(database, projectionWindow: Duration.zero);
    await seedDeviceState(database);
  });

  tearDown(() => database.close());

  /// Leaves [count] real events in one real conversation.
  Future<void> seedHistory(int count) async {
    for (var index = 0; index < count; index += 1) {
      final commit = localMessageCommit(seed: 40 + index, counter: index + 1);
      final eventId = protocolBytesToHex(commit.event.eventId);
      expect(
        await pairwise.commitLocalEcho(
          operationId: 'application:$eventId',
          eventId: eventId,
          currentUserId: localUserId,
          currentDeviceId: localDeviceId,
          peerUserId: peerUserId,
          openedLocalPayload: commit.canonicalBytes,
          applicationEvent: commit,
        ),
        isA<Success<void>>(),
      );
    }
  }

  Future<_SendCost> measure(int history) async {
    await seedHistory(history);
    final commit = localMessageCommit(seed: 200, counter: history + 1);
    final eventId = protocolBytesToHex(commit.event.eventId);

    counter.reset();
    expect(
      await pairwise.commitLocalEcho(
        operationId: 'application:$eventId',
        eventId: eventId,
        currentUserId: localUserId,
        currentDeviceId: localDeviceId,
        peerUserId: peerUserId,
        openedLocalPayload: commit.canonicalBytes,
        applicationEvent: commit,
      ),
      isA<Success<void>>(),
    );
    final echo = counter.statements;

    counter.reset();
    expect(
      await pairwise.commitPreparedSend(sealedSendFor(commit)),
      isA<Success<void>>(),
    );
    final sealed = counter.statements;

    counter.reset();
    final batch = (await sync.beginNextOutboxBatch(
      now: DateTime.utc(2026),
    )).fold(onSuccess: (batch) => batch, onFailure: (_) => null);
    final sending = counter.statements;
    expect(batch, isNotNull);

    counter.reset();
    expect(
      await sync.recordOutboxAcceptance(
        batch: batch!,
        acceptance: OutboxAcceptance(accepted: 1, staleDeviceIds: const {}),
        now: DateTime.utc(2026, 1, 2),
        retryFullAt: DateTime.utc(2026, 1, 2, 1),
      ),
      isA<Success<void>>(),
    );
    final accepted = counter.statements;

    final message = await (database.select(
      database.messages,
    )..where((row) => row.messageId.equals(eventId))).getSingle();
    expect(message.status, MessageTransportState.relayAccepted.index);

    // What one of those transitions used to cost: a full projection of this
    // conversation. Since [ADR-063](decisions.md) the event path no longer runs
    // one, so it is measured through the recovery path that still does — which
    // keeps the comparison between two numbers this suite produced rather than
    // between a number and an estimate.
    counter.reset();
    await database.writeTransaction(
      () => DriftApplicationEventProjector(database)
          .rebuildConversationInsideTransaction(
            protocolBytesToHex(commit.event.conversationId),
            currentUserId: localUserId,
          ),
    );
    final rebuild = counter.statements;

    return _SendCost(
      echo: echo,
      sealed: sealed,
      sending: sending,
      accepted: accepted,
      rebuild: rebuild,
    );
  }

  test('a transport transition costs the same in a long conversation as in a '
      'short one', () async {
    final shortHistory = await measure(4);
    await database.close();

    counter = CountingInterceptor();
    database = LocalDatabase(NativeDatabase.memory().interceptWith(counter));
    pairwise = DriftPairwiseTransportStore(database);
    sync = DriftSyncStore(database, projectionWindow: Duration.zero);
    await seedDeviceState(database);
    final longHistory = await measure(60);

    expect(longHistory.sealed, shortHistory.sealed);
    expect(longHistory.sending, shortHistory.sending);
    expect(longHistory.accepted, shortHistory.accepted);

    // Absolute bounds as well as equality, so that a change which made every
    // transition uniformly expensive would still fail. Each is a handful of
    // statements: read the rows that moved, work out one state, write one row.
    expect(longHistory.sealed, lessThan(24));
    expect(longHistory.sending, lessThan(16));
    expect(longHistory.accepted, lessThan(16));

    // And the echo itself, which ADR-061 left linear and recorded as linear:
    // it projected the conversation, so at 61 messages it cost 201 statements
    // against 33 at five. It applies one event to one message now, so it is
    // equal across the two lengths like everything else on this path
    // ([ADR-063](decisions.md)).
    expect(longHistory.echo, shortHistory.echo);
    expect(longHistory.echo, lessThan(32));

    // And the comparison the whole change is for: each transition is now a
    // small fraction of the projection it used to run, and there were two of
    // them per send.
    expect(longHistory.sending * 8, lessThan(longHistory.rebuild));
    expect(longHistory.accepted * 8, lessThan(longHistory.rebuild));
  });

  test('an outbox transition writes one row and reads no event', () async {
    await seedHistory(3);
    final commit = localMessageCommit(seed: 200, counter: 4);
    final eventId = protocolBytesToHex(commit.event.eventId);
    await pairwise.commitLocalEcho(
      operationId: 'application:$eventId',
      eventId: eventId,
      currentUserId: localUserId,
      currentDeviceId: localDeviceId,
      peerUserId: peerUserId,
      openedLocalPayload: commit.canonicalBytes,
      applicationEvent: commit,
    );
    await pairwise.commitPreparedSend(sealedSendFor(commit));
    final before = await database.select(database.messages).get();

    expect(
      await sync.beginNextOutboxBatch(now: DateTime.utc(2026)),
      isA<Success<OutboxBatch?>>(),
    );
    final after = await database.select(database.messages).get();

    // Only the sent message moved. Everything else in the conversation is the
    // same row it was, which is the property a rebuild cannot offer: a rebuild
    // rewrites all of them and is only *equivalent* if every re-derivation
    // agrees with what was already there.
    expect(after, hasLength(before.length));
    for (final row in after) {
      final previous = before.firstWhere(
        (item) => item.messageId == row.messageId,
      );
      expect(
        row,
        row.messageId == eventId ? isNot(previous) : previous,
        reason: row.messageId,
      );
    }
    expect(
      after.firstWhere((row) => row.messageId == eventId).status,
      MessageTransportState.sending.index,
    );
  });
}

final class _SendCost {
  const _SendCost({
    required this.echo,
    required this.sealed,
    required this.sending,
    required this.accepted,
    required this.rebuild,
  });

  /// The local commit the user waits for.
  final int echo;

  /// Preparing to queued, when the fan-out lands.
  final int sealed;

  /// Queued to sending, when the batch is claimed.
  final int sending;

  /// Sending to relay-accepted, when the server answers.
  final int accepted;

  /// One full projection of the same conversation, which each of the two
  /// transitions above used to run.
  final int rebuild;
}
