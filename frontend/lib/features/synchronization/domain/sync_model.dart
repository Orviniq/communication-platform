import 'dart:typed_data';

import 'package:communication_platform/core/protocol/group_sync_model.dart';
import 'package:communication_platform/core/protocol/pairwise_sync_model.dart';

enum EnvelopeDependency { directOrLocal, potentiallyMls }

enum QueueGapState { clear, recoveryRequired }

enum InboxProcessingState {
  received,
  inspecting,
  readyToAcknowledge,
  acknowledgementSending,
  acknowledged,
  blockedByQueueGap,
}

enum OutboxAttemptState {
  queued,
  sending,
  retryWait,
  accepted,
  stale,
  permanentlyFailed,
  removed,
}

enum SyncConnectionPhase {
  stopped,
  offline,
  connecting,
  draining,
  online,
  reconnectWaiting,
  revoked,
  protocolCircuitOpen,
  originRejected,
}

enum NetworkAvailability { unavailable, available }

enum ApplicationExecutionState { foreground, background, detached }

enum RealtimeDisconnectKind {
  authenticationFailed,
  revoked,
  protocolViolation,
  originRejected,
  normal,
  transportLost,
}

enum RealtimeRecoveryAction {
  refreshThenReconnectOnce,
  reconnectWithBackoff,
  stopRevoked,
  openCircuit,
  stopOriginRejected,
  none,
}

final class SyncEnvelope {
  SyncEnvelope({
    required this.id,
    required this.sequence,
    this.attempt = 1,
    this.inspectionFailures = 0,
    required Uint8List exactCiphertext,
  }) : exactCiphertext = Uint8List.fromList(exactCiphertext);

  final String id;
  final int sequence;

  /// How many times this envelope has been begun, inspection and
  /// acknowledgement alike. It drives retry backoff and nothing else.
  final int attempt;

  /// How many times inspecting this envelope has failed for a cause that will
  /// not resolve itself.
  ///
  /// Separate from [attempt] because they answer different questions. [attempt]
  /// asks how long to wait; this asks whether waiting can ever help. A device
  /// that is offline, rate limited or out of storage raises [attempt] on every
  /// pass without learning anything about the envelope, so spending an attempt
  /// budget on it would quarantine messages this device could have opened.
  final int inspectionFailures;

  final Uint8List exactCiphertext;
}

final class DrainPage {
  DrainPage({
    required List<SyncEnvelope> envelopes,
    required this.hasMore,
    required this.prunedThrough,
  }) : envelopes = List.unmodifiable(envelopes);

  final List<SyncEnvelope> envelopes;
  final bool hasMore;
  final int prunedThrough;
}

final class OpaqueEnvelopeInspection {
  const OpaqueEnvelopeInspection({
    required this.opaqueEventId,
    required this.dependency,
    this.pairwiseCommit,
    this.groupCommit,
  });

  final String opaqueEventId;
  final EnvelopeDependency dependency;
  final PairwiseSyncReceiveCommit? pairwiseCommit;
  final GroupSyncReceiveCommit? groupCommit;
}

final class PreparedOutboxTarget {
  PreparedOutboxTarget({
    required this.recipientUserId,
    required this.recipientDeviceId,
    required Uint8List exactCiphertext,
  }) : exactCiphertext = Uint8List.fromList(exactCiphertext);

  final String recipientUserId;
  final String recipientDeviceId;
  final Uint8List exactCiphertext;
}

final class OutboxTarget {
  OutboxTarget({
    required this.recipientUserId,
    required this.recipientDeviceId,
    required Uint8List exactCiphertext,
  }) : exactCiphertext = Uint8List.fromList(exactCiphertext);

  final String recipientUserId;
  final String recipientDeviceId;
  final Uint8List exactCiphertext;
}

final class OutboxBatch {
  OutboxBatch({
    required this.operationId,
    required this.eventId,
    required this.batchIndex,
    required this.attempt,
    required List<OutboxTarget> targets,
  }) : targets = List.unmodifiable(targets);

  final String operationId;
  final String eventId;
  final int batchIndex;
  final int attempt;
  final List<OutboxTarget> targets;
}

/// One committed send whose per-recipient ciphertext has not been sealed yet.
///
/// It carries only what the work needs and nothing the engine could read: the
/// payload to be sealed stays in local storage, and the engine never sees it.
final class PendingSendPreparation {
  const PendingSendPreparation({
    required this.operationId,
    required this.eventId,
    required this.localUserId,
    required this.localDeviceId,
    required this.peerUserId,
    required this.attempt,
  });

  final String operationId;
  final String eventId;
  final String localUserId;
  final String localDeviceId;
  final String peerUserId;
  final int attempt;
}

/// What `POST /api/v1/envelopes` answered about one batch.
///
/// The three fields are three different outcomes for the devices named in the
/// batch, and conflating any two of them loses a message
/// (`backend/CLIENT_CONTRACT.md` §F).
final class OutboxAcceptance {
  OutboxAcceptance({
    required this.accepted,
    required Set<String> staleDeviceIds,
    Set<String> fullDeviceIds = const {},
  }) : staleDeviceIds = Set.unmodifiable(staleDeviceIds),
       fullDeviceIds = Set.unmodifiable(fullDeviceIds);

  /// How many items the server actually wrote. Neither a stale device's nor a
  /// full device's item is among them.
  final int accepted;

  /// Devices that are gone. Their sessions are dead, they leave the fan-out,
  /// and the user who owned them needs a fresh device list.
  final Set<String> staleDeviceIds;

  /// Devices that are **live** and whose mailbox has reached
  /// `mailbox_max_bytes`.
  ///
  /// Nothing about the device is wrong and nothing about the session has
  /// changed: the owner has not collected their post. The item is offered
  /// again later, and the device stays in the session set — dropping it here
  /// would silently remove a live participant from a conversation, which is
  /// exactly the failure a stale device is supposed to signal.
  final Set<String> fullDeviceIds;
}

final class AcknowledgementBatch {
  AcknowledgementBatch({
    required List<String> envelopeIds,
    required this.attempt,
  }) : envelopeIds = List.unmodifiable(envelopeIds);

  final List<String> envelopeIds;
  final int attempt;
}

final class SyncProjection {
  const SyncProjection({
    required this.connectionPhase,
    required this.queueGapState,
    required this.highestContiguousAcknowledgedSequence,
    required this.prunedThrough,
    required this.inboxDepth,
    required this.outboxDepth,
    required this.nextRetryAt,
    required this.lastSuccessfulSyncAt,
  });

  final SyncConnectionPhase connectionPhase;
  final QueueGapState queueGapState;
  final int highestContiguousAcknowledgedSequence;
  final int prunedThrough;
  final int inboxDepth;

  /// Outbound operations that have not reached the wire, counted once each.
  ///
  /// Per operation rather than per recipient device, and inclusive of sends
  /// still owed their ciphertext, because what reads this is a trigger on the
  /// depth *growing*. An echoed send that later seals three envelopes has not
  /// become three new sends, and counting rows would say it had — and a cycle
  /// asked for on the back of that would arrive to find the work it was told
  /// about already done, having paid a drain to discover it.
  final int outboxDepth;
  final DateTime? nextRetryAt;
  final DateTime? lastSuccessfulSyncAt;

  bool get isSecurityBlocked => queueGapState == QueueGapState.recoveryRequired;
}

final class DurableReconnectState {
  const DurableReconnectState({
    required this.attempt,
    required this.dueAt,
    required this.phase,
  });

  final int attempt;
  final DateTime? dueAt;
  final SyncConnectionPhase phase;
}

final class StaleDeviceRefreshWork {
  const StaleDeviceRefreshWork({required this.userId, required this.attempt});

  final String userId;
  final int attempt;
}

final class SyncRunReport {
  const SyncRunReport({
    required this.drainedPages,
    required this.inspectedEnvelopes,
    required this.acknowledgedEnvelopes,
    required this.sentTargets,
    required this.deferred,
    this.quarantinedEnvelopes = 0,
    this.failedInspections = 0,
    this.preparedSends = 0,
  });

  const SyncRunReport.alreadyRunning()
    : drainedPages = 0,
      inspectedEnvelopes = 0,
      acknowledgedEnvelopes = 0,
      sentTargets = 0,
      deferred = true,
      quarantinedEnvelopes = 0,
      failedInspections = 0,
      preparedSends = 0;

  final int drainedPages;
  final int inspectedEnvelopes;
  final int acknowledgedEnvelopes;
  final int sentTargets;
  final bool deferred;

  /// How many envelopes this run retired into quarantine. A count, and
  /// deliberately nothing else: which envelope, why, and what was in it are all
  /// identifiers, and none of them may leave the engine.
  final int quarantinedEnvelopes;

  /// How many echoed sends this run turned into sealed per-recipient ciphertext.
  final int preparedSends;

  /// How many envelopes failed inspection and were left for a later run. Also a
  /// count only, for the same reason.
  final int failedInspections;
}

final class RealtimeDisconnect {
  const RealtimeDisconnect({required this.kind, required this.action});

  final RealtimeDisconnectKind kind;
  final RealtimeRecoveryAction action;
}
