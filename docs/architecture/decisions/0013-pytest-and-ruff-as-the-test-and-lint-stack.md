# 0013. pytest and ruff as the test and lint stack

- Status: Accepted, amended 2026-10-15
- Phase: 1 and 4
- Date: 2026-09-03

## Context

The suite is already pytest with pytest-django and pytest-asyncio: 510 tests
across 61 files, green on the developer machine. No linter is configured, no
formatter is configured, and no CI runs any of it.

Collection order was fixed, which is the condition under which an order
dependency between tests survives indefinitely. This run found one on the first
attempt: `core/tests/test_log_silence.py`'s meta-test passed only when another
test in the same file had run first, and it had been passing that way since it
was written.

## Decision

The suite is pytest with pytest-django and pytest-asyncio. `pytest-randomly`
gives every run a random order. `pytest-xdist` runs the whole suite in parallel,
and a bare `pytest` stays serial (the amendment below). `httpx` drives the API in tests. `hypothesis`
drives property-based tests. `ruff` is the only linter and formatter. No type
checker is added.

Phase 4 sets a branch-coverage gate in CI. It landed in run 13 at 95 percent, and
phase 10 run 08 raised it to 98.

## Position fields

- **Forcing function.** A fixed collection order hides an order dependency until
  the day it fails alone, and the audit suites are exactly the tests whose
  silence is load-bearing.
- **Scale band.** Band 0 to band 4. The suite runtime, not the traffic, sets the
  cost.
- **Flip trigger.** The suite runtime stops fitting a pre-push gate, or a class
  of defect appears that only a type checker catches — at which point the "no
  type checker" half of this decision is the part that gets reversed.
- **Cost.** A random order makes a failure harder to reproduce without its seed,
  so every run must print one. A coverage gate can be satisfied by tests that
  assert nothing, so it measures reach and never quality.
- **Evidence.** ruff is a widely adopted linter and formatter, and running one
  tool for both removes the class of conflict where a formatter and a linter
  disagree about the same line. `httpx` arrived with the surface that needed it,
  in phase 2. `hypothesis` and `pytest-cov` arrived in phase 4, run 12, once the
  code they would measure was the code that stays. **Currency:** current.

## Consequences

- ruff runs with a deliberately small rule set — `E`, `W`, `F` and `I` — at line
  length 90, chosen because the tree was already written to approximately that
  width, so adopting the gate cost a mechanical reformat and nothing else.
- Three per-file ignores exist and each is a documented Django idiom rather than
  a silenced finding: post-`django.setup()` imports in `config/asgi.py`, star
  imports in the settings layers, and Django's own long help texts in generated
  migrations.
- Every run prints its `--randomly-seed`, which is what makes a random-order
  failure reproducible.
- The gate landed in run 13 as `--cov-fail-under=95`, written in `pytest.ini` and
  repeated in the CI test job. It is not part of `--cov` itself: a bare `pytest`
  has to stay the fast inner loop, and a single file measured against the whole
  tree would fail a floor it was never meant to meet. pytest-cov ignores the
  option when coverage is not running, so `pytest` costs nothing and
  `pytest --cov --cov-branch` is bound.
- The floor is not the figure the suite reaches. A floor set at the measurement
  fails on the next honest refactor; one set below it says what the project will
  not go under, and the gap is the room a change is allowed to use. It was 95 from
  run 13 and is 98 from phase 10 run 08, which raised it to the largest integer at
  least one below the measured 99.97 — a rule that keeps the gap from widening
  until the floor gates nothing.
- Run 12 installed both tools and measured the figure the gate was set against.
  Branch coverage was already 96.4 percent — above the 95 this decision names —
  before that run added a test, which is why it was scoped to the missing test
  *classes* rather than to the number: property-based, malformed input,
  concurrency, replay and migration. It ended at 98.7 percent. Run 13 closed the
  rest and ended at 99.97 — 3112 statements with none missed, and one partial
  branch that is provably unreachable — so the floor and the figure are five
  points apart on purpose.
- The property tests run derandomised, through a Hypothesis profile registered
  in `backend/conftest.py`. `pytest-randomly` reseeds the global RNG for every
  test, so an entropy-driven Hypothesis would explore a different set of
  examples in each of the two orders the gate runs, and the cost this decision
  already names — a random order needs its seed to reproduce — would apply twice
  over, once for the order and once for the examples.
- `jsonschema` and its closure joined `requirements/dev.txt` in run 13, for the
  contract suite alone. It is the reference implementation of the 2020-12 dialect
  `openapi.json` declares, so a response body checked against the artefact is
  checked under the rules a client's own generator reads it by. A validator that
  approximated the dialect would be a gate that is confidently wrong, which is
  worse than no gate.
- `django-test-auditor` owns the tests themselves.

## Amendment, 2026-10-15: the suite runs in parallel

`pytest-xdist` 3.8.0 joins `requirements/dev.txt`, with `execnet` 2.1.2, its only
dependency. CI runs `pytest -n auto --cov --cov-branch --cov-fail-under=98`: one
worker per CPU of the runner. A bare `pytest` stays serial. This amends rather than
supersedes: every line above still holds, and xdist is one more tool in the stack
this decision names, as `hypothesis` and `jsonschema` were.

What makes the parallel run sound and not merely green:

- **Each worker holds its own state.** pytest-django gives each worker its own test
  database (`test_chatapp_gw0`, …). The root `conftest.py` gives each its own Redis
  index — the configured one plus the worker's number — because `flush_redis_state`
  empties the whole index before every test. Without it, a 14-worker run failed 66
  tests: the lockout, rate-limit, allowance and contract suites erasing each
  other's counters. `core/tests/workers.py` carries the scheme.
- **What no index separates is handled by name.** Pub/sub channels and client
  connections belong to the Redis server. Device topics are random ids, and the
  one command that acts on connections, `CLIENT KILL` in
  `realtime/tests/test_recovery.py`, now kills only the pub/sub connections of
  its own index. The type filter it used before dropped every worker's
  subscriber — and on a host that also serves, production's.
- **PostgreSQL connections are a shared budget.** The race tests open a connection
  from each of several threads, up to 15 at once, and the pool keeps them for ten
  minutes; every other test holds at most 2, measured per test with the pool
  emptied between tests. Those tests carry `xdist_group("connections")`, and
  `pytest.ini` sets `--dist loadgroup`, so one worker at a time holds them. That
  bounds a run at 18 + 3 × (workers − 1) connections: 57 at 14 workers, 27 on a
  4-CPU runner, against the default 100. Ungrouped, a 14-worker run peaked at 95.
- **Nothing else was made serial, on measurement.** The `pg_locks` probes read only
  their own backend's locks (`pid = pg_backend_pid()`), the prune sweep's advisory
  lock is scoped to its database (measured: the same key is refused in one
  database and granted in a second), and the three tests with wall-clock bounds
  kept at least 0.59 s of headroom at full 14-worker load, using at most 29 percent
  of their bound — the same as on an idle machine.

## Position fields of the amendment

- **Forcing function.** The suite took 230 s locally and 489 s in CI serially, and
  the flip trigger above names a suite that stops fitting a pre-push gate.
  Parallelism keeps the stack and moves the runtime instead.
- **Scale band.** Band 0 to band 4, unchanged: the suite, not the traffic, sets the
  cost.
- **Flip trigger.** A test needs state that can be neither split per worker nor
  bounded — a second shared service, or a test whose correctness depends on the
  machine being otherwise idle. The answer is a serial phase after the parallel
  one, with `--cov-append`, and not a weaker test. A worker count past Redis's 16
  indexes or past the connection bound is the other trigger.
- **Cost.** A worker's database is created and migrated at the start of every run,
  which is why a bare `pytest` stays serial: one small file takes 0.96 s alone and
  2.49 s under `-n auto`. The seed reproduces the order and not the assignment of
  tests to workers, which follows timing; a failure names its worker. A new test
  that opens connections from threads must carry the mark, and nothing enforces
  that. A parallel run empties one Redis index per worker. Past about 8 workers the
  suite stops getting faster on the developer machine: the teardown of the
  `transaction=True` tests, which truncates every table, costs 0.042 s alone and
  0.22 s at 14 workers, and the migration replay's `DROP DATABASE` waits on a forced
  checkpoint.
- **Evidence.** `GROUND-TRUTH.md` §4 carries the measurements: the serial and
  parallel times, the worker curve, the connection peaks grouped and ungrouped,
  the timing-test headroom and the CI times before and after. pytest-cov combines
  every worker's data before it reports, so the floor binds the whole suite: a
  parallel run of one file under `--cov-fail-under=98` exits 1. `loadscope`, the
  usual Django recommendation, was measured as no faster (57.5 and 58.6 s against
  56.6 and 56.5 s) and peaked at 76 and 80 connections, because it cannot honour a
  group. pytest-xdist and execnet are MIT, maintained under the pytest-dev
  organisation, pure-Python wheels, with no advisory in OSV for any version.
  **Currency:** current.
