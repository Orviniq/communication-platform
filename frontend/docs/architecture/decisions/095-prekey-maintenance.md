# ADR-095: Run prekey maintenance at the end of a healthy delivery cycle

- **Status:** Proposed (2026-10-18); implementation and ADR record landed in `5eeace1b` / `b4934d9c` (PR #87 `b781646d`) while status cell remained `Proposed` in legacy `decisions.md` (recorded as an open status gap in [index](README.md))
- **Date:** 2026-10-18 (explicitly recorded in register and full section; implemented on `frontend-prekey-maintenance-owner` in `5eeace1b`, documented in `b4934d9c`, PR #87 `b781646d`)
- **Completes:** [ADR-093](093-held-first-message.md) ("Not done here" prekey maintenance wiring)
- **Related:** [ADR-050](050-delivery-ownership.md), [ADR-087](087-chat-status.md), [ADR-093](093-held-first-message.md), [SYNC.md](../SYNC.md), [PAIRWISE-V1.md](../../contracts/PAIRWISE-V1.md), [devices API](../../../../backend/devices/API.md)

## Decision (Position)

Wired `PrekeyMaintenanceService` into `DurableSyncEngine` so every delivery owner runs signed-prekey rotation, retired-pair pruning, and one-time-prekey replenishment on a bounded schedule without interfering with message delivery or quarantining first messages on pending plans:

1. **D1 — Cycle ownership ([durable_sync_engine.dart](../../../lib/features/synchronization/application/durable_sync_engine.dart), [prekey_maintenance_providers.dart](../../../lib/features/devices/infrastructure/prekey_maintenance_providers.dart)):**
   - `DurableSyncEngine` takes an optional `DeviceMaintenancePort` (`PrekeyMaintenanceCycleWork` wrapping `ScheduledPrekeyMaintenance` via `scheduledPrekeyMaintenanceProvider(scope)`).
   - Because the foreground `MessageDeliverySession`, deferred catch-up (`deferred_delivery_catch_up.dart`), and sustained run (`sustained_delivery_run.dart`) all drive `durableSyncEngineProvider(scope)`, all three execute maintenance through one owner without a separate timer or entry point.
2. **D2 — End-of-healthy-cycle placement:**
   - Runs as the last step of `DurableSyncEngine.synchronize`, *after* the phase is marked `online` (so the [ADR-087](087-chat-status.md) Chats title does not show syncing during key uploads and outbox/inbox/acks never wait behind maintenance).
   - Skipped when the cycle encountered any failure or when the owner was asked to stand down (leaving maintenance to the foreground owner).
3. **D3 — In-memory cadence ([scheduled_prekey_maintenance.dart](../../../lib/features/devices/application/scheduled_prekey_maintenance.dart)):**
   - `ScheduledPrekeyMaintenance.runIfDue()` runs on the first turn of a process, then **6 hours** after a successful run or **5 minutes** after a failed run (and immediately if the due timestamp is more than 6 hours ahead, indicating backward clock adjustment).
   - Schedule is kept in memory per engine scope so no schema change is required (a process-start deferred catch-up pays at most one `GET /api/v1/me/devices/{id}/prekeys/count` + native prune when nothing is due).
4. **D4 — Pending maintenance plan defers initial envelopes rather than quarantining:**
   - When an earlier interrupted run left a row in `prekey_maintenance_plans`, `DriftPairwiseTransportStore._applyDeviceStateTransition` still refuses initial-envelope device transitions (preventing resurrection of a consumed one-time prekey), now throwing `_PairwiseDeviceStateHeld` (a `_PairwiseConflict` subclass).
   - `commitPreparedReceive` maps `_PairwiseDeviceStateHeld` to `CancellationFailure(lifecycleInterrupted)` so `DurableSyncEngine` treats it as transient (retried after the 1 s retry floor without spending `inspection_failures` budget), whereas volatile opens continue treating the conflict as refused and drop the signal.
5. **D5–D6 — Exclusion and fault isolation:**
   - `DurableSyncEngine.synchronize` is single-flight and `ScheduledPrekeyMaintenance` joins an in-flight run, preventing concurrent plans inside a process; across isolates, [ADR-050](050-delivery-ownership.md) arbitration keeps one owner active.
   - `DurableSyncEngine` catches exceptions from `DeviceMaintenancePort` so maintenance errors never alter the sync cycle's reported outcome; `scheduledPrekeyMaintenanceProvider` lazily resolves `prekeyMaintenanceServiceProvider(scope)` on first run and invalidates a failed composition so the next turn builds afresh.
6. **D7–D8 — Offline behavior and [ADR-093](093-held-first-message.md) preservation:**
   - Offline cycles skip maintenance (supervisor skips cycles offline; catch-up stops on offline restore; failed drains/sends skip D2); any durable pending plan holds incoming initials transiently until a healthy cycle resumes it (every 5 minutes of cycles).
   - `PrekeyMaintenanceService` and [ADR-093](093-held-first-message.md) D17 (prune day `min(today, earliestHoldDay)` and rotation postponement) are untouched.

## Rationale

- Inspection of `4091856e` confirmed `prekeyMaintenanceServiceProvider` and `PrekeyMaintenanceService.maintain` had zero callers anywhere in `lib/`, leaving [`sync-engine.md`](https://github.com/Orviniq/communication-platform/blob/4091856e93ede348a739ce08aefcecdac5ea6148/frontend/docs/sync-engine.md)'s description of active prekey rotation and replenishment untrue.
- Wiring maintenance inside `DurableSyncEngine` rather than a separate supervisor timer prevents inbox device-state transitions from racing between plan preparation and completion and covers background catch-up and sustained runs automatically.
- Treating `_PairwiseDeviceStateHeld` as transient rather than `ValidationFailure(conflict)` avoids quarantining legitimate first messages on their first attempt if a prior maintenance plan was interrupted mid-upload.

## Constraints and Open Gates

- **Scope:** Added `DeviceMaintenancePort`, `ScheduledPrekeyMaintenance`, `PrekeyMaintenanceCycleWork`, end-of-cycle call in `DurableSyncEngine`, and `_PairwiseDeviceStateHeld` transient mapping; changed no wire format, event kind, cryptographic construction, Rust core, dependency, Android permission, Kotlin file, `PrekeyMaintenanceService`, database schema, server route, or `backend/` file.
- **Verification:** Covered by host unit tests for end-of-cycle healthy execution, failure/stand-down skipping, throw isolation, in-flight joining, 6 h / 5 min / backward-clock intervals, failed-provider invalidation, and pending-plan transient deferral without state mutation.
- **Left open / not verified:** No phone or live-server run verifying the first signed-prekey rotation upload, `VerifiedRotationDeviceLog` append, peer acceptance of the rotated bundle, pre/post server prekey counts, or deferred catch-up count call.

## Costs

- Each process restart starts due and issues one `GET /api/v1/me/devices/{id}/prekeys/count` check on its first healthy cycle (including 15-minute deferred background catch-up processes).
- While a failed maintenance plan remains pending, incoming regular envelopes for that session arriving before its deferred initial still quarantine as unknown-session ([ADR-093](093-held-first-message.md) known limitation), and a permanently failing device-log append leaves incoming first messages retrying every 5 minutes of cycles rather than quarantining.

## Reversal Trigger

Reopen if the schedule must persist across process restarts (requiring a schema migration to avoid a count request per catch-up process) or when verifying rotation and replenishment end-to-end against a live server on hardware.

## History, Amendments, and Supersession

- **2026-10-18 (`5eeace1b`, `b4934d9c`, PR #87 `b781646d`):** Proposed and implemented ADR-095 wiring `ScheduledPrekeyMaintenance` into `DurableSyncEngine` and mapping pending-plan conflicts to transient deferral.
