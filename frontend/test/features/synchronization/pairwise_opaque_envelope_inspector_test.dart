import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/held_inbound_harness.dart';
import '../../support/local_send_harness.dart';

const _envelopeId = '00000000-0000-4000-8000-0000000000e1';

/// The inspector's half of ADR-093 D12 and D13: which first messages, and
/// which of their follow-ups, are held rather than refused.
void main() {
  late HeldInboundHarness harness;

  setUp(() async {
    harness = await HeldInboundHarness.open(const _Clock());
  });

  tearDown(() => harness.close());

  Future<Result<OpaqueEnvelopeOutcome>> inspect(Uint8List envelope) => harness
      .inspector
      .inspect(envelopeId: _envelopeId, exactCiphertext: envelope);

  Failure failureOf(Result<OpaqueEnvelopeOutcome> result) =>
      (result as FailureResult<OpaqueEnvelopeOutcome>).failure;

  /// Holds a stored envelope of [sequence] as an initial of the session.
  Future<void> holdInitial(int sequence) async {
    final id =
        '00000000-0000-4000-8000-${sequence.toString().padLeft(12, '0')}';
    await harness.sync.persistDrainPage(
      DrainPage(
        envelopes: [
          SyncEnvelope(
            id: id,
            sequence: sequence,
            exactCiphertext: Uint8List(1024),
          ),
        ],
        hasMore: false,
        prunedThrough: 0,
      ),
    );
    await harness.sync.beginNextEnvelopeInspection(now: const _Clock().now());
    await harness.sync.recordEnvelopeHold(
      envelopeId: id,
      hold: HeldEnvelopeInspection(
        claimedSenderUserId: peerUserId,
        sessionId: HeldInboundHarness.session,
        initial: true,
      ),
      now: const _Clock().now(),
    );
  }

  test('an unverified initial is held with its claimed sender and the '
      'header\'s session, and nothing is accepted', () async {
    final before = await harness.device.database
        .select(harness.device.database.secureSecrets)
        .getSingle();

    final result = await inspect(harness.initial(1));

    final held =
        (result as Success<OpaqueEnvelopeOutcome>).value
            as HeldEnvelopeInspection;
    expect(held.claimedSenderUserId, peerUserId);
    expect(held.sessionId, HeldInboundHarness.session);
    expect(held.initial, isTrue);
    expect(harness.crypto.accepted, 0);
    expect(harness.senders.inboundCalls, [peerUserId]);
    expect(harness.senders.verifiedCalls, isEmpty);
    expect(
      await harness.device.database
          .select(harness.device.database.pairwiseSessions)
          .get(),
      isEmpty,
    );
    final after = await harness.device.database
        .select(harness.device.database.secureSecrets)
        .getSingle();
    expect(after.stateRevision, before.stateRevision);
  });

  test('an initial whose sender block does not match the device is refused '
      'at once', () async {
    for (final envelope in [
      harness.initial(1, registrationId: 8),
      harness.initial(1, identity: Uint8List.fromList(List.filled(64, 9))),
      harness.initial(
        1,
        senderDeviceId: '00000000-0000-0000-0000-0000000000ff',
      ),
    ]) {
      expect(
        failureOf(await inspect(envelope)),
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    expect(harness.crypto.accepted, 0);
  });

  test(
    'a repair replacement from an unverified sender stays refused',
    () async {
      final result = await inspect(harness.initial(1, repairReplacement: true));

      expect(
        failureOf(result),
        const SecurityFailure(SecurityFailureKind.policyBlocked),
      );
      expect(harness.senders.inboundCalls, isEmpty);
    },
  );

  test('a refresh that failed is the answer, and nothing is held', () async {
    // A changed master key and a fork are `policyBlocked` from the refresh
    // itself; neither is "unverified".
    harness.senders.failure = const SecurityFailure(
      SecurityFailureKind.policyBlocked,
    );

    final result = await inspect(harness.initial(1));

    expect(
      failureOf(result),
      const SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  });

  test('a verified sender\'s initial opens as before', () async {
    harness.senders.verified = true;

    final result = await inspect(harness.initial(1));

    expect(
      (result as Success<OpaqueEnvelopeOutcome>).value,
      isA<OpaqueEnvelopeInspection>(),
    );
    expect(harness.crypto.accepted, 1);
  });

  test('a regular envelope with no session is held behind one held initial, '
      'and refused behind none or two', () async {
    final followUp = harness.followUp(2, messageNumber: 1);
    expect(
      failureOf(await inspect(followUp)),
      const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );

    await holdInitial(1);
    final held =
        (await inspect(followUp) as Success<OpaqueEnvelopeOutcome>).value
            as HeldEnvelopeInspection;
    expect(held.claimedSenderUserId, peerUserId);
    expect(held.sessionId, HeldInboundHarness.session);
    expect(held.initial, isFalse);

    await holdInitial(2);
    expect(
      failureOf(await inspect(followUp)),
      const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
    );
  });
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 10, 17, 12);
}
