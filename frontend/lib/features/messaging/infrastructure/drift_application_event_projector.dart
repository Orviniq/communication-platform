import 'dart:convert';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:drift/drift.dart';

enum ApplicationApplyDisposition {
  applied,
  duplicate,
  eventIdConflict,
  senderCounterRollback,
  policyRejected,
}

final class ApplicationApplyResult {
  const ApplicationApplyResult({
    required this.disposition,
    required this.eventId,
  });

  final ApplicationApplyDisposition disposition;
  final String eventId;
}

/// Executes only inside an existing Drift transaction owned by send/receive.
///
/// Projection rebuilds use the complete authenticated fact set, never arrival
/// order, so late dependencies and counter conflicts deterministically converge.
final class DriftApplicationEventProjector {
  const DriftApplicationEventProjector(this.database);

  static const int maximumFutureClockSkewMs = 5 * 60 * 1000;
  static const int earliestPlausibleTimestampMs = 946684800000;

  /// How far behind the conversation a sender's clock may be and still be read
  /// as a clock that is wrong rather than as a message that is late.
  ///
  /// Both are real. A phone with no time source drifts, and a phone that was in
  /// a tunnel sends something genuinely written minutes ago. Nothing in the
  /// event tells the two apart, so the correction is bounded instead: a minute
  /// covers the drift of a phone nobody has synchronised, and it is short
  /// enough that a message which really was late is moved by less than the
  /// timeline's own display resolution can show.
  static const int maximumOrderingClockSkewMs = 60 * 1000;

  static const int _stateCandidate = 0;
  static const int _stateEventIdConflict = 1;
  static const int _stateCounterConflict = 2;
  static const int _stateConversationRejected = 3;

  static const int _quarantineEventIdConflict = 10;
  static const int _quarantineCounterRollback = 11;
  static const int _quarantineConversationPolicy = 12;
  static const int _quarantineMessageIdCollision = 14;

  final LocalDatabase database;

  Future<ApplicationApplyResult> applyInsideTransaction(
    ApplicationEventCommit commit,
  ) async {
    final event = commit.event;
    final eventId = protocolBytesToHex(event.eventId);
    if (!_validCommit(commit)) {
      await _quarantine(_quarantineConversationPolicy, event.eventId);
      return ApplicationApplyResult(
        disposition: ApplicationApplyDisposition.policyRejected,
        eventId: eventId,
      );
    }

    final retained = await (database.select(
      database.unsupportedApplicationEvents,
    )..where((row) => row.eventId.equals(eventId))).getSingleOrNull();
    if (retained != null) {
      if (_same(retained.retainedPayload, commit.canonicalBytes)) {
        await (database.delete(
          database.unsupportedApplicationEvents,
        )..where((row) => row.recordKey.equals(retained.recordKey))).go();
      } else {
        await (database.update(
          database.unsupportedApplicationEvents,
        )..where((row) => row.recordKey.equals(retained.recordKey))).write(
          const UnsupportedApplicationEventsCompanion(
            applyState: Value(_stateEventIdConflict),
          ),
        );
        await _quarantine(_quarantineEventIdConflict, event.eventId);
        return ApplicationApplyResult(
          disposition: ApplicationApplyDisposition.eventIdConflict,
          eventId: eventId,
        );
      }
    }

    final existing = await (database.select(
      database.storedApplicationEvents,
    )..where((row) => row.eventId.equals(eventId))).getSingleOrNull();
    if (existing != null) {
      if (_same(existing.canonicalEvent, commit.canonicalBytes)) {
        return ApplicationApplyResult(
          disposition: ApplicationApplyDisposition.duplicate,
          eventId: eventId,
        );
      }
      await (database.update(
        database.storedApplicationEvents,
      )..where((row) => row.eventId.equals(eventId))).write(
        const StoredApplicationEventsCompanion(
          applyState: Value(_stateEventIdConflict),
        ),
      );
      await _quarantine(_quarantineEventIdConflict, event.eventId);
      await _rebuildConversation(
        existing.conversationId,
        currentUserId: commit.currentUserId,
      );
      return ApplicationApplyResult(
        disposition: ApplicationApplyDisposition.eventIdConflict,
        eventId: eventId,
      );
    }

    final conversationId = protocolBytesToHex(event.conversationId);
    final peerUserId = commit.peerUserId?.toLowerCase();
    final currentConversation =
        await (database.select(database.conversations)
              ..where((row) => row.conversationId.equals(conversationId)))
            .getSingleOrNull();
    if (currentConversation != null &&
        (currentConversation.kind != commit.conversationKind ||
            currentConversation.peerUserId != peerUserId)) {
      await _insertEvent(
        commit,
        applyState: _stateConversationRejected,
        orderingMs: 0,
      );
      await _quarantine(_quarantineConversationPolicy, event.eventId);
      return ApplicationApplyResult(
        disposition: ApplicationApplyDisposition.policyRejected,
        eventId: eventId,
      );
    }
    // `RETURNING`, so creating the conversation and reading the row the
    // projection needs are the same statement rather than two.
    final conversation =
        currentConversation ??
        await database
            .into(database.conversations)
            .insertReturning(
              ConversationsCompanion.insert(
                conversationId: conversationId,
                kind: commit.conversationKind,
                listProjectionCiphertext: Uint8List(0),
                sortKey: 0,
                peerUserId: Value(peerUserId),
              ),
            );

    // `sort_key` is the newest message already projected into this
    // conversation, refreshed by `_refreshConversationAggregates` at the end of
    // every apply. The row is in hand, so the floor costs no read at all.
    final orderingMs = _orderingTimestamp(
      event,
      commit.authenticatedAt,
      conversation.sortKey,
    );
    final fact = await _insertEvent(
      commit,
      applyState: _stateCandidate,
      orderingMs: orderingMs,
    );

    final collisions =
        await (database.select(database.storedApplicationEvents)..where(
              (row) =>
                  row.senderDeviceId.equals(
                    protocolUuidString(event.senderDeviceId),
                  ) &
                  row.senderCounter.equals(event.senderCounter),
            ))
            .get();
    final unsupportedCollisions =
        await (database.select(database.unsupportedApplicationEvents)..where(
              (row) =>
                  row.senderDeviceId.equals(
                    protocolUuidString(event.senderDeviceId),
                  ) &
                  row.senderCounter.equals(event.senderCounter),
            ))
            .get();
    final affectedConversations = <String>{conversationId};
    var rollback = false;
    final collidingEventIds = <String>{
      ...collisions.map((row) => row.eventId),
      ...unsupportedCollisions.map((row) => row.eventId).whereType<String>(),
    };
    if (collidingEventIds.length > 1) {
      rollback = true;
      affectedConversations.addAll(collisions.map((row) => row.conversationId));
      await (database.update(database.storedApplicationEvents)..where(
            (row) =>
                row.senderDeviceId.equals(
                  protocolUuidString(event.senderDeviceId),
                ) &
                row.senderCounter.equals(event.senderCounter),
          ))
          .write(
            const StoredApplicationEventsCompanion(
              applyState: Value(_stateCounterConflict),
            ),
          );
      await (database.update(database.unsupportedApplicationEvents)..where(
            (row) =>
                row.senderDeviceId.equals(
                  protocolUuidString(event.senderDeviceId),
                ) &
                row.senderCounter.equals(event.senderCounter),
          ))
          .write(
            const UnsupportedApplicationEventsCompanion(
              applyState: Value(_stateCounterConflict),
            ),
          );
      await _quarantine(_quarantineCounterRollback, event.eventId);
    }

    // Where the two paths part, and the only place they do.
    //
    // A sender-counter rollback retires events that were already folded into
    // the projection, in this conversation and possibly in others, so what the
    // projection should now say is not a function of the event that was just
    // applied. That is the recovery path's question and it gets the recovery
    // path's answer. Everything else — which is every message received, every
    // edit, every reaction, every pin and every receipt — is one new fact about
    // a known set of messages, and costs that set rather than the conversation.
    if (rollback) {
      for (final affectedConversation in affectedConversations) {
        await _rebuildConversation(
          affectedConversation,
          currentUserId: commit.currentUserId,
        );
      }
    } else {
      await _applyFactIncrementally(
        conversation: conversation,
        fact: fact,
        currentUserId: commit.currentUserId,
      );
    }
    return ApplicationApplyResult(
      disposition: rollback
          ? ApplicationApplyDisposition.senderCounterRollback
          : ApplicationApplyDisposition.applied,
      eventId: eventId,
    );
  }

  /// Re-folds only the messages [fact] is a fact about.
  ///
  /// The affected set is derived from the event's own body, and it has two
  /// shapes because the protocol has two. An edit, a delete, a reaction and a
  /// pin each name one target; a `messageCreate` names the message it creates;
  /// a receipt names **many**, and one receipt legitimately covering a batch of
  /// messages is the ordinary case rather than the pathological one. So the
  /// unit of work is a set of message ids, and the cost is that set's size —
  /// one, or the number of ids the receipt actually carries.
  ///
  /// Each of those messages is then re-folded from *every* stored fact about
  /// it, not from the event in hand. That is what makes a mutation arriving
  /// before its create work: the edit sat in `application_events` with its
  /// target row beside it, and the create that arrives later re-reads it along
  /// with everything else aimed at that message id.
  ///
  /// A fold that cannot read one of its own facts declines, and the caller
  /// falls back to the rebuild — which is the same escalation the rebuild
  /// itself performs, marking the unreadable fact rejected before continuing.
  Future<void> _applyFactIncrementally({
    required Conversation conversation,
    required _EventFact fact,
    required String currentUserId,
  }) async {
    for (final messageId in _affectedMessageIds(fact)) {
      final facts = await _factsForMessage(
        conversation.conversationId,
        messageId,
      );
      if (facts == null) {
        await _rebuildConversation(
          conversation.conversationId,
          currentUserId: currentUserId,
        );
        return;
      }
      await _projectOneMessage(
        conversation: conversation,
        messageId: messageId,
        facts: facts,
        currentUserId: currentUserId,
        applied: fact,
      );
    }
    await _refreshConversationAggregates(conversation.conversationId);
  }

  /// Writes, or removes, the projection of one message.
  ///
  /// Removal is explicit here because an incremental apply runs no sweep. The
  /// rebuild ends with `DELETE ... WHERE message_id NOT IN (everything it
  /// projected)`, and that single statement is how a message whose create
  /// collided with another, or was quarantined, or references a reply this
  /// device cannot verify, stops being on the timeline. With no sweep the same
  /// three cases have to be recognised one message at a time, and the delete is
  /// scoped to the conversation as well as the id: a fact in one conversation
  /// referencing a message id created in another must not be able to delete it.
  Future<void> _projectOneMessage({
    required Conversation conversation,
    required String messageId,
    required List<_EventFact> facts,
    required String currentUserId,
    required _EventFact applied,
  }) async {
    final creates = facts
        .where(
          (fact) =>
              fact.row.kind == ApplicationEventKind.messageCreate.wireValue &&
              fact.body['message_id'] == messageId,
        )
        .toList(growable: false);
    if (creates.length > 1) {
      for (final collision in creates) {
        await _quarantine(
          _quarantineMessageIdCollision,
          _hexToBytes(collision.row.eventId),
        );
      }
    }
    if (creates.length != 1 || !_referencesAreValid(creates.single)) {
      await _removeMessage(conversation.conversationId, messageId);
      return;
    }
    final existing =
        await (database.select(database.messages)..where(
              (row) =>
                  row.messageId.equals(messageId) &
                  row.conversationId.equals(conversation.conversationId),
            ))
            .getSingleOrNull();
    final localState = existing == null
        ? null
        : _LocalMessageState.of(existing);
    final projected = await _projectMessage(
      conversation: conversation,
      create: creates.single,
      facts: facts,
      currentUserId: currentUserId.toLowerCase(),
      localState: localState,
    );
    // A child table is rewritten only by an event that could have changed it.
    // Reactions and receipts are each derived from one kind of fact, so an
    // edit, a delete or a pin leaves both alone — and a row that did not change
    // is not deleted and re-inserted. A message being projected for the first
    // time writes both, because everything already stored for it is arriving at
    // once.
    final kind = ApplicationEventKind.fromWireValue(applied.row.kind);
    await _writeMessage(
      projected,
      localState: localState,
      rewriteReactions:
          existing == null || kind == ApplicationEventKind.reactionSet,
      rewriteReceipts:
          existing == null ||
          kind == ApplicationEventKind.receiptDelivered ||
          kind == ApplicationEventKind.receiptRead,
    );
  }

  Future<void> _removeMessage(String conversationId, String messageId) async {
    await (database.delete(database.messages)..where(
          (row) =>
              row.messageId.equals(messageId) &
              row.conversationId.equals(conversationId),
        ))
        .go();
  }

  /// Every candidate fact in [conversationId] that is about [messageId].
  ///
  /// Driven from `application_event_targets`, whose primary key leads with the
  /// message id, so this is a seek into the handful of entries that message has
  /// and one primary-key lookup into the log for each. Joining back to
  /// `application_events` is not a convenience: the target table is derived
  /// state, and the join is what makes a stale entry in it match nothing rather
  /// than fabricate a fact.
  ///
  /// **`CROSS JOIN`, and it is load-bearing.** Written as an ordinary join,
  /// SQLite picks the order, and with no statistics it picks the other one:
  /// `SEARCH application_events USING INDEX
  /// application_events_conversation_apply_state (conversation_id=? AND
  /// apply_state=?)` and then a probe of the target index for every candidate
  /// event in the conversation. That is one statement and a linear number of
  /// rows — the cost this phase exists to remove, hidden from a statement count
  /// and visible only in `EXPLAIN QUERY PLAN`, which is why
  /// `local_database_index_plan_test.dart` asserts the order rather than
  /// trusting it. `CROSS JOIN` is SQLite's documented way to fix a join order,
  /// and it admits exactly the same rows.
  ///
  /// The conversation is part of the predicate for the same reason the rebuild
  /// reads one conversation's events: a reference is a claim by whoever sent it,
  /// and a claim about a message id belonging to some other conversation must
  /// not reach that conversation's projection.
  ///
  /// Returns null when a stored body cannot be decoded, which is not a fold this
  /// path can complete.
  Future<List<_EventFact>?> _factsForMessage(
    String conversationId,
    String messageId,
  ) async {
    final rows = await database
        .customSelect(
          'SELECT event.* FROM application_event_targets target '
          'CROSS JOIN application_events event '
          'ON event.event_id = target.event_id '
          'WHERE target.message_id = ? AND event.conversation_id = ? '
          'AND event.apply_state = ?',
          variables: [
            Variable<String>(messageId),
            Variable<String>(conversationId),
            const Variable<int>(_stateCandidate),
          ],
          readsFrom: {
            database.applicationEventTargets,
            database.storedApplicationEvents,
          },
        )
        .get();
    final facts = <_EventFact>[];
    for (final row in rows) {
      final event = database.storedApplicationEvents.map(row.data);
      try {
        facts.add(_EventFact(row: event, body: _decodeBody(event)));
      } on Object {
        return null;
      }
    }
    return facts;
  }

  /// The messages [fact] is a fact about.
  ///
  /// Total over every kind the projector stores, including the ones that name
  /// no message at all, so that adding a kind to the protocol is a change here
  /// rather than a silent omission from the index.
  Set<String> _affectedMessageIds(_EventFact fact) {
    switch (ApplicationEventKind.fromWireValue(fact.row.kind)) {
      case ApplicationEventKind.messageCreate:
        final messageId = fact.body['message_id'];
        return messageId is String ? {messageId} : const {};
      case ApplicationEventKind.messageEdit:
      case ApplicationEventKind.messageDelete:
      case ApplicationEventKind.reactionSet:
      case ApplicationEventKind.pinSet:
        final target = fact.row.targetMessageId;
        return target == null ? const {} : {target};
      case ApplicationEventKind.receiptDelivered:
      case ApplicationEventKind.receiptRead:
        return {
          for (final id
              in fact.body['message_ids'] as List<Object?>? ?? const [])
            if (id is String) id,
        };
      case ApplicationEventKind.typingSet:
      case null:
        return const {};
    }
  }

  /// The conversation-level aggregates, read back from what was projected.
  ///
  /// Both paths call this, which is what makes "identical to what a rebuild
  /// would produce" true by construction rather than by argument: there is one
  /// definition of the conversation's preview, ordering key, last activity and
  /// unread count, and it is a function of the message rows rather than of
  /// whichever messages the caller happened to touch.
  ///
  /// Neither read is a pass over the conversation. The newest message is one
  /// entry and one row through `messages_conversation_ordering`, whose column
  /// order is this exact `ORDER BY` ([ADR-062](decisions.md)); the unread count
  /// reads `messages_unread_by_conversation`, which is partial and therefore
  /// holds only the rows being counted.
  Future<void> _refreshConversationAggregates(String conversationId) async {
    final latest =
        await (database.select(database.messages)
              ..where((row) => row.conversationId.equals(conversationId))
              ..orderBy([
                (row) => OrderingTerm.desc(row.orderingMs),
                (row) => OrderingTerm.desc(row.orderingEventId),
              ])
              ..limit(1))
            .getSingleOrNull();
    // `COUNT(*)` rather than `COUNT(message_id)`, because it needs no column
    // and the partial index is therefore covering: the count reads index
    // entries and no message rows at all.
    final unread = countAll();
    final counted =
        await (database.selectOnly(database.messages)
              ..addColumns([unread])
              ..where(
                database.messages.conversationId.equals(conversationId) &
                    _unreadRows,
              ))
            .getSingle();
    await (database.update(
      database.conversations,
    )..where((row) => row.conversationId.equals(conversationId))).write(
      ConversationsCompanion(
        listProjectionCiphertext: Value(
          latest?.projectionCiphertext ?? Uint8List(0),
        ),
        sortKey: Value(latest?.orderingMs ?? 0),
        lastActivityEventId: Value(latest?.orderingEventId),
        unreadCount: Value(counted.read(unread) ?? 0),
      ),
    );
  }

  Future<void> retainUnsupportedInsideTransaction(
    UnsupportedApplicationCommit commit,
  ) async {
    if (commit.retainedBytes.isEmpty ||
        commit.retainedBytes.length >
            ApplicationMessageProtocolV1.maximumApplicationBytes) {
      throw const FormatException('invalid unsupported event');
    }
    final eventId = commit.eventId == null
        ? null
        : protocolBytesToHex(commit.eventId!);
    final conversationId = commit.conversationId == null
        ? null
        : protocolBytesToHex(commit.conversationId!);
    final existing =
        await (database.select(database.unsupportedApplicationEvents)..where(
              (row) =>
                  row.recordKey.equals(commit.recordKey) |
                  (eventId == null
                      ? const Constant(false)
                      : row.eventId.equals(eventId)),
            ))
            .getSingleOrNull();
    if (existing != null) {
      if (_same(existing.retainedPayload, commit.retainedBytes)) {
        return;
      }
      await (database.update(
        database.unsupportedApplicationEvents,
      )..where((row) => row.recordKey.equals(existing.recordKey))).write(
        const UnsupportedApplicationEventsCompanion(
          applyState: Value(_stateEventIdConflict),
        ),
      );
      await _quarantine(
        _quarantineEventIdConflict,
        commit.eventId ?? Uint8List(0),
      );
      return;
    }

    if (eventId != null) {
      final supported = await (database.select(
        database.storedApplicationEvents,
      )..where((row) => row.eventId.equals(eventId))).getSingleOrNull();
      if (supported != null) {
        await (database.update(
          database.storedApplicationEvents,
        )..where((row) => row.eventId.equals(eventId))).write(
          const StoredApplicationEventsCompanion(
            applyState: Value(_stateEventIdConflict),
          ),
        );
        await _quarantine(
          _quarantineEventIdConflict,
          commit.eventId ?? Uint8List(0),
        );
        await _rebuildConversation(
          supported.conversationId,
          currentUserId: commit.currentUserId ?? supported.senderUserId,
        );
        return;
      }
    }
    await database
        .into(database.unsupportedApplicationEvents)
        .insert(
          UnsupportedApplicationEventsCompanion.insert(
            recordKey: commit.recordKey,
            eventId: Value(eventId),
            conversationId: Value(conversationId),
            version: commit.version,
            kind: Value(commit.kindValue),
            senderUserId: commit.senderUserId.toLowerCase(),
            senderDeviceId: commit.senderDeviceId.toLowerCase(),
            senderCounter: Value(commit.senderCounter),
            retainedPayload: commit.retainedBytes,
            authenticatedAt: Value(commit.authenticatedAt),
          ),
        );

    if (eventId != null && commit.senderCounter != null) {
      final supportedCollisions =
          await (database.select(database.storedApplicationEvents)..where(
                (row) =>
                    row.senderDeviceId.equals(
                      commit.senderDeviceId.toLowerCase(),
                    ) &
                    row.senderCounter.equals(commit.senderCounter!),
              ))
              .get();
      final unsupportedCollisions =
          await (database.select(database.unsupportedApplicationEvents)..where(
                (row) =>
                    row.senderDeviceId.equals(
                      commit.senderDeviceId.toLowerCase(),
                    ) &
                    row.senderCounter.equals(commit.senderCounter!),
              ))
              .get();
      final eventIds = <String>{
        ...supportedCollisions.map((row) => row.eventId),
        ...unsupportedCollisions.map((row) => row.eventId).whereType<String>(),
      };
      if (eventIds.length > 1) {
        await (database.update(database.storedApplicationEvents)..where(
              (row) =>
                  row.senderDeviceId.equals(
                    commit.senderDeviceId.toLowerCase(),
                  ) &
                  row.senderCounter.equals(commit.senderCounter!),
            ))
            .write(
              const StoredApplicationEventsCompanion(
                applyState: Value(_stateCounterConflict),
              ),
            );
        await (database.update(database.unsupportedApplicationEvents)..where(
              (row) =>
                  row.senderDeviceId.equals(
                    commit.senderDeviceId.toLowerCase(),
                  ) &
                  row.senderCounter.equals(commit.senderCounter!),
            ))
            .write(
              const UnsupportedApplicationEventsCompanion(
                applyState: Value(_stateCounterConflict),
              ),
            );
        await _quarantine(
          _quarantineCounterRollback,
          commit.eventId ?? Uint8List(0),
        );
        for (final affected
            in supportedCollisions.map((row) => row.conversationId).toSet()) {
          await _rebuildConversation(
            affected,
            currentUserId:
                commit.currentUserId ?? supportedCollisions.first.senderUserId,
          );
        }
      }
    }
    await database.customStatement(
      'DELETE FROM unsupported_application_events WHERE record_key NOT IN '
      '(SELECT record_key FROM unsupported_application_events '
      'ORDER BY authenticated_at DESC, record_key DESC LIMIT 256)',
    );
  }

  /// Writes one message's delivery state, for one event whose transport moved.
  ///
  /// This used to rebuild the whole conversation. Every attempt transition of
  /// every send — queued to sending, sending to accepted, either to retry or to
  /// failure — re-read every event in the thread, re-projected every message in
  /// it, and rewrote every row, to change one integer on one of them. The cost
  /// of telling the user their message reached the relay was therefore set by
  /// how long they had been talking to that person, and it was paid three times
  /// per send.
  ///
  /// Nothing else a rebuild computes can change because an outbox row changed,
  /// so nothing else is recomputed. An event that is not a locally originated
  /// message create — an edit, a reaction, a receipt, a device-log object —
  /// owns no delivery state at all and leaves without a write.
  ///
  /// The message a local create belongs to is the create itself:
  /// `SendConversationEvents` puts the event id in the body as the message id,
  /// and the projector records that same id as `ordering_event_id`. Both are
  /// asserted in the predicate rather than assumed, so an event that somehow
  /// disagreed would update nothing instead of the wrong row.
  Future<void> refreshTransportForEventInsideTransaction(String eventId) async {
    final event = await (database.select(
      database.storedApplicationEvents,
    )..where((row) => row.eventId.equals(eventId))).getSingleOrNull();
    if (event == null ||
        !event.localOrigin ||
        event.kind != ApplicationEventKind.messageCreate.wireValue) {
      return;
    }
    final state = await _deriveTransportState(eventId, localOrigin: true);
    await (database.update(database.messages)..where(
          (row) =>
              row.messageId.equals(eventId) &
              row.orderingEventId.equals(eventId),
        ))
        .write(MessagesCompanion(status: Value(state.index)));
  }

  /// Stores one event and indexes the messages it is a fact about.
  ///
  /// The target rows are written here, for every stored event and whatever its
  /// apply state, so that "an event in the log has its targets beside it" is an
  /// invariant of the log rather than a property of the path that happened to
  /// write it. `RETURNING` hands back the row that was written, so the fact the
  /// projection folds is the row the database holds and not a second
  /// construction of it.
  Future<_EventFact> _insertEvent(
    ApplicationEventCommit commit, {
    required int applyState,
    required int orderingMs,
  }) async {
    final event = commit.event;
    final body = _projectionBody(event.body, event.references);
    final row = await database
        .into(database.storedApplicationEvents)
        .insertReturning(
          StoredApplicationEventsCompanion.insert(
            eventId: protocolBytesToHex(event.eventId),
            conversationId: protocolBytesToHex(event.conversationId),
            kind: event.kindValue,
            senderUserId: protocolUuidString(event.senderUserId),
            senderDeviceId: protocolUuidString(event.senderDeviceId),
            senderCounter: event.senderCounter,
            createdMs: event.createdMs,
            orderingMs: orderingMs,
            canonicalEvent: commit.canonicalBytes,
            bodyProjection: Uint8List.fromList(utf8.encode(jsonEncode(body))),
            applyState: applyState,
            localOrigin: Value(commit.localOrigin),
            localDeviceId: Value(commit.currentDeviceId.toLowerCase()),
            targetMessageId: Value(_targetMessageId(event.body)),
            revision: Value(_revision(event.body)),
            authenticatedAt: Value(commit.authenticatedAt),
          ),
        );
    final fact = _EventFact(row: row, body: body);
    await _writeEventTargets([fact]);
    return fact;
  }

  /// Indexes [facts] by the messages they are facts about.
  ///
  /// `INSERT OR IGNORE`, because a receipt may name the same message twice and
  /// because re-presenting an event after a crash has to converge rather than
  /// collide. One statement per target: a receipt costs the ids it carries,
  /// which is the size of the work it actually is.
  Future<void> _writeEventTargets(Iterable<_EventFact> facts) async {
    for (final fact in facts) {
      for (final messageId in _affectedMessageIds(fact)) {
        await database
            .into(database.applicationEventTargets)
            .insert(
              ApplicationEventTargetsCompanion.insert(
                messageId: messageId,
                eventId: fact.row.eventId,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    }
  }

  /// Folds one conversation from its complete authenticated fact set.
  ///
  /// This is the recovery path, and it is also the definition of a correct
  /// projection: the incremental apply is an optimisation of this fold, not a
  /// second set of rules, and where the two disagree this one is right.
  ///
  /// It is reached for an event-id conflict, a sender-counter rollback and an
  /// unsupported-event collision — each of which retires a fact the projection
  /// already contains, so what the projection should say is no longer a
  /// function of the event in hand — and it is public so that a fork, a repair,
  /// or a future change to conversation-level authorisation has a door to it
  /// rather than a reason to reinvent it.
  Future<void> rebuildConversationInsideTransaction(
    String conversationId, {
    required String currentUserId,
  }) => _rebuildConversation(conversationId, currentUserId: currentUserId);

  Future<void> _rebuildConversation(
    String conversationId, {
    required String currentUserId,
  }) async {
    final conversation =
        await (database.select(database.conversations)
              ..where((row) => row.conversationId.equals(conversationId)))
            .getSingleOrNull();
    if (conversation == null) {
      return;
    }
    final events =
        await (database.select(database.storedApplicationEvents)..where(
              (row) =>
                  row.conversationId.equals(conversationId) &
                  row.applyState.equals(_stateCandidate),
            ))
            .get();
    final facts = <_EventFact>[];
    for (final row in events) {
      try {
        facts.add(_EventFact(row: row, body: _decodeBody(row)));
      } on Object {
        await (database.update(
          database.storedApplicationEvents,
        )..where((item) => item.eventId.equals(row.eventId))).write(
          const StoredApplicationEventsCompanion(
            applyState: Value(_stateConversationRejected),
          ),
        );
      }
    }

    // The target index is derived state, so the fold that defines the
    // projection also repairs it. A rebuild already rewrites every row in the
    // conversation; making it rewrite the index entries too means the recovery
    // path recovers everything the normal path depends on, including a back-fill
    // that was interrupted.
    await _writeEventTargets(facts);

    final oldMessages = await (database.select(
      database.messages,
    )..where((row) => row.conversationId.equals(conversationId))).get();
    final localState = <String, _LocalMessageState>{
      for (final message in oldMessages)
        message.messageId: _LocalMessageState.of(message),
    };

    // Every message is folded from the conversation's whole fact set, and
    // `_projectMessage` selects what it needs out of it. That is the same
    // quadratic scan it always was, and it stays: this is the fold the
    // incremental path is measured against, so it must not come to share the
    // incremental path's idea of which facts belong to which message. An error
    // in that idea has to be visible here as a disagreement rather than
    // invisible as an agreement.
    final createsByMessage = <String, List<_EventFact>>{};
    for (final fact in facts.where(
      (fact) => fact.row.kind == ApplicationEventKind.messageCreate.wireValue,
    )) {
      final messageId = fact.body['message_id'] as String;
      (createsByMessage[messageId] ??= []).add(fact);
    }

    final projectedMessageIds = <String>{};
    for (final entry in createsByMessage.entries) {
      if (entry.value.length != 1) {
        for (final collision in entry.value) {
          await _quarantine(
            _quarantineMessageIdCollision,
            _hexToBytes(collision.row.eventId),
          );
        }
        continue;
      }
      final create = entry.value.single;
      if (!_referencesAreValid(create)) {
        continue;
      }
      final projected = await _projectMessage(
        conversation: conversation,
        create: create,
        facts: facts,
        currentUserId: currentUserId.toLowerCase(),
        localState: localState[entry.key],
      );
      await _writeMessage(projected, localState: localState[entry.key]);
      projectedMessageIds.add(projected.messageId);
    }
    final staleMessages = database.delete(database.messages)
      ..where((row) => row.conversationId.equals(conversationId));
    if (projectedMessageIds.isNotEmpty) {
      staleMessages.where((row) => row.messageId.isNotIn(projectedMessageIds));
    }
    await staleMessages.go();
    await _refreshConversationAggregates(conversationId);
  }

  /// One message's projection, from the facts about that message.
  ///
  /// [facts] is the message's own fact list on both paths — read out of
  /// `application_event_targets` by an incremental apply, grouped in memory by a
  /// rebuild — and it is filtered again here rather than trusted, so the result
  /// is the same for any superset of them. That is the whole of the equivalence
  /// argument: the two paths differ in where the list comes from and in nothing
  /// else.
  Future<_ProjectedMessage> _projectMessage({
    required Conversation conversation,
    required _EventFact create,
    required List<_EventFact> facts,
    required String currentUserId,
    required _LocalMessageState? localState,
  }) async {
    final messageId = create.body['message_id']! as String;
    final senderUserId = create.row.senderUserId;
    // Materialised, because it is read four times below and a lazy `where` is
    // four passes rather than one.
    final mutations = facts
        .where((fact) => fact.row.targetMessageId == messageId)
        .toList(growable: false);
    final edits =
        mutations
            .where(
              (fact) =>
                  fact.row.kind == ApplicationEventKind.messageEdit.wireValue &&
                  fact.row.senderUserId == senderUserId &&
                  _referencesAreValid(fact),
            )
            .toList()
          ..sort(_compareEditFacts);
    final winnerEdit = edits.isEmpty ? null : edits.last;
    final deletes = mutations.where(
      (fact) =>
          fact.row.kind == ApplicationEventKind.messageDelete.wireValue &&
          _referencesAreValid(fact) &&
          (fact.row.senderUserId == senderUserId ||
              _authorizedGroupModerator(conversation, fact.row.senderUserId)),
    );
    final deletedForEveryone = deletes.isNotEmpty;

    final pinFacts =
        mutations
            .where(
              (fact) =>
                  fact.row.kind == ApplicationEventKind.pinSet.wireValue &&
                  _referencesAreValid(fact) &&
                  _authorizedPin(
                    conversation,
                    fact.row.senderUserId,
                    currentUserId,
                  ),
            )
            .toList()
          ..sort(_compareMutationFacts);
    final pinned = pinFacts.isNotEmpty
        ? pinFacts.last.body['pinned']! as bool
        : false;

    final reactionsByUser = <String, List<_EventFact>>{};
    for (final reaction in mutations.where(
      (fact) =>
          fact.row.kind == ApplicationEventKind.reactionSet.wireValue &&
          _referencesAreValid(fact) &&
          _isConversationParticipant(
            conversation,
            fact.row.senderUserId,
            currentUserId,
          ),
    )) {
      (reactionsByUser[reaction.row.senderUserId] ??= []).add(reaction);
    }
    final reactions = <({String userId, String emoji, String eventId})>[];
    for (final entry in reactionsByUser.entries) {
      entry.value.sort(_compareMutationFacts);
      final winner = entry.value.last;
      final emoji = winner.body['emoji'] as String?;
      if (emoji != null) {
        reactions.add((
          userId: entry.key,
          emoji: emoji,
          eventId: winner.row.eventId,
        ));
      }
    }
    reactions.sort((left, right) => left.userId.compareTo(right.userId));

    final receiptStates =
        <({String userId, String deviceId}), MessageReceiptState>{};
    var readOnOwnDevice = false;
    for (final receipt in facts.where(
      (fact) =>
          (fact.row.kind == ApplicationEventKind.receiptDelivered.wireValue ||
              fact.row.kind == ApplicationEventKind.receiptRead.wireValue) &&
          (fact.body['message_ids']! as List<Object?>).contains(messageId) &&
          fact.row.senderUserId != senderUserId &&
          _isConversationParticipant(
            conversation,
            fact.row.senderUserId,
            currentUserId,
          ),
    )) {
      final key = (
        userId: receipt.row.senderUserId,
        deviceId: receipt.row.senderDeviceId,
      );
      final state =
          receipt.row.kind == ApplicationEventKind.receiptRead.wireValue
          ? MessageReceiptState.read
          : MessageReceiptState.delivered;
      final previous = receiptStates[key];
      if (previous == null || state.index > previous.index) {
        receiptStates[key] = state;
      }
      if (state == MessageReceiptState.read) {
        readOnOwnDevice |= receipt.row.senderUserId == currentUserId;
      }
    }
    final receipts =
        [
          for (final entry in receiptStates.entries)
            _ProjectedReceipt(
              userId: entry.key.userId,
              deviceId: entry.key.deviceId,
              state: entry.value,
            ),
        ]..sort((left, right) {
          final user = left.userId.compareTo(right.userId);
          return user != 0 ? user : left.deviceId.compareTo(right.deviceId);
        });
    final receiptState = receipts.fold(
      MessageReceiptState.none,
      (state, receipt) =>
          receipt.state.index > state.index ? receipt.state : state,
    );

    final text =
        winnerEdit?.body['text'] as String? ?? create.body['text']! as String;
    final attachments =
        (create.body['attachments'] as List<Object?>?)
            ?.whereType<Map<String, Object?>>()
            .toList(growable: false) ??
        const <Map<String, Object?>>[];
    final revision = winnerEdit?.row.revision ?? 0;
    final currentEventId = winnerEdit?.row.eventId ?? create.row.eventId;
    var unread =
        localState?.unread ??
        (!create.row.localOrigin &&
            senderUserId != currentUserId &&
            conversation.kind != ConversationKind.saved.index);
    if (readOnOwnDevice) {
      unread = false;
    }
    final transport = localState?.status ?? await _transportState(create);
    return _ProjectedMessage(
      messageId: messageId,
      conversationId: conversation.conversationId,
      currentEventId: currentEventId,
      senderUserId: senderUserId,
      senderDeviceId: create.row.senderDeviceId,
      text: deletedForEveryone ? null : text,
      attachments: deletedForEveryone ? const [] : attachments,
      replyToMessageId: create.body['reply_to'] as String?,
      quoteFallback: create.body['quote'] as String?,
      status: transport,
      receiptState: receiptState,
      revision: revision,
      createdMs: create.row.createdMs,
      orderingMs: create.row.orderingMs,
      orderingEventId: create.row.eventId,
      timestampState: create.row.orderingMs == 0
          ? MessageTimestampState.skewed
          : MessageTimestampState.plausible,
      edited: winnerEdit != null,
      deletedForEveryone: deletedForEveryone,
      deletedForMe: localState?.deletedForMe ?? false,
      pinned: pinned,
      unread: unread,
      reactions: reactions,
      receipts: receipts,
      pendingDeliveredReceipt:
          !create.row.localOrigin &&
          senderUserId != currentUserId &&
          conversation.kind == ConversationKind.direct.index,
      receiptTargetUserId: senderUserId,
      localDeviceId: create.row.localDeviceId,
    );
  }

  /// Writes one projected message and, when they can have changed, its children.
  ///
  /// [rewriteReactions] and [rewriteReceipts] are how "a row that did not change
  /// is not rewritten" is expressed. A reaction is derived from `reactionSet`
  /// facts and a receipt from receipt facts, so an edit, a delete or a pin
  /// cannot move either and does not delete and re-insert them to prove it. A
  /// rebuild passes neither and rewrites both, because it is rebuilding.
  ///
  /// Attachments are deliberately not gated: the rebuild resets their transfer
  /// state and clears their cache handle on every write, and changing when that
  /// happens would change observable local state rather than only its cost.
  Future<void> _writeMessage(
    _ProjectedMessage message, {
    required _LocalMessageState? localState,
    bool rewriteReactions = true,
    bool rewriteReceipts = true,
  }) async {
    // The ordering time, not the sender's raw one. They are the same number
    // wherever the sender's clock agreed with this conversation, and where it
    // did not, showing the raw one would print the contradiction the ordering
    // correction exists to remove: a bubble reading 7:09 seated below one
    // reading 7:10.
    final createdAtMs =
        message.timestampState == MessageTimestampState.plausible
        ? message.orderingMs
        : 0;
    await database
        .into(database.messages)
        .insertOnConflictUpdate(
          MessagesCompanion.insert(
            messageId: message.messageId,
            conversationId: message.conversationId,
            currentEventId: message.currentEventId,
            projectionCiphertext: message.text == null
                ? Uint8List(0)
                : Uint8List.fromList(utf8.encode(message.text!)),
            status: message.status.index,
            revision: message.revision,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              createdAtMs,
              isUtc: true,
            ),
            senderUserId: Value(message.senderUserId),
            senderDeviceId: Value(message.senderDeviceId),
            replyToMessageId: Value(message.replyToMessageId),
            quoteFallbackCiphertext: Value(
              message.quoteFallback == null
                  ? null
                  : Uint8List.fromList(utf8.encode(message.quoteFallback!)),
            ),
            orderingMs: Value(message.orderingMs),
            orderingEventId: Value(message.orderingEventId),
            timestampState: Value(message.timestampState.index),
            deletedForEveryone: Value(message.deletedForEveryone),
            deletedForMe: Value(message.deletedForMe),
            pinned: Value(message.pinned),
            unread: Value(message.unread),
          ),
        );
    if (message.attachments.isNotEmpty) {
      await (database.delete(
        database.attachments,
      )..where((row) => row.messageId.equals(message.messageId))).go();
      for (final attachment in message.attachments) {
        final id = attachment['capability'];
        if (id is! String) continue;
        await database
            .into(database.attachments)
            .insertOnConflictUpdate(
              AttachmentsCompanion.insert(
                attachmentId: id,
                messageId: message.messageId,
                encryptedDescriptor: Uint8List.fromList(
                  utf8.encode(jsonEncode(attachment)),
                ),
                transferState: AttachmentTransferState.queued.index,
              ),
            );
      }
    }
    if (rewriteReactions) {
      await (database.delete(
        database.messageReactions,
      )..where((row) => row.messageId.equals(message.messageId))).go();
      for (final reaction in message.reactions) {
        await database
            .into(database.messageReactions)
            .insert(
              MessageReactionsCompanion.insert(
                messageId: message.messageId,
                reactingUserId: reaction.userId,
                eventId: reaction.eventId,
                emojiCiphertext: Value(
                  Uint8List.fromList(utf8.encode(reaction.emoji)),
                ),
              ),
            );
      }
    }
    if (rewriteReceipts) {
      await (database.delete(
        database.receipts,
      )..where((row) => row.messageId.equals(message.messageId))).go();
      for (final receipt in message.receipts) {
        await database
            .into(database.receipts)
            .insert(
              ReceiptsCompanion.insert(
                messageId: message.messageId,
                userId: receipt.userId,
                deviceId: receipt.deviceId,
                receiptState: receipt.state.index,
                projectionCiphertext: Uint8List(0),
              ),
            );
      }
    }
    if (message.deletedForEveryone) {
      await (database.update(
        database.attachments,
      )..where((row) => row.messageId.equals(message.messageId))).write(
        const AttachmentsCompanion(
          boundedCacheHandleCiphertext: Value(null),
          cacheExpiresAt: Value(null),
        ),
      );
    }
    if (message.pendingDeliveredReceipt && message.localDeviceId.isNotEmpty) {
      // Only for a message this device has not already acknowledged to its
      // sender. `pendingDeliveredReceipt` says a receipt is *owed in principle*
      // — the message came from a peer, in a direct conversation — and those
      // are properties that never change, so re-deriving the queue from them on
      // every rebuild re-queued a receipt for every message the conversation
      // had ever received. Each is an event at the far end, which rebuilds that
      // conversation and re-queues its own, and two devices in a conversation
      // sustain that indefinitely: measured at roughly seventy to a hundred and
      // eighty envelopes a minute between two idle phones (ADR-060). The column
      // read here is the durable record of what has actually been sent.
      //
      // It comes from the row that was read before this write rather than from
      // a fresh `SELECT` of the row just written: the companion omits the
      // column, so the two are the same value, and one of them is a statement
      // per message per projection. A message with no prior row has never
      // acknowledged anything.
      if (!(localState?.deliveredReceiptSent ?? false)) {
        await database
            .into(database.pendingApplicationReceipts)
            .insert(
              PendingApplicationReceiptsCompanion.insert(
                messageId: message.messageId,
                conversationId: message.conversationId,
                targetUserId: message.receiptTargetUserId,
                localDeviceId: message.localDeviceId,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    }
  }

  Future<MessageTransportState> _transportState(_EventFact create) =>
      _deriveTransportState(
        create.row.eventId,
        localOrigin: create.row.localOrigin,
      );

  /// Where the transport state of a locally originated event comes from.
  ///
  /// `outbox_operations` remains the authority the moment there is anything in
  /// it to read: those rows are the sealed per-recipient ciphertext and their
  /// attempt states are the only record of what the wire has said. Before they
  /// exist there is a second durable fact to consult — an owed or terminally
  /// failed preparation — and it is read only in that window, so an attempt
  /// transition costs the one query it always did.
  Future<MessageTransportState> _deriveTransportState(
    String eventId, {
    required bool localOrigin,
  }) async {
    if (!localOrigin) {
      return MessageTransportState.received;
    }
    final targets = await (database.select(
      database.outboxOperations,
    )..where((row) => row.eventId.equals(eventId))).get();
    if (targets.isEmpty) {
      final preparation = await (database.select(
        database.pendingSendPreparations,
      )..where((row) => row.eventId.equals(eventId))).getSingleOrNull();
      return switch (preparation?.state) {
        null => MessageTransportState.localOnly,
        _SendPreparationState.owed => MessageTransportState.preparing,
        _ => MessageTransportState.permanentlyFailed,
      };
    }
    final states = targets.map((row) => row.attemptState).toList();
    final hasAccepted = states.contains(OutboxAttemptState.accepted.index);
    final hasPending = states.any(
      (state) =>
          state == OutboxAttemptState.queued.index ||
          state == OutboxAttemptState.retryWait.index ||
          state == OutboxAttemptState.sending.index,
    );
    if (hasPending) {
      if (hasAccepted) {
        return MessageTransportState.partiallyAccepted;
      }
      return states.contains(OutboxAttemptState.sending.index)
          ? MessageTransportState.sending
          : MessageTransportState.queued;
    }
    if (states.contains(OutboxAttemptState.permanentlyFailed.index) ||
        !hasAccepted) {
      return MessageTransportState.permanentlyFailed;
    }
    return MessageTransportState.relayAccepted;
  }

  bool _validCommit(ApplicationEventCommit commit) {
    final event = commit.event;
    if (!event.isSupported ||
        event.kind == ApplicationEventKind.typingSet ||
        commit.canonicalBytes.isEmpty ||
        commit.canonicalBytes.length >
            ApplicationMessageProtocolV1.maximumApplicationBytes ||
        commit.conversationKind < 0 ||
        commit.conversationKind >= ConversationKind.values.length ||
        event.createdMs > 8640000000000000 ||
        event.senderCounter > 0x7fffffffffffffff) {
      return false;
    }
    final senderUser = protocolUuidString(event.senderUserId);
    final currentUser = commit.currentUserId.toLowerCase();
    return switch (ConversationKind.values[commit.conversationKind]) {
      ConversationKind.direct =>
        commit.peerUserId != null &&
            commit.peerUserId != currentUser &&
            (senderUser == currentUser ||
                senderUser == commit.peerUserId!.toLowerCase()),
      ConversationKind.saved =>
        commit.peerUserId == null &&
            senderUser == currentUser &&
            event.kind != ApplicationEventKind.messageDelete &&
            event.kind != ApplicationEventKind.receiptDelivered &&
            event.kind != ApplicationEventKind.receiptRead,
      ConversationKind.group => true,
    };
  }

  /// Where one event sits in its conversation's total order.
  ///
  /// The sender's own clock, which is the only account of when an event was
  /// written that anyone here has, and which `message-protocol.md` calls a
  /// display value rather than an authority. An implausible one is refused
  /// outright, as it always was.
  ///
  /// [conversationFloorMs] is what the clock alone cannot supply. Two phones in
  /// one conversation keep two unsynchronised clocks, and the timeline seated
  /// every message exactly where its sender's clock said — so a phone running
  /// half a minute behind put its replies above the messages they answered, on
  /// both phones, because both computed the same order from the same wrong
  /// number. Measured here at thirty seconds between two ordinary handsets.
  ///
  /// Neither device can read the other's clock. Both know something the clock
  /// does not: what was already in the conversation. An event that lands in a
  /// conversation which already holds something newer cannot have been written
  /// before it, so its ordering time is lifted to sit just after — and only
  /// then, only forward, and only across the gap a wrong clock can explain.
  int _orderingTimestamp(
    ApplicationEventRecord event,
    DateTime authenticatedAt,
    int conversationFloorMs,
  ) {
    final maximum =
        authenticatedAt.toUtc().millisecondsSinceEpoch +
        maximumFutureClockSkewMs;
    if (event.createdMs < earliestPlausibleTimestampMs ||
        event.createdMs > maximum) {
      return 0;
    }
    if (event.createdMs >= conversationFloorMs ||
        conversationFloorMs - event.createdMs > maximumOrderingClockSkewMs) {
      return event.createdMs;
    }
    return conversationFloorMs + 1;
  }

  bool _referencesAreValid(_EventFact fact) {
    final references = (fact.body['references']! as List<Object?>)
        .cast<String>();
    return switch (ApplicationEventKind.fromWireValue(fact.row.kind)) {
      ApplicationEventKind.messageCreate =>
        fact.body['reply_to'] == null ||
            references.contains(fact.body['reply_to']),
      ApplicationEventKind.messageEdit ||
      ApplicationEventKind.messageDelete ||
      ApplicationEventKind.reactionSet ||
      ApplicationEventKind.pinSet => references.contains(fact.body['target']),
      ApplicationEventKind.receiptDelivered ||
      ApplicationEventKind.receiptRead =>
        (fact.body['message_ids']! as List<Object?>).every(references.contains),
      ApplicationEventKind.typingSet || null => true,
    };
  }

  bool _isConversationParticipant(
    Conversation conversation,
    String userId,
    String currentUserId,
  ) {
    if (conversation.kind == ConversationKind.saved.index) {
      return conversation.peerUserId == null && userId == currentUserId;
    }
    if (conversation.kind == ConversationKind.direct.index) {
      return userId == conversation.peerUserId || userId == currentUserId;
    }
    return true;
  }

  bool _authorizedPin(
    Conversation conversation,
    String userId,
    String currentUserId,
  ) {
    if (conversation.kind != ConversationKind.group.index) {
      return _isConversationParticipant(conversation, userId, currentUserId);
    }
    return _authorizedGroupModerator(conversation, userId);
  }

  bool _authorizedGroupModerator(Conversation conversation, String userId) {
    if (conversation.kind != ConversationKind.group.index) {
      return false;
    }
    // Group role projection is established by the later MLS/control piece.
    // Until then no moderator-only mutation is guessed in Dart.
    return false;
  }

  Future<void> _quarantine(int reason, Uint8List digest) async {
    await database
        .into(database.quarantineRecords)
        .insert(
          QuarantineRecordsCompanion.insert(
            reasonCode: reason,
            opaqueDigest: Uint8List.fromList(digest.take(32).toList()),
          ),
        );
    await database.customStatement(
      'DELETE FROM quarantine WHERE id NOT IN '
      '(SELECT id FROM quarantine ORDER BY received_at DESC, id DESC LIMIT 256)',
    );
  }
}

final class _EventFact {
  const _EventFact({required this.row, required this.body});

  final StoredApplicationEvent row;
  final Map<String, Object?> body;
}

final class _LocalMessageState {
  const _LocalMessageState({
    required this.deletedForMe,
    required this.unread,
    required this.status,
    required this.deliveredReceiptSent,
  });

  /// What the row already says, on either path.
  ///
  /// Both the rebuild and an incremental apply read the existing row before
  /// they write it, and both preserve exactly this set. Naming it once is what
  /// makes "the same mechanism" checkable rather than asserted.
  factory _LocalMessageState.of(Message message) => _LocalMessageState(
    deletedForMe: message.deletedForMe,
    unread: message.unread,
    status: _storedTransportState(message.status),
    deliveredReceiptSent: message.deliveredReceiptSent,
  );

  final bool deletedForMe;
  final bool unread;

  /// Whether this device has already told the sender the message arrived.
  final bool deliveredReceiptSent;

  /// What the row already says about delivery, which is newer than anything a
  /// rebuild can work out.
  ///
  /// Transport state is written by whoever last moved the send — the commit
  /// that sealed the ciphertext, the batch that went to the wire, the response
  /// that came back — and each of those is a narrow update against this one
  /// message. A rebuild happens for an unrelated reason, an edit or a reaction
  /// or somebody else's message arriving, and re-deriving delivery from the
  /// outbox there would let a stale read overwrite a fresher write. So the
  /// rebuild carries the existing value through instead, and derives one only
  /// for a row it is creating. This is the same rule [Messages.alerted],
  /// [Messages.starred] and [Messages.deliveredReceiptSent] already live by,
  /// stated where it can be read rather than implied by an omitted companion
  /// field.
  final MessageTransportState status;
}

final class _ProjectedMessage {
  const _ProjectedMessage({
    required this.messageId,
    required this.conversationId,
    required this.currentEventId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.text,
    required this.attachments,
    required this.replyToMessageId,
    required this.quoteFallback,
    required this.status,
    required this.receiptState,
    required this.revision,
    required this.createdMs,
    required this.orderingMs,
    required this.orderingEventId,
    required this.timestampState,
    required this.edited,
    required this.deletedForEveryone,
    required this.deletedForMe,
    required this.pinned,
    required this.unread,
    required this.reactions,
    required this.receipts,
    required this.pendingDeliveredReceipt,
    required this.receiptTargetUserId,
    required this.localDeviceId,
  });

  final String messageId;
  final String conversationId;
  final String currentEventId;
  final String senderUserId;
  final String senderDeviceId;
  final String? text;
  final List<Map<String, Object?>> attachments;
  final String? replyToMessageId;
  final String? quoteFallback;
  final MessageTransportState status;
  final MessageReceiptState receiptState;
  final int revision;
  final int createdMs;
  final int orderingMs;
  final String orderingEventId;
  final MessageTimestampState timestampState;
  final bool edited;
  final bool deletedForEveryone;
  final bool deletedForMe;
  final bool pinned;
  final bool unread;
  final List<({String userId, String emoji, String eventId})> reactions;
  final List<_ProjectedReceipt> receipts;
  final bool pendingDeliveredReceipt;
  final String receiptTargetUserId;
  final String localDeviceId;

  String? get displayText => deletedForEveryone ? null : text;
}

final class _ProjectedReceipt {
  const _ProjectedReceipt({
    required this.userId,
    required this.deviceId,
    required this.state,
  });

  final String userId;
  final String deviceId;
  final MessageReceiptState state;
}

int _compareEditFacts(_EventFact left, _EventFact right) {
  final revision = left.row.revision!.compareTo(right.row.revision!);
  if (revision != 0) {
    return revision;
  }
  return _compareMutationFacts(left, right);
}

int _compareMutationFacts(_EventFact left, _EventFact right) {
  final counter = left.row.senderCounter.compareTo(right.row.senderCounter);
  return counter != 0 ? counter : left.row.eventId.compareTo(right.row.eventId);
}

/// `unread`, unbound.
///
/// `messages_unread_by_conversation` is partial, and SQLite will only choose a
/// partial index when the query's `WHERE` provably implies the index's. A bound
/// `unread = ?` does not: the value is unknown when the statement is prepared,
/// and the planner falls back to the ordering index and a row lookup for every
/// message in the conversation — which is the linear pass the incremental path
/// exists to remove, reintroduced in the one query that closes it.
const _unreadRows = CustomExpression<bool>('unread');

/// The projected body, as the map that is both stored and folded.
///
/// The bytes in `application_events.body_projection` are this map encoded. An
/// event being applied has it in hand already, so nothing writes JSON and reads
/// it back in the same transaction to find out what it just said.
Map<String, Object?> _projectionBody(
  ApplicationEventBody body,
  List<Uint8List> references,
) {
  final Map<String, Object?> value = switch (body) {
    MessageCreateBody() => {
      'message_id': protocolBytesToHex(body.messageId),
      'text': body.text,
      'content_type': body.contentType.index,
      'attachments': [
        for (final attachment in body.attachments)
          <String, Object?>{
            'capability': attachment.capabilityId,
            'key': base64UrlEncode(attachment.key),
            'header': base64UrlEncode(attachment.header),
            'stream_header': base64UrlEncode(attachment.secretstreamHeader),
            'encrypted_size': attachment.encryptedSize,
            'bucket_size': attachment.bucketSize,
            'plaintext_size': attachment.plaintextSize,
            'name': attachment.displayName,
            'mime': attachment.mimeType,
            'media_kind': attachment.mediaKind.index,
            'width': attachment.width,
            'height': attachment.height,
            'caption': attachment.caption,
            'thumbnail': attachment.thumbnail == null
                ? null
                : base64UrlEncode(attachment.thumbnail!),
          },
      ],
      'reply_to': body.replyToMessageId == null
          ? null
          : protocolBytesToHex(body.replyToMessageId!),
      'quote': body.quoteFallback,
    },
    MessageEditBody() => {
      'target': protocolBytesToHex(body.targetMessageId),
      'text': body.replacementText,
      'revision': body.revision,
    },
    MessageDeleteBody() => {'target': protocolBytesToHex(body.targetMessageId)},
    ReactionSetBody() => {
      'target': protocolBytesToHex(body.targetMessageId),
      'emoji': body.emoji,
    },
    PinSetBody() => {
      'target': protocolBytesToHex(body.targetMessageId),
      'pinned': body.pinned,
    },
    ReceiptBody() => {
      'message_ids': [for (final id in body.messageIds) protocolBytesToHex(id)],
    },
    TypingSetBody() => {
      'is_typing': body.isTyping,
      'expires_ms': body.expiresMs,
    },
    UnsupportedEventBody() => throw const FormatException(
      'unsupported event cannot be projected',
    ),
  };
  value['references'] = [
    for (final reference in references) protocolBytesToHex(reference),
  ];
  return value;
}

Map<String, Object?> _decodeBody(StoredApplicationEvent row) {
  final decoded =
      jsonDecode(utf8.decode(row.bodyProjection, allowMalformed: false))
          as Map<String, Object?>;
  return decoded;
}

/// The persisted ordinals of [PendingSendPreparations.state].
abstract final class _SendPreparationState {
  static const int owed = 0;
}

/// A stored `messages.status`, without trusting the column's own bound.
///
/// The check constraint on that column admits one ordinal more than the enum
/// has values, and this runs inside the write transaction that projects an
/// event: a range error here would not merely fail a read, it would abort the
/// commit that makes a message exist.
MessageTransportState _storedTransportState(int value) =>
    value >= 0 && value < MessageTransportState.values.length
    ? MessageTransportState.values[value]
    : MessageTransportState.localOnly;

String? _targetMessageId(ApplicationEventBody body) => switch (body) {
  MessageEditBody() => protocolBytesToHex(body.targetMessageId),
  MessageDeleteBody() => protocolBytesToHex(body.targetMessageId),
  ReactionSetBody() => protocolBytesToHex(body.targetMessageId),
  PinSetBody() => protocolBytesToHex(body.targetMessageId),
  _ => null,
};

int? _revision(ApplicationEventBody body) => switch (body) {
  MessageEditBody() => body.revision,
  _ => null,
};

Uint8List _hexToBytes(String value) => Uint8List.fromList([
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
]);

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
