# ADR-041: Same-revision fork ordering by ungrindable precedence, authority, and signer identity

- **Status:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13)
- **Date:** 2026-08-17 (explicitly recorded in register and full section; committed in `b41ad485`; closed `2026-09-13`)
- **Supersedes:** [ADR-038](038-fork-convergence.md)
- **Closed by:** [ADR-075](075-pairwise-groups.md) (2026-09-13), following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- **Related:** [ADR-036](036-beta-mls-track.md), [ADR-037](037-control-transcript.md), [ADR-039](039-two-phase-leave.md), [ADR-044](044-private-deployment.md)

## Decision (Position)

Originally decided to replace [ADR-038](038-fork-convergence.md)'s hash-only same-revision control fork tie-break with a four-key tuple (smallest first) whose deciding inputs a branch author cannot vary:

1. **`GroupControlPrecedence` of the operation:** `eviction` (`Remove`), then `authority` (`ChangeRole`, `TransferOwnership`, `UpdatePolicies`, `Create`), then `membership` (`Invite`, `Leave`), then `descriptive` (`UpdateMetadata`).
2. **Signer's role in the reconstructed shared parent:** `owner`, then `admin`, then `member` (refusing to place a signer that is not an active member of the shared parent, failing closed rather than ordering on a branch's own claims).
3. **Signer's authenticated identity:** `user_id`, then `device_id`.
4. **`control_state_hash`:** Retained solely as a final tie-breaker between two equivocating branches signed by the same device at the same revision.

Sibling authentication, replay against the reconstructed parent, `GroupControlStateMachine` authorization, and recovery of a superseded branch via fork-quarantine plus remove/re-add remained unchanged, with no wire-format, schema, or state-format change (`BETA_STATE_FORMAT_VERSION` and transport v3 unchanged). Opened no production gate.

**Closure:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13) after [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) retired MLS. Under pairwise Double Ratchet groups, two signed control events at the same revision place the group directly in `forkQuarantined` without automated winner selection ([Cryptographic protocol](../../cryptographic-protocol.md#groups)).

## Rationale

Original rationale:
- **Confirmed hash-grinding vulnerability in ADR-038:** `control_state_hash` (`SHA-256("chat:v1:group-control-state" || frame(canonical) || frame(signature))`) hashed author-chosen fields — an unbound 16-byte `event_id` and unvalidated `u64` `created_ms` — under deterministic RFC 8032 `ed25519-dalek` 3.0.0 signatures. Measured on 2026-08-17 on the shipped x86-64 release signing path: 1,000 candidate branches in 40.8 ms (~24,500 trials/s/core), needing 9 trials to beat one known rival and ~99.996% probability against an unknown rival in one second.
- **Exploitable against eviction:** Any member facing eviction (an admin with `UpdateMetadata`/`Invite`/`Leave`/member-`Remove`, or a member with `Leave` or `Invite` under `allMembers`) could grind a lower hash in under a millisecond and displace the evicting owner's `Remove`, quarantining the owner instead and keeping the epoch secret (repeatable indefinitely for admins and `allMembers` members).
- **Why alternatives failed:**
  - *Binding `event_id` to parent fields:* left `created_ms` and payload text grindable.
  - *Ordering by an epoch-secret PRF:* every member holds the epoch secret and can still grind.
  - *Preferring branches carrying an MLS Commit:* `Invite` carries a Commit too, handing displacement back to members under `allMembers`.
  - *Ordering by signer identity alone:* grindable at account registration and blind to operation precedence (a low-ID member's metadata edit could beat a high-ID owner's eviction).
- Precedence + parent authority + authenticated signer ID kept convergence total, deterministic, server-independent, and free of extra round trips.

Why closed: pairwise groups have no MLS epoch lock-in and treat any same-revision fork as `forkQuarantined` rather than electing a winning branch.

## Constraints and Open Gates

- **Closed:** Historical Rust implementation (`frontend/native/crypto_core/src/mls_beta.rs`), test `an_author_grinds_the_control_state_hash_below_a_known_rival`, and Dart fork-convergence files were removed or superseded when beta MLS was retired under ADR-075.
- Production group gates remained closed throughout ADR-041's lifetime.

## Costs

- Honest concurrent branches of identical precedence and parent authority converged on the lower authenticated signer ID rather than the lower hash; superseded branches still required fork-quarantine and remove/re-add because applied MLS commits could not be rolled back.

## Reversal Trigger

Original trigger: reopen if a future control operation could not be placed in the four precedence classes, or if a serializing delivery service removed the need for a client-side tie-break.

Current state: already closed by ADR-075 (2026-09-13).

## History, Amendments, and Supersession

- **2026-08-17 (`b41ad485`):** Recorded ADR-041 (`Accepted`), superseding [ADR-038](038-fork-convergence.md).
- **2026-09-13 (`cd36012f` / ADR-075):** Closed (`Closed by ADR-075 (2026-09-13)`).
