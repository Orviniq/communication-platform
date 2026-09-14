import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const currentUserNumber = 1000;
  const peerUserNumber = 1001;
  const currentDeviceNumber = 900;
  late FakePairwiseStore store;
  late FakeLiveResolver resolver;
  late FakeSelectiveClaims claims;
  late FakeOutboundCrypto crypto;
  late PairwiseFanoutCoordinator coordinator;

  setUp(() {
    store = FakePairwiseStore();
    resolver = FakeLiveResolver({
      uuid(peerUserNumber): [live(peerUserNumber, 1), live(peerUserNumber, 2)],
      uuid(currentUserNumber): [
        live(currentUserNumber, currentDeviceNumber),
        live(currentUserNumber, 3),
        live(currentUserNumber, 4),
      ],
    });
    store.contexts.addAll({
      uuid(1): context(primary: session(peerUserNumber, 1)),
      uuid(2): context(),
      uuid(3): context(
        primary: session(
          currentUserNumber,
          3,
          repairState: PairwiseRepairState.replacementPending,
          repairAuthorization: bytes(88, 8),
        ),
      ),
      uuid(4): context(primary: session(currentUserNumber, 4)),
    });
    claims = FakeSelectiveClaims(resolver);
    crypto = FakeOutboundCrypto();
    coordinator = PairwiseFanoutCoordinator(
      store: store,
      liveDevices: resolver,
      claims: claims,
      crypto: crypto,
      clock: const FixedClock(),
    );
  });

  test(
    'fans out to every verified peer and own-other device, claiming only missing or repair',
    () async {
      final first = await coordinator.prepareAndQueue(
        operationId: 'operation-1',
        eventId: 'event-1',
        currentUserId: uuid(currentUserNumber),
        currentDeviceId: uuid(currentDeviceNumber),
        peerUserId: uuid(peerUserNumber),
        openedOpaquePayload: bytes(16, 9),
      );

      expect(first, isA<Success<DurablePairwiseOperation>>());
      expect(resolver.calls, [uuid(peerUserNumber), uuid(currentUserNumber)]);
      expect(claims.calls, {
        uuid(peerUserNumber): [uuid(2)],
        uuid(currentUserNumber): [uuid(3)],
      });
      expect(crypto.calls.map((call) => call.recipient.deviceId), [
        uuid(1),
        uuid(2),
        uuid(3),
        uuid(4),
      ]);
      expect(crypto.calls[0].claimedBundle, isNull);
      expect(crypto.calls[1].claimedBundle, isNotNull);
      expect(crypto.calls[2].claimedBundle, isNotNull);
      expect(crypto.calls[3].claimedBundle, isNull);
      expect(
        store.commits.single.targets.map((target) => target.recipientDeviceId),
        [uuid(1), uuid(2), uuid(3), uuid(4)],
      );
      expect(
        store.commits.single.targets
            .map((target) => target.recipientDeviceId)
            .contains(uuid(currentDeviceNumber)),
        isFalse,
      );
      expect(store.commits.single.openedLocalPayload, bytes(16, 9));
      expect(store.commits.single.expectedDeviceStateVersion, 7);

      final retry = await coordinator.prepareAndQueue(
        operationId: 'operation-1',
        eventId: 'event-1',
        currentUserId: uuid(currentUserNumber),
        currentDeviceId: uuid(currentDeviceNumber),
        peerUserId: uuid(peerUserNumber),
        openedOpaquePayload: bytes(16, 9),
      );

      expect(retry, isA<Success<DurablePairwiseOperation>>());
      expect(resolver.calls, hasLength(2));
      expect(crypto.calls, hasLength(4));
      expect(store.commits, hasLength(1));
      final firstBytes = (first as Success<DurablePairwiseOperation>)
          .value
          .targets
          .map((target) => target.exactCiphertext)
          .toList();
      final retryBytes = (retry as Success<DurablePairwiseOperation>)
          .value
          .targets
          .map((target) => target.exactCiphertext)
          .toList();
      expect(retryBytes, firstBytes);
    },
  );

  test(
    'fails closed when verified own live set omits the current device',
    () async {
      resolver.devices[uuid(currentUserNumber)] = [live(currentUserNumber, 3)];

      final result = await coordinator.prepareAndQueue(
        operationId: 'operation-2',
        eventId: 'event-2',
        currentUserId: uuid(currentUserNumber),
        currentDeviceId: uuid(currentDeviceNumber),
        peerUserId: uuid(peerUserNumber),
        openedOpaquePayload: bytes(16, 2),
      );

      expect(
        (result as FailureResult<DurablePairwiseOperation>).failure,
        isA<SecurityFailure>(),
      );
      expect(claims.calls, isEmpty);
      expect(crypto.calls, isEmpty);
    },
  );

  test('can exclude own devices for a later multi-user group fanout', () async {
    final result = await coordinator.prepareAndQueue(
      operationId: 'group-user-2',
      eventId: 'group-event',
      currentUserId: uuid(currentUserNumber),
      currentDeviceId: uuid(currentDeviceNumber),
      peerUserId: uuid(peerUserNumber),
      openedOpaquePayload: bytes(16, 10),
      includeOwnDevices: false,
    );

    expect(result, isA<Success<DurablePairwiseOperation>>());
    expect(crypto.calls.map((call) => call.recipient.deviceId), [
      uuid(1),
      uuid(2),
    ]);
    expect(claims.calls.keys, [uuid(peerUserNumber)]);
  });

  test(
    'fails closed if live set changes between resolve and selective claim',
    () async {
      claims.mutateLiveUserId = uuid(peerUserNumber);

      final result = await coordinator.prepareAndQueue(
        operationId: 'operation-3',
        eventId: 'event-3',
        currentUserId: uuid(currentUserNumber),
        currentDeviceId: uuid(currentDeviceNumber),
        peerUserId: uuid(peerUserNumber),
        openedOpaquePayload: bytes(16, 3),
      );

      expect(
        (result as FailureResult<DurablePairwiseOperation>).failure,
        isA<SecurityFailure>(),
      );
      expect(crypto.calls, isEmpty);
      expect(store.commits, isEmpty);
    },
  );

  test(
    'Saved Messages commits locally with no fabricated delivery target',
    () async {
      final currentUserId = uuid(currentUserNumber);
      final currentDeviceId = uuid(currentDeviceNumber);
      resolver.devices[currentUserId] = [
        live(currentUserNumber, currentDeviceNumber),
      ];
      final event = ApplicationEventRecord(
        version: 1,
        eventId: bytes(16, 70),
        conversationId: bytes(32, 71),
        kindValue: ApplicationEventKind.messageCreate.wireValue,
        senderUserId: protocolUuidBytes(currentUserId),
        senderDeviceId: protocolUuidBytes(currentDeviceId),
        senderCounter: 1,
        createdMs: 1700000000000,
        references: const [],
        body: MessageCreateBody(messageId: bytes(16, 72), text: 'saved'),
      );
      final encoded = bytes(64, 73);
      final eventId = protocolBytesToHex(event.eventId);
      final commit = ApplicationEventCommit(
        event: event,
        canonicalBytes: encoded,
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
        conversationKind: 2,
        peerUserId: null,
        localOrigin: true,
        authenticatedAt: DateTime.fromMillisecondsSinceEpoch(
          1700000001000,
          isUtc: true,
        ),
      );

      final echoed = await coordinator.commitLocalEcho(
        operationId: 'application:$eventId',
        eventId: eventId,
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
        peerUserId: currentUserId,
        openedOpaquePayload: encoded,
        applicationEvent: commit,
      );
      final owed = OwedSendPreparation(
        operationId: 'application:$eventId',
        eventId: eventId,
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
        peerUserId: currentUserId,
      );
      final first = await coordinator.prepareOwedSend(owed);
      final retry = await coordinator.prepareOwedSend(owed);

      expect(echoed, isA<Success<void>>());
      expect(first, isA<Success<void>>());
      expect(retry, isA<Success<void>>());
      expect(store.localCommits, hasLength(1));
      expect(store.commits, isEmpty);
      expect(store.settled, ['application:$eventId', 'application:$eventId']);
      expect(crypto.calls, isEmpty);
    },
  );

  test('an echo reaches storage without resolving a single device', () async {
    final currentUserId = uuid(currentUserNumber);
    final currentDeviceId = uuid(currentDeviceNumber);
    final event = ApplicationEventRecord(
      version: 1,
      eventId: bytes(16, 80),
      conversationId: bytes(32, 81),
      kindValue: ApplicationEventKind.messageCreate.wireValue,
      senderUserId: protocolUuidBytes(currentUserId),
      senderDeviceId: protocolUuidBytes(currentDeviceId),
      senderCounter: 1,
      createdMs: 1700000000000,
      references: const [],
      body: MessageCreateBody(messageId: bytes(16, 80), text: 'echo'),
    );
    final eventId = protocolBytesToHex(event.eventId);

    final echoed = await coordinator.commitLocalEcho(
      operationId: 'application:$eventId',
      eventId: eventId,
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      peerUserId: uuid(peerUserNumber),
      openedOpaquePayload: bytes(64, 80),
      applicationEvent: ApplicationEventCommit(
        event: event,
        canonicalBytes: bytes(64, 80),
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
        conversationKind: 0,
        peerUserId: uuid(peerUserNumber),
        localOrigin: true,
        authenticatedAt: DateTime.fromMillisecondsSinceEpoch(
          1700000001000,
          isUtc: true,
        ),
      ),
    );

    expect(echoed, isA<Success<void>>());
    expect(store.localCommits, hasLength(1));
    expect(resolver.calls, isEmpty);
    expect(claims.calls, isEmpty);
    expect(crypto.calls, isEmpty);
    expect(store.commits, isEmpty);
  });

  test(
    'a group send makes one copy for each live device of each member',
    () async {
      const secondMemberNumber = 1002;
      resolver.devices[uuid(secondMemberNumber)] = [
        live(secondMemberNumber, 5),
        live(secondMemberNumber, 6),
        live(secondMemberNumber, 7),
      ];
      store.contexts.addAll({
        uuid(5): context(primary: session(secondMemberNumber, 5)),
        uuid(6): context(),
        uuid(7): context(),
      });
      store.durable['application:group'] = DurablePairwiseOperation(
        operationId: 'application:group',
        eventId: 'group-event',
        currentDeviceId: uuid(currentDeviceNumber),
        openedLocalPayload: bytes(16, 12),
        targets: const [],
      );

      final result = await coordinator.prepareOwedSend(
        OwedSendPreparation(
          operationId: 'application:group',
          eventId: 'group-event',
          currentUserId: uuid(currentUserNumber),
          currentDeviceId: uuid(currentDeviceNumber),
          peerUserId: uuid(peerUserNumber),
          audienceUserIds: [uuid(secondMemberNumber), uuid(peerUserNumber)],
        ),
      );

      expect(result, isA<Success<void>>());
      // One operation, under the one event id the message reads its transport
      // state from, however many members the group has.
      final commit = store.commits.single;
      expect(commit.eventId, 'group-event');
      expect(commit.openedLocalPayload, bytes(16, 12));
      expect(
        commit.targets.map(
          (target) => (target.recipientUserId, target.recipientDeviceId),
        ),
        [
          (uuid(peerUserNumber), uuid(1)),
          (uuid(peerUserNumber), uuid(2)),
          (uuid(currentUserNumber), uuid(3)),
          (uuid(currentUserNumber), uuid(4)),
          (uuid(secondMemberNumber), uuid(5)),
          (uuid(secondMemberNumber), uuid(6)),
          (uuid(secondMemberNumber), uuid(7)),
        ],
      );
      expect(crypto.calls.map((call) => call.recipient.deviceId), [
        for (var device = 1; device <= 7; device += 1) uuid(device),
      ]);
      expect(claims.calls, {
        uuid(peerUserNumber): [uuid(2)],
        uuid(currentUserNumber): [uuid(3)],
        uuid(secondMemberNumber): [uuid(6), uuid(7)],
      });
      expect(store.reconciliations.map((entry) => entry.$1), [
        uuid(peerUserNumber),
        uuid(secondMemberNumber),
        uuid(currentUserNumber),
      ]);
    },
  );

  test(
    'a member with no live device leaves the other members their copies',
    () async {
      const secondMemberNumber = 1002;
      resolver.devices[uuid(secondMemberNumber)] = [];
      store.durable['application:group'] = DurablePairwiseOperation(
        operationId: 'application:group',
        eventId: 'group-event',
        currentDeviceId: uuid(currentDeviceNumber),
        openedLocalPayload: bytes(16, 13),
        targets: const [],
      );

      final result = await coordinator.prepareOwedSend(
        OwedSendPreparation(
          operationId: 'application:group',
          eventId: 'group-event',
          currentUserId: uuid(currentUserNumber),
          currentDeviceId: uuid(currentDeviceNumber),
          peerUserId: uuid(peerUserNumber),
          audienceUserIds: [uuid(peerUserNumber), uuid(secondMemberNumber)],
        ),
      );

      expect(result, isA<Success<void>>());
      expect(
        store.commits.single.targets.map((target) => target.recipientDeviceId),
        [uuid(1), uuid(2), uuid(3), uuid(4)],
      );
    },
  );

  test(
    "a group with no other active member reaches this account's devices",
    () async {
      store.durable['application:alone'] = DurablePairwiseOperation(
        operationId: 'application:alone',
        eventId: 'alone-event',
        currentDeviceId: uuid(currentDeviceNumber),
        openedLocalPayload: bytes(16, 14),
        targets: const [],
      );

      final result = await coordinator.prepareOwedSend(
        OwedSendPreparation(
          operationId: 'application:alone',
          eventId: 'alone-event',
          currentUserId: uuid(currentUserNumber),
          currentDeviceId: uuid(currentDeviceNumber),
          peerUserId: uuid(currentUserNumber),
          audienceUserIds: const <String>[],
        ),
      );

      expect(result, isA<Success<void>>());
      expect(
        store.commits.single.targets.map((target) => target.recipientDeviceId),
        [uuid(3), uuid(4)],
      );
    },
  );

  test('an owed send whose event has gone is retired, not retried', () async {
    final owed = OwedSendPreparation(
      operationId: 'application:missing',
      eventId: 'missing',
      currentUserId: uuid(currentUserNumber),
      currentDeviceId: uuid(currentDeviceNumber),
      peerUserId: uuid(peerUserNumber),
    );

    final result = await coordinator.prepareOwedSend(owed);

    expect(result, isA<Success<void>>());
    expect(store.settled, ['application:missing']);
    expect(resolver.calls, isEmpty);
  });
}

final class FakePairwiseStore implements PairwiseTransportStore {
  final Map<String, PairwisePreparationContext> contexts = {};
  final Map<String, DurablePairwiseOperation> durable = {};
  final List<PairwiseSendCommit> commits = [];
  final List<ApplicationEventCommit> localCommits = [];
  final List<String> settled = [];
  final List<String> rearmed = [];
  final List<(String, Set<String>)> reconciliations = [];

  @override
  Future<Result<void>> commitLocalEcho({
    required String operationId,
    required String eventId,
    required String currentUserId,
    required String currentDeviceId,
    required String peerUserId,
    required Uint8List openedLocalPayload,
    required ApplicationEventCommit applicationEvent,
  }) async {
    localCommits.add(applicationEvent);
    durable[operationId] = DurablePairwiseOperation(
      operationId: operationId,
      eventId: eventId,
      currentDeviceId: currentDeviceId,
      openedLocalPayload: openedLocalPayload,
      targets: const [],
    );
    return const Result.success(null);
  }

  @override
  Future<Result<void>> settleSendPreparation(String operationId) async {
    settled.add(operationId);
    return const Result.success(null);
  }

  @override
  Future<Result<bool>> rearmFailedSend(String operationId) async {
    rearmed.add(operationId);
    return const Result.success(true);
  }

  @override
  Future<Result<PairwisePreparationContext>> readPreparationContext({
    required String localDeviceId,
    required String remoteUserId,
    required String remoteDeviceId,
  }) async => Result.success(contexts[remoteDeviceId]!);

  @override
  Future<Result<DurablePairwiseOperation?>> readPreparedOperation(
    String operationId,
  ) async => Result.success(durable[operationId]);

  @override
  Future<Result<void>> commitPreparedSend(PairwiseSendCommit commit) async {
    commits.add(commit);
    final operation = DurablePairwiseOperation(
      operationId: commit.operationId,
      eventId: commit.eventId,
      currentDeviceId: commit.currentDeviceId,
      openedLocalPayload: commit.openedLocalPayload,
      targets: [
        for (final target in commit.targets)
          DurablePairwiseTarget(
            recipientUserId: target.recipientUserId,
            recipientDeviceId: target.recipientDeviceId,
            exactCiphertext: target.exactCiphertext,
          ),
      ],
    );
    durable[commit.operationId] = operation;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> reconcileRemoteLiveDevices({
    required String remoteUserId,
    required Set<String> liveDeviceIds,
  }) async {
    reconciliations.add((remoteUserId, Set.of(liveDeviceIds)));
    return const Result.success(null);
  }

  @override
  Future<Result<bool>> commitPreparedReceive(
    PairwiseReceiveCommit commit,
  ) async =>
      const Result.failure(SecurityFailure(SecurityFailureKind.policyBlocked));

  @override
  Future<Result<void>> invalidateRemoteDevices({
    required String remoteUserId,
    required Set<String> remoteDeviceIds,
  }) async => const Result.success(null);

  @override
  Future<Result<PairwiseInboundPreparationContext>> readInboundContext({
    required String localDeviceId,
    Uint8List? sessionId,
  }) async =>
      const Result.failure(SecurityFailure(SecurityFailureKind.policyBlocked));

  @override
  Future<Result<void>> pruneRetainedMetadata({
    required DateTime now,
    List<ErasedPairwiseSignedPrekeyPair> erasedSignedPrekeys = const [],
  }) async => const Result.success(null);
}

final class FakeLiveResolver implements PairwiseLiveDeviceResolverPort {
  FakeLiveResolver(this.devices);

  final Map<String, List<VerifiedPairwiseLiveDevice>> devices;
  final List<String> calls = [];

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async {
    calls.add(userId);
    return Result.success(List.of(devices[userId]!));
  }
}

final class FakeSelectiveClaims implements PairwiseSelectiveClaimPort {
  FakeSelectiveClaims(this.resolver);

  final FakeLiveResolver resolver;
  final Map<String, List<String>> calls = {};
  String? mutateLiveUserId;

  @override
  Future<Result<VerifiedPairwiseClaims>> claimVerifiedDevices({
    required String userId,
    required List<String> deviceIds,
  }) async {
    calls[userId] = List.of(deviceIds);
    final liveDevices = List<VerifiedPairwiseLiveDevice>.of(
      resolver.devices[userId]!,
    );
    if (mutateLiveUserId == userId) {
      liveDevices.add(live(int.parse(userId.substring(24), radix: 16), 77));
    }
    return Result.success(
      VerifiedPairwiseClaims(
        liveDevices: liveDevices,
        claims: {
          for (final deviceId in deviceIds)
            deviceId: VerifiedPairwiseClaim(
              device: liveDevices.singleWhere(
                (device) => device.deviceId == deviceId,
              ),
              bundle: bundle(deviceId),
            ),
        },
      ),
    );
  }
}

final class FakeOutboundCrypto implements PairwiseOutboundPreparationPort {
  final List<CryptoCall> calls = [];

  @override
  Future<Result<PairwisePreparedOutbound>> prepareOutbound({
    required String currentDeviceId,
    required VerifiedPairwiseLiveDevice recipient,
    required Uint8List openedOpaquePayload,
    required int migrationUnixDay,
    required PairwisePreparationContext context,
    required VerifiedPairwiseClaim? claim,
  }) async {
    calls.add(CryptoCall(recipient: recipient, claim: claim));
    final marker = int.parse(recipient.deviceId.substring(24), radix: 16);
    return Result.success(
      PairwisePreparedOutbound(
        exactCiphertext: bytes(1024, marker),
        sessionId: context.primary?.sessionId ?? bytes(16, marker),
        nextOpaqueSessionState: bytes(32, marker),
        nextSkippedKeyCount: 0,
        disposition: PairwiseSessionDisposition.primaryBidirectional,
      ),
    );
  }
}

final class CryptoCall {
  const CryptoCall({required this.recipient, required this.claim});

  final VerifiedPairwiseLiveDevice recipient;
  final VerifiedPairwiseClaim? claim;

  ClaimedPrekeyBundle? get claimedBundle => claim?.bundle;
}

final class FixedClock implements TimeSource {
  const FixedClock();

  @override
  DateTime now() => DateTime.utc(2026, 7, 29);
}

PairwisePreparationContext context({PairwiseSessionSnapshot? primary}) =>
    PairwisePreparationContext(
      primary: primary,
      alternate: null,
      deviceState: PairwiseDeviceStateSnapshot(
        opaqueState: bytes(32, 7),
        stateVersion: 7,
      ),
      otherSessionsSkippedKeyCount: 0,
    );

PairwiseSessionSnapshot session(
  int userNumber,
  int deviceNumber, {
  PairwiseRepairState repairState = PairwiseRepairState.ready,
  Uint8List? repairAuthorization,
}) => PairwiseSessionSnapshot(
  localDeviceId: uuid(900),
  remoteUserId: uuid(userNumber),
  remoteDeviceId: uuid(deviceNumber),
  sessionId: bytes(16, deviceNumber),
  opaqueState: bytes(32, deviceNumber),
  stateVersion: 1,
  skippedKeyCount: 0,
  disposition: PairwiseSessionDisposition.primaryBidirectional,
  repairState: repairState,
  repairAuthorization: repairAuthorization,
);

VerifiedPairwiseLiveDevice live(int userNumber, int deviceNumber) =>
    VerifiedPairwiseLiveDevice(
      userId: uuid(userNumber),
      device: PeerPublicDevice(
        deviceId: uuid(deviceNumber),
        identityPublic: bytes(64, deviceNumber),
        registrationId: 0,
        bundleVersion: 1,
        crossSignature: bytes(64, deviceNumber + 1),
      ),
      selfSigningPublic: bytes(32, userNumber),
    );

ClaimedPrekeyBundle bundle(String deviceId) => ClaimedPrekeyBundle(
  deviceId: deviceId,
  registrationId: 1,
  identityPublic: bytes(64, 1),
  signedPrekeyId: 1,
  signedPrekeyPublic: bytes(32, 2),
  signedPrekeySignature: bytes(64, 3),
  crossSignature: bytes(64, 4),
  bundleVersion: 1,
  pqSignedPrekeyId: 2,
  pqSignedPrekeyPublic: bytes(1184, 5),
  pqSignedPrekeySignature: bytes(64, 6),
);

String uuid(int value) =>
    '00000000-0000-0000-0000-${value.toRadixString(16).padLeft(12, '0')}';

Uint8List bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker & 0xff));
