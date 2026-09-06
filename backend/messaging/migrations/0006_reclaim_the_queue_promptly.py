from django.db import migrations

# The stock autovacuum trigger is `autovacuum_vacuum_threshold` plus
# `autovacuum_vacuum_scale_factor` times the live row count — 50 plus a fifth. On a
# table of 200 000 envelopes that is 40 050 dead tuples before a vacuum runs, so an
# acknowledged envelope can sit in the free space of a data file for as long as it
# takes the next 40 049 to be acknowledged behind it. On a queue that empties and
# then goes quiet — which is what a shutdown looks like from this host — that is
# indefinitely.
#
# `backend/SECURITY.md` records what persists there: bucketed ciphertext this server
# cannot open, a recipient device id and a day. The window is what this bounds, not
# the residue, and nothing here zeroes a page.
SCALE_FACTOR = 0.01
THRESHOLD = 100

SET = (
    'ALTER TABLE "messaging_queuedenvelope" '
    f"SET (autovacuum_vacuum_scale_factor = {SCALE_FACTOR}, "
    f"autovacuum_vacuum_threshold = {THRESHOLD})"
)

RESET = (
    'ALTER TABLE "messaging_queuedenvelope" '
    "RESET (autovacuum_vacuum_scale_factor, autovacuum_vacuum_threshold)"
)


class Migration(migrations.Migration):
    """Storage parameters on the queue table, so a deleted row's space is reclaimed
    in minutes rather than after the next forty thousand deletions.

    At the values above the trigger is 100 dead tuples plus one percent of the live
    ones: 2100 on the 200 000-row shape `docs/architecture/GROUND-TRUTH.md` §4
    measures the sweep against, and 100 on an empty one. `autovacuum_naptime` is 60 s
    by default, so a table that crosses the trigger is vacuumed on the next pass.

    Measured on PostgreSQL 16.14: the statement takes SHARE UPDATE EXCLUSIVE on
    `messaging_queuedenvelope` and nothing else — it blocks no reader and no writer,
    only a concurrent DDL or vacuum on the same table — and `relfilenode` is unchanged
    either side of it against a 200 000-row copy, so it rewrites nothing. `RESET`
    takes the same lock and restores the cluster defaults, which is what makes this
    reversible rather than merely un-appliable.

    The deploy order is free: no code reads or writes a storage parameter, so the
    previous release serves against this schema and this release serves against the
    previous one.
    """

    dependencies = [("messaging", "0005_index_the_day_filter")]

    operations = [
        migrations.RunSQL(sql=SET, reverse_sql=RESET),
    ]
