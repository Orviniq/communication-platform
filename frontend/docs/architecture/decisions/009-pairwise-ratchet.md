# ADR-009: X3DH + Double Ratchet for device-pair channels

- **Status:** Superseded by [ADR-025](025-hybrid-pqxdh.md) (2026-07-25)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Superseded by:** [ADR-025](025-hybrid-pqxdh.md)
- **Related:** [ADR-018](018-authenticated-padding.md), [ADR-020](020-replay-and-ordering.md), [ADR-034](034-authenticated-pq-contribution.md)

## Decision (Position)

Originally selected classical **X3DH + Double Ratchet** for device-pair encrypted channels.

Superseded immediately before implementation by [ADR-025](025-hybrid-pqxdh.md): every device-pair session MUST be established with **hybrid X25519 + ML-KEM-768 PQXDH** plus Double Ratchet, with classical-only session creation forbidden.

## Rationale

Original rationale: matched the initial prekey model and asynchronous direct-messaging requirements.

Why superseded: the binding backend client contract (`CLIENT_CONTRACT.md`) requires hybrid post-quantum key agreement (PQXDH) to protect recorded ciphertext against harvest-now-decrypt-later adversaries.

## Constraints and Open Gates

- Classical-only session initiation is prohibited and fails closed (`pairwise-transport-v1.md`, [Cryptographic protocol](../../cryptographic-protocol.md)).
- Double Ratchet itself remains in use for ongoing pairwise messaging after hybrid PQXDH establishment.

## Costs

- Retained only as historical baseline; hybrid PQXDH adds ML-KEM-768 prekeys, encapsulation ciphertexts in initial messages, and 7-day signed PQ prekey rotation ([ADR-035](035-prekey-rotation.md)).

## Reversal Trigger

Already superseded by [ADR-025](025-hybrid-pqxdh.md).

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-07-25 (`7e4930f8`):** Superseded by [ADR-025](025-hybrid-pqxdh.md); register row updated to `Superseded by ADR-025`.
