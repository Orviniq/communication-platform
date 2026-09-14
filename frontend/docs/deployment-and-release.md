# Deployment and release

What the initial deployment *was* - its audience, its maturity tiers, what may be
claimed about it, and what must be disclosed - was decided by
[ADR-044](decisions.md), which [ADR-075](decisions.md) closed: the `beta` flavor that
carried the deployment was deleted with the closed-beta MLS core, so no flavor builds its
artifact now. What a build *says* to the people who receive it - the maturity vocabulary,
the disclosure, and the one acknowledgement - is decided by [ADR-045](decisions.md). The
release signing, key custody, and upgrade-continuity verification that
[Beta release signing and key continuity](release-signing.md) specified under ADR-042
belonged to the same `beta` flavor; no flavor is signed now. This document covers the
surrounding release process.

## Environments

Use compile-time flavors with separate visible identity and trust configuration.
There are exactly two; each has one Dart entry point and reads one provisioning
prefix:

| Flavor | Entry point | Purpose | Trust |
|---|---|---|---|
| development | `lib/main_development.dart` | Local engineering | local origin/CA; debug banner |
| production | `lib/main_production.dart` | Future public release | production origin/private CA/primary+backup pins only |

There is deliberately no staging flavor. A third environment would need a third
application ID, a third provisioning prefix, and its own trust material, and
nothing in the current release process needs one. Adding one is an ADR decision,
not a build edit.

Every non-production flavor carries a persistent configuration banner, on the
blocking Connection screen and inside the application shell, that names its own
build: development reads "Development configuration". Production shows no banner at all.

The banner, the Android launcher label, and the window title Android shows in the
task switcher name the same build. Before ADR-045 the title branched on production
alone, so the Private Experimental artifact called itself "Communication Platform
(Development)" beside a launcher icon reading "(Experimental)".
`AppEnvironmentBanner` now owns both strings, and the Gradle flavor owns the
launcher label they must match.

The development and production flavors are separate, coexisting Android
applications with different application IDs. Neither upgrades into the other. No
flavor has a release signing identity: the production release build is deliberately
unsigned so it keeps building and stays verifiable without being installable.

No runtime text field changes the production server. Secrets are never compiled into the
client; only public origins, CA certificates, SPKI hashes, and protocol capabilities are
configuration.

## Versioning

Track independently:

- human application version, which `BuildIdentity.version` mirrors from `pubspec.yaml`
  so that the About screen and the diagnostics export name the artifact the user
  actually installed; an architecture test fails if the two drift apart;
- monotonically increasing Android version code;
- future Web artifact/build ID (post-v1);
- local database schema version;
- application-message protocol major/minor;
- crypto-state format version;
- minimum/maximum compatible backend API version when the backend exposes one in future.

The current health endpoint intentionally exposes no version, so compatibility is proved
by contract tests and conservative client behavior, not runtime version guessing.

## Dependency and toolchain control

- Pin Flutter and Dart SDKs for the team/CI.
- Commit Flutter/Dart/Rust/Gradle lockfiles and checksum external artifacts. All four
  exist as of [ADR-054](decisions.md): `pubspec.lock` enforced by
  `flutter pub get --enforce-lockfile`, `native/crypto_core/Cargo.lock`, and
  `android/app/gradle.lockfile` in `LockMode.STRICT` over the six configurations a built
  artifact resolves. Every direct Dart dependency is one exact version, never a range.
- Mirror/cache all build dependencies so a clean release can build without international
  internet.
- Produce a version-1 SBOM covering Dart, Android/Gradle, Rust, fonts, and native
  libraries. Add Rust/Wasm and browser-worker artifacts only when Web is reopened. The
  Dart and Android/Gradle halves are the two lockfiles above plus
  [third-party-notices.md](third-party-notices.md); the Rust, font and native halves are
  not yet aggregated anywhere (ADR-054 follow-up F3).
- Review licenses, especially crypto libraries, before acceptance. What a distributed
  artifact carries, and the notices each licence requires, are recorded in
  [third-party-notices.md](third-party-notices.md).
- Never let a plugin upgrade move an Android pin as a side effect. `connectivity_plus`
  7.1.0 and later would carry `androidx.core` from 1.16.0 to 1.18.0, and with it the
  required `compileSdk`; the Gradle lock is what turns that into a failed build instead of
  a changed artifact.
- Disable crypto debug/log features and remove unused architectures/resources only after
  verifying packaging rules.

## Android release

1. Build from a clean, reviewed tag in the isolated release environment.
2. Run analysis, tests, contract suite, crypto vectors, SBOM/audit, and offline-network
   rehearsal.
3. Produce deterministic release APK artifacts where the toolchain permits.
4. Sign with an offline-controlled application signing key; keep backup/recovery process
   separate from source control. No flavor is signed today: the Beta signing path was
   deleted with the `beta` flavor, and production's key is not created until an
   explicit production release decision.
5. Generate SHA-256 artifact hashes and signed update metadata.
6. Verify install, upgrade with real encrypted migration fixtures, rollback behavior, and
   private-CA connectivity on representative devices. Upgrade continuity has to be
   proved on a device; a successful build is never sufficient evidence on its own.
   [release-signing.md](release-signing.md) records how the deleted Beta channel
   proved it.
7. Publish APK, hash, version notes, and minimum protocol compatibility through the
   self-hosted/local distribution channel.
8. For the Private Experimental deployment, deliver the written disclosure with the
   artifact. This is release-blocking, not a courtesy.

   No flavor builds that artifact now: `DeploymentDisclosure.privateExperimental` is
   rendered only for `AppEnvironment.beta`, which no entry point has used since the
   `beta` flavor was deleted, so this step and step 9 have no artifact to travel with.
   Point 6 below, and the `disclosureExperimentalGroups` string it is written from, still
   describe the deleted closed-beta MLS track; groups now run on the same pairwise
   sessions as direct messages, and no build switches them off on any phone
   ([ADR-075](decisions.md)).

   It carries **the same points, in the same order, as `DeploymentDisclosure.privateExperimental`**,
   and it is written from that list rather than from this paragraph, so the two cannot
   drift apart the way they had by revision 4 — this step previously claimed "the same
   seven facts" and then listed six of them, omitted the unbuilt surfaces entirely, and
   never mentioned the opt-in tier ADR-051 added ([ADR-052](decisions.md)). At revision 7
   ([ADR-055](decisions.md) switched the group point from a caution about experimental
   groups to a statement that they are off; [ADR-056](decisions.md) reopened them on the
   one measured ABI and the point now carries both halves) that is eight points:

   1. no part of the cryptography has been independently reviewed, and one person wrote
      and tested all of it;
   2. messages arrive immediately while the app is open, and while it is closed only when
      the phone gets round to checking — fifteen minutes apart at best, usually far less
      often, and not at all while the phone is saving battery, while Data Saver is on over
      mobile data, once the app has gone unopened for several days, or after a force-stop;
      that Settings carries an opt-in that does better on most phones at the cost of
      battery and a permanent notice; and that none of it is guaranteed;
   3. a message waits on the server only until the phone collects it, after which the
      operator's retention timer deletes it unread and it never arrives, with no
      indication of which messages were lost;
   4. history exists only on the device and uninstalling destroys it permanently;
   5. a recovery secret restores identity on a new device and never restores messages;
   6. group messaging uses experimental encryption that is unfinished, non-standard
      and unreviewed, and an update can reset a group and delete everything in it; on a
      phone whose processor it has not been tested on it is switched off instead, and
      direct messages are unaffected either way (ADR-055 and ADR-056, both closed by
      ADR-075);
   7. voice rooms and file attachments do nothing, and the display name and photo are not
      published — contacts see the registered username;
   8. the build is for evaluation among people who already trust each other, and is not
      appropriate for anyone whose safety depends on the confidentiality of their
      messages.

   The written delivery is not replaced by the in-application disclosure and stays
   release-blocking: it reaches a recipient before they install, and it is the only copy
   a person who declines to install ever sees.

9. If `DeploymentDisclosure.revision` in
   `lib/app/config/deployment_disclosure.dart` differs from the revision carried by the
   previously distributed artifact, re-deliver the written disclosure to **every**
   existing recipient, not only to new ones. The revision moves when and only when what
   the build promises moves, so a changed revision is exactly the case where a person who
   already enrolled has been told something that is no longer true.

   Since [ADR-052](decisions.md) their install also re-presents the statement once, on the
   first launch after the update, marking the points that moved — the accepted revision is
   recorded on the device, so the application can tell. That mechanism reaches only people
   who install the update, which is why this step is still release-blocking: somebody who
   stays on an older artifact, or who never installs again, is reached by the written
   delivery or by nothing.

   The revision cannot be raised by hand and cannot be skipped: it is the highest
   `DisclosurePoint.since` among the points, and `test/architecture/deployment_disclosure_test.dart`
   fails on any edit to a pinned string until that point's `since` is raised with it.

10. Deliver [third-party-notices.md](third-party-notices.md) with the artifact, in the
    same handover as the written disclosure. Apache-2.0 §4 and the BSD 3-Clause licence
    both require that whoever receives the binary receives the licence text and the
    attribution notices, and a private handover is still distribution
    ([ADR-054](decisions.md)). The machine-generated half for the Dart packages and the
    engine is inside the APK at `assets/flutter_assets/NOTICES.Z`; nothing in the
    application displays it, so this document is currently the only copy a recipient can
    read. Unlike the step above this one is not release-blocking on a disclosure
    revision: it changes when the dependency set does.

Updates are explicit user/admin actions. The app may check only the self-hosted signed
metadata endpoint. It never fetches executable code or dependencies dynamically.

## Post-v1 Web release

Web is not shipped in version 1. The following is a future release procedure and is not
part of the Android release gate:

1. Build and test the Flutter web bundle, shared crypto Wasm, and LiveKit E2EE worker from
   the same reviewed tag.
2. Generate a content-hash manifest/SRI metadata for every static artifact.
3. Verify the strict CSP and security headers against the exact compiled output.
4. Serve immutable hashed assets and a no-store/revalidated root document from the
   self-hosted origin; no service worker may pin an incompatible protocol bundle forever.
5. Run browser compatibility, storage migration, multi-tab, WebSocket origin, and voice
   E2EE tests against the deployed staging artifact.
6. Publish the production artifact hash through an independent operator channel where
   users can verify it.

Recommended response posture includes HSTS, `nosniff`, strict referrer/permissions
policies, restrictive CSP, frame denial, correct Wasm MIME, and cache rules. Exact header
values belong in version-controlled server configuration and automated deployment tests.

## Rollout order

Protocol changes use expand/migrate/contract:

1. Backend changes remain compatible with the currently released client.
2. Release a client that can read old/new but writes old.
3. Confirm adoption and migration health without collecting sensitive telemetry.
4. Enable new writes through local/operator-controlled capability configuration.
5. Remove old reads only in a later major release after the retention window.

Because the app has no remote third-party feature flag service, flags are signed
self-hosted configuration or compile-time decisions and cannot weaken cryptography.

## Rollback

- A future Web rollback is permitted only if the older bundle can read the migrated local
  DB and crypto formats.
- Android downgrades are not assumed safe. Roll forward with a fixed build unless a tested
  compatibility path exists.
- Never restore old ratchet or group control state over newer state.
- Preserve encrypted user data during application/schema failures; do not "repair" by
  deletion without explicit informed user action.
- Backend rollback must preserve API behavior required by deployed clients and avoid
  resurrecting acked/revoked state.

## Operations without international internet

Before every production release, isolate the environment from foreign networks and prove:

- build succeeds from approved mirrors/caches;
- version-1 application assets, fonts, CA material, APIs, Redis/PostgreSQL, nginx,
  LiveKit, and TURN are local/self-hosted;
- Android installation/update works. Web loading is post-v1.
- two-phase enrollment, cross-signing/SAS, PQXDH and pairwise group fan-out, device-log
  gossip, register/login/message/attachment/voice/identity-recovery flows work;
- seven-day queue gaps trigger group state recovery from a member, and history transfers
  succeed only device-to-device with no server-history dependency;
- DNS and connectivity checks do not contact foreign services.

## Incident response

Maintain runbooks for compromised signing key, compromised TLS/JWT/backend host, leaked
web bundle, vulnerable dependency, protocol flaw, corrupted migration, and lost update
channel. A protocol/crypto incident may require device/session invalidation and a new
major version; availability pressure never authorizes silent plaintext or encryption
downgrade.

## Production release checklist

- [ ] Final application name, icon, Android ID, and production origin approved.
- [ ] Documentation and ADR register match implementation.
- [ ] Security review findings closed or explicitly release-blocking.
- [ ] Crypto/interoperability vectors pass on Android. Supported-browser vectors are
  post-v1.
- [ ] Database and crypto-state migrations pass from all supported Android versions.
- [ ] Backend contract and multi-device E2E suites pass.
- [ ] Accessibility, RTL, performance, battery, and voice gates pass.
- [ ] Sustained delivery: either every mandatory cell of the matrix in
  [sustained-delivery-validation.md](sustained-delivery-validation.md) has an admissible
  record in `SustainedDeliveryGate.releaseAssertion`, or the capability is still withheld.
  **Currently withheld; the gate is CLOSED and no cell has been run.** A partially
  satisfied matrix opens nothing, and an emulator record can never satisfy a cell.
- [ ] No forbidden network calls or sensitive logs/artifacts detected. This now includes
  the user-initiated diagnostics export (§15.3): the report a recipient can be asked for
  is inspected on a real device with real content behind it, as well as by the
  adversarial host test that stuffs a canary into every table it reads.
- [ ] SBOM, hashes, signatures, update metadata, and rollback plan archived.
- [ ] Staging rehearsal and isolated-network production rehearsal completed.
