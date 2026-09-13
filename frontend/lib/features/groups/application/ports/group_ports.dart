import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

/// Functional boundary for the reviewed Rust/OpenMLS implementation in piece 19.
///
/// Implementations return a complete next opaque state without mutating the durable
/// current state. The repository commits that state, its signed control/application
/// fact, projections, and outbound work in one transaction.
abstract interface class GroupMlsCryptoPort {
  Future<Result<GroupMlsTransportProbe>> probeIncomingTransport(
    Uint8List mlsObject,
  );

  Future<Result<PreparedGroupTransition>> prepareCreate(
    GroupCreationIntent intent,
  );

  Future<Result<PreparedGroupTransition>> inspectIncomingWelcome({
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  });

  Future<Result<PreparedGroupTransition>> prepareControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
    required int createdMs,
  });

  Future<Result<PreparedGroupTransition>> inspectIncomingControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  });

  Future<Result<PreparedGroupMessage>> prepareApplicationMessage({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required String senderUserId,
    required String senderDeviceId,
    required String text,
    required int createdMs,
  });

  Future<Result<PreparedGroupMessage>> inspectIncomingApplication({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  });

  /// Decides which control branch is canonical after a same-revision fork.
  ///
  /// Every sibling is authenticated and replayed against the shared parent
  /// state before it is allowed to influence the decision, so a hostile relay
  /// cannot force a quarantine by inventing a low-ordering branch.
  Future<Result<GroupForkResolution>> reconcileFork({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required List<Uint8List> siblingCommits,
    required String localUserId,
    required String localDeviceId,
  });
}

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
