# ADR-042: Frozen Beta application ID and persistent signing identity; Production unsigned

- **Status:** Superseded by [ADR-067](067-serving-origin.md) (2026-09-07); Production signing later established by [ADR-076](076-production-signing.md) (2026-09-14)
- **Date:** 2026-08-19 (explicitly recorded in register; committed in `49835aef`; superseded `2026-09-07`)
- **Superseded by:** [ADR-067](067-serving-origin.md) (2026-09-07), committed in `1a169534`
- **Related:** [ADR-028](028-device-history-transfer.md), [ADR-030](030-recovery-key-material.md), [ADR-043](043-private-ca-transport.md), [ADR-044](044-private-deployment.md)

## Decision (Position)

*(Extracted from the ADR-042 register row and its introducing commit `49835aef`; no separate full section existed in `decisions.md`.)*

Originally decided that the Private Experimental Beta ships under a frozen non-placeholder Android application ID and one persistent signing key, while Production stays unsigned and uninstallable:

1. **Frozen flavor application IDs:** Replaced the placeholder `com.example.communication_platform.*` IDs with `dev.nimashadloo.chat{,.beta,.development}` before any external install under a domain the project operated at the time.
2. **Separate identities and signing separation:** Beta and Production use separate application IDs (coexisting with no upgrade path between them) and separate key custody. `buildTypes.release` sets `signingConfig = null`, so Production packages unsigned (still built and verified in CI, but fail-closed because the OS refuses to install it).
3. **Beta signing scheme (v2 + v3):** Beta signs with APK Signature Scheme v2 and v3 only (omitting legacy v1, unnecessary at `minSdk` 24). V3 records the signer to allow future rotation lineage on API 28+, while key loss remains unrecoverable by rotation because creating a rotation lineage requires the original key.
4. **Secret handling and artifact verification:** Private signing material never enters source control; Gradle reads it from environment variables or an untracked properties file and fails the build if absent. The public certificate fingerprint is committed so `tool/verify_release_apk.sh` verifies every artifact against the expected signing identity. Key custody and backup procedures were documented in `release-signing.md`.

**Supersession (ADR-067, 2026-09-07):** When the project stopped operating `nimashadloo.dev` and moved the serving origin to `chat.orviniq.com`, ADR-067 superseded ADR-042's frozen identifiers with `com.orviniq.chat{,.beta,.development}` and reissued the Beta signing key under `CN=com.orviniq.chat.beta` (possible safely because no external install existed yet). ADR-042's underlying reasoning on why identity and signing certificates freeze at first external install remained unchanged and governed the new identifiers. Subsequently, ADR-075 (2026-09-13) deleted the `beta` flavor, and ADR-076 (2026-09-14) gave the `production` flavor (`com.orviniq.chat`) its own persistent RSA-4096 v2+v3 signing identity ([build.gradle.kts](../../../android/app/build.gradle.kts), [SIGNING.md](../../runbooks/SIGNING.md)).

## Rationale

Original rationale:
- Android permits an in-place update only when both the application ID and the signing certificate match the installed app; otherwise the only path forward is uninstalling, which destroys local state permanently here because `allowBackup="false"`, the SQLCipher database and `no_backup` key envelope live in app data, the database key is wrapped by a non-exportable `AndroidKeyStore` key, and the server holds no message history ([ADR-028](028-device-history-transfer.md), [ADR-030](030-recovery-key-material.md)).
- Shipping `com.example.communication_platform.beta` would have guaranteed a forced reinstall after branding; freezing a real domain ID beforehand prevented that.
- Sharing a signing key between Beta and Production would buy no upgrade continuity (the application IDs differ) while exposing Production's identity to Beta's warmer custody and widening compromise blast radius.
- Direct APK distribution has no Google Play upload-key reset, making key loss permanent.

Why superseded: the domain premise (`dev.nimashadloo`) changed to `chat.orviniq.com` (ADR-067), and later ADR-075/ADR-076 retired `beta` and authorized a separate persistent signing identity for `production` testing.

## Constraints and Open Gates

- **Current production identity rules (governed by ADR-067 and ADR-076):** [build.gradle.kts](../../../android/app/build.gradle.kts) reads `application.id` (`com.orviniq.chat`) from `android/production-release-identity.properties`, enables v2+v3 signing only (`enableV1Signing = false`, `enableV4Signing = false`), and fails closed via `requireProductionReleaseSigning` unless signing material is provided or `CP_PRODUCTION_UNSIGNED_BUILD=1` is set. Verified by [android_release_signing_test.dart](../../../test/architecture/android_release_signing_test.dart) and [production_release_packaging_test.dart](../../../test/architecture/production_release_packaging_test.dart).
- Historical `android/beta-release-identity.properties` and `main_beta.dart` were removed when ADR-075 retired the `beta` flavor.

## Costs

- Key loss or application ID changes after first external install cause unrecoverable single-device history loss.
- Keeping signing material outside source control requires external key custody and encrypted backups before external distribution ([SIGNING.md](../../runbooks/SIGNING.md)).

## Reversal Trigger

Already superseded by ADR-067 (2026-09-07); `beta` flavor subsequently removed by ADR-075 (2026-09-13) and production signing defined by ADR-076 (2026-09-14).

## History, Amendments, and Supersession

- **2026-08-19 (`49835aef`):** Recorded ADR-042 (`Accepted`), moving flavors to `dev.nimashadloo.chat{,.beta,.development}`, adding `frontend/docs/release-signing.md`, and keeping Production unsigned.
- **2026-09-07 (`1a169534` / ADR-067):** Superseded (`Superseded by ADR-067 (2026-09-07)`); flavors rebased to `com.orviniq.chat{,.beta,.development}` and Beta signing identity reissued before any external install.
- **2026-09-13 (`cd36012f` / ADR-075) & 2026-09-14 (`04317e36` / ADR-076):** `beta` flavor deleted; Production given its own persistent signing identity.
