# Testing strategy

## Principles

- Test externally visible behavior and protocol invariants, not provider implementation
  details.
- Use deterministic clocks, CSPRNG fixtures only in tests, fake networks, and fault
  injection.
- Every production bug adds a regression test at the lowest useful layer plus an
  integration test when the failure crossed a boundary.
- Real-secret fixtures are forbidden.

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

Version 1 is Android-only. Piece 07's required target tests are the shared Rust primitive
suite, native ABI boundary tests, Android cross-build/package checks, Dart wrapper and
isolate tests, and a smoke call through the library packaged in an Android application.
A host-native dynamic-library test alone is not the packaged Android smoke. The
preserved Web build may exercise only an explicit fail-closed unavailable adapter; it is
not a version-1 target or release gate.

- FIPS 203 ML-KEM, hybrid PQXDH/Double Ratchet, the finalized PQ MLS/OpenMLS profile,
  Argon2id, CBOR, secretstream, and SFrame vectors applicable to the selected
  implementation. Experimental PQ MLS fixtures cannot satisfy the production gate.
- The binding backend golden vectors for `cross_sig`, `master_sig`, `spk_sig`,
  `pq_spk_sig`, optional-field encoding, and the Ed25519/X25519 `ik_pub` layout, plus
  project vectors for SAS/QR values, device-log records/gossip, every event,
  history-transfer batches, attachment headers, and protocol upgrades.
- Future Web release: byte equality between Android `mlkem_native`/shared native code
  and the reviewed browser Wasm implementation.
- Interoperability between independent devices/versions and, where available, independent
  MLS implementations.
- Property tests for encode/decode, encrypt/decrypt, state serialization, replay, skipped
  messages, and epoch transitions.
- Fuzzing of all untrusted binary parsers and state restoration. Nothing is fuzzed
  today: the one in-crate harness covered only the closed-beta PQ MLS inputs and was
  deleted with that core, and the pairwise transport, application-message, and
  attachment parsers were never fuzzed. The pinned stable toolchain and the
  offline/pinned-dependency rules exclude `cargo-fuzz`, libFuzzer, AFL++, ASan, and
  Miri, so coverage-guided instrumentation and a sanitizer build need an approved
  toolchain decision.
- Negative vectors for altered headers, signatures, associated data, padding, counters,
  final tags, credentials, and group commits.

### Device validation

Some questions no test in this repository can answer, because they are questions about
what a manufacturer's Android build does to this application over hours and days. Those
are measured on hardware, against criteria fixed before the measurement, and recorded as
evidence that a release gate reads. The first such gate is sustained delivery
([sustained-delivery-validation.md](sustained-delivery-validation.md), ADR-053): its
criteria, its seven-cell matrix, its instrument (`tool/measure_sustained_delivery.sh`)
and its current state — **closed, no cell run** — live there.

A green test suite says nothing about such a matrix, and the two are never reported as
one result. Nothing is added to the application to make this measurable: the instrument
reads the platform's own debug surfaces over adb, so the device under test runs exactly
the artifact a user would run.

### Database tests

- Constraints and exactly-once event application.
- Atomic send/receive/MLS boundaries with failure at each statement.
- Migration from every supported released schema and restoration after interrupted
  migration.
- Encrypted database/wrapping-key loss behavior.
- Retention, logout/revocation wipe, and bounded cache cleanup.
- Long-history query plans and stream invalidation.

### Backend contract tests

Run against the real Django development stack, PostgreSQL, Redis, nginx attachment path,
and LiveKit/coturn where applicable:

- every documented status/error and auth scope;
- rotating refresh and concurrent single-flight requests;
- device registration/revocation and 4003 close;
- first- and later-device two-phase enrollment, including rejection of registration-time
  `cross_sig`, null/withheld intermediate state, full-scope backup retrieval, idempotent
  resume after idempotent boundaries, ambiguous registration-response reconciliation,
  orphan revocation/device-log updates, and successful prekey cross-signature follow-up;
- identity versioning, ETag/device-log-head invalidation, device-log paging, and opaque
  record behavior;
- classical/PQ prekey races, atomic signed-prekey/cross-signature rotation, consumable
  KeyPackage depletion, last-resort reuse, and 4096/16384 buckets;
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
- create group, concurrent admin changes, add/remove, epoch rotation, history sharing;
- attachment upload/download/corruption/expiry;
- device-to-device full/partial history transfer, no source online, wrong/lost recovery
  secret, identity recovered without history, and mailbox-gap fresh-Welcome recovery;
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

Patrol may drive Android native flows. Browser E2E is post-v1 and is not required for the
Android release.

## Adverse-environment matrix

- No network, local-only server, high latency, packet loss, reordering, duplicate frames,
  proxy reset, TLS/pin failure, Redis/backend restart.
- Expired access during REST/WS, refresh response loss, revoked refresh, clock skew.
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
rehearsal, and security review to pass. Web target gates are post-v1. Coverage percentage
alone cannot waive an invariant test.
