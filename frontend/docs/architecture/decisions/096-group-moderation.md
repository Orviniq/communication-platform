# ADR-096: Group departure deletes local history and signed roster roles govern moderation

- **Status:** Accepted (2026-10-19); proposed 2026-10-19
- **Date:** 2026-10-19 (explicitly recorded in register and full section; proposed in `8da64235`, built on `frontend-group-membership-moderation` in `67e17df6`–`2945e90d`, PR #88 `0398a460`)
- **Supersedes in part:** [ADR-090](090-group-timeline.md) D4 (enables Pin and Delete for everyone in group chats under signed-roster roles; Edit stays off)
- **Related:** [ADR-075](075-pairwise-groups.md), [ADR-089](089-direct-attachments.md), [ADR-090](090-group-timeline.md), [ui-specification.md](../../ui-specification.md), [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) (cited historically as `backend/CLIENT_CONTRACT.md` before [server ADR-0030](../../../../docs/architecture/decisions/0030-the-security-model-and-the-client-contract-move-under-docs.md))

## Decision (Position)

Removed left/removed groups from the device upon departure while retaining replay-safe signed state, and enabled author and moderator message deletion plus pinning governed by the current signed group roster:

1. **D1–D2 — Departure removes local group history while retiring facts ([drift_group_repository.dart](../../../lib/features/groups/infrastructure/drift_group_repository.dart), [drift_application_event_projector.dart](../../../lib/features/messaging/infrastructure/drift_application_event_projector.dart)):**
   - Whenever `commitTransitionInsideTransaction` leaves the local user's lifecycle `left` or `removed` (whether from a local Leave or a received removal), `_removeConversation` runs atomically in the same transaction: `tombstoneConversationInsideTransaction` ([conversation_tombstone.dart](../../../lib/features/messaging/infrastructure/conversation_tombstone.dart), shared with `deleteConversationForMe`) tombstones the `conversations` row and clears draft, unread count, and attachment rows, and `retireConversationHistoryInsideTransaction` deletes `messages`, reactions, receipts, attachment rows, and owed delivered receipts while moving candidate `application_events` (`apply_state = 0`) to state `4` (`retired`, already permitted by the existing `0..5` CHECK constraint).
   - Retired facts are never folded again by rebuilds or late reactions/receipts, yet remain in `application_events` to reject replays and sender-counter collisions.
   - `group_states` and the signed control transcript remain so later non-member events are rejected and a re-add applies cleanly; when a transition moves the local user from `left` or `removed` back to `active`, `_writeConversation` clears the tombstone (a group rename leaves a user-initiated tombstone intact).
2. **D3 — Post-leave UI and cache sweep ([group_components.dart](../../../lib/features/groups/presentation/group_components.dart), [group_use_cases.dart](../../../lib/features/groups/application/group_use_cases.dart)):**
   - Leave confirmation (`groupConfirmLeaveBody`, en/fa) states that leaving deletes the group and its history from this phone while other members keep their copies.
   - Leaving navigates back to Chats (`onLeft`), and an open group chat or Group Info page observing `left`/`removed` (`groupGoneFromThisPhone` / `groupGonePage`) navigates back to Chats.
   - `MutateGroup` invokes `GroupRemovalSweepPort` after a local Leave commits; a remotely received removal relies on the startup attachment cache sweep (groups hold no attachment rows per [ADR-089](089-direct-attachments.md) D1).
3. **D4 — Author delete for everyone:**
   - `DeleteGroupMessageForEveryone` ([group_use_cases.dart](../../../lib/features/groups/application/group_use_cases.dart)) requires `GroupPermission.sendMessages` and routes via `GroupMessageSenderPort.deleteForEveryone` (`ConversationGroupMessageSender` in [group_pairwise_adapters.dart](../../../lib/features/groups/infrastructure/group_pairwise_adapters.dart)) to `SendConversationEvents.deleteForEveryone` ([conversation_use_cases.dart](../../../lib/features/messaging/application/conversation_use_cases.dart)), which still requires the original sender.
   - `ChatMessageProjection.mapGroup` ([chat_view_model_mapper.dart](../../../lib/features/messaging/presentation/chat_view_model_mapper.dart)) exposes `canDeleteForEveryone` on non-deleted own group messages.
4. **D5–D7 — Moderator delete, pinning, and signed-roster role order:**
   - **Moderator delete:** Owner may delete any member's or admin's message; an admin may delete a `member`'s message only (not another admin's or the owner's), matching `GroupAuthorization.canRemove` ([group_model.dart](../../../lib/features/groups/domain/group_model.dart)) applied to the message author (`canDeleteMessageOf` and `recordedRoleMayDelete`). Author role is read regardless of current membership, so an owner may delete messages of a departed member.
   - **Pinning:** Owner and admins may pin and unpin (`GroupPermission.pinMessages`, `recordedRoleMayPin`, `SetGroupPin`, `GroupMessageModerationPort` / `GroupRosterMessageModeration`, `ChatPinnedBanner` extracted to [chat_pinned_banner.dart](../../../lib/features/messaging/presentation/chat_pinned_banner.dart)).
   - **Convergence:** `DriftApplicationEventProjector._groupRoster` decodes `group_states` (`DriftGroupRepository.decodeStoredState`) inside each fold transaction. Because candidate facts are admitted only while active (`DriftGroupConversationMembership`), an admin who leaves retains deletes/pins sent while active, whereas `commitTransitionInsideTransaction` triggers `rebuildConversationInsideTransaction` whenever a control transition alters any existing member's role or removes them — activating a stored delete/pin on promotion and undoing one on demotion.
5. **D8 — Group edits remain disabled:** Supersedes [ADR-090](090-group-timeline.md) D4 only for Pin and Delete for everyone; Edit remains off.

## Rationale

- Field testing on 2026-10-17 flagged that leaving or being removed left a read-only group with full history in Chats, members could not delete own group messages for everyone, and owners/admins could not moderate or pin messages.
- Because the backend holds no group, roster, or roles (`CLIENT_CONTRACT.md` §F), enforcement on both send and receive must derive deterministically from the signed `group_states` transcript; using the current roster rather than adding a control-revision field to application events avoids a wire format change.
- Reusing `deleteConversationForMe` as-is was rejected because it keeps message rows and draws deleted placeholders, which would reappear if the user were re-added.

## Constraints and Open Gates

- **Scope:** Changed `drift_group_repository.dart`, `conversation_tombstone.dart`, `drift_application_event_projector.dart`, `group_model.dart`, `group_use_cases.dart`, `group_pairwise_adapters.dart`, `conversation_ports.dart`, `conversation_use_cases.dart`, `chat_view_model_mapper.dart`, `chat_pinned_banner.dart`, and group UI/l10n; changed no wire format, event kind, cryptographic construction, Rust core, dependency, Android permission, server route, database schema (`apply_state = 4` fits existing `0..5` constraint), or `backend/` file.
- **Verification:** Covered by [drift_group_repository_test.dart](../../../test/features/groups/infrastructure/drift_group_repository_test.dart), [drift_application_event_projector_test.dart](../../../test/features/messaging/drift_application_event_projector_test.dart), [group_authorization_state_machine_test.dart](../../../test/features/groups/domain/group_authorization_state_machine_test.dart), [conversation_use_cases_test.dart](../../../test/features/messaging/conversation_use_cases_test.dart), [group_use_cases_test.dart](../../../test/features/groups/application/group_use_cases_test.dart), [chat_view_model_mapper_test.dart](../../../test/features/messaging/chat_view_model_mapper_test.dart), [group_leave_test.dart](../../../test/widget/group_leave_test.dart), [group_pages_test.dart](../../../test/widget/group_pages_test.dart), and [group_message_actions_test.dart](../../../test/widget/group_message_actions_test.dart), plus 8 targeted mutation checks across D1–D7. Confirmed separately by test that `deleteConversationForMe` in a direct chat leaves its tombstone intact if the peer writes again.
- **Left open / not verified:**
  - **No device or live-server run:** Multi-device own-leave propagation, re-add, and three-account moderation/promotion/demotion remain unverified on hardware.
  - **Residual strings/sweeps:** `groupRemovedState` and `groupLeftState` still describe a readable copy (reachable only in injected-mode widget tests); remote removal sweeps the attachment cache only on next process start; no system line is emitted for deletes or pins.

## Costs

- Leaving a group is irreversible locally; being re-added restores an empty timeline while other members retain their copies.
- Pending outbound copies for messages queued before leaving fail in the audience resolver and are deleted with the conversation.
- Demoting an admin (or handing over ownership) re-folds the group and restores messages that the demoted member had previously deleted or pinned.
- Each role change triggers one full conversation rebuild. Delete for everyone remains best-effort (members who already saw a message have seen it).

## Reversal Trigger

Reopen if application events ever carry a binding control revision (allowing historical role evaluation at event time), if group editing or moderation system lines are added, or if `groupLeftState` / `groupRemovedState` are retired.

## History, Amendments, and Supersession

- **2026-10-19 (`8da64235`, `67e17df6`–`2945e90d`, PR #88 `0398a460`):** Proposed ADR-096, implemented D1–D4 (local deletion on leave/removal, retired facts, own delete for everyone) and D5–D7 (moderator delete, pinning, signed-roster role re-folding), and accepted ADR-096, superseding [ADR-090](090-group-timeline.md) D4 for Pin and Delete for everyone.
