# Closed-beta PQ MLS core run records

One directory per measurement run, produced by `tool/measure_beta_mls_core.sh`
and named `YYYY-MM-DD-<model>-<abi>`. [ADR-055](../../architecture/decisions/055-initial-artifact.md) made these
records evidence for the former gate in `lib/app/config/group_production_gate.dart`.

**Recorded beta gate state: OPEN for `arm64-v8a`, CLOSED for `armeabi-v7a` and `x86_64`**
(ADR-056). One run exists. `cp_crypto_v1_beta_mls_operation` was executed on a
Samsung SM-A566B on 2026-08-24 and the crate's own `--features beta-pq-mls`
suite passed there — 128 passed, 0 failed, 3 ignored, the same counts the x86_64
host gives, so the device ran the whole suite rather than a subset that happened
to link.

The archive has no device runs for the other two ABIs. The beta withheld the group
surface on devices that loaded them. The `arm64-v8a` phone reported an empty
`ro.product.cpu.abilist32` and could not execute the `armeabi-v7a` build.

## What the measurement answers, and what it does not

It answers one question: **does the packaged closed-beta MLS core compute
correctly on this CPU?** It runs the crate's own `--features beta-pq-mls` test
suite, cross-compiled by the pinned toolchain for one Android ABI, on the
device itself. That covers the ML-KEM, AEAD, signature and ratchet-tree
arithmetic where an ABI-specific `aws-lc` assembly path is selected — the part
that host tests on an x86 workstation cannot speak to.

It does **not** answer whether groups work between people. Multi-device
execution against a live backend, the physical-device crash matrix, and the
remaining piece-19 cells in [the historical MLS profile](https://github.com/Orviniq/communication-platform/blob/788453b430f34c52c2063ef67b8aa5e4f8fa935d/frontend/docs/mls-profile.md)
had separate evidence requirements. Opening the beta gate offered the group surface
on that ABI. All seven production gates kept their own requirements.

## What a run directory holds

| File | What it is |
|---|---|
| `run.json` | the device's own build identity, the toolchain, and the test result |
| `test-output.txt` | the suite's own output, as the device produced it |

## What must never appear in one

The suite runs on generated material and touches no account, no backend and no
user state, so a record has nothing to redact. If a run record ever contains a
message, a username, a token, a key, a server host or an IP address, that is a
defect in the harness rather than a file to edit by hand.

## Historical admissibility

A record opens a cell only if the gate's own rule accepts it — not emulated, a
strict `YYYY-MM-DD` date, a committed run record path, and every operation of
the round trip exercised. An emulator record may be committed and will never
open anything: an emulator on an x86 host does not run the ARM assembly that is
the entire subject of the measurement.

A record opens **one ABI**, never the artifact. One APK carries every ABI and the
installer, not this project, decides which library a recipient loads — so the
gate asks about the library the running process actually loaded, and an ABI with
no admissible record is withheld the surface whatever else the ledger holds. An
ABI this artifact packages no library for maps to no cell and fails closed.
