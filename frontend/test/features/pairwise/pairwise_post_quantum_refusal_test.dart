import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/pairwise_session_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/infrastructure/native_pairwise_outbound_preparation.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _ownUser = '10000000-0000-4000-8000-000000000001';
const _ownDevice = '20000000-0000-4000-8000-000000000001';
const _peerUser = '30000000-0000-4000-8000-000000000001';
const _peerDevice = '40000000-0000-4000-8000-000000000001';

/// Every session, a group's included, starts from X25519 plus ML-KEM-768, and
/// a claimed bundle that lacks the ML-KEM half is refused or flagged, never
/// silently downgraded (`backend/CLIENT_CONTRACT.md` §F). This client refuses
/// it, and refuses it twice: the claim adapter rejects the bundle, and the
/// outbound preparation would not hand one to the core if it got past that.
void main() {
  group('a claimed bundle with no PQ material', () {
    test('is refused by the claim', () async {
      final result = await ContactSelectivePairwiseClaimAdapter(
        delegate: _Peers(postQuantum: false),
        currentUserId: _ownUser,
      ).claimVerifiedDevices(userId: _peerUser, deviceIds: const [_peerDevice]);

      expect(
        (result as FailureResult<VerifiedPairwiseClaims>).failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    });

    test('is what the refusal turns on', () async {
      final result = await ContactSelectivePairwiseClaimAdapter(
        delegate: _Peers(postQuantum: true),
        currentUserId: _ownUser,
      ).claimVerifiedDevices(userId: _peerUser, deviceIds: const [_peerDevice]);

      expect((result as Success<VerifiedPairwiseClaims>).value.claims.keys, [
        _peerDevice,
      ]);
    });

    test('is never handed to the core to start a session', () async {
      final crypto = _SessionCrypto();
      final recipient = _live(_peerUser, _peerDevice);

      final result = await NativePairwiseOutboundPreparation(crypto)
          .prepareOutbound(
            currentDeviceId: _ownDevice,
            recipient: recipient,
            openedOpaquePayload: _bytes(64, 9),
            migrationUnixDay: 20709,
            context: PairwisePreparationContext(
              primary: null,
              alternate: null,
              deviceState: PairwiseDeviceStateSnapshot(
                opaqueState: _bytes(32, 1),
                stateVersion: 1,
              ),
              otherSessionsSkippedKeyCount: 0,
            ),
            claim: VerifiedPairwiseClaim(
              device: recipient,
              bundle: _bundle(_peerDevice, postQuantum: false),
            ),
          );

      expect(
        (result as FailureResult<PairwisePreparedOutbound>).failure,
        const SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
      expect(crypto.initiated, isEmpty);
    });

    test('leaves a fan-out with no session and no copy', () async {
      final database = LocalDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database
          .into(database.secureSecrets)
          .insert(
            SecureSecretsCompanion.insert(
              secretId: 'current-device-key-state-v1',
              kind: 0,
              wrappedCiphertextOrOpaqueHandle: Uint8List.fromList([7]),
              formatVersion: 2,
            ),
          );

      Future<(Result<DurablePairwiseOperation>, _SessionCrypto)> fanOut(
        String operationId, {
        required bool postQuantum,
      }) async {
        final peers = _Peers(postQuantum: postQuantum);
        final crypto = _SessionCrypto();
        final result =
            await PairwiseFanoutCoordinator(
              store: DriftPairwiseTransportStore(database),
              liveDevices: ContactPairwiseLiveDeviceResolverAdapter(
                delegate: peers,
                currentUserId: _ownUser,
              ),
              claims: ContactSelectivePairwiseClaimAdapter(
                delegate: peers,
                currentUserId: _ownUser,
              ),
              crypto: NativePairwiseOutboundPreparation(crypto),
              clock: const _Clock(),
            ).prepareAndQueue(
              operationId: operationId,
              eventId: operationId,
              currentUserId: _ownUser,
              currentDeviceId: _ownDevice,
              peerUserId: _peerUser,
              openedOpaquePayload: _bytes(64, 9),
              includeOwnDevices: false,
            );
        return (result, crypto);
      }

      final (refused, refusedCrypto) = await fanOut(
        'without-pq',
        postQuantum: false,
      );

      expect(
        (refused as FailureResult<DurablePairwiseOperation>).failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
      expect(refusedCrypto.initiated, isEmpty);
      expect(await database.select(database.pairwiseSessions).get(), isEmpty);
      expect(await database.select(database.outboxOperations).get(), isEmpty);

      // The same device with its ML-KEM half reaches the core, which is the
      // step the refusal above withheld.
      final (_, reachedCrypto) = await fanOut('with-pq', postQuantum: true);
      expect(reachedCrypto.initiated, [_peerDevice]);
    });
  });
}

/// One account and one device for each side, both verified, whose claimed
/// bundles carry the ML-KEM half only when [postQuantum] says so.
final class _Peers
    implements VerifiedLiveDeviceResolverPort, SelectivePeerPrekeyClaimPort {
  _Peers({required this.postQuantum});

  final bool postQuantum;

  @override
  Future<Result<AuthenticatedPeer>> resolveLiveDevices({
    required String userId,
  }) async => Result.success(_peer(userId, const []));

  @override
  Future<Result<AuthenticatedPeer>> refreshPeerForDevices({
    required String userId,
    required List<String> deviceIds,
  }) async => Result.success(
    _peer(userId, [
      for (final deviceId in deviceIds)
        _bundle(deviceId, postQuantum: postQuantum),
    ]),
  );

  AuthenticatedPeer _peer(String userId, List<ClaimedPrekeyBundle> bundles) =>
      AuthenticatedPeer(
        trust: ContactTrustRecord(
          userId: userId,
          state: ContactTrustState.verified,
          identity: PeerIdentityPublic(
            masterPublic: _bytes(32, 1),
            selfSigningPublic: _bytes(32, 2),
            userSigningPublic: _bytes(32, 3),
            masterSignature: _bytes(64, 4),
            version: 1,
          ),
        ),
        devices: [_publicDevice(userId == _ownUser ? _ownDevice : _peerDevice)],
        claimedBundles: bundles,
      );
}

/// Records every session the core is asked to start. What the core would then
/// do is not under test; being asked at all is.
final class _SessionCrypto implements PairwiseSessionCryptoPort {
  final initiated = <String>[];

  @override
  Future<Result<PairwiseInitiationResult>> initiate({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List senderDeviceId,
    required Uint8List recipientUserId,
    required Uint8List recipientDeviceId,
    required Uint8List recipientSelfSigningPublic,
    required ClaimedPrekeyBundle verifiedBundle,
    required Uint8List innerPayload,
    required int otherSessionsSkippedKeys,
    Uint8List? repairAuthorization,
  }) async {
    initiated.add(verifiedBundle.deviceId);
    return const Result.failure(
      CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 9, 13, 9);
}

VerifiedPairwiseLiveDevice _live(String userId, String deviceId) =>
    VerifiedPairwiseLiveDevice(
      userId: userId,
      device: _publicDevice(deviceId),
      selfSigningPublic: _bytes(32, 2),
    );

PeerPublicDevice _publicDevice(String deviceId) => PeerPublicDevice(
  deviceId: deviceId,
  identityPublic: _bytes(64, 5),
  registrationId: 1,
  bundleVersion: 1,
  crossSignature: _bytes(64, 6),
);

ClaimedPrekeyBundle _bundle(String deviceId, {required bool postQuantum}) =>
    ClaimedPrekeyBundle(
      deviceId: deviceId,
      registrationId: 1,
      identityPublic: _bytes(64, 5),
      signedPrekeyId: 1,
      signedPrekeyPublic: _bytes(32, 7),
      signedPrekeySignature: _bytes(64, 8),
      crossSignature: _bytes(64, 6),
      bundleVersion: 1,
      pqSignedPrekeyId: postQuantum ? 2 : null,
      pqSignedPrekeyPublic: postQuantum ? _bytes(1184, 9) : null,
      pqSignedPrekeySignature: postQuantum ? _bytes(64, 10) : null,
    );

Uint8List _bytes(int length, int marker) =>
    Uint8List.fromList(List<int>.filled(length, marker & 0xff));
