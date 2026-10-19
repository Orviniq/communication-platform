import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/infrastructure/group_pairwise_adapters.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/application/ports/attachment_sweep_port.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/attachment_descriptor_fixture.dart';

void main() {
  const currentUser = '00000000-0000-0000-0000-000000000001';
  const currentDevice = '00000000-0000-0000-0000-000000000011';
  const peerUser = '00000000-0000-0000-0000-000000000002';
  late _Repository repository;
  late _Protocol protocol;
  late _Fanout fanout;
  late _Sweep sweep;
  late SendConversationEvents sender;

  setUp(() {
    repository = _Repository();
    protocol = _Protocol();
    fanout = _Fanout();
    sweep = _Sweep();
    sender = SendConversationEvents(
      repository: repository,
      protocol: protocol,
      fanout: fanout,
      clock: const _Clock(),
      attachments: sweep,
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

  group('an attachment message (ADR-089 D11)', () {
    final photo = testAttachmentDescriptor(
      capability: testCapability(4),
      displayName: 'photo.jpg',
      mimeType: 'image/jpeg',
      mediaKind: AttachmentMediaKind.image,
    );
    final minutes = testAttachmentDescriptor(capability: testCapability(5));

    test('retried with nothing to re-arm sends its descriptors and its '
        'caption, never the caption alone', () async {
      fanout.hasFailedSend = false;

      final retried = await sender.retrySend(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        target: const DirectConversationTarget(peerUser),
        messageId: 'aabb',
        text: 'the view',
        replyToMessageId: _messageOne,
        attachments: [photo],
        imageMessage: true,
      );

      expect(retried, isA<Success<void>>());
      expect(fanout.rearmed, ['application:aabb']);
      final body = fanout.events.single.event.body as MessageCreateBody;
      expect(body.attachments.single.capabilityId, photo.capabilityId);
      expect(body.contentType, MessageContentType.image);
      expect(body.text, 'the view');
      expect(body.replyToMessageId, isNull);
    });

    test(
      'retried with no caption sends the descriptors with no text',
      () async {
        fanout.hasFailedSend = false;

        await sender.retrySend(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          target: const SavedConversationTarget(),
          messageId: 'aabb',
          text: '',
          attachments: [minutes],
        );

        final body = fanout.events.single.event.body as MessageCreateBody;
        expect(body.attachments.single.capabilityId, minutes.capabilityId);
        expect(body.contentType, MessageContentType.attachment);
        expect(body.text, isEmpty);
      },
    );

    test('retried with a send to re-arm sends nothing new', () async {
      fanout.hasFailedSend = true;

      await sender.retrySend(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        target: const DirectConversationTarget(peerUser),
        messageId: 'aabb',
        text: 'the view',
        attachments: [photo],
      );

      expect(fanout.events, isEmpty);
    });

    test(
      'forwarded sends its descriptors and its caption to each target',
      () async {
        for (final target in const <ConversationTarget>[
          DirectConversationTarget(peerUser),
          SavedConversationTarget(),
        ]) {
          final sent = await sender.forward(
            currentUserId: currentUser,
            currentDeviceId: currentDevice,
            target: target,
            text: 'minutes for Monday',
            attachments: [minutes],
          );
          expect(sent, isA<Success<SendMessageOutcome>>());
        }

        expect(fanout.events, hasLength(2));
        for (final event in fanout.events) {
          final body = event.event.body as MessageCreateBody;
          expect(body.attachments.single.capabilityId, minutes.capabilityId);
          expect(body.text, 'minutes for Monday');
          expect(body.contentType, MessageContentType.attachment);
        }
        expect(fanout.events.first.peerUserId, peerUser);
        expect(fanout.events.last.peerUserId, isNull);
      },
    );

    test('a forwarded text message keeps its own path', () async {
      await sender.forward(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        target: const DirectConversationTarget(peerUser),
        text: 'just words',
        quoteFallback: 'a quote',
      );

      final body = fanout.events.single.event.body as MessageCreateBody;
      expect(body.attachments, isEmpty);
      expect(body.contentType, MessageContentType.text);
      expect(body.text, 'just words');
      expect(body.quoteFallback, 'a quote');
    });
  });

  test('a malformed peer id is refused rather than thrown', () async {
    // The id is parsed inside an async helper, so a malformed one comes
    // back as a failed future, which only an awaited return lets the
    // surrounding catch turn into a failure.
    final sent = await sender.sendText(
      currentUserId: currentUser,
      currentDeviceId: currentDevice,
      target: const DirectConversationTarget('not-a-user-id'),
      text: 'never sent',
    );

    expect(
      sent,
      isA<FailureResult<SendMessageOutcome>>().having(
        (result) => result.failure,
        'failure',
        const ValidationFailure(ValidationFailureKind.invalidInput),
      ),
    );
    expect(fanout.events, isEmpty);
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

  test('durable delivered work survives a fan-out that throws', () async {
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
    fanout.commitError = Exception('the database is locked');
    final flush = FlushPendingDeliveredReceipts(
      repository: repository,
      sender: sender,
      currentUserId: currentUser,
    );

    // Awaited inside the send's try block, the fan-out's failure becomes a
    // result the flush stops on, and the receipt waits for the next flush.
    expect(await flush(), isA<FailureResult<int>>());
    expect(repository.pending, hasLength(1));
  });

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

  test('a committed deletion sweeps the attachment cache, and a refused '
      'one does not (ADR-089 D10)', () async {
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
    final local = ManageLocalConversationState(repository, attachments: sweep);

    expect(
      await sender.deleteForEveryone(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        conversationId: _directConversationHex,
        messageId: _messageOne,
      ),
      isA<Success<void>>(),
    );
    expect(sweep.sweeps, 1);
    expect(await local.deleteForMe(_messageTwo), isA<Success<void>>());
    expect(sweep.sweeps, 2);
    expect(
      await local.deleteConversationForMe(_directConversationHex),
      isA<Success<void>>(),
    );
    expect(sweep.sweeps, 3);

    repository.originalSender = false;
    expect(
      await sender.deleteForEveryone(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        conversationId: _directConversationHex,
        messageId: _messageOne,
      ),
      isA<FailureResult<void>>(),
    );
    expect(sweep.sweeps, 3);
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

  group('into a group conversation (ADR-090 D3, ADR-096 D4 to D6)', () {
    const policyBlocked = SecurityFailure(SecurityFailureKind.policyBlocked);
    late _Moderation moderation;

    /// The send path with the roster's answers of [moderation].
    SendConversationEvents moderated() => SendConversationEvents(
      repository: repository,
      protocol: protocol,
      fanout: fanout,
      clock: const _Clock(),
      attachments: sweep,
      groupModeration: moderation,
    );

    setUp(() {
      repository.conversation = const ConversationSummary(
        conversationId: _directConversationHex,
        kind: ConversationKind.group,
        peerUserId: null,
        lastMessage: null,
        lastActivityMs: 0,
        unreadCount: 0,
        mutedUntil: null,
        draft: null,
        pinnedMessageIds: {},
      );
      // An own message, and one another member wrote.
      repository.senders = {_messageOne: currentUser, _messageTwo: peerUser};
      moderation = _Moderation();
    });

    test('a reaction commits one event of the kind reactionSet', () async {
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

      expect(fanout.events, hasLength(1));
      final committed = fanout.events.single;
      expect(
        committed.event.kindValue,
        ApplicationEventKind.reactionSet.wireValue,
      );
      expect(committed.conversationKind, ConversationKind.group.index);
      expect(committed.peerUserId, isNull);
      final body = committed.event.body as ReactionSetBody;
      expect(body.emoji, '🎉');
      expect(protocolBytesToHex(body.targetMessageId), _messageOne);
      expect(committed.event.references, [body.targetMessageId]);
    });

    test('a reaction removed with a null emoji is committed as such', () async {
      await sender.setReaction(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        conversationId: _directConversationHex,
        messageId: _messageOne,
        emoji: null,
      );

      expect(
        (fanout.events.single.event.body as ReactionSetBody).emoji,
        isNull,
      );
    });

    test(
      'an invalid reaction value is refused before anything is sent',
      () async {
        expect(
          await sender.setReaction(
            currentUserId: currentUser,
            currentDeviceId: currentDevice,
            conversationId: _directConversationHex,
            messageId: _messageOne,
            emoji: '👍👎',
          ),
          isA<FailureResult<void>>(),
        );
        expect(fanout.events, isEmpty);
      },
    );

    test('a delete for everyone of an own message commits one messageDelete '
        'and sweeps the cache (ADR-096 D4)', () async {
      expect(
        await sender.deleteForEveryone(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageId: _messageOne,
        ),
        isA<Success<void>>(),
      );

      final committed = fanout.events.single;
      expect(
        committed.event.kindValue,
        ApplicationEventKind.messageDelete.wireValue,
      );
      expect(committed.conversationKind, ConversationKind.group.index);
      expect(committed.peerUserId, isNull);
      final body = committed.event.body as MessageDeleteBody;
      expect(protocolBytesToHex(body.targetMessageId), _messageOne);
      expect(committed.event.references, [body.targetMessageId]);
      expect(sweep.sweeps, 1);
    });

    test(
      'a delete for everyone of another member\'s message is refused '
      'when the roles do not allow it, or no roster answers (ADR-096 D5)',
      () async {
        for (final events in [sender, moderated()]) {
          expect(
            await events.deleteForEveryone(
              currentUserId: currentUser,
              currentDeviceId: currentDevice,
              conversationId: _directConversationHex,
              messageId: _messageTwo,
            ),
            isA<FailureResult<void>>().having(
              (result) => result.failure,
              'failure',
              policyBlocked,
            ),
          );
        }
        // The roster was asked about the author of the message.
        expect(moderation.deleteAsks, [
          (_directConversationHex, currentUser, peerUser),
        ]);
        expect(fanout.events, isEmpty);
        expect(sweep.sweeps, 0);
      },
    );

    test('a delete for everyone of another member\'s message goes out when '
        'the roles allow it (ADR-096 D5)', () async {
      moderation.delete = const Result.success(true);

      expect(
        await moderated().deleteForEveryone(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageId: _messageTwo,
        ),
        isA<Success<void>>(),
      );

      final committed = fanout.events.single;
      expect(
        committed.event.kindValue,
        ApplicationEventKind.messageDelete.wireValue,
      );
      expect(
        protocolBytesToHex(
          (committed.event.body as MessageDeleteBody).targetMessageId,
        ),
        _messageTwo,
      );
      expect(sweep.sweeps, 1);
    });

    test('a roster that cannot be read refuses with its own failure', () async {
      const unavailable = StorageFailure(StorageFailureKind.unavailable);
      moderation
        ..delete = const Result.failure(unavailable)
        ..pin = const Result.failure(unavailable);

      expect(
        await moderated().deleteForEveryone(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageId: _messageTwo,
        ),
        isA<FailureResult<void>>().having(
          (result) => result.failure,
          'failure',
          unavailable,
        ),
      );
      expect(
        await moderated().setPin(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageId: _messageTwo,
          pinned: true,
        ),
        isA<FailureResult<void>>().having(
          (result) => result.failure,
          'failure',
          unavailable,
        ),
      );
      expect(fanout.events, isEmpty);
    });

    test('a delete of a message the group does not hold is refused', () async {
      moderation.delete = const Result.success(true);

      expect(
        await moderated().deleteForEveryone(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageId: '12121212121212121212121212121212',
        ),
        isA<FailureResult<void>>(),
      );
      expect(moderation.deleteAsks, isEmpty);
      expect(fanout.events, isEmpty);
    });

    test('a pin is refused unless the roles let this user pin, and goes '
        'out when they do (ADR-096 D6)', () async {
      for (final events in [sender, moderated()]) {
        expect(
          await events.setPin(
            currentUserId: currentUser,
            currentDeviceId: currentDevice,
            conversationId: _directConversationHex,
            messageId: _messageTwo,
            pinned: true,
          ),
          isA<FailureResult<void>>().having(
            (result) => result.failure,
            'failure',
            policyBlocked,
          ),
        );
      }
      expect(fanout.events, isEmpty);

      moderation.pin = const Result.success(true);
      expect(
        await moderated().setPin(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageId: _messageTwo,
          pinned: false,
        ),
        isA<Success<void>>(),
      );
      final committed = fanout.events.single;
      expect(committed.event.kindValue, ApplicationEventKind.pinSet.wireValue);
      expect((committed.event.body as PinSetBody).pinned, isFalse);
      expect(moderation.pinAsks, [
        (_directConversationHex, currentUser),
        (_directConversationHex, currentUser),
      ]);
    });

    test('an edit is refused and commits nothing (ADR-096 D8)', () async {
      moderation.delete = const Result.success(true);
      moderation.pin = const Result.success(true);

      expect(
        await moderated().editMessage(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageId: _messageOne,
          replacementText: 'changed',
        ),
        isA<FailureResult<void>>().having(
          (result) => result.failure,
          'failure',
          policyBlocked,
        ),
      );
      expect(fanout.events, isEmpty);
      expect(sweep.sweeps, 0);
    });

    test(
      'the group sender port carries a pin into the group conversation',
      () async {
        moderation.pin = const Result.success(true);

        expect(
          await ConversationGroupMessageSender(moderated()).setPin(
            currentUserId: currentUser,
            currentDeviceId: currentDevice,
            groupId: _directConversationHex,
            messageId: _messageTwo,
            pinned: true,
          ),
          isA<Success<void>>(),
        );
        expect(
          fanout.events.single.event.kindValue,
          ApplicationEventKind.pinSet.wireValue,
        );
      },
    );

    test('a reply goes out with its reference and its quote', () async {
      expect(
        await sender.sendText(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          target: const GroupConversationTarget(_directConversationHex),
          text: 'an answer',
          replyToMessageId: _messageOne,
          quoteFallback: 'the question',
        ),
        isA<Success<SendMessageOutcome>>(),
      );

      final event = fanout.events.single.event;
      final body = event.body as MessageCreateBody;
      expect(body.text, 'an answer');
      expect(protocolBytesToHex(body.replyToMessageId!), _messageOne);
      expect(body.quoteFallback, 'the question');
      expect(event.references, [body.replyToMessageId]);
    });

    test('the group sender port carries a reply, a retry and a reaction into '
        'the group conversation', () async {
      final port = ConversationGroupMessageSender(sender);

      expect(
        await port.sendText(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          groupId: _directConversationHex,
          text: 'an answer',
          replyToMessageId: _messageOne,
          quoteFallback: 'the question',
        ),
        isA<Success<void>>(),
      );
      fanout.hasFailedSend = false;
      expect(
        await port.retryText(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          groupId: _directConversationHex,
          messageId: 'aabb',
          text: 'an answer',
          replyToMessageId: _messageOne,
          quoteFallback: 'the question',
        ),
        isA<Success<void>>(),
      );
      expect(
        await port.setReaction(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          groupId: _directConversationHex,
          messageId: _messageOne,
          emoji: '🎉',
        ),
        isA<Success<void>>(),
      );

      expect(fanout.events, hasLength(3));
      for (final committed in fanout.events.take(2)) {
        final body = committed.event.body as MessageCreateBody;
        expect(protocolBytesToHex(body.replyToMessageId!), _messageOne);
        expect(body.quoteFallback, 'the question');
      }
      expect(
        fanout.events.last.event.kindValue,
        ApplicationEventKind.reactionSet.wireValue,
      );
      expect(
        fanout.events.map((committed) => committed.conversationKind),
        everyElement(ConversationKind.group.index),
      );
    });

    test('a retry with nothing to re-arm keeps the reply', () async {
      fanout.hasFailedSend = false;

      expect(
        await sender.retrySend(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          target: const GroupConversationTarget(_directConversationHex),
          messageId: 'aabb',
          text: 'an answer',
          replyToMessageId: _messageOne,
          quoteFallback: 'the question',
        ),
        isA<Success<void>>(),
      );

      final body = fanout.events.single.event.body as MessageCreateBody;
      expect(protocolBytesToHex(body.replyToMessageId!), _messageOne);
      expect(body.quoteFallback, 'the question');
    });
  });

  group('read receipts in a group (ADR-091 D2 to D4)', () {
    const otherMember = '00000000-0000-0000-0000-000000000003';

    setUp(() {
      repository.conversation = const ConversationSummary(
        conversationId: _directConversationHex,
        kind: ConversationKind.group,
        peerUserId: null,
        lastMessage: null,
        lastActivityMs: 0,
        unreadCount: 0,
        mutedUntil: null,
        draft: null,
        pinnedMessageIds: {},
      );
    });

    Future<Result<void>> receipt(List<String> messageIds, {bool read = true}) =>
        sender.sendReceipt(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          messageIds: messageIds,
          read: read,
        );

    /// The ids each committed receipt names, in the order they were sent.
    List<List<String>> receipts() => [
      for (final committed in fanout.events)
        [
          for (final id in (committed.event.body as ReceiptBody).messageIds)
            protocolBytesToHex(id),
        ],
    ];

    test(
      'a read receipt is accepted, and a delivered receipt is refused',
      () async {
        repository.senders = {_messageOne: peerUser, _messageTwo: peerUser};

        expect(await receipt([_messageOne, _messageTwo]), isA<Success<void>>());
        expect(
          fanout.events.single.event.kind,
          ApplicationEventKind.receiptRead,
        );
        expect(
          fanout.events.single.conversationKind,
          ConversationKind.group.index,
        );
        expect(receipts(), [
          [_messageOne, _messageTwo],
        ]);

        expect(
          await receipt([_messageOne], read: false),
          isA<FailureResult<void>>().having(
            (result) => result.failure,
            'failure',
            const SecurityFailure(SecurityFailureKind.policyBlocked),
          ),
        );
        expect(fanout.events, hasLength(1));
      },
    );

    test('a receipt that names messages of two senders is refused, and '
        'nothing is written', () async {
      repository.senders = {_messageOne: peerUser, _messageTwo: otherMember};

      expect(
        await receipt([_messageOne, _messageTwo]),
        isA<FailureResult<void>>().having(
          (result) => result.failure,
          'failure',
          const ValidationFailure(ValidationFailureKind.invalidInput),
        ),
      );
      expect(fanout.events, isEmpty);
      // Not even a sender counter is spent on it.
      expect(repository.counter, 0);
    });

    test('a receipt that names a message the group does not hold is refused, '
        'and nothing is written', () async {
      repository.senders = {_messageOne: peerUser};

      expect(
        await receipt([_messageOne, _messageTwo]),
        isA<FailureResult<void>>(),
      );
      expect(fanout.events, isEmpty);
      expect(repository.counter, 0);
    });

    test('a visible read sends one receipt for each sender, and splits more '
        'than 64 messages of one sender', () async {
      final fromPeer = [for (var index = 0; index < 70; index += 1) _id(index)];
      final fromOther = [_id(100), _id(101)];
      // As the timeline orders them: the two senders interleaved.
      repository
        ..senders = {
          for (final id in fromPeer) id: peerUser,
          for (final id in fromOther) id: otherMember,
        }
        ..unreadIds = [
          fromPeer.first,
          fromOther.first,
          ...fromPeer.skip(1),
          fromOther.last,
        ];

      expect(
        await MarkConversationVisiblyRead(
          repository: repository,
          sender: sender,
        )(
          currentUserId: currentUser,
          currentDeviceId: currentDevice,
          conversationId: _directConversationHex,
          allowReadReceipts: true,
        ),
        isA<Success<void>>(),
      );

      expect(receipts(), [
        fromPeer.sublist(0, 64),
        fromPeer.sublist(64),
        fromOther,
      ]);
      expect(
        fanout.events.map((committed) => committed.event.kind),
        everyElement(ApplicationEventKind.receiptRead),
      );
    });

    test(
      'a visible read without consent clears the group and sends nothing',
      () async {
        repository
          ..senders = {_messageOne: peerUser}
          ..unreadIds = [_messageOne];

        expect(
          await MarkConversationVisiblyRead(
            repository: repository,
            sender: sender,
          )(
            currentUserId: currentUser,
            currentDeviceId: currentDevice,
            conversationId: _directConversationHex,
            allowReadReceipts: false,
          ),
          isA<Success<void>>(),
        );
        expect(repository.unreadIds, isEmpty);
        expect(fanout.events, isEmpty);
      },
    );
  });

  test('a direct chat still sends one receipt of up to 64 ids, in the order '
      'read', () async {
    final unread = [for (var index = 0; index < 70; index += 1) _id(index)];
    repository
      ..conversation = const ConversationSummary(
        conversationId: _directConversationHex,
        kind: ConversationKind.direct,
        peerUserId: peerUser,
        lastMessage: null,
        lastActivityMs: 0,
        unreadCount: 70,
        mutedUntil: null,
        draft: null,
        pinnedMessageIds: {},
      )
      ..unreadIds = unread;

    expect(
      await MarkConversationVisiblyRead(repository: repository, sender: sender)(
        currentUserId: currentUser,
        currentDeviceId: currentDevice,
        conversationId: _directConversationHex,
        allowReadReceipts: true,
      ),
      isA<Success<void>>(),
    );

    expect(
      [
        for (final committed in fanout.events)
          [
            for (final id in (committed.event.body as ReceiptBody).messageIds)
              protocolBytesToHex(id),
          ],
      ],
      [unread.sublist(0, 64), unread.sublist(64)],
    );
    // A direct chat has one sender to tell, and asks for no senders.
    expect(repository.senderReads, 0);
  });

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

/// A distinct message id for each [index].
String _id(int index) => 'b${index.toRadixString(16).padLeft(31, '0')}';

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

final class _Sweep implements AttachmentSweepPort {
  int sweeps = 0;

  @override
  Future<void> sweepAfterDeletion() async {
    sweeps += 1;
  }
}

final class _Fanout implements ApplicationFanoutPort {
  final List<ApplicationEventCommit> events = [];
  final List<String> rearmed = [];
  bool hasFailedSend = false;
  Exception? commitError;

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
    final error = commitError;
    if (error != null) {
      throw error;
    }
    events.add(applicationEvent);
    return const Result.success(null);
  }

  @override
  Future<Result<bool>> retryFailedSend(String operationId) async {
    rearmed.add(operationId);
    return Result.success(hasFailedSend);
  }
}

/// The roster's answers, and who asked.
final class _Moderation implements GroupMessageModerationPort {
  Result<bool> delete = const Result.success(false);
  Result<bool> pin = const Result.success(false);
  final deleteAsks = <(String, String, String)>[];
  final pinAsks = <(String, String)>[];

  @override
  Future<Result<bool>> mayDeleteMessageOf({
    required String groupId,
    required String actorUserId,
    required String authorUserId,
  }) async {
    deleteAsks.add((groupId, actorUserId, authorUserId));
    return delete;
  }

  @override
  Future<Result<bool>> mayPin({
    required String groupId,
    required String actorUserId,
  }) async {
    pinAsks.add((groupId, actorUserId));
    return pin;
  }
}

final class _Repository implements ConversationRepositoryPort {
  int counter = 0;
  bool originalSender = true;
  ConversationSummary? conversation;
  List<String> unreadIds = [];
  List<PendingDeliveredReceipt> pending = [];

  /// The sender of each message the conversation holds.
  Map<String, String> senders = {};
  int senderReads = 0;

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
  Future<Result<Map<String, String>>> readMessageSenders({
    required String conversationId,
    required List<String> messageIds,
  }) async {
    senderReads += 1;
    return Result.success({
      for (final messageId in messageIds) messageId: ?senders[messageId],
    });
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
  Stream<List<MessageReader>> watchMessageReaders(String messageId) =>
      const Stream.empty();

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
