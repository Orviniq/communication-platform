# ADR-017: Shared reviewed crypto core and independent assessment

- **Status:** Release gate (Open)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-025](025-hybrid-pqxdh.md), [ADR-027](027-device-cross-signing.md), [ADR-032](032-rust-ffi.md), [ADR-034](034-authenticated-pq-contribution.md), [ADR-036](036-beta-mls-track.md)

## Decision (Position)

1. All cryptographic primitives, serialization/signing encodings, key generation, and secret zeroization MUST live in a **shared, memory-safe Rust core** (`frontend/native/crypto_core/`) using reviewed external cryptographic libraries — never custom or Dart-implemented primitives.
2. **Independent cryptographic and application-security assessment is a mandatory production release gate.** No build may be claimed reviewed, verified, or production-ready until an independent assessor records a disposition for every blocking finding.

## Rationale

A custom or unaudited cryptographic implementation is not production-ready; isolating primitives in Rust and requiring independent review ensures memory safety, secret zeroization, and external verification before general release.

## Constraints and Open Gates

- **Gate status: OPEN.** As recorded in [Frontend status](../../STATUS.md#platform-identity-and-content), [Pairwise review readiness](../../pairwise-review-readiness.md), [Independent review engagement](../../independent-review-engagement.md), and [DeploymentDisclosure.noIndependentReview](../../../lib/app/config/deployment_disclosure.dart), **no layer has been independently assessed** — including pairwise PQXDH/Double Ratchet, enrollment/cross-signing/device logs, signed pairwise group control (`CPGSV001`), voice room control (`CPVRV001`), and attachment streaming.
- Every distributed artifact must disclose this lack of independent review (`noIndependentReview` in `DeploymentDisclosure`) and avoid calling any surface "supported", "stable", "verified", or "audited" (ADR-045).
- Enforced at build/test boundaries by [crypto_core_boundary_test.dart](../../../test/architecture/crypto_core_boundary_test.dart) (forbidding Dart crypto packages `cryptography`, `pinenacl`, `pointycastle`) and [Cargo.toml](../../../native/crypto_core/Cargo.toml) (`mlkem-native` v1.2.0, RustCrypto crates, `libsodium-sys-stable` 1.24.0, `zeroize`).

## Costs

- Public production release cannot complete until an independent reviewer is retained and all blocking findings are resolved.
- Strict FFI boundary and Rust toolchain pinning (`rust-version = "1.97.1"`) add build and serialization overhead ([ADR-032](032-rust-ffi.md)).

## Reversal Trigger

This gate closes only when an independent cryptographic and application-security review completes and every blocking finding has a verified disposition.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Release gate`).
- **2026-07-28 (`f7bd8115` / [ADR-032](032-rust-ffi.md)):** Implemented the shared Rust core and Android FFI boundary for Piece 07.
- **2026-08-17 (ADR-040) & 2026-08-20 (ADR-044, ADR-045):** Reaffirmed ADR-017 as an open gate; forbade project-local MLS KEM forks under ADR-017; mandated user disclosure of unreviewed status.
- **2026-09-13 (ADR-075) & 2026-09-14 (ADR-076):** Retired MLS scope (keeping MLS review packet historical) while keeping ADR-017 open for pairwise transport, signed group control, and production builds.
- No supersession; gate remains open.
