from django.contrib.postgres.operations import AddIndexConcurrently
from django.db import migrations, models


class Migration(migrations.Migration):
    """The index `POST /users/lookup` reads: the names of the accounts it may find.

    Partial on `is_active AND discoverable`, so an unknown name, an inactive
    account's name and a hidden account's name all miss it alike and cost the
    same pages (ADR-0028). It holds only the findable rows, so it is smaller than
    the two `username` indexes beside it: 3.5 MB against 7.6 MB at 200 000 rows.

    `AddIndexConcurrently` cannot run inside a transaction block, and Django raises
    NotSupportedError when the migration is atomic. The cost of leaving the
    transaction is that an interrupted build leaves an index PostgreSQL then ignores
    for queries while still maintaining it on every write, so a deploy that ran this
    migration checks for one:
      SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
    and repairs it with REINDEX INDEX CONCURRENTLY ix_user_findable_name.
    """

    atomic = False

    dependencies = [("accounts", "0004_the_discoverability_setting")]

    operations = [
        # Concurrently, not the plain `AddIndex` makemigrations writes, which takes
        # SHARE and blocks every registration, activation and setting change for
        # the length of the build. The concurrent form takes SHARE UPDATE
        # EXCLUSIVE and blocks no reader and no writer, at the price of two scans
        # of a table that holds fewer than fifty rows at this band.
        AddIndexConcurrently(
            model_name="user",
            index=models.Index(
                condition=models.Q(("discoverable", True), ("is_active", True)),
                fields=["username"],
                name="ix_user_findable_name",
            ),
        ),
    ]
