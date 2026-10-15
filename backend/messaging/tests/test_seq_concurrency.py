"""Per-device `seq` assignment is atomic under concurrency.

`transaction=True` because the point is real committed transactions racing each
other: the enqueue rests on the row lock that `SELECT ... FOR UPDATE` holds until
commit, which a wrapping test transaction would hide.
"""

import threading

import pytest
from django.db import connection, connections

from core.tests.workers import many_connections
from devices.models import Device
from messaging.models import QueuedEnvelope

from .conftest import envelope_blob, make_device

pytestmark = [pytest.mark.django_db(transaction=True), many_connections]

CONCURRENT_SENDS = 12
# The mixed race below runs senders and ackers at once, and every worker holds a
# connection for the length of its request. `DB_POOL_MAX_SIZE` defaults to 16 and
# the test itself holds one, so the two counts together stay under it — past that
# the workers queue for the pool instead of for the row, and the barrier breaks
# before the race ever happens.
MIXED_SENDERS = 10
MIXED_ACKERS = 4
SEND_URL = "/api/v1/envelopes"


def connect_then_wait(barrier):
    """Open this thread's database connection before it waits at the barrier.

    Connection setup costs 10-20 ms and varies by thread — more than the whole
    transaction this test is about — so threads released together would otherwise
    reach the row one at a time on a slow runner, and what the guard proves would
    depend on the machine instead of on the lock.
    """
    connection.ensure_connection()
    barrier.wait(timeout=10)


def test_concurrent_sends_to_one_device_never_collide_or_gap(
    new_http, active_user, device, bearer, bob
):
    target = make_device(bob, 2)
    headers = bearer(active_user, device)
    failures = []
    # A barrier so the workers contend on the same row instead of trickling through.
    start = threading.Barrier(CONCURRENT_SENDS)

    def send():
        try:
            connect_then_wait(start)
            resp = new_http().post(
                SEND_URL,
                json={
                    "messages": [{"device_id": str(target.id), "blob": envelope_blob()}]
                },
                headers=headers,
            )
            if resp.status_code != 202:
                failures.append(resp.status_code)
        except Exception as exc:  # a seq collision surfaces as IntegrityError → 500
            failures.append(repr(exc))
        finally:
            connections.close_all()

    threads = [threading.Thread(target=send) for _ in range(CONCURRENT_SENDS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert failures == []
    seqs = sorted(
        QueuedEnvelope.objects.filter(recipient_device_id=target.id).values_list(
            "seq", flat=True
        )
    )
    # Unique (no lost update) and gapless (nothing reserved then dropped), so the
    # mailbox orders deterministically.
    assert seqs == list(range(1, CONCURRENT_SENDS + 1))
    assert Device.objects.get(id=target.id).queue_seq == CONCURRENT_SENDS


def test_two_batches_with_overlapping_recipients_never_deadlock(
    new_http, active_user, device, bearer, bob
):
    """The lock order is what keeps this safe. Two batches that named the same two
    devices in opposite orders would take the rows in opposite orders and one of
    them would die with a deadlock, so the unit sorts the ids before it locks."""
    first, second = make_device(bob, 3), make_device(bob, 4)
    headers = bearer(active_user, device)
    failures = []
    start = threading.Barrier(2)

    def send(order):
        try:
            connect_then_wait(start)
            resp = new_http().post(
                SEND_URL,
                json={
                    "messages": [
                        {"device_id": str(d.id), "blob": envelope_blob()} for d in order
                    ]
                },
                headers=headers,
            )
            if resp.status_code != 202:
                failures.append(resp.status_code)
        except Exception as exc:  # a deadlock surfaces as OperationalError → 500
            failures.append(repr(exc))
        finally:
            connections.close_all()

    threads = [
        threading.Thread(target=send, args=(order,))
        for order in ([first, second], [second, first])
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert failures == []
    for target in (first, second):
        assert QueuedEnvelope.objects.filter(recipient_device_id=target.id).count() == 2


def test_the_unique_constraint_would_catch_a_duplicate_seq(bob):
    """Guards the guard: without this, the tests above could pass vacuously if the
    constraint were ever dropped."""
    target = make_device(bob, 5)
    QueuedEnvelope.objects.create(recipient_device=target, seq=1, blob=b"a" * 1024)

    with pytest.raises(Exception):
        QueuedEnvelope.objects.create(recipient_device=target, seq=1, blob=b"b" * 1024)


def test_an_emptied_mailbox_never_restarts_its_sequence(
    new_http, active_user, device, bearer, bob
):
    """The counter lives on the device row, not on the queue, so draining a
    mailbox to nothing does not hand the next envelope a number an earlier one
    already used. If it did, a client that had acked seq 1 would read the new seq
    1 as an envelope it already has and drop it."""
    target = make_device(bob, 6)
    http = new_http()
    headers = bearer(active_user, device)
    body = {"messages": [{"device_id": str(target.id), "blob": envelope_blob()}] * 3}
    assert http.post(SEND_URL, json=body, headers=headers).status_code == 202
    owner = bearer(bob, target)

    drained = http.get("/api/v1/me/envelopes", headers=owner).json()["envelopes"]
    http.post(
        "/api/v1/me/envelopes/ack",
        json={"ids": [one["id"] for one in drained]},
        headers=owner,
    )
    http.post(
        SEND_URL,
        json={"messages": [{"device_id": str(target.id), "blob": envelope_blob(b"z")}]},
        headers=headers,
    )

    assert [one["seq"] for one in drained] == [1, 2, 3]
    assert list(
        QueuedEnvelope.objects.filter(recipient_device_id=target.id).values_list(
            "seq", flat=True
        )
    ) == [4]
    assert Device.objects.get(id=target.id).queue_seq == 4


def test_acks_running_beside_sends_never_free_a_sequence_number_for_reuse(
    new_http, active_user, device, bearer, bob
):
    """The other half of the race. The senders take the device row lock; the
    ackers take no lock at all and delete rows out from under them, which is
    exactly what a live client does while its peers are talking. A counter derived
    from the queue — `MAX(seq) + 1`, say — would hand a fresh envelope a number an
    acked one already carried, and the recipient would discard it as a duplicate.

    Every seq the run produced is therefore accounted for: either an acker saw it
    or it is still in the mailbox, and no number is missing from the range.
    """
    target = make_device(bob, 7)
    sender_headers = bearer(active_user, device)
    owner_headers = bearer(bob, target)
    failures, drained_seqs = [], []
    start = threading.Barrier(MIXED_SENDERS + MIXED_ACKERS)

    def send():
        try:
            connect_then_wait(start)
            resp = new_http().post(
                SEND_URL,
                json={
                    "messages": [{"device_id": str(target.id), "blob": envelope_blob()}]
                },
                headers=sender_headers,
            )
            if resp.status_code != 202:
                failures.append(resp.status_code)
        except Exception as exc:
            failures.append(repr(exc))
        finally:
            connections.close_all()

    def drain_and_ack():
        try:
            connect_then_wait(start)
            client = new_http()
            page = client.get("/api/v1/me/envelopes", headers=owner_headers)
            if page.status_code != 200:
                failures.append(page.status_code)
                return
            envelopes = page.json()["envelopes"]
            drained_seqs.extend(one["seq"] for one in envelopes)
            acked = client.post(
                "/api/v1/me/envelopes/ack",
                json={"ids": [one["id"] for one in envelopes]},
                headers=owner_headers,
            )
            if acked.status_code != 200:
                failures.append(acked.status_code)
        except Exception as exc:
            failures.append(repr(exc))
        finally:
            connections.close_all()

    threads = [threading.Thread(target=send) for _ in range(MIXED_SENDERS)] + [
        threading.Thread(target=drain_and_ack) for _ in range(MIXED_ACKERS)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert failures == []
    assert Device.objects.get(id=target.id).queue_seq == MIXED_SENDERS
    remaining = list(
        QueuedEnvelope.objects.filter(recipient_device_id=target.id).values_list(
            "seq", flat=True
        )
    )
    assert len(remaining) == len(set(remaining))
    assert set(drained_seqs) | set(remaining) == set(range(1, MIXED_SENDERS + 1))
