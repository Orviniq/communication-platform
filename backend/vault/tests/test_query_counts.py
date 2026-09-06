"""Query-shape guards for the key-backup route.

Counted end to end through the composed application, so each number includes the
one query the authentication dependency makes. Transaction statements are
excluded, so the number is the database work itself.
"""

import re

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext

from .conftest import KEYBACKUP_URL, backup_blob

pytestmark = pytest.mark.django_db(transaction=True)

TRANSACTION_STATEMENTS = ("BEGIN", "COMMIT", "SAVEPOINT", "RELEASE", "ROLLBACK")

AUTH_QUERY = 1  # the device row, joined to its owner


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


def test_reading_the_backup_is_one_lookup(http, active_user, device, bearer):
    headers = bearer(active_user, device)
    http.put(KEYBACKUP_URL, json={"blob": backup_blob(), "version": 1}, headers=headers)

    response = counted(http, "GET", KEYBACKUP_URL, AUTH_QUERY + 1, headers=headers)

    assert response.status_code == 200


def test_a_write_is_the_owner_lock_the_version_probe_and_one_upsert(
    http, active_user, device, bearer
):
    """The owner row is locked because the backup row may not exist yet; the
    version probe reads the stored version without dragging the blob back with it;
    update_or_create is the remaining SELECT and write."""
    headers = bearer(active_user, device)

    response = counted(
        http,
        "PUT",
        KEYBACKUP_URL,
        AUTH_QUERY + 4,
        json={"blob": backup_blob(), "version": 1},
        headers=headers,
    )

    assert response.status_code == 200


def statements(http, method, url, **kwargs):
    """The non-transactional SQL one request ran, for the tests that care about
    the shape of a statement rather than how many there were."""
    with CaptureQueriesContext(connection) as context:
        response = http.request(method, url, **kwargs)
    return response, [
        query["sql"]
        for query in context.captured_queries
        if not query["sql"].startswith(TRANSACTION_STATEMENTS)
    ]


def test_reading_a_missing_backup_costs_the_same_single_lookup(
    http, active_user, device, bearer
):
    """The 404 path must not be cheaper or dearer than the 200 path: a difference
    in work is a difference an observer can time."""
    response = counted(
        http, "GET", KEYBACKUP_URL, AUTH_QUERY + 1, headers=bearer(active_user, device)
    )

    assert response.status_code == 404


def test_a_stale_write_stops_before_the_upsert(http, active_user, device, bearer):
    """The refusal costs the owner lock and the version probe and nothing else —
    no row is read back, and no write is attempted and rolled back."""
    headers = bearer(active_user, device)
    http.put(KEYBACKUP_URL, json={"blob": backup_blob(), "version": 5}, headers=headers)

    response = counted(
        http,
        "PUT",
        KEYBACKUP_URL,
        AUTH_QUERY + 2,
        json={"blob": backup_blob(b"S"), "version": 5},
        headers=headers,
    )

    assert response.status_code == 409


def test_replacing_an_existing_backup_costs_what_creating_one_did(
    http, active_user, device, bearer
):
    """The update path and the insert path run the same four statements, so a
    client cannot tell from timing whether an account already had a backup."""
    headers = bearer(active_user, device)
    http.put(KEYBACKUP_URL, json={"blob": backup_blob(), "version": 1}, headers=headers)

    response = counted(
        http,
        "PUT",
        KEYBACKUP_URL,
        AUTH_QUERY + 4,
        json={"blob": backup_blob(b"U"), "version": 2},
        headers=headers,
    )

    assert response.status_code == 200


def test_the_read_asks_for_the_two_response_fields_and_the_key(
    http, active_user, device, bearer
):
    """`.only("blob", "version")` is the whole point: the response carries two
    fields, so the query must ask for two columns and the key that finds them.

    The column list is read out of the statement rather than probed for one name.
    `updated_date` was the name this asserted against until run 08 dropped it, and a
    test that names a column nobody has passes whatever the query selects.
    """
    headers = bearer(active_user, device)
    http.put(KEYBACKUP_URL, json={"blob": backup_blob(), "version": 1}, headers=headers)

    response, sqls = statements(http, "GET", KEYBACKUP_URL, headers=headers)

    read = next(sql for sql in sqls if "vault_keybackup" in sql)
    selected = re.findall(r'"vault_keybackup"\."(\w+)"', read.split(" FROM ")[0])
    assert response.status_code == 200
    assert selected == ["user_id", "blob", "version"]


def test_the_version_probe_never_reads_the_blob(http, active_user, device, bearer):
    """A write compares versions; pulling the stored megabyte back to do it would
    be a megabyte of ciphertext crossing the wire for nothing."""
    headers = bearer(active_user, device)
    http.put(KEYBACKUP_URL, json={"blob": backup_blob(), "version": 1}, headers=headers)

    response, sqls = statements(
        http,
        "PUT",
        KEYBACKUP_URL,
        json={"blob": backup_blob(b"P"), "version": 1},
        headers=headers,
    )

    head = 'SELECT "vault_keybackup"."version"'
    probe = next(sql for sql in sqls if sql.startswith(head))
    assert response.status_code == 409
    assert '"blob"' not in probe


def test_a_write_takes_the_owner_lock_before_it_looks_at_the_backup(
    http, active_user, device, bearer
):
    """The ordering the first-write race depends on, read off the statements the
    request actually ran: the `FOR UPDATE` on the account comes first."""
    response, sqls = statements(
        http,
        "PUT",
        KEYBACKUP_URL,
        json={"blob": backup_blob(), "version": 1},
        headers=bearer(active_user, device),
    )

    lock = next(
        i for i, sql in enumerate(sqls) if "accounts_user" in sql and "FOR UPDATE" in sql
    )
    probe = next(i for i, sql in enumerate(sqls) if "vault_keybackup" in sql)
    assert response.status_code == 200
    assert lock < probe


def test_repeated_writes_do_not_grow_the_work_per_write(
    http, active_user, device, bearer
):
    """The rare case a per-write history table would show up in: the cost of a
    write stays flat across five of them, because nothing accumulates."""
    headers = bearer(active_user, device)
    costs = []

    for version in range(1, 6):
        response, sqls = statements(
            http,
            "PUT",
            KEYBACKUP_URL,
            json={"blob": backup_blob(b"R"), "version": version},
            headers=headers,
        )
        assert response.status_code == 200
        costs.append(len(sqls))

    assert costs == [AUTH_QUERY + 4] * 5
