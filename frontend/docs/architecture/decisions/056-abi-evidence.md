# ADR-056: Per-ABI hardware-execution gate for closed-beta PQ MLS

- **Status:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13)
- **Date:** 2026-08-24 (explicitly recorded in register and full section; implemented in `f4507b1a`; closed `2026-09-13`)
- **Amends:** [ADR-055](055-initial-artifact.md) (replaces global `GroupExperimentalGate.isOpen` with per-ABI `hasEvidenceFor`, opens `arm64-v8a` on measured hardware evidence, and moves disclosure revision 6 → 7)
- **Closed by:** [ADR-075](075-pairwise-groups.md) (2026-09-13), following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- **Related:** [ADR-017](017-independent-crypto-review.md), [ADR-036](036-beta-mls-track.md), [ADR-040](040-beta-kem-divergence.md), [ADR-044](044-private-deployment.md), [ADR-053](053-field-evidence-gate.md), [ADR-054](054-dependency-policy.md), [ADR-055](055-initial-artifact.md), [ADR-058](058-voice-prerequisites.md)

## Decision (Position)

Executed [ADR-055](055-initial-artifact.md)'s closed-beta PQ MLS test binary on real 64-bit ARM hardware and switched the evidence gate from all-or-nothing per-artifact to **per-ABI**:

1. **Recorded `arm64-v8a` device measurement ([2026-08-24-sm-a566b-arm64-v8a/run.json](../../archive/beta-mls-core/2026-08-24-sm-a566b-arm64-v8a/run.json)):**
   - Executed `tool/measure_beta_mls_core.sh arm64-v8a` (Rust 1.97.1, NDK 28.2.13676358, CMake 4.2.1, Ninja 1.13.2) on an unrooted retail Samsung Galaxy A56 (`SM-A566B`, Android 16 / API 36, `user` build, `release-keys`, `ro.kernel.qemu=0`, no backend/account/APK install).
   - **Result:** `128 passed, 0 failed, 3 ignored in 172.07 s` (exit 0) — identical passed/ignored counts to host `cargo test --locked --all-features`, exercising 40 `mls_beta::` tests including `suite_signs_with_ed25519_and_round_trips_hybrid_hpke` (`aws-lc` ML-KEM C/assembly).
   - Fixed two instrument bugs exposed by hardware: added `MSYS_NO_PATHCONV=1` / `MSYS2_ARG_CONV_EXCL='*'` so Git Bash did not rewrite `/data/local/tmp/...`, and replaced `>/dev/null` in device setup steps with an output-capturing helper so `adb shell` diagnostics were not silenced.
2. **D1–D4 — Per-ABI gate (`GroupExperimentalGate.hasEvidenceFor(GroupMlsFieldCell?)`) and strict fail-closed bounds:**
   - Replaced the global `isOpen` check with per-ABI resolution: `GroupProductionGate.privateExperimentalPermit` took the running ABI via a single `runtimeAbiProvider` conditional-import seam (`runtime_abi.dart` → `_native` / `_web` / `_stub`), with tests forbidding direct `Abi.current()` or `dart:ffi` imports elsewhere.
   - **Opened `arm64-v8a` only; kept `armeabi-v7a` and `x86_64` withheld** (unsupported adapter on all nine methods, zero KeyPackage upload, no post-inbox maintenance, inbound group objects refused, closed screens, disabled Contacts entry). Any ABI with no packaged library (e.g., desktop host, RISC-V) mapped to `null` and failed closed.
   - **Zero cell demotion and zero relaxation of `isAdmissible`:** Because the A56's Exynos `s5e8855` is 64-bit-only (`ro.product.cpu.abilist32` empty), `armeabi-v7a` remained mandatory and unmeasured in the ledger rather than dropped.
   - **Not a runtime switch:** `Abi.current()` is fixed by the OS-installed AOT snapshot, can only narrow, and never reached `production` (verified unsigned via `verify_release_apk.sh --production` and asserted closed even under a satisfied ledger).
3. **D5 — Disclosure revision 6 → 7 ([deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart)):**
   - Updated the `experimentalGroups` `DisclosurePoint` (`since: 7`) to state both [ADR-036](036-beta-mls-track.md)'s disposable-state rule where groups are active and that unmeasured-ABI devices have groups switched off, triggering re-presentation via `DisclosureChangeGate`.

**Closure:** Closed by [ADR-075](075-pairwise-groups.md) (2026-09-13) when MLS and the `beta` flavor were removed; groups now use pairwise Double Ratchet fan-out across all ABIs ([CRYPTO.md](../../contracts/CRYPTO.md#groups)), and the A56 measurement record is preserved in [archive/beta-mls-core/](../../archive/beta-mls-core/README.md).

## Rationale

- **One APK, three ABIs, one installed library:** Because Android installs one ABI library per device, per-artifact gating either forced quiet demotion of an unmeasurable `armeabi-v7a` cell (forbidden by [ADR-053](053-field-evidence-gate.md) and [ADR-055](055-initial-artifact.md)) or withheld a working, measured stack from all `arm64-v8a` recipients over a 32-bit device nobody in the deployment was known to carry.
- **Stricter than [ADR-055](055-initial-artifact.md) for unmeasured ABIs:** Under [ADR-055](055-initial-artifact.md), once a global ledger passed, any newly added ABI would have opened automatically without a run; under ADR-056, every unmeasured ABI remained closed regardless of other records.
- **Rejected alternatives:** (A) opening globally on an `"abi": "arm64-v8a"` record; (B) demoting `armeabi-v7a` without hardware evidence; (C) dropping `armeabi-v7a` from the APK (which would deny 32-bit users the entire supported DM tier to shield them from experimental groups); (D) blocking `arm64-v8a` until `armeabi-v7a` hardware was found; (E) accepting blanket multi-ABI risk when 64-bit ARM had been measured and 32-bit risk was cheaply isolated in ~60 lines.
- **External research (2026-08-24):** Android 64-bit requirements confirm 64-bit-only hardware (`SM-A566B`), NDK ABI docs confirm `armeabi-v7a` remains a supported NDK ABI, and `aws-lc` `README.md` lists Android `aarch64` under supported platforms vs. `arm32` under *Other platforms* — aligning with repository evidence while resting solely on observed execution.

## Constraints and Open Gates

- **Closed:** `GroupExperimentalGate`, `GroupProductionGate`, `runtime_abi.dart`, `tool/measure_beta_mls_core.sh`, and `docs/mls-profile.md` were deleted in ADR-075 (historical snapshot at `f4507b1a` / `788453b430f34c52c2063ef67b8aa5e4f8fa935d`).
- **What ADR-056 did not close (even while beta existed):** Did not close Gate 6 (process kill, Doze, force-stop, torn writes, Keystore-after-reboot), any of the seven production gates, [ADR-017](017-independent-crypto-review.md) independent review, multi-device / live-backend group testing, or the on-device Dart ABI assertion in `integration_test/crypto_core_android_smoke_test.dart` (blocked on `gradle.lockfile` requiring all three engine ABIs during a single-ABI `flutter test` build).
- **Downstream effect on voice:** [ADR-058](058-voice-prerequisites.md) subsequently bound Piece 20's experimental voice eligibility (P3) to this same per-ABI permit rule before voice pivoted to DTLS-SRTP mesh in ADR-077.

## Costs

- Users on 32-bit ARM (`armeabi-v7a`) or `x86_64` devices kept direct messaging and received no experimental groups until ADR-075 replaced MLS with pairwise groups.
- Maintaining `runtimeAbiProvider` conditional imports added ~60 lines of platform-seam indirection while the beta track existed.

## Reversal Trigger

Original triggers: open `armeabi-v7a` automatically on a passing hardware run, halt on any failing ABI run, add new packaged ABIs as withheld, or close on multi-device defects, production gate closure, or independent review.

Current state: already closed by ADR-075 (2026-09-13).

## History, Amendments, and Supersession

- **2026-08-24 (`f4507b1a`):** Recorded ADR-056 (`Accepted`), archiving `2026-08-24-sm-a566b-arm64-v8a` run evidence, switching `GroupExperimentalGate` to per-ABI, adding `runtimeAbiProvider`, fixing `measure_beta_mls_core.sh`, and moving `DeploymentDisclosure` to revision 7.
- **2026-08-25 ([ADR-058](058-voice-prerequisites.md)):** Referenced ADR-056's per-ABI gate as voice prerequisite P3.
- **2026-09-13 (ADR-075):** Closed and deleted the beta MLS track and per-ABI gate in favor of pairwise Double Ratchet groups.
