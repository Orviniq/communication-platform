import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/beta_mls_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_key_package_ports.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_key_package_model.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

/// Resolves and authenticates every live device before consuming the exact
/// corresponding backend KeyPackages for a beta MLS create transaction.
final class GroupMlsAdmissionService implements GroupMlsAdmissionPort {
  const GroupMlsAdmissionService({
    required this.remote,
    required this.authenticationForCurrentUser,
    required this.store,
    required this.liveDevicesForCurrentUser,
    required this.clock,
  });

  final GroupKeyPackageRemotePort remote;
  final GroupKeyPackageAuthenticationPort Function(String currentUserId)
  authenticationForCurrentUser;
  final GroupKeyPackageMaintenanceStore store;
  final GroupLiveDeviceResolverPort Function(String currentUserId)
  liveDevicesForCurrentUser;
  final TimeSource clock;

  @override
  Future<Result<GroupMlsCreationContext>> prepareCreate(
    GroupCreationIntent intent,
  ) async {
    final localUserId = intent.creatorUserId.toLowerCase();
    final localDeviceId = intent.creatorDeviceId.toLowerCase();
    final authentication = authenticationForCurrentUser(localUserId);
    final liveDevices = liveDevicesForCurrentUser(localUserId);
    final generationResult = await store.readGenerationContext(
      deviceId: localDeviceId,
    );
    if (generationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final generation =
        (generationResult as Success<GroupKeyPackageGenerationContext>).value;
    final localEvidenceResult = await authentication.authenticateCurrentDevice(
      userId: localUserId,
      deviceId: localDeviceId,
    );
    if (localEvidenceResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final localEvidence =
        (localEvidenceResult as Success<GroupKeyPackageAuthenticationEvidence>)
            .value;

    final members = <GroupMember>[];
    final admissions = <GroupMlsClaimedAdmission>[];
    final bundleRequests = <Uint8List>[];
    final allDeviceIds = <String>{localDeviceId};
    final sortedMembers = intent.members.toList(growable: false)
      ..sort((left, right) => left.userId.compareTo(right.userId));
    for (final member in sortedMembers) {
      final userId = member.userId.toLowerCase();
      final liveResult = await liveDevices.resolveAuthenticatedLiveDevices(
        userId,
      );
      if (liveResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final live =
          (liveResult as Success<List<GroupAuthenticatedLiveDevice>>).value;
      final liveIds =
          live
              .map((device) => device.deviceId.toLowerCase())
              .toList(growable: false)
            ..sort();
      if (live.isEmpty ||
          live.any((device) => device.userId != userId) ||
          liveIds.toSet().length != liveIds.length ||
          (userId == localUserId && !liveIds.contains(localDeviceId))) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.unauthenticatedInput),
        );
      }
      final targets = liveIds
          .where(
            (deviceId) => userId != localUserId || deviceId != localDeviceId,
          )
          .toList(growable: false);
      if (targets.isNotEmpty) {
        final claimedResult = await remote.claim(
          userId: userId,
          deviceIds: targets,
        );
        if (claimedResult case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        final claimed =
            (claimedResult as Success<List<ClaimedGroupKeyPackage>>).value;
        final byDevice = {
          for (final package in claimed)
            package.deviceId.toLowerCase(): package,
        };
        if (claimed.length != targets.length ||
            byDevice.length != targets.length ||
            !byDevice.keys.toSet().containsAll(targets) ||
            !targets.toSet().containsAll(byDevice.keys)) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          );
        }
        final peerEvidenceResult = await authentication.authenticatePeerDevices(
          userId: userId,
          deviceIds: targets,
        );
        if (peerEvidenceResult case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        final peerEvidence =
            (peerEvidenceResult as Success<GroupPeerAuthenticationEvidence>)
                .value;
        final evidenceByDevice = {
          for (final evidence in peerEvidence.authenticatedDevices)
            evidence.deviceId: evidence,
        };
        if (!_sameSet(peerEvidence.liveDeviceIds, liveIds) ||
            evidenceByDevice.length != targets.length ||
            !evidenceByDevice.keys.toSet().containsAll(targets)) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          );
        }
        for (final deviceId in targets) {
          if (!allDeviceIds.add(deviceId)) {
            return const Result.failure(
              SecurityFailure(SecurityFailureKind.unauthenticatedInput),
            );
          }
          admissions.add(
            GroupMlsClaimedAdmission(
              userId: userId,
              deviceId: deviceId,
              wrappedKeyPackage: byDevice[deviceId]!.wrappedKeyPackage,
            ),
          );
          bundleRequests.add(evidenceByDevice[deviceId]!.verifiedBundleRequest);
        }
      }
      members.add(member.copyWith(deviceIds: liveIds, verified: true));
    }
    if (allDeviceIds.length > 50 || admissions.isEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    try {
      return Result.success(
        GroupMlsCreationContext(
          authentication: BetaMlsAuthenticationInput(
            opaqueDeviceState: generation.opaqueDeviceState,
            migrationUnixDay:
                clock.now().toUtc().millisecondsSinceEpoch ~/
                Duration.millisecondsPerDay,
            localVerifiedBundleRequest:
                localEvidence.localVerifiedBundleRequest,
            additionalVerifiedBundleRequests: bundleRequests,
          ),
          authenticatedMembers: members,
          admissions: admissions,
        ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<GroupMlsControlContext>> prepareControl({
    required GroupState current,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
  }) async {
    final localUserId = actorUserId.toLowerCase();
    final localDeviceId = actorDeviceId.toLowerCase();
    final authentication = authenticationForCurrentUser(localUserId);
    final liveDevices = liveDevicesForCurrentUser(localUserId);
    final generationResult = await store.readGenerationContext(
      deviceId: localDeviceId,
    );
    if (generationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final generation =
        (generationResult as Success<GroupKeyPackageGenerationContext>).value;
    final localEvidenceResult = await authentication.authenticateCurrentDevice(
      userId: localUserId,
      deviceId: localDeviceId,
    );
    if (localEvidenceResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final localEvidence =
        (localEvidenceResult as Success<GroupKeyPackageAuthenticationEvidence>)
            .value;

    final bundleRequests = <Uint8List>[];
    final allDeviceIds = <String>{};
    final currentMembers = current.activeMembers.toList(growable: false)
      ..sort((left, right) => left.userId.compareTo(right.userId));
    for (final member in currentMembers) {
      final verified = await _verifyLiveMember(
        member: member,
        localUserId: localUserId,
        localDeviceId: localDeviceId,
        authentication: authentication,
        liveDevices: liveDevices,
        requireStoredSet: true,
      );
      if (verified case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final value = (verified as Success<_VerifiedMember>).value;
      for (final deviceId in value.liveDeviceIds) {
        if (!allDeviceIds.add(deviceId)) return _unauthenticated();
      }
      bundleRequests.addAll(value.bundleRequests);
    }

    final admissions = <GroupMlsClaimedAdmission>[];
    var authenticatedOperation = operation;
    if (operation case InviteGroupMembersOperation(:final members)) {
      final authenticatedMembers = <GroupMember>[];
      final sorted = members.toList(growable: false)
        ..sort((left, right) => left.userId.compareTo(right.userId));
      for (final member in sorted) {
        // Only an evicted member may be re-admitted, and only through the same
        // full path a first-time invitation takes: live devices are resolved
        // and authenticated again and fresh KeyPackages are claimed below. A
        // live member, or one whose eviction has not been committed yet, is a
        // conflict.
        final existing = current.member(member.userId);
        if (existing != null &&
            existing.membership != GroupMembershipState.removed) {
          return const Result.failure(
            ValidationFailure(ValidationFailureKind.conflict),
          );
        }
        final verified = await _verifyLiveMember(
          member: member,
          localUserId: localUserId,
          localDeviceId: localDeviceId,
          authentication: authentication,
          liveDevices: liveDevices,
          requireStoredSet: false,
        );
        if (verified case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        final value = (verified as Success<_VerifiedMember>).value;
        for (final deviceId in value.liveDeviceIds) {
          if (!allDeviceIds.add(deviceId)) return _unauthenticated();
        }
        final claimedResult = await remote.claim(
          userId: member.userId.toLowerCase(),
          deviceIds: value.liveDeviceIds,
        );
        if (claimedResult case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        final claimed =
            (claimedResult as Success<List<ClaimedGroupKeyPackage>>).value;
        final byDevice = {
          for (final package in claimed)
            package.deviceId.toLowerCase(): package,
        };
        if (claimed.length != value.liveDeviceIds.length ||
            byDevice.length != value.liveDeviceIds.length ||
            !_sameSet(byDevice.keys, value.liveDeviceIds)) {
          return _unauthenticated();
        }
        for (final deviceId in value.liveDeviceIds) {
          admissions.add(
            GroupMlsClaimedAdmission(
              userId: member.userId.toLowerCase(),
              deviceId: deviceId,
              wrappedKeyPackage: byDevice[deviceId]!.wrappedKeyPackage,
            ),
          );
        }
        bundleRequests.addAll(value.bundleRequests);
        authenticatedMembers.add(
          member.copyWith(deviceIds: value.liveDeviceIds, verified: true),
        );
      }
      authenticatedOperation = InviteGroupMembersOperation(
        authenticatedMembers,
      );
    }
    if (allDeviceIds.length > GroupState.maximumMembers) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    try {
      return Result.success(
        GroupMlsControlContext(
          authentication: BetaMlsAuthenticationInput(
            opaqueDeviceState: generation.opaqueDeviceState,
            migrationUnixDay:
                clock.now().toUtc().millisecondsSinceEpoch ~/
                Duration.millisecondsPerDay,
            localVerifiedBundleRequest:
                localEvidence.localVerifiedBundleRequest,
            additionalVerifiedBundleRequests: bundleRequests,
          ),
          operation: authenticatedOperation,
          admissions: admissions,
        ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<BetaMlsAuthenticationInput>> authenticateCurrentGroup({
    required GroupState current,
    required String actorUserId,
    required String actorDeviceId,
  }) async {
    final localUserId = actorUserId.toLowerCase();
    final localDeviceId = actorDeviceId.toLowerCase();
    final authentication = authenticationForCurrentUser(localUserId);
    final liveDevices = liveDevicesForCurrentUser(localUserId);
    final generationResult = await store.readGenerationContext(
      deviceId: localDeviceId,
    );
    if (generationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final generation =
        (generationResult as Success<GroupKeyPackageGenerationContext>).value;
    final localEvidenceResult = await authentication.authenticateCurrentDevice(
      userId: localUserId,
      deviceId: localDeviceId,
    );
    if (localEvidenceResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final localEvidence =
        (localEvidenceResult as Success<GroupKeyPackageAuthenticationEvidence>)
            .value;
    final bundleRequests = <Uint8List>[];
    final allDeviceIds = <String>{};
    for (final member in current.activeMembers) {
      final verified = await _verifyLiveMember(
        member: member,
        localUserId: localUserId,
        localDeviceId: localDeviceId,
        authentication: authentication,
        liveDevices: liveDevices,
        requireStoredSet: true,
      );
      if (verified case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final value = (verified as Success<_VerifiedMember>).value;
      for (final deviceId in value.liveDeviceIds) {
        if (!allDeviceIds.add(deviceId)) return _unauthenticated();
      }
      bundleRequests.addAll(value.bundleRequests);
    }
    if (allDeviceIds.length > GroupState.maximumMembers) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    try {
      return Result.success(
        BetaMlsAuthenticationInput(
          opaqueDeviceState: generation.opaqueDeviceState,
          migrationUnixDay:
              clock.now().toUtc().millisecondsSinceEpoch ~/
              Duration.millisecondsPerDay,
          localVerifiedBundleRequest: localEvidence.localVerifiedBundleRequest,
          additionalVerifiedBundleRequests: bundleRequests,
        ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  @override
  Future<Result<GroupMlsJoinContext>> prepareJoin({
    required String localUserId,
    required String localDeviceId,
  }) async {
    final userId = localUserId.toLowerCase();
    final deviceId = localDeviceId.toLowerCase();
    final generationResult = await store.readGenerationContext(
      deviceId: deviceId,
    );
    if (generationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final generation =
        (generationResult as Success<GroupKeyPackageGenerationContext>).value;
    if (generation.sealedKeyPackageState == null ||
        generation.keyPackageStateRevision <= 0) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final evidenceResult = await authenticationForCurrentUser(
      userId,
    ).authenticateCurrentDevice(userId: userId, deviceId: deviceId);
    if (evidenceResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final evidence =
        (evidenceResult as Success<GroupKeyPackageAuthenticationEvidence>)
            .value;
    try {
      return Result.success(
        GroupMlsJoinContext(
          authentication: BetaMlsAuthenticationInput(
            opaqueDeviceState: generation.opaqueDeviceState,
            migrationUnixDay:
                clock.now().toUtc().millisecondsSinceEpoch ~/
                Duration.millisecondsPerDay,
            localVerifiedBundleRequest: evidence.localVerifiedBundleRequest,
          ),
          sealedKeyPackageState: generation.sealedKeyPackageState!,
          keyPackageStateRevision: generation.keyPackageStateRevision,
        ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }

  Future<Result<_VerifiedMember>> _verifyLiveMember({
    required GroupMember member,
    required String localUserId,
    required String localDeviceId,
    required GroupKeyPackageAuthenticationPort authentication,
    required GroupLiveDeviceResolverPort liveDevices,
    required bool requireStoredSet,
  }) async {
    final userId = member.userId.toLowerCase();
    final liveResult = await liveDevices.resolveAuthenticatedLiveDevices(
      userId,
    );
    if (liveResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final live =
        (liveResult as Success<List<GroupAuthenticatedLiveDevice>>).value;
    final liveIds =
        live
            .map((device) => device.deviceId.toLowerCase())
            .toList(growable: false)
          ..sort();
    if (liveIds.isEmpty ||
        live.any((device) => device.userId != userId) ||
        liveIds.toSet().length != liveIds.length ||
        (requireStoredSet && !_sameSet(liveIds, member.deviceIds)) ||
        (userId == localUserId && !liveIds.contains(localDeviceId))) {
      return _unauthenticated();
    }
    final targets = liveIds
        .where((value) => userId != localUserId || value != localDeviceId)
        .toList(growable: false);
    if (targets.isEmpty) {
      return Result.success(
        _VerifiedMember(liveDeviceIds: liveIds, bundleRequests: const []),
      );
    }
    final evidenceResult = await authentication.authenticatePeerDevices(
      userId: userId,
      deviceIds: targets,
    );
    if (evidenceResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final evidence =
        (evidenceResult as Success<GroupPeerAuthenticationEvidence>).value;
    final byDevice = {
      for (final device in evidence.authenticatedDevices)
        device.deviceId.toLowerCase(): device,
    };
    if (!_sameSet(evidence.liveDeviceIds, liveIds) ||
        byDevice.length != targets.length ||
        !_sameSet(byDevice.keys, targets)) {
      return _unauthenticated();
    }
    return Result.success(
      _VerifiedMember(
        liveDeviceIds: liveIds,
        bundleRequests: [
          for (final deviceId in targets)
            byDevice[deviceId]!.verifiedBundleRequest,
        ],
      ),
    );
  }
}

final class _VerifiedMember {
  const _VerifiedMember({
    required this.liveDeviceIds,
    required this.bundleRequests,
  });

  final List<String> liveDeviceIds;
  final List<Uint8List> bundleRequests;
}

Result<T> _unauthenticated<T>() => const Result.failure(
  SecurityFailure(SecurityFailureKind.unauthenticatedInput),
);

bool _sameSet(Iterable<String> left, Iterable<String> right) {
  final leftSet = left.map((value) => value.toLowerCase()).toSet();
  final rightSet = right.map((value) => value.toLowerCase()).toSet();
  return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
}
