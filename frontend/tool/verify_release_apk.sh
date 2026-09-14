#!/usr/bin/env bash
# Verify a built production release artifact (ADR-076 D6).
#
# Two modes answer two different questions, and every answer must hold:
#
#   --production            the gate for a distributable artifact. Is this the
#                           application it claims to be, and is it signed by the
#                           one identity recorded in
#                           android/production-release-identity.properties?
#   --production-unsigned   the artifact CI builds. Is it the same application,
#                           and unsigned, so that the OS refuses to install it?
#
# Both modes also ask whether the artifact declares only the permissions and
# components ADR-054 recorded, and whether its packaged native core still lacks
# the deleted beta MLS symbol.
#
# Every check fails closed. A check that cannot be performed is an error, never
# a pass.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/release_env.sh"

mode=""
apk_path=""

usage() {
  cat <<'USAGE'
Usage: tool/verify_release_apk.sh (--production | --production-unsigned) <apk>

  --production            Verify a distributable production artifact: the
                          application ID recorded in
                          android/production-release-identity.properties,
                          exactly one signer, APK Signature Scheme v2 and v3
                          without v1, no debug certificate, and the signing
                          certificate recorded in the same file.
  --production-unsigned   Verify the unsigned production artifact CI builds:
                          the recorded application ID, and NOT signed, so it
                          cannot be installed.

Both modes also compare what the merged manifest declares - permissions and
components, including everything a dependency contributed - against the set
ADR-054 recorded, and check that the packaged native core does not export the
deleted beta MLS symbol.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --production | --production-unsigned)
      [[ -z "$mode" ]] || { usage >&2; fail "Choose exactly one mode."; }
      mode="${1#--}"
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; fail "Unknown option: $1" ;;
    *)
      [[ -z "$apk_path" ]] || { usage >&2; fail "Give exactly one APK."; }
      apk_path="$1"
      shift
      ;;
  esac
done

[[ -n "$mode" ]] || { usage >&2; fail "Pass --production or --production-unsigned."; }
[[ -n "$apk_path" ]] || { usage >&2; fail "No APK given."; }
[[ -f "$apk_path" ]] || fail "APK not found: $apk_path"

readonly native_apk_path="$(to_native_path "$apk_path")"
checks_passed=0

pass() {
  checks_passed=$((checks_passed + 1))
  echo "  ok    $*"
}

echo "Verifying $(basename "$apk_path") as $mode"
echo

# --- Application identity ----------------------------------------------------

# The Gradle build reads the application ID from the same committed identity
# file that release_env.sh reads it from, so the built identity and the verified
# identity cannot drift apart.
readonly expected_application_id="$production_application_id"

badging="$(aapt2 dump badging "$native_apk_path")"
actual_application_id="$(printf '%s' "$badging" |
  sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n 1)"
version_code="$(printf '%s' "$badging" |
  sed -n "s/.*versionCode='\([^']*\)'.*/\1/p" | head -n 1)"
version_name="$(printf '%s' "$badging" |
  sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -n 1)"

[[ "$actual_application_id" == "$expected_application_id" ]] ||
  fail "Application ID is '$actual_application_id' but must be '$expected_application_id'.
       An artifact with the wrong application ID is a different application to
       Android and cannot update an existing install."
pass "application ID $actual_application_id"
pass "version $version_name ($version_code)"

# --- Signature ---------------------------------------------------------------

# apksigner exits non-zero both when an artifact does not verify and when it
# cannot run at all - a JAVA_HOME it cannot use is enough - so its exit status
# alone never decides either mode.
signature_verified=0
if signature_report="$(apksigner verify --verbose --print-certs "$native_apk_path" 2>&1)"; then
  signature_verified=1
fi

report_value() {
  printf '%s\n' "$signature_report" | sed -n "s/^$1: \(.*\)$/\1/p" | head -n 1 | tr -d '\r'
}

scheme_state() {
  printf '%s\n' "$signature_report" |
    sed -n "s/^Verified using $1 scheme ([^)]*): \(.*\)$/\1/p" | head -n 1 | tr -d '\r'
}

if [[ "$mode" == "production-unsigned" ]]; then
  # CI builds production without the key. The package installer refuses an
  # unsigned APK, so this artifact cannot reach anyone by accident. Flutter
  # copies it to app-production-release.apk signed or not, so only apksigner's
  # own verdict counts as unsigned.
  [[ "$signature_verified" -eq 0 ]] ||
    fail "The artifact is signed, but --production-unsigned verifies the unsigned
       artifact CI builds. Build it with CP_PRODUCTION_UNSIGNED_BUILD=1 and no
       signing variable, or verify a signed artifact with --production."
  printf '%s\n' "$signature_report" | grep -q 'DOES NOT VERIFY' ||
    fail "apksigner did not reach a verdict, so whether this artifact is signed is
       unknown:
$signature_report"
  pass "unsigned, so the OS cannot install it"
else
  [[ "$signature_verified" -eq 1 ]] ||
    fail "apksigner could not verify the artifact, so it is not a distributable
       production artifact:
$signature_report"
  pass "apksigner verifies the signature"

  signer_count="$(report_value 'Number of signers')"
  [[ "$signer_count" == "1" ]] ||
    fail "Expected exactly one signer, found '$signer_count'."
  pass "exactly one signer"

  v1_state="$(scheme_state v1)"
  v2_state="$(scheme_state v2)"
  v3_state="$(scheme_state v3)"
  for state in "$v1_state" "$v2_state" "$v3_state"; do
    [[ "$state" == "true" || "$state" == "false" ]] ||
      fail "apksigner did not report a verdict for each of v1, v2 and v3, so which
       schemes sign this artifact is unknown:
$signature_report"
  done
  [[ "$v2_state" == "true" ]] || fail "APK Signature Scheme v2 is not present."
  [[ "$v3_state" == "true" ]] || fail "APK Signature Scheme v3 is not present."
  [[ "$v1_state" == "false" ]] ||
    fail "The legacy JAR (v1) signature is present. minSdk 24 makes it unnecessary,
       and ADR-076 D2 disables it."
  pass "signed with v2 and v3, without the legacy v1 scheme"

  signer_dn="$(report_value 'Signer #1 certificate DN')"
  [[ -n "$signer_dn" ]] ||
    fail "apksigner reported no certificate DN for the signer:
$signature_report"
  case "$signer_dn" in
    *"Android Debug"*)
      fail "This artifact is DEBUG SIGNED ($signer_dn). A debug-signed build must
           never reach anyone: the debug key differs per machine, so no release
           could ever update it."
      ;;
  esac
  pass "not debug signed"

  actual_fingerprint="$(normalize_fingerprint "$(report_value 'Signer #1 certificate SHA-256 digest')")"
  [[ "$actual_fingerprint" =~ ^[[:xdigit:]]{64}$ ]] ||
    fail "apksigner reported no certificate SHA-256 digest for the signer:
$signature_report"

  if [[ -z "$production_certificate_sha256" ]]; then
    fail "No certificate is recorded in android/production-release-identity.properties,
       so this artifact's signer cannot be checked against anything. It signs as:
         $actual_fingerprint
       The fingerprint is written once, when the production key is created, and
       never changes. If the line was emptied, restore it from the history of that
       file. Never copy an artifact's fingerprint into it to make this check pass:
       the file decides which key is trusted, not the artifact."
  fi

  [[ "$actual_fingerprint" == "$production_certificate_sha256" ]] ||
    fail "SIGNING IDENTITY MISMATCH.
         expected $production_certificate_sha256
         actual   $actual_fingerprint
       This artifact is signed by a different key than the production identity
       recorded in android/production-release-identity.properties. Android refuses
       it over any install that key signed, and the only way to apply it is an
       uninstall that permanently destroys that install's local data. Do not
       distribute it. Find the real keystore, or restore it from a backup."
  pass "signed by the recorded production identity $actual_fingerprint"
fi

# --- What the artifact declares, including what came from outside ----------

# The source manifest is not the artifact's manifest. Every dependency merges
# its own elements in, and the only place the result can be read is the packaged
# file. ADR-054 enumerated what belongs there; this refuses anything else, so a
# permission, a component or an exported entry point that arrives with a future
# dependency upgrade fails the release rather than shipping unnoticed.

expected_permissions="$(printf '%s\n' \
  "android.permission.ACCESS_NETWORK_STATE" \
  "android.permission.FOREGROUND_SERVICE" \
  "android.permission.FOREGROUND_SERVICE_SPECIAL_USE" \
  "android.permission.INTERNET" \
  "android.permission.POST_NOTIFICATIONS" \
  "android.permission.RECEIVE_BOOT_COMPLETED" \
  "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" \
  "android.permission.VIBRATE" \
  "$actual_application_id.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION" |
  sort)"

actual_permissions="$(printf '%s' "$badging" |
  sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p" | sort)"

if [[ "$actual_permissions" != "$expected_permissions" ]]; then
  fail "The packaged artifact does not ask for the permissions ADR-054 recorded.
$(diff <(printf '%s\n' "$expected_permissions") <(printf '%s\n' "$actual_permissions") |
    sed 's/^</       expected only: /; s/^>/       present but unrecorded: /' | grep -E 'expected only|unrecorded')
       A permission that arrived from a dependency is still a permission this
       application asks its users for. Read where it came from, decide it, and
       record it in the manifest and in ADR-054 - or remove what brought it."
fi
pass "declares exactly the $(printf '%s\n' "$actual_permissions" | wc -l | tr -d ' ') recorded permissions"

manifest_tree="$(aapt2 dump xmltree "$native_apk_path" --file AndroidManifest.xml)"

# One line per declared component: "type|name|exported". Attributes always
# precede nested elements in an aapt2 tree, so the next element boundary is
# where the previous component is complete.
components="$(printf '%s' "$manifest_tree" | awk '
  function flush() {
    if (type != "") { printf "%s|%s|%s\n", type, name, exported }
    type = ""
  }
  /^[[:space:]]*E: / {
    flush()
    if ($0 ~ /E: (activity|activity-alias|service|receiver|provider) \(line=/) {
      match($0, /E: [a-z-]+/)
      type = substr($0, RSTART + 3, RLENGTH - 3)
      name = "(unnamed)"
      exported = "unset"
    }
    next
  }
  type != "" && /android:name\(0x01010003\)=/ {
    if (name == "(unnamed)") { match($0, /="[^"]*"/); name = substr($0, RSTART + 2, RLENGTH - 3) }
  }
  type != "" && /android:exported\(0x01010010\)=/ {
    match($0, /=(true|false)/); exported = substr($0, RSTART + 1, RLENGTH - 1)
  }
  END { flush() }
' | sort)"

expected_components="$(printf '%s\n' \
  "activity|com.example.communication_platform.MainActivity|true" \
  "provider|androidx.core.content.FileProvider|false" \
  "provider|androidx.startup.InitializationProvider|false" \
  "service|com.example.communication_platform.DeferredDeliveryJobService|false" \
  "service|com.example.communication_platform.SustainedDeliveryService|false" |
  sort)"

if [[ "$components" != "$expected_components" ]]; then
  fail "The packaged artifact does not declare the components ADR-054 recorded.
$(diff <(printf '%s\n' "$expected_components") <(printf '%s\n' "$components") |
    sed 's/^</       expected only: /; s/^>/       present but unrecorded: /' | grep -E 'expected only|unrecorded')
       An entry point this project did not declare is reachable in the
       artifact. androidx.profileinstaller's exported ProfileInstallReceiver is
       the one this happened with before, and it is refused in the manifest
       with tools:node=\"remove\"."
fi
pass "declares exactly the 5 recorded components"

exported_components="$(printf '%s\n' "$components" | awk -F'|' '$3 == "true" { print $2 }')"
[[ "$exported_components" == "com.example.communication_platform.MainActivity" ]] ||
  fail "Exported components are '$exported_components'. Exactly one component may
       be exported - the launcher activity - because everything else in this
       artifact is started by this application or by the platform binding to it."
pass "one exported component, the launcher activity"

# --- The deleted beta MLS core stays deleted ---------------------------------

# Nothing in this tree defines cp_crypto_v1_beta_mls_operation any more: the
# closed-beta MLS core, its Cargo feature and its Android flavor were deleted.
# The check stays as a guard against a return, because a native core that
# exports the symbol was not built from this tree.

[[ -n "$llvm_nm_tool" ]] ||
  fail "llvm-nm from Android NDK $RELEASE_NDK_VERSION is required to inspect the
       packaged native core. Set ANDROID_NDK_HOME."

readonly beta_symbol="cp_crypto_v1_beta_mls_operation"
readonly native_library="lib/arm64-v8a/libcommunication_crypto_core.so"

extracted="$(mktemp -d)"
trap 'rm -rf "$extracted"' EXIT INT TERM
unzip -p "$apk_path" "$native_library" > "$extracted/core.so" 2>/dev/null ||
  fail "$native_library is missing from the artifact."
[[ -s "$extracted/core.so" ]] || fail "$native_library is empty in the artifact."

exported_symbols="$("$llvm_nm_tool" -D --defined-only "$(to_native_path "$extracted/core.so")" |
  awk '{print $NF}')"

if printf '%s\n' "$exported_symbols" | grep -qx "$beta_symbol"; then
  fail "The production artifact's packaged native core exports $beta_symbol.
       No source in this tree defines that symbol, so this native core was not
       built from it. Do not ship or accept this build."
fi
pass "packaged native core does not export $beta_symbol"

echo
echo "$checks_passed checks passed."
