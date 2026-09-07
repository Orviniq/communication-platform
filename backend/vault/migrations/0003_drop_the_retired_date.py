from django.db import migrations


class Migration(migrations.Migration):
    """Step two of two for `KeyBackup.updated_date`, the same shape as
    `accounts.0003_drop_the_retired_date`: one `DROP COLUMN` on a column
    `0002_retire_the_activity_dates` made nullable and the release beside it
    stopped writing.

    ACCESS EXCLUSIVE on `vault_keybackup` for a catalogue write, and no rewrite.
    Code deploys before the migration, and the reverse restores a nullable column
    with no values in it.
    """

    dependencies = [
        ("vault", "0002_retire_the_activity_dates"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="keybackup",
            name="updated_date",
        ),
    ]
