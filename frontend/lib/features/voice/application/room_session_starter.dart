import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';

/// One device a session-start request was committed for.
final class RoomSessionTarget {
  const RoomSessionTarget({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;

  @override
  bool operator ==(Object other) =>
      other is RoomSessionTarget &&
      other.userId == userId &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(userId, deviceId);
}

/// What one check of one room did.
final class RoomSessionCheckReport {
  RoomSessionCheckReport({
    required this.roomId,
    required Iterable<RoomSessionTarget> started,
    required Iterable<String> unresolvedUserIds,
  }) : started = List.unmodifiable(started),
       unresolvedUserIds = Set.unmodifiable(unresolvedUserIds);

  final String roomId;

  /// The devices this check committed a session-start request for. Each gets
  /// its session when the request is routed into the pairwise outbox.
  final List<RoomSessionTarget> started;

  /// Members whose live devices could not be authenticated just now: a changed
  /// safety number, a contact not verified yet, or no answer from the server.
  /// Nothing is started with them, and the call reports them as it finds them.
  final Set<String> unresolvedUserIds;
}

/// Starts, on the durable path, every pairwise session a room's call will
/// need (`voice-signalling-v1.md`, Starting the sessions a call needs; ADR-077,
/// decided B on 2026-09-30).
///
/// A call's frames are volatile, and a volatile frame never starts a session,
/// because a first frame the relay drops would leave a session only this side
/// holds. So the room does it first, with the one payload any active member may
/// send any member's device: a state request naming the state this device
/// holds, sealed to that device alone. The durable queue holds it until the
/// device fetches it, and the answer is the session's second message.
///
/// It never sends anything to a device it already has a session with, so a
/// check costs a missing session two envelopes and nothing otherwise.
final class RoomSessionStarter {
  const RoomSessionStarter({
    required this.repository,
    required this.liveDevices,
    required this.sessions,
    required this.clock,
    required this.currentUserId,
    required this.currentDeviceId,
    this.checkInterval = const Duration(hours: 24),
    this.roomsPerPass = 4,
  });

  final RoomRepositoryPort repository;
  final RoomLiveDeviceResolverPort liveDevices;
  final RoomPairwiseSessionPort sessions;
  final TimeSource clock;
  final String currentUserId;
  final String currentDeviceId;

  /// How long a room goes between checks when nothing changes in it. It is
  /// what reaches a member's new device, and a device that sorts lower and was
  /// offline when the room changed.
  final Duration checkInterval;

  /// Every check resolves each member's live devices, one authenticated lookup
  /// each, so a pass takes a few rooms and the next pass takes the rest.
  final int roomsPerPass;

  /// Runs the checks that are due, and returns how many requests they
  /// committed.
  ///
  /// A room whose change of rule 1 is unchecked starts a session only with a
  /// device that sorts above this one; a room whose last check is older than
  /// [checkInterval] starts one with every device that has none.
  Future<Result<int>> startDueSessions() async {
    final now = clock.now().toUtc();
    final dueResult = await repository.readDueSessionChecks(
      checkedBefore: now.subtract(checkInterval),
      limit: roomsPerPass,
    );
    if (dueResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    var started = 0;
    Failure? firstFailure;
    for (final check in (dueResult as Success<List<RoomSessionCheck>>).value) {
      final report = await _check(
        check,
        onlyAbove: check.followsAcceptedChange,
        now: now,
      );
      switch (report) {
        case Success(:final value):
          started += value?.started.length ?? 0;
        case FailureResult(:final failure):
          firstFailure ??= failure;
      }
    }
    return firstFailure == null
        ? Result.success(started)
        : Result.failure(firstFailure);
  }

  /// The call's check before its join: a session is started with every live
  /// device of every active member that has none, whichever id sorts lower.
  ///
  /// Refused for a room this device may not call in. A device the report
  /// names has its request committed, not delivered: the call routes the room's
  /// outbound work before it seals its `join`, and a peer that has not fetched
  /// the request yet drops that frame and takes the next attempt.
  Future<Result<RoomSessionCheckReport>> startSessionsForCall(
    String roomId,
  ) async {
    final roomResult = await repository.readRoom(roomId);
    if (roomResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final room = (roomResult as Success<RoomState?>).value;
    if (room == null ||
        !RoomAuthorization.mayAct(room, currentUserId.toLowerCase())) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final report = await _check(
      RoomSessionCheck(
        roomId: room.roomId,
        checkedAt: null,
        controlRevision: room.controlRevision,
        controlStateHash: room.controlStateHash,
      ),
      onlyAbove: false,
      now: clock.now().toUtc(),
    );
    return switch (report) {
      Success(:final value) when value != null => Result.success(value),
      Success() => const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      ),
      FailureResult(:final failure) => Result.failure(failure),
    };
  }

  /// Null when the room is no longer the one [check] read, or no longer one
  /// this device may act in: nothing is started, and nothing is recorded, so
  /// a changed room is checked again as it now stands.
  Future<Result<RoomSessionCheckReport?>> _check(
    RoomSessionCheck check, {
    required bool onlyAbove,
    required DateTime now,
  }) async {
    final local = currentUserId.toLowerCase();
    final localDevice = currentDeviceId.toLowerCase();
    final roomResult = await repository.readRoom(check.roomId);
    if (roomResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final room = (roomResult as Success<RoomState?>).value;
    if (room == null ||
        !RoomAuthorization.mayAct(room, local) ||
        room.controlRevision != check.controlRevision ||
        room.controlStateHash != check.controlStateHash) {
      return const Result.success(null);
    }

    // Payloads already owed start their own sessions when they are routed: a
    // create's or an add's own copies, an answer, an earlier request.
    final pendingResult = await repository.readPendingOutboundForRoom(
      room.roomId,
    );
    if (pendingResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final owedUsers = <String>{};
    final owedDevices = <String>{};
    for (final work
        in (pendingResult as Success<List<RoomOutboundWork>>).value) {
      if (work.recipientDeviceId case final deviceId?) {
        owedDevices.add(deviceId.toLowerCase());
      } else {
        owedUsers.addAll(work.recipientUserIds);
        if (work.includeOwnDevices) owedUsers.add(local);
      }
    }

    final payload = RoomSyncPayloadCodec.encode(
      RoomStateRequestPayload(
        roomId: room.roomId,
        haveRevision: room.controlRevision,
        haveStateHash: room.controlStateHash,
      ),
    );
    final work = <RoomOutboundWork>[];
    final started = <RoomSessionTarget>[];
    final unresolved = <String>{};
    for (final member in room.activeMembers) {
      if (owedUsers.contains(member.userId)) continue;
      final devicesResult = await liveDevices.resolveAuthenticatedLiveDevices(
        member.userId,
      );
      if (devicesResult case FailureResult()) {
        unresolved.add(member.userId);
        continue;
      }
      final devices =
          (devicesResult as Success<List<RoomAuthenticatedLiveDevice>>).value
              .where((device) => device.userId == member.userId)
              .toList(growable: false)
            ..sort((left, right) => left.deviceId.compareTo(right.deviceId));
      for (final device in devices) {
        if (device.deviceId == localDevice ||
            owedDevices.contains(device.deviceId) ||
            // Rule 1: the device that sorts lower starts the session, so two
            // devices that accepted one change start one session, not two.
            (onlyAbove && device.deviceId.compareTo(localDevice) <= 0)) {
          continue;
        }
        final hasResult = await sessions.hasSession(
          localDeviceId: localDevice,
          remoteUserId: device.userId,
          remoteDeviceId: device.deviceId,
        );
        if (hasResult case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
        if ((hasResult as Success<bool>).value) continue;
        final operationId =
            'room-session:${room.roomId}:${device.deviceId}:'
            '${now.millisecondsSinceEpoch}';
        work.add(
          RoomOutboundWork(
            operationId: operationId,
            roomId: room.roomId,
            eventId: operationId,
            payload: payload,
            recipientUserIds: [device.userId],
            recipientDeviceId: device.deviceId,
          ),
        );
        started.add(
          RoomSessionTarget(userId: device.userId, deviceId: device.deviceId),
        );
      }
    }
    final recorded = await repository.recordSessionCheck(
      check: check,
      work: work,
      checkedAt: now,
    );
    if (recorded case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(
      RoomSessionCheckReport(
        roomId: room.roomId,
        started: started,
        unresolvedUserIds: unresolved,
      ),
    );
  }
}
