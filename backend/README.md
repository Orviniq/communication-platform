# Chat backend

The Django backend of a self-hosted, end-to-end encrypted chat platform: direct
messages and group chats. The server relays and stores opaque
ciphertext and public keys; all cryptography runs in the client. The server never
holds a private key, a content key, or a plaintext message, and its schema stores no
conversation graph — an envelope knows its recipient device and nothing else.

Python 3.12, Django 6.0, FastAPI on uvicorn. PostgreSQL and Redis are the only
backing services, and there is no outbound network dependency at runtime.

FastAPI is the only API surface. It is the root application and serves every route
of every app, `/ws` included; the Django application behind it answers `ADMIN_PATH`
and, in development, the static files the admin renders with. Any other path is this
API's own `404`, never a Django page. Django keeps the ORM, the migrations, the admin
panel and the settings.

`openapi.json` is the generated contract of that surface: `python manage.py openapi`
writes it and `--check` fails when the committed file is not what the routes produce,
which CI runs as its own job. The server publishes no schema route and no interactive
documentation in any mode: a route map is reconnaissance on a server whose posture is
to reveal nothing, and the interactive views render for a browser this product does
not have. The committed file is the only reference, and it works offline.

## Protocol and transport

**REST.** All HTTP endpoints live under `/api/v1`, JSON in and JSON out. The one
exception is `POST /api/v1/attachments`, which takes a multipart body of exactly one
file part named `blob` and nothing else; its cap is the largest attachment bucket
plus `MULTIPART_OVERHEAD_BYTES`, and the bytes stream to disk one chunk at a time so
the process never holds a whole attachment. Binary values otherwise cross the API
base64-encoded. Errors share one envelope: `{"code": "...", "detail": ...}`, where
`detail` is a string except for `invalid_request`, which maps a field path to its
messages. No error body echoes request input. A request that fails validation is
`400 invalid_request`, a body above the route's cap is `413 payload_too_large`, and a
request past its deadline is `503 unavailable`.

**Authentication.** Bearer JWTs (PyJWT, HS256, a dedicated `JWT_SIGNING_KEY`). No
token is ever stored: a token table would be a per-device login record at rest, so
revocation lives in one counter on the device row instead. There is one token, and its
`typ` claim carries its power (ADR-0023). Login with a known device id yields a session
token of `SESSION_TOKEN_DAYS`, bound to that device and carrying a `tgen`
(token-generation) claim checked against the device row on every request and at every
socket bind, so revoking a device — which bumps the generation — kills all its
outstanding tokens immediately. Logout does the same for the calling device.
`POST /api/v1/auth/renew` issues another token and retires none, so nothing rotates and
the token presented stays valid until its own expiry; the cost of that is
[`../ACCEPTED_RISKS.md`](../ACCEPTED_RISKS.md) AR-18. Login without a device yields a
narrow `register` token whose only power is registering a device at
`POST /api/v1/me/devices`. Both runtimes verify through the same module, so a token one
revokes is dead on the other.

**WebSocket.** One gateway at `/ws`, a Starlette WebSocket route of the same FastAPI
application, with one handshake path: an `Authorization: Bearer` header on the upgrade
request. A bad token or no header refuses the handshake before the accept, which the
client sees as `403 Forbidden` rather than as a close code, so every accepted socket
is already bound to a device. The gateway handles `ack` and `signal` frames from the
client and emits `envelope` and `signal` frames to it; it holds no presence, which is
client protocol over `signal` frames
([ADR-0022](../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md)).
A `signal` blob is base64 of exactly one signal bucket, like every stored
ciphertext. Frames are JSON text only, size- and rate-limited;
protocol violations and a slow consumer close the socket with code 4008, revocation
with 4003, and a shutdown with 1012.

**The fan-out bus.** A frame that has to reach a socket other than the one that sent it
goes through `realtime/bus.py`: Redis publish and subscribe over the async client, one
subscription connection for each worker process, with one topic per device
(`ws:dev:<device id>`). The gateway subscribes to that topic on bind and
unsubscribes on the way out, so Redis drops a publish nobody holds rather than
carrying it to a worker that would discard it. Every
publisher — the send push, the revocation and deactivation closes, and the signal
relay — publishes after its transaction has committed, and a publish that fails never
fails the request that caused it.

**Durable queue versus volatile relay.** A sent message is fanned out into one padded
ciphertext row per recipient device, held until that device drains and acks it (or the
TTL prunes it). A group message is the same fan-out over every member device, each copy
under its own pairwise session; the server holds no group object, roster, or group key.
Everything else — the signalling of a call, and every announcement between the
members of a conversation — is relayed between live sockets over the fan-out bus and
never touches the database or disk. If no socket is listening, a volatile signal is
dropped.

**Voice.** The server half is served by this revision, and no client places a call
against it yet. The design is a full mesh of WebRTC audio between client devices, keyed
by DTLS-SRTP between the two endpoints of each connection and relayed by the self-hosted
coturn instance under a relay-only ICE policy; the offers, answers and candidates ride
the `signal` frames above, and no room record, join token or media key exists on the
server
([ADR-0021](../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)).
`POST /api/v1/me/relay` is the whole of the server's part: it mints an ephemeral coturn
credential under `TURN_STATIC_AUTH_SECRET`, the one value this backend and
`ops/coturn/turnserver.conf` share, and stores nothing behind it
([realtime/API.md](realtime/API.md)). `TURN_REALM` is read by the coturn file alone.

**Attachments.** Uploads are opaque encrypted blobs in fixed size buckets, stored on
disk under a 43-character unguessable capability id. Download responses carry an
`X-Accel-Redirect` header; nginx streams the bytes from an `internal` location, so
Django never serves file contents.

**Padding buckets.** Every stored ciphertext — envelopes, profiles, device labels,
key backups, device-log records, attachments — must be
exactly one of a fixed set of sizes for its type. Off-bucket payloads are rejected
(`400 {"code": "bad_bucket"}`) without being echoed. Size-within-a-bucket is therefore
the only content-derived signal the server can observe.

**No server-side history.** The server stores message ciphertext only in the delivery
queue: rows are deleted when the recipient device acks them, and undelivered rows are
pruned after 7 days. History sync between a user's devices is client-to-client over the
ordinary envelope endpoint — a new device has no history until an existing device is
online to transfer it. There is no server history API.

## Runtime dependencies

- PostgreSQL 16, on loopback.
- Redis 7, on loopback (rate counters, the login lockout, and the gateway's fan-out
  bus; configured non-persistent).
- uvicorn serving ASGI behind nginx, supervised by systemd, with uvloop, httptools and
  the `websockets` sans-io implementation; nginx terminates TLS and serves attachment
  bytes. `WEB_CONCURRENCY` sets the worker count and defaults to 1; each worker opens
  one Redis subscription connection of its own. Everything loop-bound — the shared
  Redis client, the bus subscriber and its reader task — is built on first use and
  released on the lifespan shutdown, which also drains every live socket with 1012.
- No CDN, no push service, no telemetry, no external CA or API. Dependencies are
  pinned and hashed in `requirements/`; the operator builds the untracked `vendor/`
  wheel cache with `ops/vendor.sh` while online, and `ops/offline_install.sh`
  installs from it with no network.

## Repository layout

| Path | Owns |
|---|---|
| `api` | The FastAPI runtime and the seam: the composed application, token issue and verification, the error envelope, the shared Redis client and the rate limiter over it, the ORM unit-of-work helper, the pure-ASGI request limits |
| `accounts` | User model, register/login/renew/logout, user directory, encrypted profile blobs |
| `devices` | Device registry, cross-signing identity, classical + ML-KEM prekeys, device-list log, peer bundles and claims, revocation cascade |
| `vault` | Recovery key backup (cross-signing private key material, opaque to the server) |
| `messaging` | Durable envelope queue: fan-out send, per-device drain, ack |
| `attachments` | Bucketed encrypted blob store with capability-id access |
| `voicerooms` | A migrations package and nothing else: `0002_delete_room` drops the table ADR-0021 removed. It leaves the tree once every environment has applied it |
| `realtime` | The `/ws` gateway, the Redis publish-and-subscribe bus behind it, and its socket-side auth |
| `core` | Size buckets, opaque blob field, env helpers, log scrubbing, health endpoint, deploy checks |
| `config` | Settings (`base`/`dev`/`prod`), the ASGI entry point, root URLconf |
| `openapi.json` | The generated OpenAPI document of the whole surface, committed so a contract change is a diff in review. `manage.py openapi` writes it; `--check` gates it |
| `ops` | Deployment units, nginx/coturn/redis config, offline-install and audit tooling |
| `requirements` | Pinned, hashed dependencies. `vendor/` holds the offline wheel cache that `ops/vendor.sh` builds; it is not tracked in git |

## Local development

Install PostgreSQL 16 and Redis 7 natively (one-time database/user setup is described
in `ops/postgres/README.md`; start Redis with
`redis-server ops/redis/redis-chatapp.conf --daemonize yes`). Then:

```sh
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements/dev.txt
cp .env.example .env        # fill in dev values
set -a; source .env; set +a
python manage.py migrate
pytest
python manage.py openapi --check
python manage.py check --deploy
```

Tests use `config.settings.dev` (see `pytest.ini`) and require both services running.
The dev settings fall back to insecure dev keys for `DJANGO_SECRET_KEY` and
`JWT_SIGNING_KEY` when unset; everything else reads from the environment.

Branch coverage is gated at 95 percent over `backend/`. `pytest` on its own does not
measure it, so the inner loop stays fast and a single file can be run alone; the gate
is `pytest --cov --cov-branch`, which is what CI runs and what `pytest.ini` binds the
floor to. `pyproject.toml` carries what is measured and what is excluded.

Each app holds exactly one `0001_initial` migration. A developer database that
recorded the history before it was regenerated cannot be migrated onto this one — drop
and recreate it, as `ops/postgres/README.md` describes. A route change that alters the
contract needs `python manage.py openapi` and the regenerated file committed with it.

## Configuration

Every environment variable the code reads, with its default:

| Variable | Default | Description |
|---|---|---|
| `DJANGO_SECRET_KEY` | — (required) | Django secret key |
| `DJANGO_ALLOWED_HOSTS` | empty | Comma-separated `ALLOWED_HOSTS` |
| `ADMIN_PATH` | `admin/` | URL path of the admin panel; the nginx site needs a matching location |
| `ADMIN_AUDIT_RETENTION_DAYS` | `90` | How long an admin audit row survives before `manage.py prune` deletes it |
| `POSTGRES_DB` | — (required) | Database name |
| `POSTGRES_USER` | — (required) | Database role |
| `POSTGRES_PASSWORD` | — (required) | Database password |
| `POSTGRES_HOST` | `127.0.0.1` | Database host |
| `POSTGRES_PORT` | `5432` | Database port |
| `DB_CONN_MAX_AGE` | `0` | Persistent DB connection lifetime, seconds. Must stay 0: the pool refuses a higher value, and nothing in this process fires the request signals that would reap a persistent connection |
| `DB_POOL_MIN_SIZE` | `1` | psycopg connection pool, minimum size |
| `DB_POOL_MAX_SIZE` | `16` | psycopg connection pool, maximum size; the ceiling on what one process takes from `max_connections` |
| `DB_POOL_TIMEOUT` | `10` | Seconds to wait for a pooled connection |
| `REDIS_URL` | `redis://127.0.0.1:6379/0` | Redis URL for the rate counters, the login lockout and the gateway bus. Production carries the `requirepass` value as `redis://:<password>@127.0.0.1:6379/0`; `check --deploy` refuses a URL without one (`core.E004`) |
| `REDIS_COMMAND_TIMEOUT_SECONDS` | `2` | Connect and per-command timeout, seconds, for every Redis client of the process; a store that accepts the connection and then stops answering fails the command instead of holding its caller. The blocking pub/sub read of the gateway bus opts out of it |
| `JWT_SIGNING_KEY` | — (required) | HS256 signing key for all JWTs; at least 32 characters and never equal to `DJANGO_SECRET_KEY`, or `check --deploy` refuses it (`core.E005`) |
| `SESSION_TOKEN_DAYS` | `30` | Session-token lifetime, days |
| `REGISTER_SCOPE_ACCESS_MIN` | `10` | Register-token lifetime, minutes |
| `REQUEST_DEADLINE_SECONDS` | `15` | Deadline for a request FastAPI serves; past it the answer is `503 unavailable` |
| `UPLOAD_DEADLINE_SECONDS` | `120` | Deadline for the attachment upload and the device/envelope batch routes |
| `BODY_CAP_JSON_BYTES` | `16384` | Body cap for a small-JSON route, and for any path no route claims |
| `BODY_CAP_BACKUP_BYTES` | `2097152` | Body cap for `PUT /api/v1/me/keybackup` |
| `BODY_CAP_BATCH_BYTES` | `73400320` | Body cap for the `devices` and `messaging` list bodies; matches nginx's `client_max_body_size 70m` |
| `MULTIPART_OVERHEAD_BYTES` | `8192` | Added to the largest attachment bucket to give `POST /api/v1/attachments` its cap |
| `THROTTLE_REGISTER` | `10/hour` | Rate limit: account registration |
| `THROTTLE_LOGIN` | `20/hour` | Rate limit: login |
| `THROTTLE_ACCOUNTS` | `120/min` | Rate limit: general account and device endpoints |
| `THROTTLE_CLAIM` | `120/min` | Rate limit: prekey-bundle claims |
| `THROTTLE_ENVELOPES` | `600/min` | Rate limit: send/drain/ack |
| `THROTTLE_ATTACHMENTS` | `60/min` | Rate limit: attachment upload/download |
| `THROTTLE_RELAY` | `60/min` | Rate limit: relay-credential minting, per account |
| `ATTACHMENTS_ROOT` | `<repo>/media_root` | Directory for attachment bytes |
| `ATTACH_USER_QUOTA_BYTES` | `2147483648` | Per-user attachment quota (2 GiB) |
| `ATTACH_TTL_DAYS` | `30` | Attachment retention, days |
| `ENVELOPE_TTL_DAYS` | `7` | Undelivered-envelope retention, days (delivered rows are deleted on ack; pruning records the per-device `pruned_through` watermark) |
| `MAILBOX_MAX_BYTES` | `33554432` | Ceiling on the undelivered bytes of one mailbox (32 MiB); a send that would pass it is refused for that device and reported in `full_devices` |
| `MAX_DEVICES_PER_USER` | `10` | Live-device cap per account |
| `MAX_DEVICELOG_RECORDS` | `10000` | Ceiling on one account's device-list log; an append past it is `409 devicelog_limit` |
| `WEB_CONCURRENCY` | `1` | uvicorn worker processes; each opens its own Redis subscription for the gateway bus |
| `WS_MAX_FRAME` | `524288` | Maximum WebSocket frame, bytes |
| `TURN_URLS` | empty | Comma-separated `turn:` URLs the relay route hands a client. Empty serves no voice: `POST /api/v1/me/relay` answers `503 voice_unconfigured` |
| `TURN_STATIC_AUTH_SECRET` | empty | The HMAC key a relay credential is signed under; one value shared with `static-auth-secret` in `ops/coturn/turnserver.conf`. `check --deploy` refuses under 32 characters once `TURN_URLS` is set (`core.E005`) |
| `RELAY_CREDENTIAL_TTL_SECONDS` | `21600` | Lifetime of a minted relay credential, seconds |

`.env.example` lists all of these plus `DJANGO_SETTINGS_MODULE` and `TURN_REALM`,
which `ops/coturn/turnserver.conf` consumes and no Python module reads.
`TURN_STATIC_AUTH_SECRET` is read by both: it is one value in two places, and the
runbook's coturn step is where the second copy is filled in.

## The admin panel

The back office runs on [django-unfold](https://unfoldadmin.com/) at `ADMIN_PATH`,
served by the same uvicorn process as the API. It registers four things and hides
everything else: accounts, devices, attachments, and a read-only audit log. It
renders no ciphertext, no key or signature bytes, no password hash and no token — a
device label is ciphertext, so it is not shown.

There is one role, the superuser owner; a staff account that is not the owner gets an
empty panel. Every administrative act writes an audit row, bulk actions included, and
`manage.py prune` deletes a row older than `ADMIN_AUDIT_RETENTION_DAYS`. Five failed
sign-ins lock an account name for fifteen minutes, in Redis and nowhere else, and a
session lasts at most eight hours and ends at browser close.

Every asset is served by this deployment: run `python manage.py collectstatic` on
deploy, and nginx serves `STATIC_ROOT` — without it the panel renders unstyled. The
nginx site needs a `location` for `ADMIN_PATH`; `ops/nginx/chat.nimashadloo.dev.conf`
carries the default one, and it and `ADMIN_PATH` are one setting in two places.

[`docs/admin/PANEL-RECORD.md`](../docs/admin/PANEL-RECORD.md) is the system of record
for the panel: the pinned release, every position with its band and flip signal, the
override ledger, the role model, the upgrade debts and the deferrals. Read it before
changing the panel.

## Deployment

[`ops/RUNBOOK.md`](ops/RUNBOOK.md) is the authoritative sequence: host setup, the
wheel vendoring and the offline install, the database and the recreation rule of this
version, `migrate` and `collectstatic`, the environment file and its permissions, the
units, nginx and TLS under the private CA, coturn, the checks that verify
a deploy, the rollback, and the maintenance timer. This README does not duplicate it.

The rest of `ops/` is what the runbook routes to: the systemd units for uvicorn and
the maintenance timer, the nginx site and the proxy snippet it includes, the coturn
configuration, PostgreSQL setup notes, the TLS scripts, and the offline
tooling (`ops/vendor.sh`, `ops/offline_install.sh`, `ops/gen_sbom.sh`,
`ops/audit/offline_rehearsal.sh`).

One step is worth naming here because nothing fails loudly without it:
`python manage.py collectstatic --noinput` must run on every deploy that changes a
dependency, or nginx serves an empty `STATIC_ROOT` and the panel loads with no styling
at all.

## What the server can still see

End-to-end encryption bounds what this server stores, not what it can observe while
running. The operator can see which accounts exist, which devices connect and when,
connection metadata such as IP addresses, and the size bucket and timing of every
stored or relayed blob — and a live operator watching the routing can log which
connection writes to and reads from which device queue, i.e. who talks to whom and
when. The social graph is not hidden from a live, hostile operator; message content is.
The schema stores none of that graph at rest, so a seized disk yields only what
[SECURITY.md](SECURITY.md) enumerates.

Further reading: [SECURITY.md](SECURITY.md) for the full threat model and residual
risk, [CLIENT_CONTRACT.md](CLIENT_CONTRACT.md) for the client-side halves of every
security property.
