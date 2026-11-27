# ADR-034: Pairwise transport v1 always mixes signed ML-KEM-768 prekey and treats unsigned PQ one-time prekey as additive only

- **Status:** Accepted
- **Date:** 2026-07-29 (explicitly recorded in register; committed in `d0092ee9`)
- **Related:** [ADR-017](017-independent-crypto-review.md), [ADR-025](025-hybrid-pqxdh.md), [ADR-035](035-prekey-rotation.md)

## Decision (Position)

In `pairwise-transport-v1`, PQXDH session initiation **always encapsulates to and mixes the signed ML-KEM-768 prekey (`pq_spk`)** into the root input key material (`IKM`), and **treats the backend's optional unsigned PQ one-time prekey (`pq_otpk`) strictly as an additive contribution (`SS_O`)**:

```text
IKM = 0xff * 32 || DH1 || DH2 || DH3 || [DH4] || SS_S || [SS_O]
```

`pq_otpk` MUST NEVER substitute for `pq_spk`. Missing, malformed, or unverified `pq_spk` aborts initiation.

## Rationale

Unlike Signal's upstream PQXDH specification (which signs the selected PQ one-time prekey), this project's backend does not carry a signature for `pq_otpk`. Allowing an unsigned `pq_otpk` to replace `pq_spk` would let an active relay strip authentication from the post-quantum layer. Appending `SS_O` after `SS_S` preserves mandatory authenticated PQ contribution while still gaining one-time PQ forward secrecy whenever `pq_otpk` is present.

## Constraints and Open Gates

- Frozen in [Pairwise transport v1](../../contracts/PAIRWISE-V1.md#backend-pq-one-time-key-deviation), implemented in `native/crypto_core/src/pairwise.rs`, and flagged explicitly for independent assessment in [Pairwise review readiness](../../pairwise-review-readiness.md#source-baseline).
- Open gate: Independent cryptographic review ([ADR-017](017-independent-crypto-review.md)) must verify that appending optional `SS_O` after `SS_S` introduces no transcript ambiguity and preserves the hybrid guarantee.

## Costs

- Every PQXDH initial message pays at least one ML-KEM-768 ciphertext (`CT_S`) for `pq_spk`, and pays a second (`CT_O`) when `pq_otpk` is claimed.
- Explicit divergence from upstream Signal PQXDH rev 3 requires dedicated vector tests and reviewer scrutiny.

## Reversal Trigger

If a future backend/protocol version adds device signatures over `pq_otpk` bundles and adopts signed one-time PQ prekey selection in `pairwise-transport-v2+`.

## History, Amendments, and Supersession

- **2026-07-29 (`d0092ee9`):** Original decision added to the register (`Accepted`) alongside Piece 13 pairwise transport implementation.
- No supersession.
