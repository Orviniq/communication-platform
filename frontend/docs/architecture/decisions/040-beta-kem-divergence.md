# ADR-040: Closed-beta hybrid KEM divergence from TBD2

- **Status:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13)
- **Date:** 2026-08-17 (explicitly recorded in register and full section; committed in `2f531703`; closed `2026-09-13`)
- **Closed by:** [ADR-075](075-pairwise-groups.md) (2026-09-13), following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- **Related:** [ADR-017](017-independent-crypto-review.md), [ADR-026](026-candidate-mls-suite.md), [ADR-036](036-beta-mls-track.md), [ADR-044](044-private-deployment.md)

## Decision (Position)

Originally decided not to change the closed-beta hybrid KEM, to record the complete ten-row divergence between `mls-rs-crypto-awslc` 0.25.0 / `mls-rs-crypto-hpke` 0.21.0 and `TBD2`'s KEM `0x647a`, and to establish that supplying a conformant KEM through `mls-rs`'s public extension points would constitute a project-local cryptographic fork:

1. **Retain the maintained `combined_hpke` / `CombinedKem::new_xwing` construction:** Closed-beta groups continue to use `mls-rs`'s maintained hybrid ML-KEM-768/X25519 construction on MLS Private Use identifier `0xFE4C` with disposable state ([ADR-036](036-beta-mls-track.md)), without triggering beta state reinitialization.
2. **Complete ten-row divergence set (D1–D10, verified 2026-08-17 against vendored crate sources and X-Wing draft text):**
   - Combiner input order (label last in `-06`/`-10` vs. label first in the vendored combiner);
   - Combiner label bytes (6 vs. 7 bytes, with an embedded `0x0a`);
   - Traditional contribution (raw X25519 vs. a `DHKEM(X25519, HKDF-SHA256)` secret);
   - HPKE `kem_id` (`0x647a` vs. `15` / `0x000F`, unassigned at IANA);
   - `DeriveKeyPair` structure (no `dkp_prk` step vs. an extra HKDF-SHA384 `dkp_prk` extraction);
   - Seed expansion (SHAKE-256 vs. SHAKE-128);
   - X25519 key derivation (raw scalar vs. RFC 9180 labeled expand);
   - Mandatory ML-KEM encapsulation-key check (required vs. no-op);
   - Serialized private key length (`Nsk` 32 vs. 2,432 bytes);
   - Targeted draft revision (`-06`/`-10` vs. `draft-01`).
   Because `0x000F` is bound into every HPKE `suite_id` and `"KEM" || kem_id` key-derivation label while `Npk`, `Nenc`, and `Nsecret` remain byte-identical, the divergence is silent on the wire and fails at decryption rather than parsing.
3. **No custom extension-point implementation:** Although `mls_rs::CryptoProvider`, `CipherSuiteProvider`, `CombinedKem::new_custom`, and `SharedSecretHashInput` are public, `AwsLcCipherSuite` and `AwsLcHpke` are private and hard-code `CombinedKem::new_xwing`, so implementing `0x647a` locally would require authoring a ~25-method `CipherSuiteProvider`, the combiner, raw-X25519 KEM, SHAKE-256 expansion via project-local `unsafe` FFI against `aws-lc-sys`, `(d || z)` split, and encapsulation-key check in project code. Authoring those algorithm steps locally crosses the line from composing maintained primitives into an unreviewed, unmaintained custom implementation prohibited by [ADR-017](017-independent-crypto-review.md), [ADR-036](036-beta-mls-track.md), and production gate 3.
4. **No production gate opened:** Beta groups remained non-`TBD2`-conformant and were prohibited from being offered as `TBD2` interoperability evidence. All seven production gates remained closed and `UnsupportedGroupMls` remained active in production.

**Closure:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13) after [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) removed MLS from the system. Closed-beta MLS code and `beta` flavor were deleted; groups now use pairwise Double Ratchet fan-out ([Cryptographic protocol](../../contracts/CRYPTO.md#groups)).

## Rationale

Original rationale:
- Beta already delivered everything [ADR-036](036-beta-mls-track.md) required — maintained hybrid ML-KEM-768/X25519 confidentiality, `TBD2`'s exact signature/AEAD/KDF/hash mapping, no classical fallback, and disposable state on `0xFE4C`.
- The divergence cost only `TBD2` interoperability, which no gate could consume while `TBD2` lacked an IANA MLS ciphersuite value, its underlying drafts (`draft-connolly-cfrg-xwing-kem-06`/`-10`, `draft-ietf-hpke-pq-05`, `draft-irtf-cfrg-concrete-hybrid-kems-03`/`-04`, `draft-ietf-mls-pq-ciphersuites-06`) were still moving, and no upstream PQ MLS vectors existed.
- The pinned `mls-rs` crypto crates (`mls-rs-crypto-hpke` 0.21.0, `mls-rs-crypto-awslc` 0.25.0, `mls-rs-crypto-traits` 0.22.0) were already the newest published versions, and migrating to OpenMLS (`0.8.1` / `0.9.0-rc.2`) was rejected because OpenMLS targeted `MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519` (`0x004D`), trading one divergence class (wrong KEM) for another (wrong AEAD, KDF, and hash). Deferring without deciding was rejected because [ADR-036](036-beta-mls-track.md)'s 2026-08-16 correction left the divergence set incomplete and unresolved.

Why closed: [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) eliminated MLS groups entirely.

## Constraints and Open Gates

- **Closed:** `frontend/docs/mls-profile.md` (which held the normative D1–D10 evidence table) and `frontend/native/crypto_core/src/mls_beta.rs` were deleted when beta MLS was retired (historical snapshot preserved at commit `788453b430f34c52c2063ef67b8aa5e4f8fa935d`).
- The prepared upstream defect report remains archived at [mls-rs-hybrid-kem-defect-report.md](../../archive/beta-mls-core/mls-rs-hybrid-kem-defect-report.md), and on-device beta run records remain at [archive/beta-mls-core/README.md](../../archive/beta-mls-core/README.md).
- Any future KEM or ciphersuite migration on an active track would have required explicit state-format version rejection because `Npk` and `Nenc` were identical (`BETA_STATE_FORMAT_VERSION`, transport v3, schema v11).

## Costs

- While active, beta group wire formats were incompatible with `TBD2` and could not produce cross-implementation or `TBD2` interoperability evidence.

## Reversal Trigger

Original trigger: reopen when a maintained provider implements `TBD2`'s KEM `0x647a` against a stable, non-expiring specification (production gates 1 and 3).

Current state: already closed by ADR-075 (2026-09-13).

## History, Amendments, and Supersession

- **2026-08-17 (`2f531703`):** Recorded ADR-040 (`Accepted`), documenting the ten-row divergence set and rejecting a custom extension-point KEM implementation or OpenMLS migration.
- **2026-08-20 ([ADR-044](044-private-deployment.md)):** Carried forward as a fixed constraint of the Private Experimental deployment's experimental tier.
- **2026-09-13 (`cd36012f` / ADR-075):** Closed and retired along with the closed-beta MLS track.
