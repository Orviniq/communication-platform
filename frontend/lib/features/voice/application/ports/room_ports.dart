import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/room_sync_payload.dart';

/// The room state the rest of the application reads: the call that prompt 7
/// builds, and the screens.
///
/// A room reads as it applies to what this device may do: while a member has
/// not yet confirmed its state, an active room reads as
/// [RoomLifecycle.stateRecoveryRequired], and [RoomAuthorization.mayAct] is
/// false for it.
abstract interface class RoomStateReadPort implements RepositoryPort {
  /// Every room this device holds, in room-id order.
  Stream<List<RoomState>> watchRooms();

  Stream<RoomState?> watchRoom(String roomId);

  Future<Result<RoomState?>> readRoom(String roomId);
}

/// A room is client state (`backend/CLIENT_CONTRACT.md` §N, server ADR-0021):
/// the roster, the accepted control transcript that justifies it, the bytes
/// still owed to other devices, the state requests still open, and when its
/// sessions were last checked all live here and nowhere else.
abstract interface class RoomRepositoryPort implements RoomStateReadPort {
  /// The room exactly as stored, which is what a control event applies to.
  Future<Result<RoomState?>> readStoredRoom(String roomId);

  /// Opens a request for a room's state from [peerUserId], unless one is
  /// already open. Bounded, so a flood of unknown rooms cannot grow it.
  Future<Result<void>> openStateRequest({
    required String roomId,
    required String peerUserId,
  });

  /// Accepted control events after [afterRevision], oldest first.
  Future<Result<List<StoredRoomControl>>> readTranscript(
    String roomId, {
    int afterRevision = 0,
  });

  Future<Result<void>> commitTransition({
    required RoomState? expectedPrevious,
    required RoomState next,
    required PreparedRoomTransition prepared,
  });

  Future<Result<List<RoomOutboundWork>>> readPendingOutbound({int limit = 20});

  /// Work for [roomId] that has not reached the pairwise outbox yet.
  Future<Result<List<RoomOutboundWork>>> readPendingOutboundForRoom(
    String roomId,
  );

  Future<Result<void>> markOutboundRouted({required String operationId});

  /// Requests never sent, and requests sent before [retryBefore] that nobody
  /// has answered.
  Future<Result<List<RoomStateRequest>>> readDueStateRequests({
    required DateTime retryBefore,
    int limit = 8,
  });

  /// Records, in one transaction, that [work] asks [peerUserId] for the room's
  /// current control state.
  Future<Result<void>> recordStateRequestSent({
    required String roomId,
    required String peerUserId,
    required RoomOutboundWork work,
    required DateTime requestedAt,
  });

  /// Retires a request no member can answer, such as a gap in a room this
  /// device's account is the only active member of.
  Future<Result<void>> retireStateRequest(String roomId);

  /// Active rooms, not waiting on their state, whose session check is due: a
  /// change of rule 1 committed since the last one, or the last one was at or
  /// before [checkedBefore].
  Future<Result<List<RoomSessionCheck>>> readDueSessionChecks({
    required DateTime checkedBefore,
    int limit = 4,
  });

  /// Commits the session-start requests one check produced, and records the
  /// check as done unless the room moved past [check]'s state meanwhile.
  Future<Result<void>> recordSessionCheck({
    required RoomSessionCheck check,
    required List<RoomOutboundWork> work,
    required DateTime checkedAt,
  });
}

/// The reviewed native core's room control operations.
abstract interface class RoomControlCryptoPort implements Port {
  /// Encodes [event] as deterministic CBOR and signs it with this device's
  /// signing key, under the room's own signing domain.
  Future<Result<SignedRoomControlEvent>> seal(RoomControlEvent event);

  /// Verifies [control] under [signerSigningPublic], the key authenticated for
  /// the device [control] names, and decodes it. A signature that does not
  /// verify is a `SecurityFailure` of kind `unauthenticatedInput`.
  Future<Result<SignedRoomControlEvent>> open({
    required RoomSignedControlBytes control,
    required Uint8List signerSigningPublic,
  });
}

abstract interface class RoomIdentityPort implements Port {
  /// Sixteen bytes from the native core's CSPRNG.
  Future<Result<Uint8List>> randomIdentifier();
}

/// The existing pairwise fan-out, which seals one durable envelope for each
/// target device and starts a session with any device that has none.
abstract interface class RoomOutboundEnvelopePort implements Port {
  Future<Result<void>> prepareAndQueue({
    required String operationId,
    required String eventId,
    required String currentUserId,
    required String currentDeviceId,
    required String targetUserId,
    required Uint8List payload,
    required bool includeOwnDevices,
    String? onlyRecipientDeviceId,
  });
}

abstract interface class RoomLiveDeviceResolverPort implements Port {
  Future<Result<List<RoomAuthenticatedLiveDevice>>>
  resolveAuthenticatedLiveDevices(String userId);
}

/// Whether this device already shares a pairwise session with another one.
abstract interface class RoomPairwiseSessionPort implements Port {
  /// True when a primary session exists, whatever its repair state: a session
  /// under repair belongs to the repair path, which the durable queue carries.
  Future<Result<bool>> hasSession({
    required String localDeviceId,
    required String remoteUserId,
    required String remoteDeviceId,
  });
}

/// Starts the authenticated repair of this device's pairwise sessions with one
/// user's devices.
abstract interface class RoomSessionRepairPort implements Port {
  /// Returns how many sessions a repair was requested for.
  Future<Result<int>> requestRepairWithUser({
    required String localDeviceId,
    required String remoteUserId,
  });
}
