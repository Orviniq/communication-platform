# ADR-076: Persistent signing identity, custody, and release pipeline for `production`

- **Status:** Accepted
- **Date:** 2026-09-14 (explicitly recorded in register and full section; accepted on owner answers in `04317e36`, implemented across PR #56 / `7ececaa1`)
- **Amends:** [ADR-042](042-beta-signing.md) and [ADR-067](067-serving-origin.md) (production unsigned clause), [ADR-045](045-maturity-disclosure.md) (D6 production disclosure and D1 designation rationale)
- **Related:** [ADR-017](017-independent-crypto-review.md), [ADR-028](028-device-history-transfer.md), [ADR-030](030-recovery-key-material.md), [ADR-043](043-private-ca-transport.md), [ADR-052](052-accurate-capability-claims.md), [ADR-053](053-field-evidence-gate.md), [ADR-054](054-dependency-policy.md), [ADR-067](067-serving-origin.md), [ADR-075](075-pairwise-groups.md), ADR-094

## Decision (Position)

Gave the `production` Android flavor (`com.orviniq.chat`) one persistent signing identity and provisioned release pipeline so the owner can install and test pairwise groups on real phones without treating the artifact as a public release:

1. **D1 — Scope (named-recipient test builds, not a public release):**
   - Enables installing `com.orviniq.chat` on owner/known-participant devices with written disclosure and [third-party-notices.md](../../third-party-notices.md); no store, download page, or update channel.
2. **D2 — Frozen identity ([production-release-identity.properties](../../../android/production-release-identity.properties)):**
   - Permanent application ID `com.orviniq.chat` (approved by Owner Question 1), RSA-4096 `SHA384withRSA` (10,000 days), PKCS12 alias `communication-platform-production`, subject `CN=com.orviniq.chat, OU=Production, O=Communication Platform`, APK Signature Schemes **v2 and v3 only** (no v1 at `minSdk` 24; no v4 `.idsig`).
   - Committed public certificate SHA-256 `a06f9e8a250dc68bf95bdf3f9ffcf4c5dc81e6bd82a785011cd1a1e964cc8395` (`ccf2ada4`) in `android/production-release-identity.properties`, read by both Gradle and `tool/verify_release_apk.sh`.
3. **D3 — Workstation custody (Owner Question 2, Option A) and encrypted backups:**
   - Recorded explicit deviation from [deployment-and-release.md](../../deployment-and-release.md) step 4's offline-key requirement: keystore and untracked `production-signing.properties` live in `~/.communication-platform/production-signing/` on the maintainer workstation (which also holds `backend/ops/tls/out/` private CA material), protected by Windows profile ACLs (`chmod` is a no-op on Git Bash `noacl` NTFS).
   - Required two independent GnuPG AES-256 symmetric backups (`tool/backup_production_keystore.sh` using `--s2k-digest-algo SHA512`) on separate drives (one off-site), test-decrypted by the owner before first install. Any public release under `com.orviniq.chat` inherits this key's custody history.
4. **D4 — Irreversible loss and leak facts:**
   - Lost key/passphrase permanently orphans all existing installs (v3 key rotation requires the original key). Leaked key permits malicious updates on every API level (`minSdk < 28` ignores v3 and verifies v2, and rotation below rotation-min-sdk still allows original key signing); recovery requires a new application ID and uninstall/data loss.
5. **D5 & D6 — Fail-closed Gradle signing and verification ([build.gradle.kts](../../../android/app/build.gradle.kts), [verify_release_apk.sh](../../../tool/verify_release_apk.sh), [ci.sh](../../../tool/ci.sh), [ci.ps1](../../../tool/ci.ps1)):**
   - Signing material enters only via `CP_PRODUCTION_SIGNING_PROPERTIES` (absolute path) or all four `CP_PRODUCTION_KEYSTORE_*`/`CP_PRODUCTION_KEY_*` env vars (never an in-repo properties fallback; partial or conflicting sets fail; attached to `production` flavor only so `buildTypes.release` keeps `signingConfig = null`).
   - `requireProductionReleaseSigning` fails closed without material unless `CP_PRODUCTION_UNSIGNED_BUILD=1` is set (and fails if both are set). CI builds with `CP_PRODUCTION_UNSIGNED_BUILD=1` and verifies with `--production-unsigned`; `--production` verifies 15 checks including apksigner v2+v3, non-debug signer, exact fingerprint, packaged `network_security_config.xml` pins/host/no-cleartext, and `raw/provisioned_private_ca`.
6. **D7 — Provisioning and release script ([render_production_trust.sh](../../../tool/render_production_trust.sh), [build_production_release.sh](../../../tool/build_production_release.sh), [release_env.sh](../../../tool/release_env.sh)):**
   - Derives `PRODUCTION_*` values fresh from `backend/ops/tls/out/` (without committing pins/CA digests), verifies live host primary pin (`30 s` timeout), renders ignored Android trust XML/PEM resources, builds with five defines, verifies with `--production`, checks `versionCode`, and publishes under `build/production-release/`.
   - **Recorded unresolved conflict:** [ADR-043](043-private-ca-transport.md) and `transport_security_native.dart` trust only the private CA in `dart:io` without checking SPKI pins in Dart, whereas [ADR-067](067-serving-origin.md) D4, server [ADR-0027](../../../../docs/architecture/decisions/0027-the-serving-origin-moves-and-a-pin-moves-with-it.md), and [SECURITY.md](../../../../docs/security/SECURITY.md) state that stale primary pins fail API handshakes. Left open for a separate decision.
7. **D8 — Deployment disclosure without Experimental designation (Owner Question 3):**
   - Deleted unused `AppEnvironment.beta` (`BETA_*` defines and beta sustained-delivery case); renamed `DeploymentDisclosure.privateExperimental` to `DeploymentDisclosure.distributed` ([deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart)) and attached it to `AppEnvironment.production` (revision 9: rewrote `pairwiseGroups` and removed the `withheld` sustained-delivery switch promise in `bestEffortDelivery`).
   - By owner decision, production keeps launcher label/title "Communication Platform" with no Experimental banner. *(Note: `DeploymentDisclosure.distributed` subsequently moved to rev 11 across ADR-089, ADR-094, and ADR-098.)*
8. **D9 — Key-handling and `adb install` rules (Owner Question 4, Option A):**
   - Owner alone creates keys/backups outside agent visibility. Agent sessions may run `tool/build_production_release.sh` passing only `CP_PRODUCTION_SIGNING_PROPERTIES` path (never reading `~/.communication-platform/`, `keytool`, or `apksigner sign`).
   - Artifacts reach devices only via `adb install` (never `-d`, `flutter install`, `flutter run`, or `flutter drive`, which can uninstall existing signed data).
9. **D10 — Gates unchanged:**
   - Opens no gate: [ADR-017](017-independent-crypto-review.md), [implementation-checklist.md](../../implementation-checklist.md) production gates, [deployment-and-release.md](../../deployment-and-release.md) checklist items, [ADR-053](053-field-evidence-gate.md) (until ADR-094 later changed `production` to `bestEffort`), and [ADR-054](054-dependency-policy.md) follow-up F2 remain closed.

## Rationale

- Keeping `production` unsigned prevented testing pairwise groups on real phones; adopting the reviewed [ADR-042](042-beta-signing.md) pipeline under `com.orviniq.chat` without in-repo secret fallbacks preserves fail-closed CI while enabling controlled device installs.

## Constraints and Open Gates

- **As-built verification:** Covered by [production_key_tooling_test.dart](../../../test/architecture/production_key_tooling_test.dart), [android_release_signing_test.dart](../../../test/architecture/android_release_signing_test.dart), [production_release_packaging_test.dart](../../../test/architecture/production_release_packaging_test.dart), and [deployment_disclosure_test.dart](../../../test/architecture/deployment_disclosure_test.dart).
- **First device install (2026-09-14, build 2 at `f85196de`):** Installed via `adb install` on Galaxy A56 (Android 16, `arm64-v8a`) and Android 15 emulator (`x86_64`) reaching the Login screen alongside retained `com.orviniq.chat.beta` build 33 ([2026-09-14-build-2/README.md](../../validation/production-release/2026-09-14-build-2/README.md), [release-signing.md](../../release-signing.md)).
- **Open gap:** D7 runtime TLS SPKI-pinning conflict between [ADR-043](043-private-ca-transport.md) / `transport_security_native.dart` and [SECURITY.md](../../../../docs/security/SECURITY.md) / server [ADR-0027](../../../../docs/architecture/decisions/0027-the-serving-origin-moves-and-a-pin-moves-with-it.md) remains open in [STATUS.md](../../STATUS.md#platform-identity-and-content).

## Costs

- Workstation custody exposes both the update signing key and private root CA key to the same workstation user account until moved offline; `production` carries no on-screen Experimental banner despite unreviewed cryptography.

## Reversal Trigger

Application ID and first signing key are permanent for existing installs; reopen custody if moving signing offline, reopen D7 for runtime Dart SPKI pinning, and reopen D8 whenever `DeploymentDisclosure` changes (subsequently revised by ADR-089, ADR-094, and ADR-098).

## History, Amendments, and Supersession

- **2026-09-14 (`61830f64`, `04317e36`, PR #56 `7ececaa1`):** Proposed, accepted on owner's four answers, implemented key tooling, Gradle signing, trust rendering/release script, disclosure rev 9, and verified build 2 install (`f85196de`).
- **2026-10-18 – 2026-10-19 (ADR-094 & ADR-098):** ADR-094 superseded [ADR-053](053-field-evidence-gate.md) for `production` to offer best-effort sustained delivery and moved `DeploymentDisclosure.distributed` to rev 10; ADR-098 moved it to rev 11.
