import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';

final class SendConversationEvents {
  const SendConversationEvents({
    required this.repository,
    required this.protocol,
    required this.fanout,
    required this.clock,
  });

  final ConversationRepositoryPort repository;
  final ApplicationProtocolPort protocol;
  final ApplicationFanoutPort fanout;
  final TimeSource clock;

  Future<Result<SendMessageOutcome>> sendText({
    required String currentUserId,
    required String currentDeviceId,
    required ConversationTarget target,
    required String text,
    String? replyToMessageId,
    String? quoteFallback,
  }) async {
    final identity = await _newIdentity(currentDeviceId);
    if (identity case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final values = (identity as Success<_NewEventIdentity>).value;
    final conversation = await _resolveTarget(currentUserId, target);
    if (conversation case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final resolved = (conversation as Success<_OutboundConversation>).value;
    Uint8List? reply;
    try {
      reply = replyToMessageId == null
          ? null
          : _hexBytes(replyToMessageId, expectedLength: 16);
    } on Object {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final event = _event(
      identity: values,
      conversation: resolved,
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      kind: ApplicationEventKind.messageCreate,
      references: [?reply],
      body: MessageCreateBody(
        messageId: values.eventId,
        text: text,
        replyToMessageId: reply,
        quoteFallback: quoteFallback,
      ),
    );
    return _sendMessage(event, resolved, currentUserId, currentDeviceId);
  }

  /// Recovers one message the user was told had failed.
  ///
  /// A failed send has a durable operation behind it — either a preparation
  /// that never produced ciphertext or ciphertext the relay refused — and
  /// re-arming that operation is what puts the same message back on its way.
  /// Sending the text again would leave the failed row on screen and add a
  /// second message beside it, which is what a retry is not.
  ///
  /// Falling back to a fresh send covers the one case with nothing to re-arm: a
  /// message whose operation record has already been pruned. It is the older
  /// behaviour, kept for the case that is genuinely a new send.
  Future<Result<void>> retrySend({
    required String currentUserId,
    required String currentDeviceId,
    required ConversationTarget target,
    required String messageId,
    required String text,
    String? replyToMessageId,
    String? quoteFallback,
  }) async {
    final rearmed = await fanout.retryFailedSend('application:$messageId');
    if (rearmed case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    if ((rearmed as Success<bool>).value) {
      return const Result.success(null);
    }
    final sent = await sendText(
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      target: target,
      text: text,
      replyToMessageId: replyToMessageId,
      quoteFallback: quoteFallback,
    );
    return sent.fold(
      onSuccess: (_) => const Result.success(null),
      onFailure: Result.failure,
    );
  }

  Future<Result<SendMessageOutcome>> sendAttachments({
    required String currentUserId,
    required String currentDeviceId,
    required ConversationTarget target,
    required List<EncryptedAttachmentDescriptor> attachments,
    String? caption,
    bool imageMessage = false,
  }) async {
    if (attachments.isEmpty || attachments.length > 32) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final identity = await _newIdentity(currentDeviceId);
    if (identity case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final values = (identity as Success<_NewEventIdentity>).value;
    final conversation = await _resolveTarget(currentUserId, target);
    if (conversation case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final resolved = (conversation as Success<_OutboundConversation>).value;
    final event = _event(
      identity: values,
      conversation: resolved,
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      kind: ApplicationEventKind.messageCreate,
      references: const [],
      body: MessageCreateBody(
        messageId: values.eventId,
        text: caption ?? '',
        contentType: imageMessage
            ? MessageContentType.image
            : MessageContentType.attachment,
        attachments: attachments,
      ),
    );
    return _sendMessage(event, resolved, currentUserId, currentDeviceId);
  }

  Future<Result<void>> editMessage({
    required String currentUserId,
    required String currentDeviceId,
    required String conversationId,
    required String messageId,
    required String replacementText,
  }) async {
    final authorized = await repository.requireOriginalSender(
      messageId: messageId,
      senderUserId: currentUserId,
    );
    if (authorized case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final revisionResult = await repository.nextEditRevision(
      messageId: messageId,
      senderUserId: currentUserId,
    );
    if (revisionResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return _sendMutation(
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      conversationId: conversationId,
      kind: ApplicationEventKind.messageEdit,
      targetMessageId: messageId,
      body: (target) => MessageEditBody(
        targetMessageId: target,
        replacementText: replacementText,
        revision: (revisionResult as Success<int>).value,
      ),
    );
  }

  Future<Result<void>> deleteForEveryone({
    required String currentUserId,
    required String currentDeviceId,
    required String conversationId,
    required String messageId,
  }) async {
    final authorized = await repository.requireOriginalSender(
      messageId: messageId,
      senderUserId: currentUserId,
    );
    if (authorized case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return _sendMutation(
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      conversationId: conversationId,
      kind: ApplicationEventKind.messageDelete,
      targetMessageId: messageId,
      body: (target) => MessageDeleteBody(targetMessageId: target),
    );
  }

  /// Sets or, with a null [emoji], removes this user's reaction.
  ///
  /// The value is checked before anything is encoded, because the encoder does
  /// not check it: `optionalText` writes whatever string it is handed, while
  /// the reader on the other side of the same file bounds the field at 64 bytes
  /// and 64 scalars. Without this an ordinary caller could produce an event
  /// that this client's own decoder rejects, on a path where the failure would
  /// surface as somebody else's message never arriving.
  Future<Result<void>> setReaction({
    required String currentUserId,
    required String currentDeviceId,
    required String conversationId,
    required String messageId,
    required String? emoji,
  }) {
    if (emoji != null && !isSendableReaction(emoji)) {
      return Future.value(
        const Result.failure(
          ValidationFailure(ValidationFailureKind.invalidInput),
        ),
      );
    }
    return _sendMutation(
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      conversationId: conversationId,
      kind: ApplicationEventKind.reactionSet,
      targetMessageId: messageId,
      body: (target) => ReactionSetBody(targetMessageId: target, emoji: emoji),
    );
  }

  Future<Result<void>> setPin({
    required String currentUserId,
    required String currentDeviceId,
    required String conversationId,
    required String messageId,
    required bool pinned,
  }) => _sendMutation(
    currentUserId: currentUserId,
    currentDeviceId: currentDeviceId,
    conversationId: conversationId,
    kind: ApplicationEventKind.pinSet,
    targetMessageId: messageId,
    body: (target) => PinSetBody(targetMessageId: target, pinned: pinned),
  );

  Future<Result<void>> sendReceipt({
    required String currentUserId,
    required String currentDeviceId,
    required String conversationId,
    required List<String> messageIds,
    required bool read,
  }) async {
    if (messageIds.isEmpty ||
        messageIds.length > ApplicationMessageProtocolV1.maximumReferences) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final conversationResult = await _existingConversation(conversationId);
    if (conversationResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final conversation =
        (conversationResult as Success<_OutboundConversation>).value;
    if (conversation.kind != ConversationKind.direct) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    try {
      final ids = [
        for (final messageId in messageIds)
          _hexBytes(messageId, expectedLength: 16),
      ];
      final identityResult = await _newIdentity(currentDeviceId);
      if (identityResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final event = _event(
        identity: (identityResult as Success<_NewEventIdentity>).value,
        conversation: conversation,
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
        kind: read
            ? ApplicationEventKind.receiptRead
            : ApplicationEventKind.receiptDelivered,
        references: ids,
        body: ReceiptBody(messageIds: ids),
      );
      return await _send(event, conversation, currentUserId, currentDeviceId);
    } on Object {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
  }

  Future<Result<void>> _sendMutation({
    required String currentUserId,
    required String currentDeviceId,
    required String conversationId,
    required ApplicationEventKind kind,
    required String targetMessageId,
    required ApplicationEventBody Function(Uint8List target) body,
  }) async {
    try {
      final target = _hexBytes(targetMessageId, expectedLength: 16);
      final conversationResult = await _existingConversation(conversationId);
      if (conversationResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final conversation =
          (conversationResult as Success<_OutboundConversation>).value;
      if (conversation.kind == ConversationKind.group ||
          (conversation.kind == ConversationKind.saved &&
              kind == ApplicationEventKind.messageDelete)) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      }
      final identityResult = await _newIdentity(currentDeviceId);
      if (identityResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final event = _event(
        identity: (identityResult as Success<_NewEventIdentity>).value,
        conversation: conversation,
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
        kind: kind,
        references: [target],
        body: body(target),
      );
      final sent = await _send(
        event,
        conversation,
        currentUserId,
        currentDeviceId,
      );
      return sent.fold<Result<void>>(
        onSuccess: (_) => const Result.success(null),
        onFailure: Result.failure,
      );
    } on Object {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
  }

  Future<Result<SendMessageOutcome>> _sendMessage(
    ApplicationEventRecord event,
    _OutboundConversation conversation,
    String currentUserId,
    String currentDeviceId,
  ) async {
    final sent = await _send(
      event,
      conversation,
      currentUserId,
      currentDeviceId,
    );
    return sent.fold(
      // Preparing, and not queued: at this point nothing has been sealed for
      // anybody, because who the recipients are is a question for the network
      // and this call did not ask it. Whether the answer turns out to be a
      // queue of devices or nobody at all is written to the message by the
      // cycle that finds out.
      onSuccess: (_) => Result.success(
        SendMessageOutcome(
          eventId: event.eventId,
          conversationId: event.conversationId,
          transportState: MessageTransportState.preparing,
        ),
      ),
      onFailure: Result.failure,
    );
  }

  Future<Result<void>> _send(
    ApplicationEventRecord event,
    _OutboundConversation conversation,
    String currentUserId,
    String currentDeviceId,
  ) async {
    final encodedResult = await protocol.encode(event);
    if (encodedResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final encoded = (encodedResult as Success<Uint8List>).value;
    final eventId = protocolBytesToHex(event.eventId);
    return fanout.commitLocalEcho(
      operationId: 'application:$eventId',
      eventId: eventId,
      currentUserId: currentUserId.toLowerCase(),
      currentDeviceId: currentDeviceId.toLowerCase(),
      peerUserId: conversation.peerUserId ?? currentUserId.toLowerCase(),
      openedPayload: encoded,
      applicationEvent: ApplicationEventCommit(
        event: event,
        canonicalBytes: encoded,
        currentUserId: currentUserId.toLowerCase(),
        currentDeviceId: currentDeviceId.toLowerCase(),
        conversationKind: conversation.kind.index,
        peerUserId: conversation.peerUserId,
        localOrigin: true,
        authenticatedAt: clock.now().toUtc(),
      ),
    );
  }

  ApplicationEventRecord _event({
    required _NewEventIdentity identity,
    required _OutboundConversation conversation,
    required String currentUserId,
    required String currentDeviceId,
    required ApplicationEventKind kind,
    required List<Uint8List> references,
    required ApplicationEventBody body,
  }) => ApplicationEventRecord(
    version: ApplicationMessageProtocolV1.version,
    eventId: identity.eventId,
    conversationId: conversation.id,
    kindValue: kind.wireValue,
    senderUserId: protocolUuidBytes(currentUserId),
    senderDeviceId: protocolUuidBytes(currentDeviceId),
    senderCounter: identity.senderCounter,
    createdMs: clock.now().toUtc().millisecondsSinceEpoch,
    references: references,
    body: body,
  );

  Future<Result<_NewEventIdentity>> _newIdentity(String deviceId) async {
    final idResult = await protocol.generateEventId();
    if (idResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final counterResult = await repository.reserveSenderCounter(deviceId);
    if (counterResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    return Result.success(
      _NewEventIdentity(
        eventId: (idResult as Success<Uint8List>).value,
        senderCounter: (counterResult as Success<int>).value,
      ),
    );
  }

  Future<Result<_OutboundConversation>> _resolveTarget(
    String currentUserId,
    ConversationTarget target,
  ) async {
    try {
      return await switch (target) {
        DirectConversationTarget() => _deriveDirect(
          currentUserId,
          target.peerUserId,
        ),
        SavedConversationTarget() => _deriveSaved(currentUserId),
        GroupConversationTarget() => _existingGroup(target.groupId),
      };
    } on Object {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
  }

  /// A group message names no peer. Who receives it is decided when the send
  /// is prepared, from the group's members at that moment.
  Future<Result<_OutboundConversation>> _existingGroup(String groupId) async {
    final result = await _existingConversation(groupId);
    return result.fold(
      onSuccess: (conversation) => conversation.kind == ConversationKind.group
          ? Result.success(conversation)
          : const Result.failure(
              ValidationFailure(ValidationFailureKind.invalidInput),
            ),
      onFailure: Result.failure,
    );
  }

  Future<Result<_OutboundConversation>> _deriveDirect(
    String currentUserId,
    String peerUserId,
  ) async {
    if (currentUserId.toLowerCase() == peerUserId.toLowerCase()) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final result = await protocol.deriveDirectConversationId(
      firstUserId: protocolUuidBytes(currentUserId),
      secondUserId: protocolUuidBytes(peerUserId),
    );
    return result.fold(
      onSuccess: (id) => Result.success(
        _OutboundConversation(
          id: id,
          kind: ConversationKind.direct,
          peerUserId: peerUserId.toLowerCase(),
        ),
      ),
      onFailure: Result.failure,
    );
  }

  Future<Result<_OutboundConversation>> _deriveSaved(
    String currentUserId,
  ) async {
    final result = await protocol.deriveSavedConversationId(
      protocolUuidBytes(currentUserId),
    );
    return result.fold(
      onSuccess: (id) => Result.success(
        _OutboundConversation(
          id: id,
          kind: ConversationKind.saved,
          peerUserId: null,
        ),
      ),
      onFailure: Result.failure,
    );
  }

  Future<Result<_OutboundConversation>> _existingConversation(
    String conversationId,
  ) async {
    final result = await repository.readConversation(conversationId);
    return result.fold(
      onSuccess: (conversation) {
        if (conversation == null) {
          return const Result.failure(
            ValidationFailure(ValidationFailureKind.invalidInput),
          );
        }
        try {
          return Result.success(
            _OutboundConversation(
              id: _hexBytes(conversation.conversationId, expectedLength: 32),
              kind: conversation.kind,
              peerUserId: conversation.peerUserId,
            ),
          );
        } on Object {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.integrityCheckFailed),
          );
        }
      },
      onFailure: Result.failure,
    );
  }
}

final class ManageLocalConversationState {
  const ManageLocalConversationState(this.repository);

  final ConversationRepositoryPort repository;

  Future<Result<void>> saveDraft({
    required String conversationId,
    required String? text,
  }) => repository.saveDraft(conversationId: conversationId, text: text);

  Future<Result<void>> mute({
    required String conversationId,
    required DateTime? until,
  }) => repository.setMutedUntil(
    conversationId: conversationId,
    mutedUntil: until,
  );

  Future<Result<void>> setPinned({
    required String conversationId,
    required bool pinned,
  }) => repository.setConversationPinned(
    conversationId: conversationId,
    pinned: pinned,
  );

  Future<Result<void>> deleteForMe(String messageId) =>
      repository.deleteForMe(messageId);

  Future<Result<void>> setStar({
    required String messageId,
    required bool starred,
  }) => repository.setStar(messageId: messageId, starred: starred);

  Future<Result<void>> deleteConversationForMe(String conversationId) =>
      repository.deleteConversationForMe(conversationId);

  Future<Result<List<String>>> markRead(String conversationId) =>
      repository.markConversationRead(conversationId);

  Future<Result<void>> markUnread({
    required String conversationId,
    required String currentUserId,
  }) => repository.markConversationUnread(
    conversationId: conversationId,
    currentUserId: currentUserId,
  );
}

final class FlushPendingDeliveredReceipts {
  const FlushPendingDeliveredReceipts({
    required this.repository,
    required this.sender,
    required this.currentUserId,
  });

  final ConversationRepositoryPort repository;
  final SendConversationEvents sender;
  final String currentUserId;

  Future<Result<int>> call() async {
    var completed = 0;
    while (true) {
      final pendingResult = await repository.readPendingDeliveredReceipts(
        limit: ApplicationMessageProtocolV1.maximumReferences,
      );
      if (pendingResult case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final pending =
          (pendingResult as Success<List<PendingDeliveredReceipt>>).value;
      if (pending.isEmpty) {
        return Result.success(completed);
      }
      final first = pending.first;
      final batch = pending
          .where(
            (receipt) =>
                receipt.conversationId == first.conversationId &&
                receipt.localDeviceId == first.localDeviceId,
          )
          .toList(growable: false);
      final messageIds = batch
          .map((receipt) => receipt.messageId)
          .toList(growable: false);
      final sent = await sender.sendReceipt(
        currentUserId: currentUserId,
        currentDeviceId: first.localDeviceId,
        conversationId: first.conversationId,
        messageIds: messageIds,
        read: false,
      );
      if (sent case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final removed = await repository.completePendingDeliveredReceipts(
        localDeviceId: first.localDeviceId,
        messageIds: messageIds,
      );
      if (removed case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      completed += messageIds.length;
    }
  }
}

final class MarkConversationVisiblyRead {
  const MarkConversationVisiblyRead({
    required this.repository,
    required this.sender,
  });

  final ConversationRepositoryPort repository;
  final SendConversationEvents sender;

  Future<Result<void>> call({
    required String currentUserId,
    required String currentDeviceId,
    required String conversationId,
    required bool allowReadReceipts,
  }) async {
    final marked = await repository.markConversationRead(conversationId);
    if (marked case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final ids = (marked as Success<List<String>>).value;
    if (!allowReadReceipts || ids.isEmpty) {
      return const Result.success(null);
    }
    for (
      var offset = 0;
      offset < ids.length;
      offset += ApplicationMessageProtocolV1.maximumReferences
    ) {
      final end = (offset + ApplicationMessageProtocolV1.maximumReferences)
          .clamp(0, ids.length);
      final sent = await sender.sendReceipt(
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
        conversationId: conversationId,
        messageIds: ids.sublist(offset, end),
        read: true,
      );
      if (sent case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
    }
    return const Result.success(null);
  }
}

final class _NewEventIdentity {
  _NewEventIdentity({required Uint8List eventId, required this.senderCounter})
    : eventId = Uint8List.fromList(eventId);

  final Uint8List eventId;
  final int senderCounter;
}

final class _OutboundConversation {
  _OutboundConversation({
    required Uint8List id,
    required this.kind,
    required this.peerUserId,
  }) : id = Uint8List.fromList(id);

  final Uint8List id;
  final ConversationKind kind;
  final String? peerUserId;
}

/// The wire bound the reaction field is read back under, mirrored on the send
/// side. `crypto_core_runtime.dart` decodes it with
/// `optionalText(maximumBytes: 64, maximumScalars: 64)`.
const int maximumReactionBytes = 64;
const int maximumReactionScalars = 64;

/// Whether [value] may be sent as a reaction.
///
/// `message-protocol.md` defines the value as "one normalized emoji grapheme or
/// null". Two of those words are decidable here, and both are decided before
/// the encoder runs:
///
///   * **one grapheme.** `dart:core` cannot segment grapheme clusters and
///     `package:characters` is not a dependency of this application, so the
///     emoji-relevant half of UAX #29 is implemented below. A boundary is
///     refused before an extending scalar (combining marks, variation
///     selectors, enclosing marks including the keycap, emoji modifiers and tag
///     characters), refused after a ZERO WIDTH JOINER, and refused between the
///     two regional indicators of a flag. Anything else between two scalars is
///     a boundary, so the value is more than one cluster and is rejected.
///   * **within the wire bound**, at 64 UTF-8 bytes and 64 scalars.
///
/// Whether the cluster is an *emoji* is deliberately not asserted. Deciding it
/// needs Unicode property data this application does not carry, and it is not
/// what protects the protocol - the cluster count is. What is refused outright
/// is a leading control character or space, which is never a reaction and would
/// render as an empty chip.
bool isSendableReaction(String value) {
  if (value.isEmpty) {
    return false;
  }
  final scalars = value.runes.toList(growable: false);
  if (scalars.length > maximumReactionScalars ||
      utf8.encode(value).length > maximumReactionBytes) {
    return false;
  }
  // A cluster begins with a base. A leading variation selector, combining mark
  // or ZERO WIDTH JOINER has nothing to attach to and renders as nothing, which
  // would put an empty chip on a message.
  if (_isControlOrSpace(scalars.first) || _isExtending(scalars.first)) {
    return false;
  }
  for (var index = 1; index < scalars.length; index += 1) {
    final previous = scalars[index - 1];
    final current = scalars[index];
    final continues =
        _isExtending(current) ||
        previous == _zeroWidthJoiner ||
        (index == 1 &&
            _isRegionalIndicator(previous) &&
            _isRegionalIndicator(current));
    if (!continues) {
      return false;
    }
  }
  return true;
}

const int _zeroWidthJoiner = 0x200D;

bool _isRegionalIndicator(int scalar) => scalar >= 0x1F1E6 && scalar <= 0x1F1FF;

/// Scalars that continue the cluster they follow rather than opening a new one.
bool _isExtending(int scalar) =>
    scalar == _zeroWidthJoiner ||
    (scalar >= 0x0300 && scalar <= 0x036F) ||
    (scalar >= 0x1AB0 && scalar <= 0x1AFF) ||
    (scalar >= 0x1DC0 && scalar <= 0x1DFF) ||
    (scalar >= 0x20D0 && scalar <= 0x20F0) ||
    (scalar >= 0xFE00 && scalar <= 0xFE0F) ||
    (scalar >= 0xFE20 && scalar <= 0xFE2F) ||
    (scalar >= 0x1F3FB && scalar <= 0x1F3FF) ||
    (scalar >= 0xE0020 && scalar <= 0xE007F);

bool _isControlOrSpace(int scalar) =>
    scalar <= 0x20 ||
    (scalar >= 0x7F && scalar <= 0xA0) ||
    (scalar >= 0x2000 && scalar <= 0x200C) ||
    scalar == 0x2028 ||
    scalar == 0x2029 ||
    scalar == 0x3000 ||
    scalar == 0xFEFF;

Uint8List _hexBytes(String value, {required int expectedLength}) {
  if (value.length != expectedLength * 2 ||
      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
    throw const FormatException('invalid hexadecimal identifier');
  }
  return Uint8List.fromList([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
}
