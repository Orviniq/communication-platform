# ADR-051: Opt-in sustained delivery via `specialUse` foreground service

- **Status:** Accepted (distribution clause superseded on 2026-08-23 by [ADR-053](053-field-evidence-gate.md) restoring a compile-time `withheld` gate; fleet figures and "within seconds" claim corrected by [ADR-053](053-field-evidence-gate.md); distribution gate superseded for production on 2026-10-18 by [ADR-094](094-best-effort-delivery.md) offering `bestEffort`; token-race repair bullet corrected 2026-10-07 by [ADR-068](068-session-token.md) & [ADR-083](083-resumable-download.md))
- **Date:** 2026-08-22 (explicitly recorded in register and full section; implemented in `e7acfcd` and documented in `c505a43`)
- **Implements / Amends:** Builds [ADR-046](046-layered-delivery.md) Layer 2 (follow-up step 5); amends [ADR-046](046-layered-delivery.md)'s distribution clause (later restored by [ADR-053](053-field-evidence-gate.md) and moved to `bestEffort` in production by [ADR-094](094-best-effort-delivery.md)); extends [ADR-050](050-delivery-ownership.md) arbitration to three owners; amends [ADR-045](045-maturity-disclosure.md) `bestEffortDelivery` (disclosure revision 3 → 4)
- **Related:** [ADR-013](013-no-foreign-push.md), [ADR-045](045-maturity-disclosure.md), [ADR-046](046-layered-delivery.md), [ADR-049](049-background-catch-up.md), [ADR-050](050-delivery-ownership.md), [ADR-052](052-accurate-capability-claims.md)

## Decision (Position)

Implements [ADR-046](046-layered-delivery.md)'s Layer 2 as an **opt-in, off-by-default** capability keeping the application process out of Android's cached state so the composed delivery path can hold its WebSocket while nobody is looking, while reporting truthfully whenever any precondition is absent:

1. **A — `specialUse` foreground service ([SustainedDelivery.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/SustainedDelivery.kt)):**
   - Declares `SustainedDeliveryService` (`android:exported="false"`, `android:foregroundServiceType="specialUse"`, `FOREGROUND_SERVICE_SPECIAL_USE`, and `android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE` justification) with zero third-party FGS dependencies (`androidx.core:core` only; `flutter_foreground_task` 11.0.1 rejected).
   - Holds no data and opens no socket in Kotlin; exists solely to keep a running service component in the process so Android's cached-app freezer does not freeze threads and terminate TCP sockets, hosting the `sustainedDelivery` Dart entrypoint.
   - Declares **no** `BOOT_COMPLETED` receiver; reboot/upgrade restoration relies on [ADR-049](049-background-catch-up.md)'s persisted periodic job running reconciliation.
2. **B — `BackgroundConnectionPolicy` port on `SyncLifecycleSupervisor`:**
   - Default composition binds `NeverHoldsInBackground` (preserving [ADR-049](049-background-catch-up.md) behavior); [sustained_delivery_run.dart](../../../lib/app/dependencies/sustained_delivery_run.dart) composes `BackgroundedExecution()` + `AlwaysHoldsInBackground()` so `_canUseRealtime` permits holding the WebSocket while backgrounded and dynamically re-evaluates if policy changes.
3. **C — Three-owner main-looper arbitration ([BackgroundDelivery.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/BackgroundDelivery.kt)):**
   - Ranks **activity isolate > sustained service isolate > deferred catch-up isolate** on the single main looper with zero durable state.
   - Foreground attach sends `standDown` to both background isolates (`SustainedDelivery` stops its isolate while keeping the Android service alive, resuming when foreground detaches); deferred ticks deliver to whichever owner is present (keeping [ADR-049](049-background-catch-up.md)'s `JobScheduler` floor armed underneath); `awaitExclusiveOwnership` waits for both background owners.
4. **D — Four-minute WebSocket keepalive (`sustainedKeepAlive = Duration(minutes: 4)`):**
   - `SocketConnector.connect` takes an optional `keepAlive` set to 4 minutes only on sustained runs so `dart:io` pings detect silent carrier NAT drops (`goingAway`) within 8 minutes at worst rather than leaving a dead socket behind a permanent notice.
5. **E — Encrypted durable preference (`DriftSustainedDeliveryStore`):**
   - Stored in SQLCipher-encrypted `local_preferences`; turning the capability off **deletes** the row so an opt-out installation is indistinguishable on disk from one that never enabled it.
6. **F & F′ — Strict foreground enable sequence and bounded transition wait:**
   - [EnableSustainedDelivery](../../../lib/features/synchronization/application/sustained_delivery.dart) runs in strict order: (1) notifications (`POST_NOTIFICATIONS`), (2) battery-optimization exemption (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, checked via `PowerManager.isIgnoringBatteryOptimizations()`, never dialog return value), (3) durable choice write, (4) service start (withdrawing the durable choice and calling `stop()` if start fails).
   - Kotlin awaits asynchronous `onStartCommand`/`onDestroy` completion up to `TRANSITION_TIMEOUT_MS = 10_000L` so an enable call never misreads a pending start as refused.
7. **G — Live platform reconciliation (not memory):**
   - On every app resume, state transition, and deferred catch-up end, reconciliation reads `areNotificationsEnabled()` and `isIgnoringBatteryOptimizations()` fresh, starting a stopped service if all preconditions hold and **stopping** a running service whenever any precondition is missing or the session/choice ends.
8. **H & I — Settings-only UI and silent lock-screen-hidden notification:**
   - One Settings entry leading to [sustained_delivery_page.dart](../../../lib/features/synchronization/presentation/sustained_delivery_page.dart) (never prompted unasked), stating what it does, battery/visibility costs, unverifiable Samsung/Xiaomi OEM steps, and degraded states.
   - Notification uses `IMPORTANCE_LOW` (never `IMPORTANCE_MIN`), `VISIBILITY_SECRET` (hidden on secure lock screens and screen sharing), launcher-only `PendingIntent`, and reviewed localized strings passed in the start `Intent` (`EXTRA_TITLE`, `EXTRA_CHANNEL_NAME`, `EXTRA_CHANNEL_DESCRIPTION`), stopping fail-closed if no text is supplied.
9. **J — Disclosure update (revision 3 → 4) and initial distribution clause *(later amended)*:**
   - Moved `DeploymentDisclosure` from revision 3 → 4.
   - *Historical distribution clause (superseded 2026-08-23):* ADR-051 initially amended [ADR-046](046-layered-delivery.md)'s distribution prohibition to ship Layer 2 off-by-default before physical-device matrix execution; **ADR-053 superseded that clause** with a compile-time `withheld` gate (empty ledger), and **ADR-094** later superseded ADR-053 for production to offer `bestEffort` with full disclosure of unverified OEM behavior and no delivery-time promise.

## Rationale

- Primary-source Android documentation (read 2026-08-22 through Android 17 / API 37):
  - **Foreground service + Doze exemption:** Android's cached-app freezer terminates TCP sockets of frozen background processes; a running foreground service prevents caching and gives unrestricted network by app state, while `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (explicitly rated **Acceptable** by Android's Doze table for chat apps unable to use FCM under [ADR-013](013-no-foreign-push.md)) permits network/partial wakelocks during Doze, **exempts the app from App Standby Bucket restrictions entirely** (lifting [ADR-049](049-background-catch-up.md)'s 8-day *restricted* ceiling), and itself grants background FGS start permission (removing any need for a `BOOT_COMPLETED` receiver). A long-running FGS also keeps the app in the *active* bucket.
  - **Why `specialUse`:** `dataSync` is capped at 6 h/24 h (`onTimeout`) and barred from `BOOT_COMPLETED` at API 35+; `remoteMessaging` is defined for device-to-device continuity; `systemExempted` requires unavailable roles; `specialUse` carries no timeout, no runtime prerequisites, and no API 35–37 boot/timeout restrictions.
  - **Why reject alternatives:** Building nothing leaves backgrounded users at ≥15-min/Doze cadence and zero network after 8 unopened days; exact alarms (`SCHEDULE_EXACT_ALARM`) silently cancel all alarms on user revocation; polling FGS wastes battery/handshakes; holding the socket in `FlutterActivity` dies on swipe-from-Recents; a `BOOT_COMPLETED` receiver cannot read SQLCipher and would leak state or flash notices to non-opted-in users; `flutter_foreground_task` moves audited manifest/type/notification invariants into an unreviewed dependency.
  - **OEM documentation gap:** Samsung documents sleeping/deep-sleeping restrictions (`Background usage limits` / `ACTION_OPEN_CHECKABLE_LISTACTIVITY` on `com.samsung.android.lool`) and states One UI 6.0+ honors FGS for API 34+ targets (covering nothing on Android ≤13 / One UI 5.x); Xiaomi documents only a per-app Background autostart setting and makes no FGS promise. Neither replaces hardware measurement. *(Note: ADR-053 later corrected ADR-051's fleet figures from "77% of all mobile / ~50% Android ≤13" to "~90% of Android fleet / 60.0% Android ≤13", leaving ~78% uncovered by any vendor statement, and withdrew ADR-051's "within seconds" claim.)*

## Constraints and Open Gates

- **Policy and gate tests:** [sustained_delivery_policy_test.dart](../../../test/architecture/sustained_delivery_policy_test.dart) enforces `specialUse` justification claims, absence of `dataSync`/`remoteMessaging`/`systemExempted`/`Log.`/`println`, `VISIBILITY_SECRET` + `IMPORTANCE_LOW`, 10 s transition await, `ApplicationRuntime` parity, and absence of `TransportSecurity.platformDefault`. [sustained_delivery_gate_test.dart](../../../test/architecture/sustained_delivery_gate_test.dart) enforces the evidence ledger (`SustainedDeliveryGate.releaseAssertion`, currently empty; production resolves `bestEffort` under ADR-094).
- **Still open — physical-device validation matrix ([sustained-delivery-validation.md](../../sustained-delivery-validation.md)):** All 9 hardware validation items remain unmeasured on real phones (only 2026-08-23 instrumentation probes exist on an A56 and API 30/35 emulators): real `startForeground` / `specialUse` / `VISIBILITY_SECRET` / Task Manager appearance, exemption dialog across Android 11–17, Doze `force-idle` socket survival, Samsung (One UI 5.x & 6.0+) + Xiaomi (MIUI & HyperOS) multi-day retention, reboot/upgrade restoration via `JobScheduler`, 3-owner Kotlin arbiter under load, release AOT `sustainedDelivery` launch, battery/data cost + NAT keepalive tuning (`sustainedKeepAlive`), and Android 13+ Task Manager "Stop" vs. force-stop behavior.
- **Voice FGS interaction:** Follow-up 3 (two simultaneous FGSs when voice ships) was later addressed when the `microphone` call service landed (ADR-077/ADR-078).

## Costs

- Persistent `IMPORTANCE_LOW` notification on unlocked devices and permanent Task Manager entry (Android 13+) making active background operation observable to anyone holding the unlocked phone.
- Continuous battery usage (keepalive, TLS socket, Android 16 concurrent job-quota tax on the background job floor).
- Two user permissions plus uncheckable manual OEM exclusion steps on Samsung/Xiaomi devices.

## Reversal Trigger

Reopen if Android adds timeouts/prerequisites/non-Play justification gates to `specialUse`, alters the cached-app freezer or standby-bucket/Doze exemption coupling, if physical-device testing shows sustained delivery is unreliable on Samsung/Xiaomi even when configured (requiring withdrawal under revisit condition 3), if the backend adds a domestic push endpoint, if a fourth delivery owner appears, or if distribution expands beyond small known-recipient handover.

## History, Amendments, and Supersession

- **2026-08-22 (`e7acfcd`, `c505a43`):** Recorded ADR-051 (`Accepted`), implementing Layer 2 (`specialUse` FGS, 3-owner arbitration, 4-minute keepalive, reconciliation, disclosure rev 4) and relaxing ADR-046's pre-matrix distribution ban.
- **2026-08-23 (ADR-053):** Superseded ADR-051's distribution clause by withholding Layer 2 behind an empty compile-time evidence ledger (`SustainedDeliveryGate`), corrected fleet figures (77% → ~90% of Android; ~50% → 60% ≤Android 13), and withdrew the "within seconds" timing claim.
- **2026-09-08 & 2026-10-07 (ADR-068, ADR-083):** Retired rotating-refresh-token repair behind three-owner arbitration after [server ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md).
- **2026-10-18 (ADR-094):** Superseded ADR-053 for `production` to offer Layer 2 as `bestEffort` with full disclosure of unverified hardware/OEM behavior and no delivery-time promise.
