# API changes

Everything a client can observe that has moved since the pre-rebuild state, for the
developer writing that client. One document, organised by the kind of change rather
than by the run that made it: the error vocabulary, then authentication, then the
routes and fields that left or changed, then realtime, then the surface that did not
move at all.

Every entry names the route or the field, the old behaviour, the new behaviour, and
what the client does about it. Nothing here repeats an endpoint reference — the
per-app [`backend/*/API.md`](backend/) files are the reference, and
[`backend/openapi.json`](backend/openapi.json) is the same contract in a form a
generator reads. This file records only what moved, and
[`backend/CLIENT_CONTRACT.md`](backend/CLIENT_CONTRACT.md) records what the client
must do for the security properties to hold.

Two things caused most of it. The HTTP surface left Django REST Framework for FastAPI
([ADR-0002](docs/architecture/decisions/0002-fastapi-as-the-only-http-api-surface.md))
and the `/ws` gateway left Channels for a WebSocket route of that same application
([ADR-0004](docs/architecture/decisions/0004-websocket-gateway-on-redis-pubsub.md)).
Groups left MLS for pairwise Double Ratchet fan-out
([ADR-0001](docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)),
which removed three routes and a request field.

## The error vocabulary

Every error of every route is now one envelope:

```json
{ "code": "…", "detail": "…" }
```

`detail` is a string on every code but `invalid_request`, where it maps a field path
to the list of messages that failed. **No error body echoes request input**, and a
`500` carries no traceback and no detail beyond a fixed string. Branch on `code`,
never on `detail`. The complete table of codes is in
[`backend/core/API.md`](backend/core/API.md).

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| A validation failure | The bare Django REST Framework field-error object, with no `code` key: `{"ik_pub": ["invalid base64"]}`, and a nested item as `{"otpks": {"0": {"pub": [...]}}}` | `400 {"code": "invalid_request", "detail": {"ik_pub": ["invalid base64"]}}`, and a nested item as a dotted path: `{"otpks.0.pub": ["invalid base64"]}` | Parse the envelope, and read the field path as a dotted string rather than walking a nested object |
| Validation messages | REST Framework's text, for example `"This field is required."` | Pydantic's text, for example `"Field required"`. The length and base64 guards keep their own wording — `"invalid base64"`, `"bad key length"`, `"bad signature length"`, `"duplicate key_id"` | Show `detail` values; never match on their text |
| The status of a validation failure | `400` | `400`, unchanged. FastAPI's own default is `422` with a nested error list; this surface never returns `422`, and the published schema does not describe one | None. A client generated from the schema will not see a `422` branch |
| `bad_request` | `400 {"code": "bad_request", ...}` on a malformed upload body and a malformed ack body | Retired. Both are `400 {"code": "invalid_request", "detail": {...}}` | Replace the `bad_request` branch with `invalid_request` |
| A rate-limited request | `429 {"detail": "Request was throttled."}` | `429 {"code": "throttled", "detail": "Request was throttled."}`, with a `Retry-After` header in seconds | Read `Retry-After` and back off |
| A wrong method | `405 {"detail": "Method \"DELETE\" not allowed."}`, with `Allow` naming every method the route serves | `405 {"code": "method_not_allowed", "detail": "That method is not allowed."}`. `Allow` names the methods of one route object, so on a path two methods share it names one of them and not both | Branch on `code`. Never read `Allow` as the complete method set of a path |
| A path no route serves | Django's own `404` page, in `text/html` | `404 {"code": "not_found", "detail": "No such route or resource."}`, with the security headers every other response carries | Branch on `code`. A typo'd path and a missing resource are no longer told apart by content type |
| An unhandled failure | Django's `500` page | `500 {"code": "server_error", "detail": "Internal error."}` | None |

Four refusals are new, because the limits behind them are new.

| Code | Status | When | Client action |
|---|---|---|---|
| `payload_too_large` | `413` | The body is above the route's cap, counted as the bytes arrive rather than read from `Content-Length` | Each route's reference names its cap. Do not trust an understated `Content-Length` to get a body through |
| `unavailable` | `503` | The request outlived its deadline, or a throttled route's counter store is unreachable | Treat `503` as an outage and `429` as backoff. They are not the same signal |
| `invalid_request` on the `Host` header | `400` | The `Host` header is not one the server lists: `{"host": ["Unknown host."]}` | Send the deployment's own hostname |

`payload_too_large` now shares `413` with `quota_exceeded`, which is unchanged and
means the account's attachment quota is exhausted. Branch on `code`, not on the
status.

Every response now carries `Cache-Control: no-store`. It carried two browser-only
headers beside it until "The web target is gone" below removed them.

## Authentication

There is **no token table and no blacklist**. Revocation is two integers on the device
row, `token_generation` and `refresh_generation`
([ADR-0006](docs/architecture/decisions/0006-device-bound-tokens-on-pyjwt.md)). A
stored token is a per-device login record at rest, which is exactly what the schema
refuses to hold.

### The `401` bodies

| Condition | Old body | New body | Client action |
|---|---|---|---|
| No `Authorization` header, or one that is not `Bearer <token>` | `401 {"detail": "Authentication credentials were not provided."}` | `401 {"code": "unauthenticated", "detail": "Authentication credentials were not provided."}`, with `WWW-Authenticate: Bearer` | Branch on `code` |
| A malformed, expired, or wrong-type token | `401 {"detail": "Given token not valid for any token type", "code": "token_not_valid", "messages": [...]}` | `401 {"code": "invalid_token", "detail": "Token is missing, malformed, or expired."}`. The `messages` array is gone | Replace the `token_not_valid` branch with `invalid_token`; drop any use of `messages` |
| A revoked device, a stale generation, or a deactivated account | `401 {"code": "token_revoked"}` | `401 {"code": "token_revoked", "detail": "Token is no longer valid."}` | None beyond comparing `code` |

### Logout, refresh, and login

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `POST /api/v1/auth/logout` | Required `{"refresh": "..."}`, blacklisted that one token, and answered `205 Reset Content`. The access token stayed valid until it expired | Takes **no body**, and answers `204 No Content`. It advances the device's `token_generation`, so the presented access token **and every refresh token of that device** die immediately, and the device's sockets close | Send no body. Treat `204` as success and discard both tokens. A retry with the same access token answers `401 token_revoked`, which is also success |
| Replaying a refresh token that was already rotated | `401`; the replayed token was blacklisted and the newest pair kept working | `401 {"code": "token_revoked", ...}`, **and the whole family dies**: `token_generation` advances, the newest access and refresh tokens die with it, and the device's sockets close | **Never retry a refresh with the same token**, including after a timeout or a network error. On an unclear outcome, log in again |
| A successful refresh | Returned a new pair; the old refresh was blacklisted | Returns a new pair; the old refresh is behind the generation and is now a replay | Replace the stored refresh token on every call, before any retry |
| A register-scope token presented to `/api/v1/auth/refresh` | `401 {"code": "token_revoked"}` | `401 {"code": "invalid_token", ...}`, refused before any database read | Branch on `invalid_token` as well |
| `POST /api/v1/auth/login` with a `device_id` | Left outstanding refresh tokens alone | Advances that device's `refresh_generation`, so a refresh token the device still held becomes a replay | Discard the previous session's tokens when a login returns a new pair |
| `device_scope_required` | Documented on the mailbox routes and the join-token route, and unreachable on all of them: a full-scope token always names a device | Returned by no route. It stays in the vocabulary and nothing answers it | Delete the branch |

`POST /api/v1/me/devices` is the one route a register-scope token reaches. Every other
authenticated route answers `403 {"code": "scope_forbidden", ...}` to one.

## Removed routes

Each path below is gone. The response is now the JSON envelope, not Django's `404`
page — an unmatched path under `/api/v1` is `404 {"code": "not_found", "detail": "No
such route or resource."}`.

| Route | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `PUT /api/v1/me/devices/{device_id}/keypackages` | Stored up to 100 consumable MLS key packages per device, plus one last-resort package, and returned `{"keypackage_count": n}`; `409 {"code": "keypackage_limit"}` at the cap | `404 not_found` | Delete the upload path. Nothing replaces it: a group start needs no key package |
| `GET /api/v1/me/devices/{device_id}/keypackages/count` | Returned `{"keypackage_count": n}` for the calling device's consumable pool | `404 not_found` | Delete the poll. Poll one-time prekeys instead, on `GET /api/v1/me/devices/{device_id}/prekeys/count` (`otpk_count`, `pq_otpk_count`) |
| `POST /api/v1/users/{user_id}/keypackages/claim` | Returned one MLS key package per live device of the user as `{"keypackages": [{"device_id": …, "blob": …}]}`, consuming it, or the device's last-resort package when its pool was empty | `404 not_found` | Start a group session by claiming PQXDH bundles from `POST /api/v1/users/{user_id}/keys/claim` for each member, exactly as for a direct message (`backend/CLIENT_CONTRACT.md` §F) |

**The server has no counterpart for an MLS profile.** No endpoint accepts, stores or
serves a key package, a Welcome, a commit, or any other MLS artefact, and none will.
`KEYPACKAGE_BUCKETS` is gone from `backend/core/buckets.py`, so no blob type pads to
`[4096, 16384]` any more; delete the constant and the padding code that used it.
`KEYPACKAGE_TTL_DAYS` is gone from the server environment, which is the operator's
concern and not the client's.

## Changed request fields

| Field | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `keypackages` in `POST /api/v1/me/devices` | A required list, empty or up to 100 base64 blobs each padded to a key-package bucket | Refused like any other unknown field, an empty list included | Remove the field from the registration body |
| `refresh` in `POST /api/v1/auth/logout` | Required | The route takes no body at all; one sent is ignored | Send no body |
| A JSON value of the wrong type, anywhere | Coerced where possible: `"1"` and `true` both arrived as the integer `1` | `400 invalid_request`. A string is a string, an integer is an integer, and a boolean is a boolean | Send the declared JSON types |
| An unknown field, anywhere | Rejected, with the bare field-error object: `{"junk": "Unexpected field."}` | Rejected, with the envelope: `{"junk": ["Extra inputs are not permitted"]}` | Send only the declared fields |
| `{"device_ids": null}` in `POST /api/v1/users/{user_id}/keys/claim` | `400`; the field rejected an explicit null | Accepted, and it means what omitting the field means: every live device of that user. An explicit `[]` still claims nothing | Omit a field you do not want to send rather than sending null. `{"ids": null}` on ack is still a `400` |
| A multipart body on `POST /api/v1/attachments` with a second part beside `blob` | Accepted and ignored | `400 invalid_request` | Send exactly one part, named `blob` |

## Changed status codes

| Outcome | Old status | New status | Client action |
|---|---|---|---|
| `POST /api/v1/auth/register` with a name that exists | `400 {"code": "username_taken"}` | `409 {"code": "username_taken"}`. The concurrent race answers `409` too | Move the branch from `400` to `409` |
| `POST /api/v1/auth/logout` | `205 Reset Content` | `204 No Content` | Treat `204` as success |
| A malformed `{user_id}`, `{device_id}` or `{room_id}` in a path | `404`, from the URL resolver | `400 {"code": "invalid_request", "detail": {"user_id": [...]}}` | Treat a malformed id as a client bug, not a missing resource |
| A request that outlives its deadline | Held until the client gave up | `503 {"code": "unavailable", ...}` | Retry with backoff, honouring the retry semantics of the route |
| A throttled route while the counter store is unreachable | An unhandled `500` | `503 {"code": "unavailable", ...}` | Treat as an outage |
| A body above the route's cap | Reached the route, or was refused by nginx with an HTML page | `413 {"code": "payload_too_large", ...}` from the application, on every route | Each route's reference names its cap |
| A body between 64 MiB + 8 KiB and 70 MiB on `POST /api/v1/attachments` | Reached the route and was refused as off-bucket | `413 payload_too_large`, because the upload now carries a cap of its own: the largest attachment bucket plus the multipart wrapper | None, for a client that pads to a bucket |

## Changed response fields

No success body changed **in the rebuild**. Every change in this section is in an error
body; the one success body that has moved since arrived later and is recorded under
[What the security audit bounded](#what-the-security-audit-bounded).

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| The `detail` of a validation failure | A nested object mirroring the body's shape | A flat map of dotted field paths to messages, so a list item carries its index in the path | Read the path as a string |
| `messages` in a token refusal | An array of per-check messages | Gone | Drop any use of it |
| `stale_version`, `not_found`, `token_revoked`, `voice_unconfigured` | The code with no `detail`, or with none on some routes | Every one carries a `detail` string | Compare `code`, never the whole body |
| An unknown room on `PUT /api/v1/rooms/{room_id}` | `404` with an empty body | `404 {"code": "not_found", "detail": "No such room."}` | Parse the refusal as JSON |
| `pruned_through` in `GET /api/v1/me/envelopes` | The same integer, but a lost envelope may have been an MLS commit: the device was permanently desynced from those groups and had to be removed and re-added with a fresh Welcome | The same integer — the highest `seq` the TTL prune has deleted from this mailbox, 0 if never. A lost envelope may now have carried a Double Ratchet message or a group control event | Replace the remove-and-re-add flow with the repair flow (`backend/CLIENT_CONTRACT.md` §H) |

## Realtime

The `/ws` gateway is a WebSocket route of the same FastAPI application, with Redis
publish and subscribe behind it. **The frame protocol did not change.** Every client
frame (`ack`, `signal`, `subscribe_presence`, `room_subscribe`, `room_leave`,
`room_signal`), every server frame (`envelope`, `signal`, `presence`, `room_signal`,
`room_presence`), their exact shapes, the URL, and every limit in
[`backend/realtime/API.md`](backend/realtime/API.md) are as they were.

The rest of this section is superseded by "The web target is gone" below, which
retired the second handshake path, the `auth` frame, the ten-second deadline, the
Origin policy, and close codes 4001 and 4403.

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| An unlisted `Origin` header | Documented as close **4403**. The code never in fact reached the client, because the refusal was decided before the accept | The server answers the upgrade request `403 Forbidden` and no socket is established | Treat a failed handshake as a refusal. The Origin policy itself is gone — see "The web target is gone" below |
| A bad `Authorization: Bearer` token on the handshake | Documented as close **4001** "immediately after accept" | The same `403 Forbidden` failed handshake | Read a failed handshake as "refresh the access token and reconnect". A handler waiting for 4001 will never fire |
| A server restart | The socket dropped with no code | Close **1012**, after every live socket is drained | Reconnect after a backoff. This is a deploy, not a fault, and must not count toward a failure budget that disables reconnection |
| A socket that is not reading | Unbounded in practice; the process's memory grew | At most 256 undelivered server frames, then close **4008** — the same code as a protocol violation | Read continuously. A 4008 with no preceding protocol error means the client fell behind: reconnect and drain the durable queue over REST |

**Delivery, stated plainly.** A live frame is dropped if no socket holds the topic at
the instant it is published, which includes the window while a device is
reconnecting. This was always true and the durable queue was always the contract;
publish and subscribe makes it structural rather than incidental. Nothing about
`envelope` delivery changed: the row stays in the mailbox until it is acked, so a
missed push costs a poll and never a message.

## The unchanged surface, route by route

Every route below keeps its path, its method, its success status, its success body,
its headers and its limits. Only the error bodies moved, in the ways above. The
reference for each is its app's `API.md`; the machine-readable form of all of them is
[`backend/openapi.json`](backend/openapi.json).

| Method | Path | Success | Reference |
|---|---|---|---|
| `GET` | `/api/v1/health` | `200` | [core](backend/core/API.md) |
| `POST` | `/api/v1/auth/register` | `201` | [accounts](backend/accounts/API.md) |
| `POST` | `/api/v1/auth/login` | `200` | [accounts](backend/accounts/API.md) |
| `POST` | `/api/v1/auth/refresh` | `200` | [accounts](backend/accounts/API.md) |
| `POST` | `/api/v1/auth/logout` | `204` | [accounts](backend/accounts/API.md) |
| `GET` | `/api/v1/users` | `200` | [accounts](backend/accounts/API.md) |
| `GET` | `/api/v1/users/{user_id}/profile` | `200` | [accounts](backend/accounts/API.md) |
| `GET` | `/api/v1/me/profile` | `200` | [accounts](backend/accounts/API.md) |
| `PUT` | `/api/v1/me/profile` | `200`, empty body | [accounts](backend/accounts/API.md) |
| `GET` | `/api/v1/me/keybackup` | `200` | [vault](backend/vault/API.md) |
| `PUT` | `/api/v1/me/keybackup` | `200`, empty body | [vault](backend/vault/API.md) |
| `PUT` | `/api/v1/me/identity` | `200`, empty body | [devices](backend/devices/API.md) |
| `GET` | `/api/v1/users/{user_id}/identity` | `200` | [devices](backend/devices/API.md) |
| `POST` | `/api/v1/me/devices` | `201` | [devices](backend/devices/API.md) |
| `GET` | `/api/v1/me/devices` | `200`, or `304` against `If-None-Match` | [devices](backend/devices/API.md) |
| `PUT` | `/api/v1/me/devices/{device_id}` | `200`, empty body | [devices](backend/devices/API.md) |
| `DELETE` | `/api/v1/me/devices/{device_id}` | `204` | [devices](backend/devices/API.md) |
| `PUT` | `/api/v1/me/devices/{device_id}/prekeys` | `200` | [devices](backend/devices/API.md) |
| `GET` | `/api/v1/me/devices/{device_id}/prekeys/count` | `200` | [devices](backend/devices/API.md) |
| `POST` | `/api/v1/me/devicelog` | `201` | [devices](backend/devices/API.md) |
| `GET` | `/api/v1/users/{user_id}/devicelog` | `200` | [devices](backend/devices/API.md) |
| `GET` | `/api/v1/users/{user_id}/devices` | `200`, or `304` against `If-None-Match` | [devices](backend/devices/API.md) |
| `POST` | `/api/v1/users/{user_id}/keys/claim` | `200` | [devices](backend/devices/API.md) |
| `POST` | `/api/v1/envelopes` | `202` | [messaging](backend/messaging/API.md) |
| `GET` | `/api/v1/me/envelopes` | `200` | [messaging](backend/messaging/API.md) |
| `POST` | `/api/v1/me/envelopes/ack` | `200` | [messaging](backend/messaging/API.md) |
| `POST` | `/api/v1/attachments` | `201` | [attachments](backend/attachments/API.md) |
| `GET` | `/api/v1/attachments/{attachment_id}` | `200`, the bytes | [attachments](backend/attachments/API.md) |
| — | `/ws` | the accepted socket | [realtime](backend/realtime/API.md) |

A trailing-slash mismatch is a `404` and was a `404` before. It is named here because
FastAPI's own default is a `307` redirect: that is turned off, because the redirect
rebuilds an absolute address from the request path and drops any prefix a proxy
stripped, which turns a write into a lost request.

Also unchanged, and worth naming because a rewrite is where these usually break: the
`register` and `full` scope split and what each scope reaches; the timing-equalised
login and its `403 account_inactive`; both device-list `ETag`s, their `304` with an
empty body, and what each tag covers; `log_head_seq`, `has_more`, `head_seq`,
`pruned_through`, `etag`, `accepted` and `stale_devices` in the bodies that carry
them; the lenient clamping of `after` and `limit` on the device log and of `limit` on
the drain, which still never error; every list and pool cap — 256 items per send, 200
ack ids, a 100-envelope drain, 200 classical and 100 PQ prekeys per pool and per
payload, 100 claim ids, 50 device-log records, a 200-record log page — with the same
public-key, signature and base64 bounds; the registration refusal of `cross_sig` and
`bundle_version` and the message naming the endpoint that accepts them; the
first-device identity exemption and `400 identity_required` past it; the device cap
and its `409 device_limit`; `409 prekey_limit`, and the rule that a refused
replenishment rotates nothing; verbatim `cross_sig` with its nulls, and the omission
of every PQ member from a classical-only bundle; single consumption of a one-time
prekey under concurrent claims; the revocation cascade and the socket close behind
it; the padding buckets of every other blob type and `400 bad_bucket` with no echo of
the payload; the `409 stale_version` rule on both versioned blobs; and every throttle
scope name, its environment variable and its default.

## The operator can now remove things the client could reach

The admin panel landed in phase 3
([ADR-0011](docs/architecture/decisions/0011-django-unfold-admin-panel.md)). It moved
no route, no field, no status code and no error code: `backend/openapi.json` is
byte-identical across the change, and no request a client makes behaves differently.

What did change is what an operator can do to state a client is holding a reference
to. Two of them are new, and a client that assumed permanence will see a `404` it
could not see before.

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `GET /api/v1/rooms/{id}`, `PUT /api/v1/rooms/{id}`, `POST /api/v1/rooms/{id}/token` | A room, once created, existed forever. Nothing deleted one — no route, no retention sweep | The operator can delete a room from the panel. All three routes then answer `404 not_found` | Treat a room id as revocable, not permanent. On `404 not_found`, drop the room from the local list rather than retrying; the members will have been told out of band |
| `GET /api/v1/attachments/{id}` | The bytes were reachable until `ATTACH_TTL_DAYS` expired them | The operator can also delete an attachment before its TTL, from the panel. The route then answers `404 not_found`, exactly as it does after expiry | None. This is the same `404` a client already had to handle for an expired attachment, arriving sooner. Do not distinguish the two: a missing attachment and a pruned one are one answer, by design |
| Account deactivation, device revocation | Both already existed — deactivation in the stock admin, revocation as `DELETE /api/v1/me/devices/{id}` | Unchanged in effect. The panel now performs both through the same service functions the API uses, so an operator revocation has exactly the consequences a client revocation has: the tokens die, the one-time key material and the mailbox go, and any live socket closes with `4003` | None |

Nothing else about the panel is observable to a client. It is served at `ADMIN_PATH`
by the Django application mounted behind FastAPI, and every other path is still this
API's own `404`.

## What the security audit bounded

Each row below is a limit the security audit of phase 4 added. Every one refuses
something a client could previously do without bound, and every one is documented in
the route's own reference.

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `POST /api/v1/auth/login` after five failed attempts on one name within fifteen minutes | Every attempt answered `401 invalid_credentials`; only the per-address limiter stood between a guesser with many addresses and the password | `429 {"code": "throttled", "detail": "Too many sign-in attempts for this name. Wait and try again."}` with `Retry-After` in seconds, for that name, until the cool-off ends. The lock applies to a name whether or not an account holds it, so it confirms nothing about existence, and a successful sign-in clears the count | Back off for `Retry-After` seconds and tell the user. Do not treat the refusal as a wrong password, and do not retry inside the window |
| `POST /api/v1/envelopes` to a device whose undelivered bytes would pass `MAILBOX_MAX_BYTES` (default 32 MiB) with this batch | Every item to a live device was queued; a mailbox had no ceiling | The device is refused whole — nothing is written for it and its sequence does not move — and named in a new `full_devices` list beside `stale_devices`; the rest of the batch proceeds and `accepted` counts only what was written | Read `full_devices` on every send. Keep a full device in the session set and retry its items once it has drained; a full device is live, not stale |
| `POST /api/v1/me/devicelog` when the account's log would pass `MAX_DEVICELOG_RECORDS` (default 10 000) records | Every well-formed append was stored; the log had no ceiling | `409 {"code": "devicelog_limit", "detail": "The device-list log of this account is full."}`, and nothing of the batch is stored | Append only on a device-set change or an identity rotation, as §J of `backend/CLIENT_CONTRACT.md` already says; a client that reaches the ceiling has a defect |

## Saturation now says so

One observable change came out of the performance, background-work and migration
audits. Everything else they touched — an index, a batched retention sweep, a pipelined
fan-out, the base64 the push stopped reproducing — leaves every request and every
response byte-identical: `backend/openapi.json` does not move.

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| Any route, when the database connection pool has nothing free and the acquisition times out | `500 {"code": "server_error", "detail": "Internal error."}` — which tells a client the request itself was at fault and it should stop | `503 {"code": "unavailable", "detail": "The service is temporarily unavailable."}` — the same envelope the rate limiter already answers when Redis is gone, and a code every route already declared | Retry a `503 unavailable` with backoff. Nothing new to handle: every route already declared the status and the code, and a `500` was never something to retry. `backend/core/API.md` now names this as its third source |

Only a pool timeout reads this way. Django wraps every psycopg `OperationalError` in
one class, and a deadlock or a dropped connection is still `500 server_error`.

## What the reviews of phase 4 corrected

The contract, seam, architecture and panel reviews of phase 4 moved no route, no
status code and no response byte. Two things a client can observe are stated here for
the first time, and one thing this file said about itself was wrong.

### The document now declares the format of what it sends

Every id this API returns is a UUID and every `_date` it returns is a calendar day, but
`backend/openapi.json` declared each of them as a bare `string`. The same values were
already `"format": "uuid"` where a client *sends* them — every `{user_id}`,
`{device_id}` and `{room_id}` path parameter, `LoginIn.device_id`,
`OutgoingItemIn.device_id`, `ClaimIn.device_ids` and `AckIn.ids` — so a generated client
got one type on the way in and another on the way out for one value.

| Field | Old declaration | New declaration |
|---|---|---|
| `user_id` in `RegisterOut`, `RegisterScopeOut`, `FullScopeOut`, `DirectoryUserOut` | `string` | `string`, `"format": "uuid"` |
| `device_id` in `FullScopeOut`, `DeviceRegisteredOut`, `OwnDeviceOut`, `PeerDeviceOut`, `ClaimedBundleOut` | `string` | `string`, `"format": "uuid"` |
| `room_id` in `RoomCreatedOut`, `RoomOut` | `string` | `string`, `"format": "uuid"` |
| `id` in `EnvelopeOut` — the id `POST /api/v1/me/envelopes/ack` takes back | `string` | `string`, `"format": "uuid"` |
| `stale_devices`, `full_devices` in `SendOut` | `array` of `string` | `array` of `string`, `"format": "uuid"` |
| `created_date`, `last_active_date` in `OwnDeviceOut`, `updated_date` in `RoomOut` | `string` | `string`, `"format": "date"` |

**No response byte moved.** A UUID still serialises to the same canonical lowercase
form and a date to the same `YYYY-MM-DD`; only the published description changed.
`attachment_id` is deliberately absent from the table: an attachment id is a 43-character
capability, not a UUID, and it stays an unformatted string in the path and in the body
alike.

**Client action.** None, unless the client is generated from the schema and its
generator maps `format` to a type — a regenerated client may now type these fields as
`UUID` and `Date` rather than `String`. The values it receives are unchanged.

### `HEAD` and `OPTIONS` are refused

Before the rebuild, Django REST Framework answered `HEAD` on every route that served
`GET`, and answered `OPTIONS` with a metadata document this API never meant to publish.
FastAPI registers only the methods a route declares, so both now answer
`405 {"code": "method_not_allowed", "detail": "That method is not allowed."}` with
`Allow` naming the methods of the one route object.

**Client action.** None for a client that issues neither. A reachability probe uses
`GET /api/v1/health`, which is what it was always for.

The refusal itself is `_ROUTING_REFUSALS` in
[`backend/api/errors.py`](backend/api/errors.py), which is what puts the envelope on a
`405` where Starlette's own handler answers a bare body.

### One standing claim in this file was stale

The **Changed response fields** section opens "No success body changed." That was true
of the rebuild it describes and is no longer true of this file as a whole: the mailbox
ceiling the security audit added put a `full_devices` list into the `202` body of
`POST /api/v1/envelopes`, recorded under **What the security audit bounded**. The
sentence now says which change it is scoped to.

### The no-echo claim in `core/API.md` was wider than the behaviour

`backend/core/API.md` said "No error body ever echoes request input." Run 13's
malformed-input sweep found one fragment that does cross: a type message for a
malformed identifier names the offending character and its offset — "Input should be a
valid UUID, invalid character: found `z` at 35" — which `backend/messaging/API.md` had
been publishing as an example all along, so the two documents disagreed. The behaviour did not change and needs nothing from a client.
`core/API.md` now states the property that actually holds: no error body echoes a
value — no blob, no password, no token, no username, no identifier — and the one
fragment that crosses is a character of a malformed identifier, never of a payload.

## What the test suite found at the column boundaries

Runs 12 and 13 drove every route with malformed input. Run 12 covered `core`, `api`,
`accounts`, `devices`, `vault` and the migrations; run 13 covered `messaging`,
`attachments`, `voicerooms`, `realtime` and, through the contract suite, every route
of the document at once. Five routes answered `500` to input the schema existed to
filter, and all five are fixed. A `500` on input is a defect on this surface, never a
documented answer, so a client that branched on one was branching on a bug.

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `PUT /api/v1/me/profile` and `PUT /api/v1/me/keybackup` with `version` above 2147483647 | `500 {"code": "server_error"}`. `version` lands in a 32-bit column and the schema bounded it below but not above, so the integer reached PostgreSQL as a `DataError` | `400 {"code": "invalid_request", "detail": {"version": [...]}}`. `accounts.schemas.BlobIn` now carries the ceiling, which both routes inherit. `version` = 2147483647 is still accepted and still stores | None, unless the client generated versions without a bound. The ceiling is the column's, not a policy: a client that increments a version per write will not reach it |
| `PUT /api/v1/me/devices/{device_id}/prekeys` with `cross_sig` and `bundle_version` both sent as `null` | `500 {"code": "server_error"}`. Both keys present satisfies the pairing guard, and `null` reached `Device.bundle_version`, which is not nullable | `400 {"code": "invalid_request", "detail": {"bundle_version": ["bundle_version must be a number when it is sent"]}}`. A sent `null` is half a pair in substance: a `cross_sig` stored against no version is one peers must reject | None. Clearing a signature against a version that is a number — `{"cross_sig": null, "bundle_version": 3}` — is unchanged and still `200` |
| `GET /api/v1/attachments/{attachment_id}` with a NUL byte in the id | `500 {"code": "server_error"}`. The same cause as the login defect below: PostgreSQL text carries no NUL, so psycopg refused the lookup rather than returning no row | `404 {"code": "not_found", "detail": "No such attachment."}`, the same answer a capability nobody holds gets. A capability id is base64url of 32 random bytes, so an id carrying the byte is an id nobody has | None. It was carried as AR-10 through run 12, because `attachments/` was outside that run's scope |
| `POST /api/v1/auth/login` with a NUL byte in `username` | `500 {"code": "server_error"}` on **anonymous** input. PostgreSQL text carries no NUL, so psycopg refused the lookup rather than returning no row | `401 {"code": "invalid_credentials"}`, the same answer every other unregistrable name gets | None. Deliberately not a `400`: `LoginIn` treats a badly shaped name as wrong credentials rather than a malformed request, and answering otherwise would tell an anonymous caller which names the column could have held |

`POST /api/v1/auth/register` was already correct — a control character in a username
has always been `400 invalid_request` there — so the two surfaces now agree: a name
that could never be registered is wrong credentials at login, and a malformed name is
a refusal at registration.

## What the edge answers, and when it stops waiting

Three of these change what a client reads on a slow request or during a restart.
None of them changes a path, a body, a field or a status a route declares, so
`openapi.json` is unmoved — the document describes the application, and these are the
two layers around it.

### A request past 60 seconds now gets this API's answer, not nginx's

`ops/nginx/chat.orviniq.com.conf` set no `proxy_read_timeout` on `/api/`, so
nginx used its own default of 60 seconds. The application's deadline on the
attachment upload and the batch routes is `UPLOAD_DEADLINE_SECONDS`, 120 seconds. A
request between the two therefore reached nginx's limit first and the client read
nginx's HTML `504 Gateway Time-out` — not `{"code": "unavailable", …}`, not any
envelope at all, and with none of the security headers the application sets.

nginx now waits 150 seconds on that location, above the deadline below it.

**Client action:** none, but a 64 MiB upload over a slow link can now legitimately
run to two minutes, and the answer to a request that outlives its deadline is the
`503 unavailable` envelope your error handling already covers. Treat an HTML body
from this host as a bug report, not a status to parse.

### A restart no longer turns an in-flight request into a `500`

`ops/systemd/chat.service` set `--timeout-graceful-shutdown 10`. On `SIGTERM`
uvicorn stops accepting, closes every live WebSocket with `1012`, and waits that long
for the requests still in flight — so a request still arriving after ten seconds was
cut, and the client read `HTTP/1.1 500 Internal Server Error`. Measured on this
application, with a body that completed six seconds after the signal: at a
ten-second window the send failed and the answer was that `500`; at a window above
the request the same probe completed and read its real status.

The window is 130 seconds now, above the longest deadline any route carries, with
`TimeoutStopSec=150` above that so systemd does not `SIGKILL` in the middle of the
drain it was asked to take.

**Client action:** none. A restart that catches an upload now completes it. Sockets
are unaffected and still close with `1012` at once — that has never been part of the
drain, and the reconnect it triggers is unchanged.

### One `Strict-Transport-Security` header, and `nosniff` on the static path

An admin-path response carried the header twice: nginx added it for the whole host
and Django's `SecurityMiddleware` set it on the responses Django serves. `add_header`
appends rather than replaces, so both arrived. nginx is now the single owner —
`snippets/proxy-headers.conf` hides the upstream copy — and `/static/`, which reaches
no application at all, gained `X-Content-Type-Options: nosniff` beside it.

The API surface is unchanged: `/api/` responses carried one HSTS header before and
carry one now. The application still sets `cache-control: no-store` on every response
it produces; the two browser-only headers it set beside it left in "The web target is
gone" below.

**Client action:** none. A client that counted on two identical HSTS headers was
already reading only the first, which is what RFC 6797 requires of it.

## The web target is gone

The product is one Flutter application for Android, and every surface the server
kept for a browser is removed
([ADR-0020](docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md)).
Nothing below affects a client that already authenticates the `/ws` upgrade with an
`Authorization: Bearer` header and reads its responses as bytes rather than as a page.

### The `/ws` handshake

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| The bare-connect path | A handshake with no `Authorization` header was **accepted**, and the socket then had ten seconds to authenticate in band | Refused before the accept, exactly as a bad token is: `403 Forbidden`, and no socket exists | Put the access token on the upgrade request. There is one handshake path |
| The `auth` frame | `{"type": "auth", "access": "…"}` as the first frame of a bare connection bound the socket; failure closed **4001** | Not a frame type. On a live socket it is an unknown type and is ignored, like any other | Delete the frame and the code that waits for the silence after it |
| The ten-second authentication deadline | An accepted socket that had not authenticated within `AUTH_DEADLINE_SECONDS` closed **4001** | Gone with the state it bounded: every accepted socket is already bound to a device | None |
| Close code **4001** | Authentication failed after the accept | Retired. Authentication is decided before the accept, so there is no accepted socket to close | A handler waiting for 4001 will never fire. Read a failed handshake as "refresh the access token and reconnect" |
| Close code **4403**, and the `Origin` allowlist | A handshake presenting an `Origin` not on `ALLOWED_WS_ORIGINS` was refused, documented as 4403 | Retired. There is no Origin policy: `Origin` is a browser cross-site defence, and a handshake with no header — which is every handshake this client makes — was always allowed | None. The header was never sent and the refusal never fired |

### Response headers

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `X-Content-Type-Options: nosniff` | On every API response | Not set. It instructs a rendering engine, and there is none | None, unless the client asserted on it |
| `Referrer-Policy: no-referrer` | On every API response | Not set. It governs a `Referer` header a browser sends, and this client sends none | None, unless the client asserted on it |
| `Cache-Control: no-store` | On every API response | Unchanged | None |
| `Content-Disposition: attachment` on `GET /api/v1/attachments/{id}` | Set, to force a download rather than a render | Not set. `Cache-Control: private, no-store` and `X-Accel-Redirect` are unchanged | None. Name the file from your own metadata, as before — the header carried no filename |

The admin panel is unaffected: it is served to an operator's browser and keeps every
header Django's `SecurityMiddleware` sets, and the nginx `/static/` location keeps
`nosniff`.

### The documentation routes

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `/openapi.json`, `/docs`, `/docs/oauth2-redirect`, `/redoc` | Registered under `DEBUG`, absent otherwise | Absent in every mode, `DEBUG` included. Each is this API's `404 not_found` envelope | Generate from [`backend/openapi.json`](backend/openapi.json). `python manage.py openapi` still writes it from the same generator and CI still fails a change that does not regenerate it |

### The removed setting

| Item | Old behaviour | New behaviour | Operator action |
|---|---|---|---|
| `ALLOWED_WS_ORIGINS` | An environment variable, required in production; an empty value failed `manage.py check --deploy` with `core.E003` | Gone, with the check. Remove the line from the environment file | Remove it. An unread variable in `.env` is a setting an operator believes they configured |

## Voice leaves the server

The server carried a LiveKit SFU, a persistent room record and four room frames, and
none of it was ever built on the client. The design that replaces it is a full mesh of
WebRTC audio between devices, keyed by DTLS-SRTP between the two endpoints of each
connection and relayed by the self-hosted coturn
([ADR-0021](docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)),
and it lands in phase 7. **Nothing below affects messaging, attachments, devices or
enrollment.** A client that never called a room route and never sent a room frame is
unaffected in full.

### The room routes

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `POST /api/v1/rooms` | Created a room from a bucketed `name_blob` and returned `room_id`, the capability anyone with an encrypted invite could use | `404 not_found`, like any other path no route serves | Delete the call. A room is client state from here: carry it as client-signed control events over ordinary envelopes, exactly as a group is carried |
| `GET /api/v1/rooms/{room_id}` | Returned `room_id`, `name_blob`, `updated_date` and `live_count` — the last read live from Redis | `404 not_found` | Delete the call. `live_count` has no replacement: the server holds no live membership, and a room's participants are known to its members and to nobody else |
| `PUT /api/v1/rooms/{room_id}` | Replaced the encrypted room name and bumped `updated_date` so peers noticed a rename | `404 not_found` | Delete the call. A rename is a control event to the members, over envelopes |
| `POST /api/v1/rooms/{room_id}/token` | Minted a short-lived LiveKit join token for the calling device: `{url, token, expires_in}`, audio-only, scoped to one room. Answered `503 voice_unconfigured` when `LIVEKIT_URL` was empty | `404 not_found` | Delete the call, and the LiveKit client SDK with it. Phase 7 replaces it with a route that mints a coturn relay credential — a TURN username and password, not a join token, and it authorizes a relay allocation rather than admission to a conference |

`503 voice_unconfigured` leaves the error vocabulary with the route that raised it. It
was the only route-specific `503`; `503 unavailable` is unchanged and still answers a
missed deadline, an unreachable rate-limit store and an exhausted connection pool.

### The `/ws` room frames

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `room_subscribe` | Joined a room's live session: subscribed the socket to `ws:room:<id>`, announced a `room_presence` join to every subscriber, and added the device to the room's live-count set. Capped at 100 rooms for one socket | Not a frame type. On a live socket it is an unknown type and is ignored, like any other | Delete the frame. There is no live session to join, and no server-side room to subscribe to |
| `room_leave` | Left the live session: announced a `room_presence` leave and dropped the live count. Disconnecting did the same for every held room | Not a frame type; ignored | Delete the frame |
| `room_signal` (client → server) | Relayed an opaque blob to every subscriber of a room the socket held — knowing the id was not enough | Not a frame type; ignored | Send ephemeral room text as `signal` frames, one to each member device. The client owns the fan-out, because the server no longer knows who is in a room |
| `room_signal` (server → client) | Arrived carrying `room_id` and `blob` | Never sent | Delete the handler |
| `room_presence` | Arrived carrying `room_id`, `device_id` and `state` — `join` or `leave` — on explicit leave and on disconnect | Never sent | Delete the handler. Announce a join or a leave as a `signal` frame to each member device |
| The room-subscription cap | 100 rooms for one socket; a subscribe past it was silently dropped | Gone with the frames | None |

`ack`, `signal`, `subscribe_presence`, `envelope` and `presence` are unchanged, and so
are every close code and every other frame limit.

### The removed settings

| Item | Old behaviour | New behaviour | Operator action |
|---|---|---|---|
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_TOKEN_TTL_SECONDS` | Configured the SFU and its join tokens. An empty `LIVEKIT_URL` turned voice off, and `check --deploy` refused an API secret under 32 characters through `core.E005` | Gone, with the SFU. `core.E005` now weighs `JWT_SIGNING_KEY` alone | Remove the four lines from the environment file, and remove `livekit.service` and `/etc/chat/livekit.yaml` from the host. An unread variable in `.env` is a setting an operator believes they configured |
| `THROTTLE_ROOMTOKEN` | The rate scope of the join-token route, `60/min` | Gone with the route it counted | Remove the line |
| `TURN_REALM`, `TURN_STATIC_AUTH_SECRET` | Read by coturn only | Unchanged, and still read by coturn only. The backend route that mints a credential from the secret lands in phase 7 | None. Keep both filled; `backend/ops/RUNBOOK.md` §7 is the coturn posture that goes with them |

## Voice comes back, as a relay credential

Phase 6 removed the SFU, the room object and the four room frames and left the design
to be built. Phase 7 builds the server half of it, and it is one route, four operator
settings and one breaking change on the socket. The reference for the route and for
every frame is [`backend/realtime/API.md`](backend/realtime/API.md); what the client
must implement for a call to be end to end is
[`backend/CLIENT_CONTRACT.md`](backend/CLIENT_CONTRACT.md) §N, which is binding and is
not repeated here. The decisions are
[ADR-0021](docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
and [ADR-0022](docs/architecture/decisions/0022-the-gateway-holds-no-presence.md).

### The relay route

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `POST /api/v1/me/relay` | No such path: `404 not_found`, like any other path no route serves. Voice's only route had been `POST /api/v1/rooms/{room_id}/token`, removed above | `200` with a coturn credential. A full-scope, device-bound token, no request body, no path and no query parameters. It reads no row and writes none — the credential is computed from a secret the backend shares with coturn, so there is nothing stored and nothing to revoke | Call it before joining a call. It is the whole of the ICE configuration a client gets, and the whole of what a call costs the server |
| The `200` body | — | Four fields: `urls`, the configured `turn:` URLs in the order the operator wrote them; `username`, the Unix timestamp the credential expires at, a colon, and sixteen random bytes as URL-safe base64; `credential`, standard base64 of HMAC-SHA1 over that username; and `expires_in`, the seconds the pair is good for (`RELAY_CREDENTIAL_TTL_SECONDS`, default 21600) | Configure one ICE server per entry of `urls` with that username and credential, under a relay-only ICE policy and with no STUN server beside it. The username carries no account identifier and no device identifier, so do not read one out of it |
| `503 voice_unconfigured` | Left the vocabulary with the join-token route, where it had meant an empty `LIVEKIT_URL` — recorded under "The room routes" above | Back in the vocabulary at `503`, on this route, meaning `TURN_URLS` is empty and the deployment serves no voice at all | Read it as "this server does not do voice" and offer no call. It is not a backoff: retrying will not make a relay appear |
| A retried or timed-out call | — | Safe to repeat, because the route stores nothing for a retry to conflict with: every call mints a fresh username, and a credential already issued stays good until its own expiry | Retry freely. Holding two live credentials is the normal outcome of a timeout, and either one works |
| The rate scope | `THROTTLE_ROOMTOKEN`, `60/min`, gone with the join-token route | Scope `relay`, `THROTTLE_RELAY`, default `60/min`, counted per account. A caller past it gets `429 throttled` with `Retry-After` | None in practice: one credential lasts six hours, so a client that refreshes on the hour-remaining rule of §N never approaches the limit |

### The `/ws` frames

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `subscribe_presence` (client → server) | Replaced the socket's presence-target set — up to 500 device UUIDs — and announced `online` to every target at once. The same targets were told `offline` when the socket closed | Not a frame type. On a live socket it is an unknown type and is ignored, like any other | Delete the frame. Presence is client protocol now: fan a query announcement out as `signal` frames and let the participants answer (`backend/CLIENT_CONTRACT.md` §N) |
| `presence` (server → client) | Arrived carrying `device_id` and `state` — `online` or `offline` — for a device the socket had subscribed to | Never sent | Delete the handler. A peer that has gone is one your own timeout tells you about; the server no longer knows |
| The presence-target cap | 500 device ids for one socket; a longer list dropped the frame | Gone with the frames it bounded | None |
| The `signal` blob | Any string of at most `SIGNAL_MAX` characters (default 16384). The server never looked inside it | **Standard base64 that decodes to exactly 1024, 4096 or 16384 bytes** — one of `SIGNAL_BUCKETS`, the padding rule every stored ciphertext already obeys. A blob outside the rule drops the frame in silence: no close code, and no error frame to read | **Breaking, and silently so.** A client that sent an arbitrary string has every `signal` frame dropped with nothing to observe but the answer that never comes. Pad the plaintext to a bucket before encrypting, encode with the standard alphabet, and treat a blob that is not one of the three lengths as a client-side bug |

`ack`, `envelope` and the relayed `signal` frame keep their shapes exactly — the
relayed frame is still the type and the blob and no sender field — and so do every
close code, the frame-size cap, the rate cap and the send-queue bound. The two size
bounds stay independent: the longest legal blob is 21848 characters, well inside
`WS_MAX_FRAME`. This section supersedes the line under "The `/ws` room frames" above
that called `subscribe_presence` and `presence` unchanged.

The bucket rule is a malformed-input guard and **never a security control**: a modified
server would relay anything a client sent it. What it buys is length uniformity on the
one ciphertext the server relays without storing, and nothing above that.

### The settings

| Item | Old behaviour | New behaviour | Operator action |
|---|---|---|---|
| `SIGNAL_MAX` | An environment variable capping a `signal` blob at 16384 characters | Gone, as a setting and as a variable. The cap now derives from the bucket set: a blob is at most the base64 of the largest bucket, 21848 characters | Remove the line from the environment file. An unread variable in `.env` is a setting an operator believes they configured |
| `TURN_URLS` | Did not exist | The comma-separated `turn:` URLs the relay route hands a client. Empty by default, and empty serves no voice — the route answers `503 voice_unconfigured` | Fill it in to serve voice, and leave it empty not to. Voice is configured on rather than off |
| `TURN_STATIC_AUTH_SECRET` | Read by coturn alone, as the row under "The removed settings" above records | Read by both: it is the HMAC key a relay credential is signed under, and one value in two places — here and `static-auth-secret` in `ops/coturn/turnserver.conf`. `check --deploy` refuses a value under 32 characters once `TURN_URLS` is set, under `core.E005` | Keep the two copies identical; a mismatch is a relay that refuses every credential the backend mints. This row supersedes the phase-6 one |
| `RELAY_CREDENTIAL_TTL_SECONDS` | Did not exist | How long a minted credential stays good, in seconds. Default 21600, six hours | None, unless six hours is wrong for the deployment |
| `THROTTLE_RELAY` | Did not exist | The rate scope of the relay route, default `60/min` per account | None |

`TURN_REALM` is unchanged and still read by the coturn file alone; no Python module
reads it.

## The token pair becomes one session token

The access and refresh pair is gone, and one device-bound session token replaces it.
The decision and its cost are
[ADR-0023](docs/architecture/decisions/0023-one-device-bound-session-token.md), which
supersedes [ADR-0006](docs/architecture/decisions/0006-device-bound-tokens-on-pyjwt.md);
the reference for the routes is [`backend/accounts/API.md`](backend/accounts/API.md)
and [`backend/devices/API.md`](backend/devices/API.md).

Why, in one line: rotation with reuse detection made a lost race between two client
isolates a sign-out, and it defended only a theft the transport pinning and the
encrypted client store already prevent. What it costs is stated rather than argued
around, in `ACCEPTED_RISKS.md` AR-18.

### The routes

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `POST /api/v1/auth/refresh` | Anonymous. Took `{"refresh": "…"}`, rotated the pair, advanced `Device.refresh_generation`, and answered `200` with `{"access", "refresh"}` | No such path: `404 not_found`, like any other path no route serves | Delete the call and the route from your client. `POST /api/v1/auth/renew` replaces it, and the request shape is different: a bearer header instead of a body |
| `POST /api/v1/auth/renew` | Did not exist | `200` with `{"token", "expires_in"}`. Takes a full-scope bearer token and **no body**; a body, if sent, is ignored. It re-checks the device and the account through the same verifier every authenticated route uses, so a revoked device, a stale token generation and a deactivated account each answer `401 token_revoked` | Call it with the token you hold, well before `expires_in` runs out. Keep whichever token you got; the one you presented also stays valid until its own expiry |
| A retried or timed-out renewal | A refresh was **never** safe to repeat: the second call presented a token the first had retired, which was a replay, which ended every token of the device | Safe to repeat. Nothing is written and no generation moves, so a retry issues another token and retires none | Delete the "never retry a refresh" rule and any arbitration built for it. Two of your isolates may renew concurrently and both keep working tokens |
| `POST /api/v1/auth/login` with a `device_id` | `200` with `{"access", "refresh", "user_id", "device_id", "scope": "full"}`, and the login advanced `Device.refresh_generation`, retiring any refresh token the device still held | `200` with `{"token", "expires_in", "user_id", "device_id", "scope": "full"}`. The device row is read and never written, so a token the device already held keeps working | Rename the field in your DTO and read `expires_in`. Stop discarding the token you were holding when a login returns |
| `POST /api/v1/auth/login` without one | `200` with `{"access", "user_id", "scope": "register"}` | `200` with `{"token", "expires_in", "user_id", "scope": "register"}` | Rename the field. `scope` is still the discriminator between the two success shapes |
| `POST /api/v1/me/devices` | `201` with `{"device_id", "access", "refresh", "scope": "full"}` | `201` with `{"device_id", "token", "expires_in", "scope": "full"}` | Rename the field. The token is the new device's session token, and it is what you cross-sign with |
| `POST /api/v1/auth/logout` | Advanced `token_generation`; the presented access token and every refresh token of the device died | Unchanged in behaviour and in wording: `token_generation` advances and every token of the device dies at once | None |

### The claims and the replay rule

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| The `scope` claim | Every token carried `scope`, `full` or `register`, and the power of a token was the pair (`scope`, `typ`) | Gone from the claims. `typ` alone carries the power: `session` for the device-bound token, `register` for the enrollment one | None, if you never read the claims. If you did, read `typ` — but the claim set is this server's and no client should depend on it: `expires_in` is published for exactly this reason |
| The `rgen` claim | Carried by every refresh token and checked against `Device.refresh_generation` | Gone, with the refresh token | None |
| The replay rule | A refresh presenting an `rgen` behind the row advanced `token_generation` and ended every token of the device, including ones the replayer had never seen | Gone. Nothing but a logout, a device revocation or an account deactivation ends a token before its own `exp` | Remove the arbitration this rule forced. A client may now hold several live tokens for one device — from a login, a registration and each renewal — and all of them work |
| `403 scope_forbidden` | A register-scope token on a full-scope route | Unchanged: a register token on a route that needs a session token. `POST /api/v1/auth/renew` is one of them, so a register token cannot renew its way to a session | None |
| A token that expires on an open socket | The socket stayed open; a revocation closed it with `4003` | Unchanged | None |

### The settings

| Item | Old behaviour | New behaviour | Operator action |
|---|---|---|---|
| `ACCESS_MIN` | Access-token lifetime in minutes, default 15 | Gone, as a setting and as a variable | Remove the line from the environment file |
| `REFRESH_DAYS` | Refresh-token lifetime in days, default 14 | Gone, as a setting and as a variable | Remove the line |
| `SESSION_TOKEN_DAYS` | Did not exist | The session token's lifetime in days, default 30. It is the whole exposure of a stolen token, so shortening it is the lever AR-18 names | None, unless 30 days is wrong for the deployment; shortening it costs only more frequent renewals |
| `THROTTLE_REFRESH` | The rate scope of the refresh route, default `120/hour` | Gone with the route it bounded. Renewal counts against `accounts`, `THROTTLE_ACCOUNTS`, default `120/min` per account | Remove the line |
| `REGISTER_SCOPE_ACCESS_MIN` | Register-scope token lifetime in minutes, default 10 | Unchanged in name, value and meaning | None |

`Device.refresh_generation` keeps its column with no reader and no writer until the
next run drops it; nothing a client can observe depends on it.

## The client stops paying for the contract

Four costs the client was carrying, and one column it can no longer read
([ADR-0024](docs/architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md)).

### `POST /api/v1/peers` — one call for a whole fan-out

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| Verifying the recipients of a send | Three reads for each recipient: `GET /api/v1/users/{user_id}/identity`, `GET /api/v1/users/{user_id}/devices` and the device log. A 50-member group was 150 round trips before one message | `POST /api/v1/peers` with 1 to 64 `{user_id, etag?}` items answers each peer's `identity`, `devices` and `log_head_seq` in one call, in request order | Optional. Replace the per-recipient loop with one call. The per-user routes are unchanged and stay, so nothing is forced |
| The bytes of each answer | — | The same bytes the per-user routes serve: `identity` is the whole body of the identity read or `null`, and `devices` holds the items of the device list | None. Whatever already verifies the per-user answers verifies these unchanged |
| Repeating the call | — | Send the `etag` the previous answer carried for that peer. A peer whose state has not moved answers `{user_id, etag, unchanged: true}` and no body | Optional. Branch on the presence of `unchanged`, never on its value — it is never `false` |
| What the tag covers | — | The identity, the live device set, every device's `bundle_version`, and the log head. It is **this route's own tag** and is not the `ETag` of either per-user route | Keep it separate from the other two. Sending one where another belongs costs a full answer, never a wrong `304` |
| A user that does not exist, is not activated, or was deactivated | Each per-user route answered separately: `404` from the identity read, an empty list from the device list | **Omitted** from `peers` entirely. The three cases are not told apart | Match the answer to the request by `user_id`; do not assume the list is the same length as the request |
| The rate cost | 150 requests against `accounts` for a 50-member fan-out | One | Optional. The 30-second peer cache built to survive the old cost is no longer needed |

### `GET /api/v1/users/{user_id}/identity` — a conditional read

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| The response | `{master_pub, self_signing_pub, user_signing_pub, master_sig, version}`, always a full `200` | The same five fields plus `etag`, and an `ETag` header carrying the same value | Optional. The added field is additive; a client that ignores it is unaffected |
| `If-None-Match` | Not read | A matching value answers `304` with an empty body | Optional. Send the tag you last received and skip the body while the identity is unchanged |
| What the tag covers | — | The four public byte fields and the version, and nothing else | Note that the identity's tag and the peer-state tag are different values for different routes; the peer-state answer carries both |
| An identity that was never published | `404 not_found` | Unchanged, whatever `If-None-Match` carries — there is no tag for a row that does not exist | None |

### `GET /api/v1/config` — the limits, published

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| The retention window | Not published anywhere. `ENVELOPE_TTL_DAYS` is an operator setting, so a client telling a user how long an undelivered message survives was guessing | `envelope_ttl_days` in the response | Recommended. Read it once at startup and use it in the queue-gap disclosure (`backend/CLIENT_CONTRACT.md` §H) |
| Every other limit | Learned from a `413`, a `409` or a `400 bad_bucket` | `attachment_ttl_days`, `mailbox_max_bytes`, `max_devices_per_user`, `max_devicelog_records`, `session_token_days`, `send_batch_max`, `ack_max`, `drain_page_max`, `claim_max`, `envelope_buckets`, `attachment_buckets`, `signal_buckets` | Recommended. Prefer these over hard-coded numbers: an operator may change any of them |
| Whether the deployment serves voice | Discovered by calling `POST /api/v1/me/relay` and reading `503 voice_unconfigured` | `voice_configured`, a boolean | Recommended. Hide the call control rather than offering one that fails |

Every value is read from the setting or the constant the enforcing route reads, so
none of them can describe a server that behaves differently. Authenticated: the
route takes a full-scope token.

### `last_active_date` is gone — this is the breaking one

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `GET /api/v1/me/devices` | Each item carried `device_id`, `label_blob`, `created_date`, `last_active_date` and `this_device` | `last_active_date` is gone from the item. The other four are unchanged | **Required.** Remove the field from the DTO and from the linked-devices screen. A DTO that requires it will fail to parse |
| What the server records about activity | The socket bind wrote `Device.last_active_date` on the day it changed, and six other columns carried a day-coarse write timestamp | Nothing. No route serves any of the seven, and the socket bind writes no row at all | None. There is no replacement, by decision: `backend/SECURITY.md` states the new seizure yield |

### The rate limit and the socket keepalive

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| `THROTTLE_ACCOUNTS` | `120/min` per account | `300/min` per account. Every route on the `accounts` scope shares it, including the two new ones | None. More headroom, not less |
| The server's WebSocket ping | uvicorn's default: a ping every 20 s, given up on after 20 s | A ping every 240 s, given up on after 60 s | None. The client's own four-minute keepalive is unaffected and stays its decision. A socket the server has stopped hearing from is closed within 300 s rather than 40 s |

## The attachment store stops naming accounts

[ADR-0025](docs/architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md)
removed the column that said which account uploaded a stored attachment. The
per-account lifetime quota went with it, because that column was what the quota summed.

### `POST /api/v1/attachments` — a daily allowance replaces the lifetime quota

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| What bounds an upload | A lifetime sum of the account's stored bytes against `ATTACH_USER_QUOTA_BYTES`, default 2 GiB. Deleting an attachment, or letting the TTL expire it, gave the space back | What the account has uploaded so far today, against `ATTACH_DAILY_BYTES`, default 256 MiB. It resets at 00:00 UTC and carries nothing forward; deleting an attachment gives nothing back, because nothing is being counted at rest | **Required if the client showed a quota.** "X of 2 GiB used" has no server-side value behind it any more. What the client can show is the day's allowance from `GET /api/v1/config` |
| The refusal | `413 {"code": "quota_exceeded", "detail": "Storage quota exhausted."}` | The same status and the same code, with `detail` `"The day's upload allowance is spent."` | None if the client branches on `code`, which the contract has always required. A client that matched the `detail` string breaks |
| What a refusal costs | The bytes were written and then unlinked | Nothing is written and nothing is charged. A retry before the day turns answers the same way | Optional. Hold the attachment and retry after 00:00 UTC rather than retrying immediately |
| An upload that fails after it is admitted | — | The allowance is given back, so a failed upload never costs the account its day | None |
| Storage below its free-space floor | Not distinguished: an upload the disk could not take was `500 server_error` | `503 {"code": "storage_full", "detail": "Attachment storage is full."}`, a new code in `backend/core/API.md` | Recommended. Treat it as retry later with backoff, like `unavailable`. It is not the account's fault and no allowance was spent |

### `GET /api/v1/config` — the allowance is published

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| The upload bound | Not published. `ATTACH_USER_QUOTA_BYTES` was an operator setting a client could only learn from a `413` | `attachment_daily_bytes`, the same value the upload route enforces | Recommended. Read it at startup and disclose it before a large send, rather than after a refusal |

### What the server no longer records

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| Which account uploaded a stored attachment | `Attachment.uploader`, a foreign key to the account | Written by nothing and read by nothing. No route ever served it, so no response shape changes | None. It is stated because `backend/SECURITY.md` states the new seizure yield: an attachment row now names a size and a day and nobody |
| The panel's view of an attachment | The operator saw the uploader, could filter by it, and saw each account's stored bytes on its page | The operator sees the size and the day. `docs/admin/PANEL-RECORD.md` §10 records the reversal | None — no client surface |

## An attachment download resumes

The edge, not the application: `proxy_request_buffering` and `client_body_timeout`
are now stated on the `/api/` location, and the internal location the download
redirects to has always been able to serve a byte range. Both are measured in
[`docs/architecture/GROUND-TRUTH.md`](docs/architecture/GROUND-TRUTH.md) §4.

### `GET /api/v1/attachments/{attachment_id}` — `Range` and `206`

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| A `Range` request | Undocumented. nginx has always honoured it, and no document said so, so no client could rely on it | Documented: `Range: bytes=<first>-<last>` answers `206 Partial Content` with `Content-Range` and exactly those bytes. The full response carries `Accept-Ranges: bytes`, an `ETag` and a `Last-Modified` | Optional. The shipped download path requires `200` and one full bucket in one response, so it declines a `206` today |
| Resuming after a dropped transfer | The whole bucket again, up to 64 MiB | The bytes after the offset already written, under `If-Range` with the `ETag` of the first response | Optional. An attachment is immutable and its id is never reused, so the tag can only fail after the retention sweep deleted the object — and the answer is then the whole body, never bytes from another file |
| What the application does | Answers `200` with an empty body and `X-Accel-Redirect` | Unchanged. The range is nginx's work, from the internal location, so no route, status or schema of this API moved | None |
| Talking to the application directly | The body is empty and the redirect header is visible | Unchanged, and `Range` does nothing: the process that would honour it is not there | None. A development client cannot test the resume path |

### The upload body, at the edge

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| Where a slow upload is paid for | nginx buffered the request body by default and nothing said so, so the application's 120 s deadline read as a bound on the client's link | `proxy_request_buffering on` is stated: nginx absorbs the body first and the application's deadline covers the loopback hop alone. Measured — with buffering off the upstream spent 3.5 s of its own deadline reading a 200 KiB body trickled over 5 s | None. The behaviour is unchanged; what changed is that it is now pinned by a test rather than inherited |
| A client that stalls mid-body | nginx's default 60 s between two reads of the body | 30 s, at the edge. A live link trickles and never approaches it | None |

## An account can erase itself

[ADR-0025](docs/architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md)
adds the one irreversible route this API has. It is additive: no existing route,
field or status changed.

### `DELETE /api/v1/me` — a new route

| Item | Old behaviour | New behaviour | Client action |
|---|---|---|---|
| Leaving the service | No route. A user who wanted their account gone asked the operator, who could deactivate it from the panel but never delete it | `DELETE /api/v1/me` with a full-scope token and `{"password": "…"}` answers `204` and deletes the account row, the devices, the one-time prekeys of both kinds, the identity, the key backup, the device-list log, the profile blob and every queued envelope of every device. The username is free again | **Required before release.** The settings screen needs the action, and its wording must say what it does not erase — see [`CLIENT_WORK.md`](CLIENT_WORK.md) |
| The password | — | Required and checked. A wrong one is `401 {"code": "invalid_credentials"}`, the same body login answers | Ask for it in the confirmation dialog. Do not cache it for this call |
| Guessing at it | — | Counted against the same per-name cool-off `POST /api/v1/auth/login` feeds: five failures on a username inside fifteen minutes lock it for fifteen on **both** routes, answering `429 throttled` with `Retry-After` | Show the wait. A user locked here cannot log in either, on any device |
| The token afterwards | — | Dead. Every socket of the account's devices closes with `4003`, and any later call answers `401 {"code": "token_revoked"}` | Treat a `401` on a retry as success: the first call landed and the response was lost |
| Attachments this account uploaded | — | Left in place until `ATTACH_TTL_DAYS` expires them. Nothing on an attachment row names an account, so there is no set of them this call could identify | None. Say "up to N days" if the screen mentions it; `attachment_ttl_days` is in `GET /api/v1/config` |
| Copies peers hold | — | Untouched, and unreachable from here. Every message this account sent was decrypted on the recipient's device | **Required in the wording.** A dialog that says "delete my data" without this is a false claim |
| The audit log | — | No row is written. The operator performed nothing | None |

## The retired columns leave the schema

**Nothing here reaches a client.** Ten columns that no route served, no response
carried and no code read or wrote were dropped from the database, with the two
indexes that were maintained for them, and the migrations-only `voicerooms` package
left the tree with them. Every field the
retirements themselves removed from a response was published when it happened —
`last_active_date` under "The token pair becomes one session token" and the
attachment fields under "The attachment store stops naming accounts" — and this step
changes no request shape, no response shape, no status and no header.
`backend/openapi.json` is byte-for-byte unchanged across it.

## What the client can build against now

**The surface is frozen at `v1` from this merge.** It is **32 operations over 28
paths**, plus the `/ws` gateway, and nothing else answers:

| App | Operations | What the client reaches there |
|---|---|---|
| [`devices`](backend/devices/API.md) | 13 | Device registration and revocation, the cross-signing identity, classical and ML-KEM prekeys, peer bundles and claims, the device-list log, and the peer-state batch |
| [`accounts`](backend/accounts/API.md) | 9 | Register, login, renew, logout, the user directory, the encrypted profile, and account erasure |
| [`messaging`](backend/messaging/API.md) | 3 | Fan-out send, per-device drain, ack |
| [`attachments`](backend/attachments/API.md) | 2 | Bucketed upload and capability download |
| [`vault`](backend/vault/API.md) | 2 | Read and write the recovery key backup |
| [`core`](backend/core/API.md) | 2 | Health, and the published limits |
| [`realtime`](backend/realtime/API.md) | 1 | The relay credential. The `/ws` gateway itself is a WebSocket and carries no OpenAPI operation, so `realtime/API.md` is the whole of its reference: its frames, its bucket rules and its close codes |

By method that is 13 `GET`, 12 `POST`, 5 `PUT` and 2 `DELETE`. Every one of the 32
declares `401`, `403`, `429`, `500` and `503`; 21 declare `400`, 15 `413`, 7 `404`
and 7 `409`.

**3 of the 32 take no credential** — health, register and login. **One takes the
short-lived register-scope token** — `POST /api/v1/me/devices`, which is the route
that mints the device a caller does not yet have. **The other 28 take a session token
bound to a live device**, and there is exactly one kind of it: one token, thirty
days, no refresh, revoked by a counter on the device row
([ADR-0023](docs/architecture/decisions/0023-one-device-bound-session-token.md)).

It is published two ways and they are the same contract:

- [`backend/openapi.json`](backend/openapi.json) — the OpenAPI document, generated
  from the routes. Every path, method, request shape, response shape and status is in
  it, including every error status each route can answer, each with the envelope. CI
  fails a change that does not regenerate it, so it cannot describe a server that no
  longer exists.
- The per-app `API.md` files — the same routes in prose, plus what a schema cannot
  carry: the retry semantics of **every** route, the padding buckets, and the
  WebSocket close codes. Every route, not only the mutating ones: "this route is a
  read" is a fact only the route can state, because the method does not carry it.

Both are gated in both directions. A route the document describes and the surface
does not serve fails, and so does a route the surface serves and the document does
not describe; the same holds for every status each route publishes against every
status its code can answer.

There is **no idempotency store**, because a stored response for a send would link a
sender to its recipients at rest — which is the one thing the schema is built to
avoid. Every mutating route documents what a retry of it does instead, and that text
is part of the contract. Read it before you write a retry policy.

The version stays `v1`. No released client exists, so no deprecation cycle is owed to
anyone; when one does, `v2` becomes a path rather than a note here
([ADR-0007](docs/architecture/decisions/0007-contract-conventions.md)).

**From here, every observable change gets a new section in this file, above this
one**, naming the route or field, the old behaviour, the new behaviour and the client
action. A change that reaches a client without a section here is a defect.
