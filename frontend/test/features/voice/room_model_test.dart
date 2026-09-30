import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/room_fakes.dart';

final _roomId = 'ab' * 32;
const _machine = RoomControlStateMachine();

void main() {
  group('room authorization', () {
    test('every active member may add, remove and rename', () {
      final room = _room([roomAlice, roomBob, roomCarol]);

      for (final actor in [roomAlice, roomBob, roomCarol]) {
        expect(
          RoomAuthorization.canAdd(
            room,
            actorUserId: actor,
            targetUserIds: [roomDave],
          ),
          isTrue,
        );
        expect(
          RoomAuthorization.canRename(room, actorUserId: actor, name: 'Desk'),
          isTrue,
        );
        for (final target in [roomAlice, roomBob, roomCarol]) {
          expect(
            RoomAuthorization.canRemove(
              room,
              actorUserId: actor,
              targetUserId: target,
            ),
            isTrue,
            reason: 'no member outranks another, and leaving is a removal',
          );
        }
      }
      expect(
        RoomAuthorization.canAdd(
          room,
          actorUserId: roomDave,
          targetUserIds: [roomDave],
        ),
        isFalse,
      );
      expect(
        RoomAuthorization.canRemove(
          room,
          actorUserId: roomAlice,
          targetUserId: roomDave,
        ),
        isFalse,
        reason: 'only an active member can be removed',
      );
      expect(
        RoomAuthorization.canRename(room, actorUserId: roomAlice, name: '  '),
        isFalse,
      );
      expect(
        RoomAuthorization.canRename(
          room,
          actorUserId: roomAlice,
          name: 'x' * 101,
        ),
        isFalse,
      );
    });

    test('a room waiting on its state or quarantined admits no change', () {
      for (final lifecycle in [
        RoomLifecycle.stateRecoveryRequired,
        RoomLifecycle.forkQuarantined,
      ]) {
        final room = _room(
          [roomAlice, roomBob],
          lifecycle: lifecycle,
          quarantineReason: lifecycle == RoomLifecycle.forkQuarantined
              ? RoomQuarantineReason.siblingControl
              : null,
        );
        expect(RoomAuthorization.mayAct(room, roomAlice), isFalse);
        expect(
          RoomAuthorization.canRename(room, actorUserId: roomAlice, name: 'A'),
          isFalse,
        );
        // The signer of somebody else's event is still judged on the roster.
        expect(
          RoomAuthorization.canRename(
            room,
            actorUserId: roomAlice,
            name: 'A',
            forControl: true,
          ),
          isTrue,
        );
      }
      expect(
        RoomAuthorization.mayAct(_room([roomAlice, roomBob]), roomAlice),
        isTrue,
      );
    });

    test('the ceiling counts active members only', () {
      final members = [
        for (var index = 1; index <= 50; index += 1) _user(index),
      ];
      final full = _room(members);
      expect(
        RoomAuthorization.canAdd(
          full,
          actorUserId: members.first,
          targetUserIds: [_user(51)],
        ),
        isFalse,
      );

      final withDeparture = RoomState(
        roomId: _roomId,
        name: 'Standup',
        members: [
          for (final userId in members)
            RoomMember(
              userId: userId,
              membership: userId == members.last
                  ? RoomMembershipState.left
                  : RoomMembershipState.active,
            ),
        ],
        controlRevision: 2,
        controlStateHash: 'cd' * 32,
      );
      expect(
        RoomAuthorization.canAdd(
          withDeparture,
          actorUserId: members.first,
          targetUserIds: [_user(51)],
        ),
        isTrue,
      );
    });
  });

  group('room control state machine', () {
    test('a create names its creator and at least one other member', () async {
      Future<RoomControlApplyResult> create(List<String> members) async =>
          _machine.apply(
            previous: null,
            signedControl: await signRoomEvent(
              signerUserId: roomAlice,
              signerDeviceId: roomAlicePhone,
              roomId: _roomId,
              revision: 1,
              previous: null,
              operation: CreateRoomOperation(
                name: ' Standup ',
                memberUserIds: members,
              ),
              eventMarker: 1,
            ),
            localUserId: roomBob,
          );

      final accepted = await create([roomAlice, roomBob]);
      final state = (accepted as RoomControlAccepted).state;
      expect(state.name, 'Standup');
      expect(state.activeMembers.map((member) => member.userId), [
        roomAlice,
        roomBob,
      ]);
      expect(state.lifecycle, RoomLifecycle.active);

      expect(
        await create([roomBob, roomCarol]),
        isA<RoomControlQuarantined>().having(
          (result) => result.reason,
          'reason',
          RoomQuarantineReason.unauthorizedControl,
        ),
      );
      expect(
        await create([roomAlice]),
        isA<RoomControlQuarantined>().having(
          (result) => result.reason,
          'reason',
          RoomQuarantineReason.invalidMembership,
        ),
      );
      expect(
        await create([roomAlice, roomBob, roomBob]),
        isA<RoomControlQuarantined>(),
      );
    });

    test('events apply in revision order, and nothing else does', () async {
      final chain = await _chain();
      final created = _applyAll(chain.take(1), roomBob);
      final renamed = _applyAll(chain.take(2), roomBob);

      expect(
        _machine.apply(
          previous: renamed,
          signedControl: chain[1],
          localUserId: roomBob,
        ),
        isA<RoomControlDuplicate>(),
      );
      expect(
        _machine.apply(
          previous: renamed,
          signedControl: chain[0],
          localUserId: roomBob,
        ),
        isA<RoomControlStale>(),
      );
      expect(
        _machine.apply(
          previous: created,
          signedControl: chain[2],
          localUserId: roomBob,
        ),
        isA<RoomControlAhead>(),
        reason: 'a gap is asked about, never skipped',
      );
      expect(
        _machine.apply(
          previous: null,
          signedControl: chain[2],
          localUserId: roomBob,
        ),
        isA<RoomControlAhead>(),
      );

      // Two valid events at one revision are a fork, and neither is chosen.
      final sibling = await signRoomEvent(
        signerUserId: roomCarol,
        signerDeviceId: roomCarolPhone,
        roomId: _roomId,
        revision: 2,
        previous: chain[0],
        operation: const RenameRoomOperation('Other name'),
        eventMarker: 99,
      );
      expect(
        _machine.apply(
          previous: renamed,
          signedControl: sibling,
          localUserId: roomBob,
        ),
        isA<RoomControlQuarantined>().having(
          (result) => result.reason,
          'reason',
          RoomQuarantineReason.siblingControl,
        ),
      );
    });

    test('two devices that apply the same events hold the same room', () async {
      final chain = await _chain();

      // Bob was in the room from its first event. Dave's device replays the
      // room from its first event as the transcript an add hands it. Alice's
      // tablet takes the same events one at a time, the third after a gap.
      final bob = _applyAll(chain, roomBob);
      final dave = _applyAll(chain, roomDave);
      var tablet = _applyAll(chain.take(2), roomAlice);
      expect(
        _machine.apply(
          previous: tablet,
          signedControl: chain[3],
          localUserId: roomAlice,
        ),
        isA<RoomControlAhead>(),
      );
      tablet = _applyAll(chain.skip(2), roomAlice, from: tablet);

      for (final other in [dave, tablet]) {
        expect(other.roomId, bob.roomId);
        expect(other.name, bob.name);
        expect(other.members, bob.members);
        expect(other.controlRevision, bob.controlRevision);
        expect(other.controlStateHash, bob.controlStateHash);
        expect(other.lifecycle, RoomLifecycle.active);
      }
      expect(bob.name, 'Weekly');
      expect(bob.controlRevision, 5);
      expect(bob.activeMembers.map((member) => member.userId), [
        roomAlice,
        roomBob,
        roomDave,
      ]);
      expect(bob.member(roomCarol)!.membership, RoomMembershipState.removed);

      // Carol's own device holds the same roster, and knows who removed it.
      final carol = _applyAll(chain, roomCarol);
      expect(carol.members, bob.members);
      expect(carol.controlStateHash, bob.controlStateHash);
      expect(carol.lifecycle, RoomLifecycle.removed);
      expect(carol.removedByUserId, roomAlice);
    });

    test(
      'a removal takes the member out and refuses what they sign after',
      () async {
        final chain = await _chain();
        final afterRemoval = _applyAll(chain.take(4), roomBob);
        expect(afterRemoval.isActiveMember(roomCarol), isFalse);

        for (final operation in <RoomControlOperation>[
          const RenameRoomOperation('Taken over'),
          AddRoomMembersOperation([roomCarol]),
          RemoveRoomMemberOperation(roomBob),
          RemoveRoomMemberOperation(roomCarol),
        ]) {
          final late = await signRoomEvent(
            signerUserId: roomCarol,
            signerDeviceId: roomCarolPhone,
            roomId: _roomId,
            revision: 5,
            previous: chain[3],
            operation: operation,
            eventMarker: 50,
          );
          final result = _machine.apply(
            previous: afterRemoval,
            signedControl: late,
            localUserId: roomBob,
          );
          expect(
            result,
            isA<RoomControlQuarantined>()
                .having(
                  (value) => value.reason,
                  'reason',
                  RoomQuarantineReason.unauthorizedControl,
                )
                .having((value) => value.state, 'state', same(afterRemoval)),
            reason: 'the room is left exactly as it was',
          );
        }
      },
    );

    test('a member who left or was removed may be added again', () async {
      final chain = await _chain();
      final removed = _applyAll(chain.take(4), roomCarol);
      final readd = await signRoomEvent(
        signerUserId: roomBob,
        signerDeviceId: roomBobPhone,
        roomId: _roomId,
        revision: 5,
        previous: chain[3],
        operation: AddRoomMembersOperation([roomCarol]),
        eventMarker: 60,
      );

      final back =
          (_machine.apply(
                    previous: removed,
                    signedControl: readd,
                    localUserId: roomCarol,
                  )
                  as RoomControlAccepted)
              .state;

      expect(back.isActiveMember(roomCarol), isTrue);
      expect(back.lifecycle, RoomLifecycle.active);
      expect(back.removedByUserId, isNull);

      final leave = await signRoomEvent(
        signerUserId: roomCarol,
        signerDeviceId: roomCarolPhone,
        roomId: _roomId,
        revision: 6,
        previous: readd,
        operation: RemoveRoomMemberOperation(roomCarol),
        eventMarker: 61,
      );
      final left =
          (_machine.apply(
                    previous: back,
                    signedControl: leave,
                    localUserId: roomCarol,
                  )
                  as RoomControlAccepted)
              .state;
      expect(left.member(roomCarol)!.membership, RoomMembershipState.left);
      expect(left.lifecycle, RoomLifecycle.left);
    });
  });
}

/// Create by Alice with Bob and Carol, a rename by Bob, an add of Dave by
/// Carol, Alice removing Carol, and a rename by Dave.
Future<List<SignedRoomControlEvent>> _chain() async {
  final create = await signRoomEvent(
    signerUserId: roomAlice,
    signerDeviceId: roomAlicePhone,
    roomId: _roomId,
    revision: 1,
    previous: null,
    operation: CreateRoomOperation(
      name: 'Standup',
      memberUserIds: [roomAlice, roomBob, roomCarol],
    ),
    eventMarker: 1,
  );
  final rename = await signRoomEvent(
    signerUserId: roomBob,
    signerDeviceId: roomBobPhone,
    roomId: _roomId,
    revision: 2,
    previous: create,
    operation: const RenameRoomOperation('Daily'),
    eventMarker: 2,
  );
  final add = await signRoomEvent(
    signerUserId: roomCarol,
    signerDeviceId: roomCarolPhone,
    roomId: _roomId,
    revision: 3,
    previous: rename,
    operation: AddRoomMembersOperation([roomDave]),
    eventMarker: 3,
  );
  final remove = await signRoomEvent(
    signerUserId: roomAlice,
    signerDeviceId: roomAlicePhone,
    roomId: _roomId,
    revision: 4,
    previous: add,
    operation: RemoveRoomMemberOperation(roomCarol),
    eventMarker: 4,
  );
  final renameAgain = await signRoomEvent(
    signerUserId: roomDave,
    signerDeviceId: roomDavePhone,
    roomId: _roomId,
    revision: 5,
    previous: remove,
    operation: const RenameRoomOperation('Weekly'),
    eventMarker: 5,
  );
  return [create, rename, add, remove, renameAgain];
}

RoomState _applyAll(
  Iterable<SignedRoomControlEvent> events,
  String localUserId, {
  RoomState? from,
}) {
  var state = from;
  for (final event in events) {
    final result = _machine.apply(
      previous: state,
      signedControl: event,
      localUserId: localUserId,
    );
    state = (result as RoomControlAccepted).state;
  }
  return state!;
}

RoomState _room(
  List<String> members, {
  RoomLifecycle lifecycle = RoomLifecycle.active,
  RoomQuarantineReason? quarantineReason,
}) => RoomState(
  roomId: _roomId,
  name: 'Standup',
  members: [for (final userId in members) RoomMember(userId: userId)],
  controlRevision: 1,
  controlStateHash: 'cd' * 32,
  lifecycle: lifecycle,
  quarantineReason: quarantineReason,
);

String _user(int index) =>
    '50000000-0000-4000-8000-${index.toRadixString(16).padLeft(12, '0')}';
