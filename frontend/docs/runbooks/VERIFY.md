# Testing strategy and verification

## Principles

- Test externally visible behavior and protocol invariants, not provider implementation
  details.
- Use deterministic clocks, CSPRNG fixtures only in tests, fake networks, and fault
  injection.
- Every production bug adds a regression test at the lowest useful layer plus an
  integration test when the failure crossed a boundary.
- Real-secret fixtures are forbidden.

## Verification matrix by execution scope

Every local command below assumes the **working directory is `frontend/`** (even where a
PowerShell or POSIX script changes into `frontend/` itself) and uses the repository-pinned
toolchains and lockfiles:

- **Flutter / Dart:** Flutter `3.44.7`, Dart `3.12.2` (`pubspec.yaml`, `pubspec.lock`). On
  Windows workstations with another Flutter SDK on `PATH`, prepend the pinned
  `flutter-3.44.7/bin` directory before running `flutter` or `dart`.
- **Rust / NDK:** Rust `1.97.1` (`rust-toolchain.toml`, `native/crypto_core/Cargo.lock`),
  Android NDK `28.2.13676358` (`ANDROID_NDK_HOME` / `ANDROID_NDK_ROOT`). On Windows, host
  proc-macros/build scripts also require VS 2022 Build Tools (`VC.Tools.x86.x64`) and the
  Windows SDK ([ANDROID.md](../architecture/ANDROID.md#windows-host-prerequisites)).
- **Android / Release tools:** Android SDK `build-tools` providing `apksigner` and
  `aapt2`, JDK `17` or newer (`CP_RELEASE_JAVA_HOME` / `JAVA_HOME` in `C:/...` form on
  Windows), Git Bash / POSIX `bash`, `openssl`, and `adb`.

> [!WARNING]
> Do **not** run `flutter analyze` or `flutter test` while
> `tool/build_production_release.sh` is running: both regenerate the gitignored plugin
> registrant with a development-only plugin (`integration_test`), which causes the release
> build to fail compilation ([SIGNING.md](SIGNING.md#2-build)).

### 1. Fake-backed and host tests (Flutter / Dart)

These run on the host Dart VM with in-memory/fake ports, deterministic clocks, fake
transports, and `dart:io` loopback TLS fixtures (`transport_security_test.dart`). They do
**not** exercise real Android Keystore hardware, native Android SQLCipher, `flutter_webrtc`
media on a radio, or vendor OEM background killing.

| Check | Working directory | Prerequisites | Command | Expected signal | What it covers |
|---|---|---|---|---|---|
| Locked pub get & codegen | `frontend/` | Pinned Flutter `3.44.7` / Dart `3.12.2` on `PATH` | `flutter pub get --enforce-lockfile` then `./tool/generate.ps1` (Windows) or `sh ./tool/generate.sh` (POSIX), then `git diff --exit-code -- lib` | Exit `0`; clean `lib/` diff after `flutter gen-l10n` and `dart run build_runner build` | Enforces `pubspec.lock` (`ADR-054`) and proves generated l10n/Drift/Riverpod code matches committed `lib/`. |
| Dart formatting | `frontend/` | Pinned Dart SDK | `dart format --output=none --set-exit-if-changed lib test integration_test` | Exit `0` with zero reformatted files | Enforces canonical Dart formatting across runtime, tests, and integration tests. |
| Static analysis | `frontend/` | Generated code present (`generate.ps1` / `generate.sh`) | `flutter analyze --fatal-infos --fatal-warnings` | Exit `0`; zero issues, warnings, or infos | Lint, type safety, and analyzer cleanliness across the Flutter tree. |
| Full host test suite | `frontend/` | Generated code present | `flutter test` | Exit `0`; all unit, widget, and architecture tests pass | Domain/application state machines, Drift schema/migrations/query plans, widget flows, diagnostics redaction canary tests, local `dart:io` TLS test, and architecture/policy guards under `test/`. |
| Targeted governance & policy gates | `frontend/` | Generated code present | `flutter test test/architecture/sustained_delivery_gate_test.dart test/architecture/dependency_policy_test.dart test/architecture/crypto_core_boundary_test.dart test/architecture/deployment_disclosure_test.dart` | Exit `0` | Verifies closed sustained-delivery ledger (`bestEffort`), pinned dependency/manifest rules, `foundation`-only FFI boundary (and absence of `cp_crypto_v1_beta_mls_operation`), and `DeploymentDisclosure.distributed` consistency. |

### 2. Host Rust crypto-core checks (`native/crypto_core`)

Host Rust checks run on the development machine's native target (`x86_64-pc-windows-msvc`
on Windows). A host Rust pass alone is **not** proof of Android ABI packaging or device
loading.

| Check | Working directory | Prerequisites | Command | Expected signal | What it covers |
|---|---|---|---|---|---|
| Rust formatting | `frontend/` | Rust `1.97.1` (`rustfmt`) | `cargo fmt --manifest-path native/crypto_core/Cargo.toml -- --check` | Exit `0` | Rust formatting across `native/crypto_core/src/`. |
| Rust unit & vector suite | `frontend/` | Rust `1.97.1`, committed `Cargo.lock` | `cargo test --locked --manifest-path native/crypto_core/Cargo.toml` | Exit `0`; all primitive, protocol, and ABI tests pass | NIST ACVP FIPS 203 ML-KEM-768 vectors (`mlkem768-acvp-fips203.json`), project composition pins (`pairwise-v1.json`, `attachment-header-v1.json`, see [vectors/README.md](../../native/crypto_core/vectors/README.md)), `group_control.rs`, `room_control.rs`, `enrollment.rs`, `application.rs`, `attachment.rs`, C ABI error codes (0–14), and `catch_unwind` panic containment (`lib.rs`). |
| Rust Clippy lints | `frontend/` | Rust `1.97.1` (`clippy`) | `cargo clippy --locked --all-targets --all-features --manifest-path native/crypto_core/Cargo.toml -- -D warnings` | Exit `0` with zero warnings | Static safety/lint checks on the Rust core and tests under locked dependencies. |

### 3. Packaged native checks & unsigned CI (`tool/ci.ps1` / `tool/ci.sh`)

These checks produce compiled Android artifacts and verify packaged native binaries,
manifest permissions/components, and signatures.

| Check | Working directory | Prerequisites | Command | Expected signal | What it covers |
|---|---|---|---|---|---|
| Android Rust & libsodium cross-build | `frontend/` | Rust `1.97.1` Android targets, Android NDK `28.2.13676358`, POSIX `bash`, `sha256sum`, `tar` | `powershell -File tool/build_rust_android.ps1 all` (Windows) or `sh ./tool/build_rust_android.sh all` (POSIX) | Exit `0`; produces `build/rust-android/foundation/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libcommunication_crypto_core.so` | Verifies `vendor/libsodium/LATEST.tar.gz` SHA-256 (`b20a92e7...`), builds static `libsodium.a`/`liblibsodium.a`, builds all 3 ABIs, checks `llvm-nm` exact 16-symbol `foundation` export allowlist, checks ELF `LOAD` alignment (`0x4000` on 64-bit; `0x1000`/`0x4000` on `armeabi-v7a`), and confirms no dynamic `libsodium.so` dependency. |
| Full unsigned CI gate | `frontend/` | Pinned Flutter `3.44.7`, Android SDK `build-tools` (`aapt2`, `apksigner`), NDK `28.2.13676358`, JDK `17+`, POSIX `bash` | `./tool/ci.ps1` (Windows) or `sh ./tool/ci.sh` (POSIX) | Exit `0`; ends with `verify_release_apk.sh --production-unsigned` reporting all checks passed (`unsigned, so the OS cannot install it`) | Runs locked `pub get`, `generate`, clean `lib/` diff, `dart format`, `flutter analyze --fatal-infos --fatal-warnings`, `flutter test`, `development` debug APK build, and an **unsigned** `production` release APK build (`CP_PRODUCTION_UNSIGNED_BUILD=1` with all `CP_PRODUCTION_*` signing vars stripped) verified with `--production-unsigned`. |
| Unsigned CI APK verification (standalone) | `frontend/` | Built unsigned APK, `release_env.sh` toolchain (`aapt2`, `apksigner`, NDK `llvm-nm`) | `sh ./tool/verify_release_apk.sh --production-unsigned build/app/outputs/flutter-apk/app-production-release.apk` | Exit `0`; prints `ok` lines and `<N> checks passed.` | Confirms `application.id` (`com.orviniq.chat`), `apksigner` returns `DOES NOT VERIFY` (cannot install), exact 12 merged manifest permissions and 6 components (`MainActivity` alone exported), and no `cp_crypto_v1_beta_mls_operation` symbol in `lib/arm64-v8a/libcommunication_crypto_core.so`. Does **not** check trust config or signing identity. |

### 4. Signed distribution build and verification (`--production`)

Signed distribution builds differ fundamentally from unsigned CI: CI builds an
uninstallable unsigned package with checked-in baseline trust resources, whereas a
distributable phone artifact **must** be built with `tool/build_production_release.sh`
against live provisioning and external signing custody ([SIGNING.md](SIGNING.md)).

| Check | Working directory | Prerequisites | Command | Expected signal | What it covers |
|---|---|---|---|---|---|
| Signed, provisioned production build & verify | `frontend/` | Committed cert SHA-256 in `android/production-release-identity.properties`; external `CP_PRODUCTION_SIGNING_PROPERTIES` (or four keystore vars) outside repo; `CP_PRODUCTION_UNSIGNED_BUILD` unset; all 5 `PRODUCTION_*` env vars derived afresh; JDK `17+`; NDK `28.2.13676358`; live server reachable | `./tool/build_production_release.sh --build-number <N>` (from Git Bash after sourcing scratch provisioning file) | Exit `0`; prints `ok` on live primary SPKI pin, renders trust resources, builds APK, passes `verify_release_apk.sh --production`, writes `build/production-release/communication-platform-<version>-<N>.{apk,apk.sha256,apk.metadata.txt}` | Proves live server serves `PRODUCTION_PRIMARY_SPKI_SHA256`; validates CA cert SHA-256 and expiry via `tool/render_production_trust.sh`; builds `--release --flavor production`; and enforces `--production` gate before publishing. |
| Signed distribution APK verification (standalone) | `frontend/` | Signed APK; `JAVA_HOME` in `C:/...` form on Windows; `PRODUCTION_SERVER_ORIGIN` + `PRODUCTION_PRIMARY_SPKI_SHA256` + `PRODUCTION_BACKUP_SPKI_SHA256` exported for full pin check | `sh ./tool/verify_release_apk.sh --production build/production-release/<artifact>.apk` | Exit `0`; prints `ok` lines and `<N> checks passed.` | Confirms `com.orviniq.chat` app ID; 1 non-debug signer matching `android/production-release-identity.properties`; APK Signature Scheme v2 + v3 present and v1 absent; 12 permissions and 6 components; packaged obfuscated `network_security_config` with `domain-config`, ≥2 SPKI pins (matching provisioned pins when exported), `cleartextTrafficPermitted=false`, and `raw/provisioned_private_ca`; and absence of `cp_crypto_v1_beta_mls_operation`. |

### 5. Connected-device work (Android emulator & physical hardware)

Connected-device work is distinct from host/CI suites: a green `flutter test` run never
establishes Android runtime loading, Keystore hardware behavior, upgrade continuity, voice
media over coturn, or OEM background survival.

| Check | Working directory | Prerequisites | Command | Expected signal | What it covers |
|---|---|---|---|---|---|
| Packaged Android native smoke test | `frontend/` | Connected Android emulator or device (`development` flavor only—never target a device holding signed `com.orviniq.chat`) | `flutter test integration_test/crypto_core_android_smoke_test.dart -d <android-device> --flavor development` | Exit `0`; test passes on Android | Loads `libcommunication_crypto_core.so` in an Android Dart isolate, checks `capabilities()`, `selfTest()`, `applicationProtocol` CBOR golden vector round-trip, and `identityCrypto` safety fingerprint & invalid-identity check. |
| Production install / in-place upgrade check | `frontend/` (host shell) | Signed `build/production-release/<artifact>.apk` + `adb` + target device | `adb install <apk>` (first) or `adb install -r <apk>` (upgrade), then `adb shell dumpsys package com.orviniq.chat` | `Success`; `firstInstallTime` unchanged, `versionCode` and `lastUpdateTime` advanced | Proves persistent signing-key upgrade continuity without erasing SQLCipher/Keystore data ([SIGNING.md](SIGNING.md#installing-on-a-device)). |
| Sustained delivery hardware measurement | `frontend/` | Physical device per mandatory cell in [SUSTAINED-DELIVERY.md](SUSTAINED-DELIVERY.md#the-matrix), two activated test accounts, `adb` over Wi-Fi for natural Doze | `./tool/measure_sustained_delivery.sh probe --serial <S> --out <DIR>`, `doze`, `watch`, `mark`, `verdict` | Validated `probe.json`, `deviceidle.txt`, `samples.ndjson`, `marks.ndjson` meeting C1–C10 | Measures real device foreground-service survival, socket continuity, Doze/standby behavior, and latency. **Gate is currently CLOSED** (`SustainedDeliveryGate.releaseAssertion` is empty; emulators cannot open a cell). |
| Multi-device voice, notification, and E2E matrix | `frontend/` + backend stack | Activated test accounts, Django/PostgreSQL/Redis/nginx/coturn stack, multiple physical Android devices (API 24–36) | Manual / Patrol E2E campaign against [End-to-end tests](#end-to-end-tests) and [STATUS.md](../STATUS.md#release-scope-and-gates) | Recorded run logs under `docs/validation/` | Covers 2–10 device voice calls, 5-hour ICE restart, TCP relay, mid-call removal, Android 13–16 notification rendering, and headless `JobScheduler` catch-up from release AOT. |

### 6. Offline / international-disconnection rehearsal

- **Working directory:** `frontend/` and isolated deployment/build environment.
- **Prerequisites:** Network isolated from international internet (no public DNS, no
  Google/Firebase, no CDN/remote font access); self-hosted backend, PostgreSQL, Redis,
  nginx, and coturn reachable locally; approved dependency mirrors/caches (note:
  [RELEASE.md](RELEASE.md#dependency-and-toolchain-control) records that no offline build
  mirror is set up yet, and a mirror must include the JitPack coordinate for
  `com.github.davidliu:audioswitch` per [ADR-078](../architecture/decisions/078-media-package.md)).
- **Command / procedure:** Execute offline build + register, login, two-phase enrollment,
  cross-signing/SAS, DM/group messaging, attachment upload/download, voice call,
  history transfer, and `pruned_through` recovery while capturing DNS/network logs.
- **Expected signal:** Zero foreign DNS lookups or outbound connections; all flows succeed
  against the local private CA and self-hosted coturn ([RELEASE.md](RELEASE.md#operations-without-international-internet)).

### 7. Independent cryptographic and security assessment

- **Not runnable by any local script.** No `flutter test`, `cargo test`, or
  `verify_release_apk.sh` run substitutes for independent review.
- **Governing specification:** [REVIEW-SCOPE.md](../security/REVIEW-SCOPE.md) defines the
  mandatory deliverables (`D1`–`D7`), work packages (`WP0`, `WP3`–`WP8`), qualification bar,
  and independence requirements (`I1`–`I5`).
- **Expected signal:** Signed deliverables `D1`–`D7` with exact reviewed commit hashes,
  zero open blocking/high findings in `D3`, written reviewer retest confirmation `D5`, and
  itemised owner residual-risk acceptance `D7`. **Currently open; no reviewer is retained.**

## Test layers

### Domain and application unit tests

- Authentication, connection, outbox, inbox, group-role, receipt, and voice state
  machines.
- Authorization of every event kind.
- Ordering, idempotency, duplicate/replay, delayed lower sender counters, sender-counter
  reuse with a different event ID, stale revision, clock skew, and unknown-version
  behavior.
- Error-code mapping and localized honest wording selection.
- Structural redaction of anything the user can export: the diagnostics report's value
  type is proved to admit no runtime text, and the collector is run against a database
  whose every readable column holds a canary.
- Recovery-secret replacement: the new secret is produced only after the server accepted
  a higher backup version, and every refusal leaves the current secret working.
- Riverpod use cases with in-memory/fake ports; no widget is required to test domain
  behavior.

### Crypto-core tests

Version 1 is Android-only. Required target tests for the Rust crypto core are the shared
Rust primitive suite, native ABI boundary tests, Android cross-build/package checks, Dart
wrapper and isolate tests, and a smoke call through the library packaged in an Android
application. A host-native dynamic-library test alone is not the packaged Android smoke.
The Web target was removed on 2026-09-08 under
[server ADR-0020](../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md).
A browser release would require an explicit decision and compatible server support.

- FIPS 203 ML-KEM, hybrid PQXDH/Double Ratchet, Argon2id, CBOR, and secretstream vectors
  applicable to the selected implementation. Voice needs none of its own: DTLS-SRTP is
  negotiated by the WebRTC stack and the project writes no media cipher
  ([server ADR-0021](../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)).
- The binding backend golden vectors for `cross_sig`, `master_sig`, `spk_sig`,
  `pq_spk_sig`, optional-field encoding, and the Ed25519/X25519 `ik_pub` layout, plus
  project vectors for SAS/QR values, device-log records/gossip, every event,
  history-transfer batches, attachment headers, and protocol upgrades.
- Future Web release: byte equality between Android `mlkem_native`/shared native code
  and the reviewed browser Wasm implementation.
- Interoperability between independent devices/versions.
- Property tests for encode/decode, encrypt/decrypt, state serialization, replay, skipped
  messages, and group control revisions.
- Fuzzing of all untrusted binary parsers and state restoration. Nothing is fuzzed
  today: the one in-crate harness covered only the closed-beta PQ MLS inputs and was
  deleted with that core, and the pairwise transport, application-message, and
  attachment parsers were never fuzzed. The pinned stable toolchain and the
  offline/pinned-dependency rules exclude `cargo-fuzz`, libFuzzer, AFL++, ASan, and
  Miri, so coverage-guided instrumentation and a sanitizer build need an approved
  toolchain decision.
- Negative vectors for altered headers, signatures, associated data, padding, counters,
  final tags, credentials, and group control events.

### Device validation

Some questions no test in this repository can answer, because they are questions about
what a manufacturer's Android build does to this application over hours and days. Those
are measured on hardware, against criteria fixed before the measurement, and recorded as
evidence that a release gate reads. The first such gate is sustained delivery
([SUSTAINED-DELIVERY.md](SUSTAINED-DELIVERY.md), ADR-053): its
criteria, its seven-cell matrix, its instrument (`tool/measure_sustained_delivery.sh`)
and its current state — **closed, no cell run** — live there.

A green test suite says nothing about such a matrix, and the two are never reported as
one result. Nothing is added to the application to make this measurable: the instrument
reads the platform's own debug surfaces over adb, so the device under test runs exactly
the artifact a user would run.

### Database tests

- Constraints and exactly-once event application.
- Atomic send/receive/group-control boundaries with failure at each statement.
- Migration from every supported released schema and restoration after interrupted
  migration.
- Encrypted database/wrapping-key loss behavior.
- Retention, logout/revocation wipe, and bounded cache cleanup.
- Long-history query plans and stream invalidation.

### Backend contract tests

Run against the real Django development stack, PostgreSQL, Redis, the nginx attachment
path, and coturn where applicable:

- every documented status/error and auth scope;
- session renewal (`POST /api/v1/auth/renew`, which does not retire presented tokens) and
  concurrent single-flight requests (contention control, ADR-083);
- device registration/revocation and 4003 close;
- first- and later-device two-phase enrollment, including rejection of registration-time
  `cross_sig`, null/withheld intermediate state, full-scope backup retrieval, idempotent
  resume after idempotent boundaries, ambiguous registration-response reconciliation,
  orphan revocation/device-log updates, and successful prekey cross-signature follow-up;
- identity versioning, ETag/device-log-head invalidation, device-log paging, and opaque
  record behavior;
- classical/PQ prekey races and atomic signed-prekey/cross-signature rotation;
- envelope fan-out above 256 targets, partial-batch progress, ambiguous retry with exact
  ciphertext reuse, drain pagination, duplicates, ack, stale devices, and TTL behavior;
- WebSocket frame/size/rate limits and all close codes;
- attachment buckets, quota, nginx streaming, expiry;
- seven-day pruning, `pruned_through` detection, and no-history-endpoint assertions;
- voice token expiration/reconnect and disabled configuration.

Contract fixtures MUST fail when backend documentation and behavior diverge.

### Widget and golden tests

- Widgetbook story for every reusable component and state.
- Goldens for narrow/medium/wide widths, light/dark/high-contrast, English/Persian,
  maximum text scale, own/peer/group messages, and all delivery/security states.
- Semantics, keyboard order, focus restoration, shortcuts, context menus, and reduced
  motion.
- Timeline-adapter pagination, anchoring, dynamic media/row sizing,
  jump-to-message, and app-owned builder output. Re-run the same suite against any
  package adapter before a future swap; none is declared as of ADR-054.

### End-to-end tests

Use at least two accounts and multiple Android devices for version 1:

- register, activate, complete first-device identity publication/two-phase
  cross-signing/backup, and handle the recovery secret;
- SAS/QR cross-signing, unsigned-device withholding, master-key change, device-log gossip,
  and server-equivocation fork alarm;
- DM send offline/online, process death, ambiguous retry, delivery/read;
- add/revoke devices, verify valid cross-signed additions, and reject invalid/PQ-missing
  devices;
- create group, concurrent admin changes, add/remove, no later copy to a removed member,
  history sharing;
- attachment upload/download/corruption/expiry;
- device-to-device full/partial history transfer, no source online, wrong/lost recovery
  secret, identity recovered without history, and mailbox-gap group state recovery;
- voice create/invite/join/reconnect/remove with encrypted media validation;
- logout, remote revocation, local wipe, deep links, and hidden notifications. The alert
  policy is decided entirely in Dart and is covered by host tests; what a device actually
  renders - lock screen, status-bar icon, heads-up, channel vibration, and the permission
  dialog across Android 13 to 16 - is a release gate that has not been run (ADR-048);
- deferred background catch-up (ADR-049). Everything that decides *when* the platform is
  asked for something, *when* it is told the wake-up is over, and *what a run refuses to
  start* is decided in Dart and covered by host tests. What is not, and is a release gate
  that has not been run: that the job runs at all on a device; that a headless
  `FlutterEngine` starts the `backgroundDelivery` entry point from the release AOT
  snapshot; the Doze, standby-bucket, eight-day restricted-bucket, reboot, force-stop,
  Data-Saver and vendor-battery matrix on Samsung, Xiaomi and an AOSP image across Android
  11 to 16; and whether a persisted job survives an in-place upgrade, which the platform
  documentation does not specify.

Patrol may drive Android native flows. Browser E2E applies if a browser target is approved.

## Adverse-environment matrix

- No network, local-only server, high latency, packet loss, reordering, duplicate frames,
  proxy reset, TLS/pin failure, Redis/backend restart.
- Expired session token during REST/WS, renewal response loss (`POST /api/v1/auth/renew`),
  revoked session token (`401 token_revoked` / WS `4003`), clock skew.
- Android Doze/standby/force-stop/reboot/permission changes/background-poll delay and
  active-voice foreground-service stop.
- Future Web release: tab sleep/reload/multiple tabs/storage eviction/private mode/browser
  upgrade.
- Low disk, database full/corrupt, attachment cancellation, OOM pressure.
- Malicious peer sending maximum valid and malformed payloads.

## Performance gates

Version-1 release budgets are measured on representative low/mid Android devices:

- startup and database unlock;
- 50,000-message conversation open/search/pagination;
- steady 60 fps interaction for target displays with bounded jank;
- encryption/decryption latency and memory for largest envelope/attachment;
- background battery/network use of best-effort polling;
- voice join time and sustained audio quality;
- no unbounded growth in providers, stream subscriptions, skipped keys, inbox, or cache.

## Security verification

- Static analysis, dependency/license audit, SBOM, secret scan, and release-config audit.
- Confirm no foreign DNS/network attempt in an isolated-network rehearsal.
- Inspect logs, notifications, crash paths, backups, screenshots, clipboard, temporary
  files, and the user-initiated diagnostics export for forbidden data.
- Independent security assessment and remediation sign-off.

## Merge and release gates

Pull requests require formatting, analysis, affected unit/widget tests, and documentation
updates. Version-1 release additionally requires the Android build, crypto vectors,
migrations, backend contracts, Android E2E matrix, accessibility, performance, offline
rehearsal, and security review to pass. Coverage percentage alone cannot waive an invariant test.
