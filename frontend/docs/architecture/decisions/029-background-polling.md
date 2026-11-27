# ADR-029: Android background messaging uses best-effort polling, not a persistent service

- **Status:** Superseded by ADR-046 (2026-08-21); token hazard note updated by ADR-083 (2026-10-07)
- **Date:** Undocumented in the ADR register (introduced in commit `7e4930f8`, 2026-07-25; superseded 2026-08-21)
- **Supersedes:** [ADR-014](014-foreground-connection.md)
- **Superseded by:** ADR-046 (2026-08-21); see also ADR-049, ADR-051, ADR-053, ADR-094
- **Related:** [ADR-013](013-no-foreign-push.md)

## Decision (Position)

Originally decided that Android background messaging uses **best-effort deferrable polling** rather than a persistent foreground service, keeping active foreground services only for live voice calls.

**Superseded by ADR-046 (2026-08-21):** Deferrable polling alone is strictly eventual (15-minute `JobScheduler` floor, Doze maintenance-window thinning, and complete network block in *rare* and *restricted* App Standby buckets). ADR-046 kept deferrable catch-up as the mandatory floor (`JobScheduler` in ADR-049, dropping WorkManager) and added an **opt-in `specialUse` foreground service** above it (built in ADR-051, offered in production as best effort in ADR-094). Active voice remains a separate `microphone` foreground service.

## Rationale

Original rationale: matched the binding client contract and avoided false delivery guarantees or an always-on messaging foreground service.

Why superseded: primary Android platform analysis on 2026-08-21 showed deferrable polling alone fails entirely in *rare*/*restricted* standby buckets and under aggressive Doze, whereas Android's Doze acceptable-use rules explicitly permit an opt-in foreground service and battery-optimization exemption for instant messaging apps unable to use FCM ([ADR-013](013-no-foreign-push.md)).

## Constraints and Open Gates

- Superseded; see ADR-046, ADR-049, ADR-051, ADR-053, and ADR-094, plus [Frontend status](../../STATUS.md#presence-voice-and-delivery) (sustained-delivery physical-device validation gate remains closed/unmet; production offers the switch as `bestEffort` with disclosed battery/notification costs).
- Note (ADR-083, 2026-10-07): The rotating-refresh-token race hazard cited in ADR-049/ADR-050 when arbitrating between UI and background isolates no longer exists after server ADR-0023 moved to a single non-rotating session token, though single-owner arbitration remains active for storage/ratchet safety.

## Costs

- Best-effort deferrable polling alone cannot promise timely background delivery; the opt-in sustained-delivery layer trades a persistent shade notification and battery draw when enabled by the user.

## Reversal Trigger

Already superseded by ADR-046 (2026-08-21).

## History, Amendments, and Supersession

- **2026-07-25 (`7e4930f8`):** Original decision added to the register (`Accepted`), superseding [ADR-014](014-foreground-connection.md).
- **2026-08-21 (ADR-046, `85e89d54`):** Superseded by layered delivery (foreground socket + `JobScheduler` floor + opt-in `specialUse` service).
- **2026-08-22 (ADR-051, `c505a436`):** Built the opt-in `SustainedDeliveryService`.
- **2026-10-07 (ADR-083):** Recorded that server ADR-0023 eliminated the rotating refresh-token hazard across standby/background delivery owners.
