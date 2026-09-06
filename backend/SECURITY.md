# SECURITY.md — What this server protects, and what it does not

This document states the security properties of the backend exactly as the code keeps
them — no more. Where a property is best-effort, it says best-effort. Honesty is a
feature of this system, not a disclaimer.

## Threat model

The adversary is a **state actor with full root access to the running VPS** — not just a
forensic disk image but a live system: all storage, all memory, all logs, all traffic in
and out, and the ability to run modified server code.

**In scope — protected even under that adversary:** message content (text, files, and
voice audio), past and future; group membership and group contents as *content*; any
per-user action or state that could identify a user as the author of specific content.

**Out of scope:** hiding user IP addresses (connection-level visibility to the ISP is
accepted); hiding that the service exists or that a given IP connects to it; client
device compromise (a seized, unlocked phone bypasses everything).

**Operational constraint:** the system runs fully during a total national internet
shutdown, with only domestic network access — no public STUN/TURN, no FCM/APNs, no
external CDN, no external CA contact, no third-party API at runtime.

## What is protected

Message, group, profile, and attachment **content** is end-to-end encrypted by the
client. The server is a blind relay and blind warehouse: it authenticates accounts,
stores opaque padded ciphertext in exact size buckets, routes ciphertext to devices, and
relays volatile encrypted signals. It cannot read any content. Group messages are
pairwise: the sender encrypts one copy per member device under that device's
Double Ratchet session, so the server holds no group object, no roster, no epoch,
and no group key. **At rest** it also
stores no conversation graph — no sender column, no membership table, no recipient
lists, no shared-blob linkage — which is a real property of a seized disk, but it is
**not** social-graph protection against the live adversary: see the residual-risk
section below.

The server enforces **nothing security-relevant**. Cross-signing keys, device-bundle
signatures, and device-list log records are stored and relayed as opaque blobs, never
parsed, never verified — all verification is client-side (`CLIENT_CONTRACT.md`), against
keys the server has never seen. Server-side sanity checks (lengths, buckets, monotonic
versions) are malformed-input and anti-accident guards; a modified server would simply
not apply them, so no client may ever rely on one.

Session establishment is hybrid **X25519 + ML-KEM-768** (PQXDH-style), so recorded
ciphertext stays confidential against harvest-now-decrypt-later unless the attacker
breaks *both* primitives. PQ signatures are deliberately not used: forgery must happen
live, before the primitive is broken, so classical Ed25519 remains sufficient there.

## The precise key invariant

The literal "no private or symmetric keys anywhere on the server" is corrected here
to the precise, testable form — a TLS-terminating, authenticating server necessarily
holds *infrastructure* secrets:

> **No content-encryption key is ever transmitted to, stored by, or derivable by the
> server.** The server holds only infrastructure secrets and public key material. A
> disk/DB dump contains message data solely as ciphertext; a memory dump may additionally
> contain live infrastructure secrets and in-flight TLS-decrypted request bytes (auth
> tokens, the ciphertext blobs themselves) — which does not compromise message content.

| Key / secret | Class | Where it lives | Server sees it? | Compromise impact |
|---|---|---|---|---|
| Cross-signing master / self-signing / user-signing keys (private halves) | content | client secure storage; wrapped inside the recovery-protected key backup | never (public halves + signatures stored opaquely) | forge identity/device attestations for that user until re-verified out-of-band |
| Device identity key (ik), signed prekeys, one-time prekeys (private halves) | content | client secure storage only | never (only public halves uploaded) | that device's future DMs until healed (PCS) |
| ML-KEM-768 prekeys (decapsulation halves) | content | client secure storage only | never (only 1184-byte encapsulation keys uploaded) | strips the PQ layer of new sessions to that device; the classical layer still holds |
| Double-Ratchet / session keys | content | client memory/storage | never | past msgs safe (FS); heals (PCS) |
| Pairwise group session keys (one Double Ratchet session per member device, started from the same PQXDH bundles as a DM) | content | client | never | that pairwise session's group msgs; heals (PCS) |
| Attachment content keys | content | inside E2E messages | never | that attachment only |
| DTLS-SRTP session keys (one per voice connection) | content | the two client endpoints of that connection | never (neither this server nor coturn holds one, and no application-level media key exists) | that connection's audio until it closes |
| Recovery secret | content | user-held only | never | can unwrap the key backup → cross-signing private keys |
| TLS private key | infrastructure | server (nginx) | yes (by definition) | impersonate transport (mitigated by client SPKI pinning); no message content |
| JWT signing key | infrastructure | server env, at least 32 generated characters (`check --deploy` refuses less) | yes | mint session tokens → account access for `SESSION_TOKEN_DAYS` at a time; cannot decrypt any message |
| coturn shared secret (`TURN_STATIC_AUTH_SECRET`) | infrastructure | server env, and `static-auth-secret` in the coturn configuration — one value in two places, at least 32 characters once `TURN_URLS` names a relay (`check --deploy` refuses less) | yes | mint relay credentials → relay bandwidth for each credential's lifetime (AR-17); cannot decrypt any audio, which is keyed by DTLS between the two client devices |
| Django `SECRET_KEY`, Argon2 params | infrastructure | server env | yes | session/signing integrity; no message content |
| Password hashes (Argon2id) | auth (not a key) | DB | yes (hash only) | offline guessing per account; no message content |

`core/tests/test_seizure_guard.py` enforces the at-rest half of this table against every
model in the app registry, permanently.

## What a seizure of the disk and database yields

There is no sender column on any stored envelope, no group or membership table, no
recipient list, and no shared-blob linkage between co-recipients (each recipient device
gets an independent row copy). Sealed sender is structural **at rest**: sender identity
exists only inside ciphertext. There is **no server-side message history of any kind**;
message ciphertext exists only in the delivery queue, deleted on ack and capped at
**7 days** for devices that never collect it.

A full seizure of this server (disk + database) reveals, in total:

- the **user list** — usernames, Argon2id password hashes, activation flags,
  day-granularity account creation (irreducible for an authenticating server);
- per-user **device counts and public key material** — identity/prekey/ML-KEM public
  keys, cross-signing public keys and their opaque signatures, the day each device was
  added, the day each revoked device was revoked, and the device's revocation counter,
  one integer that says how many times its tokens were ended and nothing about when or
  by whom. **No activity day**: the server records nothing about when a device was last
  seen, when a key was last rotated or when a blob was last written (ADR-0024), so a
  seizure cannot separate a device in daily use from one that has not connected since
  the day it was added;
- per-user **device-list log records** — opaque client-signed blobs and nothing else;
- that **delivery happened, to which device, at hour granularity** — pending queue rows
  (at most 7 days deep, and at most `MAILBOX_MAX_BYTES` for each device) tie an opaque
  blob to a recipient device, never to a sender or a conversation; acked rows are
  deleted outright;
- per-user **attachment upload counts, bucketed sizes, and days** — no recipient data
  of any kind;
- the **admin audit log** — one row per administrative act the operator performed
  through the panel, holding the operator's account, a timestamp, the affected object
  and a plain-language sentence. It names what the operator did, so it shows which
  accounts were activated or deactivated, which devices were revoked and which
  attachments were deleted, at second granularity. It carries no blob, no key, no
  token and no password. `manage.py prune` deletes a row older than
  `ADMIN_AUDIT_RETENTION_DAYS`, **90 days** by default, so a seizure takes at most one
  quarter of operator history rather than the life of the deployment. One residue is
  worth naming: the row for a deleted attachment holds that attachment's id in
  `object_id`, which is the capability that used to download it — the row and its
  bytes are gone by the time the audit row exists, so it opens nothing.

No plaintext, no content key, no sender↔recipient pair, no group roster — anywhere at
rest.

## Residual risk — what remains exposed to live root

The following are **not** protected, and no document or code comment in this repository
may claim otherwise. In particular, the social graph is **not** hidden, protected,
private, or unlinkable.

1. **The social graph is not hidden from live root.** An adversary running modified
   server code sees, in real time, which authenticated connection writes to and reads
   from which device queue, and can log who-talks-to-whom and when. This is fundamental
   to a single box the adversary controls.
2. **Group membership metadata leaks through delivery fan-out.** The server holds no
   roster, but a group message is one envelope per member device, so the adversary
   sees which mailboxes a single send lands in and infers membership from that.
3. **Fact and timing of communication** (who is online, when messages flow, message
   sizes up to the padding bucket) are visible. Padding hides exact length; nothing
   here hides timing at 20 users.
4. **The server can deny service, and can equivocate** within a single client's view if
   it also controls whether that client reaches peers; device-list gossip detects
   equivocation only once two honest clients compare heads — detection, not prevention.
5. **Account existence and coarse metadata** (that an account exists, roughly when
   active) remain visible to root.
6. **Live root reads TLS session keys** and any plaintext transiently in memory
   (routing metadata, not E2EE content). Memory hygiene does not stop this.
7. **First-contact MITM is prevented only if users actually perform SAS/QR
   verification**; unverified contacts remain exposed to a one-time key substitution.
8. **Client device compromise** (out of scope) bypasses everything above.

In short: content is well protected; the social graph and communication timing are not,
and cannot be, on a single box under live root.

Also visible, below the live-root bar: **socket and signalling metadata** — which
devices hold a socket and when, and which device signals which device. The server holds
no presence of any kind: a client learns that a peer is reachable from its own
signalling and its own timeout, never from anything this server keeps.

## Voice

Voice is served by this revision, and the audio content of a call is protected on the
same terms as every other kind of content. Each connection is SRTP keyed by DTLS between
its two client endpoints, so the keys exist on those two devices and nowhere else:
coturn relays packets it cannot open, this server relays signal ciphertext it cannot
open, neither holds a DTLS key or a media key, and there is no application-level media
key for either of them to hold. Rotation is inherent — a connection's keys die with the
connection, and a member who has left has no connection and gets no offer.

The design is
[ADR-0021](../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md):
audio only, as a full mesh of WebRTC connections between client devices under a
relay-only ICE policy. The offers, the answers and the candidates travel inside
pairwise-session ciphertext over `/ws` `signal` frames, so this server relays them and
cannot read or replace a DTLS fingerprint. A room is client state carried over ordinary
envelopes, exactly as a group is, and the gateway holds no room, no membership and no
presence
([ADR-0022](../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md)).

The whole HTTP surface of voice is `POST /api/v1/me/relay` (`realtime/API.md`), which
mints an ephemeral coturn credential under the secret the two processes share. It reads
no row and writes none: a credential is computed rather than stored, and no table stands
behind it. The username it mints is a Unix expiry timestamp, a colon and sixteen random
bytes — no account identifier, no device identifier, and nothing derived from either —
so the credential itself tells coturn nothing about who holds it: two credentials of one
device look exactly like credentials of two devices, and nothing in one joins to anything
this server holds. What coturn does learn about a caller it learns from the traffic and
not from the credential — the source address of each allocation, and the pairs, sizes
and timing below — and the threat model above places addresses out of scope.

**The honest limits of that design.** A mesh costs each participant one uplink for each
peer, so the design point is at most ten participants in one room at this scale band,
and nothing above that is claimed. Every media path crosses coturn under the relay-only
ICE policy — which is what keeps one peer from learning another's address — so coturn
sees the relay allocation pairs, and with them which device talks to which device,
together with the packet sizes and the timing of each stream; participant count is
inferable from the relay load. The gateway sees which device signals which device. Room
membership is inferable from that fan-out, exactly as group membership is inferable from
envelope fan-out. Neither is protected by this architecture, and neither can be on a
single box under live root.

coturn also carries no TLS listener, so its control channel is readable on the wire: an
on-path observer sees the STUN allocation and permission requests, and therefore the
peer pairing, where a `turns:` listener would have hidden it from everyone but the relay.
It does **not** expose media, which is SRTP under keys DTLS established between the two
client devices, and it does not expose the shared relay secret, which is never
transmitted — a credential's password is the HMAC key that authenticates each request
and never travels. The trade is deliberate: in a relay-only mesh both endpoints' flows
terminate at this box anyway, so a passive observer correlates them by timing whether the
control channel is encrypted or not, and a TLS listener would have bought a certificate,
a private key and a renewal on a host whose whole posture is to hold neither.

## Best-effort features, worded honestly

Three deletion meanings are kept distinct in code, docs, and every client-facing
string:

1. **Remote-deletion request** (delete-for-everyone) — a best-effort message asking
   peers to drop content. It cannot force a device that already decrypted content to
   forget it.
2. **Server ciphertext deletion** — removing blobs from this server: on ack, or by TTL
   (queue 7 days, attachments 30 days). This frees
   storage and bounds what a later seizure holds; it is not a remote wipe.
3. **Cryptographic erasure** — content becomes undecryptable only once every surviving
   key copy is destroyed.

None of these is ever described as one of the others.

- **Recovery is all-or-nothing and unrecoverable by design.** The key backup wraps the
  cross-signing private keys and identity material; losing the recovery secret loses
  them. Message history lives only on devices — a new device gets history only from an
  existing device that is online to transfer it, and there is no server copy to restore.
  No server-side reset or "check secret" endpoint exists. A password reset (an owner
  admin action) affects authentication only and never recovers keys or history.
- **An exhausted one-time prekey pool weakens the session start, not the server.**
  When a device's classical or ML-KEM one-time pool is empty, its claimed bundle is
  served without that one-time component — never with a substitute — and the session
  starts on the signed prekey alone until the pool is refilled. Pairwise group fan-out
  drains pools faster than DMs did, so the client replenishes on the counts the server
  reports.

## Trust boundaries

- **A fully compromised client endpoint is outside the threat model.** If a device's OS
  or the app itself is hostile, no server property can help.
- **A malicious or seized server cannot read content.** It can observe everything in the
  residual-risk list, drop or delay traffic, and refuse service. Against a
  server-*forged* device, the defense is client-side: cross-signing (peers refuse
  unsigned devices), SAS/QR verification of master keys (the only first-contact MITM
  defense), and the client-signed device-list log, whose in-band head gossip turns
  server equivocation into cryptographic evidence once two honest clients compare.
  The server stores and relays all of that material without verifying any of it —
  a check it applied would be one a modified server could skip, and trusting it would
  be the failure mode.
- **Transport** is TLS 1.3 only, 0-RTT disabled, HSTS on, terminated by nginx under a
  private CA whose root is pre-distributed to clients. No live foreign CA, no CDN, no
  telemetry, no foreign STUN or TURN, no push relays — the system has no runtime
  dependency on any non-local network.
- **Authentication vs encryption identity are never conflated.** The password authorizes
  the account (Argon2id-hashed, and it issues one device-bound JWT of
  `SESSION_TOKEN_DAYS`, renewed on demand and never rotated, ADR-0023); a device's
  cryptographic identity is created client-side and only its public keys are
  uploaded. Five failed attempts on a name within fifteen minutes lock that name for
  fifteen minutes on both password surfaces — the API login and the admin panel —
  before any hash is computed, and a locked name answers the same whether or not an
  account holds it. Owner activation gates every account; revoking a device bumps its token
  generation, which kills every outstanding token of that device at once, and deletes its
  queue and its classical and PQ prekeys in one transaction.
- **A neighbouring process on the host is not trusted.** The VPS is shared, and
  loopback is reachable by every local process. Redis therefore requires a password
  in production (`manage.py check --deploy` refuses a `REDIS_URL` without one), and
  this process never turns a Redis value back into a Python object: the rate
  counters and the login lockout are read as strings through the
  redis client, and Django's cache framework — which unpickles everything it reads —
  is kept off Redis entirely. What Redis holds is volatile and content-free either
  way; what the password protects is the integrity of the counters, the lockout, and
  the frames on the fan-out bus.
- **No token is stored, so no login history exists at rest.** Revocation is one integer
  on the device row: `token_generation`, checked on every request and at every socket
  bind. A logout, a device revocation and an account deactivation each advance it, and
  every outstanding token of that device dies at once. A token table would have been a
  per-device login record — which is to say a login history — and this design refuses to
  keep one. The price is stated in `ACCEPTED_RISKS.md` AR-18: nothing rotates, so a
  token stolen from a device stays valid until its own expiry, and the server cannot
  tell the copy from the original.

## Verification

The properties above are enforced by the test suite, not by this document:
`core/tests/test_seizure_guard.py` (no plaintext/key/graph column can ever appear),
`core/tests/test_log_silence.py` + per-app log-silence suites (no identifier, blob, or
token reaches any log line), `core/tests/test_settings_posture.py` + `manage.py check
--deploy` (deploy posture, including a hard error on a `REDIS_URL` that carries no
password, and on a weak `JWT_SIGNING_KEY` or — once `TURN_URLS` names a relay — a weak
`TURN_STATIC_AUTH_SECRET`, both under `core.E005`; and `access_log off` in every nginx
server block — the reverse proxy sees every request path one hop before uvicorn does,
and would otherwise inherit a log of them from the packaged configuration), per-app
at-rest, no-graph, and no-history suites, the adversarial
cross-signing/PQ/device-log suites in `devices/tests/`, and
`ops/audit/offline_rehearsal.sh` (the repo rebuilds and passes with no network).
