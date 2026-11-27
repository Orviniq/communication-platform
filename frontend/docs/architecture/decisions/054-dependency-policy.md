# ADR-054: Platform dependency policy, exact pinning, and Android supply-chain lock

- **Status:** Accepted (subsequently extended with `emoji_picker_flutter` 4.5.3 and `kotlin.incremental=false` in ADR-059, and with `flutter_webrtc` 1.6.2+hotfix.3 / JitPack `audioswitch` / `libwebrtc` in ADR-078; closed-beta `beta` flavor configurations removed in ADR-075)
- **Date:** 2026-08-24 (explicitly recorded in register and full section; implemented in `3a8e90c5`)
- **Supersedes:** [ADR-007](007-flyer-timeline.md) (Flyer Chat behind a timeline adapter — already replaced in implementation by piece 15's app-owned reversed sliver; later formally closed by ADR-066 on 2026-08-30)
- **Ratifies / Amends:** Platform integration choices made in [ADR-046](046-layered-delivery.md), [ADR-048](048-generic-notifications.md), [ADR-049](049-background-catch-up.md), and [ADR-051](051-sustained-delivery.md) (reverses caret ranges, unpinned Android transitive resolution, and unused packages)
- **Related:** [ADR-006](006-forui-boundary.md), [ADR-013](013-no-foreign-push.md), [ADR-031](031-semantic-icons.md), [ADR-032](032-rust-ffi.md), [ADR-036](036-beta-mls-track.md), [ADR-040](040-beta-kem-divergence.md), [ADR-043](043-private-ca-transport.md), [ADR-044](044-private-deployment.md), [ADR-053](053-field-evidence-gate.md)

## Decision (Position)

Enumerated every platform integration point of the delivery and notification path from source code, channels, imports, and the merged release manifest, and locked both the Dart and Android dependency sets:

1. **Twelve-point platform integration disposition (9 written on framework/embedding, 3 adopting `androidx.core` / `connectivity_plus`):**
   - **Written on Android framework / Flutter embedding:** (1) deferred wake-up on `JobScheduler` (`DeferredDeliveryJobService`, [ADR-049](049-background-catch-up.md); `androidx.work` rejected); (2) headless engine (`FlutterEngine` + `DartExecutor`); (3) Dart ↔ platform channels (`MethodChannel` for `background_delivery`, `sustained_delivery`, `message_alerts`, `protected_storage`); (4) `SustainedDeliveryService` ([ADR-051](051-sustained-delivery.md); `flutter_foreground_task` rejected) using `ServiceCompat`/`ContextCompat`; (7) battery-optimization exemption (`PowerManager.isIgnoringBatteryOptimizations`, `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`); (8) notification and Samsung settings intents; (10) lifecycle (`WidgetsBindingObserver`); (12) alert icon (`res/drawable/ic_message_alert.xml`, per [ADR-031](031-semantic-icons.md)). Point (11) database key is written (`ProtectedStorageChannel`), while database path stays inherited via `drift_flutter` → `path_provider_android` → `jni`/`jni_flutter` → `com.getkeepsafe.relinker` (deferred to Follow-up F1).
   - **Adopted and pinned:**
     - `androidx.core:core:1.16.0` (already on classpath via `androidx.activity`/`androidx.fragment`; declared explicitly in `android/app/build.gradle.kts` and justified for `FileProvider`, `NotificationCompat`/`NotificationManagerCompat`/`NotificationChannelCompat` [rejecting `flutter_local_notifications` and `awesome_notifications`], `ServiceCompat`/`ContextCompat`, and `ActivityCompat` [rejecting `permission_handler`]; 1.17.0 adds unused notification features and 1.18.0+ requires `compileSdk` 36.1).
     - `connectivity_plus: 6.0.5` (frozen: 7.0.0 lacks fixes and 7.1.0–7.3.1 declare `androidx.core:core:1.18.0`, forcing a `compileSdk` 36.1 migration; rejected hand-rolling `registerDefaultNetworkCallback` without physical-device testing or spinning cycles offline).
     - `jni: 1.0.3` / `jni_flutter: 1.0.2` (replaced publisher-retracted `jni` 1.0.1 and deleted the hand-written KGP workaround in `android/build.gradle.kts` with a byte-identical Gradle resolution).
2. **Exact Dart pinning and unused-package removal ([pubspec.yaml](../../../pubspec.yaml)):**
   - Removed four declared-and-unused packages (`flutter_chat_ui` 2.11.1, `flutter_chat_core` 2.9.0, `riverpod_annotation` 4.0.3, `riverpod_generator` 4.0.4), eliminating 18 transitive packages including pre-release `riverpod_analyzer_utils` (`1.0.0-dev.10`) and build-time `mockito`.
   - Replaced caret ranges on the remaining six ranged dependencies (`dio`, `drift`, `drift_flutter`, `forui`, `go_router`, `flutter_lints`) with exact versions so every direct dependency in `pubspec.yaml` is an exact pin (14 runtime + 5 dev at ADR-054; later expanded by ADR-059 and ADR-078).
3. **Android dependency locking and manifest curation ([gradle.lockfile](../../../android/app/gradle.lockfile), [dependency_policy_test.dart](../../../test/architecture/dependency_policy_test.dart)):**
   - Enabled Gradle `LockMode.STRICT` across all built configurations (at ADR-054: 78 modules across six `beta`/`production`/`developmentDebug` configurations, with 51 external modules on `betaReleaseRuntimeClasspath` / `productionReleaseRuntimeClasspath` and three plugin subprojects; `developmentDebug*` dev/test libraries such as Espresso/JUnit/Guava/Hamcrest are asserted never to reach distributed configurations). *(Note: ADR-075 later removed the `beta` flavor configurations, and ADR-059 / ADR-078 grew `productionReleaseRuntimeClasspath` to 93 modules.)*
   - Declared `ACCESS_NETWORK_STATE` explicitly in the source manifest with its justification rather than inheriting it silently from `connectivity_plus`.
   - Refused `androidx.profileinstaller.ProfileInstallReceiver` (`android:exported="true"`) via `tools:node="remove"`, keeping baseline profile writes through `ProfileInstallerInitializer` → `ProfileInstaller.writeProfile(Context)` (verified via `javap`).
   - Verified via bytecode scan of all 4,559 classes across the 51 release modules and inspection of `app-production-release.apk`'s R8-shrunk `classes.dex` (574 KB) that zero Java/Kotlin code can open a network connection; all network bytes traverse `dart:io` over the provisioned private-CA trust store.
4. **License discharge ([third-party-notices.md](../../third-party-notices.md), [deployment-and-release.md](../../deployment-and-release.md)):**
   - Recorded all distributed Android modules (Apache-2.0 and BSD-3-Clause) with full license texts and attribution in [third-party-notices.md](../../third-party-notices.md) to travel with the private handover, pinned by [dependency_policy_test.dart](../../../test/architecture/dependency_policy_test.dart) against `gradle.lockfile` so notices cannot drift from the linked set.

## Rationale

- **"We own it" vs. "everyone uses it":** Every integration point was weighed against two risks — importing unreviewed transitive code or hand-writing unforgiving platform/version branching without hardware verification.
- **Why Dart lockfiles alone are insufficient:** Upgrading `connectivity_plus` to 7.3.1 changed only one line in `pubspec.lock` while silently pulling `androidx.core:core:1.18.0`, breaking `compileSdk` 36 — proving `pubspec.lock` does not bound Android transitive dependencies.
- **Why strict locking + policy test:** Gradle's `LockMode.STRICT` fails on *new* transitive modules, while [dependency_policy_test.dart](../../../test/architecture/dependency_policy_test.dart) additionally enforces that declared pins, `gradle.lockfile`, `pubspec.yaml`, `pubspec.lock`, `AndroidManifest.xml`, and [third-party-notices.md](../../third-party-notices.md) all agree and contain zero pre-release versions or dynamic ranges.

## Constraints and Open Gates

- **Pinned enforcement:** `flutter pub get --enforce-lockfile` ([ci.sh](../../../tool/ci.sh)), Gradle `LockMode.STRICT` ([gradle.lockfile](../../../android/app/gradle.lockfile)), [dependency_policy_test.dart](../../../test/architecture/dependency_policy_test.dart), and [verify_release_apk.sh](../../../tool/verify_release_apk.sh) enforce the Dart, Android, manifest, and notice sets.
- **Deferred follow-ups recorded at ADR-054:**
  - *F1:* Evaluate replacing `path_provider` (`jni`/`jni_flutter`/ReLinker) with `ProtectedStorageChannel` while guaranteeing the identical database directory path.
  - *F2:* Add an in-app third-party notices screen surfacing `assets/flutter_assets/NOTICES.Z` and Android attributions (handover-document discharge only scales to small private distribution).
  - *F3:* Aggregate licenses for the Rust crypto core and vendored C sources ([Cargo.toml](../../../native/crypto_core/Cargo.toml)) into [third-party-notices.md](../../third-party-notices.md).
  - *F4 (historical):* Pre-existing formatting/web-literal issues noted at `3a8e90c5` (web target later removed under server ADR-0020).
- **Pre-existing caveat:** A `targetSdk` increase can alter platform job/FGS/notification rules without failing source-reading Kotlin tests, and a future AGP configuration rename requires updating the asserted configuration list.

## Costs

- `connectivity_plus` cannot receive bug fixes (such as 7.3.0's `safelyUnregisterNetworkCallback` guard) until `compileSdk` migrates to 36.1+.
- Maintaining custom Kotlin for `JobScheduler`, `SustainedDeliveryService`, `MessageAlertChannel`, settings intents, and 3-owner arbitration shifts annual Android OS rule tracking onto the project.
- Changing any dependency requires explicit updates across lockfiles, [dependency_policy_test.dart](../../../test/architecture/dependency_policy_test.dart), and [third-party-notices.md](../../third-party-notices.md).

## Reversal Trigger

Reopen `androidx.core` or `connectivity_plus` when `compileSdk` reaches 36.1+, when a needed Android API requires a newer `androidx.core`, or if a defect is found in `connectivity_plus` 6.0.5 (forcing replacement by a ~80-line `NetworkAvailabilityPort` adapter). Reopen `jni`/`jni_flutter` on F1 or `path_provider_android` changes. Reopen written Kotlin adapters on every `targetSdk` bump. Reopen notice delivery if distribution moves beyond private handover (requiring F2) or if external package fetching becomes impossible.

## History, Amendments, and Supersession

- **2026-08-24 (`3a8e90c5`):** Recorded ADR-054 (`Accepted`), superseding [ADR-007](007-flyer-timeline.md), removing 4 unused Dart packages, exact-pinning `pubspec.yaml`, replacing retracted `jni` 1.0.1, locking Android dependencies (`gradle.lockfile`), refusing `ProfileInstallReceiver`, declaring `ACCESS_NETWORK_STATE`, scanning `classes.dex`, and creating `docs/third-party-notices.md`.
- **2026-08-25 (ADR-059):** Added `emoji_picker_flutter: 4.5.3` (expanding release Android modules 51 → 91) and `kotlin.incremental=false`.
- **2026-08-30 (ADR-066):** Recorded the replacement of Flyer Chat with the app-owned sliver timeline, closing [ADR-007](007-flyer-timeline.md).
- **2026-09-13 (ADR-075):** Removed `beta` flavor Gradle configurations from `gradle.lockfile` and `dependency_policy_test.dart`.
- **2026-09-28 (ADR-078):** Added `flutter_webrtc: 1.6.2+hotfix.3`, scoped JitPack `exclusiveContent` for `audioswitch`, `MODIFY_AUDIO_SETTINGS`, and `BLUETOOTH` refusal (bringing release modules to 93).
