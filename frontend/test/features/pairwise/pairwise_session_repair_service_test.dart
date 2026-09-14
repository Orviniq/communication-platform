import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/pairwise_session_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart'
    as native;
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_session_repair_service.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _localDevice = '10000000-0000-4000-8000-000000000001';
const _peer = '20000000-0000-4000-8000-000000000001';
const _ready = '30000000-0000-4000-8000-000000000001';
const _noSession = '30000000-0000-4000-8000-000000000002';
const _repairing = '30000000-0000-4000-8000-000000000003';

/// `backend/CLIENT_CONTRACT.md` §H: a session a lost envelope may have
/// broken is repaired through its authenticated repair path. The request is
/// sealed by the native core and committed as exact ciphertext, with the
/// session marked as waiting for the replacement, before anything is sent.
void main() {
  late _Store store;
  late _Resolver resolver;
  late _Crypto crypto;
  late PairwiseSessionRepairService service;

  setUp(() {
    store = _Store()
      ..contexts.addAll({
        _ready: _context(primary: _session(_ready, marker: 0x11)),
        _noSession: _context(),
        _repairing: _context(
          primary: _session(
            _repairing,
            marker: 0x33,
            repairState: PairwiseRepairState.authenticatedRequestPending,
          ),
        ),
      });
    resolver = _Resolver(
      Result.success([_live(_repairing), _live(_noSession), _live(_ready)]),
    );
    crypto = _Crypto();
    service = PairwiseSessionRepairService(
      store: store,
      liveDevices: resolver,
      crypto: crypto,
      clock: const _Clock(),
    );
  });

  test('each ready session with the user is asked to repair once', () async {
    final result = await service.requestRepairWithUser(
      localDeviceId: _localDevice,
      remoteUserId: _peer,
    );

    expect((result as Success<int>).value, 1);
    final call = crypto.calls.single;
    expect(call.recipientDeviceId, protocolUuidBytes(_ready));
    expect(call.session.sessionId, _bytes(16, 0x11));
    expect(call.session.opaqueState, _bytes(32, 0x11));
    expect(call.deviceState, _bytes(32, 7));
    expect(call.otherSessionsSkippedKeys, 5);
    expect(
      call.unixDay,
      DateTime.utc(2026, 9, 13).millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay,
    );

    final commit = store.commits.single;
    final operationId = 'pairwise-repair:group-state:${'11' * 16}';
    expect(commit.operationId, operationId);
    expect(commit.eventId, operationId);
    expect(commit.currentDeviceId, _localDevice);
    expect(commit.expectedDeviceStateVersion, 9);
    final target = commit.targets.single;
    expect(target.recipientUserId, _peer);
    expect(target.recipientDeviceId, _ready);
    expect(target.exactCiphertext, _bytes(1024, 0x5a));
    final transition = target.sessionTransition;
    expect(transition.sessionId, _bytes(16, 0x99));
    expect(transition.nextOpaqueState, _bytes(32, 0x98));
    expect(transition.expectedStateVersion, 4);
    expect(transition.nextStateVersion, 5);
    expect(transition.nextSkippedKeyCount, 2);
    expect(
      transition.disposition,
      PairwiseSessionDisposition.primaryBidirectional,
    );
    expect(
      transition.repairState,
      PairwiseRepairState.authenticatedRequestPending,
    );
  });

  test('a session already asked is not asked again', () async {
    final operationId = 'pairwise-repair:group-state:${'11' * 16}';
    store.durable[operationId] = DurablePairwiseOperation(
      operationId: operationId,
      eventId: operationId,
      currentDeviceId: _localDevice,
      openedLocalPayload: _bytes(8, 1),
      targets: const [],
    );

    final result = await service.requestRepairWithUser(
      localDeviceId: _localDevice,
      remoteUserId: _peer,
    );

    expect((result as Success<int>).value, 0);
    expect(crypto.calls, isEmpty);
    expect(store.commits, isEmpty);
  });

  test('devices that cannot be resolved repair nothing', () async {
    resolver.result = const Result.failure(
      TransportFailure(TransportFailureKind.timeout),
    );

    final result = await service.requestRepairWithUser(
      localDeviceId: _localDevice,
      remoteUserId: _peer,
    );

    expect(
      (result as FailureResult<int>).failure,
      const TransportFailure(TransportFailureKind.timeout),
    );
    expect(crypto.calls, isEmpty);
    expect(store.commits, isEmpty);
  });
}

PairwisePreparationContext _context({PairwiseSessionSnapshot? primary}) =>
    PairwisePreparationContext(
      primary: primary,
      alternate: null,
      deviceState: PairwiseDeviceStateSnapshot(
        opaqueState: _bytes(32, 7),
        stateVersion: 9,
      ),
      otherSessionsSkippedKeyCount: 5,
    );

PairwiseSessionSnapshot _session(
  String remoteDeviceId, {
  required int marker,
  PairwiseRepairState repairState = PairwiseRepairState.ready,
}) => PairwiseSessionSnapshot(
  localDeviceId: _localDevice,
  remoteUserId: _peer,
  remoteDeviceId: remoteDeviceId,
  sessionId: _bytes(16, marker),
  opaqueState: _bytes(32, marker),
  stateVersion: 4,
  skippedKeyCount: 0,
  disposition: PairwiseSessionDisposition.primaryBidirectional,
  repairState: repairState,
  repairAuthorization: null,
);

VerifiedPairwiseLiveDevice _live(String deviceId) => VerifiedPairwiseLiveDevice(
  userId: _peer,
  device: PeerPublicDevice(
    deviceId: deviceId,
    identityPublic: _bytes(64, 1),
    registrationId: 1,
    bundleVersion: 1,
    crossSignature: _bytes(64, 2),
  ),
  selfSigningPublic: _bytes(32, 3),
);

Uint8List _bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker & 0xff));

typedef _RepairCall = ({
  Uint8List deviceState,
  int unixDay,
  Uint8List recipientDeviceId,
  native.PairwiseSessionState session,
  int otherSessionsSkippedKeys,
});

final class _Crypto implements PairwiseSessionCryptoPort {
  final calls = <_RepairCall>[];

  @override
  Future<Result<native.PreparedPairwiseEnvelope>>
  createAuthenticatedRepairRequest({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List recipientDeviceId,
    required native.PairwiseSessionState session,
    required int otherSessionsSkippedKeys,
  }) async {
    calls.add((
      deviceState: deviceState,
      unixDay: unixDay,
      recipientDeviceId: recipientDeviceId,
      session: session,
      otherSessionsSkippedKeys: otherSessionsSkippedKeys,
    ));
    return Result.success(
      native.PreparedPairwiseEnvelope(
        ciphertext: _bytes(1024, 0x5a),
        nextSession: native.PairwiseSessionState(
          sessionId: _bytes(16, 0x99),
          opaqueState: _bytes(32, 0x98),
          skippedKeyCount: 2,
        ),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Store implements PairwiseTransportStore {
  final contexts = <String, PairwisePreparationContext>{};
  final durable = <String, DurablePairwiseOperation>{};
  final commits = <PairwiseSendCommit>[];

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
    return const Result.success(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Resolver implements PairwiseLiveDeviceResolverPort {
  _Resolver(this.result);

  Result<List<VerifiedPairwiseLiveDevice>> result;

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async => result;
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 9, 13, 18);
}
