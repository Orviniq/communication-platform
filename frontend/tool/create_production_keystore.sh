#!/usr/bin/env bash
# Create the one persistent production signing identity (ADR-076).
#
# Run this exactly once, ever. The key it produces is the only key that can
# update any install it signs. Replacing it after the first install forces every
# install through an uninstall, and this app's local state cannot survive one
# (ADR-076 D4).
#
# Nothing here writes a password to a command line, to the terminal, or to the
# repository.

set -euo pipefail
# Defence in depth: a shell trace would print the passphrase.
set +x

source "$(dirname "${BASH_SOURCE[0]}")/release_env.sh"

readonly default_material_root="${CP_PRODUCTION_MATERIAL_ROOT:-$HOME/.communication-platform/production-signing}"
keystore_path="${CP_PRODUCTION_KEYSTORE_FILE:-$default_material_root/communication-platform-production.p12}"
properties_path="${CP_PRODUCTION_SIGNING_PROPERTIES:-$default_material_root/production-signing.properties}"
identity_file="$production_identity_file"
# ADR-076 D2 fixes the alias, so no option changes it.
readonly key_alias="communication-platform-production"

usage() {
  cat <<'USAGE'
Usage: tool/create_production_keystore.sh [options]

Creates the production signing identity that ADR-076 decides, once, and records
its public certificate fingerprint in the identity file.

  --keystore PATH        Where to write the keystore. Default:
                         ~/.communication-platform/production-signing/communication-platform-production.p12
  --properties PATH      Where to write the untracked signing properties file.
                         Default:
                         ~/.communication-platform/production-signing/production-signing.properties
  --identity-file PATH   The identity file that records the fingerprint. Default:
                         android/production-release-identity.properties. Point
                         it at a scratch copy to prove this script.
  -h, --help             Show this message.

Both material paths must lie outside the repository and must not exist yet, and
the identity file must not record a fingerprint yet. The passphrase is read
twice from standard input, without echo.
USAGE
}

# chmod protects the material on Linux and macOS. Git Bash mounts NTFS with
# noacl, so on Windows it sets nothing and the profile's access list is the only
# protection (ADR-076 D3).
make_private_directory() {
  if [[ ! -d "$1" ]]; then
    mkdir -p "$1"
    chmod 700 "$1" 2>/dev/null || true
  fi
}

# Gradle reads the properties file with java.util.Properties.load(), which
# decodes ISO 8859-1, takes a backslash as an escape and skips the spaces that
# open a value. Accept only a passphrase that file hands back unchanged.
passphrase_fits_properties() {
  local LC_ALL=C
  [[ "$1" != *[!\ -~]* && "$1" != *\\* && "$1" != " "* && "$1" != *" " ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keystore) keystore_path="$2"; shift 2 ;;
    --properties) properties_path="$2"; shift 2 ;;
    --identity-file) identity_file="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

# --- Refuse before anything is asked for or created ---------------------------

keystore_path="$(absolute_path "$keystore_path")"
properties_path="$(absolute_path "$properties_path")"
refuse_repository_path "The keystore path" "$keystore_path"
refuse_repository_path "The properties path" "$properties_path"

if [[ -e "$keystore_path" ]]; then
  fail "$keystore_path already exists. Never overwrite a production keystore: doing
       so destroys the only key that can update existing installs. If a new
       identity seems genuinely required, read ADR-076 D4 first."
fi

if [[ -e "$properties_path" ]]; then
  fail "$properties_path already exists. It configures signing with an existing
       key, so this script never overwrites it."
fi

identity_application_id="$(read_identity_property "$identity_file" 'application\.id')"
[[ "$identity_application_id" == "$production_application_id" ]] ||
  fail "$identity_file names the application ID '$identity_application_id', but
       android/production-release-identity.properties names
       '$production_application_id'. Give --identity-file only a copy of that file."

identity_certificate_sha256="$(read_identity_property "$identity_file" 'signing\.certificate\.sha256')"
identity_certificate_sha256="$(normalize_fingerprint "$identity_certificate_sha256")"

if [[ -n "$identity_certificate_sha256" ]]; then
  fail "A production signing identity is already recorded in $identity_file:
         $identity_certificate_sha256
       Creating a second key would orphan every install the first one signed.
       Restore the existing keystore from a backup instead."
fi

grep -q '^[[:space:]]*signing\.certificate\.sha256[[:space:]]*=' "$identity_file" ||
  fail "$identity_file has no signing.certificate.sha256 line to record the key in."
[[ -w "$identity_file" ]] || fail "$identity_file is not writable."

require_jdk

# --- Passphrase --------------------------------------------------------------

echo "Creating the persistent production signing identity (ADR-076)."
echo "Application ID (frozen at the first install): $identity_application_id"
echo
echo "Choose a passphrase of at least 16 printable ASCII characters, with no"
echo "backslash and no space at either end, and store it in your password manager"
echo "before continuing. If the passphrase is lost the key is lost."
echo

IFS= read -r -s -p "Passphrase: " passphrase || fail "No passphrase was entered."
echo
IFS= read -r -s -p "Confirm passphrase: " passphrase_confirmation ||
  fail "No confirmation was entered."
echo

[[ "$passphrase" == "$passphrase_confirmation" ]] || fail "Passphrases do not match."
unset passphrase_confirmation
[[ "${#passphrase}" -ge 16 ]] || fail "Passphrase must be at least 16 characters."
passphrase_fits_properties "$passphrase" ||
  fail "Passphrase must be printable ASCII with no backslash and no space at either
       end: the signing properties file cannot carry anything else unchanged."

# keytool reads the passphrase from the environment, so it never appears in the
# process list where any local user could read it.
export CP_KEYSTORE_PASSPHRASE="$passphrase"
unset passphrase

# --- Generate ----------------------------------------------------------------

make_private_directory "$(dirname "$keystore_path")"

# 10000 days is a little over 27 years, past Android's advice that a signing key
# stay valid for at least 25. PKCS12 is the current standard keystore format;
# the proprietary JKS format is deprecated.
keytool -genkeypair \
  -alias "$key_alias" \
  -keyalg RSA \
  -keysize 4096 \
  -sigalg SHA384withRSA \
  -validity 10000 \
  -storetype PKCS12 \
  -keystore "$(to_native_path "$keystore_path")" \
  -dname "CN=$identity_application_id, OU=Production, O=Communication Platform" \
  -storepass:env CP_KEYSTORE_PASSPHRASE \
  -keypass:env CP_KEYSTORE_PASSPHRASE

chmod 600 "$keystore_path" 2>/dev/null || true

# --- Record the public identity ----------------------------------------------

# The listing holds the certificate only: no private key and no passphrase.
# English labels keep it readable whatever the JVM's locale.
certificate_listing="$(keytool -J-Duser.language=en -list -v \
  -alias "$key_alias" \
  -keystore "$(to_native_path "$keystore_path")" \
  -storepass:env CP_KEYSTORE_PASSPHRASE | tr -d '\r')"

certificate_detail() {
  printf '%s\n' "$certificate_listing" | sed -n "s/^$1:[[:space:]]*//p" | head -n 1
}

fingerprint="$(normalize_fingerprint "$(printf '%s\n' "$certificate_listing" |
  sed -n 's/^[[:space:]]*SHA256:[[:space:]]*\(.*\)$/\1/p' | head -n 1)")"

readonly keystore_kept="The keystore at $keystore_path exists now: keep it, and do not run
       this script again."

[[ "$fingerprint" =~ ^[[:xdigit:]]{64}$ ]] ||
  fail "Could not read the certificate SHA-256 digest. $keystore_kept"

# The fingerprint is public. Recording it in source control is what lets every
# later build prove it used the same identity. Only the value changes; Git
# Bash's sed writes LF endings, which git normalizes, so a diff shows one line.
tmp_identity="$(mktemp)"
sed "s/^\([[:space:]]*signing\.certificate\.sha256[[:space:]]*=\)[^[:space:]]*/\1$fingerprint/" \
  "$identity_file" > "$tmp_identity"
mv "$tmp_identity" "$identity_file"

recorded_fingerprint="$(read_identity_property "$identity_file" 'signing\.certificate\.sha256')"
[[ "$(normalize_fingerprint "$recorded_fingerprint")" == "$fingerprint" ]] ||
  fail "The fingerprint did not reach $identity_file. Record it by hand:
         signing.certificate.sha256=$fingerprint
       $keystore_kept"

# --- Untracked signing properties --------------------------------------------

make_private_directory "$(dirname "$properties_path")"
umask 077
cat > "$properties_path" <<PROPERTIES
# Production signing material. NEVER commit this file, and never copy it into a
# repository. Signed builds read it through CP_PRODUCTION_SIGNING_PROPERTIES
# (ADR-076 D5).
storeFile=$(to_properties_path "$keystore_path")
storePassword=$CP_KEYSTORE_PASSPHRASE
keyAlias=$key_alias
keyPassword=$CP_KEYSTORE_PASSPHRASE
PROPERTIES
chmod 600 "$properties_path" 2>/dev/null || true
unset CP_KEYSTORE_PASSPHRASE

if [[ "$identity_file" -ef "$production_identity_file" ]]; then
  commit_step="3. Commit the signing.certificate.sha256 line of
     android/production-release-identity.properties. It is public, and every
     later release is verified against it."
else
  commit_step="3. Nothing to commit: $identity_file is not the tracked identity file."
fi

cat <<SUMMARY

Production signing identity created.

  Keystore     $keystore_path
  Alias        $key_alias
  Properties   $properties_path
  Certificate  $fingerprint

  Subject      $(certificate_detail 'Owner')
  Key          $(certificate_detail 'Subject Public Key Algorithm')
  Signature    $(certificate_detail 'Signature algorithm name')
  Valid from   $(certificate_detail 'Valid from')

The fingerprint was written to $identity_file.

Signed builds find the material through:

  export CP_PRODUCTION_SIGNING_PROPERTIES="$(to_properties_path "$properties_path")"

Do these now, before anything is installed anywhere:

  1. Store the keystore passphrase in your password manager, together with the
     certificate SHA-256 above. If the passphrase is lost, the key is lost.
  2. Make two encrypted backups, each on its own drive, and test-decrypt both.
     One of the drives belongs in another building (ADR-076 D3):
       tool/backup_production_keystore.sh --out <folder on the drive>
  $commit_step

SUMMARY
