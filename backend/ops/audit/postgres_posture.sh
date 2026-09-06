#!/usr/bin/env bash
# ops/audit/postgres_posture.sh — the logging posture, read back from the server that
# is actually running.
#
# PostgreSQL is the one layer of this deployment that writes request data to disk by
# default, and it is the layer no test in this repository can reach: the posture lives
# in `postgresql.conf` on a host, so nothing in the tree reports it moving. At the
# stock `log_min_error_statement = error` a failing statement is written to the server
# log in full, and a statement of this schema carries device ids, envelope ids and
# bucketed ciphertext; at the stock `log_error_verbosity = default` the DETAIL line
# beside it names the conflicting key values. Measured on PostgreSQL 16.14 against a
# mailbox-shaped table, a duplicate insert wrote the constraint name, then
# `DETAIL: Key (device, seq)=(1111…, 7) already exists.`, then the whole INSERT with
# its blob; under the posture below it wrote the constraint name and nothing else.
#
# `ops/postgres/README.md` names each setting and its reason, and `ops/RUNBOOK.md` §8
# runs this after every deploy — where an operator's earlier edit, a restored
# `postgresql.conf` or a package upgrade is what it catches.
set -euo pipefail

for name in POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_HOST POSTGRES_PORT; do
    if [ -z "${!name:-}" ]; then
        echo "FAIL: ${name} is unset — source the environment file first."
        exit 1
    fi
done

# The password reaches psql through the environment and never through an argument:
# /proc/*/cmdline is world-readable on this host, and the VPS serves two other
# projects.
export PGPASSWORD="$POSTGRES_PASSWORD"

show() {
    psql --no-psqlrc --quiet --tuples-only --no-align \
        --host "$POSTGRES_HOST" --port "$POSTGRES_PORT" \
        --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        --command "SHOW $1"
}

if ! show log_min_messages >/dev/null 2>&1; then
    # The variables and not their values, the same way the loop above reports an
    # unset one. Nothing this script prints names a host, a database or a secret.
    echo "FAIL: cannot reach the server POSTGRES_HOST, POSTGRES_PORT and POSTGRES_DB name."
    exit 1
fi

# The whole of the posture, as `SHOW` reports it. `ops/postgres/README.md` carries the
# reason for each line, and `ops/tests/test_scripts.py` holds the two files to the same
# list — a setting written in one and not the other fails the suite.
EXPECTED=(
    "log_statement=none"
    "log_min_error_statement=panic"
    "log_min_duration_statement=-1"
    "log_min_duration_sample=-1"
    "log_duration=off"
    "log_connections=off"
    "log_disconnections=off"
    "log_lock_waits=off"
    "log_error_verbosity=terse"
    "log_min_messages=warning"
)

differing=0
for pair in "${EXPECTED[@]}"; do
    setting="${pair%%=*}"
    want="${pair#*=}"
    have="$(show "$setting")"
    if [ "$have" != "$want" ]; then
        echo "DIFFERS: ${setting} is '${have}', the posture is '${want}'"
        differing=$((differing + 1))
    fi
done

if [ "$differing" -ne 0 ]; then
    echo "FAIL: ${differing} setting(s) differ from ops/postgres/README.md."
    exit 1
fi

echo "PASS: ${#EXPECTED[@]} settings, all as ops/postgres/README.md sets them."
