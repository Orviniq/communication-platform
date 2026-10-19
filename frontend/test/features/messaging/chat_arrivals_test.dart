import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/presentation/chat_arrivals.dart';
import 'package:flutter_test/flutter_test.dart';

const _me = 'me';

/// ADR-098 D3: a message appearing from another device ends its typing line,
/// and nothing else does.
void main() {
  late List<String> reported;
  late ChatArrivals arrivals;

  setUp(() {
    reported = [];
    arrivals = ChatArrivals(currentUserId: _me, report: reported.add);
  });

  test('the first page names nobody', () {
    arrivals.follow([_message('1', sender: 'bob', device: 'B1')]);

    expect(reported, isEmpty);
  });

  test('each new message from another account names its device', () {
    arrivals
      ..follow([_message('1', sender: 'bob', device: 'B1')])
      ..follow([
        _message('1', sender: 'bob', device: 'B1'),
        _message('2', sender: 'bob', device: 'B2'),
        _message('3', sender: _me, device: 'MINE'),
        _message('4', sender: 'carol', device: 'C1'),
      ]);

    expect(reported, unorderedEquals(['b2', 'c1']));
  });

  test('an older page loaded above names nobody, and neither does the same '
      'page again', () {
    final newest = _message('5', sender: 'bob', device: 'B1');
    arrivals
      ..follow([newest])
      ..follow([_message('4', sender: 'carol', device: 'C1'), newest])
      ..follow([_message('4', sender: 'carol', device: 'C1'), newest]);

    expect(reported, isEmpty);
  });

  test('a first message into an empty conversation names its device', () {
    arrivals
      ..follow(const [])
      ..follow([_message('1', sender: 'bob', device: 'B1')]);

    expect(reported, ['b1']);
  });
}

ConversationMessage _message(
  String id, {
  required String sender,
  required String device,
}) => ConversationMessage(
  messageId: id,
  conversationId: 'conversation',
  senderUserId: sender,
  senderDeviceId: device,
  text: 'text $id',
  replyToMessageId: null,
  quoteFallback: null,
  createdMs: 1,
  orderingMs: 1,
  orderingEventId: id,
  timestampState: MessageTimestampState.plausible,
  revision: 0,
  edited: false,
  deletedForEveryone: false,
  deletedForMe: false,
  pinned: false,
  unread: false,
  transportState: MessageTransportState.received,
  receiptState: MessageReceiptState.none,
  reactions: const [],
);
