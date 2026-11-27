# ADR-073: Visibility-gated conversation read marking

- **Status:** Accepted; "not done here" read-receipt wiring superseded by [ADR-074](074-seen-tick.md) (2026-09-10); group read marking later added by ADR-090 / ADR-091 (2026-10-14)
- **Date:** 2026-09-10 (explicitly recorded in register; code in `bb2c1d87`, docs in `54f49cc3`)
- **Amends:** [ADR-048](048-generic-notifications.md) (closes the arrival-while-open unread limitation and establishes the visibility trigger for follow-up 4)
- **Superseded in part by:** [ADR-074](074-seen-tick.md) (wires `MarkConversationVisiblyRead` to the visibility trigger)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-047](047-networking-composition.md), [ADR-048](048-generic-notifications.md), [ADR-074](074-seen-tick.md), ADR-090, ADR-091

## Decision (Position)

*(Extracted from the ADR-073 register row and its introducing commits `bb2c1d87` and `54f49cc3`; no separate full section existed in `decisions.md`.)*

Replaced mount-time conversation read marking with continuous foreground-and-route visibility gating:

1. **Visibility trigger (`VisibleConversationRegistry` + `VisibleConversationReadMarker` in [visible_conversation.dart](../../../lib/features/messaging/presentation/visible_conversation.dart)):**
   - Removed `ChatConversationView.initState` post-frame `MarkConversationReadIntent` (and deleted `MarkConversationReadIntent`), because a route in the Navigator remains mounted behind a backgrounded app and builds before foreground lifecycle confirmation, previously marking background arrivals as read on app launch.
   - Triggered read marking exclusively from `VisibleConversationRegistry.conversationId` (mounted route AND resumed/foregrounded application — the same definition used by [ADR-048](048-generic-notifications.md) to suppress notifications for the open chat).
   - `VisibleConversationReadMarker` ([direct_chat_page.dart](../../../lib/features/messaging/presentation/direct_chat_page.dart)) re-evaluates on visibility changes (including returning to foreground) and on new message arrivals while open (closing [ADR-048](048-generic-notifications.md)'s limitation where messages arriving on screen stayed unread until leaving and returning), collapsing signals that arrive mid-write into one subsequent pass.
2. **No-op guard in `markConversationRead` ([drift_conversation_domain_repository.dart](../../../lib/features/messaging/infrastructure/drift_conversation_domain_repository.dart)):**
   - `markConversationRead` returns before executing any database write when no message is unread and the conversation's unread count is already zero, making repeated visibility/arrival re-evaluation cheap and preventing feedback loops through watched conversation streams.
3. **Scope left explicitly deferred at ADR-073:**
   - Read receipts remained unsent (`MarkConversationVisiblyRead` remained unwired until [ADR-074](074-seen-tick.md) later the same day), and group conversations remained untouched (the piece-18 group projection still wrote no unread state until ADR-090 / ADR-091).

## Rationale

- Coupling local read marking and (next in [ADR-074](074-seen-tick.md)) read receipts to one `VisibleConversationRegistry` signal guarantees that notifications, local unread counts, and peer read receipts agree on what "the user is looking at this conversation" means.

## Constraints and Open Gates

- **Scope:** Presentation and repository write-guard only; no schema, crypto, wire, or `backend/` change; opens no production gate.
- **Verification scope:** Verified by unit tests ([visible_conversation_read_marker_test.dart](../../../test/features/messaging/visible_conversation_read_marker_test.dart), [conversation_local_state_test.dart](../../../test/features/messaging/conversation_local_state_test.dart)); no physical-device run was executed for ADR-073 alone.

## Costs

- Visibility transitions and inbound arrivals while a direct chat is open invoke the repository's read check, which short-circuits with zero writes when nothing is unread.

## Reversal Trigger

Reopen if the definition of active conversation visibility changes, or when extending visible-read marking to additional surfaces (subsequently extended by [ADR-074](074-seen-tick.md) for direct read receipts and ADR-090 / ADR-091 for groups).

## History, Amendments, and Supersession

- **2026-09-10 (`bb2c1d87`, `54f49cc3`):** Recorded and implemented ADR-073 (`Accepted`), introducing `VisibleConversationReadMarker`, deleting `MarkConversationReadIntent`, and guarding `markConversationRead` as a no-op when already clear.
- **2026-09-10 (`023f100a`, `a16dc613` / [ADR-074](074-seen-tick.md)):** Wired `MarkConversationVisiblyRead` to the visibility trigger.
- **2026-10-14 (ADR-090 & ADR-091):** Unified group chats onto `conversationMessagesProvider` and wired group visible-read marking and read receipts.
