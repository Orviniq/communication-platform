# Authentication and devices

## Trust configuration

The application ships with one provisioned server origin, private-CA trust anchor, and
native primary/backup SPKI pins. Users cannot bypass trust failures or enter arbitrary
servers. Development configuration is separate, visibly branded, and cannot be built as
a production artifact accidentally.

## Bootstrap routing

1. Load trust configuration and protected storage.
2. If configuration is absent or invalid, show the blocking not-provisioned state.
3. Check `/api/v1/health` on the configured server only.
4. If unreachable with no usable identity, remain on the connection screen with Retry.
   With a usable Android identity, open cached content in offline mode. The Web client is
   online-session-first and remains at the connection gate.
5. If a valid device session exists, renew if required and enter the app.
6. Otherwise show Login; a remembered username is non-secret and may be prefilled.

## Registration

- Normalize username to lowercase for presentation consistent with the backend.
- Enforce the documented character/length rules locally for feedback; the server remains
  authoritative.
- Never probe username existence separately.
- After `POST /api/v1/auth/register`, show Pending Activation.
- "Check again" returns to Login with the username prefilled and requires the password
  again; there is no activation polling endpoint and the pending screen does not retain
  credentials.
- Password UI states clearly that the password authenticates the account and cannot
  recover cryptographic identity or message history.

## Login and first device

Login without a known live device ID returns register scope. Before registration, the
client generates the device Ed25519/X25519 identity and classical and ML-KEM-768
prekeys. It generates no MLS KeyPackage: a group is a set of pairwise sessions with no
group key material to upload
([`CLIENT_CONTRACT.md`](../../backend/CLIENT_CONTRACT.md) §F). It calls
`POST /api/v1/me/devices` without `cross_sig` or `bundle_version`, and without
`keypackages`: `RegisterDeviceIn` has no such field and refuses an extra one. The `201`
response supplies the assigned `device_id` and one full-scope session token with its
`expires_in`.

For the first device, the client publishes the account identity, signs the canonical
bundle containing the assigned ID, sends `cross_sig` plus `bundle_version: 1` through
the prekey endpoint, uploads the recovery-protected key backup, and appends the first
device-log record. A later device registers unsigned, retrieves and unwraps the backup
with its new full-scope token, then cross-signs itself and appends the device-log change.
Until the cross-signature follow-up succeeds, the device remains in a resumable
"finishing secure setup" state and sensitive messaging stays withheld. The client never
sends a placeholder signature.

A failure before server registration keeps uncommitted keys in a resumable pending
state. The client persists the registration intent and generated public-key fingerprint
before sending the request. If the registration outcome is ambiguous, it does not erase
that state or blindly create devices until the account cap is exhausted; recovery must
reconcile unsigned devices by the same key fingerprint after a full-scope session is
obtained, revoke an orphan explicitly, and append the corresponding device-log changes.

## Returning device

Login supplies the stored device ID. A full-scope response resumes the session. If the
server treats the device as unknown/revoked and returns register scope, the UI explains
that this installation must register as a new device; it does not reuse revoked private
state.

## Token handling

There is one token. Login and device registration each answer a session token and the
`expires_in` beside it, and `POST /api/v1/auth/renew` answers another of the same kind.
The server issues no second credential to hold, so there is no pair to keep in step, no
rotation, and no route named `refresh` — server-side ADR-0023 retired all three, and
`frontend/docs/decisions.md` ADR-068 records what that costs this client.

- Android stores the session token encrypted under a Keystore-wrapped storage key. It is
  the credential itself, not a placeholder: nothing retires it, and a token outlives a
  cold start, so a restore returns a token that is ready to use.
- Web stores encrypted token material under the origin's non-extractable wrapping key;
  page code can still use it while trusted code is running.
- The token is cached in memory per isolate to spare an ordinary request a SQLCipher read.
  Any decision that could *end* a session reads the durable row instead, because that row
  is shared with every other delivery owner in the process (ADR-050).
- Dio authentication, proactive renewal, retry, logout, and WebSocket reconnect share one
  token coordinator.
- A renewal carries its token in the `Authorization` header and sends no body. It writes
  nothing and moves no generation, so it is safe to repeat: a renewal whose answer was
  lost costs a retry rather than the session, and two that race simply produce two working
  tokens.
- A renewal that cannot be read is the server's fault, not a refused token, and the live
  session survives it. Only a logout, a device revocation, a deactivated account, or an
  account erasure ends a token before its own expiry.
- Tokens and decoded claims never enter logs or crash reports.
- Logout posts the current session token when possible, then wipes locally even if the
  network request fails. It advances the device's token generation, so every outstanding
  token of that device dies at once.

## Account erasure

`DELETE /api/v1/me` is the one irreversible route the API offers, and the only
authenticated one that asks for a password. The client sends the typed password in the
body and retains it nowhere: not stored, not cached, not logged.

The use case maps the route's four documented answers, branching on the error `code` and
never on the `detail` text:

- `204` — the account is gone. The local store is cleared exactly as a logout clears it,
  and the termination that lands the user on sign-in is emitted.
- `401 invalid_credentials` — a wrong password. The account is still there, the session is
  untouched, and the user tries again. The client counts its own wrong attempts so wording
  can warn before the last one; the server is what actually counts.
- `401 token_revoked` — the retry of a call whose answer was lost. The device the token
  named went with the account, so the first call landed: this is the `204` outcome.
- `429 throttled` — a cool-off. The wait comes from `Retry-After`.

Five wrong passwords on a username inside fifteen minutes lock it for fifteen on this
route and on `POST /api/v1/auth/login` alike, so a user locked here cannot sign in on any
device until it lifts. The screen has to say that, and has to say what an erasure does not
reach: copies peers already hold were decrypted on their devices and are beyond this
server.

The local teardown deliberately does not send `POST /api/v1/auth/logout` first. After a
`204` the token is dead, and presenting it would answer `401 token_revoked` — which the
transport treats as a remote revocation and reports to the user as a revoked session,
which is not what happened. The token is dropped from the store first, which leaves
exactly the rest of a logout: the session generation advances, the wipe runs, and the
termination is `logout`.

## Linked devices

The Linked Devices screen uses `GET /api/v1/me/devices` with ETag caching. Labels are decrypted
locally. Removing a device requires confirmation and calls DELETE. Removing this device
transitions directly to revoked cleanup.

Peer device lists also use ETags covering both the live set and device-log head, and the
identity read uses one covering the four public key fields and the version. Before
use, every device bundle is verified against the peer's out-of-band-confirmed master key,
fetched from `/api/v1/users/{user_id}/identity`, and the paged
`/api/v1/users/{user_id}/devicelog` must extend the last verified head. A legitimately
cross-signed addition does not invalidate master-key verification. Invalid/unsigned
devices are withheld; master-key change or log fork blocks sensitive operations.
Unknown/foreign/revoked IDs are treated identically in UI to avoid exposing server
existence distinctions.

### Verifying a fan-out in one call

A send verifies its recipients — every peer it is for, and this account for its own other
devices — with one `POST /api/v1/peers`, and as many more as its 64-peer ceiling makes it
([ADR-080](decisions.md)). The answer is the bytes the per-user identity and device-list reads
serve, so each peer's answer goes through the checks above unchanged; what the route removes is
round trips, never a check. The device log is still read page by page, and only for a peer whose
head moved.

- **`unchanged` is a shape, decided by its presence.** It answers a tag the request carried and
  carries no body: the stored identity, device list and head stand, exactly as a `304` from the
  device-list read does, and are verified again. Its value is always `true`; any other value,
  a body beside it, or a tag other than the one sent is a malformed answer.
- **Answers are matched to requests by `user_id`.** A user that does not exist, is not activated
  or was deactivated is left out, and the route does not say which. A peer left out, or one with
  no published identity, is what the per-user identity read answers `404` for, and is blocked as
  that `404` is: `identityUnavailable`.
- **The three tags stay apart.** The identity read's `ETag` is stored as `identityEtag` and sent
  only to that route. It covers the identity alone, so it is written beside whichever identity
  is stored, and the batched answer carries it inside its identity, beside its own tag. The
  device list's is stored as the record's `etag` and sent only to that route; the batched
  read's is stored as `peerStateEtag` and sent only to it. Each of those two vouches for the
  stored state it was read with, so a read by one route keeps the other route's tag only when
  it left the stored identity, device list and head exactly as they were. A refused record
  sends none of the three.

The per-user routes are not deprecated and still serve every single-peer path: a safety number,
a `stale_devices` refresh, the prekey claim's re-resolution, the sender of an inbound envelope,
session repair, and voice.

### No peer cache

Nothing remembers what the server said about a peer between two resolutions
([ADR-082](decisions.md)). Every resolution asks the server, so a send is verified against the
state its recipients hold when it is made, and a safety number or a `stale_devices` refresh
reads exactly what a fan-out reads. The authentication service is composed against the network
repository itself, with nothing between them that could answer from memory.

What a repeat read saves is the body, never the request:

- **The identity read is conditional.** It sends the tag stored beside the identity as
  `If-None-Match`. A `304` stands for that stored identity, which is verified again exactly as
  a `200` would be, and a `304` to a read that carried no tag is refused. An identity that was
  never published is `404 not_found` whatever the header holds, because there is no tag for a
  row that does not exist, and it blocks the record as `identityUnavailable`.
- **The device list is conditional** on its own `ETag`. A `304` stands for the stored list and
  head, which are verified again.
- **The batched read answers `unchanged`** for each peer whose tag still holds.
- **The device log is read page by page,** and only for a peer whose head moved.
- **A prekey claim is a request every time.** It consumes one-time prekeys, so it is never
  replayed and never shared between callers.

Until ADR-082, a thirty-second cache answered repeated per-user reads from memory
([ADR-065](decisions.md)). It existed because a fan-out cost three reads for each recipient.
ADR-080 made a fan-out one call, and what the cache still saved, the second re-read of a peer on
the claim path, did not pay for a send sealed to state nobody had checked again.

## Prekey and key-package policy

Concrete low/target watermarks are configuration constants below the classical cap of
200 and ML-KEM cap of 100. The crypto core generates material; a maintenance use case
uploads it only for the current device. Signed classical/PQ prekeys rotate on schedule
and after suspicion of compromise, atomically with a fresh device `cross_sig` and
incremented `bundle_version`. Failed signature or cross-signature verification blocks
session setup. No KeyPackage is generated or uploaded: the server serves no MLS.

A routine prekey rotation does not reset the contact's confirmed master key only when
the user/device ID, `ik_pub`, and registration ID are unchanged, the new classical/PQ
prekey signatures and device `cross_sig` all verify, `bundle_version` increments by
exactly one, and the device log extends to the new canonical live-set hash. A peer that
observes the prekey PUT before its separately appended log record treats the state as a
temporary security block and retries; it does not persist a fork alarm. Any other
cross-signature change remains a blocking safety-number change requiring explicit
out-of-band resolution.

## Recovery

Recovery requires the server key-backup blob and user-held recovery secret. The client
performs Argon2id and authenticated decryption locally. A wrong secret produces a generic
local failure. The blob restores cross-signing private keys and identity material only;
there is no history key or server history. There is no server check/reset and the UI
never suggests one.

Message history arrives only from an existing online, cross-signing-authorized device
over ordinary per-device envelopes. Without one, the new device starts with no history.
Pairwise sessions start fresh, and a group reaches the device when one of its members sends
it the group's current control state; nobody removes and re-adds it. The UI separates
`identity recovered`, `waiting for existing device`, `history transferring`, `groups arrive
from their members`, and `ready`.

## Error mapping

Transport and backend error codes map to typed application failures. Required UX cases
include invalid credentials, inactive account, username taken, rate limited, scope
forbidden, device cap, revoked token/device, stale version, unreachable server, trust
failure, `identity_required`, unsigned/invalid device, master-key change, device-log
fork, missing PQ material, mailbox gap, malformed server response, and unsupported
protocol.

Backend error detail is safe for diagnostics only after redaction; UI uses reviewed
localized messages rather than displaying arbitrary server strings.

## API references

- [Accounts API](../../backend/accounts/API.md)
- [Devices API](../../backend/devices/API.md)
- [Vault API](../../backend/vault/API.md)
