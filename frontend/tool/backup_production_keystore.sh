#!/usr/bin/env bash
# Produce an encrypted, self-describing backup of the production signing
# identity (ADR-076 D3).
#
# The backup is a GnuPG symmetric AES-256 archive whose passphrase is stretched
# by salted, iterated SHA-512, so restoring it needs only gpg and the backup
# passphrase - no key server, no account, no vendor. Run it once for each backup
# drive, and test-decrypt every archive it writes.

set -euo pipefail
set +x

source "$(dirname "${BASH_SOURCE[0]}")/release_env.sh"

readonly default_material_root="${CP_PRODUCTION_MATERIAL_ROOT:-$HOME/.communication-platform/production-signing}"
keystore_path="${CP_PRODUCTION_KEYSTORE_FILE:-$default_material_root/communication-platform-production.p12}"
readonly key_alias="communication-platform-production"
output_directory="."

usage() {
  cat <<'USAGE'
Usage: tool/backup_production_keystore.sh [options]

  --out DIR         Directory to write the encrypted backup into (default: .).
                    It must lie outside the repository: use a folder on the
                    backup drive.
  --keystore PATH   Keystore to back up (default: ~/.communication-platform/
                    production-signing/communication-platform-production.p12).
  -h, --help        Show this message.

Writes <name>.tar.gz.gpg, its .sha256, and an unencrypted .txt label that
identifies the backup without revealing anything secret. gpg asks for the
backup passphrase itself. Nothing is ever overwritten.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keystore) keystore_path="$2"; shift 2 ;;
    --out) output_directory="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

# --- Refuse before anything is copied or written ------------------------------

output_directory="$(absolute_path "$output_directory")"
refuse_repository_path "The backup directory" "$output_directory"
command -v gpg >/dev/null 2>&1 || fail "gpg is required to encrypt the backup."
[[ -f "$keystore_path" ]] || fail "Keystore not found: $keystore_path"
[[ -n "$production_certificate_sha256" ]] ||
  fail "No certificate fingerprint recorded in android/production-release-identity.properties.
       Back up an identity only after it has been recorded there."

readonly stamp="$(date -u +%Y%m%dT%H%M%SZ)"
readonly backup_name="communication-platform-production-signing-$stamp"
readonly archive_path="$output_directory/$backup_name.tar.gz.gpg"
for existing in "$archive_path" "$archive_path.sha256" "$output_directory/$backup_name.txt"; do
  [[ ! -e "$existing" ]] || fail "$existing already exists. A backup never overwrites a file."
done
mkdir -p "$output_directory"

staging="$(mktemp -d)"
# The staging directory holds the private key in the clear; remove it whatever
# happens, including on interrupt.
cleanup() { rm -rf "$staging"; }
trap cleanup EXIT INT TERM

readonly payload="$staging/$backup_name"
mkdir -p "$payload"
cp "$keystore_path" "$payload/$(basename "$keystore_path")"

# A restore card travels inside the encrypted archive, so whoever opens it years
# from now knows exactly what it is and what to do with it.
cat > "$payload/RESTORE.txt" <<CARD
Communication Platform - production signing identity
Created (UTC):        $stamp
Application ID:       $production_application_id
Key alias:            $key_alias
Certificate SHA-256:  $production_certificate_sha256
Keystore file:        $(basename "$keystore_path")
Keystore format:      PKCS12
Decision record:      ADR-076 in frontend/docs/decisions.md

WHAT THIS IS
  The only signing key that can publish an update to an installed production
  build. Without it, existing installs can never be updated again, and users
  would have to uninstall - which erases all app data, including the encrypted
  database and the envelope holding its key. Backup is disabled in the manifest
  and the database key has no exportable copy, so that loss is permanent.
  Whoever holds this key and its passphrase can sign an update that every
  install accepts.

TO RESTORE
  1. gpg --output $backup_name.tar.gz --decrypt $backup_name.tar.gz.gpg
  2. tar -xzf $backup_name.tar.gz
  3. Move the keystore somewhere private, outside any repository, then delete
     $backup_name.tar.gz: it holds the key unencrypted.
  4. Create a signing properties file, also outside any repository:
       storeFile=<absolute path to the keystore; on Windows C:/... with forward slashes>
       storePassword=<keystore passphrase>
       keyAlias=$key_alias
       keyPassword=<keystore passphrase>
  5. export CP_PRODUCTION_SIGNING_PROPERTIES=<path to that file>
  6. Confirm the identity before releasing anything:
       keytool -list -v -alias $key_alias -keystore <path to the keystore>
     Its SHA256 line, without colons and in lower case, must equal the
     certificate SHA-256 above.

THE KEYSTORE PASSPHRASE IS NOT IN THIS ARCHIVE.
  It is held separately on purpose. Without it this file is useless.
CARD

tar -czf "$staging/$backup_name.tar.gz" -C "$staging" "$backup_name"

echo "Choose a passphrase for the backup archive."
echo "It may differ from the keystore passphrase; if it does, record both."
# --cipher-algo encrypts the archive with AES-256. The passphrase is stretched by
# the S2K options: mode 3 salts and iterates it, and --s2k-digest-algo, not
# --digest-algo, chooses the hash it is iterated with.
gpg --symmetric \
  --cipher-algo AES256 \
  --s2k-digest-algo SHA512 \
  --s2k-mode 3 \
  --s2k-count 65011712 \
  --output "$archive_path" \
  "$staging/$backup_name.tar.gz"

(cd "$output_directory" && sha256sum "$backup_name.tar.gz.gpg" > "$backup_name.tar.gz.gpg.sha256")

# Public label, so a drive can be identified without decrypting anything.
cat > "$output_directory/$backup_name.txt" <<LABEL
Communication Platform - production signing identity backup
Created (UTC):        $stamp
Application ID:       $production_application_id
Certificate SHA-256:  $production_certificate_sha256
Encrypted archive:    $backup_name.tar.gz.gpg
Archive SHA-256:      $(cut -d' ' -f1 < "$output_directory/$backup_name.tar.gz.gpg.sha256")
Contains no secret. The archive needs its own passphrase; the keystore inside
needs the keystore passphrase.
LABEL

cat <<SUMMARY

Encrypted backup written.

  $archive_path
  $archive_path.sha256
  $output_directory/$backup_name.txt

Prove that it opens, without writing the key to disk. The first command clears
gpg's passphrase cache, so the test really asks for the passphrase:

  gpgconf --reload gpg-agent
  gpg --decrypt "$archive_path" | tar -tzf -

Record the backup passphrase apart from the archive, and keep this drive away
from this machine: one of the two backup drives belongs in another building
(ADR-076 D3). A backup that lives only on the machine that holds the original is
not a backup.
SUMMARY
