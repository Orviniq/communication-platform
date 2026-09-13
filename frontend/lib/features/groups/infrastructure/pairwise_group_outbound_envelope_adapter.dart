import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';

final class PairwiseGroupOutboundEnvelopeAdapter
    implements GroupOutboundEnvelopePort {
  const PairwiseGroupOutboundEnvelopeAdapter(this.coordinator);

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
