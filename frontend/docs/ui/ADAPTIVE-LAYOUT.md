# Adaptive layout specification

This document is the layout and implementation companion to
[UI screens](SCREENS.md). `SCREENS.md` owns screen inventory, content, actions, states,
and navigation flow; this document owns width rules, shell geometry, sheets,
design-system boundaries, accessibility, RTL/internationalization, and timeline
implementation. Concrete visual tokens, semantic usage, and font provenance live in
[Visual design system](DESIGN-SYSTEM.md).

## Design direction

The visual language is minimal and product-specific, with Telegram as an interaction
reference rather than a visual clone. Forui provides primitives/tokens behind app-owned
components. App-owned builders render the timeline behind the timeline adapter. No
package-default screen is accepted as the final product design.

## Adaptive shell

Android is the sole version-1 target, supporting responsive phone and tablet viewports
and measured content constraints rather than device names. Initial breakpoints
(`AppBreakpoints.medium = 600`, `AppBreakpoints.wide = 1024`;
`AppContentWidths.navigationMedium = 88`, `AppContentWidths.navigationWide = 320`,
`AppContentWidths.readable = 760`) are tuned with golden tests and may move without
changing navigation semantics.

| Width class | A tab root | Every screen above a tab root |
|---|---|---|
| Narrow (`< 600` px) | Bottom navigation bar: Chats, Voice Rooms, Settings | Full-screen page |
| Medium (`600` to `< 1024` px) | Compact rail | Full-screen page |
| Wide (`>= 1024` px) | Rail with labels | Full-screen page |

The navigation bar and the rail show on the three tab roots only: `/chats`, `/voice-rooms`
and `/settings`. Every screen above a tab root is a full-screen page at every width: it
opens on the root navigator, above the shell, and covers the navigation bar or the rail.
Back returns to the screen below it or to the tab root, which keeps its state under it,
scroll position included. A full-screen page keeps its controls clear of the system insets
— the status bar, the gesture bar and the navigation buttons — while its colour still
reaches every edge: an app bar takes the top inset, a bar of the page's own takes the inset
at its edge, and a scrolling body adds the rest to its padding (`AppInsets.belowAppBar`).
During a call the active voice banner sits at the top of the page and takes the top inset,
and the app bar under it adds none.

The post-v1 two-pane layout ([Global layout and navigation](SCREENS.md#adaptive-shell)) is
not built: a 300–340 px conversation list beside the open conversation, and an optional
340–400 px details/thread panel. The message column has a readable maximum width rather
than stretching bubbles across the viewport.

The navigation destination set and route identity do not change between widths. Resizing
preserves the selected conversation, scroll anchor, draft, and active modal intent.
For the full screen inventory and per-screen behavior, see
[Screen inventory](SCREENS.md#screen-inventory).

## Persistent global surfaces

- Connection and sync status: the Chats title carries it, after one second and from the
  engine's live phase ([Chats List](SCREENS.md#chats-list-home--chats-tab)). The shell
  draws no connection strip.
- Active voice banner: visible across destinations until leave; returns to the room. Above
  the navigation bar or atop the rail on a tab root, at the top of a full-screen page, and
  not on the call's own screen or bootstrap/sign-in routes
  ([Persistent elements](SCREENS.md#persistent-elements)).
- Context-aware compose: New from Chats, Create Voice Room from Voice Rooms.
- Global error/toast host with accessible announcements and no sensitive detail.
- Modal routing that becomes a sheet on narrow layouts and dialog/panel on wide layouts.

## Sheets

A sheet keeps each control above the bottom system inset — the gesture bar or the
navigation buttons — and above the keyboard while one is open, with the sheet's margin and
no empty gap above the keyboard. Its surface still reaches the edge of the screen: the
content is padded, not the surface, so the app never shows through under the gesture bar. A
sheet is as tall as its content, up to 9/16 of the screen below the status bar with the
strip under the gesture bar on top of that, and never taller than the keyboard leaves room
for. Content that does not fit scrolls, and its last control scrolls fully into view. A
list or grid that scrolls on its own is cut to the same room and scrolls inside it.

Only `app_modals.dart` opens a sheet: `showAppSheet`, and `showAppAnchoredSheet` for the
message actions with the reaction panel above them. The rule is written there and nowhere
else, so a caller wraps its content in no `SafeArea`; one that did would add nothing, as
the sheet takes the insets it has applied out of the `MediaQuery` it hands down.
`test/architecture/sheet_boundary_test.dart` fails on any other call to a sheet function,
and `test/widget/sheet_insets_test.dart` holds the geometry.

## Design system

- Tokens cover semantic color, typography, spacing, radius, elevation, motion, focus,
  breakpoints, and content widths ([Visual design system](DESIGN-SYSTEM.md)).
- English and Persian typography is bundled locally and tested for equivalent hierarchy.
- UI icons use Forui's bundled `FLucideIcons` through the app-owned semantic `AppIcons`
  mapping; feature screens do not select package icons or alternate icon families.
- Directionality follows locale for chrome and Unicode bidi behavior for message content.
- Touch targets are at least platform accessibility guidance; pointer targets have hover,
  focus, and right-click behavior.
- Motion respects reduced-motion settings.
- Sensitive images/text never appear in blurred app-switcher/notification previews when
  privacy mode is enabled (`FLAG_SECURE` in `MainActivity.onCreate` per
  [ADR-092](../architecture/decisions/092-screen-capture.md)).

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
immutable `ChatTimelineViewModel`/`ChatMessageViewModel` values and dispatch typed
`ChatIntent` values.

The replacement adapter is verified for upward pagination, jump-to-message, dynamic
edit/reaction/viewport sizing, mixed directionality, keyboard and screen-reader
semantics, reduced motion, and a 50,000-message fixture with a bounded mounted-widget
count. The attachment tiles ([ADR-089](../architecture/decisions/089-direct-attachments.md),
`chat_attachment_tiles.dart`) were added inside the message builder without changing this
boundary: an inline picture holds its place with a placeholder of its ratio until it is
decoded, and the size-notification anchor path is shared by every row builder.

## Message-state presentation

The UI distinguishes local draft, queued offline, encrypting, sending, server accepted,
delivered, read, failed/retry, blocked by security change, deleted locally, remote-delete
requested, and unsupported protocol. A single generic checkmark must not collapse states
that have different guarantees.

## Accessibility and internationalization gates

Validate input on Android across its supported viewport sizes. See
[platform status](../STATUS.md#platform-identity-and-content) for target scope.

- The interface supports English and Persian from the first release, including RTL
  chrome, mixed-direction message text (first-strong per UAX #9 P2/P3), and localized
  dates and numbers while protocol values remain locale-free.
- Keyboard, pointer, touch, screen-reader, large-text (unclamped), dark-mode, and
  high-contrast support apply across supported Android layouts.
- Screen-reader traversal, labels, live regions, and focus restoration pass on all core
  flows.
- Text at maximum supported scale does not hide primary/destructive actions.
- Persian RTL and English LTR goldens cover every shell and message direction mixture.
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
