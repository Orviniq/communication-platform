import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/pairwise_session_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart'
    as native;
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';

/// Starts the authenticated repair of this device's sessions with one user.
///
/// Each ready primary session gets one authenticated repair request, sent
/// through its still-authenticated outgoing chain (`pairwise-transport-v1.md`,
/// "Replay, skipped keys, and repair"). The peer device answers the next time it
/// sends to this device, with a fresh hybrid session that replaces the old one,
/// so whatever a lost envelope did to the old session stops mattering.
final class PairwiseSessionRepairService {
  const PairwiseSessionRepairService({
    required this.store,
    required this.liveDevices,
    required this.crypto,
    required this.clock,
  });

  final PairwiseTransportStore store;
  final PairwiseLiveDeviceResolverPort liveDevices;
  final PairwiseSessionCryptoPort crypto;
  final TimeSource clock;

  /// Returns how many sessions a repair was requested for. A session with no
  /// primary state, or with a repair already under way, is left alone.
  Future<Result<int>> requestRepairWithUser({
    required String localDeviceId,
    required String remoteUserId,
  }) async {
    final devicesResult = await liveDevices.resolveVerifiedLiveDevices(
      remoteUserId,
    );
    if (devicesResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final local = localDeviceId.toLowerCase();
    final devices =
        (devicesResult as Success<List<VerifiedPairwiseLiveDevice>>).value
            .where((device) => device.deviceId.toLowerCase() != local)
            .toList(growable: false)
          ..sort((left, right) => left.deviceId.compareTo(right.deviceId));
    var requested = 0;
    for (final device in devices) {
      final contextResult = await store.readPreparationContext(
        localDeviceId: local,
        remoteUserId: device.userId,
        remoteDeviceId: device.deviceId,
      );
      if (contextResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final context =
          (contextResult as Success<PairwisePreparationContext>).value;
      final session = context.primary;
      if (session == null ||
          session.disposition !=
              PairwiseSessionDisposition.primaryBidirectional ||
          session.repairState != PairwiseRepairState.ready) {
        continue;
      }
      final operationId =
          'pairwise-repair:group-state:${protocolBytesToHex(session.sessionId)}';
      final existingResult = await store.readPreparedOperation(operationId);
      if (existingResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      if ((existingResult as Success<DurablePairwiseOperation?>).value !=
          null) {
        continue;
      }
      final preparedResult = await crypto.createAuthenticatedRepairRequest(
        deviceState: context.deviceState.opaqueState,
        unixDay:
            clock.now().toUtc().millisecondsSinceEpoch ~/
            Duration.millisecondsPerDay,
        recipientDeviceId: protocolUuidBytes(device.deviceId),
        session: native.PairwiseSessionState(
          sessionId: session.sessionId,
          opaqueState: session.opaqueState,
          skippedKeyCount: session.skippedKeyCount,
        ),
        otherSessionsSkippedKeys: context.otherSessionsSkippedKeyCount,
      );
      if (preparedResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final prepared =
          (preparedResult as Success<native.PreparedPairwiseEnvelope>).value;
      final committed = await store.commitPreparedSend(
        PairwiseSendCommit(
          operationId: operationId,
          eventId: operationId,
          currentDeviceId: local,
          expectedDeviceStateVersion: context.deviceState.stateVersion,
          openedLocalPayload: Uint8List.fromList(
            utf8.encode('session.repair:$operationId'),
          ),
          targets: [
            PreparedPairwiseSendTarget(
              recipientUserId: device.userId,
              recipientDeviceId: device.deviceId,
              exactCiphertext: prepared.ciphertext,
              sessionTransition: PairwiseSessionTransition(
                localDeviceId: local,
                remoteUserId: device.userId,
                remoteDeviceId: device.deviceId,
                sessionId: prepared.nextSession.sessionId,
                nextOpaqueState: prepared.nextSession.opaqueState,
                expectedStateVersion: session.stateVersion,
                nextStateVersion: session.stateVersion + 1,
                nextSkippedKeyCount: prepared.nextSession.skippedKeyCount,
                disposition: PairwiseSessionDisposition.primaryBidirectional,
                repairState: PairwiseRepairState.authenticatedRequestPending,
              ),
            ),
          ],
        ),
      );
      if (committed case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      requested += 1;
    }
    return Result.success(requested);
  }
}
