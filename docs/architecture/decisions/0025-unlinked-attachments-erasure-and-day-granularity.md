# 0025. Attachments with no owner, account erasure, and day granularity

- Status: Accepted
- Phase: 9
- Date: 2026-09-06
- Landed: 2026-09-06, in the sixth run of phase 9. The upload charges a daily
  allowance in Redis and a free-space floor on disk, `Attachment.uploader` has no
  reader and no writer, `DELETE /api/v1/me` is served, `QueuedEnvelope.queued_day`
  is the retention filter, and every audit row carries a day.

## Context

Four columns and one absence, each of them a thing this server records that its
own threat model says it should not.

**The uploader column.** An upload was charged against `ATTACH_USER_QUOTA_BYTES`,
a lifetime sum over `Attachment.uploader`. The quota needed the column, and the
column is the one place in the schema that says whose bytes a stored blob is. A
seizure of the disk read it directly: how many files an account uploaded, at which
bucket sizes, on which days, and — because two rows share an uploader — that two
blobs came from the same person. Nothing about the product needed it. The
capability id is the whole access control and travels inside end-to-end encrypted
messages; no route ever served the uploader, and the retention sweep deletes by
age and never by owner.

**No way to leave.** The panel could deactivate an account and never delete one,
and the API had no route at all. A user who wanted to be gone stayed in the
database: the username, the Argon2 hash, the devices and their public key
material, the published identity, the key backup, the device-list log, the profile
blob and every undelivered envelope. `manage.py prune` bounds the envelopes at
seven days and nothing bounds the rest. The seizure yield of this server therefore
grew with every account that had ever existed rather than with the accounts that
use it.

**The hour on a queued envelope.** `QueuedEnvelope.queued_hour` existed for the
retention sweep, which needs to know whether a row is older than
`ENVELOPE_TTL_DAYS` — seven days. It recorded the hour. An hour says which part of
a day a recipient device was addressed in, which is a waking pattern for the
person holding that device, and the sweep never asked for it.

**The second on an audit row.** `LogEntry.action_time` is Django's own column and
the panel wrote the second of every administrative act into it, kept for ninety
days. The log's purpose is to answer what the operator changed. The minute they
did it is the operator's own working pattern, and a quarter of it is a long record
to hold on a box whose adversary has root.

**And the guard that was missing.** The lifetime quota bounded one account against
its own ceiling and bounded the disk not at all: `ATTACH_USER_QUOTA_BYTES` times
the account count is what the deployment had sold, and nothing measured what the
filesystem actually had left. A full disk on this host is PostgreSQL and Redis
losing their writes, not one refused upload.

## Decision

### 1. The lifetime quota leaves, and a daily allowance replaces it

`ATTACH_USER_QUOTA_BYTES` and the `SUM` over `Attachment.uploader` are removed.
The server stops reading and writing `Attachment.uploader`; the column stays
nullable and unused until run 08 drops it, because a column leaves in two steps.

`ATTACH_DAILY_BYTES`, default 268435456 (256 MiB), is what one account may upload
in one UTC day. The counter is one integer in Redis under a key that names the
account and the day, expiring after two days, and it never touches disk — the same
rule the rate counters and the login lockout follow.

The upload reserves the bucket size in that counter before it writes a byte, with
one `INCRBY`, and refunds it on every failure after that point. A reservation past
the allowance answers `413 quota_exceeded`, the code the lifetime quota already
used; the code now means the day's allowance is spent. An unreachable Redis
answers `503 unavailable`, the fail-closed posture of
[0010](0010-redis-rate-limiting-that-fails-closed.md).

### 2. A free-space floor on the disk itself

`ATTACH_MIN_FREE_BYTES`, default 2147483648 (2 GiB), is the free space
`ATTACHMENTS_ROOT` must still have. An upload that finds less answers `503
storage_full`, a new code in the vocabulary of `backend/core/API.md`, which the
client reads as retry later. It is read from the filesystem on every upload with
one `statvfs`, so it holds whatever the counters in Redis say.

### 3. `GET /api/v1/config` publishes `attachment_daily_bytes`

The client can state the allowance before a large send rather than after a `413`.

### 4. `DELETE /api/v1/me`

A full-scope token and a body with one field `password`, on the `accounts` rate
scope. The password is checked under the same per-name lockout `POST
/api/v1/auth/login` runs: five failures on a name inside fifteen minutes lock it
for fifteen on both surfaces. A wrong password answers `401 invalid_credentials`.

Success answers `204`. In one transaction it deletes the account row and every row
that depends on it — the devices, the one-time prekeys of both kinds, the
identity, the key backup, the device-log records, the profile blob and every
queued envelope of its devices. The username becomes free. Every live socket of
the account's devices closes with `4003`, after the commit. Attachments stay until
the retention sweep, because nothing links them to an account any more.

No audit row is written: the operator did nothing.

A second call answers `401 token_revoked`, because the device the token names is
gone with the account. That is also success.

### 5. `QueuedEnvelope.queued_hour` becomes `queued_day`

A date. The sweep expires a row whose day is older than `ENVELOPE_TTL_DAYS`, so an
envelope survives for the rest of the day its window ends on — up to one day
longer than the hour kept it, never less. The sweep keeps its batches, its
watermark and its advisory lock.

The column arrives in three migrations: an expand step that adds it with a default
and drops the `NOT NULL` on the column it replaces, a batched backfill that gives
each row the day of its own hour, and a concurrent index build. Run 08 drops
`queued_hour` and `ix_queue_queued_hour`.

### 6. Every audit row carries the UTC day of the act

`LogEntry.action_time` belongs to a contributed application whose schema this
project does not change, so the coarsening happens at the write: the panel stamps
midnight UTC. `ADMIN_AUDIT_RETENTION_DAYS` defaults to 30.

## Position fields

- **Forcing function.** The threat model accepts an adversary with live root on
  the VPS, so every column is read as a column that adversary already has. Four of
  them recorded things no route served and no control needed: who uploaded a file,
  the hour a device was addressed in, the second an operator clicked, and the whole
  history of accounts that had asked to leave. A control that needs a column is a
  trade; a column that buys nothing is a leak with a maintenance cost.
- **Scale band.** Band 0, holding through band 2. The allowance is one Redis key
  per account per day, which is at most the account count times two live keys. The
  free-space read is one `statvfs` on the upload path, which the limiter already
  caps at 60 requests a minute per account. The erasure cascade is fifteen
  statements at any device count, every one of them a fast delete. The `queued_day`
  index is 1456 kB at 200 000 rows.
- **Flip trigger.** For the allowance: an operator who has to restart Redis often
  enough that a forgiven day stops being rare, or the first day the free-space
  guard actually fires — either buys a persisted counter, which is a schema change
  and a seizure-yield change and needs an ADR of its own (`ACCEPTED_RISKS.md`
  AR-19). For the erasure: a second operator, at which point an account that can
  open the panel erasing itself stops being one person's own decision. For the day
  granularity: an audit requirement that needs the order of two acts on one day.
- **Cost.** The allowance is a rate and not a balance, so it does not bound what
  one account accumulates over time — the retention sweep is what does, and an
  account that uploads its allowance every day for thirty days holds thirty days of
  it. Deleting an attachment gives nothing back, because nothing is counted at
  rest. The counter is volatile, so a Redis restart forgives the day (AR-19). The
  operator loses the ability to answer "who uploaded this" and "when was this
  attachment uploaded, by whom" — from the panel, the database or a dump. The audit
  log can no longer order two acts on one day. An account that can open the admin
  panel takes its own audit rows with it when it erases itself, because Django's
  `LogEntry.user` cascades. And the queue keeps two indexes until run 08, so every
  insert into the largest table in the schema maintains one B-tree it does not use.
- **Evidence.** The lock class of every new migration is measured rather than
  argued. `ALTER TABLE … ADD COLUMN <date> DEFAULT <constant> NOT NULL` rewrites
  nothing on PostgreSQL 11 and later — it stores the evaluated default in
  `pg_attribute.attmissingval` — measured at 1.7 ms against a 200 000-row, 111.6 MB
  table with `relfilenode` unchanged either side, and `DEFAULT CURRENT_DATE` and
  `DEFAULT (STATEMENT_TIMESTAMP())` behaved identically at 0.2 ms.
  `core/tests/test_migrations.py::test_each_migration_takes_only_the_locks_recorded_against_it`
  reads `pg_locks` while the statements are still held and confirms one ACCESS
  EXCLUSIVE on `messaging_queuedenvelope` and nothing else. The sweep's plan on the
  new index was re-measured on a fresh seed of the band's shape: 2 buffers and
  0.012 ms with nothing expired, 1002 buffers and 2.95 ms for a batch of 1000. The
  upload's query count fell from three statements to one, pinned at 0 and at 25
  stored rows by `attachments/tests/test_query_counts.py`. The erasure cascade is
  fifteen statements at 1 and at 3 devices, pinned by
  `accounts/tests/test_query_counts.py`. Django 6.0.7 and django-unfold 0.105.0
  were read directly to confirm that `log_change`, `log_deletions` and
  `log_addition` all come from Django's own `ModelAdmin`, so the theme shadows none
  of them. **Currency:** current.

## Consequences

- `ACCEPTED_RISKS.md` AR-8 closes, and not by its own trigger: the aggregate it
  recorded is gone rather than indexed, because the column it summed left. AR-2
  loses its uploader wording — the audit row for an operator deletion now names the
  size and the day. AR-19 is new and carries what the volatile counter costs.
  AR-12's trigger rests on AR-7 alone now.
- `backend/SECURITY.md` states the new seizure yield three times over: an
  attachment row names a size, a day and nobody; a pending envelope names a
  recipient device and a day and never an hour; the audit log holds at most one
  month, at day granularity.
- The two-step column removal applies twice more. `Attachment.uploader` and
  `QueuedEnvelope.queued_hour` survive with no reader and no writer until run 08,
  and `ix_queue_queued_hour` survives with them.
- `messaging/models.py` keeps `_truncate_hour` for `0001_initial` alone, which
  names it by import path. The migration history is append-only, and editing an
  applied migration to remove the reference is the one repair this project does not
  make.
- `core/tests/test_migrations.py` admits `AddField` and `RunPython` for the first
  time, and admits `ADD COLUMN` and `DROP DEFAULT` as `ALTER TABLE` forms. Neither
  is a blanket admission: a volatile default fails the check beside the statement
  gate, and a migration recorded as a data migration must emit no DDL at all.
- The deploy order for the queue change is migrate, then code. `0003` leaves a
  `NOT NULL` column the previous release does not know about, so that release
  cannot insert against this schema. The window does not exist on this deployment —
  one `chat.service` on one host cannot run two releases at once, and
  `ops/RUNBOOK.md` §5 stops it before `migrate` — and the failure it would produce
  is a loud, recoverable `NOT NULL` violation on the send route rather than
  anything lost.
- The nginx `/api/` location states `proxy_request_buffering on` and a
  `client_body_timeout` of 30 seconds. Neither changes behaviour; both were
  inherited, and the application's 120-second deadline is only a bound on the
  loopback hop while the first of them holds. Measured both ways —
  `GROUND-TRUTH.md` §4.
- `backend/attachments/API.md` publishes what nginx already did: a download honours
  a `Range` and answers `206` from the internal location. It stays out of
  `backend/openapi.json`, which describes what these routes answer, and this one
  always answers `200`.
- `CLIENT_WORK.md` carries three entries: the erasure action is required before
  release and its wording must say that it does not reach copies peers hold; the
  `Range` resume is optional; the allowance disclosure is recommended.
