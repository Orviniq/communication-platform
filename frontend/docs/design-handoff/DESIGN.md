# DESIGN.md — design-system brief for external design tools

**Status: derived export. Not authoritative.**
Generated from [`visual-design-system.md`](../visual-design-system.md) and
`lib/app/design_system/app_tokens.dart`. If those disagree with this file, they win.
Regenerate this file rather than editing it in place.

Its only purpose is to constrain an external UI design tool (Google Stitch, Figma, or
similar) so generated screens land inside the system this app already ships, instead of
proposing a second one that then has to be reconciled by hand.

---

## 0. Read this first

This is a **Flutter** application (Android now, web later), not a website. Do not
optimise for HTML/CSS idiom. Generated markup is a picture of the intent; the
implementation is Flutter widgets built on app-owned wrappers over the `forui` package.

**Design the content area only.** The application shell already exists and is not up for
redesign. It owns, on every screen:

- the three-destination navigation — Chats, Voice Rooms, Settings
- the environment banner (top of content)
- the compose affordance (FAB on narrow, list-header "+" on wide)
- the persistent active-voice-room banner

Do not draw navigation bars, rails, tab bars, or a compose button. A screen that
redesigns the shell is rejected on sight.

**Two locales, and Persian is not an afterthought.** The app ships `en` and `fa` and
bundles Vazirmatn for both. Every screen must work mirrored. See §7.

---

## 1. Color tokens

Twelve semantic tokens. Never use a literal color; always name the token. Four palettes
exist — light, dark, and two authored high-contrast palettes (high contrast is a separate
authored mapping, never a runtime transform of the values below).

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F6F7F9` | `#0E1014` | App background |
| `surface` | `#FFFFFF` | `#15181E` | Navigation and incoming surfaces |
| `surfaceRaised` | `#EEF1F5` | `#1C2028` | Cards, menus, selected rows |
| `textPrimary` | `#17191D` | `#F4F6F8` | Primary content |
| `textMuted` | `#626B78` | `#A8B0BC` | Secondary content |
| `border` | `#DCE1E8` | `#2B323D` | Dividers and outlines |
| `accent` | `#315CF5` | `#8298FF` | Primary action, focus, outgoing identity |
| `accentSoft` | `#E7ECFF` | `#202B52` | Outgoing bubble, selected tint |
| `success` | `#167A58` | `#53C995` | Verified, success |
| `warning` | `#9A6200` | `#E6AE55` | Degraded, attention |
| `danger` | `#BD3E4F` | `#F07886` | Destructive, failure |
| `scrim` | `#17191D` @ 60% | `#000000` @ 70% | Modal overlay |

Rules:

- All text/background pairs meet **WCAG 2.2 AA** — 4.5:1 body, 3:1 large text and UI
  indicators.
- **Color never carries state alone.** Verification, failure, speaking, mic, and message
  state always add shape, icon, or text.
- Accent is **reserved**: current destination, primary action, focus ring, verification
  action, outgoing-message identity. Navigation and settings surfaces stay neutral. Do
  not use accent for decoration, headers, or section chrome.
- There is no gradient, no glassmorphism, no colored hero, no illustration set. Security
  and connectivity states use honest text, never decorative art.

## 2. Typography

**Vazirmatn** variable, one family for Persian and Latin. Do not propose a second family
and do not use a display or brand face.

| Role | Size/line height | Weight |
|---|---|---|
| `display` | 32/40 | 600 |
| `title` | 24/32 | 600 |
| `section` | 20/28 | 600 |
| `body` | 16/24 | 400 |
| `compact` | 14/20 | 400 |
| `label` | 12/16 | 500 |

- Body and message content are regular; actions medium; unread and title emphasis
  semibold. Full bold is exceptional hierarchy only.
- Text scaling is never clamped below the platform request. **Layout reflows before text
  truncates** — the only exception is explicitly single-line list metadata, which carries
  an accessible full label. Design every screen assuming text can be much larger than
  drawn.

## 3. Geometry, density, elevation

- **Spacing scale: 4, 8, 12, 16, 24, 32, 48.** Nothing off-scale. Content follows an
  8-pixel alignment rhythm.
- **Radii:** 8 compact controls · 14 cards and dialog internals · 18 primary controls ·
  20 message bubbles · pill = half the control height.
- **Control height 48** on touch. A pointer-dense layout may draw a 40px control, but the
  hit region stays at least 48.
- **Borders** are one logical pixel at standard contrast.
- **Elevation is rare.** Level 1 (`0 2px 8px rgba(0,0,0,0.08)`) for floating navigation
  and menus. Level 2 (`0 8px 20px rgba(0,0,0,0.14)`) only for blocking dialogs. Nothing
  else casts a shadow.
- **Focus ring:** 3px in `accent`, 2px gap, on radius 18. Minimum target 48.

## 4. Layout and breakpoints

Three width classes. The destination set is identical in all three; only the container
changes.

| Class | Width | Shell |
|---|---|---|
| `narrow` | < 600 | Bottom tab bar, full-screen stacks, FAB |
| `medium` | 600–1023 | Collapsed rail, 88px |
| `wide` | ≥ 1024 | Two-pane, 320px navigation + list, detail on the right |

- Readable content column is capped at **760**.
- Wide targets a **300–340px** list column and an optional **340–400px** details or thread
  panel. The message column has a readable maximum rather than stretching across the
  viewport.
- Message bubbles are at most **82%** of the message column on narrow, **70%** on medium
  and wide.
- **Modals route by width: sheet on narrow, dialog or panel on wide.** Every sheet needs
  both forms.
- Resizing preserves state — selected conversation, scroll anchor, draft, and active modal
  intent all survive a breakpoint crossing.
- Deliver every screen at narrow and wide. Medium may follow from wide.

## 5. Motion

- 120ms press and hover · 180ms local state change · 240ms route and sheet transition.
- Emphasised deceleration on entry, acceleration on exit.
- Message insertion preserves the reading anchor and does not animate the whole list.
  Receipt and reaction changes cross-fade locally only.
- **Reduced motion** removes spatial travel and all repeated or pulsing animation while
  keeping immediate opacity and state feedback. Never design a state whose only signal is
  a pulse or a spinner animation.

## 6. Component grammar

App-owned wrappers are the only layer that configures the underlying package. Design
against these, and name them in annotations so the implementation maps 1:1.

| Component | Variants |
|---|---|
| `AppButton` | `primary`, `secondary`, `danger`, `outline`, `ghost` |
| `AppIconButton` | icon-only, localized semantic label, visible focus/pressed/disabled |
| `AppField` | text input |
| `AppCheckboxRow` | row-shaped checkbox |
| `AppStatusBadge` | `neutral`, `information`, `success`, `warning`, `danger` |
| `AppStatePanel` | `loading`, `empty`, `error` |
| `AppModals` | sheets and blocking dialogs |

- **Bubbles:** incoming on `surface`, outgoing on `accentSoft`, with readable text colors
  — not white-on-accent. Consecutive bubbles group by author and time; only the final
  bubble in a run gets the author tail.
- **Empty states:** one concise title, one explanatory sentence, at most one primary
  action.
- **Icons:** Lucide, via app-owned semantic names (`AppIcons.search`, `AppIcons.send`,
  `AppIcons.security`). Icon-only actions need labels and tooltips. Emoji are never
  functional controls.
- Needing a component that is not in this table is a finding worth reporting, not a
  licence to invent one. Say so in the screen notes.

## 7. RTL and bidirectional text

- Layout **mirrors** in Persian: leading/trailing, not left/right. Bubble tails, delivery
  ticks, swipe affordances, back arrows, and list chevrons all flip.
- **Directional icons mirror only when their meaning is directional.** Search, security,
  media state (play/pause/mute), and verification do **not** mirror merely because the
  locale is RTL.
- Paragraph direction is resolved per string by first-strong character, not by app
  locale. A Persian UI routinely contains LTR strings and vice versa — design rows and
  bubbles that hold a mixed-direction line without breaking alignment.
- Never bake text direction into a layout assumption (no "timestamp is always on the
  right").

## 7a. Accessibility — these are release gates, not polish

*Corrected 2026-10-07 (server ADR-0020):* this list held a gate for keyboard-only
operation on web, including context menus and dialogs. There is no Web client: the server
serves no browser surface, and the client's web target was removed on 2026-09-08
(`implementation-checklist.md`, The web target).

- **Color is never the only carrier** of verification, failure, mute, speaking, or receipt
  state. Every one of those needs shape, icon, or text alongside.
- **Text at maximum supported scale must not hide primary or destructive actions.** Scale
  is never clamped below the platform request, so design for text much larger than drawn.
- Screen-reader traversal, labels, live regions, and focus restoration pass on all core
  flows. Where a screen has frequent state churn, the live-region policy is a design
  decision to state explicitly, not a default to inherit.
- Touch targets at least 48; pointer targets additionally carry hover, focus, and
  right-click behaviour.
- The global error and toast host announces accessibly and carries **no sensitive detail**.
- When privacy mode is on, sensitive text and images never appear in the blurred
  app-switcher preview or in notifications.

## 8. Hard prohibitions

These are the failure modes most likely from a generative design pass on this product.

1. **Do not invent a palette, a type scale, a spacing unit, or a radius.** Use §1–§3.
2. **Do not redesign the shell** (§0).
3. **Do not design an admin hierarchy.** In voice rooms all members are equal peers —
   no owner, no admin, no roles, no kick. The backend has no member table.
4. **Do not show server-readable content.** Names, avatars, descriptions, message bodies
   and room names are all decrypted on-device. There is no server-side search, no
   server-generated preview, no server-side name.
5. **Do not design a maturity label.** Exactly two exist — **Experimental** and **Not
   built yet** — and they come from `SurfaceMaturity`. Nothing means "stable", "secure",
   "verified", or "audited".
6. **Do not present a control that cannot succeed.** If an action is unavailable, the
   screen says so and disables it. It never fails into a generic error toast.
7. **Do not overstate a guarantee.** Delete-for-everyone, ephemeral room text, and
   history recovery are best-effort, and the copy must say so.
8. **Do not use decorative illustration** for security, connectivity, or failure states.

## 9. What to hand back

Per screen, at both narrow and wide:

- Light and dark. High contrast may be omitted; it is an authored mapping, not a filter.
- **Every state from the screen's state list**, not just the happy path. For voice rooms
  that list is [`voice-room-states.md`](voice-room-states.md).
- Persian mirrored for at least the densest screen in each flow.
- A note naming the components from §6 used in each region.
