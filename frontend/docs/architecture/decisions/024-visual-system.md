# ADR-024: Restrained neutral/indigo app-owned visual system baseline

- **Status:** Accepted (register fact correction recorded 2026-08-30; decision unchanged)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24; fact correction 2026-08-30)
- **Related:** [ADR-006](006-forui-boundary.md), [ADR-007](007-flyer-timeline.md), [ADR-016](016-english-and-persian.md), [ADR-031](031-semantic-icons.md)

## Decision (Position)

Use a **restrained neutral/indigo app-owned visual system** (`AppColorTokens`, `AppTypographyTokens`, `AppSpacing`, `AppRadii`, `AppElevation`, `AppMotion`) as the production visual baseline across light, dark, and high-contrast themes.

1. Widgets consume semantic design tokens ([app_tokens.dart](../../../lib/app/design_system/app_tokens.dart), [app_theme.dart](../../../lib/app/design_system/app_theme.dart)) rather than literal colors or spacing numbers.
2. All text/background pairs target WCAG 2.2 AA contrast (4.5:1 normal text, 3:1 large text/UI indicators), and verification, failure, speaking, and message states never rely on color alone.
3. Navigation and settings surfaces stay neutral; indigo accent (`#315CF5` light / `#8298FF` dark) is reserved for active destinations, primary actions, focus, verification actions, and outgoing message identity (`accentSoft`).
4. Future product name, logo, and reviewed brand artwork may replace brand tokens/assets through an ADR without altering accessibility or component behavior.

## Rationale

Provides Forui wrappers and the app-owned timeline builders one reproducible, accessible, quiet visual identity while allowing later brand assets to replace only brand tokens.

## Constraints and Open Gates

- Specified in [Visual design system](../../ui/DESIGN-SYSTEM.md).
- Enforced through `lib/app/design_system/` and `design_system_boundary_test.dart`.
- Open gate: [Frontend status](../../STATUS.md#platform-identity-and-content) notes that core UI accessibility verification on representative device data remains open.

## Costs

- Custom semantic token classes and theme extensions must be maintained alongside Forui (`0.24.3`) and Material `ThemeData` across light, dark, and high-contrast variants.

## Reversal Trigger

A reviewed brand identity (product name, logo, accent palette) adopted via a dedicated branding ADR.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`), originally citing "Forui and Flyer builders".
- **2026-08-30 (register correction & ADR-066):** Recorded a correction of fact (decision unchanged): "Flyer builders" named a package removed by ADR-054 and superseded by ADR-066; the sole timeline builder set served by these tokens is the app-owned timeline surface (`ChatTimelineAdapter` and builders).
- No supersession.
