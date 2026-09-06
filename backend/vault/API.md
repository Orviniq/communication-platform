# vault API

The owner's encrypted storage: a single recovery key backup, strictly scoped to the
calling account. The route is served by FastAPI.

All paths are under `/api/v1`, JSON in and out with base64 blobs,
`Authorization: Bearer` with `full` scope required throughout (a register-scope token
gets `403 {"code": "scope_forbidden", …}` everywhere). Errors use the envelope and the
vocabulary that [`core/API.md`](../core/API.md) fixes, including validation failures;
the project-wide `401` bodies listed in [`accounts/API.md`](../accounts/API.md) apply
here too. The server can never decrypt the blob, and no endpoint accepts or verifies a
recovery secret.

There is **no history API**. The server stores no message history; history transfers
client-to-client between a user's devices over the ordinary envelope endpoint
(`CLIENT_CONTRACT.md` §G), and a new device has none until an existing device is
online to send it.

## Read or write the key backup

**Method:** `GET`, `PUT`
**Path:** `/api/v1/me/keybackup`

One backup blob per account, encrypted client-side under the recovery secret. The
blob carries the account's **cross-signing private keys and identity material** (it
no longer contains a history key — a client-side format change from the era when the
server held a history log). `GET` returns it; `PUT` replaces it, requiring the blob
to be exactly one backup bucket (4096 to 1048576 bytes) and the version to be
strictly greater than the stored one. A wrong recovery secret fails only on the
client; the server offers no check.

A new device calls `GET` after login and decrypts locally. Writers bump `version` on
every upload; on `409` the device refetches, merges, and retries, so a stale device
can never clobber a newer backup — including two racing first uploads.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |
| `Content-Type` | PUT only | `application/json` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| — | | | none |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body** (PUT)

```json
{ "blob": "S0tLS0tLS0tL…", "version": 5 }
```

`blob` is at most 1398112 characters of base64 — the largest bucket plus padding
headroom — and the whole request body is capped at 2 MiB. `version` is a non-negative
integer, read strictly: `"5"` and `5.0` are refused rather than converted. A field the
endpoint does not declare is refused.

**Retry semantics.** A retry of the same `PUT` either applies it or answers `409
stale_version` because the first attempt already stored that version. Both leave the
stored blob correct; on `409` the device refetches and re-applies. `GET` writes nothing
and is safe to repeat.

**Responses**

### Read — `200 OK` (GET)

```json
{ "blob": "S0tLS0tLS0tL…", "version": 5 }
```

### Written — `200 OK` (PUT)

Empty body.

### No backup yet — `404 Not Found` (GET)

```json
{ "code": "not_found", "detail": "No key backup yet." }
```

### Invalid request — `400 Bad Request` (PUT)

```json
{ "code": "invalid_request", "detail": { "version": ["Field required"] } }
```

### Off-bucket blob — `400 Bad Request` (PUT)

```json
{ "code": "bad_bucket", "detail": "Invalid payload." }
```

The rejected payload is never echoed. Field validation runs first, so a body that is
both malformed and off-bucket reports the field error.

### Body too large — `413 Payload Too Large` (PUT)

```json
{ "code": "payload_too_large", "detail": "Request body is too large." }
```

Counted as the bytes arrive, so an understated `Content-Length` does not defeat it.

### Stale version — `409 Conflict` (PUT)

```json
{ "code": "stale_version", "detail": "Version must increase." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `accounts`, default 300/min per account. `Retry-After` carries the seconds to
wait.
