import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';

/// Asks a member for a group's control state when this device may have lost
/// part of it (`backend/CLIENT_CONTRACT.md` §H).
///
/// A lost envelope may have carried a ratchet message or a control event. For
/// a mailbox gap this first asks the chosen member's devices to replace their
/// pairwise sessions with this one, through the authenticated repair path, and
/// then asks that member for every control event after the state this device
/// holds. It never asks anybody to remove this device and add it back: that was
/// how a gap was repaired when a group was an MLS epoch, and a group is not one.
final class GroupStateRecoveryService {
  const GroupStateRecoveryService({
    required this.repository,
    required this.repair,
    required this.clock,
    required this.currentUserId,
    required this.currentDeviceId,
    this.retryInterval = const Duration(hours: 6),
    this.maximumBehindAttempts = 3,
  });

  final GroupRepositoryPort repository;
  final GroupSessionRepairPort repair;
  final TimeSource clock;
  final String currentUserId;
  final String currentDeviceId;

  /// How long a sent request waits for an answer before it is sent again, to
  /// the next member in line.
  final Duration retryInterval;

  /// How often a request that was not caused by a gap is sent before it is
  /// given up. Such a request can name a group the sender never had.
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
        in (dueResult as Success<List<GroupStateRequest>>).value) {
      final storedResult = await repository.readStoredGroup(request.groupId);
      if (storedResult case FailureResult(failure: final failure)) {
        firstFailure ??= failure;
        continue;
      }
      final stored = (storedResult as Success<GroupState?>).value;
      final String? peerUserId;
      switch (request.reason) {
        case GroupStateRequestReason.queueGap:
          final candidates =
              stored == null || stored.lifecycle != GroupLifecycle.active
              ? const <String>[]
              : _candidates(stored, local);
          if (candidates.isEmpty) {
            // Nobody else holds this group's state, or this device no longer
            // follows it. There is nothing to wait for.
            final retired = await repository.retireStateRequest(
              request.groupId,
            );
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
        case GroupStateRequestReason.behind:
          peerUserId = request.peerUserId;
          if (peerUserId == null || request.attempts >= maximumBehindAttempts) {
            final retired = await repository.retireStateRequest(
              request.groupId,
            );
            if (retired case FailureResult(failure: final failure)) {
              firstFailure ??= failure;
            }
            continue;
          }
      }
      final GroupOutboundWork work;
      try {
        final operationId =
            'group-state-request:${request.groupId}:${now.millisecondsSinceEpoch}';
        work = GroupOutboundWork(
          operationId: operationId,
          groupId: request.groupId,
          eventId: operationId,
          payload: GroupSyncPayloadCodec.encode(
            GroupStateRequestPayload(
              groupId: request.groupId,
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
        groupId: request.groupId,
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

  /// The members asked, in turn: the owner, then admins, then members, each
  /// in user-id order, so every device of this account asks in the same order.
  List<String> _candidates(GroupState state, String localUserId) {
    int rank(GroupMember member) => switch (member.role) {
      GroupRole.owner => 0,
      GroupRole.admin => 1,
      GroupRole.member => 2,
    };
    final others =
        state.activeMembers
            .where((member) => member.userId != localUserId)
            .toList(growable: false)
          ..sort((left, right) {
            final byRole = rank(left).compareTo(rank(right));
            return byRole != 0 ? byRole : left.userId.compareTo(right.userId);
          });
    return [for (final member in others) member.userId];
  }
}
