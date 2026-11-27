# ADR-019: Durable per-device fan-out in deterministic batches of at most 256

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-011](011-pairwise-wrapping.md), [ADR-025](025-hybrid-pqxdh.md)

## Decision (Position)

Logical message fan-out uses **durable per-device target rows** in `outbox_operations` and transmits them in **deterministic batches of at most 256 targets** (sorted by recipient device UUID bytes).

1. A logical send commits an owed preparation (`pending_send_preparations`) alongside the local message projection, then seals exact per-recipient ciphertext into durable target rows before transmission.
2. Each HTTP 202 send batch covers at most 256 target rows; accepted targets are marked `accepted`, `stale_devices` are retired and their sessions invalidated, `full_devices` are retained for retry, and ambiguous transport retries resend the persisted ciphertext without advancing the Double Ratchet again.
3. A logical send becomes `accepted` only once all eligible targets are accepted, stale, or removed by refreshed eligibility.

## Rationale

Matches the backend's 256-target batch limit on `POST /api/v1/envelopes`, supports partial batch progress across large multi-device groups (up to 500 peer devices), and guarantees crash-safe, ratchet-safe retries without re-encrypting or double-advancing ratchets.

## Constraints and Open Gates

- Defined in [Synchronization engine](../SYNC.md#outbox) and [Pairwise transport v1](../../contracts/PAIRWISE-V1.md).
- Under ADR-060 and ADR-061, send preparation runs inside the sync cycle (`pending_send_preparations`) immediately before the outbox pass, and outbox drains before inbox so a stuck inbound envelope cannot starve user sends.
- Under ADR-075 and ADR-088, group sends map partial fan-out completion to `sending` (never `sent` early) without rendering numeric fraction text beside the status mark.
- Open gates: Independent review ([ADR-017](017-independent-crypto-review.md)) and representative multi-device group scale testing.

## Costs

- Stores encrypted per-device ciphertext blobs in Drift until accepted/retired, using SQLCipher storage and transactional writes.
- Adds preparation and batch-tracking state transitions (`queued -> preparing -> ready -> sending -> accepted` / `retry_wait` / `blocked` / `permanently_failed`).

## Reversal Trigger

If the backend batch limit changes or if group messaging moves from pairwise fan-out to a shared-ciphertext mechanism ([server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)).

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-08-26 – 2026-08-27 (ADR-060, ADR-061):** Refined cycle ordering and split `pending_send_preparations` from `outbox_operations` so messages appear locally immediately and seal in the cycle.
- **2026-09-13 (ADR-075) & 2026-10-09 (ADR-088):** Applied fan-out completion semantics to pairwise groups (ceiling 500 peer device copies plus own devices).
- No supersession.
