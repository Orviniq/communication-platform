# ADR-074: Reserving the double-tick glyph for read messages and sending read receipts

- **Status:** Accepted; group read receipts later added by ADR-091 (2026-10-14)
- **Date:** 2026-09-10 (explicitly recorded in register; code in `023f100a`, docs in `a16dc613`)
- **Supersedes in part:** [ADR-073](073-visible-read.md) (completes the unwired read-receipt / `MarkConversationVisiblyRead` items left deferred)
- **Related:** [ADR-016](016-english-and-persian.md), [ADR-031](031-semantic-icons.md), [ADR-061](061-durable-send.md), [ADR-073](073-visible-read.md), ADR-091

## Decision (Position)

*(Extracted from the ADR-074 register row and its introducing commits `023f100a` and `a16dc613`; no separate full section existed in `decisions.md`.)*

Reserved the double-tick icon strictly for *seen/read* messages and wired direct-chat `receiptRead` emission to [ADR-073](073-visible-read.md)'s visibility trigger:

1. **Glyph semantics ([app_icons.dart](../../../lib/app/design_system/app_icons.dart), [chat_message_builder.dart](../../../lib/features/messaging/presentation/chat_message_builder.dart)):**
   - Moved `AppIcons.delivered` from `FLucideIcons.checkCheck` to `FLucideIcons.check` and introduced `AppIcons.read` (`FLucideIcons.checkCheck`).
   - `accepted` and `delivered` both draw a single tick differentiated by color and localized semantics (`chatStateAccepted`, `chatStateDelivered`), while `read` draws two ticks (`chatStateRead` in accent color) so two ticks never represent automated device delivery.
   - Regenerated the three affected chat goldens (`chat_narrow_ltr.png`, `chat_wide_dark.png`, `chat_medium_rtl_high_contrast.png`) and pinned semantics in [chat_receipt_ticks_test.dart](../../../test/widget/chat_receipt_ticks_test.dart).
2. **Wiring `MarkConversationVisiblyRead` ([conversation_use_cases.dart](../../../lib/features/messaging/application/conversation_use_cases.dart), [messaging_providers.dart](../../../lib/app/dependencies/messaging_providers.dart), [direct_chat_page.dart](../../../lib/features/messaging/presentation/direct_chat_page.dart)):**
   - Wired `DirectChatPage._markRead` through `MarkConversationVisiblyRead` (passing `allowReadReceipts: !widget.savedMessages`, while `sendReceipt` already refuses non-direct conversations) on [ADR-073](073-visible-read.md)'s `VisibleConversationReadMarker` trigger and nowhere else.
   - Receipts cover the exact message IDs cleared by `markConversationRead`, are committed durably before network transmission ([ADR-061](061-durable-send.md)), and are bounded by the mark's no-op check (second visibility evaluation finds zero unread IDs and queues nothing).
3. **Zero backend change:**
   - `receiptRead` travels as an encrypted application event inside the same padded opaque envelope routes (`backend/openapi.json` has no receipt schema), byte-indistinguishable from `receiptDelivered`.

## Rationale

- Prior to ADR-074, `AppIcons.delivered` showed two ticks on automatic inbox-commit delivery while `MarkConversationVisiblyRead` had no provider/caller, making `read` unreachable and misleading senders into believing messages were seen while recipients had not opened the chat.
- Matching the universal two-tick = read convention and sourcing receipts solely from the cleared unread set keeps local read state and remote seen state identical.

## Constraints and Open Gates

- **Scope:** No backend, schema, crypto, or wire-format change; opens no production gate.
- **Left undone at ADR-074:**
  - No user-facing privacy setting backed `allowReadReceipts` (passed `true` for all direct chats; disclosure made no statement either way).
  - Conversation-level rather than per-message read marking.
  - Groups still recorded no unread state and sent no read receipts (later implemented in ADR-090 and ADR-091).

## Costs

- Direct-chat read receipts are always sent for visible direct chats (excluding Saved Messages) until a user toggle is introduced.

## Reversal Trigger

Reopen when adding a read-receipt privacy preference behind `allowReadReceipts` or extending read receipts to groups (implemented for groups in ADR-091).

## History, Amendments, and Supersession

- **2026-09-10 (`023f100a`, `a16dc613`):** Recorded and implemented ADR-074 (`Accepted`), updating `AppIcons.delivered`/`read`, wiring `MarkConversationVisiblyRead` in `DirectChatPage`, and adding `chat_receipt_ticks_test.dart`.
- **2026-10-14 (ADR-091):** Added group read receipts (sent to the message sender's devices and reader's other devices) and per-member reader lists.
