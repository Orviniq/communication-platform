import 'dart:typed_data';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_opener.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/volatile_pairwise_harness.dart';

void main() {
  final receiverUser = testUuid(2000);
  final receiverDevice = testUuid(902);
  final senderUser = testUuid(2001);
  final senderDevice = testUuid(901);
  final session = filled(16, 0x31);
  final payload = Uint8List.fromList('CPVSV001 and the rest'.codeUnits);

  late VolatileDevice receiver;
  late FakeRatchetCrypto crypto;
  late FakeLiveDevices liveDevices;
  late PairwiseVolatileOpener opener;

  setUp(() async {
    receiver = await VolatileDevice.open(
      userId: receiverUser,
      deviceId: receiverDevice,
    );
    crypto = FakeRatchetCrypto();
    liveDevices = FakeLiveDevices({
      senderUser: [liveDevice(senderUser, senderDevice)],
    });
    opener = receiver.opener(crypto: crypto, liveDevices: liveDevices);
  });

  tearDown(() => receiver.close());

  Uint8List regular({int messageNumber = 0, Uint8List? inner}) =>
      FakeRatchetCrypto.regularEnvelope(
        sessionId: session,
        messageNumber: messageNumber,
        recipientDeviceId: receiverDevice,
        inner: inner ?? payload,
      );

  Uint8List initial({
    int identity = 0x50,
    String? fromDevice,
    bool repairReplacement = false,
  }) => FakeRatchetCrypto.initialEnvelope(
    sessionId: session,
    senderUserId: senderUser,
    senderDeviceId: fromDevice ?? senderDevice,
    senderIdentityPublic: filled(64, identity),
    recipientDeviceId: receiverDevice,
    inner: payload,
    oneTimePrekeyId: 11,
    pqOneTimePrekeyId: 12,
    repairReplacement: repairReplacement,
  );

  group('a regular frame', () {
    setUp(
      () => receiver.holdSession(
        peerUserId: senderUser,
        peerDeviceId: senderDevice,
        sessionId: session,
      ),
    );

    test(
      'opens under the session it names, and writes only when committed',
      () async {
        final result = await opener.open(regular());

        final opening = (result as Success<PairwiseVolatileOpening>).value;
        expect(opening.senderUserId, senderUser);
        expect(opening.senderDeviceId, senderDevice);
        expect(opening.payload, payload);
        expect(
          (await receiver.sessionWith(senderDevice))!.stateVersion,
          1,
          reason: 'opening writes nothing',
        );

        expect(await opening.commit(), isA<Success<void>>());
        expect((await receiver.sessionWith(senderDevice))!.stateVersion, 2);
        expect(
          await receiver.database
              .select(receiver.database.inboxEnvelopes)
              .get(),
          isEmpty,
        );
      },
    );

    test('opens once: the same frame again is refused', () async {
      final frame = regular();
      final first = await opener.open(frame);
      await (first as Success<PairwiseVolatileOpening>).value.commit();

      expect(await opener.open(frame), isA<FailureResult<Object?>>());
    });

    test('is refused under a session this device does not hold', () async {
      final result = await opener.open(
        FakeRatchetCrypto.regularEnvelope(
          sessionId: filled(16, 0x77),
          messageNumber: 0,
          recipientDeviceId: receiverDevice,
          inner: payload,
        ),
      );

      expect(
        (result as FailureResult<PairwiseVolatileOpening>).failure,
        isA<SecurityFailure>(),
      );
    });

    test('carrying a repair control is left for the durable path', () async {
      final result = await opener.open(
        regular(inner: FakeRatchetCrypto.repairControl),
      );

      expect(result, isA<FailureResult<PairwiseVolatileOpening>>());
      expect((await receiver.sessionWith(senderDevice))!.stateVersion, 1);
    });

    test(
      'past the skipped-key bound asks for one repair and is dropped',
      () async {
        final first = await opener.open(regular(messageNumber: 2001));
        final second = await opener.open(regular(messageNumber: 2002));

        expect(first, isA<FailureResult<PairwiseVolatileOpening>>());
        expect(second, isA<FailureResult<PairwiseVolatileOpening>>());
        final outbox = await receiver.database
            .select(receiver.database.outboxOperations)
            .get();
        expect(outbox, hasLength(1), reason: 'one request for one session');
        expect(outbox.single.recipientDeviceId, senderDevice);
        expect(
          outbox.single.operationId,
          startsWith('pairwise-repair:signal:'),
        );
        expect(
          (await receiver.sessionWith(senderDevice))!.repairState,
          PairwiseRepairState.authenticatedRequestPending.index,
        );
      },
    );
  });

  group('an initial frame', () {
    test('opens under the sender its sealed block names, checked against '
        'the live device list', () async {
      final result = await opener.open(initial());

      final opening = (result as Success<PairwiseVolatileOpening>).value;
      expect(opening.senderUserId, senderUser);
      expect(opening.senderDeviceId, senderDevice);
      expect(liveDevices.calls, [senderUser]);
      expect(await receiver.sessionWith(senderDevice), isNull);

      expect(await opening.commit(), isA<Success<void>>());
      final created = await receiver.sessionWith(senderDevice);
      expect(created!.stateVersion, 1);
      expect(created.sessionId, session);
      final secret = await receiver.database
          .select(receiver.database.secureSecrets)
          .getSingle();
      expect(secret.stateRevision, 2);
      final tombstones = await receiver.database
          .select(receiver.database.pairwiseConsumedPrekeys)
          .get();
      expect(tombstones.map((row) => row.keyId).toSet(), {11, 12});
      final marker = await receiver.database
          .select(receiver.database.pairwiseReplayMarkers)
          .getSingle();
      expect(
        marker.firstEnvelopeId,
        DriftPairwiseTransportStore.volatileOrigin,
      );
      expect(
        await receiver.database
            .select(receiver.database.pairwiseOpenedPayloads)
            .get(),
        isEmpty,
      );

      expect(
        await opener.open(initial()),
        isA<FailureResult<PairwiseVolatileOpening>>(),
        reason: 'a replayed initial frame is refused',
      );
    });

    test('from a device its account does not list is refused', () async {
      final result = await opener.open(initial(fromDevice: testUuid(999)));

      expect(
        (result as FailureResult<PairwiseVolatileOpening>).failure,
        isA<SecurityFailure>().having(
          (failure) => failure.kind,
          'kind',
          SecurityFailureKind.unauthenticatedInput,
        ),
      );
    });

    test('whose identity key is not the listed device\'s is refused', () async {
      final result = await opener.open(initial(identity: 0x51));

      expect(result, isA<FailureResult<PairwiseVolatileOpening>>());
      expect(await receiver.sessionWith(senderDevice), isNull);
    });

    test('replacing a session is left for the durable path', () async {
      final result = await opener.open(initial(repairReplacement: true));

      expect(result, isA<FailureResult<PairwiseVolatileOpening>>());
      expect(liveDevices.calls, isEmpty);
    });
  });
}
