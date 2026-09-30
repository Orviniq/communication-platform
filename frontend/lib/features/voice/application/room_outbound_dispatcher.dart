import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';

final class RoomOutboundDispatchReport {
  const RoomOutboundDispatchReport({
    required this.workItems,
    required this.fanoutOperations,
  });

  final int workItems;
  final int fanoutOperations;
}

/// Moves transactionally persisted room payloads into recipient-bound durable
/// pairwise outboxes, through the same fan-out a group payload takes. No
/// network call is made here.
///
/// The fan-out claims a bundle for, and starts a session with, any recipient
/// device that has none, so this is also where the room's session-start
/// requests become the first message of a session.
final class RoomOutboundDispatcher {
  const RoomOutboundDispatcher({
    required this.repository,
    required this.envelopes,
  });

  final RoomRepositoryPort repository;
  final RoomOutboundEnvelopePort envelopes;

  Future<Result<RoomOutboundDispatchReport>> dispatchPending({
    required String currentUserId,
    required String currentDeviceId,
    int limit = 20,
  }) async {
    final pendingResult = await repository.readPendingOutbound(limit: limit);
    if (pendingResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final pending = (pendingResult as Success<List<RoomOutboundWork>>).value;
    var fanoutOperations = 0;
    Failure? firstFailure;
    for (final work in pending) {
      final routed = await _route(
        work,
        currentUserId: currentUserId.toLowerCase(),
        currentDeviceId: currentDeviceId.toLowerCase(),
        onFanout: () => fanoutOperations += 1,
      );
      // Each operation is independent and idempotent, so one nobody can route
      // yet — an unreachable recipient, a device with no prekeys left — does
      // not strand every later room's payload behind it. The first failure is
      // still surfaced to the caller.
      if (routed case FailureResult(failure: final failure)) {
        firstFailure ??= failure;
      }
    }
    return firstFailure != null
        ? Result.failure(firstFailure)
        : Result.success(
            RoomOutboundDispatchReport(
              workItems: pending.length,
              fanoutOperations: fanoutOperations,
            ),
          );
  }

  /// Fans one persisted payload out to every recipient, then marks it routed.
  ///
  /// Each recipient user is one pairwise operation. The marker is last and
  /// separate: a crash between the two leaves the payload pending, and the
  /// next pass reuses the exact ciphertext already persisted for each
  /// recipient rather than advancing any ratchet a second time.
  Future<Result<void>> _route(
    RoomOutboundWork work, {
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
        // One room payload becomes one pairwise operation per recipient user,
        // and the durable outbox holds at most one local application per
        // event id, so the event id is qualified the way the operation id is.
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
