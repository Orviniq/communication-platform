# Voice room control and signalling, version 1

## Status and scope

This document defines two wire formats and nothing else:

- **`CPVRV001`**, the room's signed control events, carried in ordinary **durable**
  envelopes exactly as a group's control events are; and
- **`CPVSV001`**, the call's signalling payloads, carried in **volatile** `/ws` `signal`
  frames.

It is the binding client contract for both, written by phase 6 prompt 1 and read by every
later prompt of the phase. The architecture it implements is
[`voice-and-realtime.md`](voice-and-realtime.md); the decision record is
[ADR-077](decisions.md). Where this document and
[`backend/CLIENT_CONTRACT.md`](../../backend/CLIENT_CONTRACT.md) §N or server
[ADR-0021](../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
disagree, those win.

**The credential, the signalling transport, one peer connection, the room and the call are
built; no screen is.** `lib/features/voice/` fetches, holds and refreshes the relay
credential and builds the ICE configuration from it (*The credential*, below, phase 6
prompt 3). Phase 6 prompt 4 built the `CPVSV001` transport of Part 2 — the codec, the
volatile seal and open on the pairwise session, the pacing, the candidate batching and the
bounded inbound queue — carried on the delivery session's own socket. Prompt 5 built the
connection between this device and one other (*The connection*, below). Prompt 6 built all
of Part 1: the room and its signed control events, their fan-out and receipt, the four
tables, and the sessions a call needs. Prompt 7 built the call (*The call*, below): who each
frame goes to, when to try again, the ceiling and the removal. Where the build departs from
what this document decided, the departure is dated beside the decision.

The transport beneath both formats is unchanged and is not restated here:
[`pairwise-transport-v1.md`](pairwise-transport-v1.md) is the hybrid session, the Double
Ratchet, the envelope and the sealed sender header, and this profile adds no suite, no
header flag and no key schedule of its own.

## Why two formats and not one

A room's roster has to survive being offline; a call's offer does not.

| | `CPVRV001` — room control | `CPVSV001` — call signalling |
|---|---|---|
| Channel | `POST /api/v1/envelopes`, durable queue | `/ws` `signal` frame, volatile |
| Survives the recipient being offline | Yes, for `envelope_ttl_days` | No. Dropped at the instant of publication |
| Acknowledged | Yes, by `ack` | No. Nothing reports delivery |
| Retained locally | Yes, the whole signed chain | No. In memory, for the life of the call |
| Buckets | 1024 … 262144 (§K) | 1024, 4096, 16384 (`signal_buckets`) |
| Carries | Who is in the room | Who is in the call, and how to reach them |

The split is the same one server
[ADR-0021](../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
point 7 makes: "a room is client state, carried by client-signed control events over
ordinary envelopes, exactly as a group is. Ephemeral room text and join and leave
announcements are `signal` frames the client fans out to each member device."

**A payload is accepted only from the channel it belongs to.** A `CPVRV001` that arrives
in a `signal` frame is dropped, and a `CPVSV001` that arrives in a durable envelope is
dropped. Without that rule the volatile channel is a way to write durable state, and the
durable queue is a way to replay a call's signalling hours later.

---

# Part 1 — `CPVRV001`, the room's control events

## The room

A room is a named set of member accounts that exists only in its members' clients. The
server holds no room object, no roster, no name and no live count: the whole of the voice
surface it serves is `POST /api/v1/me/relay` and the relaying of `signal` frames.

- A **room id** is 32 CSPRNG bytes, minted by the creating device. It is not derived from
  its members, because the member set changes; it is not a server identifier, because
  there is no server row to identify.
- A room is **standalone**. It is not a group and not a direct conversation, and no group
  or direct conversation hosts a call in this version (D3).
- A room's **roster** is the set of member accounts the accepted control chain builds. A
  member's *devices* are not in the roster: they are read from that member's authenticated
  live device list at the moment a payload is sealed, exactly as a group's are
  (`CLIENT_CONTRACT.md` §F).
- A room's **name** is carried inside its control events, so it is ciphertext everywhere
  outside a member's device. There is nothing to rename on the server and nothing to
  delete there.

## The event

`RoomControlEvent` mirrors `GroupControlEvent`
(`lib/features/groups/domain/group_model.dart`) field for field. The shared native core
builds it as deterministic CBOR and signs it with the signing device's Ed25519 key (bytes
0–31 of its `ik_pub`). Dart never builds or parses that CBOR and never holds the key.

| Field | Meaning |
|---|---|
| protocol version | `1` |
| `event_id` | 16 CSPRNG bytes |
| `room_id` | The room's 32-byte random id |
| `revision` | `1` for the create event, then exactly one more than the event it follows, at most `0xffffffff` |
| previous state hash | Absent at revision 1; otherwise the state hash of the event it follows |
| signer user and device | The account and device whose key signed it |
| `created_ms` | Sender wall-clock time, for display only |
| operation | One of the five below |

Two domain constants, exact ASCII, never NUL-terminated, and distinct from the group's so
that an event of one kind can never be replayed as the other:

```text
chat:v1:room-control
chat:v1:room-control-state
```

The signature is Ed25519 over `"chat:v1:room-control" || u32be(length) ||
canonical_event`. Each accepted event commits the room to the state hash
`SHA-256("chat:v1:room-control-state" || u32be(length) || canonical_event)`, and the next
event names that hash, so a room's accepted events are one hash chain. An event is at most
16,384 bytes, and a decoded event that does not re-encode to exactly the signed bytes is
refused.

**As built, 2026-09-30.** `native/crypto_core/src/room_control.rs` is the group's module
under the room's two domains, reached through operations 20 (seal) and 21 (open) of the
pairwise multiplexer. The canonical event is the group's ten-key map — 0 version,
1 `event_id`, 2 `room_id`, 3 `revision`, 4 the previous hash or null, 5 and 6 the signer,
7 `created_ms`, 8 the operation, 9 the body — and the bodies are `{0: name, 1: [user ids]}`
for a create, `{0: [user ids]}` for an add, `{0: user id}` for a removal and `{0: name}` for
a rename, account ids strictly ascending; a golden test pins the bytes. Before it signs, the
core refuses a create of fewer than two members or one that does not name its creator, an
add of 50 or more, an all-zero account id, and the reserved value 5. A signature made under
the group's domain never opens a room event, and a room event never opens as a group's.

## The operations, and who may sign each

| Operation | Value | Body | Who may sign it |
|---|---|---|---|
| create | `1` | Name and every member | The one creator it names; 2 to 50 members including the creator |
| add members | `2` | User ids, each added as a member | Any active member |
| remove member | `3` | One user id | Any active member. A member naming itself is leaving |
| rename | `4` | Name | Any active member |
| — | `5` | Reserved, so that a later role operation cannot reuse a value | — |

**Every active member has the same authority (D1).** There is no owner, no admin and no
role tag, which is what §13.2 of [`ui-specification.md`](ui-specification.md) and the
design canvas both already say, and it is the honest reading of "all peers are equal": a
room whose members can each invite anyone is a room whose members can each remove anyone.
The cost is stated rather than designed away — any member can eject any other, and the
remedy for a member who abuses that is a new room, because there is no authority above
them to appeal to. The removed member's own copy of the event tells them who signed it.

A name is at most 100 Unicode scalar values, the same bound a group name has. There is no
description: a room has no timeline to describe.

A room holds at most 50 members, and a **call** inside it holds at most 10 joined devices
(Part 2, "The ceiling"). Those are different numbers on purpose: membership costs one
envelope fan-out on a change, and a call costs every participant an uplink for every peer.

## Applying an event

A receiving device refuses an event whose signing device is not in its account's
authenticated live device list, whose signature does not verify under that device's key,
or whose chain link does not match. It then decides against the roster the event builds
on, never against its own lifecycle. The six outcomes are the group's, unchanged:

- the next revision, naming the held hash, from a signer that roster authorizes, is
  applied;
- the held revision with the held hash is a duplicate;
- a signer the roster does not authorize is recorded in `quarantine` and the event
  dropped, so one non-member cannot stop a room for everybody;
- a second event at a revision already accepted, or one naming a different hash, is a
  fork: the room is quarantined and the client never picks a branch;
- a later revision, or an event after the first for a room this device does not hold, asks
  the sender for the room's state; and
- a create event for a room this device is not in is ignored.

A quarantined room joins no call, invites nobody and renames nothing until the fork is
resolved out of band, which is the *Info — conflicting changes* state.

**As built, 2026-09-30.** `RoomControlStateMachine` and `RoomInboundCoordinator` in
`lib/features/voice/`. Two rules are stricter than the group's. A transcript that would give
this device a room is taken only when the sender's account, as well as this one's, is an
active member of the state it leads to. And a transcript confirms the state this device
holds, retiring its open request, only when the transcript's head is exactly that state: a
copy from a member who was itself behind — an answer that came late, or a new member's
transcript that crossed an event — retires nothing. A removed member's later events are
recorded in `quarantine` and dropped, and their state requests go unanswered.

## The payload

Control state travels in ordinary pairwise envelopes as a room payload, framed exactly as
a group payload is:

```text
"CPVRV001" || kind:u8 || body
  kind 1, control:    entry
  kind 2, request:    room_id[32] || have_revision:u32be || have_state_hash[32]
  kind 3, transcript: room_id[32] || base_revision:u32be || base_state_hash[32]
                      || count:u16be || count x entry
entry = signer_user_id[16] || signer_device_id[16]
        || canonical_length:u32be || canonical_event || signature[64]
```

A revision of zero carries an all-zero hash, and a payload is at most 200,000 bytes.

The four delivery rules are the group's, and hold for the same reasons
([`message-protocol.md`](message-protocol.md), Groups):

- **Control.** A device sends the event it signed to every member who held the state the
  event builds on — the member a removal removes included, so that member learns of it —
  and to its own other devices. Only the signing device may deliver a control payload.
- **Transcript to a new member.** A member an event adds is sent the whole transcript from
  revision 1 instead. A transcript that would not fit one payload means the member is not
  added.
- **State request.** A device that may be missing events names the state it holds. Only an
  active member is answered, and only by a device that holds an unquarantined state as an
  active member itself.
- **Queue gap.** After a `pruned_through` gap (§H) every room waits for its state before
  it joins a call, invites or renames. That is the *Room waiting for its state* row of
  [`design-handoff/voice-room-states.md`](design-handoff/voice-room-states.md), and the
  reason it blocks a join is that a device which may be missing a removal would otherwise
  offer audio to somebody the room has ejected.

## Starting the sessions a call needs

Decided on 2026-09-30, option B of [ADR-077](decisions.md)'s open conflict. A call's frames
are volatile, and a volatile frame never starts a pairwise session (Part 2, *Volatile seal
and open*), so the room starts every session its call will need, on the durable path, before
the call needs it. No payload is new: this is the kind 2 request above, sent on a rule of its
own.

- **The payload.** A state request naming the state this device holds, sealed to one device
  alone as an ordinary durable envelope. With no session to that device, the fan-out claims
  its bundle and the envelope's initial header starts one, and the queue holds the envelope
  until the device fetches it. The answer is the session's second message.
- **Who is sent one.** Each live device of each active member, this account's other devices
  included, that this device has no pairwise session with at all. A session under repair
  belongs to the repair path and is left alone.
- **When.**
  1. After this device commits a change that gives it the room or adds a member — a create,
     a transcript that gives it the room, an add — it sends one to each such device whose
     id sorts above its own, as lowercase strings, the order §N rule 3 uses. The device
     that sorts lower starts the session, so two devices that accept one change together
     start one session between them.
  2. Every 24 hours for each room it holds, and whenever the call asks before a join, it
     sends one to every such device, whichever sorts lower: that device may be offline, and
     a member's new device has accepted nothing.
  3. Never for a room it holds quarantined, is waiting on the state of, or is not an active
     member of.
- **Answering it** is the state-request rule above. Two rules extend the group's, for rooms
  only: a request for a room this device does not hold, and a request naming a later
  revision than this device holds, each open a state request back to the device that sent
  it, within the same 64 open requests. The first is how a member's new device learns a room:
  a member device starts a session with it by asking, and it asks back.

What a missing session costs, and the alternatives this rule was chosen over, are in the
ADR.

**As built, 2026-09-30.** `RoomSessionStarter` runs in the delivery cycle's post-inbox work,
after room state recovery and before the room dispatch, four rooms a pass. A payload already
owed to a member — a create's or an add's own copy, an answer — counts as that member's
session start, and a member whose live devices cannot be authenticated just now is left out
and reported. The call's check is `startSessionsForCall`, which refuses a room this device
may not act in. The call routes the room's outbound work before its `join`, and a peer that
has not fetched the request yet drops that frame and takes the next attempt.

## What it replaces in the database

The Drift table `voice_rooms` — `local_room_id`, `capability_ciphertext`,
`metadata_ciphertext`, `live_state` — described a server room: a capability to hold, a
name the server stored, and a live count the server counted. None of those exists.
**It is deleted**, and four tables that mirror the group's take its place:

| Table | Mirrors | Holds |
|---|---|---|
| `room_states` | `group_states` | One row per room: the encrypted roster projection, the accepted revision, the state hash, the lifecycle, and when this device last checked it for missing sessions — empty after a change of rule 1 above, so the check is due |
| `room_control_events` | `group_control_events` | The accepted chain: one row per signed event, with the exact canonical bytes and signature, so this device can hand a transcript to a new member |
| `room_outbound_objects` | `group_outbound_objects` | Exact `CPVRV001` payloads owed to other devices, committed with the state change that produced them |
| `room_state_requests` | `group_state_requests` | Rooms whose state this device still has to ask a member for |

**A call writes no row at all.** Who is connected, who is speaking, who is muted, the peer
connections, the ICE state and the room's ephemeral text are in memory for the life of the
call and are gone when it ends. A call has no durable state because it has no state worth
recovering: a reconnecting device rejoins and re-negotiates from nothing.

**As built, 2026-09-30.** Schema 23. The step drops `voice_rooms` with `secure_delete` on,
so its pages are zeroed rather than left on the free list, and gives the connection its own
setting back. A room writes no conversation row. A room's queue-gap request does not hold
the checkpoint's gap open: the checkpoint closes on the groups' answers as before, and each
room waits for its own. The rest of the application reads rooms through
`RoomStateReadPort` — `watchRooms`, `watchRoom` and `readRoom` — and
`RoomAuthorization.mayAct` says whether this device may sign a change or join a call; a room
waiting on its state reads as `stateRecoveryRequired`.

---

# Part 2 — `CPVSV001`, the call's signalling

## Framing

```text
"CPVSV001" || version:u8 || kind:u8 || deterministic-CBOR body
```

The magic and the two bytes sit outside the CBOR so that a reader routes the payload and
checks its version before it decodes anything an attacker chose. `version` is `1`.

**An unknown major version is dropped in silence, and the peer is counted as not
answering.** There is no error to send back: the `signal` channel is one-way and volatile,
so a `4` in that byte has no reply frame to travel in. The consequence is not silence to
the user, because the retry bound below turns "nothing came back" into the *not reachable*
state within about twenty seconds, and the tile can say the peer needs a newer build when
the version byte is what was wrong. An unknown `kind` inside a known version is ignored
and nothing else, so that a later version can add a kind without breaking this one.

## The common body header

Every body is a CBOR map with small unsigned integer keys, under deterministic CBOR (RFC
8949 §4.2.1: definite lengths, smallest integer encoding, sorted keys, no tags, no
indefinite items, no non-finite floats). Keys 0 to 5 are the header and are present in
every kind; 6 and 7 are reserved so that a later version can extend the header without
moving a body key; kind-specific keys begin at 8.

| Key | Field | Type | Meaning |
|---|---|---|---|
| 0 | `room_id` | bstr, 32 | The room this frame belongs to |
| 1 | `join_id` | bstr, 16 | The sender's own join id, below |
| 2 | `sender_user_id` | bstr, 16 | The sending account |
| 3 | `sender_device_id` | bstr, 16 | The sending device |
| 4 | `counter` | uint, ≤ `0xffffffff` | Monotonic within one `join_id`, from 1 |
| 5 | `created_ms` | uint | Sender wall-clock, for display and staleness only |

**`sender_user_id` and `sender_device_id` must equal the device that authenticated the
pairwise session**, exactly as an application event's must
([`message-protocol.md`](message-protocol.md), Common logical-event header). That check is
what makes the inbound `signal` frame's missing sender field cost nothing: the transport
never named a sender either, and the ciphertext has named one since the first envelope.

**A `join_id` is 16 CSPRNG bytes a device mints when it joins a call**, and keeps for as
long as it stays in that call. It is the reason no call identifier is needed. A peer keys
its per-peer state on `(device_id, join_id)`:

- a frame carrying a `join_id` this device has not seen, from a device already in its
  participant set, means that peer left and rejoined — the old connection is torn down and
  negotiation starts fresh;
- a `leave` naming a `join_id` that is no longer current is ignored, so a late retry of an
  old call's leave cannot drop a device out of the new one; and
- `counter` orders two frames of one join and drops a duplicate, which a retry can
  produce.

A frame whose `room_id` names a room this device does not hold, or holds quarantined, or
is not an active member of, is dropped before its body is read. So is a frame from a
device whose account is not an active member of that room — which is the whole of the
removal refusal of §N rule 8, and needs no separate list (Part 2, "Removal").

## The kinds

| Kind | Name | Sent to | Retried |
|---|---|---|---|
| 1 | `join` | Every live device of every active member | Yes |
| 2 | `leave` | Every device in the call | No |
| 3 | `offer` | One device | Yes |
| 4 | `answer` | One device | Yes |
| 5 | `candidates` | One device | No |
| 6 | `participants_query` | Every live device of every active member | Yes |
| 7 | `participants` | One device | No |
| 8 | `room_text` | Every device in the call | No |

Bodies, on top of the header keys:

**1 `join`** — no further key. "This device is in the call now." A participant that
receives one sends an `offer`; the joiner answers (§N rule 4).

**2 `leave`** — key 8 `reason`: uint, `1` the user left, `2` the room's state changed
under this device, `3` a local failure ended the call. Advisory only: the connection
closing is the authoritative signal, and a peer that never sees a `leave` learns the same
thing from `RTCPeerConnection` reaching `closed` or `failed`.

**3 `offer`** — key 8 `target_join_id`: bstr, 16, the peer's join id as the sender
believes it. Key 9 `sdp`: tstr. An offer whose `target_join_id` is not this device's
current one is dropped: it is addressed to an incarnation that has ended.

**4 `answer`** — key 8 `target_join_id`: bstr, 16. Key 9 `sdp`: tstr. Key 10
`answers_counter`: uint, the `counter` of the offer it answers, so a late answer to a
superseded offer is discarded.

**5 `candidates`** — key 8 `target_join_id`: bstr, 16. Key 9 `candidates`: an array of at
most 8 maps, each `{0: candidate tstr, 1: mid tstr, 2: mline uint}`. Key 10 `end`: bool,
true when no further candidate will follow for this negotiation.

**6 `participants_query`** — no further key. §N rule 5: a device that needs the current
participants asks, and the participants answer.

**7 `participants`** — key 8 `members`: an array of at most 10 maps, each `{0: user_id
bstr 16, 1: device_id bstr 16, 2: join_id bstr 16}`, being the devices the answering
device believes are in the call, itself included. It is a hint and never an authority: a
device is in this device's call when a connection to it is open, and for no other reason.

**8 `room_text`** — key 8 `text`: tstr, at most 2,000 Unicode scalar values and 8,000
encoded bytes. Ephemeral room text, in memory only, never appended to a timeline, never
acknowledged and never retried.

## Sizes, and what fits a bucket

A `signal` blob is standard base64 of **exactly** 1024, 4096 or 16384 bytes — the
`signal_buckets` of `GET /api/v1/config`, already parsed into
`ServerConfig.signalBuckets`. An off-bucket blob is dropped in silence: there is no
`400 bad_bucket` here and no error to read (`realtime/API.md`, server ADR-0022 point 4).

The blob is an `EnvelopeV1` of exactly that length, so the plaintext budget is arithmetic
on [`pairwise-transport-v1.md`](pairwise-transport-v1.md):

```text
bucket = 1 (version) + 1 (suite) + 2 (ratchet_header_length)
       + ratchet_header
       + 16 (AEAD tag) + 4 (real_length) + inner + CSPRNG padding

inner_max = bucket - 24 - len(ratchet_header)
```

A regular ratchet header is 58 bytes. An initial one is 1,382 bytes, or 2,470 with a PQ
one-time ciphertext, or 2,518 with a repair replacement as well.

| Bucket | Regular header (58) | Initial, worst case (2,518) |
|---|---|---|
| 1024 | **942** | cannot be encoded |
| 4096 | **4,014** | **1,554** |
| 16384 | **16,302** | **13,842** |

**An SDP offer fits, and the measurement is on the record.** An audio-only offer from
libwebrtc, with `iceTransportPolicy: 'relay'`, `bundlePolicy: 'max-bundle'`,
`rtcpMuxPolicy: 'require'`, one `sendrecv` audio transceiver, no video and no data
channel — which is exactly what §N rules 1 and 2 require — is **1,363 bytes** over 46
lines. Measured on 2026-09-20 against Chromium 152.0.7977.76; `flutter_webrtc` 1.6.1
carries `io.github.webrtc-sdk:android:150.7871.01`, a near neighbour of the same stack,
and an answer is that size or smaller because it narrows the codec list rather than
widening it. With the 126 bytes this framing costs and the 20 for `target_join_id`, an
`offer` is about **1,516 bytes**.

Three rules follow, and they are the reason the arithmetic is written down:

1. **An offer or an answer is sealed into bucket 4096**, which leaves 2,498 bytes of
   margin — 183 % of the measured SDP — for a future codec list, another header extension
   or a longer fingerprint. Bucket 1024 holds 942 bytes and cannot carry an SDP at all.
2. **An SDP is never the first message to a peer.** An initial ratchet header in bucket
   4096 leaves 1,554 bytes, which clears 1,516 by 38 — a margin thin enough that one added
   `a=extmap` line would silently put the frame off-bucket, and an off-bucket frame is
   dropped without a word. A device with no session to a peer sends its small `join` or
   `participants_query` first, which fits an initial header in 4096 with room to spare, and
   by the time the SDP is sealed the session has ratcheted and the header is 58 bytes. If
   an SDP must be sealed under an initial header anyway, it goes in **16384**.
3. **Everything else is sealed into the smallest bucket that holds it**, which is 1024 for
   `join`, `leave`, `participants_query`, a short `room_text` and a small `candidates`
   batch. A `room_text` at its 8,000-byte ceiling goes in 16384; the composer's limit is
   set against the bucket the plaintext pads into, never against a server ceiling, because
   there is no longer a server ceiling to read (*Chat — message too long*).

**As built, 2026-09-30.** The native core pads a payload to the smallest bucket that holds
it, and nothing pads one up. A real SDP is more than the 942 bytes bucket 1024 holds under
a regular header, so an offer or an answer lands in 4096 by rule 3 alone; one that outgrew
4096 would land in 16384 rather than off-bucket, because the codec refuses a payload over
16,302 bytes, which is what 16384 holds under a regular header. The seal compares each
sealed frame with the published `signal_buckets` before anything is committed, so a frame a
deployment's buckets cannot carry is refused (`offBucket`) and its ratchet step discarded.
Rule 2's fallback to 16384 does not arise while a volatile frame never starts a session
(*Volatile seal and open*, below).

A relay ICE candidate line is roughly 120 to 180 bytes — a foundation, a component, a
transport, a priority, an address and port, `typ relay`, a `raddr`/`rport` pair and the
`generation`, `ufrag` and `network-cost` extensions. Eight of them with their `mid` and
`mline` come to about 1,600 bytes and fit bucket 4096. Relay-only ICE with BUNDLE and
rtcp-mux gathers one candidate per TURN URL for one transport, so a batch of eight is a
ceiling with a wide margin rather than an expected size.

## Volatile seal and open

A signalling payload is **encrypted to the pairwise session of §F, on the same Double
Ratchet as a durable message, in the same chain** (D5). There is no second session between
a device pair, no signalling-only key schedule and no change to
[`pairwise-transport-v1.md`](pairwise-transport-v1.md), because §N rule 6 binds the
signalling to the session of §F and that profile is frozen and under independent review.

**The sealed state is committed before the frame leaves.** A ratchet key that encrypts two
different plaintexts is the one failure this transport cannot survive, so the rule the
durable path already obeys is unchanged: the advanced session state, and its authenticated
skipped-key count, are written in one transaction, and only then is the ciphertext handed
to the socket. What a volatile seal does *not* write is an outbox row — that is the whole
of the difference. The pairwise store gains one method beside `commitPreparedSend`:

```text
commitVolatileSeal(targets) -> ciphertext per target
```

It commits every target's next state in one transaction, exactly as `PairwiseSendCommit`
already does across a fan-out, and returns the bytes to the caller instead of storing
them. Nothing is retained for a retry, and **a retry re-seals rather than resends**: the
next attempt is a new message number on a chain that already advanced for the first one.
Re-sending stored bytes would be pointless here anyway, because the frame was not lost in
transit — it was dropped because nobody was listening.

**As built, 2026-09-30.** `PairwiseVolatileStore` holds the method, beside the durable
store rather than in it: `commitVolatileSeal` commits the transitions, and
`PairwiseVolatileSealer` hands the frames back once it has. Its partner
`commitVolatileOpen` writes the session a received frame advanced and, for an initial
header, the device state, the consumed one-time prekeys and the replay marker — and no
inbox row, no opened payload and no application event.

**What a dropped frame costs the skipped-key bound.** A frame the server drops is never
delivered and is never redelivered, so the sender's chain is one message ahead of the
receiver's for good. The receiver stores nothing at the time — a message it never saw
creates no skipped key. The cost lands later, on the next message in that chain that
*does* arrive: the receiver then derives and retains one skipped key for every message
number the drop left behind, and those keys are dead weight for the life of the session,
because the frames they open were discarded hours ago.

The bound is 2,000 skipped keys for one device pair and 20,000 across the account, and
crossing it returns `repair_required` and runs the authenticated repair path. That path
works, but it interrupts the **text** conversation with that device too, because it is one
session. So the volatile budget is capped where the budget is spent:

- **At most 32 sealed volatile frames per peer per call.** The retry bound below produces
  at most four `join`s, four `offer`s or `answer`s, four `participants_query`s, a handful
  of candidate batches and one `leave`; 32 is that with room over.
- A peer already reported unreachable is sealed nothing further until it announces itself
  again with a fresh `join`. Nothing retries on a timer.

At 32 frames it takes 62 calls in which **every** frame to one peer is dropped before that
pair reaches 2,000, and the outcome at 2,000 is a repair rather than a loss. That is the
honest cost of putting volatile traffic on the durable chain, and it is the price of not
inventing a second key schedule.

**When no session exists with a device.** The device is claimed through the existing
selective path — the recipient's complete live device set is authenticated first, and the
live set the claim returns must equal the resolved one — and the first payload is sealed
under an initial header. A claimed bundle without the signed ML-KEM prekey is refused when
it is claimed and again before the core is asked: **no call is ever placed over a
classical-only root**, and a peer whose bundle cannot be verified shows as not reachable
with the reason stated, never as a peer who is simply quiet. Each new session consumes one
classical and one ML-KEM one-time prekey of that device, so a first call into a room of
ten costs nine of each; the ordinary replenishment on
`GET /me/devices/{device_id}/prekeys/count` covers it and nothing special is needed.

**Suspended on 2026-09-30, phase 6 prompt 4: a volatile frame never starts a session.**
The native core writes an initial header on a session's first message and never again —
`ratchet_encrypt` always writes a regular one — so when the relay drops that first frame,
which is the ordinary fate of a `join` fanned out to a device that is not connected, this
device commits a session its peer never saw. Every later message on it, durable ones
included, names a session the peer does not hold; the peer refuses each as unauthenticated
input and quarantines a durable one, so a text message is lost. When the peer later starts
a session of its own, the simultaneous-initiation rule can keep the lost one as primary on
this side and demote the peer's to receive-only, which breaks the pair in both directions.
A retry cannot help: it is the next message number on the same session. So the seal
refuses a device with no ready primary session as `noSession`, and the store refuses a
volatile transition that would create a session. A session begins on the durable path,
whose queue does not lose a first message short of its TTL. Receiving an initial header
over a `signal` frame is still accepted, under every check a durable one gets. This is a
departure from the paragraph above, not a decision: [ADR-077](decisions.md) records it and
the options, for the owner.

**Decided B on 2026-09-30.** The suspension is the rule: a volatile frame never starts a
session, so *When no session exists with a device*, above, no longer applies, and nothing
is ever sealed under an initial header in a `signal` frame. The room's durable payloads start the sessions instead
(Part 1, *Starting the sessions a call needs*), so a call's first `join` to a peer rides a
session the durable queue already carried the first message of.

**When a peer's safety number changes.** An expected prekey rotation does not reset
account-master verification and costs a call nothing
([`pairwise-transport-v1.md`](pairwise-transport-v1.md), Simultaneous initiation and
overlap). Any other cross-signature change is a blocking safety-number change, and in a
call it is blocking per peer: the connection to that device is closed, nothing further is
sealed to it, and the tile says so with a route to verify. Everybody else keeps talking.
Closing is a decision rather than a consequence — the DTLS session was authenticated by a
fingerprint the pairwise session vouched for *at the time the offer was sealed*, so a key
change afterwards does not break the media on its own. It is closed because the peer's
identity is now in doubt and a call is the wrong place to carry that doubt silently.

**How an inbound blob finds its session.** Identically to a durable envelope, and this is
why the `signal` frame's missing sender field is not a problem to solve. A regular header
names the `session_id`; an initial header names the prekey ids that locate the private
keys and carries the sealed sender block, whose authenticated `sender_user_id` and
`sender_device_id` are the sender's identity (`pairwise-transport-v1.md`, Sender-hidden
initial header). The receive path is the existing one — prepare with no mutation, then one
transaction — and it is the same path whether the ciphertext arrived over `signal` or over
the durable queue. The channel the blob arrived on is remembered and checked against the
payload's magic once the plaintext is open, which is the `CPVRV001`/`CPVSV001` rule above.

**As built, 2026-09-30.** A frame is committed only when its payload is `CPVSV001`. Any
other payload is dropped with its ratchet step uncommitted, so that the channel it belongs
to can still open it: the relay holds every durable envelope and could replay one as a
signal. A `CPVSV001` that arrives in a durable envelope is not an application event the
durable decoder accepts, so it is never applied. A repair control and a repair replacement
belong to the durable path and are refused here; a frame past the skipped-key bound queues
the same authenticated repair request the durable path sends, once per session, and is
dropped. A committed message whose header names a sender other than the device the session
authenticated is dropped, and a major version this build does not speak is reported with
its authenticated sender, so the call can say that peer needs a newer build.

## The socket limits

Two ceilings bound a call, and neither is close (`realtime/API.md`, Frame limits):
**100 frames in a rolling second** closes the socket with `4008`, and **256 undelivered
server frames** for one socket closes it the same way.

A ten-device call is nine peers for each device. Everything a joining device sends, in the
worst case:

| | Frames the joiner sends | Frames the joiner receives |
|---|---|---|
| `join` fan-out | 9 | — |
| `offer` from each participant | — | 9 |
| `answer` to each | 9 | — |
| `candidates`, one batch each way | 9 | 9 |
| **Total** | **27** | **18** |

27 frames is a quarter of the outbound cap and 18 is 7 % of the inbound queue, so the
limits are met by arithmetic before any pacing. Pacing exists for the case the table does
not cover — ten devices joining at once, a room churning, a reconnect storm — and it is
deliberately generous:

- **A token bucket of 32 `signal` frames, refilling at 24 a second.** A ten-device join
  therefore leaves at once, with no added latency, and the worst second a client can
  produce is 56 frames — leaving 44 for `ack` frames and anything a later version adds.
  Acks keep their own budget of 10 a second and are unaffected.
- **Candidates go in one batch per peer per negotiation.** The batch is sent when
  `iceGatheringState` reaches `complete`, or 500 ms after the first candidate, whichever
  comes first, with `end` set on the last. An ICE restart sends a second batch. Trickling
  candidates one to a frame would multiply the frame count by the candidate count for no
  gain, because relay-only ICE with BUNDLE gathers one candidate per TURN URL.
- **The socket reader never decrypts.** An inbound `signal` frame is taken off the socket
  and put on a bounded in-memory queue of 256, drained by a worker that opens the session.
  A client that decrypted on the read loop would be a slow consumer the moment nine offers
  landed together, and a slow consumer is closed `4008`. Past 256 the oldest frames are
  dropped and the peers behind them resolve through the retry path, which is the same
  outcome as the server having dropped them.
- **Room control never touches the socket.** A `CPVRV001` payload is a durable envelope on
  `POST /api/v1/envelopes`, so inviting or removing somebody mid-call costs the rate window
  nothing.

**As built, 2026-09-30.** `SignalFramePacer` is the bucket, in whole micro-tokens so it
never drifts; `VoiceCandidateBatcher` is the batching, at most eight candidates to a frame
and further frames for more, with `end` on the last; `VoiceSignalTransport` holds the queue
of 256 and drops its oldest past it. The transport also holds the 32-frame budget of each
join to each device, which the call releases when it leaves. Signals ride the running
delivery session's socket, attached when the session starts and detached when it stops, so
there is one connection and one rolling second to count.

## Retries, and when a device is unreachable

§N rule 7: a `signal` frame is dropped if the target is not connected at the instant it is
published, and nothing recovers it. Re-send after a bounded timeout, a bounded number of
times, then report the device as unreachable.

| | Value |
|---|---|
| Attempts | 4, the first at once |
| Waits between them | 2 s, 4 s, 8 s, each with ±25 % jitter |
| Answer window after the last | 6 s |
| Unreachable at | about 20 s after the first attempt |

Retried: `join`, `offer`, `answer` and `participants_query` — the four frames that expect
something back. Not retried: `candidates`, because the next batch supersedes it;
`room_text`, which is best-effort by construction; and `leave`, which the closing
connection says anyway.

An attempt happens only while the peer is still an active member's live device and this
device is still in the call. **Nothing pauses when one peer fails**: the tile says *not
reachable* and the audio with everybody else carries on, which is the *Participant — not
reachable* state and the first of the design canvas's three principles. A peer reported
unreachable is attempted again only when a fresh `join` arrives from it, never on a timer,
which is also what keeps the 32-frame volatile budget above from being spent twice.

An answer that never comes is indistinguishable from a peer that is offline, a peer on an
unknown protocol version and a peer whose app was killed. The state says what is
observable — this device did not answer — and offers *Try again*, which re-arms the four
attempts.

## Removal

§N rule 8: removal is immediate, and the server takes no part — it will keep relaying the
removed member's frames, so the refusal has to be the client's.

**How completely the server takes no part, verified on 2026-09-20.**
`realtime/gateway.py` `_handle_signal` performs no authorization: it checks that
`to_device` parses as a UUID and that the blob is a bucket length, then publishes to that
device's topic. It never asks whether the two devices share a room, are contacts, or have
ever spoken, so **any authenticated device can signal any device id it knows**. Nor is
there anywhere for a room to live — the backend has ten models and none is a room, a
membership or a participant, and `core/tests/test_seizure_guard.py` forbids a column
named `members`, `membership`, `roster` or `group_members`. So the two steps below are
not belt-and-braces over a server check. They are the entire enforcement, and the reason
they work is that either end of a connection can close it.

On applying a signed `remove member` control event, in this order:

1. Close every `RTCPeerConnection` to every device of the removed account, at once, before
   anything else is done with the event.
2. Drop that account's devices from the call's participant set and from every pending
   retry.
3. Commit the new roster.

From then on the refusal is a consequence of the roster and needs no list of its own: a
`CPVSV001` frame is applied **only** from a device whose account is an active member of
the room the frame names, checked after the session opens the payload and before the body
is read. A removed member is not an active member, so their offers and announcements are
dropped for as long as the room is held.

A device that applies an event removing **its own** account closes its own connections,
drops the call, drops the room's ephemeral text and keeps the room in its `removed`
lifecycle so the user can see what happened and who signed it.

**The two channels race, and the race is safe in the direction that matters.** The removal
is durable and the signalling is volatile, so a removed member's frames can arrive *before*
the event that removes them — the durable queue is slower than the relay. Those frames are
applied, because at the moment they arrive that member is still in the roster; the event
lands moments later and closes everything. The reverse order, the event first, is the
common case and is clean. What cannot happen is a removed member reconnecting afterwards,
because every later frame of theirs fails the roster check.

**As built, 2026-10-01, and a departure from the order above.** The call reads the room only
through `RoomStateReadPort`, so it learns of a removal from the committed room state, not
from the event: the order is commit, then close, then drop. The close happens as the changed
state reaches the call, ahead of whatever else the call is doing — a send it is waiting on
included — and each frame is checked against the room as committed when that frame arrives,
so nothing from the removed member is applied after the commit. What the order gives up is
the moment between the roster's commit and the change reaching the call, during which the
removed member's connection is still open; closing first would need the room's inbound path
and its own signed removals to call into the call before they commit. The same path ends this
device's call when its own account is removed or leaves, or when the room starts waiting for
its state or forks: its connections close, a `leave` with reason 2 goes to the devices that
were in the call, and the room text goes.

## The credential

§N rule 9, and `POST /api/v1/me/relay` in
[`backend/realtime/API.md`](../../backend/realtime/API.md).

- **Before the button.** `voice_configured` from `GET /api/v1/config` — already parsed into
  `ServerConfig.voiceConfigured` — decides whether the deployment does voice at all.
  False means no call action is offered anywhere, which is *No voice on this server*. The
  route's `503 voice_unconfigured` is the same fact reached the hard way and is never a
  backoff: once a device has seen it, it asks nothing further for the life of the process,
  and the REST client never replays it, although the route is otherwise safe to repeat.
- **Fetch at join, not at launch.** One `POST /api/v1/me/relay` when the user joins a call.
  Minting at startup would spend the `relay` scope, 60 a minute per account, on launches
  that place no call, and would hold a six-hour bearer credential for a relay the user may
  never reach. Every join mints its own, and the call drops it when it ends.
- **Refresh under an hour.** Another mint once less than 3,600 seconds of `expires_in`
  remains. The default TTL is 21,600 seconds, so an ordinary call never refreshes.
  `expires_in` is counted on this device's clock from the moment the request was sent,
  which is never later than the mint, and the timestamp inside `username` is never read,
  so a clock that disagrees with the server's cannot delay a refresh.
  `RELAY_CREDENTIAL_TTL_SECONDS` has no floor, so a lifetime under two hours refreshes at
  half-life instead: at an hour or less every credential would be inside its final hour
  when it was minted, and each refresh would mint another that was already due.
- **Expiry mid-call is an ICE restart, not a teardown.** A fresh credential, then
  `restartIce()` on each connection, which re-gathers against the new allocation and keeps
  the media flowing where it can.
- **In memory only.** The credential is a bearer secret for the relay, is worth nothing
  after `expires_in`, and is never written to the database or a log. A retried mint is safe
  and leaves the client holding two working credentials rather than none.
- **Exactly the servers the answer names.** `iceServers` is the returned `urls` with the
  returned `username` and `credential`, and `iceTransportPolicy: 'relay'`. **No STUN
  server, no foreign server and no fallback** (§N rule 2, ADR-0021 point 2): a host or
  server-reflexive candidate would put a participant's own address in front of every other
  participant, which is the property the relay exists to remove.
- **`turn:` URLs only.** The whole answer is refused, and the mint reported as failed,
  when `urls` is empty, holds more than 16 entries, or holds anything but `turn:`, a host,
  an optional port and an optional `?transport=udp` or `?transport=tcp`. `turns:` is
  refused with the rest. The relay has no TLS listener (`backend/SECURITY.md`, "Voice"),
  and libwebrtc would check a TLS relay against its compiled-in roots and the platform
  store, user-installed authorities included, never against the provisioned CA
  ([ADR-078](decisions.md)). A TLS relay would be a contract change and a trust decision of
  its own, not something to accept on sight.
- **A dead relay answers `200`.** The route reads a setting and never reaches coturn, so a
  credential minted against a relay that is down looks perfect and the call simply fails to
  connect. The client tells that apart from a quiet peer by *which* thing failed: when no
  connection reaches `connected` within 15 seconds of the first offer **and** every
  candidate pair failed, the relay is reported unreachable — *The call could not connect* —
  rather than nine people being reported unreachable one at a time.
- **`429 throttled`** carries `Retry-After`; the join action cools down for exactly that
  long and says so. Nothing is asked during the cooldown, a refresh included, and a held
  credential stays in force through it. A `429` with no usable `Retry-After` cools down for
  a minute, the window the `relay` scope counts.

Built in `lib/features/voice/`: `RelayCredential` and `RelayIceConfiguration` in the
domain, `RelayCredentialService` for the rules above, and `DioRelayCredentialRepository`
for the route, composed in `lib/app/dependencies/voice_providers.dart`. The ICE restart is
`VoicePeerConnection.restartIce` (*The connection*, below); when to call it — at
`refreshDueAt`, with the new credential's configuration — is the call's.

## The connection

§N rules 1, 2, 3, 6 and 9, as phase 6 prompt 5 built them on 2026-09-30:
`VoicePeerConnection` in `lib/features/voice/application/`, over two ports —
`VoicePeerMediaPort` for the platform connection and `VoiceLocalAudioPort` for the
microphone — whose `flutter_webrtc` adapters are the only files that import the package
(`test/architecture/voice_media_boundary_test.dart`). A connection is to one device in one
of its joins and knows nothing of a room: whom to negotiate with, when to try again and when
to give up are the call's.

**One audio track, and nothing that could become a second.** A connection takes a hold on
the call's one capture — `getUserMedia` with `audio` true and `video` false, shared by every
connection of the call and stopped when the last hold is given back — and adds its track
with `addTrack`. No transceiver is added and no data channel is created. Two rules make
that hold on the far side too:

- **A description that is not exactly one audio section is refused**, whether it was
  received or created here. A `video` or `application` section, or a second `audio` one, is
  how a video track or a data channel would come into being on the device that applies it,
  and a peer that sends one is not a peer of this version.
- **Offers and answers are created with `OfferToReceiveVideo` false.** `flutter_webrtc`'s
  own default asks to receive video, and libwebrtc meets that legacy option under Unified
  Plan by adding a receive-only video transceiver to the offer.

**The configuration is the credential's, whole, every time**: the relay's `turn:` servers
with the credential, `iceTransportPolicy` `relay`, `max-bundle`, `rtcp-mux` `require`,
Unified Plan and `gather_once`, at the connection and again at every restart.
`flutter_webrtc`'s `setConfiguration` builds a fresh `RTCConfiguration` from what it is
given, and libwebrtc's default for a field left out is `IceTransportsType.ALL`, so a restart
that sent only the new servers would bring host candidates back.

**Perfect negotiation, with an explicit rollback.** The device that receives a `join` calls
`negotiate()`, and the joiner answers (§N rule 4). The platform's `onRenegotiationNeeded` is
not used: adding the track fires it on the joiner too, which would turn every connection
into a collision. Every step runs in one queue, so a collision is exactly a remote offer
arriving while this device's own is outstanding. The polite device — the one whose id string
sorts lower, compared in lowercase — rolls its offer back and answers; the impolite one
ignores the offer and waits for the answer to its own. The rollback is an explicit
`setLocalDescription` of type `rollback`, because libwebrtc refuses a remote offer in
`have-local-offer` unless `enableImplicitRollback` is set, and `flutter_webrtc` has no way
to set it.

**What the channel is trusted for.** A description or a candidate batch is taken only when
the device the pairwise session authenticated is this connection's peer, its header names
the same device, the room is this one, the sender's `join_id` is the join this connection is
for, and `target_join_id` is this device's own join. Within that:

- a counter already taken is a retry's duplicate and is dropped;
- an offer whose counter is below the last one applied is superseded;
- an answer whose `answers_counter` is not the outstanding offer's is discarded.

**Candidates follow their description.** A batch waits until the description it belongs to
has been handed to the transport, because a device that has not yet seen an offer has no
connection to hold them. A received candidate that arrives before any remote description is
held — 32 at most — and applied after it, because libwebrtc drops a candidate it cannot
place. Local candidates are matched to the local description applied last by the `ufrag`
extension libwebrtc writes on every candidate line, and not by the platform's gathering
events, which mark no generation: a new gathering emits no `gathering` while the old one is
still running, and the session it stops still reports `complete`, late. A completion ends
the batch only once a candidate of the current generation has arrived, so `end` is best
effort, and nothing on the receiving side depends on it.

**An ICE restart keeps the connection** (§N rule 9). `restartIce(configuration)` applies the
new configuration, calls the platform's `restartIce()` and offers again, so the offer carries
new ICE credentials and gathers against the new allocation while the media keeps its old
path. Before anything has been negotiated there is nothing to restart, and the configuration
alone is applied; with an offer outstanding, the restart follows its answer; a restart the
polite device rolls back in a collision is offered again once the peer's offer is answered.
It is reported in progress until its own answer is applied.

**Resending** (§N rule 7). `resend()` sends the unanswered offer, or the answer last sent,
again with the counter it first carried, sealed afresh; a peer that already has it drops
the copy. The four attempts at 0, 2, 4 and 8 seconds are the call's schedule.

**What it reports**: `connecting`, `connected`, `disconnected`, `failed` and `closed`; that
its offer was answered; that its ICE restart is, or is no longer, in progress; and each
frame the transport did not send, with the reason. A device with no pairwise session is
refused `noSession` by the transport, and the connection reports it rather than starting one.
Since [ADR-077](decisions.md)'s open conflict was decided B on 2026-09-30, the room starts
that session on the durable path (Part 1, *Starting the sessions a call needs*), so
`noSession` reaching the call means the room has not reached that device yet. A platform refusal of a step of this device's own negotiation is `failed` for good,
and the call closes the connection. `close()` closes the platform connection at once and
gives back its hold, and the capture stays with the call's other connections: libwebrtc's
`RtpSender.dispose` releases only the sender's own reference to the track.

**The capture must follow the join's permission request.** `getUserMedia` asks for
`RECORD_AUDIO` by itself when it is missing ([ADR-078](decisions.md)), and nothing here asks
first, so the call takes its first hold only after the join has asked (§N rule 11, prompts 8
and 9).

Read on 2026-09-30 from the pinned sources. `flutter_webrtc` 1.6.2+hotfix.3, from the pub
cache: `MethodCallHandlerImpl.parseRTCConfiguration` and `peerConnectionSetConfiguration`,
`RTCPeerConnectionNative.defaultSdpConstraints` and `GetUserMediaImpl.getUserMedia`.
`io.github.webrtc-sdk:android:150.7871.01`, disassembled from the cached AAR: the
`PeerConnection$RTCConfiguration` constructor's defaults (`ALL`, `BALANCED`, `REQUIRE`,
`UNIFIED_PLAN`, `GATHER_ONCE`, `enableImplicitRollback` false), `SessionDescription$Type`
with `ROLLBACK`, and `RtpSender.dispose`, whose `MediaStreamTrack.dispose` is one
`nativeReleaseRef`. [webrtc-sdk/webrtc at
`m150_release`](https://github.com/webrtc-sdk/webrtc/tree/m150_release):
`P2PTransportChannel::MaybeStartGathering`, `OnCandidatesReady` and
`OnCandidatesAllocationDone` in `p2p/base/p2p_transport_channel.cc`, the last two ignoring
which session they come from; `BasicPortAllocatorSession::StopGettingPorts` and
`OnConfigStop` in `p2p/client/basic_port_allocator.cc`; `IceCandidate::ToString` in
`api/jsep_ice_candidate.cc`, which writes the `ufrag` through `BuildCandidate` in
`api/candidate.cc`; and, for the rollback's empty description, `CreateSessionDescription`
in `api/jsep.cc`, which builds a rollback without reading its text, beside
`JavaToNativeSessionDescription` in `sdk/android/src/jni/pc/session_description.cc`, which
reads the text whatever the type.

## The call

§N rules 4, 5, 7, 8 and 10, as phase 6 prompt 7 built them on 2026-10-01:
`VoiceCallEngine` in `lib/features/voice/application/`, one for the process, over the
room's read port, the signalling transport, *The connection* and the credential service,
composed in `lib/app/dependencies/voice_call_providers.dart`. It holds one call at a time
and writes no row. The application layer reads it as a stream of `VoiceCallState`: the
phase, each peer's status, the room text and, when the call ended or a join was refused, the
reason.

**A join**, in this order, and nothing is sent before step 4:

1. The room must be one this device may act in. One waiting for its state, forked, left,
   removed or not held refuses the join with that reason, before anything is minted.
2. The relay credential is minted (§N rule 9). No voice on the server, `429` with its retry
   time, and a mint that failed each refuse the join and say which.
3. The room starts every pairwise session the call will need and routes those requests
   into the outbox (*Starting the sessions a call needs*), and a 16-byte join id is drawn
   from the native core's CSPRNG.
4. A `participants_query` goes to every live device of every active member, this account's
   other devices included. After the first answer window — the schedule's first wait, 2
   seconds within 25 % — the `join` goes to the same devices, unless the answers name ten
   devices already in the call: then no `join` goes out (*The ceiling*).

**Presence.** A participant answers every copy of a query it receives, since a copy means
its answer was lost, naming itself and the devices it is connected or negotiating with. A
device not in a call answers nothing. An answer is a hint and opens or closes nothing: each
device it names that this device does not know, and that is a live device of an active
member as this device resolved them, becomes a peer it expects an offer from, shown as
connecting. The sender's own entry must name the account and the join the pairwise session
and the header gave it.

**The mesh.** A participant that receives a `join` opens a connection and offers; the joiner
answers each offer with a connection of its own (§N rule 4), and two devices that join at
once both offer and the polite one rolls back. A frame from a join id this device has not
seen, from a device it knows, tears the old connection down first. A `leave` of the current
join, a connection that closes, and one that fails after it connected each drop the device;
one that fails before it ever connected stays, *not reachable*.

**Retries** (§N rule 7, on the schedule of *Retries, and when a device is unreachable*). The
`join` and the query go again to each device that has not replied — an offer replies to a
`join`, and an answer or an offer to a query — and each negotiation is sent again by the
connection's `resend()` until it has connected. A copy of an offer this device already
answered means the answer was lost, and is answered again at once. A peer this device
expected, named by an answer or heard joining before its own `join` went out, that never
negotiated is *not reachable* once the `join`'s fourth attempt and answer window are over;
a negotiation that never connected is *not reachable* six seconds after its fourth attempt.
Nothing more is sealed to it until it sends a `join` again or the user asks to try again,
which sends this device's `join` to that one device four more times.

**Room text** goes once to every device this one is connected or negotiating with, and shows
here because it was sent from here. A call keeps 200 lines and drops them when it ends. Each
line spends one of the 32 frames this join may seal to each peer, the budget the
announcements and the negotiation draw on too — see ADR-077, *Open question, dated
2026-10-01*.

**The refresh.** At the credential's `refreshDueAt` the call asks for another, and a new one
restarts ICE on each connection with its configuration. The restart's offer is retried like
any other, but a restart nobody answers leaves the connection on its old path rather than
calling the peer unreachable.

**A refused frame.** A target the transport refuses as not live, or as past its 32 frames,
is sent nothing more in this call. One refused for a changed safety number is closed, and its
tile says so; every other refusal is retried by the next attempt. A peer that sends a major
version this build does not speak, or offers media this version has none of, is closed and
says so. A microphone or a platform connection that cannot be opened ends the call.

Not built: the relay-unreachable state of *The credential* — no connection connected within
15 seconds and every candidate pair failed — which the call would report in place of nine
peers one at a time; and every screen, which is prompt 9's. The microphone request and the
foreground service are built behind two ports, which nothing calls yet (phase 6 prompt 8,
[`platform-android.md`](platform-android.md), A call's microphone): the join asks, starts
the service and then joins, and the service stops when the call ends.

## The ceiling

§N rule 10 refuses an eleventh participant and states the reason to the user. The ceiling
is enforced here and by nothing on the server.

**Ten joined devices (D2).** The cost the ceiling bounds is per connection — each
participant carries one uplink for every peer, and the relay carries every stream twice —
and a connection is to a device, not to a person. A person who joins from a phone and a
tablet occupies two of the ten and appears as two tiles. In practice a person joins a call
from one device, which is why the copy reads *ten people*; the design canvas's *Call full*
artboard says "Ten people are already in it, and a call holds ten at most, because every
phone sends its audio to every other phone", and that sentence stays true under the
device-counted rule for every user who is not in two places at once.

A device decides for itself whether the call is full, from its own participant set, before
it sends its `join`: at ten it does not send one and shows *Call full*. Two devices
joining a nine-device call at the same instant both find room, so the refusal has to hold
on the receiving side too, and it has to hold the same way on every device at once —
there is no arbiter to ask.

**The tie-break is device id string sort**, the same basis §N rule 3 already uses for the
polite peer, and for the same reason: both ends compute it from the ids alone with no
round trip. A participant that holds more than ten joined devices keeps the ten whose
device ids sort lowest and offers nothing to the rest. Every participant reaches that set
from the same join announcements, so they converge without agreeing on anything, and the
eleventh device receives no offer from anybody, exhausts its retry bound and shows *Call
full* — which is exactly what it would see if the call had been full when it asked.

**As built, 2026-10-01.** A device's participant set before it joins is the answers to its
own `participants_query`, heard over the first answer window: at ten it sends no `join`, and
its call ends *Call full*. Each participant then applies the ten lowest against every device
it knows of, another participant's answer included: a newcomer outside them is offered and
answered nothing, and a device that finds itself outside them ends its call *Call full* the
moment it learns so, rather than when its retries run out. A connection to a device outside
them is closed, which is the rule taken literally and has a consequence the paragraph above
leaves unstated: a device that joins a full call without having heard its answers, and two
that join a nine-device call at once, take the seats of the participants whose ids sort
highest, and those leave the call *Call full*. The query before the join makes the first case
rare; the second is the race the rule exists for.
