from django.db import migrations


class Migration(migrations.Migration):
    """Step two of two: the column that said whose bytes a stored attachment was.

    ADR-0025 replaced the lifetime quota this foreign key served with a daily
    allowance counted in Redis, and the release beside it stopped reading and
    writing the column. This drop is what takes the link out of the schema, and
    with it the one row a seizure could have read to tie an account to a file.

    Two statements. Django drops the foreign key first — the `SET CONSTRAINTS …
    IMMEDIATE` in front of it is how it makes a deferred constraint droppable
    inside the transaction — and the column second. The constraint drop takes
    ACCESS EXCLUSIVE on **both** sides, `attachments_attachment` and
    `accounts_user`, because a foreign key is a property of the referenced table
    as well; measured from `pg_locks` on a copy of this shape. Both are catalogue
    writes: `relfilenode` unchanged either side, and the index the foreign key
    carried is dropped with the column rather than scanned.

    Code deploys before the migration. The previous release names neither the
    column nor the relation, so it serves against either schema.

    The reverse restores a nullable foreign key and no values: which account
    uploaded which bytes is not recoverable from this database once the column is
    gone, which is the point of the change rather than a cost of it.
    """

    dependencies = [
        ("attachments", "0001_initial"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="attachment",
            name="uploader",
        ),
    ]
