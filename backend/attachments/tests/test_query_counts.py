"""Query-shape guard for the attachment routes.

Counted end to end through the composed application, so each number includes the
one query the authentication dependency makes: the device row joined to its
owner. `transaction=True` makes the transaction statements real BEGIN/COMMIT
rather than savepoints, and they are excluded here so the number is the database
work itself.
"""

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext

from attachments.models import Attachment
from core.buckets import ATTACHMENT_BUCKETS

pytestmark = pytest.mark.django_db(transaction=True)

TRANSACTION_STATEMENTS = ("BEGIN", "COMMIT", "SAVEPOINT", "RELEASE", "ROLLBACK")

AUTH_QUERY = 1  # the device row, joined to its owner
# One insert, and nothing else. The row lock and the SUM aggregate over the
# account's own rows left with the lifetime quota (ADR-0025); the day's allowance
# is charged in Redis, which is two round trips on the first upload of a day and
# one on every upload after it, and no statement at all.
UPLOAD_QUERIES = 1

UPLOAD_URL = "/api/v1/attachments"
SMALLEST = min(ATTACHMENT_BUCKETS)


def counted(http, method, url, expected, **kwargs):
    with CaptureQueriesContext(connection) as context:
        response = http.request(method, url, **kwargs)
    sqls = [
        query["sql"]
        for query in context.captured_queries
        if not query["sql"].startswith(TRANSACTION_STATEMENTS)
    ]
    assert len(sqls) == expected, "\n".join(sqls)
    return response


@pytest.mark.parametrize("existing", [0, 25])
def test_the_upload_is_one_insert_however_many_files_exist(
    http, active_user, device, bearer, existing
):
    """The cost that AR-8 recorded is gone rather than reduced: the upload reads no
    row of this table at all, so it does not grow with what is already stored."""
    Attachment.objects.bulk_create([Attachment(size=SMALLEST) for _ in range(existing)])

    resp = counted(
        http,
        "POST",
        UPLOAD_URL,
        AUTH_QUERY + UPLOAD_QUERIES,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 201


def test_the_download_is_a_single_lookup(http, active_user, device, bearer):
    cap = http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    ).json()["attachment_id"]

    resp = counted(
        http,
        "GET",
        f"{UPLOAD_URL}/{cap}",
        AUTH_QUERY + 1,
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 200


def test_a_capability_that_names_no_row_is_the_same_single_lookup(
    http, active_user, device, bearer
):
    """A miss must not cost more than a hit: the id is unguessable, so a scan on
    the way to a `404` would be work any caller could ask for at will."""
    resp = counted(
        http,
        "GET",
        f"{UPLOAD_URL}/{'z' * 43}",
        AUTH_QUERY + 1,
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 404


def test_a_body_the_route_cannot_read_costs_nothing_but_the_credential(
    http, active_user, device, bearer
):
    """The parse fails before any unit of work opens, so a malformed upload is one
    query — the credential the dependency already had to read."""
    resp = counted(
        http,
        "POST",
        UPLOAD_URL,
        AUTH_QUERY,
        data={"blob": "not a file part"},
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 400


def test_an_allowance_refusal_costs_no_statement_at_all(
    http, active_user, device, bearer, settings, attachments_root
):
    """The refusal is settled in Redis before the bytes are copied, so the only
    statement the request makes is the credential the dependency already read."""
    settings.ATTACH_DAILY_BYTES = SMALLEST - 1

    resp = counted(
        http,
        "POST",
        UPLOAD_URL,
        AUTH_QUERY,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 413
    assert Attachment.objects.count() == 0
