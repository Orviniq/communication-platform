# Operator runbook

The sequence that puts this backend onto the VPS, and the sequence that takes a
release off it again. One host, one operator, in-place deploys, and a
maintenance window whenever the operator wants one — there is no second host to
roll through and nothing to drain to.

**This file routes; it does not repeat.** Every step names the note that owns its
detail, and the note is authoritative wherever the two could differ. The notes:

| Subject | Owner |
|---|---|
| PostgreSQL role, database, `pg_hba.conf`, the recreation rule, and the logging posture | [`postgres/README.md`](postgres/README.md) |
| The private CA, the server pair, and the client SPKI pins | [`tls/README.md`](tls/README.md) |
| Redis posture | [`redis/redis-chatapp.conf`](redis/redis-chatapp.conf) |
| The units, their hardening, and every uvicorn flag | [`systemd/`](systemd/) |
| What the identity backup dumps, what it never dumps, and how it is encrypted | [`backup/identity_backup.sh`](backup/identity_backup.sh) |
| The nginx site, its per-location caps and its header ownership | [`nginx/`](nginx/) |
| The coturn relay: its listener, its quotas, its denied peers and its silence | [`coturn/turnserver.conf`](coturn/turnserver.conf) |
| Every environment variable and what it does | [`../README.md`](../README.md) §Configuration, [`../.env.example`](../.env.example) |
| The threat model these steps serve | [`../SECURITY.md`](../SECURITY.md) |

**No secret value appears in this file, and none may be added to it.** Every
secret is generated on the host and written only into the environment file of
step 5. Where a step needs one, it names the variable and never a value.

**What has and has not been exercised.** Steps 1 to 7 have never run against a
real VPS: this repository has no serving host yet, and every claim about the
host is what the committed configuration sets rather than what a machine
reported. The rollback of step 9 has never been executed, which
[`../../ACCEPTED_RISKS.md`](../../ACCEPTED_RISKS.md) records as AR-13 with the
trigger that ends it. The backup of step 11 has never run on a host either, and
AR-20 records what that leaves open — but its restore *has* been drilled, against a
scratch database on a developer machine, and step 11 gives the procedure that was
run. Read this file as the plan it is, and record what actually
happens in [`../../docs/architecture/GROUND-TRUTH.md`](../../docs/architecture/GROUND-TRUTH.md)
the first time it runs.

Run every command from `/srv/chat/backend` unless a step says otherwise. Where a
step runs a management command, it uses this form, which is the same
`set -a; . …; set +a` convention [`../README.md`](../README.md) documents for
development:

```sh
as_deploy() {
    sudo -u deploy sh -c \
        'cd /srv/chat/backend && set -a && . ./.env.production && set +a && exec "$@"' _ "$@"
}
```

`sudo -u deploy` gives the command the deploy account's full group set, which is
what lets it read the environment file of step 5.

---

## 1. One-time host setup

The host is one VPS with 1 vCPU and 1 GB of RAM, shared with two other projects
of the same operator. Everything below listens on loopback except nginx and
coturn.

1. **Packages.** `python3.12` with `python3.12-venv`, `postgresql-16`, `redis`
   (7.x), `nginx`, `coturn` and `age`. coturn is the only media service on this host
   ([ADR-0021](../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md));
   `age` is what encrypts the identity backup of step 11, and Ubuntu 24.04 packages
   it in universe.
2. **The service account.** A `deploy` user with a group of its own, additionally
   a member of `www-data`, with no login shell. Every unit runs as that user with
   `Group=www-data`, so files the process creates are group-readable by nginx.
3. **The tree.**

   ```sh
   install -d -o deploy -g www-data -m 0750 /srv/chat
   sudo -u deploy git clone https://github.com/Orviniq/communication-platform /srv/chat
   install -d -o deploy -g www-data -m 0750 /srv/chat/backend/media_root
   install -d -o deploy -g www-data -m 0750 /srv/chat/backend/static_root
   install -d -o deploy -g deploy    -m 0700 /srv/chat/backups
   ```

   `media_root` is the only path the serving unit may write, and `static_root`
   is deliberately not among them: `collectstatic` is the operator's command and
   nginx serves the result, so a compromised process cannot replace the panel's
   own JavaScript ([`systemd/chat.service`](systemd/chat.service)). `backups` is
   `deploy`-only and not group-readable, because nginx has no business reading it
   and the group is what nginx is in; it is the only path the backup unit of step 11
   may write, and no other unit may write it at all.
4. **The firewall.** Inbound: 80 and 443/tcp (nginx), 3478/udp and 3478/tcp
   (coturn), and 50000–51000/udp (the coturn relay range). Nothing else — there
   is no TLS listener on coturn and no SFU, so 5349 and the LiveKit ports of the
   previous release are closed. PostgreSQL, Redis, and uvicorn are loopback-only
   and must not be reachable from outside the host.
5. **Redis.** Copy [`redis/redis-chatapp.conf`](redis/redis-chatapp.conf) into
   the host's Redis configuration and uncomment `requirepass` with a generated
   value. The same value goes into `REDIS_URL` in step 5. It is not optional:
   `manage.py check --deploy` refuses a `REDIS_URL` with no password
   (`core.E004`), so a deployment cannot forget it.
6. **PostgreSQL.** Follow [`postgres/README.md`](postgres/README.md) — the role,
   the database, `listen_addresses`, `pg_hba.conf`, and **the logging posture**. That
   last one is the setting no other layer of this deployment can compensate for: at
   the stock `log_min_error_statement` a failing statement is written to the server
   log with its bind parameters, which on this schema are device ids and ciphertext.
   Come back here for step 3.
7. **Swap.** Either none at all, or a swap device with a random key that does not
   survive a boot — `/dev/urandom` as the key source in `/etc/crypttab`, with the
   `swap` option, so the device is re-keyed on every start. Swap is a copy of process
   memory on disk, and the memory of these processes holds the JWT signing key, the
   TURN shared secret and whatever plaintext routing metadata is in flight. A 1 GB
   host with `WEB_CONCURRENCY=1` is sized to run without swap
   ([A3](../../docs/architecture/DESIGN-RECORD.md)); the encrypted-device form exists
   for the operator who wants the safety margin anyway.
8. **Core dumps.** `fs.suid_dumpable = 0` in `/etc/sysctl.d/`, which is the kernel
   default and is written down for the same reason the PostgreSQL defaults are: a
   default is not a decision. The units set `LimitCORE=0` of their own
   ([`systemd/`](systemd/)), so none of the three processes that hold secrets can
   produce a dump whatever the host's `DefaultLimitCORE=` resolves to.

Items 7 and 8 above are **operator-set and unverifiable from this repository**. Nothing in
the tree reads a host's swap table or its `sysctl` values, and no test here can fail
when one of them changes. They are written down so the decision exists, not because
anything enforces it.

---

## 2. Vendor the wheels while the network is up, then install offline

The system must install and reinstall with no internet
([ADR-0012](../../docs/architecture/decisions/0012-pinned-hashed-and-untracked-wheel-cache.md)).
The wheel cache is per-platform and per-interpreter, so it is built **on the
VPS** — a set downloaded on a developer machine will not install on it.

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
bash ops/vendor.sh            # needs the network; writes vendor/wheels/
bash ops/offline_install.sh   # needs no network; rebuilds .venv from that cache
```

`vendor.sh` downloads with `--require-hashes --only-binary=:all:`, which refuses
a source distribution: the VPS has no compiler and, when it matters, no network
to fetch a build backend with. `offline_install.sh` installs with `--no-index
--require-hashes`, so pip reaches no index at all and a wheel that is missing or
tampered with fails the install loudly.

Re-run `vendor.sh` after **any** change to `requirements/`, while the network is
still available. `vendor/wheels/` is not tracked in git.

For a release record, `bash ops/gen_sbom.sh` writes a CycloneDX 1.6 document of
the pinned production set to `ops/sbom.prod.json`. It is derived from
`requirements/prod.txt`, so it is not committed — regenerate it with the release
it describes and keep it beside the artefact.

---

## 3. The database, and the recreation rule of this version

Create the role and the database as [`postgres/README.md`](postgres/README.md)
describes.

**Then, once, before the first `migrate` of this version: drop and recreate the
database.** The migration history was regenerated — each app holds one
`0001_initial` and every earlier file is gone
([ADR-0009](../../docs/architecture/decisions/0009-regenerate-the-initial-migrations.md))
— and Django matches an applied migration by `(app, name)`, so a database that
recorded the old names cannot be migrated onto the new history. The recreation
command is in [`postgres/README.md`](postgres/README.md) under "Recreate the
database before the first migrate of this version".

Three things about that step:

- **It is destructive DDL, and it is available exactly once.** The precondition
  is zero production accounts, recorded in
  [`GROUND-TRUTH.md`](../../docs/architecture/GROUND-TRUTH.md). Read that
  precondition before running it, not after. Once one real account exists the
  step is gone, and any future history change is expand and contract instead.
- **From the next release the history is append-only.** This is the last time
  the history is rewritten.
- **It is a stop, not a step.** A drop of a database that might hold data is
  never run on a verdict alone. Confirm the precondition, then run it
  deliberately, with the application stopped.

---

## 4. `migrate` and `collectstatic`

Both run as `deploy`, with the environment file of step 5 already in place.

```sh
as_deploy .venv/bin/python manage.py migrate
as_deploy .venv/bin/python manage.py collectstatic --noinput
```

`migrate` runs once per release, from here, and never from a unit or a boot
hook: one process applies the schema, and the code that reads it starts
afterwards.

A database that applied `voicerooms.0001_initial` and `0002_delete_room` keeps
both rows in `django_migrations` after the app left the tree; they are records of
migrations that already ran, `migrate` never looks for the files again, and
deleting them would only make the ledger disagree with what the database was
built from.

`collectstatic` is the step that fails quietly. Nothing raises without it — the
panel simply renders with no styling at all, because nginx serves `static_root`
in production and Django serves nothing. Run it on **every** deploy that changes
a dependency, since django-unfold ships the panel's whole asset set (its
stylesheet, Alpine, Chart.js, htmx, and the Inter and Material Symbols fonts) and
a version bump replaces those files.

---

## 5. The environment file and its permissions

Copy [`../.env.example`](../.env.example) to `/srv/chat/backend/.env.production`
and fill it. `DJANGO_SETTINGS_MODULE=config.settings.prod`. Generate every secret
on the host, one at a time:

```sh
.venv/bin/python -c "import secrets; print(secrets.token_urlsafe(64))"
```

Five values are generated that way and shared with nothing else:
`DJANGO_SECRET_KEY`, `JWT_SIGNING_KEY`, `POSTGRES_PASSWORD`, the password inside
`REDIS_URL`, and `TURN_STATIC_AUTH_SECRET`. Each is an infrastructure secret;
none of them can decrypt a message, because no content key ever reaches this
server. `TURN_STATIC_AUTH_SECRET` is read by the backend as well from this
release: the backend signs a relay credential under it, and coturn verifies that
credential under `static-auth-secret` in step 7. The two copies are one value and
must be the same string — a mismatch is a relay that refuses every allocation,
and check 10 of step 8 is what catches it.

`TURN_URLS` beside it is what serves voice at all. Left empty,
`POST /api/v1/me/relay` answers `503 voice_unconfigured` and no client can place
a call; filled, it is what makes `check --deploy` weigh the secret above and
refuse one under 32 characters (`core.E005`).

Then:

```sh
chown root:deploy /srv/chat/backend/.env.production
chmod 0640 /srv/chat/backend/.env.production
```

`root:deploy` and `0640`, and both halves matter. The units never read this file
themselves: systemd reads `EnvironmentFile=` as root, in PID 1, and hands the
values to the process after it drops privileges — which is why root ownership
costs the service nothing and keeps the file writable only by the operator. The
`deploy` group is for the `as_deploy` commands above, which do read it. No other
account on this shared host can.

The values still reach the process as environment variables, which systemd's own
documentation calls unsuitable for secrets. `LoadCredential=` is the alternative
and it would need the settings layer to read files instead of `os.environ`. That
is not a change this run makes; AR-14 in
[`../../ACCEPTED_RISKS.md`](../../ACCEPTED_RISKS.md) carries it with its
trigger.

`.env.production` is never committed. `.gitignore` excludes `.env.*`, and the
only file of that family in the repository is the example.

Two settings are one setting in two places, and changing either alone breaks the
panel: `ADMIN_PATH` here and the matching `location` in
[`nginx/chat.nimashadloo.dev.conf`](nginx/chat.nimashadloo.dev.conf). Pick a
non-obvious path and change both.

---

## 6. The units, nginx, and TLS

**TLS first**, because nginx will not start without the pair.
[`tls/README.md`](tls/README.md) owns the private CA: generate it off the host,
keep `ca.key` offline, and install **only** `server.crt` and `server.key` at
`/etc/chat/tls/`, root-owned and unreadable by anyone else. The clients pin the
SPKI of that key and of a backup key, so a rotation without a shipped backup pin
locks every device out permanently — read that file before generating anything.

**The units.**

```sh
install -m 0644 ops/systemd/chat.service /etc/systemd/system/
install -m 0644 ops/systemd/chat-maintenance.service /etc/systemd/system/
install -m 0644 ops/systemd/chat-maintenance.timer /etc/systemd/system/
install -m 0644 ops/systemd/chat-backup.service /etc/systemd/system/
install -m 0644 ops/systemd/chat-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now chat.service chat-maintenance.timer chat-backup.timer
```

`chat-maintenance.service` and `chat-backup.service` are never enabled at all: their
timers start them. See steps 10 and 11.

**Enable `chat-backup.timer` only after step 11**, which installs the public key it
encrypts to. Without `/etc/chat/backup.pub` the script exits 1 and the unit enters a
failed state on every fire.

**nginx.** The site and the snippet it includes both ship here, and the snippet
is not optional — it carries `X-Forwarded-Proto`, which is the header
`SECURE_PROXY_SSL_HEADER` trusts, and `proxy_hide_header
Strict-Transport-Security`, which is what leaves exactly one owner for that
header.

```sh
install -d -m 0755 /etc/nginx/snippets
install -m 0644 ops/nginx/chat.nimashadloo.dev.conf /etc/nginx/sites-available/
install -m 0644 ops/nginx/snippets/proxy-headers.conf /etc/nginx/snippets/
ln -sf /etc/nginx/sites-available/chat.nimashadloo.dev.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

`nginx -t` is the gate; never reload without it.

Two properties of that site are worth knowing before changing it, because both
fail silently:

- **Every location states its own `client_max_body_size`**, equal to the largest
  body that location admits, and the server block's value is the deny-by-default
  for a path that matches none. The `/api/` cap and `BODY_CAP_BATCH_BYTES` are
  one number in two places; so are the `/admin/` cap and `BODY_CAP_JSON_BYTES`.
  Raise one without the other and nginx either refuses a body the routes accept
  or carries one they refuse.
- **`add_header` inside a location replaces every inherited one.** nginx owns
  `Strict-Transport-Security` for the whole host, because it is the only layer
  that sees every response — the proxied ones, the files it serves from disk, and
  its own 404 and 413. The application owns `X-Content-Type-Options`,
  `Cache-Control` and `Referrer-Policy` on everything it answers. `/static/`
  reaches no application, so nginx supplies its `nosniff` and repeats HSTS
  beside it.

---

## 7. coturn

coturn is the only media service on this host. It relays SRTP between two client
devices and cannot open a packet: the keys of a voice connection are established
by DTLS between its two endpoints and exist nowhere else
([ADR-0021](../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)).

Voice is served by this revision, and this relay is the whole of its media path.
`POST /api/v1/me/relay` mints the credential a client presents here, signing it
under the same secret this file carries as `static-auth-secret`. A deployment
that leaves `TURN_URLS` empty serves no voice and can skip this step; one that
fills it needs coturn running before the first call, because the route mints a
credential whether or not a relay is listening for it.

```sh
install -d -m 0755 /etc/chat
install -o root -g turnserver -m 0640 ops/coturn/turnserver.conf /etc/chat/turnserver.conf
# The packaged coturn unit reads /etc/turnserver.conf. Point it at the file
# above rather than editing the packaged unit, which a package upgrade replaces.
mkdir -p /etc/systemd/system/coturn.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/turnserver -c /etc/chat/turnserver.conf\n' \
    > /etc/systemd/system/coturn.service.d/config-path.conf
systemctl daemon-reload && systemctl enable --now coturn.service
```

Check that the drop-in took before trusting it — a coturn reading the packaged
default answers with the wrong realm and no shared secret, and it fails at the
first client rather than at start:

```sh
systemctl show coturn.service -p ExecStart | grep -c /etc/chat/turnserver.conf   # 1
```

- **coturn cannot read environment variables, and a command-line flag would put
  the secret in world-readable `/proc/*/cmdline`.** So `realm=` and
  `static-auth-secret=` are filled inline in `/etc/chat/turnserver.conf`, from
  the `TURN_REALM` and `TURN_STATIC_AUTH_SECRET` values of the environment file,
  and the file is given the same trust boundary as `.env.production`. Set
  `listening-ip`, `relay-ip` and the `denied-peer-ip=YOUR_VPS_IP` entry to the VPS
  address; never a wildcard.
- **coturn has no TLS listener and no certificate.** The hop it carries is
  already SRTP that the relay cannot open, so a TLS or DTLS listener would buy
  nothing and would put a certificate and a renewal on a box whose posture is to
  hold neither. `no-tls` and `no-dtls` are set and there is no
  `tls-listening-port`, which is why the firewall list of step 1 has no 5349.
- **coturn writes no log, on disk or in the journal.** A TURN log line names the
  relay peer pair, which is two devices in one call, and invariant 4 refuses that
  record at every layer. The file sets `no-stdout-log`, `simple-log` and
  `log-file=/dev/null`. That is deliberate: a relay problem is diagnosed by
  raising the level temporarily and lowering it again, never by leaving it raised.
- **The peer deny list is what keeps the relay from being a pivot, and one
  entry that is *not* in it is why voice connects at all.** The file denies the
  loopback, private and link-local ranges, and denies the host's own address
  beside them: without that last line an allocation may name this box as its
  peer, which makes the relay an on-host proxy into nginx (AR-6). What must never
  be added is `denied-peer-ip=::`. coturn stores a single address as a range
  whose min and max are that address, and its `ioa_addr_in_range` matches every
  address when the max is the all-zero "any" address — so that one line denies
  every peer of every family, IPv4 included, and no call ever connects. Measured
  against coturn 4.17.2 on 2026-09-05: with the line present a relay bind to an
  IPv4 peer was refused `403` and the relay logged `A peer IP 192.168.0.102
  denied in the range: ::`; with it removed the same bind succeeded. The 4.6.1
  that Debian bookworm and Ubuntu noble install carries the identical matcher.
- **The quotas are the ceiling on this band, not a tuning knob.** `user-quota=20`
  is one device in a ten-participant mesh with headroom for an ICE restart;
  `total-quota=500` is five such rooms at once; the relay port range 50000–51000
  is wider than the total so the quota is what binds. Raising either without
  widening the range gives a relay that runs out of ports instead of refusing an
  allocation.

---

## 8. Verify a deploy

Run all of these, in order, after every deploy. Each one asserts on what came
back; none of them is satisfied by an absence of errors.

```sh
# 1. The process is up and stayed up.
systemctl is-active chat.service coturn.service     # active, active
systemctl show chat.service -p NRestarts
# Unchanged since before the deploy. A number that climbs while you watch is a
# process that boots and dies; `journalctl -u chat.service -n 50` says why.

# 2. Posture, under the settings the process actually runs.
as_deploy .venv/bin/python manage.py check --deploy
# exit 0 and no core.E / core.W. A finding here is a release defect.

# 2b. The PostgreSQL logging posture, read back off the running server.
#     Nothing in this repository sets it and no test can fail when it moves, so
#     this is the only thing that reports an operator's earlier edit, a restored
#     postgresql.conf or a package upgrade having changed it.
as_deploy bash ops/audit/postgres_posture.sh
# "PASS: 10 settings, all as ops/postgres/README.md sets them." and exit 0.
# Each difference is named on its own line and the exit status is 1. A DIFFERS on
# log_min_error_statement or log_error_verbosity means failing statements are
# reaching /var/log/postgresql with their bind parameters: fix it before anything
# else on this list.

# 3. The schema matches the code that is serving. It opens the database, so a
#    pass is also the proof that PostgreSQL answers with these credentials.
as_deploy .venv/bin/python manage.py migrate --check

# 4. Liveness, through the edge, end to end.
curl -sS -o /dev/null -w '%{http_code}\n' https://chat.nimashadloo.dev/api/v1/health
# 200

# 5. The edge is answering, and the error envelope is this API's.
curl -sS https://chat.nimashadloo.dev/api/v1/nope
# {"code": "not_found", ...} — Django's HTML 404 here means the mount is wrong.

# 6. Exactly one Strict-Transport-Security header, on a proxied path and on a
#    path nginx serves itself.
curl -sSI https://chat.nimashadloo.dev/api/v1/health | grep -ci strict-transport
curl -sSI https://chat.nimashadloo.dev/static/admin/css/base.css | grep -ci strict-transport
# 1 and 1. A 2 is a second owner; a 0 on the static path is the add_header
# inheritance rule biting.

# 7. The panel renders styled — collectstatic ran and nginx serves the result.
#    ADMIN_PATH is in .env.production, so read it from there rather than typing it.
as_deploy sh -c 'curl -sSI "https://chat.nimashadloo.dev/${ADMIN_PATH}" | head -1'
curl -sS -o /dev/null -w '%{http_code}\n' https://chat.nimashadloo.dev/static/unfold/css/styles.css
# 200 for the stylesheet. A 404 is an empty static_root.

# 8. Redis answers, with the password the check above insisted on.
as_deploy sh -c 'redis-cli -u "$REDIS_URL" ping'     # PONG

# 8b. The Redis posture, read back off the running server, for the same reason as
#     2b: `ops/redis/redis-chatapp.conf` is what this repository can test, and a
#     server started before that file, edited by hand, or restarted by a package
#     upgrade is what actually holds the counters. No test can fail when the two
#     disagree.
as_deploy sh -c 'redis-cli -u "$REDIS_URL" config get maxmemory maxmemory-policy appendonly save'
# maxmemory 134217728, maxmemory-policy noeviction, appendonly no, save empty.
#
# `maxmemory 0` is the failure this check exists for: it is Redis's default, it is
# what an unconfigured server reports, and it means the store is unbounded on a
# host it shares with PostgreSQL. `maxmemory-policy` anything but `noeviction` is
# worse than unbounded — every key in this instance is a control, so an eviction is
# a rate limit or a login lockout silently resetting, where a refused write is a
# `503` the API already answers (ADR-0010). A non-empty `save` or `appendonly yes`
# puts the throttle counters, the login lockout and the fan-out bus on disk, which
# is invariant 6.

# 9. A stored attachment serves a byte range, so a client can resume a download.
#    Needs one capability id of an attachment that is still inside its TTL; take
#    it from the client that uploaded it, never from the database, because the id
#    IS the capability and reading it out is a download anyone can then perform.
#    The token is a full-scope session token of any account.
curl -sS -D- -o /dev/null \
    -H "Authorization: Bearer $token" -H 'Range: bytes=0-9' \
    "https://chat.nimashadloo.dev/api/v1/attachments/$capability"
# HTTP/1.1 206 Partial Content, with Content-Range: bytes 0-9/<bucket size> and
# Content-Length: 10. A 200 with the whole bucket means the internal location is
# not serving the file — X-Accel-Redirect fell through, and the application's own
# empty body is what came back. A 404 means the id is spent or mistyped.

# 10. coturn accepts a credential this backend minted. Skip only if TURN_URLS is
#    empty. `turnutils_uclient` ships with coturn. The secret itself is never
#    passed to it — the tool's own -W flag would put it in world-readable
#    /proc/*/cmdline, which is the reason step 7 keeps it out of coturn's own
#    command line — so the check mints one ephemeral credential through the same
#    code path the route uses and passes that. What lands in the argument list is
#    good for RELAY_CREDENTIAL_TTL_SECONDS and can decrypt nothing (AR-17).
read -r turn_user turn_pass <<EOF
$(as_deploy .venv/bin/python -c 'import django; django.setup(); from realtime import relay; c = relay.mint(); print(c["username"], c["credential"])')
EOF
turnutils_uclient -y -c -X -n 10 -l 100 -p 3478 -u "$turn_user" -w "$turn_pass" \
    "$(sed -n 's/^listening-ip=//p' /etc/chat/turnserver.conf)"
# `channel bind: error 403 ()` is the PASS, and it is the only pass this host can
# produce. A client reaches a channel bind only after an allocation, so that line
# says coturn authenticated the minted credential under its own copy of the
# secret; the bind behind it is then refused by this deployment's own
# denied-peer-ip entry for the host's own address, because -y makes the peer
# another relay address on this box. Two real devices never meet that entry.
# `ERROR Cannot complete Allocation` is the FAIL: coturn refused the credential,
# so the value in .env.production and the static-auth-secret in
# /etc/chat/turnserver.conf are not the same string.
# Neither line before the command gives up: nothing is answering on 3478. Check
# the unit, the drop-in of step 7, and the firewall rule of step 1.
```

Check 10 is the one check with no second source. The relay writes no log at all
(AR-15), so `journalctl -u coturn.service` will not confirm or contradict it: the
client's own output is the whole of the evidence, which is why the pass and the
fail above are distinguished by the line and never by the exit status — both of
them exit non-zero.

There is no readiness endpoint and no metric, by design
([ADR-0019](../../docs/architecture/decisions/0019-the-system-emits-no-request-scoped-telemetry.md)):
one host with an in-place deploy has no rotation to gate, and a request-scoped
log on this host would be the social graph the schema exists to exclude. AR-9 in
[`../../ACCEPTED_RISKS.md`](../../ACCEPTED_RISKS.md) carries what that costs and
the trigger that ends it. The checks above are what stands in its place, so
running all ten is not optional.

`journalctl -u chat.service` carries the process's own output. It holds no
request line, no path and no identifier — that is the invariant, not an
accident — so a fault shows as a traceback that names code and never data.

---

## 9. Roll back

**The rollback is a git checkout and a restart, and it has never been
executed** (AR-13). Read that entry before you need this section.

The trigger, decided here rather than during the incident: **any** check in
step 8 fails and is not fixed by the next command you would have run anyway. Do
not diagnose first. Restore the previous release, then diagnose.

Stated as "any" and not as a count. This sentence read "any of the nine checks"
while step 8 held twelve, because a number in prose is what rots first and
nothing here gates it — the trigger has to hold for the check that was added
after it was written.

```sh
# 0. Know where you are going back to, before you stop anything.
git -C /srv/chat log --oneline -5

# 1. Stop accepting. The drain window is 130 s and it is a ceiling, not a wait:
#    with nothing in flight the process exits at once.
systemctl stop chat.service

# 2. Restore the code.
git -C /srv/chat checkout <previous-release-sha>

# 3. Restore the dependency set only if it moved between the two releases.
bash ops/offline_install.sh

# 4. Restore the collected assets, for the same reason as step 4 above.
as_deploy .venv/bin/python manage.py collectstatic --noinput

# 5. Start, and run every check of step 8 again.
systemctl start chat.service
```

Three things this procedure does not do, stated so nobody discovers them under
pressure:

- **It does not roll the schema back.** A backwards `migrate` restores structure
  and never data. Every release from here on is expand and contract
  ([ADR-0009](../../docs/architecture/decisions/0009-regenerate-the-initial-migrations.md)
  ends the rewritable era), which means the previous release serves against the
  new schema and no schema step is needed to go back. A release for which that is
  not true must not ship: fix it forward, or decompose it until each half is
  reversible.
- **It is not atomic.** There is a window between the stop and the start in which
  the host answers nothing. On one VPS with one operator that is the accepted
  shape of a deploy, not a defect to engineer around.
- **It does not undo the recreation of step 3.** That step exists once, before
  the first account. After it, a restore of data is a restore from backup, and
  this repository has never drilled one — the ground truth records the absence
  rather than claiming a number.

Environment changes roll back the same way: `.env.production` is the only place a
value lives, so keep the previous copy before you edit it.

---

## 10. The maintenance timer

`chat-maintenance.timer` runs `manage.py prune` hourly, with a five-minute
randomised delay so the sweep does not land on a predictable wall-clock edge.
`Persistent=true` means one missed run fires after a reboot, and only one — the
sweep is idempotent, so replaying every missed hour would buy nothing.

```sh
systemctl list-timers chat-maintenance.timer
systemctl status chat-maintenance.service
journalctl -u chat-maintenance.service --since '1 day ago'
```

What the journal says, and what it means:

- `envelopes pruned: N`, `attachments pruned: N (files removed: N)`,
  `audit rows pruned: N` — a completed sweep. Counts only; an id or a blob on
  that line would be exactly what the schema refuses to store.
- `skipped: another prune already holds the sweep lock` — **normal, not a
  fault.** The command takes a PostgreSQL advisory lock for its whole run and
  declines when another run holds it, exiting 0 so the unit does not enter a
  failed state for declining to do the one thing that would be wrong. It is what
  you see when an operator runs `manage.py prune` by hand beside the timer.
- `the <name> sweep failed: <ExceptionClass>` with exit 1 — a real failure. The
  exception itself never reaches the output, because a database error carries the
  statement that raised it and those statements carry envelope ids. The step name
  and the exception class are what you get; reproduce it against a scratch copy
  rather than by widening the log on the host.

The sweep is bounded at `TimeoutStartSec=15min`. The largest run ever measured
was 5.95 s for 99 962 expired envelopes, so a run that reaches that bound is
blocked rather than busy — look at `pg_stat_activity` for a lock wait. Being
killed costs nothing: each batch commits on its own, the advisory lock dies with
the backend, and the next fire resumes from what is left.

To run a sweep by hand:

```sh
systemctl start chat-maintenance.service   # or:
as_deploy .venv/bin/python manage.py prune
```

---

## 11. The identity backup, and the restore drill

**What this protects, and it is one thing.** `user_id` is inside every signed device
bundle, so a lost database is not a lost account list — it is a new identity for every
account and a fresh SAS or QR verification with every contact, performed during
whatever incident took the database. Nothing else on this host is irreplaceable: the
code is in git, the wheels are already vendored here, the TLS pair is reissued from
the offline CA, and the queue is seven days of ciphertext that expires on its own.

So [`backup/identity_backup.sh`](backup/identity_backup.sh) dumps identity and nothing
else — eight tables, listed in the script with the reason for every exclusion beside
them, and pinned by `ops/tests/test_scripts.py` so the list cannot drift quietly. The
queue, the attachment rows, the attachment bytes and the admin audit log are
deliberately absent: a backup of any of them is a second copy of exactly the rows
[`../SECURITY.md`](../SECURITY.md) bounds by retention, kept for seven days in a
directory the retention sweep does not reach.

### The key

Generate it **on the operator's own machine**, never on the VPS. The private half
never touches this host, so root here can read every backup it has written and open
none of them.

```sh
# on the operator's machine, once
age-keygen -o chat-backup.key          # mode 0600; this is the half that decrypts
grep 'public key' chat-backup.key      # age1… — this is the half the host gets
```

Keep `chat-backup.key` where the operator keeps the offline CA key
([`tls/README.md`](tls/README.md)) — the same custody, for the same reason. **A backup
whose private key is lost is not a backup**, and nothing on the VPS can regenerate it.

Then, on the host:

```sh
install -o root -g root -m 0644 backup.pub /etc/chat/backup.pub
```

Root-owned and world-readable on purpose: it is a public key, and the `deploy` account
has to read it on every run.

### The timer

```sh
systemctl enable --now chat-backup.timer
systemctl start chat-backup.service      # the first one, by hand, now
systemctl list-timers chat-backup.timer
ls -l /srv/chat/backups/
```

Daily, with a randomised delay of up to thirty minutes, and `Persistent=true` so one
missed day fires after a reboot and only one. The file is
`identity-<YYYY-MM-DD>.sql.age`, mode 0600, owned by `deploy`; the script keeps the
newest seven by the date in the name and removes the rest.

What the journal says, and what it means:

- `wrote identity-2026-09-06.sql.age (N bytes, 8 tables)` — a completed run. A byte
  count and a table count; nothing that names an account.
- `removed identity-…` — the rotation, one line per file past the seventh.
- `FAIL: /etc/chat/backup.pub is missing or unreadable` — the key step above was
  skipped. The unit fails and writes nothing, which is the correct outcome: there is
  no fallback to an unencrypted dump.
- A `pg_dump` error and exit 1 — the run wrote `identity-….sql.age.partial` and
  removed it. Nothing partial is ever renamed into place, so the rotation never counts
  a truncated file as one of the seven.

### The restore drill

**Rehearse this once before the first serving deploy**, not when it is needed. It runs
entirely on a developer machine against a scratch database; nothing on the VPS is
touched, and no production data exists to put at risk.

```sh
# on the operator's machine, with the private key
age --decrypt --identity chat-backup.key identity-2026-09-06.sql.age > drill.sql

createdb restoredrill
POSTGRES_DB=restoredrill .venv/bin/python manage.py migrate
psql -d restoredrill --set ON_ERROR_STOP=on -f drill.sql
```

`migrate` first and then the data, because the dump is `--data-only`: the schema comes
from the migration history of the release being restored, which is the only schema
that release can serve against. A dumped schema would be whichever one was current
when the dump ran, and restoring that over a newer release is how a restore becomes an
outage.

Then assert at the application level rather than on the exit status:

```sh
POSTGRES_DB=restoredrill .venv/bin/python manage.py shell -c "
from accounts.models import User
from devices.models import Device
u = User.objects.first()
print(u.username, u.id, u.check_password('<the password of a test account>'))
print(Device.objects.filter(user=u).count())
"
```

What a pass looks like: the same `user_id`, the same device ids, and a password that
still verifies. Those three are the whole point — an account whose `user_id` changed
is a new account to every peer that ever verified it.

Two things the drill will show and neither is a fault:

- **The queue and the attachments are empty.** They are not in the backup. A restore
  brings identity back; undelivered messages and stored files are gone, and the
  clients re-send.
- **Group membership on an operator account is gone.** `is_staff` and `is_superuser`
  are columns on `accounts_user` and do survive; the two Django join tables behind
  them are not in the list, so a panel role is re-granted by hand.

Record the outcome and the measured duration in
[`../../docs/architecture/GROUND-TRUTH.md`](../../docs/architecture/GROUND-TRUTH.md)
§4 the first time this runs against a real backup file, and close AR-20 with it.
