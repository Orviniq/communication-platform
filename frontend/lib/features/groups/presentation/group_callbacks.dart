import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';

typedef CreateGroupCallback =
    Future<Result<GroupState>> Function(
      GroupMetadata metadata,
      List<GroupMember> selectedMembers,
    );
typedef MutateGroupCallback =
    Future<Result<GroupState>> Function(GroupControlOperation operation);
typedef SendGroupMessageCallback =
    Future<Result<void>> Function(
      String text, {
      String? replyToMessageId,
      String? quoteFallback,
    });
typedef RetryGroupMessageCallback =
    Future<Result<void>> Function(
      String messageId,
      String text, {
      String? replyToMessageId,
      String? quoteFallback,
    });

/// Sets this user's reaction to a message, or removes it when [emoji] is null.
typedef SetGroupReactionCallback =
    Future<Result<void>> Function(String messageId, String? emoji);

/// Keeps the composer's draft on this phone, or clears it when [text] is null.
typedef SaveGroupDraftCallback = Future<Result<void>> Function(String? text);

/// Stars or unstars a message on this phone.
typedef SetGroupStarCallback =
    Future<Result<void>> Function(String messageId, bool starred);

/// Deletes a message from this phone only.
typedef DeleteGroupMessageForMeCallback =
    Future<Result<void>> Function(String messageId);

/// Follows the members who read one message of the group, each once, with
/// the time of their earliest read, the newest first (ADR-091 D7, D8).
typedef WatchGroupMessageReadersCallback =
    Stream<List<MessageReader>> Function(String messageId);

/// Sends a message on to each of [targets]: a failure when any refused.
typedef ForwardGroupMessageCallback =
    Future<Result<void>> Function(
      ChatMessageViewModel message,
      Iterable<ChatListItemViewModel> targets,
    );

final class GroupPickerContact {
  const GroupPickerContact({
    required this.userId,
    required this.name,
    required this.verified,
  });

  factory GroupPickerContact.fromContact(ContactProjection contact) =>
      GroupPickerContact(
        userId: contact.userId,
        name: contact.presentationName,
        verified: contact.trustState == ContactTrustState.verified,
      );

  final String userId;
  final String name;
  final bool verified;
}
