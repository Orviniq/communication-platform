# ADR-022: Recovery restores history separately from current secure membership

- **Status:** Superseded by ADR-028 and ADR-030 (2026-07-25)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Superseded by:** [ADR-028](028-device-history-transfer.md), [ADR-030](030-recovery-key-material.md)
- **Related:** [ADR-027](027-device-cross-signing.md)

## Decision (Position)

Originally decided that **account recovery restores message history separately from current secure membership**, preventing the UI from claiming that an archive recovery secret recreates ratchets or group authorization.

Superseded on 2026-07-25 by [ADR-028](028-device-history-transfer.md) (history exists only on clients and transfers device-to-device, not from the server) and [ADR-030](030-recovery-key-material.md) (the recovery backup contains cross-signing identity material only, never history keys).

## Rationale

Original rationale: prevent the UI from falsely claiming that an archive secret recreates Double Ratchet or MLS authorization state.

Why superseded: the backend removed server-stored history completely, so there is no server-side history archive for a recovery secret to restore; identity recovery and device-to-device history transfer are entirely separate mechanisms.

## Constraints and Open Gates

- Superseded; see [ADR-028](028-device-history-transfer.md) and [ADR-030](030-recovery-key-material.md) for active requirements and open gates.

## Costs

- Replaced by the stricter requirement that message history has no server backup at all and requires an online existing device to transfer ([ADR-028](028-device-history-transfer.md)).

## Reversal Trigger

Already superseded by [ADR-028](028-device-history-transfer.md) and [ADR-030](030-recovery-key-material.md).

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-07-25 (`7e4930f8`):** Superseded by [ADR-028](028-device-history-transfer.md) and [ADR-030](030-recovery-key-material.md); register row updated to `Superseded by ADR-028 and ADR-030`.
