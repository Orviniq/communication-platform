# ADR-075: Pairwise-session groups, piece 19 cancellation, and closing the beta MLS track

- **Status:** Accepted; item 5 inline copy-count text withdrawn by [ADR-088](088-group-composer.md) (2026-10-09)
- **Date:** 2026-09-13 (explicitly recorded in register and full section; implemented across PR #53 / `ade9172f`, documented in `cd36012f`)
- **Closes:** [ADR-026](026-candidate-mls-suite.md), [ADR-036](036-beta-mls-track.md), [ADR-037](037-control-transcript.md), [ADR-039](039-two-phase-leave.md), [ADR-040](040-beta-kem-divergence.md), [ADR-041](041-fork-ordering.md), [ADR-044](044-private-deployment.md), [ADR-055](055-initial-artifact.md), [ADR-056](056-abi-evidence.md)
- **Amended by:** [ADR-088](088-group-composer.md) (2026-10-09, withdraws item 5 inline copy-count text)
- **Related:** [ADR-010](010-mls-groups.md), [ADR-011](011-pairwise-wrapping.md), [ADR-019](019-durable-fan-out.md), [ADR-025](025-hybrid-pqxdh.md), [ADR-071](071-published-limits.md), [ADR-076](076-production-signing.md), [ADR-088](088-group-composer.md), [ADR-090](090-group-timeline.md), [ADR-091](091-group-receipts.md), [ADR-096](096-group-moderation.md), server [ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)

## Decision (Position)

Client-side record of server [ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) (accepted 2026-09-03), retiring MLS from the client, cancelling piece 19, removing the closed-beta MLS track and `beta` flavor, and defining pairwise-group UX/delivery rules:

1. **Piece 19 cancelled, not blocked:**
   - The server deleted all three MLS KeyPackage routes (`404` on keypackage upload, count, and claim) and `KEYPACKAGE_BUCKETS`, leaving 28 paths in [backend/openapi.json](../../../../backend/openapi.json) with zero MLS endpoints. Piece 19's five external prerequisites gate nothing and are no longer audited.
2. **Nine closed-beta MLS / private-deployment ADRs closed:**
   - Closed [ADR-026](026-candidate-mls-suite.md) (candidate PQ MLS suite), [ADR-036](036-beta-mls-track.md) (closed-beta MLS track & gate), [ADR-037](037-control-transcript.md) (MLS transport v3 Welcome transcript, replaced by `CPGSV001` pairwise state delivery), [ADR-039](039-two-phase-leave.md) (two-phase leave, replaced by single signed Leave control event), [ADR-040](040-beta-kem-divergence.md) (`mls-rs` KEM divergence), [ADR-041](041-fork-ordering.md) (MLS fork-convergence ordering key, replaced by quarantine without branch selection), [ADR-044](044-private-deployment.md) (Private Experimental beta tier, permit, and `beta` flavor), [ADR-055](055-initial-artifact.md) (core evidence ledger gate), and [ADR-056](056-abi-evidence.md) (per-ABI MLS permit).
3. **Group screens open on every build:**
   - Deleted `groupFeatureAvailabilityProvider` and every gate blocking group screens; signed group control events, `CPGSV001` payloads, and schema 22 store pairwise groups across all builds.
4. **Honest pairwise cost statement in Group details / Group Info:**
   - States that every group message sends one encrypted copy for each device of each member, citing concrete scale: 50 people × 3 devices ≈ 150 copies, up to the server [ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) ceiling of 50 members × 10 devices = 500 copies plus the sender's own devices.
5. **Sent state waits for fan-out completion ([drift_group_repository.dart](../../../lib/features/groups/infrastructure/drift_group_repository.dart)):**
   - Unlike direct chats (which treat partial relay acceptance as accepted), group timelines map partly accepted fan-outs to sending and show a message as sent only when zero copies remain owed (`watchFanoutProgress` over active queued/sending/partially-accepted `outbox_operations`).
   - Devices returned in `stale_devices` leave the owed count and are excluded from subsequent sends; devices in `full_devices` stay in the count until accepted; failed group sends offer retry under current membership rules.
   - *(Amended 2026-10-09 by ADR-088)*: Withdrew drawing the inline copy-count text ("Copies sent: X of Y") and composer replacement while keeping `watchFanoutProgress` and the sent-only-when-fanout-ends rule.

## Rationale

- Keeping five MLS release gates open after the server removed MLS routes left dead requirements and blocked group functionality permanently.
- Because the server stores no group object, roster, or epoch, pairwise PQXDH + Double Ratchet fan-out with signed control chains preserves zero-group-metadata server blindness at the cost of linear per-device ciphertext fan-out, which must be communicated clearly to users.

## Constraints and Open Gates

- **Verification:** Covered by [group_fanout_delivery_test.dart](../../../test/features/groups/application/group_fanout_delivery_test.dart), [pairwise_post_quantum_refusal_test.dart](../../../test/features/pairwise/pairwise_post_quantum_refusal_test.dart), [durable_sync_engine_test.dart](../../../test/features/synchronization/durable_sync_engine_test.dart), [drift_group_repository_test.dart](../../../test/features/groups/infrastructure/drift_group_repository_test.dart), [group_pages_test.dart](../../../test/widget/group_pages_test.dart), and Rust core tests.
- **Open at ADR-075:** No physical-device or live-server group run yet; independent review of the signed group control-event construction ([ADR-017](017-independent-crypto-review.md)) remains open; `AppEnvironment.beta` cleanup left to a separate decision (completed the next day in [ADR-076](076-production-signing.md)).
- **Historical references:** Deleted MLS profile `frontend/docs/mls-profile.md` is preserved in history before commit `4525d3f0`; on-device beta MLS run records live in [archive/beta-mls-core/README.md](../../archive/beta-mls-core/README.md).

## Costs

- Group send bandwidth and latency scale linearly with total recipient devices (up to 500 recipient devices plus own devices).
- No group-level forward secrecy or post-compromise recovery beyond each pairwise Double Ratchet channel.

## Reversal Trigger

Reopen only if server architecture reintroduces a group-key or MLS delivery service, or if client group fan-out UX/delivery rules change (subsequently amended by ADR-088, ADR-090, ADR-091, and ADR-096).

## History, Amendments, and Supersession

- **2026-09-13 (`cd36012f` / PR #53 `ade9172f`):** Recorded and implemented ADR-075 (`Accepted`), deleting the beta MLS core/flavor/KeyPackage schema (schemas 20–21) and shipping pairwise-session groups (schema 22).
- **2026-09-14 (`04317e36` / [ADR-076](076-production-signing.md)):** Deleted leftover `AppEnvironment.beta` and updated `DeploymentDisclosure.distributed` (`pairwiseGroups`).
- **2026-10-09 (`1446a83` / ADR-088):** Kept the group composer mounted during sends and removed the inline copy-count text while preserving `watchFanoutProgress` and sent-on-completion semantics.
