import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const currentUser = '00000000-0000-0000-0000-000000000001';
  const currentDevice = '00000000-0000-0000-0000-000000000011';
  const peerUser = '00000000-0000-0000-0000-000000000002';
  late _Repository repository;
  late _Protocol protocol;
  late _Fanout fanout;
  late SendConversationEvents sender;

  setUp(() {
    repository = _Repository();
    protocol = _Protocol();
    fanout = _Fanout();
    sender = SendConversationEvents(
      repository: repository,
      protocol: protocol,
      fanout: fanout,
      clock: const _Clock(),
    );
  });

  test(
    'text and Saved Messages sends expose honest optimistic states',
    () async {
      final direct = await sender.sendText(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        target: const DirectConversationTarget(peerUser),
        text: 'direct',
      );
      final saved = await sender.sendText(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        target: const SavedConversationTarget(),
        text: 'saved',
      );

      // Both are `preparing`, and neither could honestly be anything else. The
      // old expectations here — `queued` for a direct send, `localOnly` for
      // Saved Messages — were each a claim about a recipient set, and a send
      // that has not been near the network does not have one to claim. What
      // they distinguish is written to the message later, by the cycle that
      // finds out.
      expect(
        (direct as Success<SendMessageOutcome>).value.transportState,
        MessageTransportState.preparing,
      );
      expect(
        (saved as Success<SendMessageOutcome>).value.transportState,
        MessageTransportState.preparing,
      );
      expect(fanout.events, hasLength(2));
      expect(fanout.events.first.event.body, isA<MessageCreateBody>());
      expect(fanout.events.last.conversationKind, ConversationKind.saved.index);
      expect(fanout.events.last.peerUserId, isNull);
    },
  );

  test(
    'a retry re-arms the failed send rather than writing a second',
    () async {
      fanout.hasFailedSend = true;

      final retried = await sender.retrySend(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        target: const DirectConversationTarget(peerUser),
        messageId: 'aabb',
        text: 'once',
      );

      expect(retried, isA<Success<void>>());
      expect(fanout.rearmed, ['application:aabb']);
      expect(fanout.events, isEmpty);
    },
  );

  test('a retry with nothing durable to re-arm sends again', () async {
    fanout.hasFailedSend = false;

    final retried = await sender.retrySend(
      currentUserId: currentUser,
      currentDeviceId: currentDevice,
      target: const DirectConversationTarget(peerUser),
      messageId: 'aabb',
      text: 'once',
    );

    expect(retried, isA<Success<void>>());
    expect(fanout.rearmed, ['application:aabb']);
    expect(fanout.events, hasLength(1));
  });

  test(
    'read receipts require visible-read state and explicit privacy consent',
    () async {
      repository
        ..conversation = const ConversationSummary(
          conversationId: _directConversationHex,
          kind: ConversationKind.direct,
          peerUserId: peerUser,
          lastMessage: null,
          lastActivityMs: 0,
          unreadCount: 2,
          mutedUntil: null,
          draft: null,
          pinnedMessageIds: {},
        )
        ..unreadIds = [_messageOne, _messageTwo];
      final useCase = MarkConversationVisiblyRead(
        repository: repository,
        sender: sender,
      );

      expect(
        await useCase(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          allowReadReceipts: false,
        ),
        isA<Success<void>>(),
      );
      expect(fanout.events, isEmpty);

      repository.unreadIds = [_messageOne, _messageTwo];
      expect(
        await useCase(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          allowReadReceipts: true,
        ),
        isA<Success<void>>(),
      );
      expect(fanout.events, hasLength(1));
      expect(fanout.events.single.event.kind, ApplicationEventKind.receiptRead);
      expect(
        (fanout.events.single.event.body as ReceiptBody).messageIds,
        hasLength(2),
      );
    },
  );

  test('a conversation already read reports itself read once', () async {
    repository
      ..conversation = const ConversationSummary(
        conversationId: _directConversationHex,
        kind: ConversationKind.direct,
        peerUserId: peerUser,
        lastMessage: null,
        lastActivityMs: 0,
        unreadCount: 1,
        mutedUntil: null,
        draft: null,
        pinnedMessageIds: {},
      )
      ..unreadIds = [_messageOne];
    final useCase = MarkConversationVisiblyRead(
      repository: repository,
      sender: sender,
    );
    Future<Result<void>> visiblyRead() => useCase(
      currentUserId: currentUser,
      currentDeviceId: currentDevice,
      conversationId: _directConversationHex,
      allowReadReceipts: true,
    );

    expect(await visiblyRead(), isA<Success<void>>());
    expect(fanout.events, hasLength(1));

    // Becoming visible again is the ordinary case, not a strange one: this
    // runs on every return to the foreground and on every arrival into the
    // conversation on screen. What bounds the receipts is that the mark has
    // nothing left to clear, so there is nothing left to report.
    expect(await visiblyRead(), isA<Success<void>>());
    expect(await visiblyRead(), isA<Success<void>>());
    expect(fanout.events, hasLength(1));
  });

  test(
    'durable delivered work is removed only after fan-out is queued',
    () async {
      repository
        ..conversation = const ConversationSummary(
          conversationId: _directConversationHex,
          kind: ConversationKind.direct,
          peerUserId: peerUser,
          lastMessage: null,
          lastActivityMs: 0,
          unreadCount: 1,
          mutedUntil: null,
          draft: null,
          pinnedMessageIds: {},
        )
        ..pending = const [
          PendingDeliveredReceipt(
            messageId: _messageOne,
            conversationId: _directConversationHex,
            targetUserId: peerUser,
            localDeviceId: currentDevice,
          ),
        ];
      final flush = FlushPendingDeliveredReceipts(
        repository: repository,
        sender: sender,
        currentUserId: currentUser,
      );

      expect(await flush(), isA<Success<int>>());
      expect(
        fanout.events.single.event.kind,
        ApplicationEventKind.receiptDelivered,
      );
      expect(repository.pending, isEmpty);
    },
  );

  test('own-message mutations are authorized before fan-out', () async {
    repository.originalSender = false;

    expect(
      await sender.editMessage(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        conversationId: _directConversationHex,
        messageId: _messageOne,
        replacementText: 'unauthorized',
      ),
      isA<FailureResult<void>>(),
    );
    expect(
      await sender.deleteForEveryone(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        conversationId: _directConversationHex,
        messageId: _messageOne,
      ),
      isA<FailureResult<void>>(),
    );
    expect(fanout.events, isEmpty);
  });

  test(
    'Saved Messages supports local deletion but no remote-delete event',
    () async {
      repository.conversation = const ConversationSummary(
        conversationId: _directConversationHex,
        kind: ConversationKind.saved,
        peerUserId: null,
        lastMessage: null,
        lastActivityMs: 0,
        unreadCount: 0,
        mutedUntil: null,
        draft: null,
        pinnedMessageIds: {},
      );

      expect(
        await sender.deleteForEveryone(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageId: _messageOne,
        ),
        isA<FailureResult<void>>(),
      );
      expect(fanout.events, isEmpty);
    },
  );

  group('a reaction value is one grapheme within the wire bound', () {
    // `message-protocol.md`: the value of a reaction event is "one normalized
    // emoji grapheme or null". The encoder writes whatever string it is given
    // and only the reader is bounded, so this is the last place the two can be
    // made to agree.
    test('one cluster is one cluster however many scalars it takes', () {
      for (final value in const [
        '👍', // one scalar
        '❤️', // base + U+FE0F
        '🕊️',
        '1️⃣', // keycap: digit + U+FE0F + U+20E3
        '👍🏽', // base + emoji modifier
        '🇮🇷', // two regional indicators
        '👨‍👩‍👧', // three bases joined by U+200D
        '\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}',
        'e\u{0301}', // a base plus a combining acute is still one cluster
      ]) {
        expect(
          isSendableReaction(value),
          isTrue,
          reason: 'rejected ${value.runes.map((r) => r.toRadixString(16))}',
        );
      }
    });

    test('anything that is two clusters, empty, or blank is refused', () {
      for (final value in <String>[
        '',
        '👍👎', // two emoji
        '👍 ', // emoji then a space
        'ab',
        '🇮🇷🇮🇷', // two flags is four regional indicators
        ' ',
        '\u{200D}', // a joiner with nothing to join
        '\u{00A0}', // a no-break space
        '\n',
      ]) {
        expect(
          isSendableReaction(value),
          isFalse,
          reason: 'accepted ${value.runes.map((r) => r.toRadixString(16))}',
        );
      }
    });

    test('the wire bound is enforced on both of its axes', () {
      // 64 scalars, all extending the first, so it stays one cluster and can
      // only be refused by the bound itself.
      final atTheScalarBound = '👍${'\u{FE00}' * 63}';
      expect(atTheScalarBound.runes.length, maximumReactionScalars);
      expect(
        isSendableReaction(atTheScalarBound),
        isFalse,
        reason: 'over 64 bytes',
      );
      final overTheScalarBound = '👍${'\u{FE00}' * 64}';
      expect(isSendableReaction(overTheScalarBound), isFalse);
      // Inside both bounds, and still one cluster.
      expect(isSendableReaction('👍${'\u{FE00}' * 10}'), isTrue);
    });

    test('setReaction refuses the value before anything is encoded', () async {
      expect(
        await sender.setReaction(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageId: _messageOne,
          emoji: '👍👎',
        ),
        isA<FailureResult<void>>().having(
          (result) => result.failure,
          'failure',
          const ValidationFailure(ValidationFailureKind.invalidInput),
        ),
      );
      expect(fanout.events, isEmpty);
      expect(repository.pending, isEmpty);
    });

    test(
      'setReaction still sets one emoji and still removes with null',
      () async {
        repository.conversation = const ConversationSummary(
          conversationId: _directConversationHex,
          kind: ConversationKind.direct,
          peerUserId: peerUser,
          lastMessage: null,
          lastActivityMs: 0,
          unreadCount: 0,
          mutedUntil: null,
          draft: null,
          pinnedMessageIds: {},
        );

        expect(
          await sender.setReaction(
            currentUserId: currentUser,
            currentDeviceId: currentDevice,
            conversationId: _directConversationHex,
            messageId: _messageOne,
            emoji: '🎉',
          ),
          isA<Success<void>>(),
        );
        expect((fanout.events.last.event.body as ReactionSetBody).emoji, '🎉');
        expect(
          await sender.setReaction(
            currentUserId: currentUser,
            currentDeviceId: currentDevice,
            conversationId: _directConversationHex,
            messageId: _messageOne,
            emoji: null,
          ),
          isA<Success<void>>(),
        );
        expect(
          (fanout.events.last.event.body as ReactionSetBody).emoji,
          isNull,
        );
      },
    );
  });
}

const _directConversationHex =
    '0909090909090909090909090909090909090909090909090909090909090909';
const _messageOne = '10101010101010101010101010101010';
const _messageTwo = '11111111111111111111111111111111';

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() =>
      DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true);
}

final class _Protocol implements ApplicationProtocolPort {
  int next = 1;

  @override
  Future<Result<Uint8List>> encode(ApplicationEventRecord event) async =>
      Result.success(Uint8List.fromList([event.kindValue, ...event.eventId]));

  @override
  Future<Result<DecodedApplicationEvent>> decode(Uint8List bytes) async =>
      throw UnimplementedError();

  @override
  Future<Result<Uint8List>> deriveDirectConversationId({
    required Uint8List firstUserId,
    required Uint8List secondUserId,
  }) async => Result.success(Uint8List.fromList(List<int>.filled(32, 9)));

  @override
  Future<Result<Uint8List>> deriveSavedConversationId(Uint8List userId) async =>
      Result.success(Uint8List.fromList(List<int>.filled(32, 8)));

  @override
  Future<Result<Uint8List>> generateEventId() async =>
      Result.success(Uint8List.fromList(List<int>.filled(16, next++)));
}

final class _Fanout implements ApplicationFanoutPort {
  final List<ApplicationEventCommit> events = [];
  final List<String> rearmed = [];
  bool hasFailedSend = false;

  @override
  Future<Result<void>> commitLocalEcho({
    required String operationId,
    required String eventId,
    required String currentUserId,
    required String currentDeviceId,
    required String peerUserId,
    required Uint8List openedPayload,
    required ApplicationEventCommit applicationEvent,
  }) async {
    events.add(applicationEvent);
    return const Result.success(null);
  }

  @override
  Future<Result<bool>> retryFailedSend(String operationId) async {
    rearmed.add(operationId);
    return Result.success(hasFailedSend);
  }
}

final class _Repository implements ConversationRepositoryPort {
  int counter = 0;
  bool originalSender = true;
  ConversationSummary? conversation;
  List<String> unreadIds = [];
  List<PendingDeliveredReceipt> pending = [];

  @override
  Future<Result<void>> completePendingDeliveredReceipts({
    required String localDeviceId,
    required List<String> messageIds,
  }) async {
    pending = pending
        .where(
          (receipt) =>
              receipt.localDeviceId != localDeviceId ||
              !messageIds.contains(receipt.messageId),
        )
        .toList(growable: false);
    return const Result.success(null);
  }

  @override
  Future<Result<void>> deleteForMe(String messageId) async =>
      const Result.success(null);

  @override
  Future<Result<void>> deleteConversationForMe(String conversationId) async =>
      const Result.success(null);

  @override
  Future<Result<List<String>>> markConversationRead(
    String conversationId,
  ) async {
    final result = List<String>.of(unreadIds);
    unreadIds = [];
    return Result.success(result);
  }

  @override
  Future<Result<void>> markConversationUnread({
    required String conversationId,
    required String currentUserId,
  }) async => const Result.success(null);

  @override
  Future<Result<int>> nextEditRevision({
    required String messageId,
    required String senderUserId,
  }) async => const Result.success(1);

  @override
  Future<Result<void>> requireOriginalSender({
    required String messageId,
    required String senderUserId,
  }) async => originalSender
      ? const Result.success(null)
      : const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );

  @override
  Future<Result<List<PendingDeliveredReceipt>>> readPendingDeliveredReceipts({
    required int limit,
  }) async => Result.success(pending.take(limit).toList(growable: false));

  @override
  Future<Result<ConversationSummary?>> readConversation(
    String conversationId,
  ) async => Result.success(conversation);

  @override
  Future<Result<int>> reserveSenderCounter(String deviceId) async =>
      Result.success(++counter);

  @override
  Future<Result<void>> saveDraft({
    required String conversationId,
    required String? text,
  }) async => const Result.success(null);

  @override
  Future<Result<void>> setMutedUntil({
    required String conversationId,
    required DateTime? mutedUntil,
  }) async => const Result.success(null);

  @override
  Future<Result<void>> setConversationPinned({
    required String conversationId,
    required bool pinned,
  }) async => const Result.success(null);

  @override
  Future<Result<void>> setStar({
    required String messageId,
    required bool starred,
  }) async => const Result.success(null);

  @override
  Stream<List<ConversationSummary>> watchConversations(String currentUserId) =>
      const Stream.empty();

  @override
  Stream<ConversationMessagePage> watchMessages({
    required String currentUserId,
    required String conversationId,
    required ConversationMessageWindow window,
  }) => const Stream.empty();

  @override
  Future<Result<ConversationMessageCursor?>> olderMessageCursor({
    required String conversationId,
    required ConversationMessageCursor before,
    required int count,
  }) async => const Result.success(null);

  @override
  Future<Result<ConversationMessageCursor?>> messageCursor({
    required String conversationId,
    required String messageId,
  }) async => const Result.success(null);
}
