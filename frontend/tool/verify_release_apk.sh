#!/usr/bin/env bash
# Verify a built Production release artifact.
#
# Production must keep building and stay verifiable without ever becoming
# installable. This answers the questions that decide that, all of which must
# hold:
#
#   * is this the application it claims to be (application ID)?
#   * is it unsigned, so that the OS refuses to install it?
#   * does it declare only the permissions and components ADR-054 recorded?
#   * does its packaged native core still lack the deleted beta MLS symbol?
#
# Every check fails closed. A check that cannot be performed is an error, never
# a pass.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/release_env.sh"

production=0
apk_path=""

usage() {
  cat <<'USAGE'
Usage: tool/verify_release_apk.sh --production <apk>

  --production   Verify a Production artifact: correct application ID, NOT
                 signed (so it cannot be installed), and no beta MLS symbol
                 in the packaged native core.

The check also compares what the merged manifest declares - permissions and
components, including everything a dependency contributed - against the set
ADR-054 recorded.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --production) production=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; fail "Unknown option: $1" ;;
    *) apk_path="$1"; shift ;;
  esac
done

[[ "$production" -eq 1 ]] || { usage >&2; fail "Pass --production."; }
[[ -n "$apk_path" ]] || { usage >&2; fail "No APK given."; }
[[ -f "$apk_path" ]] || fail "APK not found: $apk_path"

readonly native_apk_path="$(to_native_path "$apk_path")"
checks_passed=0

pass() {
  checks_passed=$((checks_passed + 1))
  echo "  ok    $*"
}

echo "Verifying $(basename "$apk_path") as production"
echo

# --- Application identity ----------------------------------------------------

# The Gradle build that produces the artifact is the one place the application
# ID is written, so the built identity and the verified identity cannot drift
# apart.
readonly app_build_file="$android_root/app/build.gradle.kts"
expected_application_id="$(sed -n \
  's/^[[:space:]]*val productionApplicationId = "\([^"]*\)".*$/\1/p' \
  "$app_build_file" | head -n 1)"
[[ -n "$expected_application_id" ]] ||
  fail "No productionApplicationId is declared in $app_build_file."

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

# Production must stay undistributable. An unsigned APK is refused by the
# package installer, which is exactly the fail-closed property we want.
# apksigner also exits non-zero when it cannot run at all - a JAVA_HOME it
# cannot use is enough - so only its own verdict counts as unsigned.
if signature_report="$(apksigner verify --verbose --print-certs "$native_apk_path" 2>&1)"; then
  fail "The Production artifact is signed. Production must remain unsigned so it
       cannot be installed or distributed. Check that buildTypes.release does
       not set a signingConfig and that no signing config reached the
       production flavor."
fi
printf '%s\n' "$signature_report" | grep -q 'DOES NOT VERIFY' ||
  fail "apksigner did not reach a verdict, so whether this artifact is signed is
       unknown:
$signature_report"
pass "unsigned, so the OS cannot install it"

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
  fail "The Production artifact's packaged native core exports $beta_symbol.
       No source in this tree defines that symbol, so this native core was not
       built from it. Do not ship or accept this build."
fi
pass "packaged native core does not export $beta_symbol"

echo
echo "$checks_passed checks passed."
