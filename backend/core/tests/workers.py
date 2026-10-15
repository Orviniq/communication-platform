"""What one test process holds alone when pytest-xdist runs the suite in parallel.

pytest-django already gives each worker a test database of its own, named after
the worker (`test_chatapp_gw0`, `test_chatapp_gw1`, ...). Redis has no such
mechanism, and the suite empties the database `REDIS_URL` names before every test
(`flush_redis_state` in the root `conftest.py`), so two workers on one index would
erase each other's rate counters and login lockouts mid-test. Each worker
therefore takes the index `REDIS_URL` names plus its own number: `gw0` keeps the
configured index, `gw1` the next one, and so on. A serial run is not a worker and
keeps `REDIS_URL` exactly as configured.

The index only ever moves up from the configured one, so a test run pointed at
`/1` on a host whose serving instance uses `/0` never reaches `/0`. A worker whose
index passes the server's `databases` setting (16 by default) fails its first
command with Redis's own `DB index is out of range`; it never shares an index.

Publish and subscribe is the one part of Redis that no index separates: a channel
is server-wide. The bus names its topics after device ids, which are random, and
the tests that name a topic of their own make it unique or use it in one test
only, so no two workers subscribe to one channel. A connection is server-wide
too: the one command the suite sends that acts on connections, `CLIENT KILL` in
`realtime/tests/test_recovery.py`, picks only those on its own process's index.
"""

from urllib.parse import urlsplit, urlunsplit

import pytest

# The tests that open a database connection from each of several threads at once —
# the race tests — and so hold up to 15 connections where every other test holds at
# most 2 (measured per test with the pool emptied between tests). With
# `--dist loadgroup`, which `pytest.ini` sets for every `-n` run, xdist gives the
# whole group to one worker, so at most one worker at a time holds that many and
# the run stays inside PostgreSQL's `max_connections` at any worker count the server
# can serve: one worker at the pool's ceiling (`DB_POOL_MAX_SIZE`, 16) plus two
# outside it, and 3 for each other worker — 57 at 14 workers against the default
# 100. Without it, every worker that ran one of them would keep its pool at that
# size for the rest of the run (the pool closes an idle connection after ten
# minutes), and 14 workers could reach 250.
many_connections = pytest.mark.xdist_group("connections")


def worker_number(worker):
    """`gw3` -> 3. `worker` is `PYTEST_XDIST_WORKER`, which xdist sets in each
    worker process before Django's settings are read and never in a serial run."""
    return int(worker.removeprefix("gw"))


def redis_url_for(url, worker):
    """`url` with its database index moved up by the worker's number, or `url`
    itself when there is no worker. The scheme, the password, the host and the port
    are kept as they are."""
    if worker is None:
        return url
    parts = urlsplit(url)
    index = int(parts.path.lstrip("/") or 0) + worker_number(worker)
    return urlunsplit(parts._replace(path=f"/{index}"))
