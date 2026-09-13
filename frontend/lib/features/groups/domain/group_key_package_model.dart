import 'dart:typed_data';

import 'package:communication_platform/core/protocol/beta_mls_model.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

final class ClaimedGroupKeyPackage {
  ClaimedGroupKeyPackage({
    required this.deviceId,
    required Uint8List wrappedKeyPackage,
  }) : wrappedKeyPackage = _copyPackage(wrappedKeyPackage) {
    if (!_uuid.hasMatch(deviceId)) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final String deviceId;
  final Uint8List wrappedKeyPackage;

  @override
  String toString() => 'ClaimedGroupKeyPackage(<redacted>)';
}

final class GroupKeyPackageUpload {
  GroupKeyPackageUpload({
    required this.kind,
    required Iterable<Uint8List> wrappedKeyPackages,
  }) : wrappedKeyPackages = List.unmodifiable(
         wrappedKeyPackages.map(_copyPackage),
       ) {
    if (this.wrappedKeyPackages.isEmpty ||
        this.wrappedKeyPackages.length > 100 ||
        (kind == MlsKeyPackageKind.lastResort &&
            this.wrappedKeyPackages.length != 1)) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final MlsKeyPackageKind kind;
  final List<Uint8List> wrappedKeyPackages;

  bool get isContractIdempotent => kind == MlsKeyPackageKind.lastResort;

  @override
  String toString() => 'GroupKeyPackageUpload(<redacted>)';
}

abstract final class GroupKeyPackageMaintenancePolicy {
  static const int consumableLowWatermark = 20;
  static const int consumableTarget = 50;
  static const int maximumConsumablePool = 100;
}

enum GroupKeyPackagePlanStage { prepared, attemptStarted, ambiguous }

final class GroupKeyPackageGenerationContext {
  GroupKeyPackageGenerationContext({
    required this.deviceId,
    required Uint8List opaqueDeviceState,
    Uint8List? sealedKeyPackageState,
    required this.keyPackageStateRevision,
    required this.lastResortUploaded,
  }) : opaqueDeviceState = _copyOpaque(opaqueDeviceState),
       sealedKeyPackageState = sealedKeyPackageState == null
           ? null
           : _copyOpaque(sealedKeyPackageState) {
    if (!_uuid.hasMatch(deviceId) || keyPackageStateRevision < 0) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final String deviceId;
  final Uint8List opaqueDeviceState;
  final Uint8List? sealedKeyPackageState;
  final int keyPackageStateRevision;
  final bool lastResortUploaded;
}

final class GroupKeyPackagePreparedPlan {
  GroupKeyPackagePreparedPlan({
    required this.deviceId,
    required this.expectedStateRevision,
    required Uint8List nextSealedKeyPackageState,
    required this.upload,
    this.stage = GroupKeyPackagePlanStage.prepared,
  }) : nextSealedKeyPackageState = _copyOpaque(nextSealedKeyPackageState) {
    if (!_uuid.hasMatch(deviceId) || expectedStateRevision < 0) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final String deviceId;
  final int expectedStateRevision;
  final Uint8List nextSealedKeyPackageState;
  final GroupKeyPackageUpload upload;
  final GroupKeyPackagePlanStage stage;

  GroupKeyPackagePreparedPlan withStage(GroupKeyPackagePlanStage value) =>
      GroupKeyPackagePreparedPlan(
        deviceId: deviceId,
        expectedStateRevision: expectedStateRevision,
        nextSealedKeyPackageState: nextSealedKeyPackageState,
        upload: upload,
        stage: value,
      );

  @override
  String toString() =>
      'GroupKeyPackagePreparedPlan(stage: ${stage.name}, <redacted>)';
}

final class GroupKeyPackageAuthenticationEvidence {
  GroupKeyPackageAuthenticationEvidence({
    required Uint8List localVerifiedBundleRequest,
  }) : localVerifiedBundleRequest = _copyOpaque(localVerifiedBundleRequest);

  final Uint8List localVerifiedBundleRequest;

  @override
  String toString() => 'GroupKeyPackageAuthenticationEvidence(<redacted>)';
}

final class GroupAuthenticatedPeerDevice {
  GroupAuthenticatedPeerDevice({
    required this.userId,
    required this.deviceId,
    required Uint8List verifiedBundleRequest,
  }) : verifiedBundleRequest = _copyOpaque(verifiedBundleRequest) {
    if (!_uuid.hasMatch(userId) || !_uuid.hasMatch(deviceId)) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final String userId;
  final String deviceId;
  final Uint8List verifiedBundleRequest;
}

final class GroupPeerAuthenticationEvidence {
  GroupPeerAuthenticationEvidence({
    required this.userId,
    required Iterable<String> liveDeviceIds,
    required Iterable<GroupAuthenticatedPeerDevice> authenticatedDevices,
  }) : liveDeviceIds = List.unmodifiable(liveDeviceIds),
       authenticatedDevices = List.unmodifiable(authenticatedDevices) {
    if (!_uuid.hasMatch(userId) ||
        this.liveDeviceIds.isEmpty ||
        this.liveDeviceIds.any((value) => !_uuid.hasMatch(value)) ||
        this.liveDeviceIds.toSet().length != this.liveDeviceIds.length ||
        this.authenticatedDevices.any((value) => value.userId != userId) ||
        this.authenticatedDevices
                .map((value) => value.deviceId)
                .toSet()
                .length !=
            this.authenticatedDevices.length) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final String userId;
  final List<String> liveDeviceIds;
  final List<GroupAuthenticatedPeerDevice> authenticatedDevices;
}

final class GroupMlsClaimedAdmission {
  GroupMlsClaimedAdmission({
    required this.userId,
    required this.deviceId,
    required Uint8List wrappedKeyPackage,
  }) : wrappedKeyPackage = _copyPackage(wrappedKeyPackage) {
    if (!_uuid.hasMatch(userId) || !_uuid.hasMatch(deviceId)) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final String userId;
  final String deviceId;
  final Uint8List wrappedKeyPackage;
}

final class GroupMlsCreationContext {
  GroupMlsCreationContext({
    required this.authentication,
    required Iterable<GroupMember> authenticatedMembers,
    required Iterable<GroupMlsClaimedAdmission> admissions,
  }) : authenticatedMembers = List.unmodifiable(authenticatedMembers),
       admissions = List.unmodifiable(admissions) {
    final memberIds = this.authenticatedMembers
        .map((member) => member.userId)
        .toSet();
    final deviceIds = <String>{};
    if (this.authenticatedMembers.isEmpty ||
        this.admissions.isEmpty ||
        this.authenticatedMembers.length > GroupState.maximumMembers ||
        memberIds.length != this.authenticatedMembers.length ||
        this.admissions.any(
          (admission) =>
              !memberIds.contains(admission.userId) ||
              !deviceIds.add(admission.deviceId),
        )) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final BetaMlsAuthenticationInput authentication;
  final List<GroupMember> authenticatedMembers;
  final List<GroupMlsClaimedAdmission> admissions;
}

final class GroupMlsControlContext {
  GroupMlsControlContext({
    required this.authentication,
    required this.operation,
    required Iterable<GroupMlsClaimedAdmission> admissions,
  }) : admissions = List.unmodifiable(admissions) {
    final deviceIds = <String>{};
    if (this.admissions.length > GroupState.maximumMembers ||
        this.admissions.any((value) => !deviceIds.add(value.deviceId)) ||
        (operation is InviteGroupMembersOperation) !=
            this.admissions.isNotEmpty) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final BetaMlsAuthenticationInput authentication;
  final GroupControlOperation operation;
  final List<GroupMlsClaimedAdmission> admissions;
}

final class GroupMlsJoinContext {
  GroupMlsJoinContext({
    required this.authentication,
    required Uint8List sealedKeyPackageState,
    required this.keyPackageStateRevision,
  }) : sealedKeyPackageState = _copyOpaque(sealedKeyPackageState) {
    if (keyPackageStateRevision <= 0) {
      throw const GroupKeyPackageFormatException();
    }
  }

  final BetaMlsAuthenticationInput authentication;
  final Uint8List sealedKeyPackageState;
  final int keyPackageStateRevision;
}

final class GroupKeyPackageMaintenanceReport {
  const GroupKeyPackageMaintenanceReport({
    required this.consumableCount,
    required this.uploadedConsumables,
    required this.uploadedLastResort,
  });

  final int consumableCount;
  final int uploadedConsumables;
  final bool uploadedLastResort;
}

final class GroupKeyPackageFormatException implements Exception {
  const GroupKeyPackageFormatException();
}

Uint8List _copyPackage(Uint8List value) {
  if (value.length != 4096 && value.length != 16 * 1024) {
    throw const GroupKeyPackageFormatException();
  }
  return Uint8List.fromList(value);
}

Uint8List _copyOpaque(Uint8List value) {
  if (value.isEmpty || value.length > 1024 * 1024) {
    throw const GroupKeyPackageFormatException();
  }
  return Uint8List.fromList(value);
}

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
