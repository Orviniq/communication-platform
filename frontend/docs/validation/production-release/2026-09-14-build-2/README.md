# Production build 2 on the owner's two devices

Run on 2026-09-14 by prompt 7 of the seven production-signing prompts that
[ADR-076](../../../decisions.md) names. It put the first signed production build onto two
devices that had never held `com.orviniq.chat`, through `adb install` alone, as ADR-076
D9 requires. Nothing was uninstalled on either device, no account was signed in or
registered, and no password was typed. The owner signs in by hand afterwards.

## The artifact

| Property | Value |
|---|---|
| Date | 2026-09-14 |
| APK | `communication-platform-0.1.0-2.apk` |
| APK SHA-256 | `75b069d1773eda4f4f6e3e329fbb40c2e57439df0aaa1f30c94008785f262b50` |
| Version name | `0.1.0` |
| Version code | `2` |
| Application ID | `com.orviniq.chat` |
| Signing certificate SHA-256 | `a06f9e8a250dc68bf95bdf3f9ffcf4c5dc81e6bd82a785011cd1a1e964cc8395` |
| Source revision | `f85196de7d0d33adb1391c4ff6b1d0482750b780`, with a clean working tree |
| Server origin | `https://chat.orviniq.com` |

`tool/build_production_release.sh --build-number 2` made it from provisioning values
derived afresh from `backend/ops/tls/out/`. Before it built, the script found that the
live host served the provisioned primary pin. `tool/verify_release_apk.sh --production`
then passed all 15 of its checks, and only then did the script publish the APK with its
SHA-256 and metadata. `apksigner verify --print-certs` reported one signer,
`CN=com.orviniq.chat, OU=Production, O=Communication Platform`, whose certificate SHA-256
is the one recorded in `android/production-release-identity.properties`.

Build 1 was made the same day to prove the script and was never installed, so build 2 is
the first production build on any device.

## The devices

| | Device A | Device B |
|---|---|---|
| Model | Samsung Galaxy A56 (SM-A566B) | Android emulator, `sdk_gphone16k_x86_64` |
| Android version | 16 (API 36) | 15 (API 35) |
| ABI | arm64-v8a | x86_64 |
| Install | `adb install`, without `-r` or `-d`: `Success` | `adb install`, without `-r` or `-d`: `Success` |
| Installed version code | 2 | 2 |
| Screen reached | Login | Login |
| `com.orviniq.chat.beta` | Still installed at version code 33, with its first-install and last-update times unchanged | Still installed at version code 33, with its first-install and last-update times unchanged |

On both devices `cmd package resolve-activity` named
`com.orviniq.chat/com.example.communication_platform.MainActivity`, and `am start` opened
it. Device B made a cold start in under a second and showed the Login screen with empty
fields. The owner was using device A during the run: they opened the new app from the
home screen before the scripted start reached it, and switched to the beta app and back.
Its Login screen was captured with the production app in front. Neither device showed a
banner, as ADR-076 D8 decides for production.

Before the install, neither device listed `com.orviniq.chat`. On device A,
`pm list packages` could not read the phone's Secure Folder profile, so the check was
repeated for the primary user alone. After the install, `dumpsys package` showed the app
installed for the primary user and not in Secure Folder.

## What this shows, and what it does not

Reaching the Login screen shows that the build carries the right origin and CA. It shows
nothing about the SPKI pins: what they protect is the open conflict ADR-076 D7 records.

Installing the build opens nothing. ADR-017, every production completion gate in
`implementation-checklist.md`, ADR-053's sustained-delivery gate and ADR-054's follow-up
F2 stay closed (ADR-076 D10). The build went only to the owner's own devices, so the
written disclosure still travels with the first build handed to anyone else
(`deployment-and-release.md` steps 8 to 10).

The groups row "Not yet run" in `implementation-checklist.md` is unchanged: running groups
on these devices against the live server is the owner's own test.

## Checks at the source revision

Run at `f85196d` with the pinned Flutter 3.44.7, before the build:

- `flutter pub get --enforce-lockfile` resolved.
- `tool/generate.sh` wrote no output, and `git diff --exit-code -- lib` passed.
- `flutter analyze --fatal-infos --fatal-warnings` found no issues. `dart format` rewrote
  the two files `main` holds unformatted, and both were restored.
- `flutter test` passed 1229 tests and failed one,
  `test/architecture/background_delivery_policy_test.dart`, which fails only on a Windows
  checkout with CRLF line endings.
