# ADR-001: Feature-first Clean Architecture

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-003](003-riverpod-composition.md), [ADR-005](005-guarded-routing.md), [ADR-006](006-forui-boundary.md)

## Decision (Position)

Structure the Flutter client using **Modular Feature-First Clean Architecture with an Offline-First, Event-Driven Core**.

1. Top-level code under `frontend/lib/` is organized into four boundaries: `app/` (root widget, bootstrap, config, routing, DI composition, design system), `core/` (framework-free cross-feature policy contracts, domain primitives, protocol values, and `Result`/`Failure` types), `features/<feature>/` (product capabilities), and `shared/` (cross-feature technical adapters and reusable presentation primitives).
2. Each feature module uses only the recognized layers: `domain/`, `application/` (`use_cases/`, `ports/`), `infrastructure/`, and `presentation/`.
3. Dependencies point strictly inward: presentation depends on application use cases and immutable view state; application depends on domain types and ports; infrastructure implements ports; domain and protocol code never import Flutter widgets, Dio, Drift, Forui, or platform plugins.
4. `frontend/lib/app/dependencies/` is the sole Riverpod composition root allowed to select concrete adapters. A feature cannot import another feature's infrastructure; cross-feature communication uses typed application commands and events.

## Rationale

Keeps security, synchronization, UI, and platform concerns independently testable, prevents domain and protocol rules from coupling to transport or UI packages, and makes product capabilities visible first in the tree.

## Constraints and Open Gates

- Enforced by [architecture_boundary_test.dart](../../../test/architecture/architecture_boundary_test.dart), [source_layout_test.dart](../../../test/architecture/source_layout_test.dart), and [use_case_composition_test.dart](../../../test/architecture/use_case_composition_test.dart), and codified in [Frontend instructions](../../../AGENTS.md) and [Architecture](../../architecture.md).
- A generic `utils` dumping ground is prohibited; `core/` must not accumulate feature business concepts.
- Open gates: None for this structural pattern.

## Costs

- Boilerplate of explicit ports, adapters, and immutable view models across feature boundaries (`app_shell`, `attachments`, `authentication`, `bootstrap`, `contacts`, `devices`, `diagnostics`, `groups`, `local_storage`, `messaging`, `networking`, `notifications`, `pairwise`, `server_config`, `settings`, `signals`, `synchronization`, `voice`).
- Cross-feature orchestration must go through typed commands/events or root composition rather than direct imports.

## Reversal Trigger

If a capability requires cross-cutting state or performance optimization that cannot be expressed cleanly behind ports and root composition without duplicating transactional boundaries.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- No supersession. In [Architecture](../../architecture.md), the forbidden inner-layer package list also tracks timeline adapters (`flutter_chat_core` and `flutter_chat_ui`, checked in `architecture_boundary_test.dart` even after those packages were removed from `pubspec.yaml` by ADR-054).
