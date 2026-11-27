# ADR-039: Two-phase MLS leave — announcement then owner Remove commit

- **Status:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13)
- **Date:** 2026-08-16 (explicitly recorded in register; committed in `91ba0f8e`, 2026-08-17; closed `2026-09-13`)
- **Closed by:** [ADR-075](075-pairwise-groups.md) (2026-09-13), following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- **Related:** [ADR-036](036-beta-mls-track.md), [ADR-037](037-control-transcript.md), [ADR-038](038-fork-convergence.md)

## Decision (Position)

Originally decided that leaving a closed-beta MLS group is a **two-phase departure**:
1. **Phase 1 (non-membership announcement):** `Leave` is classified as non-membership in both `group_model.dart` and `mls_beta.rs`. The departing member signs a `Leave` at the current epoch with no MLS Commit; devices project the member to `left` (departure announced, eviction pending) and the leaver's local lifecycle moves to `GroupLifecycle.left`, while the leaver remains cryptographically present in that epoch.
2. **Phase 2 (owner `Remove` commit):** The sole active owner (`canLeave` forbids an owner from leaving while other active members remain) commits the MLS `Remove` that evicts `left` leaves and rotates the epoch, moving them to `removed`. `GroupPendingEvictionService` executed post-inbox, evicting at most one member per group per pass and retrying concurrent-control conflicts. A sole owner leaving needed no eviction commit.

**Closure:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13). With MLS replaced by pairwise Double Ratchet fan-out, there is no epoch secret or Commit: leaving is a single signed control event that removes the leaver ([ADR-075](075-pairwise-groups.md), updated in [ADR-096](096-group-moderation.md) for group leave and moderation).

## Rationale

Original rationale: RFC 9420 §12.4 forbids a committer from removing itself ("A Commit MUST NOT remove the committer"), which previously clashed with classifying `Leave` as membership-changing and requiring a commit hash; delegating Phase 2 eviction solely to the unique active owner also avoided concurrent eviction commits and forks.

Why closed: no MLS epoch or Commit exists in pairwise groups.

## Constraints and Open Gates

- **Closed:** `mls_beta.rs` and `GroupPendingEvictionService` (`frontend/lib/features/groups/application/group_pending_eviction_service.dart`, introduced in `91ba0f8e`) were deleted when closing beta MLS.
- Pairwise group leaving and moderation rules are now governed by ADR-075 and ADR-096 ([UI specification](../../ui-specification.md)).

## Costs

- While active, a departed member remained cryptographically capable of reading the current epoch until the active owner came online and committed the `Remove`, and required `GroupPendingEvictionService` post-inbox sweeps.

## Reversal Trigger

Already closed by ADR-075.

## History, Amendments, and Supersession

- **2026-08-16 (committed 2026-08-17 in `91ba0f8e`):** Original decision recorded (`Accepted`).
- **2026-09-13 (`cd36012f` / ADR-075):** Closed (`Closed by ADR-075 (2026-09-13)`).
