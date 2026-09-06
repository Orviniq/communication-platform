from django.db import migrations


class Migration(migrations.Migration):
    """Step two of two: the column ADR-0024 retired leaves the schema.

    `0002_retire_the_activity_dates` made it nullable and the release beside it
    stopped writing it. Nothing has read or written it since, so this drop removes
    a column no code names.

    `ALTER TABLE … DROP COLUMN` takes ACCESS EXCLUSIVE on the table and is a
    catalogue write: PostgreSQL marks the attribute dropped in `pg_attribute` and
    rewrites nothing. Measured at 0.065 ms against a 200 000-row, 245 MB copy with
    `relfilenode` unchanged either side (`docs/architecture/GROUND-TRUTH.md` §4).
    What it does not do is remove the values already in the heap: they stay in the
    pages until a rewrite, which is the same measurement's other half.

    The deploy order is code first, then migrate — the reverse of an expand. The
    previous release does not name the column, so it serves against either schema;
    a release that still read it would not, and none does.

    Reverses to an `AddField` of a nullable column, which restores the column and
    not the values.
    """

    dependencies = [
        ("accounts", "0002_retire_the_activity_dates"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="profileblob",
            name="updated_date",
        ),
    ]
