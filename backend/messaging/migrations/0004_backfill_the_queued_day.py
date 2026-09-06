from django.db import migrations, transaction
from django.db.models.functions import TruncDate

# The rows one statement of the backfill may touch, and the same number the
# retention sweep uses. An unbounded `UPDATE` holds a row lock on every matching
# row until it commits, against the largest table in the schema and the one every
# send writes to.
BATCH = 1000


def fill_the_day_from_the_hour(apps, schema_editor):
    """Give every row that predates `0003` its own day instead of the migration's.

    Idempotent by construction: a pass selects only the rows whose `queued_day`
    disagrees with `queued_hour::date`, and the update it then runs is what makes
    them stop disagreeing. Re-running the whole migration after a crash therefore
    finds only what the crash left, and a row inserted after `0003` by the new
    code already agrees and is never selected.

    A row whose `queued_hour` is NULL is skipped rather than guessed at. Only the
    new code writes NULL there, and only for rows that carry a correct
    `queued_day` already.

    The batches are ordered by primary key so a pass is deterministic, and each one
    commits on its own — `atomic = False` above is what makes that possible, and is
    the reason this file carries no schema operation: a data migration inside the
    same transaction as its DDL would hold the DDL's lock for the length of the
    backfill.
    """
    envelope = apps.get_model("messaging", "QueuedEnvelope")
    alias = schema_editor.connection.alias
    while True:
        stale = list(
            envelope.objects.using(alias)
            .filter(queued_hour__isnull=False)
            .exclude(queued_day=TruncDate("queued_hour"))
            .order_by("id")
            .values_list("id", flat=True)[:BATCH]
        )
        if not stale:
            return
        with transaction.atomic(using=alias):
            envelope.objects.using(alias).filter(id__in=stale).update(
                queued_day=TruncDate("queued_hour")
            )


class Migration(migrations.Migration):
    """Step two of three: the data, in its own file and its own transactions.

    The reverse is a no-op rather than an omission. What this migration writes is a
    column that `0003` created, so unapplying `0003` drops every value it wrote and
    there is nothing left to restore. Restoring the hour a row was enqueued at is
    not possible from a day, and is not wanted: the point of ADR-0025 is that the
    server stops holding it.
    """

    atomic = False

    dependencies = [("messaging", "0003_expand_the_queue_to_a_day")]

    operations = [
        migrations.RunPython(fill_the_day_from_the_hour, migrations.RunPython.noop)
    ]
