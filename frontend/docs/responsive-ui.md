# Responsive UI specification

This document is the implementation companion to the complete
[page-by-page UI specification](ui-specification.md). The page-by-page specification owns
screen content, actions, states, and navigation; this document owns responsive behavior,
design-system boundaries, accessibility, and timeline implementation. Concrete visual
tokens and component grammar live in [Visual design system](visual-design-system.md).

## Design direction

The visual language is minimal and product-specific, with Telegram as an interaction
reference rather than a visual clone. Forui provides primitives/tokens behind app-owned
components. App-owned builders render the timeline behind the timeline adapter. No
package-default screen is accepted as the final product design.

## Adaptive shell

Use measured content constraints rather than device names. Initial breakpoints are tuned
with golden tests and may move without changing navigation semantics.

| Width class | Structure |
|---|---|
| Narrow | Bottom tabs: Chats, Voice Rooms, Settings; list item pushes full-screen detail |
| Medium | Two panes when content remains usable; otherwise narrow navigation |
| Wide | Destination rail/list at left and active detail at right; optional details panel |

Wide chat layout targets a 300–340 px conversation list and optional 340–400 px
details/thread panel. The message column has a readable maximum width rather than
stretching bubbles across the viewport.

The navigation destination set and route identity do not change between widths. Resizing
preserves the selected conversation, scroll anchor, draft, and active modal intent.

## Persistent global surfaces

- Connection strip: connecting/offline state; not dismissible while false.
- Active voice banner: visible across destinations until leave; returns to the room.
- Context-aware compose: New from Chats, Create Voice Room from Voice Rooms.
- Global error/toast host with accessible announcements and no sensitive detail.
- Modal routing that becomes a sheet on narrow layouts and dialog/panel on wide layouts.

## Design system

- Tokens cover semantic color, typography, spacing, radius, elevation, motion, focus,
  breakpoints, and content widths.
- English and Persian typography is bundled locally and tested for equivalent hierarchy.
- UI icons use Forui's bundled `FLucideIcons` through the app-owned semantic `AppIcons`
  mapping; feature screens do not select package icons or alternate icon families.
- Directionality follows locale for chrome and Unicode bidi behavior for message content.
- Touch targets are at least platform accessibility guidance; pointer targets have hover,
  focus, and right-click behavior.
- Motion respects reduced-motion settings.
- Sensitive images/text never appear in blurred app-switcher/notification previews when
  privacy mode is enabled.

## Timeline customization and Flyer boundary

Use `ChatTheme` for shared baseline tokens, default-widget parameters for small changes,
and builders for:

- outgoing/incoming/group message containers;
- author/grouping/date separators;
- reply quotes, reactions, pins, edited/deleted states;
- queued/sending/sent/delivered/read/failed indicators;
- text, image, file, unsupported, and system events;
- composer, reply/edit strip, attachment affordance, and scroll-to-bottom control;
- loading, pagination, unread divider, and empty states.

Builders are pure presentation. They receive mapped immutable view models and dispatch
typed intents. They do not decrypt, call APIs, write Drift, or contain synchronization
logic.

Piece 15 tested the pinned `flutter_chat_ui` 2.11.1 surface on 2026-07-30. Its
`Chat`/`ChatAnimatedList` update path requires a mutable `ChatController`, which would
duplicate application state, and did not provide an app-owned proof for anchor
restoration after arbitrary row-size and accessibility changes. Under the documented
replacement rule, only `ChatTimelineAdapter` uses the custom reversed sliver
implementation. ADR-054 then removed both Flyer packages from `pubspec.yaml`, where
they were still declared and imported by nothing; what remains is the replaceable
boundary, and no package model or controller owns domain state. App builders consume
immutable
`ChatTimelineViewModel`/`ChatMessageViewModel` values and dispatch typed `ChatIntent`
values.

The replacement adapter is verified for upward pagination, jump-to-message, dynamic
edit/reaction/viewport sizing, mixed directionality, keyboard and screen-reader
semantics, reduced motion, and a 50,000-message fixture with a bounded mounted-widget
count. Attachment/media builders may be added in piece 16 without changing this
boundary; the size-notification anchor path is shared by every row builder.

## Screen checklist

### Bootstrap and account

- **Splash/Connection:** logo, boot status, trust/load/reachability routing, blocking
  not-provisioned state, Retry without foreign connectivity probes.
- **Login:** username/password, generic invalid-credential error, inactive account state,
  Register and Security Notice links.
- **Register:** username/password confirmation, server-authoritative errors, transition to
  Pending Activation.
- **Pending Activation:** Check Again and Back to Login; no fake activation polling.
- **Encryption Setup:** account cross-signing plus X25519/ML-KEM device generation (no
  group material exists to generate); new-account recovery-secret
  display or existing-account identity restore; explicit resumable two-phase
  enrollment/finishing-secure-setup state; mandatory Security Notice.
- **Security Notice:** exact protected/unprotected boundaries and mandatory acknowledgement
  during onboarding, plus the deployment disclosure in a build that is distributed to
  someone. One screen serves all three entry points - onboarding, Settings, and the
  pre-login links - and is never re-shown on a schedule ([ADR-045](decisions.md)).

### Discovery and chat

- **Chats List:** pinned/active rooms, conversations ordered by local activity, unread,
  mute/pin/status, offline cached state, context menu.
- **Search:** three in-place surfaces, never a merged results screen — the chat-list
  filter, the shared in-conversation sheet (direct, saved and group), and the contact
  filter. Jump to message, per-surface scope notice, and a stated result cap.
- **Contacts/New:** New Group, New Voice Room, verified indicator, cached offline state.
- **Profile bootstrap:** use backend username and deterministic local avatar until an
  authenticated profile key/payload arrives; never render unverified cached identity.
- **DM Chat:** profile header, local/volatile presence, paged timeline, pinned banner,
  verification-withheld composer, PQ-key-unavailable state, all message actions, and
  honest deletion dialog.
- **Attachment Sheet/Preview:** photo, file, mobile camera, caption, encrypt/upload states.
- **Pinned Messages:** list, jump, authorized unpin.
- **Forward Picker:** multi-select DMs/groups/Saved Messages; forwarding creates new
  encrypted sends.
- **Group Chat:** DM skeleton plus author identity, membership system events, role-aware
  actions, removed/read-only state.

### Profiles and groups

- **Contact Profile:** message, mute, safety verification, shared media, clear, and honest
  client-side Block/Unblock.
- **Safety Number:** master-key SAS and QR, cross-sign confirmation, messaging-withheld
  unverified state, master-key change, invalid device, and device-log-fork blocking states.
- **Shared Media:** local decrypted index, open and jump, safe file handling.
- **Create Group:** pick members, encrypted details, owner creation, progress/failure.
- **Group Info:** encrypted header, policy/role/member list, add/remove/leave actions.
- **Edit Group:** encrypted identity, invite policy, history-sharing policy with honest
  re-share explanation, permission-change handling.

### Voice

- **Voice Rooms List:** encrypted room name, live/empty state, active banner integration.
- **Create Voice Room:** details, invite peers, create client membership and capability.
- **Voice Room Info:** join/rejoin, live count, invited peers, rename/invite/leave.
- **Invite Picker:** searchable multi-select and encrypted invite status.
- **Live Voice Room:** participant tiles, speaking/mute state, ephemeral text panel,
  minimize, output, invite, leave, connecting/reconnecting/alone/error states.

### Personal and settings

- **Saved Messages:** self-conversation without peer presence/receipts.
- **Settings:** profile, Saved Messages, devices, security/recovery, notifications,
  receiving while closed, appearance, notice, About, logout.
- **Appearance:** theme and language, both client-only; high contrast follows the
  operating system and has no control here.
- **About/Diagnostics:** local build facts, and a redacted report the user copies. What
  the screen shows is what the clipboard receives.
- **Edit Profile:** encrypted display name/avatar and visibility wording.
- **Security Settings:** identity-recovery guidance and replacement, verified-contact
  review, notice. The replacement screen blocks screen capture and copies through the
  expiring clipboard path.
- **Linked Devices:** this/other devices, last-active coarseness, relabel/revoke.
- **Add Device/Restore:** two-phase registration, recovery-secret identity restore,
  wrong secret, finishing secure setup, waiting for an existing online history source,
  partial transfer, queue-gap recovery, groups arriving from their members, done, and
  unrecoverable wording.

### Shared modal surfaces

- Delete message, leave group, remove member/device, clear history, logout.
- Mute duration, emoji reaction, attachment, message/conversation context menu.
- Forward target, group member, voice participant sheets.
- Every destructive or best-effort action describes the actual consequence.

## Message-state presentation

The UI distinguishes local draft, queued offline, encrypting, sending, server accepted,
delivered, read, failed/retry, blocked by security change, deleted locally, remote-delete
requested, and unsupported protocol. A single generic checkmark must not collapse states
that have different guarantees.

## Accessibility and internationalization gates

- Screen-reader traversal, labels, live regions, and focus restoration pass on all core
  flows.
- Keyboard-only navigation works on web, including context menus and dialogs.
- Text at maximum supported scale does not hide primary/destructive actions.
- Persian RTL and English LTR goldens cover every shell and message direction mixture.
- Timestamps/numbers use localized presentation while protocol values remain locale-free.
- Color is never the only carrier of verification, failure, mute, speaking, or receipt
  state.

## UI validation spike

Before building every timeline screen, prove with production-like fixtures:

- stable upward pagination and jump-to-message;
- no scroll jump when images resolve or reactions/edit state changes;
- 50,000-message local history with bounded visible widgets;
- mixed RTL/LTR, large text, screen reader, keyboard, and high contrast;
- Forui token integration through builders;
- attachment/reply/reaction/failed-send layouts;
- replaceability with a custom sliver timeline if any release criterion fails.
