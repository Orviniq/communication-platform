"""The migration history: one file for each app, and a replay in both directions.

ADR-0009 regenerated the history, which is available exactly once — before the
first real user — and the precondition is that the deployment recreates the
database rather than migrating it. What that buys has to be proved rather than
assumed, so this file replays the whole history onto an empty database of its
own and then unapplies every app to zero.

The replay never touches the test database. `migrate <app> zero` drops tables,
and a failure part-way through would leave the rest of the suite without a
schema.
"""

import copy
import re
from datetime import datetime
from importlib import import_module
from io import StringIO

import pytest
from django.apps import apps
from django.conf import settings
from django.core.management import call_command
from django.db import connections, transaction
from django.db.migrations.loader import MigrationLoader
from django.db.migrations.recorder import MigrationRecorder
from django.db.utils import load_backend
from django.test.utils import CaptureQueriesContext

INITIAL = "0001_initial"
ALIAS = "migration_replay"

# Every migration this project owns, in the order each app applies them. A file
# that is not written here fails `test_every_app_owns_the_migrations_recorded_here`,
# which is what forces a new migration through the classification below rather than
# into the tree unreviewed.
RETIRE_DATES = "0002_retire_the_activity_dates"
BACKFILL_THE_DAY = "0004_backfill_the_queued_day"
HISTORY = {
    "accounts": [INITIAL, RETIRE_DATES],
    "attachments": [INITIAL],
    "devices": [INITIAL, RETIRE_DATES],
    "messaging": [
        INITIAL,
        "0002_index_the_retention_filter",
        "0003_expand_the_queue_to_a_day",
        BACKFILL_THE_DAY,
        "0005_index_the_day_filter",
    ],
    "vault": [INITIAL, RETIRE_DATES],
    "voicerooms": [INITIAL, "0002_delete_room"],
}

# The migrations that carry data operations and no schema operation. They produce
# no SQL at all, so every gate below that reads `sqlmigrate` output has to know
# which files are allowed to be silent — the alternative is a gate that passes a
# schema migration whose SQL failed to generate.
DATA_MIGRATIONS = {("messaging", BACKFILL_THE_DAY)}

# The apps of this project that own a table. `core` and `realtime` declare no
# model, and `voicerooms` stopped declaring one when ADR-0021 removed the room
# object.
PROJECT_APPS = sorted(
    config.label
    for config in apps.get_app_configs()
    # `get_models()` returns a generator, which is truthy however empty it is.
    if not config.name.startswith("django.") and any(config.get_models())
)

# The apps of this project that own a migrations package. That is the apps above
# plus `voicerooms`, which owns no table any more and keeps its package only to
# carry `0002_delete_room` to a database that still has the table.
MIGRATION_APPS = sorted(
    config.label
    for config in apps.get_app_configs()
    if not config.name.startswith(("django.", "unfold"))
    and (settings.BASE_DIR / config.label / "migrations").exists()
)

# The apps that own a migrations package and no table. One, and it is temporary:
# `voicerooms` leaves the tree once every environment has applied the delete.
MIGRATIONS_WITHOUT_A_TABLE = {"voicerooms"}

# What each `0001_initial` depends on inside this project. `accounts` holds
# `AUTH_USER_MODEL`, so every app with a foreign key to a user waits for it;
# `messaging` queues to a device, so it waits for `devices`. `voicerooms` held no
# foreign key at all, so its history depends on nothing outside itself.
DEPENDENCIES = {
    "accounts": set(),
    "attachments": {"accounts"},
    "devices": {"accounts"},
    "messaging": {"devices"},
    "vault": {"accounts"},
    "voicerooms": set(),
}


def teardown_order():
    """The apps in reverse dependency order.

    Each `zero` then unapplies its own app and nothing else. Alphabetical order
    would take `accounts` first, which cascades through every app that depends on
    it and leaves the rest of the loop unapplying nothing.
    """
    remaining, order = dict(DEPENDENCIES), []
    while remaining:
        free = sorted(app for app, needs in remaining.items() if not needs)
        assert free, f"a cycle between {sorted(remaining)}"
        order.extend(free)
        remaining = {
            app: needs - set(free) for app, needs in remaining.items() if app not in free
        }
    return list(reversed(order))


def project_tables():
    return {model._meta.db_table for model in apps.get_models() if _is_ours(model)}


def _is_ours(model):
    return model._meta.app_label in PROJECT_APPS


def tables_in(alias):
    with connections[alias].cursor() as cursor:
        cursor.execute(
            "SELECT tablename FROM pg_tables WHERE schemaname = current_schema()"
        )
        return {row[0] for row in cursor.fetchall()}


@pytest.fixture
def empty_database():
    """An empty database of its own, created and dropped around the test.

    Registered on the connection handler and never in `settings.DATABASES`: an
    alias the settings name is one Django's own test guard forbids a connection
    to unless the test declares it, and this alias does not exist when the guard
    is installed. A connection the handler holds and the settings do not is the
    dynamically created case the guard admits.

    The connection carries no pool. The replay is one session running DDL, and a
    pool's idle connection would still hold the database open when the drop runs.
    """
    name = f"{connections['default'].settings_dict['NAME']}_{ALIAS}"
    # `CREATE DATABASE` and `DROP DATABASE` take no bound parameter, so the name is
    # interpolated into the statement. It is the configured database name plus a
    # constant, never a request value, and this is what keeps it that way: anything
    # but a plain identifier never reaches the statement.
    assert name.replace("_", "").isalnum(), name
    quoted = connections["default"].ops.quote_name(name)
    settings_dict = copy.deepcopy(connections["default"].settings_dict)
    settings_dict["NAME"] = name
    settings_dict["OPTIONS"] = {
        key: value for key, value in settings_dict["OPTIONS"].items() if key != "pool"
    }
    with connections["default"].cursor() as cursor:
        cursor.execute(f"DROP DATABASE IF EXISTS {quoted}")
        cursor.execute(f"CREATE DATABASE {quoted}")
    backend = load_backend(settings_dict["ENGINE"])
    connections[ALIAS] = backend.DatabaseWrapper(settings_dict, alias=ALIAS)
    try:
        yield ALIAS
    finally:
        connections[ALIAS].close()
        del connections[ALIAS]
        with connections["default"].cursor() as cursor:
            cursor.execute(f"DROP DATABASE IF EXISTS {quoted}")


def test_every_app_owns_the_migrations_recorded_here():
    """ADR-0009 regenerated the history, so each app starts at one `0001_initial`
    and nothing precedes it. What follows grows, and `HISTORY` is the record of
    what it grew to: a file nobody wrote down fails here, which is what puts every
    new migration through the classification below."""
    loader = MigrationLoader(None, ignore_no_migrations=True)
    ours = {(app, name) for app, name in loader.disk_migrations if app in MIGRATION_APPS}

    assert ours == {(app, name) for app, names in HISTORY.items() for name in names}
    assert set(HISTORY) == set(MIGRATION_APPS)


def test_each_initial_declares_the_dependencies_recorded_here():
    """The order the apps migrate in. A dependency that disappears is a migration
    that can run before the table it points at exists."""
    loader = MigrationLoader(None, ignore_no_migrations=True)
    declared = {
        app: {
            dependency
            for dependency, _name in loader.disk_migrations[(app, INITIAL)].dependencies
            if dependency in MIGRATION_APPS and dependency != app
        }
        for app in MIGRATION_APPS
    }

    assert declared == DEPENDENCIES


def test_the_graph_has_one_leaf_for_each_app():
    """Two leaves in one app is the conflicting-history state `migrate` refuses to
    run, and it reaches the tree as a merge nobody asked for."""
    loader = MigrationLoader(None, ignore_no_migrations=True)
    leaves = {node for node in loader.graph.leaf_nodes() if node[0] in MIGRATION_APPS}

    assert leaves == {(app, names[-1]) for app, names in HISTORY.items()}


def test_no_migration_names_a_model_or_an_app_that_left():
    """Invariant: no migration file references a removed model or a removed app.
    `KeyPackage` and the MLS group state went in phase 1, and no token table has
    ever existed — `simplejwt`'s blacklist is a per-device login record at rest,
    which is what ADR-0006 refuses to hold."""
    gone = ("KeyPackage", "keypackage", "token_blacklist", "HistoryRecord")
    written = {
        (app, name): (settings.BASE_DIR / app / "migrations" / f"{name}.py").read_text()
        for app, names in HISTORY.items()
        for name in names
    }
    found = {
        (node, marker)
        for node, source in written.items()
        for marker in gone
        if marker in source
    }

    assert found == set()


@pytest.mark.django_db(transaction=True)
def test_the_history_applies_to_an_empty_database(empty_database):
    """What a deployment of this version does: create the database, migrate once.
    ADR-0009 makes that the only supported path, so it is the one this proves."""
    call_command("migrate", database=empty_database, verbosity=0)

    assert project_tables() <= tables_in(empty_database)


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize("app", teardown_order())
def test_every_app_unapplies_to_zero(empty_database, app):
    """Reversibility of the whole history, app by app. Every operation in it is a
    `CreateModel` or the `DeleteModel` that reverses one, so nothing has to be
    recovered — but an app that cannot reach zero is one whose history carries an
    operation that lies about its own reverse.

    The ledger is asserted beside the catalogue, because an app that owns no table
    would otherwise be checked against an empty set: `voicerooms` reaches zero by
    re-creating the room table and dropping it again, and only the ledger shows it
    happened.
    """
    call_command("migrate", database=empty_database, verbosity=0)

    call_command("migrate", app, "zero", database=empty_database, verbosity=0)

    applied = MigrationRecorder(connections[empty_database]).applied_migrations()
    assert tables_in(empty_database) & tables_of(app) == set()
    assert {name for recorded, name in applied if recorded == app} == set()


@pytest.mark.django_db(transaction=True)
def test_the_whole_history_unapplies_in_reverse_dependency_order(empty_database):
    """Every app to zero, one call each, leaving no table of this project behind."""
    call_command("migrate", database=empty_database, verbosity=0)

    for app in teardown_order():
        call_command("migrate", app, "zero", database=empty_database, verbosity=0)

    assert tables_in(empty_database) & project_tables() == set()


# --- Lock classification ----------------------------------------------------------
# Every operation this project's migrations may carry, and the lock it takes on
# PostgreSQL 16. An operation outside this table is unclassified, which is what
# `test_every_operation_takes_a_classified_lock` refuses: the reviewer has to name
# the lock and decide whether it can run under traffic before the file lands.
#
# `CreateModel` takes ACCESS EXCLUSIVE, which blocks reads and writes — but only on
# a relation the same migration is creating, so no other session can name it yet.
# `DeleteModel` takes the same lock on a relation that already exists, which is the
# one operation here that can block another session; it is a catalogue change and
# not a scan, so the hold is milliseconds rather than a function of the row count.
# `AddIndexConcurrently` takes SHARE UPDATE EXCLUSIVE and blocks neither, at the
# price of two table scans and a migration that cannot be atomic.
# `AlterField` is the one entry here whose lock depends on what the field became:
# a type change rewrites the table under ACCESS EXCLUSIVE for as long as the scan
# takes, and `SET NOT NULL` scans it under the same lock. Naming the operation is
# therefore not enough on its own, and the statement gate below is the other half:
# `ALTER TABLE` is narrowed to `ADD CONSTRAINT` and `ALTER COLUMN … DROP NOT NULL`,
# so every other form of `AlterField` fails there rather than passing here.
LOCK_CLASSES = {
    "CreateModel": "ACCESS EXCLUSIVE on a relation this migration creates",
    "DeleteModel": "ACCESS EXCLUSIVE on a relation this migration drops",
    "AddIndexConcurrently": "SHARE UPDATE EXCLUSIVE",
    "AlterField": (
        "ACCESS EXCLUSIVE on a relation that already exists, for the length of a "
        "catalogue write — DROP NOT NULL clears one flag in `pg_attribute` and "
        "reads no row of the table"
    ),
    "AddField": (
        "ACCESS EXCLUSIVE on a relation that already exists, for the length of a "
        "catalogue write — PostgreSQL 11 and later evaluate a non-volatile default "
        "once at DDL time and store it in `pg_attribute.attmissingval` rather than "
        "rewriting the table. Measured at 1.7 ms against a 200 000-row, 111.6 MB "
        "copy with `relfilenode` unchanged either side"
    ),
    "RunPython": (
        "ROW EXCLUSIVE on the relation it updates, one batch at a time — the lock "
        "every INSERT, UPDATE and DELETE already holds, so it blocks no other "
        "writer. It is held for one batch and not for the migration, which is what "
        "`atomic = False` and the per-batch transaction buy"
    ),
}

# The operations that cannot run inside a transaction block. A migration carrying
# one declares `atomic = False`, and Django raises NotSupportedError otherwise.
NON_ATOMIC_OPERATIONS = {"AddIndexConcurrently", "RemoveIndexConcurrently"}

# The operations that MAY leave the transaction, and the reason each one does. A
# batched backfill inside one transaction holds a row lock on every row it has
# touched until the last batch commits, which is the whole thing the batching
# exists to avoid — so `RunPython` is allowed to declare `atomic = False` where the
# operations above require it.
NON_ATOMIC_BY_CHOICE = {"RunPython"}

# The statement forms the classification above admits. `sqlmigrate` output is read
# against this rather than trusted: an operation name says what Django meant, and
# the SQL says what PostgreSQL will do.
ALLOWED_STATEMENTS = (
    "CREATE TABLE",
    "CREATE INDEX CONCURRENTLY",
    "CREATE INDEX",
    "CREATE UNIQUE INDEX",
    "DROP TABLE",
    "ALTER TABLE",  # narrowed below to four forms
)

# The four `ALTER TABLE` forms the classification covers. `ADD CONSTRAINT` is judged
# against the table it names — free on one this migration created, a validating scan
# on one that was already there. The other three are judged for themselves, because
# each one is a catalogue write whose cost does not grow with the table:
#
# * `DROP NOT NULL` clears `pg_attribute.attnotnull` and touches no row;
# * `ADD COLUMN … DEFAULT <constant> NOT NULL` stores the evaluated default in
#   `pg_attribute.attmissingval` on PostgreSQL 11 and later and rewrites nothing —
#   measured, `relfilenode` unchanged (`docs/architecture/GROUND-TRUTH.md` §4);
# * `DROP DEFAULT` is the statement Django emits right after that one, and it
#   removes a catalogue entry.
#
# Every other form — `TYPE`, `SET NOT NULL`, `SET DEFAULT`, `DROP COLUMN` — rewrites
# or scans, and each one fails here. `ADD COLUMN` with a *volatile* default would
# rewrite too, and is caught by the `DEFAULT` check beside it.
ALLOWED_ALTERATIONS = ("ADD CONSTRAINT", "DROP NOT NULL", "ADD COLUMN", "DROP DEFAULT")

# A default PostgreSQL will not put in `attmissingval`. `random()`, `nextval()` and
# `clock_timestamp()` are each volatile, and `ADD COLUMN` with one of them rewrites
# the whole table under the lock the classification calls a catalogue write.
VOLATILE_DEFAULTS = ("RANDOM(", "NEXTVAL(", "CLOCK_TIMESTAMP(", "GEN_RANDOM_UUID(")

# The `ALTER TABLE` forms whose cost is a catalogue write and never a scan, so they
# may name a table the migration did not create.
CATALOGUE_ONLY = ("DROP NOT NULL", "ADD COLUMN", "DROP DEFAULT")


def migration_nodes():
    return [(app, name) for app, names in HISTORY.items() for name in names]


def loaded(app, name):
    return MigrationLoader(None, ignore_no_migrations=True).disk_migrations[(app, name)]


@pytest.mark.parametrize(("app", "name"), migration_nodes())
def test_every_operation_takes_a_classified_lock(app, name):
    """The gate on a migration nobody has priced. Every operation in the tree is one
    whose lock is written down in `LOCK_CLASSES`; an `AddField`, an `AlterField`, a
    plain `AddIndex` or an `AddConstraint` lands here as an unclassified operation
    and stays out of the tree until its lock is named and judged."""
    unclassified = {
        type(operation).__name__
        for operation in loaded(app, name).operations
        if type(operation).__name__ not in LOCK_CLASSES
    }

    assert unclassified == set(), f"{app}.{name} carries {sorted(unclassified)}"


@pytest.mark.parametrize(("app", "name"), migration_nodes())
def test_the_atomic_flag_matches_the_operations_the_migration_carries(app, name):
    """A concurrent index build outside a transaction, everything else inside one
    unless it is a batched backfill. Django raises NotSupportedError for the first
    mismatch; the second — a schema migration downgraded to `atomic = False` for no
    reason — it accepts silently, and a failure part-way then leaves half the schema
    applied.

    A batched `RunPython` is the one case that leaves the transaction by choice
    rather than by requirement, so it is admitted by name: batching inside a single
    transaction holds a row lock on every row the backfill has touched until the
    last batch commits, which is what the batching exists to avoid.
    """
    migration = loaded(app, name)
    carried = {type(operation).__name__ for operation in migration.operations}

    if carried & NON_ATOMIC_OPERATIONS:
        assert migration.atomic is False
    elif migration.atomic is False:
        assert carried <= NON_ATOMIC_BY_CHOICE, sorted(carried)
    else:
        assert migration.atomic is True


def statements_of(sql):
    """The statements of one `sqlmigrate` run, comments and the wrapper gone."""
    body = " ".join(
        line.strip()
        for line in sql.splitlines()
        if line.strip() and not line.strip().startswith("--")
    )
    return [
        " ".join(statement.split())
        for statement in body.split(";")
        if statement.strip() and statement.strip() not in ("BEGIN", "COMMIT")
    ]


# `transaction=True`, not the default atomic wrapper: `sqlmigrate` builds the
# statements through the real schema editor, and `AddIndexConcurrently` refuses to
# do that inside a transaction — the same NotSupportedError a wrongly-atomic
# migration would raise on the deployment host.
@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize(("app", "name"), migration_nodes())
def test_the_generated_sql_is_only_the_statements_the_classification_covers(app, name):
    """The `sqlmigrate` review, run rather than remembered.

    Every statement is a relation this migration creates, or a concurrent index
    build. An `ALTER TABLE` that is anything but `ADD CONSTRAINT` on a
    same-migration table would be a rewrite or an ACCESS EXCLUSIVE hold on a
    relation with rows in it.

    The transaction wrapper is read from the same output, because the `atomic`
    flag is only a claim until the SQL carries it: a concurrent index build inside
    a `BEGIN` is a statement PostgreSQL refuses outright.
    """
    out = StringIO()
    call_command("sqlmigrate", app, name, stdout=out)
    sql = out.getvalue()
    statements = statements_of(sql)

    if (app, name) in DATA_MIGRATIONS:
        # A `RunPython` reduces to no SQL at all, so the assertion is the other
        # way round: this file carries data and no schema, and a schema operation
        # that appeared in it would be one this gate never read.
        assert statements == []
        return
    assert statements
    assert ("BEGIN;" in sql) is loaded(app, name).atomic
    for statement in statements:
        assert statement.startswith(ALLOWED_STATEMENTS), statement
        if statement.startswith("ALTER TABLE"):
            assert any(form in statement for form in ALLOWED_ALTERATIONS), statement
        if "ADD COLUMN" in statement and "DEFAULT" in statement:
            # The one form whose lock class depends on the value beside it: a
            # volatile default is evaluated per row, which is a rewrite.
            upper = statement.upper()
            assert not any(call in upper for call in VOLATILE_DEFAULTS), statement


@pytest.mark.django_db(transaction=True)
def test_no_model_change_is_waiting_for_a_migration():
    """The gate that keeps the history above complete.

    A field added, renamed or altered with no migration written for it passes
    every test in this file — the recorded history still applies, still unapplies,
    and still carries the locks it was classified with — and then fails on the
    deployment host, after the code that needs the column is already serving.
    `makemigrations --check` is the question "does the disk match the models",
    and `--dry-run` is what keeps it from answering by writing the file.
    """
    out = StringIO()

    try:
        call_command("makemigrations", "--check", "--dry-run", stdout=out, verbosity=1)
    except SystemExit as exit_code:
        raise AssertionError(
            f"a model changed with no migration written for it:\n{out.getvalue()}"
        ) from exit_code


def test_the_apps_that_own_no_table_own_no_migrations_either():
    """`core` and `realtime` are plumbing: one holds the bucket sets, the opaque
    blob field and the panel's base classes, the other holds the socket gateway
    and its Redis bus. Neither declares a model, so a migrations directory under
    either is a table somebody added without deciding to.

    `voicerooms` is the one exemption and it is temporary. ADR-0021 removed the
    room object, and the package stays only to carry `0002_delete_room` to a
    database that still holds the table; it leaves once every environment has
    applied it, and then this exemption goes with it.
    """
    tableless = sorted(
        config.label
        for config in apps.get_app_configs()
        if not config.name.startswith("django.")
        and not config.name.startswith("unfold")
        and not any(config.get_models())
    )

    assert tableless == ["core", "realtime", "voicerooms"]
    for label in set(tableless) - MIGRATIONS_WITHOUT_A_TABLE:
        assert not (settings.BASE_DIR / label / "migrations").exists(), label


def test_the_recorded_history_covers_every_app_that_owns_migrations():
    """The other direction of `HISTORY`: an app that grew a model and a migration
    directory, and was never added to the record, would be replayed by nothing
    here."""
    assert sorted(HISTORY) == MIGRATION_APPS


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize("app", teardown_order())
def test_every_app_returns_to_head_after_unapplying_to_zero(empty_database, app):
    """The other half of reversibility: down is only useful if up follows it.

    A rollback on the deployment host unapplies an app and the next deploy applies
    it again, so a `0001_initial` whose reverse leaves a sequence, a constraint or
    an enum behind fails on the way back up rather than on the way down. Read from
    `django_migrations` as well as from the catalogue, because a table that exists
    while its row does not is a schema `migrate` will try to create twice.
    """
    call_command("migrate", database=empty_database, verbosity=0)
    call_command("migrate", app, "zero", database=empty_database, verbosity=0)

    call_command("migrate", app, database=empty_database, verbosity=0)

    applied = MigrationRecorder(connections[empty_database]).applied_migrations()
    assert tables_of(app) <= tables_in(empty_database)
    assert {name for recorded, name in applied if recorded == app} == set(HISTORY[app])


@pytest.mark.django_db(transaction=True)
def test_the_whole_history_returns_to_head_after_a_full_unapply(empty_database):
    """Every app to zero and the whole history applied again on top of the
    emptied database. This is the rollback a deploy of this version can perform,
    end to end, and the state it leaves is the one the next deploy migrates."""
    call_command("migrate", database=empty_database, verbosity=0)
    for app in teardown_order():
        call_command("migrate", app, "zero", database=empty_database, verbosity=0)

    call_command("migrate", database=empty_database, verbosity=0)

    applied = MigrationRecorder(connections[empty_database]).applied_migrations()
    assert project_tables() <= tables_in(empty_database)
    assert {node for node in applied if node[0] in MIGRATION_APPS} == set(
        migration_nodes()
    )


# --- The one backfill in the history -----------------------------------------------


def rows_of(alias, statement, params=()):
    with connections[alias].cursor() as cursor:
        cursor.execute(statement, params)
        return cursor.fetchall()


def execute(alias, statement, params=()):
    with connections[alias].cursor() as cursor:
        cursor.execute(statement, params)


def migrate_to(target, alias):
    call_command("migrate", "messaging", target, database=alias, verbosity=0)


def backfill_module():
    """The backfill's own module. Imported by path rather than by name, because a
    migration file starts with a digit and is not an identifier."""
    return import_module(f"messaging.migrations.{BACKFILL_THE_DAY}")


def seed_the_queue_before_the_day(alias, hours):
    """Rows as `0003` leaves them: a real `queued_hour`, and a `queued_day` that
    carries the day the migration ran rather than the day the row was enqueued.

    Written as SQL against the replay database rather than through the ORM. The
    models this project ships are the state *after* the whole history, and what
    the backfill runs against is the state at `0003`.
    """
    account = rows_of(
        alias,
        """
        INSERT INTO accounts_user (id, password, is_superuser, username, is_active,
                                   is_staff, created_date)
        VALUES (gen_random_uuid(), '', false, 'backfill', true, false, CURRENT_DATE)
        RETURNING id
        """,
    )[0][0]
    device = rows_of(
        alias,
        """
        INSERT INTO devices_device (id, user_id, ik_pub, spk_id, spk_pub, spk_sig,
                                    registration_id, bundle_version, token_generation,
                                    refresh_generation, created_date, queue_seq,
                                    queue_pruned_through)
        VALUES (gen_random_uuid(), %s, ''::bytea, 1, ''::bytea, ''::bytea, 1, 0, 1, 1,
                CURRENT_DATE, 0, 0)
        RETURNING id
        """,
        [account],
    )[0][0]
    for seq, hour in enumerate(hours, start=1):
        execute(
            alias,
            """
            INSERT INTO messaging_queuedenvelope
                (id, recipient_device_id, seq, blob, queued_hour, queued_day)
            VALUES (gen_random_uuid(), %s, %s, ''::bytea, %s, CURRENT_DATE)
            """,
            [device, seq, hour],
        )


BACKFILL_HOURS = [
    "2026-01-01 23:59:00+00",
    "2026-01-02 00:00:00+00",
    "2026-03-09 17:00:00+00",
    None,  # written by the code that came after `0003`, and already correct
    "2026-08-31 12:00:00+00",
]


@pytest.mark.django_db(transaction=True)
def test_the_backfill_gives_every_row_the_day_of_its_own_hour(empty_database):
    """What `0003` leaves behind and `0004` corrects. `ADD COLUMN … DEFAULT` stores
    one evaluated value for every existing row, so without this pass the whole table
    would expire on one day — the day the migration ran."""
    call_command("migrate", "messaging", "0003", database=empty_database, verbosity=0)
    seed_the_queue_before_the_day(empty_database, BACKFILL_HOURS)

    call_command(
        "migrate", "messaging", BACKFILL_THE_DAY, database=empty_database, verbosity=0
    )

    stored = rows_of(
        empty_database,
        "SELECT queued_hour, queued_day FROM messaging_queuedenvelope ORDER BY seq",
    )
    assert [(hour.date() if hour else None) for hour, _day in stored] == [
        hour.date() if hour else None
        for hour in [
            None if raw is None else datetime.fromisoformat(raw) for raw in BACKFILL_HOURS
        ]
    ]
    for hour, day in stored:
        if hour is not None:
            assert day == hour.date()


@pytest.mark.django_db(transaction=True)
def test_the_backfill_leaves_a_row_with_no_hour_alone(empty_database):
    """Only the code that came after `0003` writes NULL there, and it writes the
    correct day beside it. Guessing a day for that row would be inventing one."""
    call_command("migrate", "messaging", "0003", database=empty_database, verbosity=0)
    seed_the_queue_before_the_day(empty_database, [None])
    before = rows_of(empty_database, "SELECT queued_day FROM messaging_queuedenvelope")

    call_command(
        "migrate", "messaging", BACKFILL_THE_DAY, database=empty_database, verbosity=0
    )

    assert (
        rows_of(empty_database, "SELECT queued_day FROM messaging_queuedenvelope")
        == before
    )


@pytest.mark.django_db(transaction=True)
def test_the_backfill_is_idempotent(empty_database):
    """A crash part-way through leaves a mix of filled and unfilled rows, and the
    repair is to run it again. Re-running must be a no-op on the rows it already
    settled — which is what the `exclude` on the mismatch buys."""
    from django.apps import apps as global_apps

    migrate_to(BACKFILL_THE_DAY, empty_database)
    seed_the_queue_before_the_day(empty_database, BACKFILL_HOURS)
    backfill = backfill_module()
    editor = connections[empty_database].schema_editor()
    backfill.fill_the_day_from_the_hour(global_apps, editor)
    once = rows_of(
        empty_database,
        "SELECT seq, queued_day FROM messaging_queuedenvelope ORDER BY seq",
    )

    backfill.fill_the_day_from_the_hour(global_apps, editor)

    assert once
    assert (
        rows_of(
            empty_database,
            "SELECT seq, queued_day FROM messaging_queuedenvelope ORDER BY seq",
        )
        == once
    )


@pytest.mark.django_db(transaction=True)
def test_the_backfill_updates_in_batches_that_bound_its_lock_time(
    empty_database, monkeypatch
):
    """One unbounded `UPDATE` holds a row lock on every row it touches until it
    commits, against the largest table in the schema and the one every send writes
    to. Five rows at a batch of two is three statements, not one."""
    from django.apps import apps as global_apps

    migrate_to(BACKFILL_THE_DAY, empty_database)
    seed_the_queue_before_the_day(empty_database, BACKFILL_HOURS)
    backfill = backfill_module()
    monkeypatch.setattr(backfill, "BATCH", 2)
    editor = connections[empty_database].schema_editor()

    with CaptureQueriesContext(connections[empty_database]) as context:
        backfill.fill_the_day_from_the_hour(global_apps, editor)

    updates = [
        query["sql"]
        for query in context.captured_queries
        if query["sql"].startswith('UPDATE "messaging_queuedenvelope"')
    ]
    assert len(updates) == 2  # four rows carry an hour, two at a time


# --- The locks each migration actually takes ---------------------------------------
# `LOCK_CLASSES` above says what an operation is meant to take. This section runs the
# statements and reads `pg_locks`, because the operation name is a claim and the lock
# is what the deployment lives with.
#
# The eight modes, in the order the PostgreSQL documentation lists them, weakest
# first. Everything from SHARE upwards conflicts with ROW EXCLUSIVE, which is what
# every INSERT, UPDATE and DELETE holds: a migration that takes one of those on a
# populated table stops writes to it for the duration.
LOCK_STRENGTH = [
    "AccessShareLock",
    "RowShareLock",
    "RowExclusiveLock",
    "ShareUpdateExclusiveLock",
    "ShareLock",
    "ShareRowExclusiveLock",
    "ExclusiveLock",
    "AccessExclusiveLock",
]

# The relations that already exist when each migration runs, and the strongest lock
# it takes on each. A relation this migration creates is absent from the map however
# hard it is locked: no other session can name a relation that does not exist yet.
#
# Every SHARE ROW EXCLUSIVE entry comes from the same statement shape — `ALTER TABLE
# ... ADD CONSTRAINT ... FOREIGN KEY ... REFERENCES <other table>`, which locks the
# referenced side. It blocks writes to that table, not reads. ADR-0009 is what makes
# it free here: the deployment creates the database and migrates once, so nothing is
# populated and nothing is being written. On a database with rows in it, each of
# these would be a write outage on the named table for as long as the migration runs.
#
# `voicerooms.0001_initial` held no foreign key at all — a room was a capability id
# and an encrypted name — so it locks nothing that exists. Its `0002_delete_room` is
# the one entry in this map that blocks reads as well as writes: `DROP TABLE` takes
# ACCESS EXCLUSIVE on a table that is already there. It costs nothing on this
# deployment because the same release removed every reader of it and because the
# service is stopped before `migrate` runs.
#
# The `0002_retire_the_activity_dates` rows are the other kind: they create and drop
# nothing, so every lock in them is on a relation that already exists. Each is an
# ACCESS EXCLUSIVE for one `DROP NOT NULL`, which blocks reads as well as writes —
# for the length of a catalogue write, because the statement clears a flag and reads
# no row. A concurrent statement in flight still has to finish before the lock is
# granted, so the deploy takes it with the service stopped like every other.
# The `messaging` day-granularity rows are the third kind: `0003` takes ACCESS
# EXCLUSIVE on the queue table for three catalogue writes in one transaction — the
# `ADD COLUMN` with its evaluated default, the `DROP DEFAULT` behind it, and the
# `DROP NOT NULL` on the column it replaces — and reads no row of the table for any
# of them. `0005` is the concurrent index build the probe below cannot measure, and
# `0004` carries no DDL at all, so neither appears in this map.
BLOCKING_LOCKS = {
    ("accounts", INITIAL): {
        "auth_group": "ShareRowExclusiveLock",
        "auth_permission": "ShareRowExclusiveLock",
    },
    ("accounts", RETIRE_DATES): {"accounts_profileblob": "AccessExclusiveLock"},
    ("attachments", INITIAL): {"accounts_user": "ShareRowExclusiveLock"},
    ("devices", INITIAL): {"accounts_user": "ShareRowExclusiveLock"},
    ("devices", RETIRE_DATES): {
        "devices_device": "AccessExclusiveLock",
        "devices_devicelogrecord": "AccessExclusiveLock",
        "devices_useridentity": "AccessExclusiveLock",
    },
    ("messaging", INITIAL): {"devices_device": "ShareRowExclusiveLock"},
    ("messaging", "0003_expand_the_queue_to_a_day"): {
        "messaging_queuedenvelope": "AccessExclusiveLock"
    },
    ("vault", INITIAL): {"accounts_user": "ShareRowExclusiveLock"},
    ("vault", RETIRE_DATES): {"vault_keybackup": "AccessExclusiveLock"},
    ("voicerooms", INITIAL): {},
    ("voicerooms", "0002_delete_room"): {"voicerooms_room": "AccessExclusiveLock"},
}

RELATIONS_IN_SCHEMA = """
SELECT c.oid, c.relname, c.relkind
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = current_schema()
"""

# Relation locks this backend holds right now, by oid rather than through a join to
# `pg_class`. The join would be simpler and would silently lose the one lock that
# matters most: a relation this migration dropped has no catalogue row left inside
# the transaction that dropped it, so its ACCESS EXCLUSIVE would vanish from the
# result and a `DeleteModel` would measure as taking no lock at all. The schema read
# before the statements and the one after them are what name the oids instead, and
# an oid in neither is the catalogue read of the query itself.
LOCKS_HELD = """
SELECT l.mode, l.relation
FROM pg_locks l
WHERE l.pid = pg_backend_pid() AND l.locktype = 'relation'
"""


def tables_of(app):
    return {
        model._meta.db_table
        for model in apps.get_models()
        if model._meta.app_label == app
    }


def atomic_nodes():
    return [node for node in migration_nodes() if loaded(*node).atomic]


def non_atomic_nodes():
    return [node for node in migration_nodes() if not loaded(*node).atomic]


def apply_the_state_before(node, alias):
    """Everything this migration depends on, and nothing of the migration itself.

    The graph is what names the parents rather than the file, because a swappable
    dependency is written as `__first__` in the source and resolved to a node only
    once the graph is built.
    """
    graph = MigrationLoader(None, ignore_no_migrations=True).graph
    for parent_app, parent_name in sorted(graph.node_map[node].parents):
        call_command("migrate", parent_app, parent_name, database=alias, verbosity=0)


def run_and_read_the_locks(alias, statements):
    """Run the statements in one transaction and read what it holds, then roll back.

    One transaction, because a lock is released at commit and this has to read it
    while it is held. The rollback is what keeps the probe from being a migration:
    nothing it created or dropped survives the call.

    Returns the locks as (mode, relname, relkind) — resolved from the schema read on
    either side of the statements, so a relation the migration dropped is still
    named — plus the relations it created and the relations it dropped.
    """
    with connections[alias].cursor() as cursor:
        cursor.execute(RELATIONS_IN_SCHEMA)
        before = {oid: (name, kind) for oid, name, kind in cursor.fetchall()}
    with transaction.atomic(using=alias):
        with connections[alias].cursor() as cursor:
            for statement in statements:
                cursor.execute(statement)
            cursor.execute(LOCKS_HELD)
            held = cursor.fetchall()
            cursor.execute(RELATIONS_IN_SCHEMA)
            after = {oid: (name, kind) for oid, name, kind in cursor.fetchall()}
        transaction.set_rollback(True, using=alias)
    known = {**before, **after}
    locks = [(mode, *known[oid]) for mode, oid in held if oid in known]
    created = {name for name, _kind in (after[oid] for oid in after.keys() - before)}
    dropped = {name for name, _kind in (before[oid] for oid in before.keys() - after)}
    return locks, created, dropped


def strongest(modes):
    return max(modes, key=LOCK_STRENGTH.index)


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize(("app", "name"), atomic_nodes())
def test_each_migration_takes_only_the_locks_recorded_against_it(
    empty_database, app, name
):
    """The lock review, measured rather than argued.

    The migration's own SQL is run against a database migrated to exactly the state
    that precedes it, and `pg_locks` is read while the transaction still holds
    everything it took. Two things are asserted: no relation that already existed
    is locked harder than `BLOCKING_LOCKS` records, and nothing outside the set of
    relations this migration created or dropped is held at ACCESS EXCLUSIVE.

    What this catches in a migration somebody adds later: an `ALTER TABLE` that
    rewrites a populated table or sets a column NOT NULL without a validated
    constraint first, both of which take ACCESS EXCLUSIVE on a relation that
    already exists; a plain `CREATE INDEX` on one, which takes SHARE; and a new
    foreign key to a table that is not this migration's, which takes SHARE ROW
    EXCLUSIVE and would appear in the map the author has to write down.

    What it does not catch: how long any of them is held. A lock class is not a
    duration, and an ACCESS EXCLUSIVE on a table this migration created is free
    only because no other session can name that relation yet — the same statement
    against a populated table would be an outage. A drop is the case where the lock
    class alone decides nothing: `voicerooms.0002_delete_room` takes the strongest
    lock in the list on a relation every other session can name, and what makes it
    free is the release that removed every reader, not this measurement. It also
    measures nothing about migrations that cannot run inside a transaction; the one
    this project has is held by the test below.
    """
    apply_the_state_before((app, name), empty_database)
    out = StringIO()
    call_command("sqlmigrate", app, name, database=empty_database, stdout=out)

    locks, created, dropped = run_and_read_the_locks(
        empty_database, statements_of(out.getvalue())
    )

    pre_existing = {
        relname: strongest([mode for mode, name_, _kind in locks if name_ == relname])
        for _mode, relname, kind in locks
        if kind == "r" and relname not in created
    }
    exclusive = {
        relname
        for mode, relname, _kind in locks
        if mode in ("AccessExclusiveLock", "ExclusiveLock")
    }

    recorded = BLOCKING_LOCKS[(app, name)]
    assert created or dropped or pre_existing, "the migration changed no relation"
    assert pre_existing == recorded
    assert exclusive <= created | dropped | set(recorded), sorted(
        exclusive - created - dropped - set(recorded)
    )


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize(("app", "name"), non_atomic_nodes())
def test_the_index_built_outside_a_transaction_is_built_concurrently(
    empty_database, app, name
):
    """The one migration the lock probe above cannot measure.

    `CREATE INDEX CONCURRENTLY` is refused inside a transaction block, so the
    statements cannot be run and rolled back with the lock still held. What is
    asserted instead is the statement itself: the concurrent form takes SHARE
    UPDATE EXCLUSIVE and blocks no write, where the plain form takes SHARE and
    stops every send for the length of the build. This is the largest table in the
    schema and the one every send writes to.

    The claim about which lock each form takes is PostgreSQL's documentation, not
    a measurement — an unmeasured claim, recorded as one.
    """
    apply_the_state_before((app, name), empty_database)
    out = StringIO()
    call_command("sqlmigrate", app, name, database=empty_database, stdout=out)
    statements = statements_of(out.getvalue())

    if (app, name) in DATA_MIGRATIONS:
        # It leaves the transaction to commit one batch at a time, not to run a
        # statement PostgreSQL refuses inside one. It emits no DDL, which is what
        # `test_the_generated_sql_is_only_the_statements_the_classification_covers`
        # holds, and its lock is `ROW EXCLUSIVE` for the length of one batch.
        assert statements == []
        return
    assert statements
    assert "BEGIN;" not in out.getvalue()
    for statement in statements:
        assert statement.startswith("CREATE INDEX CONCURRENTLY"), statement


# The relation a statement acts on: the table of an `ALTER TABLE`, and the table an
# index is built on rather than the index's own name.
TARGET = re.compile(
    r"^(?:ALTER TABLE"
    r'|CREATE (?:UNIQUE )?INDEX(?: CONCURRENTLY)? "[^"]+" ON)'
    r'\s+"([^"]+)"'
)


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize(("app", "name"), migration_nodes())
def test_no_statement_alters_or_indexes_a_table_the_migration_did_not_create(app, name):
    """The rule the statement prefixes do not carry, and the one that holds for the
    migrations no transaction can wrap.

    `ALTER TABLE ... ADD CONSTRAINT` is admitted by the classification, and on a
    table the same migration creates it costs nothing. On a table that was already
    there it is a validating scan under a lock that blocks writes, and the prefix
    check would pass it. The same goes for a plain `CREATE INDEX`: on a new table
    it is free, on a populated one it takes SHARE for the whole build.

    Four statements are allowed to name a table they did not create. The concurrent
    index build blocks nothing at all. `ALTER COLUMN … DROP NOT NULL`, `ADD COLUMN`
    with a non-volatile default and the `DROP DEFAULT` that follows it each block
    everything for a catalogue write and read no row, so unlike the two above their
    cost does not grow with the table — which is the whole reason they are the shapes
    a column is retired and introduced in.
    """
    out = StringIO()
    call_command("sqlmigrate", app, name, stdout=out)
    statements = statements_of(out.getvalue())
    created = {
        statement.split('"')[1]
        for statement in statements
        if statement.startswith("CREATE TABLE")
    }

    foreign = {
        target.group(1)
        for statement in statements
        if not statement.startswith("CREATE INDEX CONCURRENTLY")
        and not any(form in statement for form in CATALOGUE_ONLY)
        for target in [TARGET.match(statement)]
        if target is not None and target.group(1) not in created
    }

    if (app, name) in DATA_MIGRATIONS:
        assert statements == []
        return
    assert statements
    assert foreign == set()
