# ADR-059: Chat page emoji surface and `emoji_picker_flutter` adoption

- **Status:** Accepted
- **Date:** 2026-08-25 (explicitly recorded in register and full section; implemented in `c1ae5c8`)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-006](006-forui-boundary.md), [ADR-013](013-no-foreign-push.md), [ADR-016](016-english-and-persian.md), [ADR-054](054-dependency-policy.md), [ADR-057](057-measured-settings.md), [ADR-066](066-sliver-timeline.md)

## Decision (Position)

Replaced the chat page's hardcoded `👍` reaction and `🙂` composer insertion with a real emoji reactor and picker built on `emoji_picker_flutter` **4.5.3**, under the dependency rules of [ADR-054](054-dependency-policy.md):

1. **D1 — Exact pin forced by AGP 9 configuration ([pubspec.yaml](../../../pubspec.yaml), [dependency_policy_test.dart](../../../test/architecture/dependency_policy_test.dart)):**
   - Pinned `emoji_picker_flutter: 4.5.3` (published 2026-07-24; `sdk: ">=3.11.5 <4.0.0"`, `flutter: ">=3.41.8"`, resolving on Dart 3.12.2 / Flutter 3.44.7) in `pubspec.yaml` and the literal map in `dependency_policy_test.dart`.
   - Chosen because 4.5.0–4.5.2 moved to Flutter's built-in Kotlin and fail to configure when [gradle.properties](../../../android/gradle.properties) carries `android.builtInKotlin=false` alongside `com.android.application` 9.0.1 in [settings.gradle.kts](../../../android/settings.gradle.kts); 4.5.3 restores legacy Kotlin application conditionally. Pre-4.5.0 releases target Dart 3.4 and are superseded.
2. **D2 — Zero network surface and zero bundled assets:**
   - `emoji_picker_flutter`'s `pubspec.yaml` declares `plugin:` only (no `assets:` or `fonts:`); all emoji data are Dart string constants compiled into `libapp.so`.
   - `Config.emojiTextStyle` is left unset so glyphs draw with the device platform emoji font (Noto Color Emoji on Android).
   - `lib/` contains no HTTP/socket/image-URL surface; its sole Android `MethodChannel` call (`getSupportedEmojis`) uses `androidx.core.graphics.PaintCompat.hasGlyph` via `androidx.core` 1.16.0, already adopted in [ADR-054](054-dependency-policy.md).
3. **D3 — Enumerated transitive footprint ([gradle.lockfile](../../../android/app/gradle.lockfile), [third-party-notices.md](../../third-party-notices.md)):**
   - Added 7 new transitive Dart packages (`shared_preferences` 2.5.5 plus its 6 platform packages: `_android` 2.4.27, `_foundation` 2.5.6, `_linux` 2.4.1, `_platform_interface` 2.4.2, `_web` 2.4.3, `_windows` 2.4.1; `plugin_platform_interface` and `web` were already locked), with zero pre-release or retracted versions.
   - Added 46 Android module coordinates and replaced 6 (moving `releaseRuntimeClasspath` from 51 to 91 modules, 40 genuinely new): `shared_preferences_android` 2.4.27 pulls `androidx.datastore:datastore-preferences:1.1.7` (including `datastore-preferences-external-protobuf:1.1.7`, Google BSD 3-Clause protobuf-javalite repackaged under Apache-2.0) and `androidx.preference:preference:1.2.1` → `androidx.appcompat:appcompat:1.1.0` (2019) and legacy support-library modules; upgrades `androidx.customview` (1.0.0 → 1.1.0), `kotlin-stdlib-jdk7` (1.8.20 → 1.9.20), and `kotlinx-coroutines-*` (1.7.1 → 1.7.3). Recorded in `gradle.lockfile`, `dependency_policy_test.dart`, and `third-party-notices.md`.
4. **D4 — Disk persistence configured off ([app_emoji_picker.dart](../../../lib/app/design_system/app_emoji_picker.dart)):**
   - `AppEmojiPicker` sets `recentTabBehavior: RecentTabBehavior.NONE` and leaves `SkinToneConfig.rememberSkinTone` at `false`, leaving all four `SharedPreferences` call sites in `EmojiPickerInternalUtils`, `DefaultEmojiPickerView`, and `SearchView` unreachable for writes (`LegacySharedPreferencesPlugin` acquires a handle on attach but Android creates `FlutterSharedPreferences.xml` only on first `commit`).
   - Avoids writing a plaintext emoji-usage file outside [ADR-002](002-drift-source-of-truth.md)'s Keystore-wrapped SQLCipher boundary; compensates by offering a `const` strip of quick reactions one tap away on the message menu (single tap opens message menu + floating 24-reaction selector; double tap toggles `👍`; long-press removed; `SendConversationEvents.setReaction` in [conversation_use_cases.dart](../../../lib/features/messaging/application/conversation_use_cases.dart) enforces one grapheme cluster within the 64-byte / 64-scalar decoder bound).
5. **D5 — Single app-owned wrapper ([app_emoji_picker.dart](../../../lib/app/design_system/app_emoji_picker.dart), [design_system_boundary_test.dart](../../../test/architecture/design_system_boundary_test.dart)):**
   - `lib/app/design_system/app_emoji_picker.dart` is the sole file allowed to import `package:emoji_picker_flutter/` (matching [ADR-006](006-forui-boundary.md)), exposing `AppEmojiPicker` and `showAppEmojiPicker`.
   - Passes `emojiSet: (_) => picker.emojiSetEnglish` so tree-shaking drops eleven unused locale datasets (reclaiming 4,096,000 bytes without changing `en` or `fa` output, since `fa` already fell through to English).
6. **D6 — Non-incremental Kotlin compilation committed ([gradle.properties](../../../android/gradle.properties)):**
   - Added `kotlin.incremental=false` with inline rationale because `:shared_preferences_android:compileReleaseKotlin` failed 5/5 release builds on the workstation with Kotlin Build Tools API `Could not close incremental caches`.

## Rationale

- **Rejected alternatives:**
  - *A. In-house Unicode CLDR grid:* Avoids the 40 Android modules, but sourcing, localizing, skin-toning, and testing 1,500+ glyphs for an input control exceeded justified scope.
  - *B. Earlier `emoji_picker_flutter` releases:* Still depend on `shared_preferences`, while 4.5.0–4.5.2 break on `android.builtInKotlin=false`.
  - *C. Other pub.dev packages (`awesome_emoji_picker`, `emoji_mart_flutter`, forks):* Either still pull `SharedPreferences`, bundle remote/preset image sets (failing D2), or lack a verified maintained publisher.
  - *D. Keeping hardcoded `👍` and `🙂`:* Violated [ui-specification.md](../../ui-specification.md) §8 / §17 ("a control that presents itself as more than it is") when [MESSAGES.md](../../contracts/MESSAGES.md) already supports arbitrary normalized emoji graphemes.

## Constraints and Open Gates

- **Artifact verification:** Both new plugin manifests are empty; `tool/verify_release_apk.sh --production` passed all seven checks (same permissions and components as [ADR-054](054-dependency-policy.md); unsigned production APK; no beta MLS symbol). Opens no production gate and changes no cryptography, wire format, or delivery behavior.
- **Follow-ups recorded:**
  - **F1 (Persian search keywords):** Package ships no Persian emoji dataset; `fa` search falls back to English names. Adding a Persian `emojiSet` must move together with the `emojiSetEnglish` override in `AppEmojiPicker`.
  - **F2 (AGP 9 / built-in Kotlin warning):** `4.5.3` is the only release in its line building under `android.builtInKotlin=false`; future Flutter releases warn against plugins applying the legacy Kotlin Gradle Plugin.
  - **F3 (`appcompat` 1.1.0 watch):** Re-check on every `shared_preferences` update whether `androidx.preference` / `appcompat` drops out (~20 modules).
  - **F4 (Gradle `--write-locks` non-fixed-point):** `./gradlew :app:writeDependencyLocks --write-locks` resolves unconstrained and omitted `kotlin-stdlib-common:2.3.20` needed by constrained release builds; lock regeneration must be reconciled against an actual release build.

## Costs

- **APK size:** +1.57 MiB on an unsigned production release APK (86,760,406 → 88,410,103 bytes: +426 KiB Android tree, +1.16 MiB English emoji constants; saving 4,096,000 bytes vs. 92,506,103 bytes before pinning `emojiSetEnglish`).
- **Dependency surface:** +40 new Android modules (largely unreachable `appcompat` / `datastore` dependencies) and +7 transitive Dart packages.
- **Build & UX:** Non-incremental Kotlin compiles for the project's few Kotlin files; no recently-used emoji tab or remembered skin tone.

## Reversal Trigger

Reopen if `emoji_picker_flutter` adopts Flutter's built-in Kotlin (revisit `kotlin.incremental=false` and pin), if `shared_preferences_android` drops `androidx.preference` (F3), if a Persian keyword set is supplied (F1), or if the project replaces the package with a self-contained picker.

## History, Amendments, and Supersession

- **2026-08-25 (`c1ae5c8`):** Recorded and implemented ADR-059 (`Accepted`), adopting `emoji_picker_flutter` 4.5.3 behind `AppEmojiPicker`, disabling disk persistence, pinning Gradle/pubspec/notices, and setting `kotlin.incremental=false`.
