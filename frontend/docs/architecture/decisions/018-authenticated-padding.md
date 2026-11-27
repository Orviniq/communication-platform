# ADR-018: Padding is authenticated inside each pairwise transport envelope

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-008](008-canonical-cbor.md), [ADR-011](011-pairwise-wrapping.md), [ADR-025](025-hybrid-pqxdh.md)

## Decision (Position)

Padding is placed **inside** the authenticated plaintext (`TransportPlaintextV1`) of each pairwise Double Ratchet envelope and covered by the envelope's AEAD tag, rather than appended outside authentication to hit backend size buckets.

## Rationale

Prevents ambiguous, malleable, or unprotected trailing padding bytes and padding-oracle/truncation tampering while still fitting the backend's allowed envelope size buckets.

## Constraints and Open Gates

- Defined in [Application-message protocol](../../message-protocol.md#layering) and [Pairwise transport v1](../../pairwise-transport-v1.md).
- Outer frame size must match allowed backend buckets; malformed or non-canonical inner padding fails closed during Rust core decryption ([Pairwise review readiness](../../pairwise-review-readiness.md)).
- Open gate: Independent cryptographic review of `TransportPlaintextV1` and padding validation remains open under [ADR-017](017-independent-crypto-review.md).

## Costs

- Padding overhead is encrypted and authenticated per recipient envelope, slightly increasing per-envelope plaintext size inside the bucket.

## Reversal Trigger

Only if a new transport protocol version changes framing/padding format with equivalent or stronger authentication guarantees.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-07-29 (`d0092ee9`):** Implemented in `native/crypto_core/src/pairwise.rs` and frozen in [Pairwise transport v1](../../pairwise-transport-v1.md).
- No supersession.
