# accounts API

Account lifecycle and identity: registration, login, session renewal and logout, the
user directory, and encrypted profile blobs. Every route here is served by FastAPI.

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
`"1"` and `true` are not accepted where an integer is declared.

## Tokens

The server stores no token. There is one token, and `typ` decides its power.

- A **session token** carries `user_id`, `device_id`, `tgen`, `typ` `session`, `jti`,
  `iat` and `exp`, lives `SESSION_TOKEN_DAYS` days (default 30), and reaches every
  authenticated route.
- A **register token** carries `user_id`, `typ` `register`, `jti`, `iat` and `exp`,
  lives `REGISTER_SCOPE_ACCESS_MIN` minutes (default 10), and reaches
  `POST /api/v1/me/devices` and nothing else. Presenting one anywhere else is
  `403 scope_forbidden`.

One counter on the device row is the whole of revocation. `tgen` is checked against
the device's `token_generation` on every authenticated request and at every socket
bind. Logging out and revoking the device each advance it, and every outstanding
token of that device dies at once.

**Nothing else ends a token before its own `exp`.** A token does not rotate, a login
retires none, and renewing leaves the token it was renewed from valid until that
token expires. A client may therefore hold several live tokens for one device, and
two of its own processes may renew concurrently without either losing the session.

## Register an account

**Method:** `POST`
**Path:** `/api/v1/auth/register`

Creates an account in the inactive state. The server owner activates accounts through
the admin; until then the account cannot log in past the password check. Usernames are
lowercased before validation and storage, so `BoB` and `bob` are the same account.

A client calls this once, shows the "awaiting activation" state on the `403
account_inactive` login response, and retries login later. There is nothing to poll;
activation is a human action.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Content-Type` | yes | `application/json` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| — | | | none |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

```json
{
  "username": "alice",
  "password": "correct-horse-battery-staple"
}
```

`username`: 3–32 chars of `[a-z0-9_]` (case-insensitive input, stored lowercase).
`password`: ≥10 chars, not a common password, ≤256 chars.

**Retry semantics.** A retry after an unclear outcome either creates the account or
answers `409 username_taken`; the second is indistinguishable from someone else taking
the name, so a client that means to own the name should log in to confirm.

**Responses**

### Created — `201 Created`

```json
{ "user_id": "6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10" }
```

### Invalid request — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "password": ["Field required"] } }
```

### Body too large — `413 Payload Too Large`

```json
{ "code": "payload_too_large", "detail": "Request body is too large." }
```

The cap on this route is 16 KiB, counted as the bytes arrive rather than read from
`Content-Length`, so an understated header does not defeat it.

### Username taken — `409 Conflict`

```json
{ "code": "username_taken", "detail": "That username is taken." }
```

Also returned when two concurrent registrations race on the same name.

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `register`, default 10/hour per client address. `Retry-After` carries the
seconds to wait.

## Log in

**Method:** `POST`
**Path:** `/api/v1/auth/login`

Verifies the password and issues a token. With a `device_id` naming a live device of
this account, the response is a session token bound to that device; the device row is
read and never written, so a token that device already held keeps working. Without one
(first login, or a revoked/foreign device id), the response is a short-lived register
token whose only power is `POST /api/v1/me/devices`.

Unknown usernames and wrong passwords return the same body, and unknown usernames
still pay for a real Argon2 verification, so the two cases are not distinguishable by
response or by timing. Activation state is only revealed after a correct password.

Five failed attempts on one name within fifteen minutes lock that name for fifteen
minutes, whether or not an account holds it, so the lock confirms nothing about
existence. A locked name answers `429 throttled` with `Retry-After` before the
password is hashed, and a successful sign-in clears the count. The per-address limit
below stands beside it.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Content-Type` | yes | `application/json` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| — | | | none |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

```json
{
  "username": "alice",
  "password": "correct-horse-battery-staple",
  "device_id": "9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611"
}
```

`device_id` is optional and must be a UUID string when present.

**Retry semantics.** Safe to repeat. A retry issues another token and retires none,
so a client that did not learn the outcome of the first attempt loses nothing by
signing in again; both tokens work until they expire.

**Responses**

### Session token — `200 OK`

```json
{
  "token": "eyJhbGciOiJIUzI1NiIs…",
  "expires_in": 2592000,
  "user_id": "6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10",
  "device_id": "9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611",
  "scope": "full"
}
```

`expires_in` is the lifetime in seconds of the token the response carries. Branch on
`scope`: it is the field that tells the two success shapes apart.

### Register token — `200 OK`

```json
{
  "token": "eyJhbGciOiJIUzI1NiIs…",
  "expires_in": 600,
  "user_id": "6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10",
  "scope": "register"
}
```

### Invalid request — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "device_id": ["Input should be a valid UUID, invalid character: found `n` at 1"] } }
```

### Body too large — `413 Payload Too Large`

```json
{ "code": "payload_too_large", "detail": "Request body is too large." }
```

The cap on this route is 16 KiB, counted as the bytes arrive rather than read from
`Content-Length`, so an understated header does not defeat it.

### Wrong credentials — `401 Unauthorized`

```json
{ "code": "invalid_credentials", "detail": "Username or password is incorrect." }
```

### Awaiting activation — `403 Forbidden`

```json
{ "code": "account_inactive", "detail": "This account is awaiting activation." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Too many sign-in attempts for this name. Wait and try again." }
```

Scope `login`, default 20/hour per client address, with `detail` `"Request was
throttled."`. The body above is the other cause of the same status: the name is in
its cool-off, and `Retry-After` carries the seconds left in it.

## Renew the session token

**Method:** `POST`
**Path:** `/api/v1/auth/renew`

Issues another session token for the device the presented token names. The device and
the account are re-checked through the same verifier every other authenticated route
uses, so a revoked device, a stale token generation and a deactivated account each end
the session here rather than extending it.

**The presented token stays valid until its own `exp`.** Nothing is written and no
generation moves, so renewing invalidates neither the token that bought the new one
nor any other token of the device.

**The request takes no body.** A body, if sent, is ignored. The caller is identified by
the token it presents, so there is nothing to send and nothing to leak.

Clients renew well before expiry — the token lives 30 days by default — and may renew
from more than one process at once without coordinating between them.

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

None.

**Retry semantics.** Safe to repeat. A retry issues another token and retires none, so
a client that did not learn the outcome of the first call simply calls again and keeps
whichever token it received.

**Responses**

### Renewed — `200 OK`

```json
{ "token": "eyJhbGciOiJIUzI1NiIs…", "expires_in": 2592000 }
```

### Register token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

A register token names no device, so there is no session to renew.

### Rate limited — `429 Too Many Requests`

Scope `accounts`, default 300/min per account.

## Log out

**Method:** `POST`
**Path:** `/api/v1/auth/logout`

Ends the session of the device the token names: `token_generation` advances, so the
presented token and every other token of that device die immediately, and the device's
sockets are dropped.

**The request takes no body.** A body, if sent, is ignored. The caller is identified by
the token it presents, so there is nothing to send and nothing to leak.

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

None.

**Retry semantics.** A retry with the same token answers `401 token_revoked`, because
the first call killed that token. A client treats that as success.

**Responses**

### Logged out — `204 No Content`

Empty body.

### Register token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

Scope `accounts`, default 300/min per account.

## List users

**Method:** `GET`
**Path:** `/api/v1/users`

Returns every activated account, ordered by username: this is a small private server
and the directory is how clients pick conversation partners. Entries carry only the id
and username; nothing about devices or activity. Inactive accounts are absent. The list
is not paginated, because the scale band caps it at fewer than 50 accounts.

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

None.

**Retry semantics.** Safe to repeat: the route writes nothing. Two calls a moment
apart can differ all the same, because the operator activates and deactivates accounts
between them; the directory is a current answer, never a stable one.

**Responses**

### Listed — `200 OK`

```json
{
  "users": [
    { "user_id": "6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10", "username": "alice" },
    { "user_id": "b3a91c77-2e5d-4f28-a1c9-8d64e0f3b522", "username": "bob" }
  ]
}
```

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

Scope `accounts`, default 300/min per account.

## Read a user's profile

**Method:** `GET`
**Path:** `/api/v1/users/{user_id}/profile`

Returns the opaque profile blob another user published (display name, avatar, and so
on, encrypted client-side) with its version. The server cannot read it; clients
decrypt with material exchanged in-band. Clients cache by `version` and refetch when
a peer announces a change.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| `user_id` | UUID | yes | Account whose profile is requested |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

None.

**Retry semantics.** Safe to repeat: the route writes nothing. `version` is what tells
two answers apart, so a client that caches a profile compares that rather than the
blob.

**Responses**

### Found — `200 OK`

```json
{ "blob": "q83vEjRWeJq83vEjRWeJ…", "version": 3 }
```

### Malformed id — `400 Bad Request`

```json
{ "code": "invalid_request", "detail": { "user_id": ["Input should be a valid UUID, invalid character: found `n` at 1"] } }
```

### No profile — `404 Not Found`

```json
{ "code": "not_found", "detail": "No profile for that user." }
```

Also returned when the user does not exist or is deactivated.

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

Scope `accounts`, default 300/min per account.

## Read or write my profile

**Method:** `GET`, `PUT`
**Path:** `/api/v1/me/profile`

`GET` returns the caller's own stored profile blob. `PUT` replaces it; the blob must
decode to exactly one profile bucket (1024 or 4096 bytes) and the version must be
strictly greater than the stored one. Version monotonicity is what lets several of
the caller's devices write without a stale device clobbering a newer profile: the
losing writer gets `409 stale_version`, refetches, and reapplies.

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
{ "blob": "q83vEjRWeJq83vEjRWeJ…", "version": 4 }
```

`blob` is at most 8192 characters of base64; `version` is a non-negative integer.

**Retry semantics.** A retry of the same `PUT` either applies it or answers `409
stale_version` because the first attempt already stored that version. Both outcomes
leave the stored blob correct; on `409` the client refetches and re-applies. `GET`
writes nothing and is safe to repeat.

**Responses**

### Read — `200 OK` (GET)

```json
{ "blob": "q83vEjRWeJq83vEjRWeJ…", "version": 3 }
```

### Written — `200 OK` (PUT)

Empty body.

### No profile yet — `404 Not Found` (GET)

```json
{ "code": "not_found", "detail": "No profile yet." }
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

The cap on this route is 16 KiB, counted as the bytes arrive rather than read from
`Content-Length`, so an understated header does not defeat it.

### Stale version — `409 Conflict` (PUT)

```json
{ "code": "stale_version", "detail": "Version must increase." }
```

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

Scope `accounts`, default 300/min per account.
