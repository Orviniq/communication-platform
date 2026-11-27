# ADR-079: Two-device voice mesh validation and dispatch/service fixes

- **Status:** Accepted (2026-10-05)
- **Date:** 2026-10-05 (explicitly recorded in register, full section, and [2026-10-05 voice validation record](../../validation/voice-mesh/2026-10-05/README.md); fixes in `52a117c3` and `5b5cadbc`; documented in `fd7f4db2`)
- **Related:** [ADR-047](047-networking-composition.md), [ADR-060](060-delivery-latency.md), [ADR-076](076-production-signing.md), [ADR-077](077-voice-mesh.md), [ADR-078](078-media-package.md)

## Decision (Position)

Closed phase 6 (voice mesh) on live two-device evidence using signed `production` builds (`com.orviniq.chat`, installed via `adb install -r` over build 2 without uninstalling) and recorded the two runtime defects uncovered and fixed during the run:

1. **D1 — Seven-step call validation passed on signed production build 5 ([2026-10-05 README](../../validation/voice-mesh/2026-10-05/README.md)):**
   - Verified on build 5 (source `53ff38618e7e72103709e2f2787c5bb4017bd36d`, APK SHA-256 `20a010b41eb43c5eb5a34d1c007d58fa84548408e707e20685043b68010a37dd`, 125,865,952 bytes) between the owner's Samsung Galaxy A56 (Android 16, `arm64-v8a`) and an Android 15 emulator (`x86_64`, `sdk_gphone16k_x86_64`):
     1. Room signed on A56 reached the emulator in 6.3 s.
     2. Both joined and reached `connected` over UDP relay candidate pairs in 14 s ("2 in the call").
     3. Bidirectional audio confirmed by owner ear and libwebrtc `REC`/`PLAY` peak levels.
     4. Local mute silenced outbound audio while continuing remote playback.
     5. Backgrounding A56 to home screen for 2 min 40 s kept the `microphone` foreground service and *Call in progress* shade notification active with continuous two-way audio.
     6. Leaving from A56 closed its connection (seen by peer in ~0.5 s, dropped in ~1.5 s) and stopped its foreground service/recording within 5 s.
     7. Rejoining reconnected in ~9 s with bidirectional audio; repeating the rapid leave → rejoin (0.68 s) → home screen race kept the call service and audio alive.
2. **D2 — Outbox depth counts pending signed group and room control payloads (`52a117c3`):**
   - Build 3 revealed a >6-minute stall after signing a room: signed changes sat in `group_outbound_objects` and `room_outbound_objects` awaiting post-inbox dispatch inside a delivery cycle, which `SyncLifecycleSupervisor` only starts when watched `outbox_depth` grows ([ADR-047](047-networking-composition.md), [ADR-060](060-delivery-latency.md)).
   - Fixed so `outbox_depth` counts pending entries in `group_outbound_objects` and `room_outbound_objects` until routed into the pairwise outbox, and its stream re-reads when either table changes (documented in [SYNC.md](../SYNC.md#cycle-order); fixed in build 4, reducing room propagation from >6 min to 9.1 s on build 4 and 6.3 s on build 5). Cannot loop because supervisor reacts strictly to depth growth.
3. **D3 — Call leave stops the foreground service only if no newer join started (`5b5cadbc`):**
   - Build 4 revealed a race on rapid rejoin (657 ms after leave began): `VoiceCallController.leave` ([voice_call_controller.dart](../../../lib/features/voice/application/voice_call_controller.dart)) ended the call immediately (stopping the service via guard), then waited ~2 s notifying peers before calling service stop a second time — stripping the `microphone` service from the newly started rejoin and causing Android to silence recording ~6 s after backgrounding and tear down sockets.
   - Fixed so `VoiceCallController.leave` stops the call service only when no join has started since `leave` began (documented in [VOICE-V1.md](../../contracts/VOICE-V1.md) and [ANDROID.md](../ANDROID.md); pinned by controller test).

## Rationale

- Unit and widget tests over fake sockets/media could not catch dispatch-trigger omissions in real `ProviderContainer` lifecycles or Android OS microphone app-op revocation after a delayed background stop.
- Counting unrouted control objects in `outbox_depth` and scoping `leave`'s final stop to the active join epoch fixed both defects without changing wire formats or cryptography.

## Constraints and Open Gates

- **Scope:** Changed no cryptographic construction, protocol, wire format, state format, keystore, signing config, or `backend/` file; opened no production gate.
- **Predecessor stopped run ([2026-10-04 README](../../validation/voice-mesh/2026-10-04/README.md)):** Build 3 first stopped on 2026-10-04 because the deployment returned `voice_configured: false` until the owner configured coturn (`TURN_URLS` / `TURN_STATIC_AUTH_SECRET`).
- **Remaining unmeasured / open scenarios:**
  - More than 2 devices, the 10-device ceiling, mid-call member removal, room rename/leave, 5-hour credential/ICE restart, and TCP relay transport were not exercised on devices (all connections selected UDP).
  - Network handoffs drop the connection (per *The call*, requiring a fresh join) rather than triggering automatic ICE restart; moving between networks remains a design question beside D10's unbuilt relay-unreachable state ([ADR-077](077-voice-mesh.md)).
  - At ADR-079, `DeploymentDisclosure` `unbuiltSurfaces` still said voice rooms "do nothing" (later updated in ADR-094 rev 10), and [ADR-077](077-voice-mesh.md)'s 2026-10-01 `room_text` budget question remained open.
  - About and Diagnostics still display `0.1.0+1` (`pubspec.yaml` version) across builds `--build-number` 3–5; `dumpsys package` distinguishes installed `versionCode`s ([SIGNING.md](../../runbooks/SIGNING.md)).

## Costs

- Routing a signed control object inside a delivery cycle can register as a depth change and trigger one extra no-op cycle (matching the existing delivered-receipt behavior), and rapid-rejoin state must track join epochs in `VoiceCallController`.

## Reversal Trigger

Reopen if multi-device (>2) or 10-device ceiling tests, TCP relay runs, network-change ICE restarts, or v2 voice roles ([CLIENT_VOICE_ROLES.md](../../../../docs/client/CLIENT_VOICE_ROLES.md)) uncover new dispatch or call-lifecycle races.

## History, Amendments, and Supersession

- **2026-10-04 (`dfd7a376`):** Recorded stopped build 3 device run (`voice_configured: false`).
- **2026-10-05 (`52a117c3`, `5b5cadbc`, `fd7f4db2`):** Fixed `outbox_depth` group/room control tracking and `VoiceCallController.leave` rejoin service guard; validated all seven call steps on build 5 (`Accepted`).
- **2026-10-18 (ADR-094):** Updated `DeploymentDisclosure.distributed` (`unbuiltSurfaces`) to reflect built voice rooms.
