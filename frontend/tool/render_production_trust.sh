#!/usr/bin/env bash
# Render the production flavor's Android trust resources from the provisioning
# values (ADR-076 D7).
#
# Android reads these resources for the platform's Java HTTP stacks and WebView.
# This app's REST and WebSocket traffic runs on dart:io, which does not consult
# them and trusts the CA compiled into Dart instead (ADR-043), so they are
# rendered as defence in depth. What the SPKI pins protect is the open question
# ADR-076 D7 records, and nothing here depends on either answer to it.
#
# The rendered files are provisioning artifacts, not source: Git ignores them,
# as android/provisioning/README.md requires. tool/build_production_release.sh
# runs this on every build, so the packaged trust config cannot drift from the
# values compiled into Dart.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/release_env.sh"

readonly template="$android_root/provisioning/network_security_config.xml.template"
readonly production_res="$android_root/app/src/production/res"
readonly rendered_config="$production_res/xml/network_security_config.xml"
readonly rendered_ca="$production_res/raw/provisioned_private_ca.pem"

usage() {
  cat <<'USAGE'
Usage: tool/render_production_trust.sh

Required environment (public values, never committed):
  PRODUCTION_SERVER_ORIGIN        https origin whose host is pinned
  PRODUCTION_PRIVATE_CA_SHA256    SHA-256 of the CA certificate in DER, 64 hex chars
  PRODUCTION_PRIMARY_SPKI_SHA256  base64 SHA-256 SPKI pin
  PRODUCTION_BACKUP_SPKI_SHA256   base64 SHA-256 SPKI pin, different from the primary
  PRODUCTION_PRIVATE_CA_PEM       path to the private CA certificate in PEM form
USAGE
}

case "${1:-}" in
  "") ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; fail "Unknown argument: $1" ;;
esac

# Every value present, each in the form the app accepts, and two different pins.
require_production_provisioning

[[ -f "$template" ]] || fail "Missing trust template: $template"

# --- The CA must be the one the provisioning values describe --------------------

# The file is packaged whole, so it may hold one certificate and nothing else: a
# private key kept beside the certificate would ship inside every artifact.
pem_blocks="$(grep -c '^-----BEGIN ' "$PRODUCTION_PRIVATE_CA_PEM" || true)"
certificate_blocks="$(grep -c '^-----BEGIN CERTIFICATE-----' "$PRODUCTION_PRIVATE_CA_PEM" || true)"
[[ "$pem_blocks" == "1" && "$certificate_blocks" == "1" ]] ||
  fail "$PRODUCTION_PRIVATE_CA_PEM must hold exactly one PEM certificate and nothing
       else, because it is copied whole into every artifact."

# Native openssl on Windows cannot open a /c/... path.
readonly ca_certificate="$(to_native_path "$PRODUCTION_PRIVATE_CA_PEM")"

actual_ca_sha256="$(openssl x509 -in "$ca_certificate" -outform DER |
  openssl dgst -sha256 | sed 's/^.*= *//' | tr -d '\r\n' | tr '[:upper:]' '[:lower:]')" ||
  fail "openssl could not read $PRODUCTION_PRIVATE_CA_PEM as a certificate."
expected_ca_sha256="$(printf '%s' "$PRODUCTION_PRIVATE_CA_SHA256" | tr '[:upper:]' '[:lower:]')"

[[ "$actual_ca_sha256" == "$expected_ca_sha256" ]] ||
  fail "The CA certificate does not match PRODUCTION_PRIVATE_CA_SHA256.
         expected $expected_ca_sha256
         actual   $actual_ca_sha256
       Pinning the wrong root would either break every connection or trust the
       wrong issuer. Resolve which CA is actually deployed before building."

openssl x509 -in "$ca_certificate" -noout -checkend 0 >/dev/null 2>&1 ||
  fail "The CA certificate has expired."

# --- Render ------------------------------------------------------------------

mkdir -p "$production_res/xml" "$production_res/raw"

# `sed` would need every value escaped; awk substitutes literal strings. The host
# and both pins passed require_production_provisioning, so neither holds a
# character that awk's sub() reads specially.
awk -v host="$production_server_host" \
  -v primary="$PRODUCTION_PRIMARY_SPKI_SHA256" \
  -v backup="$PRODUCTION_BACKUP_SPKI_SHA256" '
  {
    sub(/@@SERVER_HOST@@/, host)
    sub(/@@PRIMARY_SPKI_SHA256@@/, primary)
    sub(/@@BACKUP_SPKI_SHA256@@/, backup)
    print
  }
' "$template" > "$rendered_config"

if grep -q '@@' "$rendered_config"; then
  fail "The rendered trust config still contains an unsubstituted placeholder."
fi

cp "$PRODUCTION_PRIVATE_CA_PEM" "$rendered_ca"

echo "Rendered production trust resources:"
echo "  $rendered_config"
echo "    host          $production_server_host"
echo "    primary pin   $PRODUCTION_PRIMARY_SPKI_SHA256"
echo "    backup pin    $PRODUCTION_BACKUP_SPKI_SHA256"
echo "  $rendered_ca"
echo "    CA SHA-256    $actual_ca_sha256"
