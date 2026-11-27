# ADR-003: Riverpod for DI and reactive application state

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-001](001-feature-first-architecture.md), [ADR-002](002-drift-source-of-truth.md)

## Decision (Position)

Use **Riverpod** (`flutter_riverpod: 3.3.2` in [pubspec.yaml](../../../pubspec.yaml)) for dependency injection, lifecycle coordination, commands, and reactive projections of Drift database streams.

1. Concrete adapter wiring lives in `frontend/lib/app/dependencies/` as immutable provider descriptors; `ProviderScope` owns runtime instances and test overrides rather than global singletons.
2. Providers manage lifecycle and observe database streams; they do not act as a second database or hold durable state exclusively in memory.
3. UI-only transient state (focus, selection, animation) may stay in widgets or short-lived providers.

## Rationale

Supports testable dependency scopes (`ProviderScope` overrides in unit/widget tests) and reactive Drift stream projections without global singletons.

## Constraints and Open Gates

- Enforced by [Architecture](../OVERVIEW.md) and [Frontend instructions](../../../AGENTS.md).
- Root-level lifecycle controllers must not rely on widget `build`-scoped `ref.watch` subscriptions, because `flutter_riverpod` 3.3.2 pauses those when a route leaves view (`ConsumerStatefulElement._applyTickerMode`); root-owned coordination uses `listenManual` (ADR-047).
- Hand-written provider declarations are used without code generation.
- Open gates: None.

## Costs

- Developers must avoid treating `Notifier` state as durable truth or leaking concrete infrastructure imports outside `lib/app/dependencies/`.
- Lifecycle management across headless background isolates requires constructing an independent runtime container (`ApplicationRuntime`, ADR-049 / ADR-050) rather than sharing the UI `ProviderScope`.

## Reversal Trigger

If Riverpod's scoping, ticker-mode subscription semantics, or isolate composition model introduces unresolvable lifecycle bugs or cannot represent required reactive state.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-08-21 (ADR-047):** Clarified root ownership via `listenManual` for `SyncLifecycleSupervisor`.
- **2026-08-24 (ADR-054):** Removed unused `riverpod_annotation` 4.0.3 and `riverpod_generator` 4.0.4 from `pubspec.yaml`, keeping hand-written `flutter_riverpod` providers only.
- No supersession.
