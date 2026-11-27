# ADR-036: Build draft PQ MLS as an isolated closed-beta track while keeping the production gate closed

- **Status:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13)
- **Date:** 2026-08-02 (explicitly recorded in register; fact correction 2026-08-16; committed in `91ba0f8e`, 2026-08-17; closed `2026-09-13`)
- **Closed by:** [ADR-075](075-pairwise-groups.md) (2026-09-13), following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- **Related:** [ADR-010](010-mls-groups.md), [ADR-017](017-independent-crypto-review.md), [ADR-026](026-candidate-mls-suite.md), [ADR-037](037-control-transcript.md), [ADR-038](038-fork-convergence.md), [ADR-039](039-two-phase-leave.md)

## Decision (Position)

Originally decided to build draft PQ MLS as a **real, isolated closed-beta track** while keeping the production group gate closed:
1. Beta integrated the closest available maintained provider mapping (`mls-rs` / `mls-rs-crypto-hpke` 0.21.0) behind a source-only beta permit (`GroupProductionGate`), using an MLS Private Use identifier (`0xFE4C`), a distinct Android application ID (`com.example.communication_platform.beta` -> `dev.nimashadloo.chat.beta` -> `com.orviniq.chat.beta`), separate provisioning prefix, separate Cargo feature (`beta-pq-mls`), and **disposable group state** (reinitialized, never silently migrated, when the draft or identifier changes).
2. **2026-08-16 fact correction (decision unchanged):** Verification against vendored sources established that `mls-rs-crypto-hpke` 0.21.0 delivered draft-06 `TBD2`'s signature, AEAD, KDF, and hash choices, **not** its KEM `0x647a` (shipping a pre-standard X-Wing variant with an unassigned HPKE `kem_id`). Beta groups were therefore hybrid ML-KEM-768/X25519 but not `TBD2`-conformant or `TBD2` interoperability evidence.
3. Production stayed on `UnsupportedGroupMls` until all seven production gates passed (six before the 2026-08-16 split of primitive mapping vs. MLS suite ID in [ADR-026](026-candidate-mls-suite.md)).

**Closure:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13) after [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) retired MLS. The closed-beta MLS core, permit, and `beta` track were deleted, and groups now run on pairwise Double Ratchet sessions with no disposable-state rule.

## Rationale

Original rationale: allow end-to-end group lifecycle and backend KeyPackage/pairwise integration testing during closed beta without falsifying [ADR-017](017-independent-crypto-review.md)/[ADR-026](026-candidate-mls-suite.md) or introducing a classical fallback or project-local cryptographic fork.

Why closed: [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) removed MLS from the system entirely.

## Constraints and Open Gates

- **Closed:** Historical source artifacts — `frontend/native/crypto_core/src/mls_beta.rs`, `frontend/lib/main_beta.dart`, `frontend/lib/features/groups/infrastructure/native_beta_group_mls.dart`, `frontend/lib/app/config/group_production_gate.dart`, and `frontend/docs/mls-profile.md` (before commit `4525d3f` / snapshot `788453b430f34c52c2063ef67b8aa5e4f8fa935d`) — have been removed.
- Historical on-device beta run records remain archived in [frontend/docs/archive/beta-mls-core/README.md](../../archive/beta-mls-core/README.md), and the defect report on `mls-rs` remains at [mls-rs-hybrid-kem-defect-report.md](../../upstream/mls-rs-hybrid-kem-defect-report.md).
- [crypto_core_boundary_test.dart](../../../test/architecture/crypto_core_boundary_test.dart) asserts that `cp_crypto_v1_beta_mls_operation` and `beta-pq-mls` do not exist in release builds.

## Costs

- While active, required maintaining a dual flavor/Cargo build, a separate beta gate ledger (ADR-055, ADR-056), and user disclosures for disposable group state (ADR-045, removed from `DeploymentDisclosure.pairwiseGroups` at revision 9).

## Reversal Trigger

Already closed by ADR-075.

## History, Amendments, and Supersession

- **2026-08-02 (committed 2026-08-17 in `91ba0f8e`):** Original decision recorded (`Accepted`).
- **2026-08-16 (`91ba0f8e`):** Recorded X-Wing/`0x647a` fact correction and 6-to-7 production gate split.
- **2026-08-17 – 2026-08-24:** Reinforced by ADR-040 (refusing custom KEM fork), ADR-044, ADR-045, ADR-055, and ADR-056.
- **2026-09-13 (`4525d3f`, `cd36012f` / ADR-075):** Closed and deleted; disclosure rewritten at revision 9 ([deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart)).
