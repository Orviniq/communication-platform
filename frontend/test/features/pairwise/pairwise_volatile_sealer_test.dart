import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_sealer.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_volatile_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/volatile_pairwise_harness.dart';

void main() {
  final self = testUuid(1000);
  final selfDevice = testUuid(900);
  final peer = testUuid(1001);
  final blocked = testUuid(1002);
  final unreachable = testUuid(1003);
  const signalBuckets = {1024, 4096, 16384};

  late VolatileDevice device;
  late FakeRatchetCrypto crypto;
  late FakeLiveDevices liveDevices;

  setUp(() async {
    device = await VolatileDevice.open(userId: self, deviceId: selfDevice);
    crypto = FakeRatchetCrypto();
    liveDevices = FakeLiveDevices(
      {
        peer: [
          for (final number in const [1, 2, 4, 5])
            liveDevice(peer, testUuid(number)),
        ],
      },
      failures: {
        blocked: const SecurityFailure(SecurityFailureKind.policyBlocked),
        unreachable: const TransportFailure(TransportFailureKind.offline),
      },
    );
    for (final number in const [1, 2]) {
      await device.holdSession(
        peerUserId: peer,
        peerDeviceId: testUuid(number),
        sessionId: filled(16, number),
      );
    }
  });

  tearDown(() => device.close());

  test('seals every ready session and commits each advanced state', () async {
    final result = await device
        .sealer(crypto: crypto, liveDevices: liveDevices)
        .seal(
          currentUserId: self,
          currentDeviceId: selfDevice,
          targets: [
            PairwiseLiveDevice(userId: peer, deviceId: testUuid(1)),
            PairwiseLiveDevice(userId: peer, deviceId: testUuid(2)),
          ],
          payload: filled(120, 0x42),
          allowedLengths: signalBuckets,
        );

    final outcomes =
        (result as Success<List<PairwiseVolatileSealOutcome>>).value;
    expect(outcomes, everyElement(isA<PairwiseVolatileSealed>()));
    final frames = outcomes.cast<PairwiseVolatileSealed>();
    expect(frames.map((frame) => frame.deviceId), [testUuid(1), testUuid(2)]);
    expect(frames.every((frame) => frame.frame.length == 1024), isTrue);
    for (final number in const [1, 2]) {
      final session = await device.sessionWith(testUuid(number));
      expect(session!.stateVersion, 2, reason: 'committed before any send');
    }
    expect(
      await device.database.select(device.database.outboxOperations).get(),
      isEmpty,
    );
  });

  test('refuses each device it cannot seal to, and seals the rest', () async {
    await device.holdSession(
      peerUserId: peer,
      peerDeviceId: testUuid(5),
      sessionId: filled(16, 5),
      repairState: PairwiseRepairState.authenticatedRequestPending.index,
    );

    final result = await device
        .sealer(crypto: crypto, liveDevices: liveDevices)
        .seal(
          currentUserId: self,
          currentDeviceId: selfDevice,
          targets: [
            PairwiseLiveDevice(userId: peer, deviceId: testUuid(1)),
            PairwiseLiveDevice(userId: peer, deviceId: testUuid(3)),
            PairwiseLiveDevice(userId: peer, deviceId: testUuid(4)),
            PairwiseLiveDevice(userId: peer, deviceId: testUuid(5)),
            PairwiseLiveDevice(userId: blocked, deviceId: testUuid(6)),
            PairwiseLiveDevice(userId: unreachable, deviceId: testUuid(7)),
          ],
          payload: filled(120, 0x42),
          allowedLengths: signalBuckets,
        );

    final outcomes =
        (result as Success<List<PairwiseVolatileSealOutcome>>).value;
    expect(outcomes[0], isA<PairwiseVolatileSealed>());
    expect(
      outcomes
          .skip(1)
          .map((outcome) => (outcome as PairwiseVolatileRefused).reason),
      [
        PairwiseVolatileRefusal.notLive,
        PairwiseVolatileRefusal.noSession,
        PairwiseVolatileRefusal.sessionUnderRepair,
        PairwiseVolatileRefusal.identityBlocked,
        PairwiseVolatileRefusal.unverified,
      ],
    );
    expect(crypto.encryptCalls, 1);
    expect(
      crypto.initiateCalls,
      0,
      reason: 'a volatile frame never starts a session',
    );
    expect((await device.sessionWith(testUuid(1)))!.stateVersion, 2);
    expect((await device.sessionWith(testUuid(5)))!.stateVersion, 1);
    expect(await device.sessionWith(testUuid(4)), isNull);
  });

  test('a frame that is no signal bucket is never committed', () async {
    final result = await device
        .sealer(crypto: crypto, liveDevices: liveDevices)
        .seal(
          currentUserId: self,
          currentDeviceId: selfDevice,
          targets: [PairwiseLiveDevice(userId: peer, deviceId: testUuid(1))],
          // More than bucket 16384 holds, so the core pads it to 65536: an
          // envelope bucket, and no signal bucket.
          payload: filled(17000, 0x42),
          allowedLengths: signalBuckets,
        );

    final outcome =
        (result as Success<List<PairwiseVolatileSealOutcome>>).value.single;
    expect(
      (outcome as PairwiseVolatileRefused).reason,
      PairwiseVolatileRefusal.offBucket,
    );
    expect((await device.sessionWith(testUuid(1)))!.stateVersion, 1);
  });

  test('a commit that fails leaves no frame behind', () async {
    final sealer = PairwiseVolatileSealer(
      store: device.store,
      volatileStore: _RefusingVolatileStore(),
      liveDevices: liveDevices,
      crypto: device.sealer(crypto: crypto, liveDevices: liveDevices).crypto,
      clock: FixedTime(),
    );

    final result = await sealer.seal(
      currentUserId: self,
      currentDeviceId: selfDevice,
      targets: [PairwiseLiveDevice(userId: peer, deviceId: testUuid(1))],
      payload: filled(120, 0x42),
      allowedLengths: signalBuckets,
    );

    expect(result, isA<FailureResult<List<PairwiseVolatileSealOutcome>>>());
    expect((await device.sessionWith(testUuid(1)))!.stateVersion, 1);
  });

  test('refuses a target list it cannot trust before asking anybody', () async {
    final sealer = device.sealer(crypto: crypto, liveDevices: liveDevices);
    final lists = <String, List<PairwiseLiveDevice>>{
      'this device': [PairwiseLiveDevice(userId: self, deviceId: selfDevice)],
      'one device twice': [
        PairwiseLiveDevice(userId: peer, deviceId: testUuid(1)),
        PairwiseLiveDevice(userId: peer, deviceId: testUuid(1).toUpperCase()),
      ],
      'a device id that is no UUID': [
        PairwiseLiveDevice(userId: peer, deviceId: 'device-1'),
      ],
      'nobody': const [],
    };
    for (final entry in lists.entries) {
      final result = await sealer.seal(
        currentUserId: self,
        currentDeviceId: selfDevice,
        targets: entry.value,
        payload: filled(120, 0x42),
        allowedLengths: signalBuckets,
      );
      expect(
        (result as FailureResult<List<PairwiseVolatileSealOutcome>>).failure,
        isA<ValidationFailure>(),
        reason: entry.key,
      );
    }
    expect(liveDevices.calls, isEmpty);
    expect(crypto.encryptCalls, 0);
  });
}

final class _RefusingVolatileStore implements PairwiseVolatileStore {
  @override
  Future<Result<void>> commitVolatileSeal(
    PairwiseVolatileSealCommit commit,
  ) async =>
      const Result.failure(ValidationFailure(ValidationFailureKind.conflict));

  @override
  Future<Result<void>> commitVolatileOpen(
    PairwiseVolatileOpenCommit commit,
  ) async =>
      const Result.failure(ValidationFailure(ValidationFailureKind.conflict));
}
