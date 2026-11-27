# ADR-086: Root-navigator full-screen pages, insets, call banner, and shell semantics

- **Status:** Accepted (2026-10-08); the connection strip named in its costs was deleted by [ADR-087](087-chat-status.md) (2026-10-09); accessibility follow-ups completed 2026-10-09
- **Date:** 2026-10-08 (explicitly recorded in register and full section; implemented in `edf45dda`–`faec82bb`, PR #66 `81af2e35`; accessibility follow-ups on 2026-10-09 in `6e4c1423` / `8144fad4` PR #67, `70c3615b` / `5f77385c` / `bf82fe1d` / `d7c91e13` PR #68, and `faaa1ff0` / `8af144fd` / `74f1f4fe` / `3af492d1` PR #69)
- **Amended by:** [ADR-087](087-chat-status.md) (2026-10-09, removes the shell connection strip named in ADR-086's costs)
- **Related:** [ADR-005](005-guarded-routing.md), [ADR-077](077-voice-mesh.md), [ADR-087](087-chat-status.md), [SCREENS.md](../../ui/SCREENS.md), [ADAPTIVE-LAYOUT.md](../../ui/ADAPTIVE-LAYOUT.md)

## Decision (Position)

Separated tab-root shell chrome from full-screen detail routes and aligned edge-to-edge insets, call-banner placement, and accessibility semantics across the shell and root-navigator pages:

1. **D1 — The navigation bar and rail belong to the tab roots:**
   - The bottom navigation bar (narrow) and navigation rail (medium/wide) render only on the three tab roots (`/chats`, `/voice-rooms`, `/settings`).
   - Every screen opened above a tab root — conversations, Saved Messages, contacts, voice rooms and calls, Settings screens, and sub-screens — is a full-screen page at every width, and back navigation returns to the previous screen or tab root with list state intact.
2. **D2 — Pages open on the root navigator rather than under a hidden bar ([app_router.dart](../../../lib/app/routing/app_router.dart)):**
   - All 16 routes below the three shell branches specify `parentNavigatorKey` pointing to the root navigator (including nested sub-routes, because `go_router` 17.3.0 `_matchByNavigatorKeyForGoRoute` otherwise matches unkeyed child routes inside the branch navigator).
   - `createAppRouter` allocates the root navigator key per router instance (because a `GlobalKey` marks one navigator at a time and tests build multiple routers). Routes outside the branches were already on the root navigator.
   - Rejected hiding the bar while keeping detail pages inside branch navigators (out-of-sync transitions and resizing/re-laying-out the tab root underneath on open/close).
3. **D3 — Back navigation from group chats and Saved Messages returns to Chats:**
   - The Chats list opens group chats and Saved Messages with `push` rather than `go` so the list stays beneath them at its scroll offset.
   - Group creation navigates (`go`) to `/chats` and pushes the new group chat (relying on the router's synchronous redirect), omitting intermediate creation routes from the back stack.
   - Group Info's Search pops back to the conversation beneath it, falling back to `go` only when nothing is beneath it.
4. **D4 — Edge-to-edge system insets on full-screen pages (`targetSdk` 36):**
   - App bars and page-owned bars (such as the voice call page's top and control bars) consume the inset on their edge while extending background color edge to edge.
   - Scrolling bodies add bottom and horizontal insets via `AppInsets.belowAppBar(context, spacing)` ([app_tokens.dart](../../../lib/app/design_system/app_tokens.dart)) across 13 lists while continuing to scroll behind the gesture bar; the chat composer already pads itself. During a call, the call banner consumes the top inset instead of the app bar (D5).
5. **D5 — Active call banner on full-screen pages ([voice_room_banner.dart](../../../lib/features/app_shell/presentation/voice_room_banner.dart), [voice_room_banner_frame.dart](../../../lib/features/app_shell/presentation/voice_room_banner_frame.dart)):**
   - Per [Persistent elements](../../ui/SCREENS.md#persistent-elements) and [Live Voice Room Screen](../../ui/SCREENS.md#live-voice-room-screen), `createAppRouter` wraps every non-tab-root page on the root navigator in `VoiceRoomBannerFrame`, except `/voice-rooms/<roomId>/call` for the active call's own room (a call page for another room shows it) and the six bootstrap/sign-in routes (`/connection`, `/login`, `/session-restoring`, `/register`, `/pending-activation`, `/encryption-setup`).
   - Extracted `_VoiceRoomBanner` from [app_shell.dart](../../../lib/features/app_shell/presentation/app_shell.dart) into `VoiceRoomBanner` (`active-voice-banner`, targeting `go('/voice-rooms/<roomId>/call')`), governed on both the shell and pages by `AppShellStatus.voiceRoomBannerAt(location)` and fed through `LiveShellStatus` (or base status when no `ProviderScope` exists).
   - `VoiceRoomBannerFrame` places the banner above the page's app bar, consumes the top status-bar inset on the banner when active, preserves widget identity (`Column` + `MediaQuery` around the page) so composer drafts and focus survive call start/end, reads `GoRouterState.matchedLocation` instead of `uri` (`RouteMatch.buildState` puts top-of-stack location in `uri`), and keeps `AppFocus.minimumTarget` height with 2-line label wrapping.
   - Rejected placing one banner above `MaterialApp.router` (would sit above dialogs/sheets, need route tracking, and miss page transitions).
   - Note: `flutter_riverpod` 3.3.2 `Consumer` pauses offstage subscriptions via `TickerMode`, so a covered page reflects call start/end on the first frame its cover begins leaving.
6. **Follow-up accessibility fixes (2026-10-09):**
   - **Banner tap action (`6e4c1423` / `8144fad4`):** Added `onTap` (`go('/voice-rooms/<roomId>/call')`) to `VoiceRoomBanner`'s `Semantics` while retaining `excludeSemantics: true` so Switch Access and similar services can activate the single button node.
   - **Shell navigator semantics container and single labels (`70c3615b`, `5f77385c` / `bf82fe1d`, `d7c91e13`):** Wrapped `StatefulNavigationShell` and its focus scope in `Semantics(container: true)` in `_AppShellState.build` so the tab navigator's `ModalBarrier` (`BlockSemantics` / `_RenderObjectSemantics._getNonBlockedChildren`) no longer drops semantics nodes painted before it (the rail, its banner, the environment banner, and the connection strip — later removed by [ADR-087](087-chat-status.md)). Wrapped duplicated `Text` widgets inside `ExcludeSemantics`, removed the wide rail compose button's `Tooltip` (which `AccessibilityBridge` appended below Android 9), and excluded the decorative `"Communication Platform"` brand text from semantics. Rejected wrapping only `_TwoPaneShell`, wrapping only the rail, reordering paint order, or disabling route barriers.
   - **Seven `excludeSemantics: true` tap actions (`faaa1ff0`, `8af144fd`, `74f1f4fe` / `3af492d1`):** Forwarded the underlying control's `onTap`/`onPressed` (`null` when disabled, e.g., own member row or Mute while connecting) onto `Semantics(button: true, excludeSemantics: true)` across [voice_rooms_page.dart](../../../lib/features/voice/presentation/voice_rooms_page.dart), [voice_room_info_page.dart](../../../lib/features/voice/presentation/voice_room_info_page.dart), [voice_call_page.dart](../../../lib/features/voice/presentation/voice_call_page.dart), [attachment_sheet.dart](../../../lib/features/attachments/presentation/attachment_sheet.dart), and [chat_message_builder.dart](../../../lib/features/messaging/presentation/chat_message_builder.dart).

## Rationale

- Branch-scoped detail routes violated [Adaptive shell](../../ui/SCREENS.md#adaptive-shell) and [ADAPTIVE-LAYOUT.md](../../ui/ADAPTIVE-LAYOUT.md#adaptive-shell) by leaving navigation bars visible on detail pages and causing `go` calls to group chats/Saved Messages to exit the app on back.
- Placing routes on the root navigator with `VoiceRoomBannerFrame` preserves tab-root state, ensures synchronized transitions, and keeps the active call banner accessible everywhere required without duplicating route state above the router.

## Constraints and Open Gates

- **Scope:** Changed navigator keys, four navigation calls, full-screen page insets, call banner placement, and semantics containers/labels/actions; changed no local table, wire format, protocol, dependency, cryptographic construction, or `backend/` file.
- **Verification:** Covered by [full_screen_pages_test.dart](../../../test/widget/full_screen_pages_test.dart), [group_pages_test.dart](../../../test/widget/group_pages_test.dart), [app_shell_test.dart](../../../test/widget/app_shell_test.dart), [voice_call_page_test.dart](../../../test/widget/voice_call_page_test.dart), [voice_room_pages_test.dart](../../../test/widget/voice_room_pages_test.dart), [attachment_sheet_test.dart](../../../test/widget/attachment_sheet_test.dart), and [chat_interface_test.dart](../../../test/widget/chat_interface_test.dart), plus mutation tests verifying `MediaQuery` tree stability, top inset removal, `matchedLocation` framing, semantics `onTap` / `excludeSemantics`, and shell `Semantics(container: true)` boundaries. Shell goldens unchanged.
- **Left open / found in passing:**
  - **No device run:** All checks were widget tests; nothing was installed on hardware.
  - **Missing insets elsewhere:** Centered `AppStatePanel` bodies, landscape chat-timeline horizontal insets, and pre-existing root-navigator pages (contact, safety number, create group, group screens — later partially addressed for group pages in `b21e3076`) lacked system-inset padding at ADR-086 close.
  - **Reaction chip doubled label:** Noted in [chat_message_builder.dart](../../../lib/features/messaging/presentation/chat_message_builder.dart) without `excludeSemantics` (`"👍 reaction, 2 people"` + `"👍 2"`), left unchanged.

## Costs

- Full-screen pages cover the navigation rail at medium and wide widths (post-v1 two-pane master-detail of [Adaptive shell](../../ui/SCREENS.md#adaptive-shell) remains unbuilt).
- Shell overlays — the development `"Development configuration"` environment banner, the connection strip (subsequently deleted by [ADR-087](087-chat-status.md)), and `Alt+1`/`Alt+2`/`Alt+3` keyboard shortcuts — stay on tab roots only and do not appear or fire on full-screen pages.
- During an active call, `VoiceRoomBanner` consumes ≥ 48 px (more at scaled text) from the top of full-screen pages, both shell and page banners draw briefly during open/close transitions, and the status bar keeps the overlay style of the underlying app bar.
- Whatever the shell paints beside or above a navigator must sit outside the navigator's `Semantics(container: true)` barrier (including any future second pane).

## Reversal Trigger

Reopen when implementing the post-v1 two-pane medium/wide master-detail layout of [Adaptive shell](../../ui/SCREENS.md#adaptive-shell), moving shell overlays (such as the development banner or keyboard shortcuts) onto full-screen pages, or adding system insets to the remaining root-navigator pages.

## History, Amendments, and Supersession

- **2026-10-08 (`edf45dda`–`faec82bb`, PR #66 `81af2e35`):** Implemented and accepted ADR-086 moving branch sub-routes onto the root navigator, restoring back navigation, adding edge-to-edge insets, and adding `VoiceRoomBannerFrame`.
- **2026-10-09 (`6e4c1423` / `8144fad4` PR #67; `70c3615b`, `5f77385c` / `bf82fe1d`, `d7c91e13` PR #68; `faaa1ff0`, `8af144fd`, `74f1f4fe` / `3af492d1` PR #69):** Added banner semantics tap action, `Semantics(container: true)` around tab-root navigators, single shell labels, and tap actions across seven `excludeSemantics: true` controls.
- **2026-10-09 ([ADR-087](087-chat-status.md)):** Deleted the shell connection strip referenced in ADR-086's costs and semantics notes.
