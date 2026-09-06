#!/usr/bin/env bash
# ops/backup/identity_backup.sh — the encrypted identity backup.
#
# The one thing this deployment cannot rebuild. `user_id` sits inside every signed
# device bundle, so a lost database is not a lost account list — it is a new identity
# for every account, and a fresh SAS or QR verification with every contact, performed
# during whatever incident took the database. Nothing else here is irreplaceable: the
# code is in git, the wheels are vendored on the host, the TLS pair is issued from an
# offline CA, and the queue is seven days of ciphertext that expires anyway.
#
# So this dumps identity and nothing else. The eight tables below are the whole of
# what a restore needs; every other table is deliberately absent, and
# `ops/tests/test_scripts.py` fails if one appears. The queue, the attachments and the
# admin audit log are not backed up because a backup of them is a second copy of the
# exact rows `backend/SECURITY.md` bounds by retention — a longer-lived one, sitting
# in a directory the retention sweep does not reach.
#
# The output is encrypted to a public key on the host. The private key never exists
# here: it is generated with `age-keygen` on the operator's own machine and stays
# there, so root on this box can read every backup it has ever written and open none
# of them.
set -euo pipefail

RECIPIENT=/etc/chat/backup.pub
DESTINATION=/srv/chat/backups
KEEP=7

# Exactly what a restore of identity needs, and nothing that carries message content,
# routing metadata or operator history.
#
#   accounts_user            the username, the Argon2id hash, the flags
#   accounts_profileblob     the published profile blob
#   devices_useridentity     the account's identity and cross-signing public keys
#   devices_device           the device rows and their public key material
#   devices_onetimeprekey    the classical one-time prekeys still unclaimed
#   devices_pqonetimeprekey  the ML-KEM one-time prekeys still unclaimed
#   devices_devicelogrecord  the client-signed device-list log
#   vault_keybackup          the client-encrypted key backup blob
#
# Not here, and each for its own reason: `messaging_queuedenvelope` (seven days of
# ciphertext that expires on its own), `attachments_attachment` and the bytes under
# `media_root` (the same, at the attachment window), `django_admin_log` (operator
# history, held at day granularity for a month by decision), `django_session`, and the
# two Django join tables behind `accounts_user` — group membership and per-user
# permissions come back from the panel, and `is_staff` and `is_superuser` are columns
# on the row above and do survive.
TABLES=(
    accounts_user
    accounts_profileblob
    devices_useridentity
    devices_device
    devices_onetimeprekey
    devices_pqonetimeprekey
    devices_devicelogrecord
    vault_keybackup
)

for name in POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_HOST POSTGRES_PORT; do
    if [ -z "${!name:-}" ]; then
        echo "FAIL: ${name} is unset — the unit reads .env.production; see ops/RUNBOOK.md §11."
        exit 1
    fi
done

for tool in pg_dump age; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FAIL: ${tool} is not installed — see ops/RUNBOOK.md §1."
        exit 1
    fi
done

if [ ! -r "$RECIPIENT" ]; then
    echo "FAIL: ${RECIPIENT} is missing or unreadable — the operator installs the public half there."
    exit 1
fi

if [ ! -d "$DESTINATION" ]; then
    echo "FAIL: ${DESTINATION} does not exist — the host setup creates it, not this script."
    exit 1
fi

# Owner-only, whatever the unit's UMask is. The file is opaque without the offline
# key, and a mode is cheaper than trusting that.
umask 077

# The password reaches pg_dump through the environment and never through an argument:
# /proc/*/cmdline is world-readable and the VPS serves two other projects.
export PGPASSWORD="$POSTGRES_PASSWORD"

target="${DESTINATION}/identity-$(date -u +%Y-%m-%d).sql.age"
temp="${target}.partial"
trap 'rm -f -- "$temp"' EXIT

selection=()
for table in "${TABLES[@]}"; do
    selection+=(--table="$table")
done

# `--data-only`, so the restore is `migrate` and then this file: the schema comes from
# the migration history of the release being restored, which is the only schema the
# code being restored can serve against. A dumped schema would be the one that was
# current when the dump ran, and restoring it over a newer release is how a restore
# turns into an outage. pg_dump orders the data of a `--data-only` dump by the foreign
# keys between the dumped tables, so the file loads in an order that satisfies them.
#
# Piped rather than staged: with `pipefail` a pg_dump that fails fails the run, and
# the plaintext dump never touches the disk of the host it is being protected from.
# The write goes to `.partial` and is renamed only on success, so a failed run leaves
# nothing the rotation below would then count as one of the seven.
pg_dump \
    --host "$POSTGRES_HOST" --port "$POSTGRES_PORT" \
    --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --data-only "${selection[@]}" \
    | age --encrypt --recipients-file "$RECIPIENT" > "$temp"

mv -- "$temp" "$target"
trap - EXIT
echo "wrote ${target##*/} ($(wc -c < "$target") bytes, ${#TABLES[@]} tables)"

# The newest seven by the date in the name, which sorts because it is ISO 8601 — so
# this needs no mtime and is unaffected by a file that was copied or touched.
existing="$(cd "$DESTINATION" && ls -1 identity-*.sql.age 2>/dev/null | sort -r || true)"
printf '%s\n' "$existing" | tail -n "+$((KEEP + 1))" | while read -r stale; do
    [ -n "$stale" ] || continue
    rm -f -- "${DESTINATION}/${stale}"
    echo "removed ${stale}"
done
