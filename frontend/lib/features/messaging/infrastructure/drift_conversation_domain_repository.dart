import 'dart:convert';
import 'dart:math' as math;

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/drift_repository_base.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart'
    hide MessageReaction;
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:drift/drift.dart';

final class DriftConversationDomainRepository extends DriftRepositoryBase
    implements ConversationRepositoryPort {
  const DriftConversationDomainRepository(super.database);

  @override
  Stream<List<ConversationSummary>> watchConversations(String currentUserId) {
    final query = database.select(database.conversations)
      ..where((row) => row.tombstoned.equals(false))
      ..orderBy([
        (row) => OrderingTerm.desc(row.sortKey),
        (row) => OrderingTerm.desc(row.lastActivityEventId),
        (row) => OrderingTerm.asc(row.conversationId),
      ]);
    return query.watch().asyncMap((rows) async {
      // One query for every conversation's pins, not one per conversation.
      // This used to be a `SELECT` per row, each of them a full scan of every
      // message on the device, so opening the chat list cost the square of how
      // much had been said in it.
      final pinned = await _pinnedMessageIds([
        for (final row in rows) row.conversationId,
      ]);
      return List.unmodifiable([
        for (final row in rows)
          _summary(row, pinned[row.conversationId] ?? const <String>{}),
      ]);
    });
  }

  @override
  Stream<ConversationMessagePage> watchMessages({
    required String currentUserId,
    required String conversationId,
    required ConversationMessageWindow window,
  }) {
    final query = database.select(database.messages)
      ..where((row) => row.conversationId.equals(conversationId))
      // Newest first, so a count-bounded window stops at the newest end and a
      // range-bounded one walks the index in the direction it is already
      // sorted. The page is reversed once, in memory, before it is handed on.
      ..orderBy([
        (row) => OrderingTerm.desc(row.orderingMs),
        (row) => OrderingTerm.desc(row.orderingEventId),
        (row) => OrderingTerm.desc(row.messageId),
      ]);
    switch (window) {
      case NewestConversationMessages(:final count):
        query.limit(count < 1 ? 1 : count);
      case ConversationMessagesFrom(:final oldest):
        query.where((row) => _atOrAfter(row, oldest));
    }
    return query.watch().asyncMap(
      (rows) => _projectPage(conversationId: conversationId, newestFirst: rows),
    );
  }

  @override
  Future<Result<ConversationMessageCursor?>> olderMessageCursor({
    required String conversationId,
    required ConversationMessageCursor before,
    required int count,
  }) async {
    if (count < 1) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    try {
      // Three columns and a limit, which the ordering index covers outright:
      // no row is read and nothing before the answer is visited. This is the
      // whole reason the window is a cursor and not an offset.
      final query = database.selectOnly(database.messages)
        ..addColumns([
          database.messages.orderingMs,
          database.messages.orderingEventId,
          database.messages.messageId,
        ])
        ..where(
          database.messages.conversationId.equals(conversationId) &
              _strictlyBefore(database.messages, before),
        )
        ..orderBy([
          OrderingTerm.desc(database.messages.orderingMs),
          OrderingTerm.desc(database.messages.orderingEventId),
          OrderingTerm.desc(database.messages.messageId),
        ])
        ..limit(count);
      final rows = await query.get();
      if (rows.isEmpty) {
        return const Result.success(null);
      }
      final last = rows.last;
      return Result.success(
        ConversationMessageCursor(
          orderingMs: last.read<int>(database.messages.orderingMs)!,
          orderingEventId: last.read<String>(
            database.messages.orderingEventId,
          )!,
          messageId: last.read<String>(database.messages.messageId)!,
        ),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<ConversationMessageCursor?>> messageCursor({
    required String conversationId,
    required String messageId,
  }) async {
    try {
      final row =
          await (database.select(database.messages)..where(
                (item) =>
                    item.messageId.equals(messageId) &
                    item.conversationId.equals(conversationId),
              ))
              .getSingleOrNull();
      if (row == null) {
        return const Result.success(null);
      }
      return Result.success(
        ConversationMessageCursor(
          orderingMs: row.orderingMs,
          orderingEventId: row.orderingEventId,
          messageId: row.messageId,
        ),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  /// Everything one emission of [watchMessages] needs, in five statements.
  ///
  /// Four of them are set-based over the whole window rather than per message,
  /// which is the N+1 this replaces: the timeline used to run one reaction, one
  /// receipt and one attachment query for every message in the conversation, on
  /// every emission, and re-ran all of them when any one message changed.
  Future<ConversationMessagePage> _projectPage({
    required String conversationId,
    required List<Message> newestFirst,
  }) async {
    final pinned = await _pinnedMessages(conversationId);
    if (newestFirst.isEmpty) {
      return ConversationMessagePage(
        messages: const [],
        pinned: pinned,
        hasMoreBefore: false,
      );
    }
    final oldest = ConversationMessageCursor(
      orderingMs: newestFirst.last.orderingMs,
      orderingEventId: newestFirst.last.orderingEventId,
      messageId: newestFirst.last.messageId,
    );
    final hasMoreBefore = await _existsBefore(conversationId, oldest);
    final reactions = await _reactionsIn(conversationId, oldest);
    final receipts = await _receiptStatesIn(conversationId, oldest);
    final attachments = await _attachmentsIn(conversationId, oldest);
    return ConversationMessagePage(
      messages: List.unmodifiable([
        for (final row in newestFirst.reversed)
          _message(
            row,
            reactions: reactions[row.messageId] ?? const [],
            receiptState: receipts[row.messageId] ?? MessageReceiptState.none,
            attachments: attachments[row.messageId] ?? const [],
          ),
      ]),
      pinned: pinned,
      hasMoreBefore: hasMoreBefore,
    );
  }

  /// The window, named once so the page and its three set-based reads cannot
  /// disagree about what it contains.
  Expression<bool> _windowOf(
    String conversationId,
    ConversationMessageCursor oldest,
  ) =>
      database.messages.conversationId.equals(conversationId) &
      _atOrAfter(database.messages, oldest);

  Future<bool> _existsBefore(
    String conversationId,
    ConversationMessageCursor oldest,
  ) async {
    final query = database.selectOnly(database.messages)
      ..addColumns([database.messages.messageId])
      ..where(
        database.messages.conversationId.equals(conversationId) &
            _strictlyBefore(database.messages, oldest),
      )
      ..limit(1);
    return (await query.get()).isNotEmpty;
  }

  Future<Map<String, List<MessageReaction>>> _reactionsIn(
    String conversationId,
    ConversationMessageCursor oldest,
  ) async {
    final query = database.select(database.messageReactions).join([
      innerJoin(
        database.messages,
        database.messages.messageId.equalsExp(
          database.messageReactions.messageId,
        ),
        useColumns: false,
      ),
    ])..where(_windowOf(conversationId, oldest));
    final grouped = <String, List<MessageReaction>>{};
    for (final row in await query.get()) {
      final reaction = row.readTable(database.messageReactions);
      if (reaction.emojiCiphertext == null) continue;
      (grouped[reaction.messageId] ??= []).add(
        MessageReaction(
          reactingUserId: reaction.reactingUserId,
          emoji: utf8.decode(reaction.emojiCiphertext!, allowMalformed: false),
        ),
      );
    }
    // Ordered here rather than in SQL. The join drives from the message index,
    // so an `ORDER BY` on the reaction would have made SQLite sort the whole
    // result through a temporary B-tree to settle the order of the handful of
    // reactions each message has.
    for (final reactions in grouped.values) {
      reactions.sort(
        (left, right) => left.reactingUserId.compareTo(right.reactingUserId),
      );
    }
    return grouped;
  }

  Future<Map<String, MessageReceiptState>> _receiptStatesIn(
    String conversationId,
    ConversationMessageCursor oldest,
  ) async {
    final query = database.select(database.receipts).join([
      innerJoin(
        database.messages,
        database.messages.messageId.equalsExp(database.receipts.messageId),
        useColumns: false,
      ),
    ])..where(_windowOf(conversationId, oldest));
    final states = <String, MessageReceiptState>{};
    for (final row in await query.get()) {
      final receipt = row.readTable(database.receipts);
      final state = MessageReceiptState.values[receipt.receiptState];
      final current = states[receipt.messageId] ?? MessageReceiptState.none;
      if (state.index > current.index) {
        states[receipt.messageId] = state;
      }
    }
    return states;
  }

  Future<Map<String, List<_DecodedAttachment>>> _attachmentsIn(
    String conversationId,
    ConversationMessageCursor oldest,
  ) async {
    final query = database.select(database.attachments).join([
      innerJoin(
        database.messages,
        database.messages.messageId.equalsExp(database.attachments.messageId),
        useColumns: false,
      ),
    ])..where(_windowOf(conversationId, oldest));
    final grouped = <String, List<_DecodedAttachment>>{};
    for (final row in await query.get()) {
      final attachment = row.readTable(database.attachments);
      final decoded = _decodeAttachment(attachment);
      if (decoded == null) continue;
      (grouped[attachment.messageId] ??= []).add(decoded);
    }
    return grouped;
  }

  /// The conversation's pinned messages, complete rather than page-scoped.
  ///
  /// Complete because the surface that lists them also counts them, and a
  /// banner reading three above a sheet listing one is a wrong answer rather
  /// than a narrower one. Cheap because a pin is rare and
  /// `messages_pinned_by_conversation` holds only pinned rows — which is also
  /// why the predicate is spelled `pinned` and not `pinned = ?`: a bound
  /// parameter proves nothing at prepare time, so SQLite will not choose a
  /// partial index for it.
  Future<List<ConversationMessage>> _pinnedMessages(
    String conversationId,
  ) async {
    final rows =
        await (database.select(database.messages)..where(
              (row) =>
                  row.conversationId.equals(conversationId) &
                  _pinnedRows &
                  row.deletedForMe.equals(false),
            ))
            .get();
    // Ordered here rather than in SQL, and not for tidiness: an `ORDER BY` on
    // the ordering columns is enough for SQLite to prefer the index that
    // satisfies the sort over the partial index that answers the question,
    // reading a row for every message in the conversation to find the few that
    // are pinned. There are never many pins.
    rows.sort((left, right) {
      final byTime = left.orderingMs.compareTo(right.orderingMs);
      if (byTime != 0) return byTime;
      final byEvent = left.orderingEventId.compareTo(right.orderingEventId);
      return byEvent != 0 ? byEvent : left.messageId.compareTo(right.messageId);
    });
    // Identity and text only. Nothing reads a pin's reactions, receipts or
    // attachments, and reading them would be three more statements per
    // emission for a sheet that renders one line per pin.
    return List.unmodifiable([
      for (final row in rows)
        _message(
          row,
          reactions: const [],
          receiptState: MessageReceiptState.none,
          attachments: const [],
        ),
    ]);
  }

  Future<Map<String, Set<String>>> _pinnedMessageIds(
    List<String> conversationIds,
  ) async {
    if (conversationIds.isEmpty) {
      return const {};
    }
    final query = database.selectOnly(database.messages)
      ..addColumns([
        database.messages.conversationId,
        database.messages.messageId,
      ])
      ..where(
        _pinnedRows &
            database.messages.deletedForMe.equals(false) &
            database.messages.conversationId.isIn(conversationIds),
      );
    final grouped = <String, Set<String>>{};
    for (final row in await query.get()) {
      final conversationId = row.read<String>(
        database.messages.conversationId,
      )!;
      (grouped[conversationId] ??= <String>{}).add(
        row.read<String>(database.messages.messageId)!,
      );
    }
    return grouped;
  }

  ConversationSummary _summary(Conversation row, Set<String> pinnedMessageIds) {
    return ConversationSummary(
      conversationId: row.conversationId,
      kind: ConversationKind.values[row.kind],
      peerUserId: row.peerUserId,
      lastMessage: _optionalText(row.listProjectionCiphertext),
      lastActivityMs: row.sortKey,
      unreadCount: row.unreadCount,
      mutedUntil: row.mutedUntil?.toUtc(),
      draft: _optionalText(row.draftCiphertext),
      pinnedMessageIds: Set.unmodifiable(pinnedMessageIds),
      pinned: row.pinned,
      displayTitle: _optionalText(row.displayTitleCiphertext),
    );
  }

  ConversationMessage _message(
    Message row, {
    required List<MessageReaction> reactions,
    required MessageReceiptState receiptState,
    required List<_DecodedAttachment> attachments,
  }) {
    return ConversationMessage(
      messageId: row.messageId,
      conversationId: row.conversationId,
      senderUserId: row.senderUserId,
      senderDeviceId: row.senderDeviceId,
      text: row.deletedForEveryone
          ? null
          : _optionalText(row.projectionCiphertext),
      attachments: List.unmodifiable([
        for (final attachment in attachments) attachment.descriptor,
      ]),
      attachmentStates: List.unmodifiable([
        for (final attachment in attachments) attachment.state,
      ]),
      replyToMessageId: row.replyToMessageId,
      quoteFallback: _optionalText(row.quoteFallbackCiphertext),
      createdMs: row.createdAt.millisecondsSinceEpoch,
      orderingMs: row.orderingMs,
      orderingEventId: row.orderingEventId,
      timestampState: MessageTimestampState.values[row.timestampState],
      revision: row.revision,
      edited: row.revision > 0,
      deletedForEveryone: row.deletedForEveryone,
      deletedForMe: row.deletedForMe,
      pinned: row.pinned,
      starred: row.starred,
      unread: row.unread,
      transportState: MessageTransportState.values[row.status],
      receiptState: receiptState,
      reactions: List.unmodifiable(reactions),
    );
  }

  _DecodedAttachment? _decodeAttachment(Attachment attachment) {
    try {
      final value = jsonDecode(
        utf8.decode(attachment.encryptedDescriptor, allowMalformed: false),
      );
      if (value is! Map<String, Object?>) return null;
      return _DecodedAttachment(
        descriptor: EncryptedAttachmentDescriptor(
          capabilityId: value['capability']! as String,
          key: base64Url.decode(value['key']! as String),
          header: base64Url.decode(value['header']! as String),
          secretstreamHeader: base64Url.decode(
            value['stream_header']! as String,
          ),
          encryptedSize: value['encrypted_size']! as int,
          bucketSize: value['bucket_size']! as int,
          plaintextSize: value['plaintext_size']! as int,
          displayName: value['name']! as String,
          mimeType: value['mime']! as String,
          mediaKind: AttachmentMediaKind.values[value['media_kind']! as int],
          width: value['width'] as int?,
          height: value['height'] as int?,
          caption: value['caption'] as String?,
          thumbnail: value['thumbnail'] == null
              ? null
              : base64Url.decode(value['thumbnail']! as String),
        ),
        state:
            AttachmentTransferState.values[math.min(
              math.max(attachment.transferState, 0),
              AttachmentTransferState.values.length - 1,
            )],
      );
    } on Object {
      // Malformed local descriptors remain invisible until the next
      // authenticated event rebuild; they are never presented.
      return null;
    }
  }

  @override
  Future<Result<int>> reserveSenderCounter(String deviceId) {
    return runWrite(() async {
      final normalized = deviceId.toLowerCase();
      final existing = await (database.select(
        database.applicationSenderCounters,
      )..where((row) => row.deviceId.equals(normalized))).getSingleOrNull();
      final previous = existing?.lastCounter ?? 0;
      if (previous >= 0x7fffffffffffffff) {
        throw const _CounterExhausted();
      }
      final next = previous + 1;
      await database
          .into(database.applicationSenderCounters)
          .insertOnConflictUpdate(
            ApplicationSenderCountersCompanion.insert(
              deviceId: normalized,
              lastCounter: Value(next),
            ),
          );
      return next;
    });
  }

  @override
  Future<Result<int>> nextEditRevision({
    required String messageId,
    required String senderUserId,
  }) async {
    try {
      final query = database.selectOnly(database.storedApplicationEvents)
        ..addColumns([database.storedApplicationEvents.revision.max()])
        ..where(
          database.storedApplicationEvents.targetMessageId.equals(messageId) &
              database.storedApplicationEvents.senderUserId.equals(
                senderUserId.toLowerCase(),
              ) &
              database.storedApplicationEvents.kind.equals(
                ApplicationEventKind.messageEdit.wireValue,
              ),
        );
      final row = await query.getSingle();
      final current =
          row.read(database.storedApplicationEvents.revision.max()) ?? 0;
      return Result.success(current + 1);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> requireOriginalSender({
    required String messageId,
    required String senderUserId,
  }) async {
    try {
      final message = await (database.select(
        database.messages,
      )..where((row) => row.messageId.equals(messageId))).getSingleOrNull();
      if (message == null) {
        return const Result.failure(
          ValidationFailure(ValidationFailureKind.invalidInput),
        );
      }
      if (message.senderUserId != senderUserId.toLowerCase()) {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.policyBlocked),
        );
      }
      return const Result.success(null);
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<ConversationSummary?>> readConversation(
    String conversationId,
  ) async {
    try {
      final row =
          await (database.select(database.conversations)..where(
                (conversation) =>
                    conversation.conversationId.equals(conversationId),
              ))
              .getSingleOrNull();
      if (row == null) {
        return const Result.success(null);
      }
      final pinned = await _pinnedMessageIds([conversationId]);
      return Result.success(
        _summary(row, pinned[conversationId] ?? const <String>{}),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> saveDraft({
    required String conversationId,
    required String? text,
  }) {
    if (text != null &&
        (utf8.encode(text).length >
                ApplicationMessageProtocolV1.maximumTextBytes ||
            text.runes.length >
                ApplicationMessageProtocolV1.maximumTextScalars)) {
      return Future.value(
        const Result.failure(
          ValidationFailure(ValidationFailureKind.limitExceeded),
        ),
      );
    }
    return runWrite(() async {
      final updated =
          await (database.update(
            database.conversations,
          )..where((row) => row.conversationId.equals(conversationId))).write(
            ConversationsCompanion(
              draftCiphertext: Value(
                text == null || text.isEmpty
                    ? null
                    : Uint8List.fromList(utf8.encode(text)),
              ),
            ),
          );
      if (updated != 1) {
        throw const _MissingConversation();
      }
    });
  }

  @override
  Future<Result<void>> setMutedUntil({
    required String conversationId,
    required DateTime? mutedUntil,
  }) => runWrite(() async {
    final updated =
        await (database.update(
          database.conversations,
        )..where((row) => row.conversationId.equals(conversationId))).write(
          ConversationsCompanion(mutedUntil: Value(mutedUntil?.toUtc())),
        );
    if (updated != 1) {
      throw const _MissingConversation();
    }
  });

  @override
  Future<Result<void>> setConversationPinned({
    required String conversationId,
    required bool pinned,
  }) => runWrite(() async {
    final updated =
        await (database.update(database.conversations)
              ..where((row) => row.conversationId.equals(conversationId)))
            .write(ConversationsCompanion(pinned: Value(pinned)));
    if (updated != 1) {
      throw const _MissingConversation();
    }
  });

  @override
  Future<Result<void>> deleteForMe(String messageId) => runWrite(() async {
    final updated =
        await (database.update(
          database.messages,
        )..where((row) => row.messageId.equals(messageId))).write(
          const MessagesCompanion(
            deletedForMe: Value(true),
            unread: Value(false),
          ),
        );
    if (updated != 1) {
      throw const _MissingMessage();
    }
    await (database.update(
      database.attachments,
    )..where((row) => row.messageId.equals(messageId))).write(
      const AttachmentsCompanion(
        boundedCacheHandleCiphertext: Value(null),
        cacheExpiresAt: Value(null),
      ),
    );
    await _refreshUnreadCountForMessage(messageId);
  });

  @override
  Future<Result<void>> setStar({
    required String messageId,
    required bool starred,
  }) => runWrite(() async {
    final updated =
        await (database.update(database.messages)
              ..where((row) => row.messageId.equals(messageId)))
            .write(MessagesCompanion(starred: Value(starred)));
    if (updated != 1) {
      throw const _MissingMessage();
    }
  });

  @override
  Future<Result<void>> deleteConversationForMe(String conversationId) =>
      runWrite(() async {
        final updated =
            await (database.update(
              database.conversations,
            )..where((row) => row.conversationId.equals(conversationId))).write(
              const ConversationsCompanion(
                tombstoned: Value(true),
                unreadCount: Value(0),
                draftCiphertext: Value(null),
              ),
            );
        if (updated != 1) {
          throw const _MissingConversation();
        }
        await (database.update(
          database.messages,
        )..where((row) => row.conversationId.equals(conversationId))).write(
          const MessagesCompanion(
            deletedForMe: Value(true),
            unread: Value(false),
          ),
        );
      });

  @override
  Future<Result<List<String>>> markConversationRead(String conversationId) =>
      runWrite(() async {
        final conversation =
            await (database.select(database.conversations)
                  ..where((row) => row.conversationId.equals(conversationId)))
                .getSingleOrNull();
        if (conversation == null) {
          throw const _MissingConversation();
        }
        final unread =
            await (database.select(database.messages)..where(
                  (row) =>
                      row.conversationId.equals(conversationId) &
                      row.unread.equals(true) &
                      row.deletedForMe.equals(false),
                ))
                .get();
        // Nothing to say, and saying it anyway is not free. This is called
        // every time the conversation on screen becomes visible or receives
        // anything, and a `conversations` write is observed by the chat list
        // whether or not it changed a value: re-deriving every summary for a
        // count that was already zero is the cost, and an observer that marks
        // read in response to the write it just caused is the loop.
        if (unread.isEmpty && conversation.unreadCount == 0) {
          return const <String>[];
        }
        if (unread.isNotEmpty) {
          await (database.update(database.messages)..where(
                (row) =>
                    row.conversationId.equals(conversationId) &
                    row.unread.equals(true),
              ))
              .write(const MessagesCompanion(unread: Value(false)));
        }
        // Reached with no unread rows when the aggregate has drifted above
        // them, which is the one case worth a write that changes nothing else.
        await (database.update(database.conversations)
              ..where((row) => row.conversationId.equals(conversationId)))
            .write(const ConversationsCompanion(unreadCount: Value(0)));
        return List.unmodifiable(unread.map((message) => message.messageId));
      });

  @override
  Future<Result<void>> markConversationUnread({
    required String conversationId,
    required String currentUserId,
  }) => runWrite(() async {
    final conversation =
        await (database.select(database.conversations)
              ..where((row) => row.conversationId.equals(conversationId)))
            .getSingleOrNull();
    if (conversation == null) {
      throw const _MissingConversation();
    }
    if (ConversationKind.values[conversation.kind] == ConversationKind.saved) {
      return;
    }
    final latestIncoming =
        await (database.select(database.messages)
              ..where(
                (row) =>
                    row.conversationId.equals(conversationId) &
                    row.senderUserId.equals(currentUserId.toLowerCase()).not() &
                    row.deletedForMe.equals(false),
              )
              ..orderBy([
                (row) => OrderingTerm.desc(row.orderingMs),
                (row) => OrderingTerm.desc(row.orderingEventId),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (latestIncoming == null) {
      return;
    }
    await (database.update(database.messages)
          ..where((row) => row.messageId.equals(latestIncoming.messageId)))
        .write(const MessagesCompanion(unread: Value(true)));
    await (database.update(database.conversations)
          ..where((row) => row.conversationId.equals(conversationId)))
        .write(const ConversationsCompanion(unreadCount: Value(1)));
  });

  @override
  Future<Result<List<PendingDeliveredReceipt>>> readPendingDeliveredReceipts({
    required int limit,
  }) async {
    if (limit < 1 || limit > ApplicationMessageProtocolV1.maximumReferences) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.limitExceeded),
      );
    }
    try {
      final rows =
          await (database.select(database.pendingApplicationReceipts)
                ..orderBy([
                  (row) => OrderingTerm.asc(row.createdAt),
                  (row) => OrderingTerm.asc(row.messageId),
                ])
                ..limit(limit))
              .get();
      return Result.success(
        List.unmodifiable(
          rows.map(
            (row) => PendingDeliveredReceipt(
              messageId: row.messageId,
              conversationId: row.conversationId,
              targetUserId: row.targetUserId,
              localDeviceId: row.localDeviceId,
            ),
          ),
        ),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<void>> completePendingDeliveredReceipts({
    required String localDeviceId,
    required List<String> messageIds,
  }) {
    if (messageIds.isEmpty ||
        messageIds.length > ApplicationMessageProtocolV1.maximumReferences) {
      return Future.value(
        const Result.failure(
          ValidationFailure(ValidationFailureKind.invalidInput),
        ),
      );
    }
    return runWrite(() async {
      await (database.delete(database.pendingApplicationReceipts)..where(
            (row) =>
                row.localDeviceId.equals(localDeviceId.toLowerCase()) &
                row.messageId.isIn(messageIds),
          ))
          .go();
      // The durable half of the same fact. Deleting the queue row alone said
      // only that this receipt is not queued *right now*, and the next
      // projection rebuild re-derived it from the message and queued it again.
      // This is what makes the receipt spent.
      await (database.update(database.messages)
            ..where((row) => row.messageId.isIn(messageIds)))
          .write(const MessagesCompanion(deliveredReceiptSent: Value(true)));
    });
  }

  Future<void> _refreshUnreadCountForMessage(String messageId) async {
    final message = await (database.select(
      database.messages,
    )..where((row) => row.messageId.equals(messageId))).getSingle();
    final countExpression = database.messages.messageId.count();
    final countRow =
        await (database.selectOnly(database.messages)
              ..addColumns([countExpression])
              ..where(
                database.messages.conversationId.equals(
                      message.conversationId,
                    ) &
                    database.messages.unread.equals(true) &
                    database.messages.deletedForMe.equals(false),
              ))
            .getSingle();
    await (database.update(
      database.conversations,
    )..where((row) => row.conversationId.equals(message.conversationId))).write(
      ConversationsCompanion(
        unreadCount: Value(countRow.read(countExpression) ?? 0),
      ),
    );
  }
}

/// A window's lower bound, as a predicate SQLite can use as a range.
///
/// The redundant leading term is deliberate. Written as one nested `OR`, the
/// comparison is a filter the planner applies row by row after choosing an
/// access path; written with `ordering_ms >= ?` in front of it, the same
/// comparison becomes a range constraint on the second column of
/// `messages_conversation_ordering` and the scan starts at the boundary
/// instead of at the conversation's newest message. The two forms admit
/// exactly the same rows.
Expression<bool> _atOrAfter(
  $MessagesTable row,
  ConversationMessageCursor cursor,
) {
  return row.orderingMs.isBiggerOrEqualValue(cursor.orderingMs) &
      (row.orderingMs.isBiggerThanValue(cursor.orderingMs) |
          row.orderingEventId.isBiggerThanValue(cursor.orderingEventId) |
          (row.orderingEventId.equals(cursor.orderingEventId) &
              row.messageId.isBiggerOrEqualValue(cursor.messageId)));
}

/// The mirror of [_atOrAfter], strictly below the cursor.
Expression<bool> _strictlyBefore(
  $MessagesTable row,
  ConversationMessageCursor cursor,
) {
  return row.orderingMs.isSmallerOrEqualValue(cursor.orderingMs) &
      (row.orderingMs.isSmallerThanValue(cursor.orderingMs) |
          row.orderingEventId.isSmallerThanValue(cursor.orderingEventId) |
          (row.orderingEventId.equals(cursor.orderingEventId) &
              row.messageId.isSmallerThanValue(cursor.messageId)));
}

/// `pinned`, unbound.
///
/// `messages_pinned_by_conversation` is partial, and SQLite will only choose a
/// partial index when the query's `WHERE` provably implies the index's. A bound
/// `pinned = ?` does not: the value is unknown when the statement is prepared.
/// Written as the bare column it does, and the planner reads a handful of index
/// entries instead of every message on the device.
const _pinnedRows = CustomExpression<bool>('pinned');

final class _DecodedAttachment {
  const _DecodedAttachment({required this.descriptor, required this.state});

  final EncryptedAttachmentDescriptor descriptor;
  final AttachmentTransferState state;
}

String? _optionalText(Uint8List? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return utf8.decode(value, allowMalformed: false);
}

final class _CounterExhausted implements Exception {
  const _CounterExhausted();
}

final class _MissingConversation implements Exception {
  const _MissingConversation();
}

final class _MissingMessage implements Exception {
  const _MissingMessage();
}
