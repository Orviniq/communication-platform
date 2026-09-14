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
     or a CPGSV001 group payload (a group's control state; see Groups)
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
uses a domain-separated hash of the account ID. Group IDs are random 256-bit values.
Voice room capability IDs remain backend UUIDs but are hashed into protocol contexts.

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
| `room.invite` | Voice-room capability and encrypted membership material | yes |
| `room.control` | Room metadata or removal event | yes |
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

## Receipts, typing, and presence

Delivery/read receipts name bounded explicit message-ID sets. A delivered receipt is
sent after durable local application, not merely socket arrival. A read receipt is sent
only after the conversation is visibly read and user privacy settings allow it.

Typing is an encrypted volatile signal containing conversation ID, boolean state, and a
short expiry. It is never queued. Presence uses the backend device subscription but the
meaning shown to users is conservative: online means a subscribed device currently has
a socket, not that the person is actively viewing a chat.

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
