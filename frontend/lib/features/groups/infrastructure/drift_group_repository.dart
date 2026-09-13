import 'dart:convert';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/drift_repository_base.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:drift/drift.dart';

/// Drift storage for groups built on pairwise sessions.
///
/// The roster is client state. [GroupStates] holds this device's projection of
/// each group, its member set included, and [GroupControlEvents] holds the
/// signed transcript that justifies it, byte for byte, so this device can hand
/// it to a member who needs it.
final class DriftGroupRepository extends DriftRepositoryBase
    implements GroupRepositoryPort {
  const DriftGroupRepository(super.database);

  /// Bounds the open requests a stream of control events for groups this
  /// device does not know could create.
  static const maximumStateRequests = 64;

  static const _reasonQueueGap = 0;
  static const _reasonBehind = 1;
  static const _deliveryPending = 1;
  static const _deliveryRouted = 2;

  static const _stateQuery =
      'SELECT g.control_projection_ciphertext AS projection, '
      'EXISTS (SELECT 1 FROM group_state_requests r '
      'WHERE r.group_id = g.group_id) AS pending '
      'FROM group_states g WHERE g.group_id = ?';

  @override
  Stream<GroupState?> watchGroup(String groupId) => database
      .customSelect(
        _stateQuery,
        variables: [Variable<String>(groupId)],
        readsFrom: {database.groupStates, database.groupStateRequests},
      )
      .watchSingleOrNull()
      .map((row) => row == null ? null : _projectedState(row));

  @override
  Stream<List<GroupMessage>> watchMessages(String groupId) {
    final query = database.select(database.messages)
      ..where((row) => row.conversationId.equals(groupId))
      ..orderBy([
        (row) => OrderingTerm.asc(row.orderingMs),
        (row) => OrderingTerm.asc(row.orderingEventId),
      ]);
    return query.watch().map(
      (rows) => List.unmodifiable(
        rows
            .where((row) => !row.deletedForMe)
            .map(
              (row) => GroupMessage(
                messageId: row.messageId,
                groupId: row.conversationId,
                senderUserId: row.senderUserId,
                text: row.deletedForEveryone
                    ? ''
                    : utf8.decode(
                        row.projectionCiphertext,
                        allowMalformed: false,
                      ),
                createdMs: row.createdAt.millisecondsSinceEpoch,
                localPreviewOnly:
                    row.status == MessageTransportState.localOnly.index,
              ),
            ),
      ),
    );
  }

  @override
  Future<Result<GroupState?>> readGroup(String groupId) async {
    try {
      final row = await database
          .customSelect(
            _stateQuery,
            variables: [Variable<String>(groupId)],
            readsFrom: {database.groupStates, database.groupStateRequests},
          )
          .getSingleOrNull();
      return Result.success(row == null ? null : _projectedState(row));
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<GroupState?>> readStoredGroup(String groupId) async {
    try {
      final row = await (database.select(
        database.groupStates,
      )..where((item) => item.groupId.equals(groupId))).getSingleOrNull();
      return Result.success(
        row == null ? null : _decodeState(row.controlProjectionCiphertext),
      );
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> openStateRequest({
    required String groupId,
    required String peerUserId,
  }) => _runGroupWrite(
    () => recordStateRequestInsideTransaction(
      groupId: groupId,
      peerUserId: peerUserId,
    ),
  );

  @override
  Future<Result<List<StoredGroupControl>>> readTranscript(
    String groupId, {
    int afterRevision = 0,
  }) async {
    if (afterRevision < 0) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final rows =
          await (database.select(database.groupControlEvents)
                ..where(
                  (row) =>
                      row.groupId.equals(groupId) &
                      row.revision.isBiggerThanValue(afterRevision),
                )
                ..orderBy([(row) => OrderingTerm.asc(row.revision)]))
              .get();
      final transcript = <StoredGroupControl>[];
      for (final row in rows) {
        final entry = StoredGroupControl(
          eventId: row.eventId,
          revision: row.revision,
          previousControlStateHash: row.previousControlStateHash == null
              ? null
              : protocolBytesToHex(row.previousControlStateHash!),
          controlStateHash: protocolBytesToHex(row.controlStateHash),
          signerUserId: row.signerUserId,
          signerDeviceId: row.signerDeviceId,
          canonicalBytes: row.canonicalControl,
          signature: row.signature,
        );
        // Storage is trusted to be the device's own, not to be intact. A row
        // that does not continue the chain before it is a transcript nobody
        // may be handed.
        final previous = transcript.isEmpty ? null : transcript.last;
        if (entry.revision != (previous?.revision ?? afterRevision) + 1 ||
            (previous != null &&
                entry.previousControlStateHash != previous.controlStateHash)) {
          throw const FormatException('broken stored group transcript');
        }
        transcript.add(entry);
      }
      return Result.success(List.unmodifiable(transcript));
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> commitTransition({
    required GroupState? expectedPrevious,
    required GroupState next,
    required PreparedGroupTransition prepared,
  }) => _runGroupWrite(
    () => commitTransitionInsideTransaction(
      expectedPrevious: expectedPrevious,
      next: next,
      prepared: prepared,
    ),
  );

  /// Commits a run of accepted control events, the state they lead to, and
  /// the bytes they owe, with a compare-and-swap against [expectedPrevious].
  ///
  /// Also joins the durable inbox transaction, so a received event and the
  /// pairwise receive that carried it commit as one.
  Future<void> commitTransitionInsideTransaction({
    required GroupState? expectedPrevious,
    required GroupState next,
    required PreparedGroupTransition prepared,
  }) async {
    final first = prepared.first.event;
    final last = prepared.last;
    if (last.event.groupId != next.groupId ||
        last.event.revision != next.controlRevision ||
        last.controlStateHash != next.controlStateHash ||
        (expectedPrevious == null
            ? first.revision != 1
            : expectedPrevious.groupId != next.groupId ||
                  first.revision != expectedPrevious.controlRevision + 1 ||
                  first.previousControlStateHash !=
                      expectedPrevious.controlStateHash)) {
      throw const _GroupIntegrityFailure();
    }

    final current = await (database.select(
      database.groupStates,
    )..where((row) => row.groupId.equals(next.groupId))).getSingleOrNull();
    if (expectedPrevious == null) {
      if (current != null) throw const _GroupConflict();
      await database
          .into(database.groupStates)
          .insert(
            GroupStatesCompanion.insert(
              groupId: next.groupId,
              stateVersion: 1,
              controlProjectionCiphertext: _encodeState(next),
              controlRevision: next.controlRevision,
              controlStateHash: _hexBytes(next.controlStateHash),
              lifecycle: next.lifecycle.index,
            ),
          );
    } else {
      if (current == null ||
          current.controlRevision != expectedPrevious.controlRevision ||
          protocolBytesToHex(current.controlStateHash) !=
              expectedPrevious.controlStateHash) {
        throw const _GroupConflict();
      }
      final updated =
          await (database.update(database.groupStates)..where(
                (row) =>
                    row.groupId.equals(next.groupId) &
                    row.stateVersion.equals(current.stateVersion),
              ))
              .write(
                GroupStatesCompanion(
                  stateVersion: Value(current.stateVersion + 1),
                  controlProjectionCiphertext: Value(_encodeState(next)),
                  controlRevision: Value(next.controlRevision),
                  controlStateHash: Value(_hexBytes(next.controlStateHash)),
                  lifecycle: Value(next.lifecycle.index),
                ),
              );
      if (updated != 1) throw const _GroupConflict();
    }
    await _writeConversation(next, sortKey: last.event.createdMs);
    for (final control in prepared.controls) {
      final event = control.event;
      await database
          .into(database.groupControlEvents)
          .insert(
            GroupControlEventsCompanion.insert(
              eventId: event.eventId,
              groupId: event.groupId,
              revision: event.revision,
              previousControlStateHash: Value(
                event.previousControlStateHash == null
                    ? null
                    : _hexBytes(event.previousControlStateHash!),
              ),
              controlStateHash: _hexBytes(control.controlStateHash),
              signerUserId: event.signerUserId,
              signerDeviceId: event.signerDeviceId,
              operationKind: event.operation.kind.wireValue,
              canonicalControl: control.canonicalBytes,
              signature: control.signature,
              createdMs: event.createdMs,
            ),
          );
    }
    for (final work in prepared.outbound) {
      await queueOutboundInsideTransaction(work);
    }
    if (prepared.completesStateRequest) {
      await completeStateRequestInsideTransaction(next.groupId);
    }
  }

  Future<void> _writeConversation(
    GroupState state, {
    required int sortKey,
  }) async {
    final title = Value(Uint8List.fromList(utf8.encode(state.metadata.name)));
    final existing =
        await (database.select(database.conversations)
              ..where((row) => row.conversationId.equals(state.groupId)))
            .getSingleOrNull();
    if (existing == null) {
      await database
          .into(database.conversations)
          .insert(
            ConversationsCompanion.insert(
              conversationId: state.groupId,
              kind: ConversationKind.group.index,
              listProjectionCiphertext: Uint8List(0),
              sortKey: sortKey,
              displayTitleCiphertext: title,
            ),
          );
      return;
    }
    if (existing.kind != ConversationKind.group.index) {
      throw const _GroupIntegrityFailure();
    }
    await (database.update(
      database.conversations,
    )..where((row) => row.conversationId.equals(state.groupId))).write(
      ConversationsCompanion(
        displayTitleCiphertext: title,
        sortKey: Value(sortKey > existing.sortKey ? sortKey : existing.sortKey),
      ),
    );
  }

  /// Records a rejected control event. Only a fork moves the group into
  /// quarantine; see [PreparedGroupInboxQuarantine.retainLifecycle].
  Future<void> quarantineInsideTransaction(
    GroupQuarantineRecord record, {
    required bool retainLifecycle,
    bool completesStateRequest = false,
  }) async {
    if (!retainLifecycle) {
      final row =
          await (database.select(database.groupStates)
                ..where((item) => item.groupId.equals(record.groupId)))
              .getSingleOrNull();
      if (row == null) throw const _GroupIntegrityFailure();
      final lifecycle = record.reason == GroupQuarantineReason.siblingControl
          ? GroupLifecycle.forkQuarantined
          : GroupLifecycle.controlQuarantined;
      final quarantined = _decodeState(
        row.controlProjectionCiphertext,
      ).copyWith(lifecycle: lifecycle, quarantineReason: record.reason);
      await (database.update(
        database.groupStates,
      )..where((item) => item.groupId.equals(record.groupId))).write(
        GroupStatesCompanion(
          stateVersion: Value(row.stateVersion + 1),
          controlProjectionCiphertext: Value(_encodeState(quarantined)),
          lifecycle: Value(lifecycle.index),
        ),
      );
    }
    await database
        .into(database.quarantineRecords)
        .insert(
          QuarantineRecordsCompanion.insert(
            reasonCode: 32 + record.reason.index,
            opaqueDigest: record.opaqueDigest,
            receivedAt: Value(record.receivedAt.toUtc()),
          ),
        );
    if (completesStateRequest) {
      await completeStateRequestInsideTransaction(record.groupId);
    }
  }

  /// Retires a group's open request when a member confirmed the state this
  /// device holds. A state that moved on after the answer was read keeps its
  /// request, and a later answer decides.
  Future<void> confirmStateCurrentInsideTransaction({
    required String groupId,
    required int controlRevision,
    required String controlStateHash,
  }) async {
    final row = await (database.select(
      database.groupStates,
    )..where((item) => item.groupId.equals(groupId))).getSingleOrNull();
    if (row == null ||
        row.controlRevision != controlRevision ||
        protocolBytesToHex(row.controlStateHash) != controlStateHash) {
      return;
    }
    await completeStateRequestInsideTransaction(groupId);
  }

  Future<void> queueOutboundInsideTransaction(GroupOutboundWork work) async {
    // A repeated request for the same state is answered once.
    await database
        .into(database.groupOutboundObjects)
        .insert(
          GroupOutboundObjectsCompanion.insert(
            operationId: work.operationId,
            groupId: work.groupId,
            eventId: work.eventId,
            payload: work.payload,
            recipientUserIdsJson: jsonEncode(work.recipientUserIds),
            recipientDeviceId: Value(work.recipientDeviceId),
            includeOwnDevices: Value(work.includeOwnDevices),
            deliveryState: _deliveryPending,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  /// Opens a request for a group's state after an event that builds on state
  /// this device does not hold. An open request, gap or not, is left alone.
  Future<void> recordStateRequestInsideTransaction({
    required String groupId,
    required String peerUserId,
  }) async {
    final existing = await (database.select(
      database.groupStateRequests,
    )..where((row) => row.groupId.equals(groupId))).getSingleOrNull();
    if (existing != null) return;
    final count = database.groupStateRequests.groupId.count();
    final open = await (database.selectOnly(
      database.groupStateRequests,
    )..addColumns([count])).map((row) => row.read(count) ?? 0).getSingle();
    if (open >= maximumStateRequests) return;
    await database
        .into(database.groupStateRequests)
        .insert(
          GroupStateRequestsCompanion.insert(
            groupId: groupId,
            reason: _reasonBehind,
            peerUserId: Value(peerUserId.toLowerCase()),
          ),
        );
  }

  /// Marks every active group as possibly affected by a mailbox gap: a lost
  /// envelope may have carried any group's control event.
  ///
  /// A group this device was removed from, left, or holds in quarantine is not
  /// flagged. No member's answer could change it, so flagging it would hold
  /// the gap open for good. With no group to ask, the gap closes at once.
  Future<void> recordQueueGapInsideTransaction() async {
    final rows = await (database.select(
      database.groupStates,
    )..where((row) => row.lifecycle.equals(GroupLifecycle.active.index))).get();
    for (final row in rows) {
      await database
          .into(database.groupStateRequests)
          .insertOnConflictUpdate(
            GroupStateRequestsCompanion.insert(
              groupId: row.groupId,
              reason: _reasonQueueGap,
            ),
          );
    }
    await _acknowledgeSettledQueueGapInsideTransaction();
  }

  /// Retires a group's open request. When it was the last one a mailbox gap
  /// was holding open, the gap closes.
  Future<void> completeStateRequestInsideTransaction(String groupId) async {
    final existing = await (database.select(
      database.groupStateRequests,
    )..where((row) => row.groupId.equals(groupId))).getSingleOrNull();
    if (existing == null) return;
    await (database.delete(
      database.groupStateRequests,
    )..where((row) => row.groupId.equals(groupId))).go();
    if (existing.reason != _reasonQueueGap) return;
    await _acknowledgeSettledQueueGapInsideTransaction();
  }

  /// Acknowledges a mailbox gap once no group waits on a member's answer.
  ///
  /// The loss is permanent, so the baseline advances through the observed
  /// `pruned_through` and the same gap cannot reopen on every drain. Nothing
  /// waited for the gap to close, so envelopes above it may already be
  /// acknowledged; they leave the inbox exactly as an acknowledgement would
  /// have let them if the baseline had been there.
  Future<void> _acknowledgeSettledQueueGapInsideTransaction() async {
    final count = database.groupStateRequests.groupId.count();
    final remaining =
        await (database.selectOnly(database.groupStateRequests)
              ..addColumns([count])
              ..where(
                database.groupStateRequests.reason.equals(_reasonQueueGap),
              ))
            .map((row) => row.read(count) ?? 0)
            .getSingle();
    if (remaining != 0) return;
    final checkpoint = await (database.select(
      database.syncCheckpoints,
    )..where((row) => row.singletonId.equals(1))).getSingleOrNull();
    if (checkpoint == null ||
        checkpoint.queueGapState == QueueGapState.clear.index) {
      return;
    }
    var contiguous =
        checkpoint.prunedThrough > checkpoint.highestContiguousAckedSequence
        ? checkpoint.prunedThrough
        : checkpoint.highestContiguousAckedSequence;
    final acknowledged =
        await (database.select(database.inboxEnvelopes)
              ..where(
                (row) =>
                    row.processingState.equals(
                      InboxProcessingState.acknowledged.index,
                    ) &
                    row.sequence.isBiggerThanValue(contiguous),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.sequence)]))
            .get();
    for (final row in acknowledged) {
      if (row.sequence != contiguous + 1) break;
      contiguous = row.sequence;
    }
    await (database.update(
      database.syncCheckpoints,
    )..where((row) => row.singletonId.equals(1))).write(
      SyncCheckpointsCompanion(
        highestContiguousAckedSequence: Value(contiguous),
        queueGapState: Value(QueueGapState.clear.index),
        drainRequested: const Value(true),
      ),
    );
    await (database.delete(database.inboxEnvelopes)..where(
          (row) =>
              row.processingState.equals(
                InboxProcessingState.acknowledged.index,
              ) &
              row.sequence.isSmallerOrEqualValue(contiguous),
        ))
        .go();
  }

  @override
  Future<Result<List<GroupOutboundWork>>> readPendingOutbound({
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 100) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final query = database.select(database.groupOutboundObjects)
        ..where((row) => row.deliveryState.equals(_deliveryPending))
        ..orderBy([
          (row) => OrderingTerm.asc(row.createdAt),
          (row) => OrderingTerm.asc(row.operationId),
        ])
        ..limit(limit);
      final rows = await query.get();
      return Result.success([
        for (final row in rows)
          GroupOutboundWork(
            operationId: row.operationId,
            groupId: row.groupId,
            eventId: row.eventId,
            payload: row.payload,
            recipientUserIds: _decodeRecipientUserIds(row.recipientUserIdsJson),
            recipientDeviceId: row.recipientDeviceId,
            includeOwnDevices: row.includeOwnDevices,
          ),
      ]);
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> markOutboundRouted({required String operationId}) async {
    if (operationId.isEmpty) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final current = await (database.select(
        database.groupOutboundObjects,
      )..where((row) => row.operationId.equals(operationId))).getSingleOrNull();
      if (current == null) {
        return const Result.failure(
          ValidationFailure(ValidationFailureKind.conflict),
        );
      }
      if (current.deliveryState == _deliveryRouted) {
        return const Result.success(null);
      }
      final updated =
          await (database.update(database.groupOutboundObjects)..where(
                (row) =>
                    row.operationId.equals(operationId) &
                    row.deliveryState.equals(_deliveryPending),
              ))
              .write(
                const GroupOutboundObjectsCompanion(
                  deliveryState: Value(_deliveryRouted),
                ),
              );
      return updated == 1
          ? const Result.success(null)
          : const Result.failure(
              ValidationFailure(ValidationFailureKind.conflict),
            );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<List<GroupStateRequest>>> readDueStateRequests({
    required DateTime retryBefore,
    int limit = 8,
  }) async {
    if (limit < 1 || limit > maximumStateRequests) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final rows =
          await (database.select(database.groupStateRequests)
                ..where(
                  (row) =>
                      row.requestedAt.isNull() |
                      row.requestedAt.isSmallerOrEqualValue(retryBefore),
                )
                ..orderBy([
                  (row) => OrderingTerm.asc(row.createdAt),
                  (row) => OrderingTerm.asc(row.groupId),
                ])
                ..limit(limit))
              .get();
      return Result.success([
        for (final row in rows)
          GroupStateRequest(
            groupId: row.groupId,
            reason: row.reason == _reasonQueueGap
                ? GroupStateRequestReason.queueGap
                : GroupStateRequestReason.behind,
            peerUserId: row.peerUserId,
            attempts: row.attempts,
            requestedAt: row.requestedAt,
          ),
      ]);
    } on FormatException {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> recordStateRequestSent({
    required String groupId,
    required String peerUserId,
    required GroupOutboundWork work,
    required DateTime requestedAt,
  }) => _runGroupWrite(() async {
    final existing = await (database.select(
      database.groupStateRequests,
    )..where((row) => row.groupId.equals(groupId))).getSingleOrNull();
    if (existing == null || work.groupId != groupId) {
      throw const _GroupConflict();
    }
    await (database.update(
      database.groupStateRequests,
    )..where((row) => row.groupId.equals(groupId))).write(
      GroupStateRequestsCompanion(
        peerUserId: Value(peerUserId.toLowerCase()),
        attempts: Value(existing.attempts + 1),
        requestedAt: Value(requestedAt.toUtc()),
      ),
    );
    await queueOutboundInsideTransaction(work);
  });

  @override
  Future<Result<void>> retireStateRequest(String groupId) =>
      _runGroupWrite(() => completeStateRequestInsideTransaction(groupId));

  Future<Result<void>> _runGroupWrite(Future<void> Function() operation) async {
    try {
      await database.writeTransaction(operation);
      return const Result.success(null);
    } on _GroupConflict {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    } on _GroupIntegrityFailure {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  GroupState _projectedState(QueryRow row) {
    final state = _decodeState(row.read<Uint8List>('projection'));
    // An open request means a member has not yet confirmed this roster. The
    // group stays readable and its stored lifecycle is untouched, but nothing
    // may be sent to a member set that may be stale.
    return row.read<bool>('pending') && state.lifecycle == GroupLifecycle.active
        ? state.copyWith(lifecycle: GroupLifecycle.stateRecoveryRequired)
        : state;
  }
}

List<String> _decodeRecipientUserIds(String input) {
  final decoded = jsonDecode(input);
  if (decoded is! List<Object?>) {
    throw const FormatException('invalid group outbound recipients');
  }
  final values = [
    for (final value in decoded)
      if (value is String && value.isNotEmpty && value == value.toLowerCase())
        value
      else
        throw const FormatException('invalid group outbound recipient'),
  ];
  if (values.toSet().length != values.length) {
    throw const FormatException('duplicate group outbound recipient');
  }
  return values;
}

Uint8List _encodeState(GroupState state) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'group_id': state.groupId,
      'metadata': {
        'name': state.metadata.name,
        'description': state.metadata.description,
      },
      'invite': state.invitationPolicy.index,
      'history': state.historySharingPolicy.index,
      'members': [
        for (final member in state.members)
          {
            'user_id': member.userId,
            'name': member.displayName,
            'role': member.role.index,
            'membership': member.membership.index,
            'verified': member.verified,
          },
      ],
      'revision': state.controlRevision,
      'hash': state.controlStateHash,
      'lifecycle': state.lifecycle.index,
      'quarantine': state.quarantineReason?.index,
    }),
  ),
);

GroupState _decodeState(Uint8List bytes) {
  final value = _map(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
  final metadata = _map(value['metadata']);
  final quarantine = value['quarantine'];
  return GroupState(
    groupId: _string(value['group_id']),
    metadata: GroupMetadata(
      name: _string(metadata['name']),
      description: _string(metadata['description']),
    ),
    invitationPolicy: _enum(GroupInvitationPolicy.values, value['invite']),
    historySharingPolicy: _enum(
      GroupHistorySharingPolicy.values,
      value['history'],
    ),
    members: [
      for (final member in _list(value['members'])) _decodeMember(_map(member)),
    ],
    controlRevision: _integer(value['revision']),
    controlStateHash: _string(value['hash']),
    lifecycle: _enum(GroupLifecycle.values, value['lifecycle']),
    quarantineReason: quarantine == null
        ? null
        : _enum(GroupQuarantineReason.values, quarantine),
  );
}

GroupMember _decodeMember(Map<String, Object?> value) {
  final verified = value['verified'];
  if (verified is! bool) {
    throw const FormatException('invalid member projection');
  }
  return GroupMember(
    userId: _string(value['user_id']),
    displayName: _string(value['name']),
    role: _enum(GroupRole.values, value['role']),
    membership: _enum(GroupMembershipState.values, value['membership']),
    verified: verified,
  );
}

Map<String, Object?> _map(Object? value) => value is Map<String, Object?>
    ? value
    : throw const FormatException('invalid group projection');

List<Object?> _list(Object? value) => value is List<Object?>
    ? value
    : throw const FormatException('invalid group projection');

String _string(Object? value) => value is String
    ? value
    : throw const FormatException('invalid group projection');

int _integer(Object? value) => value is int
    ? value
    : throw const FormatException('invalid group projection');

T _enum<T>(List<T> values, Object? value) {
  final index = _integer(value);
  if (index < 0 || index >= values.length) {
    throw const FormatException('invalid group projection');
  }
  return values[index];
}

Uint8List _hexBytes(String value) {
  if (value.length.isOdd || !RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
    throw const FormatException('invalid hexadecimal value');
  }
  return Uint8List.fromList([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
}

final class _GroupConflict implements Exception {
  const _GroupConflict();
}

final class _GroupIntegrityFailure implements Exception {
  const _GroupIntegrityFailure();
}
