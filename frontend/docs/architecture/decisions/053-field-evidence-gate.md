# ADR-053: Field-evidence release gate for sustained delivery

- **Status:** Accepted; superseded for `production` by [ADR-094](094-best-effort-delivery.md) (2026-10-18)
- **Date:** 2026-08-23 (explicitly recorded in register and full section; implemented in `b38aa328`; 2026-08-23 A56 hardware probe addendum recorded in `sustained-delivery-validation.md` §6.1)
- **Amends:** [ADR-051](051-sustained-delivery.md) (restores [ADR-046](046-layered-delivery.md)'s pre-matrix distribution prohibition in an enforced compile-time form; corrects fleet figures and withdraws "within seconds" latency wording)
- **Superseded in part by:** [ADR-094](094-best-effort-delivery.md) (2026-10-18, offering opt-in sustained delivery in `production` as `bestEffort` with unverified-OEM disclosure and no delivery-time promise while keeping the ledger empty and closed)
- **Related:** [ADR-013](013-no-foreign-push.md), [ADR-044](044-private-deployment.md), [ADR-045](045-maturity-disclosure.md), [ADR-046](046-layered-delivery.md), [ADR-049](049-background-catch-up.md), [ADR-051](051-sustained-delivery.md), [ADR-052](052-accurate-capability-claims.md), [ADR-054](054-dependency-policy.md)

## Decision (Position)

Withheld [ADR-051](051-sustained-delivery.md)'s opt-in `specialUse` foreground-service delivery capability from every build that reaches a user until measured on real phones across seven mandatory matrix cells against ten pre-committed falsifiable criteria:

1. **A — Compile-time withheld gate ([sustained_delivery_gate.dart](../../../lib/app/config/sustained_delivery_gate.dart)):**
   - Added `SustainedDeliveryGate.releaseAssertion` holding a source-only `List<SustainedDeliveryFieldEvidence>` (empty) with zero environment defines, remote flags, runtime setters, or debug overrides ([sustained_delivery_gate_test.dart](../../../test/architecture/sustained_delivery_gate_test.dart)).
   - Under ADR-053, both `beta` (historical, removed in ADR-075) and `production` resolved `withheld` while the ledger was incomplete, and `development` resolved `measurementOnly` (including release AOT builds so [ADR-051](051-sustained-delivery.md)'s release AOT launch item could be measured). *(Later, ADR-094 replaced `withheld` for `production` with `bestEffort` while keeping `evidenced` gated on the complete ledger.)*
2. **B — Fail-closed `withheld` behavior:**
   - When `withheld`, the controller published `SustainedDeliveryStatus.withheld`, never attached its authentication listener, never reconciled, and refused `enable()` before asking the platform for any permission, exemption dialog, durable preference write, or service start — keeping `SyncLifecycleSupervisor` closing its socket on backgrounding.
   - As one positive act, a `withheld` build explicitly **stopped** any `SustainedDeliveryService` left running by an earlier build without erasing the user's durable choice.
3. **C & D — Admissibility rules and all-or-nothing matrix ([sustained-delivery-validation.md](../../sustained-delivery-validation.md)):**
   - Seven mandatory cells (`SustainedDeliveryFleetCell`): Samsung and Xiaomi crossed with Android 11–12, 13, and 14+ (covering ~79% of the expected Android fleet), plus a platform-reference cell with no manufacturer skin. Partially satisfied matrices open nothing, and no cell is optional.
   - Each cell requires a record passing `SustainedDeliveryFieldEvidence.isAdmissible`: `emulated == false`, device-reported hardware/platform version, strict ISO `YYYY-MM-DD` date surviving round-trip, a committed run record path under `docs/validation/sustained-delivery/`, ≥ 24 holding hours, ≥ 20 timed deliveries, and ≥ 3 repetitions. Inadmissible records (such as emulator runs) may be committed for observation but count as zero toward opening the gate.
   - Ten pre-committed falsifiable criteria (`C1`–`C10`, fixed 2026-08-23 before any measurement): 24 h `isForeground=true` at 100% of samples (`3/3`), socket state `01` at ≥ 99% with no gap > 10 min (`3/3`), deep-Doze ≥ 60 min latency p50 ≤ 30 s and p95 ≤ 120 s with ≤ 1 miss in 20, day-9 genuine-inactivity survival (`1`), reboot and in-place update restoration ≤ 20 min after first unlock (`3/3` each), factory-default vendor settings check (`3/3`), OTA retention check (opportunistic), `VISIBILITY_SECRET` / `IMPORTANCE_LOW` lock-screen check (`1`), and absence check when off (`1` each). Intermittent passes (e.g., 2/3) fail.
4. **E & F — Honest UI state and withdrawn latency claim:**
   - Gave `withheld` its own localized explanation (`app_en.arb` / `app_fa.arb`) distinct from `unavailable`.
   - Withdrew `sustainedWhatItDoes`'s unmeasured "within seconds" phrasing and replaced it with a mechanism statement plus "How quickly it does on your phone has not been measured", enforced by [sustained_delivery_policy_test.dart](../../../test/architecture/sustained_delivery_policy_test.dart).
   - Corrected two Statcounter fleet figures (read 2026-08-23 for Iran, 2025-08 to 2026-07): Samsung and Xiaomi are **~90%** of the *Android* fleet (54.0% + 36.1%, excluding Apple's 14.25% rather than 77% of all mobile), and Android ≤ 13 is **60.0%** (not "roughly half"), leaving ~78% uncovered by any vendor statement.
5. **G — External zero-app-instrumentation harness ([measure_sustained_delivery.sh](../../../tool/measure_sustained_delivery.sh)):**
   - Measures unmodified user-equivalent builds solely via `adb` platform debug surfaces (`probe`, `doze`, `watch`, `mark`, `verdict`) outputting to [validation/sustained-delivery/](../../validation/sustained-delivery/README.md) using the host as single clock base, separating forced and natural Doze arms, and reducing server origin to a socket count with zero PII/keys/hosts logged.

## Rationale

- **Silent absence hazard:** Although [ADR-051](051-sustained-delivery.md) ensured the persistent notification only showed while the service was running, a vendor (e.g., Xiaomi with default-off Background autostart for sideloaded apps) stopping the service leaves the user unnotified for hours — a silent failure whose only signature is absence unless someone opens Settings to look. "We cannot measure this" is a reason to withhold a capability, not to ship it.
- **Why reject alternatives:** Shipping off-by-default ([ADR-051](051-sustained-delivery.md)), user self-attestation, runtime/build flags, prose-only gates in [platform-android.md](../../platform-android.md), or a throwaway emulator probe app all either ship unmeasured risk or bypass enforcement; removing the code outright was premature before measuring real phones.
- **2026-08-23 probes ([sustained-delivery-validation.md](../../sustained-delivery-validation.md) §6.1, [validation/sustained-delivery/](../../validation/sustained-delivery/README.md)):**
  - Two AOSP emulator probes (API 30, API 35) confirmed unrooted observation surfaces work and revealed a 30× Doze schedule difference (`inactive_to` 30 m vs. 1 m) and `use_freezer=false` at API 30 vs. `true` at API 35.
  - A later unrooted probe on a retail Samsung Galaxy A56 (`SM-A566B`, Android 16 / API 36, One UI 8.5) verified `force-idle` reaches deep `IDLE` and Samsung's `ACTION_OPEN_CHECKABLE_LISTACTIVITY` (`com.samsung.android.lool`) resolves, showed `inactive_to` 30 m (first deep idle ~35 min vs. 2 min on API 35 emulator), could not confirm via config reads whether the cached-apps freezer is active on One UI 8.5, and exposed two harness bugs (`probe` dumping 446 installed packages; `watch` reading a nonexistent `frozen=` field instead of `dumpsys activity oom`), both fixed.

## Constraints and Open Gates

- **Current gate state:** `SustainedDeliveryGate.releaseAssertion` remains empty (`isOpen == false`), and all seven matrix cells remain unrun ([STATUS.md](../../STATUS.md#presence-voice-and-delivery), [sustained-delivery-validation.md](../../sustained-delivery-validation.md)).
- **Blockers at ADR-053:** Zero physical devices across the seven cells, plus `runSustainedDelivery` requiring an operator-activated `AccountSessionScope.full` account pair.
- **Uncovered tail:** Huawei (~3.7% Android), Honor (~0.7%), Unknown (~3.5%), Android ≤ 10 (12.49%), battery/data cost criteria (deferred until hardware exists), and unenumerated actual recipient handsets (Follow-up F1).
- **No production gate opened:** Left Beta/Production separation, Cargo profiles, signing identity, and cryptography untouched.

## Costs

- While ADR-053 governed distributed builds, users received only [ADR-049](049-background-catch-up.md)'s ≥15-minute `JobScheduler` floor (and zero background network after 8 unopened days on Android 13+) even if willing to pay battery/notification costs.
- Full validation requires ~7 phones, an activated test-account pair, and ~2 weeks in parallel (or ~3 months sequentially on one device).

## Reversal Trigger

Original trigger: reopen when the 7-cell physical-device matrix runs, when actual handover devices are enumerated (F1), on any measured failure on Samsung/Xiaomi with vendor steps performed (requiring removal under [ADR-051](051-sustained-delivery.md) revisit condition 3), on Android `specialUse`/freezer/standby changes, if the backend adds a push endpoint, or by the 2027-02-23 fleet-data expiry.

Current state: superseded for `production` on 2026-10-18 by ADR-094, which offers opt-in sustained delivery as `bestEffort` while leaving the evidence ledger empty and closed ([sustained_delivery_gate.dart](../../../lib/app/config/sustained_delivery_gate.dart)).

## History, Amendments, and Supersession

- **2026-08-23 (`b38aa328`):** Recorded ADR-053 (`Accepted`), creating `SustainedDeliveryGate`, ten criteria (`C1`–`C10`), seven mandatory cells, `tool/measure_sustained_delivery.sh`, corrected fleet figures, and withdrawn latency wording; added 2026-08-23 A56 probe addendum.
- **2026-10-18 (ADR-094):** Superseded ADR-053 for `production` only, replacing `withheld` with `bestEffort` (disclosing battery cost, persistent notice, unverified OEM behavior, and no delivery-time promise) while keeping `evidenced` gated on the complete 7-cell ledger.
