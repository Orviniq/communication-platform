# ADR-010: RFC 9420 MLS for group membership/key state

- **Status:** Accepted in register (status gap: group MLS replaced and retired by [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) and [ADR-075](075-pairwise-groups.md) on 2026-09-13)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-011](011-pairwise-wrapping.md), [ADR-026](026-candidate-mls-suite.md), [ADR-036](036-beta-mls-track.md), [ADR-037](037-control-transcript.md), [ADR-038](038-fork-convergence.md), [ADR-039](039-two-phase-leave.md)

## Decision (Position)

Originally decided to use **RFC 9420 Messaging Layer Security (MLS)** for group membership and key state management.

**Current reality (status gap):** While the legacy ADR register table in [decisions.md](../../decisions.md) (see [index](README.md)) left this row's status column as `Accepted`, MLS is **no longer used anywhere in the client or server**. Under [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) (accepted 2026-09-03) and [ADR-075](075-pairwise-groups.md) (accepted 2026-09-13), the backend removed all key-package endpoints and MLS state, and the client replaced MLS with **pairwise Double Ratchet fan-out and client-signed group control events** (`CPGSV001`).

## Rationale

Original rationale: standardized asynchronous group forward secrecy and post-compromise security (FS/PCS), matching the original backend KeyPackage endpoints.

Why retired in practice: [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) determined that server-held MLS group/key-package posture conflicted with the threat model at the project's scale band (at most 50 members per group, 10 devices per member), and ADR-075 cancelled Piece 19 and removed the closed-beta MLS core (`native/crypto_core/src/mls_beta.rs`, `frontend/docs/mls-profile.md` removed in `4525d3f`).

## Constraints and Open Gates

- **Status discrepancy recorded as a gap:** ADR-075 explicitly closed ADR-026, ADR-036, ADR-037, ADR-039, ADR-040, ADR-041, ADR-044, ADR-055, and ADR-056, but did not update the `Accepted` status on `ADR-010` in the register table.
- [crypto_core_boundary_test.dart](../../../test/architecture/crypto_core_boundary_test.dart) and `tool/verify_release_apk.sh` actively forbid the historical `cp_crypto_v1_beta_mls_operation` symbol from shipping.
- Production group behavior is governed by [Cryptographic protocol](../../cryptographic-protocol.md#groups) and [Frontend status](../../STATUS.md#platform-identity-and-content), with independent review of the pairwise signed group-state construction still an open gate under [ADR-017](017-independent-crypto-review.md).

## Costs

- Original cost: draft PQ MLS ciphersuite instability ([ADR-026](026-candidate-mls-suite.md)), closed-beta Private Use isolation ([ADR-036](036-beta-mls-track.md)), and KeyPackage lifecycle complexity.
- Replacement cost (ADR-075): O(devices) ciphertext per group send (up to 500 recipient-device copies plus sender's other devices), with no shared group key rotation on member removal (removed members receive no future messages).

## Reversal Trigger

Under [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md), moving away from pairwise group fan-out would only trigger if groups exceed ~50 members or fan-out dominates send latency — in which case sender keys, not MLS, are the named first step.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-07-25 – 2026-08-17:** Refined for PQ MLS gating ([ADR-026](026-candidate-mls-suite.md)) and implemented as an isolated closed-beta track ([ADR-036](036-beta-mls-track.md)–[ADR-039](039-two-phase-leave.md) in `91ba0f8e`).
- **2026-09-13 (`4525d3f`, `cd36012f` / ADR-075):** Server removed MLS and KeyPackage endpoints; client removed the MLS core and profile (`frontend/docs/mls-profile.md` before `4525d3f`, archived run records in [beta-mls-core](../../archive/beta-mls-core/README.md)); register row for ADR-010 was not explicitly updated to `Closed`.
