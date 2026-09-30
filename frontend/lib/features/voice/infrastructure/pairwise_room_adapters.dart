import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_session_repair_service.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_transport_store.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';

/// The authenticated pairwise device view, narrowed to what a room needs: who
/// a device belongs to, and the key its room control events are checked
/// against.
final class PairwiseRoomLiveDeviceAdapter
    implements RoomLiveDeviceResolverPort {
  const PairwiseRoomLiveDeviceAdapter(this.delegate);

  final PairwiseLiveDeviceResolverPort delegate;

  @override
  Future<Result<List<RoomAuthenticatedLiveDevice>>>
  resolveAuthenticatedLiveDevices(String userId) async {
    final result = await delegate.resolveVerifiedLiveDevices(userId);
    if (result case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    try {
      return Result.success(
        List.unmodifiable([
          for (final device
              in (result as Success<List<VerifiedPairwiseLiveDevice>>).value)
            RoomAuthenticatedLiveDevice(
              userId: device.userId,
              deviceId: device.deviceId,
              // `ik_pub` is the Ed25519 device signing key followed by the
              // X25519 identity key (`backend/CLIENT_CONTRACT.md` §A). The
              // resolver has already refused any device it could not chain to
              // the account identity through the signed device log.
              signingPublic: Uint8List.sublistView(
                device.device.identityPublic,
                0,
                32,
              ),
            ),
        ]),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }
}

/// Room payloads take the same durable fan-out every group payload takes.
final class PairwiseRoomOutboundEnvelopeAdapter
    implements RoomOutboundEnvelopePort {
  const PairwiseRoomOutboundEnvelopeAdapter(this.coordinator);

  final PairwiseFanoutCoordinator coordinator;

  @override
  Future<Result<void>> prepareAndQueue({
    required String operationId,
    required String eventId,
    required String currentUserId,
    required String currentDeviceId,
    required String targetUserId,
    required Uint8List payload,
    required bool includeOwnDevices,
    String? onlyRecipientDeviceId,
  }) async {
    final result = await coordinator.prepareAndQueue(
      operationId: operationId,
      eventId: eventId,
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      peerUserId: targetUserId,
      openedOpaquePayload: payload,
      onlyRecipientDeviceId: onlyRecipientDeviceId,
      includeOwnDevices: includeOwnDevices,
    );
    return result.fold(
      onSuccess: (_) => const Result.success(null),
      onFailure: Result.failure,
    );
  }
}

/// Room and event identifiers from the native core's CSPRNG, through the same
/// operation that produces application event identifiers.
final class NativeRoomIdentity implements RoomIdentityPort {
  const NativeRoomIdentity(this.protocol);

  final ApplicationProtocolPort protocol;

  @override
  Future<Result<Uint8List>> randomIdentifier() => protocol.generateEventId();
}

final class PairwiseRoomSessionRepairAdapter implements RoomSessionRepairPort {
  const PairwiseRoomSessionRepairAdapter(this.service);

  final PairwiseSessionRepairService service;

  @override
  Future<Result<int>> requestRepairWithUser({
    required String localDeviceId,
    required String remoteUserId,
  }) => service.requestRepairWithUser(
    localDeviceId: localDeviceId,
    remoteUserId: remoteUserId,
  );
}

/// Reads whether a primary session exists from the pairwise store the durable
/// path writes, which is the only place a session is kept.
final class StoredRoomPairwiseSessions implements RoomPairwiseSessionPort {
  const StoredRoomPairwiseSessions(this.store);

  final PairwiseTransportStore store;

  @override
  Future<Result<bool>> hasSession({
    required String localDeviceId,
    required String remoteUserId,
    required String remoteDeviceId,
  }) async {
    final context = await store.readPreparationContext(
      localDeviceId: localDeviceId,
      remoteUserId: remoteUserId,
      remoteDeviceId: remoteDeviceId,
    );
    return context.fold(
      onSuccess: (value) => Result.success(value.primary != null),
      onFailure: Result.failure,
    );
  }
}
