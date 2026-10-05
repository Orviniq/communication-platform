import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';

/// One account as a voice screen names it.
final class VoiceRoomPerson {
  const VoiceRoomPerson({required this.name, required this.verified});

  final String name;

  /// Its safety number is verified: the user cross-signed this exact key.
  final bool verified;
}

/// The people a voice screen can name: the user's contacts, by account id.
///
/// A room keeps no display name and no verification of its own: both are read
/// from contacts (`room_model.dart`, `RoomMember`). An account that is not a
/// contact is named by the short form of its id the chat list uses, and never
/// by anything a member sent.
final class VoiceRoomPeople {
  VoiceRoomPeople({
    required String currentUserId,
    Map<String, VoiceRoomPerson> people = const {},
  }) : currentUserId = currentUserId.toLowerCase(),
       _people = {
         for (final entry in people.entries)
           entry.key.toLowerCase(): entry.value,
       };

  factory VoiceRoomPeople.fromContacts(
    String currentUserId,
    Iterable<ContactProjection> contacts,
  ) => VoiceRoomPeople(
    currentUserId: currentUserId,
    people: {
      for (final contact in contacts)
        contact.userId: VoiceRoomPerson(
          name: contact.presentationName,
          verified: contact.isVerified,
        ),
    },
  );

  final String currentUserId;
  final Map<String, VoiceRoomPerson> _people;

  bool isCurrentUser(String userId) => userId.toLowerCase() == currentUserId;

  String nameOf(String userId) =>
      _people[userId.toLowerCase()]?.name ?? chatShortIdentity(userId);

  bool isVerified(String userId) =>
      _people[userId.toLowerCase()]?.verified ?? false;

  /// Contacts whose safety number is verified, by name: the only accounts a
  /// room may invite, because verification precedes inviting.
  List<VoiceInviteCandidate> verifiedContacts({
    Iterable<String> excluding = const [],
  }) {
    final excluded = {for (final userId in excluding) userId.toLowerCase()};
    return [
      for (final MapEntry(key: userId, value: person) in _people.entries)
        if (person.verified &&
            userId != currentUserId &&
            !excluded.contains(userId))
          VoiceInviteCandidate(userId: userId, name: person.name),
    ]..sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
  }
}

/// A verified contact a room may invite.
final class VoiceInviteCandidate {
  const VoiceInviteCandidate({required this.userId, required this.name});

  final String userId;
  final String name;
}

/// What a room's row in the list says about it.
enum VoiceRoomRowState {
  /// The call this device is in.
  live,

  /// This device has been told about no call in it, which is not to say
  /// nobody is talking (`ui-specification.md` §13.0).
  empty,

  /// It may be missing a control event, and a member has been asked.
  waiting,

  /// Two valid control events at one revision, or one it refused.
  conflict,
  left,
  removed,
}

/// One row of the room list.
final class VoiceRoomRow {
  const VoiceRoomRow({
    required this.roomId,
    required this.name,
    required this.state,
    this.devices = 0,
  });

  final String roomId;
  final String name;
  final VoiceRoomRowState state;

  /// For [VoiceRoomRowState.live]: the devices this one counts in the call.
  final int devices;

  /// The rows for [rooms], in the order the list shows them: the room of the
  /// call in progress first, then the rooms this device may act in, then the
  /// paused ones, then the rooms it has left or been removed from, each by
  /// name.
  static List<VoiceRoomRow> fromRooms(
    Iterable<RoomState> rooms, {
    String? callRoomId,
    int callDevices = 0,
  }) {
    final rows = [
      for (final room in rooms)
        VoiceRoomRow(
          roomId: room.roomId,
          name: room.name,
          state: switch (room.lifecycle) {
            RoomLifecycle.active when room.roomId == callRoomId =>
              VoiceRoomRowState.live,
            RoomLifecycle.active => VoiceRoomRowState.empty,
            RoomLifecycle.stateRecoveryRequired => VoiceRoomRowState.waiting,
            RoomLifecycle.forkQuarantined ||
            RoomLifecycle.controlQuarantined => VoiceRoomRowState.conflict,
            RoomLifecycle.left => VoiceRoomRowState.left,
            RoomLifecycle.removed => VoiceRoomRowState.removed,
          },
          devices: room.roomId == callRoomId ? callDevices : 0,
        ),
    ];
    int rank(VoiceRoomRowState state) => switch (state) {
      VoiceRoomRowState.live => 0,
      VoiceRoomRowState.empty => 1,
      VoiceRoomRowState.waiting || VoiceRoomRowState.conflict => 2,
      VoiceRoomRowState.left || VoiceRoomRowState.removed => 3,
    };
    return rows..sort((left, right) {
      final byRank = rank(left.state).compareTo(rank(right.state));
      return byRank != 0
          ? byRank
          : left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });
  }
}
