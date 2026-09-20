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

**Nothing here is built.** No file under `lib/` implements a byte of it.

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

## What it replaces in the database

The Drift table `voice_rooms` — `local_room_id`, `capability_ciphertext`,
`metadata_ciphertext`, `live_state` — described a server room: a capability to hold, a
name the server stored, and a live count the server counted. None of those exists.
**It is deleted**, and four tables that mirror the group's take its place:

| Table | Mirrors | Holds |
|---|---|---|
| `room_states` | `group_states` | One row per room: the encrypted roster projection, the accepted revision, the state hash, the lifecycle |
| `room_control_events` | `group_control_events` | The accepted chain: one row per signed event, with the exact canonical bytes and signature, so this device can hand a transcript to a new member |
| `room_outbound_objects` | `group_outbound_objects` | Exact `CPVRV001` payloads owed to other devices, committed with the state change that produced them |
| `room_state_requests` | `group_state_requests` | Rooms whose state this device still has to ask a member for |

**A call writes no row at all.** Who is connected, who is speaking, who is muted, the peer
connections, the ICE state and the room's ephemeral text are in memory for the life of the
call and are gone when it ends. A call has no durable state because it has no state worth
recovering: a reconnecting device rejoins and re-negotiates from nothing.

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
`ServerConfiguration.signalBuckets`. An off-bucket blob is dropped in silence: there is no
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

## The credential

§N rule 9, and `POST /api/v1/me/relay` in
[`backend/realtime/API.md`](../../backend/realtime/API.md).

- **Before the button.** `voice_configured` from `GET /api/v1/config` — already parsed into
  `ServerConfiguration.voiceConfigured` — decides whether the deployment does voice at all.
  False means no call action is offered anywhere, which is *No voice on this server*. The
  route's `503 voice_unconfigured` is the same fact reached the hard way and is never a
  backoff.
- **Fetch at join, not at launch.** One `POST /api/v1/me/relay` when the user joins a call.
  Minting at startup would spend the `relay` scope, 60 a minute per account, on launches
  that place no call, and would hold a six-hour bearer credential for a relay the user may
  never reach.
- **Refresh under an hour.** Another mint once less than 3,600 seconds of `expires_in`
  remains. The default TTL is 21,600 seconds, so an ordinary call never refreshes.
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
- **A dead relay answers `200`.** The route reads a setting and never reaches coturn, so a
  credential minted against a relay that is down looks perfect and the call simply fails to
  connect. The client tells that apart from a quiet peer by *which* thing failed: when no
  connection reaches `connected` within 15 seconds of the first offer **and** every
  candidate pair failed, the relay is reported unreachable — *The call could not connect* —
  rather than nine people being reported unreachable one at a time.
- **`429 throttled`** carries `Retry-After`; the join action cools down for exactly that
  long and says so.

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
