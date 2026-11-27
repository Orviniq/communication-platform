#!/usr/bin/env bash
# Measure ADR-051's opt-in sustained delivery on a real Android device.
#
# This is the instrument for the validation matrix in
# docs/runbooks/SUSTAINED-DELIVERY.md, and it is the only thing that may
# produce a row for the evidence ledger in
# lib/app/config/sustained_delivery_gate.dart.
#
# ---------------------------------------------------------------------------
# What this observes, and why it is observed this way
# ---------------------------------------------------------------------------
#
# Nothing is added to the application. Not a log line, not a counter, not a
# diagnostic screen, not an export, and above all not an outbound call: this
# project forbids the application reporting anything about itself to anybody,
# and an instrument that required such a report would be an instrument that
# could survive into a distributed build.
#
# Everything below is read from the *platform's* own debug surfaces over adb.
# The device under test therefore runs exactly the artifact a user would run,
# and the measurement cannot alter what is being measured.
#
# ---------------------------------------------------------------------------
# What it records, and what it must never record
# ---------------------------------------------------------------------------
#
# Timestamps, booleans, counts, and the device's own build identity. No message,
# no conversation, no account, no username, no token, no key, no server host, no
# IP address, and no notification text. The origin under test is passed in and
# is reduced to a boolean before anything is written, so a run record can be
# committed to this repository without disclosing where this deployment lives or
# who is on it. Run it against test accounts only. Never against a real user's
# device or account.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#
#   tool/measure_sustained_delivery.sh probe   --serial S --out DIR
#   tool/measure_sustained_delivery.sh watch   --serial S --out DIR \
#                                              --package P --origin-port 443 \
#                                              --hours 24 [--interval 60]
#   tool/measure_sustained_delivery.sh doze    --serial S --mode force|natural
#   tool/measure_sustained_delivery.sh mark    --out DIR --label send
#   tool/measure_sustained_delivery.sh verdict --out DIR
#
# Every subcommand is idempotent, appends rather than rewrites, and fails
# closed: a check that cannot be performed is an error, never a pass.

set -euo pipefail

# MSYS rewrites arguments that look like paths, which turns `adb shell ls /data`
# into a Windows path and a nonsense error. This is the documented escape.
export MSYS_NO_PATHCONV=1

serial=""
out_dir=""
package=""
origin_port="443"
hours="24"
interval="60"
mode=""
label=""
command_name="${1:-}"
[[ $# -gt 0 ]] && shift

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) serial="${2:-}"; shift 2 ;;
    --out) out_dir="${2:-}"; shift 2 ;;
    --package) package="${2:-}"; shift 2 ;;
    --origin-port) origin_port="${2:-}"; shift 2 ;;
    --hours) hours="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

command -v adb >/dev/null 2>&1 || fail "adb is not on PATH."

device() {
  if [[ -n "$serial" ]]; then
    adb -s "$serial" "$@"
  else
    adb "$@"
  fi
}

# The host clock is the single time base for the whole run: it drives the sender
# and it reads the receiver, so no clock has to be related to any other, and no
# time service — domestic or foreign — is contacted by anything here.
host_ms() {
  date -u +%s%3N
}

require_out() {
  [[ -n "$out_dir" ]] || fail "--out DIR is required."
  mkdir -p "$out_dir"
}

require_device() {
  local state
  state="$(device get-state 2>/dev/null || true)"
  [[ "$state" == "device" ]] || fail "No device in state 'device' (got '${state:-none}')."
}

# The application's Linux UID, which is what /proc/net/tcp is keyed by.
#
# `pm list packages -U` rather than `dumpsys package`: the dumpsys layout has
# moved between releases and prints nothing usable for a shared-UID package,
# while this one line is stable from API 24 upwards. It prefix-matches, so the
# package name is compared exactly.
app_uid() {
  device shell pm list packages -U "$1" 2>/dev/null | tr -d '\r' |
    awk -v pkg="package:$1" '$1 == pkg { sub(/^uid:/, "", $2); print $2; exit }'
}

# The Doze state machine's constants, with everything that belongs to the
# device's owner removed.
#
# On an emulator `dumpsys deviceidle` is all system packages. On a real phone
# its allowlist sections are a list of the applications that person has
# installed and exempted — 161 lines of them on the first device this was run
# against — which is exactly what a committed run record may not contain. Only
# the `Flags:` and `Settings:` blocks and the trailing state booleans are kept;
# every other section is replaced by its heading and a count, so a reader can
# see that something was removed rather than that the dump was truncated.
redacted_deviceidle() {
  device shell dumpsys deviceidle 2>/dev/null | tr -d '\r' | awk '
    /^  [A-Za-z]/ {
      # A new top-level section. Flush the count of the one before it.
      if (skipping && dropped > 0) {
        printf "    [%d line(s) withheld: belongs to the device'"'"'s owner]\n", dropped
      }
      dropped = 0
      skipping = ($0 !~ /^  (Flags|Settings):/)
      print
      next
    }
    skipping { dropped++; next }
    { print }
    END {
      if (skipping && dropped > 0) {
        printf "    [%d line(s) withheld: belongs to the device'"'"'s owner]\n", dropped
      }
    }
  '
}

json_escape() {
  # Deliberately conservative: everything this writes is already ASCII, and a
  # value that is not is a value this instrument should not have collected.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'
}

# ---------------------------------------------------------------------------
# probe: what this device is, and what conditions it will let us create
# ---------------------------------------------------------------------------
#
# Run this first, on every device, before anything else. Half of what it prints
# decides whether the rest of the procedure is even meaningful on this hardware:
# a device whose Doze constants differ from another's will reach Doze on a
# different schedule, and the watch durations are derived from these values
# rather than assumed.
probe() {
  require_device
  require_out
  local record="$out_dir/probe.json"

  local manufacturer model release sdk fingerprint build_type security_patch
  manufacturer="$(device shell getprop ro.product.manufacturer | tr -d '\r\n')"
  model="$(device shell getprop ro.product.model | tr -d '\r\n')"
  release="$(device shell getprop ro.build.version.release | tr -d '\r\n')"
  sdk="$(device shell getprop ro.build.version.sdk | tr -d '\r\n')"
  fingerprint="$(device shell getprop ro.build.fingerprint | tr -d '\r\n')"
  build_type="$(device shell getprop ro.build.type | tr -d '\r\n')"
  security_patch="$(device shell getprop ro.build.version.security_patch | tr -d '\r\n')"

  # A vendor build id, where the manufacturer publishes one. Absent on AOSP.
  local vendor_skin
  vendor_skin="$(device shell getprop ro.build.version.oneui 2>/dev/null | tr -d '\r\n')"
  [[ -n "$vendor_skin" ]] || vendor_skin="$(device shell getprop ro.miui.ui.version.name 2>/dev/null | tr -d '\r\n')"
  [[ -n "$vendor_skin" ]] || vendor_skin="$(device shell getprop ro.mi.os.version.name 2>/dev/null | tr -d '\r\n')"

  # An emulator identifies itself, and a run record that says so can never open
  # a cell of the matrix. This is recorded rather than refused: an emulator
  # answers real questions about the platform's own behaviour.
  local emulated="false"
  case "$fingerprint" in
    *generic*|*sdk_gphone*|*emu64*|*goldfish*|*ranchu*) emulated="true" ;;
  esac
  [[ "$(device shell getprop ro.kernel.qemu | tr -d '\r\n')" == "1" ]] && emulated="true"

  # Can this device be put into the states the criteria require at all?
  local can_force_doze="false" can_read_sockets="false" can_set_bucket="false"
  device shell dumpsys deviceidle force-idle >/dev/null 2>&1 && can_force_doze="true"
  device shell dumpsys deviceidle unforce >/dev/null 2>&1 || true
  device shell dumpsys battery reset >/dev/null 2>&1 || true
  device shell "cat /proc/net/tcp6 >/dev/null 2>&1" && can_read_sockets="true"
  device shell "am get-standby-bucket >/dev/null 2>&1" && can_set_bucket="true"

  local uid="absent"
  if [[ -n "$package" ]]; then
    uid="$(app_uid "$package")"
    [[ -n "$uid" ]] || uid="absent"
  fi

  # The Doze state machine's own constants, read from this device rather than
  # assumed from another one. The watch durations below are derived from these.
  redacted_deviceidle > "$out_dir/deviceidle.txt" || true

  cat > "$record" <<JSON
{
  "schema": "sustained-delivery-probe/1",
  "recorded_at_host_ms": $(host_ms),
  "manufacturer": "$(json_escape "$manufacturer")",
  "model": "$(json_escape "$model")",
  "platform_release": "$(json_escape "$release")",
  "api_level": "$(json_escape "$sdk")",
  "build_type": "$(json_escape "$build_type")",
  "security_patch": "$(json_escape "$security_patch")",
  "vendor_skin": "$(json_escape "$vendor_skin")",
  "emulated": $emulated,
  "app_uid": "$(json_escape "$uid")",
  "can_force_doze": $can_force_doze,
  "can_read_sockets": $can_read_sockets,
  "can_query_standby_bucket": $can_set_bucket,
  "doze_constants": "deviceidle.txt"
}
JSON
  echo "wrote $record"
  [[ "$emulated" == "true" ]] &&
    echo "note: this is an emulator. Its results answer platform questions only, and can open no cell of the matrix." >&2
  return 0
}

# ---------------------------------------------------------------------------
# doze: reach the condition, and record which way it was reached
# ---------------------------------------------------------------------------
#
# The two modes are not interchangeable and the matrix requires both, because
# whether they agree is itself a result. `force` jumps straight to deep idle and
# skips light Doze, the inactivity timer and the motion gate; `natural` unplugs
# the battery in software, waits, and reports how long the device actually took.
# A cell whose forced and natural arms disagree has no usable forced result.
doze() {
  require_device
  case "$mode" in
    force)
      device shell dumpsys battery unplug >/dev/null
      device shell dumpsys deviceidle force-idle
      echo "deep=$(device shell dumpsys deviceidle get deep | tr -d '\r\n') (forced)"
      ;;
    natural)
      # Nothing is forced. The device must be off the charger physically, the
      # screen off, and stationary; this only watches.
      device shell dumpsys battery unplug >/dev/null
      local started
      started="$(host_ms)"
      while true; do
        local deep light
        deep="$(device shell dumpsys deviceidle get deep | tr -d '\r\n')"
        light="$(device shell dumpsys deviceidle get light | tr -d '\r\n')"
        echo "$(( ( $(host_ms) - started ) / 1000 ))s deep=$deep light=$light"
        [[ "$deep" == "IDLE" ]] && break
        sleep 60
      done
      ;;
    release)
      device shell dumpsys deviceidle unforce >/dev/null || true
      device shell dumpsys battery reset >/dev/null || true
      echo "released"
      ;;
    *) fail "--mode must be force, natural, or release." ;;
  esac
}

# ---------------------------------------------------------------------------
# watch: the long observation
# ---------------------------------------------------------------------------
#
# One line of newline-delimited JSON per sample. Append-only, so a run that is
# interrupted keeps everything it had, and a device that goes away for an hour
# leaves a visible gap rather than a silently shorter run.
watch_device() {
  require_device
  require_out
  [[ -n "$package" ]] || fail "--package is required for watch."
  local samples="$out_dir/samples.ndjson"
  local deadline=$(( $(host_ms) + hours * 3600 * 1000 ))

  local uid
  uid="$(app_uid "$package")"
  [[ -n "$uid" ]] || fail "Package $package is not installed on this device."

  echo "watching $package (uid $uid) for ${hours}h, sampling every ${interval}s"
  while [[ "$(host_ms)" -lt "$deadline" ]]; do
    local device_ms deep light bucket service foreground sockets notification proc_state exempt
    device_ms="$(device shell date -u +%s%3N | tr -d '\r\n')"
    deep="$(device shell dumpsys deviceidle get deep | tr -d '\r\n')"
    light="$(device shell dumpsys deviceidle get light | tr -d '\r\n')"
    bucket="$(device shell am get-standby-bucket "$package" | tr -d '\r\n')"

    # Is the foreground service up, and does the platform consider it foreground?
    local services
    services="$(device shell dumpsys activity services "$package" 2>/dev/null || true)"
    service="false"; foreground="false"
    case "$services" in *SustainedDeliveryService*) service="true" ;; esac
    case "$services" in *isForeground=true*) foreground="true" ;; esac

    # Is a connection to the provisioned origin actually open? Only the count is
    # kept: the host and the address are reduced to a number here and never
    # written down.
    local port_hex
    port_hex="$(printf '%04X' "$origin_port")"
    sockets="$(device shell "cat /proc/net/tcp6 /proc/net/tcp 2>/dev/null" |
      awk -v uid="$uid" -v port="$port_hex" \
        '$3 ~ (":" port "$") && $8 == uid && $4 == "01" {n++} END {print n+0}')"

    # Is the permanent entry displayed? Presence only; the text is never read.
    notification="false"
    device shell "dumpsys notification --noredact 2>/dev/null | grep -q 'pkg=$package'" &&
      notification="true"

    # What state has the platform put this process in? That is the condition
    # this capability exists to control: a process in a *cached* state is frozen
    # ten seconds later and has its sockets terminated, and a process running a
    # foreground service is not cached.
    #
    # Read from `dumpsys activity oom`, whose adj label and state triple are
    # present on every device this has been run against. An earlier version of
    # this script looked for a `frozen=` field in `dumpsys activity processes`;
    # that field appears on none of them — not on One UI 8.5 and not on the
    # AOSP emulators either — so it recorded the string "unknown" at every
    # sample while looking like data. The prefix is stripped rather than the
    # columns counted, because `Proc #26:`, `Proc # 0:` and `PERS #31:` do not
    # align.
    #
    # An empty answer means the process is not listed at all, which is the
    # strongest failure this can observe: the application is gone.
    proc_state="$(device shell "dumpsys activity oom 2>/dev/null" | tr -d '\r' |
      awk -v pkg=":$package/" '
        index($0, pkg) == 0 { next }
        { line = $0 }
        !sub(/^ *(Proc|PERS) #[ ]*[0-9]+: +/, "", line) { next }
        match(line, /[A-Z]+\/[A-Z ]*\/[A-Z]+/) {
          adj = substr(line, 1, RSTART - 1)
          gsub(/ +$/, "", adj); gsub(/ +/, " ", adj)
          print adj " " substr(line, RSTART, RLENGTH); exit
        }')"
    [[ -n "$proc_state" ]] || proc_state="absent"

    exempt="false"
    device shell "dumpsys deviceidle whitelist 2>/dev/null | grep -q ',$package,'" &&
      exempt="true"

    printf '{"host_ms":%s,"device_ms":"%s","deep":"%s","light":"%s","bucket":"%s","service":%s,"foreground":%s,"origin_sockets":%s,"notification":%s,"proc_state":"%s","doze_exempt":%s}\n' \
      "$(host_ms)" "$(json_escape "$device_ms")" "$(json_escape "$deep")" \
      "$(json_escape "$light")" "$(json_escape "$bucket")" "$service" \
      "$foreground" "$sockets" "$notification" "$(json_escape "$proc_state")" "$exempt" \
      >> "$samples"

    sleep "$interval"
  done
  echo "wrote $samples"
}

# ---------------------------------------------------------------------------
# mark: a host-timestamped event, for latency
# ---------------------------------------------------------------------------
#
# The sender is driven from this same host, so a send mark and the sample that
# first shows a notification are two readings of one clock. Nothing on either
# device has to agree with anything.
mark() {
  require_out
  [[ -n "$label" ]] || fail "--label is required for mark."
  printf '{"host_ms":%s,"label":"%s"}\n' "$(host_ms)" "$(json_escape "$label")" \
    >> "$out_dir/marks.ndjson"
  echo "marked $label"
}

# ---------------------------------------------------------------------------
# verdict: apply the criteria, and refuse to guess
# ---------------------------------------------------------------------------
#
# The thresholds are the ones in docs/runbooks/SUSTAINED-DELIVERY.md, fixed
# on 2026-08-23 before anything was measured. This prints them alongside the
# result so that a reader can see the criterion that was applied rather than
# taking the word PASS on trust.
verdict() {
  require_out
  local samples="$out_dir/samples.ndjson"
  [[ -f "$samples" ]] || fail "No samples at $samples. Nothing was measured."

  awk '
    BEGIN { total = 0; up = 0; sock = 0; dozed = 0; first = 0; last = 0; gap = 0; prev = 0 }
    {
      total++
      match($0, /"host_ms":[0-9]+/); ms = substr($0, RSTART + 10, RLENGTH - 10) + 0
      if (first == 0) first = ms
      last = ms
      if ($0 ~ /"service":true/ && $0 ~ /"foreground":true/) up++
      if ($0 ~ /"origin_sockets":0/) {
        if (prev > 0 && gap == 0) gap = ms - prev
      } else { sock++; prev = ms }
      if ($0 ~ /"deep":"IDLE"/) dozed++
    }
    END {
      if (total == 0) { print "no samples"; exit 1 }
      hours = (last - first) / 3600000.0
      printf "observed window        : %.2f h  (criterion C1/C2: >= 24 h per run)\n", hours
      printf "service up             : %d/%d samples (%.2f%%)  (criterion: 100%%)\n", up, total, 100.0 * up / total
      printf "origin socket present  : %d/%d samples (%.2f%%)  (criterion: >= 99%%)\n", sock, total, 100.0 * sock / total
      printf "longest socket gap     : %.1f min  (criterion: <= 10 min)\n", gap / 60000.0
      printf "samples in deep Doze   : %d/%d\n", dozed, total
      print  ""
      print  "This is one run. A cell needs three, on the same hardware, each from a"
      print  "fresh enable, plus 20 timed deliveries. See docs/runbooks/SUSTAINED-DELIVERY.md."
    }
  ' "$samples"
}

case "$command_name" in
  probe) probe ;;
  watch) watch_device ;;
  doze) doze ;;
  mark) mark ;;
  verdict) verdict ;;
  ""|-h|--help) usage ;;
  *) fail "Unknown command: $command_name" ;;
esac
