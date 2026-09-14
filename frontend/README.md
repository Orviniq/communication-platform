# Communication Platform frontend

Flutter client for Android. There is no browser target: the server serves no browser
surface, so a web build cannot connect. The product name and all brand assets remain
provisional. Registration, login, device enrollment and cross-signing, contacts, direct
messaging, Saved Messages, local search, linked devices, history transfer,
notifications, background delivery, the settings surfaces and the user-initiated
diagnostics export are implemented; voice rooms, file attachments, shared media and
profile publishing are not, and every surface that is routed without an implementation
behind it says so ([ADR-045](docs/decisions.md)).
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
| Production | `lib/main_production.dart` | `com.orviniq.chat` |

The two are separate, coexisting applications; neither upgrades into the other. The
`beta` flavor that shipped the Private Experimental deployment
([ADR-044](docs/decisions.md)) under the frozen application ID `com.orviniq.chat.beta`
was deleted with the closed-beta MLS core, along with its signing and release tooling.
No flavor builds that application ID now, so an existing install of it cannot be updated
from this tree; [Production release signing and key continuity](docs/release-signing.md)
records what its retained signing key still controls.

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

`<ENVIRONMENT>` is `DEVELOPMENT` or `PRODUCTION`; one artifact reads only its own prefix.
Each flavor has a distinct Android application ID, which is also what separates its
local state: the encrypted database and the KeyStore alias holding its key live in the
per-application sandbox, so a different application ID is a different store. Android
also requires the build-local resource generation described in
`android/provisioning/README.md`.

```sh
flutter run --flavor development --target lib/main_development.dart
CP_PRODUCTION_UNSIGNED_BUILD=1 flutter build apk --release --flavor production --target lib/main_production.dart
```

The production release build is signed with the one persistent production key
([ADR-076](docs/decisions.md)), attached to the `production` flavor alone; the `release`
build type itself carries no signing config, and never the debug one. Gradle reads the
application ID from the committed `android/production-release-identity.properties`, and
the key from outside the repository: from the untracked properties file that
`CP_PRODUCTION_SIGNING_PROPERTIES` names, or from all four of
`CP_PRODUCTION_KEYSTORE_FILE`, `CP_PRODUCTION_KEYSTORE_PASSWORD`,
`CP_PRODUCTION_KEY_ALIAS` and `CP_PRODUCTION_KEY_PASSWORD`. Without the key the build
fails closed, unless `CP_PRODUCTION_UNSIGNED_BUILD=1` asks for an unsigned package, as in
the command above and in CI; the OS refuses to install that package. Asking for both
fails as well. `tool/verify_release_apk.sh --production` is the gate for a distributable
artifact and checks its signer against the recorded certificate, and
`--production-unsigned` verifies the unsigned CI artifact.

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
check, strict Flutter analysis, widget/unit tests, a development Android build, and an
unsigned production Android build verified with
`tool/verify_release_apk.sh --production-unsigned`:

```powershell
./tool/ci.ps1
```

```sh
sh ./tool/ci.sh
```
