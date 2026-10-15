# 0028. An exact username lookup replaces the directory, and an account can hide from it

- Status: Accepted
- Phase: — (a change to the released `v1` surface, after the rebuild's eleven phases)
- Date: 2026-10-15
- Landed: 2026-10-15. `GET /api/v1/users` is gone; `POST /api/v1/users/lookup` and
  `GET`/`PUT /api/v1/me/discoverability` are served; `accounts.0004` adds
  `User.discoverable` and `accounts.0005` builds `ix_user_findable_name`.

## Context

`GET /api/v1/users` answered every activated account — its id and its name — to any
device holding a session. It was how the client picked a conversation partner, and
at fewer than fifty accounts it was one small body.

It was also the whole user list, handed out on request. Any member got every account
name on the server in one call; so did a stolen session token, which stays valid for
thirty days and which nothing detects (`ACCEPTED_RISKS.md` AR-18); and a client that
cached the answer put a copy of the user list on every device, where a seized phone
yields it. The server already refuses to keep a social graph at rest. A route that
publishes the list of who is on the server to whoever asks sat badly beside that, and
`REJECTED_PROPOSALS.md` §9 still described "the directory a client searches" as the
reason usernames had to stay in the clear.

The owner decided three things and they are not reopened here: the directory goes; an
authenticated device can find one account by its exact name; and every account carries
a "find me by username" setting, on by default, that hides it from that lookup. What
this record decides is the shape: the routes, the bodies, the codes, the rate, where the
setting lives, and what it costs.

## Decision

### 1. `GET /api/v1/users` is removed

No deprecation window. The surface is `v1` with no released client
([0007](0007-contract-conventions.md)), so a breaking change is a section in
`API_CHANGES.md` rather than a second version. The client in `frontend/` calls this
route for its contact picker, and that picker fails from this merge until the client
update ships; `CLIENT_WORK.md` carries it as required before release.

### 2. `POST /api/v1/users/lookup` finds one account by its exact name

A full-scope session token, and a body `{"username": "…"}` with nothing else in it.

- The name is lowercased and held to the registration rule, `^[a-z0-9_]{3,32}$`. A name
  no account could hold is `400 invalid_request` with the rule's own message and no echo
  of the input. That tells the caller what `POST /auth/register` already publishes and
  nothing about any account — and it keeps a NUL byte away from psycopg, which refuses
  the statement outright rather than finding no row.
- Found: `200 {"user_id": "…", "username": "…"}`, and nothing else about the account.
- Not found: `404 {"code": "not_found", "detail": "No account can be found by that
  name."}`. **The same answer for a name nobody holds, a name whose account is inactive,
  and a name whose owner turned discoverability off.** The detail is true of all three,
  so the route does not lie to tell them apart.
- Exact only. The statement is an equality on the stored name: no prefix, no substring,
  no fuzzy match, and no wildcard — `b_b` is three characters, not a pattern.
- Writes nothing.

**Why a `POST` with a body.** The name must not travel in the path or a query string,
because the path is the part of a request that the layers in front of this process —
a proxy, a crash report, a client's own HTTP logging — write down. nginx keeps no
access log here (`backend/SECURITY.md`), but the rule is about the shape of the
request rather than about one layer's configuration today, so it holds whatever sits
in front later. `accounts/tests/test_lookup.py` holds it over the whole generated
document, not only this route: no operation may take a name in its address. `POST
/api/v1/peers` is the precedent for a read that carries its input in a body.

**Why `404` and not `200` with an empty answer.** `not_found` is the vocabulary's word
for "nothing answers to this", the client already branches on it for the per-user
reads, and an empty-but-successful body would be one more shape to mean the same thing.

### 3. Its own rate scope, sized against a dictionary

`lookup`, from `THROTTLE_LOOKUP`, default **`50/day`**, counted per account across all
of its devices, under the limiter every other scope uses — so it fails closed with `503
unavailable` when Redis is unreachable ([0010](0010-redis-rate-limiting-that-fails-closed.md)).

It is the one authenticated scope sized against an adversary rather than against a
client's traffic. A person adding contacts looks up a handful of names, typos included.
A dictionary of 10 000 likely names costs one account 200 days at this rate, and a
dictionary of 100 000 costs it more than five years. A guesser cannot multiply the
budget by registering more accounts, because the owner activates every account by hand;
the deployment's whole lookup budget is fifty a day times the accounts the owner has
activated.

The limiter runs before the body is validated, so every outcome spends the scope — a
found name, a missed one, a refused shape and a refused body alike. Probing for free by
sending something the route refuses is not possible. It is a fixed UTC-day window, so a
guesser who spends the day's fifty just before midnight can spend fifty more just after
it; the bound is a hundred in a burst and fifty a day sustained.

### 4. The setting: `User.discoverable`, behind its own route

One boolean column on the account row, `true` for every existing and every new account,
with the default kept in the database (`db_default`).

`GET /api/v1/me/discoverability` answers `{"discoverable": true|false}`;
`PUT /api/v1/me/discoverability` takes the same body, strict — `"false"` and `0` are
refused rather than read as an answer the owner did not give — writes it with one
`UPDATE` of one column, and answers it. A repeat is the same call. Both count against
the `accounts` scope.

**Its own route rather than part of an existing one**, because none fits. There is no
`GET /me`; `DELETE /me` is the erasure; the profile is client ciphertext the server
cannot read and must not grow a plaintext sibling; and `GET /config` publishes
deployment limits, not account state. A route of its own makes the one value it carries
explicit in the document and costs one path.

**What it does, and what it does not.** When it is off, the lookup answers that name
exactly as it answers a name nobody holds. It changes nothing about any route addressed
by a `user_id`. Hiding a name hides the name.

### 5. Indistinguishable by construction, and measured

The three not-found cases share one code path. The filter is in the `WHERE` clause
rather than in Python, so the same statement runs for every name and nothing in the
handler branches on which case it was. Below a few hundred accounts the planner scans
the table, which is the same work for every name. Above that it reads an index, and
the obvious one — the unique index on `username` — finds the row of an inactive or
hidden account and then filters it out: one heap page more than a name nobody holds.

So the lookup reads a partial index instead, `ix_user_findable_name` on `username`
where `is_active AND discoverable`. An unknown name, an inactive account's name and a
hidden account's name all miss it alike — the same index pages, no heap page, no row
removed by a filter. The found case reads one heap page more, which it must: it
returns the row. The planner chooses the partial index because it is the smaller one,
and that choice is pinned by a test at 1000 accounts rather than assumed.

What the code cannot equalise is everything under it — the cache state of the page a
name lands on, the network, the scheduler. Those differences are not claimed to be
zero. They are measured below, and the scope above is what makes them unusable: an
attacker resolving a difference of microseconds through a network needs thousands of
samples of the same name, and gets fifty a day.

### 6. The panel neither shows nor edits it

The setting is the owner's choice. An operator who could flip it could make a hidden
account findable, and a column or a filter that showed it would be a list of the
accounts that chose to hide; neither is support work. Not in `list_display`, not in
`list_filter`, not in the change form — asserted against configuration and against the
rendered pages.

And the change form stops writing the row. The stock save wrote every column back as
the panel had read it, so an owner who hid between the panel's read and its save was
made findable again by an operator who never saw the setting. The save now names the
two columns its form edits. The race was reproduced first, as a failing test, and then
closed.

### 7. At rest, and why

A seizure now also yields, for each account, whether its owner chose to hide from the
lookup. That is accepted. It is one boolean about one account; it names no other
account, so it adds no edge to any graph; and the alternatives are worse.

- **In Redis, volatile like the counters.** A Redis restart forgets it, and a forgotten
  setting reads as the default — on. A privacy setting that fails open on every restart
  is not one.
- **On the client only.** The server is what answers the lookup, so the server has to
  know.

The guard against it growing into something worse is in the schema rule, not in this
column: `core/tests/test_seizure_guard.py` refuses the column names a server-side contact
list would take (`contacts`, `friends`, `discoverable_by`, `visible_to`, a lookup or
search history) and a table that references two users in any app, `accounts` included —
it used to exempt `accounts`, which is where a `Contact(owner, peer)` table would be
added. The account table's columns are pinned to the seizure list of `SECURITY.md`.

## What this does not do

Stated here because a setting called "find me by username" invites a reader to believe
more than it does.

- **Registration still answers whether a name is taken.** Anonymous `POST
  /api/v1/auth/register` answers `409 username_taken` for every existing account —
  inactive and hidden included — at `THROTTLE_REGISTER`, ten an hour for each client
  address. The setting does not change that and cannot without leaving registration
  unable to say why a name was refused. What makes it a poor oracle is that a probe of a
  *free* name succeeds: it creates an account in the inactive state, takes the name, and
  lands on the operator's dashboard as awaiting activation. A dictionary walk through
  registration registers most of the dictionary.
- **A `user_id` reaches everything addressed by one.** A member who learns another
  account's id — from a group they share, whose membership the clients exchange
  in-band, or from a contact who passes it on — reads that account's profile,
  identity, devices and device log, claims its prekeys, includes it in `POST
  /api/v1/peers` and sends to its devices, discoverable or not. Those routes are how a
  conversation that already exists works, and the setting touches none of them.
- **The server sees every lookup.** Live root reads the name in the body after TLS ends,
  which account asked, and when. No name is recorded anywhere — no access log, no
  telemetry ([0019](0019-the-system-emits-no-request-scoped-telemetry.md)), no column.
  The rate counter is the one trace: in Redis memory, with persistence off, it holds the
  asking account, the UTC day and the count of that day's lookups until the window
  expires, at most 24 hours — which accounts looked someone up today, never whom. A
  modified server can record everything. A lookup is a question asked of the adversary of the threat
  model, and a client that treats the answer as trusted has made that adversary its
  directory again (`backend/CLIENT_CONTRACT.md` §P).
- **The lookup is an existence oracle for a discoverable name**, by design and at the
  rate above. That is what finding a person by name is.

## Position fields

- **Forcing function.** The directory handed every account name to every session
  holder in one call, so a member, a stolen token and a seized device each yielded the
  whole user list. The server refuses a social graph at rest; a user list on request is
  the precondition for building one.
- **Scale band.** Band 0, holding through band 2. At band 0 the lookup scans a two-page
  table; from a few hundred accounts it reads the partial index; the statement count
  is one at every size.
- **Flip trigger.** For the rate: the first report of a `429` on a lookup in ordinary
  use — the answer is a higher `THROTTLE_LOOKUP`, which is an operator setting and not a
  code change. For the design: a need to find a person by something other than a name
  they have told you — an invite link, a QR code, a phone number — which is a new
  surface with an exposure review of its own.
- **Cost.** The client loses browsing: a person has to be told a name to be found by
  it, exactly, and the contact list becomes the client's to keep. The current client's
  contact picker breaks until it is rewritten. Fifty lookups a day can refuse a user who
  adds contacts in bulk. The seizure yield grows by one boolean per account, which says
  who chose to hide. `accounts_user` maintains one more index, and an activation or a
  setting change is no longer a HOT update because both columns are in its predicate —
  at fewer than fifty rows, nothing. A rollback past `accounts.0004` drops the column,
  and re-applying it makes every account findable again. And the honest limits above:
  registration is still an oracle, a `user_id` still reaches everything, and the server
  sees every question.
- **Evidence.** Measured on the developer machine, PostgreSQL 16.14, against the
  composed application; the rows are in [`../GROUND-TRUTH.md`](../GROUND-TRUTH.md) §4
  and §4.2. The migration: one `ALTER TABLE "accounts_user" ADD COLUMN "discoverable"
  boolean DEFAULT true NOT NULL`, 0.342 ms against a 200 000-row, 55 MB copy, ACCESS
  EXCLUSIVE on `accounts_user` and nothing else, `relfilenode` unchanged and
  `pg_attribute.atthasmissing` set, and an insert that does not name the column reads
  `true` — so the previous release keeps registering accounts against the new schema.
  `core/tests/test_migrations.py` now reads `relfilenode` inside the lock probe for
  every migration, so "rewrites nothing" is a gate rather than a note. The planner
  scans the table at 100 and 200 rows and reads an index from 400. At 200 000 rows the
  unique-index plan read 3 buffers for an unknown name and 4 for an inactive or a
  hidden one, each with one row removed by the filter; the partial index read 3 for
  each of the three and removed none, at 3.5 MB against the 7.6 MB of the
  `username` pattern index. The statement alone is 45 to 47 µs for all four cases at 47
  and at 1000 accounts. Through the composed application, 3000 rounds at 47 accounts
  with the order of the four cases shuffled each round: medians of 2605 to 2639 µs,
  with no order by case, against a p95 near 3.85 ms. The same run with a fixed order
  showed a 90 µs alternation that followed the position in the round and not the case
  — worth knowing before reading a fixed-order benchmark of this route. Every outcome of
  the lookup is the authentication read and one statement, pinned at 1 and 26 accounts
  by `accounts/tests/test_query_counts.py`. **Currency:** current.

## Consequences

- `API_CHANGES.md` § "The directory leaves: one exact name finds one account" carries
  the removal as breaking and the three new operations. The surface is 34 operations
  over 29 paths.
- `CLIENT_WORK.md` carries the client update as required before release: stop calling
  `GET /users`, find people by exact name, keep the contact list on the client, and
  offer the setting with wording that says what it does not hide.
  `backend/CLIENT_CONTRACT.md` §P binds the client half: the lookup answer is a server
  claim, verified like any other identity before it is trusted.
- `backend/SECURITY.md` names the flag in the seizure list and the three limits above
  in the residual risks. `REJECTED_PROPOSALS.md` §9 no longer cites a directory.
- `docs/admin/PANEL-RECORD.md` records the panel decision and the narrowed save.
- The deploy order is free. `0004` keeps its default in the database, so the release
  before it inserts accounts that read `true`; `0005` is `atomic = False` and builds
  concurrently, and a deploy that ran it checks for an invalid index as
  `messaging.0005` documents. `ops/RUNBOOK.md` stops the service before `migrate`
  either way.
- `THROTTLE_LOOKUP` joins the environment table of `backend/README.md` and
  `.env.example`. A deployment that sets nothing gets `50/day`.
