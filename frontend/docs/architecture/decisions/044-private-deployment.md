# ADR-044: Initial Private Experimental Android deployment and declared maturity tiers

- **Status:** Closed by ADR-075 (2026-09-13); previously amended by ADR-045 (2026-08-20), ADR-055 (2026-08-24), ADR-056 (2026-08-24), ADR-057 (2026-08-25), ADR-058 (2026-08-25), and ADR-067 (2026-09-07)
- **Date:** 2026-08-20 (explicitly recorded in register and full section; committed in `d139ca3f`; closed `2026-09-13`)
- **Closed by:** ADR-075 (2026-09-13), following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)
- **Related:** [ADR-017](017-independent-crypto-review.md), [ADR-026](026-candidate-mls-suite.md), [ADR-033](033-android-release-target.md), [ADR-036](036-beta-mls-track.md), [ADR-040](040-beta-kem-divergence.md), [ADR-042](042-beta-signing.md), [ADR-043](043-private-ca-transport.md), [ADR-045](045-maturity-disclosure.md)

## Decision (Position)

Originally defined the initial ~20–30 person private deployment as **one Private Experimental Android artifact** distributed privately under the frozen Beta identity while keeping Production unsigned and uninstallable:

1. **D1 — Private Experimental deployment:** Distributed as a direct signed APK (with SHA-256 and metadata file) under the `.beta` application ID (`dev.nimashadloo.chat.beta`, later `com.orviniq.chat.beta` per ADR-067) against one private origin (`BETA_*`). User-facing strings must say **Experimental** (never "Beta", "preview", "production", "release", "stable", or "1.0").
2. **D2 — Three declared maturity tiers in one artifact:**
   - **Supported** (expected state durability, *not* audited): registration, login, two-phase device enrollment, cross-signing, SAS/QR verification, signed device log, recovery secret, contacts/encrypted profiles *(removed by ADR-045)*, hybrid PQXDH + Double Ratchet direct messages, application-event protocol, Saved Messages, attachments *(removed by ADR-045)*, linked devices, device-to-device history transfer, durable inbox/outbox.
   - **Experimental:** closed-beta PQ MLS groups (`0xFE4C`, disposable state under [ADR-036](036-beta-mls-track.md), non-conformant with `TBD2` under [ADR-040](040-beta-kem-divergence.md)).
   - **Absent:** voice rooms, local search *(later built; ADR-052/ADR-057)*, notifications *(later built; [ADR-048](048-generic-notifications.md))*, background delivery *(later built; ADR-049/ADR-051)*, appearance settings *(later built; ADR-057)*.
3. **D3 — Single source-only group boundary and verified build-time separation:** Fixed the defect where `groupFeatureAvailabilityProvider` checked `developmentPreviewPermit` (`!kReleaseMode && development`) and closed every group screen in the release Beta build while the same build still composed `NativeBetaGroupMls` and uploaded MLS KeyPackages. Replaced with one `GroupProductionGate.privateExperimentalPermit` governing both composition and screens (`isAvailable`). Preserved three flavors, separate application IDs, two Cargo profiles (`foundation` vs. `beta` with `--features beta-pq-mls` verified by `tool/build_rust_android.sh` and `tool/verify_release_apk.sh --production`), and `signingConfig = null` on release (keeping Production uninstallable).
4. **User disclosure and mandatory security invariants:** Required persistent `AppEnvironmentBanner` ("Private experimental build"), per-tier group maturity banner (`_GroupMaturityBanner`), visibly absent placeholder pages (`StructuralPlaceholderPage`), and mandatory written handover disclosure covering unreviewed crypto, foreground-only delivery, disposable groups, device-only history, recovery excluding history, and trusted-evaluator-only use, while forbidding false claims about Android's network security config ([ADR-043](043-private-ca-transport.md)). Kept untrusted-relay client verification, no crypto in Dart, mandatory hybrid PQXDH, device cross-signing, private-CA TLS, Keystore-wrapped SQLCipher with `allowBackup="false"`, and log redaction mandatory.
5. **Piece 19 & Piece 20 framing:** Reclassified Piece 19's closed-beta half as delivered in the experimental tier while keeping its production gates blocked on external prerequisites. Re-scoped Piece 20 from "after every production gate" (unreachable) to requiring an explicit decision on which MLS exporter may key real-time media (granting neither path here).
6. **Irreversible decisions and graduation path:** Recorded permanence of the Beta application ID/signing key, unrecoverable single-device history loss, scheduled destruction of experimental group state, private-CA trust lock-in, and non-anonymous private distribution; required Beta and Production to remain separate apps with no upgrade or state migration path.

**Amendments prior to closure:**
- **ADR-045 (2026-08-20):** Removed "attachments" and "encrypted profiles" from D2's Supported tier (both absent/failing closed in Beta) and implemented the in-app first-run disclosure.
- **ADR-055 (2026-08-24) & ADR-056 (2026-08-24):** Withheld Tier 2 groups behind a hardware-execution evidence ledger, then opened them per-ABI (`arm64-v8a` open; `armeabi-v7a` and `x86_64` withheld).
- **ADR-057 (2026-08-25):** Built search, Appearance, Security & recovery, About, and diagnostics export.
- **ADR-058 (2026-08-25):** Replaced ADR-044's Piece 20 prerequisite with seven checkable fail-closed conditions (later superseded by ADR-077 for pairwise relayed WebRTC voice).
- **ADR-067 (2026-09-07):** Moved serving origin to `chat.orviniq.com`, rebased flavors to `com.orviniq.chat{,.beta,.development}`, and reissued the Beta signing key, voiding pre-2026-09-07 artifacts and resetting the off-site key-backup prerequisite.

**Closure (ADR-075, 2026-09-13):** Closed when [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) deleted MLS and the client deleted the `beta` flavor, `beta-pq-mls` Cargo profile, and `GroupProductionGate`. Production subsequently gained its own persistent signing identity and direct-install testing model under ADR-076 (2026-09-14).

## Rationale

Original rationale:
- A 20–30 person private deployment needed one authoritative definition aligning code, strings, and security posture without waiting on externally blocked IETF/IANA/OpenMLS/audit gates or creating a separate product branch.
- Shipping groups as a declared Experimental tier rather than completely unwiring them (Alternative E) avoided abandoning [ADR-036](036-beta-mls-track.md)–[ADR-041](041-fork-ordering.md) and enabled real-device testing against the packaged Rust core while protecting Production at the flavor/artifact boundary.
- Reconciling [threat-model.md](../../threat-model.md)'s release gates explicitly: those public-release gates remained closed; private distribution was authorized solely under mandatory written disclosure to named trusted recipients.

Why closed: deleting MLS and the `beta` flavor eliminated the Private Experimental Beta artifact that ADR-044 defined.

## Constraints and Open Gates

- **Closed:** `lib/main_beta.dart`, `GroupProductionGate`, `NativeBetaGroupMls`, `beta-pq-mls`, and `frontend/docs/mls-profile.md` have been removed.
- **Still binding in the current `production` testing model (carried forward through ADR-045 and ADR-076):** Mandatory security invariants (untrusted relay, no Dart crypto, hybrid PQXDH, cross-signing, private-CA TLS, encrypted local storage, no telemetry/foreign calls), direct signed APK distribution ([deployment-and-release.md](../../deployment-and-release.md)), and open public-release gates ([ADR-017](017-independent-crypto-review.md), [threat-model.md](../../threat-model.md#security-release-gates)).

## Costs

- While active, accepted no independent cryptographic review, no cross-implementation group interoperability, disposable group history, and (at the time) no background delivery, notifications, search, or voice.
- Accepted a single key-holder custody risk under `release-signing.md` and required tracking Android developer-verification rollout limits (revisit condition 6, primary source read 2026-08-20 in [ADR-045](045-maturity-disclosure.md)).

## Reversal Trigger

Already closed by ADR-075 (2026-09-13).

## History, Amendments, and Supersession

- **2026-08-20 (`d139ca3f`):** Recorded ADR-044 (`Accepted`), fixing the Beta group screen-gate contradiction and correcting stale claims in `implementation-checklist.md`, `README.md`, and `deployment-and-release.md` (no `staging` flavor).
- **2026-08-20 ([ADR-045](045-maturity-disclosure.md)):** Amended D2 Supported tier (removed attachments and encrypted profiles) and implemented in-app disclosure.
- **2026-08-24 – 2026-08-25 (ADR-055, ADR-056, ADR-057, ADR-058):** Amended Tier 2 exposure, Tier 3 completions, and Piece 20 prerequisites.
- **2026-09-07 (ADR-067):** Rebased origin, flavor IDs, and Beta signing identity.
- **2026-09-13 (`cd36012f` / ADR-075):** Closed and retired with the `beta` flavor.
