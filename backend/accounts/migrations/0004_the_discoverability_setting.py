from django.db import migrations, models


class Migration(migrations.Migration):
    """The "find me by username" setting arrives, on for every account (ADR-0028).

    One statement: `ALTER TABLE "accounts_user" ADD COLUMN "discoverable" boolean
    DEFAULT true NOT NULL`. PostgreSQL 11 and later evaluate a constant default
    once and store it in `pg_attribute.attmissingval`, so every existing row reads
    `true` and none is rewritten: measured at 0.342 ms against a 200 000-row,
    55 MB copy, with `relfilenode` unchanged and `atthasmissing` set
    (`docs/architecture/GROUND-TRUTH.md` §4). ACCESS EXCLUSIVE on `accounts_user`
    and on nothing else, for the length of that catalogue write.

    `db_default` is what keeps the `DEFAULT` in the database. With `default`
    alone Django would add it and drop it again in the same migration, and the
    release before this one — which inserts accounts without naming the column —
    would then fail every registration on the `NOT NULL`. With it, that release's
    insert reads `true`, measured on the same copy, so the deploy order is free.

    Reverses to a `DROP COLUMN`, which loses every owner's choice: a rollback past
    this migration makes every account findable again when it is re-applied.
    """

    dependencies = [
        ("accounts", "0003_drop_the_retired_date"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="discoverable",
            field=models.BooleanField(db_default=True, default=True),
        ),
    ]
