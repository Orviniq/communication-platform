import 'dart:typed_data';

import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _groupId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _owner = '00000000-0000-0000-0000-000000000001';
const _admin = '00000000-0000-0000-0000-000000000002';
const _member = '00000000-0000-0000-0000-000000000003';
const _newMember = '00000000-0000-0000-0000-000000000004';
const _device = '10000000-0000-0000-0000-000000000001';
const _machine = GroupControlStateMachine();

void main() {
  group('group authorization', () {
    test('owner, admin, and member permissions obey policy and hierarchy', () {
      for (final policy in GroupInvitationPolicy.values) {
        final state = _state(invitationPolicy: policy);
        expect(
          GroupAuthorization.allows(
            state,
            _owner,
            GroupPermission.transferOwnership,
          ),
          isTrue,
        );
        expect(
          GroupAuthorization.allows(
            state,
            _admin,
            GroupPermission.editMetadata,
          ),
          isTrue,
        );
        expect(
          GroupAuthorization.allows(state, _admin, GroupPermission.changeRoles),
          isFalse,
        );
        expect(
          GroupAuthorization.canRemove(
            state,
            actorUserId: _admin,
            targetUserId: _member,
          ),
          isTrue,
        );
        expect(
          GroupAuthorization.canRemove(
            state,
            actorUserId: _admin,
            targetUserId: _owner,
          ),
          isFalse,
        );
        expect(
          GroupAuthorization.allows(
            state,
            _member,
            GroupPermission.inviteMembers,
          ),
          policy == GroupInvitationPolicy.allMembers,
        );
      }
    });

    test('removed and recovering states expose history but no mutations', () {
      final removed = _state(
        members: [
          for (final item in _members())
            item.userId == _member
                ? item.copyWith(membership: GroupMembershipState.removed)
                : item,
        ],
      );
      expect(GroupAuthorization.permissionsFor(removed, _member), {
        GroupPermission.viewHistory,
      });

      final recovering = _state(
        lifecycle: GroupLifecycle.stateRecoveryRequired,
      );
      for (final actor in [_owner, _admin, _member]) {
        expect(GroupAuthorization.permissionsFor(recovering, actor), {
          GroupPermission.viewHistory,
        });
      }
      expect(
        GroupAuthorization.permissionsFor(
          _state(),
          '00000000-0000-0000-0000-000000000099',
        ),
        isEmpty,
      );
    });

    test('an owner must hand the group over before leaving it', () {
      final state = _state();
      expect(GroupAuthorization.canLeave(state, _owner), isFalse);
      expect(GroupAuthorization.canLeave(state, _member), isTrue);
    });
  });

  group('control state machine', () {
    test('a create establishes the roster and this device\'s place in it', () {
      final create = _signed(
        revision: 1,
        previousHash: null,
        actor: _owner,
        operation: CreateGroupOperation(
          metadata: const GroupMetadata(name: ' Team '),
          invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
          historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
          members: _members().reversed,
        ),
        controlHash: _repeat('10', 32),
      );

      final asMember = _machine.apply(
        previous: null,
        signedControl: create,
        localUserId: _member,
      );
      final state = (asMember as GroupControlAccepted).state;
      expect(state.lifecycle, GroupLifecycle.active);
      expect(state.metadata.name, 'Team');
      expect(state.members.map((item) => item.userId), [
        _owner,
        _admin,
        _member,
      ]);

      // A member added later replays the group from this event, before the
      // event that adds it.
      final asOutsider = _machine.apply(
        previous: null,
        signedControl: create,
        localUserId: _newMember,
      );
      expect(
        (asOutsider as GroupControlAccepted).state.lifecycle,
        GroupLifecycle.removed,
      );
    });

    test('a create signed by anyone but its single owner is refused', () {
      final forged = _signed(
        revision: 1,
        previousHash: null,
        actor: _admin,
        operation: CreateGroupOperation(
          metadata: const GroupMetadata(name: 'Team'),
          invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
          historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
          members: _members(),
        ),
        controlHash: _repeat('11', 32),
      );

      final result = _machine.apply(
        previous: null,
        signedControl: forged,
        localUserId: _admin,
      );
      expect(
        (result as GroupControlQuarantined).reason,
        GroupQuarantineReason.unauthorizedControl,
      );
      expect(result.state, isNull);
    });

    test('an event its signer may not make leaves the state untouched', () {
      final state = _state();
      final forged = _signed(
        revision: 2,
        previousHash: state.controlStateHash,
        actor: _member,
        operation: const RenameGroupOperation(GroupMetadata(name: 'Forged')),
        controlHash: _repeat('31', 32),
      );

      final result = _machine.apply(
        previous: state,
        signedControl: forged,
        localUserId: _member,
      );
      expect(
        (result as GroupControlQuarantined).reason,
        GroupQuarantineReason.unauthorizedControl,
      );
      expect(result.state, same(state));
    });

    test('an event is placed by its revision and its predecessor hash', () {
      final state = _state();
      final next = _rename(2, state.controlStateHash, '21');

      final accepted =
          (_machine.apply(
                    previous: state,
                    signedControl: next,
                    localUserId: _owner,
                  )
                  as GroupControlAccepted)
              .state;
      expect(accepted.controlRevision, 2);
      expect(accepted.controlStateHash, _repeat('21', 32));
      expect(accepted.metadata.name, 'Renamed');

      expect(
        _machine.apply(
          previous: state,
          signedControl: _rename(3, _repeat('ff', 32), '22'),
          localUserId: _owner,
        ),
        isA<GroupControlAhead>(),
      );
      expect(
        (_machine.apply(
                  previous: state,
                  signedControl: _rename(2, _repeat('ff', 32), '23'),
                  localUserId: _owner,
                )
                as GroupControlQuarantined)
            .reason,
        GroupQuarantineReason.siblingControl,
      );
      expect(
        _machine.apply(
          previous: accepted,
          signedControl: next,
          localUserId: _owner,
        ),
        isA<GroupControlDuplicate>(),
      );
      expect(
        (_machine.apply(
                  previous: accepted,
                  signedControl: _rename(2, state.controlStateHash, '24'),
                  localUserId: _owner,
                )
                as GroupControlQuarantined)
            .reason,
        GroupQuarantineReason.siblingControl,
      );
      final third =
          (_machine.apply(
                    previous: accepted,
                    signedControl: _rename(3, accepted.controlStateHash, '25'),
                    localUserId: _owner,
                  )
                  as GroupControlAccepted)
              .state;
      expect(
        _machine.apply(
          previous: third,
          signedControl: next,
          localUserId: _owner,
        ),
        isA<GroupControlStale>(),
      );
    });

    test('handing the group over keeps exactly one owner', () {
      for (final target in [_admin, _member]) {
        final state = _state();
        final transfer = _signed(
          revision: 2,
          previousHash: state.controlStateHash,
          actor: _owner,
          operation: ChangeGroupRoleOperation(
            targetUserId: target,
            role: GroupRole.owner,
          ),
          controlHash: target == _admin ? _repeat('51', 32) : _repeat('52', 32),
        );

        final next =
            (_machine.apply(
                      previous: state,
                      signedControl: transfer,
                      localUserId: _owner,
                    )
                    as GroupControlAccepted)
                .state;
        expect(
          next.activeMembers.where((item) => item.role == GroupRole.owner),
          hasLength(1),
        );
        expect(next.member(target)!.role, GroupRole.owner);
        expect(next.member(_owner)!.role, GroupRole.admin);
      }
    });

    test('leaving is a member removing itself', () {
      final state = _state();
      final leave = _signed(
        revision: 2,
        previousHash: state.controlStateHash,
        actor: _member,
        operation: RemoveGroupMemberOperation(_member),
        controlHash: _repeat('61', 32),
      );

      final left =
          (_machine.apply(
                    previous: state,
                    signedControl: leave,
                    localUserId: _member,
                  )
                  as GroupControlAccepted)
              .state;
      expect(left.member(_member)!.membership, GroupMembershipState.left);
      expect(left.lifecycle, GroupLifecycle.left);

      final ownerLeave = _signed(
        revision: 2,
        previousHash: state.controlStateHash,
        actor: _owner,
        operation: RemoveGroupMemberOperation(_owner),
        controlHash: _repeat('62', 32),
      );
      expect(
        (_machine.apply(
                  previous: state,
                  signedControl: ownerLeave,
                  localUserId: _owner,
                )
                as GroupControlQuarantined)
            .reason,
        GroupQuarantineReason.unauthorizedControl,
      );
    });

    test('a removed member can be added back and is active again', () {
      final state = _state();
      final removal = _signed(
        revision: 2,
        previousHash: state.controlStateHash,
        actor: _owner,
        operation: RemoveGroupMemberOperation(_member),
        controlHash: _repeat('71', 32),
      );
      final removed =
          (_machine.apply(
                    previous: state,
                    signedControl: removal,
                    localUserId: _member,
                  )
                  as GroupControlAccepted)
              .state;
      expect(removed.lifecycle, GroupLifecycle.removed);
      expect(removed.member(_member)!.membership, GroupMembershipState.removed);

      final readd = _signed(
        revision: 3,
        previousHash: removed.controlStateHash,
        actor: _admin,
        operation: AddGroupMembersOperation([
          GroupMember(userId: _member, displayName: '', role: GroupRole.member),
        ]),
        controlHash: _repeat('72', 32),
      );
      final back =
          (_machine.apply(
                    previous: removed,
                    signedControl: readd,
                    localUserId: _member,
                  )
                  as GroupControlAccepted)
              .state;
      expect(back.lifecycle, GroupLifecycle.active);
      expect(back.member(_member)!.isActive, isTrue);
      // The name this device knows the member by is its own, and survives.
      expect(back.member(_member)!.displayName, 'Member');
    });

    test('an add refuses live members, privileged roles and the cap', () {
      final state = _state();
      SignedGroupControlEvent add(List<GroupMember> members, String hash) =>
          _signed(
            revision: 2,
            previousHash: state.controlStateHash,
            actor: _owner,
            operation: AddGroupMembersOperation(members),
            controlHash: _repeat(hash, 32),
          );

      final refused = [
        add([
          GroupMember(userId: _member, displayName: '', role: GroupRole.member),
        ], '81'),
        add([
          GroupMember(
            userId: _newMember,
            displayName: '',
            role: GroupRole.admin,
          ),
        ], '82'),
        add([
          for (var index = 0; index < 48; index += 1)
            GroupMember(
              userId:
                  '00000000-0000-0000-0000-'
                  '${(0x100 + index).toRadixString(16).padLeft(12, '0')}',
              displayName: '',
              role: GroupRole.member,
            ),
        ], '83'),
      ];
      for (final control in refused) {
        expect(
          (_machine.apply(
                    previous: state,
                    signedControl: control,
                    localUserId: _owner,
                  )
                  as GroupControlQuarantined)
              .reason,
          GroupQuarantineReason.unauthorizedControl,
        );
      }
    });

    test('an admin removes members but never another admin', () {
      final state = _state(
        members: [
          ..._members(),
          GroupMember(
            userId: _newMember,
            displayName: 'Second admin',
            role: GroupRole.admin,
          ),
        ],
      );
      final byAdmin = _signed(
        revision: 2,
        previousHash: state.controlStateHash,
        actor: _admin,
        operation: RemoveGroupMemberOperation(_newMember),
        controlHash: _repeat('91', 32),
      );
      expect(
        _machine.apply(
          previous: state,
          signedControl: byAdmin,
          localUserId: _owner,
        ),
        isA<GroupControlQuarantined>(),
      );
      final byOwner = _signed(
        revision: 2,
        previousHash: state.controlStateHash,
        actor: _owner,
        operation: RemoveGroupMemberOperation(_newMember),
        controlHash: _repeat('92', 32),
      );
      expect(
        _machine.apply(
          previous: state,
          signedControl: byOwner,
          localUserId: _owner,
        ),
        isA<GroupControlAccepted>(),
      );
    });
  });
}

GroupState _state({
  GroupInvitationPolicy invitationPolicy = GroupInvitationPolicy.ownerAndAdmins,
  GroupLifecycle lifecycle = GroupLifecycle.active,
  List<GroupMember>? members,
}) => GroupState(
  groupId: _groupId,
  metadata: const GroupMetadata(name: 'Team'),
  invitationPolicy: invitationPolicy,
  historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
  members: members ?? _members(),
  controlRevision: 1,
  controlStateHash: _repeat('10', 32),
  lifecycle: lifecycle,
);

List<GroupMember> _members() => [
  GroupMember(userId: _owner, displayName: 'Owner', role: GroupRole.owner),
  GroupMember(userId: _admin, displayName: 'Admin', role: GroupRole.admin),
  GroupMember(userId: _member, displayName: 'Member', role: GroupRole.member),
];

SignedGroupControlEvent _rename(int revision, String previous, String hash) =>
    _signed(
      revision: revision,
      previousHash: previous,
      actor: _owner,
      operation: const RenameGroupOperation(GroupMetadata(name: 'Renamed')),
      controlHash: _repeat(hash, 32),
    );

SignedGroupControlEvent _signed({
  required int revision,
  required String? previousHash,
  required String actor,
  required GroupControlOperation operation,
  required String controlHash,
}) => SignedGroupControlEvent(
  event: GroupControlEvent(
    eventId: controlHash.substring(0, 32),
    groupId: _groupId,
    revision: revision,
    previousControlStateHash: previousHash,
    signerUserId: actor,
    signerDeviceId: _device,
    createdMs: 200 + revision,
    operation: operation,
  ),
  controlStateHash: controlHash,
  canonicalBytes: Uint8List.fromList([revision]),
  signature: Uint8List(SignedGroupControlEvent.signatureBytes),
);

String _repeat(String pair, int count) => List.filled(count, pair).join();
