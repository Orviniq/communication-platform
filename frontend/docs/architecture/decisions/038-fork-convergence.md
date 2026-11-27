# ADR-038: Same-revision control forks converge on smallest control state hash

- **Status:** Superseded by ADR-041 (2026-08-17); ADR-041 was subsequently closed by ADR-075 (2026-09-13)
- **Date:** 2026-08-16 (explicitly recorded in register; committed in `91ba0f8e`, 2026-08-17; superseded 2026-08-17 in `b41ad485`)
- **Superseded by:** ADR-041 (2026-08-17), later closed by ADR-075 (2026-09-13)
- **Related:** [ADR-036](036-beta-mls-track.md), [ADR-037](037-control-transcript.md), [ADR-039](039-two-phase-leave.md)

## Decision (Position)

Originally decided that same-revision closed-beta MLS control forks converge deterministically on the **lexicographically smallest `control_state_hash`** (after authenticating, replaying against the shared parent, and authorizing the sibling), and a superseded local branch enters fork-quarantine and recovers via remove/re-add rather than rolling back applied MLS epoch secrets.

**Superseded immediately on 2026-08-17 by ADR-041 (`b41ad485`):** Because `control_state_hash` hashed author-chosen fields (free 16-byte `event_id` and `created_ms`) under deterministic Ed25519 (~24,500 trials/sec/core), a member facing eviction could grind a lower hash in under a millisecond and quarantine the owner. ADR-041 replaced the tie-break with an ungrindable ordering key (operation precedence class, signer role in shared parent, authenticated user/device ID, and hash only last).

**Subsequently closed (ADR-075, 2026-09-13):** With MLS retired, pairwise groups do not pick a winning branch on forks at all; a same-revision conflict moves the group to `forkQuarantined` without selecting a winner.

## Rationale

Original rationale: RFC 9420 assumes a serializing Delivery Service, whereas this backend is an untrusted relay with per-recipient pairwise delivery and no server-imposed total order, and applied MLS epochs cannot be rolled back once old secrets are erased.

Why superseded: the hash-only tie-break was trivially grindable by a malicious participant (`b41ad485` / ADR-041).

## Constraints and Open Gates

- Superseded by ADR-041 and closed with the rest of closed-beta MLS by ADR-075.
- Historical test/implementation references existed in `group_fork_convergence_test.dart` / `mls_beta.rs` (from `91ba0f8e`).

## Costs

- Hash-only convergence introduced a concrete hash-grinding vulnerability against eviction, caught and fixed the next day in ADR-041.

## Reversal Trigger

Already superseded by ADR-041 (2026-08-17) and closed by ADR-075 (2026-09-13).

## History, Amendments, and Supersession

- **2026-08-16 (committed 2026-08-17 in `91ba0f8e`):** Original decision recorded (`Accepted`).
- **2026-08-17 (`b41ad485` / ADR-041):** Superseded by ungrindable precedence/authority/identity fork ordering (`Superseded by ADR-041 (2026-08-17)`).
- **2026-09-13 (`cd36012f` / ADR-075):** ADR-041 closed; pairwise groups quarantine forks without automated branch selection.
