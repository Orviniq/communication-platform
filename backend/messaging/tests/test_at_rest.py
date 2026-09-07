"""What a seized `messaging_queuedenvelope` table yields: fan-out must leave N
independent rows that a dump cannot join back into a conversation.

`transaction=True` matters on these tests: pg_dump runs in a separate process over a
separate connection, so it sees only committed rows.
"""

import base64
from datetime import date, timedelta
from io import StringIO

import pytest
from django.core.management import call_command
from django.utils import timezone

from accounts.models import User
from accounts.tests.test_at_rest import PG_DUMP, pg_dump_table
from core.buckets import ENVELOPE_BUCKETS
from messaging.models import QueuedEnvelope

from .conftest import PASSWORD, envelope_blob, make_device

TABLE = "messaging_queuedenvelope"

# The routing minimum and nothing else. A column added here fails this test on purpose.
EXPECTED_COLUMNS = {
    "id",
    "recipient_device_id",
    "seq",
    "blob",
    "queued_day",
}


def copy_block(dump, table):
    """Parse pg_dump's COPY block into (column names, row dicts)."""
    lines = dump.splitlines()
    for i, line in enumerate(lines):
        if line.startswith(f"COPY public.{table} "):
            cols = line[line.index("(") + 1 : line.index(")")].split(", ")
            rows = []
            for raw in lines[i + 1 :]:
                if raw == "\\.":
                    break
                rows.append(dict(zip(cols, raw.split("\t"))))
            return cols, rows
    raise AssertionError(f"no COPY block for {table} in the dump")


@pytest.fixture
def three_recipient_devices(db):
    bob = User.objects.create_user(username="bob", password=PASSWORD, is_active=True)
    carol = User.objects.create_user(username="carol", password=PASSWORD, is_active=True)
    return [make_device(bob, 11), make_device(bob, 12), make_device(carol, 21)]


@pytest.mark.skipif(PG_DUMP is None, reason="pg_dump not on PATH")
@pytest.mark.django_db(transaction=True)
def test_a_seized_queue_shows_no_sender_and_no_link_between_co_recipients(
    http, active_user, device, bearer, three_recipient_devices
):
    # One logical message to 3 devices across 2 users; a real client encrypts per
    # device, so the three copies differ.
    resp = http.post(
        "/api/v1/envelopes",
        json={
            "messages": [
                {"device_id": str(d.id), "blob": envelope_blob(bytes([65 + i]))}
                for i, d in enumerate(three_recipient_devices)
            ]
        },
        headers=bearer(active_user, device),
    )
    assert resp.status_code == 202

    cols, rows = copy_block(pg_dump_table(TABLE), TABLE)

    # (a) No sender column exists — sender identity lives only inside the ciphertext.
    assert [c for c in cols if "sender" in c.lower()] == []
    assert set(cols) == EXPECTED_COLUMNS, "the queue grew a column it must not have"

    # (b) Three independent rows. The only thing tying a row to anyone is its own
    # recipient device; no shared row id and no shared blob to join co-recipients on.
    # `seq` and `queued_day` coincide across the three rows by design: seq is
    # per-device (every fresh mailbox starts at 1) and the day is deliberately coarse.
    # Neither links co-recipients; a third party's row would carry the same values.
    assert len(rows) == 3
    assert len({r["recipient_device_id"] for r in rows}) == 3
    assert len({r["id"] for r in rows}) == 3
    assert len({r["blob"] for r in rows}) == 3

    # (c) Every stored blob is exactly one bucket long. pg_dump renders bytea as \x<hex>,
    # backslash-escaped again by the COPY text format.
    for row in rows:
        hexed = row["blob"].lstrip("\\")
        assert hexed.startswith("x"), f"unexpected bytea rendering: {hexed[:8]}"
        assert len(hexed[1:]) // 2 in set(ENVELOPE_BUCKETS)

    # (d) Nothing finer than the day is recorded (ADR-0025). A date column carries
    # no time at all, and the column that used to carry an hour has left the table
    # entirely — so a dump can say which day a device was addressed on and never
    # which part of it. The column set asserted above is what holds the second half.
    for row in rows:
        assert date.fromisoformat(row["queued_day"]) == timezone.now().date()

    # The sender is in none of it: alice sent all three and appears nowhere.
    dump = pg_dump_table(TABLE)
    assert str(active_user.id) not in dump
    assert str(device.id) not in dump


@pytest.mark.skipif(PG_DUMP is None, reason="pg_dump not on PATH")
@pytest.mark.django_db(transaction=True)
def test_an_acked_envelope_leaves_no_trace_in_a_raw_table_dump(
    http, active_user, device, bearer, three_recipient_devices
):
    """Retention honored: delivery-ack deletes the row, so a dump taken afterwards
    holds neither the row nor the ciphertext. What a seizure captures is bounded by
    the undelivered set, never by delivered traffic."""
    recipient = three_recipient_devices[0]
    blob = envelope_blob(b"W")
    resp = http.post(
        "/api/v1/envelopes",
        json={"messages": [{"device_id": str(recipient.id), "blob": blob}]},
        headers=bearer(active_user, device),
    )
    assert resp.status_code == 202

    owner_headers = bearer(recipient.user, recipient)
    drained = http.get("/api/v1/me/envelopes", headers=owner_headers).json()["envelopes"]
    assert len(drained) == 1
    acked = http.post(
        "/api/v1/me/envelopes/ack",
        json={"ids": [drained[0]["id"]]},
        headers=owner_headers,
    )
    assert acked.json() == {"deleted": 1}

    dump = pg_dump_table(TABLE)
    _cols, rows = copy_block(dump, TABLE)
    assert rows == []
    assert base64.b64decode(blob).hex() not in dump  # bytea renders as \x<hex>


@pytest.mark.django_db
def test_the_model_declares_no_sender_or_recipient_list_field():
    """The schema half of the same guard, so a regression fails fast without pg_dump."""
    from messaging.models import QueuedEnvelope

    names = {f.name for f in QueuedEnvelope._meta.get_fields()}

    assert names == {"id", "recipient_device", "seq", "blob", "queued_day"}
    assert not any("sender" in n for n in names)


@pytest.mark.skipif(PG_DUMP is None, reason="pg_dump not on PATH")
@pytest.mark.django_db(transaction=True)
def test_a_ttl_pruned_envelope_leaves_no_trace_in_a_raw_table_dump(
    http, active_user, device, bearer, three_recipient_devices, settings
):
    """The other retention path, and the one that runs without a client.

    Delivery-ack bounds a seizure by what the recipient has not yet fetched; the
    TTL bounds it by time, for the mailbox of a device that never comes back. A
    row that survived its window would make the queue an archive of every
    undelivered message the deployment has ever carried.
    """
    settings.ENVELOPE_TTL_DAYS = 7
    recipient = three_recipient_devices[0]
    blob = envelope_blob(b"T")
    resp = http.post(
        "/api/v1/envelopes",
        json={"messages": [{"device_id": str(recipient.id), "blob": blob}]},
        headers=bearer(active_user, device),
    )
    assert resp.status_code == 202
    stored = QueuedEnvelope.objects.get(recipient_device_id=recipient.id)
    QueuedEnvelope.objects.filter(id=stored.id).update(
        queued_day=timezone.now().date() - timedelta(days=8)
    )

    call_command("prune", stdout=StringIO())

    dump = pg_dump_table(TABLE)
    _cols, rows = copy_block(dump, TABLE)
    assert rows == []
    assert base64.b64decode(blob).hex() not in dump  # bytea renders as \x<hex>
    assert str(stored.id) not in dump


@pytest.mark.skipif(PG_DUMP is None, reason="pg_dump not on PATH")
@pytest.mark.django_db(transaction=True)
def test_a_drained_envelope_is_still_at_rest_until_it_is_acked(
    http, active_user, device, bearer, three_recipient_devices
):
    """Draining consumes nothing, and the dump is where that is visible rather
    than inferred: the row a client has read is still on disk, which is what makes
    a drain safe to repeat after a crash — and what makes the ack, not the read,
    the moment retention takes effect."""
    recipient = three_recipient_devices[0]
    blob = envelope_blob(b"D")
    http.post(
        "/api/v1/envelopes",
        json={"messages": [{"device_id": str(recipient.id), "blob": blob}]},
        headers=bearer(active_user, device),
    )
    owner_headers = bearer(recipient.user, recipient)

    first = http.get("/api/v1/me/envelopes", headers=owner_headers).json()
    second = http.get("/api/v1/me/envelopes", headers=owner_headers).json()

    assert [one["id"] for one in first["envelopes"]] == [
        one["id"] for one in second["envelopes"]
    ]
    _cols, rows = copy_block(pg_dump_table(TABLE), TABLE)
    assert len(rows) == 1
    assert rows[0]["recipient_device_id"] == str(recipient.id)
