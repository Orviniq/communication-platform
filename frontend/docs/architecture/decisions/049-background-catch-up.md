# ADR-049: Persisted periodic JobScheduler catch-up and in-process single-owner arbitration

- **Status:** Accepted (ownership gate placement and displacement corrected by [ADR-050](050-delivery-ownership.md) on 2026-08-22; delivery disclosure extended by [ADR-051](051-sustained-delivery.md) and [ADR-052](052-accurate-capability-claims.md); rotating-refresh-token hazard retired by [server ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md) / [ADR-068](068-session-token.md) & [ADR-083](083-resumable-download.md) on 2026-10-07, while duplicate-envelope-inspection exclusion remains active)
- **Date:** 2026-08-21 (explicitly recorded in register and full section; implemented in `25f23e90` and documented in `19232fa`)
- **Implements / Amends:** [ADR-046](046-layered-delivery.md) Layer 1 (follow-up step 3; replaces `WorkManager` dependency and durable Drift delivery lease); amends [ADR-045](045-maturity-disclosure.md) `bestEffortDelivery` (disclosure revision 2 → 3)
- **Related:** [ADR-013](013-no-foreign-push.md), [ADR-043](043-private-ca-transport.md), [ADR-045](045-maturity-disclosure.md), [ADR-046](046-layered-delivery.md), [ADR-047](047-networking-composition.md), [ADR-048](048-generic-notifications.md), [ADR-050](050-delivery-ownership.md)

## Decision (Position)

Implements [ADR-046](046-layered-delivery.md)'s mandatory Layer 1 background catch-up floor (requiring zero user permissions, exemptions, or OEM configuration) while replacing two mechanisms originally sketched in ADR-046:

1. **Persisted periodic `JobScheduler` job at the platform floor (replaces `WorkManager`):**
   - [BackgroundDelivery.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/BackgroundDelivery.kt) schedules `JobInfo.Builder(JOB_ID, DeferredDeliveryJobService)` with `setPeriodic(max(requested, JobInfo.getMinPeriodMillis()))` (15 minutes at API 35), `setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)`, and `setPersisted(true)` (requiring only the normal install-time `RECEIVE_BOOT_COMPLETED` permission, with no custom boot receiver).
   - `DeferredDeliveryJobService` is declared in [AndroidManifest.xml](../../../android/app/src/main/AndroidManifest.xml) with `android:exported="false"`, `android:permission="android.permission.BIND_JOB_SERVICE"`, no `foregroundServiceType`, and no `android:process`.
   - Replaces [ADR-046](046-layered-delivery.md)'s `androidx.work` / `WorkManager` choice and adds zero dependencies; the architecture test forbidding `workmanager` remains in force.
2. **Session-scoped idempotent arming (moved off lifecycle transitions):**
   - `MessageDeliverySession` ([message_delivery.dart](../../../lib/app/dependencies/message_delivery.dart)) arms the periodic job once when a `fullScope` / `offlineFullScope` session starts and cancels it on session stop / logout; `SyncLifecycleSupervisor` no longer schedules or cancels polling on foreground/background transitions (previously `_enterBackground`/`_resumeForeground` reset the periodic window on every app open, and `dispose()` left jobs armed after logout).
   - `BackgroundDelivery.schedule` checks `getPendingJob(JOB_ID)` so equivalent re-arming does not restart the periodic window.
3. **In-process single-owner arbitration on the main looper (replaces ADR-046's durable Drift lease):**
   - Because `DeferredDeliveryJobService` declares no `android:process` and the pinned Flutter engine enforces one Dart VM and one `IsolateNameServer` per process (`DartVMRef::Create`), all delivery owners share one OS process and one main looper (`onStartJob` and `FlutterActivity.configureFlutterEngine` both execute on it).
   - On a job tick: if a live activity engine is registered, `BackgroundDelivery` invokes `runCatchUp` on that isolate (`FOREGROUND_TICK_TIMEOUT_MS = 150_000L`); if no engine exists, it starts a headless `FlutterEngine`, attaches the Context-bound storage, alert, and delivery channels, and invokes `@pragma('vm:entry-point')` `backgroundDelivery()` (`HEADLESS_RUN_TIMEOUT_MS = 240_000L`); if a headless run is already active, the tick is dropped.
   - Foreground sessions originally waited via `MessageDeliverySession.compose` calling `awaitExclusiveOwnership()` (**later moved to `bootstrap()` and paired with stand-down signaling in [ADR-050](050-delivery-ownership.md)**).
   - `BestEffortDeliveryTick.complete()` unconditionally acknowledges every tick (with a 2-minute Dart adapter timeout) so the platform can release the wakelock and freeze the process cleanly regardless of cycle outcome.
4. **Headless catch-up behavior ([deferred_delivery_catch_up.dart](../../../lib/app/dependencies/deferred_delivery_catch_up.dart)):**
   - Opens **no WebSocket** (a cached process is frozen and its TCP sockets terminated).
   - Restores the session, runs one `DurableSyncEngine.synchronize()`, reconciles sender-neutral alerts (`_reconcileAlerts`, even after a failed drain so previously committed unalerted rows still notify — later skipped when displaced under [ADR-050](050-delivery-ownership.md)), and stops.
   - Fails closed: `storageUnavailable` (such as Direct Boot / pre-first-unlock when credential-encrypted storage cannot unwrap) concludes nothing and keeps the job armed; `noSession` and `unprovisioned` disarm the job; `offline` keeps it armed.
5. **Unified `ApplicationRuntime` and Context-bound platform channels:**
   - [ApplicationRuntime.create](../../../lib/app/dependencies/application_runtime.dart) builds protected storage, compile-time configuration, provisioned `TransportSecurity`, `CryptoCorePort`, and `AuthenticationAssembly` in one shared constructor called by both `bootstrap()` and `backgroundDelivery()`.
   - Each flavor's entrypoint (`main.dart` / `main_production.dart` / historical `main_beta.dart` later removed in ADR-075) compiles its `AppEnvironment` directly so a background run cannot weaken trust anchors or permits at runtime.
   - [ProtectedStorageChannel.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/ProtectedStorageChannel.kt) and [MessageAlertChannel.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/MessageAlertChannel.kt) moved from `MainActivity` to `Context`-bound classes so headless engines do not throw `MissingPluginException` out of `SecureLocalStorageRuntime.open()`; window-bound behavior (`FLAG_SECURE`, clipboard, permission dialogs, settings) stays on `MainActivity`.
6. **Reliability honesty and disclosure update (revision 2 → 3):**
   - Renamed `DisclosurePoint.foregroundDeliveryOnly` to `bestEffortDelivery` and updated `app_en.arb` / `app_fa.arb`, moving `DeploymentDisclosure` from revision 2 → 3 (making written handover re-delivery release-blocking).

## Rationale

- Primary-source Android documentation and pinned Flutter/SDK sources (read 2026-08-21 against `minSdk` 24, `targetSdk` 36, `compileSdk` 36, Flutter 3.44.7 / `android-35`):
  - **Only deferrable jobs fit the zero-user-action floor:** FCM is excluded by [ADR-013](013-no-foreign-push.md) and unreachable during international disconnection; Layer 2 (`specialUse` FGS) and exact alarms require user grants; sync adapters require visible accounts; home-screen widgets require user placement; `setAndAllowWhileIdle` only grants a ~10-second temporary exemption (`AlarmManager.java` javadoc) — insufficient for Keystore unwrap, SQLCipher open, private-CA TLS handshake, and drain — and throttles up to 15 minutes in idle and 1/day in *restricted*; `MY_PACKAGE_REPLACED` deliverability to manifest receivers is unspecified in background-execution exemptions.
  - **Why drop `WorkManager`:** At `minSdk` 24 `WorkManager` delegates to `JobScheduler` anyway, while adding a Room database, `SystemJobService`, `RescheduleReceiver`, and `InitializationProvider` to an audited security manifest just to schedule one persisted job (`setPersisted(true)` covers reboots natively).
  - **Why reject a self-rescheduling one-shot job (`setOverrideDeadline`):** `setOverrideDeadline` runs even when network constraints are unmet, and a single failed reschedule permanently breaks the chain, whereas `setPeriodic` is self-healing.
  - **Why reject Kotlin catch-up:** Reimplementing drain, ratchet, group stack, and projections in Kotlin would create a second, unreviewed security-critical codebase.
  - **Why drop ADR-046's durable Drift lease:** With one process and one Dart VM, a durable lease coordinates between entities that die together while introducing periodic encrypted-DB heartbeat writes and stale-lease outages after crashes (and proved weaker in [ADR-050](050-delivery-ownership.md) when a headless engine is destroyed in a surviving process).
  - **Why exclude the whole cycle (not only token refresh) and wait rather than kill:** `beginNextEnvelopeInspection` re-offers `inspecting` rows by design so concurrent engines would hand the same ciphertext to the ratchet twice, and killing a headless isolate mid-FFI call into the shared native core risks corruption. (Under rotating refresh tokens active at ADR-049, two `TokenCoordinator`s would also trigger `401 invalid_token` and clear the session; [server ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md) later retired rotating tokens, as recorded in ADR-083, leaving envelope-inspection safety and post-inbox concurrency as the active invariants.)

## Constraints and Open Gates

- **Platform reliability ceiling (stated, not hidden):** `JobInfo.getMinPeriodMillis()` caps periodic cadence at 15 minutes *at best* (`setPeriodic` guarantees at most one run per interval); Doze defers jobs to thinning maintenance windows; Android 16 applies execution quotas even in the *active* bucket; Android 13+ places apps into *restricted* after 8 unopened days with background network **disabled** (unless an unread alert is visible or tapped); Data Saver on metered connections blocks `NETWORK_TYPE_ANY` background data; force-stop and battery "Restricted" stop all background work until manual launch.
- **Policy tests ([background_delivery_policy_test.dart](../../../test/architecture/background_delivery_policy_test.dart), [sync_platform_policy_test.dart](../../../test/architecture/sync_platform_policy_test.dart)):** Pin unexported `BIND_JOB_SERVICE` declaration, absence of `android:process` and exact-alarm/SMS permissions, `JobInfo.getMinPeriodMillis()` / `NETWORK_TYPE_ANY` / `setPersisted(true)`, absence of `Log.`/`println` in Kotlin, and absence of `TransportSecurity.platformDefault` or duplicate coordinators in the headless entrypoint.
- **Still open — device validation:** No physical device or rooted non-Play-Store emulator with an operator-activated account was available at ADR-049; real job execution, headless `backgroundDelivery` startup in a release AOT snapshot (only symbol survival in `libapp.so` was verified), whether `setPersisted(true)` survives in-place upgrades, and the Samsung/Xiaomi/AOSP device matrix remain open ([STATUS.md](../../STATUS.md#presence-voice-and-delivery), [sustained-delivery-validation.md](../../sustained-delivery-validation.md)).
- **Closed/superseded follow-ups:**
  - *Ownership gate placement:* Fixed by [ADR-050](050-delivery-ownership.md) on 2026-08-22.
  - *Layer 2 (`specialUse` FGS):* Built by [ADR-051](051-sustained-delivery.md), withheld by ADR-053, later offered as `bestEffort` in production by ADR-094.
  - *Group alert gap:* Addressed later by ADR-090 and ADR-091.
  - *Written handover disclosure:* Superseded into the current revision-11 release obligation ([STATUS.md](../../STATUS.md#artifact-and-release-acceptance)).

## Costs

- Background drains expose periodic (~15-minute minimum) online/poll timing metadata to the untrusted relay even when the owner is not looking at the phone (no new party or content exposure).
- Small battery and data cost per periodic wake-up when network is available.
- Platform-level silent non-delivery after 8 unopened days (Android 13+), under Data Saver on metered networks, or under unmeasured Samsung/Xiaomi background managers (77% of all mobile / ~90% of Android fleet in Iran).

## Reversal Trigger

Reopen if the platform changes the 15-minute job floor, standby-bucket network rules, 8-day *restricted* rule, or cached-app freezer; if the app ever requires a second OS process (`android:process`); if physical-device testing proves `JobScheduler` non-functional even unconfigured on Samsung/Xiaomi; if the backend adds a domestic push endpoint; or if the distribution model outgrows private known-recipient handover.

## History, Amendments, and Supersession

- **2026-08-21 (`25f23e90`, `19232fa`):** Recorded ADR-049 (`Accepted`), implementing Layer 1 via `JobScheduler` + `ApplicationRuntime` + in-process arbitration and moving disclosure 2 → 3.
- **2026-08-22 ([ADR-050](050-delivery-ownership.md)):** Moved `awaitExclusiveOwnership()` into `bootstrap()`, added foreground-wins stand-down signaling, and added singleton-ID upsert fixes.
- **2026-08-22 ([ADR-051](051-sustained-delivery.md)) & 2026-08-23 ([ADR-052](052-accurate-capability-claims.md)):** Extended arbitration to 3 owners, disclosed Data Saver/expiry, and corrected `settingsNotificationsOn` (false since ADR-049).
- **2026-10-07 (ADR-068, ADR-083):** Recorded that [server ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md) retired rotating refresh tokens, retiring the token-loss hazard while retaining single-owner exclusion for envelope inspection and post-inbox work.
