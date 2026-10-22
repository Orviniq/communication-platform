# CLIENT_VOICE_ROLES.md — Roles in voice rooms: room protocol version 2

This document binds the Flutter client exactly as [`CLIENT_CONTRACT.md`](CLIENT_CONTRACT.md)
does, and the contract routes here from §N rule 12. It specifies client behaviour only.
**Nothing in it adds, changes or needs a server route, a column, a setting, a rate scope or a
gateway frame**: the server still holds no room, no roster, no role and no participant list
([ADR-0021](../architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md) stands),
and everything below travels as ordinary envelopes and `signal` frames. The decision is
recorded in
[ADR-0031](../architecture/decisions/0031-online-status-stays-client-protocol-over-signal-frames.md);
the work it gives the client is [`../CLIENT_WORK.md`](../../CLIENT_WORK.md).

It is a **complete delta against
[`frontend/docs/voice-signalling-v1.md`](../../frontend/docs/voice-signalling-v1.md)**, which
stays binding for version-1 rooms and for every rule this document does not name. The client
developer folds it into that document as its version-2 part, and records a client ADR that
supersedes client ADR-077's D1 — *every active member has the same authority* — for version-2
rooms.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be read as described in
RFC 2119 and RFC 8174 when, and only when, they appear in capitals. Where this document and a
client document under `frontend/docs/` disagree about what it specifies, this document is
authoritative.

## 1. What changes, and what stays

**Changes.** A room of protocol version 2 has one owner, admins and members (§2). Every change
of membership, of a role and of the name is a signed control event in the room's hash chain
(§3), and the role operation takes the value 5 that version 1 reserved for it. Every existing
version-1 room whose creator — the signer of its revision 1 — is still a member is upgraded,
with the creator as its owner, once every member's devices can read version 2 (§4); a room whose
creator has left keeps version 1. Inside a call, muting a participant, removing one from the
call and ending the call for everyone are call signals (§5).

**Stays**, unchanged and still bound by `voice-signalling-v1.md` and `CLIENT_CONTRACT.md` §N:

- rooms are standalone: no group and no direct conversation hosts a call (client ADR-077 D3).
  This is not group voice chat;
- a call holds at most **ten joined devices**, by the device-id tie-break (§N rule 10);
- one connection per device pair, relay-only ICE, the polite peer by device-id order, the
  credential and its refresh, and removal on a signed control event (§N rules 1 to 9 and 11);
- the bodies of signalling kinds 1 to 8, the four attempts at 0, 2, 4 and 8 seconds, and the
  budget of 32 sealed frames to each peer in one call (ADR-077 D5 and D8);
- a room's 50 members, its two signing domains, its hash chain, its 16,384-byte event bound,
  the six outcomes of applying an event, the four delivery rules, the starting of the sessions
  a call needs, and the rule that a payload is accepted only from the channel it belongs to.

## 2. Roles, and who may do what

A room of version 2 has exactly one **owner**; any number of **admins**; and **members**. The
values are the group's: 0 owner, 1 admin, 2 member.

| Permission | Owner | Admin | Member | Who grants it |
|---|---|---|---|---|
| Join a call and speak | yes | yes | yes | Whoever adds the member: the owner or an admin |
| Add members | yes | yes | no | The owner, by making a member an admin |
| Remove a member from the room | yes | yes | no | The owner, by making a member an admin |
| Remove an admin from the room | yes | no | no | Nobody: the owner's alone |
| Remove the owner | no | no | no | Nobody |
| Rename the room | yes | yes | no | The owner, by making a member an admin |
| Make a member an admin, or an admin a member | yes | no | no | Nobody: the owner's alone |
| Hand the room to another member | yes | no | no | Nobody: the owner does it, and becomes an admin |
| Mute a participant | admins and members | members | no | The owner, by making a member an admin |
| Remove a participant from the call | admins and members | members | no | The owner, by making a member an admin |
| End the call for everyone | yes | yes | no | The owner, by making a member an admin |
| Leave the room | as the last active member only (§3.4) | yes | yes | — |

Nobody acts on themselves through a role: a participant mutes their own microphone locally, as
today, and no frame carries it; a member leaves with a removal of themselves. The set is fixed by
the role and is not granted right by right
([`REJECTED_PROPOSALS.md`](../../REJECTED_PROPOSALS.md) 24).

## 3. The control events of version 2

### 3.1 The canonical event

The event of `voice-signalling-v1.md` § "The event", unchanged in its form: one ten-key
deterministic-CBOR map, built and signed by the shared native core under the signing device's
Ed25519 key, never by Dart. Version 2 changes key 0 to `2` and admits two operations.

```cddl
room-event = {
  0: 1 / 2,                       ; protocol version of this event
  1: bstr .size 16,               ; event_id, not all zero
  2: bstr .size 32,               ; room_id, not all zero
  3: 1..4294967295,               ; revision
  4: bstr .size 32 / null,        ; the state hash of the event it follows; null at revision 1 only
  5: bstr .size 16,               ; signer user, not all zero
  6: bstr .size 16,               ; signer device, not all zero
  7: 0..8640000000000000,         ; created_ms, display only
  8: 1..6,                        ; operation; 1 to 4 at version 1
  9: body,
}
body = create / add / remove / rename / change-role / upgrade
create      = { 0: name, 1: [2*50 bstr .size 16] }   ; op 1: strictly ascending, names the signer
add         = { 0: [1*49 bstr .size 16] }            ; op 2: strictly ascending
remove      = { 0: bstr .size 16 }                   ; op 3: the signer itself means leaving
rename      = { 0: name }                            ; op 4
change-role = { 0: bstr .size 16, 1: 0..2 }          ; op 5, version 2 only: 0 owner, 1 admin, 2 member
upgrade     = { 0: 2 }                               ; op 6, version 2 only: the version upgraded to
name = tstr                                          ; 1 to 100 scalar values, at most 400 bytes
```

The signature is Ed25519 over `"chat:v1:room-control" || u32be(length) || canonical_event`, and
the state hash `SHA-256("chat:v1:room-control-state" || u32be(length) || canonical_event)`, both
exactly as version 1: the version is inside the signed bytes, so no event of one version can be
read as the other, and no new domain is needed. The core MUST refuse, when it seals and when it
opens:

- a version other than 1 or 2 (*unsupported version*);
- operation 5 or 6 in a version-1 event, or any operation above 6 (*unsupported operation*);
- revision 1 without operation 1 or with a previous hash, or operation 1 at any other revision;
  an all-zero id; ids out of strict order; a create that does not name its signer; a role above
  2; an upgrade whose body is not `{0: 2}` (*malformed*);
- an encoding other than its own (*non-canonical*).

### 3.2 The operations, and who may sign each

| Operation | Value | Version 1 | Version 2 |
|---|---|---|---|
| create | 1 | The creator; every member has the same authority | The creator, who is the **owner**; every other member it names is a **member** |
| add members | 2 | Any active member | The owner or an admin; each account added is a member; at most 50 active members after |
| remove member | 3 | Any active member; naming itself is leaving | An admin removes a member; the owner removes an admin or a member; nobody removes the owner. Naming itself is leaving, which the owner may do only as the last active member |
| rename | 4 | Any active member | The owner or an admin |
| change role | 5 | Reserved; refused | The owner. The target is another active member and not the owner. Naming 1 or 2 sets the target's role, and naming the role it holds is refused. Naming 0 **hands the room over**: the target becomes the owner and the signer an admin |
| upgrade | 6 | Refused | Only on a version-1 state, signed by its derived owner (§4.1); the room becomes version 2 |

These are the group's rules of `frontend/docs/message-protocol.md` § "Control events", with the
group's invitation policy fixed at *owner and admins*, which is the policy every group this
client creates carries.

**Which version a new room has.** A device that implements this document creates a room at
version 2 when every live device of every account its create names has announced version 2 or
above to it (§4.2), and at version 1 otherwise, so that no invitee is handed a room it cannot
read. A version-1 room it creates is upgraded under §4.3 once negotiation completes, with its
creator as the derived owner; until then its members have the equal authority of version 1, and
the room info says so (§4.3).

### 3.3 Applying an event

A receiving device decides the chain first, exactly as version 1 does: an event whose signing
device is not in its account's authenticated live device list, whose signature fails, or whose
link does not match is refused; a duplicate is a duplicate; a second event at an accepted
revision, or one naming a different hash, is a **fork** and quarantines the room; a later
revision asks for the room's state. Only an event that passes the chain is judged against the
roster it builds on, and there **the version is part of the authorization**:

- a version-1 event is authorized only on a version-1 state, by the rules of version 1;
- a version-2 create starts a version-2 room;
- an upgrade is authorized only on a version-1 state, from its derived owner;
- a version-2 event of any other operation is authorized only on a version-2 state, by the table
  of §3.2.

An event that fails the authorization is recorded in `quarantine` and dropped, and the room goes
on — "a signer the roster does not authorize". So a version mismatch never turns a fork into a
drop, and never stops a room for everybody. A device replaying a transcript applies its version-1
events under version 1, the upgrade, and the rest under version 2, which is how a member's new
device arrives at the same roles as everyone else.

### 3.4 When the owner leaves, and when the owner is gone

- The owner MAY leave only as the last active member. While others remain, the room info offers
  the owner **Hand over and leave**: it signs a change of role naming the chosen member with role
  0, then, once that is committed, the removal of itself, which it now signs as an admin.
- Nobody can remove the owner.
- An owner whose account is erased, or whose every device is revoked, can no longer sign anything:
  the room keeps its admins and members, the admins keep adding, removing and renaming, and nobody
  can make or unmake an admin. The remedy is a new room. A client that reads the owner's identity
  as gone says so in the room info: "@x can no longer manage this room. Admins can still add and
  remove members."

## 4. Existing rooms: the migration

### 4.1 The derived owner

Every device derives the owner of a version-1 room from its accepted chain, the same way: **the
signer of revision 1, when that account is an active member** of the state the upgrade builds on.
When it is not, the room has no derived owner and is never upgraded: it keeps version 1, and with
it every member's equal authority, and members who want roles make a new room. There is no
successor. Version 1 lets any member remove any other, so a successor would let a member who
removed the creator become an owner nobody can remove
([`REJECTED_PROPOSALS.md`](../../REJECTED_PROPOSALS.md) 28).

At the upgrade, the derived owner becomes the owner and every other active member a member.

### 4.2 Version negotiation: the announcement, `CPVRV001` kind 4

A device that implements this document tells every device it shares a room with:

```text
payload = "CPVRV001" || 04 || room_protocol:u8      ; 10 bytes; room_protocol = 2 for this document
```

- It is an ordinary durable envelope, padded to 1024. A payload of any other length, or with a
  version of 0, is refused.
- **When it is sent.** Once, at the first start of a build that implements this document, to
  every live device of every active member of every room the device holds, its own other devices
  included; and to every device it later starts a room session with or first holds as a member
  device of a room. A device sends it to a given device id once, and again only when it may have
  been lost — an envelope is pruned after `envelope_ttl_days` unread: a device whose negotiation
  for a room waits on a member device sends that device its own announcement, at most once a day,
  and a device that receives an announcement from a device it has not announced to in the last
  24 hours answers with its own. A later build that implements a higher version announces to
  every device again.
- **What a receiver keeps.** For each live device of an active member of a room it holds, the
  highest version that device announced; an announcement from any other device is acknowledged
  and not kept. A version never goes down: a reinstall is a new device id, and Android refuses an
  older build over a newer one.
- **Negotiation is complete** for a room, on one device, when every live device of every active
  member — its own other devices included, and each list as this device last authenticated it —
  has announced version 2 or above to it.

A build that predates this document cannot decode kind 4 and refuses it as a payload it cannot
read — quarantined and acknowledged — and nothing happens to the room (§4.5).

### 4.3 The upgrade

- **Who signs it.** Only the derived owner's **designated device**: the live device of that
  account whose device id sorts lowest as a lowercase string — the order §N rule 3 already uses.
  Every device of the account computes it from the account's device list alone, so no two of them
  can both be designated. It signs the upgrade by itself, once it holds the room; no other device
  does.
- **When.** Once negotiation has been complete on the designated device for one hour, and is
  still complete after a fresh read of every member's live devices. The hour lets the burst of
  announcements a new build sends reach the devices that are online, so that they stop signing
  version-1 events before the upgrade exists.
- **Before it.** In a room with a derived owner, a device on which negotiation is complete MUST
  NOT sign a version-1 event, apart from its own account's leave. Room info says: "Owner and admin
  roles start once every member's app has been updated." — followed, while negotiation is not
  complete, by "Waiting for: @x, @y." A room with no derived owner says instead: "This room keeps
  equal rights for every member, because its creator has left. Make a new room to have an owner
  and admins."
- **A fallback.** When negotiation has been complete for 24 hours on another device of the
  derived owner and the room is still at version 1, that device offers **Turn on roles now**,
  and a tap signs the upgrade from it. This covers a designated device that is lost or switched
  off.
- **Never** in a room this device holds quarantined, is waiting on the state of, or is not an
  active member of, and never in a room with no derived owner.
- **What it costs.** An upgrade that crosses another change — a member's leave, or an event from a
  device that had not yet learned negotiation was complete — forks the room, exactly as any two
  concurrent changes always have: the room is quarantined and no client picks a branch. The rule
  that would pick the upgrade instead is rejected
  ([`REJECTED_PROPOSALS.md`](../../REJECTED_PROPOSALS.md) 27): it would let an owner who was just
  removed undo the removal by racing an upgrade at the same revision.

### 4.4 The forced update

- **No room upgrades while any of its member devices cannot read version 2.** Negotiation is the
  whole gate, and there is no "upgrade anyway"
  ([`REJECTED_PROPOSALS.md`](../../REJECTED_PROPOSALS.md) 26).
- **A version-2 room's calls speak signalling version 2** (§5.1). A device that speaks only
  version 1 cannot take part. A version-1 `join` or `participants_query` for a version-2 room,
  from a live device of an active member, is answered once for that sender's join with a
  version-2 `participants` frame, so that the sender's own app says why: a build that predates
  this document reports "{name}'s app speaks a version of calls this one does not, so there is no
  audio between you. One of you needs to update."; a later build that has not yet applied the
  upgrade asks the sender for the room's state.
- **Adding an account whose devices have not all announced version 2** to this device is allowed,
  once the inviter has been told: "@y's app may need an update before @y can see this room." Until
  they announce, the room info marks @y **Needs the app update**.
- **A device enrolled with a build that predates this document** never holds a version-2 room: it
  cannot open the room's events, refuses each envelope that carries one, and the room never
  reaches it.

### 4.5 What a client that predates this document does

| It receives | It does | What happens to the room |
|---|---|---|
| `CPVRV001` kind 4 | Refuses an undecodable room payload: quarantined and acknowledged | Nothing |
| A version-2 control event, or a transcript holding one | Fails the event's integrity check, refuses the envelope: quarantined and acknowledged | Nothing. No room it holds has one: a room it is in never upgrades (§4.4) |
| A version-2 signalling frame | Drops it, and its call says the peer's app speaks another version | Nothing |

So a client that predates this document never forks a room and never quarantines one, and its
user is told by its own call screen when a version-2 room's call shuts it out.

## 5. In-call actions

### 5.1 The signalling version follows the room

A device seals every `CPVSV001` frame for a room with the version of the room it holds: 1 for a
version-1 room, 2 for a version-2 room. The framing is unchanged —
`"CPVSV001" || version:u8 || kind:u8 || deterministic-CBOR body`, the same header keys 0 to 5, 6
and 7 reserved, body keys from 8, every key required and no other allowed, and the same buckets.
A receiver:

- refuses a version-2 frame for a room it holds at version 1, and asks the sender's device for the
  room's state, because it is behind — within the 64 open state requests of
  `voice-signalling-v1.md`, so a stream of such frames opens no more than one request a room;
- refuses a version-1 frame for a room it holds at version 2, and answers as §4.4 says.

### 5.2 The kinds version 2 adds, and the leave reasons

```cddl
mute       = { header, 8: bstr .size 16, 9: bool }                    ; kind 9: target account; true mutes, false lets them speak
remove     = { header, 8: bstr .size 16 }                             ; kind 10: target account, removed from this call
end-call   = { header }                                               ; kind 11: the call ends for everyone
moderation = { header, 8: [0*50 bstr .size 16], 9: [0*50 bstr .size 16] }
                                                                      ; kind 12: muted accounts, removed accounts;
                                                                      ; each strictly ascending, not both empty
leave      = { header, 8: 1..5 }                                      ; kind 2 at version 2: 4 removed from the call,
                                                                      ; 5 the call was ended
```

`header` is version 1's: 0 `room_id`, 1 `join_id`, 2 and 3 the sender, 4 `counter`, 5
`created_ms`. No account id is all zero. Kinds 9 to 12 exist at version 2 only; a version-1
decoder ignores them as unknown kinds, which is why §5.1 never lets one reach it. Every new frame
fits bucket 1024 except a `moderation` naming more than 48 accounts in its two lists, which goes
in 4096.

### 5.3 Who receives each, and what it costs

| Kind | Sent by | Sent to | Retried |
|---|---|---|---|
| 9, 10 | The owner or an admin, in the call | Every device in the sender's call, the target's included | No |
| 11 | The owner or an admin, in the call | Every device in the sender's call | No |
| 12 | Each owner or admin in the call, holding a non-empty state | A device whose connection to it has just reached `connected`, once for that device's join | No |

These frames go only to devices in the call, which hold open connections, so the relay rarely
drops one. They draw on an allowance of **16 sealed frames to each peer in one call**, beside the
32 of ADR-077 D5, and the last one of the 16 is kept for `end_call`. A device that has spent the
rest sends that peer no further action in that call. At 48 frames a call it takes 41 calls in
which every frame to one peer is dropped before that pair reaches the 2,000-key bound, and the
outcome there is a repair.

### 5.4 Checking an action

A receiving device applies a frame of kind 9 to 12 only when every one of these holds, in this
order; any other frame is dropped after the router's commit, and nothing is shown:

1. the version-1 checks of `voice-signalling-v1.md` § "The common body header": the room is held,
   at version 2, not quarantined and not waiting for its state, this account is an active member,
   and the header names the device the pairwise session authenticated, whose account is an active
   member;
2. this device is in a call in that room, and holds the header's `join_id` as the sender device's
   current join in it — so a frame from an earlier call, or from an earlier join of the sender,
   is never applied;
3. the `counter` is above the last one applied from that join;
4. the sender's role **in this device's committed roster, as it stands when the frame arrives**,
   allows the action on its target (§2): for kinds 9 and 10, the target is an active member who is
   not the sender's own account and not the owner, and an admin's target is a member; for kind 11,
   the sender is the owner or an admin; for kind 12, each entry is checked as a kind 9 or a kind
   10 from that sender, and only the entries that pass are applied.

The pairwise session authenticates the sender, and the ratchet refuses a replayed ciphertext; the
join and the counter are what keep an action from being applied twice or in another call.

### 5.5 Applying an action

- **Mute** (kind 9, `true`). This device stops playing the audio of every device of the target
  account in this call — every connection to them now, and any later in the same call — until a
  kind 9 with `false` from a sender allowed to send it, or until this device's call ends. Their
  tiles say "Muted by @x". On the target's own devices: the app disables its capture track, so it
  sends silence, says "@x muted you. You can speak again when the owner or an admin lets you.",
  and offers no unmute until then.
- **Remove from the call** (kind 10). This device closes every connection to the target's devices
  at once, drops them from its participant set and from every pending retry, and refuses every
  frame of theirs in this call — `join`, `offer`, `answer`, `candidates`, `participants` and room
  text — until its own call ends. On the target's own devices: the app leaves the call, sends
  `leave` with reason 4, and says "@x removed you from this call."
- **End the call** (kind 11). This device leaves the call: it closes every connection, sends
  `leave` with reason 5 to the devices it was connected to, drops the room text and says "@x ended
  the call." Nothing stops a member starting a new call afterwards.
- **Moderation** (kind 12). Each passing entry applies as a mute or a removal.
- A demotion or a removal from the room that arrives later does not undo an action already
  applied; the race between the durable roster and the volatile action is the one ADR-077 D11
  states for removal, and it is safe in the same direction: an admin's action applied before the
  demotion reached this device stands, and none after it does.

### 5.6 A device that joins later

Each owner and admin in a call keeps, for its call, the accounts it holds muted and removed — from
its own actions and from every action it applied. When its connection to a device of a newly
joined participant first reaches `connected`, it sends that device one `moderation` frame with both
lists, if either is non-empty. The newcomer applies it under §5.4, entry by entry. So a mute and a
removal hold for a newcomer as long as one owner or admin who applied them is still in the call.

### 5.7 The words

These carry the enforcement truth of §6, so their words are part of the requirement. The English is
binding; the Persian MUST say the same and be read by a native reader.

| Where | Text |
|---|---|
| Confirming a mute | "Every up-to-date app in this call stops playing @x's audio. Nothing can switch off @x's microphone." |
| Confirming a removal from the call | "@x's connections in this call are closed, and every up-to-date app refuses @x until this call ends. To keep @x out of the room, remove @x from the room." |
| Confirming the end of the call | "Every up-to-date app in this call leaves it." |
| Room info, a member's role | **Owner** or **Admin** beside the name; nothing for a member |
| Removing a member from the room | "Removing is a signed change every member applies. The owner and admins can remove members, only the owner can remove an admin, and nobody can remove the owner." |

`frontend/docs/ui-specification.md` §13.2 — "No role tags: every active member may add a member,
remove a member and rename the room", and the removal confirmation that says "any member can remove
any other" — stays true of a version-1 room only.

## 6. What the mesh can enforce, and what it cannot

There is no server in the call to enforce anything; each participant's own app is the whole of the
enforcement, and a modified app does what it likes.

- **Mute** means every honest participant stops playing that person's audio. It cannot switch off
  a microphone: the muted person's own app decides whether it sends silence, a modified app keeps
  sending audio, and a participant whose app never received the mute keeps playing it.
- **Removal from the call** means connections are closed and that device's offers are refused, by
  every honest participant, for the rest of its own call. The removed person can still connect to a
  participant whose app never received the removal. Keeping someone out for good is a removal from
  the room, which is a signed control event every member applies.
- **Ending the call** is a request that honest clients obey. Two apps that ignore it can keep
  talking to each other.
- **Roles** are what each member's own copy of the signed chain says. No server holds one or checks
  one, and a compromised device of the owner can do everything the owner can.

## 7. What the server sees

- No route, column, setting, rate scope or stored value changes, and nothing changes at rest.
- **The announcements** are ordinary 1 KiB envelopes: at the first start of a build that implements
  this document, one to each device of each account the device shares a room with, in a short
  window. That set is part of the social graph live root already sees (`SECURITY.md` § "Residual
  risk", items 1 and 2).
- **Role changes and the upgrade** are control events, ordinary envelopes to every member's
  devices, as every room change has been.
- **In-call actions** are `signal` frames. Live root sees one device of a call send a frame to every
  other participant at once — and, for an end of the call, every connection of the call closing a
  moment later — but not which action it was, nor whom it named.

## 8. Security analysis

- **Role escalation.** Only the owner changes a role, and handing over is the owner's own signed
  act; the core refuses a role above 2; an admin cannot act on an admin or the owner; nobody can act
  on the owner. The upgrade is signed only by the derived owner — the creator, while still a
  member, and never a successor a member could make of itself by removing the creator first
  (§4.1). Every device computes it the same way from the chain, and the upgrade's roles are
  derived, not stated, so an upgrade cannot carry a role the derivation would not give. A
  version-1 event after the upgrade is refused, so nobody can fall back to the equal authority of
  version 1, and no operation returns a room to version 1.
- **Forged and replayed in-call actions.** An action is applied only from the device the pairwise
  session authenticated, whose header names it, in this device's current call, in the sender's
  current join, with a counter it has not applied, and from a role this device's own roster gives
  the sender (§5.4). The server cannot forge one, cannot replay one — the ratchet refuses a
  replayed ciphertext — and cannot move one into another call.
- **Fork during the migration.** The upgrade waits for every member device to announce version 2,
  has one designated signer that every device of the owner computes from the account's device
  list alone, waits an hour, and stops every device that knows negotiation is complete from
  signing version-1 events. What remains is an upgrade crossing a leave or a change from a device
  that did not yet know, which forks the room as any two concurrent changes do (§4.3). A client
  that predates this document never forks a room (§4.5). A member can still keep a room at
  version 1 by removing its creator before the upgrade, which version 1 lets any member do; the
  removal is signed, every member sees who made it, and the room keeps equal authority rather than
  handing anyone the owner's.
- **Downgrade between versions.** A version-2 room speaks version-2 signalling only, and refuses a
  version-1 control event. A member cannot announce for another device: an announcement is
  authenticated by the pairwise session of the device it speaks for. The server can drop
  announcements and so delay an upgrade, which is the denial of service it can always cause
  (residual risk 4). It can also hide a device from its account's list, so that negotiation
  completes without it; the hidden device is then left at the version-1 state, and an event it signs
  later, if the server reveals it, forks the room. That is the same denial, and the device log of
  `CLIENT_CONTRACT.md` §J is what exposes a hidden device.
- **Exhaustion.** The announcement goes once to each device id, and again at most once a day
  while one is missing; the allowance of in-call actions is 16 to each peer in one call; a
  `moderation` frame names at most 50 accounts in each list.

## 9. What the client must prove

Each of these is a test that fails when the rule is broken, alongside the vectors of §10:

- every scenario of §10.3 ends in its stated outcome and roles;
- an upgrade from anyone but the derived owner, a second upgrade, a version-2 event before the
  upgrade and a version-1 event after it are each recorded and dropped, and the room goes on;
- a version-1 event at the upgrade's revision forks the room;
- the designated device signs the upgrade only after an hour of complete negotiation, and it is the
  owner's lowest live device id whatever devices hold the room; a device that knows negotiation is
  complete signs no version-1 event but its own leave;
- a room whose creator is no longer an active member is never upgraded, and its members keep
  signing version-1 events;
- a new room is created at version 2 only when every device it names has announced version 2;
- the announcement is sent once per device id, re-sent within a day when one is missing, and not
  kept from a device outside the rooms; a build that cannot decode it leaves the room untouched;
- a version-2 room's frames are version 2; a version-1 `join` for it is answered once with a
  version-2 `participants`;
- each in-call action from a member, from an admin on an admin or the owner, from an earlier join
  or with a used counter is not applied;
- a mute stops playback of every device of the target and survives the target's rejoin within the
  call; a removal closes every connection to the target and refuses its rejoin; an end of the call
  makes every honest participant leave with reason 5;
- a newcomer receives each admin's `moderation` and applies only the entries that admin may send;
- the allowance stops at 15 actions to one peer and still lets `end_call` through;
- an owner cannot leave while others remain, and **Hand over and leave** signs the two events in
  order.

## 10. Golden vectors

Line breaks inside a value are not part of it. Every value was generated twice with identical
output and reproduced by a second, independent implementation; every signature by OpenSSL 3.6.4 and
by the reference code of RFC 8032 §6 as well, and every state hash by a second SHA-256. Each refusal
is refused for the reason in its row by both implementations.

### 10.1 The inputs

| Name | Value |
|---|---|
| Alice's, Bob's and Carol's `user_id` | `6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10`, `2a77d4b9-e611-4c0f-9f1c-6a2e3b7d4e0f`, `3c5e7a9b-1d2f-4a6b-8c0d-e1f2a3b4c5d6` |
| Alice's phone, Bob's phone | `b3a91c77-2e5d-4f28-a1c9-8d64e0f3b522`, `7e1d5c9a-3b2f-4e6d-a8c1-9f0e2d3c4b5a` |
| Alice's phone's signing key, from the Ed25519 seed `13` × 32 | `66cd608b928b88e50e0efeaa33faf1c43cefe07294b0b87e9fe0aba6a3cf7633` |
| Bob's phone's signing key, from the seed `23` × 32 | `74f85cda34d1c27c4621484731e91579c3d9c6cfc0d94b281aa11e9162058aa9` |
| The new room, the old room | The 32 bytes `60` to `7f`; the 32 bytes `80` to `9f` |
| `created_ms` | 1,792,670,400,000 (2026-10-22T12:00:00Z), plus a minute for each later event of the new room and an hour for the upgrade |
| Event ids | `e1` × 16 to `e6` × 16, in the order below |

Alice's, Bob's and Alice's phone's ids are those of `CLIENT_CONTACTS_AND_TRUST.md` §4.8 and §6.6;
Carol, Bob's phone and the two seeds are new. The encoder reproduces the native core's own golden
rename (`golden_rename` in `room_control.rs`) byte for byte.

### 10.2 The announcement and the events

```text
CPVRV001 kind 4, version 2 (10 bytes)
  43505652563030310402

A1, version 2: Alice creates "Standup" with Alice, Bob and Carol, and is its owner (172 bytes)
  canonical   aa00020150e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e10258206061626364656667
              68696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f030104f605506f0c
              2f5e8a414c9e9a341f3d8f2b7c100650b3a91c772e5d4f28a1c98d64e0f3b522
              071b000001a1637b7e00080109a200675374616e6475700183502a77d4b9e611
              4c0f9f1c6a2e3b7d4e0f503c5e7a9b1d2f4a6b8c0de1f2a3b4c5d6506f0c2f5e
              8a414c9e9a341f3d8f2b7c10
  signature   e12bf3aa0b54487fc2e3ed4373ae202b1523cbbf185c006e7b8b74d729fa9745
              5dbace6e7a299b78f201831b416c6172562d3364d8c1da82843f51f151ba430d
  state hash  09d1c73ee6fcba5242fda4202046007b7245a37a06324ee96ccfdace7450b735

A2, version 2: Alice makes Bob an admin (163 bytes)
  canonical   aa00020150e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e20258206061626364656667
              68696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f030204582009d1c7
              3ee6fcba5242fda4202046007b7245a37a06324ee96ccfdace7450b73505506f
              0c2f5e8a414c9e9a341f3d8f2b7c100650b3a91c772e5d4f28a1c98d64e0f3b5
              22071b000001a1637c6860080509a200502a77d4b9e6114c0f9f1c6a2e3b7d4e
              0f0101
  signature   2ff705d40077d822bc50d0ab10dddbd1a4abe5e4fd900bf68e6d0315f8fc8437
              d0d6cb9f87fc1184708cb15576befd898003832ababce670efd123884648740a
  state hash  c836458ce6c5a972f2708687defa12024843dbdeb047fe9886126d1a1e515f8c

A3, version 2: Alice hands the room to Bob (163 bytes)
  canonical   aa00020150e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e30258206061626364656667
              68696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f0303045820c83645
              8ce6c5a972f2708687defa12024843dbdeb047fe9886126d1a1e515f8c05506f
              0c2f5e8a414c9e9a341f3d8f2b7c100650b3a91c772e5d4f28a1c98d64e0f3b5
              22071b000001a1637d52c0080509a200502a77d4b9e6114c0f9f1c6a2e3b7d4e
              0f0100
  signature   5a9773c8437c1df951b9ae60a84f9c0dddae0c1d9585f5f659510b309123f619
              8b20f10ba53880f3b3ebe79ebc46646e455cadf28470ef2b70f11a008764a504
  state hash  d386dda539dc258aa30578274da48cff64445c87f9e86cbbf0d803c8bb1ecb39

A4, version 2: Bob, the owner now, renames it "Weekly standup" from his phone (159 bytes)
  canonical   aa00020150e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e40258206061626364656667
              68696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f0304045820d386dd
              a539dc258aa30578274da48cff64445c87f9e86cbbf0d803c8bb1ecb3905502a
              77d4b9e6114c0f9f1c6a2e3b7d4e0f06507e1d5c9a3b2f4e6da8c19f0e2d3c4b
              5a071b000001a1637e3d20080409a1006e5765656b6c79207374616e647570
  signature   ded2856ebb798204cca78e63b677417d3f27d0b576d7eff773adcd9faf94808c
              72549d8ad31b3f3916c5dc38cca2de213963f7a5f22ef06da7c1827b094bff0a
  state hash  ab09bd8bc32d3c306e60eaf5bf9d12e092722e1e1436b68f5a9732acdf5528c5

B1, version 1: Alice created the old room before version 2 existed (172 bytes)
  canonical   aa00010150e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e50258208081828384858687
              88898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f030104f605506f0c
              2f5e8a414c9e9a341f3d8f2b7c100650b3a91c772e5d4f28a1c98d64e0f3b522
              071b000001a1637b7e00080109a200675374616e6475700183502a77d4b9e611
              4c0f9f1c6a2e3b7d4e0f503c5e7a9b1d2f4a6b8c0de1f2a3b4c5d6506f0c2f5e
              8a414c9e9a341f3d8f2b7c10
  signature   0961f951a54135030116113b751af530d8ba7536e6a3e619a041070d3457a945
              575b5b651e39e43b013e0ff0bfa7ab4076e4793cf87e583027e9dd89b051af05
  state hash  a8a9a9f8fe9f0b8f99acab4c3bbd9f3f8310f15978a74d2e1491d2e014cffacb

B2, version 2: Alice, the signer of revision 1, upgrades it (145 bytes)
  canonical   aa00020150e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e60258208081828384858687
              88898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f0302045820a8a9a9
              f8fe9f0b8f99acab4c3bbd9f3f8310f15978a74d2e1491d2e014cffacb05506f
              0c2f5e8a414c9e9a341f3d8f2b7c100650b3a91c772e5d4f28a1c98d64e0f3b5
              22071b000001a163b26c80080609a10002
  signature   7d1da2b82d2712a716aa38acfc6f63f8540ac3a2d420cfd73f14dc1ce70dbe31
              91c3d85013cf2d3630b6eee87b35107cfee93e9ef95d6e86aba8e60455ce0b02
  state hash  a69d9c2a1777c3aecc30b2409474b591767c0eb98afeb99ab85f63760f98760b

B2 as Alice's phone delivers it, CPVRV001 kind 1 (254 bytes)
  4350565256303031016f0c2f5e8a414c9e9a341f3d8f2b7c10b3a91c772e5d4f
  28a1c98d64e0f3b52200000091aa00020150e6e6e6e6e6e6e6e6e6e6e6e6e6e6
  e6e6025820808182838485868788898a8b8c8d8e8f909192939495969798999a
  9b9c9d9e9f0302045820a8a9a9f8fe9f0b8f99acab4c3bbd9f3f8310f15978a7
  4d2e1491d2e014cffacb05506f0c2f5e8a414c9e9a341f3d8f2b7c100650b3a9
  1c772e5d4f28a1c98d64e0f3b522071b000001a163b26c80080609a100027d1d
  a2b82d2712a716aa38acfc6f63f8540ac3a2d420cfd73f14dc1ce70dbe3191c3
  d85013cf2d3630b6eee87b35107cfee93e9ef95d6e86aba8e60455ce0b02
```

**Refused by the core**, each by the rule in brackets. Each is A2 or B2 with the one change it names:

| Event | Rule |
|---|---|
| A2 with key 0 set to 3 | unsupported version |
| A2 with key 0 set to 1: a change of role in a version-1 event | unsupported operation |
| B2 with key 0 set to 1 and B1's `created_ms`: an upgrade in a version-1 event | unsupported operation |
| A2 with its body `{0: Bob, 1: 3}` | malformed (a role of 3) |
| B2 with B1's `created_ms` and the body `{0: 3}` | malformed (an upgrade to version 3 in a version-2 event) |
| A2 with key 8 set to 7 and the body `{0: 2}` | unsupported operation |
| B2 at revision 1, with a null previous hash and B1's `created_ms` | malformed (an upgrade at revision 1) |
| A1 naming only Bob and Carol | malformed (a create that does not name its signer) |
| A2 with its revision written `1a00000002` | non-canonical |

**Refused kind 4 payloads:** `43505652563030310400` (a version of 0); `4350565256303031040200` (a
trailing byte); `435056525630303104` (no version byte).

### 10.3 The scenarios

Each row starts from an empty room and applies its events in order; every event before the last is
applied. The roster's chain links are left out: each event names the state it builds on.

| Scenario | Events | The last event | Roles after |
|---|---|---|---|
| An admin adds a member | v2 create by Alice (Alice, Bob); Alice makes Bob admin; Bob adds Carol | applied | Alice owner, Bob admin, Carol member |
| A member adds a member | v2 create by Alice (Alice, Bob); Bob adds Carol | refused | Alice owner, Bob member |
| An admin removes an admin | v2 create by Alice (all three); Alice makes Bob admin; Alice makes Carol admin; Bob removes Carol | refused | Alice owner, Bob admin, Carol admin |
| The owner removes an admin | v2 create by Alice (Alice, Bob); Alice makes Bob admin; Alice removes Bob | applied | Alice owner |
| An admin removes the owner | v2 create by Alice (Alice, Bob); Alice makes Bob admin; Bob removes Alice | refused | Alice owner, Bob admin |
| The owner leaves while others remain | v2 create by Alice (Alice, Bob); Alice removes Alice | refused | Alice owner, Bob member |
| Hand over, then leave | v2 create by Alice (Alice, Bob); Alice hands the room to Bob; Alice removes Alice | applied | Bob owner |
| A member renames | v2 create by Alice (Alice, Bob); Bob renames | refused | Alice owner, Bob member |
| An admin promotes | v2 create by Alice (all three); Alice makes Bob admin; Bob makes Carol admin | refused | Alice owner, Bob admin, Carol member |
| The upgrade | v1 create by Alice (all three); Alice upgrades | applied | Alice owner, Bob member, Carol member |
| Another member upgrades | v1 create by Alice (all three); Bob upgrades | refused | all equal (version 1) |
| The creator left | v1 create by Alice (all three); Alice leaves; Bob upgrades | refused | all equal (version 1): the room has no derived owner |
| The creator was removed | v1 create by Alice (all three); Bob removes Alice; Bob upgrades | refused | all equal (version 1): removing the creator makes nobody the owner |
| The creator removed and added again | v1 create by Alice (all three); Bob removes Alice; Bob adds Alice; Alice upgrades | applied | Alice owner, Bob member, Carol member |
| A version-1 change after the upgrade | v1 create by Alice (Alice, Bob); Alice upgrades; Bob renames with a version-1 event | refused | Alice owner, Bob member |
| A version-2 change before the upgrade | v1 create by Alice (Alice, Bob); Alice renames with a version-2 event | refused | all equal (version 1) |
| A second upgrade | v1 create by Alice (Alice, Bob); Alice upgrades; Alice upgrades | refused | Alice owner, Bob member |

### 10.4 Signalling, version 2

The header inputs are the client's own codec test
(`frontend/test/features/voice/voice_signal_codec_test.dart`): `room_id` `11` × 32, `join_id` `22` ×
16, sender `33` × 16 and `44` × 16, counter 7, `created_ms` 1,759,190,400,000. The targets are `55`,
`66` and `77`, each × 16.

```text
mute, on (132 bytes)
  43505653563030310209a8005820111111111111111111111111111111111111
  1111111111111111111111111111015022222222222222222222222222222222
  0250333333333333333333333333333333330350444444444444444444444444
  444444440407051b0000019997eb3c0008505555555555555555555555555555
  555509f5
mute, off (132 bytes): the same with its last byte f4
remove from the call (130 bytes)
  4350565356303031020aa7005820111111111111111111111111111111111111
  1111111111111111111111111111015022222222222222222222222222222222
  0250333333333333333333333333333333330350444444444444444444444444
  444444440407051b0000019997eb3c0008505555555555555555555555555555
  5555
end the call (112 bytes)
  4350565356303031020ba6005820111111111111111111111111111111111111
  1111111111111111111111111111015022222222222222222222222222222222
  0250333333333333333333333333333333330350444444444444444444444444
  444444440407051b0000019997eb3c00
moderation: 55 and 66 muted, 77 removed (167 bytes)
  4350565356303031020ca8005820111111111111111111111111111111111111
  1111111111111111111111111111015022222222222222222222222222222222
  0250333333333333333333333333333333330350444444444444444444444444
  444444440407051b0000019997eb3c0008825055555555555555555555555555
  5555555066666666666666666666666666666666098150777777777777777777
  77777777777777
leave, version 2, removed from the call (114 bytes)
  43505653563030310202a7005820111111111111111111111111111111111111
  1111111111111111111111111111015022222222222222222222222222222222
  0250333333333333333333333333333333330350444444444444444444444444
  444444440407051b0000019997eb3c000804
leave, version 2, the call was ended (114 bytes): the same with its last byte 05
```

**Not applied**, each by the rule in brackets:

| Payload | Rule |
|---|---|
| *mute, on*, with the map byte `a9` and `0a00` appended (an extra key 10) | key set |
| A *moderation* muting 66 then 55, removing nobody | out of order |
| A *moderation* muting 55 twice, removing nobody | duplicate |
| A *moderation* with both lists empty | empty |
| A *moderation* muting the 51 accounts `10` × 15 followed by `01` to `33`, removing nobody | too many |
| A *leave* of reason 6 at version 2 | out of range |
| A *leave* of reason 4 at version 1 | out of range |
| *mute, on* with its version byte `01` | ignored: unknown kind at version 1 |
| *end the call* with its version byte `03` | dropped: unsupported version |
