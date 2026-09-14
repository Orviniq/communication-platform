import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/domain/group_sync_payload.dart';

/// A group is client state (`backend/CLIENT_CONTRACT.md` §F): the roster, the
/// accepted control transcript that justifies it, the bytes still owed to other
/// devices, and the state requests still open all live here and nowhere else.
abstract interface class GroupRepositoryPort {
  Stream<GroupState?> watchGroup(String groupId);

  Stream<List<GroupMessage>> watchMessages(String groupId);

  /// The copies still owed for this device's own messages in a group, by
  /// message id. A message is absent before its copies exist and after the
  /// last of them has settled.
  Stream<Map<String, GroupFanoutProgress>> watchFanoutProgress(String groupId);

  /// The group as the screens see it: while a member has not yet confirmed
  /// its state, an active group reads as
  /// [GroupLifecycle.stateRecoveryRequired].
  Future<Result<GroupState?>> readGroup(String groupId);

  /// The group exactly as stored, which is what a control event applies to.
  Future<Result<GroupState?>> readStoredGroup(String groupId);

  /// Opens a request for a group's state from [peerUserId], unless one is
  /// already open. Bounded, so a flood of unknown groups cannot grow it.
  Future<Result<void>> openStateRequest({
    required String groupId,
    required String peerUserId,
  });

  /// Accepted control events after [afterRevision], oldest first.
  Future<Result<List<StoredGroupControl>>> readTranscript(
    String groupId, {
    int afterRevision = 0,
  });

  Future<Result<void>> commitTransition({
    required GroupState? expectedPrevious,
    required GroupState next,
    required PreparedGroupTransition prepared,
  });

  Future<Result<List<GroupOutboundWork>>> readPendingOutbound({int limit = 20});

  Future<Result<void>> markOutboundRouted({required String operationId});

  /// Requests never sent, and requests sent before [retryBefore] that nobody
  /// has answered.
  Future<Result<List<GroupStateRequest>>> readDueStateRequests({
    required DateTime retryBefore,
    int limit = 8,
  });

  /// Records, in one transaction, that [work] asks [peerUserId] for the
  /// group's current control state.
  Future<Result<void>> recordStateRequestSent({
    required String groupId,
    required String peerUserId,
    required GroupOutboundWork work,
    required DateTime requestedAt,
  });

  /// Retires a request no member can answer, such as a gap in a group this
  /// device is the only active member of.
  Future<Result<void>> retireStateRequest(String groupId);
}

/// The reviewed native core's group control operations.
abstract interface class GroupControlCryptoPort implements Port {
  /// Encodes [event] as deterministic CBOR and signs it with this device's
  /// signing key.
  Future<Result<SignedGroupControlEvent>> seal(GroupControlEvent event);

  /// Verifies [control] under [signerSigningPublic], the key authenticated for
  /// the device [control] names, and decodes it.
  Future<Result<SignedGroupControlEvent>> open({
    required GroupSignedControlBytes control,
    required Uint8List signerSigningPublic,
  });
}

abstract interface class GroupIdentityPort implements Port {
  /// Sixteen bytes from the native core's CSPRNG.
  Future<Result<Uint8List>> randomIdentifier();
}

abstract interface class GroupOutboundEnvelopePort {
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

abstract interface class GroupLiveDeviceResolverPort implements Port {
  Future<Result<List<GroupAuthenticatedLiveDevice>>>
  resolveAuthenticatedLiveDevices(String userId);
}

/// Sends an ordinary application message into a group's conversation.
///
/// The message is the same deterministic-CBOR application event a direct
/// message is, with the group's identifier as its conversation, so it takes
/// the same durable path to the wire: a local echo, then one pairwise copy for
/// every live device of every member.
abstract interface class GroupMessageSenderPort implements Port {
  Future<Result<void>> sendText({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String text,
  });

  /// Puts a message the user was told had failed back on its way, as the same
  /// message rather than a second one beside it.
  Future<Result<void>> retryText({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String messageId,
    required String text,
  });
}

/// Starts the authenticated repair of this device's pairwise sessions with one
/// user's devices.
abstract interface class GroupSessionRepairPort implements Port {
  /// Returns how many sessions a repair was requested for.
  Future<Result<int>> requestRepairWithUser({
    required String localDeviceId,
    required String remoteUserId,
  });
}
