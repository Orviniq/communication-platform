# Voice call on two devices, stopped before the call

Run on 2026-10-04 by phase 6 prompt 10, which was to prove one voice call between the
owner's two devices with the signed `production` build and then close the phase. It built
production build 3, installed it over build 2 on both devices, and stopped before the first
call step: the deployment serves no voice. Its `GET /api/v1/config` answers
`voice_configured: false`, the prompt stops there because the server's configuration is not
client work, and the owner chose to leave the phase open.

No call step ran. Nothing on the server was touched, nothing was uninstalled on either
device, no account was signed in or registered, and no password was typed.

## The artifact

| Property | Value |
|---|---|
| Date | 2026-10-04 |
| APK | `communication-platform-0.1.0-3.apk`, 125,865,952 bytes |
| APK SHA-256 | `1c46bffb537783510a33feadce37c3da27badbce5324cae4c496457e7aa58b29` |
| Version name | `0.1.0` |
| Version code | `3` |
| Application ID | `com.orviniq.chat` |
| Signing certificate SHA-256 | `a06f9e8a250dc68bf95bdf3f9ffcf4c5dc81e6bd82a785011cd1a1e964cc8395` |
| Source revision | `ab2ecb826dd00cf3256d2055d4a354527d4d9441`, with a clean working tree |

`tool/build_production_release.sh --build-number 3` made it in 3 minutes 28 seconds, from
provisioning values derived afresh from `backend/ops/tls/out/` into a scratch file outside
the repository, which was deleted afterwards. Before it built, the script found that the
live host served the provisioned primary pin. `tool/verify_release_apk.sh --production`
then passed all 15 of its checks, and only then did the script publish the APK with its
SHA-256 and metadata. Among the 15: the recorded signer, v2 and v3 without v1, exactly the
12 recorded permissions and 6 recorded components, a trust config that pins the host with
both provisioned pins, and a native core that does not export the deleted beta MLS symbol.

## The devices

| | Device A | Device B |
|---|---|---|
| Model | Samsung Galaxy A56 (SM-A566B) | Android emulator, `sdk_gphone16k_x86_64` |
| Android version | 16 (API 36) | 15 (API 35) |
| ABI | arm64-v8a | x86_64 |
| Before the run | Production build 2 | Production build 2 |
| Install | `adb install -r`: `Success` | `adb install -r`: `Success` |
| Installed version code | 3 | 3 |
| `firstInstallTime` | Unchanged | Unchanged |
| Account | Account A | Account B |
| `com.orviniq.chat.beta` | Not installed, below | Still installed at version code 33, with its first-install and last-update times unchanged |

Both updates were applied in place: `dumpsys package` showed `firstInstallTime` unchanged,
while `versionCode` and `lastUpdateTime` moved. The owner had signed both devices in on
build 2 after 2026-09-14, with two different accounts, here called A and B. Each opened
build 3 still signed in, on its Chats list, with the conversation between the two accounts
in it, so each update kept its install's data.

On device A the package manager has no record of `com.orviniq.chat.beta`, for the primary
user, among uninstalled packages kept with their data (`pm list packages -u`), or in
`dumpsys package`. The run record of 2026-09-14 lists it on device A at version code 33.
The owner states that it was never deployed there, and that the production app is the only
installation intended for device A. Nothing in this run uninstalled anything.

## The call steps

| Step | Result |
|---|---|
| 1. One device creates a room and adds the other device's member | Not run |
| 2. The other device joins, and both show the call as connected | Not run |
| 3. Audio flows both ways, as the owner confirms | Not run |
| 4. Mute on one device, and the owner confirms silence on the other | Not run |
| 5. One device goes to the home screen; the call continues and its notification shows | Not run |
| 6. One device leaves; the other drops it, and the call service stops on the device that left | Not run |
| 7. The device rejoins, and audio flows again | Not run |

The Voice Rooms tab on both devices showed *This server does not offer voice*, the *no
voice on this server* state of `ui-specification.md` §13.0, which offers no compose button
and no *Create a room*. So step 1 could not start.

The screen reads `voice_configured` from `GET /api/v1/config`, which the app fetches at the
start of each full-scope session and redraws on when the answer arrives; until it does, the
answer stored by an earlier session, or a fallback of `false`, is in force. Device B's
Diagnostics report, read after the screen, settles which one the screen showed. The delivery
session was running and no request had failed (`backend_rejected=0`, `transport_failed=0`,
`malformed_response=0`, `most_failed_operation=none`). The client also refuses a
configuration whose `voice_configured` is not a boolean, which would have counted as a
malformed response. So the screen showed the deployment's own answer. The backend computes
it as `bool(settings.TURN_URLS)` (`backend/core/routes.py`), so the deployment's
`TURN_URLS` is empty.

## What this shows, and what it does not

It shows that build 3 updates build 2 in place on both devices and keeps their sign-in, and
that a deployment without a relay offers no call control anywhere, as §13.0 says.

It shows nothing about a call. No room was created, no microphone was asked for, no relay
credential was minted, no call service started and no `signal` frame was sent. Every voice
row of `implementation-checklist.md` still describes code that has never run on a device.

The next run needs the deployment to serve voice first: `TURN_URLS` naming the relay, and
coturn running with the `TURN_STATIC_AUTH_SECRET` the backend shares
(`backend/ops/RUNBOOK.md`). The app reads the configuration at the start of each session,
so both apps need a fresh start after the server's restart. Build 3 already carries the
voice code of `ab2ecb8`; any further build is numbered 4 or higher.

About and the Diagnostics report name the version `0.1.0+1` on build 3, as they did on
builds 1 and 2. `BuildIdentity.version` is a compile-time copy of the `version:` line of
`pubspec.yaml`, while `--build-number` sets only the Android version code. Neither screen
tells the production builds apart; `dumpsys package` does.

## Checks at the source revision

Run at `ab2ecb8` with the pinned Flutter 3.44.7, after the build:

- `flutter pub get --enforce-lockfile` resolved.
- `tool/generate.sh` wrote no output, and `git diff --exit-code -- lib` passed.
- `flutter analyze --fatal-infos --fatal-warnings` found no issues. `dart format` rewrote
  the two files `main` holds unformatted, and both were restored.
- `flutter test` passed 1701 tests and failed one,
  `test/architecture/background_delivery_policy_test.dart`, which fails only on a Windows
  checkout with CRLF line endings.
