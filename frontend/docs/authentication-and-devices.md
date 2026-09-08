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
client generates the device Ed25519/X25519 identity, classical and ML-KEM-768 prekeys,
and—only after the [PQ MLS production gates](mls-profile.md#production-gates) pass—MLS
KeyPackages. It calls `POST /api/v1/me/devices` without `cross_sig` or `bundle_version`,
and without `keypackages`: `RegisterDeviceIn` has no such field and refuses an extra one,
so the closed MLS gates cost nothing here. The `201` response supplies the assigned
`device_id` and one full-scope session token with its `expires_in`.

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

Peer device lists also use ETags covering both the live set and device-log head. Before
use, every device bundle is verified against the peer's out-of-band-confirmed master key,
fetched from `/api/v1/users/{user_id}/identity`, and the paged
`/api/v1/users/{user_id}/devicelog` must extend the last verified head. A legitimately
cross-signed addition does not invalidate master-key verification. Invalid/unsigned
devices are withheld; master-key change or log fork blocks sensitive operations.
Unknown/foreign/revoked IDs are treated identically in UI to avoid exposing server
existence distinctions.

### Short-lived peer-resolution cache

Within one process, the answers `/identity`, `/devices` and `/devicelog` gave about a peer may
stand in for a repeat of the same request for **30 seconds**. The cache decorates the remote
port, *below* every check described above: a served answer re-enters the same authentication
the network's would have, so the master-key comparison, the unsigned-device rejection, the
device transition rule, the hash-chain and sequence verification, the current-live-set
requirement on the head record, the trust states and the global fork gate all run again on
every resolution. A hit shortens the path to a verdict; it never reaches one a live fetch would
not have reached, and it can never widen a live device set beyond what the server itself
returned inside the window.

It is in memory only. Nothing is persisted, so a restart starts cold — deliberately: a cache
that outlives the process can outlive a revocation it never saw. Only successful answers are
remembered. `/devicelog` pages are shared between concurrent identical requests but never
stored, because a stored page outlives the device answer that said which head to expect and a
mismatched head is read as a fork.

**A prekey claim is never cached, coalesced, memoized or replayed.** It consumes one-time
prekeys, so two callers asking for the same device produce two claims or none.

Everything invalidates it immediately:

- a `stale_devices` response, through `stale_device_refresh_requests`;
- a user opening or confirming a contact's safety number;
- any trust-state transition, fork detection or device-log head advance;
- 30 seconds.

`refreshPeer` and `confirmOutOfBand` are never served a remembered answer. Both exist to ask
whether this device's idea of a peer is still right — one for a person reading a safety number,
one for the delivery cycle acting on a `stale_devices` response — so each drops the peer and
keeps it dropped for the whole resolution, including against a fan-out running concurrently.
The fan-out's own entry points, `resolveLiveDevices` and `refreshPeerForDevices`, are the ones
the cache exists for: they ask about the same peer two to four times inside one delivery cycle.
See [ADR-065](decisions.md).

## Prekey and key-package policy

Concrete low/target watermarks are configuration constants below the classical cap of
200, ML-KEM cap of 100, and consumable KeyPackage cap of 100. The crypto core generates
material; a maintenance use case uploads it only for the current device. Signed
classical/PQ prekeys rotate on schedule and after suspicion of compromise, atomically
with a fresh device `cross_sig` and incremented `bundle_version`. Each device maintains
one last-resort PQ MLS KeyPackage outside the consumable count after the
[PQ MLS production gates](mls-profile.md#production-gates) pass; reuse is recorded as a
forward-secrecy degradation, not treated as equivalent inventory. Failed signature or
cross-signature verification blocks session setup. No production KeyPackage is generated
or uploaded while those gates remain open.

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
Pairwise sessions start fresh; missing MLS state requires peers to remove and re-add the
device with a fresh Welcome. The UI separates `identity recovered`, `waiting for existing
device`, `history transferring`, `group rejoin required`, and `ready`.

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
