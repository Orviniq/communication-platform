import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/synchronization/application/durable_sync_engine.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/held_envelope_adapters.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/held_inbound_harness.dart';
import '../../support/local_send_harness.dart';
import 'durable_sync_engine_test.dart'
    show
        FakeClock,
        FakeSyncRemote,
        RecordingStaleRefresh,
        VerifiedSenders,
        ZeroJitter,
        uuid;

/// The defect of the field test of 2026-10-17, end to end (ADR-093): a peer
/// this account has not verified sends three messages. They are held, not
/// lost; a verification releases them; they open in order, and each queues
/// its delivery receipt.
void main() {
  late FakeClock clock;
  late HeldInboundHarness harness;
  late FakeSyncRemote remote;

  setUp(() async {
    clock = FakeClock(DateTime.utc(2026, 10, 17, 12));
    harness = await HeldInboundHarness.open(clock);
    remote = FakeSyncRemote();
  });

  tearDown(() => harness.close());

  DurableSyncEngine engine({VerifiedSenders? trust}) => DurableSyncEngine(
    store: harness.sync,
    remote: remote,
    inspector: harness.inspector,
    staleDeviceRefresh: RecordingStaleRefresh(),
    clock: clock,
    jitter: const ZeroJitter(),
    heldSenderTrust: trust,
  );

  Future<SyncRunReport> run({VerifiedSenders? trust}) async {
    final report = await engine(trust: trust).synchronize();
    expect(report, isA<Success<SyncRunReport>>());
    return (report as Success<SyncRunReport>).value;
  }

  void serveThreeMessages() => remote.pages.add(
    DrainPage(
      envelopes: [
        SyncEnvelope(
          id: uuid(1),
          sequence: 1,
          exactCiphertext: harness.initial(1),
        ),
        SyncEnvelope(
          id: uuid(2),
          sequence: 2,
          exactCiphertext: harness.followUp(2, messageNumber: 1),
        ),
        SyncEnvelope(
          id: uuid(3),
          sequence: 3,
          exactCiphertext: harness.followUp(3, messageNumber: 2),
        ),
      ],
      hasMore: false,
      prunedThrough: 0,
    ),
  );

  Future<List<int>> openedCounters() async {
    final database = harness.device.database;
    final events = await database
        .select(database.storedApplicationEvents)
        .get();
    return [for (final event in events) event.senderCounter]..sort();
  }

  Future<int> queuedReceipts() async =>
      (await harness.device.database
              .select(harness.device.database.pendingApplicationReceipts)
              .get())
          .length;

  test('three messages of an unverified sender are held, and a verification '
      'opens them in order with a receipt queued for each', () async {
    serveThreeMessages();

    final held = await run();

    expect(held.heldEnvelopes, 3);
    expect(held.quarantinedEnvelopes, 0);
    expect(remote.acknowledgedIds.expand((ids) => ids), [
      uuid(1),
      uuid(2),
      uuid(3),
    ]);
    expect(await openedCounters(), isEmpty);
    expect(await queuedReceipts(), 0);
    expect(harness.crypto.accepted, 0);

    // The safety-number page's confirmation, as the contacts application
    // reports it.
    harness.senders.verified = true;
    await SyncHeldEnvelopeRelease(
      store: () async => harness.sync,
      clock: clock,
    ).peerVerified(peerUserId);
    clock.advance(SyncHeldEnvelopeRelease.releaseDelay);

    final opened = await run();

    expect(opened.inspectedEnvelopes, 3);
    expect(opened.heldEnvelopes, 0);
    expect(await openedCounters(), [1, 2, 3]);
    expect(await queuedReceipts(), 3);
    // Opened without a second acknowledgement of any of them.
    expect(remote.acknowledgedIds.expand((ids) => ids), [
      uuid(1),
      uuid(2),
      uuid(3),
    ]);
    final rows = await harness.device.database
        .select(harness.device.database.inboxEnvelopes)
        .get();
    expect(rows.every((row) => row.heldSenderUserId == null), isTrue);
  });

  test('a release the verification never made is made by the sweep', () async {
    serveThreeMessages();
    await run();

    // The trust record is written, and the process died before it released
    // anything.
    harness.senders.verified = true;
    final trust = VerifiedSenders()..verified.add(peerUserId);

    final opened = await run(trust: trust);

    expect(opened.inspectedEnvelopes, 3);
    expect(await openedCounters(), [1, 2, 3]);
  });

  test('a sender still not verified at the release is held again, and keeps '
      'its first hold time', () async {
    serveThreeMessages();
    await run();
    final first =
        (await harness.sync.readEarliestHoldTime() as Success<DateTime?>).value;

    await harness.sync.releaseHeldEnvelopes(
      senderUserId: peerUserId,
      dueAt: clock.now(),
    );
    clock.advance(const Duration(days: 1));
    final again = await run();

    expect(again.heldEnvelopes, 3);
    expect(await openedCounters(), isEmpty);
    expect(
      (await harness.sync.readEarliestHoldTime() as Success<DateTime?>).value,
      first,
    );
    expect(remote.acknowledgedIds.expand((ids) => ids), hasLength(3));
  });

  test('the held envelope keeps its exact ciphertext', () async {
    serveThreeMessages();
    final exact = Uint8List.fromList(
      remote.pages.single.envelopes.first.exactCiphertext,
    );
    await run();

    final row = await (harness.device.database.select(
      harness.device.database.inboxEnvelopes,
    )..where((item) => item.sequence.equals(1))).getSingle();
    expect(row.envelopeCiphertext, exact);
    expect(row.processingState, InboxProcessingState.held.index);
  });
}
