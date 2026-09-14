# Pairwise transport version 1

## Status and scope

This document freezes the Android version-1 hybrid session-establishment and
Double Ratchet profile. It is the review contract for implementation piece 13.
It does not define application-message semantics or a Web implementation. A group adds no
transport of its own: it is this profile used once for every recipient device (see Group
fan-out).

The construction follows the Signal PQXDH revision 3 and Double Ratchet revision
4 algorithms, with the project bindings and deviations below. The upstream
specifications were verified on 2026-07-29. Checked-in composition/KDF vectors and
malicious-input tests accompany this implementation; full-envelope fuzz targets and an
independent assessment are still required before production release. Implementing this
profile is not itself an independent review.

## Suite registry

| Field | Version-1 value |
|---|---|
| Protocol major version | `0x01` |
| Pairwise suite | `0x01` |
| Classical agreement and ratchet | X25519 |
| Post-quantum KEM | ML-KEM-768 |
| Hash, HMAC, and HKDF | SHA-256 |
| Payload AEAD | XChaCha20-Poly1305, 16-byte tag |
| UUID encoding | 16 raw bytes in network order |
| Integer encoding | Unsigned big-endian |
| Purpose | exact ASCII `pairwise-transport-v1` |

Unknown versions, suites, flag bits, or non-canonical encodings fail closed.
There is no classical-only suite or fallback identifier.

## Domain constants

The following ASCII byte strings are exact and are never NUL-terminated:

```text
chat:v1:pqxdh-x25519-mlkem768-sha256
chat:v1:pqxdh-sealed-sender
chat:v1:pqxdh-init-auth
chat:v1:double-ratchet-root
chat:v1:double-ratchet-aead
chat:v1:pairwise-state-auth
chat:v1:device-prekey-state-auth
chat:v1:session-repair
pairwise-transport-v1
```

## Claimed-bundle requirements

Session initiation accepts only a bundle that has already chained through the
confirmed account master key, self-signing key, exact device bundle, and device-log
extension. The crypto core repeats the byte-level prekey and device-signature checks.

The following are mandatory:

- the exact 64-byte `ik_pub` layout;
- a valid signed X25519 prekey;
- a valid signed ML-KEM-768 prekey and its signature;
- a valid device `cross_sig` and positive `bundle_version`; and
- a live recipient device ID matching the authenticated bundle.

The classical and PQ one-time prekeys are independently optional. Missing signed PQ
material, partial PQ fields, malformed ML-KEM material, an invalid signature, an
all-zero X25519 result, or a mismatched device/version aborts setup. No code path
derives a classical-only root.

### Backend PQ one-time-key deviation

The backend supplies an unsigned `pq_otpk`, whereas Signal PQXDH signs the selected PQ
one-time key. Therefore the project never substitutes `pq_otpk` for the signed PQ
prekey. Every initiation encapsulates to and mixes the authenticated `pq_spk` secret.
When `pq_otpk` is present, its independently encapsulated secret is appended as an
additional one-time contribution. Omitting, replacing, or knowing that optional
contribution cannot remove the mandatory signed-PQ contribution.

## PQXDH derivation

The initiator generates a fresh X25519 ephemeral key `EK_A`. With the recipient's
X25519 identity `IK_B`, signed prekey `SPK_B`, and optional classical one-time prekey
`OPK_B`, it computes in this exact order:

```text
DH1 = X25519(IK_A_private, SPK_B)
DH2 = X25519(EK_A_private, IK_B)
DH3 = X25519(EK_A_private, SPK_B)
DH4 = X25519(EK_A_private, OPK_B)       # present only when OPK_B is present
(CT_S, SS_S) = ML-KEM-768.Encaps(PQSPK_B)
(CT_O, SS_O) = ML-KEM-768.Encaps(PQOPK_B) # present only when PQOPK_B is present
```

The 32-byte shared secret is:

```text
IKM = 0xff * 32 || DH1 || DH2 || DH3 || [DH4] || SS_S || [SS_O]
SK  = HKDF-SHA256(
        salt = 0x00 * 32,
        IKM = IKM,
        info = "chat:v1:pqxdh-x25519-mlkem768-sha256",
        length = 32)
```

Brackets mean exact conditional presence determined by authenticated header flags.
Empty placeholders are not inserted. Ephemeral private material, DH outputs, and KEM
shared secrets are zeroized after the initial state and ciphertext are produced.

## Sender-hidden initial header

An initial message must let the recipient locate its private prekeys without placing
the sender user/device identifiers or identity key in the server-visible frame.

The anonymous header secret uses only material derivable by the intended recipient:

```text
AH_IKM = DH3 || [DH4] || SS_S || [SS_O]
AH = HKDF-SHA256(
       salt = 0x00 * 32,
       IKM = AH_IKM,
       info = "chat:v1:pqxdh-sealed-sender",
       length = 56)
AH_KEY   = AH[0..32]
AH_NONCE = AH[32..56]
```

`AH_KEY`/`AH_NONCE` encrypt the sender block below. Its associated data is the exact
outer fixed fields, the initial-header bytes preceding `sender_seal_length`, the raw
recipient device UUID, and the `pairwise-transport-v1` purpose.

```text
sender_block =
  block_version:u8 = 1
  sender_user_id:16
  sender_device_id:16
  sender_ik_pub:64
  sender_registration_id:u32be
  sender_bundle_version:u32be
  repair_present:u8
  [replaced_session_id:16 || repair_token:32]
  init_signature:64
```

`repair_present` is only `0` or `1`. `init_signature` is Ed25519 by bytes 0-31 of
`sender_ik_pub` over the init-auth domain followed by four-byte length-framed values,
in order: protocol version, suite, purpose, recipient device ID, all initial-header
bytes preceding `sender_seal_length`, and all sender-block bytes preceding the
signature.

Receiving an initial envelope is two phase and side-effect free until commit:

1. The core uses referenced local prekeys to authenticate-decrypt the sender block and
   returns only its bounded public identity projection.
2. The client refreshes the sender's complete device list and log without claiming or
   consuming sender prekeys. It requires the exact `sender_ik_pub` and registration ID
   to be a live, cross-signed, device-log-consistent device under the already confirmed
   master key. A queued sender bundle version may be older than that authenticated live
   projection after rotation, but a future version is rejected.
3. The core verifies `init_signature`, derives `SK`, authenticates the first ratchet
   ciphertext, and returns one prepared state transition.
4. One database transaction commits the session, opened opaque payload, replay marker,
   and deletion of any used one-time private keys. Failure before that transaction
   leaves every private prekey usable for an exact retry; successful commit makes each
   used private one-time key unreachable.

## Ratchet header and envelope

`EnvelopeV1` is exactly one allowed backend bucket:

```text
version:u8 = 1
suite:u8 = 1
ratchet_header_length:u16be
ratchet_header
ciphertext_and_tag_to_end_of_bucket
```

Allowed total byte lengths are `1024`, `4096`, `16384`, `65536`, and `262144`.
`ratchet_header` is:

```text
header_version:u8 = 1
flags:u8
session_id:16
ratchet_public:32
previous_chain_length:u32be
message_number:u32be

# only when flags.initial = 1
signed_prekey_id:u32be
one_time_prekey_id:u32be
pq_signed_prekey_id:u32be
pq_one_time_prekey_id:u32be
ephemeral_public:32
pq_signed_ciphertext:1088
[pq_one_time_ciphertext:1088]
sender_seal_length:u16be
sender_seal
```

Flag bits are `0x01 initial`, `0x02 classical one-time present`, `0x04 PQ one-time
present`, and `0x08 authenticated repair replacement`. Other bits are rejected.
Absent one-time IDs are encoded as `0xffffffff`; a presence flag and sentinel must
agree. Backend key IDs must be at most `0x7fffffff`, so the sentinel cannot collide.
Regular headers set every flag to zero. A repair replacement is also an initial header
and carries its old session ID/token only inside the sealed sender block.

`session_id` is 16 CSPRNG bytes. It is an opaque lookup value, not an account,
conversation, or device identifier. A collision with a different authenticated
transcript is rejected.

The AEAD associated data is exact concatenation:

```text
"pairwise-transport-v1"
|| version
|| suite
|| recipient_device_id_raw_16
|| ratchet_header_length_u16be
|| ratchet_header
```

Changing the purpose, protocol/suite, recipient, any header byte, or padding therefore
fails authentication. The encrypted plaintext is `real_length:u32be || inner_bytes ||
CSPRNG_padding`. The smallest fitting bucket is used. Real length is checked only after
successful AEAD and before allocation/copy.

## Double Ratchet instantiation

The recipient signed X25519 prekey is Bob's initial ratchet key. The initiator generates
a separate fresh X25519 ratchet pair and initializes according to the Signal Double
Ratchet algorithm.

```text
KDF_RK(rk, dh) = HKDF-SHA256(
  salt = rk,
  IKM = dh,
  info = "chat:v1:double-ratchet-root",
  length = 64)
new_rk = output[0..32]
new_ck = output[32..64]

message_key = HMAC-SHA256(key = chain_key, data = 0x01)
next_chain = HMAC-SHA256(key = chain_key, data = 0x02)

AEAD_MATERIAL = HKDF-SHA256(
  salt = 0x00 * 32,
  IKM = message_key,
  info = "chat:v1:double-ratchet-aead",
  length = 56)
AEAD_KEY   = AEAD_MATERIAL[0..32]
AEAD_NONCE = AEAD_MATERIAL[32..56]
```

Message keys and prior chain/root/DH private values are zeroized immediately after the
successful transition permits it. The opaque serialized state is strictly versioned
and bounded. Its HMAC-SHA256 key is `HKDF-SHA256(salt =
device_identity_secret, IKM = root_key, info = "chat:v1:pairwise-state-auth",
length = 32)`, binding the ratchet secret to this device's externally held identity
secret. A bad tag, cross-device substitution, unknown state version, counter overflow,
or non-canonical ordering fails closed.

## Replay, skipped keys, and repair

Skipped keys are indexed by `(ratchet_public, message_number)` and sorted
lexicographically in serialized state. A successfully used skipped key is deleted in
the same transaction that applies the payload. A message number behind the active chain
that has no retained skipped key is a replay and is never interpreted as a duplicate
success.

One device-pair state stores at most 2,000 skipped keys. The database stores the
authenticated count beside each opaque state and verifies it on every transition. The
sum across the account may not exceed 20,000. Preparation receives the transaction's
other-session total; the commit repeats both limits under the same write transaction.

Crossing either bound returns the typed `repair_required` outcome without changing
ratchet state. The receiver creates a CSPRNG 32-byte repair token and sends this control
plaintext through its still-authenticated outgoing chain:

```text
"CPRRV001" || type:u8(1=request) || old_session_id:16
|| repair_token:32 || reason:u8(1=skipped_limit)
```

Only successful ordinary ratchet authentication may install a pending repair token.
The peer claims a fresh fully verified hybrid bundle and sends a repair-replacement
initial message containing the exact old session ID/token in the sealed sender block.
The recipient accepts it only once against its pending authenticated token. A token
sent in plaintext, under another session, reused, or not locally pending is rejected.

## Simultaneous initiation and overlap

If both devices initiate before receiving the other's initial message, both initial
payloads are authenticated and may be applied once. The session initiated by the
lexicographically smaller raw initiator device UUID becomes the primary bidirectional
session on both sides. The other session is retained receive-only solely for its initial
payload/replay result and then erased after the primary session authenticates traffic.
It never creates a second outgoing chain. This rule is deterministic and independent
of delivery order.

Signed classical and PQ prekeys rotate together after seven UTC days. Rotation creates
fresh independent key pairs and signatures, increments `bundle_version` exactly by one,
and computes a fresh device `cross_sig`; all fields are persisted before one exact PUT
body is attempted. Ambiguous PUT retries reuse that body and its key IDs. Superseded
private signed-prekey pairs are receive-only through the end of day eight, then erased.

An expected rotation does not itself reset account-master verification when all of the
following hold: user/device ID, `ik_pub`, and registration ID are unchanged; both new
prekey signatures and the new `cross_sig` verify; `bundle_version` is exactly the prior
version plus one; and the fetched device log validly extends the stored head. Any other
cross-signature change remains a blocking safety-number change requiring explicit
out-of-band resolution.

## Group fan-out

A group is a set of pairwise sessions (`backend/CLIENT_CONTRACT.md` §F, server ADR-0001).
This profile carries a group unchanged: there is no group suite, header flag, key, or epoch.

- **One copy per device.** A group message is one send with one event ID, sealed
  separately, under each device's own session, for every live device of every active
  member and every other live device of the sender. The current device applies its own
  copy locally and is sent none. A group of 50 people with three devices each is about 150
  envelopes for one message. Server ADR-0001 caps a group at 50 members and a member at 10
  devices, so one message costs at most 500 envelopes plus the sender's own devices.
- **Recipients at sealing time.** The member set is read from the group's accepted control
  state when the copies are sealed, not when the message was written: a member removed in
  between gets no copy, and one added in between gets one. A member with no live device is
  not a recipient of that message. A group the device may no longer send into is sealed for
  nobody, and the send fails where the user can retry it.
- **Session start.** A recipient device with no primary session, or one whose authorized
  repair replacement is pending, is claimed selectively after the recipient's complete live
  device set is authenticated, and the live set the claim returns must equal the resolved
  one. A claimed bundle without the signed ML-KEM prekey is refused when it is claimed and
  again before the core is asked, and the core aborts setup without it (Claimed-bundle
  requirements), so no copy is ever sealed under a classical-only root.
- **One commit.** Every recipient's next session state and exact ciphertext commit in one
  transaction with the outbox rows (Durable boundaries). A retry sends the stored bytes and
  never encrypts again.
- **Batches.** At most 256 items go in one `POST /api/v1/envelopes`; a larger fan-out is
  several calls. An answer must account for exactly the batch sent: `accepted` equals the
  batch less `stale_devices` less `full_devices`, and every device named is one the batch
  addressed. Any other answer is retried whole.
- **`stale_devices`.** The device is gone. Its item is terminal, its pairwise sessions are
  deleted, and its owner's device list is queued for an authenticated refresh, so the next
  seal no longer includes it. It leaves the message's copy count instead of holding the send
  open.
- **`full_devices`.** The device is live and its mailbox has reached `MAILBOX_MAX_BYTES`.
  Its item waits out the ordinary backoff and is sent again, as the same bytes, when due;
  its session and its owner's device list are untouched.
- **Progress.** A group message is sent only when none of its copies is still owed. Until
  then the conversation shows how many copies the server has accepted out of the copies
  owed to devices still in the set.
- **Control events.** A signed control event, a state request, and a transcript are group
  payloads ([message-protocol.md](message-protocol.md), Groups) and fan out per recipient
  user: one pairwise operation for each member they are owed to, so a member whose devices
  cannot be reached delays only that member's copies.

## Durable boundaries

- Generation writes an opaque private state plus the exact pending upload projection
  before network I/O. Idempotent PUT retry never generates replacement IDs.
- Sending atomically compares the old session revision and writes the next opaque state,
  authenticated skipped-key count, exact per-recipient ciphertext, and local application
  marker. After commit, retries read ciphertext only and never invoke encryption.
- Receiving prepares without mutation, then atomically compares revisions, writes the
  next session/device-prekey state, consumes one-time keys, stores the opened opaque
  payload/replay marker, and marks the inbox row ready to acknowledge.
- Stale or authentically revoked devices invalidate their sessions and pending targets.
- Logout, self-revocation, database-key loss, or state-integrity failure wipes pairwise
  and prekey private state.

## Review and vector packet

The independent-review packet must contain:

- this exact profile and every domain constant;
- dependency versions/commits and the Rust unsafe/FFI inventory;
- deterministic project vectors for every optional-prekey combination and ratchet step;
- the applicable NIST ML-KEM, RFC 7748, RFC 5869, and XChaCha vectors;
- malicious bundle, downgrade, recipient/purpose/header mutation, replay, state-tamper,
  simultaneous-initiation, repair, rotation-overlap, and revocation cases;
- parser/state-machine fuzz corpora and reproducible commands; and
- an explicit list of open findings and the independent assessor's disposition.

Android passing the packet does not provide Web evidence. Cross-target byte equality
remains a post-v1 Web gate.

## Primary references

- [Signal PQXDH](https://signal.org/docs/specifications/pqxdh/), revision 3
- [Signal Double Ratchet](https://signal.org/docs/specifications/doubleratchet/), revision 4
- [FIPS 203: ML-KEM](https://csrc.nist.gov/pubs/fips/203/final)
- [RFC 7748: X25519 and X448](https://www.rfc-editor.org/rfc/rfc7748)
- [RFC 5869: HKDF](https://www.rfc-editor.org/rfc/rfc5869)
