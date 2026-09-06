import uuid

from django.db import models
from django.utils import timezone

from core.buckets import ENVELOPE_BUCKETS
from core.fields import OpaqueBlobField


def _truncate_hour(dt=None):
    """The default `queued_hour` carried until ADR-0025 retired it.

    The column is gone and this stays, because `messaging/0001_initial.py` names it
    by import path and the migration history is append-only: editing an applied
    migration to drop the reference is the one repair this project does not make.
    Removing it would make the first migration of this app unimportable, and with it
    the whole history. Nothing else calls it.
    """
    dt = dt or timezone.now()
    return dt.replace(minute=0, second=0, microsecond=0)


def _utc_day(dt=None):
    return (dt or timezone.now()).date()


class QueuedEnvelope(models.Model):
    """One padded ciphertext copy per recipient device. There is no sender column;
    sender identity exists only inside the ciphertext."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # db_index=False: the unique constraint below already indexes this column as its
    # leading key, so the default FK index would be a redundant B-tree maintained on
    # every insert.
    recipient_device = models.ForeignKey(
        "devices.Device", on_delete=models.CASCADE, related_name="queue", db_index=False
    )
    seq = models.BigIntegerField()
    blob = OpaqueBlobField(bucket_set=ENVELOPE_BUCKETS)
    # The UTC day of enqueue, and the only thing a seizure learns about when an
    # undelivered envelope arrived. An hour told an adversary which part of the day
    # a device was addressed in, which is a waking pattern; a day tells them the
    # retention window is being honoured and nothing else (ADR-0025).
    queued_day = models.DateField(default=_utc_day, editable=False)

    class Meta:
        # The unique constraint doubles as the mailbox read index: the drain query is an
        # ordered scan of (recipient_device, seq), so a separate index would only add
        # per-insert maintenance.
        constraints = [
            models.UniqueConstraint(
                fields=["recipient_device", "seq"], name="uq_queue_device_seq"
            ),
        ]
        # The retention sweep is the one query that filters this table on nothing but
        # the enqueue date, and it runs hourly against the largest table in the schema.
        # Without the index it is a sequential scan on every pass — including the
        # common pass where nothing has expired: 28 736 buffers and 26.5 ms against a
        # seeded 245 MB copy, where the index costs 2 buffers and 0.012 ms. It is the
        # one index here whose plan is recorded rather than argued
        # (`docs/architecture/GROUND-TRUTH.md`).
        #
        # One of them: `ix_queue_queued_hour` left with the column it indexed.
        indexes = [
            models.Index(fields=["queued_day"], name="ix_queue_queued_day"),
        ]
