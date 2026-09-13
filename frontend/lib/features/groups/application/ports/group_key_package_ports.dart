import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/protocol/beta_mls_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_key_package_model.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

abstract interface class GroupMlsAdmissionPort implements Port {
  Future<Result<GroupMlsCreationContext>> prepareCreate(
    GroupCreationIntent intent,
  );

  Future<Result<GroupMlsControlContext>> prepareControl({
    required GroupState current,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
  });

  Future<Result<BetaMlsAuthenticationInput>> authenticateCurrentGroup({
    required GroupState current,
    required String actorUserId,
    required String actorDeviceId,
  });

  Future<Result<GroupMlsJoinContext>> prepareJoin({
    required String localUserId,
    required String localDeviceId,
  });
}

abstract interface class GroupKeyPackageRemotePort implements Port {
  Future<Result<int>> fetchConsumableCount({required String deviceId});

  /// Consumable uploads are intentionally not automatically replayable: the
  /// backend appends them and currently exposes no idempotency key.
  Future<Result<int>> upload({
    required String deviceId,
    required GroupKeyPackageUpload upload,
  });

  Future<Result<List<ClaimedGroupKeyPackage>>> claim({
    required String userId,
    List<String>? deviceIds,
  });
}

abstract interface class GroupKeyPackageAuthenticationPort implements Port {
  Future<Result<GroupKeyPackageAuthenticationEvidence>>
  authenticateCurrentDevice({required String userId, required String deviceId});

  Future<Result<GroupPeerAuthenticationEvidence>> authenticatePeerDevices({
    required String userId,
    required List<String> deviceIds,
  });
}

abstract interface class GroupKeyPackageMaintenanceStore implements Port {
  Future<Result<GroupKeyPackageGenerationContext>> readGenerationContext({
    required String deviceId,
  });

  Future<Result<GroupKeyPackagePreparedPlan?>> readPending({
    required String deviceId,
  });

  /// Commits the newly sealed native secret repository and its exact public
  /// upload plan together using a state-revision compare-and-swap.
  Future<Result<void>> persistPrepared(GroupKeyPackagePreparedPlan plan);

  Future<Result<void>> moveStage({
    required GroupKeyPackagePreparedPlan plan,
    required GroupKeyPackagePlanStage nextStage,
  });

  Future<Result<void>> complete(GroupKeyPackagePreparedPlan plan);
}
