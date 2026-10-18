import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';

extension GroupMemberLabels on GroupMemberNames {
  /// The name a screen shows for [userId]: the name this phone holds, else
  /// "Unknown member". Never a blank and never the user id.
  String labelOf(String userId, AppLocalizations strings) =>
      nameOf(userId) ?? strings.groupUnknownMember;
}
