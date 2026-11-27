# Sustained-delivery run records

Each dated directory holds output from
[`measure_sustained_delivery.sh`](../../../tool/measure_sustained_delivery.sh).
The [field criteria](../../sustained-delivery-validation.md) define the records
required by the compiled release ledger.

**Gate state: CLOSED.** The three directories hold probes dated 2026-08-23: one
retail Samsung Galaxy A56 (Android 16/API 36) and two emulators (API 30 and API
35). The A56 probe reports the app UID as absent. These probes establish device
conditions and observation-tool coverage. No sustained-delivery trial was run.
Emulator measurements are ineligible for matrix cells. The
[compiled ledger](../../../lib/app/config/sustained_delivery_gate.dart) is empty,
and production offers opt-in sustained delivery as `bestEffort` under ADR-094.
See [frontend status](../../STATUS.md#presence-voice-and-delivery).

## What a run directory holds

| File | What it is |
|---|---|
| `probe.json` | the device's own build identity, and which test conditions it will permit |
| `deviceidle.txt` | that device's Doze constants, read rather than assumed |
| `samples.ndjson` | one line per observation: service, socket, Doze, bucket, exemption, freeze |
| `marks.ndjson` | host-timestamped events, so a send can be paired with an arrival |

## What must never appear in one

Message content, conversation, account, username, token, key, notification text,
server host, IP address. The origin under test is reduced to a socket **count**
before anything is written, so these files disclose neither where this
deployment lives nor who is on it. Runs use dedicated test accounts only, never
a real user's device or account. Anything else that turns up in a run record is
a defect in the harness, not a file to redact by hand.
