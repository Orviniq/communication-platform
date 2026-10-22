# CLIENT_PRESENCE_AND_RECEIPTS.md — Online status, who can see it, read receipts, and who reacted

This document binds the Flutter client exactly as [`CLIENT_CONTRACT.md`](CLIENT_CONTRACT.md)
does, and the contract routes here from its §R. It specifies client behaviour only.
**Nothing in it adds, changes or needs a server route, a column, a setting, a rate scope or
a gateway frame**: the server stays what [`SECURITY.md`](../security/SECURITY.md) says it
is, and the gateway still holds no presence of any kind
([ADR-0022](../architecture/decisions/0022-the-gateway-holds-no-presence.md) stands). The
decision is recorded in
[ADR-0031](../architecture/decisions/0031-online-status-stays-client-protocol-over-signal-frames.md);
the work it gives the client, in the order to do it, is
[`../CLIENT_WORK.md`](../../CLIENT_WORK.md).

The online status this document binds is the one the client already built: client ADR-098
(accepted and built on 2026-10-19, PR #90), in
[`frontend/docs/decisions.md`](../../frontend/docs/decisions.md). §3 states that protocol as
binding text, and §2 lists every change this document makes to it. The client folds those
changes into [`frontend/docs/message-protocol.md`](../../frontend/docs/message-protocol.md)
and records them in a new client ADR that amends ADR-098.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be read as described in
RFC 2119 and RFC 8174 when, and only when, they appear in capitals.

Where this document and a client document under `frontend/docs/` disagree about what it
specifies, this document is authoritative and the client document is the one to change.
`CLIENT_WORK.md` names each of them.

## 1. Terms

- **Presence frame.** A `CPPSV001` payload carried in a `signal` frame (§3.2). Its four
  kinds are `watch`, `here`, `typing` and `gone`.
- **Watch.** "I have this conversation open on my screen": the status query and the typing
  interest in one frame. **Here** is the answer to a watch.
- **Lease.** What a device keeps for a watcher it answered: that device, that conversation,
  and when the lease ends.
- **Live, probe.** A watch to a device from which a frame was committed in the last 40
  seconds is *live*; any other watch is a *probe*.
- **Audience.** The accounts this account lets see its online status, and the only accounts
  whose online status it sees (§4).
- **`MUTUAL`, verified, blocked, contact.** As
  [`CLIENT_CONTACTS_AND_TRUST.md`](CLIENT_CONTACTS_AND_TRUST.md) defines them: a direct
  conversation in which both people verified each other (§5.5 there); a trust record of
  `verified` on this account's devices (§1 there); a peer whose kind-2 block record says
  blocked (§3.3 there); a peer whose kind-1 entry is on the list (§3.1 there).
- **The privacy record.** `CPCTV001` kind 7 (§5): this account's status audience and its
  read-receipt setting, one register for the whole account.
- **Dead skipped key.** What a dropped volatile frame leaves on its target's pairwise
  session for the life of that session (§3.7).

## 2. What client ADR-098 built, and what this document changes

### 2.1 The owner's decisions, set against ADR-098

| The owner's decision (2026-10-22) | ADR-098 as built | This document |
|---|---|---|
| Presence travels as encrypted `signal` frames; a device asks only while a direct or group chat is open, repeats while it stays open, tells recent askers when the app goes to the background, and never broadcasts | The same: a `watch` when a chat opens and every 25 s while it stays open, `gone` before the socket closes, nothing on open of the app (D4, D5) | Bound as built (§3) |
| "Online" means the app is in the foreground, not that the socket is connected | The same: a device in the background answers nothing, even with a socket held open (D4) | Bound as built |
| Last seen is computed and kept on the device; its precision is the developer's to pick | Kept in `presence_devices`, never sent; minute precision today and yesterday, a date before that, no year (D8, D11) | Precision kept, and an earlier year now carries the year (§3.9) |
| A device answers only mutually verified contacts and active members of a group it shares with the asker, and never anyone the user has blocked | Answers any peer this user has verified, one-sided; blocking had no client state yet | Direct conversations need `MUTUAL`; blocked accounts get nothing; group members still need this user's verification, because the volatile sealer refuses an unverified account; and the check runs again for every frame sent, so a block or a trust drop ends a lease at once (§3.3) |
| A privacy setting — everyone I share a chat with / my contacts / nobody — that is reciprocal and replaces the on/off switch | "Show my online status", on or off, per phone, reciprocal (D9) | Three settings (§4), held for the whole account in the privacy record (§5), migrated from `presence.share.v1` (§5.4) |
| Group headers show how many members are online, from answers received | "N online" in groups of at most 32 members (D4, D11) | Every group, since a group holds at most 50 members (§8) |
| One group query, at 50 members with up to 10 devices each, stays inside the gateway limits | A query reaches at most 2 devices of each member, in a group of at most 32: 62 frames | Owner's choice of 2026-10-22: at most 2 devices of each member in a group of at most 50 — at most 98 frames, sent in 6.8 s (§8) |
| The read-receipt setting, direct conversations only | — | §6 |
| Who reacted | — | §7 |

Three rules change because a query now reaches up to 98 devices, and each closes a way a
frame could be sealed and never sent, which costs its target a dead skipped key exactly as a
dropped frame does (ADR-098 D5's own reasoning):

1. A renewal's 10-second answer window counts from the moment its frame leaves the pacer,
   not from the start of the round (§3.4). Counted from the start, the last devices of a
   98-device round would have about 3 seconds to answer and would be demoted to probes.
2. A frame is sealed only when the pacer can release it at once (§3.8). ADR-098 seals a whole
   round before pacing it, so a round cut short by leaving the app strands what it sealed.
3. The goodbye seals no more frames than the pacer releases in the 500 ms the socket waits
   (§3.6).

### 2.2 Statements in the client's documents this changes

`frontend/docs/message-protocol.md` § "Receipts and typing" describes ADR-098 as built. These
statements in it change, and [`CLIENT_WORK.md`](../../CLIENT_WORK.md) routes each one:

- **"No claim the client cannot observe."** The paragraph stays true and keeps its title: no
  screen says a peer is "offline". Its list of what shows nothing changes: "a group over 32
  members" goes, because every group now has presence, and "a peer outside your audience"
  joins "a peer online while this phone was not watching" and "a member this user has not
  verified".
- **"Who may send and receive."** "Only verified peers" becomes the admission of §3.3: a
  direct conversation in `MUTUAL`, a verified active member of a group, never a blocked
  account, and always inside the audience; "an active group of at most 32 members" becomes
  any active group.
- **"Watching."** "In a group, to at most 2 devices of each member" stays, for groups of up to
  50; the renewal window and the sealing change as §2.1 says.
- **"The switch."** It is replaced by §4 and §5: three settings, one for the whole account.
- **The first paragraph of § "Receipts and typing"**: "a read receipt is sent only after the
  conversation is visibly read and user privacy settings allow it" now names the setting of
  §6.

## 3. Online status: the protocol, bound

What ADR-098 built, stated as binding. The deltas of §2.1 are written into it and marked
**(new)**.

### 3.1 The channel

- Presence frames travel in `/ws` `signal` frames only
  ([`backend/realtime/API.md`](../../backend/realtime/API.md)): volatile, delivered to every
  live socket of the target device, and dropped in silence when it has none. Nothing about
  presence is stored by the server or sent to it in any other form, and a client MUST NOT ask
  the server anything about a peer's presence.
- Every presence frame is a 1024-byte blob. The largest payload is 112 bytes and bucket 1024
  holds 942 under a regular ratchet header; no volatile frame ever carries an initial header,
  because a volatile frame never starts a session (client ADR-077, decided B).
- **One reader.** One router is the only subscriber of the socket's inbound `signal` frames.
  It queues at most 256 and drops the oldest past that, opens each frame once under its
  pairwise session, and routes it by the first 8 bytes of the plaintext: `CPVSV001` to voice,
  `CPPSV001` to presence. A frame with a known magic MUST be committed before its channel
  reads the rest, whatever the channel then decides, because a step left uncommitted makes
  the next message of that chain leave a dead key on this phone. A payload with any other
  magic MUST be left uncommitted, so that a durable envelope the relay replays as a signal
  still opens on the durable path. A `CPPSV001` that arrives in a durable envelope MUST be
  refused there.

### 3.2 The payload

```text
payload = "CPPSV001" || version:u8 (= 1) || kind:u8 || deterministic-CBOR body
```

The body is a map with small unsigned integer keys under RFC 8949 §4.2.1 — definite lengths,
the shortest integer form, keys in ascending order, no tags. Keys 0 to 3 are the header, 4 to
7 are reserved, body keys begin at 8. **Every key a kind defines is required and no other key
is allowed**, the reserved ones included, and a payload is accepted only when it re-encodes to
exactly its own bytes.

```cddl
header = (
  0: bstr .size 16,          ; sender_user_id: the account the session authenticated
  1: bstr .size 16,          ; sender_device_id: the device the session authenticated
  2: bstr .size 16,          ; instance_id: CSPRNG bytes minted when the channel starts in a process
  3: 1..4294967295,          ; counter: monotonic within one instance_id
)
watch  = { header, 8: bstr .size 32, 9: 1..60000 }               ; kind 1: conversation_id, lease_ms
here   = { header, 8: bstr .size 32, 9: bool }                   ; kind 2: conversation_id, typing
typing = { header, 8: bstr .size 32, 9: true, 10: 1..15000 }     ; kind 3, active: ttl_ms
       / { header, 8: bstr .size 32, 9: false }                  ; kind 3, stopped
gone   = { header, 8: 1 / 2 }                                    ; kind 4: reason
```

| Kind | Name | Sent to |
|---|---|---|
| 1 | `watch` | The devices §3.4 names; `lease_ms` is always sent as 40,000 |
| 2 | `here` | The one device whose watch it answers; `typing` says whether this device is typing in that conversation |
| 3 | `typing` | The devices holding a live lease on that conversation (§3.5) |
| 4 | `gone` | Reason 1, *left the foreground*: the devices of §3.6. Reason 2, *stopped sharing with you*: the devices of §4.3 **(the words are new; the bytes are not)** |

Decoding, in this order, every step after the router's commit:

1. A version other than 1 is dropped. An unknown kind inside version 1 is ignored, so that a
   later build can add one. A payload over 942 bytes, or whose body fails the CDDL above or
   re-encodes to other bytes, is dropped.
2. A header that does not name the device the session authenticated, or names an account of
   this account's own, is dropped.
3. The receiver keeps the newest `(instance_id, counter)` of each sender device. A frame of the
   same instance whose counter is not above it is dropped; a new `instance_id` replaces the
   old one, because the sender's process restarted.

The golden vectors are §12.1; they are the client's own golden bytes, reproduced by two
independent implementations here.

### 3.3 Admission (new rules in bold)

A `watch`, `here` or `typing` is admitted only when every one of these holds; anything else is
dropped after the commit, with no answer and no lease:

- the conversation it names is one this phone holds with the sender's account: **a direct
  conversation whose state is `MUTUAL`**, or an active group in which both accounts are active
  members and whose sender **this user has verified**;
- **the sender's account is in this account's audience (§4)**;
- **the sender's account is not blocked.**

Saved Messages, a conversation this phone does not hold and a group this phone holds in any
lifecycle but active are not conversations held with anyone, so nothing about them is ever
admitted. A `gone` names no conversation and is admitted from a device this phone holds a
lease for, watches or shows online, **whose account is not blocked**. While this account's
audience is `nobody`, every presence frame is discarded unread after the commit.

**The same conditions hold for every frame this device sends (new).** A renewal, a probe, an
answer, a typing frame and a goodbye are each sealed only for a device whose account passes
them at the moment of sealing, not only when its lease was granted. Any change that takes an
account out of them — a block, its direct conversation leaving `MUTUAL`, a verification that no
longer holds, either account leaving the group, leaving the contact list under `contacts`, or a
change of the audience — MUST at once end every lease of that account's devices, stop showing
their online state and typing, and, when the account is no longer in the audience, delete its
last seen. A blocked account is sent nothing at all, not even a goodbye; every other account
that leaves the audience is sent the goodbye of §4.3.

Group members still need this user's verification, although the owner's rule names "active
members": the volatile sealer refuses to seal for an account this user has not verified, so a
device can neither watch nor answer one, and admitting a frame it could never answer would
show a status that is not reciprocal.

### 3.4 Watching and answering

- **Who watches.** A device in the foreground, whose audience is not `nobody`, watches the
  conversation it shows when that conversation is a direct conversation in `MUTUAL` with a peer
  in its audience, or an active group in which this account is an active member.
- **Targets.** In a direct conversation, every live device of the peer — at most 10. In a
  group, for each other active member in the audience whom this user has verified, at most 2
  live devices: those with the newest of their stored last seen and the time this process
  last heard them, ties by device id. Never a device of this account.
- **Rounds.** One round when the conversation opens, and one every 25 s while it stays open and
  the app stays in the foreground. In a round, a **renewal** goes to each target from which a
  frame was committed in the last 40 s and that answered its last renewal **within 10 s of that
  renewal leaving the pacer** (new); a **probe** goes to each other target its ledger allows
  (§3.7).
- **Answering.** A device in the foreground, whose audience is not `nobody`, answers each
  admitted watch at once with `here`, and keeps a lease for that device on that conversation
  for `lease_ms`, never more than 60 s. In the background it answers nothing, even with a
  socket held open by receiving while closed; a watch it admits there still makes the sender
  online.

### 3.5 Typing

- **Start**: the first edit that leaves the composer non-empty, or the first edit after a stop,
  sends `typing` active with a `ttl_ms` of 15,000. **Repeat**: every 10 s while an edit
  happened in the last 5 s. **Stop**: `typing` stopped, 5 s after the last edit, and at once on
  send, on clearing the composer, on leaving the chat and on leaving the foreground. **Pace**:
  at most one typing frame per conversation every 5 s; a change inside those 5 s waits for
  their end, and a change undone inside them sends nothing.
- **Targets**: only the devices holding a live lease on that conversation — devices that
  watched it within 40 s and were admitted, so typing reaches only the audience — and never
  this account's devices. A chat nobody watches costs nothing.
- **At the receiver**: shown for 15 s after the latest active frame, and ended at once by a
  stop, by that device's `gone`, and when a message of that sender in that conversation
  appears. A group names the members who type by the name the group page gives their messages.
- Typing is never the `typingSet` application event, which is never sent and which the durable
  inspector refuses.

### 3.6 Online, and the goodbye

- **Online.** A device is online from any admitted `watch`, `here` or `typing` until 40 s
  after the latest one, or until its `gone`. An account is online while one of its devices is.
- **The direct chat header** shows the typing line; otherwise "online"; otherwise the last seen
  of §3.9; otherwise nothing. **The group header** shows the typing line; otherwise "N members ·
  M online" when M, the other members in the audience with an online device, is at least 1;
  otherwise the member count alone.
- **The goodbye.** On leaving the foreground, the device sends the pending typing stops the
  pace allows, then `gone` with reason 1 to every device with a live lease in either
  direction, and ends every lease it holds. The socket closes after that, or after 500 ms,
  whichever comes first. **(New.)** The stops and the `gone` frames together are no more than
  the presence pacer can release within those 500 ms — at most 22, when its bucket is full —
  and the `gone` frames go to the devices most recently heard first, ties by device id. A
  device left out was sealed nothing, so it costs nothing; it learns from its own 40 s expiry.

### 3.7 The bound on dropped frames

A presence frame the server drops was sealed on the same Double Ratchet chain as durable
messages, so the receiver derives a skipped key for it when the next message of that chain
arrives, and that key is never used: it lasts as long as the session. The bounds are 2,000
for one session and 20,000 for the sum over every session on the phone. A message that would
cross either asks the peer for the authenticated repair, which replaces that session and its
dead keys; nothing is lost. These rules, kept by the sender for each peer device, are the
budget:

- **P1, silence.** After the last frame committed from a device — a presence frame, a voice
  frame, or a durable envelope its session opened — at most 4 probes go to it, then none until a
  frame from it is committed again.
- **P2, the bucket.** A probe takes a token from that device's bucket, which holds 4 and gains
  one every 6 hours, and at most one probe a minute goes to one device: at most 8 in any 24
  hours.
- **L1, live frames.** Between two frames committed from a device, at most 8 live frames —
  renewals, answers, typing and `gone` — go to it.

A committed frame from a device resets P1 and L1 for it, never P2; a durable envelope resets P1
only. The ledger is durable, so neither a process restart nor a change of the audience refills
it. Per pair, that is at most 8 dead keys a day with no vanish, plus at most 8 for each time
the phone vanishes with a chat open; §8.2 gives the totals for one phone.

### 3.8 Pacing, sealing and peer reads

- **The pacer.** Presence frames leave through a bucket of 16 refilled at 12 a second, beside
  voice's own of 32 refilled at 24 and the acknowledgements' 10 a second. The worst second is 28
  presence, 56 voice and 10 acknowledgement frames: 94 of the 100 a socket may send.
- **Sealing on release (new).** A presence frame MUST be sealed only when the pacer can release
  it at once: a round or a goodbye seals in batches of at most the tokens the pacer holds at that
  moment, and stops sealing when its conversation closes, the app leaves the foreground or the
  socket is closing. A frame sealed and not sent advances a chain whose message never leaves,
  which is a drop by another name.
- **Peer reads.** The targets of a seal are resolved with one `POST /api/v1/peers` for up to 64
  accounts, reused for at most 10 s; a seal that needs an account the answer did not cover reads
  again, and any change this phone makes to a contact's trust or block state discards it at
  once. A 50-member group is one call of 49 accounts.

### 3.9 The last seen

- The last seen of a device is this phone's own clock at the latest presence frame it admitted
  from that device, a `gone` included. It is written when that device's online state ends, and
  at most once a minute while it lasts. An account's last seen is the newest over its devices.
- It is kept in the encrypted database (`presence_devices`), never synced and never sent. It is
  only what this phone saw: a peer online while this phone was not watching does not move it,
  and neither does a durable message.
- It is shown only for an account in this account's audience, and it is deleted when the account
  leaves the audience (§4.3) or its device sends `gone` with reason 2.
- **Its precision.** "last seen today at 14:05" and "last seen yesterday at 14:05" by this phone's
  local date and its 12- or 24-hour setting; an earlier date in the current year as the
  timeline's medium date ("last seen Mon, Oct 12"); **(new)** a date in an earlier year as the
  same date with its year ("last seen Sun, Oct 12, 2025"). The precision stays exact: everyone who sees a last seen was
  admitted to watch the account in real time, so a coarser display would hide nothing from them
  that the frames had not already shown (rejected alternative:
  [`REJECTED_PROPOSALS.md`](../../REJECTED_PROPOSALS.md) 23).

### 3.10 The constants

| Constant | Value | Client ADR-098 |
|---|---|---|
| Bucket | 1024 bytes (942 of plaintext) | ADR-098 D2 |
| `lease_ms` sent / admitted | 40,000 / 1 to 60,000 | D2 |
| Live window, online window | 40 s | D4 |
| Renewal | every 25 s | D4 |
| Renewal answer window | 10 s **from the frame leaving the pacer** | D4, amended |
| Typing: ttl, repeat, idle stop, pace | 15 s, 10 s, 5 s, 1 frame per 5 s | D3 |
| Group: members, devices of each | every group (at most 50), 2 | D4, amended |
| Direct conversation: devices | every live device, at most 10 | D4 |
| P1, P2, L1 | 4; 4 + 1 per 6 h, ≤ 1 a minute; 8 | D6 |
| Presence pacer | 16, refilled at 12 a second | D7 |
| Goodbye | ≤ 500 ms, **≤ what the pacer releases in it** | D5, amended |
| Peer reads | ≤ 64 accounts a call, reused ≤ 10 s | D7 |
| Router queue | 256, oldest dropped | D1 |

## 4. Who can see my status

### 4.1 The three settings

| Setting | Its audience, minus every blocked account |
|---|---|
| **Everyone I share a chat with** (`everyone`, the default) | Every peer whose direct conversation with this account is `MUTUAL`, and every active member of an active group this account is an active member of whom this user has verified |
| **My contacts** (`contacts`) | Every peer on the contact list whose direct conversation is `MUTUAL` |
| **Nobody** (`nobody`) | No one |

The setting belongs to the account, not to a phone: it lives in the privacy record (§5), and
every device of the account applies it. The default, when no record exists and the account has
no other device, is `everyone`, which is what ADR-098's switch did when it was on (§5.2).

### 4.2 Reciprocity

A device watches, answers, sends typing to, and shows the online state, typing and last seen of
**exactly the accounts in its own audience** (§3.3, §3.4). So one person sees another's status
only when each is in the other's audience: whoever hides their status from someone sees nothing
of that person's, and `nobody` sees no one. Under `nobody` a device sends no presence frame at
all, apart from the goodbyes of §4.3, and still lets the router commit every frame it receives,
which spares the sender a dead key.

### 4.3 Narrowing and widening

- **Narrowing** — `everyone` to `contacts`, or either to `nobody`, and any account leaving the
  audience by a change of §3.3. Each device of the account, when it applies the record or the
  change that narrows it, MUST at once:
  1. send `gone` with reason 2 to every device with a live lease in either direction whose
     account is no longer in the audience — unless that account is blocked, which is sent
     nothing;
  2. end those leases, and stop showing those accounts' online state and typing;
  3. delete the stored last seen of every account no longer in the audience.

  To `nobody`, that is every live lease and every last seen, exactly as ADR-098's switch-off did.
  The probe ledger is kept.
- **Widening** sends nothing; the next round of a watch covers the accounts it added.
- **Receiving `gone` with reason 2** ends that device's online state and every lease for it at
  once, and deletes its last seen. The reason's words change from "turned status off" to
  "stopped sharing their status with you"; its bytes and its handling do not.

### 4.4 The words

These carry privacy meaning, so their words are part of the requirement. The English is
binding; the Persian MUST say the same and be read by a native reader.

- **Settings.** The row **Who can see my online status** replaces **Show my online status**
  (`frontend/docs/ui-specification.md` §15, item 5c), with the three choices of §4.1 and the
  line: "Applies on all your devices. You see other people's online status only if they are
  among the people you let see yours."
- **The disclosure.** The point ADR-098 D10 added at revision 11 says "You can turn this off
  for this phone in Settings, under Show my online status", which is no longer true. The
  disclosure moves to revision 12, and the point reads:

  > While this app is open on your screen, the people you let see your status can see that you
  > are online and when you are typing, and they learn when you open your chat with them or a
  > group you share. After you leave the app, they see when they last saw you online. You
  > choose who they are in Settings, under Who can see my online status: everyone you share a
  > chat with, only your contacts, or nobody. The choice applies on all your devices, and you
  > see other people's status only if they are among the people you let see yours. The server
  > cannot read any of this, but it can see that your phone sends short signals to theirs while
  > a chat is open.

  A reader who accepted revision 11 is shown this point once, marked as changed.

## 5. The privacy record (`CPCTV001` kind 7)

### 5.1 Layout

`CPCTV001` is the payload family of
[`CLIENT_CONTACTS_AND_TRUST.md`](CLIENT_CONTACTS_AND_TRUST.md) §6, carried in ordinary durable
envelopes; this document adds kind 7 to it, and §6.2 there admits it.

```text
payload = "CPCTV001" || 07 || count:u16be (= 1) || record
record  = revision:u32be || author_device_id[16] || presence_audience:u8 || read_receipts:u8
          presence_audience: 0 nobody, 1 contacts, 2 everyone
          read_receipts:     0 off, 1 on
```

A payload is refused whole when `count` is not exactly 1, when it is not exactly 33 bytes long,
or when `presence_audience` is above 2 or `read_receipts` above 1. Kind 7 comes only from this
account's own devices: one from a peer's device is refused and quarantined with a security
reason, as kinds 1, 2 and 6 are. Its registry name is `privacy.settings_set`.

### 5.2 The register

Kind 7 is one register for the account, ordered by `(revision, author_device_id)` — the revision
as an unsigned 32-bit integer, then the 16 raw device-id bytes — as kinds 1 and 2 are, with one
addition for the migration:

- A received record replaces the held one when its key is greater; an equal key is the same
  write and changes nothing.
- **Revision 0 is the migrated default** (§5.4). Two records at revision 0 merge field by field
  to the more private value — `nobody` before `contacts` before `everyone`, and off before on —
  keeping revision 0 and the greater of the two authors. A record at revision 0 never replaces
  one at a higher revision, and any record at revision 1 or above replaces one at revision 0.
- A change made on this device writes `revision = held revision + 1` (1 when none is held) and
  `author_device_id = this device`. A register at revision 4,294,967,295 takes no further change.
- **A device that holds no record** uses the defaults — `everyone`, and read receipts on — only
  when its account has no other live device. While another live device exists it MUST NOT send
  a presence frame or a read receipt, and its Settings show the choice as not yet known from the
  user's other devices and let the user make it, which writes a record. Either a record from an
  own device or the user's choice ends the wait. A record that cannot be read from local storage
  stops this device in the same way until it can be read.

### 5.3 When it is sent

- On every change, at once, to every other live device of this account, and to no other
  account's device.
- To each new live device of this account, as soon as this device learns of it from the
  account's device list, whether or not a history transfer runs: without it, a device added
  with no transfer would never learn a choice made before it existed.
- In the history-transfer snapshot, beside the contact records
  (`CLIENT_CONTACTS_AND_TRUST.md` §3.5).
- Once, at the migration (§5.4).

Every device applies a record the moment it holds it: §4.3 when the audience narrows, §6 at the
next read.

### 5.4 Migrating `presence.share.v1`

At the first start of a build that implements this document, once, each device whose database
an earlier build created — one that carries ADR-098's schema 26 — does what follows. A device
enrolled with a build that implements this document runs no migration: it has no switch to
carry over, and §5.2 tells it what to do with no record.

1. reads ADR-098's preference `presence.share.v1`: `off` becomes `nobody`, and anything else —
   `on`, a missing row or an unreadable one, which ADR-098 itself reads as on — becomes
   `everyone`;
2. if it holds no kind-7 record, holds a revision-0 record of that audience with read receipts
   on, authored by itself, and sends it to its own devices; if it holds one at revision 0, it
   merges its own into it (§5.2); if it holds one at a higher revision, another device has
   already recorded a choice, and that choice stands;
3. deletes `presence.share.v1` in the same transaction;
4. applies §4.3 when the record it now holds is narrower than what its switch was doing.

So two devices that disagreed — one on, one off — converge on `nobody`, and a choice the user
already made on an updated device is never overwritten by a migration.

**A device that has not updated** still follows its own `presence.share.v1` switch and knows
nothing of kind 7, which it would refuse as a payload it cannot decode. Until every device of
the account runs a build that implements this document, the account's devices may disagree, and
an old device that is switched on keeps answering the audience ADR-098 answers.

## 6. Read receipts in direct conversations

- **The setting** is `read_receipts` in the privacy record: on by default, for the whole
  account. It governs direct conversations only.
- **Off, sending.** No device of the account seals a `receipt.read` for the peer of any direct
  conversation. The read state still syncs between this account's own devices: a `receipt.read`
  sealed for this account's other devices only, the shape a group read receipt already takes
  when the sender of the messages it names has left the group (client ADR-091). Delivered
  receipts are unchanged.
- **Off, showing.** No device of the account shows a peer's read state in a direct
  conversation: an own message shows at most its delivered state, never the second tick that
  means *seen*. Read receipts that arrive while the setting is off are admitted and stored as
  any receipt is (`CLIENT_CONTACTS_AND_TRUST.md` §5.6), and are shown if the setting is turned
  on again.
- **Turning it on again** sends no read receipt for anything read while it was off.
- **Groups always send read receipts**, whatever the setting, and the reader list of an own
  group message is unchanged (client ADR-091).
- **The words.** A switch row **Read receipts** in Settings, with the line: "Off: people you
  chat with directly don't see when you have read their messages, and you don't see when they
  have read yours. Applies on all your devices. Groups always show who has read a message." The
  English is binding; the Persian MUST say the same and be read by a native reader.

## 7. Who reacted

- **No wire change.** Every member already holds the reaction events: a reaction is an
  application event of its conversation, sent to every member as a message is. The list is
  built from this device's local state alone and asks the server nothing.
- **What counts.** The reactions the client already folds: one per account per message — the
  latest `message.reaction_set` of that account by the existing mutation order — among the
  events this device admitted under the rules it already applies. In a direct conversation that
  is §5.6 of `CLIENT_CONTACTS_AND_TRUST.md`; in a group, an event from an active member, and a
  copy from a sender this device has not verified is held unopened until it is (client ADR-093
  D8). A reaction removed by its author is not listed. A member who left keeps the reaction they
  made while a member.
- **The list.** The message's context menu gains **Reactions** when the message has at least one
  reaction, and it opens a sheet with a tab **All** and one tab per emoji. The emoji tabs are
  ordered by count, highest first, ties by the earliest `ordering_ms` of the events the fold kept
  for that emoji. A tab lists one row per account — the name the conversation already gives that
  account (a group member's name, else a contact's label, else "Unknown member") and, under
  **All**, its emoji — this account first, then by the `ordering_ms` of the event kept, newest
  first, ties by account id. Every chip's count MUST equal the number of rows in its tab. The
  chip's own tap is unchanged: it sets or removes this user's reaction.
- **Who sees it.** Every member of a group, and both people of a direct conversation, each from
  their own copy. Two members' lists can differ only while one of them holds a member's copies
  unopened.
- **A blocked member.** Counted and listed like any other, so the count and the list stay one
  set; a client that collapses a blocked member's content MAY name the row "Blocked member".

## 8. Groups of up to 50 members: what one query costs

### 8.1 The gateway

One watch round of a 50-member group reaches at most 49 × 2 = **98 devices**, and at most 98
`here` answers come back to the asking socket.

| Limit ([`backend/realtime/API.md`](../../backend/realtime/API.md)) | One round of 98 |
|---|---|
| 100 frames a rolling second from one socket (close `4008`) | The pacer releases 16 at once and 12 a second after, so the round takes 6.8 s and the worst second is still 28 presence frames: 94 of 100 with voice and acknowledgements at their worst |
| 256 undelivered frames queued for one socket (close `4008`) | At most 98 answers, arriving as paced as the watches that caused them. Even a round that meets every other member's watch is 196 frames, about 274 kB over 6.8 s, which the queue holds on any link faster than about 40 kB a second; the router's own queue of 256 holds them with room for a call |
| A `signal` blob of exactly 1024, 4096 or 16384 bytes | Every presence frame is 1024 |
| The renewal every 25 s | 6.8 s, well inside it; the answer window counts from each frame's departure (§3.4) |

Across the server, each frame is one relay. With every member of one 50-member group holding the
chat open on one device, that is 50 × 49 × 2 frames every 25 s, about 196 relays a second; with
two devices each, about 784; at the band's ceiling — 50 accounts with 10 devices each, all in one
group, all with it open at once — about 3,920. The gateway relays 1,520 to 3,550 a second on the
1-vCPU serving host and 14,200 to 15,200 on the developer machine, measured through its own test
driver against a real Redis ([`GROUND-TRUTH.md`](../architecture/GROUND-TRUTH.md) §4). The
host's slowest round is about eight times the first figure above and about twice the second; the
theoretical ceiling is more than even its fastest round, as the ceiling ADR-098's 32-member bound
put near 1,600 was already more than its slowest. The review of these numbers is in
[`DESIGN-RECORD.md`](../architecture/DESIGN-RECORD.md) § "6. Review log", 2026-10-22.

### 8.2 Dead skipped keys

Per pair of devices nothing changes: at most 8 probes a day, at most 8 live frames for each time
a phone vanishes with a chat open, and at most 12 from one sender however long a phone is away
(§3.7). What grows with a 50-member group is the number of devices that may probe one phone — the
devices of 49 members, against 31 in ADR-098's bound.

| One phone, in one active group | ADR-098, 32 members | This document, 50 members |
|---|---|---|
| Realistic: 1.5 devices a member, 1 to 5 dead keys a pair a day | 46 to 232 a day: the 20,000 bound after 86 to 430 days | 74 to 367 a day: after 54 to 270 days |
| Worst case: 10 devices a member, 8 a pair a day | 2,480 a day: after 8 days | 3,920 a day: after 5 days |

The worst case needs every probe to meet a phone that is away and, by P1, that phone to have
spoken to every sender in between, so nobody reaches it by accident. At either bound a session
is repaired and nothing is lost; the cost is a repair round trip on the pairs that reach it.

## 9. What the server sees

- No route, column, setting, rate scope or stored value changes, and nothing changes at rest:
  the seizure yield of `SECURITY.md` is the same.
- **Presence** is `signal` frames, which the gateway relays and forgets, so live root sees which
  device signals which device, and when. Since ADR-098 that shows reading activity and not only
  sending: a phone with a chat open sends a frame to each watched device every 25 s and gets one
  back from each that is on screen. `SECURITY.md` § "Residual risk" states it. A phone whose
  audience is `nobody` sends none of it. Which devices a phone watches and answers shows live
  root its audience setting, as the receipts it sends show its read-receipt setting.
- **The privacy record** is one 1 KiB envelope to each of this account's other devices for each
  change, and one at the migration.
- **Read receipts off** removes the read receipts a device would have sent to a peer's devices.
  Every receipt is a 1 KiB envelope like any other, but live root can count them: after a peer's
  messages arrive, a device with read receipts on sends that peer's devices a delivered receipt
  and, once the conversation is read, a read receipt; with them off it sends only the first, and
  the difference shows over a few exchanges.
- **Who reacted** sends nothing.

## 10. Security analysis

- **Leaks to an unverified or blocked account.** Nothing is answered, watched or typed to a peer
  outside the audience, and the audience never holds a blocked account, an unverified group
  member, or a direct peer short of `MUTUAL` (§3.3, §4.1). The check runs again for every frame
  sealed, and a block, a trust drop or a group removal ends the account's leases at once, so a
  lease granted a minute earlier carries nothing past the change. A refused frame gets no
  answer, so a refused sender cannot tell "not in the audience" from "not on screen".
- **A new device.** It learns the account's choice from the first own device that sees it join,
  and until then it sends no presence frame and no read receipt if another device of the
  account exists (§5.2, §5.3), so a choice made before it existed is never overridden by the
  defaults.
- **What narrowing tells.** The accounts that leave the audience each receive one `gone` with
  reason 2, which tells them the user stopped sharing with them, and deletes the last seen their
  phone held. Sending nothing would leave that last seen on their phone; the frame is the smaller
  disclosure, and ADR-098 made the same choice for its switch.
- **Forged settings.** Kind 7 is admitted only from this account's own devices, which the
  pairwise session authenticates; a peer cannot change anyone's audience or read-receipt setting.
  A migration can only narrow a setting another device migrated (§5.2).
- **Downgrade.** A device of the account that has not updated follows its own switch (§5.4). No
  peer can make an updated device fall back to ADR-098's rules: there is no negotiation to fake.
- **Replay.** A presence frame is ordered by its `(instance_id, counter)` and refused when it is
  not newer; the ratchet refuses a replayed ciphertext. Kind 7 is idempotent by its order key.
- **Exhaustion.** Probes, live frames, typing and the goodbye are bounded (§3.5 to §3.8); the
  router's queue is 256; a 50-member round is 98 frames.
- **The server** can drop any frame, so the status is a lower bound and never a claim that a peer
  is offline; it can stop delivering the privacy record to one device, which then keeps its
  previous setting until it receives it.

## 11. What the client must prove

Each of these is a test that fails when the rule is broken, alongside the vectors of §12:

- a watch, `here` or `typing` from a direct peer short of `MUTUAL`, from a blocked account, from
  an unverified group member, or from an account outside the audience gets no answer, no lease
  and no status shown — and is still committed;
- under `contacts`, a group watch from a contact is answered and one from a non-contact is not;
  under `nobody`, nothing is sent but the goodbyes of a narrowing;
- blocking an account, its conversation leaving `MUTUAL`, or its removal from the group ends its
  leases at once: no typing frame or answer reaches it afterwards, and a blocked account is sent
  no goodbye;
- a device whose account has another live device, and that holds no privacy record, sends no
  presence frame and no read receipt until a record arrives or the user chooses; an own device
  sends its record to a new own device as soon as it sees it, with no history transfer;
- narrowing sends `gone` with reason 2 to exactly the live leases whose accounts left, ends their
  leases and deletes exactly their last seen; widening sends nothing;
- a renewal answered 9 s after its frame left the pacer is live, even when the round started 15 s
  earlier;
- a round cut short by leaving the foreground seals nothing that is not sent, and a goodbye to 40
  lease holders seals at most what the pacer releases in 500 ms;
- presence works in a group of 50 members, at 2 devices each and never more;
- two migrated records, one `everyone` and one `nobody`, converge on `nobody`; a migration never
  replaces a record at revision 1 or above; `presence.share.v1` is gone after the migration; a
  device enrolled with this build runs none;
- a kind 7 from a peer is refused; one at revision 4,294,967,295 takes no change;
- with read receipts off, no `receipt.read` is sealed for a direct peer, the own devices still
  get theirs, no second tick shows, and turning it on sends nothing for what was read meanwhile;
  a group still sends its read receipts;
- the reaction list's tabs and rows match the chips' counts, and a removed reaction is not
  listed;
- a last seen from an earlier year shows its year.

## 12. Golden vectors

Line breaks inside a value are not part of it. Every value was generated twice with identical
output and reproduced by a second, independent implementation; each refusal is refused for the
reason in its row by both.

### 12.1 `CPPSV001`

The inputs are the client's own golden test
(`frontend/test/features/signals/presence_signal_codec_test.dart`): sender user
`00000000-0000-4000-8000-000000001001`, device `00000000-0000-4000-8000-000000000901`,
`instance_id` `ab` × 16, counter 4,294,967,295, conversation `cd` × 32. The first five values are
that test's own bytes.

```text
watch (110 bytes)
  43505053563030310101a6005000000000000040008000000000001001015000
  0000000000400080000000000009010250ababababababababababababababab
  ab031affffffff085820cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  cdcdcdcdcdcdcdcdcdcd09199c40
here, typing (108 bytes)
  43505053563030310102a6005000000000000040008000000000001001015000
  0000000000400080000000000009010250ababababababababababababababab
  ab031affffffff085820cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  cdcdcdcdcdcdcdcdcdcd09f5
typing, active (112 bytes)
  43505053563030310103a7005000000000000040008000000000001001015000
  0000000000400080000000000009010250ababababababababababababababab
  ab031affffffff085820cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  cdcdcdcdcdcdcdcdcdcd09f50a193a98
typing, stopped (108 bytes)
  43505053563030310103a6005000000000000040008000000000001001015000
  0000000000400080000000000009010250ababababababababababababababab
  ab031affffffff085820cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  cdcdcdcdcdcdcdcdcdcd09f4
gone, left the foreground (73 bytes)
  43505053563030310104a5005000000000000040008000000000001001015000
  0000000000400080000000000009010250ababababababababababababababab
  ab031affffffff0801
gone, stopped sharing with you (73 bytes)
  43505053563030310104a5005000000000000040008000000000001001015000
  0000000000400080000000000009010250ababababababababababababababab
  ab031affffffff0802
```

**Not applied**, each by the rule in its row. Every payload is one of the values above with the
one change its row names; the byte offsets count from 0.

| Payload | Outcome |
|---|---|
| The watch, its last 4 bytes `09199c40` replaced by `0900` (a lease of 0) | Dropped: out of range |
| The watch, `09199c40` replaced by `0919ea61` (a lease of 60,001) | Dropped: out of range |
| The watch, `09199c40` replaced by `091a00009c40` (40,000 in a longer integer form) | Dropped: non-canonical encoding |
| The active typing, its last byte `98` replaced by `99` (a ttl of 15,001) | Dropped: out of range |
| The stopped typing, its last byte `f4` replaced by `f5` (active, and no ttl) | Dropped: key set |
| The active typing, `09f5` replaced by `09f4` (stopped, and a ttl) | Dropped: key set |
| The watch, its last 39 bytes reordered as `09199c40` then `085820` and `cd` × 32 (key 9 before key 8) | Dropped: non-canonical encoding |
| The watch, its byte 10 `a6` replaced by `a7` and `0400` inserted before `085820` (the reserved key 4) | Dropped: key set |
| The `gone` of reason 1, its last byte `01` replaced by `03` (reason 3) | Dropped: out of range |
| The watch, its byte 8 `01` replaced by `02` (version 2) | Dropped: unsupported version |
| The watch, its byte 9 `01` replaced by `05` (kind 5) | Ignored: unknown kind |

### 12.2 `CPCTV001` kind 7

The inputs of `CLIENT_CONTACTS_AND_TRUST.md` §4.8 and §6.6: Alice's phone
`b3a91c77-2e5d-4f28-a1c9-8d64e0f3b522` and tablet `0d4c8e2a-5b7f-4c1d-9e3a-7f2b6c8d1e40`.

```text
Alice's phone, revision 0, the migrated default: everyone, read receipts on (33 bytes)
  435043545630303107000100000000b3a91c772e5d4f28a1c98d64e0f3b52202
  01
Alice's phone, revision 1: nobody, read receipts on (33 bytes)
  435043545630303107000100000001b3a91c772e5d4f28a1c98d64e0f3b52200
  01
Alice's tablet, revision 3: my contacts, read receipts off (33 bytes)
  4350435456303031070001000000030d4c8e2a5b7f4c1d9e3a7f2b6c8d1e4001
  00
```

**Merges** (§5.2):

| Held | Received | Result |
|---|---|---|
| Phone, revision 0, `everyone`, on | Tablet, revision 0, `nobody`, on | Revision 0, `nobody`, on |
| Tablet, revision 0, `nobody`, on | Phone, revision 1, `everyone`, on | The phone's record |
| Tablet, revision 2, `everyone`, on | Phone, revision 2, `contacts`, off | The phone's record: `b3a9…` is above `0d4c…` |

**Refused**, each by the rule in brackets:

| Payload | Rule |
|---|---|
| `435043545630303107000100000001b3a91c772e5d4f28a1c98d64e0f3b5220301` | out of range (an audience of 3) |
| `435043545630303107000100000001b3a91c772e5d4f28a1c98d64e0f3b5220002` | out of range (read receipts of 2) |
| `435043545630303107000200000001b3a91c772e5d4f28a1c98d64e0f3b522000100000001b3a91c772e5d4f28a1c98d64e0f3b5220001` | count (the record twice, under a count of 2) |
| `4350435456303031070000` | count (0) |
| `435043545630303107000100000001b3a91c772e5d4f28a1c98d64e0f3b522000100` | trailing bytes |
| `435043545630303107000100000001b3a91c772e5d4f28a1c98d64e0f3b52200` | truncated |
