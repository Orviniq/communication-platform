# ADR-014: Explicit Android foreground connection mode

- **Status:** Superseded by [ADR-029](029-background-polling.md) (2026-07-25); [ADR-029](029-background-polling.md) was subsequently superseded by [ADR-046](046-layered-delivery.md) (2026-08-21)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Superseded by:** [ADR-029](029-background-polling.md) (2026-07-25), later superseded by [ADR-046](046-layered-delivery.md) (2026-08-21)
- **Related:** [ADR-013](013-no-foreign-push.md), [ADR-029](029-background-polling.md)

## Decision (Position)

Originally decided to rely on an **explicit Android foreground connection mode** as the primary background reachability mechanism for messaging.

Superseded on 2026-07-25 by [ADR-029](029-background-polling.md) (best-effort polling without a persistent messaging foreground service), and later by ADR-046 / ADR-051 / ADR-094 (layered delivery: foreground socket + `JobScheduler` periodic catch-up floor + **opt-in** `specialUse` sustained-delivery foreground service, plus `microphone` foreground service for active voice calls).

## Rationale

Original rationale: provide the best available self-hosted delivery when users required background reachability without foreign push ([ADR-013](013-no-foreign-push.md)).

Why superseded: `CLIENT_CONTRACT.md` required background polling rather than forcing a persistent foreground connection mode by default. Later, ADR-046 and ADR-051 reintroduced an *opt-in* `specialUse` foreground service strictly above the mandatory `JobScheduler` polling floor.

## Constraints and Open Gates

- Superseded; see [ADR-029](029-background-polling.md) and ADR-046 / ADR-049 / ADR-051 / ADR-094 for current background delivery constraints and open physical-device evidence gates ([Frontend status](../../STATUS.md#presence-voice-and-delivery)).

## Costs

- An always-on foreground service incurs persistent notification visibility, battery drain, and vendor-specific background restriction friction, which is why later decisions made it strictly opt-in (ADR-051, ADR-094).

## Reversal Trigger

Already superseded by [ADR-029](029-background-polling.md) and ADR-046.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-07-25 (`7e4930f8`):** Superseded by [ADR-029](029-background-polling.md); register row updated to `Superseded by ADR-029`.
- **2026-08-21 – 2026-10-08:** ADR-029 itself superseded by ADR-046, implemented in ADR-049 / ADR-051, and offered in production as best-effort opt-in under ADR-094.
