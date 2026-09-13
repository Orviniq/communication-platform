import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_mls_admission_service.dart';
import 'package:communication_platform/features/groups/application/ports/group_key_package_ports.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_key_package_model.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _alice = '10000000-0000-4000-8000-000000000001';
const _aliceDevice = '20000000-0000-4000-8000-000000000001';
const _aliceOther = '20000000-0000-4000-8000-000000000002';
const _bob = '30000000-0000-4000-8000-000000000001';
const _bobDevice1 = '40000000-0000-4000-8000-000000000001';
const _bobDevice2 = '40000000-0000-4000-8000-000000000002';

void main() {
  test(
    'binds one exact backend KeyPackage to every authenticated live leaf',
    () async {
      final remote = _Remote();
      final result = await GroupMlsAdmissionService(
        remote: remote,
        authenticationForCurrentUser: (_) => const _Authentication(),
        store: const _Store(),
        liveDevicesForCurrentUser: (_) => const _LiveDevices(),
        clock: const _Clock(),
      ).prepareCreate(_intent());

      expect(result, isA<Success<GroupMlsCreationContext>>());
      final context = (result as Success<GroupMlsCreationContext>).value;
      expect(
        context.authentication.additionalVerifiedBundleRequests,
        hasLength(3),
      );
      expect(context.admissions.map((value) => value.deviceId), [
        _aliceOther,
        _bobDevice1,
        _bobDevice2,
      ]);
      expect(
        context.authenticatedMembers
            .singleWhere((m) => m.userId == _alice)
            .deviceIds,
        [_aliceDevice, _aliceOther],
      );
      expect(
        context.authenticatedMembers
            .singleWhere((m) => m.userId == _bob)
            .deviceIds,
        [_bobDevice1, _bobDevice2],
      );
      expect(remote.claims, {
        _alice: [_aliceOther],
        _bob: [_bobDevice1, _bobDevice2],
      });
    },
  );

  test(
    'fails closed when the authenticated live set changes during claims',
    () async {
      final result = await GroupMlsAdmissionService(
        remote: _Remote(),
        authenticationForCurrentUser: (_) =>
            const _Authentication(dropBobSecondFromLiveSet: true),
        store: const _Store(),
        liveDevicesForCurrentUser: (_) => const _LiveDevices(),
        clock: const _Clock(),
      ).prepareCreate(_intent());

      expect(result, isA<FailureResult<GroupMlsCreationContext>>());
      expect(
        (result as FailureResult<GroupMlsCreationContext>).failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    },
  );

  test(
    'authenticates the exact persisted leaf set for later controls',
    () async {
      final remote = _Remote();
      final result =
          await GroupMlsAdmissionService(
            remote: remote,
            authenticationForCurrentUser: (_) => const _Authentication(),
            store: const _Store(),
            liveDevicesForCurrentUser: (_) => const _LiveDevices(),
            clock: const _Clock(),
          ).prepareControl(
            current: _currentState(),
            operation: const UpdateGroupMetadataOperation(
              GroupMetadata(name: 'Updated'),
            ),
            actorUserId: _alice,
            actorDeviceId: _aliceDevice,
          );

      expect(result, isA<Success<GroupMlsControlContext>>());
      final context = (result as Success<GroupMlsControlContext>).value;
      expect(
        context.authentication.additionalVerifiedBundleRequests,
        hasLength(3),
      );
      expect(context.operation, isA<UpdateGroupMetadataOperation>());
      expect(context.admissions, isEmpty);
      expect(remote.claims, isEmpty);
    },
  );

  test(
    'blocks a control when stored and authenticated live leaves diverge',
    () async {
      final current = _currentState(aliceDevices: const [_aliceDevice]);
      final result =
          await GroupMlsAdmissionService(
            remote: _Remote(),
            authenticationForCurrentUser: (_) => const _Authentication(),
            store: const _Store(),
            liveDevicesForCurrentUser: (_) => const _LiveDevices(),
            clock: const _Clock(),
          ).prepareControl(
            current: current,
            operation: const UpdateGroupMetadataOperation(
              GroupMetadata(name: 'Blocked'),
            ),
            actorUserId: _alice,
            actorDeviceId: _aliceDevice,
          );

      expect(result, isA<FailureResult<GroupMlsControlContext>>());
      expect(
        (result as FailureResult<GroupMlsControlContext>).failure,
        const SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    },
  );

  group('re-admitting an evicted member', () {
    test('claims fresh KeyPackages for every live leaf again', () async {
      // Queue-gap recovery ends in exactly this control: the peer that
      // evicted the desynced device adds it back, which must resolve its
      // live devices and claim new KeyPackages from scratch rather than
      // reuse anything bound to the epoch the device lost.
      final remote = _Remote();
      final result =
          await GroupMlsAdmissionService(
                remote: remote,
                authenticationForCurrentUser: (_) => const _Authentication(),
                store: const _Store(),
                liveDevicesForCurrentUser: (_) => const _LiveDevices(),
                clock: const _Clock(),
              ).prepareControl(
                current: _currentState(
                  bobMembership: GroupMembershipState.removed,
                ),
                operation: InviteGroupMembersOperation([
                  GroupMember(
                    userId: _bob,
                    displayName: 'Bob',
                    role: GroupRole.member,
                  ),
                ]),
                actorUserId: _alice,
                actorDeviceId: _aliceDevice,
              )
              as Success<GroupMlsControlContext>;

      expect(remote.claims, {
        _bob: [_bobDevice1, _bobDevice2],
      });
      expect(result.value.admissions.map((value) => value.deviceId), [
        _bobDevice1,
        _bobDevice2,
      ]);
      final readmitted = (result.value.operation as InviteGroupMembersOperation)
          .members
          .single;
      expect(readmitted.deviceIds, [_bobDevice1, _bobDevice2]);
      expect(readmitted.verified, isTrue);
    });

    test('a live member is still a conflict', () async {
      final remote = _Remote();
      final result =
          await GroupMlsAdmissionService(
            remote: remote,
            authenticationForCurrentUser: (_) => const _Authentication(),
            store: const _Store(),
            liveDevicesForCurrentUser: (_) => const _LiveDevices(),
            clock: const _Clock(),
          ).prepareControl(
            current: _currentState(),
            operation: InviteGroupMembersOperation([
              GroupMember(
                userId: _bob,
                displayName: 'Bob',
                role: GroupRole.member,
              ),
            ]),
            actorUserId: _alice,
            actorDeviceId: _aliceDevice,
          );

      expect(
        (result as FailureResult<GroupMlsControlContext>).failure,
        const ValidationFailure(ValidationFailureKind.conflict),
      );
      expect(remote.claims, isEmpty);
    });

    test('an uncommitted eviction is still a conflict', () async {
      // The departed leaf is still in the ratchet tree until the owner
      // commits the matching Remove, so adding the same client again would
      // duplicate it.
      final remote = _Remote();
      final result =
          await GroupMlsAdmissionService(
            remote: remote,
            authenticationForCurrentUser: (_) => const _Authentication(),
            store: const _Store(),
            liveDevicesForCurrentUser: (_) => const _LiveDevices(),
            clock: const _Clock(),
          ).prepareControl(
            current: _currentState(bobMembership: GroupMembershipState.left),
            operation: InviteGroupMembersOperation([
              GroupMember(
                userId: _bob,
                displayName: 'Bob',
                role: GroupRole.member,
              ),
            ]),
            actorUserId: _alice,
            actorDeviceId: _aliceDevice,
          );

      expect(
        (result as FailureResult<GroupMlsControlContext>).failure,
        const ValidationFailure(ValidationFailureKind.conflict),
      );
      expect(remote.claims, isEmpty);
    });
  });
}

GroupState _currentState({
  List<String> aliceDevices = const [_aliceDevice, _aliceOther],
  GroupMembershipState bobMembership = GroupMembershipState.active,
}) => GroupState(
  groupId: List.filled(64, 'a').join(),
  metadata: const GroupMetadata(name: 'Beta group'),
  invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
  historySharingPolicy: GroupHistorySharingPolicy.reshareAvailable,
  members: [
    GroupMember(
      userId: _alice,
      displayName: 'Alice',
      role: GroupRole.owner,
      verified: true,
      deviceIds: aliceDevices,
    ),
    GroupMember(
      userId: _bob,
      displayName: 'Bob',
      role: GroupRole.member,
      membership: bobMembership,
      verified: true,
      deviceIds: const [_bobDevice1, _bobDevice2],
    ),
  ],
  controlRevision: 1,
  controlStateHash: List.filled(64, 'b').join(),
  acceptedEpoch: 1,
);

GroupCreationIntent _intent() => GroupCreationIntent(
  creatorUserId: _alice,
  creatorDeviceId: _aliceDevice,
  metadata: const GroupMetadata(name: 'Beta group'),
  members: [
    GroupMember(
      userId: _alice,
      displayName: 'Alice',
      role: GroupRole.owner,
      verified: true,
      deviceIds: const [_aliceDevice],
    ),
    GroupMember(
      userId: _bob,
      displayName: 'Bob',
      role: GroupRole.member,
      verified: true,
    ),
  ],
  createdMs: 1_700_000_000_000,
);

final class _Remote implements GroupKeyPackageRemotePort {
  final claims = <String, List<String>>{};

  @override
  Future<Result<List<ClaimedGroupKeyPackage>>> claim({
    required String userId,
    List<String>? deviceIds,
  }) async {
    final requested = List<String>.from(deviceIds!);
    claims[userId] = requested;
    return Result.success([
      for (var index = 0; index < requested.length; index += 1)
        ClaimedGroupKeyPackage(
          deviceId: requested[index],
          wrappedKeyPackage: Uint8List(4096)..fillRange(0, 4096, index + 1),
        ),
    ]);
  }

  @override
  Future<Result<int>> fetchConsumableCount({required String deviceId}) async =>
      throw UnimplementedError();

  @override
  Future<Result<int>> upload({
    required String deviceId,
    required GroupKeyPackageUpload upload,
  }) async => throw UnimplementedError();
}

final class _Authentication implements GroupKeyPackageAuthenticationPort {
  const _Authentication({this.dropBobSecondFromLiveSet = false});

  final bool dropBobSecondFromLiveSet;

  @override
  Future<Result<GroupKeyPackageAuthenticationEvidence>>
  authenticateCurrentDevice({
    required String userId,
    required String deviceId,
  }) async => Result.success(
    GroupKeyPackageAuthenticationEvidence(
      localVerifiedBundleRequest: Uint8List.fromList('CPBRV001'.codeUnits),
    ),
  );

  @override
  Future<Result<GroupPeerAuthenticationEvidence>> authenticatePeerDevices({
    required String userId,
    required List<String> deviceIds,
  }) async {
    final live = userId == _alice
        ? const [_aliceDevice, _aliceOther]
        : dropBobSecondFromLiveSet
        ? const [_bobDevice1]
        : const [_bobDevice1, _bobDevice2];
    return Result.success(
      GroupPeerAuthenticationEvidence(
        userId: userId,
        liveDeviceIds: live,
        authenticatedDevices: [
          for (final deviceId in deviceIds)
            GroupAuthenticatedPeerDevice(
              userId: userId,
              deviceId: deviceId,
              verifiedBundleRequest: Uint8List.fromList(
                'CPBRV001|$deviceId'.codeUnits,
              ),
            ),
        ],
      ),
    );
  }
}

final class _Store implements GroupKeyPackageMaintenanceStore {
  const _Store();

  @override
  Future<Result<GroupKeyPackageGenerationContext>> readGenerationContext({
    required String deviceId,
  }) async => Result.success(
    GroupKeyPackageGenerationContext(
      deviceId: deviceId,
      opaqueDeviceState: Uint8List.fromList([1, 2, 3]),
      keyPackageStateRevision: 1,
      lastResortUploaded: true,
    ),
  );

  @override
  Future<Result<GroupKeyPackagePreparedPlan?>> readPending({
    required String deviceId,
  }) async => throw UnimplementedError();

  @override
  Future<Result<void>> persistPrepared(
    GroupKeyPackagePreparedPlan plan,
  ) async => throw UnimplementedError();

  @override
  Future<Result<void>> moveStage({
    required GroupKeyPackagePreparedPlan plan,
    required GroupKeyPackagePlanStage nextStage,
  }) async => throw UnimplementedError();

  @override
  Future<Result<void>> complete(GroupKeyPackagePreparedPlan plan) async =>
      throw UnimplementedError();
}

final class _LiveDevices implements GroupLiveDeviceResolverPort {
  const _LiveDevices();

  @override
  Future<Result<List<GroupAuthenticatedLiveDevice>>>
  resolveAuthenticatedLiveDevices(String userId) async => Result.success([
    for (final deviceId
        in userId == _alice
            ? const [_aliceDevice, _aliceOther]
            : const [_bobDevice1, _bobDevice2])
      GroupAuthenticatedLiveDevice(userId: userId, deviceId: deviceId),
  ]);
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 8, 9);
}
