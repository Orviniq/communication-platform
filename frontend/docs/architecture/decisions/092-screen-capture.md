# ADR-092: Application-wide screen-capture protection via `FLAG_SECURE`

- **Status:** Accepted (2026-10-17)
- **Date:** 2026-10-17 (explicitly recorded in register and full section; implemented in `b4654d94` and documented in `fbc225d6`)
- **Amends:** [ADR-057](057-measured-settings.md) (widens `FLAG_SECURE` from recovery/enrollment screens only to the entire application window)
- **Related:** [ADR-049](049-background-catch-up.md), [ADR-057](057-measured-settings.md), [threat-model.md](../../threat-model.md), [ANDROID.md](../ANDROID.md)

## Decision (Position)

Following the 2026-10-17 field test, blocked screenshots, screen recording, unsecure casting, and recent-apps previews across the entire application in every build (preserving the register/section numbering D5–D6):

1. **D5 — `MainActivity` sets `FLAG_SECURE` before the first frame in every build ([MainActivity.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/MainActivity.kt)):**
   - `MainActivity.onCreate` calls `window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)` before `super.onCreate` in both development and production builds. Nothing in Kotlin calls `clearFlags` or clears `FLAG_SECURE` via `setFlags`.
2. **D6 — `SensitiveScreenControl` retains its API while `"off"` becomes a no-op ([sensitive_screen_control.dart](../../../lib/features/devices/presentation/sensitive_screen_control.dart)):**
   - Screens showing secrets (device enrollment and recovery secret replacement) continue calling `setEnabled(true)` / `setEnabled(false)` to mark sensitive boundaries in Dart, while the platform `setSensitiveScreen` handler always calls `window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)` regardless of `enabled` and never clears the flag.

## Rationale

- Previously `FLAG_SECURE` was set only while device enrollment or recovery secret replacement was open, leaving messages, contacts, safety numbers, and the recent-apps preview capturable.
- The owner rejected scoping capture blocking only to secret screens, only to production builds, or behind a user toggle.

## Constraints and Open Gates

- **Scope:** Changed `MainActivity.kt` (`onCreate` and `setSensitiveScreen`), plus [screen_capture_policy_test.dart](../../../test/architecture/screen_capture_policy_test.dart); changed no wire format, local table, protocol, dependency, Android permission, or `backend/` file.
- **What `FLAG_SECURE` does not cover:** Notification text (protected separately by sender-neutral private previews per [ADR-048](048-generic-notifications.md) and [threat-model.md](../../threat-model.md)), external cameras/shoulder surfing, external system windows (system photo/file pickers and camera app), rooted phones or user-granted accessibility services, and windowless headless background engines.
- **Verification:** Covered by source-level assertions in [screen_capture_policy_test.dart](../../../test/architecture/screen_capture_policy_test.dart) checking that `MainActivity.onCreate` adds `FLAG_SECURE` before `super.onCreate`, no `.kt` file clears it, and `setSensitiveScreen` keeps it on. Not yet verified by attempting a screenshot on a physical phone.

## Costs

- Nobody (testers or users) can take an in-app screenshot for bug reports in any build (must describe the screen or film with a second camera).
- Physical-device screenshot behavior was unverified at record close.

## Reversal Trigger

Reopen if development or debug builds ever require in-app screenshots for testing/bug reporting or if a user-controlled screen-security preference is introduced.

## History, Amendments, and Supersession

- **2026-10-17 (`b4654d94`, `fbc225d6`):** Implemented and accepted ADR-092 setting `FLAG_SECURE` unconditionally in `MainActivity.onCreate` and keeping it enabled across `setSensitiveScreen`.
