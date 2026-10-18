import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_application_event_projector.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/conversation_history_harness.dart';
import '../../../support/local_send_harness.dart';

/// Which index the planner actually chooses.
///
/// An index that exists and is never chosen is write cost with no read
/// benefit, and nothing but `EXPLAIN QUERY PLAN` can tell the two apart. These
/// assertions are made against the statements the production code really
/// issues — captured through an interceptor rather than restated here — so a
/// query rewritten into a shape the index cannot serve fails immediately.
///
/// The partial index in particular depends on how its predicate is spelled:
/// SQLite will not choose an index whose `WHERE` the query only implies at run
/// time, so `pinned = ?` silently falls back to the ordering index and a full
/// row lookup per message. That regression is invisible except here.
void main() {
  late _StatementRecorder recorder;
  late LocalDatabase database;
  late DriftConversationDomainRepository repository;

  setUp(() async {
    recorder = _StatementRecorder();
    database = LocalDatabase(NativeDatabase.memory().interceptWith(recorder));
    repository = DriftConversationDomainRepository(database);
    await database.customSelect('SELECT 1').getSingle();
    // Many conversations, one of them long, because the scans this replaces
    // were across every message on the device and not only this conversation's.
    for (var index = 0; index < 12; index += 1) {
      await seedConversationHistory(
        database,
        conversationId: 'conversation-$index',
        messages: index == 0 ? 800 : 40,
        pinnedEvery: 100,
      );
    }
  });

  tearDown(() => database.close());

  /// The `EXPLAIN QUERY PLAN` output of every statement [action] issued.
  Future<List<_Plan>> plansOf(Future<void> Function() action) async {
    recorder.statements.clear();
    recorder.recording = true;
    await action();
    recorder.recording = false;
    final plans = <_Plan>[];
    for (final captured in recorder.statements) {
      final trimmed = captured.sql.trimLeft().toUpperCase();
      if (!trimmed.startsWith('SELECT') &&
          !trimmed.startsWith('UPDATE') &&
          !trimmed.startsWith('DELETE')) {
        continue;
      }
      final rows = await database
          .customSelect(
            'EXPLAIN QUERY PLAN ${captured.sql}',
            variables: captured.variables,
          )
          .get();
      plans.add(
        _Plan(captured.sql, [
          for (final row in rows) row.read<String>('detail'),
        ]),
      );
    }
    return plans;
  }

  test(
    'the timeline reads a conversation through its ordering index',
    () async {
      final plans = await plansOf(() async {
        await repository
            .watchMessages(
              currentUserId: 'self',
              conversationId: 'conversation-0',
              window: const NewestConversationMessages(120),
            )
            .first;
      });

      // Six statements, and not one of them a scan of `messages`.
      expect(plans, hasLength(6));
      for (final plan in plans) {
        expect(
          plan.details,
          isNot(contains('SCAN messages')),
          reason: plan.sql,
        );
        expect(
          plan.details.any((detail) => detail.contains('USE TEMP B-TREE')),
          isFalse,
          reason: 'the index already sorts: ${plan.sql}',
        );
      }

      // The page itself: the conversation is a seek, and the ordering columns
      // that follow it satisfy the `ORDER BY` in the direction it asks for.
      expect(
        plans.first.details.single,
        'SEARCH messages USING INDEX messages_conversation_ordering '
        '(conversation_id=?)',
      );
      // The pins, through the partial index, which holds only pinned rows.
      expect(
        plans.any(
          (plan) => plan.details.any(
            (detail) =>
                detail.contains('messages_pinned_by_conversation') &&
                plan.sql.contains('pinned'),
          ),
        ),
        isTrue,
        reason: plans.map((plan) => plan.sql).join('\n'),
      );
      // Whether anything older exists: answered out of the index alone.
      expect(
        plans.any(
          (plan) => plan.details.any(
            (detail) => detail.contains(
              'SEARCH messages USING COVERING INDEX '
              'messages_conversation_ordering (conversation_id=? AND '
              'ordering_ms<?)',
            ),
          ),
        ),
        isTrue,
      );
      // The three set-based child reads drive from the same covering index and
      // probe each child by its own key.
      expect(
        plans.where(
          (plan) => plan.details.any(
            (detail) => detail.contains(
              'SEARCH messages USING COVERING INDEX '
              'messages_conversation_ordering '
              '(conversation_id=? AND ordering_ms>?)',
            ),
          ),
        ),
        hasLength(3),
        reason: plans.map((plan) => plan.details.join(' | ')).join('\n'),
      );
      expect(
        plans.any(
          (plan) => plan.details.any(
            (detail) => detail.contains(
              'SEARCH attachments USING INDEX attachments_by_message '
              '(message_id=?)',
            ),
          ),
        ),
        isTrue,
      );
    },
  );

  test('paging backwards is answered out of the index alone', () async {
    final page = await repository
        .watchMessages(
          currentUserId: 'self',
          conversationId: 'conversation-0',
          window: const NewestConversationMessages(120),
        )
        .first;
    final plans = await plansOf(() async {
      await repository.olderMessageCursor(
        conversationId: 'conversation-0',
        before: page.oldest!,
        count: 120,
      );
    });
    expect(plans, hasLength(1));
    expect(
      plans.single.details.single,
      'SEARCH messages USING COVERING INDEX messages_conversation_ordering '
      '(conversation_id=? AND ordering_ms<?)',
    );
  });

  test('the conversation list reads every pin without touching a message '
      'that is not pinned', () async {
    final plans = await plansOf(() async {
      await repository.watchConversations('self').first;
    });
    expect(plans, hasLength(2));
    expect(
      plans.last.details.single,
      'SEARCH messages USING INDEX messages_pinned_by_conversation '
      '(conversation_id=?)',
    );
  });

  test(
    'applying an event seeks the facts about one message, and never scans',
    () async {
      final pairwise = DriftPairwiseTransportStore(database);
      await seedDeviceState(database);
      final commit = localMessageCommit(seed: 41, counter: 1);
      final eventId = protocolBytesToHex(commit.event.eventId);
      await pairwise.commitLocalEcho(
        operationId: 'application:$eventId',
        eventId: eventId,
        currentUserId: localUserId,
        currentDeviceId: localDeviceId,
        peerUserId: peerUserId,
        openedLocalPayload: commit.canonicalBytes,
        applicationEvent: commit,
      );

      final plans = await plansOf(() async {
        await database.writeTransaction(
          () => DriftApplicationEventProjector(database).applyInsideTransaction(
            peerReactionCommit(
              seed: 210,
              counter: 1,
              targetMessageId: commit.event.eventId,
            ),
          ),
        );
      });

      // The fold. This is the assertion the whole of F2 rests on and the only
      // place it can be made: written as an ordinary join it is one statement
      // either way, and SQLite — which has no statistics to go on — drives it
      // from `application_events_conversation_apply_state` and probes the target
      // index once per candidate event in the conversation. Same rows, same
      // statement count, linear in the conversation. `CROSS JOIN` fixes the
      // order, and only the plan can tell the two apart.
      expect(
        plans.any(
          (plan) =>
              plan.details.first ==
                  'SEARCH target USING COVERING INDEX '
                      'sqlite_autoindex_application_event_targets_1 '
                      '(message_id=?)' &&
              plan.details.last ==
                  'SEARCH event USING INDEX '
                      'sqlite_autoindex_application_events_1 (event_id=?)',
        ),
        isTrue,
        reason: plans.map((plan) => plan.details.join(' ; ')).join('\n'),
      );
      // The conversation's newest message, out of the ordering index in the
      // direction it already sorts, and its unread count out of a partial index
      // that holds only unread rows and answers without reading any of them.
      expect(
        plans.any(
          (plan) => plan.details.any(
            (detail) =>
                detail ==
                'SEARCH messages USING INDEX messages_conversation_ordering '
                    '(conversation_id=?)',
          ),
        ),
        isTrue,
      );
      expect(
        plans.any(
          (plan) => plan.details.any(
            (detail) =>
                detail ==
                'SEARCH messages USING COVERING INDEX '
                    'messages_unread_by_conversation (conversation_id=?)',
          ),
        ),
        isTrue,
        reason:
            'a bound `unread = ?` would silently fall back to a row lookup '
            'per message: ${plans.map((plan) => plan.sql).join('\n')}',
      );
      // And nothing on this path reads a table it does not seek into. The
      // candidate-event read is gone from it entirely; it belongs to the
      // recovery path now.
      for (final plan in plans) {
        for (final detail in plan.details) {
          expect(
            detail,
            isNot(
              anyOf(
                'SCAN messages',
                'SCAN application_events',
                'SCAN application_event_targets',
                'SCAN attachments',
                'SCAN outbox_operations',
              ),
            ),
            reason: plan.sql,
          );
        }
        expect(
          plan.details.any((detail) => detail.contains('USE TEMP B-TREE')),
          isFalse,
          reason: plan.sql,
        );
      }
    },
  );

  test(
    'a rebuild reads its own conversation, not the whole event log',
    () async {
      final pairwise = DriftPairwiseTransportStore(database);
      await seedDeviceState(database);
      final commit = localMessageCommit(seed: 41, counter: 1);
      final eventId = protocolBytesToHex(commit.event.eventId);
      await pairwise.commitLocalEcho(
        operationId: 'application:$eventId',
        eventId: eventId,
        currentUserId: localUserId,
        currentDeviceId: localDeviceId,
        peerUserId: peerUserId,
        openedLocalPayload: commit.canonicalBytes,
        applicationEvent: commit,
      );

      final plans = await plansOf(() async {
        await database.writeTransaction(
          () => DriftApplicationEventProjector(database)
              .rebuildConversationInsideTransaction(
                protocolBytesToHex(commit.event.conversationId),
                currentUserId: localUserId,
              ),
        );
      });

      // The candidate-event read is the one that used to scan every event this
      // device has ever stored, for anybody, and grow with the database rather
      // than with the conversation. It is the recovery path's read now, and it
      // still has to be a seek: a fork or a repair is exactly when the device
      // can least afford to read its whole log.
      expect(
        plans.any(
          (plan) => plan.details.any(
            (detail) => detail.contains(
              'SEARCH application_events USING INDEX '
              'application_events_conversation_apply_state '
              '(conversation_id=? AND apply_state=?)',
            ),
          ),
        ),
        isTrue,
        reason: plans.map((plan) => plan.sql).join('\n'),
      );
      // And nothing in a rebuild scans a table the timeline shares with it.
      for (final plan in plans) {
        for (final detail in plan.details) {
          expect(
            detail,
            isNot(
              anyOf(
                'SCAN messages',
                'SCAN application_events',
                'SCAN attachments',
                'SCAN outbox_operations',
              ),
            ),
            reason: plan.sql,
          );
        }
      }
    },
  );

  test('the held envelopes are read through their two partial indexes', () async {
    // ADR-093 D11: the Chats query, a sender's count and oldest row, the
    // release and the follow-up match. None of them may scan the inbox, which
    // holds up to 10,000 rows for at most 128 held ones.
    final sync = DriftSyncStore(database);
    final now = DateTime.utc(2026, 10, 17, 12);
    await sync.persistDrainPage(
      DrainPage(
        envelopes: [
          for (var sequence = 1; sequence <= 40; sequence += 1)
            SyncEnvelope(
              id: '00000000-0000-0000-0000-${sequence.toString().padLeft(12, '0')}',
              sequence: sequence,
              exactCiphertext: Uint8List(1024),
            ),
        ],
        hasMore: false,
        prunedThrough: 0,
      ),
    );
    Future<void> holdNext(int marker, {DriftSyncStore? into}) async {
      final envelope =
          (await sync.beginNextEnvelopeInspection(now: now)
                  as Success<SyncEnvelope?>)
              .value!;
      await (into ?? sync).recordEnvelopeHold(
        envelopeId: envelope.id,
        hold: HeldEnvelopeInspection(
          claimedSenderUserId: 'sender-${marker % 2}',
          sessionId: Uint8List.fromList(List.filled(16, marker)),
          initial: true,
        ),
        now: now,
      );
    }

    for (var marker = 1; marker <= 4; marker += 1) {
      await holdNext(marker);
    }

    final plans = await plansOf(() async {
      // At the phone's limit, so the hold also finds the phone's oldest row.
      await holdNext(
        5,
        into: DriftSyncStore(
          database,
          maximumHeldPerSender: 3,
          maximumHeldTotal: 4,
        ),
      );
      await sync.watchHeldSenders().first;
      await sync.releaseHeldEnvelopes(senderUserId: 'sender-1', dueAt: now);
      await sync.heldInitialSender(Uint8List.fromList(List.filled(16, 3)));
      await sync.readReleasableHeldSenders();
      await sync.expireHeldEnvelopes(now: now);
      await sync.readEarliestHoldTime();
    });

    var checked = 0;
    for (final plan in plans) {
      final upper = plan.sql.toUpperCase();
      final where = upper.contains('WHERE')
          ? plan.sql.substring(upper.lastIndexOf('WHERE'))
          : '';
      final String index;
      if (where.contains('held_session_id')) {
        index = 'inbox_envelopes_held_by_session';
      } else if (where.contains('held_sender_user_id')) {
        index = 'inbox_envelopes_held_by_sender';
      } else {
        continue;
      }
      checked += 1;
      expect(
        plan.details.any((detail) => detail.contains(index)),
        isTrue,
        reason: '${plan.sql}\n${plan.details}',
      );
      expect(
        plan.details,
        isNot(contains('SCAN inbox_envelopes')),
        reason: plan.sql,
      );
    }
    // The two counts, the follow-up check, the Chats query, the release, the
    // lookup, the releasable senders, the expiry and the earliest hold time.
    expect(checked, greaterThanOrEqualTo(8));
  });

  test(
    'transport state for one event is a seek, not a scan of the outbox',
    () async {
      final plans = await plansOf(() async {
        await database
            .customSelect(
              'SELECT * FROM outbox_operations WHERE event_id = ?',
              variables: [Variable<String>('event-x')],
            )
            .get();
      });
      expect(
        plans.single.details.single,
        'SEARCH outbox_operations USING INDEX outbox_operations_by_event '
        '(event_id=?)',
      );
    },
  );
}

final class _Plan {
  const _Plan(this.sql, this.details);

  final String sql;
  final List<String> details;
}

final class _Captured {
  const _Captured(this.sql, this.args);

  final String sql;
  final List<Object?> args;

  List<Variable<Object>> get variables => [
    for (final arg in args)
      switch (arg) {
        final int value => Variable<int>(value),
        final double value => Variable<double>(value),
        final Uint8List value => Variable<Uint8List>(value),
        final String value => Variable<String>(value),
        _ => Variable<String>('$arg'),
      },
  ];
}

final class _StatementRecorder extends QueryInterceptor {
  final List<_Captured> statements = [];
  bool recording = false;

  void _record(String statement, List<Object?> args) {
    if (recording) statements.add(_Captured(statement, args));
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _record(statement, args);
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _record(statement, args);
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _record(statement, args);
    return super.runDelete(executor, statement, args);
  }
}
