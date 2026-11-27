# ADR-091: Group read receipts, two-tick threshold, and sender reader list

- **Status:** Accepted (2026-10-14); proposed 2026-10-14
- **Date:** 2026-10-14 (explicitly recorded in register and full section; proposed in `7fbe2eaa`, PR #78 `3747d5d8`; built in three prompts on `frontend-group-read-receipts` in `ec69cb9d`–`d91c9d0e`, PR #79 `221b2816`)
- **Completes:** [ADR-090](090-group-timeline.md) D6 (group read-receipt follow-up)
- **Related:** [ADR-074](074-seen-tick.md), [ADR-075](075-pairwise-groups.md), [ADR-088](088-group-composer.md), [ADR-090](090-group-timeline.md), server [ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md), [message-protocol.md](../../message-protocol.md), [ui-specification.md](../../ui-specification.md), [CLIENT_CONTRACT.md](../../../../backend/CLIENT_CONTRACT.md)

## Decision (Position)

Implemented end-to-end encrypted group read receipts, first-reader two-tick status, and a per-message reader list visible only to the message's sender:

1. **D1 — Two ticks on first reader (`ChatMessageProjection._delivery` in [chat_view_model_mapper.dart](../../../lib/features/messaging/presentation/chat_view_model_mapper.dart)):**
   - An own group message displays two ticks (`AppIcons.read`, reserved for *seen* by [ADR-074](074-seen-tick.md)) as soon as at least one other member has read it, without waiting for remaining members or owed copies ([ADR-075](075-pairwise-groups.md) item 5 / [ADR-088](088-group-composer.md)). Failed messages keep the failed mark and Retry above all; unread messages show the sending clock while copies are owed and one tick once all copies are sent.
2. **D2 — Read receipts only:** Groups send no `receipt.delivered` events and show no delivered mark.
3. **D3 — Sender-only + own-device audience ([DriftGroupSendAudienceResolver](../../../lib/features/groups/infrastructure/drift_group_access_adapters.dart)):**
   - A group `receipt.read` event may name messages from **one sender only** and is addressed solely to that sender's live devices (when still an active member) plus the reader's other live devices (or reader's other devices only if the sender is no longer active).
   - `SendConversationEvents.sendReceipt` ([conversation_use_cases.dart](../../../lib/features/messaging/application/conversation_use_cases.dart)) resolves message senders via `readMessageSenders` (`application_event_targets` joined to `messages`) and `_requireOneSender` rejects mixed-sender or foreign-group receipts before spending a sender counter. Group delivered receipts and Saved Messages receipts remain refused.
4. **D4 — Per-sender batching:** `MarkConversationVisiblyRead._receipts` groups newly read group message IDs by sender and sends one `receipt.read` per sender in batches of up to 64 IDs (`ApplicationMessageProtocolV1.maximumReferences`).
5. **D5 — Direct-chat visibility triggers:** Routed group pages send read receipts only while this account can send into the group, on the same triggers as direct chats (conversation becomes visible while foregrounded, or unread message arrives while visible).
6. **D6 — Receiver admission:** Receiving clients admit group receipts only from active members, ignore receipts sent by the message's own sender, and apply receipts only to messages in the receipt's conversation.
7. **D7 — Sender-only reader list ([chat_message_readers.dart](../../../lib/features/messaging/presentation/chat_message_readers.dart)):**
   - On non-deleted own group messages, `ChatMessageBuilder._showActions` inserts `ChatReadersRow` (`"Seen by N"` or `"Not seen yet"`, keeping row height while loading and hiding on error) above sheet actions using `ChatReadersScope` (`WatchGroupMessageReadersCallback` backed by `ConversationRepositoryPort.watchMessageReaders` and `groupAvatarSeed`).
   - Tapping `"Seen by N"` closes the message sheet and opens `showChatReaderList` (`_ChatReaderList`, titled `"Seen by"` with body `"Not seen yet"` when empty), showing each reader once (display name or `chatShortIdentity`, newest first, live-updating while open; direct chats and incoming/deleted messages provide no scope/row).
8. **D8 — Read time semantics and clamping:**
   - A device's read time is the earliest `ordering_ms` of a `receipt.read` from that device naming the message (using `_orderingTimestamp`: 60 s behind newest message clamped just after it, pre-2000 or > 5 minutes ahead stored as `0`, treated as unknown / `"Time unknown"`).
   - A member's read time is the earliest across their devices (or unknown if none is non-zero), clamped at query time to never display earlier than the message's own `ordering_ms` (owner decision 2026-10-14; stored `read_at_ms` stays unclamped). `"Today"` uses the device's calendar day when the list builds; earlier days include the timeline's date-separator date format before the time.
9. **D9 — Local storage (schema 24):** Added nullable integer column `receipts.read_at_ms`, written by both incremental event application and conversation rebuild; pre-schema-24 rows and delivered rows keep null.
10. **D10 — Always on:** No setting disables group read receipts.
11. **D11 — Privacy:** Receipts remain end-to-end encrypted application events; the server sees envelope metadata only to the message sender and reader's other devices, and non-sender group members learn nothing.
12. **D12 — No wire/server change:** Uses existing `receipt.read` event format and relay; adds zero endpoints, event kinds, or dependencies (`backend/openapi.json` has 28 paths, none for receipts).

## Rationale

- Group messages never showed two ticks because `sendReceipt` refused non-direct conversations. Addressing receipts to the message sender alone rather than broadcasting to the entire group cuts a 50-member (3 devices/member) message read by 49 members from `49 × 149 = 7,301` (~7,300) receipt copies to `49 × 5 = 245` copies while keeping who read a message private to its sender.
- Clamping earlier reader clocks against the message's `ordering_ms` at read time avoids confusing "read before sent" timestamps while keeping raw corrected event ordering in storage.

## Constraints and Open Gates

- **Scope:** Added nullable `receipts.read_at_ms` (schema 24); changed group send audience resolution, receipt batching/sending, projector/repository reader query, and group message sheet/reader list UI plus `app_en.arb`/`app_fa.arb`; changed no wire format, event kind/field, dependency, cryptographic construction, or `backend/` file.
- **Verification:** Covered by [group_fanout_delivery_test.dart](../../../test/features/groups/application/group_fanout_delivery_test.dart), [conversation_use_cases_test.dart](../../../test/features/messaging/conversation_use_cases_test.dart), `conversation_local_state_test.dart` ([conversation_local_state_test.dart](../../../test/features/messaging/conversation_local_state_test.dart)), [local_database_migration_test.dart](../../../test/features/local_storage/infrastructure/local_database_migration_test.dart) (cited in `decisions.md` as `test/features/local_storage/infrastructure/database/local_database_migration_test.dart`), [receipt_read_time_test.dart](../../../test/features/messaging/receipt_read_time_test.dart), [projection_equivalence_test.dart](../../../test/features/messaging/projection_equivalence_test.dart), [group_pages_test.dart](../../../test/widget/group_pages_test.dart), [group_message_readers_test.dart](../../../test/widget/group_message_readers_test.dart) (including RTL Persian at 200% text scale), and [group_message_actions_test.dart](../../../test/widget/group_message_actions_test.dart), plus 6 targeted mutation checks (M1–M5 and `Expanded` removal).
- **Left open:** No physical-device or live-server three-account test run; reader list in direct chats, opt-out setting, and group delivered receipts remain intentionally unbuilt.

## Costs

- In a group, two ticks signify that at least one member read the message rather than all members; checking individual readers requires opening `"Seen by N"`.
- Read times reflect the reader device's clock (clamped only to ≥ message `ordering_ms` or zeroed when > 5 minutes ahead / pre-2000).
- A reader's other offline devices learn of the read only on their next mailbox drain.

## Reversal Trigger

Reopen if groups ever need a delivered state, a per-user/per-group read-receipt opt-out toggle, or a two-ticks-mean-everyone threshold.

## History, Amendments, and Supersession

- **2026-10-14 (`7fbe2eaa`, PR #78 `3747d5d8`):** Proposed ADR-091 design for sender-only group read receipts, first-reader two ticks, and reader list.
- **2026-10-14 (`ec69cb9d`–`d91c9d0e`, PR #79 `221b2816`):** Implemented prompts 1–3 (`frontend-group-read-receipts`), added schema 24 (`receipts.read_at_ms`), and accepted ADR-091.
