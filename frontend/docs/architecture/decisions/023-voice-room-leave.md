# ADR-023: Voice-room leave is client membership/key removal, not backend room deletion

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-011](011-pairwise-wrapping.md)

## Decision (Position)

Leaving a voice room is **client-side membership removal** (and, in the original framing, key removal) rather than a backend room deletion operation, and the UI MUST give users an honest statement of that consequence.

Under the implemented v1 voice design ([Voice and realtime](../../voice-and-realtime.md), [ADR-077]), a voice room is pure client state (`CPVRV001` signed control events on a hash chain, fanned out over pairwise Double Ratchet envelopes) and the server holds no room, roster, or media key at all. Leaving sends a signed `remove member` event naming the leaving user; the remaining members keep the room, and rejoining requires a fresh invite. Inside an active call, removing a participant closes their DTLS-SRTP WebRTC peer connections ([server ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)), because no application-level media key exists to rotate.

## Rationale

Matches the capability-only / zero-room-state backend (`docs/client/CLIENT_CONTRACT.md` §N, [server ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)) and ensures users understand that leaving removes their own access rather than destroying the room for other members.

## Constraints and Open Gates

- Defined in [Voice and realtime](../../voice-and-realtime.md#the-room), [Voice signalling v1](../../voice-signalling-v1.md), and [room_model.dart](../../../lib/features/voice/domain/room_model.dart).
- Open gate: [Frontend status](../../STATUS.md#presence-voice-and-delivery) notes that v2 role authority (`owner`/`admin`/`member` in `docs/client/CLIENT_VOICE_ROLES.md`), upgrade negotiation, and multi-device / mid-call removal evidence remain open before voice can ship.

## Costs

- Because no server owns the room, a departed user cannot unilaterally delete the room on other participants' devices, and content/audio already delivered before removal cannot be retroactively revoked.

## Reversal Trigger

Only if a future server change introduces server-managed rooms or a shared media-encryption layer, reversing [server ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md).

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-09-20 (ADR-077):** Implemented v1 voice rooms on client-signed `CPVRV001` control events and DTLS-SRTP WebRTC mesh ([server ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)), refining "key removal" into closing endpoint DTLS-SRTP connections since no application media key exists.
- No supersession.
