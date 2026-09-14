//! Official FIPS 203 known-answer coverage for ML-KEM-768.
//!
//! The vendored fixture is a verbatim subset of the NIST ACVP-Server vectors
//! (see `vectors/README.md` for source, revision, and the extraction recipe).
//! It is checked in, so nothing here reaches the network at build or test time.
//!
//! Every known-answer test drives the production surface —
//! [`CryptoProvider`]'s ML-KEM entry points backed by the vendored
//! `mlkem-native` build — rather than the C API directly, so the vectors also
//! pin the Rust seam: coin ordering, buffer sizes, and error mapping.

use serde_json::Value;

use crate::{
    error::CryptoError,
    provider::{
        CryptoProvider, MLKEM_SHARED_BYTES, MLKEM768_CIPHERTEXT_BYTES, MLKEM768_PUBLIC_BYTES,
        MLKEM768_SECRET_BYTES, RustCryptoProvider,
    },
    random::FixedRandomProvider,
    secret::SecretBytes,
};

const VECTORS: &str = include_str!("../vectors/mlkem768-acvp-fips203.json");

/// FIPS 203 keygen randomness is `d || z`; encapsulation randomness is `m`.
const KEYGEN_SEED_BYTES: usize = 64;
const ENCAPS_SEED_BYTES: usize = 32;

fn vectors() -> Value {
    serde_json::from_str(VECTORS).expect("vendored ML-KEM vectors are valid JSON")
}

fn group<'a>(vectors: &'a Value, name: &str) -> &'a Vec<Value> {
    vectors[name]
        .as_array()
        .unwrap_or_else(|| panic!("vector group {name} is an array"))
}

fn hex(case: &Value, field: &str) -> Vec<u8> {
    case[field]
        .as_str()
        .unwrap_or_else(|| panic!("{field} is a hex string"))
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            u8::from_str_radix(std::str::from_utf8(pair).expect("vector hex is ASCII"), 16)
                .expect("vector hex is valid")
        })
        .collect()
}

fn hex_array<const N: usize>(case: &Value, field: &str) -> [u8; N] {
    hex(case, field)
        .try_into()
        .unwrap_or_else(|bytes: Vec<u8>| panic!("{field} has {} bytes, expected {N}", bytes.len()))
}

fn tc_id(case: &Value) -> u64 {
    case["tcId"].as_u64().expect("tcId is an integer")
}

/// A provider whose randomness is exactly the vector's published seed, so the
/// production entry points run deterministically.
fn seeded(seed: &[u8]) -> RustCryptoProvider<FixedRandomProvider> {
    RustCryptoProvider::new(FixedRandomProvider::new(seed.to_vec()))
}

fn keygen_seed(case: &Value) -> Vec<u8> {
    let mut seed = hex(case, "d");
    seed.extend_from_slice(&hex(case, "z"));
    assert_eq!(seed.len(), KEYGEN_SEED_BYTES, "keygen seed is d || z");
    seed
}

#[test]
fn mlkem768_acvp_key_generation_known_answers() {
    let vectors = vectors();
    let cases = group(&vectors, "keyGen");
    assert!(!cases.is_empty(), "keyGen vectors are present");
    for case in cases {
        let (public_key, secret_key) = seeded(&keygen_seed(case))
            .mlkem768_keypair()
            .unwrap_or_else(|error| panic!("tcId {}: keygen failed: {error:?}", tc_id(case)));
        assert_eq!(
            public_key.as_slice(),
            hex(case, "ek"),
            "tcId {}: encapsulation key",
            tc_id(case)
        );
        assert_eq!(
            secret_key.expose().as_slice(),
            hex(case, "dk"),
            "tcId {}: decapsulation key",
            tc_id(case)
        );
    }
}

#[test]
fn mlkem768_acvp_encapsulation_known_answers() {
    let vectors = vectors();
    let cases = group(&vectors, "encapsulation");
    assert!(!cases.is_empty(), "encapsulation vectors are present");
    for case in cases {
        let public_key = hex_array::<MLKEM768_PUBLIC_BYTES>(case, "ek");
        let seed = hex(case, "m");
        assert_eq!(seed.len(), ENCAPS_SEED_BYTES, "encapsulation seed is m");
        let (ciphertext, shared) = seeded(&seed)
            .mlkem768_encapsulate(&public_key)
            .unwrap_or_else(|error| {
                panic!("tcId {}: encapsulation failed: {error:?}", tc_id(case))
            });
        assert_eq!(
            ciphertext.as_slice(),
            hex(case, "c"),
            "tcId {}: ciphertext",
            tc_id(case)
        );
        assert_eq!(
            shared.expose().as_slice(),
            hex(case, "k"),
            "tcId {}: shared secret",
            tc_id(case)
        );
    }
}

/// Covers both ACVP decapsulation reasons: `valid decapsulation` and
/// `modified ciphertext`. The latter pins FIPS 203 implicit rejection, which
/// must return the deterministic `J(z || c)` value rather than an error.
#[test]
fn mlkem768_acvp_decapsulation_known_answers() {
    let vectors = vectors();
    let cases = group(&vectors, "decapsulation");
    assert!(!cases.is_empty(), "decapsulation vectors are present");
    let mut rejections = 0;
    for case in cases {
        let secret_key = SecretBytes::new(hex_array::<MLKEM768_SECRET_BYTES>(case, "dk"));
        let ciphertext = hex_array::<MLKEM768_CIPHERTEXT_BYTES>(case, "c");
        let shared = seeded(&[])
            .mlkem768_decapsulate(&secret_key, &ciphertext)
            .unwrap_or_else(|error| {
                panic!("tcId {}: decapsulation failed: {error:?}", tc_id(case))
            });
        assert_eq!(
            shared.expose().as_slice(),
            hex(case, "k"),
            "tcId {}: shared secret ({})",
            tc_id(case),
            case["reason"].as_str().unwrap_or("unlabelled")
        );
        if case["reason"].as_str() == Some("modified ciphertext") {
            rejections += 1;
        }
    }
    assert!(
        rejections > 0,
        "implicit-rejection cases are part of the fixture"
    );
}

/// ACVP's `decapsulationKeyCheck` cases carry a `dk` whose embedded `H(ek)` has
/// been corrupted. FIPS 203 requires the hash check to reject those, which the
/// vendored build surfaces as [`CryptoError::MalformedInput`]. A ciphertext that
/// is merely wrong must still be accepted and implicitly rejected, so this pins
/// the boundary between "bad key" and "bad ciphertext".
///
/// The sibling `encapsulationKeyCheck` group is deliberately absent: every
/// invalid case there is a wrong-length `ek` (1600 bytes rather than 1184),
/// which the typed provider seam cannot represent, so there is no runtime
/// behaviour left to pin.
#[test]
fn mlkem768_rejects_malformed_decapsulation_keys() {
    let vectors = vectors();
    let cases = group(&vectors, "decapsulationKeyCheck");
    assert!(!cases.is_empty(), "decapsulation key-check vectors present");
    for case in cases {
        let secret_key = SecretBytes::new(hex_array::<MLKEM768_SECRET_BYTES>(case, "dk"));
        let accepted = seeded(&[])
            .mlkem768_decapsulate(&secret_key, &[0x5a; MLKEM768_CIPHERTEXT_BYTES])
            .is_ok();
        assert_eq!(
            accepted,
            case["testPassed"].as_bool().expect("testPassed is a bool"),
            "tcId {}: decapsulation key acceptance ({})",
            tc_id(case),
            case["reason"].as_str().unwrap_or("unlabelled")
        );
    }
}

#[test]
fn mlkem768_vector_fixture_shapes_are_well_formed() {
    let vectors = vectors();
    for case in group(&vectors, "keyGen") {
        assert_eq!(hex(case, "d").len(), 32);
        assert_eq!(hex(case, "z").len(), 32);
        assert_eq!(hex(case, "ek").len(), MLKEM768_PUBLIC_BYTES);
        assert_eq!(hex(case, "dk").len(), MLKEM768_SECRET_BYTES);
    }
    for case in group(&vectors, "encapsulation") {
        assert_eq!(hex(case, "ek").len(), MLKEM768_PUBLIC_BYTES);
        assert_eq!(hex(case, "m").len(), ENCAPS_SEED_BYTES);
        assert_eq!(hex(case, "c").len(), MLKEM768_CIPHERTEXT_BYTES);
        assert_eq!(hex(case, "k").len(), MLKEM_SHARED_BYTES);
    }
    for case in group(&vectors, "decapsulation") {
        assert_eq!(hex(case, "dk").len(), MLKEM768_SECRET_BYTES);
        assert_eq!(hex(case, "c").len(), MLKEM768_CIPHERTEXT_BYTES);
        assert_eq!(hex(case, "k").len(), MLKEM_SHARED_BYTES);
    }
    for case in group(&vectors, "decapsulationKeyCheck") {
        assert_eq!(hex(case, "dk").len(), MLKEM768_SECRET_BYTES);
        assert!(case["testPassed"].is_boolean());
    }

    // Both ACVP decapsulation reasons must be represented, otherwise a future
    // re-extraction could silently drop the implicit-rejection coverage.
    let reasons: std::collections::BTreeSet<&str> = group(&vectors, "decapsulation")
        .iter()
        .filter_map(|case| case["reason"].as_str())
        .collect();
    assert_eq!(
        reasons,
        ["modified ciphertext", "valid decapsulation"]
            .into_iter()
            .collect()
    );
}

/// The vendored build must not accept a truncated or oversized secret key
/// through the typed seam; sizes are compile-time checked, so this pins the
/// error mapping for a structurally valid but wrong-content key instead.
#[test]
fn mlkem768_decapsulation_maps_failures_to_malformed_input() {
    let secret_key = SecretBytes::new([0u8; MLKEM768_SECRET_BYTES]);
    assert_eq!(
        match seeded(&[]).mlkem768_decapsulate(&secret_key, &[0u8; MLKEM768_CIPHERTEXT_BYTES]) {
            Err(error) => error,
            Ok(_) => panic!("an all-zero decapsulation key was accepted"),
        },
        CryptoError::MalformedInput
    );
}
