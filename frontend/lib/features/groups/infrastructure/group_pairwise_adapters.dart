import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
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
  }) async {
    final sent = await conversations.sendText(
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      target: GroupConversationTarget(groupId),
      text: text,
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
  }) => conversations.retrySend(
    currentUserId: currentUserId,
    currentDeviceId: currentDeviceId,
    target: GroupConversationTarget(groupId),
    messageId: messageId,
    text: text,
  );
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
