"""What the device tables guarantee on their own, below every route.

Three kinds of promise live here rather than in the service layer, and a change to
`devices/models.py` is the only thing that can break them:

* the state a row is *born* in — a device that has never been cross-signed, whose
  tokens are generation 1 and whose mailbox counter is 0;
* the constraints that turn a malformed write into an error instead of a duplicate
  — `unique (device, key_id)` and `unique (user, seq)`;
* what a removal takes with it, since forward secrecy depends on a revoked or
  deleted device leaving no claimable key material behind.

The two `db_index=False` declarations are checked against the database's own index
list: the comment on each says the unique constraint already indexes the column as
its leading key, and a redundant B-tree maintained on every insert is exactly the
kind of thing that comes back by accident.
"""

import pytest
from django.db import IntegrityError, connection, transaction
from django.utils import timezone

from core.buckets import DEVICELOG_BUCKETS, LABEL_BUCKETS
from devices.models import (
    Device,
    DeviceLogRecord,
    OneTimePrekey,
    PqOneTimePrekey,
    UserIdentity,
)
from devices.schemas import PQ_PUBKEY_LEN

from .conftest import make_device, publish_identity, stock_pq_prekeys, stock_prekeys

pytestmark = pytest.mark.django_db(transaction=True)


def indexes_on(model):
    """Every index the database actually holds for a table, as column tuples."""
    with connection.cursor() as cursor:
        constraints = connection.introspection.get_constraints(
            cursor, model._meta.db_table
        )
    return [
        tuple(entry["columns"])
        for entry in constraints.values()
        if entry.get("index") or entry.get("unique")
    ]


def test_a_new_device_is_born_never_cross_signed_and_never_used(active_user):
    """The state peers already refuse, and the state the token checks start from.
    A default that drifted — a bundle_version of 1, a token_generation of 0 —
    would make an unsigned device look signed or every issued token look stale."""
    device = make_device(active_user, registration_id=11)

    assert device.cross_sig is None
    assert device.bundle_version == 0
    assert device.token_generation == 1
    assert device.queue_seq == 0
    assert device.queue_pruned_through == 0
    assert device.label_blob is None
    assert device.revoked_date is None
    assert device.pq_spk_id is None
    assert device.pq_spk_pub is None
    assert device.pq_spk_sig is None


def test_the_only_date_a_device_is_stamped_with_is_day_coarse(active_user):
    """`created_date` is a date, not a timestamp: the own-list orders by
    `(created_date, id)` precisely because the date alone leaves same-day devices in
    an arbitrary order.

    It is also the only stamp left. ADR-0024 stopped writing every other date on
    this row and `devices.0003_drop_the_retired_columns` dropped their columns, so a
    device row carries a creation day and no other date at all.
    """
    device = make_device(active_user, registration_id=12)

    assert device.created_date == timezone.now().date()
    dates = {
        field.name
        for field in device._meta.concrete_fields
        if field.get_internal_type() in ("DateField", "DateTimeField")
    }
    assert dates == {"created_date", "revoked_date"}


def test_two_devices_of_one_account_hold_independent_key_material(active_user):
    first = make_device(active_user, registration_id=13)
    second = make_device(active_user, registration_id=14)
    stock_prekeys(first, 2, start=0)
    stock_prekeys(second, 2, start=0)  # the same key ids, a different device

    assert first.id != second.id
    assert OneTimePrekey.objects.filter(device=first).count() == 2
    assert OneTimePrekey.objects.filter(device=second).count() == 2
    assert set(active_user.devices.values_list("id", flat=True)) == {
        first.id,
        second.id,
    }


@pytest.mark.parametrize(
    "model, stock, pub",
    [
        (OneTimePrekey, stock_prekeys, b"p" * 32),
        (PqOneTimePrekey, stock_pq_prekeys, b"q" * PQ_PUBKEY_LEN),
    ],
)
def test_a_repeated_key_id_on_one_device_is_refused_by_the_database(
    active_user, model, stock, pub
):
    """The constraint the schema's duplicate check exists to stay in front of. If it
    were dropped, a repeated key_id would be stored twice and one claim would hand
    the same one-time key to two senders."""
    device = make_device(active_user, registration_id=15)
    stock(device, 1, start=7)

    with pytest.raises(IntegrityError):
        with transaction.atomic():
            model.objects.create(device=device, key_id=7, pub=pub)

    assert model.objects.filter(device=device).count() == 1


def test_two_users_may_hold_the_same_device_log_sequence_number(active_user, bob):
    """The log is per account, so `seq` is unique with the user and not on its own —
    otherwise the second account to append would collide with the first."""
    DeviceLogRecord.objects.create(user=active_user, seq=0, blob=b"a" * 256)
    DeviceLogRecord.objects.create(user=bob, seq=0, blob=b"b" * 256)

    assert DeviceLogRecord.objects.filter(seq=0).count() == 2


def test_an_account_holds_at_most_one_published_identity(active_user):
    """`primary_key=True` on the one-to-one is what makes the upsert in
    `publish_identity` an upsert rather than a growing pile of identities."""
    publish_identity(active_user, version=1)

    with pytest.raises(IntegrityError):
        with transaction.atomic():
            UserIdentity.objects.create(
                user=active_user,
                master_pub=b"z" * 32,
                self_signing_pub=b"z" * 32,
                user_signing_pub=b"z" * 32,
                master_sig=b"z" * 64,
                version=2,
            )

    assert UserIdentity.objects.filter(user=active_user).count() == 1


def test_deleting_a_device_takes_both_prekey_pools_with_it(active_user):
    """Revocation keeps the row and empties the pools; a hard delete — which only
    a cascade from the account performs — must leave nothing claimable either."""
    device = make_device(active_user, registration_id=16)
    stock_prekeys(device, 3)
    stock_pq_prekeys(device, 3)

    device.delete()

    assert OneTimePrekey.objects.count() == 0
    assert PqOneTimePrekey.objects.count() == 0


def test_deleting_an_account_takes_its_whole_device_estate_with_it(active_user, bob):
    """Erasure has to be complete: devices, key material, the published identity and
    the device-list log. The second account is here so the cascade is shown to be
    scoped to one owner rather than emptying the tables."""
    mine = make_device(active_user, registration_id=17)
    stock_prekeys(mine, 2)
    stock_pq_prekeys(mine, 2)
    publish_identity(active_user)
    DeviceLogRecord.objects.create(user=active_user, seq=0, blob=b"r" * 256)
    theirs = make_device(bob, registration_id=18)
    stock_prekeys(theirs, 2)
    publish_identity(bob)
    DeviceLogRecord.objects.create(user=bob, seq=0, blob=b"r" * 256)

    active_user.delete()

    assert Device.objects.count() == 1
    assert list(Device.objects.values_list("id", flat=True)) == [theirs.id]
    assert OneTimePrekey.objects.filter(device=theirs).count() == 2
    assert PqOneTimePrekey.objects.count() == 0
    assert UserIdentity.objects.count() == 1
    assert DeviceLogRecord.objects.count() == 1


@pytest.mark.parametrize(
    "model, field, buckets",
    [
        (Device, "label_blob", LABEL_BUCKETS),
        (DeviceLogRecord, "blob", DEVICELOG_BUCKETS),
    ],
)
def test_every_opaque_column_carries_its_bucket_set_and_is_not_editable(
    model, field, buckets
):
    """`editable=False` is what keeps a ciphertext column off every form the panel
    could build, and the bucket set is what a migration carries forward."""
    column = model._meta.get_field(field)

    assert column.bucket_set == set(buckets)
    assert column.editable is False
    assert column.deconstruct()[3]["bucket_set"] == sorted(buckets)


def test_an_opaque_blob_round_trips_byte_identically(active_user):
    """Including the bytes a text column would mangle: a NUL and the high half of
    the range. The server stores ciphertext and hands it back unchanged."""
    raw = bytes(range(256))
    record = DeviceLogRecord.objects.create(user=active_user, seq=0, blob=raw)

    record.refresh_from_db()

    assert bytes(record.blob) == raw
    assert b"\x00" in raw


@pytest.mark.parametrize(
    "model, column",
    [
        (OneTimePrekey, "device_id"),
        (PqOneTimePrekey, "device_id"),
        (DeviceLogRecord, "user_id"),
    ],
)
def test_no_redundant_index_shadows_the_leading_key_of_a_unique_constraint(model, column):
    """Each of these three foreign keys declares `db_index=False`, because the
    unique constraint beside it already indexes the column as its leading key. The
    default index would be a second B-tree maintained on every insert, and it comes
    back the moment someone drops that keyword."""
    held = indexes_on(model)

    assert (column,) not in held, f"{model.__name__} carries a redundant {column} index"
    assert any(entry[0] == column and len(entry) > 1 for entry in held), (
        f"{model.__name__} has no composite index leading with {column}"
    )
