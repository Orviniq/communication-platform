# 0026. Host posture, and an identity backup nobody on the host can read

- Status: Accepted
- Phase: 9
- Date: 2026-09-06
- Landed: 2026-09-06, in the seventh run of phase 9. `ops/postgres/README.md` sets
  the logging posture and `ops/audit/postgres_posture.sh` reads it back,
  `messaging.0006_reclaim_the_queue_promptly` sets the queue's autovacuum
  parameters, the three units set `LimitCORE=0`, the nginx site resumes no TLS
  session, and `chat-backup.timer` runs `ops/backup/identity_backup.sh` daily.

## Context

Four leaks on the disk side of a design whose whole posture is that the disk holds
nothing readable, and one absence that outranks all four.

**PostgreSQL writes request data to disk by default.** Every other layer of this
deployment was closed: uvicorn runs with `--no-access-log`, nginx with `access_log
off` and `error_log … crit`, and the application's own loggers name no identifier
([0019](0019-the-system-emits-no-request-scoped-telemetry.md)). The database was not,
and nothing in the repository set it. At the stock `log_min_error_statement = error`
a failing statement is written to the server log in full, with its bind parameters —
which on this schema are device ids, envelope ids, capability ids and bucketed
ciphertext. At the stock `log_error_verbosity = default` the `DETAIL` line beside it
names the conflicting key values outright. Measured on PostgreSQL 16.14, one
duplicate insert on a mailbox-shaped table wrote the constraint name, then
`DETAIL: Key (device, seq)=(11111111-…, 7) already exists.`, then the whole `INSERT`
with its blob.

**A deleted row is not erased.** PostgreSQL marks the tuple dead and leaves its bytes
in the page; the space becomes reusable only after a vacuum, and the bytes are gone
only when a later insert takes that space. The queue deletes a row on every
acknowledgement, so this is the routine path rather than an edge case, and the stock
autovacuum trigger is 50 dead tuples plus a fifth of the live ones — 40 050 on a
200 000-row table. A queue that empties and then goes quiet, which is what a shutdown
looks like from this host, holds them indefinitely.

**A core dump is the whole address space.** The serving process holds the JWT signing
key, the Django secret key, the TURN shared secret and the database and Redis
passwords, plus whatever routing metadata and ciphertext is in flight.
`ProtectSystem=strict` does not stop a dump: the kernel writes it wherever
`kernel.core_pattern` points, which on this distribution is `systemd-coredump`,
outside every path the units may write. The units set no limit, and the inherited one
is the host's — systemd's PID 1 raises `RLIMIT_CORE` to infinity for its children,
and `DefaultLimitCORE=` differs between distributions and between releases of one.
Swap is the same exposure without the crash, and nothing in the runbook decided it.

**nginx resumes TLS sessions.** `ssl_session_tickets` is on by default, and a session
ticket key is a long-lived symmetric secret that nginx generates at startup and
rotates only on reload — sitting in worker memory, opening the resumption state of
every session it covers, on a box whose threat model grants the adversary live root.
`ssl_session_cache`'s compiled default, `none`, stores nothing but still advertises
resumption to the client.

**And there is no backup.** `ACCEPTED_RISKS.md` AR-13 and `ops/RUNBOOK.md` §9 record
that a restore has never been drilled, because there was nothing to restore from.
This is the one thing on the list that is not a leak: `user_id` is inside every
signed device bundle, so a lost database is not a lost account list — it is a **new
identity for every account**, and a fresh SAS or QR verification with every contact,
performed during whatever incident took the database. Everything else on this host is
replaceable: the code is in git, the wheels are vendored on the host, the TLS pair is
reissued from the offline CA, and the queue is seven days of ciphertext that expires
on its own.

## Decision

### 1. The logging posture is written down, all of it, and read back

`ops/postgres/README.md` names ten settings with the reason for each. Two are not
already a PostgreSQL default and are the posture itself: `log_min_error_statement =
panic`, which is the level above every level a statement is ever logged at, and
`log_error_verbosity = terse`, which drops the `DETAIL`, `HINT`, `QUERY` and
`CONTEXT` lines. The other eight — `log_statement`, `log_min_duration_statement`,
`log_min_duration_sample`, `log_duration`, `log_connections`, `log_disconnections`,
`log_lock_waits` and `log_min_messages` — are stated at their defaults, because a
default is not a decision: an operator's earlier edit, a restored `postgresql.conf`
or a package upgrade moves one silently, and nothing in this repository would report
it.

`ops/audit/postgres_posture.sh` reads all ten off the running server through `psql`,
names every difference on its own line, and exits 1. `ops/RUNBOOK.md` §8 runs it after
every deploy, which is the only thing that reports the posture having drifted.

### 2. The queue table reclaims its dead tuples in minutes

`messaging.0006_reclaim_the_queue_promptly` sets
`autovacuum_vacuum_scale_factor = 0.01` and `autovacuum_vacuum_threshold = 100` on
`messaging_queuedenvelope`. The trigger falls from 40 050 dead tuples to 2100 at the
200 000-row shape, and to 100 on an empty table.

The migration is one `RunSQL`, reversible by `RESET`, and it takes SHARE UPDATE
EXCLUSIVE — it blocks no reader and no writer.

**What this bounds is the window, not the residue.** A vacuum returns the space to
the free space map; the bytes are overwritten by the insert that takes it, and this
deployment zeroes no page. `backend/SECURITY.md` gains that as residual risk, together
with the write-ahead log, which holds the same row twice and which nothing here
shortens. Zeroing pages on a schedule is rejected rather than deferred
(`REJECTED_PROPOSALS.md` 17).

### 3. The host holds no dump and no resumable session

`chat.service`, `chat-maintenance.service` and `chat-backup.service` each set
`LimitCORE=0`. A single value sets the soft and the hard limit together, so the
process cannot raise it back, and the kernel produces no core whatever
`kernel.core_pattern` says.

The nginx TLS block sets `ssl_session_tickets off` and `ssl_session_cache off`. The
cost is one full handshake per connection, which this deployment can afford in a way
a public web host cannot: one Android client holding one long-lived socket, not a
browser opening a connection per asset.

`ops/RUNBOOK.md` §1 gains two operator-set items and says plainly that they are
unverifiable from this repository — no swap on the host, or swap on a random-key
device that never survives a boot; and `fs.suid_dumpable = 0`.

### 4. A daily identity backup, encrypted to a key this host does not have

`ops/backup/identity_backup.sh` dumps eight tables — `accounts_user`,
`accounts_profileblob`, `devices_useridentity`, `devices_device`,
`devices_onetimeprekey`, `devices_pqonetimeprekey`, `devices_devicelogrecord` and
`vault_keybackup` — and pipes them straight into `age`, encrypted to
`/etc/chat/backup.pub`. The private half is generated with `age-keygen` on the
operator's own machine and never exists on the VPS, so root here writes files it
cannot read.

**Nothing else is dumped, and that is the decision.** No queue row, no attachment row,
no attachment byte, no admin audit row, no session. A backup of any of those is a
second copy of exactly the rows `backend/SECURITY.md` bounds by retention, kept for
seven days in a directory the retention sweep does not reach.

`age` rather than `gpg`, on a verified fact rather than a preference: Ubuntu 24.04
(noble) packages `age` 1.1.1-1ubuntu0.24.04.3 in universe, providing `/usr/bin/age`
and `/usr/bin/age-keygen`, checked against the Ubuntu package index on 2026-09-06. It
is a single static binary with one file format, no keyring, no agent and no trust
model to configure — where `gpg` would put a keyring and its state on the host that
the design is protecting.

The output is `identity-<YYYY-MM-DD>.sql.age`, mode 0600, owned by `deploy`, under
`/srv/chat/backups/`, and the script keeps the newest seven by the ISO date in the
name. `chat-backup.timer` fires daily with a randomised delay of up to thirty minutes
and `Persistent=true`; `chat-backup.service` carries the maintenance unit's hardening
and may write the backup directory alone.

The dump is `--data-only`: a restore is `migrate` and then the file, so the schema
comes from the migration history of the release being restored, which is the only
schema that release can serve against. `ops/RUNBOOK.md` §11 carries the procedure and
the drill, and says the first restore is rehearsed **before the first serving deploy**
rather than during the incident that needs it.

## Position fields

- **Forcing function.** The threat model accepts an adversary with live root, and
  bounds a disk copy as a weaker one. Four things on this host wrote for that weaker
  adversary and nothing in the repository said so: a failing statement's text, a
  deleted row's bytes, a core dump's address space, and a session ticket key. The
  fifth item is the opposite forcing function — the one asset whose loss the design
  cannot absorb, protected by nothing at all.
- **Scale band.** Band 0, holding through band 2. The logging posture and the TLS
  posture cost nothing that scales. The autovacuum trigger is a rate, and a vacuum of
  2100 dead tuples on this table is milliseconds. The backup is eight tables of fewer
  than 50 accounts at up to 10 devices each — 13 936 bytes for one account with one
  device, measured — so seven of them is a directory of kilobytes.
- **Flip trigger.** For the logging posture: a production incident that cannot be
  diagnosed without a statement, at which point the widening is deliberate, temporary
  and logged as such — and it puts statements on disk for as long as it lasts. For the
  autovacuum values: a measured vacuum cost on the queue that competes with the send
  path, which at one worker on one vCPU is the thing to watch. For the TLS posture: a
  second client class that opens many short connections, which today does not exist
  ([0020](0020-one-android-client-and-no-browser-surface.md)). For the backup: a
  second operator, at which point who holds the private key stops being one person's
  decision.
- **Cost.** The logging posture costs the two diagnostics it removes: a failing
  statement's text, and the `DETAIL` that says which key values collided. An operator
  debugging a constraint violation gets the constraint name and reproduces against a
  scratch copy — which is the same discipline `manage.py prune` already follows. The
  TLS posture costs one full handshake per connection. `LimitCORE=0` costs the core
  dump of a crash that a traceback does not explain. The autovacuum parameters cost
  more frequent vacuums on the largest table in the schema, and they buy a window and
  not an erasure. The backup costs a key the operator must not lose — a backup whose
  private key is gone is not a backup — and it puts seven files on the host whose
  count, sizes and dates a seizure reads, which `backend/SECURITY.md` now states.
- **Evidence.** Every claim above was measured on this run rather than argued. The
  log posture: a duplicate insert wrote three lines under the defaults and one under
  the posture, read from the server's own log file either side. The autovacuum values:
  two 200 000-row tables of the queue's shape, 3000 rows deleted from each — the stock
  one took no autovacuum in 150 s and still held 3000 dead tuples, the tuned one
  vacuumed within 60 s and held none; relation size unchanged on both, which is the
  measured limit of what this buys. The migration's lock: SHARE UPDATE EXCLUSIVE read
  from `pg_locks` while the transaction held it, with `relfilenode` unchanged either
  side of a 200 000-row table. The backup: the dump ordered by pg_dump's own
  foreign-key sort, restored into a separately migrated scratch database with
  `ON_ERROR_STOP=on`, and asserted at the application level — the same `user_id`, the
  same device id, and `check_password` still true — with the queue and attachment
  tables restored empty. All of it in
  [`GROUND-TRUTH.md`](../GROUND-TRUTH.md) §4. **What is not evidence:** the `age` hop
  itself has never run, because the developer machine carries none; `ACCEPTED_RISKS.md`
  AR-20 records that and its trigger. **Currency:** current.

## Consequences

- `ACCEPTED_RISKS.md` gains AR-20: the backup has never run on a host and no encrypted
  file has ever been decrypted, with the first `chat-backup.service` run and its
  restore drill as the trigger. AR-13 is unchanged — the rollback is a separate
  untried procedure.
- `backend/SECURITY.md` gains two things: the encrypted backups in the seizure yield,
  with their count, sizes and dates named as what a seizure learns from them; and the
  residual-risk item for a deleted row in free space and in the WAL.
- `REJECTED_PROPOSALS.md` is new at the repository root, with nineteen entries and no
  other content, and `README.md` lists it in the document table. Three of its entries
  are reopened by the same event — a disk-copy adversary becoming the primary
  adversary — which is the boundary this run's decisions were made against.
- `core/tests/test_migrations.py` admits `RunSQL` for the first time, and `ALTER TABLE
  … SET (` as an alteration form. Neither is a blanket admission, and the second one
  cost a repair: the statement gate asked whether an *allowed* form was present, which
  was sufficient while every operation was one Django wrote — one action per statement.
  Raw SQL can write `ALTER TABLE t DROP COLUMN c, SET (…)`, which carries an admitted
  form and a table rewrite in the same statement and passed. `FORBIDDEN_ALTERATIONS`
  names the rewriting forms directly, and the compound statement now fails both that
  gate and the lock probe.
- `ops/tests/test_scripts.py` reads content for the first time rather than syntax
  alone. The backup's eight tables and its two exclusions are together every table
  this project declares a model for, so a model added in a later phase fails there
  until somebody decides which side it belongs on.
- The two operator-set items of decision 3 — swap, and `fs.suid_dumpable` — are
  written down and enforced by nothing. `ops/RUNBOOK.md` §1 says so in those words.
  They are the only claims in this run that no test can fail on.
- `chat-backup.timer` must not be enabled before `/etc/chat/backup.pub` exists, or the
  unit fails on every fire. The runbook orders it that way, and the script exits 1
  before `pg_dump` runs rather than falling back to an unencrypted dump.
