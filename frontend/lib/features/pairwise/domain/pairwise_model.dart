import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/device_control_model.dart';

/// Durable role assigned by the deterministic simultaneous-initiation rule.
enum PairwiseSessionDisposition { primaryBidirectional, alternateReceiveOnly }

/// Queryable projection of repair state authenticated inside the opaque state.
enum PairwiseRepairState {
  ready,
  repairRequired,
  authenticatedRequestPending,
  replacementPending,
}

enum PairwiseOneTimePrekeyKind { classicalX25519, postQuantumMlKem768 }

final class ErasedPairwiseSignedPrekeyPair {
  const ErasedPairwiseSignedPrekeyPair({
    required this.signedPrekeyId,
    required this.pqSignedPrekeyId,
  });

  final int signedPrekeyId;
  final int pqSignedPrekeyId;
}

final class PairwiseSessionSnapshot {
  PairwiseSessionSnapshot({
    required this.localDeviceId,
    required this.remoteUserId,
    required this.remoteDeviceId,
    required Uint8List sessionId,
    required Uint8List opaqueState,
    required this.stateVersion,
    required this.skippedKeyCount,
    required this.disposition,
    required this.repairState,
    Uint8List? repairAuthorization,
  }) : sessionId = Uint8List.fromList(sessionId),
       opaqueState = Uint8List.fromList(opaqueState),
       repairAuthorization = repairAuthorization == null
           ? null
           : Uint8List.fromList(repairAuthorization);

  final String localDeviceId;
  final String remoteUserId;
  final String remoteDeviceId;
  final Uint8List sessionId;
  final Uint8List opaqueState;
  final int stateVersion;
  final int skippedKeyCount;
  final PairwiseSessionDisposition disposition;
  final PairwiseRepairState repairState;
  final Uint8List? repairAuthorization;

  bool get requiresClaim =>
      disposition != PairwiseSessionDisposition.primaryBidirectional ||
      repairState == PairwiseRepairState.replacementPending;
}

/// A side-effect-free crypto result waiting for a database CAS commit.
final class PairwiseSessionTransition {
  PairwiseSessionTransition({
    required this.localDeviceId,
    required this.remoteUserId,
    required this.remoteDeviceId,
    required Uint8List sessionId,
    required Uint8List nextOpaqueState,
    required this.expectedStateVersion,
    required this.nextStateVersion,
    required this.nextSkippedKeyCount,
    required this.disposition,
    required this.repairState,
    Uint8List? repairAuthorization,
  }) : sessionId = Uint8List.fromList(sessionId),
       nextOpaqueState = Uint8List.fromList(nextOpaqueState),
       repairAuthorization = repairAuthorization == null
           ? null
           : Uint8List.fromList(repairAuthorization);

  final String localDeviceId;
  final String remoteUserId;
  final String remoteDeviceId;
  final Uint8List sessionId;
  final Uint8List nextOpaqueState;

  /// Null creates a session. Otherwise the stored row must have this revision.
  final int? expectedStateVersion;
  final int nextStateVersion;
  final int nextSkippedKeyCount;
  final PairwiseSessionDisposition disposition;
  final PairwiseRepairState repairState;
  final Uint8List? repairAuthorization;
}

final class PairwiseDeviceStateSnapshot {
  PairwiseDeviceStateSnapshot({
    required Uint8List opaqueState,
    required this.stateVersion,
  }) : opaqueState = Uint8List.fromList(opaqueState);

  final Uint8List opaqueState;
  final int stateVersion;
}

final class PairwiseDeviceStateTransition {
  PairwiseDeviceStateTransition({
    required Uint8List nextOpaqueState,
    required this.expectedStateVersion,
    required this.nextStateVersion,
  }) : nextOpaqueState = Uint8List.fromList(nextOpaqueState);

  final Uint8List nextOpaqueState;
  final int expectedStateVersion;
  final int nextStateVersion;
}

final class ConsumedPairwiseOneTimePrekey {
  const ConsumedPairwiseOneTimePrekey({
    required this.kind,
    required this.keyId,
  });

  final PairwiseOneTimePrekeyKind kind;
  final int keyId;
}

final class PairwisePreparationContext {
  const PairwisePreparationContext({
    required this.primary,
    required this.alternate,
    required this.deviceState,
    required this.otherSessionsSkippedKeyCount,
  });

  final PairwiseSessionSnapshot? primary;
  final PairwiseSessionSnapshot? alternate;
  final PairwiseDeviceStateSnapshot deviceState;
  final int otherSessionsSkippedKeyCount;

  bool get requiresClaim => primary == null || primary!.requiresClaim;
}

final class PairwiseInboundPreparationContext {
  const PairwiseInboundPreparationContext({
    required this.session,
    required this.deviceState,
    required this.otherSessionsSkippedKeyCount,
  });

  final PairwiseSessionSnapshot? session;
  final PairwiseDeviceStateSnapshot deviceState;
  final int otherSessionsSkippedKeyCount;
}

final class PreparedPairwiseSendTarget {
  PreparedPairwiseSendTarget({
    required this.recipientUserId,
    required this.recipientDeviceId,
    required Uint8List exactCiphertext,
    required this.sessionTransition,
    this.demotedExistingSessionTransition,
  }) : exactCiphertext = Uint8List.fromList(exactCiphertext);

  final String recipientUserId;
  final String recipientDeviceId;
  final Uint8List exactCiphertext;
  final PairwiseSessionTransition sessionTransition;
  final PairwiseSessionTransition? demotedExistingSessionTransition;
}

final class PairwiseSendCommit {
  PairwiseSendCommit({
    required this.operationId,
    required this.eventId,
    required this.currentDeviceId,
    required this.expectedDeviceStateVersion,
    required Uint8List openedLocalPayload,
    required List<PreparedPairwiseSendTarget> targets,
  }) : openedLocalPayload = Uint8List.fromList(openedLocalPayload),
       targets = List.unmodifiable(targets);

  final String operationId;
  final String eventId;
  final String currentDeviceId;
  final int expectedDeviceStateVersion;
  final Uint8List openedLocalPayload;
  final List<PreparedPairwiseSendTarget> targets;
}

/// One send whose event is committed and whose recipients are still owed.
final class OwedSendPreparation {
  OwedSendPreparation({
    required this.operationId,
    required this.eventId,
    required this.currentUserId,
    required this.currentDeviceId,
    required this.peerUserId,
    Iterable<String>? audienceUserIds,
  }) : audienceUserIds = audienceUserIds == null
           ? null
           : Set.unmodifiable(
               audienceUserIds.map((userId) => userId.toLowerCase()),
             );

  final String operationId;
  final String eventId;
  final String currentUserId;
  final String currentDeviceId;
  final String peerUserId;

  /// Every user the send is for, when that is more than [peerUserId]: the
  /// members of the group the event was written into, resolved when the send
  /// is prepared rather than when it was written, so a member removed in
  /// between gets no copy. Null keeps [peerUserId] alone.
  final Set<String>? audienceUserIds;
}

final class PairwiseReceiveCommit {
  PairwiseReceiveCommit({
    required this.envelopeId,
    required this.opaqueEventId,
    required this.senderUserId,
    required this.senderDeviceId,
    required Uint8List replayMarker,
    required Uint8List openedOpaquePayload,
    required this.sessionTransition,
    this.demotedExistingSessionTransition,
    Uint8List? replacedSessionId,
    this.signedPrekeyId,
    this.pqSignedPrekeyId,
    this.deviceStateTransition,
    List<ConsumedPairwiseOneTimePrekey> consumedOneTimePrekeys = const [],
    this.applicationEvent,
    this.unsupportedApplicationEvent,
    this.deviceControlEvent,
    List<ApplicationEventCommit> historyApplicationEvents = const [],
  }) : replayMarker = Uint8List.fromList(replayMarker),
       openedOpaquePayload = Uint8List.fromList(openedOpaquePayload),
       replacedSessionId = replacedSessionId == null
           ? null
           : Uint8List.fromList(replacedSessionId),
       consumedOneTimePrekeys = List.unmodifiable(consumedOneTimePrekeys),
       historyApplicationEvents = List.unmodifiable(historyApplicationEvents);

  final String envelopeId;
  final String opaqueEventId;
  final String senderUserId;
  final String senderDeviceId;
  final Uint8List replayMarker;
  final Uint8List openedOpaquePayload;
  final PairwiseSessionTransition sessionTransition;
  final PairwiseSessionTransition? demotedExistingSessionTransition;

  /// Exact authenticated old session erased by a repair replacement.
  final Uint8List? replacedSessionId;
  final int? signedPrekeyId;
  final int? pqSignedPrekeyId;
  final PairwiseDeviceStateTransition? deviceStateTransition;
  final List<ConsumedPairwiseOneTimePrekey> consumedOneTimePrekeys;
  final ApplicationEventCommit? applicationEvent;
  final UnsupportedApplicationCommit? unsupportedApplicationEvent;
  final DeviceControlEvent? deviceControlEvent;
  final List<ApplicationEventCommit> historyApplicationEvents;
}

final class DurablePairwiseOperation {
  DurablePairwiseOperation({
    required this.operationId,
    required this.eventId,
    required this.currentDeviceId,
    required Uint8List openedLocalPayload,
    required List<DurablePairwiseTarget> targets,
  }) : openedLocalPayload = Uint8List.fromList(openedLocalPayload),
       targets = List.unmodifiable(targets);

  final String operationId;
  final String eventId;
  final String currentDeviceId;
  final Uint8List openedLocalPayload;
  final List<DurablePairwiseTarget> targets;
}

final class DurablePairwiseTarget {
  DurablePairwiseTarget({
    required this.recipientUserId,
    required this.recipientDeviceId,
    required Uint8List exactCiphertext,
  }) : exactCiphertext = Uint8List.fromList(exactCiphertext);

  final String recipientUserId;
  final String recipientDeviceId;
  final Uint8List exactCiphertext;
}

final class PairwiseLiveDevice {
  const PairwiseLiveDevice({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;
}

final class PairwisePreparedOutbound {
  PairwisePreparedOutbound({
    required Uint8List exactCiphertext,
    required Uint8List sessionId,
    required Uint8List nextOpaqueSessionState,
    required this.nextSkippedKeyCount,
    required this.disposition,
    this.repairState = PairwiseRepairState.ready,
  }) : exactCiphertext = Uint8List.fromList(exactCiphertext),
       sessionId = Uint8List.fromList(sessionId),
       nextOpaqueSessionState = Uint8List.fromList(nextOpaqueSessionState);

  final Uint8List exactCiphertext;
  final Uint8List sessionId;
  final Uint8List nextOpaqueSessionState;
  final int nextSkippedKeyCount;
  final PairwiseSessionDisposition disposition;
  final PairwiseRepairState repairState;
}
