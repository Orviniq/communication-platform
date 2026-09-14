# Cryptographic protocol

## Status

This is the normative version-1 client design. It deliberately composes established
protocols instead of inventing cryptographic primitives. Exact CDDL schemas and test
vectors MUST be frozen with the crypto-core implementation before interoperability is
declared. Independent review is a production release gate.

## Implementation boundary

A shared memory-safe crypto core MUST expose a narrow native FFI API to the version-1
Android Flutter client. Dart code may orchestrate operations but MUST NOT implement
PQXDH, ML-KEM, ratchets, signatures, KDFs,
AEAD, secretstream, or secret zeroization.

The selected foundation implementation is Rust:

- `mlkem-native` v1.2.0 at commit
  `0ba906cb14b1c241476134d7403a811b382ca498` provides ML-KEM-768 through its
  deterministic API, with seeds supplied by the Rust-owned CSPRNG;
- pinned RustCrypto crates provide Ed25519, X25519, Argon2id,
  XChaCha20-Poly1305, SHA-2, and HKDF; `minicbor` is used behind typed,
  strict deterministic-CBOR encoders/decoders;
- libsodium 1.0.22, through `libsodium-sys-stable` 1.24.0, provides
  `secretstream_xchacha20poly1305`; and
- a future browser Wasm library must be produced from the same locked Rust source,
  provider choices, serialization, and test vectors as Android.

Signal's official `libsignal` supports Android but does not present a supported browser
runtime contract. The selected providers require separate Web validation.
Therefore dependency selection remains a mandatory implementation spike for any future
Web release; inability to produce one interoperable reviewed Android/Wasm core blocks
that Web release rather than causing pure-Dart ML-KEM, classical-only messaging, or
ad-hoc cryptography. It does not block the Android-only version-1 release.

### Piece-07 implementation staging

Piece 07 establishes the shared Rust source and Android native FFI/isolate boundary only.
The version-1 release is Android-only. The Web/Wasm adapter and browser worker are
post-v1 work; crypto-dependent Web behavior remains fail-closed, with no Dart or
JavaScript primitive fallback. A future reviewed Web adapter MUST consume the same
locked core source, provider choices, serialization, domain constants, and fixtures and
must satisfy the Web release gates before Web cryptographic behavior is enabled.
Android-only completion is not a protocol downgrade or an alternate suite.

## Protocol suite

| Purpose | Version-1 choice |
|---|---|
| Encoding | Deterministic CBOR (RFC 8949) |
| Random IDs | 128 random bits, encoded as UUIDv4 at UI/API boundaries |
| Two-device setup | Hybrid X25519 + ML-KEM-768 PQXDH-style establishment; no silent downgrade |
| Two-device messaging | Signal Double Ratchet, bounded skipped-key storage |
| Group messaging | Pairwise fan-out: one Double Ratchet envelope for each recipient device. No group key agreement, group key, or epoch (server ADR-0001) |
| Application signatures | Ed25519, only for authorization/control events that require durable attribution, group control events included |
| Cross-signing | Ed25519 master, self-signing, and user-signing keys |
| Backup AEAD | XChaCha20-Poly1305 with random 192-bit nonces |
| Password/recovery KDF | Argon2id v1: 64 MiB, 3 iterations, parallelism 4, 16-byte salt, 32-byte output |
| File streaming | libsodium `secretstream_xchacha20poly1305` |
| Media framing | **Undecided.** RFC 9605 SFrame or the LiveKit E2EE implementation, on a recorded decision standing on an Android wire measurement. LiveKit's own documentation names no SFrame and exposes `EncryptionType` as `kNone`/`kGcm`/`kCustom`, so this row is not settled by the SDK either; see [ADR-058](decisions.md) P4/P5 and [voice-and-realtime.md](voice-and-realtime.md) |

Every KDF and signature input uses the exact domain label defined by its binding
contract. Labels are constants in the shared crypto core and covered by test vectors;
the implementation MUST NOT invent alternate labels or normalize fields.

## Account cross-signing identity

On the first installation the client generates independent Ed25519 master,
self-signing, and user-signing key pairs. The master key signs a canonical encoding of
the two subkey bytes; the self-signing key signs device bundles; the user-signing key
signs another user's exact master-key bytes after SAS/QR verification. Private halves
remain in platform-protected client storage and leave a device only inside the
recovery-protected key backup. The published identity is never trusted because the
server returned it: clients verify `master_sig` and compare the exact master-key bytes
with the out-of-band-confirmed value.

`master_sig` signs ASCII `chat:v1:cross-signing-keys`, followed by a four-byte
big-endian length and bytes for `user_id` (16 raw UUID bytes), `self_signing_pub`, and
`user_signing_pub`, in that order. `version` is not signed. The backend
[golden vectors](../../backend/devices/vectors/README.md) are binding and MUST be
reproduced before enrollment is enabled.

## Device identity

Each device owns independent key material:

- an Ed25519 device signing key and an X25519 identity key;
- a signed X25519 prekey and a bounded one-time-prekey pool;
- an ML-KEM-768 signed prekey and bounded one-time-prekey pool;
- pairwise Double Ratchet sessions;
- a random local storage key protected by the platform keystore.

The API `ik_pub` field is exactly 64 bytes: the Ed25519 device-signing public key in
bytes 0–31 followed by the X25519 identity public key in bytes 32–63. The client rejects
any other length even though the blind backend intentionally enforces only a broader
opaque-blob range.

The self-signing key signs the exact canonical device-bundle encoding defined by the
binding backend client contract: ASCII `chat:v1:device-bundle` followed by a 4-byte
big-endian length and bytes for `user_id`, `device_id`, `ik_pub`, `spk_id`, `spk_pub`,
`pq_spk_id`, `pq_spk_pub`, `registration_id`, and `bundle_version`, in that order. The
encoding embeds key bytes, never server-supplied key identifiers. An absent optional PQ
field is encoded as a four-byte zero length and no content; it is never omitted.

The Ed25519 half of `ik_pub` signs the classical prekey as
`chat:v1:signed-prekey` plus length-prefixed `user_id`, `spk_id`, and `spk_pub`. It signs
the PQ prekey under the distinct `chat:v1:pq-signed-prekey` domain followed by
length-prefixed `user_id`, `pq_spk_id`, and `pq_spk_pub`. Neither prekey signature covers
`device_id`; `cross_sig` binds both prekeys to the assigned device. Peers verify the
prekey signature and device `cross_sig` through self-signing to the
out-of-band-confirmed master key before encrypting to or accepting content from that
device.

An unsigned/invalid device is withheld, a master-key change blocks the conversation, and
a device-log fork creates a global blocking equivocation alert. There is no first-seen
TOFU acceptance for messaging.

### Two-phase enrollment

The client first calls `POST /me/devices` without `cross_sig` or `bundle_version`. The
successful response supplies the backend-assigned `device_id` and full-scope tokens.
Only then does the client sign the canonical device bundle and send `cross_sig` with
`bundle_version` through `PUT /me/devices/{device_id}/prekeys`.

The first device publishes the account identity before that follow-up, then uploads the
recovery-protected key backup and appends the initial device-log record. A later device
uses its new full-scope token to retrieve and unwrap the backup before producing its
cross-signature, then appends the device-log change. Until the follow-up succeeds, the
device remains unverified and sensitive messaging is withheld. A placeholder signature
is never valid.

### Version-1 enrollment bindings

The Android Rust core owns all enrollment private state. `CPDVV001` and `CPIDV001` are
opaque native state-package versions used at the FFI/storage boundary; Dart may project
only the bounded public registration fields and one-time recovery-display material. It
must not interpret, construct, sign with, or log the private tail. Version 1 creates
eight classical and four ML-KEM one-time prekeys before persisting the registration
intent.

The recovery secret contains 32 random bytes followed by the first two bytes of
`SHA-256(entropy)`. It is Crockford Base32 encoded in uppercase groups of five
characters separated by hyphens. Restore ignores ASCII whitespace and hyphens,
uppercases input, accepts Crockford's `O`/`I`/`L` aliases, validates the checksum, and
then uses the canonical grouped encoding as the Argon2id password. Checksum, decode,
and AEAD failures all produce the same local wrong-secret result.

`CPKBV001` is the 4,096-byte version-1 identity-backup bucket:

```text
"CPKBV001"
|| u32be(memory_kib = 65536)
|| u32be(iterations = 3)
|| u32be(parallelism = 4)
|| salt[16]
|| xchacha_nonce[24]
|| u32be(ciphertext_length = 136)
|| ciphertext[136]
|| random_padding_to_4096
```

The 120-byte plaintext is `"CPIPV001" || user_uuid[16] || master_sk[32] ||
self_signing_sk[32] || user_signing_sk[32]`. XChaCha20-Poly1305 authenticates it with
AAD `"chat:v1:identity-backup" || exact_header[64] || user_uuid[16]`. Restore rejects
unknown parameters and non-bucket input before running Argon2id; it never silently
lowers the KDF cost. The recovery secret and backup copy embedded for initial display
are removed from the native identity package immediately after explicit confirmation.

The canonical live-device set used by the device log is
`"chat:v1:device-set" || u32be(device_count)` followed by devices sorted by lowercase
UUID text. Each device contributes `uuid_raw[16]`, a 4-byte-length-framed 64-byte
`ik_pub`, `u32be(registration_id)`, a framed `cross_sig` (zero length only while
unsigned), and `u32be(bundle_version)` (zero only while unsigned). Invalid lengths or a
half-present cross-signature/version pair fail closed.

`CPDLV001` device-log records use the 256-byte bucket. The signed fields are the raw
user UUID, predicted `u64be` sequence, previous 32-byte record hash (zero for the first
record), `SHA-256(canonical_live_device_set)`, identity version, and coarse UTC Unix day.
Each field is 4-byte-length framed after the
`"chat:v1:device-log-record"` domain. The stored record is the magic, format byte 1,
sequence, day, identity version, raw user UUID, previous hash, live-set hash, 64-byte
self-signing Ed25519 signature, and random padding. Its chain hash is SHA-256 over the
entire 256-byte record. Clients persist the exact predicted record before append and
accept a lost response only by finding that exact record at the predicted outer
sequence.

## Direct messages and per-device channels

Hybrid PQXDH combines X25519 and ML-KEM-768 claimed prekey material and feeds the reviewed
combined secret into the Double Ratchet. The initial ciphertext carries the hybrid
metadata and first ratchet message. A claimed bundle without PQ material is rejected and
shown as "post-quantum keys unavailable"; it never silently creates a classical-only
session. One-time private prekeys are deleted after successful use. Signed classical and
PQ prekeys rotate every seven days. Superseded private signed prekeys are retained for
eight days, matching the authoritative seven-day envelope TTL plus one day, then erased.
Rotating any signed bundle field atomically uploads a fresh `cross_sig` and incremented
`bundle_version` in the same prekey request.

Each pairwise session retains at most 2,000 skipped message keys and the client retains
at most 20,000 skipped keys across the account. A message beyond either bound enters the
authenticated session-repair path rather than causing unbounded allocation or silent
security downgrade.

Every logical DM is independently encrypted for:

- every live device belonging to the peer; and
- every other live device belonging to the sender.

The current device applies its own logical event locally and is not sent a redundant
envelope. Each recipient transport ciphertext binds, as associated data, the protocol
version, recipient device ID, ratchet header, and fixed `pairwise-transport-v1` domain
purpose. The event kind remains encrypted. The server does not
learn the sender or conversation ID.

The exact Android version-1 transcript, KDF/AEAD choices, sender-hidden initial header,
ratchet encoding, replay/repair behavior, simultaneous-initiation rule, and transactional
state boundaries are frozen in [Pairwise transport version 1](pairwise-transport-v1.md).
That profile always mixes the signed PQ prekey; the backend's unsigned PQ one-time key is
only an additional contribution and can never replace the authenticated PQ layer.

## Groups

A group is a set of pairwise sessions (`backend/CLIENT_CONTRACT.md` §F; server ADR-0001,
recorded for the client in [ADR-075](decisions.md)). There is no group key agreement, no
group key, no epoch, and no key package, and the client uploads no group key material.

A group message is encrypted independently for every live device of every active member and
for every other live device of the sender, over the same hybrid PQXDH sessions and Double
Ratchet a direct message uses. Starting any of those sessions from a bundle without PQ
material is refused exactly as it is for a direct message. Every copy is its own padded
envelope, so the backend never receives identical ciphertext for two recipients and learns
neither the group nor its members. The fan-out is specified in
[Pairwise transport version 1](pairwise-transport-v1.md), Group fan-out.

Membership, roles, policies, and metadata change only through signed control events. The
shared crypto core encodes each event as deterministic CBOR and signs
`"chat:v1:group-control" || u32be(length) || canonical_event` with the signing device's
Ed25519 key; it also returns the event's state hash,
`SHA-256("chat:v1:group-control-state" || u32be(length) || canonical_event)`. Every event
after the first names its predecessor's state hash inside its signed bytes, so a group's
accepted events form one hash chain. Opening an event verifies the signature before a byte
of the CBOR is decoded, and a decoded event must re-encode to exactly the signed bytes, so
one event has one encoding and one state hash on every device. Dart never builds or parses
the CBOR and never holds the key.

A receiver verifies each event under the key its account's authenticated device list and
signed device log vouch for, checks the chain link, and checks the signer's authority
against the roster the event was built on. No server-supplied roster exists to consult.
Two events at one revision are a fork, and the group is quarantined rather than resolved by
arrival order. The events, their operations, and their acceptance rules are defined in
[Application-message protocol](message-protocol.md), Groups.

A removed member is sealed no copy of any message sealed after its removal is accepted.
Content it already received cannot be remotely erased, and nothing is re-keyed, because
there is no shared key to rotate.

## Safety numbers and cross-signing

SAS and QR verification commit to both users' stable IDs and exact master-key bytes.
Successful out-of-band verification causes the user's user-signing key to sign the peer
master key. A legitimately added device does not reset contact verification when its
bundle chains to the already verified master key and extends the device log. A master-key
change, invalid device cross-signature, or device-log fork blocks sending and requires
explicit out-of-band resolution.

Version 1 computes the 32-byte safety fingerprint as SHA-256 over
`"chat:v1:safety-fingerprint"` followed by 4-byte-length-framed
`(user_uuid_raw[16], master_pub[32])` pairs, ordered by raw user UUID. The QR payload is
`CP-SAFETY-V1:` followed by unpadded base64url of those exact 32 bytes; the numeric and
emoji forms are alternative presentations of that same digest. Confirmation signs
`"chat:v1:user-signing-attestation" || frame(local_user_uuid_raw) ||
frame(peer_user_uuid_raw) || frame(peer_master_pub)` with the local user-signing key.
The stored attestation is reverified before a persisted contact can return to verified
state; first-seen keys never authorize messaging.

## Device-list log

Every device-set change and account-identity rotation produces a padded 256/1,024-byte
record containing the previous verified record hash, canonical live-device-set hash,
identity version, claimed sequence, coarse time, and an Ed25519 signature by the
self-signing key. Readers verify every signature/hash link and require the fetched head
to extend the last locally verified head. Ordinary E2EE messages gossip bounded
`(user_id, head_seq, head_hash)` tuples. Two valid non-extending heads are evidence of
server equivocation and trigger the global blocking state.

Because the server assigns outer log sequence numbers after receiving opaque records,
the client predicts the next sequence from the verified head and confirms the returned
range matches the signed record. Concurrent own-device appends require a reviewed
serialization/retry policy; a mismatch is never silently repaired or accepted by arrival
order.

## Recovery and device-to-device history

At account setup the client generates a random high-entropy recovery secret with a
checksum and human-safe encoding. The encrypted backup contains the master,
self-signing, and user-signing private keys plus required account identity material,
including user-signing-key signatures over already verified peer master keys. It
contains no archive/history key, device ratchet state, group state, or message history.

Argon2id derives a wrapping key from the recovery secret and a random salt. Version 1 uses
a 16-byte salt and 32-byte output, with a floor of 64 MiB memory, three iterations, and
parallelism four on Android. A future Web implementation must process the same four lanes
without changing the stored parameter so a backup created on one supported platform
cannot become unrestorable on the other. Stronger parameters require a later protocol
revision plus compatibility measurements across the supported device floor. The backup
blob stores its format version, KDF parameters, salt, nonce, and cross-signing identity
material encrypted with authenticated metadata. Restore rejects parameters below the version floor or above
the version's reviewed resource ceiling before allocation.

The server cannot validate the recovery secret. A wrong secret is detected only by AEAD
failure. Recovery restores account cross-signing identity only. A new device receives
message history through encrypted, cross-signing-authorized ordinary envelopes from an
existing online device. If no existing device is online, no history is available; the
server has no copy. Live pairwise sessions start fresh, and a group reaches the new device
when a member sends it the group's current control state.

An unlocked device may rotate recovery by generating a new secret and salt, rewrapping
the same cross-signing identity material, uploading a higher-version backup, showing the
new secret once, and erasing it from application storage. The prior secret cannot unwrap
the replaced backup. Rotation does not affect message history stored on devices.

## Profiles and labels

Account profile, device labels, group metadata, and room names are encrypted with scoped
keys derived or distributed inside authenticated conversations. A profile payload may
contain an encrypted attachment capability for an avatar because the backend profile
bucket is intentionally small. Keys for different metadata classes are domain-separated.

The backend directory username is the only presentation identity available before an
authenticated profile key arrives. During that bootstrap state the UI shows the username
and a local deterministic placeholder avatar derived from
`"chat:v1:placeholder-avatar:" || lowercase(username)`. It does not show unverified
cached display names. A pairwise session distributes
`profile.publish` to a DM peer, and the same pairwise fan-out distributes it to group
peers. Only a successfully authenticated profile with a live-device signer may
replace the fallback.

Until pairwise transport is implemented, development builds may use the explicitly
non-production `ProfileProtectionPort` and `ProfileKeyDistributionPort` fake adapters.
Production composition remains fail-closed. The fake envelope exists only to exercise
profile versioning, cache authentication, presentation gating, and distribution hooks;
it is not cryptographic acceptance evidence.

Fixed-bucket metadata uses `MetadataBlobV1`:

```text
version-byte || 24-byte random nonce
  || XChaCha20-Poly1305(fixed-width real-length || canonical record || random padding)
```

The authenticated plaintext is deterministic CBOR containing scope, object ID, monotonic
revision, previous accepted record hash, author user/device IDs, content, and an Ed25519
signature over the domain label plus the unsigned canonical record. The complete result
is padded to the backend bucket; no plaintext author or revision is exposed to the
server. The outer version and bucket size are associated data; the real-length prefix is
inside the authenticated ciphertext and is validated before padding is removed.

For account profiles, the protocol revision equals the backend profile `version` and a
valid signer must be a live device of that account. For room names, all current client-
authenticated room peers may sign. Clients select the greatest valid
`(revision, author_device_id, record_hash)` successor and announce the accepted hash in a
durable `room.control` event. Because the backend does not compare room revisions, an
accepted peer repairs a stale or replayed `name_blob` with the converged record. A new
peer receives the current record and key in its authenticated invite.

Device-label blobs use an account-local label key and are readable only by the account's
devices.

## Key lifecycle

- Secrets are generated with the platform CSPRNG through the shared crypto core.
- Ratchet message keys are erased as soon as the Double Ratchet allows.
- Logout, revocation, database-key loss, or integrity failure wipes local content keys
  and session credentials.
- No key, plaintext, nonce-bearing capability, or secret buffer crosses a log boundary.
- Debug features capable of printing cryptographic state are disabled in all builds used
  with real accounts.

## Protocol upgrade policy

Encrypted objects carry a major version. Unknown major versions are retained as
unsupported and never interpreted. Minor additive fields are ignored only when the schema
marks them optional. Crypto-suite changes require a dual-read/controlled-write migration,
interoperability fixtures, and an ADR; silent algorithm substitution is forbidden.

## Primary references

- [Binding backend client contract](../../backend/CLIENT_CONTRACT.md)
- [Signal PQXDH specification](https://signal.org/docs/specifications/pqxdh/)
- [Signal Double Ratchet specification](https://signal.org/docs/specifications/doubleratchet/)
- [Server ADR-0001: pairwise Double Ratchet group fan-out](../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- [RFC 9605: SFrame](https://www.rfc-editor.org/info/rfc9605)
- [RFC 8949: CBOR](https://www.rfc-editor.org/info/rfc8949/)
- [RFC 9106: Argon2](https://www.rfc-editor.org/info/rfc9106/)
- [libsodium secretstream](https://libsodium.gitbook.io/doc/secret-key_cryptography/secretstream)
