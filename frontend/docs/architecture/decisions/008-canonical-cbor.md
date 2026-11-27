# ADR-008: Canonical CBOR for encrypted application payloads

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-018](018-authenticated-padding.md), [ADR-032](032-rust-ffi.md)

## Decision (Position)

Use **deterministic (canonical) CBOR (RFC 8949)** for encrypted application payloads, signed control payloads, and protocol data structures inside the transport envelope.

1. The shared Rust cryptographic core uses `minicbor` (`=2.3.0` in [Cargo.toml](../../../native/crypto_core/Cargo.toml)) behind typed, strict deterministic-CBOR encoders/decoders.
2. In Dart, protocol values for signal payloads (`CPVSV001`, `CPPSV001`) use a strictly bounded deterministic-CBOR subset ([deterministic_cbor.dart](../../../lib/core/protocol/deterministic_cbor.dart)) supporting only unsigned integers, byte strings, text strings, arrays, unsigned-integer-keyed maps, and booleans.
3. Non-canonical encodings, duplicate or unsorted map keys, indefinite-length items, or unknown wire types fail closed on decode, and signed/hashed objects must re-encode byte-for-byte identically to their verified input.

## Rationale

Compact, deterministic, binary-safe, and versionable wire encoding that avoids JSON canonicalization pitfalls and supports byte-exact hashing and signature verification across devices.

## Constraints and Open Gates

- Specified in [Cryptographic protocol](../../cryptographic-protocol.md) and [Application-message protocol](../../message-protocol.md).
- For signed group and voice-room control events (`CPGSV001` / `CPVRV001`), the Rust core performs canonical CBOR encoding and decoding and verifies re-encoding byte equality before accepting state ([Cryptographic protocol](../../cryptographic-protocol.md#groups)).
- Open gate: [Application-message protocol](../../message-protocol.md#purpose-and-status) notes that exact deterministic-CBOR CDDL and golden byte fixtures remain part of protocol stabilization and independent review ([ADR-017](017-independent-crypto-review.md)).

## Costs

- Requires strict custom/subset CBOR validation rather than permissive off-the-shelf JSON serializers.
- Debugging wire payloads requires CBOR-aware tooling or golden fixtures rather than plain-text inspection.

## Reversal Trigger

If a binding contract change or interoperability requirement mandates another canonical binary format with stronger tooling/verification guarantees.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-07-28 (`f7bd8115`):** Implemented strict CBOR module (`native/crypto_core/src/cbor.rs`) using `minicbor`.
- **2026-09-20 / 2026-10-08:** Extended with the Dart strict subset codec in `deterministic_cbor.dart` for `CPVSV001` and `CPPSV001` signal bodies (ADR-077, ADR-098 D2).
- No supersession.
