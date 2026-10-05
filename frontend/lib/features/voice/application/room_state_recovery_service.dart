import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';

/// Asks a member for a room's control state when this device may have lost
/// part of it (`backend/CLIENT_CONTRACT.md` §H), or was told of state it does
/// not hold.
///
/// A lost envelope may have carried a ratchet message or a control event — a
/// removal included, which is why a room that waits joins no call. For a
/// mailbox gap this first asks the chosen member's devices to replace their
/// pairwise sessions with this one, through the authenticated repair path, and
/// then asks that member for every control event after the state this device
/// holds, exactly as a group does.
final class RoomStateRecoveryService {
  const RoomStateRecoveryService({
    required this.repository,
    required this.repair,
    required this.clock,
    required this.currentUserId,
    required this.currentDeviceId,
    this.retryInterval = const Duration(hours: 6),
    this.maximumBehindAttempts = 3,
  });

  final RoomRepositoryPort repository;
  final RoomSessionRepairPort repair;
  final TimeSource clock;
  final String currentUserId;
  final String currentDeviceId;

  /// How long a sent request waits for an answer before it is sent again, to
  /// the next member in line.
  final Duration retryInterval;

  /// How often a request that was not caused by a gap is sent before it is
  /// given up. Such a request can name a room the sender never had.
  final int maximumBehindAttempts;

  Future<Result<int>> requestDueStates({int limit = 8}) async {
    final now = clock.now().toUtc();
    final dueResult = await repository.readDueStateRequests(
      retryBefore: now.subtract(retryInterval),
      limit: limit,
    );
    if (dueResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final local = currentUserId.toLowerCase();
    var sent = 0;
    Failure? firstFailure;
    for (final request
        in (dueResult as Success<List<RoomStateRequest>>).value) {
      final storedResult = await repository.readStoredRoom(request.roomId);
      if (storedResult case FailureResult(failure: final failure)) {
        firstFailure ??= failure;
        continue;
      }
      final stored = (storedResult as Success<RoomState?>).value;
      final String? peerUserId;
      switch (request.reason) {
        case RoomStateRequestReason.queueGap:
          final candidates =
              stored == null || stored.lifecycle != RoomLifecycle.active
              ? const <String>[]
              : _candidates(stored, local);
          if (candidates.isEmpty) {
            // Nobody else holds this room's state, or this device no longer
            // follows it. There is nothing to wait for.
            final retired = await repository.retireStateRequest(request.roomId);
            if (retired case FailureResult(failure: final failure)) {
              firstFailure ??= failure;
            }
            continue;
          }
          peerUserId = candidates[request.attempts % candidates.length];
          // Best effort by design. A session that cannot be repaired right now
          // still carries the request, and the member's answer arrives on the
          // replacement session whenever the repair completes.
          final repaired = await repair.requestRepairWithUser(
            localDeviceId: currentDeviceId,
            remoteUserId: peerUserId,
          );
          if (repaired case FailureResult(failure: final failure)) {
            firstFailure ??= failure;
          }
        case RoomStateRequestReason.behind:
          peerUserId = request.peerUserId;
          if (peerUserId == null || request.attempts >= maximumBehindAttempts) {
            final retired = await repository.retireStateRequest(request.roomId);
            if (retired case FailureResult(failure: final failure)) {
              firstFailure ??= failure;
            }
            continue;
          }
      }
      final RoomOutboundWork work;
      try {
        final operationId =
            'room-state-request:${request.roomId}:${now.millisecondsSinceEpoch}';
        work = RoomOutboundWork(
          operationId: operationId,
          roomId: request.roomId,
          eventId: operationId,
          payload: RoomSyncPayloadCodec.encode(
            RoomStateRequestPayload(
              roomId: request.roomId,
              haveRevision: stored?.controlRevision ?? 0,
              haveStateHash: stored?.controlStateHash,
            ),
          ),
          recipientUserIds: [peerUserId],
        );
      } on FormatException {
        firstFailure ??= const SecurityFailure(
          SecurityFailureKind.integrityCheckFailed,
        );
        continue;
      }
      final recorded = await repository.recordStateRequestSent(
        roomId: request.roomId,
        peerUserId: peerUserId,
        work: work,
        requestedAt: now,
      );
      if (recorded case FailureResult(failure: final failure)) {
        firstFailure ??= failure;
        continue;
      }
      sent += 1;
    }
    return firstFailure == null
        ? Result.success(sent)
        : Result.failure(firstFailure);
  }

  /// The members asked, in turn, in user-id order, so every device of this
  /// account asks in the same order. A room has no roles to rank them by.
  List<String> _candidates(RoomState state, String localUserId) => [
    for (final member in state.activeMembers)
      if (member.userId != localUserId) member.userId,
  ];
}
