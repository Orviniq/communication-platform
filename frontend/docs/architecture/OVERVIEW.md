# Architecture

See the [Android platform contract](ANDROID.md) for platform boundaries, the
[local data model](LOCAL-DATA.md) for durable state and migrations, and the
[synchronization engine](SYNC.md) for delivery and recovery. The
[frontend ADR index](decisions/README.md) records the governing decisions.

## Decision

Use **Modular Feature-First Clean Architecture with an Offline-First, Event-Driven
Core**.

The architecture separates product features from transport, storage, cryptography, and
platform code while forcing all durable state changes through one transactional data
path.

## Dependency rule

Dependencies point inward:

1. Presentation depends on application use cases and immutable view state.
2. Application use cases depend on domain types and ports.
3. Infrastructure implements ports for REST, WebSocket, database, crypto, files, audio,
   secure storage, background work, and clocks.
4. Domain and protocol code never import Flutter widgets, Dio, Drift, Forui, Flyer Chat,
   or platform plugins.

Cross-feature communication uses typed application commands/events, not direct provider
lookups or database writes.

## Runtime data flow

```text
REST / WebSocket / user action
             |
             v
   protocol validation + decryption
             |
             v
      one Drift transaction
             |
             +--> domain rows
             +--> inbox/outbox state
             +--> sync checkpoints
             |
             v
      Riverpod database streams
             |
             v
       app-owned UI widgets
             |
             +--> Forui shell/components
             +--> app-owned timeline adapter and builders
```

Widgets read a single projection. A send first commits the logical message and
its owed preparation to Drift. A later delivery cycle seals and persists the
per-device outbox rows before sending them. Network acceptance updates transport
state, and receipt events update delivery state. Each message received from REST and
WebSocket is displayed once, multi-device delivery targets every live peer device and
the sender's other devices, cached conversations remain readable offline with sends
entering the durable outbox, and each send/receive transaction boundary recovers
deterministically after process death. Incoming envelopes are acknowledged after their
disposition is persisted. See [outgoing preparation](SYNC.md#owed-send-preparations)
and [incoming envelopes](SYNC.md#incoming-durable-envelopes).

The server stores no message history. Message history remains on client devices; a new
device receives history only through an encrypted transfer from an existing online device,
and the recovery backup restores cross-signing identity material rather than message
history, ratchets, group control state, or authorization. Revoked devices lose tokens,
queued content, local session access, and future group access.

## Feature boundaries

Feature modules correspond to product capabilities: bootstrap, authentication, devices,
contacts/profiles, conversations, messaging, groups, attachments, search, voice rooms,
identity recovery/device-to-device history transfer, settings, and shared shell/design
system.

Features own their use cases and presentation. Shared domain concepts live in narrowly
scoped core packages. A generic `utils` dumping ground is prohibited.

## Source layout and composition

The package must make product capabilities visible first and keep Clean Architecture
layers inside each capability:

```text
lib/
  app/                         root widget, bootstrap, config, routing, DI composition
  core/                        framework-free cross-feature policy contracts only
    application/              command, event, use-case, and port conventions
    domain/                   shared entity/value-object primitives
    protocol/                 framework-free protocol values and validation
    result/                   sealed result and safe failure classifications
  features/
    <feature>/
      domain/                 feature-owned entities, values, and rules
      application/
        use_cases/             commands/queries coordinating domain behavior
        ports/                 repository/gateway interfaces required by use cases
      infrastructure/         local, remote, crypto, and platform port adapters
      presentation/           Riverpod controllers, immutable state, and widgets
  shared/
    infrastructure/           only cross-feature technical adapters
    presentation/             app-owned reusable presentation primitives
  l10n/                       Flutter localization input/generated support files
  main*.dart                  environment entry points
```

Folders are created only when a numbered piece adds real code. `core` must not collect
feature business concepts, and `shared` must not become a generic dumping ground.
Feature-owned repository interfaces live in that feature's `application/ports`; their
Drift/Dio/platform implementations live in the same feature's `infrastructure` layer.
A feature cannot import another feature's infrastructure.

`lib/app/dependencies` is the Riverpod composition root and is the only place allowed
to select concrete adapters. Provider declarations are immutable descriptors;
ProviderScope owns instances and test overrides. The app root may import features and
infrastructure to compose them, but dependencies inside a feature point toward its
application and domain layers.

The offline-first path keeps a repository adapter as the single mutation boundary:
remote input and user commands are validated, applied to the local source of truth, and
then observed as immutable projections. Typed application events describe completed
facts; durable events are committed before projections publish them. Riverpod manages
lifecycle and observation but never owns the durable record.

Expected failures use the sealed `Result`/`Failure` model. Failures carry only stable
categories and reviewed reason codes, never raw backend messages or exception text.
Presentation maps those codes to localized copy. A source-boundary test guards core and
feature policy imports against Flutter, Dio, Drift, Forui, Flyer Chat, platform plugins,
and every other outer package. A source-layout test requires the four top-level
architecture boundaries and the recognized layer names inside every feature.

## State management

- Riverpod provides dependency injection, lifecycle, commands, and projections of Drift
  streams.
- Providers do not become an alternative database.
- Durable state is not kept only in a notifier.
- UI-only transient state such as focus, selection, and animation MAY stay in widgets or
  short-lived providers.
- Authentication and connection state are explicit state machines.

## UI boundary

Forui supplies tokens and application-shell primitives behind app-owned components.
The virtualized message surface is supplied only through the timeline adapter, whatever
implements it. Custom builders own the exclusive visual design for bubbles, grouping,
replies, status, attachments, system events, and composer.

A package's models and controllers may only ever be adapters, never domain models or the
source of truth. If the required pagination, anchoring, RTL, accessibility, or media
performance spike fails, only the timeline adapter is replaced with a custom sliver
implementation.

Piece 15 exercised that replacement clause: the then-pinned Flyer 2.11.1 update path
requires a mutable `ChatController`, so the production `ChatTimelineAdapter` is an
app-owned reversed sliver with explicit reading-anchor restoration. Drift-backed
projections remain the source of truth. **ADR-054 (2026-08-24) finished that decision**:
`flutter_chat_core` and `flutter_chat_ui` were still declared in `pubspec.yaml` and
imported by no file in `lib/`, so they were removed and ADR-007 is superseded. The
boundary itself is unchanged, and is what would make a future adapter swap possible. The adapter and all builders receive immutable view models
and emit typed intents; they cannot reach cryptography, APIs, Drift, or synchronization.

## Platform boundary

Android is the only version-1 production target. The Web shell, adapters and CI build
were removed under
[server ADR-0020](../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md),
and iOS, Windows, macOS, and Linux applications are out of scope. The interface supports
English and Persian from the first release, including RTL chrome, mixed-direction message
text, and localized dates ([Adaptive layout](../ui/ADAPTIVE-LAYOUT.md#accessibility-and-internationalization-gates)).
See [platform status](../STATUS.md#platform-identity-and-content).

- Android uses encrypted SQLite and Android Keystore wrapping.
- Active-app messaging uses the socket and authoritative REST drain. Android background
  messaging is layered and honestly tiered: the mandatory floor is a persisted periodic
  `JobScheduler` job at the platform fifteen-minute minimum (giving eventual delivery and
  nothing in Android 13+ *rare*/*restricted* standby buckets, Doze, Data Saver, or after
  a force-stop). Above it, the opt-in `specialUse` foreground service is offered in
  production as best effort under [ADR-094](decisions/094-best-effort-delivery.md) with
  no delivery-time promise, while an active voice call uses a separate `microphone`
  foreground service started on explicit join and stopped when the call ends.
- Notifications are sender-neutral projections of committed local unread state rather than
  transport events, with no decrypted previews ([ADR-048](decisions/048-generic-notifications.md)).
  See [Android platform](ANDROID.md), [sustained delivery](../runbooks/SUSTAINED-DELIVERY.md),
  and [delivery status](../STATUS.md#presence-voice-and-delivery).

No platform-specific conditional is allowed inside domain or protocol logic.

## Voice and realtime

The relayed mesh in [ADR-077](decisions/077-voice-mesh.md) supersedes the MLS, SFrame
and LiveKit prerequisites in [ADR-058](decisions/058-voice-prerequisites.md).
[Voice status](../STATUS.md#presence-voice-and-delivery) records the release gaps. The
[v1 contract](../contracts/VOICE-V1.md) specifies the implemented formats. The binding
[voice roles contract](../../../docs/client/CLIENT_VOICE_ROLES.md) defines v2 for a voice release.

### The architecture

Voice is a full mesh of WebRTC audio between devices. Every path crosses the self-hosted
coturn relay. Each connection is keyed by DTLS-SRTP between its two endpoints, so the
backend, the relay and every other participant hold none of its keys.
[Client contract §N](../../../docs/client/CLIENT_CONTRACT.md#n-voice) is the binding
statement of it and its eleven rules are cited by number throughout.

- **Audio only.** One audio track for each connection: no video track and no data channel
  in this version (§N rule 1).
- **No application media key, and none is designed** (ADR-0021 point 3). A connection's
  keys belong to its endpoints. Closing a removed member's peer connections ends media
  on those connections.
- **Relay-only ICE**, with the credential `POST /api/v1/me/relay` mints as the only ICE
  server. No STUN server and no foreign server is configured anywhere (§N rule 2, ADR-0021
  point 2).
- **The server holds no room and no participant list.** It mints a relay credential and it
  relays `signal` frames. That is the whole of its part.
- **A room is client state, exactly as a group is** — signed control events over ordinary
  durable envelopes. **A call is `signal` frames between devices.**

Two wire formats carry that, and both are specified in
[v1 signalling](../contracts/VOICE-V1.md):
`CPVRV001` for the room's control events, durable; `CPVSV001` for the call's signalling,
volatile. Both formats use [pairwise transport v1](../contracts/PAIRWISE-V1.md) with its existing
suite, header flags and key schedule.

### What the server does, and what it does not

| | Where |
|---|---|
| Mints a coturn credential | `POST /api/v1/me/relay` |
| Relays an opaque blob to one device, if that device is connected at that instant | `/ws` `signal` |
| Publishes `voice_configured` and `signal_buckets` | `GET /api/v1/config` |
| Stores a room, a name, a roster, a capability, a join token or a live count | **nowhere** |
| Counts participants, enforces a ceiling or reports presence | **nowhere** |

[OpenAPI](../../../backend/openapi.json) defines relay credentials and config. The
[realtime API](../../../backend/realtime/API.md) defines the socket transport.

### The room

A room is a named set of member accounts that exists only in its members' clients. It is
standalone — not a group, not a direct conversation, and no group or direct conversation
hosts a call in this version.

- Its id is 32 CSPRNG bytes. Its name travels inside its control events, so the server
  never holds it and there is nothing there to rename or delete.
- Its roster is built by signed control events on one hash chain, mirroring
  `GroupControlEvent` field for field under its own signing domain. Every active member
  has the same authority in v1: any active member may add or remove a member or
  rename the room. Version 2 role permissions are defined by the
  [voice roles contract](../../../docs/client/CLIENT_VOICE_ROLES.md#2-roles-and-who-may-do-what).
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

### A call

1. The call action requires a voice-enabled deployment and a room this device may act in.
2. On explicit join, the controller requests microphone permission and starts the
   microphone foreground service.
3. The engine fetches the relay credential, starts missing pairwise sessions over the
   durable path and draws a 16-byte `join_id`. It queries participants before announcing
   the join.
4. A participant that receives a join creates a relay-only `RTCPeerConnection` and offers.
   The joiner answers. The device whose lowercase device ID sorts first rolls back its
   own offer if both devices offer at once.
5. Peers exchange batched ICE candidates. The pairwise session authenticates the
   fingerprint in the SDP and the DTLS handshake keys the connection.
6. Leaving sends a volatile notice and closes the peer connections. The controller stops
   the foreground service and the call drops its in-memory text and participant state.

See the [v1 call contract](../contracts/VOICE-V1.md#the-call) and the
[Android microphone lifecycle](ANDROID.md#a-calls-microphone).

**Trouble is per person.** Every tile is its own encrypted connection, so one peer can be
unreachable, or blocked by a changed safety number, while everybody else keeps talking.
Nothing pauses when one connection fails and nothing pauses when somebody leaves — there
is no shared key to rotate.

### Realtime gateway

One application-owned gateway wraps `/ws`. It validates frame type and bounds before
routing typed events; widgets never send raw JSON. The upgrade authenticates with
`Authorization: Bearer <session token>`, which is the only handshake path: a refusal
arrives as a failed upgrade with `403 Forbidden` and never as a close code, and a handler
waiting for a close code there will never fire (§O).

Two frames go up — `ack` and `signal` — and two come down — `envelope` and `signal`. There
is no subscription frame, no `presence` frame and no room frame in either direction
(ADR-0022). Durable `envelope` frames enter the inbox pipeline and are deduplicated
against REST. The shared `SignalRouter` reads volatile `signal` frames from the delivery
socket and dispatches opened payloads to voice or presence.

The client validates the server's published signal buckets on send and receive. An outgoing
off-bucket blob is refused locally. An incoming one is dropped without closing the
socket. See the [backend realtime API](../../../backend/realtime/API.md) and the
[v1 socket limits](../contracts/VOICE-V1.md#the-socket-limits) for frame bounds, pacing and
the inbound queue.

Durable delivery uses REST recovery when the socket is down. A connected media path can
continue during an outage while joins, leaves and ephemeral text cannot travel over the
signalling path. The room text panel shows when signalling is unavailable.

### Ephemeral room text

Room text is carried in individually sealed `CPVSV001` frames. The call keeps up to
200 lines in memory and clears them when the call ends, including when the device loses
access to the room. The panel adds the sender's line locally and the relay forwards each
recipient device's frame individually.

The wording stays best-effort, because another participant can retain what they
decrypted, and because a frame published for a device that is mid-reconnect is gone.

### Participants and speaking state

- **The participant set is this device's own.** The call engine projects local peer
  connection states. `participants_query` answers can identify a peer to expect an offer
  from (§N rule 5). The media connection establishes the peer's connected state.
- **This device's mute state is local.** The call screen renders mute with an icon and
  label. See [voice status](../STATUS.md#voice-implementation-gaps) for outstanding call UI work.
- **A name and an avatar come from locally authenticated profile state**, not from
  anything a peer sent in a call.
- The room list shows *Live now · N* for this device's active call and uses that call's
  local count. Other eligible rooms show *Empty*. The server supplies no live count.

### Platform lifecycle

- Android requests the microphone on explicit join and at no other time, and runs a
  microphone-type foreground service for as long as the call lasts (§N rule 11): a call
  outlives the moment the user looks at another screen.
- `POST_NOTIFICATIONS` is off by default on a fresh install, so a denied notification
  permission is the common path rather than the edge. It is a stated outcome — the
  foreground-service disclosure is degraded and the screen says so — and never a retry
  loop.
- A temporarily disconnected peer can recover on the same connection. A failed
  connection is dropped and a fresh join is needed. Changing networks does not
  trigger an ICE restart.
- Minimising keeps audio only when the platform can truthfully maintain it, and shows the
  persistent in-app banner.

### The existing surfaces

The router exposes the room list, creation flow and Room Info, with call and invite
routes nested under the 64-character hex room ID. The shell compose action and Contacts
entry open room creation. The in-app call banner opens the current call. See the
[voice room screens](../ui/SCREENS.md#voice-rooms--list-create--info) and
[call screen](../ui/SCREENS.md#live-voice-room-screen).

The [local data model](LOCAL-DATA.md#voice-room-state) owns the four durable
room tables. The call engine keeps media and participant state in memory. The
[October 2026 screen migration](https://github.com/Orviniq/communication-platform/blob/ab2ecb826dd00cf3256d2055d4a354527d4d9441/frontend/docs/voice-and-realtime.md#the-existing-surfaces)
records the retired placeholders and table.

### Voice references

- [client contract](../../../docs/client/CLIENT_CONTRACT.md) §F, §K, §N and §O
- [Realtime API and the relay credential](../../../backend/realtime/API.md)
- [Server ADR-0021: a relayed WebRTC mesh, and no server room](../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
- [Server ADR-0022: the gateway holds no presence](../../../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md)
- [`VOICE-V1.md`](../contracts/VOICE-V1.md) — the two wire formats
- [`PAIRWISE-V1.md`](../contracts/PAIRWISE-V1.md) — the transport under both
- [Live Voice Room Screen](../ui/SCREENS.md#live-voice-room-screen) and
  [Voice Rooms](../ui/SCREENS.md#voice-rooms--list-create--info) — UI states and actions
- [ADR-077](decisions/077-voice-mesh.md) — the decision record for this design

## Failure policy

- Expected failures are typed results, not strings parsed in widgets.
- Malformed or unauthenticated protocol input is quarantined and never partially applied.
- Unknown future event kinds are retained as unsupported records without crashing.
- Security failures fail closed.
- A mailbox `pruned_through` gap queues state recovery for active groups and voice
  rooms while the client continues draining. Groups withhold sends and changes
  while waiting, and rooms withhold joins and changes. The client has no direct-chat
  gap UI. See [queue-gap recovery](SYNC.md#queue-gap-recovery).
- Network failures preserve outbox work and surface honest connection state.

## Source references

- [Flutter architecture guide](https://docs.flutter.dev/app-architecture/guide)
- [Flutter architecture case-study package structure](https://docs.flutter.dev/app-architecture/case-study)
- [Flutter offline-first guidance](https://docs.flutter.dev/app-architecture/design-patterns/offline-first)
- [Clean Architecture dependency rule](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Riverpod ProviderScope/ProviderContainer](https://riverpod.dev/docs/concepts2/containers)
- [Flyer Chat customization](https://flyer.chat/docs/flutter/getting-started/customisation/)
  — retained as the reference for the boundary the timeline adapter preserves; the
  packages themselves are no longer declared (ADR-054).
