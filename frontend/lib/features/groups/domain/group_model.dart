import 'dart:collection';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/group_sync_model.dart';

enum GroupRole { owner, admin, member }

enum GroupMembershipState { active, removed, left }

enum GroupInvitationPolicy { ownerOnly, ownerAndAdmins, allMembers }

enum GroupHistorySharingPolicy { reshareAvailable, newMessagesOnly }

/// Where this device stands in a group.
///
/// [stateRecoveryRequired] is never stored. It is laid over the stored value
/// while a lost envelope may have carried a control event this device has not
/// seen, until a member answers with the group's current control state.
enum GroupLifecycle {
  active,
  removed,
  left,
  stateRecoveryRequired,
  forkQuarantined,
  controlQuarantined,
}

enum GroupQuarantineReason {
  siblingControl,
  staleRevision,
  brokenControlChain,
  malformedControl,
  unauthenticatedControl,
  unauthorizedControl,
  invalidMembership,
}

enum GroupPermission {
  viewHistory,
  sendMessages,
  inviteMembers,
  removeMembers,
  editMetadata,
  changeRoles,
  transferOwnership,
  pinMessages,
  leave,
}

final class GroupMetadata {
  const GroupMetadata({required this.name, this.description = ''});

  static const maximumNameScalars = 100;
  static const maximumDescriptionScalars = 1000;

  final String name;
  final String description;

  bool get isValid {
    final normalizedName = name.trim();
    return normalizedName.isNotEmpty &&
        normalizedName.runes.length <= maximumNameScalars &&
        description.runes.length <= maximumDescriptionScalars;
  }

  GroupMetadata normalized() =>
      GroupMetadata(name: name.trim(), description: description.trim());

  @override
  bool operator ==(Object other) =>
      other is GroupMetadata &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(name, description);
}

/// One member of a group, as this device holds it.
///
/// [userId], [role] and [membership] are the roster every member agrees on,
/// because each is derived from signed control events. [displayName] and
/// [verified] are this device's own presentation of the member: neither is
/// signed, neither leaves the device, and another member's device may hold
/// different values for both.
final class GroupMember {
  GroupMember({
    required String userId,
    required this.displayName,
    required this.role,
    this.membership = GroupMembershipState.active,
    this.verified = false,
  }) : userId = userId.toLowerCase() {
    if (!_groupUuid.hasMatch(this.userId)) {
      throw const FormatException('invalid group member');
    }
  }

  final String userId;
  final String displayName;
  final GroupRole role;
  final GroupMembershipState membership;
  final bool verified;

  bool get isActive => membership == GroupMembershipState.active;

  GroupMember copyWith({
    String? displayName,
    GroupRole? role,
    GroupMembershipState? membership,
    bool? verified,
  }) => GroupMember(
    userId: userId,
    displayName: displayName ?? this.displayName,
    role: role ?? this.role,
    membership: membership ?? this.membership,
    verified: verified ?? this.verified,
  );

  @override
  bool operator ==(Object other) =>
      other is GroupMember &&
      other.userId == userId &&
      other.displayName == displayName &&
      other.role == role &&
      other.membership == membership &&
      other.verified == verified;

  @override
  int get hashCode =>
      Object.hash(userId, displayName, role, membership, verified);
}

/// Minimal group-owned projection of one account-authenticated live device.
///
/// [signingPublic] is the Ed25519 half of the device's `ik_pub`, taken from the
/// device list the contacts feature verified against the account identity and
/// the signed device log. It is the only key a group control event from this
/// device is checked against.
final class GroupAuthenticatedLiveDevice {
  GroupAuthenticatedLiveDevice({
    required String userId,
    required String deviceId,
    required Uint8List signingPublic,
  }) : userId = userId.toLowerCase(),
       deviceId = deviceId.toLowerCase(),
       signingPublic = Uint8List.fromList(signingPublic) {
    if (!_groupUuid.hasMatch(this.userId) ||
        !_groupUuid.hasMatch(this.deviceId) ||
        this.signingPublic.length != 32) {
      throw const FormatException('invalid authenticated live device');
    }
  }

  final String userId;
  final String deviceId;
  final Uint8List signingPublic;
}

final class GroupState {
  GroupState({
    required this.groupId,
    required this.metadata,
    required this.invitationPolicy,
    required this.historySharingPolicy,
    required Iterable<GroupMember> members,
    required this.controlRevision,
    required this.controlStateHash,
    this.lifecycle = GroupLifecycle.active,
    this.quarantineReason,
  }) : members = List.unmodifiable(_sortedMembers(members)) {
    if (!_isHex(groupId, groupIdBytes) ||
        controlRevision < 1 ||
        !_isHex(controlStateHash, stateHashBytes) ||
        !metadata.isValid ||
        this.members.length > maximumMembers ||
        this.members.map((member) => member.userId).toSet().length !=
            this.members.length) {
      throw const FormatException('invalid group state');
    }
    final activeOwners = this.members
        .where((member) => member.isActive && member.role == GroupRole.owner)
        .length;
    if (activeOwners != 1 && lifecycle != GroupLifecycle.left) {
      throw const FormatException('a live group requires exactly one owner');
    }
    if ((lifecycle == GroupLifecycle.forkQuarantined ||
            lifecycle == GroupLifecycle.controlQuarantined) !=
        (quarantineReason != null)) {
      throw const FormatException('quarantine state and reason mismatch');
    }
  }

  static const maximumMembers = 50;
  static const groupIdBytes = 32;
  static const stateHashBytes = 32;

  final String groupId;
  final GroupMetadata metadata;
  final GroupInvitationPolicy invitationPolicy;
  final GroupHistorySharingPolicy historySharingPolicy;
  final List<GroupMember> members;
  final int controlRevision;
  final String controlStateHash;
  final GroupLifecycle lifecycle;
  final GroupQuarantineReason? quarantineReason;

  Iterable<GroupMember> get activeMembers =>
      members.where((member) => member.isActive);

  GroupMember? member(String userId) {
    final normalized = userId.toLowerCase();
    for (final member in members) {
      if (member.userId == normalized) return member;
    }
    return null;
  }

  GroupState copyWith({
    GroupMetadata? metadata,
    Iterable<GroupMember>? members,
    int? controlRevision,
    String? controlStateHash,
    GroupLifecycle? lifecycle,
    GroupQuarantineReason? quarantineReason,
    bool clearQuarantineReason = false,
  }) => GroupState(
    groupId: groupId,
    metadata: metadata ?? this.metadata,
    invitationPolicy: invitationPolicy,
    historySharingPolicy: historySharingPolicy,
    members: members ?? this.members,
    controlRevision: controlRevision ?? this.controlRevision,
    controlStateHash: controlStateHash ?? this.controlStateHash,
    lifecycle: lifecycle ?? this.lifecycle,
    quarantineReason: clearQuarantineReason
        ? null
        : quarantineReason ?? this.quarantineReason,
  );
}

abstract final class GroupAuthorization {
  static Set<GroupPermission> permissionsFor(
    GroupState state,
    String actorUserId,
  ) {
    final member = state.member(actorUserId);
    if (member == null) return const {};
    if (!member.isActive || state.lifecycle != GroupLifecycle.active) {
      return const {GroupPermission.viewHistory};
    }
    return _activeMemberPermissions(state, member);
  }

  static Set<GroupPermission> _activeMemberPermissions(
    GroupState state,
    GroupMember member,
  ) {
    final permissions = <GroupPermission>{
      GroupPermission.viewHistory,
      GroupPermission.sendMessages,
      GroupPermission.leave,
    };
    if (_mayInvite(state.invitationPolicy, member.role)) {
      permissions.add(GroupPermission.inviteMembers);
    }
    if (member.role == GroupRole.admin || member.role == GroupRole.owner) {
      permissions
        ..add(GroupPermission.removeMembers)
        ..add(GroupPermission.editMetadata)
        ..add(GroupPermission.pinMessages);
    }
    if (member.role == GroupRole.owner) {
      permissions
        ..add(GroupPermission.changeRoles)
        ..add(GroupPermission.transferOwnership);
    }
    return UnmodifiableSetView(permissions);
  }

  static bool allows(
    GroupState state,
    String actorUserId,
    GroupPermission permission,
  ) => permissionsFor(state, actorUserId).contains(permission);

  /// Evaluates a signed control's signer against the roster the control was
  /// built on. This device's own lifecycle is deliberately irrelevant: a
  /// removed device still decides correctly whether somebody else's event was
  /// authorized.
  static bool allowsControl(
    GroupState state,
    String actorUserId,
    GroupPermission permission,
  ) {
    final member = state.member(actorUserId);
    return member != null &&
        member.isActive &&
        _activeMemberPermissions(state, member).contains(permission);
  }

  static bool canAdd(
    GroupState state, {
    required String actorUserId,
    required Iterable<String> targetUserIds,
    bool forControl = false,
  }) {
    final targets = targetUserIds
        .map((value) => value.toLowerCase())
        .toList(growable: false);
    if (targets.isEmpty ||
        targets.toSet().length != targets.length ||
        !(forControl ? allowsControl : allows)(
          state,
          actorUserId,
          GroupPermission.inviteMembers,
        ) ||
        state.activeMembers.length + targets.length >
            GroupState.maximumMembers) {
      return false;
    }
    return targets.every((target) => state.member(target)?.isActive != true);
  }

  static bool canRemove(
    GroupState state, {
    required String actorUserId,
    required String targetUserId,
    bool forControl = false,
  }) {
    if (actorUserId.toLowerCase() == targetUserId.toLowerCase() ||
        !(forControl ? allowsControl : allows)(
          state,
          actorUserId,
          GroupPermission.removeMembers,
        )) {
      return false;
    }
    final actor = state.member(actorUserId);
    final target = state.member(targetUserId);
    if (actor == null ||
        target == null ||
        !target.isActive ||
        target.role == GroupRole.owner) {
      return false;
    }
    return actor.role == GroupRole.owner || target.role == GroupRole.member;
  }

  /// Promotes or demotes a member. Handing the group to another owner is
  /// [canTransferOwnership], because it changes two roles at once.
  static bool canChangeRole(
    GroupState state, {
    required String actorUserId,
    required String targetUserId,
    required GroupRole role,
    bool forControl = false,
  }) {
    if (role == GroupRole.owner ||
        actorUserId.toLowerCase() == targetUserId.toLowerCase() ||
        !(forControl ? allowsControl : allows)(
          state,
          actorUserId,
          GroupPermission.changeRoles,
        )) {
      return false;
    }
    final target = state.member(targetUserId);
    return target != null &&
        target.isActive &&
        target.role != GroupRole.owner &&
        target.role != role;
  }

  static bool canTransferOwnership(
    GroupState state, {
    required String actorUserId,
    required String targetUserId,
    bool forControl = false,
  }) {
    if (actorUserId.toLowerCase() == targetUserId.toLowerCase() ||
        !(forControl ? allowsControl : allows)(
          state,
          actorUserId,
          GroupPermission.transferOwnership,
        )) {
      return false;
    }
    final target = state.member(targetUserId);
    return target != null && target.isActive && target.role != GroupRole.owner;
  }

  /// A leave is a member removing itself. An owner may only leave a group it
  /// is the last active member of, so a live group never loses its owner.
  static bool canLeave(
    GroupState state,
    String actorUserId, {
    bool forControl = false,
  }) {
    if (!(forControl ? allowsControl : allows)(
      state,
      actorUserId,
      GroupPermission.leave,
    )) {
      return false;
    }
    final actor = state.member(actorUserId)!;
    return actor.role != GroupRole.owner || state.activeMembers.length == 1;
  }

  static bool _mayInvite(GroupInvitationPolicy policy, GroupRole role) =>
      switch (policy) {
        GroupInvitationPolicy.ownerOnly => role == GroupRole.owner,
        GroupInvitationPolicy.ownerAndAdmins => role != GroupRole.member,
        GroupInvitationPolicy.allMembers => true,
      };
}

/// The five control event kinds, by the value each carries on the wire.
enum GroupControlKind {
  create(1),
  addMember(2),
  removeMember(3),
  changeRole(4),
  rename(5);

  const GroupControlKind(this.wireValue);

  final int wireValue;

  static GroupControlKind? fromWireValue(int value) {
    for (final kind in values) {
      if (kind.wireValue == value) return kind;
    }
    return null;
  }
}

sealed class GroupControlOperation {
  const GroupControlOperation();

  GroupControlKind get kind;
}

/// Starts a group. Its policies are fixed here: no later event changes them.
final class CreateGroupOperation extends GroupControlOperation {
  CreateGroupOperation({
    required this.metadata,
    required this.invitationPolicy,
    required this.historySharingPolicy,
    required Iterable<GroupMember> members,
  }) : members = List.unmodifiable(_sortedMembers(members));

  final GroupMetadata metadata;
  final GroupInvitationPolicy invitationPolicy;
  final GroupHistorySharingPolicy historySharingPolicy;
  final List<GroupMember> members;

  @override
  GroupControlKind get kind => GroupControlKind.create;
}

/// Adds members, each with the member role. A member who was removed or left
/// may be added again.
final class AddGroupMembersOperation extends GroupControlOperation {
  AddGroupMembersOperation(Iterable<GroupMember> members)
    : members = List.unmodifiable(_sortedMembers(members));

  final List<GroupMember> members;

  @override
  GroupControlKind get kind => GroupControlKind.addMember;
}

/// Removes a member. A member removing itself is leaving.
final class RemoveGroupMemberOperation extends GroupControlOperation {
  RemoveGroupMemberOperation(String targetUserId)
    : targetUserId = targetUserId.toLowerCase();

  final String targetUserId;

  @override
  GroupControlKind get kind => GroupControlKind.removeMember;
}

/// Changes one member's role. [GroupRole.owner] hands the group over: the
/// target becomes the owner and the owner who signed becomes an admin.
final class ChangeGroupRoleOperation extends GroupControlOperation {
  ChangeGroupRoleOperation({required String targetUserId, required this.role})
    : targetUserId = targetUserId.toLowerCase();

  final String targetUserId;
  final GroupRole role;

  @override
  GroupControlKind get kind => GroupControlKind.changeRole;
}

/// Renames the group and replaces its description.
final class RenameGroupOperation extends GroupControlOperation {
  const RenameGroupOperation(this.metadata);

  final GroupMetadata metadata;

  @override
  GroupControlKind get kind => GroupControlKind.rename;
}

/// One group control event.
///
/// Its wire form is deterministic CBOR built by the shared native core, which
/// also signs it with the device identity. This is the typed view of the same
/// event; nothing here is an encoder, and nothing here is signed.
final class GroupControlEvent {
  GroupControlEvent({
    this.protocolVersion = 1,
    required this.eventId,
    required this.groupId,
    required this.revision,
    required this.previousControlStateHash,
    required String signerUserId,
    required String signerDeviceId,
    required this.createdMs,
    required this.operation,
  }) : signerUserId = signerUserId.toLowerCase(),
       signerDeviceId = signerDeviceId.toLowerCase() {
    if (protocolVersion != 1 ||
        !_isHex(eventId, eventIdBytes) ||
        !_isHex(groupId, GroupState.groupIdBytes) ||
        revision < 1 ||
        revision > maximumRevision ||
        (revision == 1) != (previousControlStateHash == null) ||
        (revision == 1) != (operation is CreateGroupOperation) ||
        (previousControlStateHash != null &&
            !_isHex(previousControlStateHash!, GroupState.stateHashBytes)) ||
        !_groupUuid.hasMatch(this.signerUserId) ||
        !_groupUuid.hasMatch(this.signerDeviceId) ||
        createdMs < 0) {
      throw const FormatException('invalid group control event');
    }
  }

  static const eventIdBytes = 16;
  static const maximumRevision = 0xffffffff;

  final int protocolVersion;
  final String eventId;
  final String groupId;
  final int revision;
  final String? previousControlStateHash;
  final String signerUserId;
  final String signerDeviceId;
  final int createdMs;
  final GroupControlOperation operation;
}

/// A control event together with the exact bytes its signer signed.
final class SignedGroupControlEvent {
  SignedGroupControlEvent({
    required this.event,
    required this.controlStateHash,
    required Uint8List canonicalBytes,
    required Uint8List signature,
  }) : canonicalBytes = Uint8List.fromList(canonicalBytes),
       signature = Uint8List.fromList(signature) {
    if (!_isHex(controlStateHash, GroupState.stateHashBytes) ||
        this.canonicalBytes.isEmpty ||
        this.canonicalBytes.length > maximumCanonicalBytes ||
        this.signature.length != signatureBytes) {
      throw const FormatException('invalid signed group control');
    }
  }

  static const maximumCanonicalBytes = 16384;
  static const signatureBytes = 64;

  final GroupControlEvent event;

  /// The hash this event commits the group to. The next event names it.
  final String controlStateHash;
  final Uint8List canonicalBytes;
  final Uint8List signature;

  StoredGroupControl get stored => StoredGroupControl(
    eventId: event.eventId,
    revision: event.revision,
    previousControlStateHash: event.previousControlStateHash,
    controlStateHash: controlStateHash,
    signerUserId: event.signerUserId,
    signerDeviceId: event.signerDeviceId,
    canonicalBytes: canonicalBytes,
    signature: signature,
  );
}

/// One accepted transcript entry as storage holds it: enough to hand the
/// signed bytes to another device and to check the chain, and nothing that
/// would need the native core to read back.
final class StoredGroupControl {
  StoredGroupControl({
    required this.eventId,
    required this.revision,
    required this.previousControlStateHash,
    required this.controlStateHash,
    required String signerUserId,
    required String signerDeviceId,
    required Uint8List canonicalBytes,
    required Uint8List signature,
  }) : signerUserId = signerUserId.toLowerCase(),
       signerDeviceId = signerDeviceId.toLowerCase(),
       canonicalBytes = Uint8List.fromList(canonicalBytes),
       signature = Uint8List.fromList(signature) {
    if (!_isHex(eventId, GroupControlEvent.eventIdBytes) ||
        revision < 1 ||
        (revision == 1) != (previousControlStateHash == null) ||
        (previousControlStateHash != null &&
            !_isHex(previousControlStateHash!, GroupState.stateHashBytes)) ||
        !_isHex(controlStateHash, GroupState.stateHashBytes) ||
        !_groupUuid.hasMatch(this.signerUserId) ||
        !_groupUuid.hasMatch(this.signerDeviceId) ||
        this.canonicalBytes.isEmpty ||
        this.canonicalBytes.length >
            SignedGroupControlEvent.maximumCanonicalBytes ||
        this.signature.length != SignedGroupControlEvent.signatureBytes) {
      throw const FormatException('invalid stored group control');
    }
  }

  final String eventId;
  final int revision;
  final String? previousControlStateHash;
  final String controlStateHash;
  final String signerUserId;
  final String signerDeviceId;
  final Uint8List canonicalBytes;
  final Uint8List signature;
}

sealed class GroupControlApplyResult {
  const GroupControlApplyResult();
}

final class GroupControlAccepted extends GroupControlApplyResult {
  const GroupControlAccepted(this.state);
  final GroupState state;
}

/// The event is this device's current head, already applied.
final class GroupControlDuplicate extends GroupControlApplyResult {
  const GroupControlDuplicate(this.state);
  final GroupState state;
}

/// The event is older than this device's head. Whether it is one this device
/// accepted or a branch it never saw is a question for the stored transcript,
/// which the state machine does not hold.
final class GroupControlStale extends GroupControlApplyResult {
  const GroupControlStale(this.state);
  final GroupState state;
}

/// The event builds on a revision this device has not reached, or on a group
/// it does not know. Nothing about it is wrong; something before it is
/// missing, and a member is asked for it.
final class GroupControlAhead extends GroupControlApplyResult {
  const GroupControlAhead(this.state);
  final GroupState? state;
}

final class GroupControlQuarantined extends GroupControlApplyResult {
  const GroupControlQuarantined(this.state, this.reason);
  final GroupState? state;
  final GroupQuarantineReason reason;
}

/// Applies authenticated control events to a group's roster.
///
/// Its input is an event whose signature the native core already verified
/// under the signer device's authenticated key. What it decides is everything
/// the signature cannot: whether the event extends this device's chain, and
/// whether its signer was allowed to make it by the roster it was built on.
final class GroupControlStateMachine {
  const GroupControlStateMachine();

  GroupControlApplyResult apply({
    required GroupState? previous,
    required SignedGroupControlEvent signedControl,
    required String localUserId,
  }) {
    final event = signedControl.event;
    final local = localUserId.toLowerCase();
    if (previous == null) {
      return event.revision == 1
          ? _create(event, signedControl.controlStateHash, local)
          : const GroupControlAhead(null);
    }
    if (event.groupId != previous.groupId) {
      return GroupControlQuarantined(
        previous,
        GroupQuarantineReason.brokenControlChain,
      );
    }
    if (event.revision == previous.controlRevision) {
      return signedControl.controlStateHash == previous.controlStateHash
          ? GroupControlDuplicate(previous)
          : GroupControlQuarantined(
              previous,
              GroupQuarantineReason.siblingControl,
            );
    }
    if (event.revision < previous.controlRevision) {
      return GroupControlStale(previous);
    }
    if (event.revision > previous.controlRevision + 1) {
      return GroupControlAhead(previous);
    }
    if (event.previousControlStateHash != previous.controlStateHash) {
      return GroupControlQuarantined(
        previous,
        GroupQuarantineReason.siblingControl,
      );
    }
    final next = _applyOperation(previous, event, local);
    if (next == null) {
      return GroupControlQuarantined(
        previous,
        GroupQuarantineReason.unauthorizedControl,
      );
    }
    try {
      return GroupControlAccepted(
        GroupState(
          groupId: previous.groupId,
          metadata: next.metadata,
          invitationPolicy: previous.invitationPolicy,
          historySharingPolicy: previous.historySharingPolicy,
          members: next.members,
          controlRevision: event.revision,
          controlStateHash: signedControl.controlStateHash,
          lifecycle: next.lifecycle,
        ),
      );
    } on FormatException {
      return GroupControlQuarantined(
        previous,
        GroupQuarantineReason.invalidMembership,
      );
    }
  }

  GroupControlApplyResult _create(
    GroupControlEvent event,
    String controlStateHash,
    String localUserId,
  ) {
    final operation = event.operation;
    if (operation is! CreateGroupOperation ||
        !operation.metadata.isValid ||
        operation.members.isEmpty ||
        operation.members.length > GroupState.maximumMembers ||
        operation.members.any((member) => !member.isActive)) {
      return const GroupControlQuarantined(
        null,
        GroupQuarantineReason.invalidMembership,
      );
    }
    final owners = operation.members
        .where((member) => member.role == GroupRole.owner)
        .toList(growable: false);
    if (owners.length != 1 || owners.single.userId != event.signerUserId) {
      return const GroupControlQuarantined(
        null,
        GroupQuarantineReason.unauthorizedControl,
      );
    }
    try {
      return GroupControlAccepted(
        GroupState(
          groupId: event.groupId,
          metadata: operation.metadata.normalized(),
          invitationPolicy: operation.invitationPolicy,
          historySharingPolicy: operation.historySharingPolicy,
          members: operation.members,
          controlRevision: 1,
          controlStateHash: controlStateHash,
          // A member added later replays the group from this event, before the
          // event that adds it. Until then it is outside the group, which is
          // the removed lifecycle; the add makes it active.
          lifecycle:
              operation.members.any((member) => member.userId == localUserId)
              ? GroupLifecycle.active
              : GroupLifecycle.removed,
        ),
      );
    } on FormatException {
      return const GroupControlQuarantined(
        null,
        GroupQuarantineReason.invalidMembership,
      );
    }
  }

  _MutableGroupState? _applyOperation(
    GroupState previous,
    GroupControlEvent event,
    String localUserId,
  ) {
    final mutable = _MutableGroupState.from(previous);
    final actor = event.signerUserId;
    switch (event.operation) {
      case CreateGroupOperation():
        return null;
      case AddGroupMembersOperation(:final members):
        if (members.any(
              (member) => !member.isActive || member.role != GroupRole.member,
            ) ||
            !GroupAuthorization.canAdd(
              previous,
              actorUserId: actor,
              targetUserIds: members.map((member) => member.userId),
              forControl: true,
            )) {
          return null;
        }
        for (final member in members) {
          final existing = previous.member(member.userId);
          if (existing == null) {
            mutable.members.add(member);
          } else {
            mutable.replaceMember(
              member.userId,
              (current) => member.copyWith(
                displayName: current.displayName.isEmpty
                    ? member.displayName
                    : current.displayName,
                verified: current.verified || member.verified,
              ),
            );
          }
          if (member.userId == localUserId) {
            mutable.lifecycle = GroupLifecycle.active;
          }
        }
      case RemoveGroupMemberOperation(:final targetUserId)
          when targetUserId == actor:
        if (!GroupAuthorization.canLeave(previous, actor, forControl: true)) {
          return null;
        }
        mutable.replaceMember(
          actor,
          (member) => member.copyWith(membership: GroupMembershipState.left),
        );
        if (actor == localUserId) {
          mutable.lifecycle = GroupLifecycle.left;
        }
      case RemoveGroupMemberOperation(:final targetUserId):
        if (!GroupAuthorization.canRemove(
          previous,
          actorUserId: actor,
          targetUserId: targetUserId,
          forControl: true,
        )) {
          return null;
        }
        mutable.replaceMember(
          targetUserId,
          (member) => member.copyWith(membership: GroupMembershipState.removed),
        );
        if (targetUserId == localUserId) {
          mutable.lifecycle = GroupLifecycle.removed;
        }
      case ChangeGroupRoleOperation(:final targetUserId, :final role)
          when role == GroupRole.owner:
        if (!GroupAuthorization.canTransferOwnership(
          previous,
          actorUserId: actor,
          targetUserId: targetUserId,
          forControl: true,
        )) {
          return null;
        }
        mutable
          ..replaceMember(
            actor,
            (member) => member.copyWith(role: GroupRole.admin),
          )
          ..replaceMember(
            targetUserId,
            (member) => member.copyWith(role: GroupRole.owner),
          );
      case ChangeGroupRoleOperation(:final targetUserId, :final role):
        if (!GroupAuthorization.canChangeRole(
          previous,
          actorUserId: actor,
          targetUserId: targetUserId,
          role: role,
          forControl: true,
        )) {
          return null;
        }
        mutable.replaceMember(
          targetUserId,
          (member) => member.copyWith(role: role),
        );
      case RenameGroupOperation(:final metadata):
        if (!metadata.isValid ||
            !GroupAuthorization.allowsControl(
              previous,
              actor,
              GroupPermission.editMetadata,
            )) {
          return null;
        }
        mutable.metadata = metadata.normalized();
    }
    return mutable;
  }
}

/// Exact bytes owed to other devices, committed in the same transaction as
/// the state change that produced them and fanned out afterwards.
final class GroupOutboundWork {
  GroupOutboundWork({
    required this.operationId,
    required this.groupId,
    required this.eventId,
    required Uint8List payload,
    required Iterable<String> recipientUserIds,
    this.recipientDeviceId,
    this.includeOwnDevices = false,
  }) : payload = Uint8List.fromList(payload),
       recipientUserIds = List.unmodifiable(
         recipientUserIds.map((value) => value.toLowerCase()),
       ) {
    if (operationId.isEmpty ||
        !_isHex(groupId, GroupState.groupIdBytes) ||
        eventId.isEmpty ||
        this.payload.isEmpty ||
        this.recipientUserIds.toSet().length != this.recipientUserIds.length ||
        this.recipientUserIds.any((value) => !_groupUuid.hasMatch(value)) ||
        (this.recipientUserIds.isEmpty && !includeOwnDevices) ||
        (recipientDeviceId != null &&
            (this.recipientUserIds.length != 1 ||
                includeOwnDevices ||
                !_groupUuid.hasMatch(recipientDeviceId!)))) {
      throw const FormatException('invalid group outbound work');
    }
  }

  final String operationId;
  final String groupId;
  final String eventId;
  final Uint8List payload;
  final List<String> recipientUserIds;

  /// Restricts a single-recipient send to one device: the one that asked.
  final String? recipientDeviceId;

  /// Whether this device's other devices receive a copy too.
  final bool includeOwnDevices;
}

enum GroupStateRequestReason {
  /// The mailbox lost envelopes, one of which may have been a control event.
  queueGap,

  /// A control event arrived that builds on state this device does not hold.
  behind,
}

/// That this device still needs a group's control state from a member.
final class GroupStateRequest {
  GroupStateRequest({
    required this.groupId,
    required this.reason,
    required this.peerUserId,
    required this.attempts,
    required this.requestedAt,
  }) {
    if (!_isHex(groupId, GroupState.groupIdBytes) ||
        (peerUserId != null && !_groupUuid.hasMatch(peerUserId!)) ||
        attempts < 0) {
      throw const FormatException('invalid group state request');
    }
  }

  final String groupId;
  final GroupStateRequestReason reason;

  /// Who to ask. Null until a member is chosen for a queue gap.
  final String? peerUserId;
  final int attempts;
  final DateTime? requestedAt;
}

/// One authenticated state change and the bytes it owes other devices.
///
/// [controls] is a contiguous run of the group's chain: one locally signed
/// event, one received event, or the suffix of a transcript a member sent.
final class PreparedGroupTransition {
  PreparedGroupTransition({
    required Iterable<SignedGroupControlEvent> controls,
    Iterable<GroupOutboundWork> outbound = const [],
    this.completesStateRequest = false,
  }) : controls = List.unmodifiable(controls),
       outbound = List.unmodifiable(outbound) {
    if (this.controls.isEmpty) {
      throw const FormatException('a transition requires a control event');
    }
    for (var index = 1; index < this.controls.length; index += 1) {
      final previous = this.controls[index - 1];
      final current = this.controls[index].event;
      if (current.groupId != previous.event.groupId ||
          current.revision != previous.event.revision + 1 ||
          current.previousControlStateHash != previous.controlStateHash) {
        throw const FormatException('a transition must be one chain');
      }
    }
    if (this.outbound.any((work) => work.groupId != last.event.groupId)) {
      throw const FormatException('outbound work for another group');
    }
  }

  final List<SignedGroupControlEvent> controls;
  final List<GroupOutboundWork> outbound;

  /// Whether committing this answers an outstanding state request for the
  /// group, so the request is retired in the same transaction.
  final bool completesStateRequest;

  SignedGroupControlEvent get first => controls.first;
  SignedGroupControlEvent get last => controls.last;
}

/// An inbound group outcome that must commit in the same transaction as the
/// pairwise receive that carried it.
sealed class PreparedGroupInboxCommit implements GroupSyncReceiveCommit {
  const PreparedGroupInboxCommit({
    required this.opaqueEventId,
    required this.senderUserId,
    required this.senderDeviceId,
  });

  @override
  final String opaqueEventId;
  @override
  final String senderUserId;
  @override
  final String senderDeviceId;
}

final class PreparedGroupInboxTransition extends PreparedGroupInboxCommit {
  const PreparedGroupInboxTransition({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.expectedPrevious,
    required this.next,
    required this.prepared,
  });

  final GroupState? expectedPrevious;
  final GroupState next;
  final PreparedGroupTransition prepared;
}

final class PreparedGroupInboxQuarantine extends PreparedGroupInboxCommit {
  const PreparedGroupInboxQuarantine({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.record,
    required this.retainLifecycle,
    this.completesStateRequest = false,
  });

  final GroupQuarantineRecord record;

  /// A fork moves the group into quarantine. An event its signer was not
  /// allowed to make is recorded and dropped, so that one member cannot stop
  /// a group for everybody by signing something invalid.
  final bool retainLifecycle;

  /// Whether the answer that revealed the rejection also retires the group's
  /// open state request, because no other answer could change the outcome.
  final bool completesStateRequest;
}

final class PreparedGroupInboxStateRequest extends PreparedGroupInboxCommit {
  const PreparedGroupInboxStateRequest({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.groupId,
    required this.peerUserId,
  });

  final String groupId;
  final String peerUserId;
}

/// Bytes a member owes the device that asked it for a group's state.
final class PreparedGroupInboxOutbound extends PreparedGroupInboxCommit {
  const PreparedGroupInboxOutbound({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.work,
  });

  final GroupOutboundWork work;
}

/// A member confirmed this device already holds the group's current state.
final class PreparedGroupInboxStateCurrent extends PreparedGroupInboxCommit {
  const PreparedGroupInboxStateCurrent({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.groupId,
    required this.controlRevision,
    required this.controlStateHash,
  });

  final String groupId;
  final int controlRevision;
  final String controlStateHash;
}

/// Where one group message stands on its way to the other members.
///
/// A group message is one encrypted copy for each device of each member
/// (`backend/CLIENT_CONTRACT.md` §F), so a send has ended only when every copy
/// has. [sending] covers that whole interval, including the part in which the
/// server has accepted some copies and not yet others, and [sent] is never
/// reached before it ends.
enum GroupMessageDelivery {
  received,
  localOnly,
  preparing,
  queued,
  sending,
  sent,
  failed,
}

/// How far the copies of one message have got.
///
/// [total] counts the copies owed to devices still in the group's set: a
/// device the server reports as gone leaves the count rather than holding the
/// send open for good, and a device whose mailbox is full stays in it until
/// its copy is accepted.
final class GroupFanoutProgress {
  GroupFanoutProgress({required this.sent, required this.total}) {
    if (sent < 0 || sent > total) {
      throw const FormatException('invalid group fan-out progress');
    }
  }

  final int sent;
  final int total;

  @override
  bool operator ==(Object other) =>
      other is GroupFanoutProgress &&
      other.sent == sent &&
      other.total == total;

  @override
  int get hashCode => Object.hash(sent, total);
}

final class GroupMessage {
  const GroupMessage({
    required this.messageId,
    required this.groupId,
    required this.senderUserId,
    required this.text,
    required this.createdMs,
    required this.delivery,
  });

  final String messageId;
  final String groupId;
  final String senderUserId;
  final String text;
  final int createdMs;
  final GroupMessageDelivery delivery;
}

final class GroupQuarantineRecord {
  GroupQuarantineRecord({
    required this.groupId,
    required this.reason,
    required Uint8List opaqueDigest,
    required this.receivedAt,
  }) : opaqueDigest = Uint8List.fromList(opaqueDigest);

  final String groupId;
  final GroupQuarantineReason reason;
  final Uint8List opaqueDigest;
  final DateTime receivedAt;
}

final class _MutableGroupState {
  _MutableGroupState({
    required this.metadata,
    required this.members,
    required this.lifecycle,
  });

  factory _MutableGroupState.from(GroupState state) => _MutableGroupState(
    metadata: state.metadata,
    members: state.members.toList(),
    lifecycle: state.lifecycle,
  );

  GroupMetadata metadata;
  final List<GroupMember> members;
  GroupLifecycle lifecycle;

  void replaceMember(
    String userId,
    GroupMember Function(GroupMember member) replace,
  ) {
    final normalized = userId.toLowerCase();
    final index = members.indexWhere((member) => member.userId == normalized);
    if (index < 0) throw const FormatException('missing member');
    members[index] = replace(members[index]);
  }
}

final RegExp _groupUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

List<GroupMember> _sortedMembers(Iterable<GroupMember> values) =>
    values.toList(growable: false)
      ..sort((left, right) => left.userId.compareTo(right.userId));

bool _isHex(String value, int byteLength) =>
    value.length == byteLength * 2 && RegExp(r'^[0-9a-f]+$').hasMatch(value);
