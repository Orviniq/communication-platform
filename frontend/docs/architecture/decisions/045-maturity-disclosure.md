# ADR-045: User-facing maturity vocabulary and mandatory first-run disclosure

- **Status:** Accepted (disclosure mechanism completed by [ADR-052](052-accurate-capability-claims.md) on 2026-08-23; content and scope evolved through [ADR-048](048-generic-notifications.md), [ADR-049](049-background-catch-up.md), [ADR-051](051-sustained-delivery.md), [ADR-052](052-accurate-capability-claims.md), [ADR-055](055-initial-artifact.md), [ADR-056](056-abi-evidence.md), [ADR-071](071-published-limits.md), [ADR-075](075-pairwise-groups.md), [ADR-076](076-production-signing.md), [ADR-089](089-direct-attachments.md), [ADR-094](094-best-effort-delivery.md), and [ADR-098](098-presence-and-typing.md) to revision 11; D1/D6 amended for `production` by [ADR-076](076-production-signing.md) on 2026-09-14)
- **Date:** 2026-08-20 (explicitly recorded in register and full section; committed in `e28ab69e`)
- **Amends:** [ADR-044](044-private-deployment.md) (removes attachments and encrypted profiles from D2's Supported tier; discharges D4 in-app disclosure follow-up and revisit condition 6 primary-source verification)
- **Related:** [ADR-016](016-english-and-persian.md), [ADR-017](017-independent-crypto-review.md), [ADR-028](028-device-history-transfer.md), [ADR-030](030-recovery-key-material.md), [ADR-036](036-beta-mls-track.md), [ADR-044](044-private-deployment.md)

## Decision (Position)

Established what the distributed application says to users about its maturity, how it says it, and when acknowledgement is required:

1. **D1 — One application-level maturity designation (`Experimental`) for the private build:**
   - Carried consistently by the environment banner, Android launcher label, and task-switcher title (`AppEnvironmentBanner`, switching exhaustively over `AppEnvironment` without an `isProduction` shortcut that previously misnamed Beta as "Development").
   - *Amended by ADR-076 (2026-09-14):* When `production` became the distributed testing artifact, Production kept the deployment disclosure (`DeploymentDisclosure.distributed`) without an Experimental designation on the launcher label, banner, or title.
2. **D2 — Exactly two feature-level downgrade labels (`SurfaceMaturity`):**
   - `experimental` ("Experimental": transmits and encrypts using a maintained implementation, unreviewed/non-standard, disposable state) and `notBuilt` ("Not built yet": routed and visible surface with no live implementation behind it).
   - **No third label** and no badge meaning "supported", "stable", "verified", or "audited": the absence of a badge must never read as a safety assurance. Asserted in [deployment_disclosure_test.dart](../../../test/architecture/deployment_disclosure_test.dart).
   - Corrected [ADR-044](044-private-deployment.md) D2 Supported tier: removed encrypted profiles (`ProfileProtectionPort` / `ProfileKeyDistributionPort` resolved to `Unsupported*` outside development) and attachments (`AttachmentTransferService` was uncomposed and `AttachmentSheet` tiles were inert), relabelling both **Not built yet** (direct/Saved attachments were later built by ADR-089).
   - Fixed pre-existing UI misstatements: removed the permanent "Structural placeholder — not for shipping" navigation-rail footer from all builds, fixed double-encoded ellipses on the Connection screen, and localized Settings with a re-viewable security notice matching `ui-specification.md` §15.
3. **D3 — Four distinct disclosure placements, with no repetition for emphasis:**
   - *Continuous, low salience:* `AppEnvironmentBanner` (identity only, not an alarm).
   - *Once, high salience, blocking:* deployment disclosure inside `EnrollmentPhase.securityNotice`.
   - *Contextual, persistent, per surface:* group maturity banner, not-built placeholders, profile notice, attachment sheet.
   - *On demand, always:* Settings → "Security & how this app protects you" and pre-login notice links, rendering the same notice.
4. **D4 — Content-triggered mandatory acknowledgement inside the existing enrollment gate:**
   - Reused `EnrollmentPhase.securityNotice` (already mandatory, durable in the enrollment journal, blocking messaging until "I understand") rather than adding a second blocking consent screen.
   - Rejected periodic/timer-based re-acknowledgement on warning-habituation evidence; made re-consent content-triggered via `DeploymentDisclosure.revision` pinned by test to the exact English text.
   - *Completed by ADR-052 (2026-08-23):* Derived `DeploymentDisclosure.revision` mechanically from per-point `since` revisions and added durable device-side tracking (`DisclosureChangeGate`) so existing installs re-present moved points once.
5. **D5 — Consequence-focused `DisclosurePoint` content (originally 7 points, revision 1):**
   - Covered only facts contradicting ordinary expectations: no independent review, foreground-only delivery, device-only history, recovery excludes history, disposable experimental groups, unbuilt surfaces, and intended private-evaluation use.
   - Deliberately excluded cryptographic identifiers (`0xFE4C`, `TBD2`, `withTrustedRoots: false`, etc.) so technical detail would not bury user-facing consequences.
   - *Evolved in subsequent ADRs ([deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart)):* revised across [ADR-048](048-generic-notifications.md) (rev 2), ADR-049 (rev 3), ADR-051 (rev 4), ADR-052 (rev 5), ADR-055 (rev 6), ADR-056 (rev 7), ADR-071 (rev 8), ADR-075 & ADR-076 (rev 9, renaming `experimentalGroups` to `pairwiseGroups` and switching `AppDeploymentDisclosure` to `AppEnvironment.production`), ADR-089 & ADR-094 (rev 10), and ADR-098 (rev 11).
6. **D6 — Single notice widget (`SecurityNoticeSections`):**
   - One title and body rendered by [SecurityNoticeSections](../../../lib/features/devices/presentation/security_notice_sections.dart): permanent security boundary plus build-specific deployment disclosure (`null` in `development`; since ADR-076 carried by `production`).
7. **Out-of-band written handover preserved:** Retained [ADR-044](044-private-deployment.md)'s release-blocking written handover alongside in-app disclosure.
8. **Discharged [ADR-044](044-private-deployment.md) revisit condition 6 primary-source check:** Recorded Google's Android developer-verification docs (read 2026-08-20: enforcement starting 2026-09-30 in BR/ID/SG/TH, global 2027, 20-device free limited-distribution cap vs. 20–30 target users).

## Rationale

- Inspecting the live UI revealed four conflicting vocabularies and two false claims (task title calling Beta "Development"; rail footer claiming "not for shipping" in production; Edit Profile claiming a fake transport where Save failed; inert attachment sheet; mismatched pre-login vs. enrollment notices).
- Google's published launch-stage definition of **Experimental** (read 2026-08-20: prototype feedback, no SLA/support/deprecation policy, subject to backward-incompatible changes) matched the artifact, whereas **Preview**, **Beta**, **Alpha**, **Development**, and **Stable** made false promises.
- Using one existing mandatory gate avoided attention-splitting across two consecutive blocking screens (Akhawe & Felt, *USENIX Security* 2013), and avoiding periodic re-prompts prevented warning habituation (Kirwan et al., *Frontiers in Psychology* 2020; reinforced by Vance et al. 2018/2025 in ADR-052) that would degrade blocking security warnings (unverified identity, unsigned device, changed master key, queue-gap rejoin).
- Enforcing `SurfaceMaturity` and `DisclosurePoint` via architecture tests ([deployment_disclosure_test.dart](../../../test/architecture/deployment_disclosure_test.dart)) prevents stale or unlocalized maturity claims.

## Constraints and Open Gates

- [deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart) owns `SurfaceMaturity`, `DisclosurePoint`, and `DeploymentDisclosure.distributed` (currently revision 11 for `production`, `null` for `development`).
- Whenever `DeploymentDisclosure.revision` increases, re-delivering the written handover disclosure to existing recipients remains a release-blocking checklist item ([STATUS.md](../../STATUS.md#artifact-and-release-acceptance), [deployment-and-release.md](../../deployment-and-release.md)).
- `AppEnvironmentBanner` (`lib/app/config/app_environment_banner.dart`) and `AppEnvironment` (`lib/app/config/app_environment.dart`) switch exhaustively over environments so no build inherits another's title or banner.

## Costs

- Bilingual English and Persian parity must be maintained across every `DisclosurePoint` and `SurfaceMaturity` label ([ADR-016](016-english-and-persian.md)).
- Every feature maturity transition requires updating `deployment_disclosure.dart` and raising the relevant point's `since` revision (and delivering updated written handover for distributed builds).

## Reversal Trigger

Reopen whenever a surface changes tier (becomes built or stops working), a new user-facing security/maturity claim appears outside `SurfaceMaturity`/`DisclosurePoint`, `DeploymentDisclosure.revision` changes, or the distribution model changes from named private handover.

## History, Amendments, and Supersession

- **2026-08-20 (`e28ab69e`):** Recorded ADR-045 (`Accepted`), defining `SurfaceMaturity`, `DisclosurePoint` (revision 1), `SecurityNoticeSections`, and amending [ADR-044](044-private-deployment.md).
- **2026-08-21 – 2026-08-22 ([ADR-048](048-generic-notifications.md), ADR-049, ADR-051):** Bumped disclosure revision 1 → 2 → 3 → 4 as alerts, deferred catch-up, and sustained delivery landed.
- **2026-08-23 (ADR-052):** Corrected four false/overstated strings, prohibited feature names in the permanent notice, made `revision` mechanically derived from `since`, and added durable `DisclosureChangeGate` re-presentation (rev 5).
- **2026-08-24 – 2026-10-19 (ADR-055, ADR-056, ADR-071, ADR-075, ADR-076, ADR-089, ADR-094, ADR-098):** Amended disclosure scope and points up to revision 11; ADR-076 moved `DeploymentDisclosure.distributed` onto `production` without the Experimental designation.
