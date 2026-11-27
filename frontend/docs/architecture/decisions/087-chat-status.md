# ADR-087: Chats search page, Chats title sync status, and connection strip removal

- **Status:** Accepted (2026-10-09)
- **Date:** 2026-10-09 (explicitly recorded in register and full section; phase 10 prompts 1–2 in `9eb335a8`–`e0bdcf83`, PR #71 `02c37bbc`)
- **Amends:** [ADR-060](060-delivery-latency.md) D11 (moves delivery indicator from a list-top line to the Chats app-bar title with a 1-second delay) and [ADR-086](086-root-navigation.md) (deletes the shell connection strip named in [ADR-086](086-root-navigation.md)'s costs)
- **Related:** [ADR-052](052-accurate-capability-claims.md), [ADR-057](057-measured-settings.md), [ADR-060](060-delivery-latency.md), [ADR-086](086-root-navigation.md), [SCREENS.md](../../ui/SCREENS.md), [ADAPTIVE-LAYOUT.md](../../ui/ADAPTIVE-LAYOUT.md)

## Decision (Position)

Replaced the inline search field and static/shifting status notices on the Chats list and shell with a dedicated search page, a live title status indicator, and removal of the shell connection strip:

1. **D1 — Search is a full-screen page at `/chats/search` ([chats_search_page.dart](../../../lib/features/messaging/presentation/chats_search_page.dart)):**
   - Adopted Owner Option 2: deleted the inline search field above the Chats list and wired the Chats top-bar search icon to open `/chats/search` as a full-screen root-navigator page ([ADR-086](086-root-navigation.md), [Chats List](../../ui/SCREENS.md#chats-list-home--chats-tab)). Rejected Option 1 (keeping only the inline field).
   - Searches case-insensitively across chat names, each chat's latest message summary, and verified contact display names plus usernames via `contactMatchesSearch` ([contacts_new_page.dart](../../../lib/features/contacts/presentation/contacts_new_page.dart) / shared helper).
   - Displays **Chats** and **Contacts** sections, hides empty sections, and omits contacts already matched via a direct chat. Performs no network call or directory refresh, persists no query, and requests no keyboard learning; hint and scope copy are pinned in English and Persian by the [ADR-052](052-accurate-capability-claims.md) disclosure/claims tests.
   - **No all-message history section:** Chat summaries hold only the latest message; searching all `messages.projection_ciphertext` rows across conversations requires its own storage query, cap, and scope copy (older messages inside a chat remain searchable via in-conversation search).
2. **D2 — Chats app-bar title carries the live delivery engine status ([chats_list_page.dart](../../../lib/features/messaging/presentation/chats_list_page.dart)):**
   - Moved [ADR-060](060-delivery-latency.md) D11's content-free indicator into the Chats title slot, preserving D11's four states and nine-phase `_deliveryIndicator` mapping: settled (`online` or `null` projection) shows `"Chats"`; `connecting` shows `chatsDeliveryConnectingNotice` (*Connecting…*); `draining` shows `chatsDeliverySyncingNotice` (*Syncing…*); and `stopped`, `offline`, `reconnectWaiting`, `revoked`, `protocolCircuitOpen`, and `originRejected` show `chatsDeliveryWaitingNotice` (*Waiting to reconnect…*).
   - Reads only live `syncProjectionProvider`'s `connectionPhase` via `listenManual` (so the timer keeps running when a detail route covers `/chats`), never `AuthenticationRouteAccess.offlineFullScope`.
   - Applies a **1-second continuous unsettlement delay** before leaving `"Chats"` (so brief wake/sync cycles do not flicker); transitions between unsettled states do not reset the timer and appear immediately once the title has left `"Chats"`, any settled moment resets the timer, and settling restores `"Chats"` on the same frame.
   - Displays a small spinner before *Connecting…* and *Syncing…* (swapped for static `AppIcons.connecting` when `MediaQuery.disableAnimationsOf` is true) and no spinner before *Waiting to reconnect…*. Single-line ellipsis up to 2× text size, header semantics preserved, single semantics node, `liveRegion` enabled only while a status shows.
   - Deleted the above-list status line (`_InlineNotice`), `chatsOfflineCachedNotice` (en/fa), and `ChatListViewModel.offline` / `delivery`; Chats page watches only the phase in the title (conversation composers keep their offline queue notice). Rejected merely delaying the above-list line (still shifts the list vertically).
3. **D3 — Shell connection strip and `?offline=true` deleted ([app_shell.dart](../../../lib/features/app_shell/presentation/app_shell.dart), [app_router.dart](../../../lib/app/routing/app_router.dart)):**
   - Deleted `_ConnectionStrip`, `AppConnectionState`, `AppShellStatus.connection` (and `copyWith`), the strip copy in `LiveShellStatus`, `?offline=true` query handling, and `connectingStatus` / `offlineStatus` strings (en/fa). `/connection` now routes directly to `/chats` after every start; `BootstrapModel` keeps its offline flag.

## Rationale

- Having both a search icon that focused a permanent field and the field itself duplicated one control while permanently stealing vertical space; moving to `/chats/search` restores list height and accommodates two result sections and a scope notice.
- The above-list sync line vertically shifted the conversation list on every cycle, while both the long offline notice and the shell connection strip read session-open `offlineFullScope` / `?offline=true` and therefore remained stuck on screen after connectivity returned.
- Reading live `connectionPhase` in the Chats title after a 1-second delay avoids flicker during healthy syncs while still surfacing a stalled delivery engine without pushing list content.

## Constraints and Open Gates

- **Scope:** Changed Chats top bar and body, `/chats/search` route, shell widget and status model, and localized strings; changed no local table, wire format, protocol, dependency, cryptographic construction, or `backend/` file.
- **Verification:** Covered by 26 tests in [chats_title_status_test.dart](../../../test/widget/chats_title_status_test.dart) (plus 9 mutation checks guarding the delay, timer continuity, immediate settle restore, covered-page `listenManual`, live-region scope, ellipsis, reduced motion, `draining` mapping, and no spinner on Waiting), [bootstrap_connection_test.dart](../../../test/widget/bootstrap_connection_test.dart), [app_shell_test.dart](../../../test/widget/app_shell_test.dart), [chat_interface_test.dart](../../../test/widget/chat_interface_test.dart), and unchanged [app_shell_golden_test.dart](../../../test/golden/app_shell_golden_test.dart).
- **Left open / found in passing:**
  - **No device run:** Verified only through host widget tests; nothing installed on hardware.
  - **No cross-chat message-body search section:** Deferred pending its own query, cap, and scope design.
  - **Other sticky session-start notices left unchanged:** Direct-chat composer's offline notice and `voiceOfflineProvider` (Voice Rooms list, room info, and call screens) still read `AuthenticationRouteAccess.offlineFullScope` set at sign-in/restore and do not clear if connectivity returns mid-session (Contacts notice already follows live refresh results).
  - **`ChatsListPage.compact`:** Returns the bare list without an app bar/title and therefore renders no engine status.

## Costs

- During the first second of an offline start, the Chats title reads `"Chats"` like any other start instead of showing an immediate banner.
- Voice Rooms and Settings tab roots and full-screen pages carry no engine status indicator (matching the removed strip's `/chats`-only scope, while Voice Rooms and conversation composers keep their own offline notices).
- Because Android `AppBar` title semantics carry `namesRoute`, a screen reader returning to `/chats` while a status is displayed announces the route by that status.
- A freshly mounted `ChatsListPage` (such as right after sign-in) begins its 1-second timer from its first frame rather than when the engine first left `online`.

## Reversal Trigger

Reopen to design global cross-conversation message-body search, replace `offlineFullScope` in direct-chat composers and `voiceOfflineProvider` with live connectivity/phase state, or surface delivery status on non-Chats tabs.

## History, Amendments, and Supersession

- **2026-10-09 (`9eb335a8`–`e0bdcf83`, PR #71 `02c37bbc`):** Implemented and accepted ADR-087 (`chats/search` page, Chats title delivery status with 1-second delay, and deletion of `_ConnectionStrip` and `?offline=true`).
