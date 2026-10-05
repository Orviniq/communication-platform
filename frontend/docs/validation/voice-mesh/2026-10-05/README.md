# Voice calls on two devices, with two defects found and corrected

Run on 2026-10-05 by phase 6 prompt 10, the day after the
[stopped run of 2026-10-04](../2026-10-04/README.md), once the deployment began serving voice.
The seven call steps ran between the owner's two devices on signed production builds 3, 4
and 5. Build 3 found two defects. Build 4 corrected the first and build 5 the second, and
on build 5 every step passed. The owner confirmed each audio step by ear, and the devices'
own audio levels agree with each answer. [ADR-079](../../../decisions.md) records the
result and the two corrections.

Nothing was uninstalled on either device, no account was registered, and no password was
typed. Both devices end the run on build 5, out of any call.

## The artifacts

Each was made by `tool/build_production_release.sh` from a clean tree, with provisioning
values derived afresh into a scratch file outside the repository and deleted after the build.
Each passed all 15 checks of `tool/verify_release_apk.sh --production`, the live host served
the provisioned primary pin each time, and each is 125,865,952 bytes.

| Build | Source revision | APK SHA-256 | Installed |
|---|---|---|---|
| 3 | `ab2ecb826dd00cf3256d2055d4a354527d4d9441` | `1c46bffb537783510a33feadce37c3da27badbce5324cae4c496457e7aa58b29` | 2026-10-04, over build 2 |
| 4 | `9b63a3cb3b4adb2ae6795c08c75bfbbb85be40f6` | `121cb79861de7b498dca83de6de8783c22922e6a9967a4a77dc231d1f1709516` | 2026-10-05, over build 3 |
| 5 | `53ff38618e7e72103709e2f2787c5bb4017bd36d` | `20a010b41eb43c5eb5a34d1c007d58fa84548408e707e20685043b68010a37dd` | 2026-10-05, over build 4 |

Every install was `adb install -r`, and each was in place on both devices: `dumpsys package`
showed `firstInstallTime` unchanged while `versionCode` and `lastUpdateTime` moved. The
application ID is `com.orviniq.chat`, and the signing certificate SHA-256 is
`a06f9e8a250dc68bf95bdf3f9ffcf4c5dc81e6bd82a785011cd1a1e964cc8395` throughout. Builds 4 and 5
are not diagnostic builds: each carries a correction and nothing else.

## The devices

| | Device A | Device B |
|---|---|---|
| Model | Samsung Galaxy A56 (SM-A566B) | Android emulator, `sdk_gphone16k_x86_64` |
| Android version | 16 (API 36) | 15 (API 35) |
| ABI | arm64-v8a | x86_64 |
| Account | Account A | Account B |
| Network | Its own 4G cellular connection | Wi-Fi through the host computer |
| Microphone and speaker | The phone's own | The host computer's |
| `com.orviniq.chat.beta` | Not installed; never deployed there, the owner states | Still at version code 33, unchanged |

Accounts A and B are different accounts, each a verified contact of the other on its own
device, which is what the room's invite step and the design's authenticated device lists
require ([`voice-signalling-v1.md`](../../../voice-signalling-v1.md), Part 1). Both devices
were already signed in on build 2.

The host computer was connected to device A's Wi-Fi hotspot, so device B's traffic also left
over device A's cellular connection, which is the likeliest reason two of the path losses
below hit both devices at once. Device A ran a VPN at the start of the run, and the owner
switched it off at about 13:38:50.

Times are UTC. Device A's clock ran 14.4 s behind the host's and device B's up to 1.1 s
behind, and device logs were moved onto the host's clock by those measured offsets.

**The audio levels** quoted below are the peak sample value, out of 32,767, that libwebrtc
logs for each ten-second window of the device's recording (`REC`) and playback (`PLAY`).
A quiet window usually reads under 100 and speech reads thousands, so one device's `REC`
rising together with the other's `PLAY` is the audio crossing the call.

## The call steps on build 5

Room 3 was created for this run, and the owner touched neither screen between steps.

| Step | Result | Evidence |
|---|---|---|
| 1. One device creates a room and adds the other device's member | **Pass** | Device A signed room 3 at 16:18:57, inviting account B. Polling device B's screen once a second found the room 6.3 s later |
| 2. The other device joins, and both show the call as connected | **Pass** | Device A started the call at 16:19:35 and device B joined at 16:20:24. Both reported the connection `connected` 14 s later, each over a relay candidate pair on UDP. Both screens read "2 in the call", with the peer's tile *Connected* |
| 3. Audio flows both ways, as the owner confirms | **Pass** | The owner heard both directions. 16:20:50 to 16:21:40: device A `REC` 7,290 to 11,250 while device B `PLAY` read 6,618 to 22,039, and device B `REC` 1,836 to 10,144 while device A `PLAY` read 5,947 to 20,898 |
| 4. Mute on one device, and the owner confirms silence on the other | **Pass** | Device A muted at 16:22:09. Its tile read *Muted* and the control *Unmute*. The owner heard nothing from device A and still heard device B. Device A's capture stopped and device B `PLAY` read 0 to 2 for the whole muted span, while device B `REC` 3,655 to 3,882 reached device A at `PLAY` 9,785 |
| 5. One device goes to the home screen; the call continues and its notification shows | **Pass** | Device A went to its home screen at 16:24:26 and stayed there for 2 min 40 s. Its call service remained a foreground service of type microphone (`0x80`), its recording was not silenced, and the notification shade showed *Call in progress*. The owner heard both directions. Device A `REC` up to 15,960 reached device B at `PLAY` up to 21,105, and device B `REC` up to 11,644 reached device A at `PLAY` up to 11,340 |
| 6. One device leaves; the other drops it, and the call service stops on the device that left | **Pass** | Device A left at 16:29:01.8, and its connection closed 25 ms later. Device B logged the close from the far side about 0.4 s after that and read "1 in the call", *You are the only one here*. Five seconds after the leave, device A held no service record for the app, no call notification and no recording |
| 7. The device rejoins, and audio flows again | **Pass** | Device A rejoined at 16:31:23. Both connected about 9 s later, and device A's service was back in the foreground. The owner heard both directions. Device A `REC` up to 15,822 reached device B at `PLAY` up to 25,065, and device B `REC` 1,295 reached device A at `PLAY` 4,490 |

Then the sequence that failed on build 4 was repeated on purpose. At 16:35:56 device A left
and rejoined 0.68 s later, so that the rejoin's service started 664 ms after the old
connection closed, within the leave's own delay. Device A connected at 16:36:04 and went to
its home screen at 16:36:07. Twenty-five seconds later its service was still a foreground
service of type microphone, its recording was not silenced, and Android had logged no
silencing and no socket teardown for the app. Audio crossed both ways: device A `REC` 21,468
to device B `PLAY` 15,721, and device B `REC` 7,502 to device A `PLAY` 10,945.

Both devices then left the call. Neither kept a service, a recording or a notification.

## What builds 3 and 4 found

### A signed room change waited for an unrelated wake-up

Found on build 3, corrected in build 4 by `52a117c`.

Device A signed room 1 at 13:26:37. Device B did not hold it 70 s later. It arrived only after
device A's app was sent to the home screen and brought back, at 13:32:47, more than six
minutes after it was signed.

A signed group or room change waits in its own outbound table until the post-inbox dispatch
routes it into the pairwise outbox, and that dispatch runs only inside a delivery cycle. The
supervisor starts a cycle when the outbox depth grows, and the depth counted neither table,
so nothing asked for a cycle. Resuming the app started one. The depth now counts a pending
control payload until it is routed, and a test pins both the count and the watch's re-read.
Room 2 reached device B 9.1 s after it was signed on build 4, and room 3 6.3 s after on
build 5.

### A quick rejoin lost its call service

Seen on build 4, corrected in build 5 by `5b5cadb`.

At 15:37:45 device A left a call and rejoined within a second. The leave closed the
connection, and the service guard's stop removed the call notification within 0.2 s. The
rejoin's service started 657 ms after the close. The leave's own stop then removed the
notification again, 1.68 s after that start, because a leave ended the call at once but told
the peers before stopping the service. Nothing restarted the service.

The call ran on without it, and the fault stayed hidden while the app was on screen. At 15:53:16
device A went to its home screen. Within six seconds Android logged that it was silencing the
app's recording, because the microphone app-op was missing, and destroyed the app's TCP
sockets. The connection reported `disconnected` 5 s later and `failed` 10 s after that. A leave now
stops the service only when no join has started since, and a controller test pins the race.
On build 5 the same sequence kept the service, as above.

### The rest of the run on builds 3 and 4

- **Steps 2 to 4 on build 3.** The first join connected over the relay at 13:36:43, and the
  owner heard both directions and confirmed the mute. The first two connections ran over
  device A's VPN interface. Each lost its path within a minute, at 13:37:18 and 13:39:12:
  the first stopped getting answers to its connectivity checks, and the second could no
  longer send them. Every connection after the VPN went off ran over the cellular interface.
- **One-way audio on build 3, not an application defect.** From about 13:51 to 14:05:50,
  device B's microphone delivered digital zeros. Its level read exactly 0, where it idled
  at 6 to 8, and Android was not silencing it. It recovered when device B's capture
  restarted.
- **Path losses that hit both devices at once.** At 14:06:13 both devices lost the relay
  path in the same second, and at about 14:07:25 both lost it again. Their traffic shared
  device A's cellular connection. Device B's connection also failed at 14:42:09, while the
  owner had taken device A, whose hotspot carried the host's traffic, outdoors.
- **Steps 5 and 6 on build 3** passed by the device checks: the service stayed in the
  foreground and unsilenced with device A on its home screen, and a leave from device B
  stopped device B's service and was dropped by device A within about 4 s.
- **Step 7 on build 3** was not established. The owner was away from the devices, and
  device B's capture was being restarted. It is covered by build 5.
- **Steps 2 to 4 on build 4.** Room 2 connected 13 s after device B joined, at 15:33:28.
  The owner heard both directions, and confirmed the mute at 15:45:46.

**On the question of ICE.** Every join connected through the relay, and none failed to.
Every loss of a path after it had connected had a cause outside the call: the VPN, the shared
cellular connection, the phone moving out of range of the host, and on build 4 Android
removing the network from an app with no foreground service. A short loss recovers by
itself, which the run saw several times within 2 to 7 s. A `failed` connection is dropped,
as the design says (*The call*), and only a fresh join reconnects it. Nothing restarts ICE
on a network change.

## What this shows, and what it does not

It shows a call of two devices on the production build, through the deployment's relay,
in both directions. It also shows mute, a backgrounded call kept alive by its foreground
service, a leave that stops that service, and a rejoin.

It shows nothing about more than two devices, the ten-device ceiling, a removal mid-call,
the five-hour ICE restart on a credential refresh, or a relay over TCP: every connection
selected UDP. It does not show room text as a step: on build 3 one line typed on device B
appeared in device A's room chat, and nothing more was tried.

The disclosure still says voice rooms "do nothing" (`implementation-checklist.md`, the
disclosure row), and ADR-077's room-text budget question is still open. Both devices are the
owner's, so no build with voice has reached anybody else. Every production gate stays
closed.

## Checks on the tree that closes the phase

Run with the pinned Flutter 3.44.7 on build 5's source, `53ff386`, with these documents in
place:

- `flutter pub get --enforce-lockfile` resolved.
- `tool/generate.sh` wrote no output, and `git diff --exit-code -- lib` passed.
- `flutter analyze --fatal-infos --fatal-warnings` found no issues. `dart format` rewrote
  only the two files `main` holds unformatted, and both were restored.
- `flutter test` passed 1,704 tests and failed one,
  `test/architecture/background_delivery_policy_test.dart`, which fails only on a Windows
  checkout with CRLF line endings.
