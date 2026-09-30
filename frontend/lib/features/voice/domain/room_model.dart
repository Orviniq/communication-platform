import 'dart:typed_data';

import 'package:communication_platform/core/protocol/room_sync_model.dart';

/// Where one account stands in a room's roster.
enum RoomMembershipState { active, removed, left }

/// Where this device stands in a room.
///
/// [stateRecoveryRequired] is never stored. It is laid over the stored value
/// while a lost envelope may have carried a control event this device has not
/// seen, or while an event built on state it does not hold, until a member
/// answers with the room's current control state.
enum RoomLifecycle {
  active,
  removed,
  left,
  stateRecoveryRequired,
  forkQuarantined,
  controlQuarantined,
}

enum RoomQuarantineReason {
  siblingControl,
  brokenControlChain,
  unauthorizedControl,
  invalidMembership,
}

/// A room's name: at most 100 Unicode scalar values, the bound a group name
/// has. A room has no description, because it has no timeline to describe.
abstract final class RoomNames {
  static const maximumScalars = 100;

  static bool isValid(String name) {
    final normalized = name.trim();
    return normalized.isNotEmpty && normalized.runes.length <= maximumScalars;
  }

  static String normalized(String name) => name.trim();
}

/// One account in a room, as this device holds it.
///
/// Both fields are the roster every member agrees on, because each is derived
/// from signed control events. A room keeps no display name and no
/// verification state of its own: a screen reads those from contacts.
final class RoomMember {
  RoomMember({
    required String userId,
    this.membership = RoomMembershipState.active,
  }) : userId = userId.toLowerCase() {
    if (!_uuid.hasMatch(this.userId)) {
      throw const FormatException('invalid room member');
    }
  }

  final String userId;
  final RoomMembershipState membership;

  bool get isActive => membership == RoomMembershipState.active;

  RoomMember copyWith({RoomMembershipState? membership}) =>
      RoomMember(userId: userId, membership: membership ?? this.membership);

  @override
  bool operator ==(Object other) =>
      other is RoomMember &&
      other.userId == userId &&
      other.membership == membership;

  @override
  int get hashCode => Object.hash(userId, membership);
}

/// Minimal room-owned projection of one account-authenticated live device.
///
/// [signingPublic] is the Ed25519 half of the device's `ik_pub`, taken from the
/// device list the contacts feature verified against the account identity and
/// the signed device log. It is the only key a room control event from this
/// device is checked against.
final class RoomAuthenticatedLiveDevice {
  RoomAuthenticatedLiveDevice({
    required String userId,
    required String deviceId,
    required Uint8List signingPublic,
  }) : userId = userId.toLowerCase(),
       deviceId = deviceId.toLowerCase(),
       signingPublic = Uint8List.fromList(signingPublic) {
    if (!_uuid.hasMatch(this.userId) ||
        !_uuid.hasMatch(this.deviceId) ||
        this.signingPublic.length != 32) {
      throw const FormatException('invalid authenticated live device');
    }
  }

  final String userId;
  final String deviceId;
  final Uint8List signingPublic;
}

/// One room this device holds: who is in it, what it is called, and the state
/// hash its accepted control events chain to.
///
/// [members] keeps every account the room has held, so that a departure stays
/// readable. [removedByUserId] names the member whose event removed this
/// device's own account, while it stays removed, so that the user can see who
/// signed it.
final class RoomState {
  RoomState({
    required this.roomId,
    required this.name,
    required Iterable<RoomMember> members,
    required this.controlRevision,
    required this.controlStateHash,
    this.lifecycle = RoomLifecycle.active,
    this.quarantineReason,
    String? removedByUserId,
  }) : members = List.unmodifiable(_sortedMembers(members)),
       removedByUserId = removedByUserId?.toLowerCase() {
    if (!_isHex(roomId, roomIdBytes) ||
        controlRevision < 1 ||
        controlRevision > RoomControlEvent.maximumRevision ||
        !_isHex(controlStateHash, stateHashBytes) ||
        !RoomNames.isValid(name) ||
        this.members.length > maximumRecordedMembers ||
        this.members.where((member) => member.isActive).length >
            maximumMembers ||
        this.members.map((member) => member.userId).toSet().length !=
            this.members.length ||
        (this.removedByUserId != null &&
            !_uuid.hasMatch(this.removedByUserId!))) {
      throw const FormatException('invalid room state');
    }
    if ((lifecycle == RoomLifecycle.forkQuarantined ||
            lifecycle == RoomLifecycle.controlQuarantined) !=
        (quarantineReason != null)) {
      throw const FormatException('quarantine state and reason mismatch');
    }
  }

  /// Active members, the creator included.
  static const maximumMembers = 50;
  static const minimumCreateMembers = 2;

  /// Every account a room can have held. A transcript that named more than
  /// this could not be handed to a new member in one payload anyway.
  static const maximumRecordedMembers = 2000;
  static const roomIdBytes = 32;
  static const stateHashBytes = 32;

  final String roomId;
  final String name;
  final List<RoomMember> members;
  final int controlRevision;
  final String controlStateHash;
  final RoomLifecycle lifecycle;
  final RoomQuarantineReason? quarantineReason;
  final String? removedByUserId;

  Iterable<RoomMember> get activeMembers =>
      members.where((member) => member.isActive);

  RoomMember? member(String userId) {
    final normalized = userId.toLowerCase();
    for (final member in members) {
      if (member.userId == normalized) return member;
    }
    return null;
  }

  bool isActiveMember(String userId) => member(userId)?.isActive == true;

  RoomState copyWith({
    RoomLifecycle? lifecycle,
    RoomQuarantineReason? quarantineReason,
    bool clearQuarantineReason = false,
  }) => RoomState(
    roomId: roomId,
    name: name,
    members: members,
    controlRevision: controlRevision,
    controlStateHash: controlStateHash,
    lifecycle: lifecycle ?? this.lifecycle,
    quarantineReason: clearQuarantineReason
        ? null
        : quarantineReason ?? this.quarantineReason,
    removedByUserId: removedByUserId,
  );
}

/// Who may change a room. Every active member has the same authority (ADR-077
/// D1): there is no owner, no admin and no role, so any active member may add,
/// remove and rename, and a member naming itself is leaving.
abstract final class RoomAuthorization {
  /// Whether this device, signed in as [localUserId], may sign a change to the
  /// room or join a call in it.
  ///
  /// Only an active room qualifies. One waiting on its state may be missing a
  /// removal, and a quarantined one has a fork nobody may choose a branch of,
  /// so neither invites, renames, removes nor joins a call.
  static bool mayAct(RoomState state, String localUserId) =>
      state.lifecycle == RoomLifecycle.active &&
      state.isActiveMember(localUserId);

  /// [forControl] evaluates a signed control's signer against the roster the
  /// control was built on. This device's own lifecycle is deliberately
  /// irrelevant then: a removed device still decides correctly whether
  /// somebody else's event was authorized.
  static bool canAdd(
    RoomState state, {
    required String actorUserId,
    required Iterable<String> targetUserIds,
    bool forControl = false,
  }) {
    final targets = targetUserIds
        .map((value) => value.toLowerCase())
        .toList(growable: false);
    if (targets.isEmpty ||
        targets.toSet().length != targets.length ||
        !_actorMay(state, actorUserId, forControl: forControl) ||
        state.activeMembers.length + targets.length >
            RoomState.maximumMembers) {
      return false;
    }
    return targets.every((target) => !state.isActiveMember(target));
  }

  /// A member removing itself is leaving, which any active member may do.
  static bool canRemove(
    RoomState state, {
    required String actorUserId,
    required String targetUserId,
    bool forControl = false,
  }) =>
      _actorMay(state, actorUserId, forControl: forControl) &&
      state.isActiveMember(targetUserId);

  static bool canRename(
    RoomState state, {
    required String actorUserId,
    required String name,
    bool forControl = false,
  }) =>
      RoomNames.isValid(name) &&
      _actorMay(state, actorUserId, forControl: forControl);

  static bool _actorMay(
    RoomState state,
    String actorUserId, {
    required bool forControl,
  }) => forControl
      ? state.isActiveMember(actorUserId)
      : mayAct(state, actorUserId);
}

/// The four control operations, by the value each carries on the wire.
enum RoomControlKind {
  create(1),
  addMembers(2),
  removeMember(3),
  rename(4);

  const RoomControlKind(this.wireValue);

  /// Held back so that a later role operation cannot reuse a value. No event
  /// of this version carries it, and the native core refuses one that does.
  static const reservedWireValue = 5;

  final int wireValue;

  static RoomControlKind? fromWireValue(int value) {
    for (final kind in values) {
      if (kind.wireValue == value) return kind;
    }
    return null;
  }
}

sealed class RoomControlOperation {
  const RoomControlOperation();

  RoomControlKind get kind;
}

/// Starts a room: its name, and every member, the creator among them.
final class CreateRoomOperation extends RoomControlOperation {
  CreateRoomOperation({
    required this.name,
    required Iterable<String> memberUserIds,
  }) : memberUserIds = _sortedUserIds(memberUserIds);

  final String name;
  final List<String> memberUserIds;

  @override
  RoomControlKind get kind => RoomControlKind.create;
}

/// Adds accounts as members. A member who was removed or left may be added
/// again.
final class AddRoomMembersOperation extends RoomControlOperation {
  AddRoomMembersOperation(Iterable<String> userIds)
    : userIds = _sortedUserIds(userIds);

  final List<String> userIds;

  @override
  RoomControlKind get kind => RoomControlKind.addMembers;
}

/// Removes a member. A member removing itself is leaving.
final class RemoveRoomMemberOperation extends RoomControlOperation {
  RemoveRoomMemberOperation(String targetUserId)
    : targetUserId = _userId(targetUserId);

  final String targetUserId;

  @override
  RoomControlKind get kind => RoomControlKind.removeMember;
}

final class RenameRoomOperation extends RoomControlOperation {
  const RenameRoomOperation(this.name);

  final String name;

  @override
  RoomControlKind get kind => RoomControlKind.rename;
}

/// One room control event (`voice-signalling-v1.md`, The event).
///
/// It mirrors `GroupControlEvent` field for field. Its wire form is
/// deterministic CBOR built by the shared native core, which also signs it with
/// the device identity. This is the typed view of the same event; nothing here
/// is an encoder, and nothing here is signed.
final class RoomControlEvent {
  RoomControlEvent({
    this.protocolVersion = 1,
    required this.eventId,
    required this.roomId,
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
        !_isHex(roomId, RoomState.roomIdBytes) ||
        revision < 1 ||
        revision > maximumRevision ||
        (revision == 1) != (previousControlStateHash == null) ||
        (revision == 1) != (operation is CreateRoomOperation) ||
        (previousControlStateHash != null &&
            !_isHex(previousControlStateHash!, RoomState.stateHashBytes)) ||
        !_uuid.hasMatch(this.signerUserId) ||
        !_uuid.hasMatch(this.signerDeviceId) ||
        createdMs < 0) {
      throw const FormatException('invalid room control event');
    }
  }

  static const eventIdBytes = 16;
  static const maximumRevision = 0xffffffff;

  final int protocolVersion;
  final String eventId;
  final String roomId;
  final int revision;
  final String? previousControlStateHash;
  final String signerUserId;
  final String signerDeviceId;

  /// The signer's wall clock, for display only.
  final int createdMs;
  final RoomControlOperation operation;
}

/// A control event together with the exact bytes its signer signed.
final class SignedRoomControlEvent {
  SignedRoomControlEvent({
    required this.event,
    required this.controlStateHash,
    required Uint8List canonicalBytes,
    required Uint8List signature,
  }) : canonicalBytes = Uint8List.fromList(canonicalBytes),
       signature = Uint8List.fromList(signature) {
    if (!_isHex(controlStateHash, RoomState.stateHashBytes) ||
        this.canonicalBytes.isEmpty ||
        this.canonicalBytes.length > maximumCanonicalBytes ||
        this.signature.length != signatureBytes) {
      throw const FormatException('invalid signed room control');
    }
  }

  static const maximumCanonicalBytes = 16384;
  static const signatureBytes = 64;

  final RoomControlEvent event;

  /// The hash this event commits the room to. The next event names it.
  final String controlStateHash;
  final Uint8List canonicalBytes;
  final Uint8List signature;

  StoredRoomControl get stored => StoredRoomControl(
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

/// One accepted transcript entry as storage holds it: enough to hand the signed
/// bytes to another device and to check the chain, and nothing that would need
/// the native core to read back.
final class StoredRoomControl {
  StoredRoomControl({
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
    if (!_isHex(eventId, RoomControlEvent.eventIdBytes) ||
        revision < 1 ||
        (revision == 1) != (previousControlStateHash == null) ||
        (previousControlStateHash != null &&
            !_isHex(previousControlStateHash!, RoomState.stateHashBytes)) ||
        !_isHex(controlStateHash, RoomState.stateHashBytes) ||
        !_uuid.hasMatch(this.signerUserId) ||
        !_uuid.hasMatch(this.signerDeviceId) ||
        this.canonicalBytes.isEmpty ||
        this.canonicalBytes.length >
            SignedRoomControlEvent.maximumCanonicalBytes ||
        this.signature.length != SignedRoomControlEvent.signatureBytes) {
      throw const FormatException('invalid stored room control');
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

sealed class RoomControlApplyResult {
  const RoomControlApplyResult();
}

final class RoomControlAccepted extends RoomControlApplyResult {
  const RoomControlAccepted(this.state);
  final RoomState state;
}

/// The event is this device's current head, already applied.
final class RoomControlDuplicate extends RoomControlApplyResult {
  const RoomControlDuplicate(this.state);
  final RoomState state;
}

/// The event is older than this device's head. Whether it is one this device
/// accepted or a branch it never saw is a question for the stored transcript,
/// which the state machine does not hold.
final class RoomControlStale extends RoomControlApplyResult {
  const RoomControlStale(this.state);
  final RoomState state;
}

/// The event builds on a revision this device has not reached, or on a room it
/// does not hold. Nothing about it is wrong; something before it is missing,
/// and a member is asked for it.
final class RoomControlAhead extends RoomControlApplyResult {
  const RoomControlAhead(this.state);
  final RoomState? state;
}

final class RoomControlQuarantined extends RoomControlApplyResult {
  const RoomControlQuarantined(this.state, this.reason);
  final RoomState? state;
  final RoomQuarantineReason reason;
}

/// Applies authenticated control events to a room's roster, in revision order.
///
/// Its input is an event whose signature the native core already verified
/// under the signer device's authenticated key. What it decides is everything
/// the signature cannot: whether the event extends this device's chain, and
/// whether its signer was allowed to make it by the roster it was built on.
/// The outcome depends on nothing but the previous state and the event, so two
/// devices that apply the same events hold the same room.
final class RoomControlStateMachine {
  const RoomControlStateMachine();

  RoomControlApplyResult apply({
    required RoomState? previous,
    required SignedRoomControlEvent signedControl,
    required String localUserId,
  }) {
    final event = signedControl.event;
    final local = localUserId.toLowerCase();
    if (previous == null) {
      return event.revision == 1
          ? _create(event, signedControl.controlStateHash, local)
          : const RoomControlAhead(null);
    }
    if (event.roomId != previous.roomId) {
      return RoomControlQuarantined(
        previous,
        RoomQuarantineReason.brokenControlChain,
      );
    }
    if (event.revision == previous.controlRevision) {
      return signedControl.controlStateHash == previous.controlStateHash
          ? RoomControlDuplicate(previous)
          : RoomControlQuarantined(
              previous,
              RoomQuarantineReason.siblingControl,
            );
    }
    if (event.revision < previous.controlRevision) {
      return RoomControlStale(previous);
    }
    if (event.revision > previous.controlRevision + 1) {
      return RoomControlAhead(previous);
    }
    if (event.previousControlStateHash != previous.controlStateHash) {
      return RoomControlQuarantined(
        previous,
        RoomQuarantineReason.siblingControl,
      );
    }
    final next = _applyOperation(previous, event, local);
    if (next == null) {
      return RoomControlQuarantined(
        previous,
        RoomQuarantineReason.unauthorizedControl,
      );
    }
    try {
      return RoomControlAccepted(
        RoomState(
          roomId: previous.roomId,
          name: next.name,
          members: next.members,
          controlRevision: event.revision,
          controlStateHash: signedControl.controlStateHash,
          lifecycle: next.lifecycle,
          removedByUserId: next.removedByUserId,
        ),
      );
    } on FormatException {
      return RoomControlQuarantined(
        previous,
        RoomQuarantineReason.invalidMembership,
      );
    }
  }

  RoomControlApplyResult _create(
    RoomControlEvent event,
    String controlStateHash,
    String localUserId,
  ) {
    final operation = event.operation;
    if (operation is! CreateRoomOperation ||
        !RoomNames.isValid(operation.name) ||
        operation.memberUserIds.length < RoomState.minimumCreateMembers ||
        operation.memberUserIds.length > RoomState.maximumMembers ||
        operation.memberUserIds.toSet().length !=
            operation.memberUserIds.length) {
      return const RoomControlQuarantined(
        null,
        RoomQuarantineReason.invalidMembership,
      );
    }
    // The one creator it names is one of its members.
    if (!operation.memberUserIds.contains(event.signerUserId)) {
      return const RoomControlQuarantined(
        null,
        RoomQuarantineReason.unauthorizedControl,
      );
    }
    try {
      return RoomControlAccepted(
        RoomState(
          roomId: event.roomId,
          name: RoomNames.normalized(operation.name),
          members: [
            for (final userId in operation.memberUserIds)
              RoomMember(userId: userId),
          ],
          controlRevision: 1,
          controlStateHash: controlStateHash,
          // A member added later replays the room from this event, before the
          // event that adds it. Until then it is outside the room, which is the
          // removed lifecycle; the add makes it active.
          lifecycle: operation.memberUserIds.contains(localUserId)
              ? RoomLifecycle.active
              : RoomLifecycle.removed,
        ),
      );
    } on FormatException {
      return const RoomControlQuarantined(
        null,
        RoomQuarantineReason.invalidMembership,
      );
    }
  }

  _MutableRoomState? _applyOperation(
    RoomState previous,
    RoomControlEvent event,
    String localUserId,
  ) {
    final mutable = _MutableRoomState.from(previous);
    final actor = event.signerUserId;
    switch (event.operation) {
      case CreateRoomOperation():
        return null;
      case AddRoomMembersOperation(:final userIds):
        if (!RoomAuthorization.canAdd(
          previous,
          actorUserId: actor,
          targetUserIds: userIds,
          forControl: true,
        )) {
          return null;
        }
        for (final userId in userIds) {
          if (previous.member(userId) == null) {
            mutable.members.add(RoomMember(userId: userId));
          } else {
            mutable.replaceMember(
              userId,
              (member) =>
                  member.copyWith(membership: RoomMembershipState.active),
            );
          }
          if (userId == localUserId) {
            mutable
              ..lifecycle = RoomLifecycle.active
              ..removedByUserId = null;
          }
        }
      case RemoveRoomMemberOperation(:final targetUserId)
          when targetUserId == actor:
        if (!RoomAuthorization.canRemove(
          previous,
          actorUserId: actor,
          targetUserId: actor,
          forControl: true,
        )) {
          return null;
        }
        mutable.replaceMember(
          actor,
          (member) => member.copyWith(membership: RoomMembershipState.left),
        );
        if (actor == localUserId) {
          mutable.lifecycle = RoomLifecycle.left;
        }
      case RemoveRoomMemberOperation(:final targetUserId):
        if (!RoomAuthorization.canRemove(
          previous,
          actorUserId: actor,
          targetUserId: targetUserId,
          forControl: true,
        )) {
          return null;
        }
        mutable.replaceMember(
          targetUserId,
          (member) => member.copyWith(membership: RoomMembershipState.removed),
        );
        if (targetUserId == localUserId) {
          mutable
            ..lifecycle = RoomLifecycle.removed
            ..removedByUserId = actor;
        }
      case RenameRoomOperation(:final name):
        if (!RoomAuthorization.canRename(
          previous,
          actorUserId: actor,
          name: name,
          forControl: true,
        )) {
          return null;
        }
        mutable.name = RoomNames.normalized(name);
    }
    return mutable;
  }
}

/// Exact bytes owed to other devices, committed in the same transaction as the
/// state change that produced them and fanned out afterwards.
final class RoomOutboundWork {
  RoomOutboundWork({
    required this.operationId,
    required this.roomId,
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
        !_isHex(roomId, RoomState.roomIdBytes) ||
        eventId.isEmpty ||
        this.payload.isEmpty ||
        this.recipientUserIds.toSet().length != this.recipientUserIds.length ||
        this.recipientUserIds.any((value) => !_uuid.hasMatch(value)) ||
        (this.recipientUserIds.isEmpty && !includeOwnDevices) ||
        (recipientDeviceId != null &&
            (this.recipientUserIds.length != 1 ||
                includeOwnDevices ||
                !_uuid.hasMatch(recipientDeviceId!)))) {
      throw const FormatException('invalid room outbound work');
    }
  }

  final String operationId;
  final String roomId;
  final String eventId;
  final Uint8List payload;
  final List<String> recipientUserIds;

  /// Restricts a single-recipient send to one device: the one that asked, or
  /// the one a session is being started with.
  final String? recipientDeviceId;

  /// Whether this device's other devices receive a copy too.
  final bool includeOwnDevices;
}

enum RoomStateRequestReason {
  /// The mailbox lost envelopes, one of which may have been a control event.
  queueGap,

  /// Something arrived that names state this device does not hold: an event
  /// built on it, or a request naming it.
  behind,
}

/// That this device still needs a room's control state from a member.
final class RoomStateRequest {
  RoomStateRequest({
    required this.roomId,
    required this.reason,
    required this.peerUserId,
    required this.attempts,
    required this.requestedAt,
  }) {
    if (!_isHex(roomId, RoomState.roomIdBytes) ||
        (peerUserId != null && !_uuid.hasMatch(peerUserId!)) ||
        attempts < 0) {
      throw const FormatException('invalid room state request');
    }
  }

  final String roomId;
  final RoomStateRequestReason reason;

  /// Who to ask. Null until a member is chosen for a queue gap.
  final String? peerUserId;
  final int attempts;
  final DateTime? requestedAt;
}

/// A room whose member devices this device checks for a missing pairwise
/// session (`voice-signalling-v1.md`, Starting the sessions a call needs).
final class RoomSessionCheck {
  RoomSessionCheck({
    required this.roomId,
    required this.checkedAt,
    required this.controlRevision,
    required this.controlStateHash,
  }) {
    if (!_isHex(roomId, RoomState.roomIdBytes) ||
        controlRevision < 1 ||
        !_isHex(controlStateHash, RoomState.stateHashBytes)) {
      throw const FormatException('invalid room session check');
    }
  }

  final String roomId;

  /// When this device last checked. Null means a change that gave it the room
  /// or added a member has committed since, which is rule 1: only a device
  /// whose id sorts above this one is started now.
  final DateTime? checkedAt;

  /// The state the check was read at. A check recorded against any other
  /// state leaves the room due, because a change committed in between.
  final int controlRevision;
  final String controlStateHash;

  bool get followsAcceptedChange => checkedAt == null;
}

/// One authenticated state change and the bytes it owes other devices.
///
/// [controls] is a contiguous run of the room's chain: one locally signed
/// event, one received event, or the suffix of a transcript a member sent.
final class PreparedRoomTransition {
  PreparedRoomTransition({
    required Iterable<SignedRoomControlEvent> controls,
    Iterable<RoomOutboundWork> outbound = const [],
    this.completesStateRequest = false,
  }) : controls = List.unmodifiable(controls),
       outbound = List.unmodifiable(outbound) {
    if (this.controls.isEmpty) {
      throw const FormatException('a transition requires a control event');
    }
    for (var index = 1; index < this.controls.length; index += 1) {
      final previous = this.controls[index - 1];
      final current = this.controls[index].event;
      if (current.roomId != previous.event.roomId ||
          current.revision != previous.event.revision + 1 ||
          current.previousControlStateHash != previous.controlStateHash) {
        throw const FormatException('a transition must be one chain');
      }
    }
    if (this.outbound.any((work) => work.roomId != last.event.roomId)) {
      throw const FormatException('outbound work for another room');
    }
  }

  final List<SignedRoomControlEvent> controls;
  final List<RoomOutboundWork> outbound;

  /// Whether committing this answers an outstanding state request for the
  /// room, so the request is retired in the same transaction.
  final bool completesStateRequest;

  SignedRoomControlEvent get first => controls.first;
  SignedRoomControlEvent get last => controls.last;

  /// Whether the run gives this device the room or adds a member, which makes
  /// the room's session check due under rule 1.
  bool get admitsMembers => controls.any(
    (control) =>
        control.event.operation is CreateRoomOperation ||
        control.event.operation is AddRoomMembersOperation,
  );
}

/// An inbound room outcome that must commit in the same transaction as the
/// pairwise receive that carried it.
sealed class PreparedRoomInboxCommit implements RoomSyncReceiveCommit {
  const PreparedRoomInboxCommit({
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

final class PreparedRoomInboxTransition extends PreparedRoomInboxCommit {
  const PreparedRoomInboxTransition({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.expectedPrevious,
    required this.next,
    required this.prepared,
  });

  final RoomState? expectedPrevious;
  final RoomState next;
  final PreparedRoomTransition prepared;
}

final class PreparedRoomInboxQuarantine extends PreparedRoomInboxCommit {
  const PreparedRoomInboxQuarantine({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.record,
    required this.retainLifecycle,
    this.completesStateRequest = false,
  });

  final RoomQuarantineRecord record;

  /// A fork moves the room into quarantine. An event its signer was not
  /// allowed to make is recorded and dropped, so that one member cannot stop a
  /// room for everybody by signing something invalid.
  final bool retainLifecycle;

  /// Whether the answer that revealed the rejection also retires the room's
  /// open state request, because no other answer could change the outcome.
  final bool completesStateRequest;
}

final class PreparedRoomInboxStateRequest extends PreparedRoomInboxCommit {
  const PreparedRoomInboxStateRequest({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.roomId,
    required this.peerUserId,
  });

  final String roomId;
  final String peerUserId;
}

/// Bytes a member owes the device that asked it for a room's state.
final class PreparedRoomInboxOutbound extends PreparedRoomInboxCommit {
  const PreparedRoomInboxOutbound({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.work,
  });

  final RoomOutboundWork work;
}

/// A member confirmed this device already holds the room's current state.
final class PreparedRoomInboxStateCurrent extends PreparedRoomInboxCommit {
  const PreparedRoomInboxStateCurrent({
    required super.opaqueEventId,
    required super.senderUserId,
    required super.senderDeviceId,
    required this.roomId,
    required this.controlRevision,
    required this.controlStateHash,
  });

  final String roomId;
  final int controlRevision;
  final String controlStateHash;
}

final class RoomQuarantineRecord {
  RoomQuarantineRecord({
    required this.roomId,
    required this.reason,
    required Uint8List opaqueDigest,
    required this.receivedAt,
  }) : opaqueDigest = Uint8List.fromList(opaqueDigest);

  final String roomId;
  final RoomQuarantineReason reason;
  final Uint8List opaqueDigest;
  final DateTime receivedAt;
}

final class _MutableRoomState {
  _MutableRoomState({
    required this.name,
    required this.members,
    required this.lifecycle,
    required this.removedByUserId,
  });

  factory _MutableRoomState.from(RoomState state) => _MutableRoomState(
    name: state.name,
    members: state.members.toList(),
    lifecycle: state.lifecycle,
    removedByUserId: state.removedByUserId,
  );

  String name;
  final List<RoomMember> members;
  RoomLifecycle lifecycle;
  String? removedByUserId;

  void replaceMember(
    String userId,
    RoomMember Function(RoomMember member) replace,
  ) {
    final normalized = userId.toLowerCase();
    final index = members.indexWhere((member) => member.userId == normalized);
    if (index < 0) throw const FormatException('missing member');
    members[index] = replace(members[index]);
  }
}

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

String _userId(String value) {
  final normalized = value.toLowerCase();
  if (!_uuid.hasMatch(normalized)) {
    throw const FormatException('invalid room member');
  }
  return normalized;
}

/// Account ids in the order the native core requires: the canonical UUID
/// string sorts exactly as its bytes do. A repeated id is kept, so that the
/// state machine refuses it rather than this constructor hiding it.
List<String> _sortedUserIds(Iterable<String> values) =>
    List.unmodifiable(values.map(_userId).toList()..sort());

List<RoomMember> _sortedMembers(Iterable<RoomMember> values) =>
    values.toList(growable: false)
      ..sort((left, right) => left.userId.compareTo(right.userId));

bool _isHex(String value, int byteLength) =>
    value.length == byteLength * 2 && RegExp(r'^[0-9a-f]+$').hasMatch(value);
