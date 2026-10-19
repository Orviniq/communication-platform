# Application-message protocol

## Purpose and status

The backend routes opaque per-device blobs and intentionally has no conversation schema.
This document defines the encrypted version-1 application events carried inside the
cryptographic protocol. Exact deterministic-CBOR CDDL and golden byte fixtures MUST be
generated with the shared protocol package before implementation is considered stable.

## Layering

```text
logical event
  -> deterministic-CBOR application bytes (a DM, a group, or Saved Messages),
     or a CPGSV001 group payload (a group's control state; see Groups),
     or a CPVRV001 room payload (a voice room's control state; see Voice rooms)
  -> TransportPlaintextV1(real length, inner bytes, random padding)
  -> per-recipient Double Ratchet authenticated encryption
  -> EnvelopeV1 outer frame in an allowed backend bucket
  -> base64 in POST /api/v1/envelopes
```

The application event, sender, conversation, and content type are encrypted. The backend
sees the target device, timing, and final size bucket only. A group adds no layer of its
own: its bytes are encrypted separately for each recipient device, exactly as a DM's are.

## Common logical-event header

Every event has these authenticated fields:

| Field | Meaning |
|---|---|
| `v` | Protocol major version, initially `1` |
| `event_id` | 16 cryptographically random bytes; global deduplication identity |
| `conversation_id` | 32-byte conversation identifier |
| `kind` | Registered integer event kind |
| `sender_user_id` | Authenticated account UUID |
| `sender_device_id` | Authenticated device UUID |
| `sender_counter` | Monotonic per-device counter, persisted before send |
| `created_ms` | Sender wall-clock milliseconds for display, not authorization |
| `references` | Bounded list of event/message IDs this event depends on |
| `body` | Kind-specific deterministic-CBOR map |

The decrypted sender identity MUST match the device that authenticated the pairwise session.
Timestamps never grant permission and are clamped for display when implausibly skewed.
`sender_counter` detects sender-state rollback but does not create a global conversation
order and is never, by itself, a reason to reject a lower counter: delayed messages are
valid. Durable `event_id` uniqueness provides application deduplication; the Double
Ratchet message number and bounded skipped-key store provide cryptographic replay and
out-of-order handling. Within the retained event horizon, reuse of one sender counter
with a different event ID is quarantined as sender-state rollback. Reuse with the same
event ID is an idempotent duplicate.

DM IDs are a domain-separated hash of the sorted pair of account IDs. Saved Messages
uses a domain-separated hash of the account ID. Group IDs are random 256-bit values, and
so are voice-room IDs: there is no backend room to carry a capability ID, and a room's
32 random bytes are minted by the device that creates it (see Voice rooms).

## Event registry

| Kind | Purpose | Durable? |
|---|---|---|
| `message.create` | Text, attachment, or structured message | yes |
| `message.edit` | Replace editable content of an earlier own message | yes |
| `message.delete` | Best-effort remote deletion request | yes |
| `message.reaction_set` | Set or remove the sender user's reaction | yes |
| `message.pin_set` | Pin or unpin a message | yes |
| `receipt.delivered` | Explicit delivered message IDs | yes |
| `receipt.read` | Explicit read message IDs | yes |
| `typing.set` | Short-lived typing state | no, signal only |
| `profile.publish` | Profile version/key/material announcement | yes |
| `contact.master_verify` | User-signing-key signature over a verified peer master key | yes, own devices and optionally peer |
| `group.control` | Signed group create, membership, role, or metadata transition, carried as a `CPGSV001` group payload rather than an application-event kind (see Groups) | yes |
| `group.history_batch` | Reserved. A group's history policy is new messages only, so nothing re-shares past events with a new member | — |
| `history.transfer_manifest` | Authorize and describe own-device history transfer | yes |
| `history.transfer_batch` | Bounded own-device history content batch | yes |
| `device_log.gossip` | Latest verified contact device-log heads | yes |
| `room.control` | Signed voice-room create, membership or rename transition, carried as a `CPVRV001` room payload rather than an application-event kind (see Voice rooms) | yes |
| `room.signal` | Reserved. A call's join, leave, offer, answer, candidates, participant query and ephemeral text are `CPVSV001` payloads in volatile `signal` frames, never application events (see Voice rooms) | — |
| `session.repair` | Authenticated request/response for pairwise repair | yes |
| `protocol.notice` | Supported-version/capability announcement | yes |
| `contact.block_set` | Synchronize private block state to the user's other devices | yes, own devices only |

Unknown kinds are stored as unsupported encrypted events, bounded in size, and never
partially interpreted.

`contact.master_verify` contains the exact peer user ID, master-key bytes/fingerprint,
verification protocol version, and user-signing-key signature. It is created only after
successful out-of-band SAS/QR confirmation, synchronized to the user's own cross-signed
devices, and included in the recovery-protected identity material. It never makes a
server-supplied first-seen key trusted.

## Message creation

`message.create` contains:

- a content discriminator: text, attachment, image, system, or supported custom type;
- UTF-8 text/caption limited to 16,384 Unicode scalar values and 65,536 encoded bytes;
- optional reply target and bounded quote fallback;
- zero to 32 encrypted attachment descriptors;
- optional client accessibility metadata that contains no untrusted markup.

The common `references` list contains at most 64 IDs. Deterministic-CBOR input is limited
to 16 levels of nesting, 64 entries per map, definite lengths only, and the smallest
valid integer encoding. Duplicate map keys, tags not registered by this protocol,
indefinite-length items, non-finite floats, and invalid UTF-8 are rejected. The complete
transport plaintext must fit one backend envelope bucket after fixed suite overhead;
larger content is sent as an encrypted attachment rather than fragmented application
events.

Messages are immutable facts. Editing and deletion produce new events. HTML, executable
markup, remote image URLs, and arbitrary widget payloads are forbidden.

The sender writes the logical message and outbox jobs in one local transaction before
network work. Retrying may create duplicate backend envelopes after an ambiguous HTTP
response; recipients deduplicate by `event_id` and the sender treats the operation as one
logical message.

## Edits, reactions, pins, and deletion

- An edit is accepted only from the original sender identity and contains the target ID,
  replacement content, and a monotonically increasing edit revision. Concurrent valid
  edits resolve by `(revision, sender_counter, event_id)`.
- A reaction event is a set operation for `(target, reacting_user)`, not an increment.
  Its value is one normalized emoji grapheme or null. This makes replay idempotent.
- DM pins are shared conversation events; group pins require the role allowed by current
  group policy. Stars are local-only and never sent.
- Delete for me is a local tombstone. Delete for everyone is an authenticated request
  accepted only from the original sender or an explicitly authorized group moderator.
  It replaces local display with a tombstone and requests attachment-cache deletion; it
  cannot force a recipient to erase previously decrypted content.
- **Who changes a group message** ([ADR-096](decisions.md) D4 to D7). Each member deletes an
  own message for everyone. A `message.delete` from anyone else counts when the group's
  roster records its sender as the owner, or as an admin and the message's author as a
  member; a `message.pin_set` counts when the roster records its sender as the owner or an
  admin. An edit is accepted from the original sender only, and a group sends none. The
  server holds no role (`backend/CLIENT_CONTRACT.md` §F), so the sending phone checks the
  rule before it sends and each receiving phone checks it again when it folds the event,
  from its own `group_states` row.
- **Order.** The roles are those of the roster this device holds now, not those at the
  time of the event: an application event names no control revision, and the sender's
  clock is a display value. A delete or a pin the roles do not allow is kept as a candidate
  fact and not shown. A control event that changes a role re-folds the group's messages in
  the transaction that commits it, so a delete that arrived before the promotion that
  allows it takes effect then, and a demoted admin's deletes and pins stop counting. A
  role counts as recorded whatever the membership: an admin who leaves keeps the deletes
  made while a member.

## Receipts and typing

Delivery/read receipts name bounded explicit message-ID sets. A delivered receipt is
sent after durable local application, not merely socket arrival. A read receipt is sent
only after the conversation is visibly read and user privacy settings allow it.

Typing is an encrypted volatile signal containing conversation ID, boolean state, and a
short expiry. It is never queued.

Typing and the online status are built (ADR-098, Accepted 2026-10-19) as one payload, `CPPSV001`,
sent in volatile `signal` frames. Nothing about them reaches the server except 1024-byte blobs it
already relays and drops when the target has no socket.

- **One reader.** `SignalRouter` is the only subscriber of the socket's inbound blobs. It opens each
  blob once and routes it by the first 8 bytes of the plaintext: `CPVSV001` to voice, `CPPSV001` to
  presence. A frame with a known magic is committed before its channel reads the rest. An unknown
  payload is left uncommitted, so a durable envelope the relay replays as a signal still opens on
  the durable path; and a `CPPSV001` or `CPVSV001` arriving in a durable envelope is refused there.
- **The payload.** `"CPPSV001" || version:u8 (1) || kind:u8 || deterministic CBOR`. The header names
  the sender user and device, which must be the ones the session authenticated, a random
  `instance_id` for the process and a counter that rises within it; a frame of the same instance
  whose counter is not above the newest is dropped. The kinds are `watch` (a conversation and a
  `lease_ms` of 40,000), `here` (the answer to a watch, saying whether the device types),
  `typing` (a conversation, active or not, a `ttl_ms` of at most 15,000) and `gone` (the device left
  the foreground, or turned its status off). Every frame is a 1024-byte blob.
- **Who may send and receive.** Only verified peers with a ready pairwise session, never the user's
  own devices, and only for a conversation both accounts hold: a direct chat with that peer, or an
  active group of at most 32 members. Saved Messages, a conversation this phone does not hold, a
  blocked account and an unverified one get nothing and are answered nothing.
- **Watching.** A phone in the foreground with the switch on sends a `watch` of the chat on
  screen to the peer's live devices (in a group, to at most 2 devices of each member), renewed every
  25 s. A device in the foreground answers each accepted watch with `here` and keeps a lease for the
  asker for the lease time, never above 60 s; in the background it answers nothing. Leaving the
  foreground sends the pending typing stops and `gone` to every device with a live lease in either
  direction, and the socket closes after that, for at most 500 ms.
- **Typing.** `typing` goes only to devices whose watch of that conversation is under 40 s old: the
  first edit sends it, an edit every 10 s repeats it, 5 s without an edit, a send, clearing the
  composer, leaving the chat and leaving the foreground stop it, and at most one frame per
  conversation leaves every 5 s. The receiver shows it for 15 s after the latest active frame, and
  ends it at once on a stop, on that device's `gone` and when a message of that sender appears in
  that conversation. A group names the members who type by the name on their messages. Typing is
  never queued and is not the `typingSet` application event, which is never sent and which the
  durable inspector refuses.
- **Online and last seen.** A device is online from any accepted `watch`, `here` or `typing` until
  40 s after the latest, or until its `gone`; an account is online while one device is. The last
  seen is this phone's own clock at the latest presence frame it accepted from the account's newest
  device. It is kept in the encrypted database (`presence_devices`, schema 26), never sent, and
  only what this phone saw: a durable message does not move it.
- **The bound on dropped frames.** A frame the server drops leaves a dead skipped key on the target's
  session for good. A `watch` to a device not heard from in 40 s is a probe: at most 4 since it was
  last heard from and 8 a day, at most one a minute, and at most 8 live frames go to a device between
  two frames from it. The ledger is durable, so a restart refills nothing. A session that reaches its
  skipped-key bound is repaired by the authenticated repair, and nothing is lost.
- **The switch.** "Show my online status" is a preference of this phone (`presence.share.v1`), on by
  default. Off, the phone sends no `watch`, `here`, `typing` or `gone` (one `gone` with reason 2 at the
  moment it is turned off aside), shows nobody's online state, last seen or typing, and deletes the
  last seen it holds; a receiver of that `gone` deletes the sender's. It still opens and commits every
  presence frame it receives, which spares the sender a dead key, and discards it.

**No claim the client cannot observe.** The gateway holds no presence and offers no subscription
frame (server ADR-0022), so no screen says a peer is "offline": a peer this phone has not heard from
shows nothing, and the status is a lower bound (a peer online while this phone was not watching, a
member this user has not verified and a group over 32 members show nothing). The chat header's old
presence line was structurally false for exactly that reason. A voice call reports a participant
present because a connection to them is open, which is observed rather than asserted.

## Blocking

Blocking is private account state, not a backend ACL. `contact.block_set` contains the
target user ID, blocked boolean, monotonic revision, and event ID and is encrypted only
to the user's other live devices. It remains in each device's local history and is never
sent to the blocked contact.

For a blocked DM sender, the client still authenticates/decrypts enough to prevent queue
abuse, records the envelope as processed, and acknowledges it, but does not persist or
display message content, send receipts, subscribe/share presence, show typing, or create
notifications. Blocking does not claim to stop the sender from submitting ciphertext.
In shared groups, a blocked author's control events are still verified and applied; their
ordinary content may be locally collapsed without corrupting group state.

## Groups

A group is a set of pairwise sessions (`backend/CLIENT_CONTRACT.md` §F, server ADR-0001).
The server holds no group object, roster, epoch, or group key. The roster exists only in
its members' clients, and every change to it is a control event that one member's device
signs and every other member checks. No group key material is uploaded.

### Group messages

A group message is an ordinary application event whose `conversation_id` is the group's
random 256-bit ID. It is encrypted once for every live device of every active member and
once for every other live device of the sender, one pairwise envelope each, under one event
ID. The recipients are read from the group's accepted state when the copies are sealed, not
when the message is written, so a member removed in between gets no copy. A device accepts
a group event only from an active member of a group it holds, and only while its own account
is an active member. An event for a group it does not hold, or from a member it has not yet
seen added, asks the sender for the group's state (Group payloads) and waits for the answer.

A message is sent only when none of its copies is still owed. Until then the conversation
shows how many copies the server has accepted, and a copy for a device the server reports
as gone leaves the count.

### Group read receipts

Decided by ADR-091 (Accepted, 2026-10-14) and built. The read time is kept in
`receipts.read_at_ms` (schema 24), and the sender sees it in the reader list of an own message
(`ui-specification.md` §9).

- **Read receipts only.** A group sends `receipt.read` and never `receipt.delivered`. The
  second tick means read, and a delivered state has no mark of its own.
- **One sender per receipt.** A group read receipt names messages of one sender only, at
  most 64 of them. A device that reads messages of several senders sends one receipt for
  each sender. A receipt event that names messages of two senders is refused before it is
  sealed.
- **Audience.** The recipients of a receipt come from the messages it names
  (`application_event_targets` and `messages.sender_user_id`), not from the roster as a
  whole. The receipt is sealed for every live device of that sender, when that sender is an
  active member, and for every other live device of the reader. When the sender is not an
  active member, it is sealed for the reader's other devices only. No other member gets a
  copy.
- **When.** A read receipt is sent on the triggers of a direct conversation: the
  conversation becomes visible while the application is in front, and an unread message
  arrives while it is visible. It names exactly the messages the local read mark cleared.
- **Admission.** A receiving device admits a group receipt only from an active member, as
  any group event (Group messages). It ignores a receipt from the sender of the message it
  names, and a receipt changes only messages of the conversation it was sent in.
- **Read time.** The read time of one device is the `ordering_ms` of the earliest
  `receipt.read` from that device that names the message: the reader's clock when it
  recorded the read, corrected as a message time is: a clock up to 60 seconds behind the
  conversation's newest message is moved to just after it. It is a display value, never an
  authority. An `ordering_ms` of 0 marks an implausible clock, and the time is unknown. A
  clock further behind is stored as it came, and the reader list shows the message's own time
  in its place: a read never shows before the message it reads.
- **Readers.** The readers of one message are the users with a read row for it in `receipts`,
  each once, at the earliest read time over their devices. A member who only delivered the
  message is no reader, and a group sends no delivered receipt. Only the sender of a message
  gets the receipts that name it, so only the sender has readers to list (ADR-091 D3). The client reads
  them from its own database and asks the server nothing.
- **Privacy.** A receipt is encrypted like any application event. The server sees one more
  padded envelope from the reader's device to each device of the sender, as for a receipt in
  a direct conversation, and not its content. Other members learn nothing about who read
  the message.
- **No wire change.** These rules add no event kind, no field and no server change.

### Control events

The shared native core builds each control event as deterministic CBOR and signs it with
the signing device's Ed25519 key (bytes 0–31 of its `ik_pub`) over
`"chat:v1:group-control" || u32be(length) || canonical_event`. Dart never builds or parses
that CBOR and never holds the key. An event carries:

| Field | Meaning |
|---|---|
| protocol version | `1` |
| `event_id` | 16 random bytes |
| `group_id` | The group's 32-byte random ID |
| `revision` | `1` for the create event, then exactly one more than the event it follows, at most `0xffffffff` |
| previous state hash | Absent at revision 1; otherwise the state hash of the event it follows |
| signer user and device | The account and device whose key signed it |
| `created_ms` | Sender wall-clock time, for display only |
| operation | One of the five below |

Each accepted event commits the group to the state hash
`SHA-256("chat:v1:group-control-state" || u32be(length) || canonical_event)`, and the next
event names that hash, so a group's accepted events are one hash chain: two devices at the
same revision with the same hash hold the same history. An event is at most 16,384 bytes,
and a decoded event that does not re-encode to exactly the signed bytes is refused.

| Operation | Value | Body | Who may sign it |
|---|---|---|---|
| create | `1` | Name, description, invitation policy, history policy, and every member with a role | The one owner it names; up to 50 members |
| add members | `2` | User IDs, each added as a member | Whoever the invitation policy allows: the owner, the owner and admins, or every member. A removed or departed member may be added again, and the group stays at 50 active members or fewer |
| remove member | `3` | One user ID | An admin removes a member; the owner removes an admin or a member; nobody removes the owner. A member naming itself is leaving, which the owner may do only as the last active member |
| change role | `4` | One user ID and a role | The owner. Naming `owner` hands the group over: the target becomes the owner and the signer becomes an admin |
| rename | `5` | Name and description | The owner or an admin |

A name is at most 100 Unicode scalar values and a description at most 1,000. The invitation
and history policies are fixed by the create event, and no later event changes them. This
build creates groups with owner-and-admins invitation and new-messages-only history,
because nothing here re-shares earlier messages with a new member.

A receiving device refuses an event whose signing device is not in its account's
authenticated live device list, whose signature does not verify under that device's key, or
whose chain link does not match. It then decides against the roster the event builds on,
never against its own lifecycle:

- the next revision, naming the held hash, from a signer that roster authorizes, is applied;
- the held revision with the held hash is a duplicate;
- a signer the roster does not authorize is recorded in `quarantine` and the event dropped,
  so one member cannot stop a group for everybody;
- a second event at a revision already accepted, or one naming a different hash, is a fork:
  the group is quarantined and the client never picks a branch;
- a later revision, or an event after the first for a group this device does not hold,
  asks the sender for the group's state; and
- a create event for a group this device is not in is ignored.

### Group payloads

Control state travels in ordinary pairwise envelopes as a group payload:

```text
"CPGSV001" || kind:u8 || body
  kind 1, control:    entry
  kind 2, request:    group_id[32] || have_revision:u32be || have_state_hash[32]
  kind 3, transcript: group_id[32] || base_revision:u32be || base_state_hash[32]
                      || count:u16be || count x entry
entry = signer_user_id[16] || signer_device_id[16]
        || canonical_length:u32be || canonical_event || signature[64]
```

A revision of zero carries an all-zero hash, and a payload is at most 200,000 bytes.

- **Control.** A device sends the event it signed to every member who held the state the
  event builds on — the member a removal removes included, so that member learns of it —
  and to its own other devices. Only the signing device may deliver a control payload; a
  copy of somebody else's event travels only inside a transcript.
- **Transcript to a new member.** A member an event adds is sent the whole transcript from
  revision 1 instead, and replays and checks every entry. A transcript that would not fit
  one payload means the member is not added.
- **State request.** A device that may be missing events names the state it holds. Only an
  active member is answered, and only by a device that holds an unquarantined state as an
  active member itself. The answer goes to the asking device alone: every accepted event
  after the asker's state, an empty transcript when the asker is current, or the whole
  transcript when the asker's state is not one this device passed through, so that the
  asker finds the fork for itself.
- **Queue gap.** After a `pruned_through` gap every active group waits for its state. The
  device repairs its pairwise sessions with one member through the authenticated repair
  path, asks that member, and turns to the next member in role order if no answer comes.
  Sending and group changes are withheld until an answer arrives. A group with no other
  active member has nobody to ask and stops waiting at once.

### Own-device history

Own-device history transfer uses a cross-signing-authorized manifest followed by bounded
`history.transfer_batch` events over ordinary per-device envelopes. It transfers content
only, preserves original event IDs for deduplication, states source completeness, and
never contains Double Ratchet state or a group's control state. A mailbox `pruned_through`
gap is repaired through the authenticated session-repair path and a member's answer to a
state request (Group payloads), not by replaying history batches.

## Voice rooms

A voice room is client state exactly as a group is, and a call inside it is a full mesh
of WebRTC audio keyed by DTLS-SRTP between each pair of devices. The server holds no
room, no roster, no name and no participant list: it mints a relay credential at
`POST /api/v1/me/relay` and relays `signal` frames, and that is the whole of its part
(`backend/CLIENT_CONTRACT.md` §N, server ADR-0021).

Two payload formats carry it, and both are specified in
[voice-signalling-v1.md](voice-signalling-v1.md), which is binding:

- **`CPVRV001`**, the room's signed control events, in ordinary **durable** envelopes.
  It mirrors `CPGSV001` above — the same three kinds, the same hash chain, the same
  transcript, state-request and queue-gap rules — under its own signing domain
  `"chat:v1:room-control"` and its own state-hash domain `"chat:v1:room-control-state"`,
  so that no event of one kind can be replayed as the other. A room's id is 32 random
  bytes, its name travels inside its control events, and every active member has the same
  authority to add, remove and rename. There is no owner and no admin.
- **`CPVSV001`**, the call's signalling — join, leave, offer, answer, candidates,
  participant query, participant answer and ephemeral room text — in **volatile** `/ws`
  `signal` frames, padded to 1024, 4096 or 16384 bytes.

**A payload is accepted only from the channel it belongs to.** A `CPVRV001` arriving in a
`signal` frame is dropped, and a `CPVSV001` arriving in a durable envelope is dropped.
Without that rule the volatile channel is a way to write durable state, and the durable
queue is a way to replay a call's signalling hours later.

**A room starts the sessions its call needs** ([ADR-077](decisions.md), decided B on
2026-09-30). A volatile frame never starts a pairwise session, because a first frame the
relay drops would leave a session only its sender holds. So a device sends a `CPVRV001`
state request, sealed to one device alone, to each live device of each active member it
has no session with. On accepting a change that gives it the room or adds a member, it
sends one only to the devices that sort above its own, so a pair starts one session; once
a day, and before a call joins, it sends one to every device still missing one. The durable
queue holds that first message until the device fetches it, and the answer is the
session's second message. A request for a room a device does not hold, or naming a later
revision than it holds, is answered with a request back, which is how a member's new
device learns its rooms. The rule is in
[voice-signalling-v1.md](voice-signalling-v1.md), Starting the sessions a call needs.

## Multi-device rules

- A user's devices are independent cryptographic recipients.
- The sender fans out to peer devices and their own other devices.
- Own-device sync uses the same logical event ID, preventing duplicates.
- Drafts are local by default. A future encrypted draft-sync event requires a separate
  ADR.
- Read state is merged as an idempotent set of explicit IDs; it is not inferred from one
  device's queue sequence.
- A revoked device leaves every fan-out, a group's included, once it is reported in
  `stale_devices` or drops out of its account's authenticated device list, and its
  sessions are deleted.
- Each ordinary encrypted event may carry bounded `device_log.gossip` head tuples. A
  non-extending head or two valid heads for the same sequence triggers the global fork
  state; it is never resolved by arrival order.

## Ordering

The backend sequence is per recipient device and is only a drain checkpoint. It is not a
global chat sequence. Presentation order uses validated sender time with deterministic
ID tie-breaking and preserves explicit reply/edit dependencies. The client may annotate
late arrivals but MUST NOT rewrite cryptographic history to manufacture a false global
order.

## Padding and bounds

Padding is encrypted, not appended to ciphertext. `EnvelopeV1` is:

```text
version:u8 || suite:u8 || ratchet_header_length:u16be
  || ratchet_header
  || DoubleRatchetAEAD(
       real_inner_length:u32be || inner_bytes || CSPRNG_padding,
       associated_data = outer_fixed_fields || ratchet_header || recipient_device_id
     )
```

The encoder obtains the serialized ratchet-header size without advancing ratchet state,
chooses the smallest backend bucket in `1024, 4096, 16384, 65536, 262144` that can hold
the fixed outer fields, ratchet header, AEAD tag, length prefix, and inner bytes, and
fills the remaining authenticated plaintext with CSPRNG bytes. It then advances and
persists the send ratchet exactly once while producing the ciphertext. The outer frame
contains no real content length; ciphertext consumes the remainder of the bucket.

The decoder rejects an unknown version/suite, non-bucket total length, impossible header
length, failed AEAD, or inner length beyond the authenticated plaintext before allocating
kind-specific structures. The authenticated real length is used only after decryption to
remove padding. Application content is not compressed by default because compression
before encryption can create size side channels and decompression abuse.

## Compatibility

Event kinds and fields are centrally registered. Removing or changing a field requires a
new major protocol version. Additive optional fields require fixtures proving older
clients ignore them safely. Unsupported critical capability requirements prevent send
and show an upgrade explanation instead of downgrading security.
