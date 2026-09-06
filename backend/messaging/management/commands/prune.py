from contextlib import contextmanager
from datetime import timedelta

from django.conf import settings
from django.contrib.admin.models import LogEntry
from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction
from django.db.models import BigIntegerField, Case, Max, Value, When
from django.db.models.functions import Greatest
from django.utils import timezone

from attachments.models import Attachment
from attachments.services import purge
from devices.models import Device
from messaging.models import QueuedEnvelope

# The rows one statement of the sweep may touch. Every delete here is a range of a
# table the serving process writes to on its hot path, and an unbounded delete
# holds a row lock on every matching row until it commits: a week of undelivered
# ciphertext is up to the mailbox ceiling times the device count, and the sweep
# runs beside live traffic rather than in a window. A thousand rows is one
# short-lived transaction per pass — measured at 991 buffers to select and 5.04 ms
# on a seeded 247 MB copy — and the pass repeats until nothing is left.
BATCH = 1000

# The advisory-lock key of the sweep, in the two-integer form so it cannot collide
# with a one-bigint key. The namespace is this project; the resource is this
# command. Taken on the session rather than the transaction, because the sweep is
# many transactions and the exclusion has to span all of them; PostgreSQL drops a
# session lock when its backend goes, so a killed process leaks nothing.
LOCK_NAMESPACE = 0x43484154  # "CHAT"
LOCK_RESOURCE = 1

SKIPPED = "skipped: another prune already holds the sweep lock"


@contextmanager
def sweep_lock():
    """Hold the sweep lock for the life of the command, or report that another run
    has it.

    systemd will not start a second `Type=oneshot` instance while the first is
    still active, but that is a property of the unit's state at one instant and not
    a lock: an operator running `manage.py prune` by hand beside the timer is
    outside the unit entirely. Two sweeps interleaved would advance a watermark
    from one batch while the other deletes a different one, and the device would be
    told it lost envelopes that are still in its mailbox.
    """
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT pg_try_advisory_lock(%s, %s)", [LOCK_NAMESPACE, LOCK_RESOURCE]
        )
        held = cursor.fetchone()[0]
    try:
        yield held
    finally:
        if held:
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT pg_advisory_unlock(%s, %s)", [LOCK_NAMESPACE, LOCK_RESOURCE]
                )


class Command(BaseCommand):
    """Idempotent: every pass deletes only what is already past its TTL, so re-running
    it after a crash is safe."""

    help = "Prune expired queued envelopes, attachments and audit rows."

    def handle(self, *args, **options):
        with sweep_lock() as held:
            if not held:
                # A skipped run is a normal outcome, not a failure: exiting non-zero
                # here would put the timer's unit into a failed state for declining
                # to do the one thing that would be wrong.
                self.stdout.write(SKIPPED)
                return
            envelopes = self._step("envelope sweep", self._prune_envelopes)
            attachments, files = self._step("attachment sweep", self._prune_attachments)
            audit_rows = self._step("audit sweep", self._prune_audit)

        # Counts only: an id or a blob written here would land in the timer's journal.
        self.stdout.write(f"envelopes pruned: {envelopes}")
        self.stdout.write(f"attachments pruned: {attachments} (files removed: {files})")
        self.stdout.write(f"audit rows pruned: {audit_rows}")

    @staticmethod
    def _step(name, run):
        """Run one sweep, and turn any failure into a `CommandError`.

        The exception itself never reaches the output. A database error carries the
        statement that raised it, and the statements here carry envelope ids — so an
        escaping traceback would write the mailbox contents of a device into the
        timer's journal, which is the one thing the schema exists to avoid. The step
        and the exception class are what an operator needs and all they get;
        `CommandError` is also what makes the exit status 1 rather than a traceback.
        """
        try:
            return run()
        except Exception as failure:
            raise CommandError(f"the {name} failed: {type(failure).__name__}") from None

    @staticmethod
    def _prune_envelopes():
        # A day, not an instant: the row carries the UTC day it was enqueued on
        # (ADR-0025), so an envelope expires once its day is older than the window
        # rather than once its hour is. At a seven-day window that keeps a row for
        # up to one day longer than the hour did, and holds nothing finer.
        cutoff = timezone.now().date() - timedelta(days=settings.ENVELOPE_TTL_DAYS)
        pruned = 0
        while True:
            with transaction.atomic():
                # Oldest first, through the `queued_day` index. With nothing
                # expired — the common pass — the probe is two buffers and never
                # reaches the table at all; a full batch of a thousand costs 991.
                ids = list(
                    QueuedEnvelope.objects.filter(queued_day__lt=cutoff)
                    .order_by("queued_day")
                    .values_list("id", flat=True)[:BATCH]
                )
                if not ids:
                    return pruned
                batch = QueuedEnvelope.objects.filter(id__in=ids)
                # Watermark before delete, in one transaction, batch by batch. A
                # pruned envelope may have carried a ratchet message or a group
                # control event the device can never re-obtain, so the device must
                # be able to see that it missed something: queue_pruned_through is
                # that signal (surfaced by GET /me/envelopes as `pruned_through`).
                # Advancing the watermark without the delete committing would tell a
                # device it lost envelopes it can still fetch, so both happen or
                # neither does — which is why the pair, and not the whole sweep, is
                # what the transaction spans.
                #
                # The batch's ids are held to bound the delete, and nothing else
                # comes back: the watermark is an aggregate, one seq per device,
                # and no blob is read into this process at any point.
                highest = {
                    row["recipient_device_id"]: row["top"]
                    for row in batch.values("recipient_device_id").annotate(
                        top=Max("seq")
                    )
                }
                if highest:
                    # One UPDATE for the batch, not one for each device. `Greatest`
                    # is what keeps the mark from regressing when a later batch
                    # carries a lower seq for a device an earlier one already raised.
                    Device.objects.filter(pk__in=highest).update(
                        queue_pruned_through=Greatest(
                            "queue_pruned_through",
                            Case(
                                *[
                                    When(pk=device_id, then=Value(top))
                                    for device_id, top in highest.items()
                                ],
                                output_field=BigIntegerField(),
                            ),
                        )
                    )
                deleted, _ = batch.delete()
                pruned += deleted

    @staticmethod
    def _prune_attachments():
        cutoff = timezone.now().date() - timedelta(days=settings.ATTACH_TTL_DAYS)
        rows = files = 0
        while True:
            # Through the same service the panel's own deletion uses, so the row and
            # the file always go in the same order by the same code. No audit row: an
            # expiry is not an administrative act and no operator performed it.
            batch = list(
                Attachment.objects.filter(created_date__lt=cutoff).only("id")[:BATCH]
            )
            if not batch:
                return rows, files
            deleted, removed = purge(batch)
            rows += deleted
            files += removed
            if not deleted:
                # Every file in this batch refused to unlink, so the same rows would
                # come back for ever. They keep their rows and the next run retries
                # them, which is the same contract a single stuck file already has.
                return rows, files

    @staticmethod
    def _prune_audit():
        """Retention on the admin audit log (ADR-0011).

        The rows name an operator, a UTC day and an object, and for a deleted
        attachment the object id is that attachment's spent capability. Thirty days
        is long enough to answer "what did I change last month" and short enough
        that a seizure takes one month rather than the life of the deployment
        (ADR-0025 shortened it from ninety when the rows stopped carrying a time).
        """
        cutoff = timezone.now() - timedelta(days=settings.ADMIN_AUDIT_RETENTION_DAYS)
        pruned = 0
        while True:
            ids = list(
                LogEntry.objects.filter(action_time__lt=cutoff).values_list(
                    "pk", flat=True
                )[:BATCH]
            )
            if not ids:
                return pruned
            deleted, _ = LogEntry.objects.filter(pk__in=ids).delete()
            pruned += deleted
