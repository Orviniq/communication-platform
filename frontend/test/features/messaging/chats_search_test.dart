import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/messaging/presentation/chats_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('chatMatchesSearch', () {
    final chat = _chat('c-1', title: 'Weekend Plans', preview: 'See You THERE');

    test('matches the name, without regard to case', () {
      expect(chatMatchesSearch(chat, 'weekend'), isTrue);
      expect(chatMatchesSearch(chat, 'end pl'), isTrue);
    });

    test('matches the latest message, without regard to case', () {
      expect(chatMatchesSearch(chat, 'you there'), isTrue);
    });

    test('matches nothing else', () {
      expect(chatMatchesSearch(chat, 'monday'), isFalse);
      // The conversation's id and its peer are not what the reader sees.
      expect(chatMatchesSearch(chat, 'c-1'), isFalse);
      expect(chatMatchesSearch(chat, 'peer'), isFalse);
    });

    test('Persian text matches Persian queries', () {
      final persian = _chat('c-2', title: 'مریم', preview: 'فردا می‌بینمت');
      expect(chatMatchesSearch(persian, 'فردا'), isTrue);
      expect(chatMatchesSearch(persian, 'امروز'), isFalse);
    });

    test('an empty needle matches every chat', () {
      expect(chatMatchesSearch(chat, ''), isTrue);
    });
  });

  group('chatsSearch', () {
    final chats = [
      _chat(
        'c-1',
        title: 'Maryam',
        preview: 'see you at the park',
        peer: 'u-1',
      ),
      _chat('c-2', title: 'Park run', preview: 'Saturday', group: true),
      _chat(
        'c-3',
        title: 'Saved Messages',
        preview: 'parking spot',
        saved: true,
      ),
      _chat('c-4', title: 'Reza', preview: 'thanks', peer: 'u-2'),
    ];
    final contacts = [
      _contact('u-1', 'maryam_a', verified: true, name: 'Maryam'),
      _contact('u-2', 'reza_k'),
      _contact('u-3', 'parker'),
      _contact('u-4', 'sara', verified: true, name: 'Parisa'),
      _contact('u-5', 'nima', name: 'Parvin'),
    ];

    test('the query is trimmed and lowered once, for both sections', () {
      final results = chatsSearch(
        query: '  PAR ',
        chats: chats,
        contacts: contacts,
      );
      expect(results.chats.map((chat) => chat.conversationId), [
        'c-1',
        'c-2',
        'c-3',
      ]);
      // A display name counts only on a verified contact: Parisa is found,
      // Parvin is not.
      expect(results.contacts.map((contact) => contact.userId), ['u-3', 'u-4']);
    });

    test('a blank query finds nothing at all', () {
      for (final query in ['', '   ']) {
        final results = chatsSearch(
          query: query,
          chats: chats,
          contacts: contacts,
        );
        expect(results.isEmpty, isTrue, reason: '"$query"');
      }
    });

    test('a contact whose direct chat was found is not listed again', () {
      final results = chatsSearch(
        query: 'maryam',
        chats: chats,
        contacts: contacts,
      );
      expect(results.chats.map((chat) => chat.conversationId), ['c-1']);
      expect(results.contacts, isEmpty);
    });

    test('a contact whose direct chat was not found is listed', () {
      // Reza's chat matches neither his username nor this query.
      final results = chatsSearch(
        query: 'reza_k',
        chats: chats,
        contacts: contacts,
      );
      expect(results.chats, isEmpty);
      expect(results.contacts.map((contact) => contact.userId), ['u-2']);
    });

    test('a group or Saved Messages hides no contact', () {
      final results = chatsSearch(
        query: 'park',
        chats: [
          _chat('g', title: 'Park', preview: '', group: true, peer: 'u-3'),
          _chat('s', title: 'Park', preview: '', saved: true, peer: 'u-3'),
        ],
        contacts: contacts,
      );
      expect(results.chats, hasLength(2));
      expect(results.contacts.map((contact) => contact.userId), ['u-3']);
    });

    test('the results cannot be changed by a caller', () {
      final results = chatsSearch(
        query: 'par',
        chats: chats,
        contacts: contacts,
      );
      expect(() => results.chats.clear(), throwsUnsupportedError);
      expect(() => results.contacts.clear(), throwsUnsupportedError);
    });
  });
}

ChatListItemViewModel _chat(
  String id, {
  required String title,
  required String preview,
  String? peer,
  bool group = false,
  bool saved = false,
}) => ChatListItemViewModel(
  conversationId: id,
  title: title,
  preview: preview,
  timestamp: DateTime.utc(2026, 10, 9),
  unreadCount: 0,
  muted: false,
  pinned: false,
  savedMessages: saved,
  peerUserId: peer,
  group: group,
);

ContactProjection _contact(
  String userId,
  String username, {
  bool verified = false,
  String? name,
}) => ContactProjection(
  userId: userId,
  username: username,
  trustState: verified
      ? ContactTrustState.verified
      : ContactTrustState.unverified,
  authenticatedProfile: name == null
      ? null
      : AuthenticatedProfile(
          displayName: name,
          avatarSeed: 1,
          version: 1,
          authorDeviceId: 'device',
        ),
);
