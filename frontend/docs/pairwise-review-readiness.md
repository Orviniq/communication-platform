# Pairwise v1 independent-review packet

## Review status

This packet prepares implementation piece 13 for independent cryptographic and
application-security review. It is not a review report and does not claim approval.
Production pairwise messaging remains gated until an independent assessor records a
disposition for every blocking finding.

The normative construction is [Pairwise transport version 1](contracts/PAIRWISE-V1.md).
Reviewers should treat code, vectors, and this packet as subordinate to that profile and
report any divergence as a blocking interoperability/security defect.

## Source baseline

Primary sources were checked on 2026-07-29:

| Source | Bound revision/use |
|---|---|
| Signal PQXDH | Revision 3, last updated 2024-01-23; DH ordering, signed-prekey lifecycle, initial-session composition |
| Signal Double Ratchet | Revision 4, 2025-11-04; state machine, skipped-key handling, integration with PQXDH |
| NIST FIPS 203 | Final ML-KEM standard; ML-KEM-768 sizes and algorithm behavior |
| RFC 7748 | X25519 encoding and shared-secret operation |
| RFC 5869 | HKDF extract/expand |
| RFC 8439 plus XChaCha provider vectors | AEAD primitive/provider validation; project profile uses the pinned RustCrypto XChaCha implementation |

The project deviation from Signal PQXDH is explicit: the backend's unsigned PQ one-time
key is additive, while the signed ML-KEM prekey is always used. Review must determine
that concatenating the optional one-time contribution after the mandatory authenticated
PQ contribution neither introduces transcript ambiguity nor weakens the base hybrid
guarantee.

## Security claims in scope

- Missing, partial, invalid, or unauthenticated PQ material cannot reach session state.
- An initial root depends on both X25519 and the signed ML-KEM-768 contribution.
- Optional classical/PQ one-time private keys become unreachable only in the successful
  receive commit that installs the authenticated session and opened opaque payload.
- Signed-prekey overlap permits delayed envelopes for eight days and rejects them after
  erasure.
- Every payload authenticates the exact version, suite, purpose, recipient device, and
  ratchet header.
- A message key is used once; ambiguous transport retry reads the persisted exact
  ciphertext and does not call the ratchet again.
- Replays, stale compare-and-swap revisions, state tamper/substitution, counter
  overflow, unknown versions, and malformed padding fail closed.
- Skipped keys are bounded to 2,000 per device-pair state and 20,000 transactionally per
  account.
- Repair state originates only from a control event authenticated by the existing
  ratchet and is consumed once by a fresh mandatory-hybrid initiation.
- Simultaneous initiation converges independently of delivery order.
- Server-visible initial bytes do not contain sender user/device IDs or sender identity
  public keys.

Out of scope: rollback of the entire encrypted local database to a prior internally
consistent snapshot, traffic-analysis resistance, hiding live routing from server root,
post-quantum authentication, post-quantum ratchet healing after initial establishment,
device compromise, Web/Wasm interoperability, application-message authorization, and
MLS.

## Implementation inventory for review

Review the following boundaries after piece 13 is complete:

- Rust provider and secret wrappers under `native/crypto_core/src/`;
- pairwise/prekey state machines and their strict binary decoders;
- the single C ABI pairwise operation and `communication_crypto.h` declaration;
- Android export allowlist and three-ABI packaging script;
- Dart FFI allocation, bounds, zeroing, isolate ownership, and typed-result decoding;
- Drift schema/migration and compare-and-swap transaction code;
- REST DTO strictness and replay-safety settings for count, replenish, claim, and send;
- recipient resolution for peer devices and the sender's other devices; and
- sync receive/ack and stale/revoked-device invalidation paths.

Every `unsafe` Rust block and Dart `dart:ffi` allocation must have a local size/lifetime
argument. Error values must remain payload-free. No debug formatting implementation may
expose opaque states, plaintext, keys, ciphertext, tokens, or stable identifiers.

## Required vector matrix

The checked-in project vector set must pin exact bytes for:

1. signed-PQ only;
2. signed-PQ plus classical one-time key;
3. signed-PQ plus PQ one-time key;
4. all optional one-time keys;
5. initial sender seal, init signature, PQXDH root, first ratchet header, padded envelope,
   initiator state, and responder state;
6. one reply/DH step and multiple same-chain messages;
7. out-of-order messages and skipped-key deletion;
8. simultaneous initiation in both delivery orders;
9. authenticated repair request and accepted replacement;
10. day-seven rotation, day-eight overlap, and expiry rejection; and
11. stable state reserialization and authenticated skipped-key count.

Negative mutations cover every signature, identity/device/version field, KEM key and
ciphertext, X25519 public key, presence flag/sentinel, header length/flag/counter,
session ID, purpose, recipient ID, AEAD tag, real length, bucket size, state tag, repair
token, replayed message, and expired key.

Published primitive vectors are kept separate from project composition vectors so the
implementation cannot validate a construction solely against bytes it generated itself.

## State-machine questions for the assessor

- Can any failure after key derivation commit a state without its exact ciphertext, or
  vice versa?
- Can two concurrent transactions each pass the 20,000-key account bound?
- Can a crash between initial decrypt and commit delete a one-time private key?
- Can an accepted initial envelope be replayed after its one-time key is deleted?
- Can a malicious server cause the optional unsigned PQ key to replace, cancel, reorder,
  or ambiguously frame the mandatory signed-PQ contribution?
- Does sender probing expose plaintext or mutate prekeys before the peer bundle is fully
  authenticated?
- Can a valid but stale signed prekey outlive the documented overlap?
- Can a same-device `cross_sig` change bypass exact `bundle_version + 1`, immutable
  identity fields, signed prekey verification, or device-log extension?
- Does simultaneous initiation apply each initial logical payload once while converging
  to one outgoing session?
- Can an unauthenticated or replayed repair token replace a healthy session?
- Do stale/revoked-device responses prevent all future use of the old session and exact
  pending target?

## Reproduction commands

Run from `frontend/` with the repository-pinned toolchains and offline cache:

```powershell
cargo fmt --manifest-path native/crypto_core/Cargo.toml -- --check
cargo test --locked --manifest-path native/crypto_core/Cargo.toml
cargo clippy --locked --all-targets --all-features --manifest-path native/crypto_core/Cargo.toml -- -D warnings
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --fatal-infos --fatal-warnings
flutter test
powershell -File tool/build_rust_android.ps1 all
flutter build apk --debug --flavor development --target lib/main_development.dart
flutter build apk --release --flavor production --target lib/main_production.dart
git diff --check
git diff --name-only -- ../backend
```

The packaged Android smoke test additionally requires a connected supported Android
device or emulator. Web byte equality is deliberately absent from this packet and
remains a post-v1 gate.

## Review disposition template

| Area | Reviewer | Revision/hash | Finding | Severity | Required action | Closed by |
|---|---|---|---|---|---|---|
| Composition/transcript | | | | | | |
| Ratchet/state machine | | | | | | |
| Persistence/concurrency | | | | | | |
| FFI/memory handling | | | | | | |
| Android packaging | | | | | | |
| Adversarial tests/fuzzing | | | | | | |

Approval requires all blocking/high findings closed, exact reviewed source hashes
recorded, vector reproduction on the packaged Android artifact, and explicit acceptance
of any residual risk. Empty rows never imply approval.
