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

    **This migration runs before the code, and it is the only one of the six that
    cannot go the other way.** Five of these columns are nullable, so a release
    that stops naming them inserts against either schema. `refresh_generation` is
    `NOT NULL` with no database default — `CreateModel` never persists a field
    default — so a release that has stopped naming it cannot insert a device at
    all until this migration has run: measured, every `Device` insert against the
    pre-drop schema raises `null value in column "refresh_generation" ... violates
    not-null constraint`, which is `POST /api/v1/me/devices` answering `500` for
    as long as the window is open.

    That window does not exist on this deployment — one `chat.service` on one host
    cannot serve two releases at once, and the release procedure stops it before
    `migrate` — and `core/tests/test_migrations.py` records the constraint in
    `MIGRATE_FIRST` rather than leaving it to this paragraph. The previous release
    serves against the new schema either way, because it names none of these
    columns.

    Each reverse restores a column with no values in it — `refresh_generation` to
    its default of 1 for every row, which is the number it would have carried had
    it never been incremented.
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
