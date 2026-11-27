# ADR-031: Forui-bundled Lucide icons exposed through app-owned semantic icon tokens

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `ef47bc6a`, 2026-07-27)
- **Related:** [ADR-006](006-forui-boundary.md), [ADR-013](013-no-foreign-push.md), [ADR-016](016-english-and-persian.md), [ADR-024](024-visual-system.md)

## Decision (Position)

Expose **Forui's locally bundled Lucide icons (`FLucideIcons`)** exclusively through **app-owned semantic `AppIcons` tokens** ([app_icons.dart](../../../lib/app/design_system/app_icons.dart)).

1. Feature screens and components MUST request semantic tokens (e.g., `AppIcons.search`, `AppIcons.send`, `AppIcons.security`, `AppIcons.back`) and MUST NOT import or reference `FLucideIcons` directly.
2. Do not add a separate Lucide, Material, Cupertino, or other general-purpose icon package for ordinary UI controls.
3. Directional mirroring (`mirrorsInRtl`) and accessibility semantics are centralized on `AppIconData` / app-owned icon components rather than duplicated across screens.

## Rationale

Provides one coherent, locally bundled icon family with zero extra icon-package dependency and zero network font/CDN calls ([ADR-013](013-no-foreign-push.md)), while isolating feature code from Forui's pre-1.0 icon API and centralizing RTL mirroring ([ADR-016](016-english-and-persian.md)) and accessibility rules.

## Constraints and Open Gates

- Enforced by [design_system_boundary_test.dart](../../../test/architecture/design_system_boundary_test.dart), which fails if any file in `lib/` outside `lib/app/design_system/app_icons.dart` references `FLucideIcons`.
- Documented in [Visual design system](../../ui/DESIGN-SYSTEM.md#iconography) and [Frontend instructions](../../../AGENTS.md).
- Open gates: None.

## Costs

- Every newly needed UI icon requires adding a named semantic token to `AppIcons`.
- Product logos, avatars, and specialized illustrations remain outside the icon family and require dedicated reviewed assets.

## Reversal Trigger

If Forui removes or replaces `FLucideIcons` or an approved product ADR adopts a custom/separate icon family behind `AppIcons`.

## History, Amendments, and Supersession

- **2026-07-27 (`ef47bc6a`):** Original decision added to the register (`Accepted`).
- **2026-10-12:** Extended with `AppIcons.video` (ADR-097) and attachment status tokens (`download`, `expired`, `damaged`, ADR-089).
- No supersession.
