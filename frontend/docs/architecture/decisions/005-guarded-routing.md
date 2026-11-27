# ADR-005: `go_router` with route guards

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-001](001-feature-first-architecture.md)

## Decision (Position)

Use **`go_router`** (`go_router: 17.3.0` in [pubspec.yaml](../../../pubspec.yaml)) with declarative route guards in [app_router.dart](../../../lib/app/routing/app_router.dart) for all application navigation.

1. Route redirects derive from `AuthenticationRouteState` and explicit `AppRouteGuard` checks, keeping navigation decisions out of domain and protocol layers.
2. Authenticated root destinations (`/chats`, `/voice-rooms`, `/settings`) live in the adaptive application shell, while pages above a tab root open on the root navigator (`rootNavigatorKey`) so they cover the tab bar/rail (ADR-086).

## Rationale

Supports deep links, URL-shaped route state, and adaptive shell navigation with centralized authentication/enrollment gating and without putting navigation dependencies into domain code.

## Constraints and Open Gates

- Enforced by [Frontend instructions](../../../AGENTS.md) and [app_router.dart](../../../lib/app/routing/app_router.dart).
- Any notification tap intent must enter through the launcher intent with no deep-link destination extras that bypass route guards (ADR-048).
- Open gates: None.

## Costs

- Multi-navigator coordination (`rootNavigatorKey` vs. shell branch navigators) must be maintained explicitly so full-screen routes cover the navigation rail/bar while still carrying `VoiceRoomBannerFrame` when appropriate (ADR-086).

## Reversal Trigger

If `go_router`'s declarative `redirect` or `StatefulShellRoute` model cannot support required modal, deep-link, or adaptive multi-pane navigation flows.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-08-24 (ADR-054):** Pinned `go_router` to exact version `17.3.0` (replacing caret range).
- **2026-10-08 (ADR-086):** Established the root-navigator full-screen rule above tab roots.
- No supersession.
