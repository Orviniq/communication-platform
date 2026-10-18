import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _sender = '00000000-0000-0000-0000-0000000000a1';
const _other = '00000000-0000-0000-0000-0000000000b2';
const _third = '00000000-0000-0000-0000-0000000000c3';

/// The held envelopes of ADR-093 in the store: held, acknowledged once, kept,
/// released in mailbox order, and taken out of the held set by its limits.
void main() {
  late LocalDatabase database;
  late DriftSyncStore store;
  var now = DateTime.utc(2026, 10, 17, 12);

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    store = DriftSyncStore(database);
    now = DateTime.utc(2026, 10, 17, 12);
  });

  tearDown(() => database.close());

  /// Persists [sequences] in pages the drain ceiling allows.
  Future<void> persist(Iterable<int> sequences) async {
    final all = sequences.toList();
    for (var start = 0; start < all.length; start += 50) {
      final persisted = await store.persistDrainPage(
        DrainPage(
          envelopes: [
            for (final sequence in all.skip(start).take(50))
              SyncEnvelope(
                id: _uuid(sequence),
                sequence: sequence,
                exactCiphertext: _blob(sequence),
              ),
          ],
          hasMore: false,
          prunedThrough: 0,
        ),
      );
      expect(persisted, isA<Success<void>>());
    }
  }

  Future<SyncEnvelope?> begin() async =>
      (await store.beginNextEnvelopeInspection(now: now)
              as Success<SyncEnvelope?>)
          .value;

  /// Inspects the next due envelope, which must be [sequence], and holds it.
  Future<void> hold(
    int sequence, {
    String sender = _sender,
    int session = 1,
    bool initial = true,
  }) async {
    final envelope = await begin();
    expect(envelope?.sequence, sequence);
    final held = await store.recordEnvelopeHold(
      envelopeId: envelope!.id,
      hold: HeldEnvelopeInspection(
        claimedSenderUserId: sender,
        sessionId: _session(session),
        initial: initial,
      ),
      now: now,
    );
    expect(held, isA<Success<void>>());
  }

  /// Inspects the next due envelope, which must be [sequence], and commits it
  /// as an ordinary opened envelope.
  Future<void> open(int sequence) async {
    final envelope = await begin();
    expect(envelope?.sequence, sequence);
    final committed = await store.commitOpaqueInspection(
      envelopeId: envelope!.id,
      inspection: OpaqueEnvelopeInspection(
        opaqueEventId: 'opened-$sequence',
        dependency: EnvelopeDependency.directOrLocal,
      ),
    );
    expect(committed, isA<Success<bool>>());
  }

  /// Every acknowledgement batch that is due, answered by the server.
  Future<List<String>> acknowledgeAll() async {
    final acknowledged = <String>[];
    while (true) {
      final batch =
          (await store.beginAcknowledgementBatch(now: now, maximumIds: 500)
                  as Success<AcknowledgementBatch?>)
              .value;
      if (batch == null) {
        return acknowledged;
      }
      acknowledged.addAll(batch.envelopeIds);
      expect(
        await store.recordAcknowledgementSuccess(batch: batch, now: now),
        isA<Success<void>>(),
      );
    }
  }

  Future<InboxEnvelope?> row(int sequence) => (database.select(
    database.inboxEnvelopes,
  )..where((item) => item.sequence.equals(sequence))).getSingleOrNull();

  Future<List<int>> quarantineReasons() async => [
    for (final record in await (database.select(
      database.quarantineRecords,
    )..orderBy([(item) => OrderingTerm.asc(item.id)])).get())
      record.reasonCode,
  ];

  Future<int> heldOf(String sender) async => (await (database.select(
    database.inboxEnvelopes,
  )..where((item) => item.heldSenderUserId.equals(sender))).get()).length;

  Future<void> release(String sender) async {
    expect(
      await store.releaseHeldEnvelopes(senderUserId: sender, dueAt: now),
      isA<Success<int>>(),
    );
  }

  test('a held envelope waits for its acknowledgement, survives it, and lets '
      'the rows after it go', () async {
    await persist([1, 2]);
    await hold(1);

    final waiting = await row(1);
    expect(
      waiting!.processingState,
      InboxProcessingState.readyToAcknowledge.index,
    );
    expect(waiting.readyToAcknowledge, isTrue);
    expect(waiting.heldSenderUserId, _sender);
    expect(waiting.heldSessionId, _session(1));
    expect(waiting.heldInitial, isTrue);
    expect(waiting.heldAt?.toUtc(), now);
    expect(waiting.inspectionFailures, 0);

    await open(2);
    expect(await acknowledgeAll(), [_uuid(1), _uuid(2)]);

    final kept = await row(1);
    expect(
      kept,
      isNotNull,
      reason: 'a held envelope survives its acknowledgement',
    );
    expect(kept!.processingState, InboxProcessingState.held.index);
    expect(kept.envelopeCiphertext, _blob(1));
    expect(
      await row(2),
      isNull,
      reason: 'the rows after a held row are deleted',
    );
    final checkpoint = await database
        .select(database.syncCheckpoints)
        .getSingle();
    expect(checkpoint.highestContiguousAckedSequence, 2);
    expect(await begin(), isNull, reason: 'a held row is never inspected');
  });

  test('a release opens the sender\'s envelopes in sequence order and before '
      'later envelopes', () async {
    await persist([1, 2, 3, 4]);
    await hold(1);
    await hold(2, sender: _other, session: 2);
    await hold(3, initial: false);
    await open(4);
    await acknowledgeAll();
    await persist([5]);

    await release(_sender);

    final order = <int>[];
    while (true) {
      final envelope = await begin();
      if (envelope == null) {
        break;
      }
      order.add(envelope.sequence);
      await store.commitOpaqueInspection(
        envelopeId: envelope.id,
        inspection: OpaqueEnvelopeInspection(
          opaqueEventId: 'opened-${envelope.sequence}',
          dependency: EnvelopeDependency.directOrLocal,
        ),
      );
    }
    expect(order, [1, 3, 5]);
    expect(
      (await row(2))!.processingState,
      InboxProcessingState.held.index,
      reason: 'another sender\'s envelope stays held',
    );
  });

  test(
    'a released envelope\'s commit is not acknowledged a second time',
    () async {
      await persist([1]);
      await hold(1);
      await acknowledgeAll();
      await release(_sender);
      await open(1);

      final opened = await row(1);
      expect(opened!.processingState, InboxProcessingState.acknowledged.index);
      expect(opened.readyToAcknowledge, isFalse);
      expect(opened.heldSenderUserId, isNull);
      expect(opened.heldSessionId, isNull);
      expect(opened.heldInitial, isNull);
      expect(opened.heldAt, isNull);
      expect(
        await acknowledgeAll(),
        isEmpty,
        reason: 'no second acknowledgement',
      );

      // The next acknowledgement deletes it, as it deletes every acknowledged
      // row the walk has passed.
      await persist([2]);
      await open(2);
      expect(await acknowledgeAll(), [_uuid(2)]);
      expect(await row(1), isNull);
    },
  );

  test('an owed acknowledgement is not released', () async {
    await persist([1]);
    await hold(1);

    expect(
      await store.releaseHeldEnvelopes(senderUserId: _sender, dueAt: now),
      isA<Success<int>>().having((result) => result.value, 'moved', 0),
    );
    expect(
      (await row(1))!.processingState,
      InboxProcessingState.readyToAcknowledge.index,
    );
    expect(await begin(), isNull);

    await acknowledgeAll();
    expect(
      await store.releaseHeldEnvelopes(senderUserId: _sender, dueAt: now),
      isA<Success<int>>().having((result) => result.value, 'moved', 1),
    );
    expect((await begin())?.sequence, 1);
  });

  test(
    'the releasable senders are those with an acknowledged held envelope',
    () async {
      await persist([1, 2]);
      await hold(1);
      await hold(2, sender: _other, session: 2);
      expect(
        (await store.readReleasableHeldSenders() as Success<List<String>>)
            .value,
        isEmpty,
      );
      await acknowledgeAll();
      expect(
        (await store.readReleasableHeldSenders() as Success<List<String>>)
            .value,
        [_sender, _other],
      );
    },
  );

  test('the 65th envelope of a sender evicts its oldest with the whole '
      'session', () async {
    // The oldest is an initial with two follow-ups; 61 more initials make 64.
    await persist(List.generate(65, (index) => index + 1));
    await hold(1);
    await hold(2, initial: false);
    await hold(3, initial: false);
    for (var sequence = 4; sequence <= 64; sequence += 1) {
      await hold(sequence, session: sequence);
    }
    expect(await heldOf(_sender), 64);

    await hold(65, session: 65);

    expect(await heldOf(_sender), 62);
    expect(await quarantineReasons(), [6, 6, 6]);
    for (final sequence in [1, 2, 3]) {
      final evicted = await row(sequence);
      expect(evicted!.heldSenderUserId, isNull);
      expect(evicted.heldSessionId, isNull);
      // Still owed its acknowledgement, so it keeps that state.
      expect(
        evicted.processingState,
        InboxProcessingState.readyToAcknowledge.index,
      );
    }
    expect((await row(65))!.heldSenderUserId, _sender);
  });

  test('the 129th envelope of the phone evicts the phone\'s oldest', () async {
    await persist(List.generate(129, (index) => index + 1));
    for (var sequence = 1; sequence <= 64; sequence += 1) {
      await hold(sequence, session: sequence);
    }
    for (var sequence = 65; sequence <= 128; sequence += 1) {
      await hold(sequence, sender: _other, session: sequence);
    }
    await acknowledgeAll();

    await hold(129, sender: _third, session: 129);

    expect(await heldOf(_sender), 63);
    expect(await heldOf(_other), 64);
    expect(await heldOf(_third), 1);
    expect(await quarantineReasons(), [6]);
    // Its server copy is gone, so the walk deletes it with the next batch.
    expect(
      (await row(1))!.processingState,
      InboxProcessingState.acknowledged.index,
    );
    await acknowledgeAll();
    expect(await row(1), isNull);
  });

  test('a follow-up of an evicted initial is quarantined, not held', () async {
    final small = DriftSyncStore(
      database,
      maximumHeldPerSender: 2,
      maximumHeldTotal: 4,
    );
    store = small;
    await persist([1, 2, 3, 4]);
    await hold(1);
    await hold(2, session: 2);
    // Holding a follow-up of session 1 needs room, and the room is made by
    // evicting session 1 itself.
    final envelope = await begin();
    await store.recordEnvelopeHold(
      envelopeId: envelope!.id,
      hold: HeldEnvelopeInspection(
        claimedSenderUserId: _sender,
        sessionId: _session(1),
        initial: false,
      ),
      now: now,
    );

    final orphan = await row(3);
    expect(orphan!.heldSenderUserId, isNull);
    expect(
      orphan.processingState,
      InboxProcessingState.readyToAcknowledge.index,
    );
    expect(await quarantineReasons(), [6, 2]);

    // And a follow-up of a session that left earlier never joins it.
    await hold(4, initial: false);
    expect((await row(4))!.heldSenderUserId, isNull);
    expect(await quarantineReasons(), [6, 2, 2]);
  });

  test('a held envelope expires after 7 days with reason 5, and its session '
      'with it', () async {
    await persist([1, 2, 3]);
    await hold(1);
    await hold(2, initial: false);
    now = now.add(const Duration(hours: 1));
    await hold(3, session: 3);
    await acknowledgeAll();

    now = now
        .add(HeldEnvelopePolicy.lifetime)
        .subtract(const Duration(hours: 1, seconds: 1));
    expect(
      (await store.expireHeldEnvelopes(now: now) as Success<int>).value,
      0,
    );

    now = now.add(const Duration(seconds: 1));
    expect(
      (await store.expireHeldEnvelopes(now: now) as Success<int>).value,
      2,
    );
    expect(await quarantineReasons(), [5, 5]);
    expect(
      (await row(1))!.processingState,
      InboxProcessingState.acknowledged.index,
    );
    expect(
      (await row(2))!.processingState,
      InboxProcessingState.acknowledged.index,
    );
    expect((await row(3))!.processingState, InboxProcessingState.held.index);
  });

  test(
    'a re-hold keeps its first hold time and owes no acknowledgement',
    () async {
      final first = now;
      await persist([1]);
      await hold(1);
      await acknowledgeAll();
      await release(_sender);

      now = now.add(const Duration(days: 2));
      await hold(1);

      final again = await row(1);
      expect(again!.processingState, InboxProcessingState.held.index);
      expect(again.heldAt?.toUtc(), first);
      expect(await acknowledgeAll(), isEmpty);
    },
  );

  test('a released initial that fails its new inspection takes its follow-ups '
      'and is not acknowledged again', () async {
    await persist([1, 2]);
    await hold(1);
    await hold(2, initial: false);
    await acknowledgeAll();
    await release(_sender);
    final envelope = await begin();

    await store.recordEnvelopeRejection(
      envelopeId: envelope!.id,
      reasonCode: 2,
    );

    expect(await quarantineReasons(), [2, 2]);
    for (final sequence in [1, 2]) {
      final rejected = await row(sequence);
      expect(
        rejected!.processingState,
        InboxProcessingState.acknowledged.index,
      );
      expect(rejected.heldSenderUserId, isNull);
    }
    expect(await acknowledgeAll(), isEmpty);
    expect(await begin(), isNull);
  });

  test('the earliest hold time is the oldest held-marked row\'s', () async {
    expect(
      (await store.readEarliestHoldTime() as Success<DateTime?>).value,
      isNull,
    );
    final first = now;
    await persist([1, 2]);
    await hold(1);
    now = now.add(const Duration(days: 1));
    await hold(2, session: 2);
    expect(
      (await store.readEarliestHoldTime() as Success<DateTime?>).value?.toUtc(),
      first,
    );
  });

  test(
    'the held senders count the held envelopes and not the released ones',
    () async {
      final seen = <List<(String, int, DateTime)>>[];
      final subscription = store
          .watchHeldSenders()
          .map(
            (senders) => [
              for (final sender in senders)
                (sender.userId, sender.count, sender.latestHeldAt.toUtc()),
            ],
          )
          .listen(seen.add);
      addTearDown(subscription.cancel);
      await persist([1, 2, 3]);
      await hold(1);
      await hold(2, initial: false);
      now = now.add(const Duration(minutes: 1));
      await hold(3, sender: _other, session: 3);
      await acknowledgeAll();
      await pumpEventQueue();
      expect(seen.last, [
        (_sender, 2, DateTime.utc(2026, 10, 17, 12)),
        (_other, 1, DateTime.utc(2026, 10, 17, 12, 1)),
      ]);

      await release(_sender);
      await pumpEventQueue();
      expect(seen.last, [(_other, 1, DateTime.utc(2026, 10, 17, 12, 1))]);
    },
  );

  test(
    'the follow-up lookup names a sender only for exactly one initial',
    () async {
      await persist([1, 2, 3]);
      expect(
        (await store.heldInitialSender(_session(1)) as Success<String?>).value,
        isNull,
      );
      await hold(1);
      await hold(2, initial: false);
      expect(
        (await store.heldInitialSender(_session(1)) as Success<String?>).value,
        _sender,
      );
      await hold(3, sender: _other);
      expect(
        (await store.heldInitialSender(_session(1)) as Success<String?>).value,
        isNull,
      );
    },
  );

  test('the projection counts no held envelope as inbox work', () async {
    await persist([1, 2]);
    await hold(1);
    await acknowledgeAll();
    final projection =
        (await store.readProjection() as Success<SyncProjection>).value;
    expect(projection.inboxDepth, 1, reason: 'only the envelope still due');
  });
}

String _uuid(int value) =>
    '00000000-0000-0000-0000-${value.toRadixString(16).padLeft(12, '0')}';

Uint8List _blob(int marker) =>
    Uint8List.fromList(List<int>.filled(1024, marker & 0xff));

Uint8List _session(int marker) =>
    Uint8List.fromList(List<int>.filled(16, marker & 0xff));
