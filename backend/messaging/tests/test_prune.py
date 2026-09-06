import base64
import os
from contextlib import contextmanager
from datetime import timedelta
from io import StringIO
from unittest import mock

import psycopg
import pytest
from django.contrib.admin.models import ADDITION, LogEntry
from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import DatabaseError, connection
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from attachments.models import Attachment
from core.buckets import ATTACHMENT_BUCKETS
from devices.models import Device
from messaging.management.commands import prune
from messaging.models import QueuedEnvelope

from .conftest import SMALLEST_BUCKET, make_device


def run_prune():
    out = StringIO()
    call_command("prune", stdout=out)
    return out.getvalue()


def queue_row(device, seq, age_days=0):
    row = QueuedEnvelope.objects.create(
        recipient_device=device, seq=seq, blob=b"a" * SMALLEST_BUCKET
    )
    if age_days:
        QueuedEnvelope.objects.filter(id=row.id).update(
            queued_day=timezone.now().date() - timedelta(days=age_days)
        )
    return row


def stored_attachment(root, age_days=0):
    attachment = Attachment.objects.create(size=min(ATTACHMENT_BUCKETS))
    path = root / attachment.id[:2] / attachment.id
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x01" * min(ATTACHMENT_BUCKETS))
    if age_days:
        Attachment.objects.filter(id=attachment.id).update(
            created_date=timezone.now().date() - timedelta(days=age_days)
        )
    return attachment, path


@pytest.fixture
def attachments_root(settings, tmp_path):
    settings.ATTACHMENTS_ROOT = tmp_path
    return tmp_path


@pytest.fixture
def expired_audit_rows(active_user, settings):
    """Five audit rows past the retention window, so a batch of two takes three
    passes."""
    rows = [
        LogEntry.objects.create(
            user=active_user, object_repr="x", action_flag=ADDITION, change_message=""
        )
        for _ in range(5)
    ]
    LogEntry.objects.filter(pk__in=[row.pk for row in rows]).update(
        action_time=timezone.now()
        - timedelta(days=settings.ADMIN_AUDIT_RETENTION_DAYS + 1)
    )
    return rows


@pytest.mark.django_db
def test_expired_queue_rows_go_and_fresh_ones_stay(device, settings):
    settings.ENVELOPE_TTL_DAYS = 30
    fresh = queue_row(device, 1)
    expired = queue_row(device, 2, age_days=31)

    output = run_prune()

    assert list(QueuedEnvelope.objects.values_list("id", flat=True)) == [fresh.id]
    assert "envelopes pruned: 1" in output
    assert str(expired.id) not in output


@pytest.mark.django_db
def test_expired_attachments_lose_both_row_and_bytes(attachments_root, settings):
    settings.ATTACH_TTL_DAYS = 30
    fresh, fresh_path = stored_attachment(attachments_root)
    expired, expired_path = stored_attachment(attachments_root, age_days=31)

    output = run_prune()

    assert list(Attachment.objects.values_list("id", flat=True)) == [fresh.id]
    assert fresh_path.exists()
    assert not expired_path.exists()
    assert "attachments pruned: 1 (files removed: 1)" in output


@pytest.mark.django_db
def test_a_missing_file_does_not_stop_the_row_being_cleared(attachments_root, settings):
    settings.ATTACH_TTL_DAYS = 30
    expired, path = stored_attachment(attachments_root, age_days=31)
    path.unlink()  # a previous run died between unlink and delete

    output = run_prune()

    assert not Attachment.objects.filter(id=expired.id).exists()
    assert "attachments pruned: 1 (files removed: 0)" in output


@pytest.mark.django_db
def test_one_unremovable_file_does_not_stall_the_whole_sweep(
    attachments_root, settings, monkeypatch
):
    """Rows are cleared in one pass after the loop, so an escaping OSError would stop
    retention altogether."""
    settings.ATTACH_TTL_DAYS = 30
    stuck, stuck_path = stored_attachment(attachments_root, age_days=31)
    ok, ok_path = stored_attachment(attachments_root, age_days=31)
    real_remove = os.remove

    def refuse_one(path, *args, **kwargs):
        if str(path) == str(stuck_path):
            raise PermissionError(13, "Permission denied")
        return real_remove(path, *args, **kwargs)

    monkeypatch.setattr(os, "remove", refuse_one)

    output = run_prune()

    # The healthy row is gone; the stuck one keeps its row so the next run retries it.
    assert not Attachment.objects.filter(id=ok.id).exists()
    assert Attachment.objects.filter(id=stuck.id).exists()
    assert not ok_path.exists()
    assert "attachments pruned: 1 (files removed: 1)" in output


@pytest.mark.django_db
def test_pruning_sets_the_watermark_to_the_max_pruned_seq_per_device(
    active_user, settings
):
    """A pruned envelope may have carried a ratchet message or a control event the
    device can never re-obtain, so the prune must leave a per-device high-water mark
    for the drain to surface."""
    settings.ENVELOPE_TTL_DAYS = 7
    lagging = make_device(active_user, 71)
    current = make_device(active_user, 72)
    queue_row(lagging, 3, age_days=8)
    queue_row(lagging, 4, age_days=8)
    queue_row(lagging, 5)  # fresh: survives, stays above the watermark
    queue_row(current, 9, age_days=8)

    run_prune()

    lagging.refresh_from_db()
    current.refresh_from_db()
    assert lagging.queue_pruned_through == 4
    assert current.queue_pruned_through == 9
    assert list(QueuedEnvelope.objects.values_list("seq", flat=True)) == [5]


@pytest.mark.django_db
def test_the_watermark_is_idempotent_and_never_regresses(active_user, settings):
    settings.ENVELOPE_TTL_DAYS = 7
    device = make_device(active_user, 73)
    queue_row(device, 6, age_days=8)

    run_prune()
    device.refresh_from_db()
    first = device.queue_pruned_through

    # A second pass deletes nothing and must not move the mark; nor may a later
    # pass over lower-seq stragglers pull it backwards.
    run_prune()
    queue_row(device, 2, age_days=8)
    run_prune()

    device.refresh_from_db()
    assert first == 6
    assert device.queue_pruned_through == 6


@pytest.mark.django_db
def test_prune_is_safe_to_run_repeatedly(device, attachments_root, settings):
    settings.ENVELOPE_TTL_DAYS = 30
    settings.ATTACH_TTL_DAYS = 30
    queue_row(device, 1, age_days=31)
    stored_attachment(attachments_root, age_days=31)

    first = run_prune()
    second = run_prune()

    assert "envelopes pruned: 1" in first
    assert "envelopes pruned: 0" in second
    assert "attachments pruned: 0 (files removed: 0)" in second


@pytest.mark.django_db
def test_prune_prints_counts_but_never_an_identifier(
    device, active_user, attachments_root, settings
):
    """The timer's stdout lands in the journal, so an id here would be a graph leak."""
    settings.ENVELOPE_TTL_DAYS = 30
    settings.ATTACH_TTL_DAYS = 30
    row = queue_row(device, 1, age_days=31)
    attachment, _path = stored_attachment(attachments_root, age_days=31)

    output = run_prune()

    for identifier in (str(row.id), str(device.id), str(active_user.id), attachment.id):
        assert identifier not in output


@pytest.mark.django_db
def test_pruning_a_device_out_of_existence_takes_its_queue(active_user, settings):
    """Cascade check: deleting a device must not strand its queue rows."""
    doomed = make_device(active_user, 77)
    queue_row(doomed, 1)

    doomed.delete()

    assert QueuedEnvelope.objects.count() == 0


@pytest.mark.django_db
def test_the_retention_filter_column_carries_an_index():
    """The sweep runs hourly and filters the largest table on `queued_day` alone.

    Without an index that filter is a sequential scan of the whole table on every
    pass, including the common pass where nothing has expired at all. Measured on
    a seeded copy (200 000 envelopes, 245 MB): 28 736 buffers and 26.5 ms with
    nothing to delete, against 2 buffers and 0.012 ms once the index exists. The
    plans are recorded in `docs/architecture/GROUND-TRUTH.md`.
    """
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT indexdef FROM pg_indexes WHERE tablename = %s",
            [QueuedEnvelope._meta.db_table],
        )
        definitions = [row[0] for row in cursor.fetchall()]

    assert any("(queued_day" in definition for definition in definitions), definitions


# --- The sweep as background work -------------------------------------------------


@contextmanager
def another_session():
    """A second PostgreSQL session, outside Django's connection.

    An advisory lock belongs to the backend that took it, so proving the guard
    needs a second backend. Built from the parameters Django would use, minus the
    two objects that are Django's own machinery rather than connection settings.
    """
    params = {
        key: value
        for key, value in connection.get_connection_params().items()
        if key not in ("cursor_factory", "context")
    }
    session = psycopg.connect(**params, autocommit=True)
    try:
        yield session
    finally:
        session.close()


def deletes_of(context, table):
    return [
        query["sql"]
        for query in context.captured_queries
        if query["sql"].startswith("DELETE") and table in query["sql"]
    ]


@pytest.mark.django_db(transaction=True)
def test_the_envelope_sweep_deletes_in_batches_that_bound_its_lock_time(
    active_user, settings, monkeypatch
):
    """One unbounded DELETE holds a row lock on every expired envelope until it
    commits, and the sweep runs beside live traffic rather than in a window. The
    mailbox ceiling times the device count is what that delete could be."""
    settings.ENVELOPE_TTL_DAYS = 7
    monkeypatch.setattr(prune, "BATCH", 2)
    device = make_device(active_user, 81)
    for seq in range(1, 6):
        queue_row(device, seq, age_days=8)

    with CaptureQueriesContext(connection) as context:
        run_prune()

    assert deletes_of(context, "messaging_queuedenvelope") != []
    assert len(deletes_of(context, "messaging_queuedenvelope")) == 3  # 2 + 2 + 1
    assert QueuedEnvelope.objects.count() == 0


@pytest.mark.django_db(transaction=True)
def test_the_audit_sweep_deletes_in_batches_too(expired_audit_rows, monkeypatch):
    monkeypatch.setattr(prune, "BATCH", 2)

    with CaptureQueriesContext(connection) as context:
        run_prune()

    assert len(deletes_of(context, "django_admin_log")) == 3  # 2 + 2 + 1
    assert LogEntry.objects.count() == 0


@pytest.mark.django_db(transaction=True)
def test_the_watermark_of_a_batch_is_one_update_however_many_devices(
    active_user, settings
):
    """The mark used to be raised one device at a time, which is a query per device
    with expired mail inside the transaction that holds the delete."""
    settings.ENVELOPE_TTL_DAYS = 7
    for index in range(4):
        queue_row(make_device(active_user, 90 + index), index + 1, age_days=8)

    with CaptureQueriesContext(connection) as context:
        run_prune()

    updates = [
        query["sql"]
        for query in context.captured_queries
        if query["sql"].startswith("UPDATE") and "devices_device" in query["sql"]
    ]
    assert len(updates) == 1
    assert list(
        Device.objects.order_by("registration_id").values_list(
            "queue_pruned_through", flat=True
        )
    ) == [1, 2, 3, 4]


@pytest.mark.django_db(transaction=True)
def test_a_sweep_declines_while_another_session_holds_the_lock(active_user, settings):
    """Two sweeps interleaved would advance one device's watermark from one batch
    while the other deletes a different one, and the device would be told it lost
    envelopes that are still in its mailbox. systemd declining to start a second
    `Type=oneshot` instance is the state of the unit at one instant, not a lock,
    and an operator running this by hand is outside the unit entirely."""
    settings.ENVELOPE_TTL_DAYS = 7
    device = make_device(active_user, 95)
    queue_row(device, 1, age_days=8)

    with another_session() as session:
        session.execute(
            "SELECT pg_advisory_lock(%s, %s)",
            [prune.LOCK_NAMESPACE, prune.LOCK_RESOURCE],
        )
        output = run_prune()

    assert prune.SKIPPED in output
    assert QueuedEnvelope.objects.count() == 1
    device.refresh_from_db()
    assert device.queue_pruned_through == 0


@pytest.mark.django_db(transaction=True)
def test_the_lock_is_released_so_the_next_run_sweeps(active_user, settings):
    """A session lock outlives every transaction of the sweep, so nothing but the
    command's own release ends it while the process lives."""
    settings.ENVELOPE_TTL_DAYS = 7
    queue_row(make_device(active_user, 96), 1, age_days=8)

    run_prune()
    queue_row(make_device(active_user, 97), 1, age_days=8)
    second = run_prune()

    assert prune.SKIPPED not in second
    assert QueuedEnvelope.objects.count() == 0


@pytest.mark.django_db(transaction=True)
def test_a_failed_sweep_names_the_step_and_nothing_else(active_user, settings):
    """The statements of this command carry envelope ids, and a database error
    carries the statement that raised it — so an escaping traceback writes a
    device's mailbox into the timer's journal. `CommandError` is also what makes
    the exit status 1 instead of a traceback."""
    settings.ENVELOPE_TTL_DAYS = 7
    device = make_device(active_user, 98)
    row = queue_row(device, 1, age_days=8)
    leaky = DatabaseError(f"DELETE FROM messaging_queuedenvelope WHERE id = '{row.id}'")

    with mock.patch.object(Device.objects, "filter", side_effect=leaky):
        with pytest.raises(CommandError) as raised:
            run_prune()

    assert "envelope sweep" in str(raised.value)
    assert str(row.id) not in str(raised.value)
    assert str(device.id) not in str(raised.value)


@pytest.mark.django_db(transaction=True)
def test_a_failed_sweep_exits_non_zero(active_user, settings, capsys):
    """The real exit path, not the `call_command` one: `run_from_argv` turns a
    `CommandError` into `sys.exit(1)`, which is what the timer's unit reads."""
    settings.ENVELOPE_TTL_DAYS = 7
    queue_row(make_device(active_user, 99), 1, age_days=8)

    with mock.patch.object(Device.objects, "filter", side_effect=DatabaseError("x")):
        with pytest.raises(SystemExit) as exit_status:
            prune.Command().run_from_argv(["manage.py", "prune"])

    assert exit_status.value.code == 1
    assert "envelope sweep" in capsys.readouterr().err


@pytest.mark.django_db(transaction=True)
def test_a_skipped_sweep_exits_zero(active_user, settings, capsys):
    """A run that declines the lock has done the right thing. Exiting non-zero
    would leave the timer's unit in a failed state for it."""
    settings.ENVELOPE_TTL_DAYS = 7
    queue_row(make_device(active_user, 100), 1, age_days=8)

    with another_session() as session:
        session.execute(
            "SELECT pg_advisory_lock(%s, %s)",
            [prune.LOCK_NAMESPACE, prune.LOCK_RESOURCE],
        )
        prune.Command().run_from_argv(["manage.py", "prune"])

    assert prune.SKIPPED in capsys.readouterr().out
    assert QueuedEnvelope.objects.count() == 1


# --- Retention, one class at a time, at the exact cutoff ---------------------------


class FrozenClock:
    """The clock the sweep reads, stopped.

    Each retention class computes its cutoff as `now - TTL` at the moment the step
    runs, so a row exactly at the cutoff cannot be written against the wall clock:
    whatever instant the test picked has already passed by the time the command
    reads it. Substituted for the module's `timezone` rather than patched globally,
    so nothing else in the process — an `auto_now` column, an issued token — moves
    with it.
    """

    def __init__(self, instant):
        self._instant = instant

    def now(self):
        return self._instant


@pytest.fixture
def stopped_clock(monkeypatch):
    """A fixed instant, far enough from every real timestamp that a row written by
    a fixture cannot land inside a window by accident."""
    instant = timezone.now().replace(microsecond=0)
    monkeypatch.setattr(prune, "timezone", FrozenClock(instant))
    return instant


def at(row, day):
    QueuedEnvelope.objects.filter(id=row.id).update(queued_day=day)
    return row


@pytest.mark.django_db
def test_the_envelope_cutoff_keeps_the_row_that_lands_exactly_on_it(
    device, settings, stopped_clock
):
    """`queued_day < cutoff`, strictly. The boundary matters because the column is
    coarsened to the day (ADR-0025): with `<=` the whole day that lands on the
    cutoff would go a day early, and the client would be told it lost envelopes
    whose TTL had not run out."""
    settings.ENVELOPE_TTL_DAYS = 7
    cutoff = stopped_clock.date() - timedelta(days=7)
    outside = at(queue_row(device, 1), cutoff - timedelta(days=1))
    on_it = at(queue_row(device, 2), cutoff)
    inside = at(queue_row(device, 3), cutoff + timedelta(days=1))

    output = run_prune()

    assert sorted(QueuedEnvelope.objects.values_list("seq", flat=True)) == [
        on_it.seq,
        inside.seq,
    ]
    assert not QueuedEnvelope.objects.filter(id=outside.id).exists()
    assert "envelopes pruned: 1" in output


@pytest.mark.django_db
def test_the_attachment_cutoff_keeps_the_row_that_lands_exactly_on_it(
    attachments_root, settings, stopped_clock
):
    """A date, not an instant: the column holds the upload's day, so the window is
    whole days and the day on the cutoff is still inside it."""
    settings.ATTACH_TTL_DAYS = 30
    cutoff = stopped_clock.date() - timedelta(days=30)
    rows = {}
    for label, created in (
        ("outside", cutoff - timedelta(days=1)),
        ("on_it", cutoff),
        ("inside", cutoff + timedelta(days=1)),
    ):
        attachment, path = stored_attachment(attachments_root)
        Attachment.objects.filter(id=attachment.id).update(created_date=created)
        rows[label] = (attachment, path)

    output = run_prune()

    assert not Attachment.objects.filter(id=rows["outside"][0].id).exists()
    assert not rows["outside"][1].exists()
    assert Attachment.objects.filter(id=rows["on_it"][0].id).exists()
    assert Attachment.objects.filter(id=rows["inside"][0].id).exists()
    assert "attachments pruned: 1 (files removed: 1)" in output


@pytest.mark.django_db
def test_the_audit_cutoff_keeps_the_row_that_lands_exactly_on_it(
    active_user, settings, stopped_clock
):
    """Thirty days of administrative history: long enough to answer what changed
    last month, short enough that a seizure takes one month rather than the life of
    the deployment. The window is pinned here rather than read from the settings,
    because a boundary test that moved with the operator's own number would assert
    nothing about where the boundary is."""
    settings.ADMIN_AUDIT_RETENTION_DAYS = 30
    cutoff = stopped_clock - timedelta(days=30)
    marks = {}
    for label, action_time in (
        ("outside", cutoff - timedelta(microseconds=1)),
        ("on_it", cutoff),
        ("inside", cutoff + timedelta(microseconds=1)),
    ):
        entry = LogEntry.objects.create(
            user=active_user, object_repr="x", action_flag=ADDITION, change_message=""
        )
        LogEntry.objects.filter(pk=entry.pk).update(action_time=action_time)
        marks[label] = entry.pk

    output = run_prune()

    assert sorted(LogEntry.objects.values_list("pk", flat=True)) == sorted(
        [marks["on_it"], marks["inside"]]
    )
    assert "audit rows pruned: 1" in output


# --- The watermark across batches -------------------------------------------------


@pytest.mark.django_db(transaction=True)
def test_the_watermark_takes_the_highest_seq_of_the_whole_run_not_of_one_batch(
    active_user, settings, monkeypatch
):
    """One row per batch, in oldest-first order, so the batch carrying the highest
    seq is not the last one the run sees. `Greatest` is what keeps the mark where
    the highest batch left it instead of following the final batch down."""
    settings.ENVELOPE_TTL_DAYS = 7
    monkeypatch.setattr(prune, "BATCH", 1)
    device = make_device(active_user, 110)
    for seq, age in ((9, 11), (3, 10), (5, 9)):
        queue_row(device, seq, age_days=age)

    run_prune()

    device.refresh_from_db()
    assert device.queue_pruned_through == 9
    assert QueuedEnvelope.objects.count() == 0


@pytest.mark.django_db(transaction=True)
def test_the_attachment_sweep_also_deletes_in_batches(
    attachments_root, settings, monkeypatch
):
    """The same bound as the other two sweeps, and for the same reason: one
    unbounded pass would hold a row lock on every expired attachment while it
    unlinked each file in turn."""
    settings.ATTACH_TTL_DAYS = 30
    monkeypatch.setattr(prune, "BATCH", 2)
    for _ in range(5):
        stored_attachment(attachments_root, age_days=31)

    with CaptureQueriesContext(connection) as context:
        output = run_prune()

    assert len(deletes_of(context, "attachments_attachment")) == 3  # 2 + 2 + 1
    assert Attachment.objects.count() == 0
    assert "attachments pruned: 5 (files removed: 5)" in output


@pytest.mark.django_db(transaction=True)
def test_a_batch_whose_files_all_refuse_to_unlink_ends_the_sweep_instead_of_spinning(
    active_user, attachments_root, settings, monkeypatch
):
    """The rare one, and the one that would take the host down rather than a
    request: nothing was deleted, so the same rows come back on the next pass of
    the same loop for ever. They keep their rows and the next run retries them,
    which is the contract a single stuck file already has."""
    settings.ATTACH_TTL_DAYS = 30
    stuck = [stored_attachment(attachments_root, age_days=31) for _ in range(2)]

    def refuse_everything(path, *args, **kwargs):
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(os, "remove", refuse_everything)

    output = run_prune()

    assert "attachments pruned: 0 (files removed: 0)" in output
    assert Attachment.objects.count() == 2
    for _attachment, path in stuck:
        assert path.exists()


@pytest.mark.django_db(transaction=True)
def test_an_ack_between_the_scan_and_the_watermark_leaves_the_mark_where_it_was(
    active_user, settings
):
    """The sweep lock excludes another sweep, not a client.

    The batch's ids are listed and then aggregated as two statements of one
    read-committed transaction, so a device that acked its whole mailbox in
    between leaves the aggregate empty — and an unguarded `UPDATE` built from an
    empty mapping would be a `Case` with no branches. The run ends with nothing
    pruned and the mark untouched, which is the truth: those envelopes were
    delivered, not lost.
    """
    settings.ENVELOPE_TTL_DAYS = 7
    device = make_device(active_user, 111)
    queue_row(device, 1, age_days=8)
    queue_row(device, 2, age_days=8)
    acked = []

    def ack_between(execute, sql, params, many, context):
        if not acked and sql.startswith("SELECT") and "MAX(" in sql:
            acked.append(True)
            with another_session() as session:
                session.execute("DELETE FROM messaging_queuedenvelope")
        return execute(sql, params, many, context)

    with connection.execute_wrapper(ack_between):
        output = run_prune()

    assert acked == [True], "the aggregate never ran; this proved nothing"
    assert "envelopes pruned: 0" in output
    assert QueuedEnvelope.objects.count() == 0
    device.refresh_from_db()
    assert device.queue_pruned_through == 0


# --- What a failure is allowed to say ---------------------------------------------


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize(
    "step, manager",
    [
        ("envelope sweep", QueuedEnvelope),
        ("attachment sweep", Attachment),
        ("audit sweep", LogEntry),
    ],
)
def test_a_failed_step_names_the_step_and_the_exception_class_and_nothing_else(
    settings, step, manager
):
    """The whole message, not a substring of it. A database error carries the
    statement that raised it, and the statements here carry envelope ids, so
    anything appended from the exception would write a mailbox into the journal.
    `from None` is the other half: the raised error carries no cause and
    suppresses its context, so no traceback of the original — and no statement —
    reaches an operator's terminal either."""
    settings.ENVELOPE_TTL_DAYS = 7
    settings.ATTACH_TTL_DAYS = 30
    settings.ADMIN_AUDIT_RETENTION_DAYS = 30
    leaky = DatabaseError("SELECT blob FROM messaging_queuedenvelope WHERE id = 'x'")

    with mock.patch.object(manager.objects, "filter", side_effect=leaky):
        with pytest.raises(CommandError) as raised:
            run_prune()

    assert str(raised.value) == f"the {step} failed: DatabaseError"
    assert raised.value.__cause__ is None
    # `from None` suppresses the chain, which is what keeps the original error —
    # and the statement it carries — out of anything Django prints.
    assert raised.value.__suppress_context__ is True


@pytest.mark.django_db(transaction=True)
def test_the_output_carries_no_identifier_no_payload_and_no_path(
    active_user, attachments_root, settings
):
    """Everything this command writes lands in the timer's journal, which is on
    disk and outside the schema's control. Counts are the whole vocabulary: an id
    is a graph edge, a path names an attachment, and the bytes are the thing the
    system exists to keep."""
    settings.ENVELOPE_TTL_DAYS = 7
    settings.ATTACH_TTL_DAYS = 30
    settings.ADMIN_AUDIT_RETENTION_DAYS = 30
    device = make_device(active_user, 112)
    row = queue_row(device, 1, age_days=8)
    blob = bytes(QueuedEnvelope.objects.get(id=row.id).blob)
    attachment, path = stored_attachment(attachments_root, age_days=31)
    entry = LogEntry.objects.create(
        user=active_user, object_repr="x", action_flag=ADDITION, change_message=""
    )
    LogEntry.objects.filter(pk=entry.pk).update(
        action_time=timezone.now() - timedelta(days=91)
    )

    output = run_prune()

    forbidden = {
        "envelope id": str(row.id),
        "device id": str(device.id),
        "user id": str(active_user.id),
        "attachment id": attachment.id,
        "attachment path": str(path),
        "attachments root": str(attachments_root),
        "audit row id": str(entry.pk),
        "envelope payload": base64.b64encode(blob).decode(),
        "envelope payload in hex": blob.hex(),
    }
    for label, secret in forbidden.items():
        assert secret not in output, f"{label} reached the command output"
