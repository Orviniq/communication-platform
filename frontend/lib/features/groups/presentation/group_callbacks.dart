import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

typedef CreateGroupCallback =
    Future<Result<GroupState>> Function(
      GroupMetadata metadata,
      List<GroupMember> selectedMembers,
    );
typedef MutateGroupCallback =
    Future<Result<GroupState>> Function(GroupControlOperation operation);
typedef SendGroupMessageCallback = Future<Result<void>> Function(String text);
typedef RetryGroupMessageCallback =
    Future<Result<void>> Function(GroupMessage message);

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
