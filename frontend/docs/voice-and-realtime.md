# Voice and realtime

## Status

**Nothing in this document below the realtime gateway is implemented.** It is the design
this project intends to build, not a description of the artifact. `/voice-rooms` renders
`StructuralPlaceholderPage`, `pubspec.yaml` declares no media dependency, the shared Rust
core exports no media-key operation, and no run record exists under
`docs/validation/voice-media/`. ADR-044 places voice in the **absent** tier, where absent
means visibly missing rather than half-present.

The one part that does exist is the realtime gateway: `dio_websocket_gateway.dart`
validates and routes `envelope` and `signal` frames today, and nothing else. The four room
frames and the `presence` frame were retired by server ADR-0021 and ADR-0022, and
[ADR-069](decisions.md) deleted the client half; neither room frames nor room behaviour
exists now. Everything a room needs rides `signal`, which the voice phase specifies.

**What piece 20 is waiting for is [ADR-058](decisions.md), not a schedule.** It replaces
ADR-044's re-scope — itself a replacement for an unreachable public-release condition —
with seven conditions that are answered by inspecting a named artifact rather than by
judgement, and that fail closed when unanswered:

| | Condition | State on 2026-08-25 |
|---|---|---|
| P1 | A dated ADR grants exactly one MLS exporter as the media-key source: the production exporter, or the closed-beta experimental one for experimental voice only | **Not granted.** ADR-044 declined; ADR-058 declines |
| P2 | That exporter is reachable as key material, under a label domain-separated from the group's, with the symbol in the native export allowlist | **False.** The core returns only SHA-256 over `export_secret` as an epoch-agreement digest; no exporter secret crosses the FFI boundary |
| P3 | Voice resolves through the same permit as groups, so it is never offered on an ABI whose packaged core has no admissible record (ADR-056) | Mechanism exists and fails closed; voice has no consumer of it yet |
| P4 | The frame-encryption contract is settled by a recorded decision, reconciling the disagreement in *Media encryption gate* below | **Unresolved** |
| P5 | An admissible Android wire record under `docs/validation/voice-media/` shows the SFU cannot decrypt | **None.** The directory does not exist |
| P6 | Self-hosted LiveKit and TURN are reachable, and the client package is reviewed into the pinned dependency map under ADR-054 | **Not deployed, not declared** |
| P7 | Voice is claimed no more strongly than the weakest layer beneath it, and the foreground-service interaction with ADR-051's service is decided in advance | Not applicable until P1 |

Absence of evidence is refusal, never permission. A partially satisfied list authorizes
nothing.

## Realtime gateway

One application-owned gateway wraps `/ws`. It validates frame type and bounds before
routing typed events. Widgets never send raw JSON. Android authenticates the upgrade
with its bearer header. A future Web client sends the required auth frame first and sends
nothing else until authentication succeeds.

Durable `envelope` frames enter the inbox pipeline and are deduplicated against REST.
`signal`, presence, room signal, and room presence are volatile and expire locally.

The client obeys backend limits: JSON text objects only, maximum frame size, 100 frames
per rolling second, bounded ack/presence lists, signal size, and room subscriptions.
Batching and backpressure prevent locally generated bursts from causing close 4008.

## Voice-room model

A backend room is a capability ID plus an encrypted name and live count. Membership,
invites, and media-key state are authenticated client protocol state. All invited peers
are equal in the product UI; there is no server owner/member table.

Create flow:

1. Generate room metadata key and encrypted name bucket.
2. POST `/api/v1/rooms`.
3. Establish the room's client-side MLS membership state.
4. Send encrypted `room.invite` events containing the capability and Welcome/material.
5. Persist room capability only in protected storage.

Rename and invite actions require valid current room membership even though the backend
capability endpoint cannot enforce it. A malicious capability holder can still call the
backend rename API; clients authenticate accepted metadata updates and surface conflicts
rather than trusting server ciphertext alone.

Room MLS credentials obey the same verified account-master/device-cross-signature as group
chat, the same [PQ MLS production gates](mls-profile.md#production-gates), and — since
ADR-056 — the same per-ABI experimental permit. Voice is never available on a device where
groups are withheld, and it may not introduce a second availability rule
([ADR-058](decisions.md) P3). An unsigned, unverified, forked, or classical-only peer
cannot receive room membership/media keys.

Leaving is a client-protocol action, not a backend deletion. The client sends an
authenticated `room.control` leave/removal event, commits the MLS membership change,
disconnects from LiveKit/realtime presence, and deletes its local capability, room keys,
and ephemeral text after the durable transition succeeds. The backend room row persists
and the capability itself cannot be revoked by the current API. Peers ignore future
metadata from a removed credential, and a returning user requires a fresh authenticated
invite. The confirmation dialog states these limits; it never claims that leaving deletes
the server room or erases copies held by others.

## Joining voice

1. Fetch/decrypt room state and subscribe to room realtime presence.
2. POST `/api/v1/rooms/{room_id}/token` with a device-bound full token.
3. Derive the current media-key context from authenticated room MLS state using a
   domain-separated exporter label containing room ID and media epoch. That label MUST
   differ from the group stack's `chat:v1:beta-group-export`, and the derivation MUST
   happen inside the shared Rust core: no MLS secret enters Dart. No such operation
   exists today — see [ADR-058](decisions.md) P2.
4. Connect to the returned self-hosted LiveKit URL before token expiry.
5. Enable E2EE before publishing the microphone.
6. Publish audio only; do not enable video or unencrypted data channels.
7. Re-mint a token on reconnect and rotate media keys on membership change.

LiveKit is responsible for WebRTC/SRTP transport and SFU forwarding, not key
distribution. Media keys are never placed in the LiveKit token or sent to the backend,
SFU, or TURN server.

## Media encryption gate

**This section records an unresolved disagreement. It is not a settled contract, and
[ADR-058](decisions.md) P4 requires it be settled by a recorded decision — standing on the
P5 wire record — before piece 20 begins.** Four statements, verified 2026-08-25:

| Source | What it says |
|---|---|
| This document, as written before ADR-058 | RFC 9605 SFrame is *the* target framing contract |
| [`cryptographic-protocol.md`](cryptographic-protocol.md) media-framing row | RFC 9605 SFrame **or** the LiveKit E2EE implementation after wire-level validation |
| [`backend/SECURITY.md`](../../backend/SECURITY.md), which this project may not edit | "audio itself is SFrame-encrypted end-to-end" |
| [LiveKit's own documentation](https://docs.livekit.io/transport/encryption/) | Names no SFrame and no RFC 9605 anywhere on its encryption pages. `EncryptionType` is `kNone`, `kGcm`, `kCustom`; the built-in frame cipher is AES-GCM |

LiveKit's silence does not disprove the backend statement — its frame format is not
documented in enough detail on those pages to conclude either way, and `kCustom` leaves
room for a conformant implementation. So the question is open, and it is recorded as open
rather than answered in either direction here.

What is established from LiveKit's official documentation, and is not in dispute:

- Key distribution is entirely the application's problem. "LiveKit does not (and cannot)
  store or transport encryption keys for you." Keys are never in the join token and never
  reach the SFU or TURN server.
- The built-in shared-key provider is **not sufficient** for this project. Per-participant
  keys and in-room rotation — which removed-member exclusion requires — need a custom key
  provider, which LiveKit documents as the route for "implementing the MEGOLM or MLS
  protocol".
- The Flutter SDK can accept raw exporter bytes per participant:
  `BaseKeyProvider.setRawKey(Uint8List key, {String? participantId, int? keyIndex})`, with
  `ratchetKey`, `keyRingSize` and `failureTolerance` alongside it. `livekit_client` was at
  2.11.0 on 2026-08-25.

Before any Android release carrying voice, a wire-level spike MUST prove on real hardware
that the selected SDK version, cipher and key-provider behaviour keep the SFU unable to
decrypt, and that record must be admissible under ADR-058 P5. Before a future Web release,
the corresponding browser worker behaviour must also pass. If the spike cannot prove it,
publishing stays fail-closed: ordinary SRTP to the SFU is not accepted as end-to-end
encryption, no media cipher is invented here, and no foreign service is substituted.

## Media-key lifecycle

- Each media epoch has fresh exporter context.
- A participant removal causes an MLS commit and media-key rotation before further audio.
- Per-sender key IDs/counters are unique and replay-checked.
- Old media keys are retained only for a short jitter/reordering window then erased.
- Reconnect never silently falls back to unencrypted media.
- Key failure mutes publishing and shows a blocking encryption error.

## Ephemeral room text

**For the voice phase.** `room_signal` is not a frame (server ADR-0021); room text is one
more thing members tell each other over `signal`, under the bucket rule that frame obeys.
Room text uses authenticated ciphertext and is held in memory only. It is
never appended to history or the durable message queue. Clients drop it when they leave,
when room membership becomes invalid, and when the observed room empties. Wording remains
best-effort because another participant can retain decrypted content.

## Presence and participant state

Room subscription produces device join/leave hints. The LiveKit participant connection
is authoritative for current media tiles; backend `live_count` is a coarse hint and may
lag. Display name/avatar comes from locally authenticated profile state. Speaking and mic
indicators come from local/LiveKit media state and reveal no readable audio to the server.

## Platform lifecycle

- Android uses microphone permission only on explicit join and a microphone/connected
  foreground-service notification while active.
- A future Web client requires secure context and a user gesture for microphone
  permission/audio start.
- Network change enters reconnecting state, stops misleading speaking indicators, and
  never connects to a foreign fallback.
- Minimizing the room keeps audio only when the platform can truthfully maintain it and
  shows the persistent in-app banner.

## Primary references

- [Realtime API](../../backend/realtime/API.md)
- [Voice rooms API](../../backend/voicerooms/API.md)
- [RFC 9605: SFrame](https://www.rfc-editor.org/info/rfc9605)
- [LiveKit encryption overview](https://docs.livekit.io/transport/encryption/)
- [LiveKit Flutter SDK E2EE reference](https://docs.livekit.io/reference/client-sdk-flutter/)
- [LiveKit E2EE implementation guide, including the custom key provider](https://docs.livekit.io/transport/encryption/start/)
- [`BaseKeyProvider` API, including `setRawKey`](https://pub.dev/documentation/livekit_client/latest/livekit_client/BaseKeyProvider-class.html)
- [RFC 9420 §8.5, the MLS exporter](https://www.rfc-editor.org/rfc/rfc9420.html)
- [ADR-058, the prerequisite this document is gated on](decisions.md)
