from django.contrib.postgres.operations import AddIndexConcurrently
from django.db import migrations, models


class Migration(migrations.Migration):
    """Step three of three: the index the retention sweep reads.

    Last, so the build runs once over the values `0004` settled rather than
    maintaining an index through the backfill.

    `AddIndexConcurrently` cannot run inside a transaction block, and Django raises
    NotSupportedError when the migration is atomic. The cost of leaving the
    transaction is that an interrupted build leaves an index PostgreSQL then ignores
    for queries while still maintaining it on every write, so a deploy that ran this
    migration checks for one:
      SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
    and repairs it with REINDEX INDEX CONCURRENTLY ix_queue_queued_day.
    """

    atomic = False

    dependencies = [("messaging", "0004_backfill_the_queued_day")]

    operations = [
        # Concurrently, not the plain `AddIndex` makemigrations writes. A plain
        # `CREATE INDEX` takes SHARE, which blocks every write to the mailbox table
        # for the whole build; the concurrent form takes SHARE UPDATE EXCLUSIVE and
        # blocks nothing, at the price of two table scans. This is the largest table
        # in the schema and the one every send writes to, so the deploy that adds
        # this index must not be the deploy that stops delivery.
        AddIndexConcurrently(
            model_name="queuedenvelope",
            index=models.Index(fields=["queued_day"], name="ix_queue_queued_day"),
        ),
    ]
