from django.db import migrations


class Migration(migrations.Migration):
    """Step two of two: the column ADR-0025 replaced with a day leaves the queue.

    `0003_expand_the_queue_to_a_day` added `queued_day` and made this column
    nullable, `0004_backfill_the_queued_day` gave every row the day of its own
    hour, and the release beside them stopped writing the hour. `0007` took its
    index. What is left is a column nothing reads, and this drops it.

    One `ALTER TABLE … DROP COLUMN` under ACCESS EXCLUSIVE on
    `messaging_queuedenvelope`, held for a catalogue write: measured at 0.065 ms
    against a 200 000-row, 245 MB copy with `relfilenode` unchanged either side
    (`docs/architecture/GROUND-TRUTH.md` §4).

    It removes the column and not the values. An hour already written stays in the
    heap pages until a rewrite reclaims them — measured on the same page with
    `pageinspect`, present after the drop and gone after `VACUUM FULL`. On this
    deployment that is free: ADR-0009 makes creating the database and migrating
    once the supported path, so no environment carries a row written before the
    hour was retired. On one that did, the drop would be a schema change and the
    erasure would still be owed.

    Code deploys before the migration. The previous release does not name the
    column, and the reverse restores a nullable column with nothing in it.
    """

    dependencies = [("messaging", "0007_drop_the_hour_index")]

    operations = [
        migrations.RemoveField(
            model_name="queuedenvelope",
            name="queued_hour",
        ),
    ]
