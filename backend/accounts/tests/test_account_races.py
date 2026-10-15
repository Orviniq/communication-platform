"""Two accounts writes that can arrive at once, driven from real threads.

`transaction=True` because the point is real committed transactions racing: both
guards here are database constraints — the unique index on the username and the
primary key of the profile row — and a wrapping test transaction would hide
exactly that.

The style is the one `devices/tests/test_claim_race.py` and
`devices/tests/test_device_limit_race.py` set: every thread opens its connection
before the barrier, every thread closes it after, and each race is followed by a
test that shows the obvious implementation would not have held.
"""

import base64
import threading

import pytest
from django.db import IntegrityError, connection, connections

from accounts.models import ProfileBlob, User
from core.buckets import PROFILE_BUCKETS
from core.tests.workers import many_connections

pytestmark = [pytest.mark.django_db(transaction=True), many_connections]

CONCURRENT = 4
GOOD_PASSWORD = "a-sufficiently-long-passphrase"
CONTESTED_NAME = "zed"
REGISTER_URL = "/api/v1/auth/register"
MY_PROFILE_URL = "/api/v1/me/profile"


def connect_then_wait(barrier):
    """Open this thread's database connection before it waits at the barrier.

    Connection setup costs 10-20 ms and varies by thread — more than the whole
    transaction a race test is about, and `CONN_MAX_AGE` is 0, so every unit of
    work opens its own. Threads released together would otherwise reach the row
    one at a time on a slow runner, and what the guard proves would depend on the
    machine instead of on the constraint.
    """
    connection.ensure_connection()
    barrier.wait(timeout=10)


def storm(work, count=CONCURRENT):
    """Run `work(index)` in `count` threads released together; collect what each
    returned, and re-raise nothing — a thread that failed returns its exception."""
    start = threading.Barrier(count)
    results = []
    lock = threading.Lock()

    def run(index):
        try:
            connect_then_wait(start)
            outcome = work(index)
        except Exception as exc:  # noqa: BLE001 - surfaced through `results`
            outcome = exc
        finally:
            connections.close_all()
        with lock:
            results.append(outcome)

    threads = [threading.Thread(target=run, args=(i,)) for i in range(count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)
    assert len(results) == count, "a thread never finished"
    return results


def test_two_registrations_of_one_name_settle_on_a_single_account(new_http):
    """The name race. Whatever the interleaving, one caller is told it created the
    account and every other is told the name is taken, and the directory the
    operator later activates has one row to activate."""

    def register(_index):
        return new_http().post(
            REGISTER_URL,
            json={"username": CONTESTED_NAME, "password": GOOD_PASSWORD},
        )

    responses = storm(register)

    assert [r for r in responses if isinstance(r, Exception)] == []
    statuses = sorted(response.status_code for response in responses)
    assert statuses == [201] + [409] * (CONCURRENT - 1), statuses
    assert User.objects.filter(username=CONTESTED_NAME).count() == 1
    conflicts = [r.json()["code"] for r in responses if r.status_code == 409]
    assert conflicts == ["username_taken"] * (CONCURRENT - 1)


def test_the_index_is_what_settles_it_and_a_prior_probe_would_not_have(new_http):
    """Guards the guard. The obvious implementation — ask whether the name exists,
    then create it — cannot settle this race at all: two callers that both look
    before either writes both see nothing, and the second write is refused by the
    unique index rather than by the probe. The unit of work skips the probe and
    lets the index answer, which is the same outcome one query cheaper."""
    barrier_after_probe = threading.Barrier(2)

    def probe_then_insert(_index):
        seen = User.objects.filter(username=CONTESTED_NAME).exists()
        barrier_after_probe.wait(timeout=10)
        try:
            User.objects.create_user(username=CONTESTED_NAME, password=GOOD_PASSWORD)
        except IntegrityError as exc:
            return ("refused-by-the-index", seen, exc.__class__.__name__)
        return ("created", seen, None)

    outcomes = storm(probe_then_insert, count=2)

    assert {outcome[1] for outcome in outcomes} == {False}, (
        "the two probes did not overlap, so this proves nothing about the race"
    )
    assert sorted(outcome[0] for outcome in outcomes) == [
        "created",
        "refused-by-the-index",
    ]
    assert User.objects.filter(username=CONTESTED_NAME).count() == 1


def test_concurrent_first_profile_writes_leave_one_row_and_one_winner(
    new_http, active_user, device, bearer
):
    """The other end of the same shape. `select_for_update` locks nothing when the
    row does not exist yet, so several first writes can all pass the version check;
    the primary key of the profile row is what refuses the losers, and they are
    told what a late writer is always told."""
    headers = bearer(active_user, device)
    blob = base64.b64encode(b"\x04" * PROFILE_BUCKETS[0]).decode()

    def write(_index):
        return new_http().put(
            MY_PROFILE_URL, json={"blob": blob, "version": 1}, headers=headers
        )

    responses = storm(write)

    statuses = sorted(response.status_code for response in responses)
    assert statuses == [200] + [409] * (CONCURRENT - 1), statuses
    assert {r.json()["code"] for r in responses if r.status_code == 409} == {
        "stale_version"
    }
    row = ProfileBlob.objects.get(user=active_user)
    assert row.version == 1
    assert len(bytes(row.blob)) == PROFILE_BUCKETS[0]
