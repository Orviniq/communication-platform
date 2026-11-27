# ADR-090: Shared conversation timeline projection and message actions in group chats

- **Status:** Accepted (2026-10-14); proposed 2026-10-14; D4 superseded in part by ADR-096 (2026-10-19) for Pin and Delete for everyone
- **Date:** 2026-10-14 (explicitly recorded in register and full section; PR #77 `9c60fc34`, commits `a8c828e7`–`d8bc6872`)
- **Superseded in part by:** ADR-096 (2026-10-19, supersedes D4 for Pin and Delete for everyone using signed roster roles; Edit stays off)
- **Related:** [ADR-075](075-pairwise-groups.md), [ADR-088](088-group-composer.md), [ADR-089](089-direct-attachments.md), [ADR-091](091-group-receipts.md), ADR-096, [ui-specification.md](../../ui-specification.md), [CLIENT_CONTRACT.md](../../../../backend/CLIENT_CONTRACT.md)

## Decision (Position)

Unified group chat message reading and actions onto the shared conversation timeline projection ([chat_view_model_mapper.dart](../../../lib/features/messaging/presentation/chat_view_model_mapper.dart), [group_chat_page.dart](../../../lib/features/groups/presentation/group_chat_page.dart)):

1. **D1 — One timeline projection for direct and group chats:**
   - `GroupChatPage` reads `conversationMessagesProvider` keyed by `groupId`, mapped through one page-held `ChatMessageProjection.mapGroup`, paging via `conversationTimelineWindowProvider` (`loadOlder()`, `reveal(id)`) and setting `highlightedMessageId` so search results and reply quotes scroll to targets. Groups show no pinned-messages banner.
   - `mapGroup` resolves authors and reply-quote authors to roster display names or `chatShortIdentity`, keeps `partiallyAccepted` as sending per [ADR-075](075-pairwise-groups.md) / [ADR-088](088-group-composer.md) and `permanentlyFailed` as failed with Retry, and memoizes resolved names per message so a member rename re-derives only that member's messages and replies quoting them.
   - Injected test mode takes `ConversationMessage` rows and maps them through the same `ChatMessageProjection` used in production.
   - **Deleted:** `GroupMessage`, `GroupMessageDelivery`, `GroupRepositoryPort.watchMessages`, `DriftGroupRepository.watchMessages`, `groupMessagesProvider`, and page-local delivery/retry stubs (retaining `watchFanoutProgress` and `GroupFanoutProgress` per [ADR-088](088-group-composer.md)).
2. **D2 — Replies:** `SendGroupMessage`, `RetryGroupMessage`, and `GroupMessageSenderPort` carry `replyToMessageId` and `quoteFallback`, preserving reply references and quoting the replied member's display name or short identity.
3. **D3 — Reactions:** Any active member holding `GroupPermission.sendMessages` may react (`SetGroupReaction` in [group_use_cases.dart](../../../lib/features/groups/application/group_use_cases.dart) → `ConversationGroupMessageSender` in [group_pairwise_adapters.dart](../../../lib/features/groups/infrastructure/group_pairwise_adapters.dart) → `SendConversationEvents.setReaction`), permitted in `_sendMutation` ([conversation_use_cases.dart](../../../lib/features/messaging/application/conversation_use_cases.dart)).
4. **D4 — Moderator/author mutations kept off at ADR-090 (partially superseded by ADR-096):**
   - Added `ChatMessageViewModel.canPin` (defaulting true for direct chats) and set `canPin`, `canEdit`, and `canDeleteForEveryone` to false in groups so the action sheet hides Pin, Edit, and Delete for everyone; `_authorizedGroupModerator` in [drift_application_event_projector.dart](../../../lib/features/messaging/infrastructure/drift_application_event_projector.dart) stayed intentionally false until signed-roster role enforcement was wired (later enabled for Pin and Delete for everyone in ADR-096; Edit remains off).
5. **D5 — Local actions and cross-chat forwarding ([chat_forward.dart](../../../lib/features/messaging/presentation/chat_forward.dart)):**
   - Copy (`Clipboard.setData`), Star, Delete for me, and drafts (`ManageLocalConversationState`, `conversationDraftProvider`) work in groups. `_GroupChatSession` holds a `ProviderSubscription` created in `initState` so draft persistence works when the composer disposes after deactivation (direct chat's `ref.read` draft bug noted separately and left for its own fix).
   - Extracted shared forward picker and loop into `chat_forward.dart`: forwarding works from groups and into groups (via `SendGroupMessage`), blocks attachment messages from forwarding into groups ([ADR-089](089-direct-attachments.md) D1), and sends to every selected target before reporting failures once rather than aborting on the first refusal (fixed in both direct and group chats).
6. **D6 — Local read marking without read receipts:**
   - Routed group page wraps the timeline in `VisibleConversationScope` and drives `VisibleConversationReadMarker` ([visible_conversation.dart](../../../lib/features/messaging/presentation/visible_conversation.dart)) on the same triggers as direct chats with `allowReadReceipts: false`, clearing local unread counts and suppressing notifications while on screen (group read receipts deferred to and designed in [ADR-091](091-group-receipts.md)).

## Rationale

- Field testing on 2026-10-09 showed group replies dropping references, reactions doing nothing, and message-sheet actions failing because `GroupChatView` rendered `ChatMessageBuilder` over `GroupMessage`, a stripped model lacking replies, reactions, receipts, pins, stars, and edits, while `_handleIntent` silently dropped unhandled intents.
- Groups already share the `conversations` and `messages` tables by `groupId`; extending `GroupMessage` would maintain a drifting duplicate projection that would have to be rebuilt again for group read receipts ([ADR-091](091-group-receipts.md)).
- Kept `GroupChatPage`'s own header, lifecycle notices, inline error bar, and wide side panel rather than reusing `ChatConversationView` (whose contact link, pinned banner, and attachment pickers are direct-chat-specific).

## Constraints and Open Gates

- **Scope:** Changed group chat screen, `ChatMessageViewModel` / `ChatMessageProjection`, `chat_forward.dart`, group/conversation use cases, and group repository ports; changed no database schema/table, wire format, protocol, dependency, cryptographic construction, or `backend/` file. Also updated [ui-specification.md §9](../../ui-specification.md) to note that membership system lines (`"X was added"`) are not built.
- **Verification:** Covered by [chat_view_model_mapper_test.dart](../../../test/features/messaging/chat_view_model_mapper_test.dart), [group_use_cases_test.dart](../../../test/features/groups/application/group_use_cases_test.dart), [conversation_use_cases_test.dart](../../../test/features/messaging/conversation_use_cases_test.dart), [group_fanout_delivery_test.dart](../../../test/features/groups/application/group_fanout_delivery_test.dart), [group_pages_test.dart](../../../test/widget/group_pages_test.dart), and [group_message_actions_test.dart](../../../test/widget/group_message_actions_test.dart) (over an in-memory database).
- **Left open at ADR-090 close:** No physical-device or live-server run; Pin/Edit/Delete for everyone (Pin and Delete for everyone later added by ADR-096), group attachments ([ADR-089](089-direct-attachments.md) D1), group read receipts (completed in [ADR-091](091-group-receipts.md)), membership system lines, and the direct-chat `ref.read` draft bug.

## Costs

- In-group search covers only the loaded timeline window (matching direct chats) rather than loading the entire group history into memory.
- Messages deleted for me render the deleted placeholder in groups instead of disappearing silently.
- Pin, Edit, and Delete for everyone waited on signed-roster role support (until ADR-096 for Pin and Delete for everyone); group read receipts waited until [ADR-091](091-group-receipts.md).

## Reversal Trigger

Reopen for edits in group chats (remaining unbuilt part of D4), direct-chat draft disposal saving via subscription, or adding membership system lines.

## History, Amendments, and Supersession

- **2026-10-14 (`a8c828e7`–`d8bc6872`, PR #77 `9c60fc34`):** Proposed, implemented across three steps, and accepted ADR-090 unifying group chats onto `ChatMessageProjection` and `conversationMessagesProvider`.
- **2026-10-19 (ADR-096):** Superseded D4 in part by enabling Pin and Delete for everyone in groups enforced against signed-roster roles (Edit remains disabled).
