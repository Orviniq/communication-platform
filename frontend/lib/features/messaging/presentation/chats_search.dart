import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/domain/contact_search.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:flutter/foundation.dart';

/// Whether [chat] matches [needle], a query already trimmed and in lower case.
///
/// The rule the Chats list's own box applied: the chat's name or its latest
/// message, without regard to case. No older message is read: each message
/// body is stored as ciphertext in its own row, so a search across
/// conversations would need a design of its own, and a conversation's own
/// search reads its history instead. An empty [needle] matches every chat.
bool chatMatchesSearch(ChatListItemViewModel chat, String needle) =>
    chat.title.toLowerCase().contains(needle) ||
    chat.preview.toLowerCase().contains(needle);

/// What the Chats search page lists for one query.
@immutable
final class ChatsSearchResults {
  ChatsSearchResults({
    required Iterable<ChatListItemViewModel> chats,
    required Iterable<ContactProjection> contacts,
  }) : chats = List.unmodifiable(chats),
       contacts = List.unmodifiable(contacts);

  static final empty = ChatsSearchResults(chats: const [], contacts: const []);

  final List<ChatListItemViewModel> chats;
  final List<ContactProjection> contacts;

  bool get isEmpty => chats.isEmpty && contacts.isEmpty;
}

/// The chats and the contacts [query] finds, in the order they were given.
///
/// Pure: everything it searches is passed in, already on this phone, so the
/// scope the page states is a property a test can assert without a widget.
/// The query is trimmed and lowered once, here, and an empty one finds
/// nothing. A contact whose direct chat is among the chats found is left out
/// of the contacts, because the chat already leads to the same conversation.
ChatsSearchResults chatsSearch({
  required String query,
  required List<ChatListItemViewModel> chats,
  required List<ContactProjection> contacts,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return ChatsSearchResults.empty;
  final foundChats = [
    for (final chat in chats)
      if (chatMatchesSearch(chat, needle)) chat,
  ];
  final peersFound = {
    for (final chat in foundChats)
      if (!chat.group && !chat.savedMessages) ?chat.peerUserId,
  };
  return ChatsSearchResults(
    chats: foundChats,
    contacts: [
      for (final contact in contacts)
        if (!peersFound.contains(contact.userId) &&
            contactMatchesSearch(contact, needle))
          contact,
    ],
  );
}
