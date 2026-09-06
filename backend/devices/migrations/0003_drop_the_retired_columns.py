from django.db import migrations


class Migration(migrations.Migration):
    """Step two of two for six columns across three tables.

    Five were retired by ADR-0024 with the activity dates and one by ADR-0023 with
    the refresh token it counted. `0002_retire_the_activity_dates` made the five
    nullable; `refresh_generation` was never written after the refresh token left,
    and its default is what kept the column insertable in the meantime. No code has
    named any of them since.

    Six `DROP COLUMN` statements in one transaction, so the tables are held once
    each rather than six times. Each is a catalogue write under ACCESS EXCLUSIVE on
    the table it names and rewrites nothing — measured at 0.065 ms against a
    200 000-row, 245 MB copy with `relfilenode` unchanged either side
    (`docs/architecture/GROUND-TRUTH.md` §4). The values already in the heap stay
    there until a rewrite; the drop is a schema change and never an erasure.

    Code deploys before the migration. The previous release names none of these
    columns, so it serves against either schema, and each reverse restores a
    column with no values in it — `refresh_generation` to its default of 1 for
    every row, which is the number it would have carried had it never been
    incremented.
    """

    dependencies = [
        ("devices", "0002_retire_the_activity_dates"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="device",
            name="last_active_date",
        ),
        migrations.RemoveField(
            model_name="device",
            name="pq_spk_updated_date",
        ),
        migrations.RemoveField(
            model_name="device",
            name="refresh_generation",
        ),
        migrations.RemoveField(
            model_name="device",
            name="spk_updated_date",
        ),
        migrations.RemoveField(
            model_name="devicelogrecord",
            name="stored_date",
        ),
        migrations.RemoveField(
            model_name="useridentity",
            name="updated_date",
        ),
    ]
