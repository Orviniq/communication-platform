# ADR-025: Hybrid X25519 + ML-KEM-768 PQXDH establishes every DM session

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `7e4930f8`, 2026-07-25)
- **Supersedes:** [ADR-009](009-pairwise-ratchet.md)
- **Related:** [ADR-011](011-pairwise-wrapping.md), [ADR-017](017-independent-crypto-review.md), [ADR-018](018-authenticated-padding.md), [ADR-020](020-replay-and-ordering.md), [ADR-034](034-authenticated-pq-contribution.md), [ADR-035](035-prekey-rotation.md)

## Decision (Position)

Every device-pair Double Ratchet session MUST be established using **hybrid X25519 + ML-KEM-768 PQXDH** (`Pairwise transport v1`: suite `0x01`, HKDF-SHA256, XChaCha20-Poly1305 AEAD), and **silent downgrade or classical-only session initiation is forbidden**.

1. Claimed recipient bundles missing valid signed ML-KEM-768 prekey material (`pq_spk_id`, `pq_spk_pub`, and signature) or containing partial/malformed PQ fields fail closed (`"post-quantum keys unavailable"`).
2. The sender-hidden initial header derives its sealing key (`chat:v1:pqxdh-sealed-sender`) from recipient-derivable DH3, optional DH4, `SS_S`, and optional `SS_O` so server-visible frames never expose sender identity or device IDs.
3. Since [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) and ADR-075 (2026-09-13), this same pairwise hybrid PQXDH + Double Ratchet transport carries group and voice-room payloads as well as direct messages and Saved Messages.

## Rationale

Protects recorded encrypted sessions against harvest-now-decrypt-later quantum attacks and satisfies the binding backend client contract (`docs/client/CLIENT_CONTRACT.md`).

## Constraints and Open Gates

- Frozen in [Pairwise transport v1](../../pairwise-transport-v1.md) and implemented in `native/crypto_core/src/pairwise.rs` using `mlkem-native` v1.2.0 (`0ba906cb14b1c241476134d7403a811b382ca498`), `x25519-dalek` `=3.0.0`, `ed25519-dalek` `=3.0.0`, `chacha20poly1305` `=0.11.0`, and `hkdf`/`hmac`/`sha2`.
- Prekey signing and additive unsigned `pq_otpk` mixing are constrained by [ADR-034](034-authenticated-pq-contribution.md); 7-day signed prekey rotation continuity is constrained by [ADR-035](035-prekey-rotation.md).
- Open gate: Independent cryptographic review of `pairwise-transport-v1` and `pairwise.rs` remains open under [ADR-017](017-independent-crypto-review.md) ([Pairwise review readiness](../../pairwise-review-readiness.md)).

## Costs

- Larger prekey bundles and initial message ciphertexts (ML-KEM-768 public keys and ciphertexts) and higher CPU cost per session establishment than classical X3DH.
- Pairwise fan-out multiplies this per-device session cost across group and multi-device sends (ADR-075).

## Reversal Trigger

Only an explicit security/protocol upgrade (e.g. a future versioned ciphersuite `v2`) after cryptographic review; downgrading to classical-only X3DH is explicitly prohibited.

## History, Amendments, and Supersession

- **2026-07-25 (`7e4930f8`):** Original decision added to the register (`Accepted`), superseding [ADR-009](009-pairwise-ratchet.md).
- **2026-07-29 (`d0092ee9`):** Implemented in `native/crypto_core/src/pairwise.rs`, frozen in [Pairwise transport v1](../../pairwise-transport-v1.md), and supplemented by [ADR-034](034-authenticated-pq-contribution.md) and [ADR-035](035-prekey-rotation.md).
- **2026-09-13 (ADR-075):** Extended to carry all group messaging and control payloads after MLS retirement.
- No supersession.
