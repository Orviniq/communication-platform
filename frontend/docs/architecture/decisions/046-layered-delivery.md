# ADR-046: Layered Android background message delivery and state-projected notifications

- **Status:** Accepted (Layer 0 implemented by [ADR-047](047-networking-composition.md); Layer 3 amended and implemented by [ADR-048](048-generic-notifications.md); Layer 1 mechanism and lease replaced by ADR-049 on 2026-08-21 and ADR-050 on 2026-08-22; Layer 2 distribution gate amended by ADR-051, restored by ADR-053, and superseded for production by ADR-094 on 2026-10-18; token-race premise changed by server ADR-0023 / ADR-068 & ADR-083)
- **Date:** 2026-08-21 (explicitly recorded in register and full section; committed in `85e89d54`)
- **Supersedes:** [ADR-029](029-background-polling.md)
- **Related:** [ADR-013](013-no-foreign-push.md), [ADR-043](043-private-ca-transport.md), [ADR-045](045-maturity-disclosure.md), [ADR-047](047-networking-composition.md), [ADR-048](048-generic-notifications.md)

## Decision (Position)

Supersedes [ADR-029](029-background-polling.md) with a **layered Android delivery architecture** converging on the single `DurableSyncEngine`, plus notifications strictly projected from committed local state:

1. **Defect correction prior to design:** Inspection showed `DurableSyncEngine`, `SyncLifecycleSupervisor`, `DioWebSocketGateway`, `GatewayRealtimeSyncAdapter`, and `NetworkingFoundation` were uncomposed in the running app (`durableSyncEngineProvider` had no consumer), so `SendConversationEvents` stopped at `fanout.prepareAndQueue` and neither sending nor receiving worked in the shipped artifact (later corrected to note `NetworkingFoundation` had no tests at all in [ADR-047](047-networking-composition.md)). Composing the delivery path (Layer 0) was made mandatory step 1.
2. **Layer 0 — Compose the existing foreground delivery path (mandatory, no user action):** Wire `SyncLifecycleSupervisor`, `GatewayRealtimeSyncAdapter`, and `DioWebSocketGateway` onto the single `TokenCoordinator` and single provisioned-CA `SecurityContext` owned by `AuthenticationAssembly` (implemented in [ADR-047](047-networking-composition.md)). WebSocket `envelope` frames remain wake-up hints triggering an authoritative REST drain.
3. **Layer 1 — Best-effort deferrable background catch-up floor (mandatory, no user action):** Schedule periodic and connectivity/boot-triggered catch-up behind `AndroidPollingScheduler` (originally sketched as `WorkManager`; **replaced by persisted `JobScheduler` without `WorkManager` in ADR-049**), reconstructing protected storage, database, provisioned transport (`TransportSecurity.provisioned`), and engine, failing closed before first unlock (Direct Boot), and never starting a foreground service.
4. **Layer 2 — Opt-in persistent-connection foreground service (off by default):** A `specialUse` foreground service declared with truthful `android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE` keeping the process out of the cached state so the composed socket survives. Requires user opt-in, `POST_NOTIFICATIONS`, battery-optimization exemption (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`), and disclosed per-OEM setup (Samsung/Xiaomi). Refuses `dataSync` (6 h/24 h cap, no `BOOT_COMPLETED` start at `targetSdk` 35+), `remoteMessaging` (device-continuity semantics), and `systemExempted` (unavailable roles). Originally prohibited from distributed builds until physical-device matrix execution (**amended by ADR-051**, restored as compile-time withheld gate by **ADR-053**, superseded for production to `bestEffort` offer by **ADR-094**).
5. **Layer 3 — Notifications as a projection of committed local state:** Never triggered by transport events or unauthenticated/quarantined/queue-gap envelopes; deduplicated durably and recovered by query rather than replay (**amended and implemented by [ADR-048](048-generic-notifications.md)**: aggregate sender-neutral notification reconciled from Drift post-commit stream with boolean `messages.alerted` instead of `PostInboxCommitWorkPort`, individual+summary alerts, and `notified_at`).
6. **Single delivery owner at a time:** Forbade concurrent engine execution across isolates to prevent duplicate envelope inspection and rotating-refresh-token races. Originally specified as a durable Drift lease (**replaced by in-process Dart-VM arbitration in ADR-049 and bootstrap gate in ADR-050**; token-rotation race itself later retired by server ADR-0023 / ADR-068 & ADR-083, while duplicate-inspection guard remains load-bearing).
7. **Four-tier reliability honesty and platform distinction:** Strictly separate Android *guaranteed restrictions* (force-stop silence, *rare*/*restricted* bucket no-network, cached-process socket termination, `WorkManager`/`JobScheduler` 15-minute floor, `POST_NOTIFICATIONS` denial) from *merely permitted* behaviors (FGS survival, OEM exemption persistence, job timing). State reliability honestly in four tiers: near-real-time foregrounded; near-real-time best-effort with Layer 2 + exemption + OEM cooperation; eventual otherwise (and none in *rare*/*restricted* buckets); none after force-stop.
8. **No foreign push, SMS, or external dependency additions by ADR-046:** Reaffirms [ADR-013](013-no-foreign-push.md); rejects FCM/APNs, UnifiedPush, exact alarms, and SMS wake; prefers app-owned Kotlin for small security-sensitive ports.

## Rationale

- Primary-source Android documentation (read 2026-08-21 against `minSdk` 24 / `targetSdk` 36 / `compileSdk` 36 and Iranian fleet data showing ~77% combined Samsung/Xiaomi share across Android 11–16, later corrected in ADR-053 to ~90% of Android fleet):
  - **Cached-app freezer (Android 14+ / AOSP):** Freezes threads and terminates active TCP sockets when an app moves to background with no active service, making an unattended WebSocket impossible.
  - **Doze & standby buckets (Android 16 quotas):** `JobScheduler`/`WorkManager` have a 15-minute floor, Doze thins maintenance windows, Android 16 enforces quotas in *active* bucket, and *rare*/*restricted* buckets disable background network completely — capping Layer 1 at *eventual*.
  - **While-idle alarms:** Capped at 9 minutes / 7 per hour, need user-revocable `SCHEDULE_EXACT_ALARM` (or disallowed `USE_EXACT_ALARM`), and still lack network in *rare*/*restricted* buckets.
  - **Foreground service + Doze exemption:** Android's only documented unrestricted-background-network state, explicitly rated **Acceptable** by Android's Doze acceptable-use table for chat apps unable to use FCM.
  - **UnifiedPush rejected:** Backend has no push endpoint and `backend/` is read-only; requires a second app and service per user; exposes message-timing metadata outside the reviewed boundary; and relocates rather than removes Android FGS/OEM constraints.
  - **SMS wake rejected:** Binds accounts to carrier phone numbers and leaks social-graph timing to carriers.

## Constraints and Open Gates

- **Closed/superseded follow-up steps:**
  - Step 1 (Layer 0 composition): done in [ADR-047](047-networking-composition.md).
  - Step 2 (Notifications / Layer 3): done and amended in [ADR-048](048-generic-notifications.md).
  - Steps 3–4 (Layer 1 & single owner): done and amended in ADR-049 & ADR-050 (`JobScheduler` without `WorkManager`, in-process arbitration without Drift lease).
  - Step 5 (Layer 2 service): built in ADR-051 (without a boot receiver, using its own isolate + 4-minute keepalive + precondition reconciliation).
  - Step 6 (Disclosure revision): moved at ADR-048 (rev 2), ADR-049 (rev 3), ADR-051 (rev 4), ADR-052 (rev 5), etc.
  - Step 8 (Dependencies): decided in ADR-054 (app-owned Kotlin + `androidx.core:core:1.16.0`; no `workmanager`, `flutter_local_notifications`, or `flutter_foreground_task`).
- **Still open — Step 7 (Physical-device matrix):** Mandatory physical-device validation across Samsung, Xiaomi, and AOSP (Android 11–16) in [sustained-delivery-validation.md](../../sustained-delivery-validation.md) remains open (empty ledger; only 2026-08-23 instrumentation probes exist). Under ADR-094, production currently offers Layer 2 as `bestEffort` with full disclosure of unverified OEM behavior and no delivery-time promise ([STATUS.md](../../STATUS.md#presence-voice-and-delivery)).
- Manifest architecture tests ([background_delivery_policy_test.dart](../../../test/architecture/background_delivery_policy_test.dart), [sync_platform_policy_test.dart](../../../test/architecture/sync_platform_policy_test.dart)) continue to forbid `remoteMessaging`, `dataSync`, exact alarms, `RECEIVE_SMS`, `workmanager`, and `firebase`.

## Costs

- **Layer 2 visibility & battery cost:** Persistent status-bar/lock-screen notification makes the app's active status observable on the device, consumes battery, requires two permissions (`POST_NOTIFICATIONS`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`), and demands per-OEM settings on Samsung/Xiaomi devices.
- **Residual unreliability:** Force-stop stops all delivery; OEM battery savers can still kill background work on 77%–90% of the target Android fleet.

## Reversal Trigger

Reopen if the backend adds a domestic push endpoint enabling UnifiedPush (with metadata tradeoffs resolved), a controlled domestic push service becomes available, Android alters `specialUse`/freezer/standby rules, the physical-device matrix proves Layer 2 unusable on Samsung/Xiaomi (requiring withdrawal under ADR-051 revisit condition 3), the deployment grows beyond a small trusted handover audience, or voice foreground-service interaction requires adjustment (addressed under ADR-077/ADR-078).

## History, Amendments, and Supersession

- **2026-08-21 (`85e89d54`):** Recorded ADR-046 (`Accepted`), superseding [ADR-029](029-background-polling.md) and reaffirming [ADR-013](013-no-foreign-push.md).
- **2026-08-21 ([ADR-047](047-networking-composition.md)):** Completed Step 1 (Layer 0) and corrected `NetworkingFoundation` test-inventory claim.
- **2026-08-21 ([ADR-048](048-generic-notifications.md)):** Completed Step 2 and amended Layer 3 (aggregate alert, Drift reconciliation, `messages.alerted`).
- **2026-08-21 – 2026-08-22 (ADR-049, ADR-050):** Completed and amended Steps 3–4 (`JobScheduler`, no `WorkManager`, in-process ownership arbitration at `bootstrap()`).
- **2026-08-22 – 2026-08-23 (ADR-051, ADR-053):** Built Layer 2 (without boot receiver, with own isolate + keepalive), amended and then restored the physical-device gate as compile-time `withheld`.
- **2026-10-07 (ADR-068, ADR-083) & 2026-10-18 (ADR-094):** Server ADR-0023 retired rotating refresh tokens (leaving envelope-inspection safety as the remaining reason for single-owner arbitration); ADR-094 superseded ADR-053 for production to offer Layer 2 as `bestEffort`.
