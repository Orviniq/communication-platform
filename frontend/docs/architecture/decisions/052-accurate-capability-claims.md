# ADR-052: Truthful capability claims, derived disclosure revisions, and durable re-acknowledgement

- **Status:** Accepted (disclosure scope and copy subsequently evolved through [ADR-055](055-initial-artifact.md), [ADR-056](056-abi-evidence.md), [ADR-071](071-published-limits.md), [ADR-075](075-pairwise-groups.md), [ADR-076](076-production-signing.md), [ADR-089](089-direct-attachments.md), [ADR-094](094-best-effort-delivery.md), and [ADR-098](098-presence-and-typing.md) to revision 11; `chatsListSearchScopeNotice` was later replaced by the dedicated `/chats/search` page under [ADR-087](087-chat-status.md); `SyncProjection.isSecurityBlocked` remains unconsumed in UI per [STATUS.md](../../STATUS.md#platform-identity-and-content) and [sync-engine.md](../../sync-engine.md#queue-gap-recovery))
- **Date:** 2026-08-23 (explicitly recorded in register and full section; committed in `a6106a8`)
- **Amends:** [ADR-045](045-maturity-disclosure.md) (completes device-side durable tracking and mechanical revision derivation; disclosure revision 4 → 5), [ADR-048](048-generic-notifications.md) (`settingsNotificationsOn`), and [ADR-049](049-background-catch-up.md) / [ADR-051](051-sustained-delivery.md) (delivery disclosure: Data Saver and server envelope expiry)
- **Related:** [ADR-016](016-english-and-persian.md), [ADR-017](017-independent-crypto-review.md), [ADR-045](045-maturity-disclosure.md), [ADR-048](048-generic-notifications.md), [ADR-049](049-background-catch-up.md), [ADR-051](051-sustained-delivery.md)

## Decision (Position)

Audited every user-facing security and capability statement directly against the composed Private Experimental artifact (not documentation or tests) and fixed both the false/overstated claims and the unenforced revision mechanism:

1. **Corrected four false claims and two overstatements in `app_en.arb` and `app_fa.arb`:**
   - **`settingsNotificationsOn` (false since [ADR-049](049-background-catch-up.md)):** Previously claimed alerts "can only reach you while this app is running", contradicting headless alert reconciliation in [deferred_delivery_catch_up.dart](../../../lib/app/dependencies/deferred_delivery_catch_up.dart) and [sustained_delivery_run.dart](../../../lib/app/dependencies/sustained_delivery_run.dart). Rewritten to state alerts can reach the user while closed when the phone next lets the app look for messages.
   - **`disclosureUnbuiltSurfaces` (partly false):** Removed "search" because chat-list title/preview filtering and full-history conversation search were both built.
   - **`enrollmentProtectsBody` (permanent section, misleading):** Promised "messages, files, and voice audio" were unreadable to the server when neither attachments nor voice existed. Rewritten structurally to describe the cryptographic boundary without naming any feature, enforced by a test in [deployment_disclosure_test.dart](../../../test/architecture/deployment_disclosure_test.dart) forbidding feature words so the permanent section cannot go stale.
   - **`chatsSearchHint` & `chatsListSearchScopeNotice` (over-promising):** Narrowed `chatsSearchHint` from "Search chats and messages on this device" to "Search names and the latest message" and added `chatsListSearchScopeNotice` pointing to in-conversation search *(later replaced when `/chats/search` landed under ADR-087)*.
   - **`disclosureBestEffortDelivery` (incomplete):** Added Data Saver on metered connections (`NETWORK_TYPE_ANY` jobs are blocked by Android Data Saver).
   - **`disclosureMessagesExpireUnread` (new `DisclosurePoint`):** Disclosed that undelivered messages expire on the server after an operator-set retention window (`ENVELOPE_TTL_DAYS`, default 7, without guessing an operator setting — later enhanced in ADR-071 to show the live number once `GET /api/v1/config` answers) and that the app will not name lost one-to-one messages (because `SyncProjection.isSecurityBlocked` has no UI consumer).
   - **`disclosureDeviceOnlyHistory` & `enrollmentDoesNotProtectBody`:** Narrowed "the server keeps no copy" to "no copy of your history" (mailbox holds ciphertext in transit) and replaced unexplained jargon ("social graph", "out of band", "compare fingerprints") with plain words pointing to the *Safety number* screen.
   - **Deleted `chatsPinViaMessageNotice`:** Removed an unused ARB key containing internal schema vocabulary.
2. **Mechanically derived `DeploymentDisclosure.revision` (4 → 5):**
   - Each `DisclosurePoint` in [deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart) carries `since` (the revision its wording or presence last changed).
   - [deployment_disclosure_test.dart](../../../test/architecture/deployment_disclosure_test.dart) asserts `DeploymentDisclosure.distributed.revision` equals `max(point.since)` and pins the exact English copy, so editing wording forces raising `since`, which forces raising `revision` (closing the gap where revisions 2, 3, and 4 shipped without device-side tracking).
3. **Durable device-side acknowledgement and one-time re-presentation gate ([DisclosureChangeGate](../../../lib/features/devices/presentation/disclosure_change_gate.dart)):**
   - Stores one bare integer (no timestamp, no identifier, never lowered) in SQLCipher-encrypted `local_preferences` (`DriftDisclosureAcknowledgementStore`), written on enrollment completion before the session opens.
   - Wraps the routed widget tree above `go_router` so deep links and notification taps cannot bypass it (never shown before enrollment completes, and never built into `development`).
   - Users with `acknowledgedRevision < revision` see one blocking full-screen `DisclosureChangePage` with changed points marked by a labelled badge (`disclosureChangedLabel`); users with no durable record (`0`, i.e. pre-ADR-052 installs) see the whole statement with nothing badged because nothing is known about what they previously read.
   - **Fail-open safety rule:** An unreadable preference row withholds the gate rather than locking the user out of messages; a failed write only costs one extra showing.
4. **Written handover & full-catalogue localization parity:**
   - Updated [deployment-and-release.md](../../deployment-and-release.md) to match `DisclosurePoint` (fixing the stale 6-of-7 list, missing unbuilt surfaces, and missing ADR-051 opt-in) while keeping written re-delivery release-blocking for recipients who have not updated.
   - Replaced three per-feature hand-maintained l10n key lists with catalogue-wide parity enforcement between `app_en.arb` and `app_fa.arb` (and checked overflow up to 160% text scale).

## Rationale

- **Empirical warning-habituation & usability research (read 2026-08-23):**
  - *Vance et al. (MIS Quarterly 2018):* Attention to repeated unchanged warnings declines rapidly across days, whereas polymorphic variation restores adherence.
  - *Vance et al. ("The Fog of Warnings", MIS Quarterly 2025):* Habituation to routine notifications *generalises* to security warnings never seen before — decisive here because [ADR-048](048-generic-notifications.md) and [ADR-051](051-sustained-delivery.md) emit message alerts and a persistent foreground-service notice. Delivering a disclosure correction as a banner or notification was therefore rejected in favor of a full blocking screen used nowhere else, with labelled badges on changed points.
  - *Böhme & Köpsell (CHI 2010):* EULA-style padding drives blind acceptance; non-safety items (e.g., `/settings/appearance` placeholder) were excluded from the disclosure list.
  - *WCAG 2.2 SC 3.1.5:* Targeted lower-secondary reading level (~9 years of schooling) without Android API level numbers.
- **Rejected alternatives:** Written handover alone (unenforced, already drifted, misses unreachable installs); timer-based re-consent; banners/notifications; unbadged full re-presentation; keeping historical diff strings in ARB files; server-side acceptance tracking (leaks timing/read metadata to untrusted relay); storing acceptance in `enrollment_intents` (deleted on completion); timestamped acceptance logs; hand-maintained revision constant; naming `ENVELOPE_TTL_DAYS` as "about a week" before runtime config existed; pruning feature lists in the permanent section.

## Constraints and Open Gates

- **Pinned invariants:** [deployment_disclosure_test.dart](../../../test/architecture/deployment_disclosure_test.dart) pins all `DisclosurePoint` orderings, `since` / `revision` invariants, forbidden feature words in `enrollmentProtectsBody`, and catalogue-wide `app_en.arb` / `app_fa.arb` parity.
- **Remaining limitations and open follow-ups:**
  - *One-to-one mailbox gap UI (Follow-up 1):* `SyncProjection.isSecurityBlocked` still has no UI consumer ([STATUS.md](../../STATUS.md#platform-identity-and-content), [sync-engine.md](../../sync-engine.md#queue-gap-recovery)); direct message expiration remains unannounced in-app.
  - *Persian comprehension & second-speaker review (Follow-up 2):* RTL layout, non-emptiness, and 160% scale non-overflow are tested, but neither second-speaker Persian review nor audience comprehension testing has been conducted.
  - *Device visual check (Follow-up 3):* `DisclosureChangeGate` is exercised in widget tests (`disclosure_change_gate_test.dart`), not yet photographed on physical hardware in both languages.
  - *Update reach:* Recipients who do not install the updated APK rely exclusively on out-of-band written handover re-delivery.

## Costs

- Every user-facing change to a `DisclosurePoint` forces a `since` and `revision` increment, triggers a one-time full-screen re-acknowledgement for existing installs on upgrade, and makes written handover re-delivery release-blocking ([STATUS.md](../../STATUS.md#artifact-and-release-acceptance)).
- Strict catalogue-wide ARB parity blocks adding English-only strings before Persian translation.

## Reversal Trigger

Reopen whenever any `DisclosurePoint` wording changes, when unbuilt surfaces ship or change (attachments, voice, profiles), when [ADR-017](017-independent-crypto-review.md) closes (making `disclosureNoIndependentReview` false), if `ENVELOPE_TTL_DAYS` changes materially, or if distribution expands beyond small private handover where out-of-band written re-delivery stops scaling.

## History, Amendments, and Supersession

- **2026-08-23 (`a6106a8`):** Recorded ADR-052 (`Accepted`), correcting four false claims and two overstatements, banning feature words in `enrollmentProtectsBody`, deriving `DeploymentDisclosure.revision` (4 → 5), and adding `DisclosureChangeGate` + `DriftDisclosureAcknowledgementStore`.
- **2026-08-24 – 2026-10-19 (ADR-055, ADR-056, ADR-071, ADR-075, ADR-076, ADR-087, ADR-089, ADR-094, ADR-098):** Evolved `DisclosurePoint`s and copy to revision 11 (runtime `envelope_ttl_days` from `/api/v1/config` in ADR-071, pairwise groups & production disclosure in ADR-075/ADR-076, `/chats/search` in ADR-087, direct attachments in ADR-089, `bestEffort` sustained offer in ADR-094, and `onlineStatus` in ADR-098).
