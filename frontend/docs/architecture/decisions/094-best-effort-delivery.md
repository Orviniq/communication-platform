# ADR-094: Offer receiving while closed in production as best effort

- **Status:** Accepted (2026-10-18); proposed 2026-10-17; supersedes [ADR-053](053-field-evidence-gate.md) for the `production` flavor only
- **Date:** 2026-10-17 proposed, 2026-10-18 accepted (explicitly recorded in register and full section; implemented in `6f3b5516` and documented in `8e4a6ee3` on `frontend-offer-receiving-while-closed`, PR #86 `4091856e`)
- **Supersedes in part:** [ADR-053](053-field-evidence-gate.md) (supersedes `production` withholding while keeping [ADR-053](053-field-evidence-gate.md) intact for its historical record and for the `development` flavor)
- **Related:** [ADR-045](045-maturity-disclosure.md), [ADR-051](051-sustained-delivery.md), [ADR-052](052-accurate-capability-claims.md), [ADR-053](053-field-evidence-gate.md), [ADR-076](076-production-signing.md), [ADR-089](089-direct-attachments.md), [ADR-098](098-presence-and-typing.md), [SUSTAINED-DELIVERY.md](../../runbooks/SUSTAINED-DELIVERY.md), [ANDROID.md](../ANDROID.md), [RELEASE.md](../../runbooks/RELEASE.md)

## Decision (Position)

Enabled the opt-in "Receiving while closed" (`specialUse` foreground service) toggle in `production` builds as an unmeasured best-effort capability with explicit disclosure of untested device behavior and zero delivery-time guarantees:

1. **D1 — Best-effort production availability ([sustained_delivery_gate.dart](../../../lib/app/config/sustained_delivery_gate.dart)):**
   - `SustainedDeliveryGate.availabilityIn(AppEnvironment.production)` returns `SustainedDeliveryAvailability.bestEffort` while the compiled evidence ledger (`SustainedDeliveryGate.releaseAssertion`) is incomplete, `measurementOnly` for `development`, and `evidenced` once the ledger is complete.
   - Because every availability now offers the switch in Settings and on the Sustained Delivery page, deleted `SustainedDeliveryAvailability.withheld`, `mayOffer`, `SustainedDeliveryStatus.withheld`, `SustainedDeliveryRefusal.withheld`, the withheld branch/stand-down of an earlier install's service, and strings `settingsSustainedWithheld`, `sustainedStatusWithheld`, and `sustainedRefusedWithheld`. The controller still stops the service whenever no user is signed in.
2. **D2 — Preserve the seven-cell field-evidence ledger and admissibility rules:**
   - Kept the seven mandatory matrix cells (Samsung Android 11–12, 13, 14+; Xiaomi Android 11–12, 13, 14+; platform reference), `SustainedDeliveryFieldEvidence.isAdmissible` (non-emulated, strict ISO date, committed run record, ≥ 24 holding hours, ≥ 20 timed deliveries, ≥ 3 repetitions), and `evidenced` promotion path in [SUSTAINED-DELIVERY.md](../../runbooks/SUSTAINED-DELIVERY.md).
3. **D3 — No delivery-time claim:**
   - Retains `"How quickly it does on your phone has not been measured"` on the Sustained Delivery page; architecture/policy tests fail if copy claims `"within seconds"` or `"instantly"`.
4. **D4 — Deployment disclosure revision 10 ([deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart)):**
   - Updated `DisclosurePoint.bestEffortDelivery` (`since: 10`) to offer the Settings switch with its battery cost and permanent notification, state that it has not been tested on phones like the reader's and that some phones stop it silently, and retain `"Nothing about any of this is guaranteed"`.
   - Updated `DisclosurePoint.unbuiltSurfaces` (`since: 10`) to match shipped reality (removing voice rooms and direct attachments, leaving group file sending and unpublished display name/photo).
   - Bumped `DeploymentDisclosure.distributed.revision` to `10` (later raised to `11` by [ADR-098](098-presence-and-typing.md)), triggering one-time re-acknowledgement for revision-8 and revision-9 readers; Persian wording flagged for owner review.
5. **D5 — Scoped supersession of [ADR-053](053-field-evidence-gate.md):**
   - Supersedes [ADR-053](053-field-evidence-gate.md) for `production` only; `development` remains `measurementOnly` and [ADR-053](053-field-evidence-gate.md)'s matrix/admissibility design remains the gate to `evidenced`.

## Rationale

- Following the 2026-10-17 field test, the owner requested offering "Receiving while closed" in signed `production` builds ([ADR-076](076-production-signing.md)) while the seven Samsung/Xiaomi matrix cells remained unmeasurable without that hardware fleet (only one Samsung Galaxy A56 had been probed).
- Keeping the switch withheld gave Samsung/Xiaomi users no opt-in option at all; offering it without disclosing the missing measurements would reintroduce the false assurance [ADR-053](053-field-evidence-gate.md) removed; forking the Android manifest per flavor (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, and `SustainedDeliveryService` are already in `android/app/src/main/AndroidManifest.xml`) would make the distributed binary diverge from the measured binary.

## Constraints and Open Gates

- **Scope:** Changed `SustainedDeliveryGate`, sustained-delivery controller/status/refusal types, Settings/page presentation, `DeploymentDisclosure` points and localized strings (`app_en.arb`, `app_fa.arb`); changed no Kotlin, manifest, wire format, schema, dependency, cryptographic construction, or `backend/` file.
- **Verification:** Covered by host and widget tests including [sustained_delivery_gate_test.dart](../../../test/architecture/sustained_delivery_gate_test.dart) verifying `bestEffort` vs `evidenced` vs `measurementOnly`, revision 10 text and re-presentation for revision 8/9 readers, and production switch visibility.
- **Left open:** No physical-device run of sustained delivery in a signed production build; the seven-cell validation matrix in [SUSTAINED-DELIVERY.md](../../runbooks/SUSTAINED-DELIVERY.md) remains empty (`SustainedDeliveryGate.releaseAssertion`).

## Costs

- Re-accepts the silent-termination risk identified in [ADR-053](053-field-evidence-gate.md): Samsung or Xiaomi OS policies may kill the process without warning, leaving a user who enabled the opt-in toggle thinking closed-app messages will arrive reliably when they do not. Mitigated solely by keeping the switch off by default, offering vendor setup without claiming confirmation, and stating the unmeasured status in both the page and disclosure.

## Reversal Trigger

Reopen once all seven mandatory hardware cells in [SUSTAINED-DELIVERY.md](../../runbooks/SUSTAINED-DELIVERY.md) hold admissible records (advancing `availabilityIn(production)` from `bestEffort` to `evidenced` and updating the disclosure), or if production must withdraw the capability again.

## History, Amendments, and Supersession

- **2026-10-17 – 2026-10-18 (`6f3b5516`, `8e4a6ee3`, PR #86 `4091856e`):** Proposed and accepted ADR-094, superseding [ADR-053](053-field-evidence-gate.md) for `production` only, introducing `bestEffort`, deleting `withheld` states/strings, and updating `DeploymentDisclosure` to revision 10.
- **2026-10-19 ([ADR-098](098-presence-and-typing.md)):** Raised `DeploymentDisclosure.distributed.revision` from `10` to `11` for `onlineStatus`.
