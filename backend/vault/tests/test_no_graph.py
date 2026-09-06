"""No-graph proof for vault_keybackup, the vault's only remaining table.

A dump of the table shows only {user_id, blob, version}: the blob is an exact bucket
length, and the single user reference is the backup's owner. ADR-0024 stopped writing
the date this table used to carry and `vault.0003_drop_the_retired_date` dropped the
column, so there is no when to read. No column links a second user, and no history
table exists in this app at all (vault/tests/test_no_history.py proves that
removal).
"""

import base64

import pytest
from django.db import connection

from core.buckets import BACKUP_BUCKETS
from vault.models import KeyBackup

from .conftest import KEYBACKUP_URL, backup_blob, make_device

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

EXPECTED_COLUMNS = {"user_id", "blob", "version"}


def test_keybackup_columns_are_exactly_the_minimum():
    with connection.cursor() as cur:
        columns = {
            c.name
            for c in connection.introspection.get_table_description(
                cur, KeyBackup._meta.db_table
            )
        }
    assert columns == EXPECTED_COLUMNS, columns

    # The only foreign key to a user is the owner; there is no second-user column.
    user_fks = [
        f.name
        for f in KeyBackup._meta.get_fields()
        if getattr(f, "many_to_one", False) or getattr(f, "one_to_one", False)
    ]
    assert user_fks == ["user"]


def test_stored_blob_is_bucket_sized_and_no_date_is_stored(
    http, active_user, device, bearer
):
    http.put(
        KEYBACKUP_URL,
        json={"blob": backup_blob(), "version": 1},
        headers=bearer(active_user, device),
    )
    backup = KeyBackup.objects.get(user_id=active_user.id)

    assert len(bytes(backup.blob)) in set(BACKUP_BUCKETS)
    # No date at all: ADR-0024 stopped writing one and run 08 dropped the column, so
    # a dump of this table carries no field the row could put a day in.
    assert not hasattr(backup, "updated_date")


def dump(user_id):
    """The stored row exactly as PostgreSQL holds it, read outside the ORM so no
    model field can hide a column from this test."""
    with connection.cursor() as cur:
        cur.execute("SELECT * FROM vault_keybackup WHERE user_id = %s", [str(user_id)])
        columns = [c.name for c in cur.description]
        return dict(zip(columns, cur.fetchone(), strict=True))


def test_the_row_never_records_which_device_wrote_it(http, active_user, device, bearer):
    """Two devices of one account write in turn, and the row must look the same
    either way. Which device holds the recovery secret is a graph edge, and a
    `written_by` column would be that edge written down."""
    second = make_device(active_user, registration_id=77)
    http.put(
        KEYBACKUP_URL,
        json={"blob": backup_blob(b"1"), "version": 1},
        headers=bearer(active_user, device),
    )
    after_first = dump(active_user.id)

    http.put(
        KEYBACKUP_URL,
        json={"blob": backup_blob(b"2"), "version": 2},
        headers=bearer(active_user, second),
    )
    after_second = dump(active_user.id)

    assert set(after_first) == set(after_second) == EXPECTED_COLUMNS
    written = " ".join(repr(value) for value in after_second.values())
    assert str(device.id) not in written
    assert str(second.id) not in written


def test_the_row_names_its_owner_and_no_other_account(
    http, active_user, device, bearer, bob, bob_device
):
    """The one identifier in the row is the owner's, and it is the primary key —
    so the table cannot express a relationship between two accounts at all."""
    for user, dev, filler in (
        (active_user, device, b"A"),
        (bob, bob_device, b"B"),
    ):
        http.put(
            KEYBACKUP_URL,
            json={"blob": backup_blob(filler), "version": 1},
            headers=bearer(user, dev),
        )

    mine = dump(active_user.id)
    assert str(mine["user_id"]) == str(active_user.id)
    assert str(bob.id) not in " ".join(repr(value) for value in mine.values())


def test_the_stored_bytes_are_the_bytes_that_were_uploaded(
    http, active_user, device, bearer
):
    """The blind-relay property at rest: what PostgreSQL holds is the client's
    ciphertext, byte for byte, with nothing prepended, appended or re-encoded."""
    uploaded = base64.b64encode(bytes(range(256)) * 16).decode()

    http.put(
        KEYBACKUP_URL,
        json={"blob": uploaded, "version": 1},
        headers=bearer(active_user, device),
    )

    assert bytes(dump(active_user.id)["blob"]) == base64.b64decode(uploaded)


def test_the_read_response_carries_no_identifier(http, active_user, device, bearer):
    """The answer is the blob and its version. A user id, a device id or a
    username in it would let a stolen response be attributed to an account."""
    headers = bearer(active_user, device)
    http.put(KEYBACKUP_URL, json={"blob": backup_blob(), "version": 1}, headers=headers)

    body = http.get(KEYBACKUP_URL, headers=headers).text

    assert str(active_user.id) not in body
    assert str(device.id) not in body
    assert active_user.username not in body


def test_writing_many_times_leaves_one_row_and_one_table(
    http, active_user, device, bearer
):
    """A per-write audit row, wherever it lived, would show up as a second row or
    a second `vault_` table. Neither may appear."""
    headers = bearer(active_user, device)
    for version in range(1, 6):
        http.put(
            KEYBACKUP_URL,
            json={"blob": backup_blob(b"W"), "version": version},
            headers=headers,
        )

    assert KeyBackup.objects.count() == 1
    tables = {
        name
        for name in connection.introspection.table_names()
        if name.startswith("vault_")
    }
    assert tables == {KeyBackup._meta.db_table}
