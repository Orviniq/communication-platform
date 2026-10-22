# Rejected proposals

A defence on this list was considered for this system and turned down. It is not a
backlog and it is not a list of things nobody got to — each entry names what the
proposal would have protected, why it is not built, and the **trigger** that reopens
it. A trigger is an event, never a date.

Three neighbouring documents, so a reader lands in the right one:

| Document | What it holds |
|---|---|
| This file | A defence that was considered and turned down |
| [`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md) | An exposure the project understands and carries for now |
| [`docs/security/SECURITY.md`](docs/security/SECURITY.md) | What is protected, what a seizure yields, and what is structurally out of reach |
| [`docs/architecture/decisions/`](docs/architecture/decisions/) | The proposals that were **accepted**, one ADR each |

An entry here routes to the ADR that holds the accepted alternative rather than
repeating it.

---

### 1. Sealed sender

**Protects.** The sender's identity from the server.

**Rejected.** At rest it is already structural: no stored envelope carries a sender
column, and sender identity exists only inside ciphertext
([`docs/security/SECURITY.md`](docs/security/SECURITY.md)). What sealed sender would add is
concealment from the live process — and the authenticated socket that deposits the
envelope has already named the depositor to live root, one layer above anything a
sealed-sender construction touches.

**Reopens when.** A second relay hop exists that hides the depositing connection.

---

### 2. Cover traffic and constant-rate transmission

**Protects.** The timing of communication from live root.

**Rejected.** It only works if every device transmits constantly, and every byte of
that lands on the client as battery and mobile data — against the shipping rule, on a
fleet whose users are paying for the data. It also protects the wrong thing: the fact
that this application is in use is out of scope, and the padding buckets already remove
message length.

**Reopens when.** Nothing on the current threat model. A change to the threat model
that makes traffic timing the primary exposure would reopen it, and would need the
client cost measured on a real device first.

---

### 3. Mix networks, Tor, and multi-server anonymity

**Protects.** The social graph from any single operator.

**Rejected.** Every construction here needs more than one operator who do not collude,
and domestic infrastructure that survives a national shutdown. Neither exists. During a
shutdown, one VPS inside the country is the whole reachable network.

**Reopens when.** A second independent operator inside the same network exists and is
willing to run a relay.

---

### 4. Private information retrieval for key lookups

**Protects.** Which peer's keys a device asks for.

**Rejected.** Every practical PIR construction needs a second, non-colluding server. See
entry 3 — there is no second operator.

**Reopens when.** The same trigger as entry 3.

---

### 5. A server-held key transparency log

**Protects.** Against the server equivocating about a user's device list.

**Rejected.** The client-signed device-list log with in-band gossip already detects
equivocation, and it detects it between clients — against keys the server has never
held. A server-authored transparency log is data the adversary of this threat model
writes, so it would add an appearance of a guarantee and no guarantee.

**Reopens when.** A third party operates the log, on infrastructure this operator does
not control.

---

### 6. Confidential computing

**Protects.** Process memory from the host.

**Rejected.** No such hardware on this VPS, and the hosting provider controls the
hypervisor. Attestation against a hypervisor the adversary owns proves nothing.

**Reopens when.** The deployment moves to hardware the operator owns physically, with
an attestation root the operator can verify.

---

### 7. OPAQUE password authentication

**Protects.** A password the server would otherwise see at login.

**Rejected.** It protects the wrong asset here. The password authorises the account and
nothing else — it derives no key, opens no backup and reaches no ciphertext — and the
server stores an Argon2id hash of it. What it would cost is a new protocol
implementation in the client for that one property, which the shipping rule refuses.

**Reopens when.** A password ever derives key material, at which point the server seeing
it once would matter.

---

### 8. Rotating capability mailboxes

**Protects.** The identity of a mailbox from a copy of the disk.

**Rejected.** It hides nothing from live root, which watches the rotation happen. On the
client it is a rotating identifier that has to be agreed with every peer, out of band of
the messages themselves, and a peer that misses a rotation is a peer that cannot deliver.

**Reopens when.** A disk-copy adversary becomes the primary adversary of the threat
model, and the queue's day-granularity yield
([0025](docs/architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md))
is judged too much.

---

### 9. Hashed usernames at rest

**Protects.** The user list in a copy of the database.

**Rejected.** A username is low-entropy and a hash of one is reversed by dictionary in
seconds. Both surfaces that exist need the name in the clear anyway: the login, and the
exact-name lookup a client uses to find a contact
([0028](docs/architecture/decisions/0028-an-exact-username-lookup-replaces-the-directory.md)),
which replaced the directory and compares the name a person typed with the stored one.
There is no longer a list of names to search.

**Reopens when.** Nothing. This one does not work.

---

### 10. Hashed Redis keys

**Protects.** The account names in the rate counters and the day's upload allowance.

**Rejected.** Redis runs with persistence off and holds nothing on disk
([`GROUND-TRUTH.md`](docs/architecture/GROUND-TRUTH.md) §2), so the only adversary who
reads a Redis key is one reading process memory — who reads the pre-image beside it.

**Reopens when.** Redis is ever given persistence, which would be a seizure-yield change
needing an ADR of its own.

---

### 11. A volatile journal

**Protects.** Nothing that is currently at risk.

**Rejected.** The journal names no data — that is the invariant the silence suites
prove, not an accident
([0019](docs/architecture/decisions/0019-the-system-emits-no-request-scoped-telemetry.md)).
A volatile journal would lose the tracebacks that diagnose a crash and buy nothing back.

**Reopens when.** A log line is ever found to carry an identifier that the silence
suites did not catch, and the layer that emitted it cannot be fixed.

---

### 12. A LUKS data volume with manual unlock

**Protects.** The database and the attachment bytes in a cold copy of the disk.

**Rejected.** No gain against live root, which reads the mounted filesystem. And an
unattended reboot then fails: the one host a whole circle depends on during a shutdown
would sit at an unlock prompt until the operator can reach it. The cold-copy yield it
would protect is usernames, public keys, day-granularity counts and opaque blobs
([`docs/security/SECURITY.md`](docs/security/SECURITY.md)).

**Reopens when.** A disk-copy adversary enters the threat model as the primary
adversary.

---

### 13. The LiveKit end-to-end path as the voice design

**Protects.** Voice media from the server, in a packaged form.

**Rejected.** On the evidence
[0021](docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
records: a `connectivity_plus ^7.0.0` requirement against the client's frozen 6.0.5,
twelve added packages, a PBKDF2-derived 128-bit AES-GCM frame cipher that is not SFrame,
one plaintext byte per audio frame, and key management written in Dart. The relayed mesh
that replaced it is keyed by DTLS-SRTP between the two endpoints and the server holds no
media key at all.

**Reopens when.** Nothing. [0021](docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
supersedes [0016](docs/architecture/decisions/0016-client-held-voice-media-keys.md); a
reversal would need a new ADR.

---

### 14. RFC 9605 SFrame

**Protects.** Media frames end to end through a forwarding server.

**Rejected.** No Dart implementation exists, and `flutter_webrtc` exposes no
frame-transform hook to install one behind. Both halves are a fork, which the shipping
rule refuses. It also protects against a forwarding server this deployment no longer
has.

**Reopens when.** `flutter_webrtc` publishes a frame-transform API **and** a maintained
Dart or Rust SFrame implementation exists — and a forwarding server returns, which
[0021](docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
removed.

---

### 15. Resumable chunked uploads

**Protects.** A large attachment upload over a link that drops.

**Rejected.** The client's single-shot upload exists and is tested, nginx absorbs a slow
link by buffering the whole body before it opens the loopback connection
([`GROUND-TRUTH.md`](docs/architecture/GROUND-TRUTH.md) §4), and the download side
already resumes — the internal location honours a `Range` and answers `206`. What is
left is a genuine gap and a small one.

**Reopens when.** Measured upload failures on the fleet.

---

### 16. A mailbox hint frame without the blob

**Protects.** Nothing. It would reduce what a push frame carries.

**Rejected.** The client uses the pushed blob directly, so a hint costs one round trip
for every message before anything can be shown. The frame carries ciphertext the server
cannot open either way.

**Reopens when.** A push frame's size becomes a measured cost on the fleet — mobile data
or battery — rather than an aesthetic one.

---

### 17. Zeroing freed database pages on a schedule

**Protects.** A deleted row's bytes in the free space of a data file.

**Rejected.** There is no way to do it without rewriting the table under an exclusive
lock, on the hot path of the largest table in the schema. What persists there is bucketed
ciphertext, a recipient device id and a UTC day — no sender, no conversation, no content
key. The window is bounded instead, by the autovacuum storage parameters
[0026](docs/architecture/decisions/0026-host-posture-and-the-identity-backup.md) sets;
`docs/security/SECURITY.md` states plainly that this bounds the window and not the residue.

**Reopens when.** A disk-copy adversary enters the threat model as the primary
adversary.

---

### 18. A longer envelope retention window

**Protects.** A message for a recipient who is offline longer than the window.

**Rejected.** Every extra day is extra seizure depth, on the one table that holds
ciphertext at all. The client reads the window from `GET /api/v1/config` and can tell a
sender what it is, so the cost is visible rather than silent.

**Reopens when.** Assumption A6 of
[`DESIGN-RECORD.md`](docs/architecture/DESIGN-RECORD.md) fires — a user reports a
message that expired before delivery.

---

### 19. Foreign or federated push, including UnifiedPush and SMS wake-up

**Protects.** Delivery to a device whose socket is closed.

**Rejected.** Every form of it is a foreign runtime dependency, which is the one thing
this system is built to remove: during a shutdown the push service is on the wrong side
of the cut and the wake-up never arrives. UnifiedPush adds a second application on the
phone that has to be running; an SMS wake-up hands a carrier-held identifier — a phone
number — to a design that deliberately holds none. The socket, with the client's own
foreground service behind it, is the whole push path.

**Reopens when.** Nothing. A push path that survives a national shutdown is a
contradiction, and any of these would have to be defended as a second, best-effort path
in a new ADR rather than as a replacement.

---

### 20. SPQR, a post-quantum ratchet

**Protects.** Recovery after a device's session state has been exposed, against an
adversary who records the traffic and later holds a quantum computer. The Double
Ratchet's later steps are X25519 exchanges, so such an adversary, once it has a session's
state, can follow the session through the very exchanges that would otherwise heal it.
SPQR, which Signal announced on 2 October 2025, runs an ML-KEM-768 ratchet beside the
Double Ratchet and mixes the two, so the healing holds against that adversary as well.

**Rejected.** By the owner's decision, recorded on 2026-10-20. It is a change to the
shared Rust core on both of its boundaries: a second ratchet with its own state, chunked
and erasure-coded ML-KEM messages inside every ratchet message, a new session-state
format, and a migration of every live session — against a pairwise transport whose
version 1 is frozen around one ratchet. What it would add is narrow here. PQXDH already
makes every session's starting secret quantum-resistant
([`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §F), which is what protects
recorded traffic as long as no device's state is exposed; and the exposure SPQR heals
from is a compromised client device, which the threat model of
[`docs/security/SECURITY.md`](docs/security/SECURITY.md) places out of scope.

**Reopens when.** Only by an explicit owner decision.

---

### 21. A group's online status watching every device of every member

**Protects.** Nothing. It would show a member online on a third or later device that is in
the foreground but not watching the group itself.

**Rejected.** By the owner's choice of 2026-10-22, between three options costed in full
([ADR-0031](docs/architecture/decisions/0031-online-status-stays-client-protocol-over-signal-frames.md)).
A query of a 50-member group of ten-device members would be up to 490 frames, which the
presence pacer cannot send inside one 25-second renewal at any rate the socket's 100-frame
second leaves room for, and it would probe every dormant device of every member, each of which
then collects dead skipped keys. Two devices a member — at most 98 frames — cost neither.

**Reopens when.** A client surface needs the status of a device that is not among a member's
two most recently heard, which is a new owner decision with its own cost.

---

### 22. The status audience and the read-receipt setting kept per phone

**Protects.** Nothing. It would keep client ADR-098's per-phone switch and spare one own-device
record.

**Rejected.** By the owner's choice of 2026-10-22. A setting that hides a person's status on one
phone and not on the tablet they forgot reveals them the moment the tablet is opened; a person's
privacy choice belongs to the person. The account-wide record is `CPCTV001` kind 7
([`docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md`](docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md) §5).

**Reopens when.** Only by an explicit owner decision.

---

### 23. A coarse last seen, such as "recently" or "within a week"

**Protects.** The exact time a person was last online, from people allowed to see their status.

**Rejected.** The last seen is only ever shown to someone in the person's audience, and that
someone's phone was admitted to watch them in real time: the frames have already shown it the
exact moments the person was online while it watched. A coarser display would hide nothing the
frames had not shown, and would make the screen less true than what the phone knows. Hiding the
time from someone is done by leaving them out of the audience, which deletes the last seen their
phone holds.

**Reopens when.** A last seen is shown to anyone outside the audience — which this design never
does.

---

### 24. Admin rights granted one by one, as Telegram grants them

**Protects.** Least privilege inside a voice room: an admin who may mute but not remove, or end
a call but not rename the room.

**Rejected.** A minimal set was asked for. Fixed roles mirror the group's owner, admins and
members, which the client already builds, checks and shows; rights granted one by one add a
field to every role event, a rule for who may grant which right, a screen for it, and a chain of
grants to check on every device, for rooms of at most 50 members whose owner can make and unmake
admins at will
([`docs/client/CLIENT_VOICE_ROLES.md`](docs/client/CLIENT_VOICE_ROLES.md) §2).

**Reopens when.** An owner asks for a moderator who holds some admin powers and not others.

---

### 25. In-call actions as signed control events in the room's chain

**Protects.** A mute or a removal from a call that every member, a late joiner included, applies
from the same signed record, with an audit trail.

**Rejected.** A control event is durable and arrives when the recipient next drains its queue,
which may be after the call; a mute that lands an hour late is not a mute. It would also make
every mute a revision of the room's chain, and every concurrent pair of them a fork that
quarantines the room. The actions ride the call's own volatile signalling instead, checked
against each device's copy of the roster, and a newcomer learns them from the owner and the
admins in the call
([`docs/client/CLIENT_VOICE_ROLES.md`](docs/client/CLIENT_VOICE_ROLES.md) §5). Keeping someone out
for good is a removal from the room, which is a control event.

**Reopens when.** A call action must outlive the call.

---

### 26. Upgrading a room before every member's devices can read version 2

**Protects.** Nothing. It would start roles sooner in a room with a member who has not updated.

**Rejected.** A device that cannot read version 2 cannot open the upgrade, stays at the
version-1 state, and may sign a version-1 change the others then see as a fork. It would not know
it had been left behind: the room would fork on its side, silently
([`docs/client/CLIENT_VOICE_ROLES.md`](docs/client/CLIENT_VOICE_ROLES.md) §4.4).

**Reopens when.** A client exists that can be made to refuse a room it cannot read, rather than
diverge from it.

---

### 27. Letting an upgrade win over a change it crosses

**Protects.** A room from being quarantined when its upgrade and another change are signed
against the same revision.

**Rejected.** A rule that picks the upgrade makes the upgrade a veto. A member removes the owner
at revision *n*; the owner, or a server that controls delivery order, signs an upgrade against
revision *n − 1*; every device that saw the upgrade first would drop the removal. The fork rule
quarantines the room instead and lets no client pick a branch, which is what every concurrent
pair of changes already does
([`docs/client/CLIENT_VOICE_ROLES.md`](docs/client/CLIENT_VOICE_ROLES.md) §4.3).

**Reopens when.** Rooms gain a merge rule for concurrent changes in general, which would be
reviewed as a change to the chain itself.

---

### 28. A successor owner for a room whose creator has left

**Protects.** Nothing. It would give roles to a version-1 room whose creator — the signer of its
revision 1 — is no longer a member, by making the earliest remaining member the owner.

**Rejected.** By the design review of 2026-10-22. Version 1 lets any member remove any other, the
creator included, so a successor rule is a way for a member to make itself the owner: remove the
creator, and every member who joined earlier, then sign the upgrade. Equal authority that others
could contest would become an owner's authority that nobody can remove. Such a room keeps version
1 instead, and members who want roles make a new room
([`docs/client/CLIENT_VOICE_ROLES.md`](docs/client/CLIENT_VOICE_ROLES.md) §4.1).

**Reopens when.** A room can name its owner by a signed act of its members, rather than by an
order a member can arrange.
