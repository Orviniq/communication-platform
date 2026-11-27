# Independent cryptographic review scope and engagement

## Review status

**Updated 2026-09-13.** The MLS track this engagement was originally prepared for is cancelled: the
server deleted MLS
([server ADR-0001](../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)),
and the MLS profile and the closed-beta PQ MLS review packet were deleted from this tree.
Every MLS gate, prerequisite, and packet named below is historical and can no longer
open. The pairwise scope is unaffected.

**Updated 2026-09-14.** The closed-beta MLS track is cancelled, not blocked ([ADR-075](../architecture/decisions/075-pairwise-groups.md)), so
where this document records an MLS gate or prerequisite as open or blocked, that is the
state it was in when the track was cancelled. Files marked deleted in work packages WP1,
WP2, WP5, WP6 and WP7 were deleted with the MLS track. The signed group control events
that replaced the MLS group construction ([MESSAGES.md](../contracts/MESSAGES.md))
and the voice room control and signalling formats ([VOICE-V1.md](../contracts/VOICE-V1.md))
are consolidated into the active v1 review scope below; ADR-075 and ADR-077 leave their
independent review open.

This document prepares the *engagement* that ADR-017 requires, and that production gate 7
in the deleted MLS profile also required, together with the surviving
[Pairwise v1 review packet](#pairwise-v1-review-packet) and the
[Consolidated active v1 review scope](#consolidated-active-v1-review-scope). **It retains
nobody, names nobody as retained, and closes nothing.**

- No reviewer, firm, or individual named below has been approached, contacted, solicited,
  or engaged. Nobody has agreed to anything. Availability, willingness, price, and
  jurisdictional feasibility are unknown for every name in this document and cannot be
  established from inside this repository.
- Gate 7 ("An independent cryptographic review closes all blocking findings") remains
  **open and untouched**. So do gates 1-6. Preparing an engagement or a review packet is
  not a review, does not claim approval, and a perfect qualification bar with no reviewer
  behind it satisfies no gate, not partially and not conditionally.
- The Phase-A preflight row "Qualified independent reviewer available for the final
  implementation" remains **Blocked**. This document does not change its result. It
  supplies the "scope of work" half of what that row says is missing; the "named, retained
  reviewer" and "review schedule" halves are external and stay missing.
- The active v1 client stays gated until an independent assessor records a disposition for
  every blocking finding across the
  [Consolidated active v1 review scope](#consolidated-active-v1-review-scope) and
  [Pairwise v1 review packet](#pairwise-v1-review-packet).

The review packet material for this engagement:

- Closed-beta PQ MLS independent-review packet (deleted)
- [Pairwise v1 review packet](#pairwise-v1-review-packet)
- [Consolidated active v1 review scope](#consolidated-active-v1-review-scope)

Everything in the [Qualification bar](#qualification-bar), [Scope of work](#scope-of-work),
and [Deliverables required before the review gate can close](#deliverables-required-before-the-review-gate-can-close)
sections below is complete locally and needs no external party. Everything in
[Candidate evaluation](#candidate-evaluation), [Funding routes](#funding-routes), and
[What remains externally blocked](#what-remains-externally-blocked) is a *proposal for evaluation*,
not an action taken.

---

## Consolidated active v1 review scope

Live source code and test fixtures were inspected at `bcc64eba` (the Phase 1 step 1
baseline recorded in [STATUS.md](../STATUS.md)); subsequent Phase 3 documentation
restructuring (`6c04d4e`) changed no runtime code, native crate, Kotlin file, or build
script (`git diff --stat bcc64eba..HEAD -- frontend/lib/ frontend/native/ frontend/android/ frontend/tool/`
contains only doc-path comments and l10n text). The exact full commit hash under review
must be fixed at engagement start in `D1` and `D2`.

| Review area | Primary specifications & evidence paths | Inspected revision | Outstanding assessments | Responsible acceptance role |
|---|---|---|---|---|
| **Pairwise transport v1 (hybrid PQXDH & Double Ratchet)** | [PAIRWISE-V1.md](../contracts/PAIRWISE-V1.md), [CRYPTO.md](../contracts/CRYPTO.md), [pairwise.rs](../../native/crypto_core/src/pairwise.rs), [prekey_state.rs](../../native/crypto_core/src/prekey_state.rs), [provider.rs](../../native/crypto_core/src/provider.rs), [device_signatures.rs](../../native/crypto_core/src/device_signatures.rs), [enrollment.rs](../../native/crypto_core/src/enrollment.rs), [vectors/README.md](../../native/crypto_core/vectors/README.md), [pairwise-v1.json](../../native/crypto_core/vectors/pairwise-v1.json), [mlkem768-acvp-fips203.json](../../native/crypto_core/vectors/mlkem768-acvp-fips203.json), [pairwise_opaque_envelope_inspector.dart](../../lib/features/synchronization/infrastructure/pairwise_opaque_envelope_inspector.dart), [pairwise_session_crypto.dart](../../lib/shared/infrastructure/crypto/native/pairwise_session_crypto.dart), [pairwise tests](../../test/features/pairwise) | `bcc64eba` (fix exact commit in `D2` at engagement start) | Independent assessment of mandatory `pq_spk` + optional unsigned `pq_otpk` composition, Double Ratchet state machine, 2,000/20,000 skipped-key bounds, simultaneous initiation, authenticated repair (`CPRRV001`), 7d/8d rotation overlap, held first-message probe & non-committing `CPCTV001` kind-3 read exception ([ADR-093](../architecture/decisions/093-held-first-message.md)), and missing parser/state-machine fuzzing on the pinned stable Rust toolchain ([VERIFY.md](../runbooks/VERIFY.md#crypto-core-tests)). | **Independent Cryptographic Reviewer** (`D3`, `D5`, `D6`) + **Project Owner** (`D1` scope, `D4` fixes/vectors, `D7` itemised residual-risk acceptance) |
| **Signed group control (`CPGSV001`) & voice room control/signalling (`CPVRV001` / `CPVSV001`)** | [MESSAGES.md](../contracts/MESSAGES.md#groups), [VOICE-V1.md](../contracts/VOICE-V1.md), [ADR-075](../architecture/decisions/075-pairwise-groups.md), [ADR-077](../architecture/decisions/077-voice-mesh.md), [ADR-096](../architecture/decisions/096-group-moderation.md), [group_control.rs](../../native/crypto_core/src/group_control.rs), [room_control.rs](../../native/crypto_core/src/room_control.rs), [application.rs](../../native/crypto_core/src/application.rs), [cbor.rs](../../native/crypto_core/src/cbor.rs), [drift_group_repository.dart](../../lib/features/groups/infrastructure/drift_group_repository.dart), [native_group_control_crypto.dart](../../lib/features/groups/infrastructure/native_group_control_crypto.dart), [drift_room_repository.dart](../../lib/features/voice/infrastructure/drift_room_repository.dart), [native_room_control_crypto.dart](../../lib/features/voice/infrastructure/native_room_control_crypto.dart), [pairwise_voice_signal_crypto.dart](../../lib/features/voice/infrastructure/pairwise_voice_signal_crypto.dart), [room_inbound_coordinator.dart](../../lib/features/voice/application/room_inbound_coordinator.dart), [room_session_starter.dart](../../lib/features/voice/application/room_session_starter.dart), [voice_call_engine.dart](../../lib/features/voice/application/voice_call_engine.dart), [group tests](../../test/features/groups), [voice tests](../../test/features/voice) | `bcc64eba` (voice build 5 run at `53ff386`) | No independent review has examined `group_control.rs` (`chat:v1:group-control`), `room_control.rs` (`chat:v1:room-control`), hash-chain fork quarantine & `CPGSV001`/`CPVRV001` state recovery, channel separation (`CPVRV001` durable vs `CPVSV001` volatile), moderation re-folding (`ADR-096`), `VoiceCallEngine` post-commit removal timing gap ([STATUS.md](../STATUS.md#voice-implementation-gaps)), or planned v2 room roles ([CLIENT_VOICE_ROLES.md](../../../docs/client/CLIENT_VOICE_ROLES.md)). | **Independent Cryptographic Reviewer** (`D3`, `D5`, `D6`) + **Project Owner** (`D4`/`D7` and v2/removal-gap resolution) |
| **Android key storage & platform boundaries** | [ANDROID.md](../architecture/ANDROID.md#key-and-data-protection), [CLIENT-THREAT-MODEL.md](CLIENT-THREAT-MODEL.md), [SIGNING.md](../runbooks/SIGNING.md), [ProtectedStorageChannel.kt](../../android/app/src/main/kotlin/com/example/communication_platform/ProtectedStorageChannel.kt), [MainActivity.kt](../../android/app/src/main/kotlin/com/example/communication_platform/MainActivity.kt), [BackgroundDelivery.kt](../../android/app/src/main/kotlin/com/example/communication_platform/BackgroundDelivery.kt), [SustainedDelivery.kt](../../android/app/src/main/kotlin/com/example/communication_platform/SustainedDelivery.kt), [VoiceCall.kt](../../android/app/src/main/kotlin/com/example/communication_platform/VoiceCall.kt), [MessageAlertChannel.kt](../../android/app/src/main/kotlin/com/example/communication_platform/MessageAlertChannel.kt), [AttachmentChannel.kt](../../android/app/src/main/kotlin/com/example/communication_platform/AttachmentChannel.kt), [AndroidManifest.xml](../../android/app/src/main/AndroidManifest.xml), [build.gradle.kts](../../android/app/build.gradle.kts), [production-release-identity.properties](../../android/production-release-identity.properties), [render_production_trust.sh](../../tool/render_production_trust.sh), [verify_release_apk.sh](../../tool/verify_release_apk.sh), [secure_local_storage_platform_test.dart](../../test/architecture/secure_local_storage_platform_test.dart), [screen_capture_policy_test.dart](../../test/architecture/screen_capture_policy_test.dart), [production_release_packaging_test.dart](../../test/architecture/production_release_packaging_test.dart) | `bcc64eba` (`f85196de` build 2, `53ff386` build 5, `973e6eb8` probes) | Independent sign-off on `AndroidKeyStore` AES-256-GCM wrapping (`ProtectedStorageChannel.kt`: StrongBox preference with TEE/software fallback, `noBackupFilesDir/storage_key_v1.bin`, `allowBackup="false"`, `FLAG_SECURE`, wipe on logout/revocation/key-loss); hardware-backed Keystore physical-device verification; open owner policy decision on Dart runtime SPKI pinning vs exclusive private-CA anchoring ([ADR-076](../architecture/decisions/076-production-signing.md) D7); closed sustained-delivery matrix ([SUSTAINED-DELIVERY.md](../runbooks/SUSTAINED-DELIVERY.md#the-gate)). | **Independent Security / Mobile Reviewer** (`D3`, `D5`, `D6`) + **Project Owner** (`ADR-076` D7 policy decision, physical-device matrix, `D7` acceptance) |
| **Persistence & concurrency (Drift / SQLCipher)** | [LOCAL-DATA.md](../architecture/LOCAL-DATA.md), [SYNC.md](../architecture/SYNC.md), [local_database.dart](../../lib/features/local_storage/infrastructure/database/local_database.dart) (schema **26**), [drift_pairwise_transport_store.dart](../../lib/features/pairwise/infrastructure/drift_pairwise_transport_store.dart), [drift_sync_store.dart](../../lib/features/synchronization/infrastructure/drift_sync_store.dart), [drift_group_repository.dart](../../lib/features/groups/infrastructure/drift_group_repository.dart), [drift_room_repository.dart](../../lib/features/voice/infrastructure/drift_room_repository.dart), [drift_application_event_projector.dart](../../lib/features/messaging/infrastructure/drift_application_event_projector.dart), [local_database_migration_test.dart](../../test/features/local_storage/infrastructure/local_database_migration_test.dart), [local_database_index_plan_test.dart](../../test/features/local_storage/infrastructure/local_database_index_plan_test.dart), [sync tests](../../test/features/synchronization) | `bcc64eba` | Independent assessment of compare-and-swap under control revision/hash and pairwise session revisions, two-transaction send/prepare boundary (`pending_send_preparations` vs `outbox_operations`), crash-safe receive/ack and exact-ciphertext retry, 20,000-key account bound under concurrent writes, held-envelope limits/expiry (`ADR-093`), `IsolateNameServer` shared SQLCipher access (`shareAcrossIsolates`) across Activity / Sustained / Deferred owners, and schema-26 migration/interrupted-upgrade fixtures on real Android hardware. | **Independent Reviewer** (`D3`, `D5`) + **Project Owner** (`D4`/`D7` and device migration/crash tests) |
| **FFI, native core & packaging boundary** | [ANDROID.md](../architecture/ANDROID.md#piece-07-crypto-core-delivery-scope), [lib.rs](../../native/crypto_core/src/lib.rs) (`#![forbid(unsafe_op_in_unsafe_fn)]`, 16 exported symbols, status codes 0–14), [bounds.rs](../../native/crypto_core/src/bounds.rs) (1 MiB `MAX_INPUT_BYTES`), [error.rs](../../native/crypto_core/src/error.rs), [secret.rs](../../native/crypto_core/src/secret.rs), [communication_crypto.h](../../native/crypto_core/include/communication_crypto.h) (2 MiB `CP_CRYPTO_V1_PAIRWISE_MAX_IO_BYTES`), [isolate_crypto_core_worker.dart](../../lib/shared/infrastructure/crypto/native/isolate_crypto_core_worker.dart), [crypto_core_ffi.dart](../../lib/shared/infrastructure/crypto/native/crypto_core_ffi.dart), [pairwise_crypto_ffi.dart](../../lib/shared/infrastructure/crypto/native/pairwise_crypto_ffi.dart), [enrollment_crypto_ffi.dart](../../lib/shared/infrastructure/crypto/native/enrollment_crypto_ffi.dart), [build_rust_android.sh](../../tool/build_rust_android.sh), [build_libsodium_android.sh](../../tool/build_libsodium_android.sh), [verify_release_apk.sh](../../tool/verify_release_apk.sh), [crypto_core_boundary_test.dart](../../test/architecture/crypto_core_boundary_test.dart), [crypto_core_android_smoke_test.dart](../../integration_test/crypto_core_android_smoke_test.dart) | `bcc64eba` | Independent audit of every `unsafe` block and C FFI wrapper in `lib.rs` and `provider.rs`, Dart `dart:ffi` allocation/bounds/buffer zeroing (`_clear` before `calloc.free`), single-isolate ownership (`IsolateCryptoCoreWorker`), payload-free error discipline, static libsodium 1.0.22 + `mlkem-native` v1.2.0 3-ABI packaging, absence of `cp_crypto_v1_beta_mls_operation`, and representative connected-device smoke execution. | **Independent Reviewer** (`D3`, `D5`) + **Project Owner** (`D4`/`D7` and packaged Android smoke execution) |

**Unfilled review decisions remain open:** No reviewer is retained, `D1`–`D7` have not been produced, `Appendix A` and `Appendix B` are empty, and the `ADR-076` D7 runtime SPKI pinning policy decision remains open for the owner.

---

## Pairwise v1 review packet

This packet prepares the pairwise transport implementation for independent cryptographic and
application-security review. It is not a review report and does not claim approval.
Production pairwise messaging remains gated until an independent assessor records a
disposition for every blocking finding.

The normative construction is [Pairwise transport version 1](../contracts/PAIRWISE-V1.md).
Reviewers should treat code, vectors, and this packet as subordinate to that profile and
report any divergence as a blocking interoperability/security defect.

### Pairwise source baseline

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

### Security claims in scope

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

### Implementation inventory for review

Review the following boundaries:

- Rust provider and secret wrappers under `native/crypto_core/src/`;
- pairwise/prekey state machines and their strict binary decoders;
- the pairwise C ABI operations (`cp_crypto_v1_pairwise_operation`,
  `cp_crypto_v1_identity_operation`, enrollment exports) and `communication_crypto.h`
  declarations;
- Android export allowlist (16 `foundation` symbols) and three-ABI packaging script;
- Dart FFI allocation, bounds (1 MiB standard / 2 MiB pairwise mux), zeroing, isolate
  ownership (`IsolateCryptoCoreWorker`), and typed-result decoding;
- Drift schema/migration (currently schema 26) and compare-and-swap transaction code;
- REST DTO strictness and replay-safety settings for count, replenish, claim, and send;
- recipient resolution for peer devices and the sender's other devices; and
- sync receive/ack and stale/revoked-device invalidation paths.

Every `unsafe` Rust block and Dart `dart:ffi` allocation must have a local size/lifetime
argument. Error values must remain payload-free. No debug formatting implementation may
expose opaque states, plaintext, keys, ciphertext, tokens, or stable identifiers.

### Required vector matrix

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

### State-machine questions for the assessor

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

### Reproduction commands

Run from `frontend/` with the repository-pinned toolchains and offline cache (see
[VERIFY.md](../runbooks/VERIFY.md) for prerequisites and separation between unsigned CI
and signed distribution):

```powershell
cargo fmt --manifest-path native/crypto_core/Cargo.toml -- --check
cargo test --locked --manifest-path native/crypto_core/Cargo.toml
cargo clippy --locked --all-targets --all-features --manifest-path native/crypto_core/Cargo.toml -- -D warnings
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --fatal-infos --fatal-warnings
flutter test
powershell -File tool/build_rust_android.ps1 all
flutter build apk --debug --flavor development --target lib/main_development.dart
sh ./tool/ci.sh
git diff --check
git diff --name-only -- ../backend
```

For a signed, provisioned distribution build, run `tool/build_production_release.sh` as
documented in [SIGNING.md](../runbooks/SIGNING.md#2-build) and
[VERIFY.md](../runbooks/VERIFY.md#4-signed-distribution-build-and-verification---production).
The packaged Android smoke test (`integration_test/crypto_core_android_smoke_test.dart`)
additionally requires a connected supported Android device or emulator (`--flavor development`).
Web byte equality is deliberately absent from this packet and remains a post-v1 gate.

### Review disposition template

| Area | Reviewer | Revision/hash | Finding | Severity | Required action | Closed by |
|---|---|---|---|---|---|---|
| Composition/transcript (pairwise) | | | | | | |
| Ratchet/state machine | | | | | | |
| Signed group & room control (`CPGSV001`/`CPVRV001`/`CPVSV001`) | | | | | | |
| Android key storage & trust boundaries | | | | | | |
| Persistence/concurrency (Drift/SQLCipher) | | | | | | |
| FFI/memory handling & packaging | | | | | | |
| Adversarial tests/fuzzing | | | | | | |

Approval requires all blocking/high findings closed, exact reviewed source hashes
recorded, vector reproduction on the packaged Android artifact, and explicit acceptance
of any residual risk. Empty rows never imply approval.

---

## What the engagement has to satisfy

| Requirement | Where it is written | What it demands |
|---|---|---|
| ADR-017 | [decision register](../architecture/decisions/README.md) | Shared reviewed crypto core **and independent assessment**; "a custom, unaudited cryptographic implementation is not production-ready" |
| ADR-026 | [decision register](../architecture/decisions/README.md) | Review is one of the mandatory conditions alongside registry assignment, suite identifier, provider support, and Android interoperability. ADR-026 also forbids assigning a production identifier locally, which is why no review outcome can substitute for gate 2 |
| Production gate 7 | MLS profile (deleted) | "An independent cryptographic review closes all blocking findings" |
| Phase-A prerequisite 5 | MLS profile (deleted) | A qualified independent reviewer must be *available and retained*, with a recorded scope of work and schedule |
| Pairwise production gate | [pairwise transport v1](../contracts/PAIRWISE-V1.md), [Pairwise v1 review packet](#pairwise-v1-review-packet) | An independent assessor records a disposition for every blocking finding, with reviewed source hashes and residual-risk acceptance |
| Group & voice control review | [ADR-075](../architecture/decisions/075-pairwise-groups.md), [ADR-077](../architecture/decisions/077-voice-mesh.md), [MESSAGES.md](../contracts/MESSAGES.md), [VOICE-V1.md](../contracts/VOICE-V1.md) | Independent assessment of signed group (`CPGSV001`) and room (`CPVRV001`/`CPVSV001`) control chains, recovery, and channel separation |
| Threat-model sign-off | [client threat model](CLIENT-THREAT-MODEL.md) | An independent reviewer signs off the protocol, implementation boundary, and Android key handling |

Note what gate 7 does **not** do. Closing it opens nothing on its own: gates 1, 2, and 3
are registry, specification, and upstream-provider conditions that no review can supply,
and the MLS profile records that gates 1-3 "cannot be advanced by any work in this
repository". A completed review moves exactly one gate.

---

## Qualification bar

The bar is stated as evidence a candidate must be able to **show**, not as reputation.
Every item is verifiable by the owner before any money is committed, from public material
or from material the candidate supplies on request. A candidate who cannot evidence a
mandatory item does not meet the bar, regardless of standing.

### Mandatory evidence

| # | Requirement | Evidence that satisfies it | Why this implementation needs it |
|---|---|---|---|
| **Q1** | **Demonstrated MLS competence** *(superseded for active v1 scope by pairwise & signed hash-chain control competence)* | Published work on RFC 9420 or its drafts: specification authorship, a machine-checked or hand-written security analysis, or a published assessment of an MLS implementation or an MLS-based deployment | Written when the group construction was MLS. It is not any more: a group is a set of pairwise sessions and the MLS core is deleted ([ADR-075](../architecture/decisions/075-pairwise-groups.md)), so no material now in scope is MLS |
| **Q2** | **Demonstrated hybrid post-quantum KEM competence** | Published work on ML-KEM/FIPS 203, KEM combiners, hybrid PQ/T constructions, HPKE, or PQ key agreement — specification, analysis, implementation, or assessment | The pairwise track is hybrid PQXDH. The beta's *non-standard* hybrid KEM, which diverged from `TBD2` in ten recorded ways (rows D1-D10 of the deleted MLS profile) and posed the hardest question in the MLS packet, was deleted with the MLS core ([ADR-075](../architecture/decisions/075-pairwise-groups.md)) |
| **Q3** | **Implementation-level review, not design-only** | At least one published engagement that read source and reported source-anchored findings, not solely a design/architecture opinion | The active scope is implementation-anchored. A design review of the profile documents alone would leave the Rust, Dart, and Kotlin inventory unread |
| **Q4** | **Rust and FFI boundary competence** | Published work involving Rust cryptographic code, `unsafe` review, memory/secret lifetime, or foreign-function boundaries | The core is Rust with `unsafe` FFI and C-wrapper blocks in `lib.rs` and `provider.rs`, 1 MiB/2 MiB `dart:ffi` allocation paths with explicit zeroing, and a dedicated worker isolate (`IsolateCryptoCoreWorker`). `mls_beta.rs`, which had no `unsafe` of its own, was deleted with the MLS core ([ADR-075](../architecture/decisions/075-pairwise-groups.md)) |
| **Q5** | **Protocol-invention review capability** | Evidence of reviewing bespoke state machines, concurrency, and persistence — not only primitive or parameter checking | Project-specific state machines and hash chains (`CPGSV001`, `CPVRV001`, `CPVSV001`, `CPRRV001` repair, held first-message state, two-transaction send/commit, FFI boundary, Android Keystore wrap, and redaction) have no external specification or conformance vector |
| **Q6** | **A published report of the required shape** | At least one publicly readable report containing, per finding: an identifier, a severity, a source location, and a disposition; plus a statement of what was and was not in scope | [Deliverables required before the review gate can close](#deliverables-required-before-the-review-gate-can-close) requires exactly this shape. A candidate who has never produced it is being asked to invent their deliverable format on this engagement |
| **Q7** | **Named assessors** | The individuals who will do the work are named, with their own attributable prior work | A firm brand is not evidence that the people assigned to this engagement have Q1-Q5. Reports that name their assessors are the norm in this field, including in the closest comparable engagements |
| **Q8** | **Fix verification, in writing, as part of the engagement** | A prior engagement where the assessor verified remediation and said so, or a written commitment to do so here | D5 (retest confirmation) cannot be produced by the owner. If the candidate will not retest, the gate cannot close |
| **Q9** | **Willingness to work under a stated out-of-scope list and to record residual risk** | Acceptance of the packets' "explicitly out of scope" sections as engagement boundaries, and willingness to record what was *not* assessed | The out-of-scope list is deliberate (no sanitizer/Miri/coverage-guided fuzzing on the pinned stable Rust toolchain, no physical-device crash matrix, no state-format migration fuzzing). A reviewer who silently treats these as covered would produce a report that overstates assurance |

### Independence requirements

Independence is a property of the *engagement*, not a compliment paid to the reviewer.

| # | Requirement |
|---|---|
| **I1** | The reviewer did not author, co-author, maintain, or contribute to any code, document, vector, or decision under review, and is not doing so during the engagement |
| **I2** | The reviewer has no ownership, employment, contractor, advisory, or revenue relationship with the project owner beyond this engagement, and none is created by it |
| **I3** | The reviewer discloses, in writing and before the engagement starts, any relationship to the parties whose work this implementation *depends on or criticises*, or did while it carried the MLS core deleted under [ADR-075](../architecture/decisions/075-pairwise-groups.md): `mls-rs` and AWS; OpenMLS and Phoenix R&D; the authors of `draft-ietf-mls-pq-ciphersuites`, `draft-ietf-hpke-pq`, `draft-irtf-cfrg-concrete-hybrid-kems`, and `draft-connolly-cfrg-xwing-kem`; and libsodium and mlkem-native. Disclosure is not disqualification — the strongest candidates are close to this work — but an undisclosed relationship is |
| **I4** | The reviewer's fee, scope, and continuation are not contingent on the findings, their severity, or a favourable conclusion. No clause may let the owner suppress a finding, and the reviewer keeps editorial control of the findings text |
| **I5** | The reviewer states positively, in the report, what they did **not** review, and what their conclusions therefore do not cover |

### Disqualifying conditions

A candidate is out, regardless of other evidence, if any of these hold:

1. They wrote or maintain part of what they would be reviewing (I1).
2. They will not name the individuals doing the work (Q7).
3. They will not retest fixes (Q8).
4. Their only relevant track record is general application penetration testing with no
   cryptographic or protocol content — a competent app pentest is not a cryptographic
   review and cannot close gate 7.
5. They require that findings be delivered only as a summary or a pass/fail conclusion,
   without a per-finding register.
6. They would treat the project's bespoke state machines and protocol constructions as out
   of scope, or would scope the engagement to primitive conformance only.
7. They offer to review against `TBD2` as a conformance target. The beta was not `TBD2` and
   never had been; such an engagement would have produced wrong conclusions by construction
   (see the deleted packet's "The one thing to read first").

### How the bar is applied

Q2-Q9 and I1-I5 are mandatory for the active v1 engagement (with Q1 historical since MLS
removal). There is no scoring, no weighting, and no "strong overall" path past a missing
item. Where a single candidate cannot evidence everything, the bar is met by a
**combination** — for example an implementation-review practice for Q3/Q4/Q6/Q8 plus a
named specialist for Q2 — provided the combination is contracted as one engagement with
one findings register and one retest, and each named assessor individually satisfies I1-I5.
Two disconnected reviews that never reconcile their findings do not satisfy the bar,
because no single party ever states what was and was not covered overall.

---

## Scope of work

Bounded to this implementation, at a pinned revision, using the
[Consolidated active v1 review scope](#consolidated-active-v1-review-scope) and
[Pairwise v1 review packet](#pairwise-v1-review-packet) as the reviewer's entry point.

### Engagement source baseline

| | |
|---|---|
| Repository | this repository, `frontend/` (`lib/`, `native/`, `android/`, `tool/`) only |
| Revision under review | to be fixed at engagement start and recorded verbatim in D1 and D2 |
| Current live code inspection baseline | `bcc64eba` (Phase 1 step 1; Phase 3 docs PR merged at `6c04d4e` with zero functional/native/Android/tool code changes since `bcc64eba`) |
| Historical MLS engagement baseline (2026-08-18) | `4e65eaf4f0e4a017a42b48b49a444570f47cbffb` (branch `frontend`, committed 2026-08-18); `HEAD` then `76056597d34987d615d1616cdfa2cc7adb036725` (docs-only delta) |
| Toolchain | Rust 1.97.1 stable, Flutter 3.44.7, Dart 3.12.2, Android NDK 28.2.13676358, exactly as pinned and recorded in the repository |
| Backend | **read-only**. `backend/` is not modifiable from this track and is not part of this scope |

The reviewer works from a fixed revision. If the owner lands changes during the
engagement, they become a *second* recorded revision in D2, or they wait.

### Work packages

| WP | Subject | Primary material | Deliverable contribution |
|---|---|---|---|
| **WP0** | Scope agreement and threat-model reconciliation. Confirm the claims in scope, confirm the out-of-scope list is understood and accepted, and reconcile against [the client threat model](CLIENT-THREAT-MODEL.md) | [Consolidated active v1 review scope](#consolidated-active-v1-review-scope), [Security claims in scope](#security-claims-in-scope), [the client threat model](CLIENT-THREAT-MODEL.md) | D1 |
| **WP1** | **Historical (deleted with MLS): the ten MLS project inventions.** | Deleted MLS packet; `native_beta_group_mls.dart` (deleted), `mls_beta.rs` (deleted) | Historical only |
| **WP2** | **Historical (deleted with MLS): suite assembly and the recorded KEM divergence.** | MLS profile (deleted) rows D1-D10; [mls-rs-hybrid-kem-defect-report.md](../archive/beta-mls-core/mls-rs-hybrid-kem-defect-report.md); `mls_beta.rs` (deleted); `beta_kem_vectors.rs` (deleted) | Historical only |
| **WP3** | **Pairwise transport v1.** Hybrid PQXDH composition and transcript, the ratchet state machine, skipped-key bounds, repair, rotation overlap, revocation, held first messages | [pairwise transport v1](../contracts/PAIRWISE-V1.md); [Pairwise v1 review packet](#pairwise-v1-review-packet) | D3 |
| **WP3b** | **Signed group control & voice room control/signalling.** `CPGSV001` and `CPVRV001` hash chains, fork quarantine, state recovery, `CPVSV001` volatile signalling, channel separation, moderation re-folding, removal timing | [MESSAGES.md](../contracts/MESSAGES.md#groups), [VOICE-V1.md](../contracts/VOICE-V1.md), `group_control.rs`, `room_control.rs`, `application.rs`, `drift_group_repository.dart`, `drift_room_repository.dart`, `voice_call_engine.dart` | D3 |
| **WP4** | **Persistence, concurrency, and the commit boundary.** Compare-and-swap under control revision and hash; crash between commit and fan-out; exact-ciphertext retry; the 20,000-key account bound under concurrent transactions; shared SQLCipher across isolates | `drift_group_repository.dart`, `drift_room_repository.dart`, `drift_pairwise_transport_store.dart`, `drift_sync_store.dart`, `drift_application_event_projector.dart`, `local_database.dart` (schema 26) | D3 |
| **WP5** | **The FFI and Android key-storage boundary.** The 16 C ABI exports (`lib.rs`, `communication_crypto.h`), `unsafe` blocks in `lib.rs` and `provider.rs`, 1 MiB / 2 MiB `dart:ffi` allocations and zero-and-free paths, isolate ownership, typed-response decoding, Android Keystore AES-256-GCM wrapping, `FLAG_SECURE`, and wipe boundaries | `lib.rs`, `provider.rs`, `isolate_crypto_core_worker.dart`, `*_ffi.dart`, `ProtectedStorageChannel.kt`, `MainActivity.kt` | D3 |
| **WP6** | **Isolation and packaging.** That the production release artifact contains no beta code path, uses pinned `libsodium` + `mlkem-native` across all three ABIs, checks live SPKI/CA provisioning, and enforces the 16-symbol export allowlist and manifest component/permission bounds | `tool/build_rust_android.sh/.ps1`, `tool/build_libsodium_android.sh`, `tool/render_production_trust.sh`, `tool/verify_release_apk.sh`, `android/app/build.gradle.kts`, `AndroidManifest.xml` | D3 |
| **WP7** | **Evidence adequacy.** Whether the vector split (official primitive vectors vs project-generated regression pins), the missing parser fuzz coverage, and the fault-injection matrix support the claims made — and whether stated limits are stated *honestly and completely* | `native/crypto_core/vectors/README.md`, `test/architecture/`, `integration_test/crypto_core_android_smoke_test.dart`, [VERIFY.md](../runbooks/VERIFY.md) | D3, D7 |
| **WP8** | **Retest.** Re-examine every finding the owner claims to have fixed, at a new recorded revision, and state per finding whether the fix resolves it | the fixes produced under D4 | D5 |

### Explicitly out of scope

The reviewer must accept and restate these, so the report cannot be read as covering them.

- **Everything listed as out of scope**, including: `TBD2` conformance;
  interoperability with any MLS implementation; post-quantum *authentication* (the
  signature is Ed25519 throughout — the claim is PQ confidentiality only); sanitizer, Miri,
  and coverage-guided fuzzing (the stable Rust pin forecloses them); the physical-device
  crash matrix; state-format migration fuzzing; Web/Wasm; traffic analysis and fan-out
  metadata; device compromise; and full-database rollback.
- **`backend/`.** Read-only here, governed by its own contract, and not assessable from
  this track.
- **The internals of pinned upstream dependencies**, beyond how this implementation uses
  them.
- **Any claim about production readiness of the deleted beta track.** The beta was
  Private Use `0xFE4C` with disposable state, and it was deleted.

### Effort benchmarks

For budgeting only. These are published figures from comparable engagements, not quotes,
and no candidate has been asked what this would cost.

| Comparable engagement | Recorded effort | Source, verified 2026-08-18 |
|---|---|---|
| Discord DAVE protocol **design** review (an MLS-based E2EE deployment protocol) | 4 engineer-weeks, Aug 2024 | Trail of Bits publications index |
| Discord DAVE protocol **code** review | 4 engineer-weeks, Sep 2024 | Trail of Bits publications index |
| Open Quantum Safe `liboqs` security review | 5 engineer-weeks, Apr 2025 | Trail of Bits publications index |
| Ockam cryptographic design review | 11 engineer-weeks, Nov 2023 | Trail of Bits publications index |
| Go cryptographic libraries security review | 12 engineer-weeks, Mar 2025 | Trail of Bits publications index |
| OpenMLS security assurance assessment | 4 named assessors; code reviewed to a commit dated 22 October 2025; report v1.2 dated 11 March 2026; biweekly meetings throughout | SRLabs report, obtained from the OpenMLS blog |

On 2026-08-18 the planning figure for WP0-WP8 across the MLS and pairwise packets was
**10-16 engineer-weeks, plus a separate retest pass for WP8.** Treat it as an order of
magnitude for deciding whether a funding route is viable at all, not as a number to
negotiate against. It predates [ADR-075](../architecture/decisions/075-pairwise-groups.md)
and [ADR-077](../architecture/decisions/077-voice-mesh.md): `mls_beta.rs` and the MLS
packet were deleted, pairwise groups and voice rooms (`WP3b`) were added, and nothing has
been re-estimated since.

---

## Deliverables required before the review gate can close

All seven are mandatory. Gate 7 closes when all seven exist and D3 shows no open blocking
or high finding — not before, and not partially.

| # | Deliverable | Acceptance criteria |
|---|---|---|
| **D1** | **Agreed scope statement** | Written and signed by both parties *before* work starts. Names the work packages included and excluded; restates the packets' out-of-scope list as engagement boundaries; states the threat model and adversary assumed; states what a "blocking" finding means for this project. Later scope changes are amendments to D1, dated, not silent |
| **D2** | **Exact reviewed source hashes** | The full commit hash of every revision reviewed, plus the hashes or pinned versions of the dependency set (`Cargo.lock`, `pubspec.lock`, `android/app/gradle.lockfile`) and the vendored C sources (`libsodium`, `mlkem-native`). If the retest ran against a later revision, both revisions appear. A report that identifies its subject as "the repository" or by branch name does not satisfy D2 |
| **D3** | **Findings register with a disposition for every finding** | One row per finding, with: identifier, title, severity, the exact file and line reviewed, reproduction or argument, recommended action, **and a disposition**. Permitted dispositions: *fixed*, *mitigated*, *risk accepted*, *not a defect*. **Every finding carries one — none may be blank.** *Risk accepted* and *not a defect* each require a written justification, by the owner and the reviewer respectively. Zero findings is a valid register only if the reviewer states positively that they looked and found none in each area |
| **D4** | **Remediation evidence** | For every finding disposed *fixed* or *mitigated*: the commit that changed it, the test or vector that now covers it, and a note where the fix changes a documented behaviour (which then updates the owning document). Fixes without a regression test are incomplete |
| **D5** | **Explicit retest confirmation** | A written statement **by the reviewer**, at a named revision, that they re-examined each fix and whether it resolves the finding — including any fix that does not. This cannot be produced by the owner, and no amount of owner-side testing substitutes for it. Absent D5, gate 7 stays open even if every finding is marked fixed |
| **D6** | **Written independence statement** | Signed by the reviewer, covering I1-I5: no authorship or maintenance of the reviewed material; no relationship to the owner beyond this engagement; disclosure of relationships to `mls-rs`/AWS, OpenMLS/Phoenix R&D, the four draft author sets, and the vendored C dependencies; confirmation that fee and scope were not contingent on findings; and a positive statement of what was not reviewed |
| **D7** | **Recorded owner acceptance of residual risk** | Signed and dated by the owner, itemising each accepted residual risk individually — every *risk accepted* disposition from D3, plus each item on the packets' out-of-scope lists that remains unexercised at release. A blanket "residual risks accepted" sentence does not satisfy D7; the owner must be able to show they knew what they were accepting, one item at a time |

Where the outputs land: D1, D2, D3, D5, and D6 populate the
[Review disposition template](#review-disposition-template) above, which is currently empty.
D4 lands as commits and tests. D7 lands in
[Appendix A: owner acceptance of residual risk (D7)](#appendix-a-owner-acceptance-of-residual-risk-d7),
when — and only when — the owner actually signs it.

**What these deliverables do not do.** All seven complete, with a clean register, closes
gate 7 alone. Gates 1, 2, and 3 are registry, specification, and upstream-provider
conditions outside this repository; gates 4, 5, and 6 need the packaged Android artifact,
the bucket evidence, and the full multi-device matrix respectively.

---

## Candidate evaluation

### Method and its limits

Candidates were derived from primary sources on 2026-08-18: the IETF datatracker pages for
the four relevant drafts, the IANA registries, the published reports and publication
indexes of assessment practices, and the primary publication records of the academic work
on this protocol family. No prior candidate list was used as an input.

Three limits apply to everything in this section.

1. **Nobody has been contacted.** Every "meets Q*n*" judgement below is about *published
   evidence*, not about a candidate's interest, availability, capacity, price, or
   willingness to work under [Deliverables required before the review gate can close](#deliverables-required-before-the-review-gate-can-close). Those are unknowable without
   contact, which is externally blocked and not authorised.
2. **I1-I5 cannot be verified from public material.** Independence is established by a
   signed D6 after disclosure, not by inference here.
3. **Absence of published work is not absence of competence.** Where a table says
   "no published *X* found", it means exactly that — a search of primary sources on
   2026-08-18 did not surface it — not that the candidate lacks the skill.

### Organisations

| Candidate | Q1 MLS | Q2 hybrid PQ KEM | Q3 impl. review | Q4 Rust/FFI | Q5 inventions | Q6 report shape | Q7 named | Q8 retest | Primary evidence (verified 2026-08-18) |
|---|---|---|---|---|---|---|---|---|---|
| **Trail of Bits** | **Yes** | **Yes** | **Yes** | Yes | Yes | **Yes** | Yes | Likely | Published *Discord DAVE Protocol Design Review* (Aug 2024) and *Code Review* (Sep 2024) of an MLS-based E2EE deployment; DAVE's own whitepaper cites their findings by identifier (`TOB-DISCE2EC-2/-5/-7`) with severity and difficulty. Published *Open Quantum Safe liboqs Security Review* (Apr 2025). Published *SimpleX Chat* and *Ockam* cryptographic reviews. Publication index at `github.com/trailofbits/publications` |
| **Cryspen** | **Yes** | **Yes** | Yes | **Yes** | Partial | Different shape | Yes | Unknown | Karthikeyan Bhargavan (Cryspen) co-authored *TreeKEM: A Modular Machine-Checked Symbolic Security Analysis of Group Key Agreement in MLS* (ePrint 2025/410, with Wallez/Inria and Protzenko/Microsoft) and *Formal verification of the PQXDH Post-Quantum key agreement protocol* (USENIX Security '24, with Jacomme, Kiefer, Schmidt). Cryspen's own account of the Signal SPQR work (published 2025-10-02) describes ProVerif models, their libcrux ML-KEM implementation, and a hax/F* verification pipeline for the Rust implementation |
| **SRLabs** | **Yes** | Not found | **Yes** | Yes | Yes | **Yes** | **Yes** | **Yes** | The OpenMLS security assurance assessment: report v1.2, 11 March 2026, prepared for Phoenix R&D, funded by the Sovereign Tech Agency; named assessment team (Constantin Schwarz, Nils Ollrogge, Bruno Produit, Marc Heuse); STRIDE threat model, manual review, fuzzing and static analysis; scope table with per-component priority; reviewed to a commit dated 22 October 2025; **eight findings with per-finding status — five Mitigated, one Acknowledged, one Risk Accepted, one Mitigated at Info** — and an explicit remediation-support phase in which "the fix is verified by" the assessor |
| **Phoenix R&D** | **Yes** (deepest) | **Yes** | Yes | **Yes** | Yes | n/a (client, not assessor) | Yes | Unknown | Maintainers of OpenMLS; their own site states they offer "software development, research and consulting services to companies that are interested in secure messaging, post-quantum resistance, and privacy-preserving technologies". They published the audit-results post (Raphael Robert, 2026-05-27) |
| **NCC Group Cryptography Services** | Not found | Partial | **Yes** | Yes | Yes | **Yes** | Yes | Likely | Public report index at `cryptoservices.github.io` lists cryptographic implementation reviews (Go `x/crypto/ssh`, BLS signatures, Keyfork, WhatsApp-related assessments for Meta). No MLS-specific published report was found on that index |
| **Cure53** | Not found | Not found | **Yes** | Partial | Partial | **Yes** | Yes | Yes | Site states they provide "infrastructure, platform and cryptography audits" and publish reports "upon explicit request by the project maintainers"; listed crypto-adjacent work includes Noble Cryptography Libraries (08.2024), Nym (07.2024), Threema mobile apps (10.2020) |
| **Radically Open Security** | Not found | Not found | Yes | Unknown | Unknown | Yes | Yes | Unknown | Describes itself as a "Non-Profit Computer Security Consultancy" committed to transparency. Relevant chiefly as the audit route attached to certain European funding programmes rather than on published MLS or PQ work |

**Reading of the organisation table.** Trail of Bits and SRLabs are the only two candidates
whose *published output already has the exact shape [Deliverables required before the review gate can close](#deliverables-required-before-the-review-gate-can-close) demands* — source-anchored
findings, identifiers, severities, per-finding dispositions including "Risk Accepted", and
assessor-verified remediation — and both have published work on an MLS codebase or an
MLS-based deployment. Trail of Bits additionally evidences Q2 through the `liboqs` review;
SRLabs' published PQ KEM work was not found, which is the one mandatory item it does not
clearly evidence alone. Cryspen evidences Q1 and Q2 more deeply than anyone else and is the
strongest match for PQ KEM / PQXDH protocol questions, but its published output is
verification artifacts and papers rather than findings registers, so Q6 and Q8 would have
to be established by agreement rather than by precedent. Phoenix R&D has deep messaging
competence and is an **I3 disclosure case** (they author OpenMLS and operate in the same
product space).

The realistic shape of a compliant engagement is therefore **a combination under one
contract**: an implementation-review practice carrying Q3/Q4/Q6/Q8 and the findings
register, plus a named hybrid-PQ-KEM specialist carrying Q2. [How the bar is applied](#how-the-bar-is-applied) permits
this and states the condition — one register, one retest, one statement of coverage.

### Individuals

Named for domain evidence only. Several hold institutional positions that may not permit
paid consulting at all; none has been approached, and no inference about availability
should be drawn from inclusion here.

| Candidate | Published position (verified 2026-08-18) | Where they would fit | Conflict note |
|---|---|---|---|
| **Rohan Mahy**; **Richard Barnes** (Cisco) | Authors of `draft-ietf-mls-pq-ciphersuites`, revision 06, 21 July 2026, expiring 22 January 2027, MLS WG, state "Waiting for WG Chair Go-Ahead / Revised I-D Needed - Issue raised by WG". Barnes is additionally co-author of `draft-ietf-hpke-pq-05` (with Connolly) and `draft-irtf-cfrg-concrete-hybrid-kems-04`, and is listed by IANA as a designated expert for the MLS Cipher Suites registry | Historical WP2 (`TBD2` context) | Barnes' registry-expert role made him the wrong person to position as *the* independent assessor of a Private Use deployment that diverged from his own draft |
| **Deirdre Connolly** (Selkie Cryptography); **Peter Schwabe** (MPI-SP & Radboud); **Bas Westerbaan** (Cloudflare) | Authors of `draft-connolly-cfrg-xwing-kem`, revision 10, 2 March 2026, **expiring 2026-09-03**, Independent Submission stream. X-Wing is the construction IANA records as the reference for HPKE KEM `0x647A` | Q2 hybrid PQ KEM specialist | Reviewing hybrid PQ KEM constructions requires I3 disclosure |
| **Théophile Wallez** (Inria Paris); **Jonathan Protzenko** (Microsoft Azure Research) | With Bhargavan, authors of *TreeKEM* (ePrint 2025/410) — "the first machine-checked security proof for TreeKEM" — and of *TreeSync* (USENIX Security '23), whose analysis "identified a new attack" and produced changes adopted into the MLS draft | Protocol-level transcript & state-machine questions | Institutional consulting constraints likely; no published engagement of the D1-D7 shape |
| **Konrad Kohbrok**, **Raphael Robert** (Phoenix R&D) | OpenMLS maintainers; Robert is also listed by IANA as a designated expert for the MLS Cipher Suites registry and authored the audit-results post | Protocol / evidence review | Same I3 disclosure and commercial-conflict considerations as Phoenix R&D above |

---

## Funding routes

Evaluated against each body's published criteria. **The decisive fact for most of them is
local and verifiable: this repository carries no licence file at any level and is not
published as open source** (checked 2026-08-18). Almost every open-source audit fund
requires an OSI- or FSF-approved licence as a threshold condition, and several additionally
require the findings to be published.

| Route | What it provides | Published eligibility (verified 2026-08-18) | Verdict for this project |
|---|---|---|---|
| **Owner-funded** | Direct commercial engagement | None | **The only route with no eligibility blocker.** It is also the only route compatible with a closed codebase, with owner control of disclosure timing, and with the 10-16 engineer-week estimate as a single procurement. Recommended baseline |
| **OTF Security Lab** | Independent audits, explicitly including "early-stage security assessments of their technical design, those looking for cryptographic design reviews, and those looking for code reviews". Reports >170 audits supported | "Projects that are not receiving OTF support but are otherwise relevant to internet freedom may apply for an audit." OTF "places high priority on funding tools that are open-source and freely available to download and use". Beneficiary focus is "the world's most repressive environments" and the Global South. **"Audit findings are made publicly available after undergoing a responsible disclosure period."** Applicants in surveillance technology are ineligible | **The best-fit external route on subject matter** — it funds exactly cryptographic design and code review, and this project's design constraints (no foreign runtime dependency, operation without international internet, Persian as a first-release language) sit inside its remit. Two real obstacles: the project is not currently open source, against OTF's stated priority; and findings become public, which the owner must decide to accept. Neither is a technical blocker the way an OSI-licence requirement is |
| **NLnet / NGI Zero** | Grants €5,000-€50,000, plus "security and accessibility audits, mentoring, testing expertise, and copyright & licensing advice" to grantees | "All software and hardware developed **must** be published under a recognised free and open source license." Open to "individuals, research organisations, non-profits, public institutions, companies". "There is a deadline on the 3rd of every _odd_ month". Funds noted as in transition, with new funds active after summer | **Blocked by the licence requirement.** Grant ceiling is also below the estimate in [Effort benchmarks](#effort-benchmarks) for the full scope, though it could fund one work package |
| **Sovereign Tech Agency** | Funded the OpenMLS audit performed by SRLabs — the closest precedent in existence for the engagement described here | The funding relationship is confirmed by the OpenMLS maintainers' own announcement and by the SRLabs report's acknowledgement ("SRLabs thanks the Sovereign Tech Agency for funding this independent audit"). **The agency's own eligibility pages could not be retrieved: `sovereign.tech` returned HTTP 403 on 2026-08-18.** Secondary sources describe an OSI/FSF licence requirement, a focus on open digital *base* technologies (libraries, protocols, tooling, infrastructure), and a €50,000 minimum — these are recorded here as unverified at primary source | **Blocked in its current form, and structurally mismatched.** Even setting the licence aside, the precedent funds *base technology* — the OpenMLS library — not a closed end-user application built on it. The analogous fundable object here would be an upstream component, not this client |
| **OSTIF** | Facilitates and manages third-party audits of open-source projects, publishing the resulting reports | Open-source projects; requests are made by contacting the organisation directly. **Their site returned HTTP 403 on 2026-08-18**, so the criteria could not be read at primary source; the audit-report corpus itself is publicly linked | **Blocked by openness.** Reports are published as a matter of course |
| **Alpha-Omega (OpenSSF)** | Grants typically $50,000-$100,000 | Projects must use an "OSI-approved open source license"; standalone projects, foundations, or core ecosystem services; quarterly intake (January, April, July, October) with co-design and decision phases; grantees commit to monthly public reports and three public blog posts | **Blocked by the licence requirement**, and the public-accountability commitments are incompatible with a closed codebase |
| **GitHub Secure Open Source Fund** | $10,000 per project plus training and credits | "Clear open source license"; "Open source first project with demonstrated community traction and adoption"; maintainer located in a GitHub Sponsors-supported region; rolling applications | **Blocked by the licence and traction requirements.** At $10,000 it is also an order of magnitude below the estimate, and it funds security education rather than a third-party cryptographic review |

**Conclusion on funding.** If the codebase stays closed, exactly one route is open:
the owner pays. Every grant route evaluated requires open-source publication, and two of
them additionally require the findings to be public. If the owner is willing to publish the
crypto core under an OSI-approved licence — a separate strategic decision that this
document does not make and should not pre-empt — then OTF's Security Lab becomes the
best-matched route on subject matter, and the Sovereign Tech precedent becomes reachable
for an upstream-shaped component rather than for the client application.

---

## What remains externally blocked

Complete locally, in this document, needing nobody outside the repository:

- the qualification bar ([Qualification bar](#qualification-bar));
- the consolidated active v1 scope, work packages, exclusions, and effort benchmarks
  ([Consolidated active v1 review scope](#consolidated-active-v1-review-scope), [Scope of work](#scope-of-work));
- the definition and acceptance criteria of all seven required deliverables
  ([Deliverables required before the review gate can close](#deliverables-required-before-the-review-gate-can-close));
- the candidate evaluation against the bar, from primary sources
  ([Candidate evaluation](#candidate-evaluation)); and
- the funding-route evaluation against published criteria, including the local facts that
  decide most of it ([Funding routes](#funding-routes)).

Externally blocked, and not satisfiable by any work in this repository:

| Blocked item | Why it cannot be done here | What would unblock it |
|---|---|---|
| **Retaining a reviewer** | Requires contacting a candidate, agreeing scope and price, and signing. No candidate has been approached; none has agreed to anything | Owner authorises contact, then contracts |
| **Funding** | Requires either the owner committing money or applying to a body — and every grant route evaluated is blocked by the absent open-source licence | Owner funds directly, or makes the separate decision to publish under an OSI-approved licence and then applies |
| **The review itself** | An independent party must read the code. Assembling material is not review; this document is not review; the packets are not review | The engagement runs |
| **Closure of the review's findings** | D3-D5 need a reviewer to raise findings, the owner to fix them, and **the reviewer** to retest and confirm. D5 is structurally impossible for the owner to produce | Findings raised, fixed, retested, confirmed in writing |
| **Gates 1, 2, 3** *(historical MLS)* | Registry assignment, a final MLS specification with an IANA-assigned suite value, and a maintained provider implementing the final mapping. ADR-026 forbids assigning an identifier locally | Superseded by [ADR-075](../architecture/decisions/075-pairwise-groups.md) for active v1 |
| **Upstream interoperability vectors** *(historical MLS)* | The MLS WG publishes none for any PQ suite. Project-generated vectors explicitly do not advance this | Superseded by [ADR-075](../architecture/decisions/075-pairwise-groups.md) for active v1 |
| **Gates 4, 5, 6 & device matrices** | Need the packaged Android artifact on hardware, sustained-delivery physical-device matrix, multi-device E2E, and voice acceptance — implementation and device-matrix work, not review work | Separate implementation and device-matrix work |

The gate list is unchanged by this document. All active review gates and open owner policy
decisions remain open.

---

## Validation

### External claims and their primary sources

Every external claim in the engagement evaluation traces to a source below. All were
retrieved and read on **2026-08-18** unless stated otherwise.

| Claim | Primary source | Verified |
|---|---|---|
| `draft-ietf-mls-pq-ciphersuites` is at revision 06, dated 21 July 2026, expires 22 January 2027, authors Rohan Mahy and Richard L. Barnes, MLS WG, state "Waiting for WG Chair Go-Ahead" / "Revised I-D Needed - Issue raised by WG" | https://datatracker.ietf.org/doc/draft-ietf-mls-pq-ciphersuites/ | 2026-08-18 |
| `draft-connolly-cfrg-xwing-kem` is at revision 10, dated 2 March 2026, expires 2026-09-03, Independent Submission, authors Deirdre Connolly (SandboxAQ), Peter Schwabe (MPI-SP & Radboud), Bas Westerbaan (Cloudflare) | https://datatracker.ietf.org/doc/draft-connolly-cfrg-xwing-kem/ | 2026-08-18 |
| `draft-ietf-hpke-pq` is at revision 05, dated 6 July 2026, authors Richard Barnes (Cisco) and Deirdre Connolly (Selkie Cryptography) | https://datatracker.ietf.org/doc/draft-ietf-hpke-pq/ | 2026-08-18 |
| `draft-irtf-cfrg-concrete-hybrid-kems` is at revision 04, CFRG, authors Connolly and Barnes, state "I-D Exists::Revised I-D Needed" | https://datatracker.ietf.org/doc/draft-irtf-cfrg-concrete-hybrid-kems/ | 2026-08-18 |
| The IANA "MLS Cipher Suites" registry contains only `0x0000` RESERVED, RFC 9420 `0x0001`-`0x0007`, GREASE, and Private Use `0xF000`-`0xFFFF`; **no post-quantum or ML-KEM suite is registered**; last updated 2025-11-17; policy Specification Required; designated experts Sean Turner, Raphael Robert, Richard Barnes | https://www.iana.org/assignments/mls/mls.xhtml | 2026-08-18 |
| IANA HPKE registries: KEM `0x647A` = X-Wing, reference `draft-connolly-cfrg-xwing-kem-06`; KDF `0x0002` = HKDF-SHA384 (RFC 5869); AEAD `0x0002` = AES-256-GCM (NIST SP 800-38D); last updated 2026-04-16 | https://www.iana.org/assignments/hpke/hpke.xhtml | 2026-08-18 |
| OpenMLS was independently audited by SRLabs, funded by the Sovereign Tech Agency; eight issues, one High; seven fixed in openmls 8.1 and 7.3, one Low outstanding at publication; post by Raphael Robert, 2026-05-27 | https://blog.phnx.im/openmls-independent-security-audit/ and https://blog.openmls.tech/ | 2026-08-18 |
| The SRLabs report: "Threat model and hacking assessment report", v1.2, 11 March 2026, prepared for Phoenix R&D; assessment team Constantin Schwarz, Nils Ollrogge, Bruno Produit, Marc Heuse; scope `openmls`/`traits`/`basic_credential` with per-component priority, reviewed to a commit dated 22 October 2025; crypto and storage providers explicitly out of scope; STRIDE methodology in four steps ending in remediation support where "the fix is verified by" the assessor; findings 1 High / 3 Medium / 2 Low / 2 Info with statuses Mitigated, Acknowledged, Risk Accepted; "SRLabs thanks the Sovereign Tech Agency for funding this independent audit" | https://blog.openmls.tech/SRL-OpenMLS_security_assurance_assessment.pdf | 2026-08-18 |
| Trail of Bits published *Discord DAVE Protocol Design Review* (Aug 2024, 4 engineer-weeks) and *Discord DAVE Protocol Code Review* (Sep 2024, 4 engineer-weeks); *Open Quantum Safe liboqs Security Review* (Apr 2025, 5); *Ockam Design Review* (Nov 2023, 11); *Go Cryptographic Libraries Security Review* (Mar 2025, 12); *SimpleX Chat* (Oct 2022) | https://github.com/trailofbits/publications | 2026-08-18 |
| DAVE is an MLS-based E2EE protocol (MLS 1.0, ciphersuite 2, RFC 9420) and its whitepaper cites Trail of Bits findings by identifier with severity — `TOB-DISCE2EC-5` (low, high difficulty), `TOB-DISCE2EC-7` (medium, high difficulty), `TOB-DISCE2EC-2` | https://github.com/discord/dave-protocol (`protocol.md`) | 2026-08-18 |
| *TreeKEM: A Modular Machine-Checked Symbolic Security Analysis of Group Key Agreement in MLS* — Théophile Wallez (Inria Paris), Jonathan Protzenko (Microsoft Azure Research), Karthikeyan Bhargavan (Cryspen); ePrint 2025/410, approved 2025-03-04; "the first machine-checked security proof for TreeKEM" | https://eprint.iacr.org/2025/410 | 2026-08-18 |
| *TreeSync: Authenticated Group Management for Messaging Layer Security*, USENIX Security '23, Wallez, Protzenko, Beurdouche, Bhargavan; F* specification, DY* analysis, identified a new attack, changes adopted into the MLS draft | https://www.usenix.org/conference/usenixsecurity23/presentation/wallez | 2026-08-18 |
| *Formal verification of the PQXDH Post-Quantum key agreement protocol for end-to-end secure messaging*, USENIX Security '24 — Karthikeyan Bhargavan, Charlie Jacomme, Franziskus Kiefer, Rolfe Schmidt; ProVerif and CryptoVerif; identified flaws in the specification | https://www.usenix.org/system/files/usenixsecurity24-bhargavan.pdf | 2026-08-18 |
| Cryspen's Signal engagement: PQXDH analysis from 2023, then SPQR from design through implementation — ProVerif models, libcrux ML-KEM with an incremental API, and a hax/F* verification pipeline for the Rust implementation; published 2025-10-02 | https://cryspen.com/post/signal-spqr-verification/ | 2026-08-18 |
| **`mls-rs` states: "This library has been validated for conformance to the RFC 9420 specification but has not yet received a full security audit by a 3rd party."** Dual-licensed Apache-2.0 OR MIT | https://github.com/awslabs/mls-rs and https://awslabs.github.io/mls-rs/ | 2026-08-18 |
| Phoenix R&D offers "software development, research and consulting services to companies that are interested in secure messaging, post-quantum resistance, and privacy-preserving technologies" | https://phnx.im/ | 2026-08-18 |
| NCC Group Cryptography Services publishes cryptographic implementation reviews (Go `x/crypto/ssh`, BLS signatures, Keyfork, WhatsApp-related work for Meta); no MLS-specific report found on that index | https://cryptoservices.github.io/ | 2026-08-18 |
| Cure53 provides "infrastructure, platform and cryptography audits" and publishes reports "upon explicit request by the project maintainers"; listed work includes Noble Cryptography Libraries (08.2024), Nym (07.2024), Threema (10.2020) | https://cure53.de/ | 2026-08-18 |
| SRLabs is based in Berlin and lists Software Assurance and Blockchain Security ("the cryptography underneath") among its services | https://www.srlabs.de/ | 2026-08-18 |
| Radically Open Security describes itself as a "Non-Profit Computer Security Consultancy" | https://www.radicallyopensecurity.com/ | 2026-08-18 |
| OTF Security Lab: supports audits for OTF-supported projects, and "projects that are not receiving OTF support but are otherwise relevant to internet freedom may apply"; covers "early-stage security assessments of their technical design, those looking for cryptographic design reviews, and those looking for code reviews"; "Audit findings are made publicly available after undergoing a responsible disclosure period"; >170 audits supported; contact `security_lab@opentech.fund` | https://docs.opentech.fund/otf-application-guidebook/our-labs/security-lab and https://docs.opentech.fund/otf-application-guidebook/llms-full.txt | 2026-08-18 |
| OTF: "places high priority on funding tools that are open-source and freely available to download and use"; beneficiary focus on "the world's most repressive environments" and the Global South; applicants in surveillance technology ineligible; overhead capped at 10% of direct costs; determination 6-8 weeks after submission | https://docs.opentech.fund/otf-application-guidebook/llms-full.txt | 2026-08-18 |
| NLnet: "all software and hardware developed **must** be published under a recognised free and open source license"; €5,000-€50,000; "anyone can apply: individuals, research organisations, non-profits, public institutions, companies"; offers "security and accessibility audits, mentoring, testing expertise"; "There is a deadline on the 3rd of every _odd_ month" | https://nlnet.nl/funding.html | 2026-08-18 |
| Alpha-Omega: requires an "OSI-approved open source license"; typically $50,000-$100,000; quarterly intake in January, April, July, October; grantees commit to monthly public reports and three public blog posts | https://alpha-omega.dev/grants/how-to-apply/ | 2026-08-18 |
| GitHub Secure Open Source Fund: requires a "Clear open source license", an "Open source first project with demonstrated community traction and adoption", maintainer in a GitHub Sponsors-supported region; $10,000 total, paid $6,000/$2,000/$2,000; rolling applications | https://github.com/open-source/github-secure-open-source-fund | 2026-08-18 |
| **Not verified at primary source:** the Sovereign Tech Agency's own eligibility criteria, funding minimum, and application process. `https://www.sovereign.tech/programs`, `https://www.sovereign.tech/programs/fund`, and `https://www.sovereign.tech/tech/openmls` each returned **HTTP 403** on 2026-08-18. Only the funding *relationship* to the OpenMLS audit is primary-sourced, via the SRLabs report and the OpenMLS announcement above. OSTIF's criteria are likewise unverified — `https://ostif.org/what-we-do/` returned HTTP 403 the same day | — | 2026-08-18 |

### Internal consistency

| Check | Result |
|---|---|
| Gate list unchanged | **Pass.** No gate is marked satisfied, partially satisfied, or advanced by this document. Active review gates and historical MLS gates remain open |
| Phase-A prerequisite 5 | **Pass.** Still recorded as Blocked. This document supplies the scope-of-work half only, and says so |
| No reviewer named as retained | **Pass.** Every candidate is marked not approached and not retained, in [Method and its limits](#method-and-its-limits) and in [Review status](#review-status) |
| Consolidated v1 scope covers all active domains | **Pass.** Pairwise, signed group and room control (`CPGSV001`, `CPVRV001`, `CPVSV001`), Android key storage, persistence/concurrency (schema 26), and FFI/packaging each list evidence paths, inspection revision, outstanding assessments, and acceptance role |
| Consistent with the pairwise packet | **Pass.** The pairwise packet requires all blocking/high findings closed, exact reviewed source hashes, vector reproduction on the packaged Android artifact, and explicit residual-risk acceptance; WP3 and D1-D7 cover its review half |
| Consistent with ADR-017 and ADR-026 | **Pass.** ADR-017's "independent assessment" is the engagement defined here. ADR-026's prohibition on locally assigning a production identifier is restated, and no review outcome is presented as substituting for gate 2 |
| Source baseline consistent with the codebase | **Pass.** `bcc64eba` is verified identical in functional code, native Rust, Kotlin, and build scripts to `6c04d4e` (`git diff --stat bcc64eba..HEAD -- frontend/lib/ frontend/native/ frontend/android/ frontend/tool/`); historical `4e65eaf`..`7605659` baseline is preserved |
| Backend untouched | **Pass.** `backend/` is strictly read-only and excluded from modification |
| Effort figures traceable | **Pass.** Every engineer-week figure in [Effort benchmarks](#effort-benchmarks) is quoted from the published index cited in [External claims and their primary sources](#external-claims-and-their-primary-sources); the 10-16 week figure is labelled a historical pre-ADR-075/077 estimate |

---

## External actions the owner must authorise

None of these has been taken. Each requires an explicit decision by the owner.

1. **Decide the funding basis.** Owner-funded is the only route open while the codebase is
   closed. Everything else waits on decision 2.
2. **Decide whether the crypto core is published under an OSI-approved licence.** This is a
   strategic product decision, not a review decision. It is the single fact that unblocks
   or blocks NLnet, Alpha-Omega, GitHub SOSF, OSTIF, and the Sovereign Tech precedent, and
   it materially affects OTF's stated priority.
3. **Decide whether findings may be published.** OTF publishes audit findings after a
   responsible-disclosure period; Alpha-Omega requires public reporting. An owner who needs
   findings to stay private has ruled those routes out irrespective of licensing.
4. **Authorise contact with candidates.** No approach, enquiry, or request for a quote has
   been made to anyone in [Candidate evaluation](#candidate-evaluation), and none may be made without this authorisation.
5. **Authorise disclosure of source to a third party**, including whatever NDA the owner
   requires, before any candidate can scope the work properly.
6. **Confirm engagement feasibility on the owner's side** — contracting, payment route, and
   any export-control or sanctions considerations that apply to the owner's jurisdiction
   and the candidate's. These are legal questions this document does not attempt to answer.
7. **Fix the review revision** and record it in D1 and D2 at engagement start.
8. **Commit to producing D4 and D7 personally.** Remediation evidence and the itemised
   residual-risk acceptance are owner deliverables. A reviewer cannot supply them, and
   without them the gate stays open even after a clean report.

---

## Appendix A: owner acceptance of residual risk (D7)

**Empty. Nothing is accepted.**

This appendix exists so that D7 has a defined home. It is filled in only after a review has
actually happened, itemising each accepted residual risk individually, signed and dated by
the owner. An empty appendix means no residual risk has been accepted — never that none
exists.

## Appendix B: engagement record

**Empty. No engagement exists.**

| Field | Value |
|---|---|
| Reviewer | *none retained* |
| Named assessors | *none* |
| D1 agreed scope statement | *not produced* |
| D2 reviewed source hashes | *not produced* |
| D3 findings register | *not produced* |
| D4 remediation evidence | *not produced* |
| D5 retest confirmation | *not produced* |
| D6 independence statement | *not produced* |
| D7 residual-risk acceptance | *not produced* |
| Gate 7 status | **open** |

An empty row means the deliverable does not exist. It never means the deliverable was
waived, satisfied informally, or judged unnecessary.
