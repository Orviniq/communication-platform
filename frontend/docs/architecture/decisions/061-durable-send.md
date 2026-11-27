# ADR-061: Local-first message echo, durable send preparations, and narrow status writes

- **Status:** Accepted
- **Date:** 2026-08-27 (explicitly recorded in register and full section; implemented in `8036634`, documented in `bdef40d`)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-060](060-delivery-latency.md), [ADR-062](062-timeline-window.md), [ADR-063](063-event-projection.md), [ADR-064](064-incremental-rebuild.md), ADR-065

## Decision (Position)

Eliminated the >3 s tap-to-bubble latency on direct messages and the O(N) conversation rebuild on every outbox attempt transition by committing the local message first and deferring fan-out sealing to the delivery cycle:

1. **D1 — Local echo commits before network work (`commitLocalEcho`, schema 15 → 16):**
   - Replaced `ApplicationFanoutPort.prepareAndQueue` with `commitLocalEcho` across `SendConversationEvents` ([conversation_use_cases.dart](../../../lib/features/messaging/application/conversation_use_cases.dart)), [pairwise_application_fanout_adapter.dart](../../../lib/features/messaging/infrastructure/pairwise_application_fanout_adapter.dart), [pairwise_fanout_coordinator.dart](../../../lib/features/pairwise/application/pairwise_fanout_coordinator.dart), and [drift_pairwise_transport_store.dart](../../../lib/features/pairwise/infrastructure/drift_pairwise_transport_store.dart).
   - One local transaction writes `pairwise_local_applications` (opaque payload), a queue row in `pending_send_preparations` ([local_database.dart](../../../lib/features/local_storage/infrastructure/database/local_database.dart)), and the message projection, touching no network. Covers every application event kind (creates, edits, deletes, reactions, pins, receipts).
   - Used a separate table rather than a status column on `pairwise_local_applications` because `pairwise_local_applications` is idempotency metadata pruned at 16 days, coupled only by the rule that retention never discards a payload still owed in `pending_send_preparations` ([local-data-model.md](../../local-data-model.md#retention-and-deletion)).
2. **D2 — Delivery cycle owns fan-out preparation ([durable_sync_engine.dart](../../../lib/features/synchronization/application/durable_sync_engine.dart), [pairwise_send_preparation_adapter.dart](../../../lib/features/messaging/infrastructure/pairwise_send_preparation_adapter.dart)):**
   - Added `_prepareSends` before each `_flushOutbox` pass (per-run budget 32 vs. outbox 100), calling `SendPreparationPort` → `PairwiseFanoutCoordinator.prepareOwedSend`, which deletes the preparation row in the same transaction that inserts the sealed `outbox_operations` rows.
   - Re-entrancy checks existing sealed outbox rows rather than `readPreparedOperation` (which now exists before sealing). Transport failures leave the row owed with `SyncRetryPolicy` backoff and halt the stage; settled failures (`_isPermanentSendFailure` / `SecurityFailure`) retire that single preparation to terminal failure and continue.
   - Moved `DeviceLogGossipCoordinator.queueForUser` off the user send path into post-preparation background execution (later moved again by ADR-065 behind the outbox as cycle-owned debt).
3. **D3 — Per-operation `outbox_depth` and `nextRetryAt` ([drift_sync_store.dart](../../../lib/features/synchronization/infrastructure/drift_sync_store.dart)):**
   - `outbox_depth` counts distinct non-terminal operation IDs across `outbox_operations` union `pending_send_preparations` **per operation** (not per target row, so sealing three recipient envelopes does not trigger a spurious second cycle and REST drain).
   - `nextRetryAt` incorporates due times from `pending_send_preparations`.
4. **D4 — `messages.status` carried through rebuilds ([drift_application_event_projector.dart](../../../lib/features/messaging/infrastructure/drift_application_event_projector.dart)):**
   - `_rebuildConversation` preserves existing `messages.status` (deriving from `outbox_operations` only when creating a new row), matching the `alerted`/`starred`/`delivered_receipt_sent` pattern while keeping `outbox_operations` authoritative.
   - Narrowed `refreshTransportForEventInsideTransaction` to exit immediately unless the stored event is a locally originated `messageCreate`, updating the single row matching `message_id = :eventId AND ordering_event_id = :eventId`.
5. **D5 — Eighth transport state `MessageTransportState.preparing` ([conversation_model.dart](../../../lib/features/messaging/domain/conversation_model.dart)):**
   - Appended `preparing` at ordinal 7 (already admitted by `messages.status` `0..8` check constraint), mapping onto the previously unreachable `ChatDeliveryViewState.encrypting` / `chatStateEncrypting` UI state ([chat_view_model_mapper.dart](../../../lib/features/messaging/presentation/chat_view_model_mapper.dart)).
6. **D6 — In-place retry (`rearmFailedSend`):**
   - `RetryMessageIntent` / `SendConversationEvents.retrySend` invokes `rearmFailedSend` to re-arm either a terminally failed preparation or permanently failed outbox rows in place without burning a new sender counter, falling back to a fresh `sendText` only when the operation record has already been pruned.

## Rationale

- Placing HTTPS peer/self device lookups, prekey claims, and ratchet steps behind the local commit instead of in front of it brings tap-to-bubble latency down to a local SQLite transaction without weakening transport or ratchet guarantees.
- Preserving `messages.status` across full rebuilds eliminates the clobber hazard while removing two full-conversation rebuilds per send (`queued → sending` and `sending → accepted`) and one per-message `SELECT` per rebuild.

## Constraints and Open Gates

- **Scope:** Schema 15 → 16 (additive table only, no back-fill); touches zero cryptographic constructions, wire formats, transport trust anchors, or `backend/` files; opens no production gate.
- **Verified crash safety ([local_echo_crash_safety_test.dart](../../../test/features/messaging/local_echo_crash_safety_test.dart)):** Four fault-injection tests against reopened DB files verify atomic invariants (never both owed and queued; never neither when projection fails).
- **Measured statement counts ([local_send_cost_test.dart](../../../test/features/messaging/local_send_cost_test.dart)):** At 5 vs. 61 messages, `queued → sending` dropped to **7** statements (from 27 / 195), `sending → relay-accepted` to **4**, and `preparing → queued` to **15**, equal across both lengths. The initial echo remained **33** (5 msgs) / **201** (61 msgs) pending ADR-063.
- **Explicitly deferred at ADR-061:** F2 (incremental projection — fixed in ADR-063), F4 (indexes — fixed in ADR-062), F5 (read window — fixed in ADR-062), F6/F7 (peer cache & gossip debt — fixed in ADR-065), F8–F10 (UI render/debounce — fixed in ADR-064), and on-device A56 tap-to-bubble measurement.

## Costs

- Adds one durable queue table (`pending_send_preparations`) and introduces a visible `encrypting` (`preparing`) state on the timeline when a device is offline or delayed resolving recipient keys.
- Separates send commit and sealing into two transactions bridged by durable queue re-entrancy.

## Reversal Trigger

Reopen if durable preparation retries or schema retention rules conflict with future multi-device or group send semantics, or if `messages.status` carrier semantics diverge from `outbox_operations`.

## History, Amendments, and Supersession

- **2026-08-27 (`8036634`, `bdef40d`):** Recorded and implemented ADR-061 (`Accepted`), adding schema 16 `pending_send_preparations`, `_prepareSends`, `MessageTransportState.preparing`, narrow `refreshTransportForEventInsideTransaction`, and in-place `rearmFailedSend`.
- **2026-08-27 (ADR-063 / `9aee093`):** Eliminated the remaining O(N) echo cost (`201` statements at 61 msgs) and inverted the linearity assertion in [local_send_cost_test.dart](../../../test/features/messaging/local_send_cost_test.dart).
- **2026-08-28 (ADR-065 / `335fbf3`):** Moved `DeviceLogGossipCoordinator` out of `PairwiseSendPreparationAdapter` to cycle-owned post-inbox debt behind the outbox.
