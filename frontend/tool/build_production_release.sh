#!/usr/bin/env bash
# Build, sign, provision and verify one production artifact for a phone
# (ADR-076 D7).
#
# This is the only supported way to make one. It refuses to build without the
# recorded signing certificate, complete provisioning, signing material and a
# build number that rises; it refuses an unsigned request; it stops when the
# live host does not serve the provisioned primary pin; and it publishes nothing
# that tool/verify_release_apk.sh --production has not passed.
#
# Only the presence of signing material is checked here. Nothing in this script
# reads, prints or copies a properties file, a keystore or a password.

set -euo pipefail
# Defence in depth: a shell trace would print every value it expands.
set +x

source "$(dirname "${BASH_SOURCE[0]}")/release_env.sh"

readonly release_directory="$frontend_root/build/production-release"
readonly built_apk="$frontend_root/build/app/outputs/flutter-apk/app-production-release.apk"
# A host that accepts the connection and never answers must not hang the build.
readonly live_check_timeout_seconds=30

build_number=""
build_name=""

usage() {
  cat <<'USAGE'
Usage: tool/build_production_release.sh --build-number N [--build-name X]

  --build-number N   Android versionCode: a positive integer of at most nine
                     digits, greater than every Version code recorded in
                     build/production-release/*.metadata.txt.
  --build-name X     Human version name (default: the pubspec version).

Required environment, derived afresh for every build. These are public values,
never committed; docs/release-signing.md shows how to derive them:
  PRODUCTION_SERVER_ORIGIN         https origin, no path, query or fragment
  PRODUCTION_PRIVATE_CA_SHA256     SHA-256 of the CA certificate in DER, 64 hex chars
  PRODUCTION_PRIMARY_SPKI_SHA256   base64 SHA-256 pin the live host must serve
  PRODUCTION_BACKUP_SPKI_SHA256    base64 SHA-256 pin, different from the primary
  PRODUCTION_PRIVATE_CA_PEM        path to the private CA certificate, PEM form

Required signing material, outside the repository (ADR-076 D5), one of:
  CP_PRODUCTION_SIGNING_PROPERTIES, the absolute path of the untracked
  properties file; or all four of CP_PRODUCTION_KEYSTORE_FILE,
  CP_PRODUCTION_KEYSTORE_PASSWORD, CP_PRODUCTION_KEY_ALIAS and
  CP_PRODUCTION_KEY_PASSWORD.

CP_PRODUCTION_UNSIGNED_BUILD must not be set.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number)
      [[ $# -ge 2 ]] || { usage >&2; fail "--build-number needs a value."; }
      build_number="$2"
      shift 2
      ;;
    --build-name)
      [[ $# -ge 2 ]] || { usage >&2; fail "--build-name needs a value."; }
      build_name="$2"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$build_number" ]] || { usage >&2; fail "--build-number is required."; }
# No leading zero, because the shell reads 010 as octal when it compares.
[[ "$build_number" =~ ^[1-9][0-9]{0,8}$ ]] ||
  fail "--build-number must be a positive integer of at most nine digits, but is '$build_number'."

# --- Preconditions -----------------------------------------------------------

# Every refusal comes before any build time is spent.

[[ -n "$production_certificate_sha256" ]] ||
  fail "No signing certificate is recorded in
       android/production-release-identity.properties, so no artifact this script
       built could be verified. The fingerprint is written once, when the
       production key is created. If the line was emptied, restore it from the
       history of that file; never create another key to fill it (ADR-076 D4)."

require_production_provisioning

if [[ -n "${CP_PRODUCTION_SIGNING_PROPERTIES:-}" ]]; then
  [[ -f "$CP_PRODUCTION_SIGNING_PROPERTIES" ]] ||
    fail "CP_PRODUCTION_SIGNING_PROPERTIES names $CP_PRODUCTION_SIGNING_PROPERTIES,
       which is not a file. If it is lost, RESTORE.txt inside each encrypted backup
       of the production keystore says how to write it again."
  refuse_repository_path "The signing properties file" "$CP_PRODUCTION_SIGNING_PROPERTIES"
elif [[ -n "${CP_PRODUCTION_KEYSTORE_FILE:-}" ]]; then
  refuse_repository_path "The production keystore" "$CP_PRODUCTION_KEYSTORE_FILE"
else
  fail "No production signing material. Set CP_PRODUCTION_SIGNING_PROPERTIES to the
       absolute path of the untracked properties file, or set all four
       CP_PRODUCTION_KEYSTORE_* and CP_PRODUCTION_KEY_* variables. If the key
       cannot be found, restore it from one of its encrypted backups: only the
       original key can update an install it signed (ADR-076 D4)."
fi

[[ -z "${CP_PRODUCTION_UNSIGNED_BUILD+set}" ]] ||
  fail "CP_PRODUCTION_UNSIGNED_BUILD is set. It asks for an unsigned package, which no
       phone can install, so this script never builds with it. Unset it."

# A build number only rises (ADR-076 D9). This directory belongs to one checkout
# and `flutter clean` deletes it, so the refusal is a convenience: the last
# installed number is also recorded in docs/release-signing.md, and Android
# refuses a downgrade by itself.
highest_recorded=0
for metadata in "$release_directory"/*.metadata.txt; do
  [[ -f "$metadata" ]] || continue
  recorded="$(awk '/^Version code:/ { sub(/^Version code:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit }' "$metadata")"
  [[ "$recorded" =~ ^[1-9][0-9]{0,8}$ ]] ||
    fail "$metadata records no readable Version code, so whether build $build_number
       rises above it cannot be told."
  if (( recorded > highest_recorded )); then
    highest_recorded="$recorded"
  fi
done
(( build_number > highest_recorded )) ||
  fail "Build number $build_number is not greater than $highest_recorded, the highest
       Version code recorded in $release_directory. Choose a higher number; a
       number is never reused."

for existing in "$release_directory"/*-"$build_number".apk*; do
  if [[ -e "$existing" ]]; then
    fail "$existing already exists. A published artifact is never overwritten."
  fi
done

# apksigner runs only after the build, so a missing JDK has to fail before it.
require_jdk

# --- The primary pin the live host serves ------------------------------------

# backend/ops/tls/make_ca.sh mints a new server key on every run, so the primary
# pin can move with nothing in this repository noticing (ADR-067 D4). Compare the
# provisioned pin with the one the deployment actually serves before building.
# What a stale pin does to the app's own connection is the open question ADR-076
# D7 records; this check keeps the rendered trust config true either way.

if command -v timeout >/dev/null 2>&1; then
  with_timeout() { timeout "$live_check_timeout_seconds" "$@"; }
else
  with_timeout() { "$@"; }
fi

readonly live_endpoint="$production_server_host:$production_server_port"
echo "Reading the primary pin that $live_endpoint serves."

live_certificate="$(echo | with_timeout openssl s_client -connect "$live_endpoint" \
  -servername "$production_server_host" 2>/dev/null | openssl x509 2>/dev/null)" || true
[[ "$live_certificate" == *"-----BEGIN CERTIFICATE-----"* ]] ||
  fail "Could not read a certificate from $live_endpoint. The live primary pin cannot
       be checked, so nothing is built. Check the network path to the host and run
       this again; never build around this check."

live_primary_pin="$(printf '%s\n' "$live_certificate" |
  openssl x509 -pubkey -noout 2>/dev/null |
  openssl pkey -pubin -outform der 2>/dev/null |
  openssl dgst -sha256 -binary | base64 | tr -d '\r\n')" ||
  fail "Could not derive the SPKI pin of the certificate $live_endpoint serves."
[[ "$live_primary_pin" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
  fail "Could not derive the SPKI pin of the certificate $live_endpoint serves."

[[ "$live_primary_pin" == "$PRODUCTION_PRIMARY_SPKI_SHA256" ]] ||
  fail "PRIMARY PIN MISMATCH. $live_endpoint serves a key whose pin is
         $live_primary_pin
       but PRODUCTION_PRIMARY_SPKI_SHA256 is
         $PRODUCTION_PRIMARY_SPKI_SHA256
       Either the values were not derived afresh from backend/ops/tls/out/, or the
       host serves a different key from out/server.crt, which is what a later run
       of backend/ops/tls/make_ca.sh leaves behind. Find out which key the host
       serves before building; never copy the live pin in without knowing why it
       moved."
echo "  ok    $live_endpoint serves the provisioned primary pin"

# --- Build -------------------------------------------------------------------

cd "$frontend_root"

readonly source_revision="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
source_status="$(git status --porcelain 2>/dev/null)" || source_status="unknown"
if [[ -n "$source_status" ]]; then
  readonly working_tree_dirty="yes"
  echo "warning: the working tree has uncommitted changes, so this artifact is" >&2
  echo "         not reproducible from $source_revision alone." >&2
else
  readonly working_tree_dirty="no"
fi

# Render the Android trust resources from the same values compiled into Dart, on
# every build, so the packaged trust config cannot drift from them.
echo
"$frontend_root/tool/render_production_trust.sh"
echo

# The authority itself, which dart:io verifies against (ADR-043). Without it the
# app fails closed at configuration.
readonly private_ca_base64="$(base64 < "$PRODUCTION_PRIVATE_CA_PEM" | tr -d '\r\n')"
[[ -n "$private_ca_base64" ]] || fail "Could not encode $PRODUCTION_PRIVATE_CA_PEM."

build_arguments=(
  build apk
  --release
  --flavor production
  --target lib/main_production.dart
  --build-number "$build_number"
  "--dart-define=PRODUCTION_SERVER_ORIGIN=$PRODUCTION_SERVER_ORIGIN"
  "--dart-define=PRODUCTION_PRIVATE_CA_SHA256=$PRODUCTION_PRIVATE_CA_SHA256"
  "--dart-define=PRODUCTION_PRIMARY_SPKI_SHA256=$PRODUCTION_PRIMARY_SPKI_SHA256"
  "--dart-define=PRODUCTION_BACKUP_SPKI_SHA256=$PRODUCTION_BACKUP_SPKI_SHA256"
  "--dart-define=PRODUCTION_PRIVATE_CA_PEM_BASE64=$private_ca_base64"
)
if [[ -n "$build_name" ]]; then
  build_arguments+=(--build-name "$build_name")
fi

echo "Building the production release, build number $build_number."
flutter "${build_arguments[@]}"

[[ -f "$built_apk" ]] || fail "Expected artifact not produced: $built_apk"

# --- Verify before publishing anything ---------------------------------------

# apksigner's launcher reads JAVA_HOME literally and rejects a /c/... path, and
# jdk_home is in C:/... form on Windows.
export JAVA_HOME="$jdk_home"
echo
"$frontend_root/tool/verify_release_apk.sh" --production "$built_apk"

# --- Publish the verified artifact -------------------------------------------

badging="$(aapt2 dump badging "$(to_native_path "$built_apk")")"
resolved_version_name="$(printf '%s\n' "$badging" |
  sed -n "s/^package: .*versionName='\([^']*\)'.*/\1/p" | head -n 1)"
resolved_version_code="$(printf '%s\n' "$badging" |
  sed -n "s/^package: .*versionCode='\([^']*\)'.*/\1/p" | head -n 1)"
[[ -n "$resolved_version_name" ]] || fail "The artifact reports no versionName."
[[ "$resolved_version_code" == "$build_number" ]] ||
  fail "The artifact's versionCode is '$resolved_version_code', not $build_number."

readonly artifact_name="communication-platform-$resolved_version_name-$build_number.apk"
readonly artifact_path="$release_directory/$artifact_name"

mkdir -p "$release_directory"
cp "$built_apk" "$artifact_path"
(cd "$release_directory" && sha256sum "$artifact_name" > "$artifact_name.sha256")

cat > "$artifact_path.metadata.txt" <<METADATA
Communication Platform - production release (ADR-076)
Artifact:                     $artifact_name
Built (UTC):                  $(date -u +%Y-%m-%dT%H:%M:%SZ)
Source revision:              $source_revision
Working tree dirty:           $working_tree_dirty
Application ID:               $production_application_id
Version name:                 $resolved_version_name
Version code:                 $build_number
Signing certificate SHA-256:  $production_certificate_sha256
APK SHA-256:                  $(cut -d' ' -f1 < "$artifact_path.sha256")
Server origin:                $PRODUCTION_SERVER_ORIGIN

Verified by tool/verify_release_apk.sh --production before publication.
Recipients should check the APK SHA-256 above, and may confirm the signing
certificate themselves with:
  apksigner verify --print-certs $artifact_name
METADATA

cat <<SUMMARY

Production release artifact ready.

  $artifact_path
  $artifact_path.sha256
  $artifact_path.metadata.txt

Before anyone installs it, hand over the written disclosure and
docs/third-party-notices.md (docs/deployment-and-release.md, steps 8 to 10).

Put it on a device with adb install only: never with -d, and never uninstall
anything to make an install succeed. Never point flutter install, flutter run or
flutter drive at a device that holds the signed app (ADR-076 D9). Record the
number of every installed build in docs/release-signing.md.
SUMMARY
