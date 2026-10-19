import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_session_repair_service.dart';

/// Group identifiers from the native core's CSPRNG, through the same
/// operation that produces application event identifiers.
final class NativeGroupIdentity implements GroupIdentityPort {
  const NativeGroupIdentity(this.protocol);

  final ApplicationProtocolPort protocol;

  @override
  Future<Result<Uint8List>> randomIdentifier() => protocol.generateEventId();
}

/// Sends a group message through the conversation pipeline every message
/// takes, with the group as its conversation.
final class ConversationGroupMessageSender implements GroupMessageSenderPort {
  const ConversationGroupMessageSender(this.conversations);

  final SendConversationEvents conversations;

  @override
  Future<Result<void>> sendText({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String text,
    String? replyToMessageId,
    String? quoteFallback,
  }) async {
    final sent = await conversations.sendText(
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      target: GroupConversationTarget(groupId),
      text: text,
      replyToMessageId: replyToMessageId,
      quoteFallback: quoteFallback,
    );
    return sent.fold(
      onSuccess: (_) => const Result.success(null),
      onFailure: Result.failure,
    );
  }

  @override
  Future<Result<void>> retryText({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String messageId,
    required String text,
    String? replyToMessageId,
    String? quoteFallback,
  }) => conversations.retrySend(
    currentUserId: currentUserId,
    currentDeviceId: currentDeviceId,
    target: GroupConversationTarget(groupId),
    messageId: messageId,
    text: text,
    replyToMessageId: replyToMessageId,
    quoteFallback: quoteFallback,
  );

  @override
  Future<Result<void>> setReaction({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String messageId,
    required String? emoji,
  }) => conversations.setReaction(
    currentUserId: currentUserId,
    currentDeviceId: currentDeviceId,
    conversationId: groupId,
    messageId: messageId,
    emoji: emoji,
  );

  @override
  Future<Result<void>> deleteForEveryone({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String messageId,
  }) => conversations.deleteForEveryone(
    currentUserId: currentUserId,
    currentDeviceId: currentDeviceId,
    conversationId: groupId,
    messageId: messageId,
  );

  @override
  Future<Result<void>> setPin({
    required String currentUserId,
    required String currentDeviceId,
    required String groupId,
    required String messageId,
    required bool pinned,
  }) => conversations.setPin(
    currentUserId: currentUserId,
    currentDeviceId: currentDeviceId,
    conversationId: groupId,
    messageId: messageId,
    pinned: pinned,
  );
}

/// Answers the conversation send path from the group's roster, as this
/// device holds it (ADR-096 D5, D6).
///
/// The roster is read with the lifecycle a pending state request lays over
/// it, so a member who may hold a stale roster sends no delete of another
/// member's message and no pin until the group's state is confirmed.
final class GroupRosterMessageModeration implements GroupMessageModerationPort {
  const GroupRosterMessageModeration(this.groups);

  final GroupRepositoryPort groups;

  @override
  Future<Result<bool>> mayDeleteMessageOf({
    required String groupId,
    required String actorUserId,
    required String authorUserId,
  }) => _withGroup(
    groupId,
    (group) => GroupAuthorization.canDeleteMessageOf(
      group,
      actorUserId: actorUserId,
      authorUserId: authorUserId,
    ),
  );

  @override
  Future<Result<bool>> mayPin({
    required String groupId,
    required String actorUserId,
  }) => _withGroup(
    groupId,
    (group) => GroupAuthorization.allows(
      group,
      actorUserId,
      GroupPermission.pinMessages,
    ),
  );

  Future<Result<bool>> _withGroup(
    String groupId,
    bool Function(GroupState group) decide,
  ) async {
    final result = await groups.readGroup(groupId);
    return result.fold(
      onSuccess: (group) => Result.success(group != null && decide(group)),
      onFailure: Result.failure,
    );
  }
}

final class PairwiseGroupSessionRepairAdapter
    implements GroupSessionRepairPort {
  const PairwiseGroupSessionRepairAdapter(this.service);

  final PairwiseSessionRepairService service;

  @override
  Future<Result<int>> requestRepairWithUser({
    required String localDeviceId,
    required String remoteUserId,
  }) => service.requestRepairWithUser(
    localDeviceId: localDeviceId,
    remoteUserId: remoteUserId,
  );
}
