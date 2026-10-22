# 0031. Online status stays client protocol over signal frames, and the gateway still holds no presence

- Status: Accepted
- Phase: — (a change to the released `v1` client contract, after the rebuild's eleven phases)
- Date: 2026-10-22
- Landed: 2026-10-22, as binding client text:
  [`docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md`](../../client/CLIENT_PRESENCE_AND_RECEIPTS.md),
  [`docs/client/CLIENT_VOICE_ROLES.md`](../../client/CLIENT_VOICE_ROLES.md), and
  `docs/client/CLIENT_CONTRACT.md` §R and §N rule 12. No server code, route, column, setting,
  rate scope or gateway frame changed; the client's work is `CLIENT_WORK.md`.

## Context

The owner decided four things on 2026-10-22: online status between the people of a
conversation, with a privacy setting for who can see it; a read-receipt setting for direct
conversations; a list of who reacted to a message; and roles in voice rooms. The first is the
one this record exists for, because it is the one that could have reopened
[0022](0022-the-gateway-holds-no-presence.md): the gateway held presence until phase 7, and the
owner's first decision is that it gains nothing back.

The client had already built online status by the time the owner decided. Client ADR-098
(accepted and built on 2026-10-19, PR #90) sends `CPPSV001` payloads in `signal` frames: a
`watch` of the chat on screen, renewed every 25 seconds; a `here` from each device that has the
app in the foreground; `typing`; and `gone` before the socket closes. Each frame the server drops
leaves a dead skipped key on its target's session for good, so ADR-098 bounds the probes it sends
to a device it has not heard from, and it bounds a group query: a group of at most 32 members,
at most 2 devices of each. The server relayed all of it without a change, because it is exactly
what [0022](0022-the-gateway-holds-no-presence.md) decision 3 said presence would be: client
protocol over `signal` frames, like the join, the leave and the query announcements of a call.

The owner's decisions agreed with ADR-098 in most things and diverged in four, which the binding
text lists one by one: a direct conversation needs both people verified, as
[0029](0029-a-contact-code-and-verification-by-both-people.md) made content need; a blocked
account gets nothing; a privacy setting of three values replaces ADR-098's switch; and groups of
33 to 50 members, which ADR-098 left without presence, get it — with the cost of one group query
stated at 50 members of up to 10 devices each. The last of those breaks a bound ADR-098 set to
protect the dead-key budget, so the owner was asked, with the dead-key and gateway cost of each
option, and chose on 2026-10-22: every group of up to 50 members, at most 2 devices of each. The
owner was asked one more thing and chose it the same day: the privacy setting and the
read-receipt setting belong to the account, synced between its own devices, not to a phone.

## Decision

### 1. Online status stays client protocol, and 0022 stands

The gateway gains no frame, no subscription, no set of devices and no state. Online status,
typing and the last seen remain `CPPSV001` in `signal` frames between devices, bound in
`CLIENT_PRESENCE_AND_RECEIPTS.md`.

**Why the flip trigger of 0022 is not met.** It reads: "A client surface that needs
server-derived presence for a set of devices it cannot enumerate itself. A client that can name
the devices can ask them." Every surface the owner asked for concerns devices the client already
names:

- the direct chat's header: the peer's live devices, from the authenticated device list the
  client reads to encrypt to them;
- the group header's count: up to two live devices of each member, read in one
  `POST /api/v1/peers` for up to 64 accounts;
- typing: the devices that watched the conversation, which told the client themselves;
- the last seen: only what this phone saw, so it needs nobody else's record;
- the audience: computed from the client's own contact list, verifications, group rosters and
  blocks, which the server does not hold and must not.

No surface asks about a device the client cannot name, and the client deliberately shows nothing
for a peer it has not heard from. A server-derived presence would bring back what 0022 removed: a
contact list declared to the server, and a frame composed out of the server's own knowledge.

**And the cost does not need the server either.** One query of a 50-member group reaches at most
98 devices. At the presence pacer it leaves in 6.8 seconds, the worst second stays at 94 of the
100 frames a socket may send, and at most 98 answers come back to a socket whose queue holds
256. Across the server, every member of a 50-member group holding the chat open on one device is
about 196 relays a second; the measured relay rate of the gateway is 1 520 to 3 550 a second on
the serving host, and 14 200 to 15 200 on the developer machine (Evidence, below).

### 2. One group query reaches at most two devices of each member, in groups of up to 50

The owner's choice. A third and later device of a member is not probed: a dormant tablet collects
no dead keys, and a member active on a third device is still seen when that device watches the
chat itself. Watching every device of every member was rejected — up to 490 frames a query, which
does not fit the 25-second renewal at a pacer the 100-frame second leaves room for, and which
probes dormant devices too (`REJECTED_PROPOSALS.md` 21). Three rules move with the larger query,
each closing a way a frame could be sealed and never sent: the answer window counts from each
frame's departure, a frame is sealed only when the pacer releases it, and the goodbye seals no
more than the pacer releases in the 500 ms the socket waits.

### 3. Who can see a person's status, and whether they send read receipts, belong to the account

`everyone` — every peer in a `MUTUAL` direct conversation and every verified member of a shared
group — `contacts`, or `nobody`; reciprocal, so a device watches and shows only the people it lets
see it. The setting and the read-receipt setting are one `CPCTV001` record of kind 7, a register
synced between the account's own devices like the contact list and the block list
([0029](0029-a-contact-code-and-verification-by-both-people.md)). A setting per phone, as ADR-098
had, was rejected by the owner: a second device the user forgot would reveal what the first one
hides (`REJECTED_PROPOSALS.md` 22).

### 4. Read receipts and who reacted need nothing of the server

The read-receipt setting governs direct conversations only and is reciprocal; groups always send
read receipts, and client ADR-091's reader list is unchanged. Who reacted is a list built from the
reaction events every member already holds, with no wire change.

### 5. Roles in voice rooms are client state, and 0021 stands

A room of protocol version 2 has an owner, admins and members; every change of membership, role or
name is a signed control event in the room's chain, and the role operation takes the value 5 that
version 1 reserved for it. Every version-1 room whose creator — the signer of its revision 1 — is
still a member is upgraded, with the creator as its owner, once every member's devices have
announced that they read version 2 — and never before, so a client that predates the change never
holds a room it cannot read and never forks one. A room whose creator has left keeps version 1:
naming a successor would let a member who removed the creator become an owner nobody can remove.
Muting
a participant, removing one from a call and ending a call for everyone are `signal` frames, each
applied by every honest participant against the sender's role in its own copy of the roster.

That is [0021](0021-relayed-webrtc-mesh-and-no-server-room.md) decision 7 unchanged — "a room is
client state, carried by client-signed control events over ordinary envelopes, exactly as a group
is" — with roles added to the state. The server holds no room, no role and no participant list,
and enforces nothing of it; the binding text says what a mesh with no server can and cannot
enforce, in the owner's words.

### 6. Where the text lives

Two new documents under `docs/client/`, as
[0030](0030-the-security-model-and-the-client-contract-move-under-docs.md) placed every binding
client text: `CLIENT_PRESENCE_AND_RECEIPTS.md`, routed from the contract's new §R, and
`CLIENT_VOICE_ROLES.md`, routed from its §N rule 12 and written as a complete delta against the
client's own `voice-signalling-v1.md`. `CLIENT_CONTACTS_AND_TRUST.md` admits the new `CPCTV001`
kind 7.

## What this does not do

- **It does not hide reading activity.** A phone with a chat open signals the devices it watches
  every 25 seconds, so live root learns who has which conversation open, with whom and when, and
  not only who sends. ADR-098 made that true on 2026-10-19; this record extends it to every group.
  `SECURITY.md` § "Residual risk" states it.
- **It does not make a role, a mute, a removal from a call or the end of a call enforceable against
  a modified client.** Nothing switches off a microphone.
- **It does not upgrade a room while any member device reads only version 1.** A member who never
  updates holds the room at version 1, and at equal authority, for everyone.
- **It does not change groups** — their read receipts, their admission or their trust rule.
- **It does not bring back any server presence**: no `subscribe_presence`, no `presence` frame, no
  announcement on connect or disconnect.

## Position fields

- **Forcing function.** The owner's decisions of 2026-10-22, against a client that had already
  built online status over `signal` frames and needed its rules and bounds stated where the server
  side binds them; and version-1 rooms, in which any member can eject any other with no authority
  to appeal to.
- **Scale band.** Band 0, holding through band 1. A query is bounded by the group ceiling of 50 and
  two devices a member, not by the population; what grows with the population is the gateway's
  relay rate, measured below on the serving host with a margin of about eight, at its slowest
  round, over the realistic peak of one group.
- **Flip trigger.** For presence, still 0022's: a client surface that needs presence for devices it
  cannot enumerate — and, on the cost side, a group ceiling above 50, or relays in real use
  reaching a quarter of the rate the gateway sustains on the serving host: about 380 a second, a
  quarter of its slowest measured round. For voice, 0021's: a role that must be enforced against
  a modified client needs a server in the media path, which is an SFU again.
- **Cost.** Reading activity visible to live root. More devices that can probe one phone — a phone
  in one active 50-member group reaches the 20 000 dead-key bound after 54 to 270 days in the
  realistic case, against 86 to 430 at 32 members, and is then repaired with nothing lost. One more
  own-device record. A Rust core change for room version 2, rooms that cannot gain roles until
  every member updates, and rooms whose creator has left, which never gain them. In-call actions
  that only honest clients obey.
- **Evidence.** Read from the client at `b237981`: `presence_channel.dart` (32 members, 2 devices,
  25 s, 40 s, the renewal recorded at the round's start, the whole round sealed before it is
  paced), `presence_probe_ledger.dart` (4, 4 + 1 per 6 h, 1 a minute), the `CPPSV001` codec and its
  golden test, and `drift_presence_stores.dart` (`presence.share.v1`, read as on when missing); the
  room core, `room_control.rs` (version 1 only, value 5 refused); and what a client that predates
  this record does with what it cannot read — an unknown room payload kind and a version-2 event
  are refused as envelopes and leave the room alone (`room_sync_payload.dart`,
  `native_room_control_crypto.dart`, `durable_sync_engine.dart`), and an unknown signalling
  version shows "One of you needs to update" (`voice_signal_codec.dart`, `app_en.arb`). The golden
  vectors were generated twice and reproduced by a second implementation, the signatures by
  OpenSSL 3.6.4 and the reference code of RFC 8032 as well; the generator first reproduced the
  client's own `CPPSV001` golden bytes and the core's golden room event. The relay rate was measured
  on 2026-10-22 on the developer machine (Apple M4 Max), through the gateway suite's own socket
  driver against a real Redis 8.8.0: fifty sockets, each sending 49 `signal` frames of 1024 bytes
  and answering the 49 it received — 4 900 relays in 322 to 345 ms, 14 200 to 15 200 a second, at
  65 to 70 µs of process CPU a relay with the driver's own work counted
  ([`GROUND-TRUTH.md`](../GROUND-TRUTH.md) §4). The same day, the same round on the 1-vCPU serving
  host, run as a standalone script that reads no database: 4 900 relays in 1 380 to 3 221 ms,
  1 520 to 3 550 a second, over nine rounds in three runs (§4 there). Its slowest round is about
  eight times the realistic peak of one 50-member group, and less than the band's theoretical
  ceiling — as it was already less than the ceiling ADR-098's 32-member bound put near 1 600. It
  replaces an assumption, the full suite's tenfold slowdown on the host, which had put the rate
  near 1 400. **Currency:** current.

## Consequences

- `docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md` and `docs/client/CLIENT_VOICE_ROLES.md` are new and
  binding; `CLIENT_CONTRACT.md` gains §R and §N rule 12; `CLIENT_CONTACTS_AND_TRUST.md` admits
  `CPCTV001` kind 7.
- `docs/security/SECURITY.md` states the reading activity that presence frames show, beside the
  socket and signalling metadata, and gains a paragraph on roles in § "Voice".
- `REJECTED_PROPOSALS.md` records eight alternatives, entries 21 to 28; the last of them was
  rejected by the design review of this record.
- `CLIENT_WORK.md` carries the client's work, the client documents it changes, and the client ADR
  that amends ADR-098 and supersedes ADR-077's D1 for version-2 rooms.
- The "Gateway state" and "Voice" positions of `DESIGN-RECORD.md` cite this record; neither 0021
  nor 0022 is superseded.
- `API_CHANGES.md` is unchanged: no observable server behaviour moved.
