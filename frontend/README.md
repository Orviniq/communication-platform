# Communication Platform frontend

Flutter client for Android. There is no browser target: the server serves no browser
surface, so a web build cannot connect. The product name and all brand assets remain
provisional. Registration, login, device enrollment and cross-signing, contacts, direct
messaging, Saved Messages, local search, linked devices, history transfer,
notifications, background delivery, the settings surfaces, the user-initiated
diagnostics export and the closed-beta group stack are implemented; voice rooms, file
attachments, shared media and profile publishing are not, and every surface that is
routed without an implementation behind it says so ([ADR-045](docs/decisions.md)).
`docs/implementation-checklist.md` is the live status.

The app bundles Vazirmatn `v33.003` and its SIL OFL 1.1 license under
`assets/fonts/vazirmatn/`. The exact artifact and checksum provenance is recorded in
`docs/visual-design-system.md`; no font or visual asset is fetched at runtime.

## Toolchain

- Flutter `3.44.7` (also recorded in `.fvmrc`)
- Dart `3.12.2`
- Android is the only target

Run dependency resolution from this directory:

```sh
flutter pub get --enforce-lockfile
```

The repository `pubspec.lock` is authoritative. Release and isolated build environments
must provide Flutter, Pub, Gradle, and Android artifacts from an approved local cache or
mirror; the application has no foreign runtime dependency.

## Environments and identifiers

| Environment | Dart entry point | Android application ID |
|---|---|---|
| Development | `lib/main_development.dart` | `com.orviniq.chat.development` |
| Private Experimental | `lib/main_beta.dart` | `com.orviniq.chat.beta` |
| Production | `lib/main_production.dart` | `com.orviniq.chat` |

The beta flavor ships the **Private Experimental** deployment defined by
[ADR-044](docs/decisions.md): one privately distributed artifact for roughly 20-30
trusted people, carrying declared maturity tiers rather than one uniform claim. It is
deliberately not called a beta in anything a user reads - nothing in it has been
independently reviewed - even though the frozen application ID, the Gradle flavor, and
the `AppEnvironment` value all keep the `beta` name they can no longer change.

What that build *says* about itself is decided by [ADR-045](docs/decisions.md): one
application-level word, two feature labels that only ever read down from it
(**Experimental**, **Not built yet**), and one mandatory disclosure shown once, as part
of the enrollment security notice a device must already pass. There is deliberately no
label meaning supported, stable, verified or audited - nothing here has been assessed by
anyone outside the project - and the notice is never re-shown on a timer. The written
disclosure delivered with the artifact stays release-blocking alongside it.

The three are separate, coexisting applications; none upgrades into another. The
closed-beta ID is **frozen** and lives in `android/beta-release-identity.properties`,
which the build reads and the release verification checks against. Changing it after
the first external install would force every beta user through an uninstall that
permanently destroys their local state — see
[Beta release signing and key continuity](docs/release-signing.md).

The Android `namespace` is still `com.example.communication_platform`. That is only
the build-time Kotlin/resource package and is not part of the installed identity.

Plain `flutter run` uses `lib/main.dart`, which delegates to development and always
shows a visible non-production label. Production builds must select the production
entry point explicitly.

Every entry point loads exactly one HTTPS origin from environment-specific compile-time
defines. There is no runtime server selector, remote configuration, certificate bypass,
public connectivity probe, telemetry, or third-party runtime resource loader. A build
without complete provisioning stops at the blocking Connection screen.

The controlled build environment supplies these public provisioning values (never
credentials or private keys):

- `<ENVIRONMENT>_SERVER_ORIGIN` (an HTTPS origin with no path/query/fragment);
- `<ENVIRONMENT>_PRIVATE_CA_SHA256` (64 hexadecimal characters);
- Android only: `<ENVIRONMENT>_PRIMARY_SPKI_SHA256` and
  `<ENVIRONMENT>_BACKUP_SPKI_SHA256` (distinct base64 SHA-256 digests);
- Android only: `<ENVIRONMENT>_PRIVATE_CA_PEM_BASE64`, the authority certificate itself,
  PEM then base64. `dart:io` verifies against a certificate rather than a digest and does
  not read Android's network security configuration, so without this the app's own REST
  and WebSocket traffic cannot reach the provisioned server (ADR-043). Absent or
  malformed material fails configuration closed rather than falling back to public roots.

`<ENVIRONMENT>` is `DEVELOPMENT`, `BETA`, or `PRODUCTION`; one artifact reads only its own prefix.
The beta artifact uses a distinct backend origin and a distinct Android application ID,
which is also what separates its local state: the encrypted database and the KeyStore
alias holding its key live in the per-application sandbox, so a different application ID
is a different store. Its closed-beta PQ MLS state is disposable and is never migrated into
production state. That beta suite is hybrid ML-KEM-768/X25519 on a Private Use
identifier; it is not the IETF draft suite the production profile selects, and
`docs/mls-profile.md` records exactly how the two differ.
Closed-beta MLS transport v3 authenticates later Welcome/re-add with
the complete bounded signed control transcript. V2 beta groups and queued group objects
lack that evidence and must be recreated/rejoined rather than silently migrated.
Android also requires the build-local resource generation described in
`android/provisioning/README.md`.

```sh
flutter run --flavor development --target lib/main_development.dart
flutter build apk --release --flavor beta --target lib/main_beta.dart
flutter build apk --release --flavor production --target lib/main_production.dart
```

The beta flavor signs with the frozen persistent release identity described in
[Beta release signing and key continuity](docs/release-signing.md) (ADR-042), and
`tool/build_beta_release.sh` is the only supported way to produce an artifact for
users. The production release build has no signing config at all, so it packages
unsigned: it keeps building and stays verifiable in CI, but the OS cannot install it,
which is fail-closed by construction. Production gains its own identity only through an
explicit, separate release decision.

## Generation and verification

Localization and builder output are deterministic under the pinned SDK, constraints,
and lockfile. Run the repository generator command after editing ARB or annotated files:

```powershell
./tool/generate.ps1
```

```sh
sh ./tool/generate.sh
```

The local CI commands run locked dependency resolution, generation with a clean-diff
check, strict Flutter analysis, widget/unit tests, a development Android build, and
production Android compilation:

```powershell
./tool/ci.ps1
```

```sh
sh ./tool/ci.sh
```
