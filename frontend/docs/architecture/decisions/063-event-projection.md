# ADR-063: Incremental event projection via `application_event_targets`

- **Status:** Accepted
- **Date:** 2026-08-27 (explicitly recorded in register and full section; implemented in `9aee093`, documented in `50b6655`)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-060](060-delivery-latency.md), [ADR-061](061-durable-send.md), [ADR-062](062-timeline-window.md), [ADR-064](064-incremental-rebuild.md), [ADR-089](089-direct-attachments.md)

## Decision (Position)

Replaced whole-conversation event-log rebuilds on ordinary event application with per-message incremental folding backed by a derived target index (`application_event_targets`, schema 17 → 18), while preserving the full rebuild as an independent recovery path and test oracle:

1. **D1 — Total affected-message derivation (`_affectedMessageIds`):**
   - Exhaustively extracts target message IDs over every stored event kind: single ID for `messageCreate` (`body.message_id`), `messageEdit`/`messageDelete`/`reactionSet`/`pinSet` (`target_message_id`), and `message_ids` list for `receiptDelivered`/`receiptRead`.
2. **D2 — Single projection function ([drift_application_event_projector.dart](../../../lib/features/messaging/infrastructure/drift_application_event_projector.dart)):**
   - Kept `_projectMessage` as the sole fold implementation: full rebuilds pass the conversation's entire candidate fact list; incremental applies pass only the facts naming that message ID from `application_event_targets`.
3. **D3 — Derived index table `application_event_targets` (schema 17 → 18, [local_database.dart](../../../lib/features/local_storage/infrastructure/database/local_database.dart)):**
   - Stores one `(message_id, event_id)` row for every stored event regardless of apply state, keyed by `(message_id, event_id)` with deliberately **no foreign key** on `event_id` (avoiding unindexed child scans on `application_events` writes).
   - Derived index only (reads always join back to `application_events` so stale rows match nothing; rebuilds rewrite target rows for every folded fact).
   - Migration back-fills single-target kinds in one SQL statement and decodes creates/receipts in keyset pages over the primary key (no `OFFSET`, no SQLite JSON dependency, `INSERT OR IGNORE` idempotent, undecodable bodies skipped).
4. **D4 — `CROSS JOIN` fixed join order:**
   - The incremental fold spells `FROM application_event_targets target CROSS JOIN application_events event` scoped by `event.conversation_id = ? AND event.apply_state = ?` so SQLite drives from `target.message_id` instead of scanning every event in the conversation (asserted by [local_database_index_plan_test.dart](../../../test/features/local_storage/infrastructure/local_database_index_plan_test.dart)).
5. **D5 — Shared conversation aggregates and partial unread index:**
   - Both incremental apply and rebuild call `_refreshConversationAggregates`: newest message preview/ordering/activity via reverse read of `messages_conversation_ordering` (`LIMIT 1`), and `unread_count` via covering partial index `messages_unread_by_conversation` on `(conversation_id, unread) WHERE unread` (using bare `unread` predicate; O(u) in unread count: 93–431 µs up to 20k unread, rejecting O(1) deltas to keep a single definition).
6. **D6 — Boundary between incremental apply and full rebuild:**
   - `applied` events fold incrementally (removing messages explicitly when unprojectable).
   - Full rebuild (`rebuildConversationInsideTransaction`, made public) keeps all fact-retirement paths (`eventIdConflict`, `counterConflict`, `conversationRejected`, forks/repairs, future conversation-level authorization changes) and receives escalations when incremental apply encounters a corrupt stored body.
   - Narrowed `refreshTransportForEventInsideTransaction` ([ADR-061](061-durable-send.md)) remains untouched; `delivered_receipt_sent` moves into `_LocalMessageState` (removing a per-message `SELECT`).

## Rationale

- `_rebuildConversation` previously scanned and re-folded the entire conversation's event log on every message, edit, reaction, pin, and batch receipt (**6,556 statements / 283 ms** at 1,200 messages), making receiving scale with total thread length.
- Keeping the O(N²) full rebuild independent of `_affectedMessageIds` prevents shared-bug blindness in the differential equivalence oracle (`projection_equivalence_test.dart`).

## Constraints and Open Gates

- **Scope:** Additive migration (schema 17 → 18); zero cryptographic, protocol, wire, or `backend/` changes; opens no production gate.
- **Verification suites:**
  - [projection_equivalence_test.dart](../../../test/features/messaging/projection_equivalence_test.dart): 24 adversarial shuffled sequences comparing incremental state against step-by-step rebuild and clean log-only rebuild.
  - [projection_recovery_path_test.dart](../../../test/features/messaging/projection_recovery_path_test.dart): verifies tampering recovery on retirement paths.
  - [incremental_apply_crash_safety_test.dart](../../../test/features/messaging/incremental_apply_crash_safety_test.dart): verifies crash rollback and convergence across reopened DB faults.
  - [local_database_migration_test.dart](../../../test/features/local_storage/infrastructure/local_database_migration_test.dart): verifies v17→v18 back-fill and post-upgrade folding.
  - [local_apply_cost_test.dart](../../../test/features/messaging/local_apply_cost_test.dart): 1200-message apply costs **14–16 statements / 1,061–1,244 µs** (245 statements / 16,786 µs for a 32-id receipt), identical at 48 and 1,200 messages; [local_send_cost_test.dart](../../../test/features/messaging/local_send_cost_test.dart) echo linearity assertion inverted.
- **Left undone at ADR-063:** F6 (peer cache — addressed in ADR-065), F8–F10 (UI render/debounce — addressed in ADR-064), pre-existing deletion/re-insertion of `attachments` rows on message re-fold (subsequently fixed in `8ca4a1a` / ADR-089 D10 so downloaded files survive re-folds), `unsupported_application_events` scan, O(u) unread count, and A56 on-device long-thread measurement.

## Costs

- Adds one derived-state table (`application_event_targets`) and one partial index (`messages_unread_by_conversation`), plus a one-time v17→v18 keyset back-fill scan over `application_events`.
- Full recovery rebuilds remain deliberately O(N²) to preserve oracle independence.

## Reversal Trigger

Reopen if `unread_count` O(u) cost becomes significant under huge unread backlogs, if group role authorization requires incremental transitions instead of targeted `rebuildConversationInsideTransaction`, or if `application_event_targets` back-fill latency proves prohibitive on large existing databases.

## History, Amendments, and Supersession

- **2026-08-27 (`9aee093`, `50b6655`):** Recorded and implemented ADR-063 (`Accepted`), adding schema 18 `application_event_targets`, `messages_unread_by_conversation`, `CROSS JOIN` incremental fold, shared `_refreshConversationAggregates`, and equivalence/cost/crash suites.
- **2026-10-10 (`8ca4a1a`, ADR-089 D10):** Updated attachment projection so matching capabilities retain their cache handle and state across re-folds rather than deleting and re-inserting attachment rows.
