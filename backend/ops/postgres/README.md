# PostgreSQL setup

PostgreSQL 16, self-hosted, **listening on localhost only**. The same setup serves
development and production.

## One-time database and role

Run as a superuser (`psql -d postgres`):

```sql
-- Generate the password with:
--   python -c "import secrets; print(secrets.token_urlsafe(64))"
CREATE ROLE chat WITH LOGIN CREATEDB PASSWORD 'replace-me-with-a-generated-secret';
CREATE DATABASE chat OWNER chat;
```

`CREATEDB` is granted because `pytest-django` creates and drops a `test_<name>`
database on every run. On a production host you may drop the attribute after the last
test run:

```sql
ALTER ROLE chat NOCREATEDB;
```

Put the same credentials in the env file (`.env` in development,
`/srv/chat/backend/.env.production` on the VPS) as `POSTGRES_DB`, `POSTGRES_USER`
and `POSTGRES_PASSWORD`.

## Recreate the database before the first migrate of this version

The migration history was regenerated: each app now holds one `0001_initial` and
every earlier file is gone. A database that recorded the old history cannot be
migrated onto the new one, because Django matches a migration by `(app, name)`
and the names it recorded no longer exist.

**Drop and recreate `chat` before the first `migrate` of this version.** No user
depends on stored data — there is no production deployment yet, and
[`docs/architecture/GROUND-TRUTH.md`](../../../docs/architecture/GROUND-TRUTH.md)
records the zero-account precondition that makes this safe. It is available
exactly once, before the first real account exists.

```sql
-- as a superuser, with the application stopped
DROP DATABASE IF EXISTS chat;
CREATE DATABASE chat OWNER chat;
```

Then run `python manage.py migrate` once. A developer machine takes the same
step for its own database.

From the next phase on the history is append-only and every change ships as
expand and contract. This is the last time the history is rewritten.

## Bind to localhost only

Nothing outside the VPS ever talks to the database. In `postgresql.conf`:

```
listen_addresses = 'localhost'
```

and in `pg_hba.conf` allow only local connections with password auth:

```
local   all   all               scram-sha-256
host    all   all   127.0.0.1/32   scram-sha-256
host    all   all   ::1/128        scram-sha-256
```

Reload with `pg_ctl reload` (or `systemctl reload postgresql`).

## The logging posture

**PostgreSQL is the one layer of this deployment that writes request data to disk by
default.** uvicorn runs with `--no-access-log`, nginx with `access_log off` and
`error_log … crit`, and the application's own loggers name no identifier
([ADR-0019](../../../docs/architecture/decisions/0019-the-system-emits-no-request-scoped-telemetry.md)).
The database was the hole in that: at the stock `log_min_error_statement = error`
every statement that fails is written to the server log in full, and a statement of
this schema carries device ids, envelope ids, capability ids and bucketed ciphertext.

Measured on PostgreSQL 16.14 against a mailbox-shaped table, one duplicate insert
under the stock settings wrote three lines:

```
ERROR:  duplicate key value violates unique constraint "queue_device_seq_key"
DETAIL:  Key (device, seq)=(11111111-1111-1111-1111-111111111111, 7) already exists.
STATEMENT:  INSERT INTO queue VALUES ('11111111-1111-1111-1111-111111111111', 7, '\xdeadbeef');
```

and under the settings below it wrote the first line and nothing else.

Set these in `postgresql.conf` and reload. **Every value is stated, including the ones
that are already a default**, because a default is not a decision: an operator's
earlier edit, a restored configuration file or a package upgrade moves one silently,
and nothing in this repository would report it.

| Setting | Value | Default | Why |
|---|---|---|---|
| `log_min_error_statement` | `panic` | `error` | The one setting here that is not already its default, and the reason the rest are written down. `PANIC` is the highest level there is and a `PANIC` takes the cluster down with it, so in practice no failing statement is ever logged |
| `log_error_verbosity` | `terse` | `default` | `default` adds the `DETAIL`, `HINT`, `QUERY` and `CONTEXT` lines. `DETAIL` on a unique violation names the conflicting key values — a device id and a sequence number, measured above — and it is attached to the error whatever `log_min_error_statement` says about the statement |
| `log_statement` | `none` | `none` | `ddl`, `mod` and `all` write statement text for every matching statement, failing or not |
| `log_min_duration_statement` | `-1` | `-1` | A statement slower than the threshold is logged with its text. A latency question on this host is answered from `pg_stat_statements` on a scratch copy, never from a log line on the serving box |
| `log_min_duration_sample` | `-1` | `-1` | The second path to the same text: a positive value logs a `log_statement_sample_rate` share of the statements above it |
| `log_duration` | `off` | `off` | A timing line for every statement. It carries no text on its own, but it is a per-statement record of when the one application talked to the database |
| `log_connections` | `off` | `off` | A connection line names the client address, the role and the database. Everything here connects over loopback, so what it records is the connection pattern of the one process |
| `log_disconnections` | `off` | `off` | The same line with the session duration on it |
| `log_lock_waits` | `off` | `off` | A record that a named relation was contended, kept on disk. The same question is answered from `pg_stat_activity` while the wait is happening, which is what [`../RUNBOOK.md`](../RUNBOOK.md) §10 already directs an operator to |
| `log_min_messages` | `warning` | `warning` | Below `warning` the server writes `NOTICE`, `INFO` and the `DEBUG` levels, and the debug levels carry query and plan detail |

Reload with `pg_ctl reload` (or `systemctl reload postgresql`), then read the posture
back off the running server:

```sh
bash ops/audit/postgres_posture.sh
```

It exits 0 when every setting above is the running one, and names each difference and
exits 1 otherwise. [`../RUNBOOK.md`](../RUNBOOK.md) §8 runs it after every deploy.

**What this does not do.** It stops the statement text of a failure reaching disk; it
does nothing about the rows themselves. A deleted row stays in the free space of a
data file until that space is reused, and in a WAL segment until the segment is
recycled — [`../../SECURITY.md`](../../SECURITY.md) carries that as residual risk, and
the storage parameters `messaging.0006_reclaim_the_queue_promptly` sets on the queue
table are what bound how long the first half of it lasts.

## Extensions

**None.** No extension beyond a default PostgreSQL 16 install is required. Every
column this backend uses is a stock type — `uuid`, `bytea`, `date`, `bigint`,
`varchar`, `boolean`. Do not add extensions "just in case"; each one widens the
attack surface of a machine that is meant to hold nothing readable.

## What a dump of this database contains

Opaque ciphertext blobs in fixed size buckets, public keys, Argon2id password hashes,
the user list, and coarse (day- or hour-granularity) timestamps. No message content,
no content keys, and no sender↔recipient graph.
