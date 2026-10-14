import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_components.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_model_mapper.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('securityGate', () {
    test('reports checking while the contact projection is unresolved', () {
      expect(
        ChatViewModelMapper.securityGate(null, resolved: false),
        ChatSecurityGate.checking,
      );
      // A trust state that arrived alongside an unresolved flag is still not an
      // answer: the caller has told us it has nothing to stand behind.
      expect(
        ChatViewModelMapper.securityGate(
          ContactTrustState.verified,
          resolved: false,
        ),
        ChatSecurityGate.checking,
      );
    });

    test('resolves a missing trust state closed', () {
      expect(
        ChatViewModelMapper.securityGate(null),
        ChatSecurityGate.unverifiedIdentity,
      );
    });

    test('maps every resolved trust state onto its gate', () {
      expect(
        ChatViewModelMapper.securityGate(ContactTrustState.verified),
        ChatSecurityGate.ready,
      );
      expect(
        ChatViewModelMapper.securityGate(ContactTrustState.unverified),
        ChatSecurityGate.unverifiedIdentity,
      );
      expect(
        ChatViewModelMapper.securityGate(ContactTrustState.identityUnavailable),
        ChatSecurityGate.unverifiedIdentity,
      );
      expect(
        ChatViewModelMapper.securityGate(ContactTrustState.invalidDevice),
        ChatSecurityGate.unverifiedDevice,
      );
      expect(
        ChatViewModelMapper.securityGate(ContactTrustState.masterKeyChanged),
        ChatSecurityGate.masterKeyChanged,
      );
      expect(
        ChatViewModelMapper.securityGate(ContactTrustState.deviceLogFork),
        ChatSecurityGate.deviceLogFork,
      );
    });
  });

  group('a group (ADR-090)', () {
    const names = {_alice: 'Alice', _bob: 'Bob'};
    String memberName(String userId) =>
        names[userId] ?? chatShortIdentity(userId);
    List<ChatMessageViewModel> mapGroup(
      ChatMessageProjection projection,
      List<ConversationMessage> source, {
      String Function(String userId)? name,
    }) => projection.mapGroup(
      source,
      currentUserId: _me,
      currentUserName: 'You',
      memberName: name ?? memberName,
    );

    test('names each author, and the author of each replied message', () {
      final views = mapGroup(ChatMessageProjection(), [
        _message('a', sender: _alice, at: 1),
        _message('b', sender: _stranger, at: 2),
        _message('c', sender: _me, at: 3),
        _message('d', sender: _bob, at: 4, replyTo: 'a'),
        _message('e', sender: _alice, at: 5, replyTo: 'b'),
        _message('f', sender: _alice, at: 6, replyTo: 'c'),
      ]);

      expect([for (final view in views) view.authorName], [
        'Alice',
        chatShortIdentity(_stranger),
        'You',
        'Bob',
        'Alice',
        'Alice',
      ]);
      expect([for (final view in views) view.replyAuthor], [
        null,
        null,
        null,
        'Alice',
        chatShortIdentity(_stranger),
        'You',
      ]);
      // A user the roster does not name is never shown by the raw id.
      expect(views[1].authorName, isNot(_stranger));
    });

    test('reads as sending until none of its copies is owed', () {
      // Moved from the group repository's own read, which this replaced.
      const states = {
        MessageTransportState.localOnly: ChatDeliveryViewState.localOnly,
        MessageTransportState.preparing: ChatDeliveryViewState.encrypting,
        MessageTransportState.queued: ChatDeliveryViewState.queued,
        MessageTransportState.sending: ChatDeliveryViewState.sending,
        // The server holds some copies and not others: the send has not ended.
        MessageTransportState.partiallyAccepted: ChatDeliveryViewState.sending,
        MessageTransportState.relayAccepted: ChatDeliveryViewState.accepted,
        MessageTransportState.permanentlyFailed: ChatDeliveryViewState.failed,
        MessageTransportState.received: ChatDeliveryViewState.received,
      };
      expect(states.keys, containsAll(MessageTransportState.values));
      for (final MapEntry(key: transport, value: delivery) in states.entries) {
        final view = mapGroup(ChatMessageProjection(), [
          _message(
            'm',
            sender: transport == MessageTransportState.received ? _alice : _me,
            at: 1,
            transport: transport,
          ),
        ]).single;
        expect(view.delivery, delivery, reason: transport.name);
      }
    });

    test('a direct chat still shows a partly accepted message as accepted', () {
      final view = ChatMessageProjection().map(
        [
          _message(
            'm',
            sender: _me,
            at: 1,
            transport: MessageTransportState.partiallyAccepted,
          ),
        ],
        currentUserId: _me,
        currentUserName: 'You',
        peerName: 'Peer',
      ).single;

      expect(view.delivery, ChatDeliveryViewState.accepted);
    });

    test('offers no Edit, Delete for everyone or Pin in a group', () {
      final source = [
        _message('own', sender: _me, at: 1),
        _message('theirs', sender: _alice, at: 2),
      ];
      final group = mapGroup(ChatMessageProjection(), source);
      final direct = ChatMessageProjection().map(
        source,
        currentUserId: _me,
        currentUserName: 'You',
        peerName: 'Peer',
      );

      for (final view in group) {
        expect(view.canEdit, isFalse, reason: view.id);
        expect(view.canDeleteForEveryone, isFalse, reason: view.id);
        expect(view.canPin, isFalse, reason: view.id);
      }
      // Where a direct chat offered them, it still does.
      expect(direct.first.canEdit, isTrue);
      expect(direct.first.canDeleteForEveryone, isTrue);
      expect(direct.first.canPin, isTrue);
      expect(direct.last.canPin, isTrue);
    });

    test('an unchanged message keeps its view model instance', () {
      final projection = ChatMessageProjection();
      List<ConversationMessage> page() => [
        _message('a', sender: _alice, at: 1),
        _message('b', sender: _bob, at: 2, replyTo: 'a'),
      ];
      final first = mapGroup(projection, page());
      final derived = projection.derivations;

      // Fresh rows, as every emission of local storage is.
      final second = mapGroup(projection, page());

      expect(projection.derivations, derived);
      expect(identical(first[0], second[0]), isTrue);
      expect(identical(first[1], second[1]), isTrue);
    });

    test("a renamed member re-derives that member's messages and the replies "
        'that quote them, and no other', () {
      final projection = ChatMessageProjection();
      final source = [
        _message('a', sender: _alice, at: 1),
        _message('b', sender: _bob, at: 100000000),
        _message('c', sender: _bob, at: 200000000, replyTo: 'a'),
        _message('d', sender: _me, at: 300000000),
      ];
      final before = mapGroup(projection, source);
      final derived = projection.derivations;

      final after = mapGroup(
        projection,
        source,
        name: (userId) => userId == _alice ? 'Alice Smith' : memberName(userId),
      );

      expect(projection.derivations - derived, 2);
      expect(after[0].authorName, 'Alice Smith');
      expect(after[2].replyAuthor, 'Alice Smith');
      expect(identical(before[1], after[1]), isTrue);
      expect(identical(before[3], after[3]), isTrue);
    });
  });
}

const _me = '00000000-0000-0000-0000-00000000000a';
const _alice = '00000000-0000-0000-0000-00000000000b';
const _bob = '00000000-0000-0000-0000-00000000000c';
const _stranger = '00000000-0000-0000-0000-00000000000d';
const _group =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

ConversationMessage _message(
  String id, {
  required String sender,
  required int at,
  String? replyTo,
  MessageTransportState? transport,
}) => ConversationMessage(
  messageId: id,
  conversationId: _group,
  senderUserId: sender,
  senderDeviceId: 'device',
  text: 'text $id',
  replyToMessageId: replyTo,
  quoteFallback: null,
  createdMs: at,
  orderingMs: at,
  orderingEventId: id,
  timestampState: MessageTimestampState.plausible,
  revision: 0,
  edited: false,
  deletedForEveryone: false,
  deletedForMe: false,
  pinned: false,
  unread: false,
  transportState:
      transport ??
      (sender == _me
          ? MessageTransportState.relayAccepted
          : MessageTransportState.received),
  receiptState: MessageReceiptState.none,
  reactions: const [],
);
