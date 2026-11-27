# ADR-077: Relayed WebRTC voice mesh and client-held rooms

- **Status:** Accepted (2026-09-20, on owner's A answers to D1, D2, D3, and D5); open conflict decided B (2026-09-30); one open question on room-text signalling budget (2026-10-01)
- **Date:** 2026-09-20 (explicitly recorded in register and full section in `25a8bf05` / `6fec14e`; open conflict recorded 2026-09-30 in `a0b57afb` and decided B in `2cff8039`; room and call built 2026-09-30 – 2026-10-01 in `ccca4ecd` / `16efd926`)
- **Supersedes:** [ADR-058](058-voice-prerequisites.md) (voice prerequisites P1–P7, which named the removed MLS exporter, per-ABI MLS permit, and LiveKit SFU)
- **Related:** [ADR-019](019-durable-fan-out.md), [ADR-023](023-voice-room-leave.md), [ADR-025](025-hybrid-pqxdh.md), [ADR-075](075-pairwise-groups.md), [ADR-076](076-production-signing.md), [ADR-078](078-media-package.md), [ADR-079](079-voice-device-run.md), [ADR-098](098-presence-and-typing.md), server [ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md), server [ADR-0022](../../../../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md)

## Decision (Position)

Client-side record of server [ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md) and server [ADR-0022](../../../../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md), establishing a relayed WebRTC audio mesh with client-held room state and pairwise-encrypted volatile call signalling:

1. **D1 — Client-held rooms with equal active-member authority (Owner answer A, 2026-09-20):**
   - A room ID is 32 CSPRNG bytes; its name (up to 100 Unicode scalar values via `RoomNames`) travels inside signed control events ([room_model.dart](../../../lib/features/voice/domain/room_model.dart)).
   - `RoomControlEvent` mirrors `GroupControlEvent` field for field (version, event ID, room ID, revision, previous state hash, signer, `created_ms`, operation) with the same hash chain and six apply outcomes under distinct signing/hash domains (`"chat:v1:room-control"` and `"chat:v1:room-control-state"`).
   - Five operations: create, add members, remove member, rename, plus reserved operation value `5` so a future role operation cannot collide.
   - Every active member has equal authority to add, remove, and rename (no owner/admin hierarchy in v1), matching [ui-specification.md](../../ui-specification.md#132-voice-room-info-screen) and the unauthenticated `/ws` `signal` relay in `backend/realtime/gateway.py` (where `core/tests/test_seizure_guard.py` forbids server-side membership tables). Any member can eject any other; the remedy for abuse or fork is quarantine and a new room.
2. **D2 — Ten-device call ceiling (Owner answer A, 2026-09-20):**
   - Per [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) §N rule 10, the ceiling counts **joined devices** (10 max), not accounts, because uplink and coturn relay costs scale per device connection.
   - Enforced deterministically on both sender and receiver by sorting device IDs as lowercase strings (matching §N rule 3's polite-peer rule): participants keep the 10 lowest and offer nothing to the rest, so an 11th device exhausts retries and sees *Call full*.
3. **D3 — Standalone rooms only (Owner answer A, 2026-09-20):**
   - Neither groups nor direct chats host calls in this version (`ui-specification.md` §13.1), avoiding dual signed chains governing one roster. Creating a room as a snapshot from a group roster is left for a later decision.
4. **D4 — Channel-split wire formats with cross-channel refusal ([VOICE-V1.md](../../contracts/VOICE-V1.md)):**
   - `CPVRV001` carries room control events over **durable** envelopes (`EnvelopeV1`); `CPVSV001` carries the eight call-signalling kinds (`join`, `leave`, `participants_query`, `offer`, `answer`, `candidates`, `room_text`, plus versioned header) over **volatile** `/ws` `signal` frames.
   - Each payload is refused if received on the other channel, preventing durable replay of stale offers and volatile writes to durable rosters.
5. **D5 — Volatile frames share the durable pairwise Double Ratchet (Owner answer A, 2026-09-20):**
   - Per [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) §N rule 6 and frozen [PAIRWISE-V1.md](../../contracts/PAIRWISE-V1.md), `CPVSV001` seals under the existing pairwise Double Ratchet (`PairwiseVolatileSealer` in [pairwise_volatile_sealer.dart](../../../lib/features/pairwise/application/pairwise_volatile_sealer.dart)) rather than a second session or signalling-only key schedule.
   - Committed session state advances before sending, with no outbox row written; retries re-seal on a new message number.
   - Dropped volatile frames leave retained skipped keys on the peer's next received message (against bounds of 2,000 skipped keys per device pair and 20,000 per account). Budgeted at **32 sealed volatile frames per peer per call** (`VoiceSignalTransport.volatileBudgetPerPeer` in [voice_signal_transport.dart](../../../lib/features/voice/application/voice_signal_transport.dart)) — 62 wholly dropped calls before reaching 2,000 — and nothing further is sealed to a peer marked unreachable until a fresh `join`.
6. **D6 — Local schema replacement (schema 23 in `32c85dc7`):**
   - Deleted the server-oriented `voice_rooms` table and replaced it with four group-shaped tables in [local_database.dart](../../../lib/features/local_storage/infrastructure/database/local_database.dart): `room_states`, `room_control_events`, `room_outbound_objects`, and `room_state_requests`. Calls themselves persist zero database rows.
7. **D7 — SDP sizing and no-session resolution (amended by Owner Decision B, 2026-09-30):**
   - Audio-only, relay-only, max-bundle SDP offers measured 1,363 bytes over 46 lines (Chromium 152.0.7977.76 on 2026-09-20), framing to ~1,516 bytes — clearing bucket 4096's regular-header budget (4,014 bytes) by 2,498 bytes and worst-case initial-header budget (1,554 bytes) by only 38 bytes.
   - **Open conflict (2026-09-30, `a0b57afb`) & Owner Decision B (2026-09-30, `2cff8039`):** Because the Rust core (`ratchet_encrypt` in [pairwise.rs](../../../native/crypto_core/src/pairwise.rs)) emits an initial header on a session's first message only, a dropped initial `signal` frame would create a one-sided primary session and break durable text delivery too. Therefore, **a volatile frame never starts a session** (`PairwiseVolatileSealer` returns `noSession`). Instead, the room's durable `CPVRV001` kind 2 state request (77 bytes) starts missing sessions (`RoomSessionStarter` in [room_session_starter.dart](../../../lib/features/voice/application/room_session_starter.dart)) on room accept/add (initiated by the device whose lowercase device ID sorts lower), every 24 hours per room, and before a join. Receiving a valid initial header over `signal` remains accepted under full authentication checks, and every outbound call frame travels under a 58-byte regular header.
8. **D8 — Bounded retry schedule and per-peer unreachable state:**
   - Retried kinds (`join`, `offer`, `answer`, `participants_query`) send at 0, 2 s, 4 s, and 8 s (±25% jitter) with a 6 s answer window (~20 s total) before marking that peer *not reachable* without pausing the rest of the call; retried again only on a fresh `join` from that peer. `candidates`, `room_text`, and `leave` are not retried.
9. **D9 — Pacing, single-batch ICE, and bounded inbound worker queue:**
   - Outbound `SignalFramePacer` uses a 32-token bucket refilling at 24 frames/s (covering a 10-device join's 27 outbound frames without delay while staying below the 100-frame rolling second / 256-frame server queue).
   - Relay-only BUNDLE ICE sends candidates in one batch per negotiation; the WebSocket reader enqueues frames onto a bounded 256-entry in-memory queue (`SignalRouter` / `VoiceSignalTransport.inboundQueueCapacity`) so decryption never stalls the socket read loop (`4008` slow-consumer protection).
10. **D10 — Relay credential lifecycle and relay-unreachable distinction:**
    - `POST /api/v1/me/relay` credentials are fetched at join, kept in memory only, refreshed under 1 hour (`RelayCredentialService`), and trigger an ICE restart on refresh mid-call. `voice_configured` from `GET /api/v1/config` hides call actions when false (`503 voice_unconfigured`). If no peer reaches `connected` within 15 s and all candidate pairs fail, report the relay unreachable.
11. **D11 — Roster-driven removal enforcement:**
    - On applying a signed removal, active connections and pending retries for that account's devices close; inbound `CPVSV001` frames require the sender account to be active in the committed room roster.
12. **D12 — Surface and icon mapping:**
    - Kept `/voice-rooms`, `/voice-rooms/new`, shell compose action, `activeVoiceRoomName`, Contacts entry, `AppIcons.voiceRooms`, `voice_configured`, and `signal_buckets`; replaced `/voice-rooms/sample-room` and the banner tap target with `/voice-rooms/:roomId` ([app_router.dart](../../../lib/app/routing/app_router.dart)); deleted `voice_rooms`; added 22 design-canvas voice icons.
13. **D13 — Two-device validation plan:**
    - Validated on signed `production` builds (`--build-number >= 3`) via `adb install -r` on the owner's Samsung Galaxy A56 and API 35 emulator without uninstalling or touching beta installs (executed in [ADR-079](079-voice-device-run.md)).

## Rationale

- Server [ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md) delegates all room membership and call signalling to client-encrypted channels while leaving wire design to the client ([CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) §N).
- Separating durable membership (`CPVRV001`) from volatile call signalling (`CPVSV001`) matches persistence guarantees to semantics, reuses the reviewed group state-chain design, and lets durable room traffic establish pairwise sessions without altering the frozen [PAIRWISE-V1.md](../../contracts/PAIRWISE-V1.md) profile.

## Constraints and Open Gates

- **Scope:** Superseded [ADR-058](058-voice-prerequisites.md) P1–P7; schema moved to 23 (`32c85dc7`) when implemented; initial ADR-077 commit (`25a8bf05` / `6fec14e`) was documentation-only, followed by implementation across phase 6 prompts 2–9.
- **Built refinements (2026-09-30 – 2026-10-01, `ccca4ecd` & `16efd926`):**
  - Room transcript acceptance requires the sender to be active in the target state, confirms state only on exact head match, and room mailbox-gap requests do not hold the checkpoint gap open.
  - `VoiceCallEngine` ([voice_call_engine.dart](../../../lib/features/voice/application/voice_call_engine.dart)) probes active participants via `participants_query` + 2 s (±25%) answer window before sending `join`, applies the 10-device sort ceiling against known participants, and closes connections upon committed room removal.
  - The D10 relay-unreachable state was left unbuilt across phase 6.
- **Open question (2026-10-01, prompt 7 — room text vs. 32-frame signalling budget):** `VoiceSignalTransport` charges `room_text` frames against D5's 32-frame-per-peer-per-call cap (`VoiceRoomTextBudget` in [voice_room_text_budget.dart](../../../lib/features/voice/domain/voice_room_text_budget.dart) caps per-line size against published buckets). Sending ~30 lines of room text to a peer exhausts that peer's call budget, blocking `leave` and 5-hour ICE restarts. Four options (A: keep + composer warning; B: exclude `room_text`; C: separate line allowance; D: reserve signalling headroom out of 32, recommended D/C+D) remain open in [STATUS.md](../../STATUS.md#presence-voice-and-delivery).
- **V2 roles gap:** Equal-member v1 authority remains open against [CLIENT_VOICE_ROLES.md](../../../../docs/client/CLIENT_VOICE_ROLES.md) v2 owner/admin/member rules in [STATUS.md](../../STATUS.md#presence-voice-and-delivery).

## Costs

- Any active member can remove any other active member; recovery from a malicious ejection is a new room.
- Sharing the durable Double Ratchet means dropped volatile frames accumulate dead skipped keys (capped at 32 frames/peer/call; 62 fully dropped calls to reach the 2,000-key repair threshold).
- Pre-establishing sessions via 77-byte `CPVRV001` state requests consumes one classical + one ML-KEM one-time prekey per missing session (e.g., 1,176 sessions for a 50-member room created at once, up to 49 initiated with the highest-sorting device ID).

## Reversal Trigger

Reopen D1 for v2 room roles ([CLIENT_VOICE_ROLES.md](../../../../docs/client/CLIENT_VOICE_ROLES.md)), D5 if the 32-frame budget triggers frequent text-session repairs (switch to rejected option B: a dedicated signalling session), or the 2026-10-01 open question to reserve `leave`/ICE-restart headroom from `room_text`.

## History, Amendments, and Supersession

- **2026-09-20 (`25a8bf05`, `89c32119`, `6fec14e`):** Proposed and accepted ADR-077 on the owner's A answers to D1, D2, D3, and D5, superseding [ADR-058](058-voice-prerequisites.md) P1–P7.
- **2026-09-30 (`a0b57afb`, `2cff8039`, `ccca4ecd`):** Recorded the no-session volatile conflict; owner chose option B (durable `CPVRV001` state requests establish missing sessions; volatile frames never create sessions), and room state/schema 23 shipped (`32c85dc7`–`672328df`).
- **2026-10-01 (`16efd926`):** Shipped `VoiceCallEngine` (`6666ce83`–`e37b765e`) and recorded the open question on `room_text` spending the 32-frame signalling budget.
- **2026-10-19 (ADR-098):** Shared `/ws` `signal` ingress through `SignalRouter` alongside `CPPSV001` presence frames, keeping `CPVSV001` routing unchanged.
