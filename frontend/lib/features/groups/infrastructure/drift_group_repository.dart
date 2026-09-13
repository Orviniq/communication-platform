import 'dart:convert';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/drift_repository_base.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:drift/drift.dart';

final class DriftGroupRepository extends DriftRepositoryBase
    implements GroupRepositoryPort, GroupControlTranscriptPort {
  const DriftGroupRepository(super.database);

  @override
  Stream<GroupState?> watchGroup(String groupId) {
    final query = database.select(database.mlsGroups)
      ..where((row) => row.groupId.equals(groupId));
    return query.watchSingleOrNull().map((row) {
      if (row == null || row.controlProjectionCiphertext == null) return null;
      return _overlayQueueGap(
        _decodeState(row.controlProjectionCiphertext!),
        row.queueGapRecoveryState,
      );
    });
  }

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
      final row = await (database.select(
        database.mlsGroups,
      )..where((item) => item.groupId.equals(groupId))).getSingleOrNull();
      if (row == null || row.controlProjectionCiphertext == null) {
        return const Result.success(null);
      }
      return Result.success(
        _overlayQueueGap(
          _decodeState(row.controlProjectionCiphertext!),
          row.queueGapRecoveryState,
        ),
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
  Future<Result<List<GroupControlTranscriptEntry>>> readVerifiedTranscript(
    String groupId,
  ) async {
    try {
      final rows =
          await (database.select(database.groupControlEvents)
                ..where((row) => row.groupId.equals(groupId))
                ..orderBy([(row) => OrderingTerm.asc(row.revision)]))
              .get();
      final transcript = <GroupControlTranscriptEntry>[];
      for (final row in rows) {
        final projection = row.deterministicProjection;
        final signedPayload = row.signedPayload;
        final signerProof = row.signerAuthenticationProof;
        if (projection == null ||
            signedPayload == null ||
            signerProof == null) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.integrityCheckFailed),
          );
        }
        final event = GroupControlEvent.fromDeterministicProjection(projection);
        if (event.groupId != row.groupId ||
            event.eventId != row.eventId ||
            event.revision != row.revision ||
            event.mlsEpoch != row.epoch ||
            event.signerUserId != row.signerUserId ||
            event.signerDeviceId != row.signerDeviceId ||
            event.operation.code != row.operationKind ||
            event.previousControlStateHash !=
                _optionalHex(row.previousControlStateHash) ||
            event.mlsCommitHash != _optionalHex(row.mlsCommitHash)) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.integrityCheckFailed),
          );
        }
        transcript.add(
          GroupControlTranscriptEntry(
            signedControl: SignedGroupControlEvent(
              event: event,
              controlStateHash: _bytesHex(row.controlStateHash),
              canonicalBytes: row.canonicalControl,
              signature: row.signature,
            ),
            signedPayload: signedPayload,
            signerAuthenticationProof: signerProof,
          ),
        );
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
    required bool developmentPreviewOnly,
  }) => _runGroupWrite(
    () => commitTransitionInsideTransaction(
      expectedPrevious: expectedPrevious,
      next: next,
      prepared: prepared,
      developmentPreviewOnly: developmentPreviewOnly,
    ),
  );

  /// Used only by the durable inbox transaction after pairwise preparation.
  Future<void> commitTransitionInsideTransaction({
    required GroupState? expectedPrevious,
    required GroupState next,
    required PreparedGroupTransition prepared,
    required bool developmentPreviewOnly,
  }) async {
    final event = prepared.signedControl.event;
    if (event.groupId != next.groupId ||
        prepared.signedControl.controlStateHash != next.controlStateHash ||
        event.revision != next.controlRevision) {
      throw const _GroupIntegrityFailure();
    }
    _validateControlTranscript(expectedPrevious, prepared);

    if (expectedPrevious == null) {
      final existing = await (database.select(
        database.mlsGroups,
      )..where((row) => row.groupId.equals(next.groupId))).getSingleOrNull();
      if (existing != null) throw const _GroupConflict();
      await database
          .into(database.conversations)
          .insert(
            ConversationsCompanion.insert(
              conversationId: next.groupId,
              kind: ConversationKind.group.index,
              listProjectionCiphertext: Uint8List(0),
              sortKey: event.createdMs,
              displayTitleCiphertext: Value(
                Uint8List.fromList(utf8.encode(next.metadata.name)),
              ),
            ),
          );
      await database
          .into(database.mlsGroups)
          .insert(
            MlsGroupsCompanion.insert(
              groupId: next.groupId,
              acceptedEpoch: next.acceptedEpoch,
              stateVersion: 1,
              controlProjectionCiphertext: Value(_encodeState(next)),
              controlRevision: Value(next.controlRevision),
              controlStateHash: Value(_hexBytes(next.controlStateHash)),
              lifecycle: Value(next.lifecycle.index),
            ),
          );
    } else {
      final previousHash = _hexBytes(expectedPrevious.controlStateHash);
      final current =
          await (database.select(database.mlsGroups)..where(
                (row) =>
                    row.groupId.equals(next.groupId) &
                    row.controlRevision.equals(
                      expectedPrevious.controlRevision,
                    ),
              ))
              .getSingleOrNull();
      // A queue-gapped group has no usable parent epoch, so no control may
      // extend it. The application-message path enforces the same rule.
      if (current == null ||
          current.queueGapRecoveryState != 0 ||
          !_bytesEqual(current.controlStateHash, previousHash)) {
        throw const _GroupConflict();
      }
      final updated =
          await (database.update(database.mlsGroups)..where(
                (row) =>
                    row.groupId.equals(next.groupId) &
                    row.controlRevision.equals(
                      expectedPrevious.controlRevision,
                    ),
              ))
              .write(
                MlsGroupsCompanion(
                  acceptedEpoch: Value(next.acceptedEpoch),
                  stateVersion: Value(current.stateVersion + 1),
                  controlProjectionCiphertext: Value(_encodeState(next)),
                  controlRevision: Value(next.controlRevision),
                  controlStateHash: Value(_hexBytes(next.controlStateHash)),
                  lifecycle: Value(next.lifecycle.index),
                  pendingMutationId: const Value(null),
                ),
              );
      if (updated != 1) throw const _GroupConflict();
      await (database.update(
        database.conversations,
      )..where((row) => row.conversationId.equals(next.groupId))).write(
        ConversationsCompanion(
          displayTitleCiphertext: Value(
            Uint8List.fromList(utf8.encode(next.metadata.name)),
          ),
          sortKey: Value(event.createdMs),
        ),
      );
      await (database.delete(
        database.memberships,
      )..where((row) => row.conversationId.equals(next.groupId))).go();
    }

    await _insertMemberships(next);
    for (final entry in prepared.precedingControlTranscript) {
      await _insertControlEvent(entry.signedControl, entry);
    }
    await _insertControlEvent(
      prepared.signedControl,
      prepared.controlTranscriptEntry,
    );
    if (prepared.outbound) {
      await database
          .into(database.groupOutboundObjects)
          .insert(
            GroupOutboundObjectsCompanion.insert(
              operationId: prepared.mutationId,
              groupId: next.groupId,
              eventId: event.eventId,
              epoch: next.acceptedEpoch,
              mlsObject: prepared.mlsObject,
              recipientUserIdsJson: Value(
                jsonEncode(prepared.recipientUserIds),
              ),
              deliveryState: developmentPreviewOnly ? 0 : 1,
            ),
          );
    }
  }

  Future<void> _insertMemberships(GroupState next) async {
    for (final member in next.members) {
      await database
          .into(database.memberships)
          .insert(
            MembershipsCompanion.insert(
              conversationId: next.groupId,
              userId: member.userId,
              rolePolicyProjectionCiphertext: _encodeMember(member),
            ),
          );
    }
  }

  Future<void> _insertControlEvent(
    SignedGroupControlEvent signed,
    GroupControlTranscriptEntry? transcript,
  ) async {
    final event = signed.event;
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
            controlStateHash: _hexBytes(signed.controlStateHash),
            mlsCommitHash: Value(
              event.mlsCommitHash == null
                  ? null
                  : _hexBytes(event.mlsCommitHash!),
            ),
            epoch: event.mlsEpoch,
            signerUserId: event.signerUserId,
            signerDeviceId: event.signerDeviceId,
            operationKind: event.operation.code,
            deterministicProjection: Value(
              transcript == null ? null : event.deterministicProjection,
            ),
            canonicalControl: signed.canonicalBytes,
            signature: signed.signature,
            signedPayload: Value(transcript?.signedPayload),
            signerAuthenticationProof: Value(
              transcript?.signerAuthenticationProof,
            ),
            applyState: 0,
            createdMs: event.createdMs,
          ),
        );
  }

  @override
  Future<Result<void>> commitMessage({
    required GroupState expectedGroup,
    required PreparedGroupMessage prepared,
    required bool developmentPreviewOnly,
  }) => _runGroupWrite(
    () => commitMessageInsideTransaction(
      expectedGroup: expectedGroup,
      prepared: prepared,
      developmentPreviewOnly: developmentPreviewOnly,
    ),
  );

  /// Used only by the durable inbox transaction after pairwise preparation.
  Future<void> commitMessageInsideTransaction({
    required GroupState expectedGroup,
    required PreparedGroupMessage prepared,
    required bool developmentPreviewOnly,
  }) async {
    if (prepared.groupId != expectedGroup.groupId ||
        prepared.epoch != expectedGroup.acceptedEpoch ||
        (!prepared.outbound && developmentPreviewOnly)) {
      throw const _GroupIntegrityFailure();
    }
    final hash = _hexBytes(expectedGroup.controlStateHash);
    final row =
        await (database.select(database.mlsGroups)..where(
              (item) =>
                  item.groupId.equals(expectedGroup.groupId) &
                  item.controlRevision.equals(expectedGroup.controlRevision),
            ))
            .getSingleOrNull();
    if (row == null ||
        !_bytesEqual(row.controlStateHash, hash) ||
        row.queueGapRecoveryState != 0) {
      throw const _GroupConflict();
    }
    final updated =
        await (database.update(database.mlsGroups)..where(
              (item) =>
                  item.groupId.equals(expectedGroup.groupId) &
                  item.controlRevision.equals(expectedGroup.controlRevision),
            ))
            .write(
              MlsGroupsCompanion(stateVersion: Value(row.stateVersion + 1)),
            );
    if (updated != 1) throw const _GroupConflict();
    await database
        .into(database.messages)
        .insert(
          MessagesCompanion.insert(
            messageId: prepared.messageId,
            conversationId: prepared.groupId,
            currentEventId: prepared.messageId,
            projectionCiphertext: Uint8List.fromList(
              utf8.encode(prepared.text),
            ),
            status: !prepared.outbound
                ? MessageTransportState.received.index
                : developmentPreviewOnly
                ? MessageTransportState.localOnly.index
                : MessageTransportState.queued.index,
            revision: 0,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              prepared.createdMs,
              isUtc: true,
            ),
            senderUserId: Value(prepared.senderUserId),
            senderDeviceId: Value(prepared.senderDeviceId),
            orderingMs: Value(prepared.createdMs),
            orderingEventId: Value(prepared.messageId),
          ),
        );
    await database
        .into(database.messageEvents)
        .insert(
          MessageEventsCompanion.insert(
            eventId: prepared.messageId,
            messageId: prepared.messageId,
            conversationId: prepared.groupId,
            eventKind: 0,
            authenticatedCiphertext: prepared.mlsObject,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              prepared.createdMs,
              isUtc: true,
            ),
          ),
        );
    if (prepared.outbound) {
      await database
          .into(database.groupOutboundObjects)
          .insert(
            GroupOutboundObjectsCompanion.insert(
              operationId: prepared.operationId,
              groupId: prepared.groupId,
              eventId: prepared.messageId,
              epoch: prepared.epoch,
              mlsObject: prepared.mlsObject,
              recipientUserIdsJson: Value(
                jsonEncode(prepared.recipientUserIds),
              ),
              deliveryState: developmentPreviewOnly ? 0 : 1,
            ),
          );
    }
    await (database.update(
      database.conversations,
    )..where((row) => row.conversationId.equals(prepared.groupId))).write(
      ConversationsCompanion(
        listProjectionCiphertext: Value(
          Uint8List.fromList(utf8.encode(prepared.text)),
        ),
        sortKey: Value(prepared.createdMs),
        lastActivityEventId: Value(prepared.messageId),
      ),
    );
  }

  @override
  Future<Result<void>> quarantine(GroupQuarantineRecord record) =>
      _runGroupWrite(() => quarantineInsideTransaction(record));

  /// Same durable effect as [quarantine], but joins the caller's transaction so
  /// a fork outcome commits atomically with the inbox envelope that carried it.
  Future<void> quarantineInsideTransaction(
    GroupQuarantineRecord record, {
    bool retainLifecycle = false,
  }) async {
    final row = await (database.select(
      database.mlsGroups,
    )..where((item) => item.groupId.equals(record.groupId))).getSingleOrNull();
    if (row == null || row.controlProjectionCiphertext == null) {
      throw const _GroupIntegrityFailure();
    }
    if (!retainLifecycle) {
      final state = _decodeState(row.controlProjectionCiphertext!);
      final lifecycle = record.reason == GroupQuarantineReason.siblingCommit
          ? GroupLifecycle.forkQuarantined
          : GroupLifecycle.controlQuarantined;
      final quarantined = state.copyWith(
        lifecycle: lifecycle,
        quarantineReason: record.reason,
      );
      await (database.update(
        database.mlsGroups,
      )..where((item) => item.groupId.equals(record.groupId))).write(
        MlsGroupsCompanion(
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
  }

  @override
  Future<Result<List<GroupState>>> readGroupsPendingEviction({
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 100) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final rows =
          await (database.select(database.mlsGroups)
                ..where(
                  (row) => row.lifecycle.equals(GroupLifecycle.active.index),
                )
                ..orderBy([(row) => OrderingTerm.asc(row.groupId)]))
              .get();
      final pending = <GroupState>[];
      for (final row in rows) {
        final projection = row.controlProjectionCiphertext;
        if (projection == null) continue;
        final state = _overlayQueueGap(
          _decodeState(projection),
          row.queueGapRecoveryState,
        );
        if (state.lifecycle != GroupLifecycle.active) continue;
        final departed = state.members.any(
          (member) => member.membership == GroupMembershipState.left,
        );
        if (!departed) continue;
        pending.add(state);
        if (pending.length == limit) break;
      }
      return Result.success(List.unmodifiable(pending));
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
        ..where((row) => row.deliveryState.equals(1))
        ..orderBy([(row) => OrderingTerm.asc(row.createdAt)])
        ..limit(limit);
      final rows = await query.get();
      return Result.success([
        for (final row in rows)
          GroupOutboundWork(
            operationId: row.operationId,
            groupId: row.groupId,
            eventId: row.eventId,
            epoch: row.epoch,
            openedMlsPayload: row.mlsObject,
            recipientUserIds: _decodeRecipientUserIds(row.recipientUserIdsJson),
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
      if (current.deliveryState == 2) return const Result.success(null);
      if (current.deliveryState != 1) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      }
      final updated =
          await (database.update(database.groupOutboundObjects)..where(
                (row) =>
                    row.operationId.equals(operationId) &
                    row.deliveryState.equals(1),
              ))
              .write(
                const GroupOutboundObjectsCompanion(deliveryState: Value(2)),
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

  GroupState _overlayQueueGap(GroupState state, int queueGapState) {
    if (queueGapState == 0 ||
        state.lifecycle == GroupLifecycle.removed ||
        state.lifecycle == GroupLifecycle.left) {
      return state;
    }
    return state.copyWith(
      lifecycle: GroupLifecycle.queueGapRejoinRequired,
      clearQuarantineReason: true,
    );
  }
}

List<String> _decodeRecipientUserIds(String input) {
  final decoded = jsonDecode(input);
  if (decoded is! List<Object?> || decoded.isEmpty) {
    throw const FormatException('invalid group outbound recipients');
  }
  final values = decoded
      .map((value) {
        if (value is! String || value.isEmpty || value != value.toLowerCase()) {
          throw const FormatException('invalid group outbound recipient');
        }
        return value;
      })
      .toList(growable: false);
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
        'photo': state.metadata.photoCapability,
      },
      'invite': state.invitationPolicy.index,
      'history': state.historySharingPolicy.index,
      'members': [for (final member in state.members) _memberJson(member)],
      'revision': state.controlRevision,
      'hash': state.controlStateHash,
      'epoch': state.acceptedEpoch,
      'lifecycle': state.lifecycle.index,
      'quarantine': state.quarantineReason?.index,
    }),
  ),
);

GroupState _decodeState(Uint8List bytes) {
  final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  if (value is! Map<String, Object?>) {
    throw const FormatException('invalid group projection');
  }
  final metadata = value['metadata'];
  final members = value['members'];
  if (metadata is! Map<String, Object?> || members is! List<Object?>) {
    throw const FormatException('invalid group projection');
  }
  final quarantine = value['quarantine'] as int?;
  return GroupState(
    groupId: value['group_id']! as String,
    metadata: GroupMetadata(
      name: metadata['name']! as String,
      description: metadata['description']! as String,
      photoCapability: metadata['photo'] as String?,
    ),
    invitationPolicy: GroupInvitationPolicy.values[value['invite']! as int],
    historySharingPolicy:
        GroupHistorySharingPolicy.values[value['history']! as int],
    members: [for (final member in members) _decodeMember(member!)],
    controlRevision: value['revision']! as int,
    controlStateHash: value['hash']! as String,
    acceptedEpoch: value['epoch']! as int,
    lifecycle: GroupLifecycle.values[value['lifecycle']! as int],
    quarantineReason: quarantine == null
        ? null
        : GroupQuarantineReason.values[quarantine],
  );
}

Map<String, Object?> _memberJson(GroupMember member) => {
  'user_id': member.userId,
  'name': member.displayName,
  'role': member.role.index,
  'membership': member.membership.index,
  'verified': member.verified,
  'devices': member.deviceIds,
};

Uint8List _encodeMember(GroupMember member) =>
    Uint8List.fromList(utf8.encode(jsonEncode(_memberJson(member))));

GroupMember _decodeMember(Object value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('invalid member projection');
  }
  return GroupMember(
    userId: value['user_id']! as String,
    displayName: value['name']! as String,
    role: GroupRole.values[value['role']! as int],
    membership: GroupMembershipState.values[value['membership']! as int],
    verified: value['verified']! as bool,
    deviceIds: (value['devices']! as List<Object?>).cast<String>(),
  );
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

String _bytesHex(Uint8List value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

String? _optionalHex(Uint8List? value) =>
    value == null ? null : _bytesHex(value);

void _validateControlTranscript(
  GroupState? expectedPrevious,
  PreparedGroupTransition prepared,
) {
  final event = prepared.signedControl.event;
  if (expectedPrevious != null) {
    if (prepared.precedingControlTranscript.isNotEmpty) {
      throw const _GroupIntegrityFailure();
    }
    return;
  }
  String? previousHash;
  var revision = 1;
  for (final entry in prepared.precedingControlTranscript) {
    final prior = entry.signedControl.event;
    if (prior.groupId != event.groupId ||
        prior.revision != revision ||
        prior.previousControlStateHash != previousHash) {
      throw const _GroupIntegrityFailure();
    }
    previousHash = entry.signedControl.controlStateHash;
    revision += 1;
  }
  if (event.revision != revision ||
      event.previousControlStateHash != previousHash) {
    throw const _GroupIntegrityFailure();
  }
}

bool _bytesEqual(Uint8List? left, Uint8List right) {
  if (left == null || left.length != right.length) return false;
  for (var index = 0; index < right.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _GroupConflict implements Exception {
  const _GroupConflict();
}

final class _GroupIntegrityFailure implements Exception {
  const _GroupIntegrityFailure();
}
