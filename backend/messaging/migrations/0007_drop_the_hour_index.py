from django.contrib.postgres.operations import RemoveIndexConcurrently
from django.db import migrations


class Migration(migrations.Migration):
    """Step one of two: the index leaves before the column it indexed.

    Concurrently, not the plain `DROP INDEX` makemigrations writes. Measured on
    PostgreSQL 16.14 against a 200 000-row copy: `DROP INDEX CONCURRENTLY` holds
    SHARE UPDATE EXCLUSIVE on `messaging_queuedenvelope` and on the index while it
    waits for the transactions that can still be using it, and blocks no reader and
    no writer; the plain form takes ACCESS EXCLUSIVE on the table and stops every
    send for as long as it holds it. This is the largest table in the schema and
    the one every send writes to.

    Separate from the column drop, and first, because the two cannot share a file:
    `DROP INDEX CONCURRENTLY` is refused inside a transaction block, so this
    migration is `atomic = False`, and a `DROP COLUMN` beside it would then run
    outside a transaction for no reason. Dropping the index first also means the
    column drop never has an index to cascade.

    The cost of leaving the transaction is that an interrupted drop leaves an
    invalid index behind, so a deploy that ran this migration checks for one:
      SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
    and removes it with DROP INDEX CONCURRENTLY IF EXISTS ix_queue_queued_hour.

    Reverses to a concurrent build of the same index, which is the operation
    `0002_index_the_retention_filter` performed.
    """

    atomic = False

    dependencies = [("messaging", "0006_reclaim_the_queue_promptly")]

    operations = [
        RemoveIndexConcurrently(
            model_name="queuedenvelope",
            name="ix_queue_queued_hour",
        ),
    ]
