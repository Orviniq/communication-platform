import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/local_send_harness.dart';

/// What the delivery supervisor is watching, and what a local echo does to it.
///
/// Sending is not a call into the supervisor: a composer writes a durable row
/// and returns, and the row is the request (ADR-060). Local echo changes which
/// row that is — the ciphertext no longer exists at the moment of the send — so
/// this depth has to count what is owed as well as what is sealed, or a message
/// would sit in storage until something unrelated happened to wake the engine.
///
/// It also has to count *operations* rather than rows. The supervisor reacts to
/// growth, and a send that seals three envelopes has not become three new
/// sends: counting rows would ask for a cycle that arrives to find the work it
/// was told about already done, having paid a drain to discover it.
void main() {
  late LocalDatabase database;
  late DriftPairwiseTransportStore transport;
  late DriftSyncStore sync;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    transport = DriftPairwiseTransportStore(database);
    sync = DriftSyncStore(database, projectionWindow: Duration.zero);
    await seedDeviceState(database);
  });

  tearDown(() => database.close());

  Future<int> depth() async => (await sync.readProjection()).fold(
    onSuccess: (projection) => projection.outboxDepth,
    onFailure: (_) => -1,
  );

  test(
    'an echo raises the depth once, and sealing it raises it no further',
    () async {
      expect(await depth(), 0);

      final commit = localMessageCommit(seed: 40, counter: 1);
      final eventId = protocolBytesToHex(commit.event.eventId);
      await transport.commitLocalEcho(
        operationId: 'application:$eventId',
        eventId: eventId,
        currentUserId: localUserId,
        currentDeviceId: localDeviceId,
        peerUserId: peerUserId,
        openedLocalPayload: commit.canonicalBytes,
        applicationEvent: commit,
      );

      // One. This is the rise the supervisor turns into a delivery cycle, and it
      // happens the moment the user presses send rather than two round trips
      // later.
      expect(await depth(), 1);

      await transport.commitPreparedSend(sealedSendFor(commit, targets: 3));

      // Still one, with three sealed envelopes behind it. The work did not grow;
      // it changed shape.
      expect(
        await database.select(database.outboxOperations).get(),
        hasLength(3),
      );
      expect(await depth(), 1);

      final batch = (await sync.beginNextOutboxBatch(
        now: DateTime.utc(2026),
      )).fold(onSuccess: (batch) => batch, onFailure: (_) => null);
      expect(await depth(), 1);

      await sync.recordOutboxAcceptance(
        batch: batch!,
        acceptance: OutboxAcceptance(accepted: 3, staleDeviceIds: const {}),
        now: DateTime.utc(2026, 1, 2),
        retryFullAt: DateTime.utc(2026, 1, 2, 1),
      );
      expect(await depth(), 0);
    },
  );

  test('a second send is a second operation, and says so', () async {
    for (var index = 0; index < 2; index += 1) {
      final commit = localMessageCommit(seed: 40 + index, counter: index + 1);
      final eventId = protocolBytesToHex(commit.event.eventId);
      await transport.commitLocalEcho(
        operationId: 'application:$eventId',
        eventId: eventId,
        currentUserId: localUserId,
        currentDeviceId: localDeviceId,
        peerUserId: peerUserId,
        openedLocalPayload: commit.canonicalBytes,
        applicationEvent: commit,
      );
    }

    expect(await depth(), 2);
  });

  test(
    'an owed send that is waiting out a retry is a time somebody wakes for',
    () async {
      final commit = localMessageCommit(seed: 40, counter: 1);
      final eventId = protocolBytesToHex(commit.event.eventId);
      await transport.commitLocalEcho(
        operationId: 'application:$eventId',
        eventId: eventId,
        currentUserId: localUserId,
        currentDeviceId: localDeviceId,
        peerUserId: peerUserId,
        openedLocalPayload: commit.canonicalBytes,
        applicationEvent: commit,
      );
      final owed = (await sync.beginNextSendPreparation(
        now: DateTime.utc(2026),
      )).fold(onSuccess: (work) => work, onFailure: (_) => null);
      final due = DateTime.utc(2026, 1, 1, 0, 5);

      await sync.recordSendPreparationRetry(preparation: owed!, retryAt: due);

      // `nextRetryAt` is the one timer the supervisor arms. A send waiting out a
      // backoff is exactly the work nothing else announces, so leaving it out of
      // this would leave it sitting until something unrelated woke the session.
      final projection = (await sync.readProjection()).fold(
        onSuccess: (projection) => projection,
        onFailure: (_) => null,
      );
      expect(projection!.nextRetryAt!.isAtSameMomentAs(due), isTrue);
      // And it is genuinely not due yet: the same cycle asking again gets
      // nothing, which is what stops one refused send being retried in a loop.
      expect(
        (await sync.beginNextSendPreparation(
          now: DateTime.utc(2026),
        )).fold(onSuccess: (work) => work, onFailure: (_) => null),
        isNull,
      );
      expect(
        (await sync.beginNextSendPreparation(
          now: due,
        )).fold(onSuccess: (work) => work?.attempt, onFailure: (_) => null),
        2,
      );
    },
  );

  test(
    "a group's or a room's signed change is owed until it is routed",
    () async {
      // Neither payload is a send yet. Each waits in its own table until the
      // post-inbox dispatch, which runs only inside a cycle, routes it into the
      // pairwise outbox. Left out of this depth, a room created on one device
      // reached the other only when something unrelated woke the creator's
      // session, six minutes later on 2026-10-05.
      await _queueRoomPayload(database, 'room-control:1');
      expect(await depth(), 1);

      await _queueGroupPayload(database, 'group-control:1');
      expect(await depth(), 2);

      // Routed, each is the pairwise outbox's to count, under the recipient's
      // own operation id, so it is no longer owed here.
      await database
          .update(database.roomOutboundObjects)
          .write(const RoomOutboundObjectsCompanion(deliveryState: Value(2)));
      await database
          .update(database.groupOutboundObjects)
          .write(const GroupOutboundObjectsCompanion(deliveryState: Value(2)));
      expect(await depth(), 0);
    },
  );

  test('the watched depth rises the moment a change is queued', () async {
    final depths = <int>[];
    final subscription = sync.watchProjection().listen(
      (projection) => depths.add(projection.outboxDepth),
    );
    addTearDown(subscription.cancel);
    await pumpEventQueue();
    expect(depths, [0]);

    await _queueRoomPayload(database, 'room-control:1');
    await pumpEventQueue();

    // The rise is the supervisor's whole trigger, so the watch has to re-read
    // when the room's table changes, not merely count it when asked.
    expect(depths.last, 1);
  });
}

Future<void> _queueRoomPayload(LocalDatabase database, String operationId) =>
    database
        .into(database.roomOutboundObjects)
        .insert(
          RoomOutboundObjectsCompanion.insert(
            operationId: operationId,
            roomId: 'aa' * 32,
            eventId: '0b' * 16,
            payload: Uint8List.fromList(const [1, 2, 3]),
            recipientUserIdsJson: '["$peerUserId"]',
            deliveryState: 1,
          ),
        );

Future<void> _queueGroupPayload(LocalDatabase database, String operationId) =>
    database
        .into(database.groupOutboundObjects)
        .insert(
          GroupOutboundObjectsCompanion.insert(
            operationId: operationId,
            groupId: 'cc' * 32,
            eventId: '0d' * 16,
            payload: Uint8List.fromList(const [4, 5, 6]),
            recipientUserIdsJson: '["$peerUserId"]',
            deliveryState: 1,
          ),
        );
