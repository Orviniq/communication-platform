# Defect report — hybrid KEM combiner, PQ KEM identifiers, and the post-quantum cipher suite builder in `mls-rs`

**Status: draft, not filed.** Prepared 2026-08-17. Intended recipient: the maintainers of
`mls-rs` (<https://github.com/awslabs/mls-rs>).

Five separate defects in the `post-quantum` code paths of `mls-rs-crypto-hpke` and
`mls-rs-crypto-awslc`. Two are interoperability defects against the specification the code
names as its own reference, one is a duplicated builder method, one is a placeholder
protocol identifier that also collapses HPKE domain separation across three cipher suites,
and one is a validation hook that validates nothing on every post-quantum path.

They are reported together because they share a blast radius: all five sit on the
`CipherSuite::ML_KEM_*` / `CipherSuite::ML_KEM_768_X25519` paths, and findings 2, 3 and 4
each independently change bytes that a peer must reproduce.

---

## 1. Affected versions

| Crate | Version examined | Newest published on crates.io (checked 2026-08-17) | Examined version is newest? |
|---|---|---|---|
| `mls-rs-crypto-hpke` | 0.21.0 | 0.21.0 (published 2026-04-21) | yes |
| `mls-rs-crypto-awslc` | 0.25.0 | 0.25.0 (published 2026-04-21) | yes |
| `mls-rs-crypto-traits` | 0.22.0 | 0.22.0 (published 2026-04-21) | yes |
| `mls-rs` | 0.55.2 (context only) | 0.55.3 (published 2026-08-07) | no — 0.55.3 not inspected |

**No published release fixes any of these five findings**, because the three crypto crates
examined are each already the newest published version of that crate.

All five were additionally confirmed present on the `main` branch of
`github.com/awslabs/mls-rs`, retrieved 2026-08-17, so none is fixed in unreleased code
either. Per-finding `main` evidence is given in each section.

The `post-quantum` cargo feature is required to reach any of this code.

---

## 2. How each claim was verified

* **Source claims** were read from the unpacked `.crate` sources of the exact versions in
  the table above, as vendored into a local cargo registry. Every file path below is
  relative to the crate root of the crate named alongside it, and every line number refers
  to the version named alongside it.
* **Specification claims** were read from primary sources: the IETF Datatracker and
  `www.ietf.org/archive/id/` for Internet-Draft text, and the IANA HPKE registry page.
  Retrieval date for all of them is 2026-08-17.
* **Finding 2 was verified mechanically**, by compiling the byte-string literal with
  `rustc` and printing its bytes. That output is quoted verbatim in §3.2.
* **Findings 1, 4 and 5 include runnable reproduction programs that were *not* executed**
  by the author, because building `mls-rs-crypto-awslc` requires an `aws-lc-sys` toolchain
  that was unavailable in the environment used. Those three findings are established by
  source inspection; the programs are provided so a maintainer can confirm them directly.
  Each is marked accordingly.

---

## 3. Findings

### 3.1 — `ghp_combined_hpke` is a verbatim duplicate of `combined_hpke` and never constructs a GHP combiner

**Crate:** `mls-rs-crypto-awslc` 0.25.0
**Severity:** API correctness. A caller that selects the GHP construction silently receives
the X-Wing construction instead.

`AwsLcCipherSuiteBuilder` exposes two `#[cfg(feature = "post-quantum")]` builder methods
with different names and identical bodies:

* `combined_hpke` — `src/lib.rs:242-265`
* `ghp_combined_hpke` — `src/lib.rs:267-290`

Both take the same five parameters `(classical_cipher_suite, ml_kem, kdf, aead, hash)`, and
both bodies are byte-for-byte the same after the signature:

```rust
let ml_kem = MlKemKem { ml_kem, kdf: AwsLcHkdf(kdf) };
let ecdh = dhkem(classical_cipher_suite);

let hpke = ecdh.map(|ecdh| {
    let kem = CombinedKem::new_xwing(ml_kem, ecdh, hash, AwsLcShake128);
    AwsLcHpke::Combined(Hpke::new(kem, AwsLcHkdf(kdf), Some(AwsLcAead(aead))))
});

Self { hpke, ..self }
```

(`src/lib.rs:251-264` and `src/lib.rs:276-289` respectively; the `new_xwing` calls are at
`src/lib.rs:259` and `src/lib.rs:284`.)

Neither method mentions `GhpKemCombiner`. The GHP combiner itself does exist — it is
declared at `mls-rs-crypto-hpke` 0.21.0 `src/kem_combiner/ghp.rs:58-69`, with its `KemType`
impl at `src/kem_combiner/ghp.rs:190-237` — but within `mls-rs-crypto-hpke` 0.21.0,
`mls-rs-crypto-awslc` 0.25.0 and `mls-rs` 0.55.2 the only place a `GhpKemCombiner` value is
ever constructed is the crate's own test module, at `src/kem_combiner/ghp.rs:259` inside
`#[cfg(test)] mod tests` (`src/kem_combiner/ghp.rs:239-456`). No non-test code path
instantiates it.

The duplicate is also untested, and in fact uncalled. Within `mls-rs-crypto-awslc` 0.25.0
and `mls-rs` 0.55.2 the only occurrence of the identifier `ghp_combined_hpke` is its own
definition at `src/lib.rs:268`; there is no call site anywhere in either crate. The crate's
integration test `tests/cipher_suite_builder.rs` covers `combined_hpke` at line 33 and
never calls `ghp_combined_hpke`.

**Expected:** `ghp_combined_hpke` builds a `GhpKemCombiner` — presumably with the
concatenation codecs `CatCodec2` and `CatCodec7`, which `mls-rs-crypto-hpke` 0.21.0
documents for exactly this purpose at `src/kem_combiner/byte_vec_codecs.rs:28-34` and
`:36-42` ("The concatenation codec for two/seven chunks to instantiate [GhpKemCombiner] as
specified in the [RFC draft]") — or, if the method is not meant to exist, it is removed.

**Actual:** it builds `CombinedKem::new_xwing`, identical to `combined_hpke`.

**Reproduction** (not executed by the author; source-derived). With
`mls-rs-crypto-awslc = { version = "=0.25.0", features = ["post-quantum"] }`,
`mls-rs-core = { version = "=0.27.0", features = ["post-quantum", "std"] }` and
`mls-rs-crypto-traits = "=0.22.0"`:

```rust
use mls_rs_core::crypto::{CipherSuite, CipherSuiteProvider};
use mls_rs_crypto_awslc::{AwsLcCipherSuiteBuilder, AwsLcHash, MlKem, Sha3};
use mls_rs_crypto_traits::{AeadId, KdfId};

fn build(ghp: bool) -> impl CipherSuiteProvider {
    let hash = AwsLcHash::new_sha3(Sha3::SHA3_256).unwrap();
    let b = AwsLcCipherSuiteBuilder::new().hash(hash);
    let b = if ghp {
        b.ghp_combined_hpke(CipherSuite::CURVE25519_AES128, MlKem::MlKem768,
                            KdfId::HkdfSha256, AeadId::Aes128Gcm, hash)
    } else {
        b.combined_hpke(CipherSuite::CURVE25519_AES128, MlKem::MlKem768,
                        KdfId::HkdfSha256, AeadId::Aes128Gcm, hash)
    };
    b.fallback_cipher_suite(CipherSuite::CURVE25519_AES128)
     .build(CipherSuite::new(0xF000)).unwrap()
}

fn main() {
    let xwing = build(false);
    let ghp = build(true);

    // Seal under the "GHP" builder, open under the X-Wing builder.
    let (sk, pk) = ghp.kem_derive(&[0u8; 64]).unwrap();
    let ct = ghp.hpke_seal(&pk, b"info", None, b"pt").unwrap();
    let pt = xwing.hpke_open(&ct, &sk, &pk, b"info", None).unwrap();

    // Succeeds. Two nominally different KEM constructions are the same construction.
    assert_eq!(&*pt, b"pt");
}
```

**Upstream status:** not fixed. On `main` (retrieved 2026-08-17) the two methods are still
present with identical bodies, and neither constructs `GhpKemCombiner`.

---

### 3.2 — The X-Wing combiner label is 7 bytes containing an embedded `0x0a`; the specified label is 6 bytes

**Crate:** `mls-rs-crypto-hpke` 0.21.0
**Severity:** interoperability. The derived shared secret cannot match any conforming
X-Wing implementation.

`XWingSharedSecretHashInput` (`src/kem_combiner/xwing.rs:83`, impl at `:100-115`) prefixes
the combiner input with this literal, at `src/kem_combiner/xwing.rs:107`:

```rust
b"\\./\n/^\\"
```

Applying Rust byte-string escaping, that is **7 bytes**: `5c 2e 2f 0a 2f 5e 5c`. The `\n`
between the two halves of the ASCII-art label is a literal line feed and is part of the
hashed input.

`draft-connolly-cfrg-xwing-kem` defines the label as a concatenation of two 3-byte strings
with no separator, and states its value explicitly:

> "In hexadecimal, XWingLabel is given by 5c2e2f2f5e5c."
> — draft-connolly-cfrg-xwing-kem-10 (2026-03-02)

That is **6 bytes**. This is not a revision-dependent difference: revision `-01`, the
revision the module's own doc comment cites (see §3.3), likewise specifies a 6-byte label
of backslash, period, slash, slash, caret, backslash, with no line feed.

**Mechanical verification (executed).** The literal was copied verbatim from
`src/kem_combiner/xwing.rs:107` into a standalone program and compiled with `rustc`:

```rust
fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect::<Vec<_>>().join("")
}

fn main() {
    // verbatim from mls-rs-crypto-hpke-0.21.0/src/kem_combiner/xwing.rs:107
    let impl_label: &[u8] = b"\\./\n/^\\";
    // XWingLabel per draft-connolly-cfrg-xwing-kem: "given by 5c2e2f2f5e5c"
    let spec_label: &[u8] = &[0x5c, 0x2e, 0x2f, 0x2f, 0x5e, 0x5c];

    println!("impl  len={} hex={}", impl_label.len(), hex(impl_label));
    println!("spec  len={} hex={}", spec_label.len(), hex(spec_label));
    println!("equal={}", impl_label == spec_label);
}
```

Output:

```
impl  len=7 hex=5c2e2f0a2f5e5c
spec  len=6 hex=5c2e2f2f5e5c
equal=false
```

**Impact.** The label is hashed together with the two shared secrets by
`src/kem_combiner/xwing.rs:106-114`, and the digest is returned as the KEM shared secret
(`src/kem_combiner/xwing.rs:188-195` for encapsulation, `:232-239` for decapsulation).
The extra byte changes that shared secret completely. Because the public key and ciphertext
sizes are unaffected, the divergence is invisible to any length or parsing check and
surfaces only as a decryption failure against a conforming peer.

**Upstream status:** not fixed. On `main` (retrieved 2026-08-17) the literal is still
`b"\\./\n/^\\"`.

---

### 3.3 — The X-Wing combiner implements the input ordering of superseded revision `-01`, and its doc comment cites that revision

**Crate:** `mls-rs-crypto-hpke` 0.21.0
**Severity:** interoperability, plus a stale specification reference.

The doc comment at `src/kem_combiner/xwing.rs:97` reads:

```rust
/// Defined in https://www.ietf.org/archive/id/draft-connolly-cfrg-xwing-kem-01.html
```

`draft-connolly-cfrg-xwing-kem` is at revision **`-10`**, dated 2026-03-02 (IETF
Datatracker, retrieved 2026-08-17). Revision `-01` is nine revisions behind. Separately,
the IANA HPKE KEM Identifiers registry records `-06` as the reference for the X-Wing code
point, so `-01` is behind the registered reference as well.

This is not only a stale link — the implementation tracks `-01`'s byte ordering. The
combiner input is assembled at `src/kem_combiner/xwing.rs:106-114` as:

```
label || ss_details1.shared_secret || ss_details2.shared_secret
      || ss_details2.enc || ss_details2.public_key
```

In the provider's own X-Wing instantiation, `kem1` is ML-KEM-768 and `kem2` is
DHKEM(X25519) — see `mls-rs-crypto-awslc` 0.25.0 `src/lib.rs:353-358`, where
`CombinedKem::new_xwing` is called with `MlKemKem::new(CipherSuite::ML_KEM_768)` and
`dhkem(classical_cs)`, hashing with `AwsLcHash::new_sha3(Sha3::SHA3_256)` at
`src/lib.rs:356`. So the implemented construction is:

```
SHA3-256( XWingLabel || ss_M || ss_X || ct_X || pk_X )
```

The two relevant revisions define:

| Revision | Combiner |
|---|---|
| `-01` (cited by the code) | `SHA3-256(concat(XWingLabel, ss_M, ss_X, ct_X, pk_X))` — label **first** |
| `-10` (current) | `SHA3-256(concat(ss_M, ss_X, ct_X, pk_X, XWingLabel))` — label **last** |

The change is recorded in the `-10` changelog, under the section for changes since
revision `-04`:

> "Move label at the end. As everything fits within a single block of SHA3-256, this does
> not make any difference."

i.e. the reordering landed in `-05`. The changelog's remark that it "does not make any
difference" is a statement about security, not about the wire: the two orderings produce
different digests and therefore different shared secrets.

**Impact.** Independently of finding 3.2, this alone makes the construction
non-interoperable with any implementation of `-05` or later, including the revision IANA
records for the assigned code point.

**Suggested fix:** move the label to the end of the concatenation and update the doc
comment to a revision-less Datatracker URL
(`https://datatracker.ietf.org/doc/draft-connolly-cfrg-xwing-kem/`) or to whichever
revision the implementation is deliberately targeting, stated explicitly.

**Upstream status:** not fixed. On `main` (retrieved 2026-08-17) the doc comment still
cites `draft-connolly-cfrg-xwing-kem-01` and the label is still concatenated first.

---

### 3.4 — `kem_id()` returns the unassigned placeholder `15` for both the ML-KEM and hybrid KEMs, giving three cipher suites an identical HPKE suite ID

**Crates:** `mls-rs-crypto-hpke` 0.21.0, `mls-rs-crypto-awslc` 0.25.0
**Severity:** protocol correctness. This is the widest-reaching of the five findings.

Two distinct KEM implementations return the same hard-coded value:

* `CombinedKem::kem_id` — `mls-rs-crypto-hpke` 0.21.0 `src/kem_combiner/xwing.rs:149-152`:
  ```rust
  fn kem_id(&self) -> u16 {
      // TODO not set by any RFC
      15
  }
  ```
* `MlKemKem::kem_id` — `mls-rs-crypto-awslc` 0.25.0 `src/kem/ml_kem.rs:73-76`: the same
  comment and the same value `15`.

The trait these implement documents the contract explicitly, at `mls-rs-crypto-traits`
0.22.0 `src/kem.rs:30`:

```rust
/// KEM Id, as specified in RFC 9180, Section 5.1 and Table 2.
fn kem_id(&self) -> u16;
```

**Against the registry.** From the IANA HPKE KEM Identifiers registry (retrieved
2026-08-17):

| Value | Assignment |
|---|---|
| `0x0001`–`0x000F` | **Unassigned** |
| `0x0040` / `0x0041` / `0x0042` | ML-KEM-512 / ML-KEM-768 / ML-KEM-1024 (ref. `draft-connolly-cfrg-hpke-mlkem-04`) |
| `0x647A` | X-Wing (ref. `draft-connolly-cfrg-xwing-kem-06`) |

`15` is `0x000F`, which is unassigned. Assigned code points now exist for every KEM this
code implements. The `// TODO not set by any RFC` comment is literally still true — the
referencing documents for `0x0040`–`0x0042` and `0x647A` are Internet-Drafts, not RFCs —
but the registry is not an RFC Required registry. RFC 9180 defines the KEM Identifiers
registry in §11.1 and states in §11.3 that all three HPKE registries are "administered
under a Specification Required policy"; IANA lists the same procedure on the registry page
itself. A draft reference is therefore exactly what a valid assignment looks like here. The
assignments are usable today; the placeholder is not.

Note also that `KemId` (`mls-rs-crypto-traits` 0.22.0 `src/kem.rs:86-92`) enumerates only
the five RFC 9180 DHKEMs and has no post-quantum variants, so there is currently no shared
constant a fix could reuse.

**Why the value matters on the wire.** `kem_id()` is consumed by `Hpke::new` at
`mls-rs-crypto-hpke` 0.21.0 `src/hpke.rs:89-97`:

```rust
let suite_id = [
    b"HPKE",
    &kem.kem_id().to_be_bytes() as &[u8],
    &kdf.kdf_id().to_be_bytes() as &[u8],
    &aead_id.to_be_bytes() as &[u8],
].concat();

let kem_suite_id = [b"KEM", &kem.kem_id().to_be_bytes() as &[u8]].concat();
```

Both IDs feed the labeled extract/expand steps of the HPKE key schedule, so the placeholder
is bound into every derivation performed under these cipher suites — it is not an
informational field.

**The collision.** Because both KEMs return the same `kem_id`, and because the KDF and AEAD
for several PQ suites are derived from the *same* classical fallback suite, the resulting
HPKE `suite_id` is identical across structurally different KEMs. In `mls-rs-crypto-awslc`
0.25.0 `src/lib.rs:332-340`, `CipherSuite::ML_KEM_512`, `CipherSuite::ML_KEM_768` and
`CipherSuite::ML_KEM_768_X25519` all map to `classical_cs = CipherSuite::CURVE25519_AES128`
(`src/lib.rs:336-338`), and the KDF and AEAD are then constructed from `classical_cs` at
`src/lib.rs:342-343`. With `kem_id` fixed at `15` for all of them, all three suites produce:

* the same `suite_id` (`"HPKE" || 0x000F || kdf_id || aead_id`), and
* the same `kem_suite_id` (`"KEM" || 0x000F`),

despite being three different KEMs — ML-KEM-512, ML-KEM-768, and the ML-KEM-768 + X25519
hybrid — with different key and ciphertext sizes. The domain separation that `kem_id` exists
to provide is therefore absent between them.

**Reproduction** (not executed by the author; source-derived):

```rust
use mls_rs_core::crypto::CipherSuite;
use mls_rs_crypto_awslc::MlKemKem;
use mls_rs_crypto_traits::KemType;

fn main() {
    for cs in [CipherSuite::ML_KEM_512, CipherSuite::ML_KEM_768, CipherSuite::ML_KEM_1024] {
        println!("{:?} -> kem_id {}", cs, MlKemKem::new(cs).unwrap().kem_id());
    }
    // Expected from source: all three print kem_id 15.
}
```

**Upstream status:** not fixed. On `main` (retrieved 2026-08-17) both `kem_id()` bodies
still read `// TODO not set by any RFC` / `15`.

---

### 3.5 — `public_key_validate` is unconditionally `Ok(())` on every post-quantum path, including the KeyPackage init-key validation hook

**Crates:** `mls-rs-crypto-hpke` 0.21.0, `mls-rs-crypto-awslc` 0.25.0
**Severity:** validation contract violated. A documented validation function performs no
validation.

Three implementations, all unconditionally successful:

| Type | Location | Comment present |
|---|---|---|
| `CombinedKem` | `mls-rs-crypto-hpke` 0.21.0 `src/kem_combiner/xwing.rs:242-245` | `// TODO Not clear how to do this for Kyber or how useful it is.` |
| `GhpKemCombiner` | `mls-rs-crypto-hpke` 0.21.0 `src/kem_combiner/ghp.rs:234-236` | none |
| `MlKemKem` | `mls-rs-crypto-awslc` 0.25.0 `src/kem/ml_kem.rs:142-144` | none |

Each body is `Ok(())` with the key parameter bound to `_key`.

**The contract.** `mls-rs-core` 0.27.0 `src/crypto.rs:494-495`:

```rust
/// Verify that the given byte vector `key` can be decoded as an HPKE public key.
fn kem_public_key_validate(&self, key: &HpkePublicKey) -> Result<(), Self::Error>;
```

**Reachability.** `AwsLcCipherSuite::kem_public_key_validate` dispatches to the KEM at
`mls-rs-crypto-awslc` 0.25.0 `src/lib.rs:647-656`, including the
`AwsLcHpke::PostQuantum` and `AwsLcHpke::Combined` arms at `src/lib.rs:651` and `:653`.
Those arms are selected for `CipherSuite::ML_KEM_512`, `ML_KEM_768`, `ML_KEM_1024`
(`src/lib.rs:348-350`) and `ML_KEM_768_X25519` (`src/lib.rs:352-361`), all four of which
are advertised by `supported_pq_cipher_suites()` at `src/lib.rs:142-149`.

The hook is on the KeyPackage validation path. `mls-rs` 0.55.2
`src/key_package/validator.rs:29-31`:

```rust
// Verify that the public init key is a valid format for this cipher suite
cs.kem_public_key_validate(&package.hpke_init_key)
    .map_err(|_| MlsError::InvalidInitKey)?;
```

So on any post-quantum cipher suite, `MlsError::InvalidInitKey` is unreachable from this
check: a KeyPackage whose `hpke_init_key` is of *any* length, including zero, passes it.

**Contrast with the classical path.** `DhKem::public_key_validate` delegates to the DH
implementation at `mls-rs-crypto-hpke` 0.21.0 `src/dhkem.rs:155-159`, and for NIST curves
`Ecdh::public_key_validate` parses the point via `EcPublicKey::from_bytes` at
`mls-rs-crypto-awslc` 0.25.0 `src/kem/ecdh.rs:88-94`. For completeness and accuracy: that
same function also returns `Ok(())` for X25519 without a length check
(`src/kem/ecdh.rs:89-93`), so the classical path is not uniformly strict either — but the
NIST curves do get a real structural check, and the post-quantum suites get none at all.

Downstream length handling does not compensate. `CombinedKem::parse_key`
(`mls-rs-crypto-hpke` 0.21.0 `src/kem_combiner/xwing.rs:339-347`) enforces only
`key.len() >= size`, so an over-long combined public key is split rather than rejected, and
whatever checking occurs happens later inside the component KEM operations rather than at
the validation hook that exists for the purpose.

**Reproduction** (not executed by the author; source-derived):

```rust
use mls_rs_core::crypto::{CipherSuite, CipherSuiteProvider, CryptoProvider};
use mls_rs_crypto_awslc::AwsLcCryptoProvider;

fn main() {
    let provider = AwsLcCryptoProvider::new();
    for cs in [CipherSuite::ML_KEM_512, CipherSuite::ML_KEM_768,
               CipherSuite::ML_KEM_1024, CipherSuite::ML_KEM_768_X25519] {
        let csp = provider.cipher_suite_provider(cs).unwrap();
        // A zero-length key is structurally impossible for every one of these suites.
        assert!(csp.kem_public_key_validate(&Vec::<u8>::new().into()).is_ok(),
                "{cs:?} unexpectedly rejected an empty key");
    }
    // Expected from source: all four assertions hold.
}
```

**Suggested fix:** at minimum enforce the expected encoded length for each suite. The
lengths are already available: `FixedLengthKemType::public_key_size` supplies them for
`MlKemKem` (`mls-rs-crypto-awslc` 0.25.0 `src/kem/ml_kem.rs:159-165`) and for `CombinedKem`
(`mls-rs-crypto-hpke` 0.21.0 `src/kem_combiner/xwing.rs:279-281`), so the check costs one
comparison.

Beyond length, `draft-connolly-cfrg-xwing-kem-10` states the stronger requirement directly:

> "ML-KEM-768.Encaps(pk_M) MUST perform the encapsulation key check of [MLKEM] §7.2 and
> raise an error if it fails."

i.e. the modulus/type check of FIPS 203 §7.2 on the ML-KEM component. For balance: the same
draft imposes no corresponding validation requirement on the X25519 component, so a fix
targeting the ML-KEM half plus a total-length check would satisfy the specification.

**Upstream status:** not fixed. On `main` (retrieved 2026-08-17), `CombinedKem` and
`GhpKemCombiner` still return `Ok(())`, `MlKemKem` still returns `Ok(())`, and
`mls-rs/src/key_package/validator.rs` still calls the hook with the same comment and the
same `MlsError::InvalidInitKey` mapping.

---

## 4. Candidates investigated and *not* confirmed

Recorded so the report is not read as broader than what was verified.

**The GHP combiner's specification reference is *not* stale.** The candidate "the combiner
documentation references a superseded specification revision" was checked against both
combiner modules. It holds for the X-Wing module (finding 3.3) but **not** for the GHP
module. The doc comment at `mls-rs-crypto-hpke` 0.21.0 `src/kem_combiner/ghp.rs:42-43`
links to `https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-hybrid-kems` — a
revision-less Datatracker URL that resolves to the current revision. That document
("Hybrid PQ/T Key Encapsulation Mechanisms") is active at revision `-12` as of 2026-08-17,
and the link tracks it automatically. No defect.

**No claim is made about full X-Wing conformance beyond findings 3.2 and 3.3.** Other
properties of the construction — component ordering, the `enc`/public-key concatenation
layout, and the encapsulation/decapsulation size parameters — were read but are not
reported here, because they were not the subject of this review and a conformance verdict
on them would exceed what was verified.

---

## 5. Summary table

| # | Finding | Crate(s) | Primary location | Fixed upstream? |
|---|---|---|---|---|
| 3.1 | `ghp_combined_hpke` duplicates `combined_hpke`; no GHP combiner is ever built | `mls-rs-crypto-awslc` 0.25.0 | `src/lib.rs:267-290` | No (also unfixed on `main`) |
| 3.2 | X-Wing label is 7 bytes with an embedded `0x0a`; spec says 6 bytes | `mls-rs-crypto-hpke` 0.21.0 | `src/kem_combiner/xwing.rs:107` | No (also unfixed on `main`) |
| 3.3 | Combiner ordering and doc comment track superseded draft `-01` | `mls-rs-crypto-hpke` 0.21.0 | `src/kem_combiner/xwing.rs:97`, `:106-114` | No (also unfixed on `main`) |
| 3.4 | `kem_id` is the unassigned placeholder `15`, shared by two KEMs, collapsing suite IDs across three cipher suites | `mls-rs-crypto-hpke` 0.21.0, `mls-rs-crypto-awslc` 0.25.0 | `src/kem_combiner/xwing.rs:149-152`, `src/kem/ml_kem.rs:73-76` | No (also unfixed on `main`) |
| 3.5 | `public_key_validate` is a no-op on all PQ paths, on the KeyPackage init-key hook | `mls-rs-crypto-hpke` 0.21.0, `mls-rs-crypto-awslc` 0.25.0 | `src/kem_combiner/xwing.rs:242-245`, `src/kem_combiner/ghp.rs:234-236`, `src/kem/ml_kem.rs:142-144` | No (also unfixed on `main`) |

---

## 6. References

All retrieved 2026-08-17.

* IANA, *Hybrid Public Key Encryption (HPKE) IANA Registries* — KEM Identifiers table.
  <https://www.iana.org/assignments/hpke/hpke.xhtml>
* `draft-connolly-cfrg-xwing-kem` — revision `-10` (2026-03-02, current) and revision `-01`
  (the revision cited by the code). Combiner definition, `XWingLabel` value, and the
  changelog entry moving the label. Revision text read from
  `https://www.ietf.org/archive/id/draft-connolly-cfrg-xwing-kem-10.txt` and `…-01.txt`.
  <https://datatracker.ietf.org/doc/draft-connolly-cfrg-xwing-kem/>
* *Hybrid PQ/T Key Encapsulation Mechanisms*, `draft-irtf-cfrg-hybrid-kems`, revision `-12`.
  <https://datatracker.ietf.org/doc/draft-irtf-cfrg-hybrid-kems/>
* RFC 9180, *Hybrid Public Key Encryption* — §5.1 and Table 2 (KEM identifiers); §11.1
  (KEM Identifiers registry) and §11.3 (Specification Required policy).
* NIST FIPS 203, *Module-Lattice-Based Key-Encapsulation Mechanism Standard* — §7.2
  (encapsulation key check), referenced in the suggested fix for finding 3.5.
* crates.io version metadata for `mls-rs-crypto-hpke`, `mls-rs-crypto-awslc`,
  `mls-rs-crypto-traits` and `mls-rs`.
* `github.com/awslabs/mls-rs`, branch `main`, for the upstream-status checks.
