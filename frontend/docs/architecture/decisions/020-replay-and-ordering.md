# ADR-020: Event IDs and ratchet state reject replay; sender counters do not reject delayed messages

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-008](008-canonical-cbor.md), [ADR-009](009-pairwise-ratchet.md), [ADR-025](025-hybrid-pqxdh.md)

## Decision (Position)

1. **Application deduplication** uses durable `event_id` uniqueness, and **cryptographic replay protection** uses Double Ratchet message numbers with bounded skipped-key storage (2,000 skipped keys per device-pair session; 20,000 across the account).
2. **`sender_counter` does not reject delayed or out-of-order messages** simply for arriving with a lower counter than a previously observed event. Instead, within the retained event horizon, reusing the same `(sender_device_id, sender_counter)` with a *different* `event_id` is quarantined as sender-state rollback, while reuse with the *same* `event_id` is an idempotent duplicate.

## Rationale

Preserves legitimate out-of-order delivery across independent per-device paths, offline/reconnected sessions, and retries without losing rollback or replay detection.

## Constraints and Open Gates

- Defined in [Application-message protocol](../../message-protocol.md#common-logical-event-header) and [Cryptographic protocol](../../cryptographic-protocol.md#direct-messages-and-per-device-channels).
- Indexed via `application_events_sender_counter` on `application_events (sender_device_id, sender_counter)` ([Local data model](../LOCAL-DATA.md#indexes)).
- Messages arriving beyond the 2,000/20,000 skipped-key bounds enter the authenticated session-repair path rather than allocating unbounded memory or relaxing replay checks.
- Open gate: Independent cryptographic review under [ADR-017](017-independent-crypto-review.md).

## Costs

- Requires maintaining durable `event_id` and `(sender_device_id, sender_counter)` uniqueness indexes and bounded skipped-key state in Rust/Drift.
- Display ordering uses clamped `created_ms` / ordering keys rather than assuming `sender_counter` equals global conversation order.

## Reversal Trigger

If a protocol revision changes replay or rollback semantics or replaces bounded skipped-key storage.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-07-29 (`d0092ee9`):** Implemented in `native/crypto_core/src/pairwise.rs` and [Pairwise transport v1](../../pairwise-transport-v1.md).
- No supersession.
