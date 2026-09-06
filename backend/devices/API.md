# devices API

The device registry and public-key distribution: publishing the account's
cross-signing identity, registering a device with its signed key bundle, listing and
labelling devices, replenishing classical and ML-KEM one-time prekeys, maintaining
the client-signed device-list log, reading peers' device lists,
and claiming key material to start sessions. Every route here is served by FastAPI.

All paths are under `/api/v1`. Requests and responses are JSON; binary values are
base64 strings. Unless an endpoint says otherwise, it requires
`Authorization: Bearer <session token>`. Errors use the envelope and
the vocabulary that [`core/API.md`](../core/API.md) fixes; three responses can appear
on any authenticated endpoint and are not repeated per section:

- `401 {"code": "unauthenticated", …}` with `WWW-Authenticate: Bearer` when the
  `Authorization` header is absent or malformed;
- `401 {"code": "invalid_token", …}` when the token fails signature, expiry, type or
  claim checks;
- `401 {"code": "token_revoked", …}` when the device is revoked or deleted, a
  generation is stale, or the account has been deactivated.

Every request body rejects a field the endpoint does not declare, and every field is
read strictly: a value of the wrong JSON type is refused rather than converted, so
`"1"` and `true` are not accepted where an integer is declared. A `{user_id}` or
`{device_id}` in a path that is not a UUID is
`400 {"code": "invalid_request", "detail": {"user_id": [...]}}`, not a `404`.

**Nothing in this app is verified server-side.** Cross-signatures, prekey signatures,
identity self-signatures, and device-log hash chains are stored and relayed as opaque
bytes; every length and version check below is a malformed-input or anti-accident
guard, never a security control. The verifying party is always the peer client —
`CLIENT_CONTRACT.md` specifies that half.

## Publish my cross-signing identity

**Method:** `PUT`
**Path:** `/api/v1/me/identity`

Uploads the account's cross-signing public keys: the master key, the self-signing key
(signs device bundles), the user-signing key (signs other users' master keys after
out-of-band verification), and `master_sig`, the master key's Ed25519 signature over
the canonical subkey encoding (`chat:v1:cross-signing-keys` — exact bytes and golden
vectors below). All are opaque to the server. The `version`
must be strictly greater than the stored one; the check exists so a stale client
cannot accidentally clobber a newer identity — a modified server would simply not
apply it, so clients must detect identity changes themselves (fetch + compare against
the out-of-band-verified master key).

A fresh account publishes its identity immediately after registering its first device
(the first registration is the only one allowed without a published identity — see
device registration below).

**Retry semantics.** A retry of the same `PUT` either applies it or answers `409
stale_version`, because the first attempt already stored that version. Both leave the
stored identity correct; on `409` the client re-reads before it writes again.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |
| `Content-Type` | yes | `application/json` |

**Request body**

```json
{
  "master_pub": "bU1hc3RlcktleQ…",
  "self_signing_pub": "c1NlbGZTaWdu…",
  "user_signing_pub": "dVVzZXJTaWdu…",
  "master_sig": "Z01hc3RlclNpZw…",
  "version": 1
}
```

Keys decode to 32–256 bytes (Ed25519 keys are 32); `master_sig` must decode to exactly
64 bytes. `version` fits a 32-bit column.

**Responses**

### Published — `200 OK`

Empty body.

### Invalid request — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "master_sig": ["bad signature length"] } }
```

### Body too large — `413 Payload Too Large`

```json
{ "code": "payload_too_large", "detail": "Request body is too large." }
```

The cap on this route is 16 KiB, counted as the bytes arrive rather than read from
`Content-Length`, so an understated header does not defeat it.

### Stale version — `409 Conflict`

```json
{ "code": "stale_version", "detail": "Version must increase." }
```

Sent when `version` ≤ the stored version; the stored identity is unchanged.

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.

## Fetch a user's cross-signing identity

**Method:** `GET`
**Path:** `/api/v1/users/{user_id}/identity`

Returns the user's published identity verbatim — including after a master-key change:
the server never smooths over, merges, or hides a substitution, because surfacing the
new bytes is exactly what lets the client raise its safety-number-style alarm and
block the conversation pending re-verification.

**The client must verify signatures over the exact key bytes in this response, never
look a key up by a server-supplied identifier and trust that instead.** That mistake
was CVE-2022-39250 in matrix-js-sdk (cross-signing identity injection, CVSS 8.6):
checking and signing were two separate steps, so a malicious homeserver could
substitute the key between them. The canonical encodings in this API are
self-contained so no such indirection exists.

The response carries an `ETag` over the four key fields and the version, mirrored as
`etag` in the body, and answers `304` to a matching `If-None-Match`. The tag is
derived from the row rather than stored beside it, so a `304` costs the server the
same one query a `200` does; what it saves is the body, which is four base64 key
fields on every recipient of every send.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |
| `If-None-Match` | no | Previous `ETag` value |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| `user_id` | UUID | yes | Account whose identity is fetched |

**Retry semantics.** Safe to repeat: the route writes nothing. `version` moves when the
user rotates the identity, and a client that has pinned one compares that rather than
the key bytes. A retry carrying the `ETag` of the first answer gets `304` while the
identity is unchanged.

**Responses**

### Found — `200 OK`

```json
{
  "master_pub": "bU1hc3RlcktleQ…",
  "self_signing_pub": "c1NlbGZTaWdu…",
  "user_signing_pub": "dVVzZXJTaWdu…",
  "master_sig": "Z01hc3RlclNpZw…",
  "version": 3,
  "etag": "\"9f2c4b7a1e6d3058c4a1b2e7f0d93a65\""
}
```

Header: `ETag: "9f2c4b7a1e6d3058c4a1b2e7f0d93a65"`. The tag changes when any of the
four key fields or the version changes, and never otherwise.

### Not modified — `304 Not Modified`

Empty body.

### Malformed id — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "user_id": ["Input should be a valid UUID, invalid character: found `n` at 1"] } }
```

A `user_id` that is not a UUID never reaches the lookup.

### No published identity, unknown or deactivated user — `404 Not Found`

```json
{ "code": "not_found", "detail": "No published identity." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.

## The canonical device-bundle encoding (client-computed; the server never parses it)

The self-signing key signs every device's bundle. The signed payload is the ASCII
domain separator `chat:v1:device-bundle` followed by the length-prefixed concatenation
(4-byte big-endian length before each field) of, in this exact order:

| # | Field | Encoding |
|---|-------|----------|
| 1 | `user_id` | 16 bytes, UUID raw |
| 2 | `device_id` | 16 bytes, UUID raw |
| 3 | `ik_pub` | raw bytes |
| 4 | `spk_id` | 4 bytes, big-endian |
| 5 | `spk_pub` | raw bytes |
| 6 | `pq_spk_id` | 4 bytes, big-endian; zero-length field if absent |
| 7 | `pq_spk_pub` | raw bytes; zero-length field if absent |
| 8 | `registration_id` | 4 bytes, big-endian |
| 9 | `bundle_version` | 4 bytes, big-endian |

The encoding embeds the key **bytes**, never key identifiers, so verifying it commits
the verifier to exactly the material the server served (the CVE-2022-39250 lesson
above). `bundle_version` is bumped by the client whenever any signed field changes, so
a stale signature is detectable client-side.

> **Load-bearing coupling:** rotating the signed prekey (`spk`) changes field 5, so
> the existing `cross_sig` goes stale. A client that rotates `spk` without supplying a
> fresh `cross_sig` and incremented `bundle_version` **in the same request** will be
> correctly rejected by peers. See "Replenish prekeys" below.

> **`cross_sig` cannot be computed at registration time.** Field 2 is the `device_id`
> that `POST /me/devices` assigns, so the first call goes out without a cross-signature
> and the client supplies it in the follow-up `PUT /me/devices/{id}/prekeys`. Full
> enrollment order: `CLIENT_CONTRACT.md` §M.

### `ik_pub` layout

`ik_pub` is exactly **64 bytes**: the device's Ed25519 signing public key (bytes 0–31)
followed by its X25519 identity public key (bytes 32–63). The Ed25519 half verifies
`spk_sig` and `pq_spk_sig`; the X25519 half is the identity key in X3DH/PQXDH. The
server's 32–256-byte range check deliberately does **not** enforce this — enforcing it
would mean the server parsing key material and committing to a curve. A peer whose
`ik_pub` is not 64 bytes is malformed to clients, not to the server.

### The other three signature encodings

Same rule as the bundle: ASCII domain separator, then a 4-byte big-endian length before
each field. Distinct separators are what stop a signature from one context being
replayed into another.

| Signature | Signed by | Domain separator | Fields, in order |
|---|---|---|---|
| `master_sig` | master key | `chat:v1:cross-signing-keys` | `user_id` (16 B) · `self_signing_pub` (raw) · `user_signing_pub` (raw) |
| `spk_sig` | Ed25519 half of `ik_pub` | `chat:v1:signed-prekey` | `user_id` (16 B) · `spk_id` (4 B BE) · `spk_pub` (raw) |
| `pq_spk_sig` | Ed25519 half of `ik_pub` | `chat:v1:pq-signed-prekey` | `user_id` (16 B) · `pq_spk_id` (4 B BE) · `pq_spk_pub` (raw) |

`master_sig` does not cover `version`: the version is this server's anti-accident
monotonic check, and signing it would imply the served number carries a guarantee it
does not. The two prekey signatures do not cover `device_id`, which would otherwise be
unknowable at registration — the bundle above is what binds a prekey to a device.

**Golden vectors for all four encodings: `devices/vectors/`.** Reproducing them byte for
byte is the only way two client platforms can be sure they agree; the server never
computes or checks any of it.

## Register a device / list my devices

**Method:** `POST`, `GET`
**Path:** `/api/v1/me/devices`

`POST` registers a cryptographic device: identity key, signed prekey with signature,
registration id, optional ML-KEM-768 signed prekey and one-time prekeys, optional
encrypted label, and optional initial classical one-time prekeys, all in one
transaction. It is the only endpoint that accepts a register-scope token, and it
responds with a full-scope token pair for the new device. Live devices are capped per
account (default 10); revoked devices do not count.

**`cross_sig` and `bundle_version` are not accepted here.** Sending either is a `400`
whose message names the endpoint that does accept them. No valid value exists: the
canonical bundle above covers `device_id` (field 2), and this request is what mints it,
so a cross-signature computed before the `201` cannot cover the device it describes. A
later device has a second reason: cross-signing needs the account's self-signing private
key, which lives in the key backup, and reading that needs the full-scope token this
endpoint returns. The cross-signature therefore belongs in the client's **next** call,
`PUT /me/devices/{id}/prekeys`.

Every device is consequently born with `cross_sig` null — the "never cross-signed" state
peers already refuse — and null here does **not** mean a pre-cross-signing device. The
field is refused rather than quietly ignored because storing a signature over the wrong
`device_id` is worse than storing nothing: peers read null as "unverified, withhold", but
read the later correction as a **cross-signature change**, which `CLIENT_CONTRACT.md`
§D/§E requires them to treat as a safety-number event and block the conversation over.

Any registration past the account's first live device additionally requires a published
identity (`400 {"code":"identity_required"}` — the first device is exempt because a
register-scope token cannot have published one yet). None of these are security
controls: a modified server would skip them, and peers must reject unverifiable devices
regardless. What they buy is that a client cannot believe it cross-signed a device it
did not. The full enrollment order is `CLIENT_CONTRACT.md` §M.

`GET` (session token only) lists the caller's live devices with their encrypted labels
and coarse dates, marking which entry is the calling device, plus `log_head_seq`, the
head of the account's device-list log (null when empty). The response carries an
`ETag`; poll with `If-None-Match` and treat `304` as "nothing changed". The tag covers
the live device set **and** the device-log head, so a log append also invalidates it —
expect more frequent invalidation than under the device-set-only tag.

**Retry semantics.** `POST` is not idempotent: a retry after a lost response mints a
second device with a second id and a second session token, and the first device stays
live and counts against `MAX_DEVICES_PER_USER`. A client that has lost the response
lists its devices with `GET` before it registers again, and revokes the device it
cannot use. `GET` writes nothing.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>`; POST also accepts a register token, GET does not |
| `Content-Type` | POST only | `application/json` |
| `If-None-Match` | no (GET) | Previous `ETag` value |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| — | | | none |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body** (POST)

```json
{
  "ik_pub": "mNfJ2kLxWQ…",
  "spk_id": 1,
  "spk_pub": "aX9cR3tYvB…",
  "spk_sig": "Zk4wPq8sLm…",
  "registration_id": 4242,
  "pq_spk": { "spk_id": 1, "pub": "cVBxU3BrS2V5…", "sig": "c1BxU2ln…" },
  "pq_otpks": [ { "key_id": 1, "pub": "cVBxT3Rwaw…" } ],
  "label_blob": "cGFkZGVkLWxhYmVs…",
  "otpks": [ { "key_id": 1, "pub": "b2t0cGtl…" } ]
}
```

Classical key fields decode to 32–256 bytes; `pq_spk.sig` to exactly 64 bytes (Ed25519);
PQ public keys to exactly 1184 bytes (an ML-KEM-768 encapsulation key is fixed-size, so
the exact check rejects nothing a real client would send). `ik_pub` is the 64-byte
Ed25519-then-X25519 pair the client contract defines; the server's range check is
deliberately looser than that and commits to nothing about the bytes, so a wrong-sized
`ik_pub` is caught only by peers.
`otpks` ≤ 200 and `pq_otpks` ≤ 100 items with unique `key_id`s per list;
`label_blob` optional, one label bucket (256 or 1024 bytes). Integer ids must fit a
32-bit column. Every signature is stored and relayed, never verified server-side;
verification is the peer client's job.

**Responses**

### Registered — `201 Created` (POST)

```json
{
  "device_id": "9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611",
  "token": "eyJhbGciOiJIUzI1NiIs…",
  "expires_in": 2592000,
  "scope": "full"
}
```

The token is a session token bound to the device the response names, and
`expires_in` is its lifetime in seconds. It is the credential the client
cross-signs the new device with; there is nothing further to exchange.

### Listed — `200 OK` (GET)

```json
{
  "devices": [
    {
      "device_id": "9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611",
      "label_blob": "cGFkZGVkLWxhYmVs…",
      "created_date": "2026-07-20",
      "this_device": true
    }
  ],
  "log_head_seq": 4
}
```

`label_blob` and `log_head_seq` may be `null`. Header: `ETag: "5b3a9c…"`.

There is no last-active value. The server records no activity day for a device
(ADR-0024), so this list carries the day it was added and nothing about when it was
last seen.

### Not modified — `304 Not Modified` (GET)

Empty body, when `If-None-Match` matches the current `ETag`.

### Invalid request — `400 Bad Request` (POST)

```json
{ "code": "invalid_request", "detail": { "otpks.0.pub": ["invalid base64"] } }
```

`detail` maps a dotted field path to its messages; a list item carries its index in
that path.

### Off-bucket label — `400 Bad Request` (POST)

```json
{ "code": "bad_bucket", "detail": "Invalid payload." }
```

### Cross-signature sent at registration — `400 Bad Request` (POST)

```json
{
  "code": "invalid_request",
  "detail": {
    "cross_sig": ["Not accepted at registration: the canonical device bundle covers device_id, which this request assigns, so no signature computed before the response can be valid. Send cross_sig and bundle_version to PUT /me/devices/{device_id}/prekeys once you have the device_id."]
  }
}
```

Both fields are named when both are sent.

### No published identity (second device onward) — `400 Bad Request` (POST)

```json
{ "code": "identity_required", "detail": "Publish a cross-signing identity before adding another device." }
```

### Body too large — `413 Payload Too Large` (POST)

```json
{ "code": "payload_too_large", "detail": "Request body is too large." }
```

The cap on this route is 70 MiB, counted as the bytes arrive rather than read from
`Content-Length`, so an understated header does not defeat it. The 70 MiB is what nginx
admits; the list caps of the schema refuse a larger body long before it.

### Device cap reached — `409 Conflict` (POST)

```json
{ "code": "device_limit", "detail": "This account has too many devices." }
```

### Register-scope token — `403 Forbidden` (GET)

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.

## Relabel or revoke a device

**Method:** `PUT`, `DELETE`
**Path:** `/api/v1/me/devices/{device_id}`

`PUT` replaces the device's encrypted label. `DELETE` revokes the device: its token
generation is bumped (killing every outstanding token of that device), its
one-time prekeys (classical and ML-KEM) and queued envelopes are deleted in one
transaction, any live WebSocket is closed with code 4003, and it disappears from
device lists. Revocation is permanent; a "re-added"
device is a new registration. Any device of the account may revoke any other (or
itself). The client appends a device-list log record for the removal
(CLIENT_CONTRACT.md §J).

**Retry semantics.** `PUT` is idempotent: it replaces the label blob, so a repeated
call with the same body leaves the same label. `DELETE` is safe to repeat and
self-reporting: the first call revokes, and a second answers `404` because a revoked
device is no longer found — which is also what an id from another account answers, so
a `404` never confirms that a device exists.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |
| `Content-Type` | PUT only | `application/json` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| `device_id` | UUID | yes | A live device belonging to the caller |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body** (PUT)

```json
{ "label_blob": "cGFkZGVkLWxhYmVs…" }
```

**Responses**

### Relabelled — `200 OK` (PUT)

Empty body.

### Revoked — `204 No Content` (DELETE)

Empty body.

### Invalid request — `400 Bad Request` (PUT)

```json
{ "code": "invalid_request", "detail": { "label_blob": ["Field required"] } }
```

An off-bucket label is `400 {"code": "bad_bucket", "detail": "Invalid payload."}`.

### Malformed id — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "device_id": ["Input should be a valid UUID, invalid character: found `n` at 1"] } }
```

A `device_id` that is not a UUID never reaches the lookup.

### Body too large — `413 Payload Too Large` (PUT)

```json
{ "code": "payload_too_large", "detail": "Request body is too large." }
```

The cap on this route is 16 KiB, counted as the bytes arrive rather than read from
`Content-Length`, so an understated header does not defeat it.

### Unknown, foreign, or already-revoked device — `404 Not Found`

```json
{ "code": "not_found", "detail": "No such device." }
```

Another account's device id is a `404`, not a `403`, so existence is not confirmed.

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.

## Replenish prekeys

**Method:** `PUT`
**Path:** `/api/v1/me/devices/{device_id}/prekeys`

Uploads new one-time prekeys (classical and/or ML-KEM) and/or rotates the signed
prekeys for the calling device. Only the device itself may call this: the token's
`device_id` must equal the path. Re-uploading a `key_id` the device already stored is
an idempotent retry, not an error; a duplicated `key_id` inside one payload is a
`400`. The classical pool is capped at 200 and the PQ pool at 100; a batch that would
cross either cap is refused whole and, in that case, nothing else in the request is
applied either — no prekey rotation, no signature update.

> **This is also where a device's first `cross_sig` arrives.** Registration cannot
> carry one — the canonical bundle covers the `device_id` that registration assigns —
> so every newly registered device cross-signs itself here, with the `device_id` from
> its `201`. See `CLIENT_CONTRACT.md` §M for the full order.

> **Rotating `spk` stales your `cross_sig`.** The signed prekey is a field of the
> canonical device bundle, so replacing it invalidates the stored cross-signature.
> Send a fresh `cross_sig` and an incremented `bundle_version` **in the same call**,
> or peers fetching your bundle will correctly reject this device. Sending one without
> the other is a `400`, and so is sending `bundle_version` as `null` — the version is a
> number or it is not sent, because a `cross_sig` stored against no version is one peers
> must reject. Beyond that the server stores whatever it is given and never
> checks that the signature matches the bundle — only peers can, so there is no server
> error to save a client that signs the wrong bytes.

Clients watch the count endpoint (or the `otpk_count` in this response) and replenish
when the pools run low, since every peer claim consumes one of each.

**Retry semantics.** Idempotent on the keys: a `key_id` the device already stores is
ignored rather than rejected, so re-sending a batch stores nothing twice and the
returned `otpk_count` is the truth either way. Two cases are not idempotent. The
signed prekey and the cross-signature are replaced by whatever the retry carries, and
the pool cap is checked against the batch as sent, so a retry of a batch that already
landed can answer `409 prekey_limit` while storing nothing. On `409` the client reads
`GET .../prekeys/count` before it decides what to send.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>`, bound to `{device_id}` |
| `Content-Type` | yes | `application/json` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| `device_id` | UUID | yes | Must equal the token's own device id |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

```json
{
  "spk": { "spk_id": 7, "pub": "aX9cR3tYvB…", "sig": "Zk4wPq8sLm…" },
  "cross_sig": "eENyb3NzU2ln…",
  "bundle_version": 2,
  "pq_spk": { "spk_id": 3, "pub": "cVBxU3BrS2V5…", "sig": "c1BxU2ln…" },
  "pq_otpks": [ { "key_id": 12, "pub": "cVBxT3Rwaw…" } ],
  "otpks": [ { "key_id": 41, "pub": "b2t0cGtl…" } ]
}
```

All fields optional; an empty body is a no-op that still returns the count. PQ public
keys must decode to exactly 1184 bytes; `cross_sig` and `pq_spk.sig` to exactly 64.

**Responses**

### Replenished — `200 OK`

```json
{ "otpk_count": 173 }
```

### Invalid request — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "otpks": ["duplicate key_id"] } }
```

### Not this device — `403 Forbidden`

```json
{ "code": "forbidden", "detail": "This token does not belong to that device." }
```

### Body too large — `413 Payload Too Large`

```json
{ "code": "payload_too_large", "detail": "Request body is too large." }
```

The cap on this route is 70 MiB, counted as the bytes arrive rather than read from
`Content-Length`, so an understated header does not defeat it. The 70 MiB is what nginx
admits; the list caps of the schema refuse a larger body long before it.

### Pool cap reached — `409 Conflict`

```json
{ "code": "prekey_limit", "detail": "Too many stored one-time prekeys for this device." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.

## Prekey count

**Method:** `GET`
**Path:** `/api/v1/me/devices/{device_id}/prekeys/count`

Reports how many one-time prekeys — classical and ML-KEM — the calling device still
has stored. Same self-only gate as replenishment.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>`, bound to `{device_id}` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| `device_id` | UUID | yes | Must equal the token's own device id |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

None.

**Retry semantics.** Safe to repeat: the route writes nothing. The two counts fall
whenever a peer claims a bundle, so treat an answer as a reading taken at that instant
and never as a reservation.

**Responses**

### Counted — `200 OK`

```json
{ "otpk_count": 173, "pq_otpk_count": 88 }
```

### Malformed id — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "device_id": ["Input should be a valid UUID, invalid character: found `n` at 1"] } }
```

A `device_id` that is not a UUID never reaches the lookup.

### Not this device — `403 Forbidden`

```json
{ "code": "forbidden", "detail": "This token does not belong to that device." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.

## List a user's devices

**Method:** `GET`
**Path:** `/api/v1/users/{user_id}/devices`

The public identity of a peer's live devices: device id, identity key, registration
id, cross-signature, and bundle version, ordered by id — what a sender needs to fan a
message out to every device *and* to verify each device against the owner's published
identity. `cross_sig` is served verbatim, `null` included: a device that was never
cross-signed must be visible as unsigned so peers can refuse it (the server never
substitutes or synthesizes a signature). The response also carries `log_head_seq`, the
head of the user's device-list log. Labels, dates, and activity are omitted; those
belong to the owner. The response carries an `ETag` (also mirrored in the body), and
an unknown user is indistinguishable from a user with no live devices.

Poll with `If-None-Match` before encrypting to a peer; a changed tag means a device
was added or removed **or the device log was appended to** (the tag covers both), and
session state / log-head comparison should be refreshed.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |
| `If-None-Match` | no | Previous `ETag` value |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| `user_id` | UUID | yes | Account whose devices are listed |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

None.

**Retry semantics.** Safe to repeat: the route writes nothing. A retry that carries the
`ETag` of the first answer gets `304` while the device set is unchanged, which is the
cheap way to poll it.

**Responses**

### Listed — `200 OK`

```json
{
  "devices": [
    {
      "device_id": "2a77d4b9-e611-4c0f-9f1c-6a2e3b7d4e0f",
      "ik_pub": "mNfJ2kLxWQ…",
      "registration_id": 4242,
      "cross_sig": "eENyb3NzU2ln…",
      "bundle_version": 2
    }
  ],
  "etag": "\"5b3a9c1d7e2f4a6b8c0d1e2f3a4b5c6d\"",
  "log_head_seq": 4
}
```

Header: `ETag: "5b3a9c1d7e2f4a6b8c0d1e2f3a4b5c6d"`. `cross_sig` and `log_head_seq`
may be `null`. An unknown or deactivated user yields `{"devices": [], "etag": …,
"log_head_seq": null}` with `200`.

### Malformed id — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "user_id": ["Input should be a valid UUID, invalid character: found `n` at 1"] } }
```

A `user_id` that is not a UUID never reaches the lookup.

### Not modified — `304 Not Modified`

Empty body.

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.

## Peer state for a set of users

**Method:** `POST`
**Path:** `/api/v1/peers`

Everything a sender needs to verify a set of recipients, in one call: for each peer
its published identity, its live devices and the head of its device-list log — the
same bytes `GET /api/v1/users/{user_id}/identity` and
`GET /api/v1/users/{user_id}/devices` serve, verbatim. A client that verifies the
per-user answers verifies these without changing a line of that code.

It exists because verifying a fan-out cost three reads for each recipient. A
50-member group was 150 round trips before a single send, against a scope that
counts every one of them; this is one.

A `POST` because the request carries a body — up to 64 ids, each with the tag the
client already holds — and a query string will not carry 64 of those. It reads state
and writes none.

Each answer carries **this route's own tag**, which is not the tag of either
per-user route: it covers the identity, the live device set, every device's
`bundle_version` and the log head together, so one comparison replaces three. Send
the tag back on the next cycle and a peer whose state has not moved answers with
three fields and no body.

An unknown, inactive or deactivated user is **omitted** from the answer rather than
distinguished — the same refusal to tell those apart that the per-user routes make.
A `user_id` repeated in the request is answered once for each entry, each against
its own `etag`.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| — | | | none |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

| Field | Type | Required | Description |
|---|---|---|---|
| `peers` | array | yes | 1 to 64 items |
| `peers[].user_id` | UUID | yes | Account to read |
| `peers[].etag` | string | no | The tag this route gave for that peer earlier; max 64 characters |

An unknown field anywhere in the body is refused.

```json
{
  "peers": [
    { "user_id": "0f8b2c11-6a5e-4f3d-9c27-1e8a5b0d4c73" },
    {
      "user_id": "7c1d9e40-3b62-4a08-9f51-2d6c8a3b7e19",
      "etag": "\"3d5f81a0c26b47e9138a5c0d2f7b46e1\""
    }
  ]
}
```

**Retry semantics.** Safe to repeat: the route writes nothing. A retry that carries
the tags of the first answer gets `unchanged` for every peer that has not moved,
which is the cheap way to poll before a send. Its cost to the server does not grow
with the number of peers: one call is four queries whether it names one peer or
sixty-four.

**Responses**

### Read — `200 OK`

```json
{
  "peers": [
    {
      "user_id": "0f8b2c11-6a5e-4f3d-9c27-1e8a5b0d4c73",
      "etag": "\"a1b2c3d4e5f60718293a4b5c6d7e8f90\"",
      "identity": {
        "master_pub": "bU1hc3RlcktleQ…",
        "self_signing_pub": "c1NlbGZTaWdu…",
        "user_signing_pub": "dVVzZXJTaWdu…",
        "master_sig": "Z01hc3RlclNpZw…",
        "version": 3,
        "etag": "\"9f2c4b7a1e6d3058c4a1b2e7f0d93a65\""
      },
      "devices": [
        {
          "device_id": "2a77d4b9-e611-4c0f-9f1c-6a2e3b7d4e0f",
          "ik_pub": "mNfJ2kLxWQ…",
          "registration_id": 4242,
          "cross_sig": "eENyb3NzU2ln…",
          "bundle_version": 2
        }
      ],
      "log_head_seq": 4
    },
    {
      "user_id": "7c1d9e40-3b62-4a08-9f51-2d6c8a3b7e19",
      "etag": "\"3d5f81a0c26b47e9138a5c0d2f7b46e1\"",
      "unchanged": true
    }
  ]
}
```

Items are in request order, and only users that exist and are active appear.

Two item shapes, and `unchanged` is what tells them apart. It is present only on the
short one and is always `true`; branch on its presence, never on its value.

- **Unchanged** — `user_id`, `etag`, `unchanged`. The `etag` the request carried is
  still the current one, so the peer's identity, live device set, bundle versions
  and log head are all as the client last read them.
- **Full** — `user_id`, `etag`, `identity`, `devices`, `log_head_seq`. `identity` is
  the whole body of `GET /api/v1/users/{user_id}/identity`, or `null` when the user
  has published none. `devices` holds the items of
  `GET /api/v1/users/{user_id}/devices`, ordered by device id, and is `[]` for a user
  with no live device. `log_head_seq` is `null` for an empty log.

`cross_sig` is `null` on a device that was never cross-signed, exactly as it is on
the per-user list: an unsigned device must look unsigned, and the client — never the
server — decides what to do about it.

### Malformed body — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "peers.0.user_id": ["Input should be a valid UUID, invalid character: found `n` at 1"] } }
```

An empty `peers`, more than 64 items, an unknown field, or a `user_id` that is not a
UUID all land here.

### Body too large — `413 Payload Too Large`

```json
{ "code": "payload_too_large", "detail": "Request body is too large." }
```

Cap: `BODY_CAP_JSON_BYTES`, 16 KiB by default, which is well above 64 ids and their
tags.

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.

## Claim prekey bundles

**Method:** `POST`
**Path:** `/api/v1/users/{user_id}/keys/claim`

Returns a hybrid PQXDH bundle for each of the target user's live devices, atomically
consuming one classical and (when the device has PQ material) one ML-KEM one-time
prekey per device (each key is handed out at most once, even under concurrent
claims). When a device's classical pool is empty the bundle is served without the
`otpk` field; the client falls back per protocol. Claiming your own `user_id` is the
normal self-sync path.

**When a device holds no PQ signed prekey, every PQ field is omitted from its bundle
— never null-filled, zeroed, or substituted with classical material — so a
classical-only bundle is visibly classical-only.** Deciding whether to refuse it or
proceed with a clearly-flagged classical-only session is the client's job
(CLIENT_CONTRACT.md §F: never silently downgrade).

Call it when starting a session with a peer. An explicit `"device_ids": []` claims
nothing — the empty list is honoured, not treated as "all" — so batch carefully.
Group sessions start here too: a group is a set of pairwise sessions, one per member
device, so starting one claims from each member's `user_id` in turn
(CLIENT_CONTRACT.md §F). There is no group-specific key material.

**Retry semantics.** Not idempotent, and expensively so: every call consumes one
one-time prekey from each target device, so a retry after a lost response burns a
second key per device and the first is gone for good. Nothing recovers it — a
one-time prekey is handed out once by construction. A client that loses the response
treats the claim as spent and starts the session from the bundle the retry returned.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |
| `Content-Type` | yes | `application/json` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| `user_id` | UUID | yes | Owner of the devices whose prekeys are claimed |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

```json
{ "device_ids": ["2a77d4b9-e611-4c0f-9f1c-6a2e3b7d4e0f"] }
```

Optional (≤ 100 ids). Omitted entirely means "all live devices of that user".

**Responses**

### Claimed — `200 OK`

```json
{
  "bundles": [
    {
      "device_id": "2a77d4b9-e611-4c0f-9f1c-6a2e3b7d4e0f",
      "registration_id": 4242,
      "ik_pub": "mNfJ2kLxWQ…",
      "spk_id": 7,
      "spk_pub": "aX9cR3tYvB…",
      "spk_sig": "Zk4wPq8sLm…",
      "cross_sig": "eENyb3NzU2ln…",
      "bundle_version": 2,
      "pq_spk_id": 3,
      "pq_spk_pub": "cVBxU3BrS2V5…",
      "pq_spk_sig": "c1BxU2ln…",
      "pq_otpk": { "key_id": 12, "pub": "cVBxT3Rwaw…" },
      "otpk": { "key_id": 41, "pub": "b2t0cGtl…" }
    }
  ]
}
```

`otpk` is absent when that device's classical pool is empty; `pq_otpk` when its PQ
pool is empty; all four `pq_*` fields when the device has no PQ signed prekey.
`cross_sig` is `null` for a device that was never cross-signed (verify before
encrypting — CLIENT_CONTRACT.md §C/§E). An unknown user or one with no live devices
yields `{"bundles": []}` with `200`.

### Invalid request — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "device_ids.0": ["Input should be a valid UUID, invalid character: found `n` at 1"] } }
```

### Body too large — `413 Payload Too Large`

```json
{{ "code": "payload_too_large", "detail": "Request body is too large." }}
```

The cap on this route is 70 MiB, counted as the bytes arrive rather than read from
`Content-Length`, so an understated header does not defeat it. The 70 MiB is what
nginx admits; the list caps of the schema refuse a larger body long before it.

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `claim`, default 120/min.

## Append to my device-list log

**Method:** `POST`
**Path:** `/api/v1/me/devicelog`

Appends client-signed, hash-chained records to the account's device-list log. The
client appends one on every device-set change (add, remove, revoke) and on identity
rotation. Record contents are client-defined and opaque — the expected structure is
`prev_hash`, a hash of the canonical device-set encoding, the current identity
`version`, the record `seq`, a coarse timestamp, and an Ed25519 signature by the
self-signing key over all of it — but **the server never parses or validates any of
that, including the hash chain**. A record whose `prev_hash` links to nothing is
accepted and served verbatim; server-side chain validation would be fake enforcement
that trains clients to skip the head comparison which actually detects equivocation.
Two honest clients holding different heads for the same user is cryptographic proof
the server equivocated — detection, not prevention, and only once two clients
actually compare (clients gossip heads inside ordinary E2EE messages).

Appending changes the account's device-list `ETag`, so polling peers re-fetch and see
the new head.

The log holds at most `MAX_DEVICELOG_RECORDS` records (default 10 000) and is never
pruned. An append that would pass the ceiling is refused whole with
`409 devicelog_limit` and stores nothing. A client appends one record for each
device-set change, so a log that reaches the ceiling is a client defect, not a
condition to handle by trimming: nothing on the server removes a record.

**Retry semantics.** Not idempotent: the server assigns `seq` and never inspects a
record, so a retry after a lost response appends the same blobs again under fresh
sequence numbers. The log is a hash chain the client builds, so the duplicate records
link to the same predecessor and every reader sees a fork. Before retrying, read the
log back with `GET /users/{user_id}/devicelog` and compare `head_seq` against what the
append should have produced.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |
| `Content-Type` | yes | `application/json` |

**Request body**

```json
{ "records": [ { "blob": "ZGV2aWNlbG9nLXJlY29yZA…" } ] }
```

1–50 records, each exactly one device-log bucket (256 or 1024 bytes).

**Responses**

### Appended — `201 Created`

```json
{ "first_seq": 5, "last_seq": 5 }
```

Sequence numbers are server-assigned, per-user, contiguous within a batch, starting
at 0.

### Body too large — `413 Payload Too Large`

```json
{{ "code": "payload_too_large", "detail": "Request body is too large." }}
```

The cap on this route is 70 MiB, counted as the bytes arrive rather than read from
`Content-Length`, so an understated header does not defeat it. The 70 MiB is what
nginx admits; the list caps of the schema refuse a larger body long before it.

### Off-bucket record — `400 Bad Request`

```json
{ "code": "bad_bucket", "detail": "Invalid payload." }
```

### Log full — `409 Conflict`

```json
{ "code": "devicelog_limit", "detail": "The device-list log of this account is full." }
```

Nothing of the batch is stored.

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.

## Read a user's device-list log

**Method:** `GET`
**Path:** `/api/v1/users/{user_id}/devicelog`

Keyset-paged read of a user's device-list log, records served byte-identically in
seq order — no repair, no reordering, no dropping of non-linking records (see the
append endpoint for why). On fetch, the client verifies the head signature and that
the head **extends** the last head it saw for that user; a fork is proof of server
equivocation (CLIENT_CONTRACT.md §C/§J).

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| `user_id` | UUID | yes | Account whose log is read |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `after` | int | no | start of log | Return records with `seq` greater than this |
| `limit` | int | no | 200 | Page size, clamped into [1, 200] |

A non-numeric `after` falls back to the start; a bad limit falls back to the cap —
never a `500`.

**Request body**

None.

**Retry semantics.** Safe to repeat: the route writes nothing and a keyset page is
stable, because a record is only ever appended and never edited or deleted. Re-reading
a page after a lost response yields the same records; pass the same `after` rather than
restarting from the head.

**Responses**

### Read — `200 OK`

```json
{
  "records": [ { "seq": 4, "blob": "ZGV2aWNlbG9nLXJlY29yZA…" } ],
  "has_more": false,
  "head_seq": 4
}
```

`head_seq` is `null` and `records` empty for an empty log, an unknown user, or a
deactivated user.

### Malformed id — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "user_id": ["Input should be a valid UUID, invalid character: found `n` at 1"] } }
```

A `user_id` that is not a UUID never reaches the lookup.

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 120/min.
