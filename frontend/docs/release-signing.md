# Production release signing and key continuity

This is the operating manual for making, signing, verifying and installing builds of the
`production` flavor, `com.orviniq.chat`. It is written for whoever makes a build,
including the person who inherits this project later. The governing decision is
[ADR-076](decisions.md), which on 2026-09-14 gave production one persistent signing key,
so that the owner can install real builds on their own devices and hand one to a known
person taking part in a test.

An installable build is not a released one. No store, download page or update channel
carries it, and signing it opens nothing: not ADR-017, not a production completion gate in
`implementation-checklist.md`, not an item of the production release checklist in
[deployment-and-release.md](deployment-and-release.md), not ADR-053's sustained-delivery
gate, and not ADR-054's follow-up F2, so a build reaches nobody except by hand (ADR-076
D1 and D10).

Read [What is at stake](#what-is-at-stake) before you touch anything in here. The rest of
the document only makes sense once that is clear.

## What is at stake

Android accepts an update only when **both** the application ID and the signing
certificate match what is already installed. If either differs, the OS refuses the
install, and the only way forward is to uninstall first, which erases the app's data from
the device ([How app updates work](https://developer.android.com/google/play/app-updates)).

For this client that erasure is not an inconvenience:

| What is lost | Why it cannot be recovered |
|---|---|
| The SQLCipher database | Deleted with the app data directory. |
| `storage_key_v1.bin` in the no-backup directory | The envelope holding the database key, deleted with it. |
| Any backup of either | `AndroidManifest.xml` sets `allowBackup="false"` and `fullBackupContent="false"`, so Android Backup and `adb backup` hold nothing. |
| The database key itself | Wrapped by a non-exportable `AndroidKeyStore` key (`ProtectedStorageChannel.kt`), so no exportable copy exists anywhere, by design. |
| Message history | There is no server-side history by design; see `sync-engine.md`. |

A user with a recovery secret and a second enrolled device can restore their identity and
pull history device-to-device (pieces 10 and 17). A single-device user cannot. Ratchets and
group control state are never transferred, so every pairwise session needs re-establishing
regardless, and a group returns only when one of its members sends the group's current
control state.

So **the signing key and the application ID are user-data-preservation mechanisms, not
build configuration.** Both freeze at the first install on any device. Before it, either
can still change without harming anybody; from then on, neither ever changes (ADR-076 D2).

## The frozen identity

| Property | Value |
|---|---|
| Application ID | `com.orviniq.chat`, permanent by the owner's answer to ADR-076's first question |
| Artifact | Direct-install APK: no App Bundle, no store |
| Key alias | `communication-platform-production` |
| Key | RSA 4096, `SHA384withRSA`, valid for 10 000 days (a little over 27 years) |
| Keystore format | PKCS12 |
| Certificate subject | `CN=com.orviniq.chat, OU=Production, O=Communication Platform` |
| Signature schemes | v2 and v3; **not** v1, **not** v4 |
| Certificate SHA-256 | Recorded in `android/production-release-identity.properties` |

`android/production-release-identity.properties` is committed and holds no secret. Gradle
reads the application ID from it, and `tool/verify_release_apk.sh` reads the application ID
and the certificate SHA-256 from it through `tool/release_env.sh`, so the built identity and
the verified identity cannot drift apart. The certificate SHA-256 is public: it names the
signer, and it is neither an SPKI pin nor a CA digest, both of which stay out of the tree.

The development flavor is `com.orviniq.chat.development`, a separate application that
coexists with production on a device and is never handed to anyone. The Android `namespace`
is still `com.example.communication_platform`. That is a build-time Kotlin and resource
package, not part of the installed identity, and it was deliberately left alone.

### Why these signature schemes

`minSdk` is 24, the pinned SDK's `flutter.minSdkVersion`, so every device that can install
this artifact verifies APK Signature Scheme v2, and a v1 (JAR) signature is dead weight. v3
records the signer in its own block, which is what a later rotation lineage attaches to on
API 28 and above. v4 serves only incremental installs, from a separate `.idsig` file that
would have to travel beside every APK.

### How a build gets the key

Gradle takes signing material from two places, both outside the repository, and from
nowhere else (ADR-076 D5):

- the untracked properties file that `CP_PRODUCTION_SIGNING_PROPERTIES` names by an
  absolute path, holding `storeFile`, `storePassword`, `keyAlias` and `keyPassword`; or
- all four of `CP_PRODUCTION_KEYSTORE_FILE` (an absolute path),
  `CP_PRODUCTION_KEYSTORE_PASSWORD`, `CP_PRODUCTION_KEY_ALIAS` and
  `CP_PRODUCTION_KEY_PASSWORD`.

A partial set of the four fails, naming the key both ways fails, and a Git Bash `/c/...`
path is read as `C:/...`. The signing config is attached inside `create("production")`
alone, so only `productionRelease` is signed with the key, and `buildTypes.release` keeps
`signingConfig = null`. `productionDebug` and Flutter's `productionProfile` stay
debug-signed while claiming `com.orviniq.chat`, which is one reason for
[the install rule](#installing-on-a-device).

A `productionRelease` build without the key fails closed, unless
`CP_PRODUCTION_UNSIGNED_BUILD=1` asks for an unsigned package, which the OS refuses to
install. Asking for both fails as well. CI (`tool/ci.sh`, `tool/ci.ps1`) builds that way,
with every production signing variable removed from the build's environment, and verifies
the result with `tool/verify_release_apk.sh --production-unsigned`. A file name is no
evidence either way: Flutter copies the artifact to `app-production-release.apk` signed or
not (ADR-076 D6).

## Key custody

| Question | Answer |
|---|---|
| Who holds the key | The owner, currently the only holder. |
| Where it lives | `~/.communication-platform/production-signing/` on the maintainer workstation: the keystore `communication-platform-production.p12` and the untracked `production-signing.properties`. Never inside a repository. |
| Why there | The owner's answer to ADR-076's second question: this workstation, "for now". [deployment-and-release.md](deployment-and-release.md) step 4 asks for an offline-controlled key, and ADR-076 D3 records the deviation and what it costs from the first day. A public release under `com.orviniq.chat` would inherit a key that was never offline, and moving it offline later limits future exposure and undoes none of the past. |
| How many copies | The working copy plus **two** encrypted backups, each on its own drive, one of them kept in another building. Both are made and test-decrypted before the first install, and nothing is installed until the owner confirms that both open (ADR-076 D3). A copy on the workstation's own disks is not a backup. |
| Encryption | `tool/backup_production_keystore.sh`: GnuPG symmetric AES-256, with the passphrase salted and iterated over SHA-512 (`--s2k-digest-algo SHA512`, `--s2k-mode 3`, `--s2k-count 65011712`). Restoring needs only `gpg` and the backup passphrase. |
| Passphrases | The keystore passphrase lives in the owner's password manager. Each backup archive's passphrase is recorded apart from that archive. Never store a passphrase beside the file it opens. |
| What protects the folder | On Windows, the profile's access list, not `chmod`: Git Bash mounts NTFS with `noacl`, so the `chmod 700` and `chmod 600` the scripts run set no Windows permission. The properties file holds the passphrase in plain text beside the keystore, so anything that runs as the owner can sign with the key (ADR-076 D3). |
| Who does what | Only the owner creates the key and makes the backups, in their own shell, because the passphrase must never be typed where a session can see it. An agent session may run the signed build through `tool/build_production_release.sh` alone, passing the properties file by its path. It never reads, prints, lists or copies anything under `~/.communication-platform/`, never runs `keytool` or `apksigner sign` against the keystore, and never creates a key (ADR-076 D9). |

The same workstation also holds the private CA's key in `backend/ops/tls/out/`, so one
compromise of the owner's account would yield both the key every install trusts for its
updates and the authority every install trusts for its connection (ADR-076 D3).

### Detecting exposure

The certificate fingerprint is public. Exposure of the *private* key is not directly
detectable, so treat each of these as exposure until proven otherwise:

- the keystore or the properties file appearing in `git status`, a diff or a branch;
- an artifact you did not build that verifies against the recorded fingerprint;
- the workstation being compromised, lost, or disposed of without wiping.

Run this before every build; it prints nothing:

```bash
git log --all --full-history --oneline -- '**/production-signing.properties' '**/*.p12' '**/*.jks' '**/*.keystore'
```

If the key is exposed, see [If the key leaks](#if-the-key-leaks).

### If the workstation is lost

Restore the keystore from one of the encrypted backups onto a new machine. `RESTORE.txt`
inside the archive gives the steps, including how to write the properties file again. Then
confirm the identity before building anything: the owner lists the certificate with
`keytool -list -v -alias communication-platform-production -keystore <path to the keystore>`,
and its `SHA256` line, without colons and in lower case, must equal
`signing.certificate.sha256` in the identity file. The next build must then pass
`tool/verify_release_apk.sh --production`. If both hold, nothing was lost.

### If the owner becomes unavailable

**This is an accepted, unmitigated risk.** With one holder nobody else can update an
install, and the outcome is the same as
[losing the key](#if-the-key-or-its-passphrase-is-lost). To close it, a second trusted
holder takes an encrypted backup and its passphrase, under the custody rules above. Nothing
about the key or the artifact changes; the second holder simply becomes able to restore.

## One-time setup

**Done on 2026-09-14**, when the owner created the key and committed its fingerprint
(`ccf2ada`). The steps are kept so that anyone can check what was done. They may run again
only while nothing is installed anywhere and the fingerprint line is empty; once anything
is installed, [never](#what-maintainers-must-never-do).

The owner runs every step in their own Git Bash window, never in a terminal a session can
read.

1. **Check that no key exists.**
   `ls -la ~/.communication-platform/production-signing 2>/dev/null || echo "none yet"`
   prints `none yet`, and the `signing.certificate.sha256=` line of
   `android/production-release-identity.properties` has nothing after the `=`. If either
   says otherwise, stop and delete nothing.
2. **Choose the keystore passphrase** in the password manager first: at least 16 random
   characters, printable ASCII, with no backslash and no space at either end.
   `tool/create_production_keystore.sh` refuses anything else, because
   `java.util.Properties` would hand Gradle a different passphrase from the keystore's.
3. **Create the key.**

   ```bash
   cd frontend && ./tool/create_production_keystore.sh
   ```

   It reads the passphrase twice without echo, writes the keystore and the properties file
   under `~/.communication-platform/production-signing/`, and records the certificate
   SHA-256 in the identity file. It refuses an existing keystore, an existing properties
   file, a recorded fingerprint, a path inside the repository and an identity file that
   names another application ID. Those refusals are the point: a second key orphans every
   install the first one signed. Copy the certificate SHA-256 it prints into the password
   manager entry.
4. **Check the result.** `git status --short` lists only the identity file, and `git diff`
   changes only its `signing.certificate.sha256=` line.
5. **Back up to the first drive**, then prove that the archive opens without writing the
   key to disk. Replace `/g/` with the drive. `gpgconf` clears gpg's passphrase cache, so
   the test really asks for the passphrase, and the listing must name
   `communication-platform-production.p12` and `RESTORE.txt`:

   ```bash
   ./tool/backup_production_keystore.sh --out /g/communication-platform-production-signing
   gpgconf --reload gpg-agent
   (cd /g/communication-platform-production-signing && sha256sum -c *.tar.gz.gpg.sha256 && gpg --decrypt *.tar.gz.gpg | tar -tzf -)
   ```

6. **Back up to the second drive** by running the script again on that drive, rather than
   copying the first archive, and test it the same way.
7. **Store the drives.** Label each with its public `.txt` label, keep one in another
   building, and keep the other away from the workstation.
8. **Check that nothing secret reached git** with the command under
   [Detecting exposure](#detecting-exposure), then commit the fingerprint line and nothing
   else.

## Releasing

`tool/build_production_release.sh --build-number N` is the only supported way to make a
production artifact for a phone (ADR-076 D7). A signed build without provisioning stops at
the "App not provisioned" screen and tests nothing, which is what a bare
`flutter build apk --release --flavor production` makes when it does not fail closed.

### 1. Derive the provisioning values afresh, for every build

The app reads five public values at compile time (`lib/app/config/app_configuration.dart`),
and a missing or malformed one stops it at "App not provisioned". They are public, but they
are never committed and never carried over from an earlier build:
`backend/ops/tls/make_ca.sh` mints a new `server.key` on every run, so the primary pin can
move with nothing in this repository noticing (ADR-067 D4). **Never run `make_ca.sh` as
part of a release.**

Write the exports into a scratch file outside the repository, `source` it in the shell that
builds, and delete it afterwards. On Windows `openssl` is the native binary: give it
`C:/...` or `F:/...` paths, and set `MSYS_NO_PATHCONV=1`. Below, `<tls-out>` stands for the
absolute path of `backend/ops/tls/out/` in that form. Read only `ca.crt` and `server.crt`
there, and use `backup.key` only as the input of `openssl pkey -pubout`.

```bash
export PRODUCTION_SERVER_ORIGIN="https://chat.orviniq.com"
export PRODUCTION_PRIVATE_CA_PEM="<tls-out>/ca.crt"
export PRODUCTION_PRIVATE_CA_SHA256="$(openssl x509 -in "$PRODUCTION_PRIVATE_CA_PEM" -outform der | openssl dgst -sha256 | sed 's/^.*= *//')"
export PRODUCTION_PRIMARY_SPKI_SHA256="$(openssl x509 -in <tls-out>/server.crt -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"
export PRODUCTION_BACKUP_SPKI_SHA256="$(openssl pkey -in <tls-out>/backup.key -pubout -outform der | openssl dgst -sha256 -binary | base64)"
```

Each value has one shape, and the release script refuses any other:

| Variable | Shape |
|---|---|
| `PRODUCTION_SERVER_ORIGIN` | An https origin with no user info, path, query or fragment |
| `PRODUCTION_PRIVATE_CA_PEM` | A path to a file holding one PEM certificate and nothing else, because the file is packaged whole |
| `PRODUCTION_PRIVATE_CA_SHA256` | `<64 hexadecimal characters>`: the SHA-256 of that certificate in DER |
| `PRODUCTION_PRIMARY_SPKI_SHA256` | `<44 base64 characters, ending in =>` |
| `PRODUCTION_BACKUP_SPKI_SHA256` | `<44 base64 characters, ending in =>`, different from the primary |

The fifth define, `PRODUCTION_PRIVATE_CA_PEM_BASE64`, is not derived by hand: the script
encodes the certificate itself.

To see before a build whether the host still serves the primary pin (the script checks it
again), compare the output of this with `PRODUCTION_PRIMARY_SPKI_SHA256`:

```bash
echo | openssl s_client -connect chat.orviniq.com:443 -servername chat.orviniq.com 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
```

`curl` needs `--ssl-no-revoke` to reach the host from Windows.

### 2. Build

Commit first, so that the metadata names a clean revision. Then:

```bash
cd frontend
source <the scratch file>
export CP_PRODUCTION_SIGNING_PROPERTIES="C:/Users/<you>/.communication-platform/production-signing/production-signing.properties"
./tool/build_production_release.sh --build-number <N>
```

Do not run `flutter analyze` or `flutter test` while the build runs: both regenerate the
gitignored plugin registrant with a development-only plugin in it, and the release build
then fails to compile.

The script refuses to start:

1. without a certificate recorded in the identity file;
2. without all five values, each in its shape, with two different pins;
3. without signing material, or with a properties file or keystore inside the repository;
4. with `CP_PRODUCTION_UNSIGNED_BUILD` set at all;
5. with a build number that is not greater than every `Version code:` recorded in
   `build/production-release/*.metadata.txt`, or that already names an artifact there;
6. without a JDK 17 or newer, which `apksigner` needs at the end;
7. when the live host cannot be reached, or serves a primary pin other than
   `PRODUCTION_PRIMARY_SPKI_SHA256`. Where `timeout` exists, as in Git Bash, a host that
   never answers is given up on after 30 seconds.

Then it renders the Android trust resources with `tool/render_production_trust.sh`
([`android/provisioning/README.md`](../android/provisioning/README.md)), which checks the CA
certificate against its SHA-256 and its expiry before writing anything; builds
`--release --flavor production --target lib/main_production.dart` with the five defines;
exports `JAVA_HOME` in `C:/...` form; and runs `tool/verify_release_apk.sh --production`. It
publishes nothing that check did not pass. What it publishes lands in
`build/production-release/`:

- `communication-platform-<version>-<N>.apk`;
- its `.sha256`;
- a `.metadata.txt` recording the source revision, whether the working tree was dirty, the
  application ID, the version name and code, the certificate SHA-256, the APK SHA-256 and
  the server origin. It names no pin and no CA digest.

### Build numbers

The version code starts at 1 and only rises (ADR-076 D9). `build/production-release/`
belongs to one checkout and `flutter clean` deletes it, so the script's refusal is a
convenience. Android refuses a downgrade by itself, and the numbers are recorded here. A
number is never reused, even for a build nobody installed.

- **Last installed build:** none yet.

### 3. Hand the build over

A build handed to someone carries the written disclosure and
[third-party-notices.md](third-party-notices.md) in the same handover, before they install
([deployment-and-release.md](deployment-and-release.md) steps 8 to 10). Hand over the APK,
its `.sha256` and its metadata file. The recipient can confirm the signer with
`apksigner verify --print-certs <apk>`.

## Installing on a device

**An artifact reaches a device only through `adb install`, never with `-d`, and nothing is
uninstalled** (ADR-076 D9).

- A first install is `adb install <apk>`, and an update is `adb install -r <apk>`. If
  Android refuses either, stop: a refusal changes nothing on the device, while an uninstall
  destroys the app's local data for good.
- Never point `flutter install`, `flutter run` or `flutter drive` at a device that holds the
  signed app, because in the pinned `flutter_tools` each of them can delete it.
  `flutter install` uninstalls an installed app before it installs. `flutter run` answers a
  refused install over an installed app by uninstalling that app and trying again, and a
  `productionDebug` or `productionProfile` build is debug-signed under the same application
  ID, so it is refused. `flutter drive` uninstalls the app when it finishes, unless
  `--keep-app-running` or `--use-existing-app` is passed. `--flavor development` targets
  `com.orviniq.chat.development` and cannot touch the signed app.
- An update was applied in place when `adb shell dumpsys package com.orviniq.chat` shows
  `firstInstallTime` unchanged, and `versionCode` and `lastUpdateTime` moved.
- Record the number of every installed build under [Build numbers](#build-numbers).

Reaching the Login screen on a device proves that the build carries the right origin and
CA. It proves nothing about the pins; see
[What the trust checks prove](#what-the-trust-checks-prove).

## Verifying an artifact

```bash
./tool/verify_release_apk.sh --production build/production-release/<artifact>.apk
./tool/verify_release_apk.sh --production-unsigned build/app/outputs/flutter-apk/app-production-release.apk
```

On Windows `apksigner` rejects a `/c/...` `JAVA_HOME`, so before running the verifier by
hand export one in `C:/...` form, such as `export JAVA_HOME="C:/Program Files/Java/jdk-22"`.

`--production` is the gate for a distributable artifact. It fails closed unless:

- the application ID is the one recorded in the identity file;
- `apksigner` verifies the signature, with exactly one signer, v2 and v3 present and v1
  absent, a signer that is not the Android debug certificate, and a certificate SHA-256
  equal to the recorded one, which may not be empty;
- the merged manifest declares exactly the permissions and components ADR-054 recorded,
  with the launcher activity as the only exported component;
- the **packaged** Android trust config, found through the resource table because release
  file names are obfuscated, has a `domain-config`, carries at least two SPKI pins and
  disables cleartext everywhere, and the provisioned CA is packaged as its trust anchor.
  When `PRODUCTION_SERVER_ORIGIN`, `PRODUCTION_PRIMARY_SPKI_SHA256` and
  `PRODUCTION_BACKUP_SPKI_SHA256` are set, the config must also pin that host and carry
  both pins, so source the scratch file for a full check;
- the packaged native core does not export the deleted beta MLS symbol.

`--production-unsigned` verifies what CI builds: the application ID, that `apksigner`
finds the artifact unsigned, the manifest declarations and the native core. It does not
check trust, because CI's artifact carries the checked-in baseline configuration.

A check that cannot run is an error, never a pass.

### What the trust checks prove

The trust config governs the platform's Java HTTP stacks and WebView. The app's own REST
and WebSocket traffic runs on `dart:io`, which does not consult it, and trusts the CA
compiled in from `PRODUCTION_PRIVATE_CA_PEM_BASE64` and no other authority (ADR-043);
`test/features/networking/transport_security_test.dart` covers that against a real TLS
handshake. The trust checks therefore confirm that the declarative Android configuration is
correct and consistent with provisioning, and no more.

What the SPKI pins protect is an open conflict. ADR-043 says leaf SPKI pinning is
deliberately not implemented in Dart, and the code agrees: nothing in `lib/` uses either pin
once `app_configuration.dart` has checked its shape. ADR-067 D4, server ADR-0027 and
`backend/SECURITY.md` say that a client built against a stale primary pin fails its
handshake. ADR-076 D7 records the conflict and leaves it to a decision of its own, and this
manual relies on neither statement: the live pin check keeps the rendered configuration
true whichever of them is right.

## Failure modes, honestly

### If the key or its passphrase is lost

For an app distributed outside Play there is no recovery path
([Sign your app](https://developer.android.com/studio/publish/app-signing)).

| Question | Answer |
|---|---|
| Can existing installs be updated? | **No. Never.** |
| Can rotation fix it? | **No.** A v3 rotation lineage is made by the *old* key signing the new one. Without the old key there is no lineage. |
| Can new users still install? | Yes, with a new key and a **new application ID**, as a different application. |
| Do existing users keep their data? | Only by staying on the last build forever. Moving to the new application is an uninstall, and the data does not survive it. |
| Is there an upload-key reset? | No. That exists only under Play App Signing, which does not apply to a direct APK. |

Before the first install on any device, a lost key or passphrase can still be replaced,
because nothing depends on it yet. After it, the table above is final. That is why both
backups come before the first install, not after (ADR-076 D3 and D4).

### If the key leaks

Whoever holds it can sign an update that every install accepts. Rotation limits that from
then on and undoes none of it: devices below API 28 ignore v3 and verify v2, and below
`--rotation-min-sdk-version` the original key still signs, so for as long as `minSdk` stays
below 28 the first key keeps signing the v2 block and cannot be retired
([APK Signature Scheme v3](https://source.android.com/docs/security/features/apksigning/v3),
[apksigner](https://developer.android.com/tools/apksigner)). Assume a leak is permanent,
tell every holder of the app out of band, and treat a new application ID as the real
remedy, with the data loss that brings.

A backup survives a loss. Nothing survives a leak (ADR-076 D4).

### If a build stops

| What the script says | What it means, and what to do |
|---|---|
| No signing certificate is recorded | The identity file's fingerprint line is empty. Restore it from that file's history; never create a key to fill it. |
| Missing production provisioning, or a value in the wrong shape | Derive the values again, afresh, as above. |
| No production signing material | Set `CP_PRODUCTION_SIGNING_PROPERTIES`. If the file or the keystore is gone, restore it from a backup; never create a key. |
| `CP_PRODUCTION_UNSIGNED_BUILD` is set | Unset it. Only CI builds unsigned. |
| The build number is not greater | Choose a higher number. A number is never reused. |
| Could not read a certificate from the host | The host cannot be reached. Check the network path to it, then run the script again. Never build around the check. |
| PRIMARY PIN MISMATCH | The host serves another key than the one provisioned. Either the values were not derived afresh, or the deployment serves a different key from `out/server.crt`, which is what a later run of `make_ca.sh` leaves behind. Find out which key the host serves before building; never copy the live pin in without knowing why it moved. |
| The CA certificate does not match, or has expired | The CA file is not the one the digest describes, or it is no longer valid. Resolve which CA is deployed before building. |
| A check of `tool/verify_release_apk.sh` failed | Nothing was published. Read the failing check, and never publish around it. |

### If Android refuses an install

- **A downgrade.** The build number is not greater than the installed one. Build again
  with a higher number. Never use `adb install -d`.
- **A signature mismatch.** The device holds an install signed by another key, such as a
  debug-signed `productionDebug` or `productionProfile`. Stop and find out which. Never
  uninstall to make room: the uninstall destroys that install's data.

### If the app shows "App not provisioned"

The build compiled a missing or malformed value, and nothing on the device can fix it. Build
again, with a higher number, from values derived afresh.

## What maintainers must never do

- Never create a second production key. If a build cannot find the key, find it, or
  restore it from a backup.
- Never change `application.id` or `signing.certificate.sha256` in
  `android/production-release-identity.properties` once anything is installed, and never
  copy an artifact's fingerprint into that file to make a check pass: the file decides which
  key is trusted, not the artifact.
- Never commit a keystore, a `production-signing.properties`, a passphrase, an SPKI pin, a
  CA digest or a CA certificate.
- Never hardcode a password into a Gradle file.
- Never hand anyone an artifact that `tool/build_production_release.sh` did not make, or
  that `tool/verify_release_apk.sh --production` did not pass.
- Never distribute a debug-signed APK. The debug key differs per machine, so no release
  could ever update it.
- Never sign production with the beta key, and never give `buildTypes.release` a signing
  config.
- Never treat an uninstall and reinstall as a migration, and never install with `-d`.
- Never point `flutter install`, `flutter run --flavor production` or
  `flutter drive --flavor production` at a device that holds the signed app.
- Never run `backend/ops/tls/make_ca.sh` to get past a release problem: it mints a new
  server key.
- Never set `CP_PRODUCTION_UNSIGNED_BUILD` for a build meant for a phone.
- Never enable Gradle's configuration cache for a signed build without first checking that
  signing material is not serialised to disk.
- Never run a signed build with `--debug`, `--info`, `--verbose` or `-v` logging.

## The retained beta key

The `beta` flavor, its application ID `com.orviniq.chat.beta`, and its signing and release
pipeline were deleted with the closed-beta MLS core ([ADR-075](decisions.md)). Its key was
not. It lives in `~/.communication-platform/beta-signing/`, reissued on 2026-09-07 under
`CN=com.orviniq.chat.beta` (ADR-067 D5), and it is still the only key that can update the
beta installs on the owner's phone and emulator, which hold real data. No tree after
`8267429` builds that application, so this repository cannot update those installs, but it
must not strand them either. **Do not destroy the beta key, its archived predecessor, or
their backups.** Production never uses the beta key.

The beta pipeline is readable in git. `git show 8267429:frontend/docs/release-signing.md`
is its manual, `git show 8267429:frontend/android/beta-release-identity.properties` records
its certificate, and its scripts sit beside them at the same revision. Its upgrade
continuity was proven on an API 35 emulator on 2026-08-19: an in-place update from version
code 1 to 2 kept `firstInstallTime`, and the same artifact re-signed with another key was
refused. `implementation-checklist.md` still records the reissued key's off-site backups as
not existing. The old manual described those backups as stretched with SHA-512, but the
beta script's `--digest-algo SHA512` never reached the passphrase stretching, so GnuPG
used its SHA-256 default. That does not affect restoring them (ADR-076, as built by
prompt 3).

## Primary references

- [App signing](https://source.android.com/docs/security/features/apksigning): the scheme
  overview
- [APK Signature Scheme v3](https://source.android.com/docs/security/features/apksigning/v3):
  rotation, and its API-level limits
- [APK Signature Scheme v4](https://source.android.com/docs/security/features/apksigning/v4):
  incremental installs and the `.idsig` file
- [Sign your app](https://developer.android.com/studio/publish/app-signing): key validity,
  key loss and key leaks
- [How app updates work](https://developer.android.com/google/play/app-updates): update
  compatibility
- [apksigner](https://developer.android.com/tools/apksigner): verification and
  `--rotation-min-sdk-version`

ADR-076's Sources table records what each of these said when it was read on 2026-09-14,
and which files of the pinned Flutter 3.44.7 sources show the `flutter install`,
`flutter run` and `flutter drive` behaviour described above.
