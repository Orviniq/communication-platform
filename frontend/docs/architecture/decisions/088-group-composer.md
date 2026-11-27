# ADR-088: Group composer persistence and removal of per-bubble copy count

- **Status:** Accepted (2026-10-09); withdraws the copy count of [ADR-075](075-pairwise-groups.md) item 5
- **Date:** 2026-10-09 (explicitly recorded in register and full section; PR #72 `b71f2d69`, commits `6f823836`, `fb25aae4`, `1446a832`)
- **Amends:** [ADR-075](075-pairwise-groups.md) (withdraws the `"Copies sent: M of N"` text from item 5 while preserving owed-copy sent gating and retry)
- **Related:** [ADR-075](075-pairwise-groups.md), [ADR-090](090-group-timeline.md), [ADR-091](091-group-receipts.md), [SCREENS.md](../../ui/SCREENS.md#group-chat-screen), [STATUS.md](../../STATUS.md)

## Decision (Position)

Fixed two owner-reported UX defects in [group_chat_page.dart](../../../lib/features/groups/presentation/group_chat_page.dart) and the group message bubble:

1. **D1 — Keep the group composer mounted during sends:**
   - Removed the progress bar that previously replaced the group composer while a send ran, keeping the composer in the widget tree continuously (as direct conversations already do) so the text field keeps focus and the soft keyboard stays open across consecutive messages.
   - Because sends can now overlap without a blocking bar, the inline send error (`"The message was not saved. Nothing was sent."`) is only raised by a failing send and cleared at the start of a subsequent send — an overlapping successful send never clears an earlier failed send's error.
   - Rejected moving a progress bar above the composer (unnecessary busy chrome for a local DB queue write whose state already shows on the message bubble).
2. **D2 — Show only the delivery state icon on group message bubbles, with no copy count:**
   - Removed `"Copies sent: M of N"` beside the delivery mark on in-flight group messages; deleted `chatFanoutProgress` in English and Persian (`app_en.arb`, `app_fa.arb`), the view-model progress field, the group screen's progress map, `groupFanoutProgressProvider`, and the spoken count in the bubble's semantics label.
   - Rejected reserving a fixed wide width on every outgoing group bubble to stop resizing.
   - **Preserved from [ADR-075](075-pairwise-groups.md) item 5:** A group message is still marked sent only when zero copies are owed (`stale_devices` cleared from owed targets, `full_devices` kept owed until accepted, failed messages offer Retry). `GroupRepositoryPort.watchFanoutProgress` ([group_ports.dart](../../../lib/features/groups/application/ports/group_ports.dart)), `DriftGroupRepository.watchFanoutProgress` ([drift_group_repository.dart](../../../lib/features/groups/infrastructure/drift_group_repository.dart)), and `GroupFanoutProgress` ([group_model.dart](../../../lib/features/groups/domain/group_model.dart)) remain in place and tested for delivery/fan-out tests, though no UI screen reads them.

## Rationale

- Group sends write to the local database and queue fan-out targets via the same durable send path as direct messages and return before network fan-out; unmounting the composer waited on nothing while dismissing the user's keyboard after every message.
- Short messages are sized by their footer row; rendering `"Copies sent: 45 of 150"` made a bubble expand dramatically while sending and collapse once sent (404 px vs. 131 px in the pre-change 800 px widget layout; 448.25 px vs. 130.75 px in the regression mutation check), whereas the delivery mark already indicates sending vs. sent state.

## Constraints and Open Gates

- **Scope:** Changed the group chat screen, message bubble, one provider, and one localized string pair; changed no local table, wire format, protocol, dependency, cryptographic construction, or `backend/` file.
- **Verification:** Covered by [group_pages_test.dart](../../../test/widget/group_pages_test.dart) on mounted `GroupChatPage` (verifying composer focus and text-input channel retention during an in-flight send, inline error persistence across overlapping sends, constant bubble width across queued → sending → sent, and mutation failure when progress text is restored).
- **Left open:** No physical-device run (keyboard persistence verified via Flutter widget focus/text-input channel, not an OS IME); fan-out progress counts are not shown in message details and `watchFanoutProgress` remains unread by UI code.

## Costs

- Users no longer see numeric fan-out progress (`M of N` copies sent) on large groups while copies are still draining.
- Overlapping sends mean an inline error from one failed send persists until the user starts the next send rather than being cleared if a concurrent send completes.
- `watchFanoutProgress` and `GroupFanoutProgress` remain in repository/domain code solely for delivery test observation.

## Reversal Trigger

Reopen if large-group senders require numeric fan-out progress inside a message details sheet (using the retained `watchFanoutProgress` query without altering bubble width) or if `watchFanoutProgress` is replaced in fan-out tests and can be deleted.

## History, Amendments, and Supersession

- **2026-10-09 (`6f823836`, `fb25aae4`, `1446a832`, PR #72 `b71f2d69`):** Implemented and accepted ADR-088 keeping the group composer mounted during sends and withdrawing [ADR-075](075-pairwise-groups.md) item 5's per-bubble copy count.
