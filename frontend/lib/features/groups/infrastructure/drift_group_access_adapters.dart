import 'dart:convert';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:drift/drift.dart' show Variable;

/// Names the members an owed group message is for, when its send is
/// prepared rather than when it was written, so that a member removed in
/// between gets no copy and a member added in between gets one.
final class DriftGroupSendAudienceResolver implements PairwiseSendAudiencePort {
  const DriftGroupSendAudienceResolver({
    required this.database,
    required this.groups,
  });

  final LocalDatabase database;
  final GroupRepositoryPort groups;

  @override
  Future<Result<Set<String>?>> resolveAudience({
    required String eventId,
    required String currentUserId,
  }) async {
    final StoredApplicationEvent event;
    final Conversation? conversation;
    try {
      final stored = await (database.select(
        database.storedApplicationEvents,
      )..where((row) => row.eventId.equals(eventId))).getSingleOrNull();
      if (stored == null) {
        // Nothing left to decide for. The preparation settles itself when it
        // finds its record gone.
        return const Result.success(null);
      }
      event = stored;
      conversation =
          await (database.select(database.conversations)..where(
                (row) => row.conversationId.equals(stored.conversationId),
              ))
              .getSingleOrNull();
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    if (conversation == null ||
        conversation.kind != ConversationKind.group.index) {
      return const Result.success(null);
    }
    final groupResult = await groups.readGroup(conversation.conversationId);
    if (groupResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final group = (groupResult as Success<GroupState?>).value;
    final local = currentUserId.toLowerCase();
    // A group this device may no longer send into — removed, left, holding a
    // refused control, or waiting on a member to confirm its roster — gets no
    // copy of anything. The send fails where the user can see and retry it.
    if (group == null ||
        !GroupAuthorization.allows(
          group,
          local,
          GroupPermission.sendMessages,
        )) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    if (event.kind == ApplicationEventKind.receiptRead.wireValue ||
        event.kind == ApplicationEventKind.receiptDelivered.wireValue) {
      return _receiptAudience(event, group, local);
    }
    return Result.success({
      for (final member in group.activeMembers)
        if (member.userId != local) member.userId,
    });
  }

  /// A receipt is for the sender of the messages it names, while that sender
  /// is an active member, and for nobody else (ADR-091 D3). Each other member
  /// would learn who read the messages of others.
  ///
  /// A receipt that names messages of two senders, or a message this group's
  /// conversation does not hold, is for no member: its copies go to this
  /// account's other devices only.
  Future<Result<Set<String>?>> _receiptAudience(
    StoredApplicationEvent event,
    GroupState group,
    String local,
  ) async {
    final Set<String>? senders;
    try {
      senders = await _sendersNamedBy(event);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
    if (senders == null || senders.length != 1) {
      return const Result.success({});
    }
    final sender = senders.single;
    return Result.success({
      if (sender != local &&
          group.activeMembers.any((member) => member.userId == sender))
        sender,
    });
  }

  /// The senders of the messages [receipt] names, or null when one of them is
  /// not a message of the receipt's own conversation.
  ///
  /// The names come from the stored body, and each is then looked up in
  /// `application_event_targets` by its whole primary key. That table's key
  /// leads with the message id and nothing indexes its event id, so a lookup
  /// by the event alone would read every target of every event on the device.
  Future<Set<String>?> _sendersNamedBy(StoredApplicationEvent receipt) async {
    final named = _namedMessageIds(receipt);
    if (named == null || named.isEmpty) {
      return null;
    }
    final placeholders = List.filled(named.length, '?').join(', ');
    // `CROSS JOIN` fixes the order: the targets by their key, then each
    // message by its own, as the projector reads the facts of a message.
    final rows = await database
        .customSelect(
          'SELECT target.message_id AS message_id, '
          'message.sender_user_id AS sender_user_id '
          'FROM application_event_targets target '
          'CROSS JOIN messages message '
          'ON message.message_id = target.message_id '
          'WHERE target.message_id IN ($placeholders) '
          'AND target.event_id = ? AND message.conversation_id = ?',
          variables: [
            for (final messageId in named) Variable<String>(messageId),
            Variable<String>(receipt.eventId),
            Variable<String>(receipt.conversationId),
          ],
          readsFrom: {database.applicationEventTargets, database.messages},
        )
        .get();
    final found = {for (final row in rows) row.read<String>('message_id')};
    if (!found.containsAll(named)) {
      return null;
    }
    return {for (final row in rows) row.read<String>('sender_user_id')};
  }

  /// The message ids the projector stored for [receipt], or null when its
  /// body is not the projection of a receipt.
  static Set<String>? _namedMessageIds(StoredApplicationEvent receipt) {
    try {
      final body = jsonDecode(utf8.decode(receipt.bodyProjection));
      final ids = body is Map<String, Object?> ? body['message_ids'] : null;
      if (ids is! List<Object?> || ids.any((id) => id is! String)) {
        return null;
      }
      return {for (final id in ids) id! as String};
    } on FormatException {
      return null;
    }
  }
}

/// Admits an application event into a group conversation only from an active
/// member, and only while this device's account is one.
final class DriftGroupConversationMembership
    implements GroupConversationMembershipPort {
  const DriftGroupConversationMembership(this.groups);

  final GroupRepositoryPort groups;

  @override
  Future<Result<void>> authorizeGroupEvent({
    required String groupId,
    required String senderUserId,
    required String currentUserId,
  }) async {
    if (!_groupId.hasMatch(groupId)) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final storedResult = await groups.readStoredGroup(groupId);
    if (storedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final group = (storedResult as Success<GroupState?>).value;
    final sender = group?.member(senderUserId);
    if (group == null || sender == null) {
      // Either a group this device has not been given yet — a new device of a
      // member, or a member whose transcript has not arrived — or a member
      // this device has not seen added. Both are answered by asking the sender
      // for the group's state, and the event waits for that answer within its
      // inspection budget.
      final opened = await groups.openStateRequest(
        groupId: groupId,
        peerUserId: senderUserId,
      );
      if (opened case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    if (group.member(currentUserId)?.isActive != true) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    if (!sender.isActive) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    return const Result.success(null);
  }
}

final RegExp _groupId = RegExp(r'^[0-9a-f]{64}$');
