"""Client-signed append-only device-list log.

The server assigns sequence numbers and serves bytes back verbatim; everything
that makes the log meaningful — the hash chain, the signatures, comparing heads
and raising a fork alarm — is client-side and specified in CLIENT_CONTRACT.md.
The adversarial test here proves the server-side half: no chain validation, no
repair, no smoothing.
"""

import base64
import threading

import pytest
from django.db import connections
from hypothesis import given, settings
from hypothesis import strategies as st

from core.buckets import DEVICELOG_BUCKETS
from core.tests.workers import many_connections
from devices.models import DeviceLogRecord
from devices.schemas import page_bounds
from devices.services import peer_log

from .conftest import DEVICES_URL, connect_then_wait

pytestmark = pytest.mark.django_db(transaction=True)

LOG_URL = "/api/v1/me/devicelog"

CONCURRENT_APPENDS = 12


def peer_log_url(user_id, query=""):
    return f"/api/v1/users/{user_id}/devicelog{query}"


def log_blob(filler=b"R", size=None):
    size = size or min(DEVICELOG_BUCKETS)
    return base64.b64encode((filler * size)[:size]).decode()


def test_appends_assign_seq_and_read_back_byte_identical(
    http, active_user, device, bearer, peer, peer_device
):
    mine = bearer(active_user, device)
    blobs = [log_blob(bytes([65 + i])) for i in range(3)]

    posted = http.post(
        LOG_URL, json={"records": [{"blob": b} for b in blobs]}, headers=mine
    )

    assert posted.status_code == 201
    assert posted.json() == {"first_seq": 0, "last_seq": 2}
    page = http.get(
        peer_log_url(active_user.id), headers=bearer(peer, peer_device)
    ).json()
    assert [r["blob"] for r in page["records"]] == blobs
    assert [r["seq"] for r in page["records"]] == [0, 1, 2]
    assert page["head_seq"] == 2
    assert page["has_more"] is False


def test_keyset_paging_clamps_bad_cursors_and_limits(
    http, active_user, device, bearer, peer, peer_device
):
    mine = bearer(active_user, device)
    http.post(
        LOG_URL,
        json={"records": [{"blob": log_blob(bytes([65 + i]))} for i in range(5)]},
        headers=mine,
    )
    theirs = bearer(peer, peer_device)

    page = http.get(
        peer_log_url(active_user.id, "?after=1&limit=2"), headers=theirs
    ).json()
    assert [r["seq"] for r in page["records"]] == [2, 3]
    assert page["has_more"] is True
    assert page["head_seq"] == 4

    # A junk cursor falls back to the start; a junk limit falls back to the cap.
    junk = http.get(
        peer_log_url(active_user.id, "?after=abc&limit=zzz"), headers=theirs
    ).json()
    assert [r["seq"] for r in junk["records"]] == [0, 1, 2, 3, 4]


def test_an_off_bucket_record_is_rejected_without_echoing(
    http, active_user, device, bearer
):
    off_bucket = base64.b64encode(b"x" * 300).decode()

    response = http.post(
        LOG_URL,
        json={"records": [{"blob": off_bucket}]},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400
    assert response.json()["code"] == "bad_bucket"
    assert off_bucket not in response.text
    assert DeviceLogRecord.objects.count() == 0


def test_more_than_fifty_records_per_append_are_rejected(
    http, active_user, device, bearer
):
    body = {"records": [{"blob": log_blob()} for _ in range(51)]}

    response = http.post(LOG_URL, json=body, headers=bearer(active_user, device))

    assert response.status_code == 400


def test_a_log_append_changes_the_device_list_etag(http, active_user, device, bearer):
    headers = bearer(active_user, device)
    before = http.get(DEVICES_URL, headers=headers).headers["etag"]

    http.post(LOG_URL, json={"records": [{"blob": log_blob()}]}, headers=headers)

    after = http.get(DEVICES_URL, headers=headers)
    assert after.headers["etag"] != before
    assert after.json()["log_head_seq"] == 0
    # And once the client holds the new tag, polling returns 304 again.
    assert (
        http.get(
            DEVICES_URL, headers={**headers, "If-None-Match": after.headers["etag"]}
        ).status_code
        == 304
    )


def test_the_peer_list_surfaces_the_log_head(
    http, active_user, device, bearer, peer, peer_device
):
    http.post(
        LOG_URL,
        json={"records": [{"blob": log_blob()}, {"blob": log_blob(b"S")}]},
        headers=bearer(peer, peer_device),
    )

    body = http.get(
        f"/api/v1/users/{peer.id}/devices", headers=bearer(active_user, device)
    ).json()

    assert body["log_head_seq"] == 1


def test_a_deactivated_users_log_is_hidden(
    http, active_user, device, bearer, peer, peer_device
):
    http.post(
        LOG_URL,
        json={"records": [{"blob": log_blob()}]},
        headers=bearer(peer, peer_device),
    )
    peer.is_active = False
    peer.save(update_fields=["is_active"])

    page = http.get(peer_log_url(peer.id), headers=bearer(active_user, device)).json()

    assert page["records"] == []
    assert page["head_seq"] is None


def test_a_non_linking_record_is_accepted_and_served_unchanged(
    http, active_user, device, bearer, peer, peer_device
):
    """Server-side half of "equivocation detected via gossip": a record whose
    prev_hash is deliberate garbage must be accepted and served byte-identically,
    in order, proving no server-side chain validation, repair, reordering, or
    dropping exists — which is what makes detection genuinely client-side. The
    other half — two clients comparing heads and raising a fork alarm on mismatch
    — is client behaviour and belongs to CLIENT_CONTRACT.md."""
    mine = bearer(active_user, device)
    http.post(LOG_URL, json={"records": [{"blob": log_blob(b"A")}]}, headers=mine)
    # Not a hash of anything: a chain-validating server would have to reject it.
    garbage = log_blob(b"\xff")

    posted = http.post(LOG_URL, json={"records": [{"blob": garbage}]}, headers=mine)

    assert posted.status_code == 201
    page = http.get(
        peer_log_url(active_user.id), headers=bearer(peer, peer_device)
    ).json()
    assert [r["blob"] for r in page["records"]] == [log_blob(b"A"), garbage]
    assert page["head_seq"] == 1


@many_connections
def test_parallel_appends_never_duplicate_or_gap_seq(
    new_http, active_user, device, bearer
):
    """Mirror of vault/tests/test_concurrency.py: seq assignment rests on a real
    committed user-row lock racing other transactions, which a wrapping test
    transaction would hide."""
    headers = bearer(active_user, device)
    failures = []
    start = threading.Barrier(CONCURRENT_APPENDS)

    def append_one():
        try:
            connect_then_wait(start)
            response = new_http().post(
                LOG_URL, json={"records": [{"blob": log_blob()}]}, headers=headers
            )
            if response.status_code != 201:
                failures.append(response.status_code)
        except Exception as exc:  # a seq collision surfaces as IntegrityError
            failures.append(repr(exc))
        finally:
            connections.close_all()

    threads = [threading.Thread(target=append_one) for _ in range(CONCURRENT_APPENDS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert failures == []
    seqs = sorted(
        DeviceLogRecord.objects.filter(user_id=active_user.id).values_list(
            "seq", flat=True
        )
    )
    assert seqs == list(range(CONCURRENT_APPENDS))


def test_the_unique_constraint_would_catch_a_duplicate_seq(active_user):
    """Guards the guard: without (user, seq) unique the race test above could
    pass vacuously if the counter logic were ever broken."""
    DeviceLogRecord.objects.create(user=active_user, seq=0, blob=b"a" * 256)

    with pytest.raises(Exception):
        DeviceLogRecord.objects.create(user=active_user, seq=0, blob=b"b" * 256)


def test_the_log_has_a_ceiling(http, active_user, device, bearer, peer, peer_device):
    """The log is append-only and never pruned, so without a ceiling one account
    grows it at the batch cap times the rate limit forever. Past the ceiling an
    append is refused whole and stores nothing; a batch that lands exactly on it
    is accepted."""
    from django.test import override_settings

    mine = bearer(active_user, device)

    with override_settings(MAX_DEVICELOG_RECORDS=3):
        first = http.post(
            LOG_URL, json={"records": [{"blob": log_blob(b"A")}] * 2}, headers=mine
        )
        refused = http.post(
            LOG_URL, json={"records": [{"blob": log_blob(b"B")}] * 2}, headers=mine
        )
        last = http.post(
            LOG_URL, json={"records": [{"blob": log_blob(b"C")}]}, headers=mine
        )

    assert first.status_code == 201
    assert refused.status_code == 409
    assert refused.json()["code"] == "devicelog_limit"
    assert last.status_code == 201
    assert last.json() == {"first_seq": 2, "last_seq": 2}
    page = http.get(peer_log_url(active_user.id), headers=bearer(peer, peer_device))
    assert page.json()["head_seq"] == 2
    assert DeviceLogRecord.objects.filter(user=active_user).count() == 3


LOG_LENGTH = 12


@pytest.fixture
def a_log(active_user):
    """A real log of known contents, built once and only read from: the paging
    properties below re-run the test body for every example, so anything they wrote
    would leak from one example into the next."""
    blobs = [bytes([65 + index]) * min(DEVICELOG_BUCKETS) for index in range(LOG_LENGTH)]
    DeviceLogRecord.objects.bulk_create(
        [
            DeviceLogRecord(user=active_user, seq=index, blob=blob)
            for index, blob in enumerate(blobs)
        ]
    )
    return blobs


@given(
    after=st.integers(min_value=-5, max_value=LOG_LENGTH + 5),
    limit=st.integers(min_value=1, max_value=LOG_LENGTH + 3),
)
def test_a_page_is_ordered_bounded_and_starts_where_the_cursor_left_off_property(
    a_log, active_user, after, limit
):
    """The four keyset invariants at one cursor: a page never repeats a record it
    has already served (every seq is past the cursor and the page is strictly
    increasing), never skips one (it starts at the very next stored seq), honours
    the limit as an upper bound, and serves the stored bytes unchanged."""
    page = peer_log(active_user.id, after, limit)
    seqs = [record["seq"] for record in page["records"]]

    assert len(seqs) <= limit
    assert seqs == sorted(seqs)
    assert len(seqs) == len(set(seqs))
    assert all(seq > after for seq in seqs)
    remaining = [seq for seq in range(LOG_LENGTH) if seq > after]
    if remaining:
        assert seqs[:1] == remaining[:1], "the page skipped the next stored record"
    assert seqs == remaining[:limit]
    for record in page["records"]:
        assert base64.b64decode(record["blob"]) == a_log[record["seq"]]
    assert page["head_seq"] == LOG_LENGTH - 1
    assert page["has_more"] is (len(remaining) > limit)


@settings(max_examples=30)
@given(
    limit=st.one_of(
        st.integers(min_value=-3, max_value=LOG_LENGTH + 3).map(str),
        st.sampled_from(["", "abc", "none", "1e3", None]),
    )
)
def test_walking_the_cursor_to_exhaustion_serves_every_record_once_property(
    a_log, active_user, limit
):
    """The whole walk, driven the way a client drives it: the page size comes off
    the query string, so a junk one is clamped rather than refused, and the cursor
    is the last seq of the previous page. However the pages fall, the union is the
    log exactly once and in order."""
    cursor, seen = -1, []

    for _page in range(LOG_LENGTH + 2):
        page = peer_log(active_user.id, *page_bounds(cursor, limit))
        seen.extend(record["seq"] for record in page["records"])
        if not page["has_more"]:
            break
        cursor = page["records"][-1]["seq"]
    else:  # pragma: no cover - a walk that never exhausts is the failure
        pytest.fail("the walk never reached the end of the log")

    assert seen == list(range(LOG_LENGTH))


def test_a_cursor_at_or_past_the_head_serves_nothing_and_still_names_the_head(
    http, active_user, device, bearer, peer, peer_device, a_log
):
    """The boundary a caught-up poller sits on: it holds the head as its cursor and
    must be told there is nothing new without losing sight of where the head is."""
    theirs = bearer(peer, peer_device)

    caught_up = http.get(
        peer_log_url(active_user.id, f"?after={LOG_LENGTH - 1}"), headers=theirs
    ).json()

    assert caught_up == {"records": [], "has_more": False, "head_seq": LOG_LENGTH - 1}


def test_a_cursor_far_beyond_any_stored_sequence_is_answered_not_refused(
    http, active_user, device, bearer, peer, peer_device, a_log
):
    """A corrupted bookmark can carry a number no `bigint` column could hold. It
    must come back as an empty page rather than as a database error."""
    theirs = bearer(peer, peer_device)

    enormous = http.get(
        peer_log_url(active_user.id, f"?after={'9' * 40}"), headers=theirs
    )

    assert enormous.status_code == 200
    assert enormous.json()["records"] == []
    assert enormous.json()["head_seq"] == LOG_LENGTH - 1


@many_connections
def test_parallel_batch_appends_land_as_contiguous_blocks_that_never_interleave(
    new_http, active_user, device, bearer
):
    """Six clients appending three records each. `seq` is assigned under the account
    row lock, so each batch must occupy one unbroken run: a batch split by another
    client's records would break the hash chain every record in it was signed over,
    and no client could ever repair it."""
    batches, per_batch = 6, 3
    headers = bearer(active_user, device)
    start = threading.Barrier(batches)
    answers, failures = [], []
    lock = threading.Lock()

    def append(index):
        try:
            connect_then_wait(start)
            response = new_http().post(
                LOG_URL,
                json={"records": [{"blob": log_blob(bytes([65 + index]))}] * per_batch},
                headers=headers,
            )
            if response.status_code != 201:
                with lock:
                    failures.append(response.status_code)
                return
            with lock:
                answers.append((index, response.json()))
        except Exception as exc:  # noqa: BLE001 - surfaced through `failures`
            with lock:
                failures.append(repr(exc))
        finally:
            connections.close_all()

    threads = [threading.Thread(target=append, args=(i,)) for i in range(batches)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert failures == []
    stored = dict(
        DeviceLogRecord.objects.filter(user=active_user).values_list("seq", "blob")
    )
    assert sorted(stored) == list(range(batches * per_batch))
    claimed = []
    for index, body in answers:
        block = list(range(body["first_seq"], body["last_seq"] + 1))
        assert len(block) == per_batch
        mine = (bytes([65 + index]) * min(DEVICELOG_BUCKETS))[: min(DEVICELOG_BUCKETS)]
        assert [bytes(stored[seq]) for seq in block] == [mine] * per_batch
        claimed.extend(block)
    assert sorted(claimed) == list(range(batches * per_batch))
