# 0013. pytest and ruff as the test and lint stack

- Status: Accepted
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
gives every run a random order. `httpx` drives the API in tests. `hypothesis`
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
