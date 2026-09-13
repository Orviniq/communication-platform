import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';

/// Creates a group: one signed create event, committed with the roster it
/// establishes and the copy it owes every member's devices.
final class CreateGroup {
  const CreateGroup({
    required this.repository,
    required this.crypto,
    required this.identity,
    required this.clock,
    this.stateMachine = const GroupControlStateMachine(),
  });

  final GroupRepositoryPort repository;
  final GroupControlCryptoPort crypto;
  final GroupIdentityPort identity;
  final TimeSource clock;
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
    final List<GroupMember> members;
    try {
      members = [
        GroupMember(
          userId: currentUserId,
          displayName: ownerDisplayName,
          role: GroupRole.owner,
          verified: true,
        ),
        for (final member in selectedMembers)
          GroupMember(
            userId: member.userId,
            displayName: member.displayName,
            role: GroupRole.member,
            verified: member.verified,
          ),
      ];
    } on FormatException {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    if (members.map((member) => member.userId).toSet().length !=
            members.length ||
        members.length < 2 ||
        members.length > GroupState.maximumMembers) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    // A group identifier is 256 random bits and an event identifier 128, both
    // from the native core's CSPRNG.
    final randomResult = await _randomIdentifiers(identity, 3);
    if (randomResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final random = (randomResult as Success<Uint8List>).value;
    final GroupControlEvent event;
    try {
      event = GroupControlEvent(
        eventId: protocolBytesToHex(random.sublist(32, 48)),
        groupId: protocolBytesToHex(random.sublist(0, 32)),
        revision: 1,
        previousControlStateHash: null,
        signerUserId: currentUserId,
        signerDeviceId: currentDeviceId,
        createdMs: clock.now().toUtc().millisecondsSinceEpoch,
        operation: CreateGroupOperation(
          metadata: normalized,
          invitationPolicy: GroupInvitationPolicy.ownerAndAdmins,
          // Nothing re-shares earlier messages with a member who joins later,
          // so the only policy this build can honour is the one it states.
          historySharingPolicy: GroupHistorySharingPolicy.newMessagesOnly,
          members: members,
        ),
      );
    } on FormatException {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    return _signApplyAndCommit(
      repository: repository,
      crypto: crypto,
      stateMachine: stateMachine,
      current: null,
      event: event,
      localUserId: currentUserId,
    );
  }
}

/// Signs one change to an existing group and commits it with the copies it
/// owes: the event itself to every member who held the state it builds on,
/// and the whole transcript to every member it adds.
final class MutateGroup {
  const MutateGroup({
    required this.repository,
    required this.crypto,
    required this.identity,
    required this.clock,
    this.stateMachine = const GroupControlStateMachine(),
  });

  final GroupRepositoryPort repository;
  final GroupControlCryptoPort crypto;
  final GroupIdentityPort identity;
  final TimeSource clock;
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
    // A group waiting on a member to confirm its state, or holding a control it
    // refused, is read-only: a change signed now could build on a roster that
    // is already stale.
    if (current.lifecycle != GroupLifecycle.active ||
        !_authorized(current, actorUserId.toLowerCase(), operation)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final randomResult = await _randomIdentifiers(identity, 1);
    if (randomResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final GroupControlEvent event;
    try {
      event = GroupControlEvent(
        eventId: protocolBytesToHex((randomResult as Success<Uint8List>).value),
        groupId: current.groupId,
        revision: current.controlRevision + 1,
        previousControlStateHash: current.controlStateHash,
        signerUserId: actorUserId,
        signerDeviceId: actorDeviceId,
        createdMs: clock.now().toUtc().millisecondsSinceEpoch,
        operation: switch (operation) {
          RenameGroupOperation(:final metadata) => RenameGroupOperation(
            metadata.normalized(),
          ),
          _ => operation,
        },
      );
    } on FormatException {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    return _signApplyAndCommit(
      repository: repository,
      crypto: crypto,
      stateMachine: stateMachine,
      current: current,
      event: event,
      localUserId: actorUserId,
    );
  }

  bool _authorized(
    GroupState state,
    String actorUserId,
    GroupControlOperation operation,
  ) => switch (operation) {
    CreateGroupOperation() => false,
    AddGroupMembersOperation(:final members) =>
      members.every(
            (member) => member.isActive && member.role == GroupRole.member,
          ) &&
          GroupAuthorization.canAdd(
            state,
            actorUserId: actorUserId,
            targetUserIds: members.map((member) => member.userId),
          ),
    RemoveGroupMemberOperation(:final targetUserId)
        when targetUserId == actorUserId =>
      GroupAuthorization.canLeave(state, actorUserId),
    RemoveGroupMemberOperation(:final targetUserId) =>
      GroupAuthorization.canRemove(
        state,
        actorUserId: actorUserId,
        targetUserId: targetUserId,
      ),
    ChangeGroupRoleOperation(:final targetUserId, :final role)
        when role == GroupRole.owner =>
      GroupAuthorization.canTransferOwnership(
        state,
        actorUserId: actorUserId,
        targetUserId: targetUserId,
      ),
    ChangeGroupRoleOperation(:final targetUserId, :final role) =>
      GroupAuthorization.canChangeRole(
        state,
        actorUserId: actorUserId,
        targetUserId: targetUserId,
        role: role,
      ),
    RenameGroupOperation(:final metadata) =>
      metadata.isValid &&
          GroupAuthorization.allows(
            state,
            actorUserId,
            GroupPermission.editMetadata,
          ),
  };
}

/// Sends a text message into a group.
///
/// The message is an ordinary application event whose conversation is the
/// group, so it takes the same durable path a direct message takes: a local
/// echo now, and one pairwise copy for every live device of every member once
/// the delivery cycle resolves who those devices are.
final class SendGroupMessage {
  const SendGroupMessage({required this.repository, required this.sender});

  final GroupRepositoryPort repository;
  final GroupMessageSenderPort sender;

  Future<Result<void>> call({
    required String groupId,
    required String senderUserId,
    required String senderDeviceId,
    required String text,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty ||
        normalized.runes.length >
            ApplicationMessageProtocolV1.maximumTextScalars ||
        normalized.codeUnits.length >
            ApplicationMessageProtocolV1.maximumTextBytes) {
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
    return sender.sendText(
      currentUserId: senderUserId.toLowerCase(),
      currentDeviceId: senderDeviceId.toLowerCase(),
      groupId: group.groupId,
      text: normalized,
    );
  }
}

final class GroupUseCases {
  const GroupUseCases({
    required this.create,
    required this.mutate,
    required this.sendMessage,
  });

  final CreateGroup create;
  final MutateGroup mutate;
  final SendGroupMessage sendMessage;
}

/// Who a locally signed control event is owed to, and in which payloads.
abstract final class GroupControlDistribution {
  /// [transcriptBefore] is every accepted event before [signed], which a
  /// member this event adds needs to replay the group from its first event.
  ///
  /// Throws [FormatException] when a payload would not fit one envelope.
  static List<GroupOutboundWork> forLocalControl({
    required GroupState? previous,
    required GroupState next,
    required SignedGroupControlEvent signed,
    required String currentUserId,
    List<StoredGroupControl> transcriptBefore = const [],
  }) {
    final local = currentUserId.toLowerCase();
    final event = signed.event;
    final added = <String>{
      if (event.operation case AddGroupMembersOperation(:final members))
        ...members.map((member) => member.userId),
    };
    // Everybody who held the state this event builds on, the member it removes
    // included, so that member learns it. A member the event adds cannot apply
    // it alone and is sent the transcript instead.
    final recipients =
        <String>{
            ...(previous ?? next).activeMembers.map((member) => member.userId),
          }
          ..remove(local)
          ..removeAll(added);
    final work = <GroupOutboundWork>[
      GroupOutboundWork(
        operationId: 'group-control:${event.eventId}',
        groupId: event.groupId,
        eventId: 'group-control:${event.eventId}',
        payload: GroupSyncPayloadCodec.encode(
          GroupControlDelivery(GroupSignedControlBytes.fromSigned(signed)),
        ),
        recipientUserIds: recipients.toList(growable: false)..sort(),
        includeOwnDevices: true,
      ),
    ];
    if (added.isNotEmpty) {
      final transcript = GroupSyncPayloadCodec.encode(
        GroupTranscriptPayload(
          groupId: event.groupId,
          baseRevision: 0,
          baseStateHash: null,
          entries: [
            ...transcriptBefore.map(GroupSignedControlBytes.fromStored),
            GroupSignedControlBytes.fromSigned(signed),
          ],
        ),
      );
      for (final member in added.toList(growable: false)..sort()) {
        work.add(
          GroupOutboundWork(
            operationId: 'group-transcript:${event.eventId}:$member',
            groupId: event.groupId,
            eventId: 'group-transcript:${event.eventId}:$member',
            payload: transcript,
            recipientUserIds: [member],
          ),
        );
      }
    }
    return work;
  }
}

Future<Result<GroupState>> _signApplyAndCommit({
  required GroupRepositoryPort repository,
  required GroupControlCryptoPort crypto,
  required GroupControlStateMachine stateMachine,
  required GroupState? current,
  required GroupControlEvent event,
  required String localUserId,
}) async {
  final sealedResult = await crypto.seal(event);
  if (sealedResult case FailureResult(failure: final failure)) {
    return Result.failure(failure);
  }
  final sealed = (sealedResult as Success<SignedGroupControlEvent>).value;
  final applied = stateMachine.apply(
    previous: current,
    signedControl: sealed,
    localUserId: localUserId,
  );
  // The caller authorized this change against the same state, so a refusal
  // here means the signed bytes do not say what was asked for.
  if (applied is! GroupControlAccepted) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );
  }
  var transcriptBefore = const <StoredGroupControl>[];
  if (current != null && event.operation is AddGroupMembersOperation) {
    final transcriptResult = await repository.readTranscript(event.groupId);
    if (transcriptResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    transcriptBefore =
        (transcriptResult as Success<List<StoredGroupControl>>).value;
    if (transcriptBefore.isEmpty ||
        transcriptBefore.last.revision != current.controlRevision ||
        transcriptBefore.last.controlStateHash != current.controlStateHash) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }
  final List<GroupOutboundWork> outbound;
  try {
    outbound = GroupControlDistribution.forLocalControl(
      previous: current,
      next: applied.state,
      signed: sealed,
      currentUserId: localUserId,
      transcriptBefore: transcriptBefore,
    );
  } on FormatException {
    // A transcript too long for one envelope cannot be handed to a member who
    // needs all of it, so the member is not added rather than added blind.
    return const Result.failure(
      ValidationFailure(ValidationFailureKind.limitExceeded),
    );
  }
  final committed = await repository.commitTransition(
    expectedPrevious: current,
    next: applied.state,
    prepared: PreparedGroupTransition(controls: [sealed], outbound: outbound),
  );
  return committed.fold(
    onSuccess: (_) => Result.success(applied.state),
    onFailure: Result.failure,
  );
}

Future<Result<Uint8List>> _randomIdentifiers(
  GroupIdentityPort identity,
  int count,
) async {
  final builder = BytesBuilder(copy: false);
  for (var index = 0; index < count; index += 1) {
    final result = await identity.randomIdentifier();
    if (result case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final value = (result as Success<Uint8List>).value;
    if (value.length != GroupControlEvent.eventIdBytes) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    builder.add(value);
  }
  return Result.success(builder.takeBytes());
}
