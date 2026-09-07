# Beta release signing and key continuity

This is the operating manual for shipping the Private Experimental Beta to its
20–30 trusted users. It is written for whoever performs a release, including the
person who inherits this project later. The governing decision is
[ADR-042](decisions.md).

Read [What is actually at stake](#what-is-actually-at-stake) before you touch
anything in here. The rest of the document only makes sense once that is clear.

## What is actually at stake

Android accepts an update only when **both** the application ID and the signing
certificate match what is already installed. If either differs, the OS refuses
the install; the user's only way forward is to uninstall first, and

> a user must first uninstall the currently installed version, which erases all
> app data from the device
> — [How app updates work](https://developer.android.com/google/play/app-updates)

For this client, "erases all app data" is not an inconvenience:

| What is lost | Why it cannot be recovered |
|---|---|
| The SQLCipher database | Deleted with the app data directory. |
| `no_backup/storage_key_v1.bin` | The envelope holding the database key, deleted with it. |
| Any backup of either | `AndroidManifest.xml` sets `allowBackup="false"` and `fullBackupContent="false"`, so Android Backup and `adb backup` hold nothing. |
| The database key itself | Protected by a non-exportable `AndroidKeyStore` key (`MainActivity.kt`), so no exportable copy exists anywhere, by design. |
| Message history | There is no server-side history by design; see `docs/sync-engine.md`. |

A user with a recovery secret and a second enrolled device can restore their
identity and pull history device-to-device (pieces 10 and 17). A single-device
user cannot. Ratchets and MLS epochs are never transferred, so every pairwise
session and every group needs re-establishing regardless.

So: **the signing key and the application ID are user-data-preservation
mechanisms, not build configuration.** Treat them accordingly.

## The frozen identity

| Property | Value |
|---|---|
| Application ID | `com.orviniq.chat.beta` |
| Artifact | Direct-install APK (no App Bundle, no store) |
| Key alias | `communication-platform-beta` |
| Key | RSA 4096, `SHA384withRSA`, 10 000 days (~27 years) |
| Keystore format | PKCS12 |
| Signature schemes | v2 + v3; **not** v1, **not** v4 |
| Certificate SHA-256 | recorded in `android/beta-release-identity.properties` |

`android/beta-release-identity.properties` is committed and contains no secret.
Gradle reads the application ID from it and `tool/verify_release_apk.sh` verifies
artifacts against it, so the built identity and the verified identity cannot
drift apart.

The Android `namespace` is still `com.example.communication_platform`. That is a
build-time Kotlin/resource package only; it is not part of the installed
identity and changing it would affect nothing. It was deliberately left alone.

### Why these signature schemes

`minSdk` is 24, so every device that can install this artifact verifies APK
Signature Scheme v2. The legacy v1 (JAR) signature is therefore dead weight and
is disabled. v3 is enabled because it records the signer in its own block, which
is what a rotation lineage attaches to on API 28+. v4 is disabled: it only
serves ADB Incremental installs and would emit a stray `.idsig` that would then
have to be distributed alongside every APK.

## Beta and Production use different keys

They are **separate applications** that coexist on a device:

- Beta is `com.orviniq.chat.beta`, Production is `com.orviniq.chat`.
- Neither can ever upgrade into the other — different application IDs — so a
  shared key would buy exactly zero upgrade continuity.
- The Beta key has to be reachable for frequent releases, and eventually by CI.
  The Production key is meant to stay offline (`docs/deployment-and-release.md`).
  One key cannot be both.
- If the Beta key leaks, an attacker can sign something that updates *beta*
  installs. That is bad, and bounded. With a shared key it would also be a
  Production-identity forgery.

**Production release is deliberately unsigned.** `buildTypes.release` sets no
signing config; the identity is attached at flavor level to Beta only. So the
Production release APK still builds and is still verified on every CI run, but
the OS cannot install it, which means it cannot reach a user by accident. CI
asserts this in `tool/ci.sh` — note that Flutter copies the artifact to
`app-production-release.apk`, dropping the `-unsigned` suffix the Android build
gave it, so the filename must never be taken as evidence of anything.

Production gains its own signing identity only through an explicit, separate
release decision. Nothing in this document authorizes it.

## One-time setup

### 1. Create the signing identity

Do this **once, ever**, on the maintainer workstation:

```bash
cd frontend && ./tool/create_beta_keystore.sh
```

It prompts for a passphrase (never echoed, never passed on a command line),
writes the keystore outside the repository under
`~/.communication-platform/beta-signing/`, records the public certificate
fingerprint in `android/beta-release-identity.properties`, and writes an
untracked properties file next to the keystore.

It refuses to run if a keystore already exists at the target path, and refuses
if a fingerprint is already recorded. Those refusals are the point: creating a
second identity is the mistake that orphans every existing install.

Commit the fingerprint change. It is public and every later release is verified
against it.

### 2. Point builds at the material

```bash
export CP_BETA_SIGNING_PROPERTIES="$HOME/.communication-platform/beta-signing/beta-signing.properties"
```

### 3. Back it up before building anything for users

```bash
cd frontend && ./tool/backup_beta_keystore.sh --out /path/to/removable/media
```

See [Key custody](#key-custody).

## Key custody

Scale: one private beta, 20–30 users, currently one active release maintainer.
This is deliberately not an enterprise ceremony, but it is not "keep it
somewhere safe" either.

| Question | Answer |
|---|---|
| Who owns the key | The release maintainer (currently the sole holder). |
| How many copies | The working copy, plus **at least two** encrypted backups. |
| Where | The two backups live on two separate physical media, at least one of them not in the same building as the workstation. |
| Encryption | `tool/backup_beta_keystore.sh` — GnuPG symmetric AES-256, SHA-512, iterated S2K. Restoring needs only `gpg` and the passphrase. |
| Passphrases | Keystore passphrase in a password manager. Backup-archive passphrase recorded **separately** from the archive; if they differ, record both. Never store either alongside the file it opens. |
| Access | Only the maintainer. Not in the repository, not in chat, not in a shared drive, not in CI until a CI is actually introduced. |
| Rotation of custody | On handover, the successor generates their own backup passphrases and re-encrypts; the old archives are destroyed. |

### Detecting exposure

The signing certificate fingerprint is public and pinned in
`beta-release-identity.properties`. Exposure of the *private* key is not
directly detectable, so treat these as exposure until proven otherwise:

- the keystore or properties file appearing in `git status`, a diff, or a
  branch — `git log --all --full-history -- '**/beta-signing.properties' '**/*.p12' '**/*.jks'`;
- an artifact you did not build that verifies against the recorded fingerprint;
- the workstation being compromised, lost, or disposed of without wiping.

Run this before every release; it should print nothing:

```bash
git log --all --full-history --oneline -- '**/beta-signing.properties' '**/*.p12' '**/*.jks' '**/*.keystore'
```

If the key is exposed, see [If the key is compromised](#if-the-key-is-compromised).

### If the maintainer's machine is lost

Restore from an encrypted backup onto a new machine (`RESTORE.txt` inside the
archive has the exact steps), then confirm the identity before releasing:

```bash
./tool/verify_release_apk.sh --beta <a previously released apk>
```

The fingerprint it reports must equal the one in
`beta-release-identity.properties`. If it does, nothing was lost.

### If the maintainer becomes unavailable

**This is currently an accepted, unmitigated risk.** With a single holder, the
beta cannot be updated by anyone else, and the outcome is identical to
[losing the key](#if-the-signing-key-is-lost).

To close it, a second trusted holder takes an encrypted backup plus its
passphrase, by the procedure above. No key regeneration is needed and nothing
about the artifact changes — the second holder simply becomes able to restore.
Do this before the beta grows past a handful of users.

## Releasing

Provisioning values are public (origins, CA fingerprint, SPKI pins) and are
supplied per build; they are not secrets and are not compiled into source
control.

```bash
cd frontend
export CP_BETA_SIGNING_PROPERTIES="$HOME/.communication-platform/beta-signing/beta-signing.properties"
export BETA_SERVER_ORIGIN="https://chat.orviniq.com"
export BETA_PRIVATE_CA_SHA256="<64 hex characters>"
export BETA_PRIMARY_SPKI_SHA256="<base64 pin>"
export BETA_BACKUP_SPKI_SHA256="<a different base64 pin>"
export BETA_PRIVATE_CA_PEM="<path to the private CA certificate>"
./tool/build_beta_release.sh --build-number 2 --build-name 0.1.1
```

`--build-number` is the Android `versionCode` and **must strictly increase**;
Android refuses downgrades. Keep a record of the last released number — the
metadata file beside each artifact carries it.

The script fails closed on missing provisioning, missing signing material, or
any verification failure, and refuses to publish an artifact it did not verify.
Output lands in `build/beta-release/`: the APK, its `.sha256`, and a metadata
file recording the source revision, version, and signing certificate.

Then prove the upgrade before distributing — see
[Proving upgrade continuity](#proving-upgrade-continuity).

Distribute the APK, its SHA-256, and the metadata file over the self-hosted
channel. Recipients can check the signer themselves with
`apksigner verify --print-certs <apk>`.

## Verifying an artifact

```bash
./tool/verify_release_apk.sh --beta build/beta-release/<artifact>.apk
./tool/verify_release_apk.sh --production build/app/outputs/flutter-apk/app-production-release.apk
```

Beta mode checks the application ID, that apksigner verifies the signature, that
there is exactly one signer, that v2 and v3 are present and v1 is not, that the
signer is not the Android debug certificate, that the certificate SHA-256 equals
the recorded identity, and that the packaged native core really does export
`cp_crypto_v1_beta_mls_operation`.

It also reads the **compiled network security config back out of the artifact**
and checks that it pins the provisioned host, carries both SPKI pins, disables
cleartext, and packages the private CA as a trust anchor. Resource names are
obfuscated in a release build, so the check resolves them through the resource
table rather than by filename.

Note what that check does and does not prove. Android applies this configuration
to the platform's Java HTTP stacks and WebView; the app's own REST and WebSocket
traffic runs on `dart:io`, which does not consult it (ADR-043). Trust for the
app's traffic comes from `BETA_PRIVATE_CA_PEM`, which `build_beta_release.sh`
also passes to the client as `BETA_PRIVATE_CA_PEM_BASE64`, and is covered by
`test/features/networking/transport_security_test.dart` against a real TLS
handshake. The artifact check confirms the declarative Android configuration is
correct and consistent with provisioning; it is defence in depth, not the
mechanism protecting API traffic.

Production mode checks the application ID, that the artifact is **not** signed,
and that the packaged native core does **not** export the beta MLS symbol — the
Beta/Production native separation asserted at the artifact level, not just in
the build tree.

Every check fails closed. A check that cannot run is an error, never a pass.

## Proving upgrade continuity

A signed APK proves nothing on its own. What matters is that the OS accepts it
as an update to what users already have.

```bash
./tool/verify_upgrade_continuity.sh --old <previous release apk> --new <candidate apk>
```

This uninstalls the app under test on the target device. **Never point it at a
device holding real beta data.**

### Tier 1 — always runs

Installs the previous artifact, launches it, then installs the candidate with
`adb install -r` (no `-d`, no uninstall) and asserts:

- the OS accepted the upgrade in place;
- `versionCode` advanced;
- `firstInstallTime` is unchanged, so this was an update and not a reinstall;
- and, as a negative control, that the same APK re-signed with a *different* key
  is **rejected** — proving signing identity really is what gates the upgrade,
  rather than assuming it.

### Tier 2 — requires `adb root`

Compares SHA-256 digests, across the upgrade, of the wrapped storage key and the
encrypted database, and then again after launching the upgraded build. That last
comparison is the decisive one: if the `AndroidKeyStore` alias had not survived,
the storage runtime reports `wrappingKeyLost` and **wipes** local state
(`local_storage_runtime.dart`), so an unchanged digest after a real launch
proves the upgraded build unwrapped the existing key rather than starting over.

Google Play emulator images are `user` builds and never allow `adb root`. Use a
`google_apis` (non-Play) image:

```bash
sdkmanager "system-images;android-35;google_apis;x86_64"
avdmanager create avd -n cp_beta_root -k "system-images;android-35;google_apis;x86_64" -d pixel_6
```

When root is unavailable the script reports Tier 2 as **SKIPPED**, never as
passed.

### Tier 3 — manual, with a live backend

Tiers 1 and 2 prove the OS and the storage layer. Only this tier proves product
state. Run it before the first external release and before any release that
touches storage, schema, or crypto state.

1. Point `BETA_SERVER_ORIGIN` at a running beta backend and build artifact N.
2. Install N on a physical device. Register an account and enrol the device.
3. Create representative state: a pairwise conversation with at least ten
   messages in both directions, one attachment, one beta group with a second
   device invited, and at least one group membership change.
4. Record what you expect to survive: the account, the device list, the safety
   number, the message count per conversation, the group roster and epoch.
5. Build artifact N+1 from the same key with a higher `--build-number`.
6. `adb install -r <N+1>` — it must succeed with no uninstall and no `-d`.
7. Launch. Confirm **without re-registering or re-enrolling**: still signed in;
   the device list and safety number unchanged; every conversation shows the
   same message history; the attachment still opens; the group still shows its
   roster; a new message sends and is received by the second device.
8. Confirm the identity did not change:
   `adb shell dumpsys package com.orviniq.chat.beta | grep -i versionCode`
   and `apksigner verify --print-certs` on both artifacts — same certificate.

Record the result and the two build numbers in the release notes.

## Failure modes, honestly

### If the signing key is lost

For an app distributed outside Play there is no recovery path:

> if you lose your app's signing key, you lose the ability to update your app
> — [Sign your app](https://developer.android.com/studio/publish/app-signing)

Concretely:

| Question | Answer |
|---|---|
| Can existing installs be updated? | **No. Never.** |
| Can rotation fix it? | **No.** A v3 rotation lineage is built by having the *old* key sign the new one. Without the old key there is no lineage. |
| Can new users still install? | Yes, with a new key and a **new application ID**, as a different app. |
| Do existing users keep their data? | Only by staying on the last release forever. Moving to the new app is an uninstall, and the data does not survive it. |
| Is there an upload-key reset? | No. That exists only under Play App Signing, which does not apply to direct APK distribution. |

There is no partial recovery. This is why the backup procedure is mandatory
before the first external install, not after.

### If the key is compromised

Rotation limits it going forward but does not undo it. An attacker holding the
key can sign an update that any existing install accepts, and on devices below
API 28 rotation does not help at all, because

> Devices running Android 8.1 (API level 27) or lower don't support changing the
> signing certificate
> — [APK signature scheme v3](https://source.android.com/docs/security/features/apksigning/v3)

With `minSdk` 24, the original key must keep signing the v2 block forever, so it
can never actually be retired. Assume compromise is permanent, tell the beta
users out of band, and treat a new application ID as the real remedy — with the
data loss that implies.

### If `versionCode` was not increased

The install is refused as a downgrade. Rebuild with a higher `--build-number`.
Never work around this with `adb install -d` or an uninstall.

## What maintainers must never do

- Never generate a second Beta keystore. If a build cannot find the key, find
  the key; do not create one.
- Never change `application.id` or `signing.certificate.sha256` in
  `android/beta-release-identity.properties`.
- Never commit a keystore, a `beta-signing.properties`, or any passphrase.
- Never hardcode a password into a Gradle file.
- Never distribute a debug-signed APK. The debug key is per-machine and no real
  release could ever update it.
- Never distribute an artifact that `tool/verify_release_apk.sh --beta` has not
  passed.
- Never sign Production with the Beta key, and never give the release build type
  a signing config to "make production installable".
- Never treat an uninstall/reinstall as an acceptable migration.
- Never enable Gradle's configuration cache for a release build without
  re-checking that signing material is not serialised to disk.
- Never run a release build with `--debug` or `--info` logging and then publish
  the log.

## CI secret contract

There is no CI in this repository today, and the release path deliberately does
not require one. `tool/build_beta_release.sh` runs the same way on a workstation
and on a runner.

If CI is introduced later, it needs these injected as secrets — and nothing
else:

| Secret | Purpose |
|---|---|
| `CP_BETA_KEYSTORE_FILE` | Absolute path to the keystore materialised on the runner. Relative paths are rejected, because they would resolve against whatever directory the build started in. |
| `CP_BETA_KEYSTORE_PASSWORD` | Keystore passphrase. |
| `CP_BETA_KEY_ALIAS` | `communication-platform-beta`. |
| `CP_BETA_KEY_PASSWORD` | Key passphrase. |
| `BETA_SERVER_ORIGIN`, `BETA_PRIVATE_CA_SHA256`, `BETA_PRIMARY_SPKI_SHA256`, `BETA_BACKUP_SPKI_SHA256` | Provisioning. Public values, but keep them out of the repository. |
| `BETA_PRIVATE_CA_PEM` | Path to the private CA certificate on the runner. Public material, but the build fails closed without it, and the app cannot reach the server without it. |

Supplying only *some* of the `CP_BETA_*` variables is a hard failure, never a
silent fallback to the file.

Before adopting a hosted CI, weigh what it means: the beta signing key would
live on someone else's infrastructure. For 20–30 users, a maintainer-run
release is the smaller risk, and it is what this pipeline is built for. The
Android NDK, Rust toolchain, and AWS-LC build also have to be reproduced on the
runner, which is not free.

## Primary references

- [App signing](https://source.android.com/docs/security/features/apksigning) — scheme overview
- [APK signature scheme v3](https://source.android.com/docs/security/features/apksigning/v3) — rotation and its API-level limits
- [Sign your app](https://developer.android.com/studio/publish/app-signing) — key validity, key loss
- [How app updates work](https://developer.android.com/google/play/app-updates) — update compatibility rules
- [apksigner](https://developer.android.com/tools/apksigner) — verification and rotation tooling

Verified against these sources on 2026-08-19.
