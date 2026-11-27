# Visual design system

## Direction and authority

The product uses a quiet, precise, minimal visual language. Telegram is an interaction
reference, not a visual template. The identity comes from restrained density, strong
typographic hierarchy, selective indigo, carefully shaped message surfaces, and motion
that explains state without decoration.

These tokens are the production baseline for app-owned Forui wrappers and the app-owned
timeline builders (`lib/app/design_system/app_tokens.dart`). Widgets MUST consume
semantic tokens rather than literal colors or dimensions. The future product name, logo,
and reviewed brand artwork may replace brand assets and the accent family through an ADR;
they do not silently change accessibility or component behavior.

## Color tokens

All text/background combinations MUST meet WCAG 2.2 AA; normal body text targets at
least 4.5:1 and large text/UI indicators at least 3:1. Verification, failure, speaking,
and message state always include shape, icon, or text and never rely on color alone.

| Semantic token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F6F7F9` | `#0E1014` | App background |
| `surface` | `#FFFFFF` | `#15181E` | Navigation and incoming surfaces |
| `surfaceRaised` | `#EEF1F5` | `#1C2028` | Cards, menus, selected rows |
| `textPrimary` | `#17191D` | `#F4F6F8` | Primary content |
| `textMuted` | `#626B78` | `#A8B0BC` | Secondary content |
| `border` | `#DCE1E8` | `#2B323D` | Dividers and outlines |
| `accent` | `#315CF5` | `#8298FF` | Primary action/focus/outgoing identity |
| `accentSoft` | `#E7ECFF` | `#202B52` | Outgoing bubble and selected tint |
| `success` | `#167A58` | `#53C995` | Verified/success |
| `warning` | `#9A6200` | `#E6AE55` | Degraded/attention |
| `danger` | `#BD3E4F` | `#F07886` | Destructive/failure |
| `scrim` | `#17191D99` | `#000000B3` | Modal overlay |

High-contrast mode is a separate semantic-token mapping (`highContrastLight` and
`highContrastDark` in `AppColorTokens`), not a runtime manipulation of the values above.
Private content never appears beneath a translucent surface when the privacy mode requires
obscuring it.

## Typography

- Bundle one reviewed, redistributable variable sans family with complete Persian and
  Latin coverage. Piece 03 pins the official Vazirmatn `v33.003` variable TTF at
  `assets/fonts/vazirmatn/Vazirmatn-Variable.ttf` (SHA-256
  `696249a2c74b39ffdef55de4df2809c5b639d3ff80d618d8160a095d2fd49dca`) with its local
  SIL Open Font License 1.1 copy (SHA-256
  `17e355067c8284f47743a1ee3b1ef7ff684ff0601eda357f9353b10b3016ab31`). The artifact,
  Latin/Persian coverage, and license were verified from the
  [official repository](https://github.com/rastikerdar/vazirmatn/tree/v33.003) on
  2026-07-27. It is bundled into Android version-1 artifacts; Android is the sole
  version-1 target ([frontend status](../STATUS.md#the-web-target)), and any future Web
  artifact must also bundle it and make no font request at runtime.
- Type scale: display 32/40, title 24/32, section 20/28, body 16/24, compact 14/20,
  label 12/16. Values are font size/line height in logical pixels at scale 1.0.
- Body and message content use regular weight (`FontWeight.w400`); actions (`label`) use
  medium (`FontWeight.w500`); display, title, and section headings use semibold
  (`FontWeight.w600`). Full bold is reserved for exceptional hierarchy.
- Text scaling is never clamped below the platform request. Layout changes before text is
  truncated, except for explicitly single-line list metadata with an accessible full
  label.

## Geometry and density

- Base spacing unit is 4. Tokens are `4, 8, 12, 16, 24, 32, 48`.
- Control height is 48 on Android touch layouts. A future pointer-dense layout may
  use a 40 px visual control while keeping touch hit regions at least 48 px;
  touch hit regions remain at least 48 even when the visible icon is smaller.
- Radii are 8 for compact controls, 14 for cards/dialog internals, 18 for primary
  controls, and 20 for message bubbles. Pills use half the control height.
- Borders use one logical pixel at standard contrast. Elevation is rare: level 1 for
  floating navigation/menus and level 2 only for blocking dialogs.
- Content uses an 8-pixel alignment rhythm. Optical exceptions for icons and bubble tails
  are encoded inside components, never repeated as screen literals.

## Iconography

- Use the Lucide icon set bundled with Forui, exposed by `FLucideIcons`, as the default
  product UI icon family. Do not add a separate Lucide, Material, Cupertino, or other
  general-purpose icon package for ordinary application controls.
- Feature code MUST request app-owned semantic icons such as `AppIcons.search`,
  `AppIcons.send`, or `AppIcons.security`; it MUST NOT reference `FLucideIcons` directly.
  The mapping layer keeps icon meaning consistent and isolates package/API changes.
- Keep Forui's widget-level `FIcons` mapping on its default Lucide family unless a
  reviewed product requirement and ADR explicitly replace it.
- Icon-only actions have localized semantic labels, tooltips where appropriate, visible
  focus/pressed/disabled states, and the minimum target sizes defined above. Decorative
  icons are excluded from accessibility semantics.
- Directional icons mirror with the interface only when their meaning is directional.
  Universal symbols such as search, security, media state, and verification do not
  mirror merely because the locale is RTL.
- Icons and color never carry state alone. Product logos, avatars, thumbnails, flags,
  and illustrations are reviewed assets rather than substitutions from the icon set;
  emoji are not used as functional controls.

## Component grammar

- App-owned wrappers are the only layer that configures Forui. Feature screens do not
  import package theme values directly.
- Navigation and settings surfaces are neutral. Accent is reserved for current
  destination, primary action, focus, verification action, and outgoing-message identity.
- Incoming bubbles use `surface`; outgoing bubbles use `accentSoft`, with readable text
  colors rather than white-on-accent by default. Consecutive bubbles group by author and
  time; the final bubble alone receives the author-tail treatment.
- Bubble width is at most 82% of the message column on narrow layouts and 70% on
  medium/wide layouts. The readable message column remains bounded by
  [Adaptive layout](ADAPTIVE-LAYOUT.md#adaptive-shell).
- Composer, reply strip, attachment progress, reactions, receipts, and failure actions
  are built through the app-owned timeline builders using the same tokens.
  Package-default bubbles and composers are prohibited in release builds.
- Empty states use one concise title, one explanatory sentence, and at most one primary
  action. Security and connectivity states use honest text rather than decorative art.

## Motion and interaction

- Durations: 120 ms for hover/press, 180 ms for local state changes, and 240 ms for
  route/sheet transitions. Standard easing is emphasized deceleration on entry and
  acceleration on exit.
- Message insertion preserves the reading anchor; it does not animate the entire list.
  Receipt/reaction changes use local cross-fades only. Jump-to-message pulse keeps an
  accent tint that fades over 1,500 ms (`AppMotion.pulse`), or stays steady for 1,000 ms
  (`AppMotion.pulseReduced`) when reduced motion is enabled.
- Reduced-motion mode removes spatial travel and repeated/pulsing animation while
  retaining immediate opacity/state feedback.
- Pointer/keyboard interaction exposes visible keyboard focus, hover only as enhancement,
  platform-consistent selection, and right-click menus without disabling system
  accessibility shortcuts.

## Brand assets still expected

Communication Platform is the working name, and the wordmark, app icon, and final logo
geometry remain inputs from the future brand/design phase. Until then, development uses a
neutral non-shipping placeholder. Missing brand artwork does not block architecture,
protocol, or component implementation, but the version-1 Android release build MUST replace
the placeholder and pass Android asset, contrast, small-size, and dark-surface review.
