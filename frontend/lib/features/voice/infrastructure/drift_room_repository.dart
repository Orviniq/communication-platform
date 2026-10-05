import 'dart:convert';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/drift_repository_base.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:drift/drift.dart';

/// Drift storage for voice rooms, which are client state exactly as groups are.
///
/// [RoomStates] holds this device's projection of each room, its name and
/// roster included, and [RoomControlEvents] holds the signed transcript that
/// justifies it, byte for byte, so this device can hand it to a member it adds.
/// A room is not a conversation and writes no conversation row; a call writes
/// no row at all.
final class DriftRoomRepository extends DriftRepositoryBase
    implements RoomRepositoryPort {
  const DriftRoomRepository(super.database);

  /// Bounds the open requests a stream of payloads naming rooms this device
  /// does not hold could create.
  static const maximumStateRequests = 64;

  /// Quarantine reason codes 48 to 51. The group's are 32 to 38.
  static const _quarantineReasonBase = 48;
  static const _reasonQueueGap = 0;
  static const _reasonBehind = 1;
  static const _deliveryPending = 1;
  static const _deliveryRouted = 2;

  static const _stateQuery =
      'SELECT s.control_projection_ciphertext AS projection, '
      'EXISTS (SELECT 1 FROM room_state_requests r '
      'WHERE r.room_id = s.room_id) AS pending '
      'FROM room_states s';

  @override
  Stream<List<RoomState>> watchRooms() => database
      .customSelect(
        '$_stateQuery ORDER BY s.room_id',
        readsFrom: {database.roomStates, database.roomStateRequests},
      )
      .watch()
      .map((rows) => List.unmodifiable(rows.map(_projectedState)));

  @override
  Stream<RoomState?> watchRoom(String roomId) => database
      .customSelect(
        '$_stateQuery WHERE s.room_id = ?',
        variables: [Variable<String>(roomId)],
        readsFrom: {database.roomStates, database.roomStateRequests},
      )
      .watchSingleOrNull()
      .map((row) => row == null ? null : _projectedState(row));

  @override
  Future<Result<RoomState?>> readRoom(String roomId) async {
    try {
      final row = await database
          .customSelect(
            '$_stateQuery WHERE s.room_id = ?',
            variables: [Variable<String>(roomId)],
            readsFrom: {database.roomStates, database.roomStateRequests},
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
  Future<Result<RoomState?>> readStoredRoom(String roomId) async {
    try {
      final row = await (database.select(
        database.roomStates,
      )..where((item) => item.roomId.equals(roomId))).getSingleOrNull();
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
    required String roomId,
    required String peerUserId,
  }) => _runRoomWrite(
    () => recordStateRequestInsideTransaction(
      roomId: roomId,
      peerUserId: peerUserId,
    ),
  );

  @override
  Future<Result<List<StoredRoomControl>>> readTranscript(
    String roomId, {
    int afterRevision = 0,
  }) async {
    if (afterRevision < 0) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final rows =
          await (database.select(database.roomControlEvents)
                ..where(
                  (row) =>
                      row.roomId.equals(roomId) &
                      row.revision.isBiggerThanValue(afterRevision),
                )
                ..orderBy([(row) => OrderingTerm.asc(row.revision)]))
              .get();
      final transcript = <StoredRoomControl>[];
      for (final row in rows) {
        final entry = StoredRoomControl(
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
          throw const FormatException('broken stored room transcript');
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
    required RoomState? expectedPrevious,
    required RoomState next,
    required PreparedRoomTransition prepared,
  }) => _runRoomWrite(
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
  /// pairwise receive that carried it commit as one. A run that gives this
  /// device the room or adds a member makes the room's session check due.
  Future<void> commitTransitionInsideTransaction({
    required RoomState? expectedPrevious,
    required RoomState next,
    required PreparedRoomTransition prepared,
  }) async {
    final first = prepared.first.event;
    final last = prepared.last;
    if (last.event.roomId != next.roomId ||
        last.event.revision != next.controlRevision ||
        last.controlStateHash != next.controlStateHash ||
        (expectedPrevious == null
            ? first.revision != 1
            : expectedPrevious.roomId != next.roomId ||
                  first.revision != expectedPrevious.controlRevision + 1 ||
                  first.previousControlStateHash !=
                      expectedPrevious.controlStateHash)) {
      throw const _RoomIntegrityFailure();
    }

    final current = await (database.select(
      database.roomStates,
    )..where((row) => row.roomId.equals(next.roomId))).getSingleOrNull();
    if (expectedPrevious == null) {
      if (current != null) throw const _RoomConflict();
      await database
          .into(database.roomStates)
          .insert(
            RoomStatesCompanion.insert(
              roomId: next.roomId,
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
        throw const _RoomConflict();
      }
      final updated =
          await (database.update(database.roomStates)..where(
                (row) =>
                    row.roomId.equals(next.roomId) &
                    row.stateVersion.equals(current.stateVersion),
              ))
              .write(
                RoomStatesCompanion(
                  stateVersion: Value(current.stateVersion + 1),
                  controlProjectionCiphertext: Value(_encodeState(next)),
                  controlRevision: Value(next.controlRevision),
                  controlStateHash: Value(_hexBytes(next.controlStateHash)),
                  lifecycle: Value(next.lifecycle.index),
                  sessionsCheckedAt: prepared.admitsMembers
                      ? const Value(null)
                      : const Value.absent(),
                ),
              );
      if (updated != 1) throw const _RoomConflict();
    }
    for (final control in prepared.controls) {
      final event = control.event;
      await database
          .into(database.roomControlEvents)
          .insert(
            RoomControlEventsCompanion.insert(
              eventId: event.eventId,
              roomId: event.roomId,
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
      await completeStateRequestInsideTransaction(next.roomId);
    }
  }

  /// Records a rejected control event. Only a fork moves the room into
  /// quarantine; see [PreparedRoomInboxQuarantine.retainLifecycle].
  Future<void> quarantineInsideTransaction(
    RoomQuarantineRecord record, {
    required bool retainLifecycle,
    bool completesStateRequest = false,
  }) async {
    if (!retainLifecycle) {
      final row = await (database.select(
        database.roomStates,
      )..where((item) => item.roomId.equals(record.roomId))).getSingleOrNull();
      if (row == null) throw const _RoomIntegrityFailure();
      final lifecycle = record.reason == RoomQuarantineReason.siblingControl
          ? RoomLifecycle.forkQuarantined
          : RoomLifecycle.controlQuarantined;
      final quarantined = _decodeState(
        row.controlProjectionCiphertext,
      ).copyWith(lifecycle: lifecycle, quarantineReason: record.reason);
      await (database.update(
        database.roomStates,
      )..where((item) => item.roomId.equals(record.roomId))).write(
        RoomStatesCompanion(
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
            reasonCode: _quarantineReasonBase + record.reason.index,
            opaqueDigest: record.opaqueDigest,
            receivedAt: Value(record.receivedAt.toUtc()),
          ),
        );
    if (completesStateRequest) {
      await completeStateRequestInsideTransaction(record.roomId);
    }
  }

  /// Retires a room's open request when a member confirmed the state this
  /// device holds. A state that moved on after the answer was read keeps its
  /// request, and a later answer decides.
  Future<void> confirmStateCurrentInsideTransaction({
    required String roomId,
    required int controlRevision,
    required String controlStateHash,
  }) async {
    final row = await (database.select(
      database.roomStates,
    )..where((item) => item.roomId.equals(roomId))).getSingleOrNull();
    if (row == null ||
        row.controlRevision != controlRevision ||
        protocolBytesToHex(row.controlStateHash) != controlStateHash) {
      return;
    }
    await completeStateRequestInsideTransaction(roomId);
  }

  Future<void> queueOutboundInsideTransaction(RoomOutboundWork work) async {
    // A repeated request for the same state is answered once.
    await database
        .into(database.roomOutboundObjects)
        .insert(
          RoomOutboundObjectsCompanion.insert(
            operationId: work.operationId,
            roomId: work.roomId,
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

  /// Opens a request for a room's state after something named state this
  /// device does not hold. An open request, gap or not, is left alone.
  Future<void> recordStateRequestInsideTransaction({
    required String roomId,
    required String peerUserId,
  }) async {
    final existing = await (database.select(
      database.roomStateRequests,
    )..where((row) => row.roomId.equals(roomId))).getSingleOrNull();
    if (existing != null) return;
    final count = database.roomStateRequests.roomId.count();
    final open = await (database.selectOnly(
      database.roomStateRequests,
    )..addColumns([count])).map((row) => row.read(count) ?? 0).getSingle();
    if (open >= maximumStateRequests) return;
    await database
        .into(database.roomStateRequests)
        .insert(
          RoomStateRequestsCompanion.insert(
            roomId: roomId,
            reason: _reasonBehind,
            peerUserId: Value(peerUserId.toLowerCase()),
          ),
        );
  }

  /// Marks every active room as possibly affected by a mailbox gap: a lost
  /// envelope may have carried any room's control event, a removal included,
  /// so every such room waits for its state before it joins a call, invites
  /// or renames.
  ///
  /// A room this device was removed from, left, or holds in quarantine is not
  /// flagged, because no member's answer could change it. Unlike a group's, a
  /// room's request does not hold the checkpoint's gap open: the checkpoint
  /// closes on the groups' answers as before, and each room waits for its own.
  Future<void> recordQueueGapInsideTransaction() async {
    final rows = await (database.select(
      database.roomStates,
    )..where((row) => row.lifecycle.equals(RoomLifecycle.active.index))).get();
    for (final row in rows) {
      await database
          .into(database.roomStateRequests)
          .insertOnConflictUpdate(
            RoomStateRequestsCompanion.insert(
              roomId: row.roomId,
              reason: _reasonQueueGap,
            ),
          );
    }
  }

  /// Retires a room's open request.
  Future<void> completeStateRequestInsideTransaction(String roomId) async {
    await (database.delete(
      database.roomStateRequests,
    )..where((row) => row.roomId.equals(roomId))).go();
  }

  @override
  Future<Result<List<RoomOutboundWork>>> readPendingOutbound({
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 100) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    return _readPending(
      database.select(database.roomOutboundObjects)
        ..where((row) => row.deliveryState.equals(_deliveryPending))
        ..orderBy([
          (row) => OrderingTerm.asc(row.createdAt),
          (row) => OrderingTerm.asc(row.operationId),
        ])
        ..limit(limit),
    );
  }

  @override
  Future<Result<List<RoomOutboundWork>>> readPendingOutboundForRoom(
    String roomId,
  ) => _readPending(
    database.select(database.roomOutboundObjects)
      ..where(
        (row) =>
            row.roomId.equals(roomId) &
            row.deliveryState.equals(_deliveryPending),
      )
      ..orderBy([
        (row) => OrderingTerm.asc(row.createdAt),
        (row) => OrderingTerm.asc(row.operationId),
      ])
      ..limit(maximumPendingForRoom),
  );

  /// A room of fifty with one device each owes at most this many copies of
  /// its payloads at once, which is the most a session check needs to see.
  static const maximumPendingForRoom = 256;

  Future<Result<List<RoomOutboundWork>>> _readPending(
    SimpleSelectStatement<
      $RoomOutboundObjectsTable,
      StoredRoomOutboundObjectRow
    >
    query,
  ) async {
    try {
      final rows = await query.get();
      return Result.success([
        for (final row in rows)
          RoomOutboundWork(
            operationId: row.operationId,
            roomId: row.roomId,
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
        database.roomOutboundObjects,
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
          await (database.update(database.roomOutboundObjects)..where(
                (row) =>
                    row.operationId.equals(operationId) &
                    row.deliveryState.equals(_deliveryPending),
              ))
              .write(
                const RoomOutboundObjectsCompanion(
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
  Future<Result<List<RoomStateRequest>>> readDueStateRequests({
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
          await (database.select(database.roomStateRequests)
                ..where(
                  (row) =>
                      row.requestedAt.isNull() |
                      row.requestedAt.isSmallerOrEqualValue(retryBefore),
                )
                ..orderBy([
                  (row) => OrderingTerm.asc(row.createdAt),
                  (row) => OrderingTerm.asc(row.roomId),
                ])
                ..limit(limit))
              .get();
      return Result.success([
        for (final row in rows)
          RoomStateRequest(
            roomId: row.roomId,
            reason: row.reason == _reasonQueueGap
                ? RoomStateRequestReason.queueGap
                : RoomStateRequestReason.behind,
            peerUserId: row.peerUserId,
            attempts: row.attempts,
            requestedAt: row.requestedAt?.toUtc(),
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
    required String roomId,
    required String peerUserId,
    required RoomOutboundWork work,
    required DateTime requestedAt,
  }) => _runRoomWrite(() async {
    final existing = await (database.select(
      database.roomStateRequests,
    )..where((row) => row.roomId.equals(roomId))).getSingleOrNull();
    if (existing == null || work.roomId != roomId) {
      throw const _RoomConflict();
    }
    await (database.update(
      database.roomStateRequests,
    )..where((row) => row.roomId.equals(roomId))).write(
      RoomStateRequestsCompanion(
        peerUserId: Value(peerUserId.toLowerCase()),
        attempts: Value(existing.attempts + 1),
        requestedAt: Value(requestedAt.toUtc()),
      ),
    );
    await queueOutboundInsideTransaction(work);
  });

  @override
  Future<Result<void>> retireStateRequest(String roomId) =>
      _runRoomWrite(() => completeStateRequestInsideTransaction(roomId));

  @override
  Future<Result<List<RoomSessionCheck>>> readDueSessionChecks({
    required DateTime checkedBefore,
    int limit = 4,
  }) async {
    if (limit < 1 || limit > maximumStateRequests) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      final waiting = database.selectOnly(database.roomStateRequests)
        ..addColumns([database.roomStateRequests.roomId]);
      final rows =
          await (database.select(database.roomStates)
                ..where(
                  (row) =>
                      row.lifecycle.equals(RoomLifecycle.active.index) &
                      (row.sessionsCheckedAt.isNull() |
                          row.sessionsCheckedAt.isSmallerOrEqualValue(
                            checkedBefore,
                          )) &
                      row.roomId.isNotInQuery(waiting),
                )
                ..orderBy([
                  (row) => OrderingTerm(
                    expression: row.sessionsCheckedAt,
                    nulls: NullsOrder.first,
                  ),
                  (row) => OrderingTerm.asc(row.roomId),
                ])
                ..limit(limit))
              .get();
      return Result.success([
        for (final row in rows)
          RoomSessionCheck(
            roomId: row.roomId,
            checkedAt: row.sessionsCheckedAt?.toUtc(),
            controlRevision: row.controlRevision,
            controlStateHash: protocolBytesToHex(row.controlStateHash),
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
  Future<Result<void>> recordSessionCheck({
    required RoomSessionCheck check,
    required List<RoomOutboundWork> work,
    required DateTime checkedAt,
  }) => _runRoomWrite(() async {
    if (work.any((item) => item.roomId != check.roomId)) {
      throw const _RoomIntegrityFailure();
    }
    for (final item in work) {
      await queueOutboundInsideTransaction(item);
    }
    // Every request is owed whatever happened meanwhile, because a missing
    // session is missing either way. Only the record that the room was
    // checked waits on the state: a change of rule 1 that committed in
    // between left the room due, and it stays due.
    await (database.update(database.roomStates)..where(
          (row) =>
              row.roomId.equals(check.roomId) &
              row.controlRevision.equals(check.controlRevision) &
              row.controlStateHash.equals(_hexBytes(check.controlStateHash)),
        ))
        .write(
          RoomStatesCompanion(sessionsCheckedAt: Value(checkedAt.toUtc())),
        );
  });

  Future<Result<void>> _runRoomWrite(Future<void> Function() operation) async {
    try {
      await database.writeTransaction(operation);
      return const Result.success(null);
    } on _RoomConflict {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.conflict),
      );
    } on _RoomIntegrityFailure {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  RoomState _projectedState(QueryRow row) {
    final state = _decodeState(row.read<Uint8List>('projection'));
    // An open request means a member has not yet confirmed this roster. The
    // room stays readable and its stored lifecycle is untouched, but nothing
    // may be signed into it, and no call joined, while it may be stale.
    return row.read<bool>('pending') && state.lifecycle == RoomLifecycle.active
        ? state.copyWith(lifecycle: RoomLifecycle.stateRecoveryRequired)
        : state;
  }
}

List<String> _decodeRecipientUserIds(String input) {
  final decoded = jsonDecode(input);
  if (decoded is! List<Object?>) {
    throw const FormatException('invalid room outbound recipients');
  }
  final values = [
    for (final value in decoded)
      if (value is String && value.isNotEmpty && value == value.toLowerCase())
        value
      else
        throw const FormatException('invalid room outbound recipient'),
  ];
  if (values.toSet().length != values.length) {
    throw const FormatException('duplicate room outbound recipient');
  }
  return values;
}

Uint8List _encodeState(RoomState state) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'room_id': state.roomId,
      'name': state.name,
      'members': [
        for (final member in state.members)
          {'user_id': member.userId, 'membership': member.membership.index},
      ],
      'revision': state.controlRevision,
      'hash': state.controlStateHash,
      'lifecycle': state.lifecycle.index,
      'quarantine': state.quarantineReason?.index,
      'removed_by': state.removedByUserId,
    }),
  ),
);

RoomState _decodeState(Uint8List bytes) {
  final value = _map(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
  final quarantine = value['quarantine'];
  final removedBy = value['removed_by'];
  if (removedBy != null && removedBy is! String) {
    throw const FormatException('invalid room projection');
  }
  return RoomState(
    roomId: _string(value['room_id']),
    name: _string(value['name']),
    members: [
      for (final member in _list(value['members']))
        RoomMember(
          userId: _string(_map(member)['user_id']),
          membership: _enum(
            RoomMembershipState.values,
            _map(member)['membership'],
          ),
        ),
    ],
    controlRevision: _integer(value['revision']),
    controlStateHash: _string(value['hash']),
    lifecycle: _enum(RoomLifecycle.values, value['lifecycle']),
    quarantineReason: quarantine == null
        ? null
        : _enum(RoomQuarantineReason.values, quarantine),
    removedByUserId: removedBy as String?,
  );
}

Map<String, Object?> _map(Object? value) => value is Map<String, Object?>
    ? value
    : throw const FormatException('invalid room projection');

List<Object?> _list(Object? value) => value is List<Object?>
    ? value
    : throw const FormatException('invalid room projection');

String _string(Object? value) => value is String
    ? value
    : throw const FormatException('invalid room projection');

int _integer(Object? value) => value is int
    ? value
    : throw const FormatException('invalid room projection');

T _enum<T>(List<T> values, Object? value) {
  final index = _integer(value);
  if (index < 0 || index >= values.length) {
    throw const FormatException('invalid room projection');
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

final class _RoomConflict implements Exception {
  const _RoomConflict();
}

final class _RoomIntegrityFailure implements Exception {
  const _RoomIntegrityFailure();
}
