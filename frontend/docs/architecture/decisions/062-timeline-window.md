# ADR-062: Bounded cursor-anchored timeline window and first database indexes

- **Status:** Accepted
- **Date:** 2026-08-27 (explicitly recorded in register and full section; implemented in `d1d1a0f`, documented in `5776e98`)
- **Amends:** [LOCAL-DATA.md](../LOCAL-DATA.md#search) and [ADR-057](057-measured-settings.md) search scope (in-conversation search reads the loaded window rather than the whole local history; out-of-window targets load on jump via `reveal`)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-057](057-measured-settings.md), [ADR-061](061-durable-send.md), [ADR-063](063-event-projection.md), [ADR-064](064-incremental-rebuild.md)

## Decision (Position)

Replaced unbounded `3N + 1` timeline queries and zero-index table scans with a cursor-anchored keyset page window, set-based child queries, and six `EXPLAIN QUERY PLAN`-verified indexes (schema 16 → 17):

1. **D1 — Bottom-anchored keyset window ([conversation_model.dart](../../../lib/features/messaging/domain/conversation_model.dart), [drift_conversation_domain_repository.dart](../../../lib/features/messaging/infrastructure/drift_conversation_domain_repository.dart)):**
   - `watchMessages` takes `ConversationMessageWindow` (`NewestConversationMessages(n)` or `ConversationMessagesFrom(cursor)`) over `(ordering_ms, ordering_event_id, message_id)` and returns `ConversationMessagePage`.
   - Subsequent reads anchor at the oldest loaded message rather than taking a sliding "newest N" count so incoming messages never push the user's reading line off the bottom (`chat_pagination_test.dart`).
   - Rejected `OFFSET` in favor of `olderMessageCursor`; keyset predicate includes an explicit `ordering_ms >= :ms` range constraint so SQLite seeks from the boundary instead of scanning from the newest row.
2. **D2 — Set-based child reads (`3N + 1` → 6 statements):**
   - Reactions, receipts, and attachments each execute once per emission joined against the shared `_windowOf` predicate and grouped in memory (`local_read_cost_test.dart`: **3601 → 6** statements at 1200 messages; **25 → 6** at 8 messages; `watchConversations` reduced to **2** statements).
   - Reactions sort in Dart to prevent a temporary B-tree sort in SQLite.
3. **D3 — Complete conversation pins alongside the window:**
   - `pinnedMessages` (`ChatTimelineViewModel`) carries the conversation's entire pinned set (one query per emission) rather than page-scoped pins so banner counts match the pinned-messages sheet.
4. **D4 — `reveal` jump loading ([conversation_timeline.dart](../../../lib/features/messaging/application/conversation_timeline.dart)):**
   - `ConversationTimelineWindow.reveal` looks up `messageCursor` by primary key and widens the window to include a page of context below any out-of-window target (from search, pinned banner, reply quote, or `JumpToMessageIntent`), while the timeline retains unresolved jump requests across page emissions.
5. **D5 — Window controller behind unchanged provider identity ([messaging_providers.dart](../../../lib/app/dependencies/messaging_providers.dart)):**
   - Kept the provider family key `(currentUserId, conversationId)` unchanged and placed range state, `loadingBefore`, `olderLoadFailed`, and DB subscription retargeting inside `ConversationTimelineWindow` so paging backwards never disposes `autoDispose` providers or destroys scroll position; empty anchored windows reset to the newest page.
   - Composes cleanly with `ChatTimelineAdapter`'s 80 + 60 display-window handshake over 120-row DB pages (`chat_timeline.dart` at `d1d1a0f`, later split into [chat_timeline_adapter.dart](../../../lib/features/messaging/presentation/chat_timeline_adapter.dart)).
6. **D6 — Six schema-17 indexes verified by `EXPLAIN QUERY PLAN` ([local_database.dart](../../../lib/features/local_storage/infrastructure/database/local_database.dart), [local_database_index_plan_test.dart](../../../test/features/local_storage/infrastructure/local_database_index_plan_test.dart)):**
   - `messages_conversation_ordering` on `(conversation_id, ordering_ms, ordering_event_id, message_id)` — serves window reads, ordering without temp B-tree, cursor probes, and conversation-scoped writes (+3.0% write cost on 1200-msg rewrite; newest-120 read drops from 4,676–5,722 µs to 2,712–2,911 µs in memory).
   - `messages_pinned_by_conversation` on `(conversation_id, message_id) WHERE pinned` — partial index requiring bare `pinned` predicate (bound `pinned = ?` degraded to 453 µs vs. 287 µs) and Dart sorting.
   - `attachments_by_message` on `(message_id)` — removes full table scans on `attachments` during `ON DELETE CASCADE` checks on every `messages` write (cuts 1200-msg rewrite from **96,234 µs** to **27,442 µs**, a 71% drop; 4800-msg seed whole index set cuts rewrite from 594,078 µs to 83,008 µs).
   - `application_events_conversation_apply_state` on `(conversation_id, apply_state)` and `application_events_sender_counter` on `(sender_device_id, sender_counter)` — keeps projector candidate reads and replay checks flat across 1k–50k total stored events.
   - `outbox_operations_by_event` on `(event_id)`.
   - Deliberately left unindexed: `unsupported_application_events` (empty on current protocol), `nextEditRevision` `MAX(revision)` (~300 µs off hot path), `pending_send_preparations.state` (0–3 rows), and `conversations` list sort.

## Rationale

- Unbounded queries and zero indexes forced `3N + 1` statements and full encrypted-page table scans under SQLCipher on every emission; keyset anchoring + planner-verified indexes bound both statement count and scan range without breaking scroll stability.

## Constraints and Open Gates

- **Scope:** Additive index-only migration (16 → 17, `IF NOT EXISTS`, rollback-safe in transaction); zero cryptographic, wire, or `backend/` changes; opens no production gate.
- **Page-scoped behavior ([LOCAL-DATA.md](../LOCAL-DATA.md#search)):** In-conversation search filters loaded rows (full-history chat search subsequently added separately at `/chats/search` under ADR-087); `ConversationSummary.pinnedMessageIds` remains computed for summary contract parity despite the chat page reading `pinnedMessages`.
- **Deferred at ADR-062:** F2 (incremental projection — addressed in ADR-063), F6 (peer cache — addressed in ADR-065), F8–F10 (UI mapper/anchor/debounce — addressed in ADR-064), widening `watchMessages` stream triggers beyond `messages`, and on-device A56 timing for long conversations.

## Costs

- Schema 17 migration scans all 4 indexed tables once at first open (6 `CREATE INDEX` passes; +18% DB file growth on the 4800-message seed, 1472 → 1731 pages).
- `messages_conversation_ordering` adds +3.0% write overhead on full rebuilds (greatly outweighed by `attachments_by_message`'s 71% cascade reduction).
- Partial index `messages_pinned_by_conversation` relies on bare SQL predicate spelling policed by `local_database_index_plan_test.dart`.

## Reversal Trigger

Reopen if whole-history in-conversation search (without paging) requires a repository query, if `watchMessages` must react to child-table updates that do not touch `messages`, or if query-plan regressions occur under future SQLite/SQLCipher versions.

## History, Amendments, and Supersession

- **2026-08-27 (`d1d1a0f`, `5776e98`):** Recorded and implemented ADR-062 (`Accepted`), adding `ConversationMessageWindow`, `ConversationTimelineWindow`, set-based child queries, schema-17 indexes, and planner tests, while scoping in-conversation search to the loaded window.
- **2026-10-09 (ADR-087):** Added `/chats/search` full-history chat search alongside in-conversation search.
