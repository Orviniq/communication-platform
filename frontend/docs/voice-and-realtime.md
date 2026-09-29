# Voice and realtime

## Status

**Nothing about voice is implemented.** `/voice-rooms` renders
`StructuralPlaceholderPage`, `pubspec.yaml` declares `flutter_webrtc` but no Dart file
imports it ([ADR-078](decisions.md)), no file under `lib/` sends a `signal` frame, and
`RealtimeGateway.send` has no caller at all. This document is the design phase 6 builds,
not a description of the artifact.

The one part that does exist is the realtime gateway: `dio_websocket_gateway.dart`
validates and routes `envelope` and `signal` frames, and nothing else. The four room
frames and the `presence` frame were retired by server
[ADR-0021](../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
and [ADR-0022](../../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md),
and [ADR-069](decisions.md) deleted the client half.

**The seven prerequisites this document used to be gated on are gone.**
[ADR-058](decisions.md)'s P1 to P7 named an MLS exporter as the media-key source, a
per-ABI group permit, a self-hosted LiveKit deployment, an SFrame contract and a wire
record proving an SFU could not decrypt. None of those things exists to be met: groups are
pairwise sessions and the MLS core and the permit were deleted
([ADR-075](decisions.md)), the SFU left with server ADR-0021, and DTLS-SRTP keys each
connection between its two endpoints so there is no application-level media key for an
exporter to supply. [ADR-077](decisions.md) supersedes that list and replaces it with the
design below. Voice is **buildable**, and what remains between here and a call is work
rather than a gate.

## The architecture

Voice is a full mesh of WebRTC audio between devices. Every path crosses the self-hosted
coturn relay. Each connection is keyed by DTLS-SRTP between its two endpoints, so the
backend, the relay and every other participant hold none of its keys.
[`backend/CLIENT_CONTRACT.md`](../../backend/CLIENT_CONTRACT.md) §N is the binding
statement of it and its eleven rules are cited by number throughout.

- **Audio only.** One audio track for each connection: no video track and no data channel
  in this version (§N rule 1).
- **No application media key, and none is designed** (ADR-0021 point 3). A connection's
  keys die with the connection, so a removed member's exclusion is the closing of a socket
  rather than the rotation of a key.
- **Relay-only ICE**, with the credential `POST /api/v1/me/relay` mints as the only ICE
  server. No STUN server and no foreign server is configured anywhere (§N rule 2, ADR-0021
  point 2).
- **The server holds no room and no participant list.** It mints a relay credential and it
  relays `signal` frames. That is the whole of its part.
- **A room is client state, exactly as a group is** — signed control events over ordinary
  durable envelopes. **A call is `signal` frames between devices.**

Two wire formats carry that, and both are specified in
[`voice-signalling-v1.md`](voice-signalling-v1.md), which is binding for the phase:
`CPVRV001` for the room's control events, durable; `CPVSV001` for the call's signalling,
volatile. The transport under both is [`pairwise-transport-v1.md`](pairwise-transport-v1.md)
unchanged — no suite, no header flag, no key schedule of its own.

## What the server does, and what it does not

| | Where |
|---|---|
| Mints a coturn credential | `POST /api/v1/me/relay` |
| Relays an opaque blob to one device, if that device is connected at that instant | `/ws` `signal` |
| Publishes `voice_configured` and `signal_buckets` | `GET /api/v1/config` |
| Stores a room, a name, a roster, a capability, a join token or a live count | **nowhere** |
| Counts participants, enforces a ceiling or reports presence | **nowhere** |

`backend/openapi.json` holds 28 paths and `/api/v1/me/relay` is the only one of them that
voice touches. There is no `backend/voicerooms/API.md`; the file is gone.

## The room

A room is a named set of member accounts that exists only in its members' clients. It is
standalone — not a group, not a direct conversation, and no group or direct conversation
hosts a call in this version.

- Its id is 32 CSPRNG bytes. Its name travels inside its control events, so the server
  never holds it and there is nothing there to rename or delete.
- Its roster is built by signed control events on one hash chain, mirroring
  `GroupControlEvent` field for field under its own signing domain. Every active member
  has the same authority: any member may add a member, remove a member, or rename the
  room. There is no owner and no admin.
- A member's *devices* are never in the roster. They are read from that member's
  authenticated live device list when a payload is sealed, exactly as a group's are (§F).
- Conflicting events at one revision are a fork, and a forked room is quarantined and
  joins no call until it is resolved. A `pruned_through` gap makes a room wait for a
  member's answer before it joins, invites or renames, because a device that may be
  missing a removal would otherwise offer audio to somebody the room has ejected.
- At most 50 members in a room; at most 10 joined devices in a call. They are different
  numbers because membership costs an envelope fan-out on a change and a call costs every
  participant an uplink for every peer.

Leaving is a signed `remove member` event naming yourself. It is not a backend deletion,
because there is nothing on the backend to delete: the other members keep the room, and
a member who leaves needs a fresh invite to come back.

## A call

1. `voice_configured` is true, so a call action is offered. The room is held, unquarantined
   and not waiting for its state.
2. The microphone is requested — at join and at no other time (§N rule 11) — and the
   microphone-type foreground service starts.
3. `POST /api/v1/me/relay` mints a credential. It is held in memory, never written down,
   and refreshed once less than an hour of `expires_in` remains (§N rule 9).
4. The joining device mints a 16-byte `join_id` and fans a `join` announcement out to every
   live device of every active member (§N rule 4).
5. A participant that receives the announcement creates an `RTCPeerConnection` with
   `iceTransportPolicy: 'relay'`, sends an `offer`, and the joiner answers. Of two devices
   that offer at once, the one whose device id string sorts lower is the polite peer of the
   perfect-negotiation pattern (§N rule 3) — both ends compute that from the two ids and
   there is nothing to ask the server.
6. Candidates go in one batch for each peer for each negotiation, and the DTLS handshake
   keys the connection. **A remote description is accepted only from that channel** (§N
   rule 6): the fingerprint inside the SDP is authenticated by the pairwise session and
   never by the server, which is what makes the media end to end even though the server
   chose neither endpoint.
7. Leaving fans out a `leave` and closes every connection. The foreground service stops,
   the ephemeral text is dropped, and nothing about the call was ever written to the
   database.

**Trouble is per person.** Every tile is its own encrypted connection, so one peer can be
unreachable, or blocked by a changed safety number, while everybody else keeps talking.
Nothing pauses when one connection fails and nothing pauses when somebody leaves — there
is no shared key to rotate.

## Realtime gateway

One application-owned gateway wraps `/ws`. It validates frame type and bounds before
routing typed events; widgets never send raw JSON. The upgrade authenticates with
`Authorization: Bearer <session token>`, which is the only handshake path: a refusal
arrives as a failed upgrade with `403 Forbidden` and never as a close code, and a handler
waiting for a close code there will never fire (§O).

Two frames go up — `ack` and `signal` — and two come down — `envelope` and `signal`. There
is no subscription frame, no `presence` frame and no room frame in either direction
(ADR-0022). Durable `envelope` frames enter the inbox pipeline and are deduplicated
against REST. A `signal` frame is volatile and expires locally.

The client obeys the published limits: JSON text objects only, `WS_MAX_FRAME`, 100 frames
per rolling second, at most 200 ack ids, and a `signal` blob that is base64 of exactly
1024, 4096 or 16384 bytes. A blob off those buckets is dropped in silence — there is no
`400 bad_bucket` on this path and no error frame to read. Pacing and a bounded inbound
queue keep a locally generated burst from reaching close `4008`; the numbers are in
[`voice-signalling-v1.md`](voice-signalling-v1.md), "The socket limits".

The socket is a wake-up hint and never the delivery contract. **A call can be
audio-connected while the socket is down**: audio continues, and the ephemeral text,
the joins and the leaves stop. That split is a visible state, not a silent freeze.

## Ephemeral room text

Room text is a `CPVSV001` frame fanned out to each device in the call, one at a time. It
is authenticated ciphertext, held in memory only, never appended to a timeline or the
durable queue, and dropped when the user leaves, when the room's membership becomes
invalid and when the call empties. There is no subscriber fan-out and no echo of the
sender's own message to account for: the panel renders what this client sent because it
sent it.

The wording stays best-effort, because another participant can retain what they
decrypted, and because a frame published for a device that is mid-reconnect is gone.

## Participants and speaking state

- **The participant set is this device's own.** A device is in the call when a connection
  to it is open, and for no other reason. `participants_query` and its answer are a hint
  for a device that joined late (§N rule 5) and never an authority.
- **Speaking and mute come from local media state**, never from the server, and each needs
  a non-colour signal as well.
- **A name and an avatar come from locally authenticated profile state**, not from
  anything a peer sent in a call.
- There is no `live_count`. A room in the list shows *Live now · N* only from a call this
  device is in or has just been told about by a member; a room nobody has told it about
  reads as *Empty*, which is honest — the device does not know.

## Platform lifecycle

- Android requests the microphone on explicit join and at no other time, and runs a
  microphone-type foreground service for as long as the call lasts (§N rule 11): a call
  outlives the moment the user looks at another screen.
- `POST_NOTIFICATIONS` is off by default on a fresh install, so a denied notification
  permission is the common path rather than the edge. It is a stated outcome — the
  foreground-service disclosure is degraded and the screen says so — and never a retry
  loop.
- A network change enters a reconnecting state, stops misleading speaking indicators, and
  never connects to a foreign fallback.
- Minimising keeps audio only when the platform can truthfully maintain it, and shows the
  persistent in-app banner.

## The existing surfaces

Every voice surface in the tree today was built for the removed design. What happens to
each:

| Surface | Where | Decision |
|---|---|---|
| `/voice-rooms` route | `app_router.dart` | **Keep.** The placeholder stands until prompt 9 builds the list |
| `/voice-rooms/new` route | `app_router.dart` | **Keep.** Same |
| `/voice-rooms/sample-room` route | `app_router.dart` | **Replace** with `/voice-rooms/:roomId`, whose id is the room's 32-byte id in hex. A fixed path cannot name a room |
| Shell compose action | `app_shell.dart` | **Keep.** It routes to `/voice-rooms/new` and still should |
| `activeVoiceRoomName`, which nothing sets | `app_shell.dart`, `app_router.dart` | **Keep.** It is the minimised banner's input and the call controller is what will set it |
| The banner's tap target | `app_shell.dart:649` | **Replace** with the id of the call in progress, alongside the route above |
| Contacts "New voice room" | `contacts_new_page.dart` | **Keep** |
| `AppIcons.voiceRooms` | `app_icons.dart` | **Keep**, and add the 22 icons the design canvas draws that `AppIcons` has no mapping for — mic, mic-off, speaker, phone-off, user-plus and the rest |
| Drift table `voice_rooms` | `local_database.dart:995` | **Delete.** It has no reader and no writer, and its three columns describe a server room: a capability to hold, a name the server stored, a live count the server counted. `room_states`, `room_control_events`, `room_outbound_objects` and `room_state_requests` replace it |
| `StructuralPlaceholderKind.voiceRooms`, `.newRoom`, `.room` | `structural_placeholder_page.dart` | **Keep** until prompt 9 replaces each with a real screen |
| `voiceRoomsPlaceholderTitle` / `Body` | `l10n` | **Keep** until then |
| `voice_configured`, `signal_buckets` | `server_config_model.dart` | **Keep.** Both are already parsed and both are load-bearing here |

## The testing path

The owner decided to test voice on two real devices with the signed `production` flavor.
The signing setup is done ([ADR-076](decisions.md),
[`release-signing.md`](release-signing.md)).

- **The flavor is `production`**: application id `com.orviniq.chat`, entry point
  `lib/main_production.dart`.
- **A production APK for a phone comes only from**
  `tool/build_production_release.sh --build-number N` (ADR-076 D7). `N` must be greater
  than every build `release-signing.md` records, and a number is never reused. The last
  installed build was 2, on 2026-09-15, so the first voice build is **3 or higher**.
- **The devices** are the Samsung A56 (`R5CY716AG0L`) and the emulator (`emulator-5554`).
- **The upgrade is in place.** Each device holds `com.orviniq.chat.beta` and, beside it,
  production build 2 of `com.orviniq.chat`. A new production build replaces build 2 with
  `adb install -r`. **Neither app is ever uninstalled**, and the beta app is not touched:
  the signing certificate and the application id both match, which is the only reason an
  update is possible at all (ADR-067 D2).
- **The owner signs in and enrolls each device by hand** in the production app. No script
  enrolls a device.
- **Prompt 10 runs the call**: build and install on both devices, enroll both, create a
  room on one, invite the other, join from both, and check that audio carries in both
  directions across the relay. Then the states that need two devices — one device leaving,
  one device removed mid-call, the socket dropped while audio continues, and a peer that
  never answers.

## Primary references

- [`backend/CLIENT_CONTRACT.md`](../../backend/CLIENT_CONTRACT.md) §F, §K, §N and §O
- [Realtime API and the relay credential](../../backend/realtime/API.md)
- [Server ADR-0021: a relayed WebRTC mesh, and no server room](../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
- [Server ADR-0022: the gateway holds no presence](../../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md)
- [`voice-signalling-v1.md`](voice-signalling-v1.md) — the two wire formats
- [`pairwise-transport-v1.md`](pairwise-transport-v1.md) — the transport under both
- [`design-handoff/voice-room-states.md`](design-handoff/voice-room-states.md) — every
  screen and state
- [ADR-077](decisions.md) — the decision record for this design
