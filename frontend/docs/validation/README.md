# Frontend validation evidence

Use [frontend status](../STATUS.md) for current release gates and the
[verification runbook](../runbooks/VERIFY.md) to choose a check. Each record below
applies to its recorded build, devices, and conditions. The revision column
distinguishes APK source revisions from commits that record evidence.

| Dated record | Device class | Revision | Result and evidence limits |
|---|---|---|---|
| [2026-08-23 · A56 probe](sustained-delivery/2026-08-23-samsung-a56/) | Retail Samsung Galaxy A56, Android 16 / API 36 | Probe record at `973e6eb8` | Recorded device conditions and observation capabilities. The app UID was absent, and the sustained-delivery trial did not run. |
| [2026-08-23 · API 30 probe](sustained-delivery/2026-08-23-emulator-api30/) | Android 11 / API 30 emulator | Probe record at `973e6eb8` | Recorded device conditions and observation capabilities with the app UID absent. Emulators are ineligible for sustained-delivery matrix cells. |
| [2026-08-23 · API 35 probe](sustained-delivery/2026-08-23-emulator-api35/) | Android 15 / API 35 emulator | Probe record at `973e6eb8` | Recorded device conditions and observation capabilities with the app UID absent. Emulators are ineligible for sustained-delivery matrix cells. |
| [2026-08-26 · Direct-message latency](delivery-latency/2026-08-26-adr-060/README.md) | Samsung Galaxy A56 and API 36 emulator | Builds 12 and 15. Observation recorded in `ee7af86f` | A probe became visible on the peer after 2.33 s on build 15. UI polling could not resolve the send-stage targets, and traffic counters were device-wide. |
| [2026-09-14 · Signed production build 2](production-release/2026-09-14-build-2/README.md) | Samsung Galaxy A56 and API 35 emulator | APK source `f85196de` | Fresh install and launch to Login on both devices. The run ended before sign-in and did not exercise runtime SPKI enforcement or group messaging. |
| [2026-10-04 · Stopped voice run](voice-mesh/2026-10-04/README.md) | Samsung Galaxy A56 and API 35 emulator | Build 3 source `ab2ecb82` | Both devices updated in place and kept sign-in. The deployment returned `voice_configured: false`, so all call steps were unrun. |
| [2026-10-05 · Two-device voice pass](voice-mesh/2026-10-05/README.md) | Samsung Galaxy A56 and API 35 emulator on the phone's cellular uplink | Builds 3, 4, and 5 from `ab2ecb82`, `9b63a3cb`, and `53ff3861` | Build 5 passed all seven call steps over the UDP relay, including two-way audio, mute, background service, leave, and rejoin. More than two devices, the ten-device ceiling, mid-call removal, credential refresh with ICE restart, and TCP relay were outside the run. Room text had one observation on build 3. |

The [probe series](sustained-delivery/README.md) and
[field criteria](../runbooks/SUSTAINED-DELIVERY.md) explain what the sustained-delivery
ledger requires. It has no qualifying runs. The [latency series](delivery-latency/README.md)
describes how its observations were gathered.

## Archived evidence

| Dated record | Device class | Revision | Result and evidence limits |
|---|---|---|---|
| [2026-08-24 · Closed-beta PQ MLS core](../archive/beta-mls-core/2026-08-24-sm-a566b-arm64-v8a/) | Samsung Galaxy A56, arm64-v8a, Android 16 / API 36 | Run record at `f4507b1a` | 128 passed, 0 failed, 3 ignored. The [archive](../archive/README.md) covers the retired beta core and its per-ABI gate. The other ABIs had no device run. |
