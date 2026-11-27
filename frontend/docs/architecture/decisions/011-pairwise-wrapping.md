# ADR-011: Per-recipient pairwise transport wrapping

- **Status:** Accepted in register (MLS motivation retired by ADR-075; per-recipient pairwise wrapping remains the sole transport for direct, group, and room payloads)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-010](010-mls-groups.md), [ADR-018](018-authenticated-padding.md), [ADR-019](019-durable-fan-out.md), [ADR-025](025-hybrid-pqxdh.md)

## Decision (Position)

Every outbound message and control payload is **independently encrypted and wrapped per recipient device** over its own pairwise transport session, rather than sending shared ciphertext across recipients.

## Rationale

Originally adopted so identical MLS ciphertext could not link a sender's recipient set at rest on the untrusted relay server.

After MLS was retired by [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) and ADR-075 (2026-09-13), per-recipient pairwise Double Ratchet wrapping remains the active transport for **every** durable payload (direct messages, Saved Messages to other own devices, group messages/control events, and voice-room control events), ensuring the server never sees shared ciphertext across recipients, never learns group membership, and never stores a group roster.

## Constraints and Open Gates

- Specified in [Pairwise transport v1](../../pairwise-transport-v1.md) and [Application-message protocol](../../message-protocol.md).
- Every envelope uses its own pairwise Double Ratchet session ([ADR-025](025-hybrid-pqxdh.md)) and its own authenticated padding ([ADR-018](018-authenticated-padding.md)).
- Open gates: Independent review of the pairwise transport and group fan-out remains open under [ADR-017](017-independent-crypto-review.md).

## Costs

- O(devices) encryption operations and server envelope rows per group/multi-device send (up to 500 peer device copies plus sender's other devices under the 50-member × 10-device cap, ADR-075).

## Reversal Trigger

If fan-out volume beyond ~50 group members requires a shared-ciphertext scheme such as sender keys (server ADR-0001).

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`), phrased around wrapping MLS ciphertext.
- **2026-09-13 (ADR-075):** With MLS retired, pairwise Double Ratchet encryption directly carries group and room payloads per recipient device; the register row remains `Accepted` with its original MLS-era reason text.
