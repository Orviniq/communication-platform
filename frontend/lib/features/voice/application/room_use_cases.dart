import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';

/// Creates a room: one signed create event, committed with the roster it
/// establishes and the copy it owes every member's devices.
///
/// The create's own fan-out starts this device's session with every member
/// device that has none; the members start theirs with each other when they
/// accept it (`voice-signalling-v1.md`, Starting the sessions a call needs).
final class CreateRoom {
  const CreateRoom({
    required this.repository,
    required this.crypto,
    required this.identity,
    required this.clock,
    this.stateMachine = const RoomControlStateMachine(),
  });

  final RoomRepositoryPort repository;
  final RoomControlCryptoPort crypto;
  final RoomIdentityPort identity;
  final TimeSource clock;
  final RoomControlStateMachine stateMachine;

  /// [memberUserIds] are the accounts invited besides this one.
  Future<Result<RoomState>> call({
    required String currentUserId,
    required String currentDeviceId,
    required String name,
    required Iterable<String> memberUserIds,
  }) async {
    if (!RoomNames.isValid(name)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final List<String> members;
    try {
      members = CreateRoomOperation(
        name: name,
        memberUserIds: [currentUserId, ...memberUserIds],
      ).memberUserIds;
    } on FormatException {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    if (members.toSet().length != members.length ||
        members.length < RoomState.minimumCreateMembers ||
        members.length > RoomState.maximumMembers) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    // A room identifier is 256 random bits and an event identifier 128, all
    // from the native core's CSPRNG.
    final randomResult = await _randomIdentifiers(identity, 3);
    if (randomResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final random = (randomResult as Success<Uint8List>).value;
    final RoomControlEvent event;
    try {
      event = RoomControlEvent(
        eventId: protocolBytesToHex(random.sublist(32, 48)),
        roomId: protocolBytesToHex(random.sublist(0, 32)),
        revision: 1,
        previousControlStateHash: null,
        signerUserId: currentUserId,
        signerDeviceId: currentDeviceId,
        createdMs: clock.now().toUtc().millisecondsSinceEpoch,
        operation: CreateRoomOperation(
          name: RoomNames.normalized(name),
          memberUserIds: members,
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

/// Signs one change to an existing room and commits it with the copies it
/// owes: the event itself to every member who held the state it builds on,
/// and the whole transcript to every member it adds.
final class MutateRoom {
  const MutateRoom({
    required this.repository,
    required this.crypto,
    required this.identity,
    required this.clock,
    this.stateMachine = const RoomControlStateMachine(),
  });

  final RoomRepositoryPort repository;
  final RoomControlCryptoPort crypto;
  final RoomIdentityPort identity;
  final TimeSource clock;
  final RoomControlStateMachine stateMachine;

  Future<Result<RoomState>> call({
    required String roomId,
    required String actorUserId,
    required String actorDeviceId,
    required RoomControlOperation operation,
  }) async {
    final roomResult = await repository.readRoom(roomId);
    if (roomResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final current = (roomResult as Success<RoomState?>).value;
    if (current == null) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    // A room waiting on a member to confirm its state, or holding a control it
    // refused, is read-only: a change signed now could build on a roster that
    // is already stale.
    if (!_authorized(current, actorUserId.toLowerCase(), operation)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final randomResult = await _randomIdentifiers(identity, 1);
    if (randomResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final RoomControlEvent event;
    try {
      event = RoomControlEvent(
        eventId: protocolBytesToHex((randomResult as Success<Uint8List>).value),
        roomId: current.roomId,
        revision: current.controlRevision + 1,
        previousControlStateHash: current.controlStateHash,
        signerUserId: actorUserId,
        signerDeviceId: actorDeviceId,
        createdMs: clock.now().toUtc().millisecondsSinceEpoch,
        operation: switch (operation) {
          RenameRoomOperation(:final name) => RenameRoomOperation(
            RoomNames.normalized(name),
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
    RoomState state,
    String actorUserId,
    RoomControlOperation operation,
  ) => switch (operation) {
    CreateRoomOperation() => false,
    AddRoomMembersOperation(:final userIds) => RoomAuthorization.canAdd(
      state,
      actorUserId: actorUserId,
      targetUserIds: userIds,
    ),
    RemoveRoomMemberOperation(:final targetUserId) =>
      RoomAuthorization.canRemove(
        state,
        actorUserId: actorUserId,
        targetUserId: targetUserId,
      ),
    RenameRoomOperation(:final name) => RoomAuthorization.canRename(
      state,
      actorUserId: actorUserId,
      name: name,
    ),
  };
}

final class RoomUseCases {
  const RoomUseCases({required this.create, required this.mutate});

  final CreateRoom create;
  final MutateRoom mutate;
}

/// Who a locally signed control event is owed to, and in which payloads.
abstract final class RoomControlDistribution {
  /// [transcriptBefore] is every accepted event before [signed], which a
  /// member this event adds needs to replay the room from its first event.
  ///
  /// Throws [FormatException] when a payload would not fit one envelope.
  static List<RoomOutboundWork> forLocalControl({
    required RoomState? previous,
    required RoomState next,
    required SignedRoomControlEvent signed,
    required String currentUserId,
    List<StoredRoomControl> transcriptBefore = const [],
  }) {
    final local = currentUserId.toLowerCase();
    final event = signed.event;
    final added = <String>{
      if (event.operation case AddRoomMembersOperation(:final userIds))
        ...userIds,
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
    final work = <RoomOutboundWork>[
      RoomOutboundWork(
        operationId: 'room-control:${event.eventId}',
        roomId: event.roomId,
        eventId: 'room-control:${event.eventId}',
        payload: RoomSyncPayloadCodec.encode(
          RoomControlDelivery(RoomSignedControlBytes.fromSigned(signed)),
        ),
        recipientUserIds: recipients.toList(growable: false)..sort(),
        includeOwnDevices: true,
      ),
    ];
    if (added.isNotEmpty) {
      final transcript = RoomSyncPayloadCodec.encode(
        RoomTranscriptPayload(
          roomId: event.roomId,
          baseRevision: 0,
          baseStateHash: null,
          entries: [
            ...transcriptBefore.map(RoomSignedControlBytes.fromStored),
            RoomSignedControlBytes.fromSigned(signed),
          ],
        ),
      );
      for (final member in added.toList(growable: false)..sort()) {
        work.add(
          RoomOutboundWork(
            operationId: 'room-transcript:${event.eventId}:$member',
            roomId: event.roomId,
            eventId: 'room-transcript:${event.eventId}:$member',
            payload: transcript,
            recipientUserIds: [member],
          ),
        );
      }
    }
    return work;
  }
}

Future<Result<RoomState>> _signApplyAndCommit({
  required RoomRepositoryPort repository,
  required RoomControlCryptoPort crypto,
  required RoomControlStateMachine stateMachine,
  required RoomState? current,
  required RoomControlEvent event,
  required String localUserId,
}) async {
  final sealedResult = await crypto.seal(event);
  if (sealedResult case FailureResult(failure: final failure)) {
    return Result.failure(failure);
  }
  final sealed = (sealedResult as Success<SignedRoomControlEvent>).value;
  final applied = stateMachine.apply(
    previous: current,
    signedControl: sealed,
    localUserId: localUserId,
  );
  // The caller authorized this change against the same state, so a refusal
  // here means the signed bytes do not say what was asked for.
  if (applied is! RoomControlAccepted) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.integrityCheckFailed),
    );
  }
  var transcriptBefore = const <StoredRoomControl>[];
  if (current != null && event.operation is AddRoomMembersOperation) {
    final transcriptResult = await repository.readTranscript(event.roomId);
    if (transcriptResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    transcriptBefore =
        (transcriptResult as Success<List<StoredRoomControl>>).value;
    if (transcriptBefore.isEmpty ||
        transcriptBefore.last.revision != current.controlRevision ||
        transcriptBefore.last.controlStateHash != current.controlStateHash) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
  }
  final List<RoomOutboundWork> outbound;
  try {
    outbound = RoomControlDistribution.forLocalControl(
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
    prepared: PreparedRoomTransition(controls: [sealed], outbound: outbound),
  );
  return committed.fold(
    onSuccess: (_) => Result.success(applied.state),
    onFailure: Result.failure,
  );
}

Future<Result<Uint8List>> _randomIdentifiers(
  RoomIdentityPort identity,
  int count,
) async {
  final builder = BytesBuilder(copy: false);
  for (var index = 0; index < count; index += 1) {
    final result = await identity.randomIdentifier();
    if (result case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final value = (result as Success<Uint8List>).value;
    if (value.length != RoomControlEvent.eventIdBytes) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    builder.add(value);
  }
  return Result.success(builder.takeBytes());
}
