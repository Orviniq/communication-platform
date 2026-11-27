# ADR-055: Direct-messaging-only initial artifact and hardware-execution gate for beta PQ MLS

- **Status:** Closed by ADR-075 (2026-09-13); previously amended the same day by [ADR-056](056-abi-evidence.md) (2026-08-24)
- **Date:** 2026-08-24 (explicitly recorded in register and full section; implemented in `80c19481`; amended by [ADR-056](056-abi-evidence.md) on 2026-08-24; closed `2026-09-13`)
- **Amends:** [ADR-044](044-private-deployment.md) Tier 2 (moves closed-beta PQ MLS groups from exposed Experimental to withheld behind a hardware-execution ledger) and [ADR-045](045-maturity-disclosure.md) / [ADR-052](052-accurate-capability-claims.md) (`DeploymentDisclosure` revision 5 → 6)
- **Closed by:** ADR-075 (2026-09-13), following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- **Related:** [ADR-017](017-independent-crypto-review.md), [ADR-032](032-rust-ffi.md), [ADR-036](036-beta-mls-track.md), [ADR-037](037-control-transcript.md), [ADR-039](039-two-phase-leave.md), [ADR-040](040-beta-kem-divergence.md), [ADR-041](041-fork-ordering.md), [ADR-044](044-private-deployment.md), [ADR-053](053-field-evidence-gate.md), [ADR-056](056-abi-evidence.md)

## Decision (Position)

Decided that the first externally distributed Private Experimental artifact exposes **direct messaging only**, withholding closed-beta PQ MLS group messaging in substance behind a source-only hardware-execution evidence ledger until the packaged native core has been observed executing on real ARM hardware:

1. **D1 — Direct-messaging-only initial exposure:** Retained [ADR-044](044-private-deployment.md)'s Supported tier (registration, enrollment, cross-signing, verification, device log, recovery, contacts/profiles, hybrid PQXDH + Double Ratchet direct messages, Saved Messages, linked devices, history transfer, and durable inbox/outbox) unchanged.
2. **D2 — Group messaging withheld in substance, not merely hidden:**
   - With `GroupExperimentalGate` closed, the beta artifact composed `UnsupportedGroupMlsCrypto` (failing closed on all nine port methods), threw from `groupKeyPackageMaintenanceServiceProvider` so **zero KeyPackages were generated or uploaded**, omitted KeyPackage post-inbox maintenance from `DurableSyncEngine`, refused inbound group objects in `GroupMlsInboundCoordinator`, rendered the closed gate on all five routed group screens, and disabled/labelled the Contacts group entry point.
   - Fixed a screen-bypass defect in historical `CreateGroupPage`, `GroupChatPage`, and `GroupInfoPage` (`group_pages.dart`, later split) where injected-collaborator checks ran before the availability gate.
3. **D3 — Source-only evidence ledger (`GroupExperimentalGate` in historical `lib/app/config/group_production_gate.dart`):**
   - Replaced `GroupProductionGate.privateExperimentalPermit`'s environment-only check with `environment == beta && ledger.isOpen`, backed by an empty `List<GroupMlsFieldEvidence>` with zero build defines, remote flags, runtime setters, or debug overrides.
   - Required an admissible record (`isAdmissible`: `emulated == false`, strict `YYYY-MM-DD` date surviving round-trip, committed run record path, and every round-trip operation exercised) for every mandatory ABI (`arm64-v8a` and `armeabi-v7a` under ADR-055's original all-or-nothing framing, before [ADR-056](056-abi-evidence.md) changed the gate to per-ABI).
   - Preserved the Beta/Production boundary: a test asserted that even a fully satisfied ledger still left `production` with no permit and `UnsupportedGroupMlsCrypto`.
4. **D4 — Standalone device measurement instrument (historical `tool/measure_beta_mls_core.sh`):**
   - Cross-compiled `--features beta-pq-mls` tests for a target Android ABI with the pinned toolchain, ran them on a connected device via `adb` with no APK install, backend, account, or root, and wrote machine-readable run records under historical `docs/validation/beta-mls-core/` (now archived under [archive/beta-mls-core/](../../archive/beta-mls-core/README.md)).
5. **D5 — Disclosure revision 5 → 6 ([deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart)):**
   - Updated the groups `DisclosurePoint` from describing experimental group encryption/resets to stating that group chats were switched off and why (`since: 6`, triggering one-time re-presentation via `DisclosureChangeGate`).

**Amendment and Closure:** Later the same day ([ADR-056](056-abi-evidence.md), 2026-08-24), `arm64-v8a` passed on hardware and the gate shifted from all-or-nothing to per-ABI (`arm64-v8a` open, `armeabi-v7a`/`x86_64` withheld). On 2026-09-13, ADR-075 closed the entire closed-beta MLS track following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md), deleting the `beta` flavor, `beta-pq-mls` Cargo profile, `GroupProductionGate`, `GroupExperimentalGate`, and `measure_beta_mls_core.sh`; groups now ship on pairwise Double Ratchet fan-out ([cryptographic-protocol.md](../../cryptographic-protocol.md#groups)).

## Rationale

- **Zero ARM execution of `aws-lc-sys`:** While the `foundation` profile (pure Rust + libsodium) had run on an Android device, the `beta` profile's C and assembly (`aws-lc-sys` 0.40.0 + `mls-rs` 0.55.2 via `cp_crypto_v1_beta_mls_operation`) had **never executed a single instruction on ARM** — Dart tests stubbed `BetaMlsNativeApi`, `integration_test/crypto_core_android_smoke_test.dart` tested only the 15 foundation symbols, and `catch_unwind` at the C ABI cannot contain a fault below Rust (which would crash the direct-message tier too).
- **Three decisive asymmetries:**
  1. *Execution gap:* First ARM execution of `aws-lc-sys` would have occurred in recipients' hands.
  2. *Failure cost under 7-day pruning (`ENVELOPE_TTL_DAYS = 7` in `backend/config/settings/base.py:154`):* Double Ratchet retains `MAX_SKIPPED_PER_SESSION = 2_000` keys and survives individual pruned messages, whereas a pruned MLS Commit forces `queueGapRejoinRequired` (`CLIENT_CONTRACT.md` §H), unrecoverable without an owner/admin removing and re-adding the member.
  3. *Third-party failure blast radius:* A device with a faulty ABI core would still upload KeyPackages, causing peers to add it and carry a non-converging member whose failure signature is silent absence on someone else's phone.
- **Reversibility & re-testing [ADR-044](044-private-deployment.md) Alternative E:** Exposing groups scheduled future data loss ([ADR-036](036-beta-mls-track.md)), whereas withholding was free to reverse. Unlike unwiring [ADR-036](036-beta-mls-track.md)–[ADR-041](041-fork-ordering.md) (rejected Alternative C), gating preserved the tested stack; and [ADR-044](044-private-deployment.md)'s premise that evidence required users was false because *core correctness on target CPU* needed one phone and zero users/backend.
- **External research (2026-08-24) did not override repository evidence:** `aws-lc-sys` 0.40.0 was patched against RUSTSEC-2026-0044..-0048, `mls-rs` 0.55.2 was unaffected by the `mls-rs-crypto-rustcrypto` fix in 0.55.4, `aws-lc` listed Android `aarch64` as supported (and `arm32` under *Other platforms*), `TBD2` remained unassigned at `draft-06`, and Android developer verification enforcement (from 2026-09-30 in 4 countries, global 2027+, with 20-device limited distribution) posed no immediate block ([ADR-044](044-private-deployment.md) revisit condition 6 discharged). Nevertheless, vendor intent is not an observation of this build on hardware ([ADR-053](053-field-evidence-gate.md)).

## Constraints and Open Gates

- **Closed:** `lib/app/config/group_production_gate.dart`, `tool/measure_beta_mls_core.sh`, `NativeBetaGroupMls`, and `docs/mls-profile.md` were deleted in ADR-075 (`cd36012f` / `e802cf0e` / `92211fa2` / `4525d3f0`). Historical snapshots exist at commit `80c19481` (ADR-055) and `788453b430f34c52c2063ef67b8aa5e4f8fa935d`.
- **Preserved evidence:** The subsequent `arm64-v8a` run record produced under this instrument is archived at [archive/beta-mls-core/README.md](../../archive/beta-mls-core/README.md).
- **Still open across current system:** [ADR-017](017-independent-crypto-review.md) (independent review) and [ADR-052](052-accurate-capability-claims.md)'s unconsumed `SyncProjection.isSecurityBlocked` gap remain open ([STATUS.md](../../STATUS.md)).

## Costs

- While closed, recipients went without group messaging even if the packaged core was sound, and `armeabi-v7a` risked becoming a permanent gate block until [ADR-056](056-abi-evidence.md) moved the gate per-ABI.
- Measuring core arithmetic alone left multi-device live-backend execution, Doze, force-stop, torn writes, and Keystore-after-reboot unmeasured.

## Reversal Trigger

Original triggers: open when all mandatory ABIs had admissible records, re-scope if `armeabi-v7a` proved unobtainable or if no run occurred by the second external build, or halt on any core test failure.

Current state: amended within hours by [ADR-056](056-abi-evidence.md) (2026-08-24) and permanently closed by ADR-075 (2026-09-13).

## History, Amendments, and Supersession

- **2026-08-24 (`80c19481`):** Recorded ADR-055 (`Accepted`), adding `GroupExperimentalGate`, `tool/measure_beta_mls_core.sh`, screen-gate ordering fixes, and `DeploymentDisclosure` revision 6.
- **2026-08-24 ([ADR-056](056-abi-evidence.md)):** Measured `arm64-v8a` on a Samsung Galaxy A56, changing `GroupExperimentalGate` from per-artifact to per-ABI (`arm64-v8a` open, `armeabi-v7a` and `x86_64` withheld) and moving disclosure to revision 7.
- **2026-09-13 (ADR-075):** Closed and deleted closed-beta MLS and the `beta` flavor in favor of pairwise Double Ratchet groups.
