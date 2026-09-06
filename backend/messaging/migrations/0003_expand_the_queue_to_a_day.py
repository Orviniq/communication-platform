from django.db import migrations, models

import messaging.models


class Migration(migrations.Migration):
    """Step one of three: the column arrives, and the one it replaces stops being
    required. No row is read and no index is built here.

    `AddField` with a default is the one operation in this file whose cost is not
    obvious. PostgreSQL 11 and later evaluate the default once at DDL time and
    store it in `pg_attribute.attmissingval`, so `ADD COLUMN … DEFAULT <constant>
    NOT NULL` rewrites nothing: measured at 1.7 ms against a 200 000-row, 111.6 MB
    copy, with `relfilenode` unchanged either side
    (`docs/architecture/GROUND-TRUTH.md` §4). What that costs instead is a column
    whose existing rows all carry the day the migration ran, which is what
    `0004_backfill_the_queued_day` exists to correct.

    The deploy order is migrate first, then the code, and this migration is the
    reason: the new column is `NOT NULL` and Django drops the default it added, so
    the previous release — which knows nothing about `queued_day` — cannot insert
    against this schema. That window does not exist on this deployment. One
    `chat.service` on one host cannot run two releases at once, and `ops/RUNBOOK.md`
    §5 stops it before `migrate` runs. The failure it would produce is loud and
    recoverable in seconds: a `NOT NULL` violation on the send route, nothing
    written and nothing lost.
    """

    dependencies = [
        ("devices", "0002_retire_the_activity_dates"),
        ("messaging", "0002_index_the_retention_filter"),
    ]

    operations = [
        migrations.AddField(
            model_name="queuedenvelope",
            name="queued_day",
            field=models.DateField(default=messaging.models._utc_day, editable=False),
        ),
        # `DROP NOT NULL` on a column the new code stops writing. It clears one flag
        # in `pg_attribute` and reads no row, so the ACCESS EXCLUSIVE it takes is
        # held for a catalogue write whatever the table holds — the same shape the
        # three `0002_retire_the_activity_dates` migrations take.
        migrations.AlterField(
            model_name="queuedenvelope",
            name="queued_hour",
            field=models.DateTimeField(null=True),
        ),
    ]
