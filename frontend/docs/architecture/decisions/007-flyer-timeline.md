# ADR-007: Flyer Chat behind a timeline adapter

- **Status:** Superseded by [ADR-066](066-sliver-timeline.md) (2026-08-30); packages removed by [ADR-054](054-dependency-policy.md) (2026-08-24)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Superseded by:** [ADR-066](066-sliver-timeline.md) (2026-08-30); package dependency removed earlier in [ADR-054](054-dependency-policy.md) (2026-08-24)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-006](006-forui-boundary.md), [ADR-024](024-visual-system.md)

## Decision (Position)

Originally decided to place **Flyer Chat** (`flutter_chat_ui` / `flutter_chat_core`) behind a replaceable `ChatTimelineAdapter` seam with custom builders owning the visual design of bubbles, grouping, replies, status, attachments, system events, and the composer.

As superseded by ADR-066: the timeline seam (`ChatTimelineAdapter` taking immutable view models and emitting typed intents) is preserved, while the implementation behind it is an **app-owned reversed sliver (`CustomScrollView`)** with explicit reading-anchor restoration, and Flyer Chat is not used.

## Rationale

Original rationale: reuse chat list virtualization while allowing exclusive custom builders or full replacement if pagination, anchoring, RTL, accessibility, or media performance spikes failed.

Why superseded: Piece 15 discovered that Flyer 2.11.1 required a mutable, controller-owned `ChatController` for message state, conflicting directly with [ADR-002](002-drift-source-of-truth.md) (Drift as single source of truth). Reconciling a mutable package controller against a Drift stream reintroduces state divergence one layer higher.

## Constraints and Open Gates

- `flutter_chat_core` (2.9.0) and `flutter_chat_ui` (2.11.1) are removed from [pubspec.yaml](../../../pubspec.yaml) and forbidden in core/feature policy layers by [architecture_boundary_test.dart](../../../test/architecture/architecture_boundary_test.dart).
- [ChatTimelineAdapter](../../../lib/features/messaging/presentation/chat_timeline_adapter.dart) preserves the adapter boundary defined in [Architecture](../../architecture.md#ui-boundary).
- Note: [Frontend instructions](../../../AGENTS.md) still mentions Flyer Chat in its general boundary prose as a historical package name alongside the live app-owned adapter.

## Costs

- Original cost: maintaining an adapter layer over Flyer Chat.
- Replacement cost (recorded in ADR-066): the app owns reversed-sliver scroll physics, per-message keys, `findChildIndexCallback`, pagination anchor restoration, bubble geometry, and first-strong RTL/bidi resolution (`app_text_direction.dart`).

## Reversal Trigger

The original replacement trigger ("if pagination, anchoring, RTL, or [ADR-002] single-source-of-truth requirements fail, replace behind the timeline adapter with a custom sliver") already fired in Piece 15 and was finalized by ADR-054 and ADR-066.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **Piece 15:** Implementation replaced Flyer Chat with an app-owned reversed sliver behind `ChatTimelineAdapter`, though the register row remained `Accepted` and the packages remained in `pubspec.yaml`.
- **2026-08-24 (ADR-054):** Removed `flutter_chat_ui` 2.11.1 and `flutter_chat_core` 2.9.0 from `pubspec.yaml` as declared-and-unimported dependencies.
- **2026-08-30 (ADR-066, `ef3ad255`):** Formally superseded ADR-007 and updated the register row to `Superseded by ADR-066 (2026-08-30)`, recording the architectural conflict with ADR-002 and separating application-layer performance costs (ADR-062, ADR-063, ADR-064) from rendering ownership.
