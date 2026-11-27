# ADR-032: Stage Piece 07 as a shared Rust core with an Android FFI adapter and defer its Web/Wasm adapter

- **Status:** Accepted (Web/Wasm target subsequently dropped from scope by [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md) and commit `8236ca5b`)
- **Date:** 2026-07-28 (explicitly recorded in register; committed in `f7bd8115`)
- **Related:** [ADR-015](015-web-session.md), [ADR-017](017-independent-crypto-review.md), [ADR-026](026-candidate-mls-suite.md), [ADR-033](033-android-release-target.md)

## Decision (Position)

Stage Piece 07 as a **shared Rust cryptographic core** (`frontend/native/crypto_core/`) paired with an **Android `dart:ffi` + dedicated worker isolate adapter**, while **deferring the Web/Wasm adapter**.

1. Dart code never implements cryptographic primitives, key generation, or secret zeroization; all native operations cross a narrow, versioned C ABI (`cp_crypto_v1_*` in `communication_crypto.h`) run inside `IsolateCryptoCoreWorker`.
2. Any future Web adapter MUST consume the exact same locked Rust source, provider choices, deterministic encodings, and test vectors, with fail-closed behavior (`UnsupportedCryptoCore`) until independent review, browser vectors, and parity gates pass.
3. This staging narrows only the initial implementation milestone; it does not satisfy or waive [ADR-017](017-independent-crypto-review.md) or [ADR-026](026-candidate-mls-suite.md).

## Rationale

Delivered the shared Android Rust cryptographic foundation (`mlkem-native` v1.2.0, RustCrypto primitives, `libsodium-sys-stable` 1.24.0) without moving primitives into Dart or JavaScript or blocking Android progress on Wasm browser-worker parity.

## Constraints and Open Gates

- Enforced by [crypto_core_boundary_test.dart](../../../test/architecture/crypto_core_boundary_test.dart), `tool/build_rust_android.sh`, and `tool/verify_release_apk.sh` (which verifies exported symbols on packaged Android ABIs).
- Non-Android targets resolve `UnsupportedCryptoCore` ([platform_crypto_core_native.dart](../../../lib/shared/infrastructure/crypto/platform_crypto_core_native.dart)); the former `platform_crypto_core_web.dart` file was later removed (in `ff95a674` / Web removal `8236ca5b`) alongside the browser shell.
- Open gate: Independent assessment of the Rust core and Android FFI boundary remains open under [ADR-017](017-independent-crypto-review.md). ([ADR-026](026-candidate-mls-suite.md) was later closed by ADR-075.)

## Costs

- Requires maintaining the Rust toolchain (`1.97.1`), NDK cross-compilation across Android ABIs (`arm64-v8a`, `armeabi-v7a`, `x86_64`), vendored `mlkem-native` / `libsodium` provenance, and C ABI marshalling.

## Reversal Trigger

A new approved browser target decision (reversing [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md)) would trigger implementing the deferred Wasm adapter against the same locked Rust source.

## History, Amendments, and Supersession

- **2026-07-28 (`f7bd8115`):** Original decision added to the register (`Accepted`).
- **2026-07-28 (`7e550a63` / [ADR-033](033-android-release-target.md)):** Formalized Web as post-v1.
- **2026-09-08 (`8236ca5b`) & `ff95a674`:** Deleted the browser shell and collapsed conditional Web crypto imports as dead code after [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md) removed browser support.
- No supersession.
