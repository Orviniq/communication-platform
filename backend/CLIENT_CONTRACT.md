# CLIENT_CONTRACT.md — What the Flutter client must implement

This backend is a blind relay: it stores and serves key material and ciphertext as
opaque bytes and **verifies none of it**. Every security property below therefore lives
in the client. This document is the binding list of those client-side halves, written
for the Flutter developer. The server-side halves are specified in `SECURITY.md` and
the per-app `API.md` files; the residual-risk statement (what none of this protects) is
`SECURITY.md` § "Residual risk".

A server-side sanity check (length, bucket, monotonic version) is never a security
control. If the client ever skips a verification because "the server already checks
that," the design has failed — the server is the adversary.

## A. Key generation and storage

- On first install: generate **master**, **self-signing**, and **user-signing** Ed25519
  keys. Private keys go to platform secure storage (Keychain/Keystore) and **never**
  leave the device except inside the recovery-protected key backup blob
  (`PUT /me/keybackup`).
- Per device: an Ed25519 device signing key, X25519 identity + prekeys, and ML-KEM-768
  prekeys.
- **`ik_pub` carries two of those keys in one field: exactly 64 bytes, the Ed25519
  device signing public key (bytes 0–31) then the X25519 identity public key (bytes
  32–63).** The Ed25519 half verifies `spk_sig` and `pq_spk_sig`; the X25519 half is the
  identity key in X3DH/PQXDH. The server treats the field as opaque bytes and enforces
  only a loose length range, so a peer whose `ik_pub` is not 64 bytes is malformed **to
  you** — reject it; nothing upstream will.
- **Libraries:** use `mlkem_native` (FFI to the formally-verified pq-code-package
  mlkem-native, FIPS 203) for ML-KEM. Use `cryptography` or `pinenacl` for
  Ed25519/X25519. **Do not** use pure-Dart ML-KEM implementations such as `kyber-py` or
  `mlkem` — they are explicitly educational and **not side-channel safe**.

## B. What the client signs

- The **self-signing key** signs the canonical device-bundle encoding (below).
- The **master key** signs the self-signing and user-signing public keys.
- The **user-signing key** signs another user's master key after out-of-band
  verification.
- **Device-log records** are hash-chained and signed by the self-signing key.

### The one encoding rule

Every signature below covers an ASCII **domain separator**, followed by the
length-prefixed concatenation of its fields: a **4-byte big-endian length before each
field**. The domain separator itself is not length-prefixed.

An **absent optional field is still emitted — a 4-byte zero length with no content.**
Never skip it. Skipping would let a bundle with PQ material and one without collide onto
the same signed bytes, so one `cross_sig` would verify for both.

**Golden vectors: `devices/vectors/vectors.json`.** Reproduce every `signed_bytes_hex`
byte for byte and verify every `signature_hex` before shipping. Do not treat the tables
below as sufficient on their own — a client that agrees with the prose but not with the
vectors cannot talk to the other platforms, and the symptom is silently unverifiable
devices.

### Canonical device-bundle encoding — `cross_sig`

Signed by the **self-signing key**. Domain separator `chat:v1:device-bundle`, then:

| # | Field | Encoding |
|---|-------|----------|
| 1 | `user_id` | 16 bytes, UUID raw |
| 2 | `device_id` | 16 bytes, UUID raw |
| 3 | `ik_pub` | raw bytes (the 64-byte pair, §A) |
| 4 | `spk_id` | 4 bytes, big-endian |
| 5 | `spk_pub` | raw bytes |
| 6 | `pq_spk_id` | 4 bytes, big-endian; zero-length field if absent |
| 7 | `pq_spk_pub` | raw bytes; zero-length field if absent |
| 8 | `registration_id` | 4 bytes, big-endian |
| 9 | `bundle_version` | 4 bytes, big-endian |

The encoding is deliberately self-contained: every signed key appears as its **bytes**,
never as an identifier to be resolved later.

### Canonical identity encoding — `master_sig`

Signed by the **master key**. Domain separator `chat:v1:cross-signing-keys`, then:

| # | Field | Encoding |
|---|-------|----------|
| 1 | `user_id` | 16 bytes, UUID raw |
| 2 | `self_signing_pub` | raw bytes |
| 3 | `user_signing_pub` | raw bytes |

`version` is **not** covered. It is the server's anti-accident monotonic check, and
signing it would imply the served version number carries a guarantee it does not — you
must detect identity changes by comparing `master_pub`, never by trusting `version`.

### Canonical prekey encodings — `spk_sig` and `pq_spk_sig`

Both signed by the **Ed25519 half of `ik_pub`** (bytes 0–31).

| Signature | Domain separator | Fields, in order |
|---|---|---|
| `spk_sig` | `chat:v1:signed-prekey` | `user_id` (16 B) · `spk_id` (4 B BE) · `spk_pub` (raw) |
| `pq_spk_sig` | `chat:v1:pq-signed-prekey` | `user_id` (16 B) · `pq_spk_id` (4 B BE) · `pq_spk_pub` (raw) |

The separate domains are what stop either signature being replayed as the other. Neither
covers `device_id`, deliberately: `device_id` does not exist until registration succeeds
and `spk_sig` is required at registration, so covering it would make the first
registration impossible. Nothing is lost — the device bundle above already binds
`spk_pub` and `pq_spk_pub` to a `device_id` under `cross_sig`, so **that** is the
signature you rely on to know a prekey belongs to the device serving it. Verify both.

## C. What the client verifies

- Before encrypting to, or accepting a message from, any peer device: verify the device
  bundle signature chains self-signing → master, and that the master key equals the one
  confirmed out-of-band. Reject otherwise.
- **Verify the key bytes, never a server-supplied identifier.** CVE-2022-39250
  (matrix-js-sdk cross-signing identity injection, CVSS 8.6) happened because checking
  and signing were two separate steps, letting a malicious homeserver substitute the key
  in between.
- On device-list fetch: verify the log head signature and that it **extends** the
  last-seen head. A fork is proof of server equivocation.

## D. Verification UX

- **SAS:** display a short emoji/number string derived from both parties' master keys;
  both users confirm out-of-band.
- **QR:** encode the master key fingerprint; scanning cross-signs.
- This is the **only** defense against first-contact MITM. It must be prominent, not
  buried.
- **Safety-number-style change warning:** if a contact's master key or a device's
  cross-signature changes, **block sending** and require re-verification.

## E. Behavior on verification failure

| Condition | Required behavior |
|-----------|-------------------|
| Unsigned / invalidly-signed device | Refuse to encrypt to it; show "unverified device — messages withheld" |
| Master key change | Block the conversation pending re-verification. Never silently re-trust. |
| Log fork detected | Global alert state; halt sensitive operations pending an out-of-band check |

## F. Sessions and groups

Every session — direct or group — is a pairwise PQXDH plus Double Ratchet session
between two devices. The server holds no group object, no roster, no epoch, and no
group key; a group exists only in its members' clients.

- **Session start.** Always use hybrid **X25519 + ML-KEM-768** (PQXDH-style), from the
  bundles `POST /users/{user_id}/keys/claim` serves. If a claimed bundle lacks PQ
  material, either refuse or clearly flag the session as classical-only. **Never
  silently downgrade.**
- **A group session is a set of pairwise sessions**: one between the sender's device
  and every live device of every member, and one with each of the sender's own other
  devices. There is no group endpoint and no group key material to upload; start each
  pairwise session from the same claimed bundles as a DM.
- **Prekey material.** The pools, caps, and replenishment are unchanged: at most 200
  classical and 100 ML-KEM one-time prekeys stored per device. Pairwise fan-out
  consumes one one-time prekey per session start, so replenish on the counts the
  server reports (`GET /me/devices/{device_id}/prekeys/count` and the response of
  `PUT /me/devices/{device_id}/prekeys`) before a pool empties.
- **Fan-out.** Encrypt the group message once per recipient device and send the copies
  with `POST /envelopes`, up to 256 items per call; a larger fan-out is several calls.
  Read `accepted`, `stale_devices` and `full_devices` from every response: drop a
  stale device from the group's session set and refresh that user's device list;
  keep a full device in the set and retry its items later, because it is live and
  its mailbox has merely reached its ceiling (`MAILBOX_MAX_BYTES`, default 32 MiB
  of undelivered bytes).
- **Queue, acknowledgement, and time to live.** The server stores one padded row per
  recipient device with a per-device `seq`, deletes the row on ack, and prunes an
  undelivered row after `ENVELOPE_TTL_DAYS` (default 7). The drain response carries
  `pruned_through` (§H).
- **Replay defence and ordering.** The server gives each mailbox a monotonic `seq`,
  delivers a row until it is acked, and never re-creates a deleted row. It adds
  nothing else: replay defence inside a session is your ratchet counter and a bounded
  skipped-key store, and any ordering across sessions is whatever the group protocol
  carries inside its ciphertext.
- **Device addition and removal** use the existing machinery: the device-list `ETag`,
  the client-signed device log (§J), `stale_devices`, and the revocation cascade. A
  member's new device joins the group when a member starts a pairwise session with
  it; a revoked device leaves the fan-out when it appears in `stale_devices`.
- **Member removal** is a client-side signed control event carried as an ordinary
  envelope. The sender stops fan-out to the removed member's devices. The server takes
  no part and learns nothing.

## G. History sync — changed; the server no longer stores history

- On new-device enrollment, transfer history **client-to-client**, encrypted and
  authorized by cross-signing, over the ordinary envelope endpoint. There is no server
  history API.
- A new device has **no history** until an existing device is online to send it.
- The key backup blob no longer contains a history key; it carries cross-signing private
  key material.

## H. Queue gap handling

- `GET /me/envelopes` returns `pruned_through`. If the client's last acked seq is
  **below** `pruned_through`, envelopes were lost to the `ENVELOPE_TTL_DAYS` cap, and
  the server cannot re-create them.
- A lost envelope may have carried a ratchet message or a group control event. Repair
  each affected pairwise session through its authenticated repair path, then ask a
  member for the current group control state. Client-to-client history transfer (§G)
  moves content, not ratchet state, so it is not the repair.
- Surface this to the user as a recoverable state, not a silent failure.

## I. Cross-signature freshness

- Rotating the signed prekey (`spk`) changes a signed field in the device bundle. The
  client **must** supply a fresh `cross_sig` and an incremented `bundle_version` in the
  same `PUT /me/devices/{id}/prekeys` call, or peers will correctly reject the device.

## J. Device-list log maintenance

- Append a signed record on every device-set change (add, remove, revoke) and on
  identity rotation, and on nothing else: the log holds at most
  `MAX_DEVICELOG_RECORDS` records (default 10 000), is never pruned, and refuses an
  append past the ceiling with `409 devicelog_limit`.
- Piggyback the latest known heads of contacts on ordinary E2EE messages; on receipt,
  compare against the local view and raise the fork alarm on mismatch.

## K. Padding

- Pad every ciphertext to the exact bucket lengths defined in `core/buckets.py` before
  upload. A non-bucket length is rejected with `400 bad_bucket`.

## L. Polling

- No foreign push (FCM/APNs) is available. Background polling only.

## M. Enrollment ordering (load-bearing — read before implementing registration)

`cross_sig` covers `device_id`, and **`device_id` does not exist until registration
succeeds**. No first call can carry a valid cross-signature, so registration **refuses**
`cross_sig`/`bundle_version` outright (`400`) rather than storing bytes that could only
be wrong, and the device is stored uncross-signed until you supply one. Both flows below
end with the same `PUT /me/devices/{id}/prekeys` call; until it lands, peers see
`cross_sig: null` and correctly withhold messages.

Do not work around this by sending a placeholder. A stored-then-corrected `cross_sig` is
a **cross-signature change** to any peer that polled in between, and §D requires them to
block the conversation and demand re-verification over it. Null is the state that means
"not yet"; there is no signature-shaped value that means the same.

Both flows begin with a login that names no device, and end holding one session
token. There is one token in this system: `POST /auth/login` and `POST /me/devices`
each answer `token` and `expires_in`, `POST /auth/renew` issues another without
retiring the one you presented, and nothing rotates. A device may therefore hold
several live tokens at once, and two of your isolates may renew concurrently without
coordinating — the loser of that race keeps a working token rather than losing the
session.

**First device on a new account:**

1. `POST /auth/login` with no `device_id` → `scope: "register"` and a register token
   (10 min; its only power is step 2).
2. `POST /me/devices`, omitting `cross_sig`/`bundle_version` → `201` with the assigned
   `device_id` and a session token bound to it.
3. `PUT /me/identity` — publish the cross-signing identity. Required before any *later*
   device can register, so do not defer it.
4. `PUT /me/devices/{device_id}/prekeys` with `cross_sig` (over the bundle for the
   `device_id` from step 2) + `bundle_version: 1`.
5. `PUT /me/keybackup` — the recovery-protected blob carrying the cross-signing private
   keys. Skipping this strands every future device: step 3 of the flow below has no other
   source for the self-signing key.
6. `POST /me/devicelog` — the first signed log record.

**Every later device:**

1. `POST /auth/login` with no `device_id` → register token. A login that names an
   existing device of the account answers that device's session token instead, which
   is the sign-in path rather than the enrollment path.
2. `POST /me/devices`, omitting `cross_sig`/`bundle_version` → `201`, `device_id`, and
   the new device's session token. The account's identity must already be published or
   this is `400 {"code":"identity_required"}`.
3. `GET /me/keybackup` (needs the session token from step 2) → unwrap with the user's
   recovery secret → the account's **self-signing private key**. This is the only path to
   it; a device that cannot unwrap the backup can never be cross-signed, and the user
   must verify it out-of-band from an existing device instead.
4. `PUT /me/devices/{device_id}/prekeys` with `cross_sig` + `bundle_version`.
5. `POST /me/devicelog` — append the device-set change.

In the `prekeys` call, sending only one of `cross_sig`/`bundle_version` is `400`: the
version is what tells peers which bundle the signature covers, so half a pair is
unusable. That, and the `identity_required` check, are completeness checks —
**not** security controls. A modified server would skip them, so peers must verify
regardless, and a device that never reaches step 4 must stay unverified in your UI
forever rather than being trusted on the server's word.

## N. Voice

Voice is served from this revision. A call is a full mesh of WebRTC audio between
devices, every path across the self-hosted coturn, and each connection keyed by
DTLS-SRTP between its two endpoints
([ADR-0021](../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)).
There is no application-level media key to distribute, so nothing of §F applies to the
media itself. What §F does carry is the signalling.

**The server holds no room and no participant list.** It mints a relay credential
(`POST /me/relay`, [`realtime/API.md`](realtime/API.md)) and relays `signal` frames,
and that is the whole of its part. Everything below is therefore yours to build, and
none of it is checked by anything upstream. The packaging each rule implies — the media
package, its Android dependency set, the offline mirror and the manifest permissions —
is [`../CLIENT_WORK.md`](../CLIENT_WORK.md); what follows is the protocol.

1. **One connection per device pair.** Create one `RTCPeerConnection` between each of
   your own devices and each member device present in the room — a room of ten
   participants is nine connections on each device. One audio track; **no video track
   and no data channel** in this version.
2. **Relay-only ICE.** Configure `iceTransportPolicy: relay` with the `urls`,
   `username` and `credential` of `POST /me/relay` as the only ICE server. Configure
   **no STUN server and no foreign server**: a host or server-reflexive candidate would
   put a participant's own address in front of every other participant, which is the
   property the relay exists to remove.
3. **Glare.** Of two devices, the one whose device id **string sorts lower** is the
   polite peer of the perfect-negotiation pattern. Both ends compute this from the two
   ids alone, so there is no round trip to agree on it and no server to ask.
4. **Join and leave.** A joining device fans a join announcement out to every live
   member device as `signal` frames. A participant that receives one sends an offer to
   the joiner, and the joiner answers. A participant that receives a leave announcement,
   or whose connection to a device closes, drops that device from the room.
5. **Presence and room text are yours.** A device that needs the current participants
   fans out a query announcement and the participants answer; ephemeral room text is
   fanned out the same way. There is no presence frame and no room object on the server
   — nothing about a room reaches it outside `signal` frames and ordinary envelopes.
6. **Everything signalled is pairwise ciphertext.** Every offer, answer, candidate set
   and announcement is encrypted to the pairwise session of §F, padded to 1024, 4096 or
   16384 bytes on the same rule as §K, and sent as a `signal` blob. An off-bucket
   blob is not refused the way an off-bucket upload is — the frame is dropped in
   silence, so there is no error to read and nothing arrives. **Accept a remote
   description from that channel only.** The DTLS fingerprint inside the SDP is
   authenticated by the pairwise session and never by the server, which is what makes
   the media path end to end even though the server chose neither endpoint.
7. **A `signal` frame is volatile.** It is dropped if the target is not connected at
   the instant it is published, and nothing recovers it. Re-send an unanswered offer or
   announcement after a bounded timeout, a bounded number of times, and then report the
   device as unreachable. Never wait forever for an answer that no one is holding.
8. **Removal is immediate.** On applying a signed control event that removes a member,
   close every connection to that member's devices at once, and from then on refuse
   their offers and their announcements. A removed device closes its own connections.
   The server takes no part: it will keep relaying their frames, so the refusal has to
   be yours.
9. **Credential lifetime.** Fetch a credential before joining, and fetch another once
   less than an hour of `expires_in` remains. If one expires mid-call, perform an ICE
   restart with the new credential rather than tearing the call down.
10. **Ten participants.** Refuse to admit an eleventh participant to a room, and state
    the reason to the user. A full mesh costs each participant one uplink per peer, and
    ten is the design point of this deployment; the ceiling is enforced here and by
    nothing on the server.
11. **Microphone and foreground service.** Request the microphone at join and at no
    other time, and run a microphone-type foreground service for as long as the call
    lasts: a call outlives the moment the user looks at another screen, and the
    foreground service is what keeps it capturing when it does.

## O. The `/ws` handshake

- The token goes on the upgrade request, as `Authorization: Bearer <session token>`.
  There is one handshake path and this is it: the server refuses a handshake that
  carries no header, and there is no in-band authentication frame to fall back on.
- A refusal is decided **before** the accept, so it reaches you as a failed upgrade
  (`403 Forbidden`) and never as a close code. Read one as "renew the session token
  and reconnect"; a handler that waits for a close code there will never fire.
- A token that expires while its socket is open does not close the socket. Only a
  revocation does, as close code `4003`.
- Treat a socket as a wake-up hint and never as the delivery contract. The durable
  queue is authoritative (§H), so reconnect with backoff and drain over REST rather
  than trusting a frame to arrive.
