#!/usr/bin/env bash
# Shared release-tooling environment.
#
# Source this; do not execute it. It resolves the production release identity
# and the exact toolchain the release scripts need, and fails closed when
# anything required is missing. It never reads, prints, or stores a password.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "release_env.sh is a library; source it instead of running it." >&2
  exit 2
fi

set -euo pipefail

frontend_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly frontend_root
readonly android_root="$frontend_root/android"
readonly production_identity_file="$android_root/production-release-identity.properties"

# frontend/ sits at the top of the repository, so signing material has to stay
# outside the whole repository, not only outside frontend/.
repository_root="$(cd "$frontend_root/.." && pwd -P)"
readonly repository_root

# The pinned NDK that tool/build_rust_android.sh already requires. Reused here
# only for llvm-nm, which proves in the packaged artifact, rather than only in
# the build tree, that the deleted beta MLS core has not come back.
readonly RELEASE_NDK_VERSION="28.2.13676358"

host_kernel="$(uname -s)"
case "$host_kernel" in
  MINGW* | MSYS*)
    readonly release_host_windows=1
    readonly release_exe_suffix=".exe"
    readonly release_bat_suffix=".bat"
    readonly release_ndk_host_tag="windows-x86_64"
    # Native Windows tools cannot read POSIX paths.
    to_native_path() { cygpath -w "$1"; }
    # Java treats /c/... as relative, so a path written into a properties file
    # needs a drive letter. Forward slashes, not backslashes: Properties.load()
    # reads a backslash as an escape character.
    to_properties_path() { cygpath -m "$1"; }
    ;;
  Linux*)
    readonly release_host_windows=0
    readonly release_exe_suffix=""
    readonly release_bat_suffix=""
    readonly release_ndk_host_tag="linux-x86_64"
    to_native_path() { printf '%s\n' "$1"; }
    to_properties_path() { printf '%s\n' "$1"; }
    ;;
  Darwin*)
    readonly release_host_windows=0
    readonly release_exe_suffix=""
    readonly release_bat_suffix=""
    readonly release_ndk_host_tag="darwin-x86_64"
    to_native_path() { printf '%s\n' "$1"; }
    to_properties_path() { printf '%s\n' "$1"; }
    ;;
  *)
    echo "Unsupported release host: $host_kernel" >&2
    exit 2
    ;;
esac

fail() {
  echo "error: $*" >&2
  exit 1
}

# --- Production release identity ---------------------------------------------

# Prints the last value KEY takes in the properties file FILE. KEY is a sed
# pattern, so escape its dots.
read_identity_property() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || fail "Release identity file not found: $file"
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$file" |
    tail -n 1 |
    tr -d '\r' |
    sed 's/[[:space:]]*$//'
}

# apksigner prints lower-case hex without separators; keytool prints upper-case
# colon-separated. Compare only after normalising both to the former.
normalize_fingerprint() {
  printf '%s' "$1" | tr -d ': \t\r\n' | tr '[:upper:]' '[:lower:]'
}

production_application_id="$(read_identity_property "$production_identity_file" 'application\.id')"
[[ -n "$production_application_id" ]] ||
  fail "application.id is empty in $production_identity_file."
readonly production_application_id

# Empty until the production key exists (ADR-076 D2).
production_certificate_sha256="$(read_identity_property "$production_identity_file" 'signing\.certificate\.sha256')"
production_certificate_sha256="$(normalize_fingerprint "$production_certificate_sha256")"
[[ -z "$production_certificate_sha256" || "$production_certificate_sha256" =~ ^[[:xdigit:]]{64}$ ]] ||
  fail "signing.certificate.sha256 in $production_identity_file is not a SHA-256 digest."
readonly production_certificate_sha256

# --- Signing material stays outside the repository ---------------------------

# Prints PATH as an absolute POSIX path in which every directory that exists is
# resolved physically, so that neither a relative path nor a symbolic link hides
# where it points. The rest of PATH need not exist yet.
absolute_path() {
  local path="$1"
  local existing
  local rest=""
  [[ -n "$path" ]] || fail "An empty path was given."
  if [[ "$release_host_windows" == "1" ]]; then
    path="$(cygpath -u "$path")"
  fi
  [[ "$path" == /* ]] || path="$PWD/$path"
  existing="$path"
  while [[ ! -d "$existing" ]]; do
    rest="/$(basename "$existing")$rest"
    existing="$(dirname "$existing")"
  done
  existing="$(cd "$existing" && pwd -P)"
  printf '%s%s\n' "${existing%/}" "$rest"
}

# Fails when PATH, resolved by absolute_path, is the repository or lies inside
# it. Key material in the working tree is one `git add -A` away from a commit.
refuse_repository_path() {
  local description="$1"
  local path
  path="$(absolute_path "$2")"
  local candidate="$path"
  local root="$repository_root"
  if [[ "$release_host_windows" == "1" ]]; then
    # Windows matches file names without regard to case, so this must too.
    candidate="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')"
    root="$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]')"
  fi
  if [[ "$candidate" == "$root" || "$candidate" == "$root"/* ]]; then
    fail "$description $path is inside the repository at $repository_root.
       Signing material and its backups belong outside the working tree."
  fi
}

# --- Production provisioning -------------------------------------------------

# The five public values a production build for a phone compiles in (ADR-076 D7).
# None of them is a secret, and none of them is ever committed.
readonly -a production_provisioning_names=(
  PRODUCTION_SERVER_ORIGIN
  PRODUCTION_PRIVATE_CA_SHA256
  PRODUCTION_PRIMARY_SPKI_SHA256
  PRODUCTION_BACKUP_SPKI_SHA256
  PRODUCTION_PRIVATE_CA_PEM
)

# Fails unless all five are present, each in the form
# lib/app/config/app_configuration.dart accepts, with two different pins and a CA
# certificate file that exists. The app refuses anything else when it starts, so a
# build that compiled such a value would be spent. Sets production_server_host and
# production_server_port from the origin.
require_production_provisioning() {
  local name
  local missing=()
  for name in "${production_provisioning_names[@]}"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  [[ "${#missing[@]}" -eq 0 ]] ||
    fail "Missing production provisioning: ${missing[*]}.
       A build without complete provisioning stops at the \"App not provisioned\"
       screen and tests nothing. docs/release-signing.md shows how to derive every
       value afresh."

  # An origin as ServerOrigin.parse accepts it: https, with no user info, path,
  # query or fragment. The trust config pins one exact host, so the host has to
  # be a DNS name.
  local authority="${PRODUCTION_SERVER_ORIGIN#https://}"
  authority="${authority%/}"
  [[ "$PRODUCTION_SERVER_ORIGIN" == https://* && -n "$authority" && "$authority" != *[/?#@]* ]] ||
    fail "PRODUCTION_SERVER_ORIGIN must be an https origin with no user info, path, query
       or fragment, but is '$PRODUCTION_SERVER_ORIGIN'."
  production_server_host="${authority%%:*}"
  production_server_port="${authority#"$production_server_host"}"
  production_server_port="${production_server_port#:}"
  production_server_port="${production_server_port:-443}"
  [[ "$production_server_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
    fail "PRODUCTION_SERVER_ORIGIN must name a DNS host, but names '$production_server_host'."
  [[ "$production_server_port" =~ ^[1-9][0-9]{0,4}$ && "$production_server_port" -le 65535 ]] ||
    fail "PRODUCTION_SERVER_ORIGIN names an invalid port, '$production_server_port'."

  [[ "$PRODUCTION_PRIVATE_CA_SHA256" =~ ^[[:xdigit:]]{64}$ ]] ||
    fail "PRODUCTION_PRIVATE_CA_SHA256 must be 64 hexadecimal characters."
  for name in PRODUCTION_PRIMARY_SPKI_SHA256 PRODUCTION_BACKUP_SPKI_SHA256; do
    [[ "${!name}" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
      fail "$name must be a base64 SHA-256 digest: 44 characters ending in '='."
  done
  [[ "$PRODUCTION_PRIMARY_SPKI_SHA256" != "$PRODUCTION_BACKUP_SPKI_SHA256" ]] ||
    fail "The primary and backup pins are identical, so pin rotation is impossible."

  [[ -f "$PRODUCTION_PRIVATE_CA_PEM" ]] ||
    fail "CA certificate not found: $PRODUCTION_PRIVATE_CA_PEM"
}

# --- Android SDK -------------------------------------------------------------

resolve_android_sdk() {
  local candidate=""
  if [[ -f "$android_root/local.properties" ]]; then
    candidate="$(sed -n 's/^[[:space:]]*sdk\.dir[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' \
      "$android_root/local.properties" | tail -n 1 | tr -d '\r')"
    # local.properties escapes Windows separators.
    candidate="${candidate//\\\\//}"
    candidate="${candidate//\\//}"
  fi
  if [[ -z "$candidate" ]]; then
    candidate="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  fi
  [[ -n "$candidate" ]] ||
    fail "Android SDK not found. Set ANDROID_SDK_ROOT or sdk.dir in android/local.properties."
  if [[ "$release_host_windows" == "1" && "$candidate" == ?:/* ]]; then
    candidate="$(cygpath -u "$candidate")"
  fi
  [[ -d "$candidate" ]] || fail "Android SDK directory does not exist: $candidate"
  printf '%s\n' "$candidate"
}

android_sdk_root="$(resolve_android_sdk)"
readonly android_sdk_root

# Highest installed build-tools that actually carries the tools we need.
resolve_build_tools() {
  local directory
  local version
  for directory in $(ls -1 "$android_sdk_root/build-tools" 2>/dev/null | sort -Vr); do
    version="$android_sdk_root/build-tools/$directory"
    if [[ -f "$version/apksigner$release_bat_suffix" && -f "$version/aapt2$release_exe_suffix" ]]; then
      printf '%s\n' "$version"
      return 0
    fi
  done
  fail "No Android build-tools with apksigner and aapt2 under $android_sdk_root/build-tools."
}

build_tools_root="$(resolve_build_tools)"
readonly build_tools_root
readonly apksigner_tool="$build_tools_root/apksigner$release_bat_suffix"
readonly aapt2_tool="$build_tools_root/aapt2$release_exe_suffix"

apksigner() { "$apksigner_tool" "$@"; }
aapt2() { "$aapt2_tool" "$@"; }

# --- JDK ---------------------------------------------------------------------

# keytool ships with the JDK, and Gradle 9 and AGP 9 need a JDK 17 or newer. The
# system `java` on a maintainer workstation is frequently older, so resolve one
# explicitly and never depend on whatever happens to be first on PATH.
#
# On Windows the home is printed in C:/... form. apksigner's launcher reads
# JAVA_HOME literally and rejects a /c/... path, so a release script can export
# this value as JAVA_HOME unchanged; Git Bash runs tools from either form.
resolve_jdk_home() {
  local candidate
  local major
  local candidates=()
  [[ -n "${CP_RELEASE_JAVA_HOME:-}" ]] && candidates+=("$CP_RELEASE_JAVA_HOME")
  [[ -n "${JAVA_HOME:-}" ]] && candidates+=("$JAVA_HOME")
  if [[ "$release_host_windows" == "1" ]]; then
    while IFS= read -r candidate; do
      candidates+=("$candidate")
    done < <(ls -d "/c/Program Files/Java"/jdk-* 2>/dev/null | sort -Vr)
  fi
  for candidate in "${candidates[@]:-}"; do
    [[ -n "$candidate" ]] || continue
    if [[ "$release_host_windows" == "1" ]]; then
      candidate="$(cygpath -m "$candidate")"
    fi
    [[ -x "$candidate/bin/keytool$release_exe_suffix" ]] || continue
    major="$("$candidate/bin/java$release_exe_suffix" -version 2>&1 |
      sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n 1)"
    if [[ -n "$major" && "$major" -ge 17 ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Resolving never fails a script that runs no JDK tool. A script that does calls
# require_jdk before it asks for anything.
jdk_home="$(resolve_jdk_home || true)"
readonly jdk_home

require_jdk() {
  [[ -n "$jdk_home" ]] || fail "No JDK 17 or newer found. Set CP_RELEASE_JAVA_HOME to one."
}

# Git Bash rewrites an argument that looks like a POSIX path before a native
# program sees it, so keytool gets none of that; pass paths through
# to_native_path.
keytool() {
  require_jdk
  MSYS_NO_PATHCONV=1 "$jdk_home/bin/keytool$release_exe_suffix" "$@"
}

# --- Native symbol inspection ------------------------------------------------

resolve_llvm_nm() {
  local ndk_root="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  if [[ -z "$ndk_root" ]]; then
    ndk_root="$android_sdk_root/ndk/$RELEASE_NDK_VERSION"
  fi
  if [[ "$release_host_windows" == "1" && "$ndk_root" == ?:/* ]]; then
    ndk_root="$(cygpath -u "$ndk_root")"
  fi
  local tool="$ndk_root/toolchains/llvm/prebuilt/$release_ndk_host_tag/bin/llvm-nm$release_exe_suffix"
  [[ -x "$tool" ]] || return 1
  printf '%s\n' "$tool"
}

llvm_nm_tool="$(resolve_llvm_nm || true)"
readonly llvm_nm_tool
