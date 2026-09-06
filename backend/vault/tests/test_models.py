"""The one table this app owns.

The shape of `KeyBackup` is a design decision, not an accident: the owner is the
primary key, so the database itself is what makes "one backup per account" true;
the blob column is declared with the bucket set the route enforces; and the
timestamp is a date, so the row cannot say when in the day a device was awake.
"""

import pytest
from django.db import IntegrityError

from core.buckets import BACKUP_BUCKETS
from core.fields import OpaqueBlobField
from vault.models import KeyBackup

pytestmark = pytest.mark.django_db(transaction=True)

SMALLEST = min(BACKUP_BUCKETS)


def store(user, filler=b"M", version=1):
    return KeyBackup.objects.create(
        user=user, blob=(filler * SMALLEST)[:SMALLEST], version=version
    )


def test_the_owner_is_the_primary_key():
    """One row per account is a database rule, not a code convention: there is no
    surrogate id a second row could take."""
    pk = KeyBackup._meta.pk

    assert pk.name == "user"
    assert pk.one_to_one
    assert pk.remote_field.related_name == "keybackup"


def test_a_second_backup_for_one_account_cannot_be_inserted(active_user):
    store(active_user)

    with pytest.raises(IntegrityError):
        KeyBackup.objects.create(user=active_user, blob=b"x" * SMALLEST, version=2)


def test_the_row_is_reachable_from_its_owner_by_the_documented_accessor(active_user):
    store(active_user, b"A", version=3)

    active_user.refresh_from_db()
    assert active_user.keybackup.version == 3


def test_deleting_the_account_takes_the_backup_with_it(active_user):
    store(active_user)

    active_user.delete()

    assert KeyBackup.objects.count() == 0


def test_deleting_the_backup_leaves_the_account(active_user):
    """The cascade runs one way only — a client discarding its backup must not
    discard the account with it."""
    store(active_user).delete()

    assert type(active_user).objects.filter(id=active_user.id).exists()


def test_the_table_carries_exactly_three_concrete_columns():
    names = [field.name for field in KeyBackup._meta.concrete_fields]

    assert names == ["user", "blob", "version"]
    assert KeyBackup._meta.db_table == "vault_keybackup"


def test_the_blob_column_declares_the_backup_bucket_set():
    """The model and `vault/schemas.py` must agree on which lengths exist, or the
    route would admit a length the column was never designed to hold."""
    field = KeyBackup._meta.get_field("blob")

    assert isinstance(field, OpaqueBlobField)
    assert field.bucket_set == set(BACKUP_BUCKETS)
    assert field.editable is False


def test_the_version_column_starts_at_zero_and_refuses_a_negative(active_user):
    row = KeyBackup.objects.create(user=active_user, blob=b"v" * SMALLEST)

    assert row.version == 0
    with pytest.raises(IntegrityError):
        KeyBackup.objects.filter(pk=row.pk).update(version=-1)


def test_no_save_stamps_a_time_of_any_kind(active_user):
    """A day the account last wrote its backup is a presence signal, and ADR-0024
    stopped recording one. `vault.0003_drop_the_retired_date` took the column with
    it, so a seizure of this table has no column to read a when from at all."""
    stored = store(active_user)

    assert [
        field.name
        for field in type(stored)._meta.concrete_fields
        if field.get_internal_type() in ("DateField", "DateTimeField")
    ] == []


@pytest.mark.parametrize(
    "payload",
    [
        pytest.param(bytes(SMALLEST), id="all nul bytes"),
        pytest.param(bytes(range(256)) * (SMALLEST // 256), id="every byte value"),
        pytest.param(b"\xff" * SMALLEST, id="all high bytes"),
    ],
)
def test_bytea_returns_the_bytes_it_was_given(active_user, payload):
    """The rare cases that a text column would mangle: the server stores
    ciphertext, which is uniformly random, so every byte value has to survive."""
    store(active_user, b"placeholder")
    KeyBackup.objects.filter(user_id=active_user.id).update(blob=payload)

    assert bytes(KeyBackup.objects.get(user_id=active_user.id).blob) == payload
