# ADR-037: Closed-beta MLS transport v3 carries authenticated control transcript; v2 beta groups recreated

- **Status:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13)
- **Date:** 2026-08-09 (explicitly recorded in register; committed in `91ba0f8e`, 2026-08-17; closed `2026-09-13`)
- **Closed by:** [ADR-075](075-pairwise-groups.md) (2026-09-13), following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- **Related:** [ADR-036](036-beta-mls-track.md), [ADR-038](038-fork-convergence.md), [ADR-039](039-two-phase-leave.md)

## Decision (Position)

Originally decided that closed-beta MLS transport v3 carries the **complete authenticated control transcript** (capped at 512 entries) needed for a later joiner or re-added member to authenticate the product roster before joining a Welcome in one atomic commit, and that v2 beta groups are recreated rather than silently upgraded.

1. Every prior deterministic control projection bound to its exact signed payload and signer Authentication Service proof was replayed from initial state, and the Rust-returned MLS `BasicCredential` roster had to match the reconstructed product roster before committing.
2. Absence, disagreement, replay, authorization failure, or malformed credentials failed closed.
3. V2 beta state and queued objects were treated as disposable closed-beta data ([ADR-036](036-beta-mls-track.md)).

**Closure:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13). There is no MLS Welcome or MLS credential roster; new/rejoined group members receive and verify the signed group control transcript as a `CPGSV001` payload directly over pairwise Double Ratchet envelopes ([Cryptographic protocol](../../contracts/CRYPTO.md#groups), [Local data model](../LOCAL-DATA.md)).

## Rationale

Original rationale: a newly invited or re-added MLS member cannot authenticate the product-level roster from the current Invite alone without replaying the signed control chain.

Why closed: MLS and Welcome messages were removed under [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) and ADR-075.

## Constraints and Open Gates

- **Closed:** Transport v3 and MLS `BasicCredential` cross-checks left the codebase with `mls_beta.rs` and `native_beta_group_mls.dart` (introduced in `91ba0f8e`, deleted under ADR-075).
- The underlying signed control-chain concept (`group_control_events` verified against authenticated device logs) survives in `CPGSV001` pairwise groups ([Application-message protocol](../../contracts/MESSAGES.md)).

## Costs

- While active, capped transcript replay at 512 entries and required recreating v2 closed-beta groups.

## Reversal Trigger

Already closed by ADR-075.

## History, Amendments, and Supersession

- **2026-08-09 (committed 2026-08-17 in `91ba0f8e`):** Original decision recorded (`Accepted`).
- **2026-09-13 (`cd36012f` / ADR-075):** Closed (`Closed by ADR-075 (2026-09-13)`).
