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
| [`backend/SECURITY.md`](backend/SECURITY.md) | What is protected, what a seizure yields, and what is structurally out of reach |
| [`docs/architecture/decisions/`](docs/architecture/decisions/) | The proposals that were **accepted**, one ADR each |

An entry here routes to the ADR that holds the accepted alternative rather than
repeating it.

---

### 1. Sealed sender

**Protects.** The sender's identity from the server.

**Rejected.** At rest it is already structural: no stored envelope carries a sender
column, and sender identity exists only inside ciphertext
([`backend/SECURITY.md`](backend/SECURITY.md)). What sealed sender would add is
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
directory a client searches to find a contact.

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
([`backend/SECURITY.md`](backend/SECURITY.md)).

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
`backend/SECURITY.md` states plainly that this bounds the window and not the residue.

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
