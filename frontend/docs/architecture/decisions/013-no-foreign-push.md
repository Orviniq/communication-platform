# ADR-013: No foreign push or telemetry

- **Status:** Accepted (reaffirmed by ADR-046 and ADR-054)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-014](014-foreground-connection.md), [ADR-029](029-background-polling.md), [ADR-033](033-android-release-target.md)

## Decision (Position)

The application MUST include **no foreign push service, no third-party telemetry/analytics, no CDN, no remote fonts, and no public connectivity probe** (such as Google/Firebase FCM, Crashlytics, UnifiedPush relays outside the self-hosted boundary, or external runtime calls).

1. All network traffic targets only the self-hosted provisioned backend and its co-located coturn relay (`POST /api/v1/me/relay`).
2. Fonts (`Vazirmatn-Variable.ttf`), icons (Forui-bundled Lucide), and cryptographic libraries are bundled locally inside the APK.

## Rationale

Required for reliable operation during international internet disconnection (domestic-only connectivity to the self-hosted deployment) and for metadata/privacy protection (`docs/security/SECURITY.md`, server ADR-0019).

## Constraints and Open Gates

- Enforced by [Frontend instructions](../../../AGENTS.md), [background_delivery_policy_test.dart](../../../test/architecture/background_delivery_policy_test.dart) (forbidding `firebase`, `unifiedpush`, `FirebaseMessaging`, and external `http://`/`https://`/`InetAddress` probes in background delivery), and [Visual design system](../../visual-design-system.md) (bundled `Vazirmatn v33.003`).
- Directly constrains Android background delivery (ADR-046, ADR-049, ADR-051, ADR-094): without FCM, background delivery uses `JobScheduler` plus an optional opt-in `specialUse` foreground service.
- Open gates: None.

## Costs

- Android cannot use FCM high-priority wakeups during Doze; background catch-up is best-effort/deferrable or requires an explicit opt-in foreground service with a persistent notification and battery cost (ADR-046, ADR-094).
- Crash/diagnostics reporting is strictly local and user-initiated (`DiagnosticsPage`, copied to clipboard rather than uploaded).

## Reversal Trigger

Would require an explicit security/product policy change abandoning domestic-only offline resilience and self-hosted isolation.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-08-21 (ADR-046) & 2026-08-24 (ADR-054):** Explicitly reaffirmed; UnifiedPush and FCM were re-evaluated and rejected under this constraint.
- No supersession.
