import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

final class GroupOutboundDispatchReport {
  const GroupOutboundDispatchReport({
    required this.workItems,
    required this.fanoutOperations,
  });

  final int workItems;
  final int fanoutOperations;
}

/// Moves transactionally persisted group payloads into recipient-bound durable
/// pairwise outboxes. No network call is made here.
final class GroupOutboundDispatcher {
  const GroupOutboundDispatcher({
    required this.repository,
    required this.envelopes,
  });

  final GroupRepositoryPort repository;
  final GroupOutboundEnvelopePort envelopes;

  Future<Result<GroupOutboundDispatchReport>> dispatchPending({
    required String currentUserId,
    required String currentDeviceId,
    int limit = 20,
  }) async {
    final pendingResult = await repository.readPendingOutbound(limit: limit);
    if (pendingResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final pending = (pendingResult as Success<List<GroupOutboundWork>>).value;
    var fanoutOperations = 0;
    Failure? firstFailure;
    for (final work in pending) {
      final routed = await _route(
        work,
        currentUserId: currentUserId.toLowerCase(),
        currentDeviceId: currentDeviceId.toLowerCase(),
        onFanout: () => fanoutOperations += 1,
      );
      // Pending work is ordered by creation, so ending the pass on the first
      // failure would let one operation nobody can route — an unreachable
      // recipient, a corrupt persisted row — strand every later group's
      // durable payload behind it for as long as its cause lasts. Each
      // operation is independent and idempotent, so the rest continue and the
      // first failure is still surfaced to the caller.
      if (routed case FailureResult(failure: final failure)) {
        firstFailure ??= failure;
      }
    }
    return firstFailure != null
        ? Result.failure(firstFailure)
        : Result.success(
            GroupOutboundDispatchReport(
              workItems: pending.length,
              fanoutOperations: fanoutOperations,
            ),
          );
  }

  /// Fans one persisted payload out to every recipient, then marks it routed.
  ///
  /// Each recipient user is one pairwise operation, so one member whose
  /// devices cannot be reached yet delays that member's copies and nobody
  /// else's. The marker is deliberately last and deliberately separate: a
  /// crash between the two leaves the payload pending, and the next pass
  /// reuses the exact ciphertext already persisted for each recipient rather
  /// than advancing any ratchet a second time.
  Future<Result<void>> _route(
    GroupOutboundWork work, {
    required String currentUserId,
    required String currentDeviceId,
    required void Function() onFanout,
  }) async {
    final deviceId = work.recipientDeviceId;
    if (deviceId != null) {
      final target = work.recipientUserIds.single;
      final queued = await envelopes.prepareAndQueue(
        operationId: '${work.operationId}:$target',
        eventId: '${work.eventId}:$target',
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
        targetUserId: target,
        payload: work.payload,
        includeOwnDevices: false,
        onlyRecipientDeviceId: deviceId,
      );
      if (queued case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      onFanout();
      return repository.markOutboundRouted(operationId: work.operationId);
    }
    final remoteUsers =
        work.recipientUserIds
            .where((value) => value != currentUserId)
            .toList(growable: false)
          ..sort();
    // A payload for nobody but this account's other devices is one operation
    // addressed to this account.
    final targets = remoteUsers.isEmpty ? [currentUserId] : remoteUsers;
    for (var index = 0; index < targets.length; index += 1) {
      final target = targets[index];
      final queued = await envelopes.prepareAndQueue(
        operationId: '${work.operationId}:$target',
        // One group payload becomes one pairwise operation per recipient user,
        // and a pairwise operation owns its logical send outright: the durable
        // outbox holds at most one local application per event id. The event
        // id is therefore qualified the same way the operation id is, so a
        // group with two or more remote members can fan out at all.
        eventId: '${work.eventId}:$target',
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
        targetUserId: target,
        payload: work.payload,
        includeOwnDevices:
            index == 0 && (work.includeOwnDevices || remoteUsers.isEmpty),
      );
      if (queued case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      onFanout();
    }
    return repository.markOutboundRouted(operationId: work.operationId);
  }
}
