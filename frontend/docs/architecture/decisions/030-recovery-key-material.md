# ADR-030: Recovery backup contains cross-signing identity material, not history keys

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `7e4930f8`, 2026-07-25)
- **Supersedes (with ADR-028):** [ADR-022](022-history-recovery.md)
- **Related:** [ADR-027](027-device-cross-signing.md), [ADR-028](028-device-history-transfer.md), [ADR-032](032-rust-ffi.md)

## Decision (Position)

The encrypted identity recovery backup (`CPKBV001`, 4,096-byte fixed bucket) wraps **only the account's UUID and its three Ed25519 cross-signing private keys** (`master_sk`, `self_signing_sk`, `user_signing_sk`) — never message history keys, peer attestations, or Double Ratchet session state.

1. The recovery secret is 32 CSPRNG bytes + 2-byte SHA-256 checksum, Crockford Base32 encoded in 5-character hyphenated groups.
2. Key derivation uses Argon2id v1 (`64 MiB` / `65536 KiB`, `3` iterations, parallelism `4`, 16-byte salt, 32-byte output) and XChaCha20-Poly1305 with AAD `"chat:v1:identity-backup" || exact_header[64] || user_uuid[16]`.
3. Restore rejects unknown KDF parameters or non-4096-byte inputs before running Argon2id (never silently lowering KDF cost) and collapses checksum, decode, and AEAD errors into one uniform wrong-secret result.
4. Recovery secret material embedded for initial one-time display is sanitized immediately from the native identity package upon explicit user confirmation.

## Rationale

Recovery preserves verifiable account cross-signing identity across device loss or new-device enrollment without misleading users into thinking it restores local message history ([ADR-028](028-device-history-transfer.md)).

## Constraints and Open Gates

- Defined in [Cryptographic protocol](../../cryptographic-protocol.md#version-1-enrollment-bindings) and implemented in Rust (`native/crypto_core/src/enrollment.rs`, `argon2 = "=0.5.3"`, `chacha20poly1305 = "=0.11.0"`).
- Disclosed mandatorily at enrollment via `DeploymentDisclosure.recoveryExcludesHistory` ([deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart)).
- Open gate: Independent cryptographic review of `CPKBV001` and key sanitization remains open under [ADR-017](017-independent-crypto-review.md).

## Costs

- Users must safeguard their recovery secret separately from device backups (`allowBackup="false"`), and restoring identity on a replacement device without an existing online device leaves prior message history unrecoverable.
- Argon2id (64 MiB, 3 iterations) incurs intentional memory/CPU cost during backup creation, rotation, and restore.

## Reversal Trigger

Would require a protocol version bump (`CPKBV002+`) if KDF parameters or backed-up identity material change.

## History, Amendments, and Supersession

- **2026-07-25 (`7e4930f8`):** Original decision added to the register (`Accepted`), superseding [ADR-022](022-history-recovery.md) alongside [ADR-028](028-device-history-transfer.md).
- **2026-07-28 – 2026-07-29:** Implemented in the Rust crypto core (`enrollment.rs`, `cp_crypto_v1_restore_identity`, `cp_crypto_v1_sanitize_identity`).
- No supersession.
