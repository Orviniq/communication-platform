import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';

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
    final Conversation? conversation;
    try {
      final event = await (database.select(
        database.storedApplicationEvents,
      )..where((row) => row.eventId.equals(eventId))).getSingleOrNull();
      if (event == null) {
        // Nothing left to decide for. The preparation settles itself when it
        // finds its record gone.
        return const Result.success(null);
      }
      conversation =
          await (database.select(database.conversations)..where(
                (row) => row.conversationId.equals(event.conversationId),
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
    return Result.success({
      for (final member in group.activeMembers)
        if (member.userId != local) member.userId,
    });
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
