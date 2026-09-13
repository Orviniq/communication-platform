#!/usr/bin/env bash
set -euo pipefail

readonly RUST_VERSION="1.97.1"
readonly NDK_VERSION="28.2.13676358"
readonly ANDROID_API="24"
readonly LIBRARY_NAME="libcommunication_crypto_core.so"

requested_abi="${1:-all}"
crypto_profile="${2:-foundation}"
case "$crypto_profile" in
  foundation) ;;
  *)
    echo "Unsupported crypto profile: $crypto_profile" >&2
    exit 2
    ;;
esac

frontend_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly frontend_root
readonly manifest="$frontend_root/native/crypto_core/Cargo.toml"
readonly build_root="$frontend_root/build/rust-android/$crypto_profile"
readonly sodium_root="$frontend_root/build/rust-android/libsodium"
readonly cargo_target_dir="$build_root/cargo-target"
readonly jni_root="$build_root/jniLibs"
readonly cargo_command="${CARGO:-cargo}"
readonly libsodium_script="$frontend_root/tool/build_libsodium_android.sh"
readonly libsodium_archive="$frontend_root/native/crypto_core/vendor/libsodium/LATEST.tar.gz"
libsodium_script_sha256="$(sha256sum "$libsodium_script" | awk '{print $1}')"
libsodium_archive_sha256="$(sha256sum "$libsodium_archive" | awk '{print $1}')"
readonly libsodium_cache_key="${libsodium_script_sha256:0:16}-${libsodium_archive_sha256:0:16}"

host_kernel="$(uname -s)"
case "$host_kernel" in
  MINGW* | MSYS*)
    readonly host_tag="windows-x86_64"
    readonly executable_suffix=".exe"
    readonly clang_wrapper_suffix=".cmd"
    to_tool_path() { cygpath -w "$1"; }
    ;;
  Linux*)
    readonly host_tag="linux-x86_64"
    readonly executable_suffix=""
    readonly clang_wrapper_suffix=""
    to_tool_path() { printf '%s\n' "$1"; }
    ;;
  Darwin*)
    readonly host_tag="darwin-x86_64"
    readonly executable_suffix=""
    readonly clang_wrapper_suffix=""
    to_tool_path() { printf '%s\n' "$1"; }
    ;;
  *)
    echo "Unsupported build host: $host_kernel" >&2
    exit 2
    ;;
esac

ndk_root="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$ndk_root" && "$host_tag" == "windows-x86_64" ]]; then
  ndk_root="${LOCALAPPDATA:-}/Android/Sdk/ndk/$NDK_VERSION"
fi
if [[ -z "$ndk_root" ]]; then
  echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT must point to NDK $NDK_VERSION." >&2
  exit 2
fi
if [[ "$host_tag" == "windows-x86_64" ]]; then
  ndk_root="$(cygpath -u "$ndk_root")"
fi
readonly ndk_root

if [[ "$(basename "$ndk_root")" != "$NDK_VERSION" ]]; then
  echo "Expected Android NDK $NDK_VERSION, found: $ndk_root" >&2
  exit 2
fi

actual_rustc_version="$(rustc --version)"
case "$actual_rustc_version" in
  "rustc $RUST_VERSION "*) ;;
  *)
    echo "Expected Rust $RUST_VERSION, found: $actual_rustc_version" >&2
    exit 2
    ;;
esac

bash "$frontend_root/tool/build_libsodium_android.sh" "$requested_abi"

readonly toolchain="$ndk_root/toolchains/llvm/prebuilt/$host_tag"
readonly llvm_ar="$toolchain/bin/llvm-ar$executable_suffix"
readonly llvm_nm="$toolchain/bin/llvm-nm$executable_suffix"
readonly llvm_readelf="$toolchain/bin/llvm-readelf$executable_suffix"

build_abi() {
  local abi="$1"
  local rust_target="$2"
  local clang_wrapper="$3"
  local cargo_target_key
  local cc_target_key
  local linker
  local archiver
  local sodium_lib_dir
  local source_library
  local destination_dir

  cargo_target_key="$(printf '%s' "$rust_target" | tr '[:lower:]-' '[:upper:]_')"
  cc_target_key="$(printf '%s' "$rust_target" | tr '-' '_')"
  linker="$(to_tool_path "$toolchain/bin/$clang_wrapper$clang_wrapper_suffix")"
  archiver="$(to_tool_path "$llvm_ar")"
  sodium_lib_dir="$(to_tool_path "$sodium_root/$libsodium_cache_key/$abi/install/lib")"
  source_library="$cargo_target_dir/$rust_target/release/$LIBRARY_NAME"
  destination_dir="$jni_root/$abi"

  env \
    "CARGO_TARGET_${cargo_target_key}_LINKER=$linker" \
    "CC_${cc_target_key}=$linker" \
    "AR_${cc_target_key}=$archiver" \
    "SODIUM_LIB_DIR=$sodium_lib_dir" \
    "CARGO_TARGET_DIR=$(to_tool_path "$cargo_target_dir")" \
    "$cargo_command" build \
      --locked \
      --release \
      --manifest-path "$(to_tool_path "$manifest")" \
      --target "$rust_target"

  if [[ ! -f "$source_library" ]]; then
    echo "Rust did not produce $source_library." >&2
    exit 4
  fi
  mkdir -p "$destination_dir"
  cp "$source_library" "$destination_dir/$LIBRARY_NAME"

  # Keep the native surface auditable: Rust's cdylib must expose only the
  # versioned profile symbols. Android's 16-KiB page-size requirement applies
  # to the 64-bit artifacts; the 32-bit armeabi-v7a artifact remains 4-KiB aligned.
  local exports
  exports="$("$llvm_nm" -D --defined-only "$destination_dir/$LIBRARY_NAME" |
    awk '{print $NF}' | sort)"
  local expected_exports
  expected_exports=$'cp_crypto_v1_abi_version\ncp_crypto_v1_application_operation\ncp_crypto_v1_attachment_operation\ncp_crypto_v1_attest_peer_master\ncp_crypto_v1_capabilities\ncp_crypto_v1_create_device_log_record\ncp_crypto_v1_cross_sign_device\ncp_crypto_v1_identity_operation\ncp_crypto_v1_inspect_device_log_record\ncp_crypto_v1_pairwise_operation\ncp_crypto_v1_prepare_device\ncp_crypto_v1_prepare_first_identity\ncp_crypto_v1_restore_identity\ncp_crypto_v1_rotate_recovery_secret\ncp_crypto_v1_sanitize_identity\ncp_crypto_v1_self_test'
  if [[ "$exports" != "$expected_exports" ]]; then
    echo "Unexpected exported symbols in $destination_dir/$LIBRARY_NAME:" >&2
    printf '%s\n' "$exports" >&2
    exit 5
  fi

  local load_alignments
  load_alignments="$("$llvm_readelf" -l "$destination_dir/$LIBRARY_NAME" |
    awk '$1 == "LOAD" {print $NF}')"
  local allowed_alignment_pattern='^0x4000$'
  if [[ "$abi" == "armeabi-v7a" ]]; then
    allowed_alignment_pattern='^(0x1000|0x4000)$'
  fi
  if [[ -z "$load_alignments" ]] || grep -Eqv "$allowed_alignment_pattern" <<<"$load_alignments"; then
    echo "Android ELF load segments have an unsupported alignment for $abi: $load_alignments" >&2
    exit 5
  fi
  if "$llvm_readelf" -d "$destination_dir/$LIBRARY_NAME" | grep -qi 'libsodium\.so'; then
    echo "The Rust library unexpectedly has a dynamic libsodium dependency." >&2
    exit 5
  fi
}

case "$requested_abi" in
  all)
    build_abi "arm64-v8a" "aarch64-linux-android" \
      "aarch64-linux-android$ANDROID_API-clang"
    build_abi "armeabi-v7a" "armv7-linux-androideabi" \
      "armv7a-linux-androideabi$ANDROID_API-clang"
    build_abi "x86_64" "x86_64-linux-android" \
      "x86_64-linux-android$ANDROID_API-clang"
    ;;
  arm64-v8a)
    build_abi "$requested_abi" "aarch64-linux-android" \
      "aarch64-linux-android$ANDROID_API-clang"
    ;;
  armeabi-v7a)
    build_abi "$requested_abi" "armv7-linux-androideabi" \
      "armv7a-linux-androideabi$ANDROID_API-clang"
    ;;
  x86_64)
    build_abi "$requested_abi" "x86_64-linux-android" \
      "x86_64-linux-android$ANDROID_API-clang"
    ;;
  *)
    echo "Unsupported Android ABI: $requested_abi" >&2
    exit 2
    ;;
esac
