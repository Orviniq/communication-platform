# ADR-026: Candidate PQ MLS ciphersuite selection and release gating

- **Status:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13)
- **Date:** Undocumented in the ADR register (introduced in commit `7e4930f8`, 2026-07-25; refined `ef47bc6a` on 2026-07-27, `7e550a63` on 2026-07-28, and `91ba0f8e` / presentation clarification `2026-08-16`; closed `2026-09-13`)
- **Closed by:** [ADR-075](075-pairwise-groups.md) (2026-09-13), following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- **Related:** [ADR-010](010-mls-groups.md), [ADR-017](017-independent-crypto-review.md), [ADR-033](033-android-release-target.md), [ADR-036](036-beta-mls-track.md)

## Decision (Position)

Originally selected the IETF candidate suite **`MLS_128_MLKEM768X25519_AES256GCM_SHA384_Ed25519`** (`TBD2`) for future production MLS groups, while forbidding the project from assigning a production ciphersuite identifier locally.

Production release of MLS groups remained gated on:
1. a stable published specification and registry assignment for every primitive in the mapping (tracked separately from the MLS suite value);
2. an IANA-assigned MLS ciphersuite value (`TBD2` was unassigned);
3. maintained OpenMLS/provider support;
4. Android interoperability and upstream vectors; and
5. independent cryptographic review ([ADR-017](017-independent-crypto-review.md)), with Web interoperability moved to a post-v1 Web release gate under [ADR-033](033-android-release-target.md).

**Closure:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13) because [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) deleted MLS from the server and replaced group messaging with pairwise Double Ratchet fan-out. No MLS ciphersuite is used at all.

## Rationale

Original rationale: align hybrid ML-KEM-768/X25519 and Ed25519 with the existing protocol without inventing an unstandardized production ciphersuite ID.

Why closed: with the backend serving no KeyPackages or MLS state, Piece 19's five external prerequisites became irrelevant and Piece 19 was cancelled rather than blocked (ADR-075).

## Constraints and Open Gates

- **Closed:** All MLS ciphersuite gates are closed/obsolete; `frontend/docs/mls-profile.md` (which held the candidate suite profile and evidence table) was deleted in commit `4525d3f` (historical snapshot preserved at commit `788453b430f34c52c2063ef67b8aa5e4f8fa935d`).

## Costs

- While active, stalled production MLS groups on external IETF/IANA/OpenMLS progress and necessitated the separate closed-beta Private Use track ([ADR-036](036-beta-mls-track.md)).

## Reversal Trigger

Already closed by ADR-075.

## History, Amendments, and Supersession

- **2026-07-25 (`7e4930f8`):** Original generic release gate ("reviewed interoperable PQ MLS ciphersuite").
- **2026-07-27 (`ef47bc6a`):** Named IETF `MLS_128_MLKEM768X25519_AES256GCM_SHA384_Ed25519` and prohibited local production ID assignment.
- **2026-07-28 (`7e550a63`):** Scoped v1 gate to Android interoperability; moved Web interoperability to post-v1 ([ADR-033](033-android-release-target.md)).
- **2026-08-16 (`91ba0f8e`):** Split primitive-mapping registry assignment and MLS ciphersuite IANA assignment into separate gates because different registries govern them on independent schedules.
- **2026-09-13 (`cd36012f` / ADR-075):** Closed (`Closed by ADR-075 (2026-09-13)`).
