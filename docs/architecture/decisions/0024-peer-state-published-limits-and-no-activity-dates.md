# 0024. Peer state in one call, published limits, and no activity dates

- Status: Accepted
- Phase: 8
- Date: 2026-09-06
- Landed: 2026-09-06, in the fifth run of phase 8. `POST /api/v1/peers` and
  `GET /api/v1/config` are served, `GET /api/v1/users/{user_id}/identity` answers
  conditionally, `THROTTLE_ACCOUNTS` defaults to `300/min`, the seven activity
  dates have no writer, and uvicorn pings a socket every 240 seconds.

## Context

Four costs, all of them paid by the one client, and none of them buying the
server anything.

**The verification round trips.** Before a send the client verifies every
recipient, and `frontend/docs/decisions.md` ADR-060 and ADR-065 and
`frontend/docs/sync-engine.md` record what that costs: three reads for each
recipient — `GET /api/v1/users/{user_id}/identity`,
`GET /api/v1/users/{user_id}/devices` and the device log — at 107 to 137
milliseconds a round trip. A 50-member group is 150 round trips against a scope of
120 requests a minute, so one fan-out exhausts the limit in one cycle. The client
answered with a 30-second in-memory cache, which is a correctness compromise it
took on to survive a server shape: for those thirty seconds it encrypts against
state it has not re-checked.

**The unconditional identity read.** `/devices` has carried an `ETag` since the
device log landed. `/identity` never did, so every one of those reads was a full
`200` carrying four base64 key fields, whether the identity had moved or not.

**The unstateable retention window.** `frontend/docs/sync-engine.md` records that
`ENVELOPE_TTL_DAYS` is an operator setting the client cannot state, so a client
that tells a user how long an undelivered message survives is guessing. The same
is true of every other limit a `413`, a `409` or a `400 bad_bucket` teaches the
hard way.

**The socket keepalive.** uvicorn pings every live WebSocket at its default 20
seconds. The client holds that socket in the background under an opt-in foreground
service with a four-minute keepalive of its own, so the server's ping wakes a
mobile radio every twenty seconds for the life of the session, on the one push
path this product has.

And one cost the server pays for nothing. The schema carries seven day-granularity
activity dates — `Device.last_active_date`, written on every socket bind;
`Device.spk_updated_date` and `Device.pq_spk_updated_date`;
`UserIdentity.updated_date`, `ProfileBlob.updated_date`, `KeyBackup.updated_date`;
`DeviceLogRecord.stored_date`. One route served one of them. The rest were read by
nothing at all, and every one of them is a line in the seizure yield of a server
whose adversary holds live root.

## Decision

### 1. `POST /api/v1/peers`

A full-scope token and a body with one field `peers`: 1 to 64 items, each
`user_id` with an optional `etag`. An unknown field is refused.

`200` with one field `peers`: one item for each requested user that exists and is
active, in request order. An unknown, inactive or deactivated user is **omitted**,
so the route tells those three apart no better than the per-user routes do.

An item whose request `etag` matches the current tag carries `user_id`, `etag` and
`unchanged` with the value true. Every other item carries `user_id`, `etag`,
`identity`, `devices` and `log_head_seq` — `identity` in the shape of
`GET /api/v1/users/{user_id}/identity` or null, `devices` in the item shape of
`GET /api/v1/users/{user_id}/devices`. Both are built by the functions those routes
build them with, so the bytes are the same bytes and a client that verifies one
verifies the other unchanged.

The tag is the route's own, and not either per-user tag: it changes when the
identity, the live device set, any bundle version or the log head changes, and
never otherwise. It is a digest over exactly what the route serves for that peer,
which is what makes "exactly when" a property of the code rather than a claim about
it.

The query count is constant in the number of peers: four statements, whether the
call names one peer or sixty-four. The rate-limit scope is `accounts`. The route
writes nothing.

### 2. The identity read answers conditionally

`GET /api/v1/users/{user_id}/identity` carries an `ETag` header, mirrored as `etag`
in the body, over the four public byte fields and the version. A matching
`If-None-Match` is `304` with an empty body. The tag is derived from the row rather
than stored beside it, so a `304` costs the same one query a `200` does; what it
saves is the body. `PUT /api/v1/me/identity` is unchanged.

### 3. `GET /api/v1/config`

A full-scope token, no parameters, scope `accounts`. `200` with
`envelope_ttl_days`, `attachment_ttl_days`, `mailbox_max_bytes`,
`max_devices_per_user`, `max_devicelog_records`, `session_token_days`,
`send_batch_max`, `ack_max`, `drain_page_max`, `claim_max`, `envelope_buckets`,
`attachment_buckets`, `signal_buckets` and `voice_configured`. Every value is read
from the setting or the module constant the enforcing route reads, so nothing is
duplicated by hand and nothing can drift from what the server actually does.

### 4. `THROTTLE_ACCOUNTS` defaults to `300/min`

A 50-member fan-out with per-user reads reached the old 120 in one cycle. The
peer-state route removes most of those reads; the raise covers the rest, including
the client's own retry and renewal traffic on the same scope.

### 5. The activity dates stop being written

The server writes none of the seven. The bind write in `backend/realtime/auth.py`
leaves with the function that held it, so bringing a socket up is one read and no
write at all. `last_active_date` leaves `OwnDeviceOut`, and no route serves any of
the seven.

Each field becomes nullable with no automatic value in this run; run 08 drops the
columns. A column leaves in two steps, which is the migration rule of this
repository.

`created_date` on accounts, devices and attachments stays, and `revoked_date` on
devices stays: an authenticating server cannot avoid knowing when an account was
made, and the operator answering "I lost my phone" needs to see which device is
still live. The panel loses its activity columns and its activity filter and keeps
creation and revocation.

### 6. The socket keepalive is 240 seconds

`backend/ops/systemd/chat.service` runs uvicorn with `--ws-ping-interval 240` and
`--ws-ping-timeout 60`. A dead peer therefore holds a socket for at most 300
seconds. The nginx `/ws` read timeout stays at 3600 seconds, well above the
interval, so an idle socket is closed by the keepalive and never cut by the edge.
The client's own four-minute keepalive stays the client's decision.

## Position fields

- **Forcing function.** The client paid three round trips for each recipient of
  every send and had to cache the answers for thirty seconds to fit the rate limit;
  it could not state the retention window to its user at all; and its background
  socket was woken every twenty seconds by a ping it did not need. Each is a server
  shape, and each is cheaper to fix on the server than to work around on the
  client — which is the standing rule of this project.
- **Scale band.** Band 0, holding through band 2. At most 500 devices and at most
  50 members in a group. What moves with traffic is the peer-state route, and it
  moves the right way: the work is four statements per call rather than three per
  recipient, so a larger group makes the saving larger. The batch ceiling of 64 is
  above the largest group the band admits.
- **Flip trigger.** A group larger than 64 members, which makes the batch two calls
  rather than one and is the moment to weigh a page against a larger ceiling. For
  the keepalive: evidence that a middlebox on a real network drops an idle socket
  inside 240 seconds, which would make the interval a reachability problem rather
  than a battery one.
- **Cost.** The peer-state answer is larger than any single per-user answer, so a
  client that wanted only one peer's devices still pays for the identity and the
  log head — the per-user routes stay for exactly that case. It is also larger per
  unit of rate limit than what it replaces: the `accounts` scope counts a request
  rather than its bytes, and one call at the route's ceiling answers 222 kB, so an
  account can pull about 66 MB a minute of public key material where the per-user
  reads gave it roughly 130 kB. `ACCEPTED_RISKS.md` AR-4 carries the measurement and
  the trigger. The tag is one
  comparison over four inputs, so a change to any of them costs a full answer for
  all of them: a device added to a peer re-sends that peer's identity too. A dead
  peer now holds a socket for up to 300 seconds instead of 40, which is 500
  connections' worth of the `--limit-concurrency` budget held five times as long in
  the worst case — inside the band, because the budget is 1024 and the band is 500
  devices. And the operator loses the activity day: "when was this device last
  seen" is no longer answerable from the panel, the database or a dump.
- **Evidence.** The client cost is recorded rather than predicted:
  `frontend/docs/decisions.md` ADR-060 and ADR-065 and
  `frontend/docs/sync-engine.md` name the three reads per recipient, the 107–137 ms
  round trip, the 150 round trips for a 50-member group and the 30-second cache
  built to survive them, and record that `ENVELOPE_TTL_DAYS` is an operator setting
  the client cannot state (read 2026-09-06). The query count is measured, not
  argued: `devices/tests/test_query_counts.py` pins four statements at 1, 5, 32 and
  64 peers and at 1, 5 and 10 devices for one peer. uvicorn's WebSocket ping
  defaults are 20 seconds for both the interval and the timeout, set by
  `--ws-ping-interval` and `--ws-ping-timeout`, and `ops/systemd/chat.service` is
  where this deployment overrides them (uvicorn 0.52.4). `ALTER COLUMN … DROP NOT
  NULL` is a `pg_attribute` write that reads no row; the lock it takes is measured
  rather than assumed by
  `core/tests/test_migrations.py::test_each_migration_takes_only_the_locks_recorded_against_it`,
  which reads `pg_locks` while the statements are still held.
  **Currency:** current.

## Consequences

- The client may drop the 30-second peer cache. `CLIENT_WORK.md` records the
  removal as optional and the linked-devices change as required.
- A client still holds two different tags for one peer: the identity's own, and the
  peer-state route's. They are for different routes and are not interchangeable —
  sending one where the other belongs costs a full answer, never a wrong `304`.
- `backend/SECURITY.md` states the new seizure yield: a creation day, a revocation
  day, and no activity day anywhere.
- The `voicerooms`-style two-step applies again: seven columns survive with no
  reader and no writer until run 08 drops them, and
  `core/tests/test_migrations.py` carries their `AlterField` operations, the
  statement form it admits, and the ACCESS EXCLUSIVE each takes.
- `core/tests/test_migrations.py` admits `AlterField` for the first time. It is not
  a blanket admission: the statement gate is narrowed to `ADD CONSTRAINT` and
  `ALTER COLUMN … DROP NOT NULL`, so a type change or a `SET NOT NULL` — the two
  forms of `AlterField` that rewrite or scan a table — still fails there.
- `API_CHANGES.md` carries the two new routes, the identity `ETag`, the removed
  `last_active_date`, the throttle default and the ping interval, each with the
  client action.
