from django.db import migrations


class Migration(migrations.Migration):
    """The account model's display name, in the operator's words.

    `AlterModelOptions` changes the migration state and nothing in the database:
    `sqlmigrate accounts 0006` prints `-- (no-op)` between the transaction
    statements, so no relation is locked and no row is read. It exists because
    Django records `verbose_name` in the state it compares the models against,
    and `makemigrations --check` fails a model whose options moved without one.

    The panel's breadcrumb read "Accounts › Users" under a sidebar entry that says
    "Accounts" (`docs/admin/PANEL-RECORD.md` §9, the vocabulary deferral, whose
    trigger fired with `0004` and `0005`).

    Reverses to the options it replaced, which are none.
    """

    dependencies = [
        ("accounts", "0005_index_the_findable_names"),
    ]

    operations = [
        migrations.AlterModelOptions(
            name="user",
            options={"verbose_name": "account", "verbose_name_plural": "accounts"},
        ),
    ]
