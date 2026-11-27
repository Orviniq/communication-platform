# ADR-006: Forui behind app-owned components

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-001](001-feature-first-architecture.md), [ADR-007](007-flyer-timeline.md), [ADR-024](024-visual-system.md), [ADR-031](031-semantic-icons.md)

## Decision (Position)

Adopt **Forui** (`forui: 0.24.3` in [pubspec.yaml](../../../pubspec.yaml)) strictly behind **app-owned design-system wrapper components** under `frontend/lib/app/design_system/`.

1. Feature modules under `frontend/lib/features/` MUST NOT import `package:forui/` or reference Forui theme/icon APIs directly.
2. App-owned wrappers (`app_theme.dart`, `app_icons.dart`, and `app_components.dart` / `components/*`) configure Forui using the project's semantic tokens (`app_tokens.dart`) and present application-owned APIs to features.
3. Forui's pre-1.0 API surface is isolated to a minimal set of files in `lib/app/design_system/` (verified by ADR-066 D3 and [design_system_boundary_test.dart](../../../test/architecture/design_system_boundary_test.dart)).

## Rationale

Gains consistent, accessible UI primitives without coupling product design, feature screens, or state models directly to a pre-1.0 external package API.

## Constraints and Open Gates

- Enforced by [design_system_boundary_test.dart](../../../test/architecture/design_system_boundary_test.dart) and [architecture_boundary_test.dart](../../../test/architecture/architecture_boundary_test.dart), and documented in [Visual design system](../../ui/DESIGN-SYSTEM.md) and [Frontend instructions](../../../AGENTS.md).
- Text input, selection controls, menus, dialogs, and bottom sheets rely on Material where IME composition, RTL caret handling, and TalkBack semantics are already proven (ADR-066 D3).
- Open gates: None.

## Costs

- Wrapper components must be maintained for each primitive exposed to features.
- Upgrading `forui` (0.24.3) requires updating wrapper internals when pre-1.0 breaking changes occur, though the blast radius stays bounded to `lib/app/design_system/`.

## Reversal Trigger

If Forui's pre-1.0 maintenance, RTL behavior, or accessibility semantics become incompatible with Material/Flutter updates and maintaining the wrappers costs more than app-owned Material primitives.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-08-24 (ADR-054):** Pinned `forui` to exact version `0.24.3`.
- **2026-08-25 (ADR-059):** Extended the same app-owned wrapper pattern to `emoji_picker_flutter` (`app_emoji_picker.dart`).
- **2026-08-30 (ADR-066 D3):** Reaffirmed ADR-006 unchanged alongside app-owned timeline rendering and Material text/selection surfaces.
- No supersession.
