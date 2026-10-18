/// What this device shows for one member of a group.
///
/// Worked out from this phone's contacts when a screen needs it (see
/// `groupMemberNamesProvider`). The group never stores it: a signed control
/// event carries a user id and a role, and the name of a member is each
/// device's own view of that user.
final class GroupMemberName {
  const GroupMemberName({required this.name, required this.verified});

  /// The display name of a verified contact, else the directory username.
  /// Never empty.
  final String name;

  /// Whether this phone has verified the user. This device's own trust state,
  /// and not something the group says.
  final bool verified;

  @override
  bool operator ==(Object other) =>
      other is GroupMemberName &&
      other.name == name &&
      other.verified == verified;

  @override
  int get hashCode => Object.hash(name, verified);
}

/// The names this device holds for a set of group members, by user id.
///
/// A member this device cannot name is absent. A screen words that absence as
/// "Unknown member": it never shows the user id and never shows a blank.
final class GroupMemberNames {
  GroupMemberNames(Map<String, GroupMemberName> entries)
    : _entries = Map.unmodifiable({
        for (final entry in entries.entries)
          entry.key.toLowerCase(): entry.value,
      });

  const GroupMemberNames.empty() : _entries = const {};

  final Map<String, GroupMemberName> _entries;

  /// The name of [userId], or null when this device holds none.
  String? nameOf(String userId) => _entries[userId.toLowerCase()]?.name;

  bool isVerified(String userId) =>
      _entries[userId.toLowerCase()]?.verified ?? false;

  @override
  bool operator ==(Object other) {
    if (other is! GroupMemberNames ||
        other._entries.length != _entries.length) {
      return false;
    }
    for (final entry in _entries.entries) {
      if (other._entries[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered([
    for (final entry in _entries.entries) Object.hash(entry.key, entry.value),
  ]);
}

/// The members a name lookup is for.
///
/// A value, so that a provider family keyed by it is one provider for one set
/// of members whatever order the roster lists them in.
final class GroupMemberNamesRequest {
  GroupMemberNamesRequest(Iterable<String> userIds)
    : userIds = List.unmodifiable(
        {for (final id in userIds) id.toLowerCase()}.toList()..sort(),
      );

  final List<String> userIds;

  @override
  bool operator ==(Object other) =>
      other is GroupMemberNamesRequest && _sameIds(other.userIds, userIds);

  @override
  int get hashCode => Object.hashAll(userIds);

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}
