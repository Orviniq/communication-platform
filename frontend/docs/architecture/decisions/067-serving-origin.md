# ADR-067: Serving origin move to `chat.orviniq.com` and rebased Android identities

- **Status:** Accepted *(Note: Beta flavor and identity subsequently deleted by [ADR-075](075-pairwise-groups.md) on 2026-09-13; Production later given a persistent signing identity by [ADR-076](076-production-signing.md) on 2026-09-14)*
- **Date:** 2026-09-07 (explicitly recorded in register and full section; committed in `1a169534` after origin/docs updates `8125b339` and `886402af`)
- **Supersedes:** [ADR-042](042-beta-signing.md)
- **Amends:** [ADR-044](044-private-deployment.md)
- **Related:** [ADR-028](028-device-history-transfer.md), [ADR-030](030-recovery-key-material.md), [ADR-043](043-private-ca-transport.md), [ADR-075](075-pairwise-groups.md), [ADR-076](076-production-signing.md)

## Decision (Position)

Rebased the deployment serving origin and Android application identities from `chat.nimashadloo.dev` / `dev.nimashadloo.chat*` onto `chat.orviniq.com` / `com.orviniq.chat*` before any external device installation existed:

1. **D1 — Serving origin moves to `https://chat.orviniq.com`:**
   - Updated provisioning/deployment/ops references from `chat.nimashadloo.dev` to `https://chat.orviniq.com`, with zero Dart `lib/` changes because the origin is supplied via compile-time `--dart-define` and health/socket/attachment URLs derive from it.
   - Retained original measurement dates in [GROUND-TRUTH.md](../../../../docs/architecture/GROUND-TRUTH.md) because only the cited hostname/site-file name changed.
2. **D2 — Flavor IDs move to `com.orviniq.chat{,.beta,.development}` ([build.gradle.kts](../../../android/app/build.gradle.kts)):**
   - Replaced `dev.nimashadloo.chat{,.beta,.development}` (whose domain premise in [ADR-042](042-beta-signing.md) no longer held) while keeping the Gradle namespace and Kotlin package `com.example.communication_platform` separate from application IDs.
   - Reaffirmed [ADR-042](042-beta-signing.md)'s core reasoning unchanged: Android updates require matching application ID and signing certificate, and uninstalling destroys the SQLCipher database, `no_backup/storage_key_v1.bin` envelope, and non-exportable `AndroidKeyStore` wrapping key (`allowBackup="false"`, `fullBackupContent="false"`, no server message history).
3. **D3 — Freeze safely broken once, then re-bound:**
   - Breaking the freeze was safe on 2026-09-07 only because zero external installs existed outside CI; the freeze re-bound immediately from that date forward.
4. **D4 — Private root CA reused; leaf reissue rotated primary SPKI pin:**
   - Verified from 2026-08-19 `ca.crt`/`ca.key` mtimes and certificate properties (`CN=chat private root CA`, `CA:TRUE, pathlen:0`, no `nameConstraints`, no SAN) that the root CA needed no replacement, preserving `BETA_PRIVATE_CA_SHA256` and `BETA_PRIVATE_CA_PEM_BASE64`.
   - Reissuing the leaf (`CN=chat.orviniq.com`, `subjectAltName=DNS:chat.orviniq.com`, valid to 2028-12-10) via `ops/tls/make_ca.sh` regenerated `server.key` (only `ca.key` and `backup.key` are guarded by `if [ ! -f ]`), moving the **primary** SPKI pin (`BETA_PRIMARY_SPKI_SHA256`) while leaving `backup.key` and the backup pin unchanged. *(Note: [ADR-076](076-production-signing.md) D7 subsequently recorded an unresolved conflict between ADR-067 D4 / server [ADR-0027](../../../../docs/architecture/decisions/0027-the-serving-origin-moves-and-a-pin-moves-with-it.md)'s statement that a stale primary pin fails the handshake and [ADR-043](043-private-ca-transport.md) / `transport_security_native.dart` checking only the private CA in Dart.)*
5. **D5 — Beta signing identity reissued for subject coherence:**
   - Generated a new RSA-4096 SHA-384 v2+v3 Beta signing key on 2026-09-07 (`CN=com.orviniq.chat.beta`, `OU=Private Experimental Beta`, `O=Communication Platform`, SHA-256 `a1189203…fb9a7ba9`, valid to 2054-01-23) while archiving (not destroying) the prior `archived-nimashadloo-` keystore, resetting the two-copy off-site backup obligation for the live Beta key.
6. **D6 — Pre-2026-09-07 artifacts disqualified:**
   - Superseded all APKs built before 2026-09-07 (carrying old origin, ID, certificate, and primary pin), requiring re-execution rather than reuse of prior verification runs.

## Rationale

- [ADR-042](042-beta-signing.md) was superseded rather than edited because its premise ("under a domain the project already operates") became false while its update/keystore reasoning remained valid.
- Reissuing the Beta certificate subject before first external install avoided permanent subject/application-ID incoherence at zero cost.

## Constraints and Open Gates

- **Scope:** Local schema stayed at 18; changed no Dart behavior, endpoints, cryptography, or `backend/` files; opened no production gate.
- **Unenforced provisioning check at ADR-067:** `BETA_PRIMARY_SPKI_SHA256` staleness could not be caught by repository tests because provisioning values live outside Git (later mitigated for production by `tool/build_production_release.sh` checking the live host pin under [ADR-076](076-production-signing.md) D7).

## Costs

- Pre-2026-09-07 artifacts could not be distributed; off-site encrypted backups had to be recreated for the reissued key; `ops/tls/make_ca.sh`'s unconditional `server.key` regeneration remains a separate operational issue.

## Reversal Trigger

Freeze re-bound on 2026-09-07; changing `com.orviniq.chat` after first external install forces uninstall/data loss. (`beta` flavor was subsequently removed by [ADR-075](075-pairwise-groups.md), and `com.orviniq.chat` signing was governed by [ADR-076](076-production-signing.md).)

## History, Amendments, and Supersession

- **2026-09-07 (`8125b339`, `886402af`, `1a169534`):** Accepted ADR-067, superseding [ADR-042](042-beta-signing.md) and amending [ADR-044](044-private-deployment.md).
- **2026-09-13 (`cd36012f` / [ADR-075](075-pairwise-groups.md)) & 2026-09-14 (`04317e36` / [ADR-076](076-production-signing.md)):** Deleted the `beta` flavor (`com.orviniq.chat.beta` remained only on already-installed owner test devices) and gave `com.orviniq.chat` its own persistent production signing identity.
