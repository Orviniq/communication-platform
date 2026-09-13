import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

final class CreateGroup {
  const CreateGroup({
    required this.repository,
    required this.clock,
    required this.developmentPreviewOnly,
    this.stateMachine = const GroupControlStateMachine(),
  });

  final GroupRepositoryPort repository;
  final TimeSource clock;
  final bool developmentPreviewOnly;
  final GroupControlStateMachine stateMachine;

  Future<Result<GroupState>> call({
    required String currentUserId,
    required String currentDeviceId,
    required String ownerDisplayName,
    required GroupMetadata metadata,
    required Iterable<GroupMember> selectedMembers,
  }) async {
    final normalized = metadata.normalized();
    if (!normalized.isValid) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final members = <GroupMember>[
      GroupMember(
        userId: currentUserId.toLowerCase(),
        displayName: ownerDisplayName,
        role: GroupRole.owner,
        verified: true,
        deviceIds: [currentDeviceId],
      ),
      ...selectedMembers.map(
        (member) => GroupMember(
          userId: member.userId.toLowerCase(),
          displayName: member.displayName,
          role: GroupRole.member,
          membership: GroupMembershipState.active,
          verified: member.verified,
          deviceIds: member.deviceIds,
        ),
      ),
    ];
    final ids = members.map((member) => member.userId).toSet();
    if (ids.length != members.length ||
        members.length < 2 ||
        members.length > GroupState.maximumMembers) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    final intent = GroupCreationIntent(
      creatorUserId: currentUserId.toLowerCase(),
      creatorDeviceId: currentDeviceId.toLowerCase(),
      metadata: normalized,
      members: members,
      createdMs: clock.now().toUtc().millisecondsSinceEpoch,
    );
    final preparedResult = await crypto.prepareCreate(intent);
    if (preparedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final prepared = (preparedResult as Success<PreparedGroupTransition>).value;
    final applied = stateMachine.apply(
      previous: null,
      signedControl: prepared.signedControl,
      localUserId: currentUserId,
    );
    // A locally originated transition must carry the exact object its peers
    // need. Committing one without it would advance this device to an epoch
    // no peer can ever reach, and the transaction boundary cannot tell the
    // difference on its own because an inbound commit legitimately has none.
    if (applied is! GroupControlAccepted || !prepared.outbound) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final committed = await repository.commitTransition(
      expectedPrevious: null,
      next: applied.state,
      prepared: prepared,
      developmentPreviewOnly: developmentPreviewOnly,
    );
    return committed.fold(
      onSuccess: (_) => Result.success(applied.state),
      onFailure: Result.failure,
    );
  }
}

final class MutateGroup {
  const MutateGroup({
    required this.repository,
    required this.clock,
    required this.developmentPreviewOnly,
    this.stateMachine = const GroupControlStateMachine(),
  });

  final GroupRepositoryPort repository;
  final TimeSource clock;
  final bool developmentPreviewOnly;
  final GroupControlStateMachine stateMachine;

  Future<Result<GroupState>> call({
    required String groupId,
    required String actorUserId,
    required String actorDeviceId,
    required GroupControlOperation operation,
  }) async {
    final groupResult = await repository.readGroup(groupId);
    if (groupResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final current = (groupResult as Success<GroupState?>).value;
    if (current == null) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    if (!_authorized(current, actorUserId, operation)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final stateResult = await repository.readOpaqueMlsState(groupId);
    if (stateResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final opaqueState = (stateResult as Success<Uint8List?>).value;
    if (opaqueState == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final preparedResult = await crypto.prepareControl(
      current: current,
      currentOpaqueMlsState: opaqueState,
      operation: operation,
      actorUserId: actorUserId.toLowerCase(),
      actorDeviceId: actorDeviceId.toLowerCase(),
      createdMs: clock.now().toUtc().millisecondsSinceEpoch,
    );
    if (preparedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final prepared = (preparedResult as Success<PreparedGroupTransition>).value;
    final applied = stateMachine.apply(
      previous: current,
      signedControl: prepared.signedControl,
      localUserId: actorUserId,
    );
    if (applied is! GroupControlAccepted || !prepared.outbound) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final committed = await repository.commitTransition(
      expectedPrevious: current,
      next: applied.state,
      prepared: prepared,
      developmentPreviewOnly: developmentPreviewOnly,
    );
    return committed.fold(
      onSuccess: (_) => Result.success(applied.state),
      onFailure: Result.failure,
    );
  }

  bool _authorized(
    GroupState state,
    String actorUserId,
    GroupControlOperation operation,
  ) {
    final permission = operation.requiredPermission;
    if (permission == null ||
        !GroupAuthorization.allows(state, actorUserId, permission)) {
      return false;
    }
    return switch (operation) {
      RemoveGroupMemberOperation(:final targetUserId) =>
        GroupAuthorization.canRemove(
          state,
          actorUserId: actorUserId,
          targetUserId: targetUserId,
        ),
      LeaveGroupOperation() => GroupAuthorization.canLeave(state, actorUserId),
      ChangeGroupRoleOperation(:final targetUserId, :final role) =>
        GroupAuthorization.canChangeRole(
          state,
          actorUserId: actorUserId,
          targetUserId: targetUserId,
          role: role,
        ),
      TransferGroupOwnershipOperation(:final targetUserId) =>
        state.member(targetUserId)?.isActive == true &&
            state.member(targetUserId)?.role != GroupRole.owner,
      _ => true,
    };
  }
}

final class SendGroupMessage {
  const SendGroupMessage({
    required this.repository,
    required this.clock,
    required this.developmentPreviewOnly,
  });

  final GroupRepositoryPort repository;
  final TimeSource clock;
  final bool developmentPreviewOnly;

  Future<Result<GroupMessage>> call({
    required String groupId,
    required String senderUserId,
    required String senderDeviceId,
    required String text,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty ||
        normalized.runes.length > 16384 ||
        normalized.codeUnits.length > 65536) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final groupResult = await repository.readGroup(groupId);
    if (groupResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final group = (groupResult as Success<GroupState?>).value;
    if (group == null ||
        !GroupAuthorization.allows(
          group,
          senderUserId,
          GroupPermission.sendMessages,
        )) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final stateResult = await repository.readOpaqueMlsState(groupId);
    if (stateResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final state = (stateResult as Success<Uint8List?>).value;
    if (state == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final preparedResult = await crypto.prepareApplicationMessage(
      current: group,
      currentOpaqueMlsState: state,
      senderUserId: senderUserId.toLowerCase(),
      senderDeviceId: senderDeviceId.toLowerCase(),
      text: normalized,
      createdMs: clock.now().toUtc().millisecondsSinceEpoch,
    );
    if (preparedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final prepared = (preparedResult as Success<PreparedGroupMessage>).value;
    if (!prepared.outbound) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final committed = await repository.commitMessage(
      expectedGroup: group,
      prepared: prepared,
      developmentPreviewOnly: developmentPreviewOnly,
    );
    return committed.fold(
      onSuccess: (_) => Result.success(
        GroupMessage(
          messageId: prepared.messageId,
          groupId: prepared.groupId,
          senderUserId: prepared.senderUserId,
          text: prepared.text,
          createdMs: prepared.createdMs,
          localPreviewOnly: developmentPreviewOnly,
        ),
      ),
      onFailure: Result.failure,
    );
  }
}

final class ApplyIncomingGroupControl {
  const ApplyIncomingGroupControl({
    required this.repository,
    required this.clock,
    required this.localUserId,
    required this.localDeviceId,
    this.stateMachine = const GroupControlStateMachine(),
  });

  final GroupRepositoryPort repository;
  final TimeSource clock;
  final String localUserId;
  final String localDeviceId;
  final GroupControlStateMachine stateMachine;

  Future<Result<GroupControlApplyResult>> call({
    required String groupId,
    required Uint8List mlsObject,
    required Uint8List opaqueDigest,
  }) async {
    final groupResult = await repository.readGroup(groupId);
    if (groupResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final current = (groupResult as Success<GroupState?>).value;
    if (current == null) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final stateResult = await repository.readOpaqueMlsState(groupId);
    if (stateResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final state = (stateResult as Success<Uint8List?>).value;
    if (state == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final inspected = await crypto.inspectIncomingControl(
      current: current,
      currentOpaqueMlsState: state,
      mlsObject: mlsObject,
      localUserId: localUserId,
      localDeviceId: localDeviceId,
    );
    if (inspected case FailureResult(failure: final failure)) {
      final reason =
          failure is SecurityFailure &&
              failure.kind == SecurityFailureKind.unauthenticatedInput
          ? GroupQuarantineReason.unauthenticatedControl
          : GroupQuarantineReason.malformedControl;
      final quarantined = await repository.quarantine(
        GroupQuarantineRecord(
          groupId: groupId,
          reason: reason,
          opaqueDigest: opaqueDigest,
          receivedAt: clock.now().toUtc(),
        ),
      );
      return quarantined.fold(
        onSuccess: (_) =>
            Result.success(GroupControlQuarantined(current, reason)),
        onFailure: Result.failure,
      );
    }
    final prepared = (inspected as Success<PreparedGroupTransition>).value;
    final applied = stateMachine.apply(
      previous: current,
      signedControl: prepared.signedControl,
      localUserId: localUserId,
    );
    switch (applied) {
      case GroupControlAccepted(:final state):
        final committed = await repository.commitTransition(
          expectedPrevious: current,
          next: state,
          prepared: prepared,
          developmentPreviewOnly: false,
        );
        return committed.fold(
          onSuccess: (_) => Result.success(applied),
          onFailure: Result.failure,
        );
      case GroupControlDuplicate():
        return Result.success(applied);
      case GroupControlQuarantined(:final reason):
        final stored = await repository.quarantine(
          GroupQuarantineRecord(
            groupId: groupId,
            reason: reason,
            opaqueDigest: opaqueDigest,
            receivedAt: clock.now().toUtc(),
          ),
        );
        return stored.fold(
          onSuccess: (_) => Result.success(applied),
          onFailure: Result.failure,
        );
    }
  }
}

final class ApplyIncomingGroupMessage {
  const ApplyIncomingGroupMessage({required this.repository});

  final GroupRepositoryPort repository;

  Future<Result<GroupMessage>> call({
    required String groupId,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async {
    final groupResult = await repository.readGroup(groupId);
    if (groupResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final current = (groupResult as Success<GroupState?>).value;
    if (current == null) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final stateResult = await repository.readOpaqueMlsState(groupId);
    if (stateResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final state = (stateResult as Success<Uint8List?>).value;
    if (state == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final inspected = await crypto.inspectIncomingApplication(
      current: current,
      currentOpaqueMlsState: state,
      mlsObject: mlsObject,
      localUserId: localUserId.toLowerCase(),
      localDeviceId: localDeviceId.toLowerCase(),
    );
    if (inspected case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final prepared = (inspected as Success<PreparedGroupMessage>).value;
    if (prepared.outbound) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final committed = await repository.commitMessage(
      expectedGroup: current,
      prepared: prepared,
      developmentPreviewOnly: false,
    );
    return committed.fold(
      onSuccess: (_) => Result.success(
        GroupMessage(
          messageId: prepared.messageId,
          groupId: prepared.groupId,
          senderUserId: prepared.senderUserId,
          text: prepared.text,
          createdMs: prepared.createdMs,
          localPreviewOnly: false,
        ),
      ),
      onFailure: Result.failure,
    );
  }
}

final class GroupUseCases {
  const GroupUseCases({
    required this.create,
    required this.mutate,
    required this.sendMessage,
    required this.applyIncomingMessage,
  });

  final CreateGroup create;
  final MutateGroup mutate;
  final SendGroupMessage sendMessage;
  final ApplyIncomingGroupMessage applyIncomingMessage;
}
