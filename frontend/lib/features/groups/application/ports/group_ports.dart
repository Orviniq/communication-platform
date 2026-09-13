import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

abstract interface class GroupControlTranscriptPort {
  Future<Result<List<GroupControlTranscriptEntry>>> readVerifiedTranscript(
    String groupId,
  );
}

abstract interface class GroupRepositoryPort {
  Stream<GroupState?> watchGroup(String groupId);

  Stream<List<GroupMessage>> watchMessages(String groupId);

  Future<Result<GroupState?>> readGroup(String groupId);

  Future<Result<Uint8List?>> readOpaqueMlsState(String groupId);

  Future<Result<void>> commitTransition({
    required GroupState? expectedPrevious,
    required GroupState next,
    required PreparedGroupTransition prepared,
    required bool developmentPreviewOnly,
  });

  Future<Result<void>> commitMessage({
    required GroupState expectedGroup,
    required PreparedGroupMessage prepared,
    required bool developmentPreviewOnly,
  });

  Future<Result<void>> quarantine(GroupQuarantineRecord record);

  /// Live groups holding at least one member that announced a leave but is
  /// still in the MLS tree. Ordered by group id so eviction is deterministic.
  Future<Result<List<GroupState>>> readGroupsPendingEviction({int limit = 20});

  Future<Result<List<GroupOutboundWork>>> readPendingOutbound({int limit = 20});

  Future<Result<void>> markOutboundRouted({required String operationId});
}

abstract interface class GroupOutboundEnvelopePort {
  Future<Result<void>> prepareAndQueue({
    required String operationId,
    required String eventId,
    required String currentUserId,
    required String currentDeviceId,
    required String targetUserId,
    required Uint8List openedMlsPayload,
    required bool includeOwnDevices,
  });
}

abstract interface class GroupApplicationIdentityPort {
  Future<Result<int>> reserveSenderCounter(String deviceId);
}

abstract interface class GroupLiveDeviceResolverPort implements Port {
  Future<Result<List<GroupAuthenticatedLiveDevice>>>
  resolveAuthenticatedLiveDevices(String userId);
}
