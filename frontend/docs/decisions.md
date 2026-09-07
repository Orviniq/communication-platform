# Architecture decisions

This file is the initial ADR register. A changed accepted decision gets a dated ADR; it
is not silently edited out of history.

| ID | Status | Decision | Reason |
|---|---|---|---|
| ADR-001 | Accepted | Feature-first Clean Architecture | Keeps security, sync, UI, and platform concerns independently testable. |
| ADR-002 | Accepted | Drift is the local source of truth | Prevents REST, socket, and optimistic state from diverging in widgets. |
| ADR-003 | Accepted | Riverpod for DI and reactive application state | Supports testable scopes and database-stream projections without global singletons. |
| ADR-004 | Accepted | Dio for REST and a dedicated WebSocket gateway | Centralizes authentication, redaction, refresh, retries, and protocol limits. |
| ADR-005 | Accepted | `go_router` with route guards | Supports deep links and adaptive navigation without navigation in domain code. |
| ADR-006 | Accepted | Forui behind app-owned components | Gains consistent primitives without coupling product design directly to a package. |
| ADR-007 | Superseded by ADR-066 (2026-08-30) | Flyer Chat behind a timeline adapter | Reuses virtualization while allowing exclusive builders or full replacement. The replacement is what happened: piece 15 built an app-owned reversed sliver instead of keeping messages in a Flyer controller, and ADR-054 removed `flutter_chat_ui` 2.11.1 and `flutter_chat_core` 2.9.0 from the resolved set as declared-and-unimported — noting in the same breath that this row had never been superseded. It stayed `Accepted`, naming a package the application does not depend on, for the whole of that interval. ADR-066 records what shipped, on the reason that actually decided it. |
| ADR-008 | Accepted | Canonical CBOR for encrypted application payloads | Compact, deterministic, binary-safe, and versionable. |
| ADR-009 | Superseded by ADR-025 | X3DH + Double Ratchet for device-pair channels | The binding backend client contract now requires hybrid PQXDH session establishment. |
| ADR-010 | Accepted | RFC 9420 MLS for group membership/key state | Provides standardized asynchronous group FS/PCS and matches backend key packages. |
| ADR-011 | Accepted | Per-recipient pairwise transport wrapping | Prevents identical MLS ciphertext from linking a sender's recipient set at rest. |
| ADR-012 | Accepted | Local-only search | The server never receives content or search terms. |
| ADR-013 | Accepted | No foreign push or telemetry | Required for operation during international disconnection and privacy. |
| ADR-014 | Superseded by ADR-029 | Explicit Android foreground connection mode | The binding backend client contract now requires background polling for messaging. |
| ADR-015 | Accepted | Web is online-session-first | Browser background execution cannot provide native-style delivery guarantees. |
| ADR-016 | Accepted | English and Persian at first release | RTL and mixed-direction behavior must be structural, not retrofitted. |
| ADR-017 | Release gate | Shared reviewed crypto core and independent assessment | A custom, unaudited cryptographic implementation is not production-ready. |
| ADR-018 | Accepted | Padding is authenticated inside each pairwise transport envelope | Prevents ambiguous/unprotected trailing bytes while preserving backend size buckets. |
| ADR-019 | Accepted | Logical fan-out uses durable per-device targets and deterministic batches of at most 256 | Supports the backend limit, partial progress, and crash-safe retries for large multi-device groups. |
| ADR-020 | Accepted | Event IDs and ratchet state reject replay; sender counters do not reject delayed messages | Preserves legitimate out-of-order delivery without losing rollback detection. |
| ADR-021 | Accepted | Missing profile keys render username plus a deterministic local avatar | Avoids presenting unauthenticated profile identity during contact bootstrap. |
| ADR-022 | Superseded by ADR-028 and ADR-030 | Recovery restores history separately from current secure membership | The server no longer stores history; history transfer and identity recovery are separate. |
| ADR-023 | Accepted | Voice-room leave is client membership/key removal, not backend room deletion | Matches the capability-only backend and gives users an honest consequence statement. |
| ADR-024 | Accepted | A restrained neutral/indigo app-owned visual system is the production baseline | Gives Forui and Flyer builders one reproducible identity while allowing later brand assets to replace only brand tokens. Correction of fact recorded 2026-08-30, decision unchanged: "Flyer builders" names a package ADR-054 removed and ADR-066 supersedes. There is one builder set for this identity to serve now — the app-owned timeline surface — and the tokens it consumes are the same ones this row already named. |
| ADR-025 | Accepted | Hybrid X25519 + ML-KEM-768 PQXDH establishes every DM session | Protects recorded sessions against harvest-now-decrypt-later and forbids silent downgrade. |
| ADR-026 | Release gate | Use the IETF `MLS_128_MLKEM768X25519_AES256GCM_SHA384_Ed25519` candidate; do not assign a production ID locally | It aligns hybrid ML-KEM-768/X25519 and Ed25519 with the existing protocol. For the Android-only version-1 release, a stable published specification and registry assignment for every primitive in the mapping, an IANA-assigned MLS ciphersuite value, maintained OpenMLS/provider support, Android interoperability, and review remain mandatory; Web interoperability is a post-v1 Web release gate under ADR-033. Presentation clarified 2026-08-16, decision unchanged: the primitive mapping and the MLS suite value are tracked as two separate gates because different registries own them under different policies and on independent schedules, and the primitive identifiers are already assigned outside the MLS registry while `TBD2` is not assigned at all. This project still assigns no production identifier locally. |
| ADR-027 | Accepted | Account cross-signing and a client-signed device log authenticate devices | A hostile server cannot make an unsigned device or identity substitution trusted by clients. |
| ADR-028 | Accepted | History exists only on clients and transfers device-to-device | Matches the backend's removal of server history and states the online existing-device dependency honestly. |
| ADR-029 | Superseded by ADR-046 (2026-08-21) | Android background messaging uses best-effort polling, not a persistent service | Deferrable polling alone can only ever be eventual: Doze defers it to thinning maintenance windows and the *rare* and *restricted* standby buckets disable background network entirely. ADR-046 keeps it as the mandatory floor and adds an opt-in `specialUse` foreground service above it; active voice remains foreground. That service was built on 2026-08-22 (ADR-051), and the exemption it requires additionally removes the standby-bucket restrictions named here for the user who grants it. |
| ADR-030 | Accepted | Recovery backup contains cross-signing identity material, not history keys | Recovery preserves verifiable account identity but cannot recreate local message history. |
| ADR-031 | Accepted | Forui-bundled Lucide icons are exposed through app-owned semantic icon tokens | Provides one coherent, locally bundled icon language without an extra icon dependency, while isolating feature code from package APIs and centralizing accessibility and RTL choices. |
| ADR-032 | Accepted | Stage piece 07 as a shared Rust core with an Android FFI adapter and defer its Web/Wasm adapter (2026-07-28) | This narrows the current implementation milestone without moving primitives into Dart or JavaScript. The future Web adapter must use the same locked core source, provider choices, serialization, and fixtures; Web crypto remains fail-closed and ADR-017, ADR-026, Android/Web parity, browser vectors, and independent-review gates remain unsatisfied until evidenced. |
| ADR-033 | Accepted | Version 1 ships Android only; Web is post-v1 (2026-07-28) | Keeps the first release on the verified Android trust and delivery boundary. Pieces 08 onward may implement Android protocol behavior without waiting for Wasm, browser workers, or Android/Web parity. The preserved Web foundation remains fail-closed and any future Web release must use the same reviewed Rust core, providers, encodings, vectors, and an independently verified worker boundary. |
| ADR-034 | Accepted | Pairwise transport v1 always mixes the signed ML-KEM-768 prekey and treats an unsigned PQ one-time prekey as additive only (2026-07-29) | The backend does not carry a signature for `pq_otpk`; allowing it to replace `pq_spk` would remove the authenticated PQ contribution. The frozen profile preserves the mandatory signed-PQ layer and gains one-time PQ forward secrecy when the optional key is present. |
| ADR-035 | Accepted | A verified monotonic prekey rotation under an unchanged device identity does not reset master-key verification (2026-07-29) | Routine seven-day rotation necessarily changes `cross_sig`. Requiring user SAS/QR every week would make safe rotation unusable. Only exact `bundle_version + 1` rotations with valid prekey/device signatures and an extending device log are routine; every other signature change remains blocking. |
| ADR-036 | Accepted | Build draft PQ MLS as a real, isolated closed-beta track while keeping the production gate closed (2026-08-02) | Phase A found that the selected suite is still an Internet-Draft with no IANA ciphersuite value, no exact maintained OpenMLS provider, no upstream MLS vectors, and no retained independent reviewer. Closed beta may nevertheless integrate the draft-06 mapping as closely as a maintained provider offers it, behind a source-only beta permit, using only maintained external cryptographic implementations and the real backend/pairwise transport. Correction of fact recorded 2026-08-16, decision unchanged: verification against the pinned vendored sources established that this yields draft-06 `TBD2`'s signature, AEAD, KDF, and hash choices but **not** its KEM `0x647a`, because `mls-rs-crypto-hpke 0.21.0` ships a pre-standard X-Wing variant that reports an unassigned HPKE `kem_id`. Beta groups are hybrid ML-KEM-768/X25519 but are not `TBD2`-conformant and are not `TBD2` interoperability evidence; `docs/mls-profile.md` holds the evidence table. Beta uses an MLS Private Use identifier, a distinct Android application ID and provisioning namespace, and disposable state that must be reinitialized rather than silently migrated when the draft or identifier changes. This decision does not satisfy or weaken ADR-017/ADR-026, does not authorize a classical fallback or production KeyPackage path, and production continues to resolve the unsupported adapter until all seven production gates are evidenced (six until 2026-08-16, when the combined specification/identifier gate was split into separately evidenced primitive-mapping and MLS-suite-identifier gates; nothing was merged away or marked satisfied). |
| ADR-037 | Accepted | Closed-beta MLS transport v3 carries the complete authenticated control transcript needed for later Welcome and re-add; v2 beta groups are recreated, never silently upgraded (2026-08-09) | A later member cannot authenticate the product roster from only the current Invite. V3 therefore binds every prior deterministic control projection to its exact signed payload and signer Authentication Service proof, replays the bounded transcript from the initial state, joins the Welcome, and compares the Rust-returned BasicCredential roster with the reconstructed product roster before one atomic commit. Existing members verify the same transcript. The transcript is capped at 512 entries and fails closed on absence, disagreement, replay, authorization failure, or malformed credentials. V2 state and queued objects are disposable closed-beta data and must be recreated/rejoined; this is not a production migration or permission to open the production gate. |
| ADR-038 | Superseded by ADR-041 (2026-08-17) | Same-revision control forks converge on the lexicographically smallest control state hash; a superseded branch is recovered by remove/re-add, never by rollback (2026-08-16) | RFC 9420 assumes a delivery service that serializes commits and rejects the losers. This project's backend is an untrusted relay and group objects ride per-recipient pairwise envelopes, so no server order exists. Every branch already carries a control state hash over its full signed descriptor, so ordering by that hash is total, deterministic, and needs no extra round trip or server trust. A sibling is authenticated, replayed against the reconstructed shared parent, and authorized before it may influence the decision, so a hostile relay cannot force a quarantine with an invented low-ordering branch. An applied MLS commit cannot be rewound because the previous epoch secrets are gone by construction; a superseded local branch is therefore fork-quarantined and rejoins through the existing remove/re-add path. This is closed-beta convergence behavior and does not open any production gate. |
| ADR-039 | Accepted | Leave is a two-phase departure: a non-membership announcement by the leaver, then the active owner's Remove commit that evicts the leaf (2026-08-16) | RFC 9420 section 12.4 states "A Commit MUST NOT remove the committer", because the committer must know the new epoch secrets; `remove_members_operation` already enforces this and rejects self-removal. The beta control model nevertheless classified `Leave` as membership-changing in both `group_model.dart` and `mls_beta.rs`, and `read_group_control_descriptor` rejects a membership-changing control without a commit hash, so a leaver was required to produce a Commit it is forbidden to produce. `Leave` is therefore reclassified as non-membership in both places. **Phase 1:** the departing member signs a leave at the current epoch, carrying no Commit; every device projects the member to `left`, which means "departure announced, eviction pending", and the leaver's own projection moves to `GroupLifecycle.left`. Because no Commit is involved the leaver is still cryptographically present at that epoch and processes its own announcement like everyone else, so `removedLocally` covers `Remove` only. **Phase 2:** the active owner commits the `Remove` that actually evicts the leaves and rotates the epoch, moving the member to `removed`. The owner is the deterministic committer because `canLeave` only permits an owner to leave as the last active member, so any group that still has members still has exactly one active owner; restricting eviction to that single committer keeps concurrent eviction commits, and the fork they would cause, off the wire. `GroupAuthorization.isEvictable` keeps `left` a valid Remove target — a departed leaf still holds the epoch secret, so eviction is a security obligation, not bookkeeping — while an already `removed` member is not a target again. `GroupPendingEvictionService` runs as post-inbox work, evicting at most one member per group per pass so a partial sweep is always resumable, and treating a concurrent-control conflict as a retry rather than an error. A sole owner leaving needs no committer: nobody remains to be protected from. |
| ADR-040 | Accepted | The closed-beta hybrid KEM is not changed; the complete divergence from `TBD2`'s KEM `0x647a` is recorded, and supplying a conformant KEM through `mls-rs`'s public extension points would be a project-local cryptographic fork (2026-08-17) | The beta already delivers everything ADR-036 asked of it — hybrid ML-KEM-768/X25519 confidentiality from a maintained implementation, `TBD2`'s exact signature/AEAD/KDF/hash mapping, no classical fallback, disposable state on Private Use `0xFE4C` — and the KEM divergence costs only `TBD2` interoperability, which no gate can consume while `TBD2` has no IANA suite value and no upstream PQ vectors exist. The pinned `mls-rs` crypto crates are already the newest published versions, so no maintained fix exists to adopt, and no maintained provider implements `TBD2` at all. Correcting the KEM in place would mean authoring the combiner, the raw-X25519 KEM, the SHAKE-256 expansion, and the encapsulation-key check in project code, because `AwsLcCipherSuite` cannot be re-parameterized — which is what production gate 3 and ADR-017 exclude, closes no gate, and would be written against a specification still in motion. Full reasoning, the ten-row divergence set, and the rejected alternatives are in "ADR-040 in full" below and in `docs/mls-profile.md`. This decision opens no production gate. |

| ADR-041 | Accepted | Same-revision control forks converge on an ordering key the branch author cannot vary — operation precedence class, then the signer's authority in the shared parent, then the signer's authenticated user and device id, then the control state hash; supersedes ADR-038 (2026-08-17) | ADR-038 ordered siblings by the control state hash alone. That hash is SHA-256 over the signed descriptor, and the descriptor's 16-byte event id is free author-chosen entropy that nothing binds, `created_ms` is an unvalidated `u64`, and Ed25519 is deterministic, so one grinding trial is one signature plus one hash and produces an independent uniform ordering value. Measured on the shipped signing path: about 24,500 candidate branches per second per core, and 9 trials to land below one known rival. A member facing eviction sees the `Remove` first, so it could undercut it for well under a millisecond of work and quarantine the evicting owner instead. Ordering now reads the operation's precedence class first, so an eviction cannot lose to a metadata edit, an invite, or a leave; then the signer's role in the reconstructed shared parent, so an evicted admin's counter-`Remove` loses to the owner's; then the authenticated signer identity. The hash is reached only between two branches from one device, where ordering decides nothing that author could not decide by choosing which branch to send. Every input is either fixed by the shared parent or bound to an authenticated device credential, so no participant can bias the outcome, and the rule stays total, deterministic, server-independent and free of extra round trips. Sibling authentication, replay against the reconstructed parent, and authorization are unchanged, and a superseded branch is still recovered by fork-quarantine plus remove/re-add. This is closed-beta convergence behavior and opens no production gate. |

| ADR-042 | Superseded by ADR-067 (2026-09-07) | The Private Experimental Beta ships under a frozen application ID and one persistent signing key, separate from Production, which stays unsigned (2026-08-19) | Android accepts an update only when both the application ID and the signing certificate match the installed app; otherwise the only path forward is uninstall, and this client cannot survive one. Uninstalling erases all app data, here both the SQLCipher database and the `no_backup` envelope holding its key, the manifest sets `allowBackup="false"` so nothing restores either, and the database key is protected by a non-exportable AndroidKeyStore key so no exportable copy exists; local message history has no server-side copy by design. Identity was therefore frozen before any external install rather than after: `com.example.communication_platform.beta` was a documented placeholder awaiting branding, and shipping it would have guaranteed a later forced reinstall, so the flavors move to `dev.nimashadloo.chat{,.beta,.development}` under a domain the project already operates. Beta and Production take separate keys because their application IDs differ, so they coexist and no upgrade path between them can ever exist; a shared key would buy no continuity while dragging Production's identity into the Beta's warmer custody and widening compromise blast radius. Production release keeps no signing config at all, so it packages unsigned: it still builds and is verified in CI, but the OS cannot install it, which is fail-closed by construction. Beta signs v2+v3 without the legacy v1 scheme, which minSdk 24 makes unnecessary; v3 records the signer so a rotation lineage stays possible on API 28+, though rotation requires the original key, so key loss is not recoverable by rotation. Private material never enters source control: Gradle reads it from the environment or an untracked properties file, absence is a hard build failure, and the public certificate fingerprint is committed so every artifact is verified against the identity it must match. |

| ADR-043 | Accepted | The client's own transport trusts the provisioned private CA exclusively; Android's network security configuration is retained as defence in depth for non-Dart traffic only (2026-08-20) | Release validation of a real signed Beta APK found the app could not reach a healthy, correctly provisioned server. Every network precondition held - DNS, TCP, TLS from the host, a chain verifying against the provisioned CA, ~1.1s latency - and removing the pin-set from a diagnostic build changed nothing. The cause is that Android's `network_security_config` governs the platform's Java HTTP stacks and WebView, while this app's REST and WebSocket traffic both run on `dart:io`, which does not consult it. The configuration was therefore protecting no traffic at all: the app was simultaneously unable to reach its own server and, had it reached one, unpinned. Trust now comes from a `SecurityContext` built with `withTrustedRoots: false` plus the provisioned authority, so the built-in root store is **replaced** rather than extended and no public authority can issue a certificate this client accepts; chain construction, expiry, and hostname verification are still performed in full by BoringSSL. Both transports share one context, and the authority reaches the app as `<ENV>_PRIVATE_CA_PEM_BASE64` because `dart:io` verifies against a certificate, not the digest the configuration previously carried. Absent or malformed authority material fails configuration closed rather than falling back to public roots. Leaf SPKI pinning is deliberately **not** reimplemented in Dart: `X509Certificate` exposes no SPKI accessor and no SHA-256, so it would require hand-written ASN.1 parsing plus a hashing dependency inside the TLS path, which `AGENTS.md` forbids and which would be unreviewed cryptographic code. Anchoring exclusively to a single offline private root is a stronger constraint than the public-CA-plus-leaf-pin model it replaces, and the residual exposure - a stolen CA key minting a new leaf - is accepted for the closed beta and recorded here. The rendered Android configuration and its two pins are kept and still verified in the artifact, but only as defence in depth for any future WebView or Java-side traffic; no document may claim they protect the app's API traffic. Health checks now distinguish `trustRejected` from ordinary connectivity so a refused certificate is never reported, or retried, as an outage. |

| ADR-044 | Accepted, tier-2 exposure amended by ADR-055, tier-3 contents amended by ADR-057, piece-20 prerequisite amended by ADR-058 | The initial deployment is one Private Experimental Android artifact carrying declared maturity tiers, distributed privately under the frozen Beta identity, while Production stays uninstallable (2026-08-20) | A 20-30 person private deployment needed one authoritative definition, and the repository did not have one. Inspection found the existing build-time separation correct and worth keeping - three flavors, three application IDs, two Cargo profiles whose native symbol sets are verified in the packaged artifact, a signing identity attached only to Beta, and `signingConfig = null` on the release build type so Production packages unsigned and the OS cannot install it. It also found the separation incomplete in one place: `groupFeatureAvailabilityProvider` derived availability from the development-preview permit alone, which requires `!kReleaseMode`, so every group screen in the shipped Beta artifact rendered the closed gate while that same artifact composed `NativeBetaGroupMls`, ran `GroupKeyPackageMaintenanceService`, and processed inbound group objects - uploading MLS KeyPackages for groups no user of it could create. One source-only `GroupProductionGate.privateExperimentalPermit` now decides both the stack and its screens, and the screens gate on `isAvailable` rather than naming one tier. The deployment is defined as **experimental, not beta**: nothing in it has been independently reviewed, its group suite is MLS Private Use `0xFE4C` and is not `TBD2`-conformant (ADR-040), and it has no background delivery, notifications, voice, or search. The frozen application ID keeps its `.beta` suffix because ADR-042 makes it unchangeable and an identifier is not a claim; every user-facing string says Experimental. One artifact carries three declared tiers - supported (pairwise messaging, identity, devices, attachments, history transfer), experimental (closed-beta PQ MLS groups, whose state is disposable by ADR-036 and is disclosed as such on every group screen), and visibly absent (voice, search, notifications, background delivery). Confidentiality, integrity, client-side verification, hybrid PQXDH with no fallback, provisioned-CA-only transport, encrypted local state, key continuity, and the Beta/Production artifact separation all stay mandatory; independent review, registry assignment, interoperability, upstream vectors, reproducible builds, and background delivery are deferred with their residual risk recorded and disclosed to users in writing at handover. Piece 19's closed-beta half is delivered as the experimental tier and its production half stays blocked on the same five external prerequisites; piece 20 is re-scoped from "after every production gate" - unreachable, and therefore dead rather than blocked - to a decision about which MLS exporter may key real-time media, which this decision does not grant. Opens no production gate and supersedes nothing. |

| ADR-045 | Accepted, re-presentation completed by ADR-052 | One application-level maturity word - Experimental - two feature labels that only ever read *down* from it, and one mandatory first-run disclosure inside the enrollment gate that already exists; amends two rows of ADR-044's tier table (2026-08-20) | ADR-044 defined what the deployment *is* and deferred what the software *says*. Inspection of the running surfaces found four different vocabularies reaching users and two of them false in the artifact that carries them: the task-switcher title called the Private Experimental build "Communication Platform (Development)" while its own launcher label said Experimental; the wide navigation rail carried a permanent "Structural placeholder - not for shipping" footer in **every** build including production; Edit Profile claimed a "development-only fake transport" in a build that composes no profile adapter at all, so Save could only fail; and the composer's paperclip opened three inert options because no build composes an attachment picker or transfer service. Those last two are also a correction to ADR-044, whose supported tier listed encrypted profiles and attachments: both are absent and are now labelled **Not built yet**. Terminology was re-derived rather than inherited and landed in the same place for a better reason - Google's published launch-stage definition of Experimental ("not intended for production use or covered by any SLA, support obligation, or deprecation policy and might be subject to backward-incompatible changes", read at primary source 2026-08-20) describes this artifact exactly, including the backward-incompatible clause that is ADR-036's disposable group state, while Preview promises the previewed thing ships and Beta promises feature completeness. Consent reuses `EnrollmentPhase.securityNotice`, which is already mandatory, already durable in the enrollment journal, and already withholds messaging until accepted, rather than adding a second blocking screen that would split the attention paid to both. Seven disclosure points state only the facts that make an ordinary expectation wrong - no review, foreground-only delivery, device-only history, recovery without history, resettable groups, unbuilt surfaces, intended use - and cryptographic identifiers are excluded by decision because printing them beside those seven would bury them. Periodic re-acknowledgement is rejected on measured evidence that repetition destroys a warning and that the damage generalises to this app's genuinely blocking security states; re-consent is content-triggered through `DeploymentDisclosure.revision`, pinned by a test to the exact disclosure text. There is deliberately no label meaning supported, stable, verified or audited: the absence of a badge must never read as an assurance. Opens no production gate and supersedes nothing. |

| ADR-046 | Accepted, Layers 0 and 1 amended by ADR-047 and ADR-049 | Background message delivery is layered — a composed foreground socket, a best-effort WorkManager floor, and an opt-in `specialUse` foreground service holding the same connection — and a notification is a projection of committed local state, never of the transport; supersedes ADR-029 (2026-08-21) | ADR-029 chose best-effort polling and no persistent service. Inspection of the composed artifact found something else entirely: `SyncLifecycleSupervisor`, `DioWebSocketGateway`, `GatewayRealtimeSyncAdapter` and `NetworkingFoundation` exist, are tested, and are constructed **only in tests**, and `durableSyncEngineProvider` is read by nothing, so the shipped build neither drains its mailbox nor transmits its outbox — `SendConversationEvents` ends at `fanout.prepareAndQueue` and the rows stay there. ADR-045's disclosure "messages arrive only while this app is open" is therefore wrong in the user's favour and is corrected here. On the platform, primary sources read 2026-08-21 leave a narrow design space: a backgrounded process is cached, and "if all processes for a particular app are frozen, the system terminates any active TCP sockets maintained by the app", so an unattended socket is closed rather than slow; `WorkManager`'s floor is 15 minutes, Doze defers `JobScheduler` to maintenance windows that thin out over time, Android 16 enforces job quota even in the active standby bucket, and the *rare* and *restricted* buckets disable background network outright, so deferrable work can only ever be *eventual*; while-idle alarms buy six minutes of best-case cadence for a user-revocable `SCHEDULE_EXACT_ALARM` and still wake an app that has no network. The one documented state with unrestricted background network is "app process is running a foreground service", and Android's own Doze acceptable-use table rates the battery-optimization exemption **Acceptable** for an "instant messaging, chat, or calling app" that "can't use FCM because of technical dependency", which is this application exactly — the exemption granting that an app "can use the network and hold partial wake locks during Doze and App Standby" and being itself an exemption from the Android 12 background FGS-start restriction. The type is `specialUse` with a truthful subtype property, because `dataSync` is capped at 6 h/24 h and barred from `BOOT_COMPLETED` at `targetSdk` 35+, `remoteMessaging` means device-to-device continuity, and `systemExempted` is gated on roles this app lacks; the existing test forbidding `remoteMessaging` and `FOREGROUND_SERVICE_DATA_SYNC` in the manifest stands unchanged. Exactly one delivery owner runs at a time, held as a durable Drift lease rather than an in-memory flag, because concurrent isolates would race a *rotating* refresh token and can invalidate the session. Notifications fire only from the existing `PostInboxCommitWorkPort` after the inbox transaction commits, deduplicated by a durable `notified_at`, recovered by query rather than replay, and bounded by a grouped summary. Reliability is stated in four tiers and never as a guarantee: near-real-time foregrounded; near-real-time best-effort backgrounded when the user has granted the exemption and their vendor cooperates; eventual otherwise, and nothing at all in the *rare* and *restricted* buckets; and nothing whatsoever after force-stop, which no design can change. The costs are accepted and disclosed: a persistent shade entry that makes the app observable on the device, real battery use, two permissions, and per-vendor setup on the 77% of the Iranian fleet that is Samsung or Xiaomi (Statcounter, July 2026). Layer 2 ships off by default and may not be enabled in any distributed artifact before the physical-device matrix runs; UnifiedPush was rejected because the backend has no push endpoint and may not be changed, it needs a second app and a second service per user, and it moves message-timing metadata outside the reviewed boundary without removing the Android constraint; SMS wake was rejected outright for binding accounts to carrier-held phone numbers. No experiment was run: only Play-Store emulator images without root were available and no Samsung or Xiaomi hardware, so a local result would have proved nothing about the fleet that matters. Reaffirms ADR-013, opens no production gate, changes no cryptographic behaviour, and adds no dependency by itself. |
| ADR-047 | Accepted | The delivery path is composed at the application root, on the one networking foundation, and a send is a durable write the supervisor observes rather than a call it receives (2026-08-21) | Implements ADR-046's Layer 0 and closes its follow-up step 1. **The two composition roots are resolved into one**: `AuthenticationAssembly` owns a single `NetworkingFoundation` — one `DioRestClient`, one `TokenCoordinator`, one provisioned `SecurityContext` — and the socket is built from it by `NetworkingFoundation.realtimeGateway`, so close 4001 refreshes and close 4003 revokes through the coordinator the whole application shares. A second coordinator was rejected outright: both would rotate the same refresh token and the loser would present one the server has already retired, ending the session for both. `NetworkingFoundation` was dead code and, contrary to ADR-046's inventory, had no tests at all; it is kept and made live rather than deleted, because the role its name claims is the role the application needs. **Ownership sits at the application root**, as a Riverpod notifier the root holds through `listenManual`: `flutter_riverpod` 3.3.2 pauses subscriptions created in `build` when their widget leaves the view (`ConsumerStatefulElement._applyTickerMode`, verified in the pinned source), so a screen-owned or `ref.watch`-owned controller would silently stop managing sessions when a route covered it, while `listenManual` subscriptions are never ticker-mode managed. Exactly one session runs at a time, serialized on one transition queue with the wanted scope re-checked after every await; the durable cross-isolate lease ADR-046 requires is not built and is not yet needed, because this stage composes exactly one isolate. A session runs only for `fullScope`/`offlineFullScope` and stops when logout *begins*, because `TokenCoordinator.logout` wipes protected storage and closes the database before it emits the termination a completion-triggered stop would wait for. **A send is not a call into the supervisor**: composers write exact per-recipient ciphertext into `outbox_operations` and return, and the supervisor requests a cycle when the durable projection's outbox depth *increases*. Reacting to depth being non-zero was rejected — every engine run rewrites the connection phase and re-emits the projection, so it spins against a row waiting out its backoff (demonstrated: the rule inverted makes the loop-safety test hang) — and an in-memory trigger port was rejected for needing cross-feature wiring that the durable queue already provides, and for not surviving a restart. Two platform edges were corrected because they neutralised the composed path: Flutter leaves `WidgetsBinding.lifecycleState` null until the first `SystemChannels.lifecycle` message and documents the initial value as detached "updated to the current state (usually resumed) as soon as the first lifecycle update is received", so reading "not yet reported" as background made a session started at launch stand itself down and never connect; and connectivity_plus documents that Android 8.0+ does not deliver connectivity changes to a backgrounded app and that status should be re-checked on resume, so a cached *unavailable* could outlive the outage and block foreground reconnect. Connectivity, lifecycle, wall-clock delay and the deferred scheduler are resolved and released together as one `DeliveryPlatformPorts`, which is also what lets a test drive the real supervisor without a device. This build composes `UnscheduledBestEffortPolling`, which schedules nothing and emits nothing: ADR-046's Layers 1 to 3 stay unbuilt, a backgrounded application still performs no catch-up, and ADR-045's `foregroundDeliveryOnly` disclosure — previously wrong in the user's favour — is now true, so its revision does not move. Adds no dependency, changes no cryptographic behaviour, opens no production gate, and leaves the Beta/Production boundary untouched: the engine's group stack still resolves through the compile-time permit, and the production artifact verifies unsigned and free of the beta MLS symbol. |
| ADR-048 | Accepted, notification claim corrected by ADR-052 | The user is told a message arrived by one sender-neutral system notification that is a reconciliation of committed local state, not an event; amends ADR-046's Layer 3 and ADR-045's delivery disclosure (2026-08-21) | ADR-046 sketched Layer 3 in three sentences and ADR-047 built the delivery path under it; inspection of the composed artifact found no notification port, adapter, channel or dependency of any kind, and two things that change what could honestly be built — a message arriving into the conversation on screen is still marked unread, because `ChatConversationView` marks read exactly once from `initState`, so `messages.unread` alone cannot answer "is the user looking at this"; and inbound **group** messages set no unread state at all, because `commitMessageInsideTransaction` writes neither `unread` nor `unread_count`, which is a piece-18 gap left unfixed here because `GroupChatPage` also never marks a group read. Three of ADR-046's Layer 3 details are amended on evidence. **One aggregate notification, not bounded individual ones plus a summary**: with a sender-neutral preview, N notifications are N copies of one sentence, and the only thing they add is a per-message or per-conversation identifier visible to `system_server` and to any app holding notification access — which the threat model's "person with filesystem access to a locked device" adversary and its protection of "notification previews" both weigh against; `MessagingStyle` and conversation shortcuts were rejected outright for publishing a pseudonymous per-contact identifier into the launcher, and an unspecified per-package cap (AOSP near 50, OEM-variable, unqueryable) makes any count-growing design unspecified. **A reconciliation of durable state, not an emission from `PostInboxCommitWorkPort`**: that hook fires only when the engine runs, so it can announce but never *withdraw*, and read-elsewhere, withdrawn-by-sender, conversation-opened and mute are all changes to committed state that no post-drain hook observes; drift dispatches table updates only after `COMMIT` (`Transaction.complete()` precedes `disposeChildStreams()`, verified in pinned 2.34.2 source), so a stream over `messages` and `conversations` is a strictly post-commit trigger and preserves ADR-046's actual principle more directly than the hook did. **A boolean `messages.alerted` (schema 12), not `notified_at`**: nothing reads the time, and it survives projection rebuilds because the projector upserts with a companion that omits the column, the same mechanism that already preserves `starred`. Content is `New message` / `New messages` and nothing else — no sender, conversation, text, count or timestamp — `VISIBILITY_PRIVATE` with a matching `setPublicVersion`, because Android 15 shows that during screen sharing and otherwise redacts "without any further context". Tapping carries the launcher intent alone under `FLAG_IMMUTABLE`: no destination, no extra, no identifier, so there is nothing to forge and no path around the routing guards. Deliberate silence (muted, on screen) still spends the marker so it cannot surface late; a platform refusal spends nothing, so granting later announces the backlog. "On screen" requires a mounted route **and** a foregrounded application, with an unreported lifecycle read as foreground for ADR-047's reason. One automatic `POST_NOTIFICATIONS` prompt at the point of use, guarded by a durable marker and by `shouldShowRequestPermissionRationale` — true in exactly the one state where a second refusal would make the denial permanent — so the app never nags and never spends the user's last prompt. No dependency: `flutter_local_notifications` 22.3.0 would work but every API needed is in `androidx.core:core:1.16.0`, already declared for `FileProvider`, so the platform half is app-owned Kotlin behind a port that carries no identifier and holds no policy. Only `POST_NOTIFICATIONS` and `VIBRATE` are added; a new architecture test forbids every foreground-service, boot, exact-alarm and SMS permission while ADR-046's Layers 1 and 2 stay unbuilt. Reliability is unchanged and stated: an alert reaches the user only while the process is alive, so ADR-045's `foregroundDeliveryOnly` — which said "There are no notifications" — is now false, its revision moves 1 → 2, and re-delivering the written handover becomes release-blocking. The Kotlin half is **unmeasured**: no rooted image and no signed-in session are reachable from this workstation, so what the notification looks like on a device is a release gate, not a claim. Full reasoning in "ADR-048 in full" below. Opens no production gate and changes no cryptographic behaviour. |
| ADR-049 | Accepted, ownership arbitration corrected by ADR-050, delivery disclosure extended by ADR-052 | A backgrounded client catches up through one persisted periodic `JobScheduler` job at the platform floor, delivered to the isolate that already exists or to a headless one when none does, and never to both; ADR-046's WorkManager dependency and its durable delivery lease are both replaced (2026-08-21) | ADR-046's Layer 1. Nothing was assumed: every Android mechanism that runs without the user was re-derived from primary sources read 2026-08-21, and the scope excludes anything the user must grant, configure or change, which removes the foreground service, the exact alarm and the battery-optimization exemption by definition and leaves deferrable jobs as the only floor. **The dependency is dropped.** `JobInfo` is in the framework at `minSdk` 24 and `setPersisted(true)` survives a reboot with no receiver of this application's own, so `androidx.work` would have added a Room database, a service and a boot receiver to the merged manifest of a security-reviewed artifact in order to schedule one job; the existing test forbidding the `workmanager` package therefore stands and now records a decision rather than an absence. **The durable Drift lease is dropped too, and replaced by something exact.** Verified in the pinned engine source, `DartVMRef::Create` documents that "there can only be one VM running in the process at any given time", the `IsolateNameServer` belongs to that VM, and the job service is declared with no `android:process` — so every delivery owner this design can produce is in one process, on one main looper, and in-process arbitration is not weaker than a heartbeat lease but strictly more precise: a job whose process holds a live activity engine sends `runCatchUp` into that isolate and waits for the reply, and only a process with no engine starts a headless one. The hazard being removed is concrete and now evidenced twice over: two `TokenCoordinator`s rotate one refresh token, the loser presents a retired one, the backend returns 401 `invalid_token` (accounts `API.md`) and `TokenCoordinator._endsSession` clears the session — and `beginNextEnvelopeInspection` selects rows in `received` *or* `inspecting`, so two engines would hand the same envelope to the ratchet twice. A foreground session therefore asks the platform for exclusive ownership *before* it opens storage or reads a token, and waits for a headless run rather than killing one mid-call into the shared native core. **A tick is acknowledged, not fired and forgotten**, because a job that is finished lets the process be frozen again and an unacknowledged tick is a catch-up the platform stops mid-drain. **Arming moved off the lifecycle**: a periodic job restarts its window every time it is registered, so ADR-046's arm-on-background/cancel-on-foreground would have meant a user who opens the app more often than the interval never receives one wake-up, and a process that died while foregrounded would have left nothing scheduled at all; it is armed once for the life of a signed-in session and disarmed on logout, and a headless run that finds no session disarms it for itself. **Both entry points now compose through one `ApplicationRuntime`**, so the provisioned authority, the single token coordinator and the environment-gated crypto core cannot be silently absent from the background path; `MainActivity`'s protected-storage and message-alert channels were Activity-scoped and unreachable from a headless engine, and are now Context-bound classes with one implementation each. The alert path needs no change and asks for no permission in the background, because `ReconcileMessageAlerts` already gates the single automatic prompt on `visible.isForeground`. Reliability is stated in four tiers and never as a guarantee: near-real-time foregrounded; *eventual* backgrounded, fifteen minutes at best and bound to Doze maintenance windows that thin out; **nothing** in the *rare* and *restricted* buckets, where Android disables background network and which Android 13+ applies after eight days without interaction; and nothing whatsoever after a force-stop. ADR-045's disclosure moves to revision 3 in both catalogues, which makes re-delivering the written handover release-blocking again. Adds no dependency, changes no cryptographic behaviour, opens no production gate, and leaves the Beta/Production boundary untouched — verified after the change against the built artifact, which packages unsigned, carries the production application ID, exports no beta MLS symbol, and declares exactly one service, bound with `BIND_JOB_SERVICE`, unexported, in the default process, with no foreground-service permission of any kind. |
| ADR-050 | Accepted | Exactly one part of the application drives delivery, arbitrated in the process and asked for by the *entry point* rather than by the delivery session; the losing owner is asked to stand down and gives way between units of work; and losing a refresh-token rotation to another owner is repaired instead of read as the server ending the session; corrects ADR-049 (2026-08-22) | The hazard ADR-049 named is real and reachable on an ordinary user action - a headless catch-up posts a notification (ADR-048), the user taps it, and two Dart root isolates in one process both rotate one shared refresh token that the backend blacklists on use (`ROTATE_REFRESH_TOKENS` with `BLACKLIST_AFTER_ROTATION`), signing out a user who did nothing. ADR-049 chose the right mechanism and put it in the wrong place: `awaitExclusiveOwnership` was called by `MessageDeliverySession.compose`, which is reached only after `AuthenticationController.restore()` - and that restore *is* the rotation. A test asserted the opposite and passed, because its harness replaced the real `TokenCoordinator`; `sync-engine.md` simultaneously claimed a durable lease ADR-049 had already removed. The gate moves to `bootstrap()`, before storage is opened or a token is read; `attachForeground` now asks an in-flight catch-up to stand down, which `DurableSyncEngine` reads between envelopes, pages and batches, so the foreground waits for one unit of work rather than a whole drain; and the coordinator tells a lost race apart from a real session ending by re-reading the shared durable row rather than its own per-isolate cache. ADR-046's durable lease was re-derived independently and rejected again: every owner is in one process, so a lease coordinates things that always die together while adding an expiry, a clock and a stale-holder window - and it would be *weaker* where it matters, because a headless engine destroyed while the process survives leaves a lease nobody releases, whereas the Kotlin arbiter is the code that destroys it. Nothing durable records ownership and no wait is unbounded, so the mechanism cannot wedge delivery. Proved with two real isolates over one real shared SQLCipher store, in both orderings, under repeated contention, and with a contender killed mid-rotation. Separately corrects a pre-existing defect the work uncovered: `account_session` and `account_identity` were upserted without `singleton_id`, which SQLite treats as a rowid alias and auto-assigns, so every write after the first threw `SqliteException(275)`. Adds no dependency, changes no cryptographic behaviour, touches no backend, opens no production gate, and changes nothing the application says about itself. |
| ADR-051 | Accepted, distribution clause and delivery claim amended by ADR-053 | Receiving while the application is not in use is an opt-in capability, off by default: a `specialUse` foreground service that keeps the process out of the cached state so the composed delivery path can keep its connection, armed only after the user grants notifications and the battery-optimization exemption, and stopped by the application itself the moment either is withdrawn; builds ADR-046's Layer 2, amends its distribution clause, extends ADR-050 to a third owner, and takes ADR-045's delivery disclosure to revision 4 (2026-08-22) | ADR-046 sketched this layer and left it unbuilt, and ADR-049 recorded the ceiling it was meant to lift: fifteen minutes at best, Doze deferral, and **no background network at all** in the *rare* and *restricted* standby buckets, where Android 13+ puts an app after eight unopened days. Every mechanism was re-derived from primary sources read 2026-08-22, including Android 17, and two facts neither earlier decision recorded changed the arithmetic: apps on the Doze exemption list are exempt from **App Standby Bucket restrictions entirely**, so enabling this repairs the mandatory floor as well as adding a layer above it; and a long-running foreground service by itself keeps the app in the *active* bucket. The manufacturer half is no longer community reporting: Samsung publishes that sleeping apps (3 days unused and poor system health) have "Job, Alarm, and Foreground-service … restricted", publishes the user's exception path and a deep-link intent to it, and states that since One UI 6.0 foreground services of apps targeting Android 14 "will be guaranteed to work as intended"; Xiaomi publishes only a per-app Background autostart permission. That is better evidence than ADR-046 had and still not measurement, so the vendor half stays **unresolved** and the device matrix stays open. `specialUse` is selected because it is accurate: `dataSync` is capped at six hours per twenty-four and forbidden from a boot receiver at `targetSdk` 35+, `remoteMessaging` documents device-to-device message continuity, `systemExempted` is gated on roles this application does not have — and `specialUse` still carries no timeout, no runtime prerequisite and no boot restriction at API 37. The alternative of **building nothing** was evaluated on the same footing and rejected on three findings, the decisive one being that the brief's own failure mode is avoidable by construction: the platform displays the permanent entry only while the service is genuinely running, and the application re-reads every precondition on every resume and stops the service, and says so, whenever the arrangement is incomplete. No dependency is added, no boot receiver is declared, the choice lives in the encrypted preference table and is deleted rather than falsified when turned off, and the socket gains a four-minute keepalive because a connection a carrier's NAT dropped is never heard from again and must not sit behind a notice saying the application is kept open. Full reasoning, the alternatives, the three separated classes of claim and the enumerated outstanding validation are in "ADR-051 in full" below. This decision opens no production gate. |
| ADR-052 | Accepted | Four user-facing claims were false or read as promising more than the artifact delivers and are corrected; the permanent half of the security notice may no longer name a feature; the disclosure revision becomes a derived value that an edit cannot skip; and the revision a user accepted becomes a durable device-side record that re-presents a corrected statement once — completing the half of ADR-045 that was never built (2026-08-23) | ADR-045 established the disclosure and rejected periodic re-consent correctly, on evidence that still holds. What it did not build was the device side: nothing recorded which revision a user had accepted, so when the revision moved at ADR-048, ADR-049 and ADR-051 the only thing reaching an existing recipient was a release-checklist step a human had to remember, and their install could not distinguish "accepted the current statement" from "accepted one that is no longer true". Auditing the composed artifact rather than its documentation found **four wrong claims, two of them outside the disclosure**. `settingsNotificationsOn` said an alert "can only reach you while this app is running" — false since ADR-049: `deferred_delivery_catch_up.dart` and `sustained_delivery_run.dart` both call `ReconcileMessageAlerts` from isolates with no activity in the process, and the string had never been edited since ADR-048 wrote it. `disclosureUnbuiltSurfaces` said search "do[es] nothing" — false: the chat list filters on title and last-message preview, and a conversation's own search reads that conversation's entire local history, because `watchMessages` applies no limit. `enrollmentProtectsBody` promised that "messages, files, and voice audio" were unreadable to the server, in an artifact that can send no file and carry no audio; it is a **permanent** section, so the fix is structural — it now describes the boundary and names no feature at all, and a test forbids feature words in it, because an enumeration goes stale every time the feature set moves. `chatsSearchHint` promised "chats and messages on this device" for a box that matches names and one preview line. Two further statements were true but read as promising more: `disclosureBestEffortDelivery` described delivery as slow, which a reader takes to mean *eventual*, while the server prunes undelivered envelopes on a retention timer clients are never told (`ENVELOPE_TTL_DAYS`, default 7) — late and never are different outcomes and only one was disclosed, so a new point states it, and states that the client will not name what was lost, because `SyncProjection.isSecurityBlocked` is dead code and a one-to-one queue gap surfaces nowhere; and the same point omitted Data Saver, which blocks the catch-up's `NETWORK_TYPE_ANY` request on exactly the metered connection this audience pays for, and which the written handover had been stating while the application did not. `enrollmentDoesNotProtectBody` stated a real limitation in vocabulary the reader cannot decode — "social graph", "out of band", "compare fingerprints" — while the screen it instructs them to use is titled *Safety number*; a limitation a reader cannot act on is a limitation that was not disclosed. **The mechanism is corrected rather than the strings.** Each `DisclosurePoint` now carries the revision at which its wording last moved, `DeploymentDisclosure.revision` must equal the highest of them, and the pinned-text test fails on any edit — so an edit forces a `since` bump and a `since` bump forces the revision, and the bump can no longer be forgotten by a person, which is how three revisions shipped with nothing checking them. The accepted revision is recorded in the encrypted preference table as one integer and nothing else — no timestamp, no identifier — never lowered, written by enrollment before the session opens, and read by a gate that wraps the routed child above the router, so no route, deep link or notification tap reaches the application without passing it. A reader from revision 4 sees the statement again with the four moved points badged; a reader with no record at all — every recipient who enrolled before this — sees the whole statement with nothing badged, because 0 means the application does not know what they saw and may assume nothing read. Periodic re-consent stays rejected on the evidence ADR-045 cited and on newer evidence that strengthens it: Vance et al. (MIS Quarterly 2018) show attention to a repeated warning collapsing within days and polymorphic variation restoring adherence at three weeks, and Vance et al. (MIS Quarterly 2025, "The Fog of Warnings") show habituation *generalising* from ordinary notifications to security warnings never seen before, which is decisive here because this artifact now posts message alerts and a permanent foreground-service notice — so the correction is a full screen the application shows nowhere else, and the "changed" mark is a labelled badge rather than a colour. It **fails open** in exactly one direction: an unreadable preference row withholds the gate rather than the application, because an honesty mechanism must not become a denial of service, and a failed write costs one extra showing. The written re-delivery stays release-blocking and is corrected too — `deployment-and-release.md` claimed "the same seven facts" while listing six, omitted the unbuilt surfaces and the ADR-051 opt-in, and is now generated from the same point list. Language parity is enforced catalogue-wide instead of by three hand-maintained key lists that a new English-only key passed. Adds no dependency, changes no feature behaviour, touches no backend file, opens no production gate, and leaves the Beta/Production boundary untouched: production and development still carry no disclosure and cannot render Private Experimental wording. Disclosure revision moves 4 → 5. Full audit, evidence, alternatives and sources in "ADR-052 in full" below. |
| ADR-053 | Accepted | Sustained delivery is withheld from every build that reaches a user until it has been measured on real phones: a source-only evidence ledger with seven mandatory matrix cells, admissibility rules that refuse an emulator, a short run or a single observation, and ten falsifiable criteria fixed before anything was measured; amends ADR-051 and restores ADR-046's distribution clause in an enforced form (2026-08-23) | ADR-046 required the physical-device matrix before this layer could be enabled in a distributed artifact; ADR-051 removed that clause because the matrix could not be run in the available environment. It still cannot: there is no physical Android device of any kind here, and behind that the capability cannot start on any target without an operator-activated account, because `runSustainedDelivery` refuses anything short of a full device-bound session. So **no cell of the matrix has been run**, and "we cannot measure this" is a reason to withhold a capability, never a reason to ship it — the failure it risks is a person who was told messages would arrive and was not told about one for hours, a failure whose entire signature is absence. The gate is a compile-time constant with an empty ledger: beta and production resolve `withheld`, development resolves `measurementOnly` so the matrix can be run at all. A withheld build never asks the platform for anything, never writes the durable choice, never starts the service, and **stops** one an earlier build left running. Opening it needs seven records that each pass `isAdmissible` — not emulated, a strict ISO date, a committed run record, ≥ 24 holding hours, ≥ 20 timed deliveries, ≥ 3 repetitions — and an inadmissible record simply does not count rather than being refused. Two fleet figures ADR-051 recorded are corrected on a re-read of Statcounter (2026-08-23): Samsung and Xiaomi are **90%** of the *Android* fleet rather than 77% of all mobile, and Android 13-or-earlier is **60%** rather than "roughly half", so the fraction covered by no vendor statement is about 78%. One user-facing claim is withdrawn: `sustainedWhatItDoes` promised delivery "within seconds" in a build where nothing had ever been timed. Measured, on two AOSP emulator images only: every observation surface works unrooted, and their Doze constants differ by a factor of thirty with the freezer off at API 30 and on at API 35 — so the procedure reads constants per device, and whether the freezer even exists on Android 11–12 is now an explicit question for two cells. `docs/sustained-delivery-validation.md` holds the criteria, the matrix and the results; `tool/measure_sustained_delivery.sh` is the instrument |
| ADR-054 | Accepted | The delivery and notification path's platform integration was enumerated from the code and decided point by point: nine of twelve points are written on the framework and three adopt `androidx.core`, which was already in the artifact and is now pinned at 1.16.0 for a stated reason; `connectivity_plus` stays at 6.0.5 because 7.1.0 and later force `androidx.core` 1.18.0 and with it `compileSdk` 36.1; the Android dependency set is locked for the first time, four declared-and-unused packages and a retracted `jni` 1.0.1 are removed, `ACCESS_NETWORK_STATE` is declared where it can be justified, and an exported receiver `androidx.profileinstaller` merged into every artifact is refused (2026-08-24) | A dependency that nobody decided is still a dependency the artifact carries. Every integration point was traced from the code rather than from a package list; what is adopted is pinned exactly and recorded in `android/app/gradle.lockfile` and `pubspec.lock`; what is written is bounded by a port this project owns; and the shipped `classes.dex` is proved to contain no code capable of opening a network connection at all. Supersedes ADR-007's adoption of Flyer Chat, which piece 15 contradicted without a record. |
| ADR-055 | Accepted, exposure amended by ADR-056 | The first externally distributed artifact exposes **direct messaging only**; closed-beta PQ MLS group messaging is withheld in substance behind a source-only evidence ledger that opens when the packaged native core has been observed executing on real ARM hardware; amends ADR-044's tier 2 and takes the disclosure to revision 6 (2026-08-24) | ADR-044 put groups in the deployment as a declared experimental tier and rejected direct-message-only as its alternative E. Re-deciding on evidence: the group *logic* is well evidenced - 17 Dart test files, a 30-test queue-gap recovery matrix, fork convergence, crash injection, 128 Rust tests under `--all-features`, 12 fuzz targets - but `cp_crypto_v1_beta_mls_operation` has **never executed on any device or emulator**, which the repository's own records already said in five places. The `beta` Cargo profile is the only one linking `aws-lc-sys`, C and assembly cross-compiled per ABI, and `catch_unwind` at the C ABI contains a Rust panic but not a fault below Rust - which would take the direct-message tier down with it. Three asymmetries decide it: a pruned envelope costs a Double Ratchet session some messages and costs an MLS member the whole group, unrecoverable without an owner removing and re-adding them, in a deployment whose delivery timeliness is entirely unmeasured and whose server prunes at 7 days (`ENVELOPE_TTL_DAYS`, read from backend source); a device whose core is wrong on its ABI still uploads KeyPackages, so peers add it, consume them, and *they* carry a member who never converges - a failure whose signature is absence on somebody else's phone, the category ADR-053 refused to ship; and withholding is free to reverse while exposing is not, because ADR-036 has already *scheduled* experimental group history for destruction. ADR-044's alternative E was rejected partly on the ground that the outstanding evidence could only be produced by people using the feature; that is false in its own terms, because *does the packaged core compute correctly on this CPU* needs one person with one phone, no backend and no second device, and is separable from *does the group system work between people*. So the gate is an evidence ledger rather than a removal: nothing is unwired, ADR-036, ADR-037, ADR-039, ADR-040 and ADR-041 are untouched and every one of their tests still runs, and `tool/measure_beta_mls_core.sh` runs the crate's own beta test suite on-device with nothing added to the application. Withheld means withheld: the unsupported adapter on all nine port methods, **no KeyPackage generated or uploaded**, no post-inbox maintenance composed, inbound group objects refused, screens closed, and the Contacts entry disabled and labelled rather than routing to a refusal. Also fixes a real defect - three group screens checked their injected-collaborator path *before* the availability gate, so a caller could render the flow around it. External research on 2026-08-24 found nothing arguing against exposure and no deadline forcing it: `aws-lc-sys` 0.40.0 is patched against all five filed RustSec advisories, `mls-rs` 0.55.2 is unaffected by the one security fix in its update range (it lands in a crate this project does not use), Android aarch64 is a supported `aws-lc` platform, `TBD2` is still unassigned at draft-06, and developer-verification enforcement reaches only four countries' app stores on 2026-09-30 with global rollout in 2027 - discharging ADR-044's revisit condition 6, which required the primary source be read and dated before any of it became binding. The decision therefore rests on the repository's evidence rather than the ecosystem's: an officially supported platform is a statement of intent, not an observation of this build on this hardware. Production is untouched and provably so - a test asserts a fully satisfied ledger still leaves production holding no permit. Opens no production gate and supersedes nothing. |
| ADR-056 | Accepted | The closed-beta PQ MLS core was measured on real hardware and the group surface opens on the ABI that was measured and no other: the evidence gate becomes per-ABI rather than per-artifact, `arm64-v8a` is open, `armeabi-v7a` and `x86_64` stay withheld, and the disclosure moves to revision 7; amends ADR-055 (2026-08-24) | A Samsung Galaxy A56 (SM-A566B, Android 16, API 36, retail `user` build, `release-keys`) became available, so ADR-055's one outstanding item was run rather than argued about. `tool/measure_beta_mls_core.sh arm64-v8a` cross-compiled the crate's own `--features beta-pq-mls` test binary with the pinned toolchain, pushed it to the phone and ran it there, installing nothing and needing no backend, account or root: **128 passed, 0 failed, 3 ignored in 172.07 s, exit 0** - the *same* counts `cargo test --locked --all-features` gives on the x86_64 host, so the device ran the whole suite to the same conclusion rather than a subset that happened to link. Forty `mls_beta::` tests ran, including the create/join/private-message/proposal/commit/remove round trip and `suite_signs_with_ed25519_and_round_trips_hybrid_hpke`, which is where `aws-lc`'s ML-KEM runs - the C-and-assembly dependency the `beta` profile adds and `foundation` does not. Contact with hardware also exposed two defects in the instrument, neither findable any other way: MSYS rewrote `adb push … /data/local/tmp/…` into `C:/Program Files/Git/data/…` so the first run failed with `remote secure_mkdirs() failed`, and the three setup lines sent stdout to `/dev/null` while `adb shell` folds remote stderr into stdout, so that failure printed nothing at all. Both fixed. The A56 reports an **empty `abilist32`** - its Exynos s5e8855 is 64-bit-only and cannot execute AArch32 - so `armeabi-v7a` is unmeasurable on the hardware that measured `arm64-v8a`. ADR-055's all-or-nothing framing then left only two moves, both bad: demote the cell for being unmeasurable, which is the reason ADR-053 exists and which ADR-055 explicitly pre-refused; or withhold from everyone over a 32-bit device nobody in this deployment is known to have, while ignoring a passing run for the ABI every recipient loads. So the *question* changed rather than the standard: one APK carries three libraries and the installer picks one, so `hasEvidenceFor(GroupMlsFieldCell?)` replaces the global `isOpen` and the permit takes the running ABI. **No cell was demoted** - `armeabi-v7a` stays in the ledger recorded as unmeasured, and opens on the same rule if 32-bit hardware ever appears. This is **stricter** than ADR-055 where it matters, not looser: under ADR-055 a satisfied ledger would have opened every ABI including one added later with no run behind it, while now an ABI without an admissible record is withheld whatever else the ledger holds, and an ABI this artifact packages no library for maps to no cell and fails closed. The ABI is **read, never chosen** - `Abi.current()` is fixed by the AOT snapshot the platform loaded, reaches the application through one `runtimeAbiProvider` seam that a test asserts is the only caller, can only narrow, and cannot reach production, which fails the environment test first and packages a core without the symbol. Rejected: opening globally on one ABI's record; demoting the cell; dropping `armeabi-v7a` from the APK, which would deny a 32-bit user the whole supported direct-message tier to protect them from an experimental group feature; and blanket risk acceptance, because once `arm64-v8a` was measured there was no blanket risk left to accept - only 32-bit ARM, which per-ABI resolution removes outright for about sixty lines. Closes none of the seven production gates, does not satisfy gate 6 (process kill, Doze, force-stop, torn writes and Keystore-after-reboot are still unrun), reviews nothing, and leaves multi-device and live-backend execution outstanding. Production re-verified: rebuilt and `verify_release_apk.sh --production` passed all seven checks, and a test asserts a fully satisfied ledger still leaves production holding no permit on any ABI. Disclosure moves 6 → 7. Opens no production gate and supersedes nothing. |
| ADR-057 | Accepted | The remainder of piece 21 is built as it was measured rather than as it was described: local search needed one shared surface and a group entry point rather than an encrypted index; the settings set gets Appearance, Security & recovery with a real recovery-secret replacement, About and a user-initiated diagnostics export; and the export is made incapable of carrying a prohibited value by its type rather than by review (2026-08-25) | Three of piece 21's named remainders turned out to be three different situations, and the audit that found that out is the decision. **Search was already built and the checklist said it was not.** ADR-052 had already established the two-surface design and pinned it with a test; the row `Local search | Pending Android encrypted index` had never been updated and was wrong in both halves. The phrase "Android encrypted index" traces to one sentence in `local-data-model.md` and to the piece-21 prompt that repeated it; the only *accepted* decision about search is ADR-012, which says the server never receives content or search terms and says nothing about an index. Meanwhile the encrypted database already **is** the index the sentence asks for: `messages.projection_ciphertext` holds the decrypted body inside SQLCipher under a Keystore-wrapped key, `watchMessages` reads it with no `LIMIT`, and a second FTS structure would duplicate every message body into a second place, enlarge what a wipe has to reach, and buy nothing at this deployment's scale. So no index is built, the sentence is corrected to describe what exists, and the row is corrected. What search *did* need was the gap the audit found: `GroupChatView` had no search at all and Group Info offered a permanently disabled "Search this chat" button — a control that can never succeed, which the UI specification's own core rules forbid. One shared `showConversationSearch` now serves direct, saved and group conversations, so the scope notice, the empty states and the result cap cannot disagree between two surfaces promising the same thing; and the cap, which was silently 30, is now stated on screen when it bites, for the reason ADR-052 corrected `chatsSearchHint`. **The settings set was genuinely absent and one of its screens could not be built honestly without a new primitive.** §15.2 requires that an unlocked device be able to generate a fresh recovery secret, re-wrap the same cross-signing identity, upload a higher backup version and invalidate the old secret — and the crypto core had no operation that re-wraps without regenerating. `cp_crypto_v1_rotate_recovery_secret` adds one. It changes no construction, no ciphersuite and no state format: it parses the existing package, draws fresh entropy, and calls the same `encode_recovery_secret` and `encrypt_backup` the first upload used, so the encoded package is byte-identical to the original apart from the recovery and backup fields, master signature included, because Ed25519 signing is deterministic. Generating a new *identity* instead — the only thing the existing API could have done — would have silently un-verified every contact and invalidated every device cross-signature, which is why the caller may not reach for `prepare_first_identity` here. The flow's ordering is the security property: the secret is shown **only** after the server accepted the higher version, and every refusal says the current secret still works, because the server still holds the blob it opens. Nothing local is rewritten, so no crash can leave a device holding keys that do not match a backup. **The diagnostics export is made safe by its type.** A report is a list of typed entries whose keys are an enumeration and whose values are constructible only from a boolean, an enumeration, a bounded integer or a declared constant — there is no constructor taking runtime text, so a username, a display name, a message body, a device label, a token, a server origin, a capability or a key cannot reach the export, not because a reviewer checked but because the type will not hold one. Counts leave as orders of magnitude and the timestamp is an hour, because an exact description of one person's usage is a needlessly precise thing to put in a document they may hand to somebody else. What is on the screen is byte-for-byte what the copy button copies, in locale-independent ASCII: a screen showing a friendly summary while copying something larger would ask a person to share a document they have not read, which is the failure this surface exists to avoid. The application sends it nowhere and says so; the clipboard is the whole export path and where the text goes next is the user's decision. The counters it reports come from `NetworkDiagnostics`, which piece 06 already made payload-free, now recorded in a bounded in-memory counter owned by `ApplicationRuntime` so both entry points count into one — and deliberately never persisted, because a diagnostics buffer that survived a restart would be a durable record of when its owner used the application. Adds no Dart dependency, no Android library, no permission and no manifest component; adds one native symbol to the export allowlist. Four smaller corrections travel with it, all found by the same audit and all in the settings surface set: the in-conversation "Clear history" row closed the menu and did nothing; Linked Devices was entirely unlocalised, printed a raw failure object to the user, rendered a coarse UTC calendar day through `toLocal()` so every reader west of UTC saw the previous day, and offered an "Add device" button routed to `/devices/enroll`, which is not a route this application has. Opens no production gate, touches no cryptographic construction, and leaves the Beta/Production boundary, the group gate and the delivery behaviour untouched. Full reasoning in "ADR-057 in full" below. |
| ADR-058 | Accepted | Piece 20's prerequisite becomes seven objectively checkable conditions that fail closed, replacing ADR-044's requirement that somebody make a decision; no exporter is granted and piece 20 stays unstarted (2026-08-25) | The prompt's original condition — piece 19 passing every production gate — is unreachable by this project's own record, since `mls-profile.md` states that gate 2 "cannot be reached by any work inside this project", so as written piece 20 was dead rather than blocked. ADR-044 diagnosed that and re-scoped it to "a decision about which MLS exporter it may derive media keys from", which was right in direction and left the bar unset: whoever wrote the granting ADR would set their own. Two things have also changed underneath it. ADR-055 and ADR-056 landed four days later and made the exporter's availability per-ABI, so on `armeabi-v7a` and `x86_64` the beta MLS stack is withheld entirely and ADR-044's path (b) points at something those devices cannot reach. And the exporter is not reachable as key material on any ABI: `mls_beta.rs` returns SHA-256 over `export_secret` as an epoch-agreement digest and no exporter secret crosses the FFI boundary, so keying media needs a new reviewed native operation nothing had named. The prerequisite is now P1 a granted media-key source named by a dated ADR, in one of exactly two forms; P2 that exporter reachable under its own domain separation and present in the native export allowlist; P3 the same per-ABI permit that governs groups, so voice is never offered where groups are withheld; P4 the frame-encryption contract settled by a recorded decision; P5 an admissible Android wire record under `docs/validation/voice-media/` showing the SFU cannot decrypt; P6 self-hosted LiveKit and TURN with the client package reviewed into the pinned dependency map; P7 a user-facing claim no stronger than the weakest layer underneath. Absence of evidence is refusal, and a partially satisfied list authorizes nothing. This is stricter than what it replaces on every axis: P1(a) preserves the prompt's production condition unchanged, and P2, P3, P4 and P5 are new. Only the four externally blocked registry and ecosystem facts are removed as preconditions for *experimental* voice, and P1(a) keeps every one of them in force for production. No new gate object is added, because voice is neither built nor half-built and a gate with no consumer is decoration; the conditions resolve instead against four mechanisms that already fail closed — the production gate's constructor assertion, `GroupExperimentalGate`'s per-ABI ledger, the native symbol allowlist `build_rust_android.sh` enforces, and the literal dependency map `dependency_policy_test.dart` pins. Also records a conflict rather than resolving it: `voice-and-realtime.md` calls RFC 9605 SFrame the framing contract, `cryptographic-protocol.md` permits LiveKit's own implementation after validation, `backend/SECURITY.md` states audio is SFrame-encrypted, and LiveKit's own documentation names no SFrame anywhere and exposes `EncryptionType` as `kNone`/`kGcm`/`kCustom`. P4 and P5 force that to be answered on evidence. Amends ADR-044's *Piece 20* section, supersedes nothing, opens no production gate, adds no dependency, changes no shipped runtime behaviour, and grants neither exporter path. |
| ADR-059 | Accepted | The chat page's emoji surface is `emoji_picker_flutter` **4.5.3**, pinned exactly, reached only through one app-owned component, and configured so that it writes nothing to disk; it is at once the newest release and the only one that builds under this project's AGP 9 configuration, it reaches no network and bundles no font, and it brings 7 transitive Dart packages and 40 new Android modules that this decision enumerates rather than leaves to be found later (2026-08-25) | The React row sent a hardcoded `👍` and the composer button inserted a hardcoded `🙂`, in an application whose protocol has carried an arbitrary reaction grapheme since it was written and whose UI specification names an emoji reactor as a required surface — a control presenting itself as more than it is, which §8's own core rules call a defect. Making it real needs a picker, and the picker was evaluated as a dependency rather than as a widget. **The version is not a preference.** 4.5.3's entire changelog entry fixes an Android build failure "on AGP 9 when `android.builtInKotlin=false`", which is exactly what Flutter's own migrator wrote into this project's `gradle.properties` beside `com.android.application` 9.0.1; 4.5.0 is where this package moved its Android plugin *to* built-in Kotlin, so 4.5.0-4.5.2 are exactly the releases that cannot configure here and 4.5.3 restores the legacy path conditionally; 4.4.0 and earlier are superseded rather than tested, so 4.5.3 is both the newest release and the only one in its line that builds, with nothing recent to fall back on (follow-up F2). **It passes the constraint that actually governs**: it ships no asset and no font, every emoji is a Dart string literal compiled into `libapp.so`, glyphs are drawn with the platform emoji face, and its whole `lib/` contains no HTTP, no socket, no image URL and no Google or Firebase reference — its one platform call asks `PaintCompat.hasGlyph` which glyphs this device can draw, through `androidx.core`, already adopted at 1.16.0 under ADR-054. An emoji picker that carried its own Apple/Google/Twitter image sets was rejected on precisely this. **What it costs is on the Android side and is stated in full**: `shared_preferences` arrives to hold recent emoji, and behind it `shared_preferences_android` pulls `androidx.datastore` (with a repackaged protobuf and okio) and `androidx.preference`, which pulls **`androidx.appcompat` 1.1.0 from 2019** and the legacy support-library tree with it — 51 modules on a release runtime classpath become 91, of which 40 artifacts are new, in an application that instantiates no AppCompat class and renders nothing through a `RecyclerView`. That is the largest expansion of the Android set since ADR-054 locked it, it is accepted because the alternative is sourcing and maintaining 1500+ glyphs with per-locale names and skin-tone variants in application code, and it is accepted **enumerated**: the lockfile records every coordinate, `dependency_policy_test.dart` pins the resolved release set as a literal, and `docs/third-party-notices.md` now lists 91 modules instead of 51 and names the protobuf inside the AndroidX wrapper. **The storage half is refused rather than inherited.** The package's two `shared_preferences` features are guarded by `RecentTabBehavior` and `SkinToneConfig.rememberSkinTone`; `AppEmojiPicker` sets the first to `NONE` and leaves the second at its default `false`, so no write is reachable and Android never creates the file, because it creates it on first commit and there is no first commit. Everything else this application knows about a person is in SQLCipher under a Keystore-wrapped key; a plaintext list of the emoji they most recently used would be a durable record of their behaviour outside that boundary, which is the category ADR-057 built the diagnostics export's types to be incapable of holding. Losing recents is a real cost, answered where it matters by a fixed set of common reactions one tap away on the message itself rather than by writing a file. `lib/app/design_system/app_emoji_picker.dart` is the only file naming the package, on ADR-006's rule for Forui, and a new assertion in `design_system_boundary_test.dart` fails if a second one appears — which matters here because the package's defaults turn recents *on*. Adds no permission and no manifest component: both new plugin manifests are empty, and `verify_release_apk.sh --production` passes all seven checks on a built artifact, reading the same permission set and the same five components ADR-054 recorded out of the packaged file; the measured cost is +1.57 MiB on an unsigned production release APK, of which +426 KiB is the Android tree (far less than its own footprint, because almost none of it is reachable) and +1.16 MiB is the emoji data itself - after the wrapper named one locale set instead of letting the package's twelve-way switch keep all of them, which returned exactly 4,096,000 bytes and changes nothing a user sees. It does change the build once: these are the first plugin subprojects here that compile Kotlin, every release build of them failed with "Could not close incremental caches" five times out of five, and `kotlin.incremental=false` is now committed in `android/gradle.properties` with the reasoning beside it, because a release that only builds when somebody remembers a command-line flag is a release process with a hole in it. Also records something the regeneration exposed: `--write-locks` resolves *without* the lock while an ordinary build resolves *with* it, and locking applies the recorded versions as strict constraints, so a regenerated lockfile is not automatically a fixed point — one module the unconstrained graph evicts is kept by the constrained one, and the first regenerated lock was rejected by the next release build (follow-up F4). Opens no production gate, supersedes nothing, and changes no cryptographic construction, protocol, wire format or shipped delivery behaviour. |
| ADR-060 | Accepted | A delivery cycle sends the user's message before it reads anybody else's, one envelope's failure stays on that envelope, and an envelope this device can never open is retired through a bounded attempt budget into quarantine and acknowledged (2026-08-26) | Measured on real devices: fifteen to twenty seconds to the first `POST /envelopes`, delivery that never arrived, 1.1 MB/min of idle re-download and up to one and a half CPU cores, all of it client-side against a network and backend measured clean. Every stage of a run returned its first failure and the inbound stages ran first, so one unopenable envelope stopped a sealed, durable outbox row from ever leaving the process; nothing retired that envelope, so the server re-served it forever; and a failed cycle scheduled *reconnect* backoff, whose uniform draw was the wait itself. Also: schema 14 repairs the devices already stranded, `cipher_memory_security` is turned off as a defence against a threat the model excludes and could not complete anyway, the socket hint stays a hint because `pruned_through` is how a lost envelope is detected, a response this client refuses now cancels its transfer instead of buffering it whole, and the always-false presence line is withdrawn until `subscribe_presence` exists. |
| ADR-061 | Accepted | A message is committed and drawn before any network call is made, the fan-out that seals it becomes a durable request the delivery cycle owes, and an outbox attempt transition writes one row instead of re-projecting the conversation (2026-08-27) | Sending a DM rendered its own bubble in over three seconds, and the wait was two authenticated device lookups, a prekey claim and one ratchet step per recipient, all in front of the local commit that makes the message visible. The commit is now first and the fan-out is a row in `pending_send_preparations` (schema 15 -> 16) that the delivery cycle drains before the outbox. Separately, every attempt transition ran `_rebuildConversation`: measured at **195 statements** in a 61-message conversation, three times per send, to move one integer on one message. `messages.status` becomes a column the rebuild carries through rather than re-derives, on the `alerted`/`starred`/`delivered_receipt_sent` precedent, and the transitions now cost **7** and **4** statements. `MessageTransportState.preparing` makes the timeline's existing `encrypting` state reachable, and a retry re-arms the failed operation instead of writing a second message. |
| ADR-062 | Accepted | The conversation timeline reads a bounded, cursor-anchored window instead of its whole history, its three per-message queries become three set-based ones, and the schema gains its first six indexes (2026-08-27) | Opening a conversation cost what had been said in it. `watchMessages` had no `LIMIT` and ran a reactions, a receipts and an attachments query for **every** message on **every** emission: measured at **3601 statements** for one emission of a 1200-message conversation, against **6** now, equal at eight messages and at twelve hundred. `watchConversations` had the same shape one level up and is now two statements rather than one per conversation. The window is a keyset range anchored at the oldest loaded message rather than a count from the newest, so a message arriving cannot push the line the reader is on out of the other end, and `OFFSET` is rejected because it re-scans what it skips. Separately, the schema declared 43 tables and **zero** indexes, so every lookup by a non-leading key column was a full scan under SQLCipher: six indexes (schema 16 -> 17, additive, no table dropped or re-keyed) chosen from `EXPLAIN QUERY PLAN` and asserted against the planner, including a partial index for pins that only works because both callers spell the predicate unbound, and a foreign-key child index on `attachments` that takes one rebuild of a 1200-message conversation from 96 ms to 27 ms. `LoadOlderMessagesIntent` and the three hardcoded pagination fields become real, and a jump to a message outside the window loads it instead of doing nothing. |
| ADR-063 | Accepted | Applying an application event re-folds only the messages that event is a fact about, and the full rebuild becomes the recovery path it always was (2026-08-27) | The last and largest term ADR-061 and ADR-062 left behind: every authenticated event re-projected its whole conversation from the whole event log, so the cost of *receiving* anything was set by how long the conversation was — worst for an inbound receipt, which is one event per batch of messages. Measured end to end, one such rebuild of a 1200-message conversation is **6556 statements and 283 ms**; applying one event now costs **14-16 statements and about 1.1 ms**, equal at 48 messages and at 1200, and a receipt covering thirty-two messages costs thirty-two folds rather than twelve hundred. A new derived-state table, `application_event_targets` (schema 17 -> 18, additive, back-filled), gives the projector the direction the log lacks: which facts a message has. The fold is spelled `CROSS JOIN` because the ordinary form is the same statement count and a linear number of rows, visible only in `EXPLAIN QUERY PLAN`. Conversation aggregates get one definition both paths call, plus a covering partial index for the unread count. The rebuild is kept, made publicly reachable, and deliberately left folding each message against the whole fact set, because it is the oracle a differential equivalence test compares against and it must not come to share the incremental path's idea of which facts belong to which message. |
| ADR-064 | Accepted | A rebuild re-derives the messages that changed and redraws the rows that changed, the reading anchor comes from the rows that are mounted, and a keystroke costs a timer instead of a database write and a page rebuild (2026-08-28) | The last three terms ADR-061, ADR-062 and ADR-063 left behind, all of them on the main isolate. Measured on the A56 in a 219-message conversation with the whole thing drawn: typing goes from **5.25 ms median / 8.13 p90 / 9.89 worst** of build time per frame to **2.33 / 3.76 / 6.57**, and produces 38 frames for thirty characters where it produced 55, because the page is no longer one of the things that rebuild; a message arriving goes from **1.77 / 5.02 / 7.49** to **0.82 / 3.23 / 5.97**. On the host, where a long conversation could be driven, the frame that draws an arrival went from 36.7 ms median at 1200 messages (19.7 at 48) to 10.9 (13.7 at 48), and a keystroke from 32.7 (16.8 at 48) to 4.0 (5.1 at 48) — before, both roughly doubled with conversation length; after, neither grows. `ChatMessageProjection` returns the identical view model for every message whose row cannot have changed, keyed on the whole `ConversationMessage` plus the positional inputs grouping and reply quotes actually depend on, so one arrival derives **2** elements and one reaction **1**, equal at a 48-message window and a 240-message one, against the whole window on every emission before; the timeline retains the built row behind it, so `Element.updateChild` skips it outright, and every row is keyed with a `findChildIndexCallback` so an arrival relocates elements instead of re-parenting a `GlobalKey` per row. `_messageKeys` becomes a registry of *mounted* rows — bounded by construction, and always the only set an anchor could come from — and the anchor is captured in `didUpdateWidget`, in `didChangeDependencies` and at scroll end, rather than additionally on every build and every scroll tick. The draft is debounced 500 ms and flushed on blur, route pop, leaving `resumed`, dispose and send, and the cascade that made a keystroke rebuild the page is cut in the provider layer — the draft becomes a one-shot read, typing narrows to a boolean through `select`, and the forward targets become a callback — because the draft must keep living in the `conversations` row. Also: `DateTime.now()` leaves `build` for a clock refreshed exactly when the earliest mute on screen expires, a jump no longer has its own scroll cancelled by the reading anchor it was leaving, and a jump to a target already inside the drawn range asks for the frame nothing else was going to schedule. Schema stays at 18; no repository, projector, outbox, sync-engine or backend file is touched. |
| ADR-065 | Accepted | A delivery cycle asks the network once per person instead of two to four times, through a thirty-second process-local cache that sits below every authentication gate and never touches a prekey claim; and the device-log gossip a send owes becomes a debt the cycle records and pays after the outbox instead of a second fan-out awaited in front of the first one's ciphertext; closes the RCA ADR-060 opened (2026-08-28) | `ClientAuthenticationService` was entirely uncached, so one `prepareOwedSend` fetched a peer's identity — an unconditional full `200`, because `/identity` offers no ETag — twice, three times when a session had to be started, and again for the gossip owed to the same peer moments later, against a round trip ADR-060 measured at **107-137 ms**. Measured on the composed send path with a synthetic 122 ms round trip: a first contact and its gossip fall from **14 round trips / 1828 ms to 6 / 788**, a send and its gossip from **8 / 1051 to 4 / 528**, two sends to one peer from **8 / 1037 to 4 / 522**, and the time from `prepare` starting to a postable ciphertext from **8 / 1028 to 4 / 512** — the last of those is F7 alone, because half of it was a fan-out owed to somebody else. The cache decorates `PeerIdentityRemotePort` rather than memoizing `AuthenticatedPeer`, so a hit is the *same* verification over the same bytes: the master-key comparison, the unsigned-device rejection, the transition check, the hash chain, `requireCurrentLiveSet`, the trust states and the global fork gate all still run, and a suite proves each rejection is reproduced on a hit with zero further requests. `claimPrekeyBundles` reaches no map, no in-flight entry and no bypass check, because it consumes one-time prekeys and is `ReplaySafety.never`. The device log is coalesced but never stored: a stored page outlives the head that said what to expect, and a mismatched head is read as a fork, which would withhold every send to every peer. `refreshPeer` and `confirmOutOfBand` are forced live by the service itself, which is what makes user verification and the `stale_devices` path bypass it with no call site changed. Gossip's failure isolation stops being a swallowed `try`/`catch` and becomes a `void` return with no future to await; a bare `unawaited` was rejected because a headless catch-up (ADR-049/ADR-050) disposes its container and closes its database the moment `synchronize()` returns. Schema stays at 18; no migration, table, column or index, no endpoint, header or status-code change, no cryptographic construction touched, and no `backend/` file. |
| ADR-066 | Accepted | Supersedes ADR-007: the conversation timeline is an app-owned reversed sliver because Flyer requires mutable controller-owned message state and ADR-002 puts that state in drift, not because a package was slow; custom ownership is bounded to the timeline surface and Material keeps every surface the user types into or selects within; and the first thing owning it costs is a first-strong direction resolver that is correct where neither the previous regex nor `intl`'s `Bidi` is (2026-08-30) | ADR-007 named a package `pubspec.yaml` has not carried since ADR-054, and it did so for the whole interval between piece 15 replacing the adapter's contents and this row. The reason on the checklist is the durable one and was never promoted into the register: Flyer 2.11.1 keeps messages in a mutable controller it owns, and ADR-002 makes drift the single source of truth, so the two want the same state in two places — an architectural conflict, decided before any frame was measured. **The performance record is corrected rather than inherited**: ADR-062, ADR-063 and ADR-064 fixed F8's whole-window mapper re-derivation, F9's unpruned `GlobalKey` walk and F10's per-keystroke draft write, and all three were application-layer costs that no package choice caused and no package choice would have fixed. Custom rendering did not buy that performance; measuring the mapper, the key registry and the provider cascade did. **The boundary is stated so "custom" cannot drift into "from scratch"**: app-owned covers the timeline surface — the reversed sliver, the keys and `findChildIndexCallback`, pagination, author grouping and bubble geometry — while Material remains the foundation for text fields, sheets, menus, dialogs, selection and focus traversal, because IME composition, RTL caret placement, selection handles and TalkBack semantics are not being re-implemented here. ADR-006's rule for Forui and the assertion in `design_system_boundary_test.dart` are unchanged and still the thing that keeps the package out of `lib/features`. **What owning the bubble actually costs is measured on its first bill.** `_contentDirection` was not first-strong: its class was the block range `֐-ࣿ`, which contains Arabic-Indic (U+0660-U+0669, class AN) and Persian (U+06F0-U+06F9, class EN) digits, so `۱۲۳ hello` resolved RTL where UAX #9 P2 skips both and answers LTR, and it contained neither Arabic Presentation Forms block, so a `ﻲ` pasted from a legacy Windows source resolved to nothing at all. `intl` 0.20.2 was read in the pub cache rather than recalled and **rejected as a replacement on evidence**: its `Bidi.startsWithRtl` is structurally first-strong but its `_RTL_CHARS` is `֑-߿`, which repeats the digit defect exactly, while its `_LTR_CHARS` claims `ࠀ-῿` wholesale and hands Samaritan, Mandaic, Syriac Supplement and Arabic Extended-A to LTR; `Bidi.detectRtlDirectionality` is not first-strong at all but a whitespace-token count against a 0.40 threshold, with a `^http://` special case a `https://` URL does not meet. The two implementations are wrong on **different** inputs and neither is a superset, so `resolveFirstStrongDirection` replaces both, on R/AL/L ranges from `DerivedBidiClass` with the weak, neutral, mark and format classes falling through, plus P2's isolate-run skipping; 29 tests hold it, including the executable comparison against both predecessors. **The isolation half of the finding was tested and half of it did not exist**: an embedded Latin URL with trailing punctuation inside Persian needs no FSI/PDI, because Flutter runs UAX #9 per paragraph and there is no second direction spliced into that string, and that non-defect is recorded so it is not re-fixed; the real one is the composer's character counter, where `20 / 500` is two EN runs around a neutral and N1 resolves the separator to an RTL base, reversing the pair to `500 / 20`. It is pinned to LTR, which is how the expression reads in either locale. A fourth golden, `chat_medium_rtl_mixed.png`, holds all three mixed-direction cases in one RTL frame; the existing three were not regenerated. Schema stays at 18; no migration, table, column or index, no repository, projector, outbox or delivery behaviour, no endpoint, header or status code, no cryptographic construction, no protocol, no wire format and no `backend/` file. **Opens no production gate.** |
| ADR-067 | Accepted | Supersedes ADR-042: the serving origin becomes `chat.orviniq.com` and the flavors move to `com.orviniq.chat{,.beta,.development}`, the Beta signing identity is reissued under a matching subject, and the private CA is reused rather than replaced — but the leaf reissue moved the primary SPKI pin, which is the one thing in this migration that would have been unrecoverable a day later (2026-09-07) | ADR-042 froze the application ID on a premise that has since become false: the flavors took `dev.nimashadloo.chat{,.beta,.development}` "under a domain the project already operates", and the project no longer operates that domain. **Its reasoning is not what failed — only its premise.** Everything ADR-042 says about why the identity must be frozen is unchanged and now governs the new one: Android accepts an update only when the application ID and the signing certificate both match, the only path past a mismatch is uninstall, and uninstall destroys the SQLCipher database and the `no_backup` envelope holding its key with `allowBackup="false"` and a non-exportable AndroidKeyStore key behind them. **The freeze was breakable here because it had not yet bound.** No external install existed — no device, no emulator outside CI, no archived artifact in anyone's hands — so there was no update path to break and no local history to destroy. That is a fact about 2026-09-07 and not a property of the decision: the freeze re-binds from this point, and the next time this question is asked the answer is no. **The private CA is untouched and did not need touching**: it is hostname-agnostic by construction — subject `CN=chat private root CA`, `CA:TRUE, pathlen:0`, no `nameConstraints` and no SAN of its own — so it signs for the new host unchanged, and `BETA_PRIVATE_CA_SHA256` and `BETA_PRIVATE_CA_PEM_BASE64` keep their values. Verified rather than assumed: `ca.crt` and `ca.key` carry their original 2026-08-19 mtimes, and the reissue archive holds a leaf pair and no CA. **One pin moved, and the premise that neither would was wrong.** A pin covers a key, not a hostname, so a leaf reissued for a new name over the same key would have held both pins — but `ops/tls/make_ca.sh` does not reissue that way. It guards `ca.key` and `backup.key` behind `if [ ! -f ]` and mints `server.key` unconditionally on every run, so reissuing the leaf regenerated the server key and the **primary** SPKI pin with it; the backup pin, keyed to the untouched `backup.key`, did not move. Measured off the archived and current certificates, not argued. `BETA_PRIMARY_SPKI_SHA256` must therefore be re-read before the next Beta build, and a client carrying the old primary pin cannot complete a handshake against the new leaf at all. Today that costs nothing, for the same reason the identity move costs nothing; on any later day it locks out every provisioned device, which is the sharper half of ADR-043's two-pin rule and the reason the second pin exists. **The Beta signing identity was reissued as coherence, not correctness.** Nothing in Android, Gradle or `verify_release_apk.sh` enforces a match between a certificate subject and an application ID; a key reading `CN=dev.nimashadloo.chat.beta` would have kept signing `com.orviniq.chat.beta` artifacts indefinitely and no check would have objected. It was reissued because the freeze could still be broken safely and would not be again, so the incoherence would have been permanent. Created 2026-09-07, certificate SHA-256 `a1189203…fb9a7ba9`, subject `CN=com.orviniq.chat.beta`, valid to 2054-01-23, read back out of the keystore and matching `android/beta-release-identity.properties` exactly. The previous keystore is **archived, not destroyed**, under `archived-nimashadloo-` names beside the live one. Off-site encrypted backups do not exist for the reissued key: the reissue reset that obligation rather than inheriting it, and `docs/release-signing.md` still requires two of them before the first external install. **Every artifact built before this date is superseded and may not be distributed** — each carries the old origin, the old application ID, the old signing certificate and the old primary pin, and any one of the four is disqualifying on its own. |

## ADR-067 in full — the origin moves, and the one thing that moved with it (2026-09-07)

**Status:** Accepted. **Supersedes ADR-042.** Amends ADR-044. Deployment and client-identity
decision. Touches no Dart source: no server origin is hardcoded in `lib/`, which takes the
origin as a compile-time `--dart-define` and derives the health, socket and attachment URLs from
it, so the migration is a provisioning change and a build-configuration change and nothing else.
**The local schema stays at 18**: no migration, table, column or index, no repository, projector,
outbox or delivery behaviour, no endpoint, header, status code, cryptographic construction,
ciphersuite identifier, protocol or wire format. **Opens no production gate.**

### The question

> The server hostname moved from `chat.nimashadloo.dev` to `chat.orviniq.com`. ADR-042 froze the
> application ID under the old domain and gave a reason that no longer holds. What may be
> changed, what must not be, and what does the change cost that is not obvious from the rename?

### D1. The origin moves, and nothing else about the deployment does

The serving origin becomes `https://chat.orviniq.com`. Same VPS, same architecture, same
private-CA TLS posture, same routes, same ports, same units. What moved is a name: the nginx
site file and both its server blocks, the relay values that name the box coturn runs on, the
provisioning examples, and the documentation that cites the site file as the source of a
measurement. No measurement, date or claim moved with it — the rows in
[`GROUND-TRUTH.md`](../../docs/architecture/GROUND-TRUTH.md) keep the dates they were measured
on, because the rename changes the file a row cites and not what was read out of it.

### D2. ADR-042's premise failed; its reasoning did not

ADR-042 moved the flavors to `dev.nimashadloo.chat{,.beta,.development}` "under a domain the
project already operates." The project does not operate that domain any more, so the sentence is
false and the decision that rests on it cannot stand as written. It is **superseded rather than
rewritten**, on this register's standing rule that an accepted decision records what was decided
and why at the time.

The flavors take `com.orviniq.chat.development`, `com.orviniq.chat.beta` and `com.orviniq.chat`.
The invariant the suite enforces is unchanged and still holds: Beta is exactly
`<production>.beta`. The Gradle namespace `com.example.communication_platform` and the Kotlin
package under it are deliberately **not** part of the application ID and do not move;
`android/app/build.gradle.kts` already documents why.

**What ADR-042 got right is untouched and now governs the new identity.** Android accepts an
update only when the application ID and the signing certificate both match the installed app.
Past a mismatch the only path forward is uninstall, and uninstall is unrecoverable here: it
erases the SQLCipher database and the `no_backup/storage_key_v1.bin` envelope holding its key,
`allowBackup="false"` and `fullBackupContent="false"` mean nothing restores either, the database
key is protected by a non-exportable AndroidKeyStore key so no exportable copy exists, and local
message history has no server-side copy by design. None of that reasoning is weakened by this
decision. All of it applies to `com.orviniq.chat.beta` from this point forward.

### D3. Why breaking the freeze was safe, and why it is not safe again

A frozen identity binds at the **first external install**, not at the moment it is written down.
On 2026-09-07 there was none: no device, no emulator outside CI, no artifact in anyone's hands.
There was no update path to break and no local state to destroy, so rebasing the application ID
cost nothing that a later rebase would cost.

That is a fact about a date, not a property of the decision. **The freeze re-binds here.** The
warning in `android/beta-release-identity.properties` is not weakened by having been stepped
over once; it applies again from this point, and the next time this question is asked under an
install that exists, the answer is no.

### D4. The private CA is unchanged, and one pin is not

The private root CA is hostname-agnostic by construction: subject `CN=chat private root CA`,
`basicConstraints=critical,CA:TRUE,pathlen:0`, `keyUsage=critical,keyCertSign,cRLSign`, no
`nameConstraints` and no SAN of its own. It signs for the new host unchanged, and
`BETA_PRIVATE_CA_SHA256` and `BETA_PRIVATE_CA_PEM_BASE64` keep the values they had.

That was verified rather than assumed. `ca.crt` and `ca.key` carry their original 2026-08-19
mtimes, the reissue archive holds a leaf pair and no CA, and the fingerprint read off the
current `ca.crt` is the one already provisioned. Only the **leaf** was reissued:
`CN=chat.orviniq.com`, `subjectAltName=DNS:chat.orviniq.com`, valid to 2028-12-10.

**The premise that both SPKI pins would survive that reissue was wrong, and this is the finding
of this decision.** A pin covers a public key, not a hostname, so a leaf reissued for a new name
*over the same key* holds every pin. `ops/tls/make_ca.sh` does not reissue that way. It guards
the two keys it means to preserve — `ca.key` and `backup.key` — behind `if [ ! -f ]`, and it
mints `server.key` unconditionally on every run. Reissuing the leaf therefore regenerated the
server key, and the **primary** pin moved with it. The **backup** pin, keyed to the untouched
`backup.key`, did not.

Measured off the archived and the current certificate rather than argued: the two primary pins
differ, the two backup pins are the same file. Neither value is written here, because this
repository carries no real pin and no real CA digest — `docs/release-signing.md` keeps them as
placeholders and calls them public values that stay out of the tree.

The consequence is operational and immediate: **`BETA_PRIMARY_SPKI_SHA256` must be re-read
before the next Beta build.** A client compiled against the old primary pin cannot complete a
handshake with the new leaf — not degrade, not warn, fail closed, which is what ADR-043's
`SecurityContext(withTrustedRoots: false)` posture is for. Today that costs nothing, for exactly
the reason D3 gives. On any later day it is a permanent lockout of every provisioned device,
recoverable only through the backup pin, which is the whole reason ADR-042 required two.

### D5. The Beta signing identity was reissued, as coherence rather than correctness

The old certificate's subject read `CN=dev.nimashadloo.chat.beta`. Nothing enforces a match
between a certificate subject and an application ID — not Android, not Gradle, not
`tool/verify_release_apk.sh`, which checks the artifact's certificate against the recorded
SHA-256 and never reads the subject. That key would have gone on signing `com.orviniq.chat.beta`
artifacts indefinitely and no check anywhere would have objected.

It was reissued anyway, and the reason is the same window D3 describes: the incoherence would
have been permanent the moment the freeze re-bound, and this was the last day it could be fixed
for free. **This is a decision, not a correctness fix**, and it is recorded as one so that a
later reader does not mistake it for a defect that had to be repaired.

| | |
|---|---|
| Created | 2026-09-07 |
| Subject | `CN=com.orviniq.chat.beta`, `OU=Private Experimental Beta`, `O=Communication Platform` |
| Certificate SHA-256 | `a1189203…fb9a7ba9` |
| Valid to | 2054-01-23 |
| Algorithm | RSA-4096, SHA-384, v2+v3, unchanged from ADR-042 |

Read back out of the keystore on the day it was made, and matching
`android/beta-release-identity.properties` exactly.

The previous keystore is **archived, not destroyed** — `archived-nimashadloo-` names beside the
live one — because destroying the only key that can verify a previously distributed artifact is
not reversible either, and the archive costs nothing. It signs nothing from here on.

**The off-site backup obligation was reset, not inherited.** `docs/release-signing.md` requires
at least two encrypted copies on separate media, one of them off-site, before the first external
install. Those copies, if they were ever made, protect the archived key and not the live one.
None exists for the reissued key today; the requirement is unchanged and outstanding.

### D6. Every artifact built before this date is superseded

Any APK produced before 2026-09-07 carries the old origin, the old application ID, the old
signing certificate and the old primary SPKI pin. **Any one of the four is disqualifying on its
own**, and the last of them means such an artifact cannot reach the server even if someone
chooses to ignore the first three. None may be distributed. That includes the production
verification run ADR-044 records against a 2026-08-20 tree: what it checked is still the check,
but the identity it checked against has moved, and the run is re-performed rather than cited.

### Consequences

- ADR-042 is `Superseded by ADR-067 (2026-09-07)` in the register. Its reasoning column is
  untouched, which is the point of superseding rather than editing.
- ADR-044 gains an amendment line. Its identifiers now read as migrated; every decision it
  makes stands on the reasoning written there.
- `BETA_PRIMARY_SPKI_SHA256` is stale in any provisioning environment that predates this
  decision, and no test in this repository can fail on that — the pins are provisioning values
  and deliberately absent from the tree. It is the one claim here that is enforced by nothing.
- `ops/tls/make_ca.sh` regenerates `server.key` on every run. That is correct for first
  generation and wrong for a leaf reissue, and it is why the primary pin moved. Whether the
  script should grow a reissue path that preserves the server key is a separate decision and is
  not taken here.
- The frozen-identity constraint re-binds. This decision is the last one permitted to move an
  application ID or a signing key without an uninstall, and it says so in those words.

## ADR-066 in full — the timeline is app-owned, and the first thing owning it costs is the bidi (2026-08-30)

**Status:** Accepted. **Supersedes ADR-007.** Records a correction of fact against ADR-024.
Client-side decision, entirely in the presentation layer and the decision register. **The local
schema stays at 18**: no migration, no table, no column, no index. Changes no repository, no
projector, no outbox, no delivery cycle, no endpoint, path, header, query parameter, request or
response shape, no accepted status code, no cryptographic construction, no ciphersuite
identifier, no protocol, no wire format and no backend file. **Opens no production gate.**

### The question

> The register says the conversation timeline is Flyer Chat behind an adapter. The application
> has not depended on Flyer since ADR-054, and the checklist that replaced it recorded a reason
> the register never carried. What actually decided that replacement, what did the three
> performance ADRs that followed actually fix, and what does owning a chat bubble outright
> oblige this application to get right that a package would otherwise have owned?

### D1. What replaced Flyer, and the reason that actually decided it

ADR-007 was written as reuse: take Flyer's virtualization, keep an adapter seam, and replace it
later if the seam is not enough. Piece 15 replaced it almost immediately, and the reason is on
the piece checklist rather than in this file: **Flyer 2.11.1 requires mutable, controller-owned
message state.** ADR-002 makes drift the single source of truth precisely so REST, socket and
optimistic state cannot diverge inside a widget. A controller that owns a mutable message list
is a second source of truth for the same rows, and reconciling it against a drift stream is the
divergence ADR-002 exists to prevent, reintroduced one layer higher.

That is an architectural conflict, and it was decided before a frame was measured. It is the
reason this ADR carries, because it is the one that stays true independent of how fast anything
turned out to be.

The seam ADR-007 asked for survived: `ChatTimelineAdapter` still takes immutable application
view models and emits typed intents, and the comment at its declaration still calls itself a
replaceable timeline boundary. What changed is what is behind the seam — a reversed
`CustomScrollView` whose stable indices make upward pagination an append at the far edge, so
loading older messages cannot move the row the reader is looking at.

### D2. The performance record, corrected

The performance argument for a custom timeline is the one most likely to be repeated, and it is
not supported by this project's own measurements.

ADR-062, ADR-063 and ADR-064 fixed, in order: an unbounded per-message read on every emission;
a whole-conversation re-projection per applied event; and then F8, F9 and F10 — the mapper
re-deriving the entire loaded window twice per rebuild, `_messageKeys` growing without bound and
being walked with `findRenderObject()` once per frame, and every keystroke writing the
`conversations` row and rebuilding the page through the provider that watched it.

**Every one of those is an application-layer cost.** None was caused by a rendering package and
none would have been fixed by choosing a different one. F8 is a mapper, F9 is a key registry,
F10 is a provider cascade. Owning the render surface bought none of it; reading
`EXPLAIN QUERY PLAN`, counting derived elements and timing frames on the A56 bought all of it.

Anyone reaching for this ADR as precedent for replacing a package on performance grounds should
read that paragraph first and measure instead.

### D3. The boundary custom ownership actually has

"Custom timeline" and "custom UI from scratch" are different decisions and only the first one is
in force.

**App-owned:** the reversed sliver and its scroll physics, the per-message keys and
`findChildIndexCallback`, pagination and the reading anchor, author grouping and date and unread
separators, bubble geometry and its directional padding, the reaction row, the delivery
indicator.

**Material, and staying Material:** every surface the user types into or selects within — text
fields, bottom sheets, menus, dialogs, the selection controls, focus traversal. IME composition,
RTL caret placement, selection handles, long-press selection and TalkBack semantics are hard,
already correct there, and re-implementing them would trade a bounded rendering problem for an
unbounded accessibility one.

**Forui, unchanged:** ADR-006 stands. Three files under `lib/app/design_system/` name the
package, and `design_system_boundary_test.dart` fails if a fourth appears or if anything under
`lib/features` imports it. Forui is pre-1.0 and `app_theme.dart` depends on it for the visual
identity, which is exactly why the blast radius is three files and asserted rather than assumed.

### D4. First-strong direction, and why neither existing implementation was kept

ADR-016 requires RTL and mixed-direction behaviour to be structural. The bubble already gets the
hard half right — alignment follows the **sender** through `AlignmentDirectional`, text
direction follows the **content** — and those two being independent is the property a package
that couples them cannot be made to honour. The content half was wrong.

`_contentDirection` matched the block range `֐-ࣿ` for RTL and `[A-Za-z]` for LTR. Two
failures, both reproduced as tests before being fixed:

- **Digits are not strong.** U+0660-U+0669 are class AN and U+06F0-U+06F9 are class EN, and both
  sit inside that block range, so `۱۲۳ hello` resolved RTL. UAX #9 P2 finds the first character
  of class L, AL or R and skips everything else; the answer is LTR. *(The RCA framing called the
  Persian digits AN; `DerivedBidiClass` has them as EN. Neither is strong, so the conclusion is
  the same.)*
- **Neither Arabic Presentation Forms block was covered.** U+FB50-U+FDFF and U+FE70-U+FEFF are
  AL and are what text pasted from legacy Windows sources contains. Both resolved to `null`.

`intl` 0.20.2 is already a pinned direct dependency, so it was read in the pub cache rather than
recalled, and it was rejected on what the source says:

| input | old regex | `Bidi.startsWithRtl` | correct |
|---|---|---|---|
| `۱۲۳ hello` — U+06Fx, class EN | rtl | rtl | **ltr** |
| `١٢٣ hello` — U+066x, class AN | rtl | rtl | **ltr** |
| `ﻲ` Presentation Forms-B, AL | *null* | rtl | **rtl** |
| `ﭐ` Presentation Forms-A, AL | *null* | rtl | **rtl** |
| `ࠀ` Samaritan, R | rtl | *ltr* | **rtl** |
| `ࢠ` Arabic Extended-A, AL | rtl | *ltr* | **rtl** |

`Bidi.startsWithRtl` is structurally first-strong — `^[^LTR]*[RTL]` — but its `_RTL_CHARS` is
`֑-߿`, which contains both digit blocks, so it repeats the defect exactly; and its
`_LTR_CHARS` claims `ࠀ-῿` wholesale, which hands Samaritan, Mandaic, Syriac Supplement and
Arabic Extended-A to the wrong direction. `Bidi.detectRtlDirectionality` is not first-strong at
all: it splits on whitespace, counts tokens against a `_RTL_DETECTION_THRESHOLD` of 0.40, and
special-cases `^http://` — which a `https://` URL does not match. The package's own source says
its patterns "are not completely correct according to the Unicode standard. They are simplified
for performance and small code size."

The two are wrong on **different** inputs and neither contains the other, so neither was kept.
`lib/app/design_system/app_text_direction.dart` implements P2 and P3 over
`DerivedBidiClass` R/AL and L ranges, with the weak, neutral, mark and format classes falling
through by omission and the RTL table checked first, so a combining mark inside an RTL block is
not claimed by the broader LTR ranges. P2's isolate-run skipping is implemented. The one
deliberate departure from P3 is that a string with no strong character returns `null` rather
than LTR, so a bare number stays in the reading direction of the conversation around it — which
is also what the code it replaces did. `intl`'s `TextDirection` never enters widget code; the
package is imported only in the test that proves it was the wrong tool.

### D5. What isolation was actually needed, and what was not

The finding said no bidi isolation exists anywhere in `lib/` and named an embedded URL with
trailing punctuation as the symptom. Half of that is not a defect, and the half that is sits
somewhere else.

**Not reproducible, and recorded so it is not re-fixed.** `سلام https://example.com/a?b=1.`
laid out with an RTL base puts the Persian at the right, the URL to its left with its own run
intact, and the sentence-final stop at the far left — which is where an RTL paragraph belongs
to put it. Flutter runs UAX #9 per paragraph, and `message.text` reaches `Text` as one string
with one direction. There is no second direction spliced into it, so there is nothing for an
FSI/PDI pair to isolate. A test asserts the box positions rather than the absence of a bug.

**Real, and fixed at the smallest boundary.** The composer's character counter is the one place
in the file where two independent runs share a paragraph: `'$currentLength / $maxLength'` is two
EN runs around a neutral separator, and under an RTL ambient direction N1 resolves that
separator to the base direction and reverses the pair — `20 / 500` renders as `500 / 20`,
asserted by box position before the fix. The counter is pinned to `TextDirection.ltr`, because
the expression reads left to right in both locales. The reaction chip `'{emoji} {count}'` was
measured too and is not a defect: the emoji sits right of the count under RTL, which is the
mirroring that surface wants.

### D6. The golden that would have caught this

`goldens/chat_medium_rtl_mixed.png` holds three cases in one `fa` frame: Persian carrying an
embedded Latin URL and a sentence-final stop, a bubble opening with Persian digits and
continuing in Latin, and an outgoing Latin bubble whose alignment follows the sender while its
glyphs follow the content. The existing three goldens were regenerated by name filter, which is
to say not at all — only the new file is written.

### Follow-ups

- **F1.** `message.replyQuote` is rendered by a `Text` with no `textDirection` at all, so a
  quoted Persian message inside an English UI, or the reverse, takes the ambient locale
  direction rather than its own content's. It is the same defect class as D4 at a second call
  site and was left alone here to keep this change to what it says it is.
- **F2.** `resolveFirstStrongDirection` covers the BMP RTL scripts, both Presentation Forms
  blocks and the supplementary RTL planes, and for LTR covers Latin, Greek, Cyrillic, Armenian,
  the Indic and South-East Asian blocks, CJK, Kana and Hangul. A script outside that set returns
  `null` and inherits the ambient direction. That is a bounded claim, tested as such, and the
  boundary is stated in the file rather than discovered later.

## ADR-065 in full — the cycle asks once, and gossip goes behind the message (2026-08-28)

**Status:** Accepted. Client-side cost decision, entirely in the contacts, devices and
synchronization composition. **The local schema stays at 18**: no migration, no table, no
column, no index. Changes no endpoint, path, header, query parameter, request or response
shape, no accepted status code, no cryptographic construction, no ciphersuite identifier, no
protocol, no wire format, no transport trust anchor and no backend file. **Opens no production
gate.** This ADR closes the RCA ADR-060 opened.

### The question

> Nothing a user waits on is slow any more. What is left is redundant network work *inside*
> the delivery cycle: the same questions asked of the same server about the same people, two
> to four times per message, and a second fan-out standing in front of the first one's
> ciphertext. What does one message actually cost the network, and what is the smallest set of
> changes that makes it cost what it needs to?

Two answers, coupled. They are the last two findings of the original RCA, F6 and F7 — and
ADR-064's closing list mislabels F7 as "the dio client"; ADR-061 has it right, and it is what
device-log gossip does and when it is owed.

**F6 — nothing about a peer is remembered for even a moment.**
`ClientAuthenticationService` is entirely uncached. One `prepareOwedSend` resolves the peer's
live devices and then this account's, and a send that has to establish a session resolves the
peer a *third* time through `claimVerifiedDevices`. Each resolution is an unconditional
`GET .../identity` — the endpoint offers no ETag, so it is always a full `200` — a
`GET .../devices`, and device-log pages when the head moved. Then the gossip owed to that same
peer runs moments later and resolves both accounts again from scratch. ADR-060 measured a real
round trip from the A56 at 107 to 137 ms against a network and backend it had already cleared.

**F7 — gossip is in front of the message.** ADR-061 moved gossip off the path the user waits
on, and stopped there. `PairwiseSendPreparationAdapter.prepare` still `await`ed
`afterSuccessfulQueue`, so a whole second fan-out — its own two device lookups, its own ratchet
steps, its own commit transaction — ran between a sealed envelope and its `POST`. ADR-060's
governing rule is that a delivery cycle sends the user's message before it reads anybody
else's. Gossip is owed to a peer, not to this message, and it was in front of it.

They are coupled: detaching gossip takes it off the critical path, and caching stops it
re-fetching what the send just fetched. Neither is worth much alone.

### D1. The cache is a response cache, and it sits *below* every gate

This is the whole safety argument, and it is the reason the design is a decorator on
`PeerIdentityRemotePort` rather than a memo on `AuthenticatedPeer`.

`PeerIdentityRoundTripCache` implements the same port `DioContactRepository` implements and
wraps it. `ClientAuthenticationService` is composed against the wrapper and cannot tell the
difference: it receives an identity, a device refresh and a device-log page, exactly as it
would from the network, and then does what it always did. The master-key comparison, the
unsigned-device rejection, `_isValidDeviceTransition`, the hash-chain and
sequence-monotonicity checks, `requireCurrentLiveSet` on the head record, the same-head
pending-window rule, the `masterKeyChanged` and `deviceLogFork` trust states and the global
fork gate all run again, on every call, on every path.

So the rule the phase demanded — *a cache may only ever shorten the path to the same answer,
and may never satisfy a caller the uncached path would have refused* — holds by construction
rather than by review. A cache hit is not a skipped verification; it is the same verification,
over the same bytes, reaching the same verdict without the round trip. It cannot widen a
device set either: the widest set it can serve is one the server itself returned inside the
window.

The alternative — remembering the `AuthenticatedPeer` a resolution produced and returning it
on a hit — was rejected for the obvious reason. It puts the cache *above* the gates, and every
gate then has to be re-derived by hand at the cache boundary, correctly, forever. The
`peer_resolution_cache_test.dart` group *every gate the live path applies is reached on a hit*
exists to hold this: it plants the offending answer in the cache and proves that an unsigned
device, an impossible device transition, a rewound log head, a changed master key, a rejected
identity signature and the global fork gate each produce their own rejection, and their own
persisted trust state, with **zero** further requests.

### D2. Thirty seconds, keyed on the user, and everything that empties it

**The key.** Identity is keyed on `userId` alone. Devices are keyed on `userId` and remember
the ETag that was *sent* to obtain the answer: a `200` is a complete answer and is served back
to any caller, while a `304` is a statement about the ETag that produced it and is served only
back to a caller holding that same ETag. The device log is coalesced but never stored (D5).

**The scope.** In memory, in the process, and nowhere else. The schema does not move and a
restart starts cold, which is correct rather than a limitation: a cache that outlives the
process is a cache that can outlive a revocation it never saw. It is one instance for the
composed application, so the send fan-out, the prekey claim and gossip all ask through it.

**The TTL is thirty seconds, and the number is chosen against what it exposes.** Thirty
seconds is the span of one delivery cycle, which is the only thing this cache is for. Every
redundant resolution named above is inside one: a preparation's peer lookup, its own-account
lookup and the claim's re-resolution are consecutive, and the gossip the same cycle owes that
peer is separated from them by one outbox flush and one inbox pass. Ten seconds covers the
first three and loses the fourth on any device with a mailbox; a minute would start joining
*different* cycles, which nothing asked for and nothing invalidates.

What it costs is bounded and stated. The only thing a TTL protects against is a change that
produced **no local signal at all** — a peer revoking or adding a device while this device
receives no `stale_devices` response, no envelope from an unknown device, no trust transition
and no user action. Every other change invalidates immediately. So the exposure is: a device
revoked or added with no signal is invisible for at most thirty seconds longer than it already
was. That is small beside the window that already exists between sealing a ciphertext and
delivering it, which the outbox's own backoff measures in minutes, and it is far below the
fifteen-minute floor at which the platform can wake a backgrounded process at all (ADR-049),
so no entry can survive from one background catch-up to the next.

**What empties it**, all of it immediate and none of it waiting for the clock:

| Signal | How it reaches the cache |
|---|---|
| A `stale_devices` response | `stale_device_refresh_requests` → `ContactStaleDeviceRefreshAdapter` → `refreshPeer`, which is a forced-live entry point (D4) |
| A user verifying a contact | The verification screen's `refreshPeer` and `confirmOutOfBand`, both forced-live (D4) |
| Any trust-state transition, fork detection or head advance | Written by `ClientAuthenticationService` and by nothing else in the tree, so the answer that produced it is the answer that is held, and the next resolution reaches the same verdict from it |
| A global device-log fork | `hasAnyDeviceLogFork()` is a local read in front of the resolution; no remembered answer is reachable past it |
| Thirty seconds | Everything else |

**Nothing failed is ever remembered.** A failure is precisely the answer that deserves another
attempt, and remembering one would let a dropped connection keep writing `identityUnavailable`
against a contact for the length of the window. Negative caching was considered and rejected
for that reason alone.

### D3. The prekey claim is excluded, and excluded structurally

`claimPrekeyBundles` consumes one-time prekeys on the server and is marked
`ReplaySafety.never`. Serving one twice is a cryptographic fault, not a saved round trip.

It is therefore not "excluded by a condition". It reaches no map, no in-flight entry and no
bypass check: the override is three lines that delegate, and there is nothing in the class it
could be served from. Two concurrent callers asking to claim for the same device produce two
claims or none — never one shared answer — which is the one place single-flight coalescing
would have been actively wrong.

The cached path also *self-corrects* against a device set that is stale in the dangerous
direction. A claim for a device the server has since revoked comes back short, and
`claimed.length != requestedDeviceIds.length` is already `_invalidDevice`.

### D4. Two entry points may never be served, and the service says which

`PeerResolutionCachePort` has three methods — `invalidate`, `invalidateAll`, and
`live<T>(userId, resolve)` — and `ClientAuthenticationService` takes one, defaulting to
`NoPeerResolutionCache`, which remembers nothing.

`refreshPeer` and `confirmOutOfBand` run under `live`. Both exist to answer the question *is
this device's idea of that peer still right* — one asked by a person looking at a safety
number, the other by the delivery cycle acting on a `stale_devices` response — and a cache is
the one thing that cannot answer it. `resolveLiveDevices` and `refreshPeerForDevices` do not,
because they are the fan-out asking the same question of the same peer two to four times
inside one cycle.

Putting that decision in the service rather than in its callers is what makes it hold. It is
knowledge the service owns — nothing else in the tree knows which of its entry points is a
user's question and which is a fan-out's — and it means no call site changed: the verification
screen and `ContactStaleDeviceRefreshAdapter` are byte-identical and are forced live anyway.

`live` drops the user *and keeps them dropped for the whole of `resolve`*, counted rather than
flagged so nested and concurrent resolutions cannot end each other's bypass. Invalidating only
on entry would have left a concurrent fan-out free to hand the refresh the very answer it
exists to replace.

### D5. The device log is coalesced but never stored

`fetchDeviceLog` shares an open request with a concurrent identical one and forgets it the
moment it completes. The asymmetry is deliberate and it is a safety property, not an
optimisation that was skipped.

A *stored* page outlives the device answer that said which head to expect. A page whose
`headSequence` no longer matches the advertised head is read by `_refresh` as a **fork** — it
persists `deviceLogFork`, which trips the global gate, which withholds every send to every
peer. A cache that can manufacture a false equivocation alarm is worse than no cache. Sharing
an *open* request carries none of that risk: both callers receive the answer to one request
made at one instant, which is exactly what they would each have received.

It also costs almost nothing to give up. The first resolution of a cycle advances the stored
head, so every later one in that cycle finds `advertisedHead` equal to it and asks for no page
at all — which is why the log column is empty in the measurements below.

### D6. Gossip becomes a debt the cycle records and pays after the outbox

`PairwiseSendPreparationAdapter.afterSuccessfulQueue`, a `Future<void> Function(String)` that
was awaited, becomes `onPreparedForPeer`, a `void Function(String)` that is called. It records
one string in `OwedDeviceLogGossip`, an in-memory set of the peers this process still owes an
advertisement to, and returns. `prepare` is finished the moment the send's own ciphertext is
durable.

The debt is paid by `DeviceLogGossipPostInboxWork`, a `PostInboxCommitWorkPort` composed last
in the existing `_CompositePostInboxWork`. That position is load-bearing twice over:

- It is **after the first outbox pass**, which is ADR-060's rule: the cycle sends the user's
  message before it does anything on anybody else's behalf. The gossip rows it queues are
  sealed by the second preparation pass and leave on the second outbox pass, in the same
  cycle — so gossip is later, not slower.
- It is **after the inbox has committed**, which makes the advertisement *better*. The inbound
  half of a cycle is exactly what can advance a device-log head, so gossip run here advertises
  the heads this cycle just learned rather than the ones it started with.

**Failure is structural now, not swallowed.** The old guarantee — a gossip failure is not the
send's failure — was a `try`/`catch` and a comment inside `prepare`. It is now a property of
the signature: `onPreparedForPeer` returns `void`, there is no future to await and no result to
inspect, and there is no path from a gossip round back to a preparation whose ciphertext is
already durable. `OwedDeviceLogGossip.settle` cannot fail either; a peer whose round failed is
not re-owed there, because the next send to them re-creates the debt, which is exactly what the
old code did — and nothing records a success that did not happen, so that next send is not
suppressed.

**Coalescing has two mechanisms** because there are two shapes of "quick succession". Inside
one cycle, the owed set does it: two sends to the same peer produce one entry and one round.
Across cycles, a one-minute window does it: a device-log head moves when a device is enrolled,
revoked or rotates a prekey — events measured in days — so advertising the same heads to the
same person twice inside a minute tells them nothing while costing a full fan-out.

### D7. Why a detached future was not acceptable

`unawaited(gossip(peer))` would have been three characters and wrong.

A delivery cycle is not always owned by a process that is going to be there afterwards.
ADR-049 and ADR-050 put exactly one delivery owner in the process, and one of the owners is a
headless catch-up the platform woke for a bounded moment: `runDeferredDeliveryCatchUp` calls
`engine.synchronize()` and then, in its `finally`, disposes the provider container and closes
the database. A future still in flight at that point is a future running against a closed
database, or one racing whatever the next cycle opens — and the platform is entitled to freeze
the process again the moment the tick is acknowledged. Everything above is reached from inside
`synchronize()` and finishes inside it, which `owed_gossip_lifetime_test.dart` asserts directly:
when the cycle returns, nothing is owed and nothing is running.

### What it cost, measured

**From a fake transport, not from a device.** The figures below are the real composed send path
— `PairwiseFanoutCoordinator` over `ClientAuthenticationService` over the cache — against a
`PeerIdentityRemotePort` that delays every request by **122 ms**, the midpoint of the 107–137 ms
real round trip ADR-060 measured from the A56 against the deployed backend. No device
measurement of this change has been taken. The round-trip counts are exact and are asserted in
the committed suite; the milliseconds are what that harness took on the host and should be read
as *round trips × a measured constant*, not as a device figure.

| | round trips before | ms before | round trips after | ms after |
|---|---|---|---|---|
| A send in an established conversation | 4 | 521 | 4 | 497 |
| A send that must establish a session | 7 | 874 | **5** | **619** |
| A send and the gossip it owes | 8 | 1051 | **4** | **528** |
| A first contact and the gossip it owes | 14 | 1828 | **6** | **788** |
| Two sends to one peer in a cycle | 8 | 1037 | **4** | **522** |
| **`prepare` starting → the ciphertext is postable** | **8** | **1028** | **4** | **512** |

The last row is F7 by itself and is the one that matters most: the time from a preparation
starting to a sealed envelope being ready to `POST` halves, because half of it was a second
fan-out for somebody else. In the *after* column that work has not disappeared — it happens
later in the same cycle, after the message is on the wire, and costs nothing extra because the
resolutions it needs are already answered.

The first row is the honest null result: a single send in an established conversation resolves
two distinct users once each, and always did. There was no redundancy there to remove. The win
is entirely in the three shapes that ask about the *same* person more than once — a claim, a
gossip round, a second send — which is what the RCA said it was.

`peer_resolution_cache_test.dart` pins both columns as *equalities*, in the discipline ADR-061
through ADR-064 established, so a resolution finding its way back onto the path fails there
loudly:

| Requests about the peer | before | after |
|---|---|---|
| A send that establishes a session — identity / devices / claim | 2 / 2 / 1 | **1 / 1 / 1** |
| A send and its gossip — identity / devices | 2 / 2 | **1 / 1** |
| Two sends to one peer — identity / devices | 2 / 2 | **1 / 1** |
| A first contact and its gossip — identity / devices / claim | 4 / 4 / 2 | **1 / 1 / 2** |

The claim column is deliberately unchanged everywhere. It is the one request that must not
move.

### Correctness

Forty new tests across three files, and the security ones are the point.

- **`peer_resolution_cache_test.dart`** drives the real `PairwiseFanoutCoordinator` over the
  real `ClientAuthenticationService` over the real cache, and asserts on the device ids
  `prepareOutbound` was actually called with — the devices encrypted to, not whether a fetch
  happened. It covers: a device revoked, a device added, a master key changed, a fork detected
  and a `stale_devices` refresh raised, each proving the pre-change answer never reaches a
  ciphertext; every gate reproduced on a hit with zero requests; the claim called exactly once
  per establishment, never served from the cache and never coalesced; the request counts above
  in both columns; single-flight; a failure never remembered; a `304` served only back to its
  own ETag; and a forced-live resolution staying live for its whole length against a concurrent
  fan-out.
- **`owed_gossip_lifetime_test.dart`** drives the real `DurableSyncEngine` over a real Drift
  store and asserts the ordering directly: the preparation returns with nothing gossiped, the
  batch it sealed is already on the wire when gossip runs, and when `synchronize()` returns
  nothing is owed and nothing is running. It also proves two sends in one cycle gossip once, a
  second cycle moments later gossips no further, a cycle past the window gossips again, a
  failing or throwing gossip round is not the cycle failing and does not put the retired
  preparation back, a failed round is caught up by the next send, and a preparation that failed
  owes nothing.
- **`pairwise_send_preparation_adapter_test.dart`** keeps its three existing properties and
  gains the ordering one: `prepare` returns, then gossip runs.

Everything named as a regression surface is green and unweakened:
`test/features/contacts/**`, `pairwise_fanout_coordinator_test.dart`,
`local_echo_visibility_test.dart`, `local_echo_crash_safety_test.dart`,
`durable_sync_engine_test.dart`, `durable_sync_engine_isolation_test.dart`,
`sustained_delivery_test.dart`, `queue_gap_recovery_matrix_test.dart`,
`platform_deferred_delivery_scheduler_test.dart`, `test/features/devices/**` and
`test/architecture/*`. `client_authentication_service_test.dart` is unchanged — the service's
security contract did not move, and the default `NoPeerResolutionCache` is why that test
composes exactly what it composed before.

### What this does not do

- **No schema change.** Still 18. No migration, no table, no column, no index. Nothing
  persistent moved, which is why `local-data-model.md` is untouched.
- **No wire change.** No path, header, query parameter, request or response shape, or accepted
  status code. In particular `/identity` gained no `If-None-Match`: the server does not offer
  an ETag there, so reducing identity round trips is a caching problem and was solved as one.
- **No cryptographic change.** No construction, no ciphersuite, no isolate, no
  `PairwiseCryptoOperation`, no `backend/` file.
- **No change to what gossip says.** It advertises this device's verified log heads to a peer
  it is talking to, exactly as before. Only when it runs has changed.

### What is explicitly left undone

- **The claim path still re-verifies from cached bytes rather than reusing the resolution the
  send already completed.** It costs a full local verification — four local reads and an
  identity signature check, sub-millisecond against a 122 ms round trip — and splitting
  `_refresh` into resolve-then-claim would reorder the storage writes that currently happen
  after a failed claim. Not worth the risk for local work that does not show up in the budget.
- **The cache is per-process and per-composition.** A second `ProviderContainer` in the same
  process gets a second cache. Nothing composes one today, and ADR-050 forbids a second
  delivery owner, so this is stated rather than fixed.
- **Own-account resolution is treated exactly like a peer's.** It is resolved once per cycle
  and cached the same way, though the local identity is already on the device; a narrower path
  for `localIdentity.userId == userId` would save one round trip per cycle and would mean the
  own-account device set stopped being verified the same way everybody else's is.
- **Gossip's own fan-out is not batched across peers.** Two peers owed an advertisement in one
  cycle produce two fan-outs and two commits. They are already coalesced per peer, and batching
  across peers would change what a gossip envelope is.
- **No device measurement.** The numbers above are from the suite with a synthetic 122 ms
  round trip. A signed-beta A56 run against the deployed backend would say what the counts are
  worth in the field, and has not been taken.
- **The one-minute gossip window is not adaptive.** A device that enrols and revokes twice
  inside a minute advertises the later state a minute late, or on its next send, whichever is
  sooner.

### This closes the RCA

ADR-060 opened it on a measurement: a direct message took fifteen to twenty seconds to reach
`POST /api/v1/envelopes`, the peer never received it at all, and two idle devices re-downloaded
1.1 MB a minute against a network and backend that had already been cleared. Five phases:

- **ADR-060** made a cycle finish. One unopenable envelope stopped ending the run, the outbox
  went first, and an envelope this device can never open got a terminal state.
- **ADR-061** made a send a local write. The message is committed and drawn before any network
  call, and the fan-out that seals it became a durable row the cycle owes.
- **ADR-062** made reading a conversation cost the window instead of the history.
- **ADR-063** made receiving an event cost the event instead of the conversation.
- **ADR-064** made a frame cost what changed on the screen instead of what is on it.
- **ADR-065**, here, makes a delivery cycle ask the network once per person, and puts the work
  this device owes other people behind the message its user just sent.

End to end, against the original symptom: the bubble appears at the speed of a local write
rather than after two round trips and a claim; the cycle that carries it to the wire reaches
the wire; the ciphertext is postable in half the time it was; a first contact and its gossip
cost six round trips where they cost fourteen; typing costs 2.33 ms of build time where it cost
5.25; and applying one event costs fourteen to sixteen statements where it cost the whole
conversation. Nothing from the RCA's list remains unaddressed.

## ADR-064 in full — the chat screen costs what changed on it (2026-08-28)

**Status:** Accepted. Client-side cost decision, entirely in the presentation and provider
layers. **The local schema stays at 18**: no migration, no table, no column, no index. Changes
no repository, no projector, no outbox, no delivery cycle, no cryptographic construction, no
protocol, no wire format and no backend file. **Opens no production gate.**

### The question

> ADR-061 made the write path cheap, ADR-062 made the read path cheap, and ADR-063 made
> applying an event cost the event rather than the conversation. Every term those three left
> is on the main isolate, in the widget layer. What does one thing happening — a message
> arriving, a reaction landing, a character typed — cost the screen, and what is the smallest
> set of changes that makes that cost a property of the change rather than of the conversation
> it happened in?

Three of them, named F8, F9 and F10 by the original RCA:

- **F8.** `ChatViewModelMapper.messages` re-derived the *whole loaded window* on every
  rebuild, twice — once for the timeline and once for the pins — and handed back a freshly
  allocated view model for every message whether or not anything about it had changed. The
  timeline follows the identity of those objects, so one receipt landing cost the window
  twice: once to derive it and once to redraw it. `ChatViewModelMapper.summaries` was called
  again on every build of the *chat* page, over every conversation on the device, to fill a
  forward sheet almost every build never opens — with `DateTime.now()` read inside `build`.
- **F9.** `_messageKeys` held a `GlobalKey` for every message ever drawn and was never pruned,
  and `_captureReadingAnchor` walked all of it, calling `findRenderObject()` and
  `localToGlobal()` per entry — synchronously in `didUpdateWidget`, in
  `didChangeDependencies`, at the top of every `_timeline()` build, and once per frame for as
  long as anybody was scrolling.
- **F10.** Every keystroke called `setState` and dispatched `SaveDraftIntent`, which wrote the
  `conversations` row, which invalidated `conversationSummariesProvider`, which the chat page
  watched, which rebuilt the page, which re-ran both of F8's mapper calls. Typing twenty
  characters did that twenty times.

### D1. The page is re-derived where it changed, and nowhere else

`ChatMessageProjection` holds the last page it mapped and returns the **same view model
instance** for every message whose projection cannot have changed. It is owned by
`_ProjectedConversationPageState` — one for the window, one for the pins — so it lives exactly
as long as the open conversation, which is what makes it worth anything: the page it is handed
on the next emission is mostly the page it was handed on this one.

**Mapping bound to the widget's sub-window was rejected.** It would have inverted the layering
— the page would have to know `_visibleMessageCount`, which the widget owns and grows through
the `_loadOlder` handshake — and it would have saved the smaller half of the cost. The
expensive half is not the derivation, it is the *identity churn*: `Element.updateChild` skips a
child whose new widget is the one it already holds, so a stable view model is the difference
between rebuilding two rows and rebuilding every row on screen.

**The memo key is "is this the same row", not "does the view model read this".**
`_sameMessage` compares every field of `ConversationMessage`, including the ones the view model
does not read today, because the question it answers stays true when somebody adds a field and
starts drawing it. Positional inputs are compared separately and exactly:
`groupedWithPrevious`, `groupedWithNext`, and the reply target's author and text — grouping is
`_grouped(previous, message)`, so a message whose *neighbour* changed must be re-derived, and a
quote is re-read from its target, so an edit to the target must invalidate the quote that shows
it. Getting this wrong in the permissive direction is the one failure that would be silent, so
attachments, whose descriptors have no value equality, are compared by capability and a list
that cannot be matched that way is reported as **changed** rather than as equal.

The cache is bounded by construction: an entry exists only for a message the page still names.
Pruning is a rebuild of the map, and it runs only when the entry count no longer matches the
page's — so the ordinary emission, one more message at the newest end, does not pay for it.

### D2. The timeline reuses the row, not just the view model

A stable view model is only worth something if the widget built from it is stable too, so
`_rowWidget` retains the built row and hands the identical instance back when neither the
message nor its highlight moved. Two generations of that cache are live at once and the older
is dropped whole, because rows are built during **layout** as well as during build — a scroll
materialises children without the adapter rebuilding at all — so the generation rolls on size
rather than on frames.

Every row now carries a key, and the list is given a `findChildIndexCallback`. This is what
makes an arrival cheap in a reversed viewport: a message at the newest end shifts every index
by one, and without the callback every keyed child whose index moved would be discarded and
rebuilt. That relocation is exactly what the `GlobalKey` per message used to buy, at the price
of a re-parent per row per arrival — which is why the keys could go and the behaviour could
stay. Date headings are keyed by the message they sit above rather than by the day they name,
because a skewed timestamp can put the same day on both sides of another one and two rows
sharing a key is a crash rather than a wrong heading.

Two smaller terms went with it. The drawn range's rows are rebuilt only when that range
actually changed, decided by a walk of object identities rather than by re-deriving separators
and days for a window that may hold the whole conversation; and the day a message belongs to is
compared as an integer, so a `DateTime` — and the timezone conversion inside it — is
constructed once per heading instead of once per message.

### D3. The chat page stops subscribing to what it does not draw

- **The draft is read once.** `conversationDraftProvider` is a one-shot read of the
  conversation row, not a slice of the summaries stream. A draft is an *initial value for a
  field the user is about to own*, and the field is what writes it — subscribing put the
  composer's own keystrokes on a path back to the page around it. The composer adopts a draft
  that lands after its first build, but only into a field that is still untouched and still
  empty, which is what makes the one-shot read safe and also closes a hole that was already
  there: before this, a stored draft that arrived after the composer's `initState` was simply
  never restored.
- **Typing is narrowed to a boolean.** `typingProjectionsProvider` is watched through a
  `select` for whether *anybody* is typing, which is all the header draws. The list is rebuilt
  on every heartbeat and its identity changes with it; the answer does not.
- **The forward targets are a callback.** They are resolved when the sheet opens. The summaries
  stream is still subscribed — through `listenManual`, so the sheet is instant — but it is no
  longer *watched*, so a draft write cannot rebuild the page. That distinction is the whole of
  F10's cascade: `watchConversations` re-emits on a draft write and `watchMessages` does not,
  which `chat_render_cost_test.dart` asserts directly.
- **`DateTime.now()` leaves `build`.** The conversation list holds its reading of the clock in
  its `State` and refreshes it on a schedule it can state: exactly when the earliest mute on
  screen expires, and never otherwise. A list with nothing muted holds no timer at all. The
  forward sheet reads the clock when it opens, which is not a build.

The conversation list's search field went the same way as the Send button: the query lives in
the controller and only the results listen to it, so typing in it no longer re-maps every
conversation on the device to filter a list that has not changed.

### D4. The anchor comes from the rows that exist

`_messageKeys` is replaced by a registry of **mounted** rows. A row registers itself for as
long as its element lives, which bounds the set by what the viewport and its cache extent hold
— and it was always the only set an anchor could have come from, because an unmounted row has
no render object to measure. The jump path, which read the same map and is not obvious from its
name, is unchanged in behaviour for the same reason: a row that is not mounted had no
`currentContext` either.

**The anchor is captured when it is about to be used.** The build-time capture is gone. The
per-scroll-tick capture is gone: the standing anchor exists for one consumer — a row that
changes size after the fact, which arrives as a notification once the new layout has already
happened and so cannot capture its own "before" — and while the reader is scrolling, the
position is theirs and a correction computed against a reading taken before the gesture would
fight them. So the standing anchor is dropped on `ScrollStartNotification` and taken again on
`ScrollEndNotification`, and never while the viewport is moving.

Two behaviours were found and fixed while proving this. A jump now **drops** the anchor rather
than restoring it: the anchor captured a moment earlier describes a line the reader has just
asked to leave, and a row materialising during the scroll reports its size, and the correction
answering that report cancelled the jump. And `_jumpIfRequested` now asks for the frame it
needs — a jump to a target that is already loaded and already inside the drawn range changes no
state at all, so nothing scheduled the frame its scroll was waiting for, and the tap did
nothing. Its landing estimate is the drawn range's own average row height rather than a
constant `88.0`, and the `ensureVisible` that finishes the job runs once the scroll has
settled rather than while it is still running.

### D5. A keystroke costs a timer

`_onTextChanged` cancels and re-arms a 500 ms timer. Nothing else. The Send button follows the
text through a `ValueListenableBuilder` on the controller, so the only thing that rebuilds when
a character lands is the button.

**The flush contract is the dangerous half, and it is explicit.** A draft written half a second
late is fine; a draft whose last four characters are lost because the user switched
applications is worse than the writes the debounce removed. So the draft is written down
immediately on **every** exit from the composer:

| Trigger | Where |
|---|---|
| The composer loses focus | a listener on the `FocusNode` |
| The route pops | `PopScope.onPopInvokedWithResult`, on the `didPop` branch |
| The application leaves `resumed` | `WidgetsBindingObserver.didChangeAppLifecycleState` |
| The composer is disposed | `dispose`, before the controller goes |
| The message is sent | `_submit`, after the field is cleared |

A flush with nothing new to say writes nothing — the composer remembers what storage is holding
— which is what makes it safe to call from five places that all happen at once when somebody
swipes back out of a conversation. Sending flushes rather than waiting, because a conversation
reopened inside that half second would have shown the sent message back as an unsent draft.

The draft still lives in the `conversations` row. Nothing below the presentation layer moved.

### What it cost, measured

**On the A56 (SM-A566B, Android 16), in a Saved Messages conversation of 219 messages with the
whole conversation drawn.** Build 19 is the tree before this change and build 20 the tree
after, both instrumented with a temporary `FrameTiming` logger and otherwise identical signed
beta artifacts; the instrumentation is not in the committed tree. Milliseconds, from
`FrameTiming.buildDuration` and `rasterDuration`. Frame budget is 16.7 ms.

| | frames | build p50 | build p90 | build worst | raster p50 | raster p90 | raster worst |
|---|---|---|---|---|---|---|---|
| Scrolling, before | 1950 | 0.58 | 2.02 | 3.69 | 2.39 | 2.90 | 21.94 |
| Scrolling, after | 1910 | 0.57 | 2.05 | 4.45 | 2.26 | 2.87 | 23.25 |
| Typing, before | 55 | 5.25 | 8.13 | 9.89 | 2.14 | 5.17 | 8.42 |
| Typing, after | 38 | **2.33** | **3.76** | **6.57** | 4.18 | 7.97 | 10.43 |
| A message arriving, before | 186 | 1.77 | 5.02 | 7.49 | 1.51 | 3.17 | 11.71 |
| A message arriving, after | 169 | **0.82** | **3.23** | **5.97** | 1.56 | 3.21 | 9.12 |

Typing thirty characters costs less than half the build time it did, and produces 38 frames
where it produced 55 — the page is no longer among the things that rebuild. A message arriving
halves again. **Scrolling is unchanged**, and that is the honest result: at 219 messages the
anchor walk was already small, so F9's saving is structural rather than visible at this length,
and the worst raster frame (~22 ms, one frame in nineteen hundred) is the same in both builds
and is not attributable to this change. Raster while typing reads *higher* after, which is
noise from different content being on screen in the two runs — the widget tree a row paints is
untouched by this decision.

**On the host**, from a temporary harness under `flutter test` (JIT, and with no rasterizer, so
these are build-plus-layout-plus-paint wall times and not device figures), timing the frame
that draws the change in a conversation whose whole window is drawn:

| | 48 messages | 1200 messages |
|---|---|---|
| A message arriving, before | 19.68 median / 27.90 worst | 36.71 / **46.88** |
| A message arriving, after | 13.71 / 18.18 | **10.93** / 18.78 |
| A keystroke, before | 16.84 / 24.72 | 32.72 / **34.86** |
| A keystroke, after | 5.08 / 13.04 | **3.95** / 6.46 |

Before, both roughly doubled between 48 messages and 1200. After, neither grows — the 1200
column is *faster* than the 48 column, which is JIT warm-up rather than a real ordering. That
is the property this phase existed to establish: the frame is a cost of the change, not of the
conversation. Deriving the same 1200-message page fell from 0.25 ms to 0.03 ms.

`chat_render_cost_test.dart` asserts the shape of it rather than the timings, as *equalities
across two window sizes* in the discipline ADR-061, ADR-062 and ADR-063 established:

| Applying one … | 48-message window | 240-message window |
|---|---|---|
| message arriving — elements derived | 2 | **2** |
| message arriving — page rebuilds | 1 | **1** |
| reaction — elements derived | 1 | **1** |
| keystroke — elements derived | 0 | **0** |
| keystroke — page rebuilds | 0 | **0** |
| *(control)* one emission with nothing to compare against | 48 | **240** |

The control row is what this page did on every emission before.

### Correctness

Four new obligations, beyond the existing suites staying green with their goldens unchanged:

- **`chat_render_cost_test.dart`** drives the real repository, the real window and the real
  conversation view against a real database, and asserts the counts above — plus, at the
  provider level, that a draft write re-emits the conversation list and does **not** re-emit
  the open conversation. That is the cascade named exactly: it is why the page may subscribe to
  the summaries and may not watch them.
- **`chat_draft_durability_test.dart`** drives every flush trigger in the table above, proves a
  burst of typing is one write rather than one per character, proves a settled draft is not
  written again for having been looked at, and proves that a draft arriving late is adopted
  into an untouched field and refused by a field the user has since typed into.
- **`chat_pagination_test.dart`** gains a bound — the anchor registry and the retained rows
  stay small while a 300-message conversation is scrolled end to end — and proves a jump still
  resolves a target whose rows have been evicted.
- **The reading line** is now asserted for both directions it can move: an older page arriving
  (which it already covered) and a message arriving at the newest end while the reader is
  paged back, which in a reversed viewport moves everything older by the height of the new
  bubble.

The goldens are the guard against the memoization silently breaking grouping or separators, and
they are byte-identical: nothing this decision changed is visible in a still frame.

### What is explicitly left undone

- **F6**, identity and device-resolution caching, and **F7**, the dio client. Untouched, as
  they were before.
- **The conversation list still re-maps every conversation when a summary changes.** It is
  bounded by how many conversations exist rather than by how long any of them is, and the
  screen it feeds draws all of them; the same memoization would apply, and there is no
  measurement saying it needs to.
- **`ChatConversationView` still rebuilds its whole scaffold on every emission** — app bar,
  pinned banner and composer included. It is O(1) in the conversation, it is the dominant term
  in what is left of an arrival frame on the host, and splitting it would mean moving the model
  into the widgets that read parts of it, which is a larger change than this phase.
- **F9's saving is not visible on a 219-message conversation.** The anchor walk was bounded by
  what had been *rendered*, so it grows with a session rather than with a conversation, and
  proving it on a device would mean a longer conversation and a longer session than were
  available. The bound is asserted in a widget test instead.
- **The A56 measurement is of a Saved Messages conversation**, seeded to 219 messages for this
  purpose. It is one device, one conversation and one text size, and the raster column moves
  with what happens to be on screen.
- **Jump-to-message still lands by estimate first and corrects afterwards.** The estimate is
  now measured rather than assumed, but a conversation with wildly uneven bubble heights will
  still need the `ensureVisible` correction to finish the job.

## ADR-063 in full — an event costs the message it is about, not the conversation it is in (2026-08-27)

**Status:** Accepted. Client-side cost decision. Adds one local schema version (17 → 18),
one derived-state table and one index. Creates no user-facing table, drops no table, re-keys
no table and rewrites no existing row. Changes no cryptographic construction, no ciphersuite
identifier, no protocol, no wire format, no canonical event encoding, no transport trust
anchor, and no backend file. **Opens no production gate.**

### The question

> ADR-061 made the write path cheap and ADR-062 made the read path cheap. Both left the same
> term untouched, and it is the largest one: every authenticated application event re-projects
> its whole conversation from the whole event log. What does applying one event cost, and what
> is the smallest set of changes that makes that cost a property of the event rather than of
> how long two people have been talking?

`_rebuildConversation` reads every candidate event in the conversation, decodes every body,
and then, for each message, folds it against the **whole** fact set — five separate passes,
four of them re-evaluating the same lazy `where` over every event in the thread and the fifth
a list scan nested inside a scan for receipts — before rewriting every message row, deleting
and re-inserting every reaction and every receipt, whether or not anything about that message
changed.

That ran on every message received, every edit, every reaction, every pin, and every inbound
receipt — which is the worst of them, because a receipt is one event per *batch* of messages,
so the cheapest thing the protocol carries paid the dearest price. ADR-062 measured one such
rebuild at 27 ms after indexing and 96 ms before it. Measured here, end to end and including
the fold rather than only the row rewriting, a 1200-message conversation is **6556 statements
and 283 ms**.

### D1. The affected set is a set, because the protocol has two shapes

An event names the messages it is a fact about, and it does so in two different ways:

- a `messageCreate` names the message it creates, in `body.message_id`;
- a `messageEdit`, `messageDelete`, `reactionSet` or `pinSet` names one target, which is
  already the `target_message_id` column;
- a `receiptDelivered` or `receiptRead` names **many**, as a `message_ids` list in the body,
  and one receipt covering a batch is the ordinary case rather than the pathological one.

`_affectedMessageIds` is total over every kind the projector stores — including the ones that
name nothing — so adding a kind to the protocol is a change there rather than a silent
omission. Applying an event re-folds exactly that set, and the cost is that set's size: one,
or the number of ids the receipt actually carries.

### D2. The unit of projection did not change; where its facts come from did

`_projectMessage` already took "a message's create, and a list of facts" and returned that
message's projection. It filtered the list itself. So F2 changes what is handed to it, and
nothing else:

- **the rebuild** hands it the conversation's whole candidate fact set, exactly as before;
- **an incremental apply** hands it the facts about that one message, read out of a new index.

Everything downstream — the edit winner, the delete authority, the pin, the reaction per
user, the receipt state per device, the preserved local-only columns — is the same code
reaching the same answer. That is what makes the equivalence test in §Correctness a
statement about one function and two inputs rather than about two implementations.

### D3. `application_event_targets`, and why it is a table

The projector needs the direction the log does not have. An event carries the message it
targets; an incremental apply has to ask which facts a message has. `application_event_targets`
is one row per (message, event) pair, written in the same statement sequence as the event
itself, for every stored event whatever its apply state.

**It is derived state and only an index.** The authoritative fact is the event, and everything
read through here joins back to `application_events`. That is what makes a *stale* row
harmless — it joins to nothing — while a missing one is not, which is why a full rebuild
rewrites the rows for every fact it folds and why the migration back-fills.

**A table rather than a column,** because a receipt names many messages and SQLite has no
array. The obvious alternative — extend `target_message_id` to mean "the message this event is
about", set it on creates too, and keep a second table only for receipts — was rejected: it
changes the meaning of a populated column, needs the same back-fill anyway, and leaves the
fold reading a union of two shapes instead of one.

**The primary key leads with `message_id`,** so its implicit index answers the only question
asked of it and no second index is declared. There is deliberately **no foreign key**:
`event_id` would be an unindexed child key and SQLite would scan this table on every write to
`application_events` to prove nothing was orphaned — precisely the cost `attachments_by_message`
exists to remove (ADR-062).

### D4. `CROSS JOIN`, and why the plan test is the only thing that could catch it

The fold reads

```sql
SELECT event.* FROM application_event_targets target
CROSS JOIN application_events event ON event.event_id = target.event_id
WHERE target.message_id = ? AND event.conversation_id = ? AND event.apply_state = ?
```

Written as an ordinary join it is one statement either way and the statement count is
identical — and SQLite, which has no statistics to go on, picks the other order:
`SEARCH application_events USING INDEX application_events_conversation_apply_state
(conversation_id=? AND apply_state=?)`, then a probe of the target index for **every candidate
event in the conversation**. Same rows, same statement count, linear in the conversation. The
cost this phase exists to remove, invisible to a counting interceptor and visible only in
`EXPLAIN QUERY PLAN`. `CROSS JOIN` is SQLite's documented way to fix a join order, and
`local_database_index_plan_test.dart` asserts the resulting plan rather than trusting it.

The conversation is in the predicate for the same reason the rebuild reads one conversation's
events: a reference is a claim by whoever sent it, and a claim about a message id belonging to
some other conversation must not reach that conversation's projection.

### D5. The conversation's aggregates have one definition, and both paths call it

`unreadCount`, `sortKey`, `listProjectionCiphertext` and `lastActivityEventId` are read back
out of the message rows by `_refreshConversationAggregates`, which the rebuild now calls too.
"Identical to what a rebuild would produce" is therefore true by construction rather than by
argument, and the rebuild's in-memory running totals are gone.

- **The newest message** is `ORDER BY ordering_ms DESC, ordering_event_id DESC LIMIT 1`, which
  is the column order of `messages_conversation_ordering` (ADR-062) read backwards: one index
  entry and one row. It carries all three of the preview, the ordering key and the last
  activity, because `messages.projection_ciphertext` is already exactly what the conversation
  wants — a message deleted for everyone stores an empty blob, which is what
  `displayText == null` produced.
- **The unread count** is `COUNT(*) ... WHERE conversation_id = ? AND unread`, served by a new
  partial index.

**`messages_unread_by_conversation` on `(conversation_id, unread) WHERE unread`.** Partial, so
it holds only unread rows and an insert that is not unread writes nothing to it. `unread` is a
column as well as the predicate, and that is not redundant: without it SQLite keeps the query's
own `unread` term as a filter, needs the column to evaluate it, and visits the row —
614 µs against **431 µs** over twenty thousand unread messages, and the plan says
`USING COVERING INDEX` only in the second form. It carries the same catch as ADR-062's pinned
index: SQLite will only choose a partial index for a query whose `WHERE` contains the bare term
`unread`, so the projector spells it unbound and the plan test is the only thing that can catch
a regression to `unread = ?`.

**The residual term, stated rather than buried.** The count is O(u) in the number of *unread*
messages, not O(1): 93 µs at a hundred, 105 µs at two thousand, 431 µs at twenty thousand,
against a whole apply of about 1100 µs. It is not a pass over the conversation — opening the
conversation empties the index and the count becomes one probe — and no index shape measured
makes it constant. The alternative is a delta (`unread_count = unread_count + Δ`), which is
O(1) and was rejected: it gives the two paths two definitions of the same number, and a delta
is only correct if every writer of `messages.unread` maintains it, which is exactly the class
of drift ADR-060 and ADR-061 were about. The existing `_refreshUnreadCountForMessage` in the
repository counts the same rows with a *bound* predicate, so it does not even reach the index;
this is strictly cheaper than the precedent it follows.

### D6. Where the boundary sits

**Incremental** is the `applied` disposition: one new fact about a known set of messages.

**The rebuild** keeps every case where a fact the projection already contains is *retired*, so
that what the projection should now say is no longer a function of the event in hand:

| Case | Site |
|---|---|
| an event id presented twice with different canonical bytes | `applyInsideTransaction` |
| a sender counter replayed, in every conversation it touches | `applyInsideTransaction` |
| an unsupported event colliding with a stored event id | `retainUnsupportedInsideTransaction` |
| an unsupported event replaying a sender counter | `retainUnsupportedInsideTransaction` |
| a stored body that cannot be decoded | the incremental fold declines and escalates |
| a fork, a repair, or a future change to conversation-level authorisation | `rebuildConversationInsideTransaction` |

The last row is new. `_rebuildConversation` was private and reachable only through a conflict;
it is now also a public entry point, because requirement four of this phase is that the
recovery path stay *reachable*, and because the answer to hard case five below needs a door to
it rather than a reason to reinvent it.

The escalation is the design's safety valve: **the incremental path may decline at any point
and delegate**, and correctness is then the rebuild's. Today it declines for exactly one
reason — a stored body it cannot read, which is storage corruption — and the rebuild marks
that fact rejected and re-derives the conversation, which is what it already did.

`refreshTransportForEventInsideTransaction` is untouched. ADR-061 narrowed it to one row and
it stays that way.

### The seven hard cases

1. **Receipts are one-to-many.** `_targetMessageId` is non-null only for edit, delete, reaction
   and pin; a receipt carries a `message_ids` list instead. The affected-set derivation covers
   both shapes (D1), the index table stores one row per (message, event) so both shapes fit
   one lookup (D3), and the cost of a receipt is the ids it carries — measured at 245
   statements for thirty-two ids against 16 for one, equal at 48 messages and at 1200.
2. **Mutations arrive before their create.** The target row is written for *every* stored
   event, including one whose message does not exist yet, so it is sitting in the index when
   the create lands. Applying a `messageCreate` re-folds from every stored fact targeting that
   message id, not from the create it was handed. The equivalence generator forces this rather
   than leaving it to the shuffle: one message's whole fact set is delivered before its create,
   every seed.
3. **Apply-state transitions change the fold input.** Every transition to `eventIdConflict`,
   `counterConflict` or `conversationRejected` happens on a path that keeps the full rebuild —
   verified, and asserted in `projection_recovery_path_test.dart` by tampering with an
   *unrelated* message first: a value no fold produces is written straight into `messages`, and
   only a whole-conversation re-derivation puts it back. The one transition inside the
   incremental path (a body that will not decode) escalates rather than proceeding.
4. **A message can stop being projectable.** The rebuild's terminal `DELETE ... WHERE
   message_id NOT IN (…)` is gone from the event path, so removal is explicit: a create that
   collided with another, a create whose references do not carry its reply target, and a
   message id with no create at all each delete the row. Scoped to the conversation as well as
   the id, because a fact in one conversation referencing a message id created in another must
   not be able to delete it.
5. **Authorization is conversation state.** `_authorizedPin` and `_isConversationParticipant`
   read `conversations.kind` and `conversations.peer_user_id`; `_authorizedGroupModerator`
   returns false unconditionally until group role projection exists. Those two columns are
   written once, when the conversation row is created, and an event disagreeing with them is
   rejected rather than applied — so **no already-applied event's authorization can change
   today**, and the incremental path needs no answer. When group roles land, the answer is a
   targeted rebuild on membership change, and `rebuildConversationInsideTransaction` exists so
   that it is one call rather than a second projector.
6. **Idempotency and re-entry.** A re-presented event returns `duplicate` before anything is
   inserted, so no incremental work runs at all. The whole apply is inside the caller's
   transaction, so a crash rolls back to a state from which re-presenting converges — asserted
   against a **reopened database file** in `incremental_apply_crash_safety_test.dart`, for a
   fault on the message write, a fault on the index write, and a fault between two of the
   messages one receipt names. `unread_count` is recomputed rather than incremented, so it
   cannot double-count; reactions and receipts are rewritten as a set, so they cannot
   double-insert; and the index insert is `INSERT OR IGNORE`, because a receipt may name the
   same message twice.
7. **Local-only columns.** `deleted_for_me`, `pinned`, `starred`, `unread`, `alerted`,
   `delivered_receipt_sent` and `status` are preserved by the same mechanism as before —
   companions that omit them, plus the existing row read into `_LocalMessageState`, which now
   has a named constructor both paths use so "the same mechanism" is checkable rather than
   asserted. `delivered_receipt_sent` moves *into* that record, which removes a `SELECT` per
   message per projection: the companion omits the column, so the row read before the write and
   the row read after it carry the same value.

### Correctness

**The differential equivalence test is the phase's argument, and it was written first.**
`projection_equivalence_test.dart` builds a deliberately hostile log — competing edits at the
same revision from the same sender, an edit from somebody who did not write the message, an
edit whose references do not carry its target, a delete over the top of an edit, a delete of
somebody else's message, a reaction replaced twice and then cleared, a reaction on a message
that has not arrived, a pin set and cleared, a receipt naming every message in the
conversation, a receipt from this account's other device, a receipt naming a message that does
not exist, a second create claiming a message id that already has one, and a duplicate
re-presentation — shuffles its delivery with a printable seed, and runs it twenty-four times.

Three databases, because two comparisons catch different mistakes:

- **Step by step.** A second database applies the same event and then runs the recovery path
  over it. If the incremental apply is right the rebuild is a no-op and the two agree; if it is
  wrong in anything a rebuild re-derives, they diverge on the event that did it.
- **From nothing.** A third throws its projection away at the end and rebuilds from the log
  alone. That is the only comparison that says anything about the *preserved* columns, because
  a rebuild over an existing row carries those through and would carry a mistake through with
  them.

The snapshot is every column of `messages`, every reaction, every receipt, every attachment,
every conversation aggregate, and every event's apply state.

**The oracle is kept independent, deliberately.** The rebuild still folds each message against
the conversation's whole fact set — the quadratic scan §3 of the brief describes — rather than
against a grouping computed from `_affectedMessageIds`. Grouping it would have been a free
speed-up for the recovery path and was rejected: it would make the oracle share the incremental
path's idea of which facts belong to which message, and an error in that idea would then show
up as agreement. Mutation-tested: breaking the receipt fan-out, dropping the removal of a
message that stopped being projectable, and folding only the event in hand each fail all
twenty-four seeds. With the shared grouping in place, the first of those failed none of them.

The conversation aggregates get a third opinion for the same reason — both paths now share one
SQL definition, so the harness recomputes all four in Dart from the rows that are there.

### What it cost, measured

From `local_apply_cost_test.dart`, which asserts the statement counts are *equal* across the
two conversation lengths rather than merely bounded. Microseconds are the mean of twelve
applies of each kind against the same database; the 1200-message run is the warm one and is
what the wall-clock column quotes.

| Applying one … | 48 messages | 1200 messages | 1200, wall clock |
|---|---|---|---|
| `messageCreate` | 16 | **16** | 1061 µs |
| `messageEdit` | 14 | **14** | 1066 µs |
| `reactionSet` | 16 | **16** | 1244 µs |
| `pinSet` | 14 | **14** | 1106 µs |
| `messageDelete` | 15 | **15** | 1177 µs |
| `receiptDelivered`, 1 id | 16 | **16** | 1105 µs |
| `receiptRead`, 32 ids | 245 | **245** | 16 786 µs |
| one full rebuild | 796 | **6556** | 282 749 µs |

So applying one event to a 1200-message conversation went from 6556 statements to **14–16**,
and from 283 ms to **about 1.1 ms** — a factor of about 260 — while a receipt covering
thirty-two messages costs thirty-two folds and not twelve hundred. Every number in the
right-hand column is the same as at 48 messages; before this change none of them were.

**Against ADR-062's 27 ms.** That figure measured *rewriting every row* of a 1200-message
conversation with the attachments index in place. The 283 ms here is the whole of
`_rebuildConversation` on the same in-memory SQLite: reading every candidate event, decoding
every body, and folding each message against the whole fact set, which the row-rewrite
measurement did not include. The two are consistent, and the second is what the event path was
actually paying.

`local_send_cost_test.dart` records the other end of it. ADR-061 left the echo linear and said
so — 201 statements at 61 messages against 33 at five, and the test asserted that it *grew*.
It is now equal across the two lengths, and that assertion is inverted.

### The migration

Schema 17 → 18. One new table, one new index, no column added, no table dropped or re-keyed,
and no existing row rewritten. The step sits inside the existing `transaction()` wrapper with
`StorageMigrationHooks` around it, in the stepwise `if (from < N)` style, and checks for the
table before creating it in the style of the schema-14, -15 and -16 steps — a database whose
recorded version is behind its actual shape is a real condition on a device that has taken a
development build.

**The back-fill is the whole cost, and it is not optional.** An empty target table would not be
a slower projection, it would be a wrong one: an edit landing on a message whose create has no
row there would fold the edit alone and find no message to edit. So every event a device
already holds has to be indexed before the first incremental apply runs.

- The four single-target kinds are already a column, so they are **one set-based statement**
  that never leaves SQLite.
- Creates and receipts carry their message ids inside the projected body, so those are read in
  keyset pages over the primary key, decoded and written back in batches — the same single pass
  over `application_events` that `CREATE INDEX` costs, with a JSON decode on top of it, and
  never the bodies of a whole event log in memory together. `OFFSET` would re-scan what it
  skipped, which is the shape ADR-062 rejected on the read path. SQLite's JSON functions were
  not used: their availability under the SQLCipher build is not something to discover during a
  migration on somebody's phone.
- `INSERT OR IGNORE` throughout, so an upgrade that is interrupted and retried cannot collide
  with itself. A body that cannot be decoded is skipped rather than failing the upgrade; the
  projector already rejects such a fact the next time it folds that conversation.

`local_database_migration_test.dart` runs it against a populated version-17 database and
asserts the exact set of index rows — one per create, one for the pin, three for the receipt —
that no message row moved, that the new index exists, and then, end to end, that an edit
arriving *after* the upgrade folds against a create stored before it and brings the pin stored
before it along too.

A rebuild also rewrites the index rows for every fact it folds, so the recovery path repairs an
interrupted back-fill as well as an interrupted projection.

### What is explicitly left undone

- **F6**, identity and device-resolution caching. A send still resolves both device sets over
  the network; ADR-061 moved that off the path the user waits on and it has not moved again.
- **F8**, `ChatViewModelMapper.messages` mapping the whole loaded window on every emission.
- **F9**, `_messageKeys` pruning and the anchor walk.
- **F10**, draft debounce.
- **The rebuild is still O(N²) in the conversation**, on purpose (see Correctness). It is the
  recovery path, it runs on conflicts and repairs, and its cost is now a cost of recovering
  rather than a cost of receiving. Making it linear means giving it the incremental path's
  grouping, which is the one thing the oracle must not share.
- **Attachments are still deleted and re-inserted whenever the message they belong to is
  written**, which resets `transfer_state` to queued and clears `bounded_cache_handle_ciphertext`
  — so a downloaded attachment loses its cache handle. That is pre-existing behaviour, it is
  O(1) in conversation length, and F2 makes it *far* rarer (it now happens only when an event
  about that message is applied, rather than on every event in the conversation). Gating it the
  way reactions and receipts are gated would change observable local state and is a separate
  change.
- **`unsupported_application_events` is still scanned** for the sender-counter check, as
  ADR-062 decided: the table is empty on a client at the current protocol version.
- **The unread count is O(u), not O(1)**, as measured and argued in D5.
- **Measured in statements and microseconds, not on a device.** The figures are from the suite,
  on an in-memory SQLite with no SQLCipher underneath it, so they understate the win rather
  than overstate it. No A56 measurement of receiving into a long conversation has been taken
  for this change.

## ADR-062 in full — the timeline reads a window, and the database has indexes (2026-08-27)

**Status:** Accepted. Client-side cost decision. Adds one local schema version (16 → 17) and
six indexes. Creates no table, drops no table, re-keys no table and rewrites no row. Changes
no cryptographic construction, no ciphersuite identifier, no protocol, no wire format, no
transport trust anchor, and no backend file. **Opens no production gate.**

### The question

> ADR-061 fixed the write path: a message is committed and drawn before any network call, and
> a transport transition costs 7 statements instead of 195. The read path was not touched.
> What does opening a conversation cost, and what is the smallest set of changes that makes
> that cost a property of the screen rather than of how long two people have been talking?

Two answers, and like ADR-061's they are independent.

**The timeline had no `LIMIT` and an N+1 on top of it.**
`DriftConversationDomainRepository.watchMessages` selected every message in the conversation
and then, inside `asyncMap`, ran one reactions query, one receipts query and one attachments
query *per row*. Every emission. So one emission cost `3N + 1` statements, and an emission
happens whenever anything in `messages` changes — a receipt landing, a draft being saved, a
transport transition, the user's own keystroke echoing. Measured in
`test/features/messaging/local_read_cost_test.dart`, against 1200 messages: **3601
statements**. Against eight: 25. `watchConversations` had the same shape one level up, one
`SELECT` over `messages` per conversation in the list, each of them a full scan.

**And the schema declared 43 tables and zero indexes.** Every lookup by a column that was not
the leading component of a primary key was a full table scan — under SQLCipher, where each
page read is a decrypt. `messages` is keyed by `message_id`, so `WHERE conversation_id = ?`
scanned every message on the device for everybody. `application_events` is keyed by
`event_id`, so a projection rebuild scanned every event ever stored. `outbox_operations` is
keyed by `(operation_id, recipient_device_id)`, so reading a message's transport state
scanned the whole outbox.

### D1. The window is a cursor range, not a count

`watchMessages` takes a `ConversationMessageWindow` and returns a `ConversationMessagePage`.
The window has two shapes and both are ranges over the timeline's own ordering key
`(ordering_ms, ordering_event_id, message_id)`:

- `NewestConversationMessages(n)` — the first read, before anything is known. Ordered
  descending with `LIMIT n`, reversed once in memory.
- `ConversationMessagesFrom(cursor)` — every read after it. An **open-ended range anchored at
  the oldest message already on screen**.

Anchoring at the bottom rather than counting from the top is the whole design, and it is not
cosmetic. A window defined as "the newest 240" slides: a message arriving at the top pushes
the oldest loaded message out of the other end, and the line the reader is looking at moves
every time anybody says anything. A window defined as "everything at or after this key" only
ever grows at the top. `test/widget/chat_pagination_test.dart` asserts exactly that — a
message arriving while the reader is two pages back leaves the oldest loaded message where it
was.

**`OFFSET` was rejected.** It re-scans everything it skips, so paging backwards would get
slower the further back you went, which is the failure being fixed rather than a milder form
of it. `olderMessageCursor` asks for the key `n` rows below the current bound instead: three
columns, a limit, and the ordering index covers it outright, so it reads the page and nothing
before it.

**The keyset predicate carries a redundant term on purpose.** Written as one nested `OR`, the
comparison is a filter SQLite applies after choosing an access path, and the scan starts at
the conversation's newest message every time. Written as `ordering_ms >= :ms AND (ordering_ms
> :ms OR ...)`, the leading term is a range constraint on the second column of the index and
the scan starts at the boundary. Same rows, and the plan says
`(conversation_id=? AND ordering_ms>?)` rather than `(conversation_id=?)`.

### D2. The three per-row queries become three set-based ones, joined on the same range

Reactions, receipts and attachments are read once each for the whole page, by joining the
child table to `messages` under the *same* window predicate the page used — named once, in
`_windowOf`, so the four statements cannot disagree about what the window contains. They are
grouped in memory. Statement count per emission becomes O(1) in conversation length:

| | 8 messages | 1200 messages |
|---|---|---|
| One emission, before | 25 | **3601** |
| One emission, after | **6** | **6** |
| One emission, window anchored two pages back (240 loaded) | 6 | **6** |
| Resolving the next page back | 1 | **1** |
| One emission of the conversation list | 2 | **2** |

The six are: the page, whether anything older exists, the page's reactions, its receipts, its
attachments, and the conversation's pins. `local_read_cost_test.dart` asserts these as
*equalities across the two conversation lengths*, in the discipline ADR-061 established, so an
N+1 finding its way back onto this path fails loudly rather than gradually.

Reactions are sorted in Dart rather than in SQL. An `ORDER BY` on the reaction would have made
SQLite sort the joined result through a temporary B-tree to settle the order of the two or
three reactions each message has.

### D3. `pinnedMessageIds` is not page-scoped, because a banner counts them

The pinned banner may target the oldest message in the thread, and the sheet behind it lists
every pin with its text. A window makes "the pins that happen to be loaded" the common answer,
and a banner reading three above a sheet listing one is a wrong answer rather than a narrower
one. So the page carries the conversation's **complete** pinned set beside its window — one
extra statement per emission, bounded by how many pins exist, and it is what the chat page now
reads for the count, the jump target and the sheet. `ChatTimelineViewModel.pinnedMessageIds`
became `pinnedMessages` for the same reason: the surface needs their text.

### D4. A jump reveals what it names

Four entry points can name a message older than anything loaded: search, the pinned banner,
reply-quote navigation, and `JumpToMessageIntent`. `_jumpIfRequested` resolved its target with
`indexWhere` over the loaded list and returned silently when it was absent, which a window
turns from an edge case into the common case — a working feature into a dead tap.

`ConversationTimelineWindow.reveal` looks the target's key up (`messageCursor`, a primary-key
lookup), and if it is below the current bound, opens the window to a page's worth of context
*below* it so the target does not land against the top edge. The widget remembers a jump it
could not resolve and runs it again when the page carrying the target arrives; without that,
the second build takes `didUpdateWidget`'s "nothing changed" branch and the jump is dropped
after the work to load it has already been done.

### D5. The window lives in a controller, not in a provider key

`ConversationTimelineWindow` is an application-layer object holding the current range, a
`loadingBefore` flag and an `olderLoadFailed` flag, and owning the database subscription. The
provider that the screen watches is keyed by `(currentUserId, conversationId)` — unchanged —
and the window is created once per open conversation behind it.

This is the point of the whole arrangement. If the cursor were part of the family key, asking
for an older page would change the provider's identity: `autoDispose` would dispose the old
one, the screen would be handed a fresh `loading` state, `ChatTimelineAdapter`'s `State` would
be rebuilt from nothing, and the reader's scroll position — the thing paging backwards exists
to preserve — would be gone. Retargeting instead swaps the inner subscription and leaves every
widget in place.

An anchored window that comes back empty resets itself to the newest page. That happens when
the anchor is deleted for this device out from under the bound; leaving it would show an empty
conversation that is not empty.

**The two windows compose rather than compete.** `ChatTimelineAdapter` still widens what it
draws first (80, then 60 at a time) and only asks the application when it has drawn everything
loaded. That handshake in `_loadOlder` is untouched; the database page (120) is simply what
"more" now means.

### D6. Six indexes, each with a plan behind it

Derived from `EXPLAIN QUERY PLAN` against a seeded database — 25 conversations, 4800 messages,
4800 attachments — not from the RCA's list, which predates ADR-061.
`test/features/local_storage/infrastructure/local_database_index_plan_test.dart` captures the
statements the production code really issues, through an interceptor, and asserts the plan for
each; an index that exists and is never chosen is write cost with no read benefit, and only the
planner can tell the two apart.

| Query | Before | After |
|---|---|---|
| the page | `SCAN messages` + `USE TEMP B-TREE FOR ORDER BY` | `SEARCH messages USING INDEX messages_conversation_ordering (conversation_id=?)` |
| is anything older | `SCAN messages` | `SEARCH messages USING COVERING INDEX messages_conversation_ordering (conversation_id=? AND ordering_ms<?)` |
| the next page's cursor | `SCAN messages` + `USE TEMP B-TREE FOR ORDER BY` | `SEARCH messages USING COVERING INDEX messages_conversation_ordering (conversation_id=? AND ordering_ms<?)` |
| the page's reactions | `SCAN messages` + `SEARCH message_reactions USING INDEX sqlite_autoindex_message_reactions_1 (message_id=?)` | `SEARCH messages USING COVERING INDEX messages_conversation_ordering (conversation_id=? AND ordering_ms>?)` + the same reaction seek |
| the page's receipts | `SCAN messages` + `SEARCH receipts USING INDEX sqlite_autoindex_receipts_1 (message_id=?)` | the same covering seek + the same receipt seek |
| the page's attachments | `SCAN attachments` + `SEARCH messages USING INDEX sqlite_autoindex_messages_1 (message_id=?)` | the same covering seek + `SEARCH attachments USING INDEX attachments_by_message (message_id=?)` |
| this conversation's pins | `SCAN messages` | `SEARCH messages USING INDEX messages_pinned_by_conversation (conversation_id=?)` |
| every conversation's pins | `SCAN messages` | `SEARCH messages USING INDEX messages_pinned_by_conversation (conversation_id=?)` |
| candidate events for a rebuild | `SCAN application_events` | `SEARCH application_events USING INDEX application_events_conversation_apply_state (conversation_id=? AND apply_state=?)` |
| sender-counter uniqueness check | `SCAN application_events` | `SEARCH application_events USING INDEX application_events_sender_counter (sender_device_id=? AND sender_counter=?)` |
| transport state for one event | `SCAN outbox_operations` | `SEARCH outbox_operations USING INDEX outbox_operations_by_event (event_id=?)` |

**`messages_conversation_ordering` on `(conversation_id, ordering_ms, ordering_event_id,
message_id)`.** The one the timeline is read through. Column order follows the query's leading
column *and* its ordering, so the same index answers the `WHERE`, satisfies the `ORDER BY` in
both directions with no temporary B-tree, and is covering for the cursor probe. It also serves
every other `WHERE conversation_id = ?` on `messages`: the unread count, mark-as-read,
mark-as-unread, delete-conversation-for-me, and the rebuild's read of the old rows.
**Write cost, measured:** rewriting every row of a 1200-message conversation — what
`_rebuildConversation` does on the real event path, and F2 leaves in place — costs **+3.0%**
with this index (27 442 µs → 28 270 µs, measured with only the attachments index for a
baseline). **Read win, measured:** one whole emission of the newest-120 window on that
conversation, 4676–5722 µs without the `messages`/`attachments` indexes against 2712–2911 µs
with them, on an in-memory database where a page read costs nothing. Under SQLCipher the ratio
is larger, because the pages the scan reads and the index does not are each a decrypt.

**`messages_pinned_by_conversation` on `(conversation_id, message_id) WHERE pinned`.** Partial,
so it holds a handful of entries rather than one per message and an insert that is not pinned
writes nothing to it. The catch is that SQLite will only choose a partial index when the
query's `WHERE` *provably* implies the index's, and a bound `pinned = ?` proves nothing at
prepare time: with the bound form the planner silently picks the ordering index and does a row
lookup for every message in the conversation to find the few that are pinned — measured
*worse* than the scan it replaced (287 µs → 453 µs). Both callers therefore spell the predicate
as the bare column, and the pins are sorted in Dart, because an `ORDER BY` on the ordering
columns is by itself enough to make SQLite prefer the index that sorts over the index that
answers. The plan test is the only thing that can catch either regression.

**`attachments_by_message` on `(message_id)`.** Read by the timeline, but **paid for on the
write path**, which is the opposite of what an index usually does here. `attachments.message_id`
is a foreign key into `messages` with `ON DELETE CASCADE`, and `PRAGMA foreign_keys` is on, so
every write to a `messages` row makes SQLite prove no attachment is orphaned. Without an index
on the child key that proof is a full scan of `attachments`, once per parent row. Measured on a
1200-message rewrite: **96 234 µs without it, 27 442 µs with it** — a 71% reduction in the cost
of the rebuild this change does not otherwise touch. On the larger seed (4800 attachments) the
whole index set takes that rewrite from 594 078 µs to 83 008 µs.

**`application_events_conversation_apply_state` on `(conversation_id, apply_state)`** and
**`application_events_sender_counter` on `(sender_device_id, sender_counter)`.** Both are on the
projector's path, not the timeline's, and both scan the entire event log — the second has no
conversation to narrow it at all, because a replayed counter is a fact about a device. The
justification is that their cost is a function of the database rather than of the work, which
is what the scaling measurement shows (same seeder, only the total event count varying, one
200-event conversation read):

| Total stored events | candidate events | sender-counter check |
|---|---|---|
| 1 000 | 778 µs → 649 µs | 129 µs → 86 µs |
| 5 000 | 768 µs → 636 µs | 367 µs → 148 µs |
| 20 000 | 1 207 µs → 613 µs | 1 238 µs → 369 µs |
| 50 000 | 6 342 µs → 1 494 µs | 9 891 µs → 1 947 µs |

Indexed, both stay flat; unindexed, both grow with everything the device has ever stored. The
table is append-only, so the write cost is one entry per insert each.

**`outbox_operations_by_event` on `(event_id)`.** Read whenever a message's transport state is
derived. ADR-061 narrowed this to messages being *created* rather than every message in a
rebuild, so it is no longer per-row-per-rebuild; it is still a whole-outbox scan each time it
runs, and the table is small and written a handful of times per send.

**What was measured and deliberately not indexed.** `unsupported_application_events` carries the
same sender-counter check, and is empty on a client at the current protocol version, so the
scan it does is free and an index there would be write cost with no measured read benefit.
`nextEditRevision`'s `MAX(revision)` over `application_events` runs once per edit and measured
~300 µs; it is not on a hot path. `pending_send_preparations.state`, which ADR-061 listed, is a
queue whose depth is the number of unsent messages — normally zero to three — so an index on it
would never pay for itself. The conversation list's own `SCAN conversations` +
`USE TEMP B-TREE FOR ORDER BY` is left alone: it reads every conversation by construction, and
sorting a few dozen rows is not what made opening the list slow.

### The migration

Schema 16 → 17, additive and index-only. No table is created, dropped, re-keyed or rewritten.
The step sits inside the existing `transaction()` wrapper with `StorageMigrationHooks` around
it, in the stepwise `if (from < N)` style the rest of the file uses, so a fault-injected failure
still rolls back to exactly the database that was there —
`local_database_migration_test.dart` covers that on a populated database and asserts that all
six indexes land and that every row is the row it was.

Each declaration carries `IF NOT EXISTS`, so the same statement serves `createAll` on a fresh
install and the upgrade step on an existing one, and neither can fail against a database that
has already seen the other.

**Expected cost on a populated database, stated rather than discovered on a phone.**
`CREATE INDEX` reads its whole table once. Six of them means two passes over `messages`, two
over `application_events`, and one each over `attachments` and `outbox_operations` — under
SQLCipher, where every page read is a decrypt. On the 4800-message seed the three largest took
1.9 ms, 0.35 ms and 1.1 ms; on a phone with real history the whole step is of the same order as
the `PRAGMA quick_check` already run at every open, and it is paid once, at the first open after
the update. The file grows: 1472 → 1731 pages on that seed, **about 18%**.

### What is page-scoped now, and said so

- **In-conversation search** reads the loaded window rather than the whole of the conversation's
  local history. The filter did not narrow; the list it is given did. A hit outside the window is
  reached by paging back, and the pinned banner, reply quotes and search results all still jump
  to a target outside it because `reveal` loads it first. Restoring whole-history search means a
  repository-side search rather than a filter over a decrypted list, and that is not this change.
- **The unread divider** is inserted before the first unread message in what is drawn. Unread
  messages are the newest, so they are in the first page by construction.
- **`ConversationSummary.pinnedMessageIds`** stays on the summary and is now computed for every
  conversation in one query rather than one per conversation. The chat page no longer reads it —
  it reads the page's complete pinned messages, because it needs their text as well as their ids
  — which leaves the summary field with no production consumer. Removing it would delete the
  pinned read from `watchConversations` and `readConversation` entirely; it is left in place here
  because it is part of the summary's contract and this change is already the read path's shape.

### What is explicitly left undone

- **F2, incremental projection.** `_rebuildConversation` still scans facts O(N²) and rewrites
  every message row in the conversation on the real event path. It is why the echo is still
  linear, and it is now the largest remaining cost on either path. The `messages` index is paid
  on every one of those rewrites, measured at +3%; `attachments_by_message` gives back far more
  than that.
- **F6**, identity and device-resolution caching.
- **F8**, `ChatViewModelMapper.messages` mapping the whole list. It now maps the window rather
  than the history, which is a smaller list for the same code, but it is still every loaded
  message on every emission.
- **F9**, `_messageKeys` pruning and the anchor walk. `_messageKeys` still grows for the life of
  the screen, and now grows a page at a time.
- **F10**, draft debounce.
- **The stream still subscribes to `messages` alone.** A change to a reaction, receipt or
  attachment row that does not also touch a message row does not re-emit. That was true before
  this change and stays true: on the real event path a rebuild rewrites the message row anyway.
  Widening the subscription without losing drift's result de-duplication is a separate change.
- **The window is measured in statements and microseconds, not on a device.** No A56 measurement
  of opening a long conversation has been taken for this change, and the microsecond figures
  above are from an in-memory SQLite with no SQLCipher underneath it, so they understate the
  win rather than overstate it.

## ADR-061 in full — the message goes on the screen before it goes on the network (2026-08-27)

**Status:** Accepted. Client-side latency and cost decision. Adds one local schema version
(15 → 16) and one table. Changes no cryptographic construction, no ciphersuite identifier,
no protocol, no wire format, no transport trust anchor, and no backend file. **Opens no
production gate.**

### The question

> A direct message takes more than three seconds to render its own bubble. Where does that
> time go, and what is the smallest set of changes that puts the user's own message on
> their own screen at the speed of a local write?

Two answers, and they are independent of each other.

**The send is behind the network.** `SendConversationEvents._send` encoded the event and
called `fanout.prepareAndQueue`, and everything that made the message *exist* was at the
far end of that call. `PairwiseFanoutCoordinator` resolved the peer's verified live devices
over HTTPS, resolved this account's own devices over HTTPS again, claimed prekeys for any
device without a session, ran one ratchet step per recipient device, and only then opened
the transaction — `commitPreparedSend` — that inserted the stored event and projected the
message. ADR-060 measured a real round trip from a phone at 107 to 137 ms; two of them plus
a claim plus the ratchet is the wait, and none of it is work the timeline needs. The bubble
was waiting on the recipient set.

**And every attempt transition re-projected the conversation.**
`refreshTransportForEventInsideTransaction` looked up the event and called
`_rebuildConversation`, which reads every candidate event in the conversation, decodes each
body, re-projects every message, rewrites every message row, and deletes and re-inserts
every reaction and receipt — to change one integer on one message. It is called from three
places in `DriftSyncStore`: claiming a batch (`queued → sending`), recording acceptance, and
`_updateOutboxBatch` (retry and permanent failure). So the cost of telling somebody their
message reached the relay was set by how long they had been talking to that person, and it
was paid twice per send on top of the projection the send itself did.

Measured in `test/features/messaging/local_send_cost_test.dart`, against a conversation of
61 messages: **one full projection of that conversation is 195 statements**. Against five
messages it is 27. That is the number each transition was paying.

### D1. The local commit goes first, and the fan-out becomes a durable request

`ApplicationFanoutPort.prepareAndQueue` is replaced by `commitLocalEcho`. It writes, in one
transaction: the `pairwise_local_applications` row that holds the opaque payload, a row in
the new `pending_send_preparations` table, and the projection. It touches no network. The
message is on the timeline when it returns.

The new table is the request. A row in it says: this operation's event is committed, and
its per-recipient ciphertext is owed to this peer. It carries the operation id, the event
id, the local user and device, the peer, an attempt count and a due time — and nothing
else, because the bytes to be sealed are already in `pairwise_local_applications` under the
same operation id. It is a queue in the shape `pending_application_receipts` and
`stale_device_refresh_requests` already use: a row exists while work is owed, and is deleted
in the same transaction that writes the outbox rows.

**Why a table and not a column.** `pairwise_local_applications` could have carried a state
column, and that was rejected: the row there is a durable payload with an idempotency key,
and it outlives the work by design — retained metadata, pruned on a sixteen-day cutoff. A
queue whose depth is `COUNT(*)` and whose empty state means "nothing owed" is a different
object with a different lifetime, and merging them would have made both harder to reason
about. The one place they are coupled is now explicit: **retention never discards the
payload of a send still owed.** Sixteen days of owing one is pathological, but discarding
those bytes would leave a message on screen that nothing can ever seal.

**Every application event takes this path, not only a message create.** Edits, deletions,
reactions, pins and receipts are all sends, they all went through the same fan-out, and
splitting only the message create would have left two paths through one port for no
benefit. A reaction now appears instantly for the same reason a message does.

### D2. The delivery cycle owes the fan-out, and runs it before the outbox

`DurableSyncEngine` gains one stage, `_prepareSends`, immediately before each of its two
`_flushOutbox` passes. It asks the store for the oldest due preparation, hands it to a new
`SendPreparationPort`, and the same cycle carries the resulting ciphertext to the wire.

The port's implementation, `PairwiseSendPreparationAdapter`, calls
`PairwiseFanoutCoordinator.prepareOwedSend` — which is the same `_prepare` body
`prepareAndQueue` runs, differing only in how it decides the work is already done and what
it does with no recipients. **Re-entrancy moves from the operation record to the outbox.**
It used to be enough that `readPreparedOperation` returned non-null; the echo writes that
record before any ciphertext exists, so sealed outbox rows are now the test, and finding
some means an earlier attempt committed and died before its caller heard about it.

Failure handling is the outbox's, deliberately. A transport-shaped failure leaves the row
owed with a due time and ends the stage — the next preparation would fail the same way and
the rows are durable. A settled failure (`_isPermanentSendFailure`, or a `SecurityFailure`:
a device set that changed under the claim, a peer this build cannot encrypt to) retires
that one row to a terminal state and the stage continues to the next, so one unsendable
message is not a stuck queue. Nothing is marked in flight, because nothing is: a
preparation either commits in the transaction that also retires it, or it does not, and a
process that dies mid-attempt comes back to a row that is exactly owed. `SyncRetryPolicy`
and the per-run budget are shared with the outbox; the budget is 32 rather than 100 because
a preparation is two round trips and N ratchet steps against a batch send's one request.

**Device-log gossip moved with it.** `PairwiseApplicationFanoutAdapter.afterSuccessfulQueue`
awaited `DeviceLogGossipCoordinator.queueForUser` on the send path, and that call is itself
a full fan-out with its own device lookup and its own ratchet steps. It now runs after a
successful preparation, in the same background stage. Its failure is swallowed rather than
reported: gossip is owed to a peer and not to this message, and by the time it runs the
message's ciphertext is already durable.

### D3. `outbox_depth` counts operations, and counts what is owed

ADR-060 states the rule this depends on: *sending is not a call into the supervisor; a
composer writes a durable row and returns, and the row is the request.* Local echo changes
which row that is. If the projection kept counting only `outbox_operations`, an echoed
message would raise nothing, and nothing would wake the engine.

So the depth is now `COUNT` over the union of non-terminal outbox operation ids and owed
preparation ids — **per operation, not per row**. The per-operation part is not cosmetic.
The supervisor triggers on the depth *growing*, and a send that later seals three envelopes
has not become three new sends; counting rows would have asked for a second cycle that
arrived to find the work already done, having paid an authoritative drain — a REST round
trip — to discover it. Counted this way, an echo raises the depth by exactly one, sealing
it raises it by nothing, and acceptance returns it to zero.

`nextRetryAt` gains the preparation queue for the same reason it already covers the inbox,
the outbox and the reconnect schedule: a send waiting out a backoff is a *time*, and it is
the one kind of work nothing else announces.

### D4. `messages.status` is a column the rebuild carries through

This is the answer to the clobber hazard, and it is the codebase's own.

`_rebuildConversation` still runs on the real event path and still writes every message
row. If something narrower becomes the authority on transport state, a later rebuild must
not overwrite a fresh value with a stale re-derivation. `messages.alerted`,
`messages.starred` and `messages.delivered_receipt_sent` already answer exactly this shape
of problem, by being columns the rebuild does not own.

`status` joins them, with one difference worth stating: those three are preserved by being
omitted from the upsert companion, while `status` is required at insert. So the rebuild
reads the existing row's status — it already reads the old rows, for `deleted_for_me` and
`unread` — and carries it into the projected message. A row it is *creating* still derives
one. **`outbox_operations` therefore remains the authority**, exactly as it was: it is
consulted whenever a row is created, and by every narrow update. What changed is that a
rebuild is no longer one of the things that asks.

This also removes a per-message `SELECT` from every rebuild. `_transportState` ran one
`SELECT … FROM outbox_operations WHERE event_id = ?` per message per rebuild; it now runs
only for a message being created.

`refreshTransportForEventInsideTransaction` is narrowed rather than deleted, so its three
call sites are unchanged and the ordering the stale-device path relies on — the refresh
after the pairwise-session deletes — is untouched. It reads the stored event, returns
immediately unless that event is a locally originated message create (an edit, a reaction, a
receipt or a device-log object owns no delivery state of its own and used to trigger a full
rebuild for nothing), derives the state, and writes one row. The row is identified by
`message_id = :eventId AND ordering_event_id = :eventId`: `SendConversationEvents` puts the
event id in the body as the message id and the projector records that same id as
`ordering_event_id`, and asserting both in the predicate means an event that somehow
disagreed updates nothing rather than the wrong row.

### D5. An eighth transport state, because seven cannot say this

`MessageTransportState.preparing` is added, **appended** at ordinal 7 — the ordinal is what
`messages.status` stores and every value before it is already on a device. The check
constraint on that column is `0..8` and already admits it, so this needs no column change.

Seven could not express the new window. `queued` means sealed bytes are waiting for the
transport; the new state means the recipient set has not been resolved and nothing has been
sealed at all. Calling it `queued` would have been a claim about an audience that had not
been asked for yet, and `localOnly` — "kept on this device" — would have been worse.

The evidence that this state was always missing is that the timeline already had a word for
it. `ChatDeliveryViewState.encrypting` exists, `chatStateEncrypting` is translated in both
locales, `_DeliveryIndicator` and `_deliveryLabel` both handle it, and **nothing could ever
produce it**: the mapper had no `MessageTransportState` to map onto it. This change makes an
existing, unreachable UI state reachable, which is the opposite of adding one.

### D6. A retry recovers the message, instead of writing a second one

`RetryMessageIntent` called `sendText` again: a new event id, a new sender counter, a new
message row beside the failed one. That was tolerable when a failed send left nothing on
screen. It is not tolerable now, because F1 puts a row there for exactly the failures that
used to be invisible.

`SendConversationEvents.retrySend` asks the fan-out port to re-arm
`application:$messageId` first. `rearmFailedSend` finds one of two durable failures and
repairs it in place: a terminally failed preparation goes back to owed with a zero attempt
count, or permanently failed outbox rows go back to queued — the same repair schema 14
applied to every stranded row at once, asked for one operation at a time by the person
whose message it is. Either way the projection is refreshed narrowly and the depth rises, so
the supervisor runs a cycle. A fresh `sendText` remains the fallback for the one case with
nothing to re-arm, a message whose operation record has already been pruned.

The reserved sender counter is untouched by this. It is consumed once, by the send that
created the event, and a retry that re-arms consumes none — which is strictly better than
before, where every retry burned another.

### Crash safety

The new window is between two transactions that used to be one, and four assertions in
`test/features/messaging/local_echo_crash_safety_test.dart` are made against a reopened
database file rather than against objects an interrupted run left behind:

- A fault on the outbox insert leaves the message visible, the preparation owed, no
  ciphertext and no ratchet step — the session transitions were in the transaction that
  aborted — and `beginNextSendPreparation` hands the work straight back.
- A fault on the preparation delete rolls the outbox rows back with it. **Never both**: the
  retry cannot queue a second copy.
- A successful seal leaves no preparation and one operation's rows, and the cycle stops
  asking.
- A fault while projecting leaves no message, no event, no local application and no
  preparation. **Never neither**: a request is only owed for a message that exists.

Determinism is unchanged. The same event log still produces the same projection: the echo
runs the same `applyInsideTransaction` the atomic commit used to run, and `status` — the one
value a rebuild now carries through rather than re-derives — is not a function of the event
log at all. It never was; it is a function of `outbox_operations`, which is local transport
state that no two devices are expected to agree on.

### What it cost, measured

From `local_send_cost_test.dart`, which asserts the transition costs are *equal* across two
conversation lengths rather than merely bounded, so a rebuild finding its way back onto this
path fails loudly:

| | 5 messages | 61 messages |
|---|---|---|
| One full projection of the conversation | 27 | **195** |
| The echo the user waits for | 33 | 201 |
| Preparation → queued, when the fan-out lands | 15 | **15** |
| Queued → sending | 7 | **7** |
| Sending → relay-accepted | 4 | **4** |

Before this change a send cost three full projections — one at commit and one for each of
the two transport transitions — which at 61 messages is 195 statements each. After it, the
two transitions cost 7 and 4 regardless of conversation length, and the third projection is
the echo, which still runs one (see below). The network round trips in front of the visible
message went from two lookups, a claim and N ratchet steps to **none**.

### What is explicitly left undone

- **F2, incremental projection.** `_rebuildConversation`'s O(N²) fact scanning is untouched,
  and it is the whole of the echo's 201 statements. The cost test asserts that this number
  grows with history rather than hiding it. It is the next thing to fix and the reason the
  echo is not already a handful of statements.
- **F4, indexes.** No index is created. `outbox_operations.event_id`,
  `messages.ordering_event_id` and `pending_send_preparations.state` are all unindexed
  scans, which is why the numbers above are as high as they are for the work they do.
- **F5**, the `watchMessages`/`watchConversations` N+1 shape and its missing `LIMIT`.
- **F6**, identity and device-resolution caching. The preparation still resolves both device
  sets over the network on every send; it is simply no longer in front of the user.
- **F7**, what device-log gossip does and when it is owed. It moved off the synchronous path
  as a consequence of the fan-out becoming background work; its semantics are unchanged.
- **F8-F10**, the view-model mapping window, `_messageKeys` pruning, and the draft debounce.
- **The send is measured in statements, not on a device.** The figures above are from the
  suite. No A56 measurement of the tap-to-bubble latency has been taken for this change.

## ADR-060 in full — what a delivery cycle owes the message the user just sent (2026-08-26)

**Status:** Accepted. Client-side correctness and cost decision. Adds one local schema
version (13 → 14) and one column. Changes no cryptographic construction, no ciphersuite
identifier, no protocol, no wire format, no transport trust anchor, and no backend file.
**Opens no production gate.**

### The question

> Sending a direct message on the beta artifact took fifteen to twenty seconds to reach
> `POST /api/v1/envelopes`, and the peer never received it — not in twenty-seven minutes,
> not at all. Meanwhile both devices, completely idle, re-downloaded about 1.1 MB every
> minute and burned between two thirds and one and a half of a CPU core. Where is that,
> and what is the smallest set of changes that makes a send a send?

Measured on 2026-08-26 against `0.1.0+1` beta (versionCode 12) on a Samsung A56 and on the
emulator. The network and the backend were measured first and cleared: ICMP to the server
averaged 27.9 ms at 0 % loss, a real HTTP round trip from the phone — connect, request,
response, close — was 107 to 137 ms, and Django plus daphne added about 30 ms over a pure
nginx response on the same warm connection. The client's own counters agreed: over more
than a thousand requests, `backend_rejected=0`, `transport_failed=0`, `cancelled=0`,
`malformed_response=0`, `slowest_response=under2Seconds`. Every finding below is therefore
client-side, and `backend/` is untouched by this decision.

### D1. A run may not end because one envelope would not open

`DurableSyncEngine._run` executed inbox, then post-inbox work, then acknowledgements, then
the drain loop, and only then the outbox — and *every* one of those stages returned its
first failure straight out of `_run`. Inside the inbox pass, an inspection failure that was
not classified as rejectable wrote a retry row and then returned a failure too.

The consequence is the entire user-visible fault. A device holding one envelope it cannot
open never reached its own outbox, so a message whose per-recipient ciphertext was already
sealed and already durable sat in `outbox_operations` while the engine spent every cycle
failing on somebody else's bytes. Both measured devices were in exactly that state:
`pending_inbound` frozen at 10-99 on the phone and 100-999 on the emulator, unchanged over
nine and six minutes respectively, beside `quarantined_input=0`.

**Decided.** A per-envelope failure is recorded against that envelope and the loop
continues. The one condition that still ends a run is a failure of the *store* — a Drift
transaction that will not commit — because a run that cannot write anything down cannot
make progress and would spin. That distinction is drawn by *source*, not by type: a
`StorageFailure` returned by a `_store` call ends the run; the same type returned by the
inspector is one envelope's transient problem.

The outbox now runs **first**, before any inbound work, and again at the end. Nothing a
queued outbox row needs comes from the inbox — the ciphertext is sealed before the row
exists — so the only thing the ordering decided was who waits for whom, and the answer was
wrong. The second pass exists because the inbound half queues rows of its own: delivery
receipts, group Commits, eviction fan-out. It is skipped when the first pass already found
the transport unwilling, since a transport that refused one batch will refuse the next and
those rows are durable.

A failure that says the *session* rather than one envelope is unhealthy is still reported:
it is carried in `_RunProgress.failure` and returned at the end, after the local half of
the cycle has run to completion. The supervisor therefore still backs off on a transport
that will not carry a request, and `recordSuccessfulSync` and `markConnectionPhase(online)`
still happen only when the cycle genuinely completed. Neither had run on either measured
device, because the run never reached them.

### D2. An envelope this device can never open needs a terminal state

`_isRejectableEnvelopeFailure` accepted a `ValidationFailure`, or a `SecurityFailure` that
was not `policyBlocked`, and quarantined those. Everything else was retried forever. A
`CryptoCoreFailure` — the native core refusing these bytes — is not in that set, and
neither is `SecurityFailure(policyBlocked)` nor an unsupported protocol. So the server
re-served the envelope on the next drain, the device re-stored it, re-inspected it,
re-failed, and re-downloaded it again on the cycle after that. That loop is the 1.1 MB per
minute: a hundred envelopes per page, fetched and stored and never retired, on a device
where nothing at all was happening.

**Decided.** Envelope inspection gets a bounded attempt budget,
`SyncEngineLimits.maximumInspectionAttempts`, defaulting to **8**. Causes are split in two:

- **Transient** — `TransportFailure`, `StorageFailure`, `CancellationFailure`,
  `AuthenticationFailure`, `BackendFailure` that is `rateLimited`, `quotaExceeded` or the
  `unknown` every unnamed 5xx maps to, and `CryptoCoreFailure` that is `resourceExhausted`
  or `entropyUnavailable`. These retry and spend no budget. A device that is offline or out
  of storage has learned nothing about the bytes in hand, and spending the budget on it
  would quarantine messages the device could have opened.
- **Settled** — everything else. The native core refused these bytes, policy rejected
  them, or the protocol is one this build does not implement. No later attempt changes any
  of those, so each one spends budget, and the eighth retires the envelope.

Retirement is `recordEnvelopeRejection` followed by acknowledgement. Quarantining alone
would leave `pending_inbound` falling while the server kept serving the same bytes; the
acknowledgement is what makes the server delete them. The invariant that an envelope is
never acknowledged without first being either applied or quarantined is unchanged, and a
quarantine record still carries a numeric `reasonCode` and an empty digest — a number, and
nothing that could identify anything.

This is deliberately *not* a first-occurrence quarantine, even though every cause in the
settled class is by definition permanent. A budget of eight costs a device eight attempts
against bytes it will discard anyway, and buys back the case where the classification
itself is wrong — a cause listed as settled that a future build handles. Eight failed
attempts against one envelope is a cheap way to be wrong about that; discarding on the
first is not.

The budget lives in a new `inbox_envelopes.inspection_failures` column rather than in
`attempt_count`. They answer different questions: `attempt_count` counts every begun
attempt, inspection and acknowledgement alike, and drives retry backoff, so it rises while
a device is merely offline. Overloading it would have made the two classes above
indistinguishable, which is the whole point of drawing them.

`SyncRunReport` gained `quarantinedEnvelopes` and `failedInspections`. Counts, and
deliberately nothing else — which envelope, why, and what was in it are all identifiers.

### D3. Ordering by sequence stays, because retirement is what unblocks the head

`beginNextEnvelopeInspection` hands out the oldest due envelope, so a permanently
un-openable low-sequence row was re-tried ahead of everything else on every pass. Once D1
stops the pass aborting and D2 retires the row, the ordering is no longer the problem, and
in-order delivery for healthy envelopes is worth keeping. It is kept.

Two guards make that true rather than nearly true. `SyncRetryPolicy.delayFor` draws
uniformly from `[0, cap]` and so returns zero on a real fraction of draws; on the
lowest-sequence row that is a pass which inspects one envelope a thousand times and never
reaches the second. Inspection retries therefore carry a floor,
`SyncEngineLimits.minimumInspectionRetry`, of one second — the only thing that makes "leave
it for later" mean later. And a pass working through a large mailbox can outlive that
floor, so a pass also remembers what it has already deferred: when the head of the queue is
something this pass has already dealt with, the pass ends, and the drain, the
acknowledgements and the outbox all still run.

### D4. Reconnect backoff is not delivery scheduling

`SyncLifecycleSupervisor._runCycles` called `_scheduleReconnect` on *any* failed cycle, and
that persists `reconnect_at = now + delayFor(attempt)` where the delay is a uniform draw
from zero to a five-minute cap. That uniform draw **is** the thirteen to twenty seconds the
user waited, and it is why the two measured runs differed at all: 15.05 s and 19.91 s are
two samples from the same distribution.

**Decided.** Reconnect backoff exists for a transport that will not carry a request, and is
applied only to `TransportFailure`, `AuthenticationFailure`, and `BackendFailure`
`rateLimited`. A cycle that failed locally — an envelope that would not open, a batch the
server refused on its contents — schedules nothing, and if a request arrived while it was
running it runs again immediately. That `continue` re-checks the loop condition, so it can
only repeat while somebody is actually asking; it cannot spin on its own.

The reconnect attempt counter is now retired by any completed cycle, not only by
`_markStableAfterDelay` thirty seconds after a socket opens. A completed cycle is the
stronger evidence: it means the REST path carried a drain, an acknowledgement and a send.
A flag keeps that to a single write, and starts true so the first successful cycle of a
process clears whatever the previous process left behind.

**And the wake-up that came with it has to be replaced, not simply removed.** This was
found on the devices rather than in the reasoning: with backoff no longer firing on every
failed cycle, a row waiting out a retry had nothing left to wake it. Rows in retry-wait are
the only work in this system that nothing announces — a socket hint is an inbound envelope
and a growing outbox is a new send, both events with triggers, while a retry is a *time*,
and the only thing that happened to re-run the engine on one was the bug. So the supervisor
now arms a wake-up on `SyncProjection.nextRetryAt`, which is already the earliest due time
across the inbox, the outbox and the reconnect schedule, so one timer covers all three. It
cannot spin: it arms only for a time in the future, only when that time is earlier than
whatever it is already waiting for, and the cycle it eventually runs either finishes the
work or pushes the due time further out. On the emulator this is the difference between a
poison envelope retiring and a poison envelope sitting until something unrelated happens.

### D5. The devices that already ran the broken engine have to be repaired, not just fixed

A code change alone leaves the measured devices exactly as they are. Their inbox rows are
stranded in `inspecting` behind attempt counts high enough that the backoff they produce is
a quarter of an hour of uniform jitter; their outbox rows — including the two stranded
probe messages — are waiting out the same thing; and the emulator's `conversations`
projection reads zero while its `messages` rows exist and the chat page renders one from
them.

**Decided.** Schema 14 carries a one-shot, idempotent repair beside the new column. It
resets non-terminal inbox rows to `received` with a zero attempt count and no due time,
does the same for non-terminal outbox rows, un-tombstones any conversation that has
messages, and inserts a minimal conversation row for any conversation whose row is gone
entirely. None of it is content, all of it is scheduling and projection state, and all of
it is derivable — the ordering key comes back from `MAX(ordering_ms)`, and the rendered
preview is left to the next projector pass rather than guessed at.

The orphan-row branch is defensive: the foreign key makes that state unreachable while it
is enforced, so it exists for a database written while it was not. The tombstone branch is
the one the emulator is actually in.

**This ships as an in-place update.** The A56 holds real beta data under a non-exportable
Keystore key with `allowBackup="false"`; `adb install -r` under the frozen signing identity
is the only route, `tool/verify_upgrade_continuity.sh` uninstalls the application under
test and must never be pointed at that device.

### D6. `cipher_memory_security` is turned off

SQLCipher ships `cipher_memory_security` **off** and documents it as a large slowdown; it
scrubs and locks every allocation the library makes. This project had it on, on the hot
path of every statement.

**Decided.** It goes, and the reason is not the cost. What it defends against is reading
plaintext out of a live process, and `docs/threat-model.md` places "a device compromised
while it can decrypt content" explicitly **outside the guarantee**. Even inside that
threat, the defence would be partial in a way that makes it decorative: the same plaintext
is simultaneously in the Dart heap, in the text-shaping and raster buffers of the Flutter
engine, and in the platform's own view system, and this pragma reaches none of them. What
the threat model *does* cover — "a person with filesystem access to a locked but otherwise
uncompromised Android device" — is answered by the SQLCipher key itself, which is
unchanged, still 256-bit, still wrapped by a non-exportable Keystore key. The line in
`platform_local_storage_native.dart` is a comment saying this, so the next reader sees a
decision and not an omission.

`shareAcrossIsolates: true` **stays**, and this is the reason it is written down rather
than left as a default. Delivery runs from a second entry point — the deferred catch-up
wakes this process with no user interface at all — so two isolates genuinely can hold this
database open at once, and a port round trip per statement is the price of that being safe
rather than a race. It is not a knob to turn until somebody has measured what it actually
costs after D7.

### D7. The projection watch, the drain page, and the checkpoint row

Three costs, all of them the same shape: work repeated once per envelope that only needed
doing once.

- **`persistDrainPage` asked about each envelope twice.** One `SELECT … WHERE envelope_id
  = ?` and one `SELECT … WHERE sequence = ?` per envelope, plus a full `COUNT(*)` over
  `inbox_envelopes`, inside a single write transaction — roughly two hundred statements per
  page to establish that all hundred rows were already there, which during any backlog is
  the ordinary case rather than an edge one. It is now two set-based reads for the whole
  page, and the capacity check reads one primary-key value past the headroom instead of
  counting the table. Measured in the suite: **four statements** for a fully re-served
  hundred-envelope page. The `_ServerInvariant` semantics are byte-for-byte unchanged — a
  re-served envelope whose ciphertext or sequence disagrees with the stored row is still a
  hard violation, and so is a second envelope claiming a taken sequence.
- **`readProjection()` ran once per envelope.** It is a three-subquery aggregate — two
  `COUNT(*)`s over the two largest tables and a `MIN` over a three-way `UNION ALL` — and
  the inbox loop recomputed it from scratch on every one of up to a thousand iterations to
  read one boolean. There is now `readQueueGapState()`, one column off the singleton
  checkpoint row, read once per pass. Once is correct and not merely cheaper: only
  `persistDrainPage` sets that flag, which happens between passes, and nothing inside a
  pass can clear it, because while a gap is open the inspector is forbidden from advancing
  MLS state and the authenticated re-admission that would retire the obligation cannot be
  committed from there.
- **`watchProjection` re-ran that aggregate on every write.** Its `readsFrom` names
  `sync_checkpoints`, `inbox_envelopes` and `outbox_operations` — exactly the three tables
  the engine writes on every state transition. It is now conflated on a 250 ms window,
  which keeps both properties a listener depends on: the first value is emitted
  immediately, so a restart still replays the durable outbox depth and drains what was
  queued before the process died, and the last value of every window is always emitted, so
  no state is skipped. Growth of the outbox depth additionally bypasses an open window
  entirely, because that transition is the one somebody is waiting on — a message the user
  has already sent, whose only route out of the process is a listener noticing the rise. So
  conflation can never cost a send its latency. The window is a constructor parameter so a
  test can collapse it to one turn of the event loop.
- **`_ensureCheckpoint` wrote on every read.** An unconditional `INSERT OR IGNORE` against
  `sync_checkpoint` sat in front of every projection read, every phase transition and every
  checkpoint read — an insert statement against one of the three tables that watch reads
  from. It reads first now, and writes only when the row is genuinely absent.

### D8. The socket hint stays a hint

`GatewayRealtimeSyncAdapter` drops the envelope bytes a socket event carries and follows
every hint with an authoritative REST drain. That was re-examined, and it is **kept**.

The cost is real and now written into the comment: one REST round trip per inbound message,
107 to 137 ms from a real phone, and one re-download of bytes the socket already delivered.
What it buys is that one code path decides what is in this device's mailbox. The drain page
is where `pruned_through` arrives, and `pruned_through` against the local contiguous
acknowledgement watermark is the *only* way a lost envelope is detected — the mechanism the
whole queue-gap recovery matrix is built on. A pushed frame carries no such watermark, so
seeding the inbox from one would be a second admission path that cannot answer the question
the first exists to answer.

The measured idle traffic that made this look expensive was never this. It was D2: an inbox
that could not retire what it could not open, so the same hundred envelopes were served,
stored and served again on every cycle.

### D9. A response this client refuses is a transfer it must stop

Two sockets sat in `CLOSE_WAIT` against the server on the emulator for more than twenty
minutes, holding 16,456 and 7,546 unread bytes. Reading Dio 5.11.0 rather than guessing:
under `ResponseType.stream`, Dio does **not** hand back the socket. `handleResponseStream`
subscribes to it the moment the headers arrive and pumps every byte into an internal
`StreamController` whose stream is what the caller receives — and that controller has no
cancel hook. A caller that stops reading stops nothing; the download runs to completion into
a buffer nobody will read.

The consequence is worse than a leaked socket. `DioRestClient` rejected a response whose
declared `Content-Length` exceeded `maximumResponseBytes` and returned **without touching
the body at all**, which means that limit was bounding the *decode* and not the *transfer*:
the oversized body arrived in full, into Dio's buffer, and the connection was held until it
did.

**Decided.** Every path that abandons a response cancels the request's `CancelToken`, which
is what reaches Dio's own subscription and through it the `HttpClientResponse`, so
`dart:io` stops reading and releases the connection. That covers the declared-size
rejection, the mid-stream size rejection and caller cancellation. `_readBounded` was also
rewritten around an explicit subscription so that completion, overflow, cancellation and a
stream error all leave through one `cancel`.

Cancelling rather than draining is deliberate: the callers here are paths that rejected the
response *because* it is larger than they are willing to read, so draining it to keep the
connection poolable would be the same unbounded read under another name.

Connection reuse is addressed alongside it, to the extent it can be without a device.
`TransportSecurity` now states `idleTimeout` explicitly at thirty seconds rather than
inheriting a default from whichever layer happens to supply the client: `dart:io` gives
fifteen seconds and Dio's own factory — which this replaces, and could stop replacing —
gives three, short enough that a drain and the send after it each pay a fresh TCP and TLS
handshake. Thirty spans the phases of one delivery cycle and stays inside a stock nginx
`keepalive_timeout` of sixty-five, so this side gives the connection up first and no
request races a close it cannot see. **Whether that alone ends the observed churn is not
measured**, and is recorded as open below.

### D10. The application stops claiming a presence it cannot know

The chat header rendered "online via a subscribed device" or, failing that, "offline". It
always rendered the second, for everyone, forever — including a peer holding a live socket
in the same conversation. The reason is structural: `subscribe_presence` is a frame this
client validates and never sends. The only frame it writes is `auth`. With no subscription
the server has no target to emit presence to, so `applyPresence` is called by nothing and
`onlineDeviceCount` is zero by construction.

**Decided.** The claim goes. Implementing `subscribe_presence` is a real feature with its
own exposure question — a subscription tells the server which peers this device is watching
— and it is not something to bolt onto a latency fix. Saying nothing is the honest state
until the subscription exists; the header now speaks only while somebody is actually
typing. The port, the projection and the frame validation are all left in place, because
what is missing is the subscription and not the machinery.

### D11. A stalled engine is now visible

Nothing in the application consumed `SyncConnectionPhase`. The engine had been writing it
all along and no screen read it, so a jammed engine and a slow network looked identical
from outside — which is how a stall that lasted twenty-seven minutes went unnoticed by the
person it was happening to.

**Decided.** The chats list carries one content-free line, in the place the offline notice
already occupies: connecting, syncing, waiting to reconnect, or — when the session is
settled — nothing at all. Four states, no counts, no identifiers, no timings, and no alarm.
An indicator that is always on screen is one nobody reads, and this one exists to be
noticed on the day it stops changing. Every terminal phase — revoked, circuit open, origin
rejected — reports as waiting, because the session-level surfaces already own those
conditions and speak about them properly, and a second vaguer voice for them here would be
worse than silence.

### D12. What the fix unmasked: a delivered receipt owed once per rebuild

Found on the devices, an hour after the rest of this had been installed and was working.
Both phones were pulling and pushing continuously while nobody was using them — the A56 at
roughly 250 KB/min inbound and 90 KB/min outbound, the emulator at 80 and 97 — and the rate
did not decay over two hours, which is not what draining a backlog looks like. Backgrounding
the application took the device-wide figure to 14 KB/min, so it was this process, and the
outbound half said it was *sending*, not catching up.

`DriftApplicationEventProjector._writeMessage` queued a delivered receipt whenever
`pendingDeliveredReceipt` was true, and that flag is derived from three properties that
never change: the message did not originate locally, the sender is not this account, and the
conversation is direct. It is a statement that a receipt is owed *in principle*, not that one
is outstanding. `_rebuildConversation` rewrites every message in a conversation on every
applied event, so every event re-queued a receipt for every message that conversation had
ever received — and each receipt is an event at the far end, which rebuilds that conversation
and re-queues its own. Two devices in one conversation sustain that indefinitely, at a rate
set by how much history they share.

**Decided.** `messages.delivered_receipt_sent`, modelled on `messages.alerted`, which exists
for exactly this shape of problem: a durable one-shot marker that a projection rebuild
preserves because the rebuild's companion omits the column. `completePendingDeliveredReceipts`
sets it in the same transaction that clears the queue row, and the projector consults it
before queueing. Schema 15 adds the column, marks every existing message as already
acknowledged — everything already on a device has had its receipt sent many times over — and
empties the pending queue, so the upgrade itself does not send one more round.

This is not one of the defects this work set out to fix, and it is not new: the loop has been
there for as long as the projector has. It could not run, because the engine never reached
the outbox — the receipts piled up locally behind the same wall as everything else. Fixing
D1 opened it, and the idle-traffic figure this change is measured against cannot be met while
it runs, so it is fixed here rather than filed.

### What this does not do

- It does not change `backend/`. The server was measured healthy and its wire contract is
  correct. Nothing in `messaging/`, `realtime/`, nginx or the daphne unit is touched.
- It does not weaken TLS or trust. `badCertificateCallback`, `withTrustedRoots: false` and
  the provisioned-CA path are untouched; the only change in that file is an explicit idle
  timeout on the pooled client.
- It does not change the wire contract, the exact-ciphertext semantics of an outbox row, or
  the rule that every network call is bracketed by a Drift journal transition.
- It does not add a diagnostics field. `pending_inbound`, `quarantined_input` and
  `conversations` already answer everything this change needs answered, and
  `DiagnosticValue` still has no constructor that accepts a runtime string.

### What it was worth, measured

The before-and-after table is in
[`docs/validation/delivery-latency/2026-08-26-adr-060/`](validation/delivery-latency/2026-08-26-adr-060/README.md),
taken on the same two devices as the investigation, upgraded in place. In short:
`pending_inbound` went from frozen at `10-99` and `100-999` to **zero** on both;
`quarantined_input` from `0` to `100-999`, which is what a terminal state looks
like from outside; the emulator's `conversations` from `0` to matching its own
list; idle CPU from 4.37 CPU-s per ten seconds to **0.00**; and a message from
one device was on the other **2.33 seconds** after the tap, against never. Both
messages the investigation left stranded delivered, and `durably delivered` — the
state that had never been reached at all — now arrives in both directions.

Two readings carry caveats that are stated in full in that record rather than
smoothed over here: idle traffic can only be measured device-wide on these
kernels and is not certified under the twenty-kilobyte target, and the
send-latency instrument cannot resolve below about two and a half seconds, so
the sub-second figure is reached by implication from the peer-arrival number
rather than measured directly.

### Open, and named as open

- **Connection reuse (D9) is unverified.** The leak is fixed and the keep-alive lifetime is
  stated, but whether the measured `TIME_WAIT` churn ends is a device measurement that has
  not been taken.
- **`shareAcrossIsolates` (D6) is unmeasured.** It stays until somebody measures the port
  round trip against the statement volume that survives D7.
- **`subscribe_presence` (D10) is unimplemented.** Presence is absent rather than wrong,
  which is the correct interim state and not the finished one.
- **The idle-traffic target is not certified.** Neither device offers per-uid byte
  accounting, so the residual can only be bounded, and what bounding it shows is socket
  reconnect churn on a transport both devices already report as the thing that fails —
  which is a different question from this one.

## ADR-059 in full — the chat page's emoji surface, and what it costs (2026-08-25)

**Status:** Accepted. Dependency decision, under the rules ADR-054 established. Adds one
direct Dart dependency and the Android modules it brings with it. Changes no cryptographic
construction, no ciphersuite identifier, no protocol, no wire format, no transport trust,
no state format, and no backend file. **Opens no production gate.**

### The question

> The chat page has an emoji button that inserts one hardcoded `🙂` and a React row that
> sends one hardcoded `👍`. Making either of them real needs an emoji picker. Is there a
> package that supplies one under this project's constraints, what exactly does it bring
> with it, and what is pinned?

Nothing was assumed: not that a package is needed, not that the newest version is the
right one, and not that a picker is a purely visual component. The last two turned out to
be the interesting ones.

### D1. The version is not simply the newest

`emoji_picker_flutter` **4.5.3**, published 2026-07-24, read from pub.dev and from
`github.com/Fintasys/emoji_picker_flutter` on **2026-08-25**. Its `environment` is
`sdk: ">=3.11.5 <4.0.0"`, `flutter: ">=3.41.8"`; this project is Dart 3.12.2 on Flutter
3.44.7, so it resolves. It is pinned exactly, with no caret, and added to the literal map
in `test/architecture/dependency_policy_test.dart`, as every direct dependency here is.

What makes 4.5.3 the answer rather than merely the latest is its entire changelog entry:
*"Fix Android build failure (`Could not find method kotlin()`) on AGP 9 when
`android.builtInKotlin=false`."* `android/gradle.properties` in this project carries
exactly `android.builtInKotlin=false`, written by Flutter's own AGP 9 migrator, and
`android/settings.gradle.kts` pins `com.android.application` 9.0.1. 4.5.0 is where the
package moved its Android plugin *to* Flutter's built-in Kotlin, so 4.5.0, 4.5.1 and 4.5.2
are precisely the releases that cannot configure under this project's settings, and 4.5.3
restores the legacy application conditionally. 4.4.0 and earlier still declare Dart 3.4 and
were not built here; they are superseded rather than tested. The practical position is that
4.5.3 is both the newest release and the only one in its line that configures, so there is
nothing to move forward to and nothing recent to fall back on if a future release regresses
it. Recorded as follow-up F2. 4.5.0 is also where the package raised its own floor to Flutter 3.41.8 and fixed a
defect this application would have hit — the recent-emoji list changing on an unrelated
parent rebuild — which is moot here only because recents are off (D4).

### D2. It reaches no network and bundles no font

The operating constraint is absolute: this application must work with no route out of the
country, so a CDN, a remote font, a Google or Firebase service, or any other foreign
runtime call disqualifies a dependency outright. This package makes none.

- **It bundles no asset and no font.** Its `pubspec.yaml`'s `flutter:` section declares
  only `plugin:` - no `assets:` and no `fonts:` - so nothing from the package is packaged
  into the application at all. The images in its archive are pub.dev screenshots and its
  own example app's background. Every emoji is a Dart string literal in
  `lib/src/default_emoji_set.dart` and the twelve `lib/locales/emoji_set_*.dart` files,
  compiled into `libapp.so` like any other constant.
- **Glyphs come from the platform emoji font.** The only way to name a face here is
  `Config.emojiTextStyle`, and the wrapper leaves it unset, so the grid is drawn with the
  device's own emoji face — Noto Color Emoji on Android, which is part of the system image.
  Nothing is downloaded and nothing needs bundling.
- **There is no network surface at all.** Grepping the package's whole `lib/` for `http`,
  `HttpClient`, `NetworkImage`, `Uri.parse`, `fetch(`, `dart:io` and `package:web` returns
  comment URLs, one `Platform` shim behind a conditional import, and one `window` read on
  the web branch, which this project does not build.
- **Its one platform call is a font question, not a network one.** The Android plugin is a
  single Kotlin class answering `getSupportedEmojis` with `PaintCompat.hasGlyph`, so the
  grid can drop glyphs this device cannot draw rather than showing tofu. `androidx.core` is
  already adopted at 1.16.0 under ADR-054, so that call costs nothing new.

An emoji picker that carried its own image set — `emoji_mart_flutter`, with its Apple,
Google, Facebook and Twitter presets — would have failed here for exactly this reason, and
that is the main thing separating it from the package chosen.

### D3. What it brings with it, stated in full

This is the part that has to be written down rather than discovered later. **8 Dart
packages** and **46 Android module coordinates** arrive with one line in `pubspec.yaml`.

Dart, from `pubspec.lock`: `emoji_picker_flutter` 4.5.3 itself, then `shared_preferences`
2.5.5 and its six platform implementations — `shared_preferences_android` 2.4.27,
`_foundation` 2.5.6, `_linux` 2.4.1, `_platform_interface` 2.4.2, `_web` 2.4.3, `_windows`
2.4.1. The package's other two dependencies, `plugin_platform_interface` and `web`, were
already in the lock. Nothing is a pre-release and nothing is retracted, which
`dependency_policy_test.dart` asserts.

Android is where the weight is. `betaReleaseRuntimeClasspath` and
`productionReleaseRuntimeClasspath` — identical, as they must be — go from **51 modules to
91**: 46 coordinates added and 6 removed, each of the six being the same artifact at a
lower version. **40 artifacts are genuinely new.** The chain is one link long and then fans
out:

```text
emoji_picker_flutter 4.5.3
  -> shared_preferences ^2.3.3        (recent emoji, remembered skin tone)
     -> shared_preferences_android 2.4.27
        -> androidx.datastore:datastore-preferences 1.1.7   (+ 9 datastore modules, okio, a repackaged protobuf)
        -> androidx.preference:preference 1.2.1
           -> androidx.appcompat:appcompat 1.1.0             (+ recyclerview, transition, the legacy-support tree)
```

Four modules already in the artifact resolve upward as a side effect:
`androidx.customview` 1.0.0 to 1.1.0, `kotlin-stdlib-jdk7` 1.8.20 to 1.9.20, and
`kotlinx-coroutines-*` 1.7.1 to 1.7.3. `kotlin-stdlib-jdk7` moves because
`emoji_picker_flutter`'s own `android/build.gradle` declares it at 1.9.20 on the legacy
Kotlin path this project's `android.builtInKotlin=false` selects.

Two of the arrivals deserve to be named rather than counted.
**`androidx.appcompat:appcompat:1.1.0` is from 2019**, and it is not here because anything
wants AppCompat: `androidx.preference` depends on it, `shared_preferences_android` depends
on `androidx.preference`, and this application never instantiates an AppCompat class. It
brings `recyclerview`, `coordinatorlayout`, `drawerlayout`, `swiperefreshlayout`,
`slidingpanelayout`, `asynclayoutinflater`, `cursoradapter`, `print`,
`localbroadcastmanager`, `documentfile`, `transition`, `vectordrawable` and both
`androidx.legacy:legacy-support-*` artifacts with it — a support-library tree in an
application built entirely on Flutter's own rendering. **`androidx.datastore:
datastore-preferences-external-protobuf` 1.1.7** is protobuf-javalite repackaged under
`androidx.datastore.preferences.protobuf.*`, published by AndroidX under Apache-2.0 while
its contents are Google's BSD 3-Clause protobuf; `docs/third-party-notices.md` now records
both facts, because a recipient of the binary is owed the attribution for what is actually
in it.

This is the largest single expansion of the Android set since ADR-054 locked it, and the
honest summary is that the *picker* is small and its *storage dependency* is not. It is
accepted because the alternative is worse (see the alternatives below), not because it is
cheap. `android/app/gradle.lockfile` records every coordinate,
`dependency_policy_test.dart` pins the resolved release set as a literal, and
`docs/third-party-notices.md` lists it — so the next module to arrive here arrives through
a review conversation rather than a `pub get`.

### D4. The picker writes nothing to disk, and that is configured, not hoped for

`shared_preferences` is in the tree because the package persists two things: the
recently-used emoji list, and the last skin tone the user chose. Both are reachable from
exactly four call sites in `EmojiPickerInternalUtils`, and both are guarded:

- `EmojiPickerState._onEmojiSelected` calls `addEmojiToRecentlyUsed` only under
  `RecentTabBehavior.RECENT` and `addEmojiToPopularUsed` only under `POPULAR`;
  `_updateEmojis` reads `getRecentEmojis` only under those same two;
- `DefaultEmojiPickerView` and `SearchView` read and write the skin tone only when
  `SkinToneConfig.rememberSkinTone` is true, which is the package's own default of `false`.

`AppEmojiPicker` sets `recentTabBehavior: RecentTabBehavior.NONE` and leaves
`rememberSkinTone` alone, so no write is reachable. `LegacySharedPreferencesPlugin`
still calls `getSharedPreferences(..., MODE_PRIVATE)` when the engine attaches, which
returns a handle and creates no file; Android writes `FlutterSharedPreferences.xml` on the
first `commit`, and there is never a first `commit`. The one remaining read is
`SearchView.initState`, which asks for the recent list when the search field opens and gets
an empty answer.

This is a deliberate refusal, not tidiness. Everything else this application knows about a
person lives in the Drift database of ADR-002, which is SQLCipher under a Keystore-wrapped
key. A plaintext
list of the emoji someone most recently used is a durable, readable record of their
behaviour, sitting outside that boundary, in a file any process with the app's UID or a
backup extraction can read — the same category of thing ADR-057 built the diagnostics
export's type system to be incapable of holding. Turning the feature off costs a
convenience nobody has yet; leaving it on would have been a privacy regression introduced
by an emoji keyboard.

Losing recents is a real usability cost and is acknowledged as one. It is answered where it
actually matters — by a fixed set of common reactions one tap away on the message itself,
held as a `const` in presentation code — rather than by writing a file.

### D5. It is wrapped, never imported

`lib/app/design_system/app_emoji_picker.dart` is the only file in this repository that
names `package:emoji_picker_flutter`. Feature screens use `AppEmojiPicker` and
`showAppEmojiPicker`. This is the rule ADR-006 set for Forui and ADR-007 set for the
timeline, applied again: the package supplies primitives, the application owns the
component, and replacing the package is an edit to one file rather than a search across
`lib/features`.

The wrapper also owns three settings that are properties of the application rather than of
any screen — the two in D4, and the deliberate absence of `emojiTextStyle`, which is the
only place a font family could be named and would otherwise put Vazirmatn in front of the
platform emoji face and leave every cell to font fallback.

### D6. It changes the build, once, and that is recorded here rather than left to be rediscovered

`emoji_picker_flutter` and the `shared_preferences_android` behind it are the first plugin
subprojects in this build that compile Kotlin of their own. Every release build after they
arrived failed:

```text
Execution failed for task ':shared_preferences_android:compileReleaseKotlin'.
> java.lang.Exception: Could not close incremental caches in
  <build>/shared_preferences_android/kotlin/compileReleaseKotlin/cacheable/caches-jvm/jvm/kotlin:
  class-fq-name-to-source.tab, source-to-classes.tab, internal-name-to-source.tab
```

Five attempts, five failures. It survived stopping the Gradle daemon and deleting both
plugin build directories, and it is not a race between concurrent builds, because it
reproduced on a single build with nothing else running. The Kotlin Build Tools API cannot
release its memory-mapped incremental-cache files on this workstation. The same build with
`-Pkotlin.incremental=false` succeeded, and `tool/verify_release_apk.sh --production` then
passed all seven checks on its artifact.

`kotlin.incremental=false` is therefore set in `android/gradle.properties`, with the
reasoning beside it. This project owns five Kotlin files and the two plugins own a handful
between them, so the whole of what this disables is a few seconds of compilation; what it
buys is a build that finishes. It is a workstation-visible symptom rather than a
project-wide one, but the property is committed rather than left as a local flag, because a
release build that only works when somebody remembers a command-line argument is a release
process with a hole in it.

### Alternatives

**A. Write the grid in application code.** No dependency, no Android modules, complete
control, and it is the option that best fits this project's instincts. Rejected on scope:
1500+ glyphs across eight categories, per-locale names for search, skin-tone variants and
the platform-support filter are a body of data and behaviour that would have to be sourced
from Unicode CLDR, kept current, and tested — for a control that inserts a character. The
40 new Android modules are the price of not maintaining that, and they are at least
enumerated, pinned and reviewable.

**B. An earlier version of the same package.** Rejected without being measured in detail,
because it cannot buy the thing that matters: `shared_preferences` is declared by 4.5.3 and
by the 4.x releases before it, so the Android weight it drags in is a property of the
package rather than of this version, and 4.5.0-4.5.2 are precisely the releases that cannot
configure under this project's AGP 9 settings. Going back further than 4.5.0 means taking a
release from nine months or more ago to avoid a dependency it also has.

**C. A different package.** Surveyed on 2026-08-25 from pub.dev: `awesome_emoji_picker`
states that it persists recently used emoji with `SharedPreferences`, so it carries the same
tree for the same reason; `emoji_mart_flutter` offers native, Facebook, Apple, Google and
Twitter presets, which means an image set rather than the platform font and fails D2;
`emoji_text_field`, `flutter_emoji_picker`, `flutter_emoji_selector_plus` and `gugor_emoji`
remain, and the last two describe themselves as modifications of `emoji_selector` and of the
deprecated `emoji_picker`. None was read line by line, because none of them removes the
storage dependency that is the actual cost here, and `emoji_picker_flutter` is the one
carrying a verified publisher and a maintained release line.

**D. Keep the fixed `👍` and the fixed `🙂`.** Rejected: the protocol has carried an
arbitrary reaction grapheme since it was written (`message-protocol.md`, "one normalized
emoji grapheme or null"), every layer below presentation already supports it, and the UI
specification §8 and §17 both name an emoji reactor as a required surface. A React button
that can only ever send one emoji is the shape the specification's own core rules call a
defect — a control that presents itself as more than it is.

### What this does not decide

No cryptographic construction, ciphersuite, protocol version, wire format or state format
changes. No permission and no manifest component is added — both new plugin manifests are
empty, and `tool/verify_release_apk.sh --production`, which reads the merged result out of
the packaged artifact rather than out of source, passes all seven checks on a build carrying
this change: the same permission set and the same five components ADR-054 recorded, one
exported component, and a native core that still does not export
`cp_crypto_v1_beta_mls_operation`. The Beta/Production separation, the per-ABI group gate
(ADR-056) and the delivery behaviour are untouched, and Production still packages unsigned.
The measured cost in the artifact is **+1.57 MiB**: an unsigned production release APK goes
from 86,760,406 to 88,410,103 bytes. It divides in two, and both halves were measured
rather than estimated. The Android module tree costs **+426 KiB** (86,760,406 to
87,196,563, taken with the dependency declared and the picker not yet reachable) - far less
than those modules' own footprint, because almost nothing in that support-library tree is
reachable from this application. The picker itself costs the remaining **+1.16 MiB**, which
is the emoji data: 1500 glyphs with their names and search keywords, as Dart constants in
`libapp.so`.

It would have been **+5.48 MiB**. The package ships twelve locale sets and selects between
them in a `switch`, so all twelve are reachable and all twelve compile in; the artifact
measured 92,506,103 bytes before the wrapper named one. `AppEmojiPicker` passes
`emojiSet: (_) => emojiSetEnglish`, which changes nothing anybody sees - the package's own
`getDefaultEmojiLocale` already returns that set for `en` directly and for `fa` through its
default branch - and returns **4,096,000 bytes** exactly to an artifact that is handed to
people over a slow link. That line has to move together with follow-up F1.

### Sources, read on 2026-08-25

| Claim | Source | State on 2026-08-25 |
|---|---|---|
| 4.5.3 is the newest published version, and what its releases changed | [pub.dev](https://pub.dev/packages/emoji_picker_flutter), [versions](https://pub.dev/packages/emoji_picker_flutter/versions), [CHANGELOG](https://github.com/Fintasys/emoji_picker_flutter/blob/master/CHANGELOG.md) | 4.5.3 published 2026-07-24; 4.5.0-4.5.3 are the only releases requiring Dart 3.11; 4.4.0 and earlier require Dart 3.4. 4.5.3 is the AGP 9 / `builtInKotlin=false` fix |
| Its SDK constraints and its complete dependency list | [`pubspec.yaml`](https://github.com/Fintasys/emoji_picker_flutter/blob/master/pubspec.yaml) | `sdk: ">=3.11.5 <4.0.0"`, `flutter: ">=3.41.8"`; `flutter`, `flutter_web_plugins`, `plugin_platform_interface ^2.1.8`, `shared_preferences ^2.3.3`, `web ^1.1.0`. Declares plugin classes for six platforms |
| Its Android code, and that it is a font query rather than a network one | [`EmojiPickerFlutterPlugin.kt`](https://github.com/Fintasys/emoji_picker_flutter/blob/master/android/src/main/kotlin/com/fintasys/emoji_picker_flutter/EmojiPickerFlutterPlugin.kt) | One `MethodChannel`, one method `getSupportedEmojis`, answered by `androidx.core.graphics.PaintCompat.hasGlyph` |
| Its Android build applies the Kotlin Gradle Plugin on the legacy path | [`android/build.gradle`](https://github.com/Fintasys/emoji_picker_flutter/blob/master/android/build.gradle) | `compileSdk` 35, `minSdk` 21, JVM 17; applies `kotlin-android` 1.9.20 and adds `kotlin-stdlib-jdk7:1.9.20` when AGP < 9 **or** `android.builtInKotlin=false` |
| What actually reaches storage, and what guards it | Package sources at 4.5.3 in the pub cache: `src/emoji_picker_internal_utils.dart`, `src/emoji_picker.dart`, `src/skin_tones/skin_tone_config.dart`, `src/search_view/search_view.dart` | Four `SharedPreferences` call sites; writes reachable only under `RecentTabBehavior.RECENT`/`POPULAR` or `rememberSkinTone: true`, whose default is `false` |
| The Android side creates no file until something is written | [`LegacySharedPreferencesPlugin.kt`](https://github.com/flutter/packages/blob/main/packages/shared_preferences/shared_preferences_android/android/src/main/kotlin/io/flutter/plugins/sharedpreferences/LegacySharedPreferencesPlugin.kt) at 2.4.27 | `onAttachedToEngine` calls `getSharedPreferences(name, MODE_PRIVATE)`, which returns a handle; the XML file is written on the first `commit` |
| What `shared_preferences_android` links on Android | `android/build.gradle.kts` at 2.4.27, in the pub cache | `androidx.datastore:datastore:1.1.7`, `androidx.datastore:datastore-preferences:1.1.7`, `androidx.preference:preference:1.2.1` |
| The alternatives, and why each was rejected | [pub.dev](https://pub.dev/packages/awesome_emoji_picker), [pub.dev](https://pub.dev/packages/emoji_mart_flutter) and the surrounding search results | `awesome_emoji_picker` persists recents to `SharedPreferences`; `emoji_mart_flutter` offers native/Facebook/Apple/Google/Twitter presets |

### Follow-ups

- **F1.** The package carries no Persian emoji set, so under `fa` its own
  `getDefaultEmojiLocale` falls back to the English names and search matches English
  keywords in both locales. The glyphs, the categories and the layout are unaffected.
  Supplying a Persian set through `Config.emojiSet` is a self-contained piece of work.
- **F2.** 4.5.3 is the only release in its line that builds here. Watch the package for one that adopts
  Flutter's built-in Kotlin — the build already warns that a future Flutter will fail on a
  plugin applying the Kotlin Gradle Plugin, and this is now the only such plugin in the
  artifact.
- **F3.** `androidx.appcompat` 1.1.0 is six years old and arrives two levels below anything
  this project chose. If `shared_preferences_android` ever drops `androidx.preference`, or
  if the picker ever stops needing `shared_preferences`, roughly twenty modules leave with
  it. Re-check on every `shared_preferences` bump.
- **F4.** Regenerating the Gradle lock is not the fixed-point operation it looks like, and
  this change is where that showed. `./gradlew :app:writeDependencyLocks --write-locks`
  produced a lock in which `kotlin-stdlib-common:2.3.20` was absent from all three runtime
  classpaths; the next ordinary release build then failed with *"Resolved
  'org.jetbrains.kotlin:kotlin-stdlib-common:2.3.20' which is not part of the dependency
  lock state"*. Running the real `assemble`/`merge` tasks under `--write-locks` reproduced
  the same omission, because `--write-locks` resolves **without** the lock, while an
  ordinary build resolves **with** it — dependency locking applies the recorded versions as
  strict constraints, and those constraints changed conflict resolution enough to keep a
  module the unconstrained graph evicts. The entry was therefore recorded from what a
  constrained build actually resolves, and a plain `flutter build apk --release --flavor
  production` then passed against it, which is the fixed point. Anyone regenerating this
  lock must build afterwards and expect to reconcile, not assume the regenerated file is
  correct because the command succeeded.

## ADR-058 in full — what piece 20 is actually waiting for (2026-08-25)

**Status:** Accepted. Scoping decision. **Opens no production gate.** Amends ADR-044's
*Piece 20* section, which re-scoped the prerequisite correctly and left it unfinished.
Grants no exporter, adds no dependency, changes no cryptographic construction,
ciphersuite identifier, dependency version, state format, or shipped runtime behaviour.

### The question

Piece 20 — voice rooms, realtime encrypted media, ephemeral room text — carries a
prerequisite. The question is whether that prerequisite still expresses the condition
this project actually needs, under the deployment model actually in force, and if not,
what condition should replace it.

The answer had to be established from the code and the tracked register rather than from
the prompt, because the prompt is not tracked and because ADR-052 established by doing
exactly this kind of audit that documents in this repository do drift from the artifact.

### Which prerequisite is the recorded one

Two texts claim to state it, and they say different things.

`docs/implementation-prompts.md` prompt 20 says:

> Start only after piece 19 has passed every production gate, the independent review has
> closed all blocking findings, and the reviewed PQ MLS provider is enabled in the
> production composition root. A docs-only or blocked piece-19 outcome does not satisfy
> this prerequisite.

That file is **untracked**. `git ls-files --error-unmatch docs/implementation-prompts.md`
fails and `git check-ignore -v` reports `frontend/.gitignore:57`. Editing prompt 20 there
ships nothing, which is why ADR-044 already said the same thing and put the re-scope here.

ADR-044 (2026-08-20) is therefore the recorded prerequisite. It found the prompt text
unreachable — "gates 1–3 cannot be reached from inside this project, so as written piece
20 is permanently dead rather than merely blocked" — and replaced it with:

> piece 20's real prerequisite is a decision about which MLS exporter it may derive media
> keys from

naming two paths and granting neither.

**That re-scope was right about the direction and is not reopened.** What it did not do
is say what the granting decision must establish. This ADR does that, and nothing else.

### Why the re-scope is no longer sufficient

Four findings, each traced rather than assumed.

| # | Finding | Evidence |
|---|---|---|
| 1 | It states a requirement to *decide*, not a condition to *check* | ADR-044 names the two paths and three considerations in prose — a self-hosted LiveKit/TURN deployment, an Android SFrame wire spike, a truthful foreground-service integration — as things "that decision" needs. It fixes no bar, so whoever writes the granting ADR sets their own. A prerequisite whose standard is set by the person clearing it is not a prerequisite |
| 2 | It predates the gate that now governs the exporter it points at | ADR-055 and ADR-056 landed four days later. `GroupProductionGate.privateExperimentalPermit` now returns null unless `GroupExperimentalGate.ledger.hasEvidenceFor(abi)` holds. `arm64-v8a` carries an admissible record; `armeabi-v7a` and `x86_64` carry none. On two of the three ABIs this artifact packages, the beta MLS stack — and therefore any exporter — is not available at all. ADR-044 could not have said this and does not |
| 3 | The exporter it names is not reachable as key material | `native/crypto_core/src/mls_beta.rs:2108` computes `exporter_confirmation` as SHA-256 over `export_secret(b"chat:v1:beta-group-export", group_id, 32)` and returns **only the digest**. Dart receives `exporterConfirmation` (`lib/core/protocol/beta_mls_model.dart`) and uses it for one purpose: comparing epoch agreement (`native_beta_group_mls.dart:167`, `:552`). No exporter secret crosses the FFI boundary today, on any path. Keying media requires a new reviewed native operation, which neither the prompt nor ADR-044 names |
| 4 | It leaves the media-framing question unowned while three statements disagree | See *The framing tension* below |

### The framing tension, reported and not resolved

`frontend/AGENTS.md` requires that an official source conflicting with the backend
contract or an accepted decision be reported exactly rather than reconciled in passing.
This one is reported and left open, because settling it is the granting ADR's job and it
needs evidence nobody has produced.

| Source | What it says |
|---|---|
| `docs/voice-and-realtime.md` § *Media encryption gate* | "RFC 9605 SFrame is the target framing contract" |
| `docs/cryptographic-protocol.md` media-framing row | "RFC 9605 SFrame **or** the LiveKit E2EE implementation after wire-level validation" |
| `backend/SECURITY.md` (read-only) | "audio itself is SFrame-encrypted end-to-end", and classifies the key as "Voice SFrame / per-sender media keys ... derived from live MLS subgroup" |
| LiveKit's official documentation, read 2026-08-25 | The encryption pages never mention SFrame or RFC 9605. `EncryptionType` is `kNone`, `kGcm`, `kCustom` — the built-in frame cipher is AES-GCM |

The two frontend documents already disagree with each other: one states SFrame as *the*
contract, the other permits LiveKit's own implementation subject to validation. The
backend document, which this project may not edit, makes the stronger claim. LiveKit's
own documentation supports neither reading unambiguously — it does not claim RFC 9605
conformance, and it also does not disclaim it.

Nothing here is decided. What changes is that the question can no longer be answered by
whoever starts the work: P4 and P5 below require it be answered by a recorded decision
standing on a measurement.

### What piece 20 genuinely depends on

Separating the dependencies that bear on safety from those inherited from an assumption
about a public release is the whole substance of this decision.

**Safety-bearing, and kept:** a named source for media keys; that source being reachable
as key material under its own domain separation; the stack that produces it actually
existing on the device in hand; a settled frame-encryption contract proven on the wire;
every runtime dependency self-hosted; and a user-facing claim no stronger than the
weakest layer underneath it.

**Inherited from a public-release assumption, and not safety-bearing for a private
experimental artifact:** an IANA-assigned MLS ciphersuite value, a non-expiring
specification for every primitive, a maintained provider implementing `TBD2`'s KEM, and
upstream interoperability vectors. `docs/mls-profile.md` records that gate 2 "cannot be
reached by any work inside this project", and ADR-044 already deferred all four for this
deployment with the residual risk written down and disclosed. Requiring them before
*experimental* voice may exist would not make anyone safer. It would only guarantee that
the question is never asked.

Independent cryptographic review (gate 7) sits deliberately in the second list and stays
there. ADR-044 deferred it deployment-wide, for every layer including pairwise, and
recorded it as "the largest one" of the deferred risks. Re-imposing it on voice alone
would re-litigate an accepted decision rather than implement one. What replaces it is P7:
voice may not be presented as more mature than the layer it rests on.

### The prerequisite

**Piece 20 does not begin until every condition below is true.** Each is answered by
inspecting the artifact it names. None is answered by judgement about whether it matters,
and none may be argued away for being difficult or unobtainable — ADR-053 exists because
that argument was made once and was wrong.

**P1 — A granted media-key source.** This register contains an accepted, dated ADR that
names exactly one MLS exporter as the source of room media keys and states the terms of
the grant. Two admissible forms and no third:

- **(a) Production.** `GroupProductionGate.releaseAssertion.productionTransportEnabled`
  is `true`, which cannot occur before all seven `mls-profile.md` production gates are
  evidenced. This is the prompt's original condition, unchanged and unweakened.
- **(b) Closed-beta experimental.** The experimental exporter, granted for experimental
  voice only, under ADR-036's disposable-state rule and ADR-044's disclosure rules.
  Path (b) opens no production gate and does not make production voice permissible.

**This ADR grants neither.** ADR-044 declined the grant and gave three reasons; all three
still hold, and findings 2 and 3 above add two more.

**P2 — The exporter is reachable, and is not the group's.** The shared Rust core exports
an operation returning room media key material derived through `export_secret` under a
label domain-separated from `chat:v1:beta-group-export`, and that symbol is present in
the export allowlist `tool/build_rust_android.sh` enforces. Today no such operation
exists, so this condition is currently false on both paths.

**P3 — The device has the stack the key comes from.** Under path (b), voice resolves
through the *same* permit as groups — `GroupProductionGate.privateExperimentalPermit`,
which since ADR-056 requires an admissible `GroupMlsFieldEvidence` record for the ABI the
running process loaded. Voice is never offered on an ABI whose packaged core has never
been observed executing. **Voice may not introduce a second availability rule**, and it
may not be available anywhere groups are withheld.

**P4 — The framing contract is settled by a decision, not by an implementer.** The
granting ADR names the frame encryption actually used, the exact SDK version it was
established against, and whether RFC 9605 conformance is claimed — and reconciles the
three statements in *The framing tension*. If it cannot claim conformance, it says so in
the documents that currently do.

**P5 — An Android wire-level observation that the SFU cannot decrypt.** A run record
under `docs/validation/voice-media/`, on the admissibility idiom ADR-053, ADR-055 and
ADR-056 established: real hardware and never an emulator, the whole publish → SFU →
subscribe path exercised, SFU-side frames shown undecryptable with the media key
withheld, a strict `YYYY-MM-DD` date, and the device and platform version as the device
reports them. A reasoned argument that it must be encrypted is not a record.

**P6 — Every runtime dependency is self-hosted and reviewed in.** A self-hosted LiveKit
and TURN deployment is reachable from the provisioned origin, and the client package is
added at one exact version to the literal dependency map
`test/architecture/dependency_policy_test.dart` pins, under ADR-054's rules. ADR-013's
prohibition on foreign push, telemetry, STUN/TURN, or media services is unchanged.

**P7 — The surface tells the truth.** Voice is placed in the tier of the weakest layer it
rests on and never above it — under path (b), Experimental. The written handover in
`docs/deployment-and-release.md` and `DeploymentDisclosure` move accordingly, which
ADR-052's mechanism forces rather than asks for: an edited point forces its `since:`, and
`since:` forces the revision. The interaction between an active-call foreground service
and ADR-051's opt-in `specialUse` service is decided in advance rather than discovered —
ADR-051 already records that two services can be armed at once if voice ships.

**Resolution rule.** Absence of evidence is refusal, never permission. Any condition not
evidenced is not met; a partially satisfied list authorizes nothing; and while the list is
unsatisfied every voice surface stays exactly as it is today — `StructuralPlaceholderPage`,
no dependency, no native symbol, no key.

### Why this is stricter than what it replaces

Worth stating plainly, because a re-scope that starts a blocked piece is the failure mode
to watch for.

| Axis | Prompt text | ADR-044 | This ADR |
|---|---|---|---|
| Production voice | All seven gates + review + production provider | Unstated | **Unchanged** — P1(a) is the same condition |
| Experimental voice | Impossible | Available, on an unspecified bar | Available, on seven named conditions |
| Per-ABI evidence | Not mentioned | Not mentioned | **Required** (P3) |
| Exporter reachability | Not mentioned | Not mentioned | **Required** (P2) |
| Wire-level proof | Prose instruction inside the prompt | Prose consideration | **Required as an admissible record** (P5) |
| Framing contract | Assumed settled | Unowned | **Must be decided and reconciled** (P4) |

Every safety-bearing condition is preserved or added. The only thing removed is the
requirement that four externally blocked registry and ecosystem facts be true before a
*private experimental* capability may be considered — and P1(a) keeps every one of them
in force for the production path.

### Why no new gate object

`GroupExperimentalGate` and `SustainedDeliveryGate` are the right pattern for a
capability that **exists and is being withheld**. Voice is neither built nor half-built:
`/voice-rooms` renders `StructuralPlaceholderPage`, `pubspec.yaml` declares no media
dependency, and the native core exports no media-key operation. A gate object with no
consumer would be decoration — an object asserting a fact about nothing — and
`frontend/AGENTS.md` forbids exactly that ("avoid speculative abstractions"). It would
also require inventing admissibility rules for a measurement nobody has yet designed,
which is how a ledger becomes a formality.

The conditions instead resolve against four mechanisms that already exist and already
fail closed, which is why this decision needs no new code to be enforceable:

| Condition | Mechanism that already refuses it | Enforced by |
|---|---|---|
| P1(a) production exporter | `GroupProductionGate.releaseAssertion` — private constructor with an `assert` forbidding a true value, referenced by `main_production.dart` | `test/architecture/group_production_gate_test.dart` |
| P3 per-ABI availability | `GroupExperimentalGate.ledger.hasEvidenceFor(abi)` — null ABI and inadmissible record both resolve to withheld | `test/architecture/group_experimental_gate_test.dart` |
| P2 native operation | The exported-symbol allowlist in `tool/build_rust_android.sh`, which exits 5 on any mismatch and is re-checked against the packaged library by `tool/verify_release_apk.sh` | `tool/ci.sh` |
| P6 dependency | The literal declared-dependency map in `dependency_policy_test.dart`; adding `livekit_client` fails the suite until it is reviewed in | `flutter test` |

A voice gate object becomes the right answer when there is a voice implementation to
withhold. It is written by the piece that builds one, against a measurement that has been
designed, not by this one.

### Alternatives evaluated

**A. Leave ADR-044's re-scope exactly as written.** Rejected, and it was the serious
alternative — it is already tracked, already authoritative, and already correct in
direction. It fails on findings 2 and 3: it points at an exporter that two of three ABIs
cannot reach and that no ABI can currently obtain as key material. A prerequisite that
names an unreachable dependency reproduces the defect it was written to fix, one level
down.

**B. Restore the prompt's original prerequisite.** Rejected. It is unreachable by this
project's own record — `mls-profile.md` states gate 2 "cannot be reached by any work
inside this project" — so it makes piece 20 permanently dead rather than blocked, which
is precisely what ADR-044 diagnosed. Preserved intact as P1(a) for the production path,
where it is the correct condition.

**C. Grant the experimental exporter here, so piece 20 can start.** Rejected. The
evidence ADR-044 required for that grant has not been produced: no self-hosted LiveKit or
TURN deployment is recorded, no Android wire observation exists, and the framing contract
is not settled. Granting it now would be relaxing a safety-bearing condition to make a
future piece easier to begin, which this decision is explicitly not for.

**D. Add a `VoiceMediaGate` evidence ledger now.** Rejected for the reasons in *Why no
new gate object*. Reconsider when there is an implementation to gate.

**E. Correct the prompt file and stop.** Rejected. It is gitignored, so the correction
would reach nobody and the register would still carry an unfinished prerequisite. The
prompt is corrected as well, for local coherence, but it is not where this lives.

### Research

Verified 2026-08-25 against primary sources. Search summaries were used for discovery
only and are not cited as evidence.

| Claim | Source | State on 2026-08-25 |
|---|---|---|
| SFrame is a published standard, so "RFC 9605" names a fixed contract | [RFC 9605](https://www.rfc-editor.org/info/rfc9605), [datatracker](https://datatracker.ietf.org/doc/rfc9605/) | "Secure Frame (SFrame): Lightweight Authenticated Encryption for Real-Time Media", IETF stream, Proposed Standard, published August 2024, not obsoleted |
| MLS is specified as a source of keys for other protocols | [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html) §8.5, and §3.1's statement that the exporter secret "allows other protocols to leverage MLS as a generic authenticated group key exchange" | Unchanged |
| LiveKit cannot be trusted with media keys, and does not ask to be | [LiveKit encryption overview](https://docs.livekit.io/transport/encryption/) | "It is your responsibility to securely generate, store, and distribute encryption keys to your application at runtime. LiveKit does not (and cannot) store or transport encryption keys for you." Signalling is explicitly **not** end-to-end encrypted |
| An MLS-keyed custom key provider is the documented route, not a workaround | [LiveKit E2EE guide](https://docs.livekit.io/transport/encryption/start/) | A custom key provider is required for per-participant keys or in-room rotation, "such as when implementing the MEGOLM or MLS protocol". The built-in shared-key provider is insufficient for removed-member exclusion |
| The Flutter SDK can accept raw exporter bytes per participant | [`livekit_client` API docs](https://pub.dev/documentation/livekit_client/latest/livekit_client/BaseKeyProvider-class.html) | `setRawKey(Uint8List key, {String? participantId, int? keyIndex})`, plus `ratchetKey`, `keyRingSize`, `failureTolerance` |
| LiveKit's frame cipher, and the absence of an RFC 9605 claim | [`EncryptionType`](https://pub.dev/documentation/livekit_client/latest/livekit_client/EncryptionType.html), [E2EE guide](https://docs.livekit.io/transport/encryption/start/) | `kNone`, `kGcm`, `kCustom`. The Rust example sets `EncryptionType::Gcm`. No LiveKit encryption page names SFrame or RFC 9605 |
| The package version any future spike would pin | [pub.dev](https://pub.dev/packages/livekit_client) | `livekit_client` 2.11.0, published approximately 2026-08-11 |

**Where the research and the repository disagree**, the repository was not overruled. The
LiveKit documentation's silence on RFC 9605 does not by itself disprove
`backend/SECURITY.md`'s SFrame statement — LiveKit's frame format is not documented in
enough detail on those pages to conclude either way, and `kCustom` leaves room for a
conformant implementation. The honest position is that this is unresolved, so it is
recorded as unresolved and made a precondition (P4, P5) rather than settled here in
either direction. No backend file is edited, and no cipher is chosen.

### What this amends

ADR-044's *Piece 20* section. Its finding stands, its two paths stand, and its refusal to
grant either stands. What is added is the bar the granting decision must clear. ADR-044's
dated ledgers are left as written; this register does not edit history out of itself.

### What this does not do

- It opens no production gate and leaves ADR-017, ADR-026, the seven gates in
  `mls-profile.md`, `GroupExperimentalGate`, and ADR-053's `SustainedDeliveryGate`
  exactly as they were.
- It does not touch the Beta/Production boundary, the frozen application identity or
  signing certificate digest, any cryptographic construction, any ciphersuite identifier,
  any dependency version, or any state format.
- It changes no shipped runtime behaviour. No Dart, Rust, Gradle, manifest or asset file
  is edited by it, and every gate in `docs/testing-strategy.md` produces the same result
  after it as before.
- It does not move the deployment disclosure. `DeploymentDisclosure.revision` stays at 7:
  voice rooms were already named as unbuilt and remain unbuilt, so no point becomes
  false. The release-blocking written re-delivery obligation is unchanged.
- It grants no exporter, adds no dependency, and starts no part of piece 20.

### Not verified here

- Whether LiveKit's AES-GCM frame format is or is not RFC 9605 conformant. Unresolved by
  design; P4 and P5 require it be answered on evidence before piece 20 begins.
- Whether the closed-beta exporter is sound as a media-key source. The construction is
  RFC 9420 §8.5 and the beta engine exercises it, but no independent review of any layer
  exists (ADR-017, ADR-044).
- Anything about LiveKit on a device. Nothing in this repository has ever run it.

### Review and revisit conditions

1. **Any of P1–P7 becomes satisfiable** — in particular a self-hosted LiveKit and TURN
   deployment existing, or a first admissible record appearing under
   `docs/validation/voice-media/`.
2. **A production gate closes**, particularly gates 1 or 2, which makes P1(a) reachable
   and begins the group layer's replacement.
3. **An independent cryptographic review is retained** (ADR-017), which changes what may
   be claimed about every layer including this one.
4. **A further ABI gains or loses an admissible record** in `GroupExperimentalGate`,
   which changes where path (b) could ever be offered.
5. **LiveKit's documented encryption contract changes** — a stated RFC 9605 conformance,
   a new `EncryptionType`, or a change to the custom key provider API.
6. **The audience or the threat model changes** under ADR-044's conditions 1, 2 or 7. A
   deployment carrying live audio is a materially different exposure from one carrying
   text.
## ADR-057 in full — the remainder of piece 21, as measured (2026-08-25)

**Status:** Accepted. Implementation decision. **Opens no production gate.** Changes no
cryptographic construction, ciphersuite identifier or state format.

### The question

Piece 21 names four remainders: local search, the settings surface set, the diagnostics
export, and notifications with background polling. The last of those was delivered under
ADR-048, ADR-049, ADR-050, ADR-051 and ADR-053 and is not reopened here. The question is
what the other three actually still need — established from the composed artifact, not
from the checklist, the prompt or this register, because ADR-052 found by doing exactly
that audit that four user-facing claims in this application were false.

### What the audit found

| Claim | Verdict | Evidence |
|---|---|---|
| `Local search \| Pending Android encrypted index` (checklist) | **Wrong in both halves** | ADR-052 already recorded search as built and pinned it with a test. The chat-list filter is `chat_pages.dart` (`item.title`/`item.preview`); the in-conversation filter read `widget.model.messages`, which `watchMessages` loads with no `LIMIT`. |
| "Android maintains a local index inside the encrypted database" (`local-data-model.md`) | **True already, and read as a promise of something else** | `messages.projection_ciphertext` holds the decrypted body — the column name is historical — inside SQLCipher under a Keystore-wrapped key. That *is* an index inside the encrypted database. |
| "Implement local-only conversation/message/contact search with Android encrypted indexes" (prompt 21) | **Not a recorded decision** | The only accepted decision about search is ADR-012: "the server never receives content or search terms." No ADR, no checklist row and no owning document records a decision to build a separate index structure. The phrase appears in `local-data-model.md` and in the prompt that repeated it. |
| Group conversations can be searched | **False** | `GroupChatView`'s app bar had one action, Group Info. `_GroupInfoSummary` rendered a "Search this chat" button with `onPressed: null` — permanently. |
| "Clear history" in the direct-conversation overflow | **False** | `onTap: () => Navigator.pop(context)`. It closed the menu and did nothing. |
| Linked Devices is a reviewed, localized surface | **False** | Every string was a hard-coded English literal; `error` printed the raw failure object to the user; "Add device" routed to `/devices/enroll`, which the router does not declare; and `Last active` rendered a day-level UTC value through `toLocal()`. |
| Appearance is routed | **True, and unbuilt** | `/settings/appearance` resolved to `StructuralPlaceholderPage`. The deployment disclosure lists the unbuilt surfaces and does not name it. |
| Settings offers Saved Messages, Security & recovery, About and Log out | **False** | None of the four existed. §15 lists all four. |
| A user-initiated diagnostics export exists | **False** | `NetworkDiagnostics` was a port with one implementation, `NoopNetworkDiagnostics`, composed everywhere. Nothing collected and nothing exported. |

### The decisions

**1. No search index is built, and the sentence that asked for one is corrected.**

A second index would hold a second copy of every message body. That is a larger wipe
surface, a second thing a migration can corrupt, and a second place a future defect can
leak from — against a benefit that does not exist at this scale, because the timeline
already materialises the whole conversation and the filter runs over what is already in
memory. `local-data-model.md` now describes the index that exists rather than one that
does not, and the checklist row is corrected. This is recorded rather than done silently
because the phrasing had already been copied forward twice.

**2. One shared in-conversation search surface, and the group entry point it was
missing.**

`showConversationSearch` is opened by direct, saved and group conversations over the same
`ChatMessageViewModel` list, so the scope notice, the empty states, the result cap and
the jump behaviour cannot drift between two surfaces that promise the same thing. The
filter itself is a pure function, which is what lets a test assert the scope claim — the
whole of this conversation's local history and nothing else — without a widget, and what
makes it obvious that nothing here touches storage, the network or the crypto core.

The result cap was already 30 and was silent. It now says so on screen when it bites, for
the reason ADR-052 gave when it corrected `chatsSearchHint`: a surface that shows fewer
results than it found, without saying so, is misdescribing its own scope.

Group Info's disabled button now opens the conversation, where the messages are. A
control that can never succeed is what the UI specification's core rules forbid, and it
had been sitting in a shipped screen.

**3. The settings set, as §15 lists it.**

Settings home gains the profile header, Saved Messages, Security & recovery, Appearance,
About and Log out. Appearance owns exactly two client-only choices — theme and language —
and says so; high contrast deliberately has no control, because Android owns that switch,
`MaterialApp` follows it, and a second control could only disagree with the system one.
Both values live in the encrypted preference table, so the logout wipe that destroys the
database key destroys them too and a second account on the same phone does not inherit
the first one's screen. A write that fails is reported on the screen as a preference that
will not survive a restart, rather than silently accepted.

Log out states what it costs before it happens, and states it in the vocabulary the
security notice uses: everything on the phone is erased, the server keeps no copy of the
history, and the recovery secret restores the identity and never the messages.

**4. Recovery-secret replacement, and the one native operation it needed.**

§15.2 requires replacement, and replacement requires re-wrapping the *same* identity. The
crypto core could generate a new identity or restore one from a backup; it could not
re-wrap. `cp_crypto_v1_rotate_recovery_secret` parses the existing package, draws fresh
entropy, and calls the same `encode_recovery_secret` and `encrypt_backup` that the first
upload used. No construction changes, no format changes, and the encoded package is
byte-identical to the original apart from the recovery and backup fields — the master
signature included, because Ed25519 signing is deterministic over the same key and
message.

The alternative — reaching for `prepare_first_identity` — was rejected outright. It would
have produced a new master key, invalidating every device cross-signature and every peer
attestation, and it would have done so silently, presented to the user as "make a new
recovery secret".

The ordering is the security property, and it is asserted rather than described:

* The new secret is produced locally and shown **only** after the server accepted the new
  backup at a strictly higher version.
* Every refusal — offline, stale after a retry, a crypto core that will not compose —
  reports that the *current* secret still works, because the server still holds the blob
  it opens. A user can never be left having written down a secret that recovers nothing.
* Nothing local is rewritten. The private material on the device is unchanged by
  construction, so there is no window in which a crash leaves a device holding keys that
  do not match a backup; the only durable local effect is the recorded backup version,
  and a stale one costs one extra round trip rather than an identity.

The screen blocks screen capture for as long as the route is mounted and releases it when
it is not, and copies through the clipboard path that expires — both required controls in
the threat model, and both now asserted by a test rather than assumed. A build without
that path says copying is unavailable rather than falling back to an ordinary clipboard
that never clears.

**5. The diagnostics export is safe by its type, not by review.**

A `DiagnosticsReport` is a list of `DiagnosticEntry`. An entry's key is a
`DiagnosticField` — an enumeration — and its value is a `DiagnosticValue`, whose every
subclass is constructible only from a boolean, an enumeration, a bounded integer, or a
compile-time constant this repository declares. There is no constructor that takes
runtime text. That is the whole redaction mechanism: a plaintext, a credential, a stable
identifier, a key, a recovery secret, a ciphertext, a capability or a decoded token
cannot reach the export because the type will not hold one.

Three consequences were chosen deliberately:

* **Counts leave as orders of magnitude.** An exact count is not a prohibited value, but
  it is a needlessly precise description of one person's usage to put in a document they
  may hand to somebody else. `0`, `1-9`, `10-99`, `100-999`, `1000+` answers every
  question a reader of this report actually has.
* **The timestamp is an hour.** Enough to find the right window in an operator's log,
  which is the only reason a timestamp is there.
* **What is shown is what is copied, byte for byte, in locale-independent ASCII.** A
  screen that rendered a friendly localized summary and copied something larger would be
  asking a person to share a document they have not read. The chrome is translated; the
  report is not, because its recipient may not read the sender's language.

The application sends it nowhere, and the screen says so: the clipboard is the entire
export path, and where the text goes next is the user's decision. A file written through
`FileProvider` and handed to an arbitrary application through `ACTION_SEND` was considered
and rejected — it would add a platform channel, a new intent and a third-party recipient
chosen at the moment of use, for no gain over a paste.

The one string-taking constructor cannot be closed by the type system, so its call sites
are enumerated in `test/architecture/settings_and_diagnostics_policy_test.dart`. A fourth
one has to be added there, deliberately, where the decision to put something new into an
exportable document is visible to a reviewer — the same mechanism this repository already
uses for dependencies and for manifest permissions.

The counters come from `NetworkDiagnostics`, which piece 06 built payload-free and which
nothing had ever collected. `RecordingNetworkDiagnostics` is one integer per enumeration
cell, so it is O(1) whatever the application does, owned by `ApplicationRuntime` so the
activity and the headless catch-up count into the same one, and **never persisted**: a
diagnostics buffer that survived a restart would be a durable record of when its owner
used the application, kept for a screen almost nobody opens.

**6. Four corrections in the settings surface set, found by the same audit.**

`Clear history` now dispatches a typed intent that the layer owning the repository
handles, behind a confirmation that states the consequence: this phone's copy is removed,
the peer keeps theirs, this account's other devices keep theirs, and nothing asks anybody
to forget anything.

Linked Devices is localized in both languages; its failure state is reviewed copy rather
than a raw failure object; `Last active` renders the calendar day the backend reported
rather than that day shifted into local time, which had been showing the previous day to
every reader west of UTC and was finer-grained than the value the server holds; and the
"Add device" button is replaced by the explanation §16.1 actually describes, because the
flow starts on the *other* device and there was nothing here to start — the route it
pointed at does not exist.

### What this amends

ADR-044's **Absent** tier listed "voice rooms, local search, notifications, background
delivery, appearance settings". Three of those five have since left it: notifications at
ADR-048, background delivery at ADR-049, and now appearance settings. **Local search was
never in it correctly** — ADR-052 established that the artifact already searched when
ADR-044 was written, and corrected the user-facing disclosure accordingly without editing
the tier table. The tier now reads: **voice rooms, file attachments, profile publishing,
shared media**. The dated ledgers inside ADR-042 and ADR-044 are left as written; they
record what was observed on the day they were made, and this register does not edit
history out of itself.

### What this does not do

* It opens no production gate, and leaves ADR-017, the PQ MLS gates in `mls-profile.md`
  and ADR-053's sustained-delivery gate exactly as they were.
* It does not touch the Beta/Production boundary, the frozen application identity, or the
  group experimental gate.
* It adds no Dart dependency, no Android library, no permission and no manifest
  component. It adds one native symbol, which is recorded in the export allowlist
  `tool/build_rust_android.sh` checks.
* It does not move the deployment disclosure. No disclosure point becomes false: the
  unbuilt-surfaces point names voice rooms, file attachments and profile publishing, and
  all three remain unbuilt. `DeploymentDisclosure.revision` stays at 7, so the
  release-blocking written re-delivery obligation is unchanged.

### Not verified by any test here

* What the recovery rotation does against a live backend. The use case is covered against
  faked ports, including the stale-version conflict the backend documents; a real 409 from
  a running server has not been exercised.
* What the diagnostics screen and the recovery screen look like on a device, including
  whether `FLAG_SECURE` actually blocks a capture and whether the clipboard clear fires.
  Both are Android behaviours no host test reaches, and both join the existing release
  gate for the notification path.
* Whether a reader understands any of the wording added here.

## ADR-056 in full — the first measurement, and what it opens (2026-08-24)

**Status:** Accepted. Deployment decision. Amends ADR-055. **Opens no production gate.**

### The question

ADR-055 withheld closed-beta PQ MLS group messaging from the Private Experimental
artifact behind an evidence ledger, and named the one thing that would open it: an
observation of the packaged native core executing on real ARM hardware. It also recorded
the risk that the gate might never be opened, and set a follow-up to force that question.

A Samsung Galaxy A56 became available. So the question is no longer whether to accept the
risk ADR-055 declined to accept — it is what the measurement says, and what the answer
opens.

### Exact environment, fixed

| | |
|---|---|
| Working tree | `frontend` branch at `80c1948`, clean at the start of this work |
| Flutter / Dart | 3.38.0 / 3.10.0 |
| Rust | 1.97.1 (`rust-toolchain.toml`), NDK 28.2.13676358, CMake 4.2.1, Ninja 1.13.2 |
| Device | `samsung SM-A566B`, Android 16, API 36, `user` build, `release-keys`, `ro.kernel.qemu=0`, serial `R5CY716AG0L` |
| Host | Windows 11 Pro 26200, Git Bash |

### What was run

`tool/measure_beta_mls_core.sh arm64-v8a` cross-compiled the crate's own
`--features beta-pq-mls` test binary for `aarch64-linux-android` with the pinned toolchain,
pushed it to the phone, and ran it there. Nothing was installed on the device, no backend
was involved, no account existed, and no root was used.

**Result: 128 passed, 0 failed, 3 ignored, in 172.07 s.** Exit code 0. The record is
`docs/validation/beta-mls-core/2026-08-24-sm-a566b-arm64-v8a/`.

Two things make this more than a green tick.

**It is the same result the host gives.** `cargo test --locked --all-features` on the
x86_64 workstation reports 128 passed, 0 failed, 3 ignored. The two ignored-plus-passed
counts match exactly, so the device ran the same suite to the same conclusion rather than
a subset that happened to link.

**It covers the arithmetic, not just the linkage.** Forty `mls_beta::` tests ran, including
`operation_round_trips_create_join_private_message_proposal_commit_and_remove`,
`authenticated_suite_runs_key_package_welcome_proposal_commit_private_message_and_exporter`,
and `suite_signs_with_ed25519_and_round_trips_hybrid_hpke`. The last is the one that
mattered most: the hybrid HPKE round trip is where `aws-lc`'s ML-KEM runs, and `aws-lc` is
the C-and-assembly dependency the `beta` Cargo profile adds and the `foundation` profile
does not. That code has now executed on an ARM phone and produced the right bytes.

### Two defects in the instrument, found by contact with hardware

Neither could have been found any other way, which is the same thing ADR-053 recorded about
`tool/measure_sustained_delivery.sh`.

**The first run failed with no diagnostic at all.** On a Git Bash host, MSYS rewrites every
argument that looks like an absolute POSIX path into a Windows one before the process sees
it, so `adb push … /data/local/tmp/cp-beta-mls/beta_mls_tests` became
`C:/Program Files/Git/data/local/tmp/…` and adb reported
`remote secure_mkdirs() failed: No such file or directory`. The `adb` wrapper now sets
`MSYS_NO_PATHCONV=1` and `MSYS2_ARG_CONV_EXCL='*'`, both inert on Linux and macOS.

**And the reason it was silent was a second defect.** The three device-setup lines
redirected stdout to `/dev/null`, and `adb shell` folds the remote command's stderr into
its stdout — so the only diagnostic a device-side failure produces was being discarded, and
the script exited 1 saying nothing. Setup steps now run through a helper that captures the
output, prints it on failure, and additionally fails on the device-side error strings adb
reports while still exiting 0.

### The cell that cannot be measured

The A56 reports an empty `ro.product.cpu.abilist32`. Its Exynos s5e8855 is 64-bit-only and
cannot execute AArch32 at all, so the hardware that measured `arm64-v8a` can never measure
`armeabi-v7a`. This is not a quirk of one handset: Google's own 64-bit requirements page,
read 2026-08-24, tells developers that supporting 64-bit "sets you up for devices with
64-bit-only hardware", and this phone is one.

ADR-055 asked one question of the whole artifact — may it offer groups? — and required
every mandatory cell at once. With one cell measured and one unmeasurable, that framing
left exactly two moves, and both are bad:

- **Demote `armeabi-v7a` because it cannot be measured.** This is the reason ADR-053 exists
  to forbid. ADR-055 anticipated the temptation and wrote it down: dropping the cell "is a
  decision to make with a stated reason, not by quietly editing the enum" — and *"I could
  not measure it"* is not a stated reason, it is the absence of one. Worse, it would teach
  the ledger that a cell in the way can be argued away, which is precisely what
  `isAdmissible` exists to prevent.
- **Withhold the surface from everybody**, on account of a 32-bit-only device nobody in this
  deployment is known to have, while holding a passing measurement for the ABI every
  plausible recipient actually loads.

### Decision

**D1. The question changes from per-artifact to per-ABI.** One APK carries three native
libraries and the installer picks one, so "has the packaged core been observed running" has
three genuinely different answers, and the honest gate asks the one that applies to the
device in hand. `GroupExperimentalGate.hasEvidenceFor(GroupMlsFieldCell?)` replaces the global `isOpen`,
and `GroupProductionGate.privateExperimentalPermit` now takes the running ABI alongside the
environment.

**D2. `arm64-v8a` is open. `armeabi-v7a` and `x86_64` are not.** A device that loads the
measured library gets the closed-beta group surface, as ADR-044's experimental tier, with
its banner and its disposable-state disclosure intact. A device that loads either other
library is withheld it in substance — the unsupported adapter on all nine port methods, no
KeyPackage generated or uploaded, no post-inbox maintenance composed, inbound group objects
refused, every screen closed, and the Contacts entry disabled and labelled.

**D3. No cell is demoted, and the standard does not move.** `armeabi-v7a` stays in the
ledger, unmeasured, with its own comment saying why it cannot be measured here. If a 32-bit
device ever becomes available, the instrument runs against it and that ABI opens on the same
rule as the first. Nothing about `isAdmissible` changed: not emulated, a strict date that
survives a round trip, a committed run record, and every operation of the round trip
exercised.

**D4. This is stricter than ADR-055 where it matters, not looser.** The superficial reading
is that a partially satisfied matrix now opens something where before it opened nothing.
The substantive reading is the opposite: under ADR-055 a satisfied ledger would have opened
the surface on *every* ABI, including one added later with no run behind it. Under ADR-056
an ABI with no admissible record is withheld whatever else the ledger contains, and an ABI
this artifact packages no library for — a desktop host, an Android RISC-V device — maps to
no cell and fails closed. **No unmeasured processor is offered the surface, at all.**

**D5. Disclosure moves 6 → 7.** Revision 6 told every reader that group chats were switched
off, which is now true of only some. The point carries both halves: ADR-036's
disposable-state rule where the surface is available, and the fact that a phone whose
processor has not been measured is withheld it instead. Neither half may be dropped — a
reader whose groups work needs the first, and a reader whose groups are missing needs the
second or will conclude the application is broken. Under ADR-052's mechanism the edit forced
`since: 7`, which forced the revision, and `DisclosureChangeGate` re-presents to revision-5
and revision-6 readers with that single point badged.

### Is the ABI a runtime switch?

It has to be answered, because ADR-044 and ADR-055 both forbid one. No, on three grounds.

It is **read, never chosen**: `Abi.current()` is a property of the AOT snapshot the platform
loaded, fixed before any application code runs, and there is nothing to select. It can
**only narrow**: every path through the gate withholds on an unknown ABI and grants on
nothing but a committed, admissible record. And it **cannot reach production**, which fails
the environment test first, holds no permit on any ABI, packages a core that does not export
the symbol, and is unsigned. A test asserts that a fully satisfied ledger still leaves
production closed on all three ABIs.

It reaches the application through one provider, `runtimeAbiProvider`, backed by a
conditional import (`runtime_abi.dart` → `_native` / `_web` / `_stub`) that resolves
`Abi.current()` to a `GroupMlsFieldCell`. The platform read therefore sits behind a single
seam rather than being called from a config class or a screen — the rule
`frontend/AGENTS.md` states for platform differences — the gate speaks this project's own
vocabulary instead of `dart:ffi`'s, and a host test can pin an ABI it is not running on.
Tests assert that no consumer calls `Abi.current()` or imports `dart:ffi` directly, and
that the native resolver really runs: this suite executes on a host the artifact packages no
library for, so `currentGroupMlsAbiCell()` returning null there exercises the conditional
export, the read and the fail-closed default for real.

Android is the only version-1 target and this decision does not change that. The seam is
justified by the ports/adapters rule on its own; that it also keeps `dart:ffi` out of the
composition root, where it would break the web scaffold `frontend/AGENTS.md` keeps for
post-v1 work, is a second reason rather than the first.

### Alternatives evaluated

**A. Record the A56 run and open the gate globally.** Rejected. It would grant the surface
on two ABIs nothing has ever executed on, which is the claim ADR-055 was written to stop, and
it would do it while pointing at a run record that says `"abi": "arm64-v8a"`.

**B. Demote `armeabi-v7a` to non-mandatory.** Rejected, at length, above.

**C. Stop packaging `armeabi-v7a`.** Considered seriously, because it eliminates the risk
rather than routing around it: a library that is not in the APK cannot be loaded unmeasured.
Rejected because the cost lands in the wrong place — dropping the ABI denies a 32-bit user
the entire supported direct-message tier in order to protect them from an experimental group
feature, and `minSdk` is 24 precisely so those devices can install. Withholding one tier is
proportionate; refusing installation is not.

**D. Leave the gate closed until every ABI is measured.** Rejected. It makes the deployment
wait on hardware that may never be obtainable, and — unlike ADR-055's position, which rested
on *nothing* having been measured — there would now be a passing measurement for the ABI
every recipient is expected to load, being ignored.

**E. Accept the residual risk across all ABIs and open everything.** This is what the task
that produced this decision asked for. Rejected on the evidence, and the reason is worth
stating: once `arm64-v8a` was measured, there was no longer a blanket risk to accept. What
remained was one narrow, precisely locatable risk — 32-bit ARM — which per-ABI resolution
removes entirely at a cost of about sixty lines. Accepting a risk you can cheaply eliminate
is not pragmatism.

### What this does not close

- **Gate 6 is not satisfied.** The packaged-core cell of the physical-device matrix now has
  a run; process kill, Doze, force-stop, torn writes and Keystore-after-reboot do not.
  `docs/mls-profile.md` is unchanged on all of them.
- **No production gate moves.** The seven remain exactly where they were, and the five
  external Phase-A prerequisites remain blocked.
- **Nothing is reviewed.** ADR-017 is open for every layer, and this measurement says the
  code computes what it computes on ARM — not that what it computes is right.
- **Multi-device and live-backend execution is still outstanding.** One phone running a test
  suite is not two people exchanging group messages, and the remaining piece-19 cells stay
  open.
- **The on-device *Dart* assertion was not run.**
  `integration_test/crypto_core_android_smoke_test.dart` now asserts that the gate resolves
  the ABI the VM says it is running, but it could not be executed here: a device-targeted
  test build fetches only that device's engine ABI while ADR-054's `gradle.lockfile`
  requires all three, so the build fails on `Did not resolve 'io.flutter:armeabi_v7a_debug'`.
  The resolver itself is exercised on the host, where it correctly returns null; what stays
  unverified on hardware is only that `Abi.current()` reports `androidArm64` on an
  `arm64-v8a` install.

### Research

| Question | Source | Read | Finding |
|---|---|---|---|
| Does Android still expect 32-bit devices? | <https://developer.android.com/google/play/requirements/64-bit> | 2026-08-24 | Apps on Google Play must support 64-bit; supporting it "sets you up for devices with **64-bit-only hardware**". The direction is away from AArch32, and the measured device is already there |
| What is `armeabi-v7a`? | <https://developer.android.com/ndk/guides/abis> | 2026-08-24 | "This ABI is for 32-bit ARM CPUs", Thumb-2 and Neon, `-mfloat-abi=softfp`. Still a supported NDK ABI, so packaging it remains correct |
| Is Android ARM a supported `aws-lc` platform? | <https://github.com/aws/aws-lc> `README.md` | 2026-08-24 | Android **aarch64** is in the supported-platforms table — the ABI now measured. Android **arm32** is under *Other platforms*, a lower tier — the ABI now withheld. The support tiers and the evidence agree, which is a coincidence worth noting rather than relying on |

**Where the external evidence and the repository disagreed.** They did not, this time. The
external sources say 32-bit ARM is a shrinking, lower-tier configuration; the repository says
it has never been executed; the device says it cannot be. All three point the same way, and
the decision follows the repository's, because "lower support tier" is a statement about a
library's intent and "never run" is a fact about this build.

### Consequences

- Group messaging is available at first install to every recipient on a 64-bit ARM phone,
  which on current evidence is all of them.
- The KeyPackages this artifact publishes now correspond to a stack that has been observed
  working on the processor that will run it.
- A recipient on a 32-bit-only device keeps the entire supported tier and sees one honest
  sentence about why groups are missing.
- The ledger keeps its integrity: no cell was demoted, and the one that cannot be measured
  is still recorded as unmeasured rather than quietly reclassified.
- ADR-055's follow-up 1 is discharged. Its follow-up 2 — re-scope or re-decide if no run has
  happened by the second external build — is moot for `arm64-v8a` and now applies to
  `armeabi-v7a` instead.

### Review and revisit conditions

1. **A 32-bit ARM device becomes available.** Run the instrument; that ABI opens on the same
   rule, with no ADR needed.
2. **A run fails on any ABI.** That is a finding about the packaged core and outranks this
   decision.
3. **The packaged ABI set changes.** A new ABI must arrive with a cell and no evidence, and
   therefore withheld; a removed ABI takes its cell with it.
4. **Multi-device or live-backend execution produces a defect**, which is the outstanding
   piece-19 evidence this deployment exists to generate.
5. **A production gate closes**, particularly 1 or 2, which begins the group layer's
   replacement and makes this gate moot rather than satisfied.
6. **An independent cryptographic review is retained or reports** — ADR-044's condition 3,
   unchanged and still the largest deferred requirement.


## ADR-055 in full — what the first artifact hands a user (2026-08-24)

**Status:** Accepted. Deployment decision. Amends ADR-044's tier 2. **Opens no production
gate.**
**Amended by ADR-056 (2026-08-24):** the measurement this decision demanded was run and
passed on `arm64-v8a`, so the group surface is open on that ABI and withheld on the two with
no admissible record. D1, D2 and the ledger's all-or-nothing framing read as written only
for an ABI that has never been measured; the reasoning, the admissibility rules and the
withheld-in-substance requirement stand unchanged.

### The question

ADR-044 defined the initial deployment and put closed-beta PQ MLS groups in it as a
declared experimental tier. It considered shipping direct messages only, as alternative E,
and rejected it. Four days and nine ADRs later, one of ADR-044's own revisit conditions has
fired and the delivery picture underneath it has changed twice.

So the question is asked again, from evidence rather than from ADR-044's conclusion: **does
the first externally distributed artifact expose direct messaging only, or group messaging
as well?**

### Exact environment, fixed

| | |
|---|---|
| Working tree | `frontend` branch at `3a8e90c`, clean at the start of this work |
| Flutter | 3.38.0, Dart 3.10.0 |
| Rust | 1.97.1, edition 2024 |
| Host | Windows 11 Pro 26200, `TZ` offset `+0200` |
| Android devices attached | **none.** `adb devices` lists nothing |
| Backend | read-only, not running |

### What the repository actually shows, by trace rather than by documentation

Every row below was read out of code or a primary source during this work, not taken from a
checklist.

| Claim | How it was checked | Result |
|---|---|---|
| The beta artifact composes the real MLS stack | `group_providers.dart`, `sync_providers.dart` | Yes: `NativeBetaGroupMls`, `GroupKeyPackageMaintenanceService` as post-inbox work, `GroupMlsInboundCoordinator` on the inbound path |
| The group surface fails closed on divergence | `group_model.dart`, `drift_group_repository.dart`, `group_pages.dart` | Yes. Seven lifecycle states, five quarantine reasons, each with its own reviewed string and a `ChatSecurityGate` that withholds the composer |
| A group fault degrades direct messages | `pairwise_opaque_envelope_inspector.dart:423` | **No.** `_isGroupTransport` is tested first, so a queue gap blocks only MLS-dependent payloads. This is correct and was worth confirming |
| A Rust panic in the MLS core takes the process down | `lib.rs`, `Cargo.toml` | No. The C ABI wraps every call in `catch_unwind` and the release profile keeps `panic = "unwind"` so it can |
| A fault *below* Rust is contained | same | **No.** Nothing contains a fault in `aws-lc`'s own C or assembly, and it would take the direct-message tier down with it |
| The group logic is under-tested | `test/features/groups/**`, `native/crypto_core/src/mls_beta*` | **No, and emphatically not.** 17 Dart test files, a 30-test queue-gap recovery matrix, fork convergence, crash injection, 128 Rust tests under `--all-features`, 12 fuzz targets |
| The packaged MLS core has ever run on a phone | grep for `cp_crypto_v1_beta_mls_operation` across every `.dart`, `.kt`, `.sh`, `.rs` | **Never.** It appears in the FFI lookup, the Rust export, the host fuzz targets, the build allowlist and the artifact verifier. In no test on any device |
| The one Android integration test covers it | `integration_test/crypto_core_android_smoke_test.dart` | **No.** Capabilities, self-test, application protocol, identity crypto — the fifteen foundation symbols. It never reaches the beta symbol, and `tool/ci.sh` does not run `integration_test` at all |
| `beta_mls_native_session_test.dart` exercises the real core | its own source | No. It drives a stubbed `BetaMlsNativeApi`. Every beta MLS Dart test does |
| The undelivered-envelope TTL | `backend/config/settings/base.py:154` | `ENVELOPE_TTL_DAYS = 7`, confirmed in backend source rather than in `API.md` alone |
| Background delivery is available in the shipped artifact | `sustained_delivery_gate.dart` | The ADR-049 floor is; ADR-051's sustained delivery resolves `withheld` for beta, and **nothing about the floor's timing has ever been observed** |

The repository's own records agree about the decisive row. `docs/mls-profile.md` line 380
and `docs/implementation-checklist.md` rows 71, 73, 75, 78 and 79 each say that execution
against the packaged Rust core and physical devices remains pending;
`docs/mls-beta-review-readiness.md` line 1137 lists "the packaged Android smoke test and any
on-device execution" among what was **not** run and is "therefore not evidence of anything".

### The asymmetry that decides this

Both tiers are built on the same reviewed-by-nobody foundation and neither is audited. They
are not, however, in the same position, and three differences are load-bearing.

**1. What has executed where.** The `foundation` profile is pure Rust plus libsodium, and
the beta build carrying it has run on a device far enough to clear the fail-closed
provisioning gate against a live backend. The `beta` profile adds `aws-lc-sys` — C and
assembly, cross-compiled per ABI through bindgen and CMake — and `mls-rs` above it. That
addition has never executed a single instruction on ARM. The first execution of that code
path on the target architecture would be in a recipient's hands.

**2. What a missed delivery costs.** A pruned envelope costs a Double Ratchet session the
individual messages that were pruned; the session continues, because the core keeps up to
`MAX_SKIPPED_PER_SESSION = 2_000` skipped keys. A pruned envelope that was an MLS Commit
costs the member the group: `queueGapRejoinRequired`, which `CLIENT_CONTRACT.md` §H states
the device cannot self-recover from. Recovery requires **another person** — an owner or
admin removing and re-adding them for a fresh Welcome. In a deployment whose delivery
timeliness is entirely unmeasured and whose server prunes at seven days, that is not a
remote scenario.

**3. Whose failure it is.** This is the argument ADR-044 did not have in front of it. The
beta artifact generates and uploads KeyPackages. Peers claim them to add a device to a
group. If that device's MLS core is wrong on its particular ABI, its peers still add it,
consume its KeyPackage, and get a member who never converges — and *they* carry the cost, on
their groups, with no signal beyond someone who has gone quiet. That failure's signature is
absence, on somebody else's phone. It is exactly the category ADR-053 refused to ship.

### Re-testing ADR-044's alternative E

ADR-044 rejected direct-message-only on three grounds. Each is tested here rather than
inherited.

**E1 — "closing only the screens produces the current defect rather than safety."**
Correct, and still correct. It is an argument against closing the screens *alone*, which is
not what this decision does. What ships here withholds the stack, the KeyPackages and the
inbound path, and the screens follow.

**E2 — "closing it properly means unwiring five accepted decisions and leaving them
permanently unexercisable."** This is the strongest of the three and it is the reason this
decision is a gate rather than a removal. Nothing is unwired: `NativeBetaGroupMls`,
`GroupMlsAdmissionService`, the fork reconciler, the eviction service and the whole inbound
coordinator stay composed, tested and maintained, and every one of their tests still runs.
What changes is whether a distributed artifact *offers* the surface. ADR-036, ADR-037,
ADR-039, ADR-040 and ADR-041 are untouched, and none is superseded.

**E3 — "the only remaining piece-19 evidence can only be produced by people using it."**
This is the claim that does not survive. It is precisely the argument ADR-051 made for
sustained delivery and ADR-053 rejected, and here it is additionally **false in its own
terms**. The outstanding evidence decomposes into two questions, and only one of them needs
people:

- *does the packaged core compute correctly on this CPU?* — answerable by one person with
  one phone, no backend, no account and no second device; and
- *does the group system work between people over a live backend?* — which does need users.

The first is the one that makes exposure dangerous, and it is obtainable before
distribution. ADR-044 treated the pair as one indivisible item and concluded, reasonably
from that premise, that only distribution could produce it. Separating them dissolves the
dead end.

### Research

Everything below was read against the primary source on **2026-08-24**. `WebFetch` was
blocked on `developer.android.com`; those pages were retrieved with the locally installed
`scrapling` and read end to end.

| Question | Source | Read | Finding |
|---|---|---|---|
| Does Android developer verification block this distribution? | <https://developer.android.com/developer-verification> | 2026-08-24 | **No, not yet.** Enforcement from **2026-09-30** is scoped to *participating app stores* (Google Play, HONOR, OPPO, Galaxy Store, Palm Store, V-Appstore, GetApps) in **Brazil, Indonesia, Singapore and Thailand**, on certified devices running Android 7+. Global rollout is "**2027 and beyond**". Limited-distribution accounts launched August 2026 and cover "**up to 20 devices**" without a government ID or fee; an advanced flow keeps sideloading of unverified apps available |
| Is `TBD2` assigned yet? | <https://datatracker.ietf.org/doc/draft-ietf-mls-pq-ciphersuites/> | 2026-08-24 | **No.** Draft **06**, 2026-07-21, "Waiting for WG Chair Go-Ahead" with a revised I-D needed. All code points remain `TBD1`–`TBD11`. Production gates 1 and 2 are exactly where `docs/mls-profile.md` records them |
| Is `mls-rs` maintained? | crates.io API, `awslabs/mls-rs` compare API | 2026-08-24 | Yes, actively. Pinned **0.55.2** (2026-06-17); latest **0.56.0** (2026-08-19). **0.55.3 was yanked** and has no git tag; 0.55.4 landed the same day as 0.56.0. The nine commits between 0.55.2 and 0.55.4 are features plus one security fix — `fix(rust crypto x509): validate basic constraints, path length, key usage` (#371) — which lands in `mls-rs-crypto-rustcrypto`, **a crate this project does not use**. This project uses `mls-rs-crypto-awslc`, pinned 0.25.0, which is the latest |
| Does `aws-lc-sys` 0.40.0 carry a known vulnerability? | `rustsec/advisory-db`, five advisories | 2026-08-24 | **No.** RUSTSEC-2026-0044 and -0048 are patched at `>= 0.39.0`; -0045, -0046 and -0047 at `>= 0.38.0`. The pin is 0.40.0, so **all five are patched**, and all five concern X.509, PKCS7, CRL or AES-CCM surfaces that MLS does not reach. `mls-rs` and `mls-rs-crypto-awslc` have no advisory directory at all |
| Is Android ARM a supported `aws-lc` platform? | <https://github.com/aws/aws-lc> `README.md` | 2026-08-24 | Android **aarch64** is in the supported-platforms table. Android **arm32** is under *Other platforms*, a lower tier. Android x86_64 appears in neither |

**Where the external evidence disagrees with the decision, and which was followed.** It
disagrees in the direction of *permitting* exposure, and this is worth stating plainly
because it is the opposite of what a reader might expect. I went looking for a concrete
dependency defect that would settle the question and did not find one: the pinned
`aws-lc-sys` is patched against every filed advisory, the pinned `mls-rs` is unaffected by
the one security fix in its own update range, the upstream is actively maintained, and the
primary target ABI is officially supported. Nothing external argues against shipping this
tier, and no external deadline forces it either — verification enforcement does not reach
this deployment before 2027.

So the decision rests on the repository's own evidence rather than on the ecosystem's, and
the repository's evidence is unambiguous: the code has never run on the machine it ships to.
"Officially supported platform" is a statement about the library's intent, not an
observation of this build on this hardware. Treating the first as a substitute for the
second is the substitution ADR-053 was written to stop.

### Decision

**D1. The first externally distributed artifact exposes direct messaging only.** Registration,
enrollment, cross-signing, verification, the device log, recovery, contacts and profiles,
hybrid PQXDH + Double Ratchet direct messages, Saved Messages, attachments, linked devices,
history transfer and the durable inbox/outbox — ADR-044's supported tier, unchanged and
undiminished.

**D2. Group messaging is withheld in substance, not hidden from view.** With the gate closed
the beta artifact composes `UnsupportedGroupMlsCrypto`, which fails closed on all nine port
methods; `groupKeyPackageMaintenanceServiceProvider` throws, so **no KeyPackage is generated
or uploaded and this device advertises no group capability to anyone**; the durable sync
engine composes no KeyPackage post-inbox work; the inbound coordinator receives the
unsupported adapter, so a group object that arrives anyway is refused rather than processed;
and every group screen renders the closed gate. The Contacts entry point is disabled and
labelled instead of routing to a refusal.

**D3. The gate is an evidence ledger, and it is the reason this is a deferral.**
`GroupExperimentalGate` in `lib/app/config/group_production_gate.dart` holds an empty
`List<GroupMlsFieldEvidence>`. `privateExperimentalPermit` now requires the beta environment
**and** `ledger.isOpen`. Opening it means editing that file to add a record for each
mandatory ABI, and each record must survive `isAdmissible`: not emulated, a strict
`YYYY-MM-DD` that survives a round trip, a committed run record, and every operation of the
local round trip exercised. An inadmissible record is kept and does not count. A partially
satisfied matrix opens nothing, because one APK carries every ABI and the installer, not
this project, decides which library a recipient loads. There is no define, no remote value,
no runtime setter and no debug override.

**D4. The measurement is an instrument, not a promise.** `tool/measure_beta_mls_core.sh`
cross-compiles the crate's own `--features beta-pq-mls` test binary for one Android ABI with
the pinned toolchain, pushes it to a connected device, runs it there, and writes a
machine-readable record under `docs/validation/beta-mls-core/`. It installs no APK, needs no
backend, no account and no root, and adds nothing to the application — the same rule
`tool/measure_sustained_delivery.sh` follows. It exits non-zero with no device attached, and
it was verified to do so.

**D5. The disclosure moves to revision 6.** Through revision 5 the statement told the reader
that group chats use experimental encryption and that an update can reset a group. In an
artifact with no reachable group stack that is a false description of a feature, not a
caution. The point stays in the statement — a reader who is not told will look for groups and
conclude the application is broken — and now says the feature is off and why. Under ADR-052's
mechanism the edit forces `since: 6`, which forces `DeploymentDisclosure.revision` to 6, and
`DisclosureChangeGate` re-presents the statement once to a revision-5 reader with that single
point badged.

### A defect found and fixed on the way

`CreateGroupPage`, `GroupChatPage` and `GroupInfoPage` each checked their injected-collaborator
path **before** the availability gate, so a caller supplying its own collaborators rendered
the flow in a build with no group stack. Nothing in the router does that and it was not
reachable in the application, but a gate a constructor argument can step around is not a
gate. The availability check is now first on all five routed group screens, and a test pins
the ordering.

### Alternatives evaluated

**A. Keep ADR-044's exposure unchanged.** Rejected, but it is a serious position and it was
close. The group stack fails closed everywhere, cannot degrade the direct-message tier, and
is disclosed honestly; its logic is better tested than most shipping software. What it
cannot answer is the third asymmetry above — the cost of a wrong ABI is partly borne by
people other than the user who installed it, silently — and it asks 20–30 people to be the
first execution of a cryptographic library on ARM.

**B. Withhold the screens only, leave the stack running.** Rejected outright. This is the
exact defect ADR-044 found and fixed, in mirror image, and the task of withholding a surface
"in substance, not merely hidden from view" forbids it.

**C. Remove the group stack from the artifact.** Rejected. It would strand five accepted
decisions, make the outstanding evidence unobtainable, and force a supersede chain to reach.
It also buys nothing over a closed gate: with the gate closed the stack is unreachable, and
the packaged native core's symbol set is unchanged either way — which matters, because
changing it would change what `tool/verify_release_apk.sh` and the `build_rust_android.sh`
allowlist assert about the beta artifact.

**D. Expose groups to a subset of recipients, or after some usage period.** Rejected. Every
mechanism for it is a runtime or remote switch, which is forbidden and rightly: it would put
a per-user toggle in front of a cryptographic surface. It also inverts the risk — the
recipients least able to assess a failure would be the ones assessing it.

**E. Ship groups and disable KeyPackage upload.** Rejected as incoherent. A device that
cannot publish KeyPackages cannot be added to a group, so this is D2 with a worse
explanation and a surface that appears to work until someone tries to use it.

### What is irreversible, and what is not

This is the crux, and it points one way.

**Withholding is reversible at no cost to anyone.** The permit is a compile-time function.
A later build opens it: no uninstall, no application-ID change, no data migration, no lost
history. Recipients lose nothing, because they never had it.

**Exposing is not.** Once people build history in an experimental group, ADR-036 has already
scheduled that history for destruction when the suite changes — a group's history is not
merely at risk, it is *going* to be discarded. Withdrawing the feature afterwards takes
something away; leaving it in place means the loss lands later and larger. And a member
locked out by a queue gap needs somebody else to notice and act.

The two are not symmetric, and when one direction is free and the other is not, the free one
is where the uncertainty belongs.

### Security invariants

Every invariant in ADR-044's table is unchanged and none is weakened. Three are strengthened
by arithmetic rather than by assertion: this artifact now publishes no MLS KeyPackage at
all, executes no unreviewed draft ciphersuite, and carries no reachable code path into
`aws-lc`. The attack surface of the distributed artifact is strictly smaller than it was.

### Beta and production

| | Production | Private Experimental |
|---|---|---|
| Installable | **No.** Packages unsigned | Yes, frozen Beta identity |
| Native core | `foundation`, 15 symbols | `beta`, 16 symbols — **unchanged** |
| Group stack | `UnsupportedGroupMlsCrypto` | `UnsupportedGroupMlsCrypto`, while the ledger is empty |
| Group screens | `GroupProductionGatePage`, production wording | `GroupProductionGatePage`, withheld wording |
| KeyPackage upload | Impossible | **None while the ledger is empty** |
| Reason it is closed | No stack exists, and never will in this artifact | Evidence is absent, and is obtainable |

The production boundary is untouched. Production still resolves the unsupported adapter,
`GroupProductionGate.releaseAssertion` is unchanged, `main_production.dart` still references
it, the production artifact stays unsigned, and its packaged core still exports no beta
symbol. A test asserts that even a fully satisfied ledger leaves production holding no
permit: the evidence gate sits in front of the beta boundary, never in place of it.

### Known limitations

- **This decision withholds a working feature.** If the measurement passes on the first
  attempt, some recipients will have gone without groups for the interval, for a fault that
  was not there. That cost is accepted, and it is the smaller of the two available errors.
- **The gate could become a cancellation in practice.** Its whole justification is that the
  measurement is obtainable, and there is no device on this host. A Samsung Galaxy A56 was
  available to this project on 2026-08-23; if it is available again, the instrument runs
  against it. If nothing is ever run, this decision has withheld a feature permanently
  without saying so, and the follow-up below exists to force that question.
- **The measurement covers computation, not the system.** Passing it says the packaged core
  computes correctly on that ABI. It says nothing about multi-device behaviour, a live
  backend, Doze, force-stop, torn writes or Keystore after reboot. Gate 6 and the remaining
  piece-19 cells stay exactly where `docs/mls-profile.md` records them.
- **`armeabi-v7a` may be untestable in practice.** It is mandatory because the artifact
  packages it and `aws-lc` supports it at a lower tier, but 32-bit ARM hardware may be
  harder to obtain than the cell's importance warrants. Dropping it to non-mandatory is a
  decision to make with a stated reason, not by quietly editing the enum.
- **`SyncProjection.isSecurityBlocked` remains dead code**, as ADR-052 recorded. It is
  unrelated to this decision and is not fixed here.

### Follow-up

1. **Run `tool/measure_beta_mls_core.sh` on the first available phone**, for `arm64-v8a`
   first. This is the only thing standing between the recipients and group messaging.
2. **Re-scope or re-decide if no run has happened by the second external build.** A gate
   nobody attempts to open is a removal that has not admitted what it is.
3. **Extend the Android smoke test to the beta symbol** once a device exists to run it on,
   so CI has somewhere to put the regression rather than the ledger carrying it alone.
4. **Re-read the Android verification documentation before any distribution in 2027**, and
   before any distribution at all if the audience grows past the 20-device limited-distribution
   cap. ADR-044's revisit condition 6 is discharged for now, and dated.

### Review and revisit conditions

Re-open this decision when one of these occurs:

1. **An admissible record exists for every mandatory ABI** — the gate opens, and the group
   surface returns to ADR-044's experimental tier with its disclosure restored to matching
   wording.
2. **A run fails.** That is a finding about the packaged core and is worth more than this
   whole decision; it changes what may be said about the tier, not merely when it ships.
3. **`armeabi-v7a` hardware proves genuinely unobtainable**, which is a reason to argue the
   cell down explicitly, in an ADR, with the residual risk stated.
4. **The audience changes shape or public distribution is proposed** — ADR-044's conditions 1
   and 2, unchanged.
5. **A production gate closes**, particularly 1 or 2, which begins the group layer's
   replacement and makes this gate moot rather than satisfied.
6. **An independent cryptographic review is retained or reports** — ADR-044's condition 3,
   unchanged and still the largest deferred requirement.


## ADR-054 in full — what the delivery and notification path takes from outside, and what it writes (2026-08-24)

**Status:** Accepted. Ratifies, on evidence, the dependency choices ADR-046, ADR-048,
ADR-049 and ADR-051 each made in passing while deciding something else, and reverses two
of them. Supersedes ADR-007's adoption of Flyer Chat, which piece 15 contradicted in
implementation and no decision ever recorded. Adds the Android half of dependency pinning,
which did not exist. Changes no feature behaviour, no cryptography, no protocol, no wire
format, no transport trust, and no backend file.

### The question

> This work touches the platform in several distinct places. For each of them: what is
> genuinely required, what are the realistic ways of obtaining it, what does each way cost
> this project over years rather than this week — and what exactly is pinned?

Nothing was assumed. Not that any of it needs a package, not that any of it does not, not
that what is already installed was ever chosen, and not that one answer fits every point.
Both directions have a real failure mode: an adopted package brings code nobody here has
read into a product whose premise is that its code can be reasoned about; code written
here brings a surface nobody outside this project has ever exercised, in an area where the
platform is unforgiving and the mistakes are subtle. "We own it" is not a security
argument and "everyone uses it" is not a review.

### Exact environment, fixed

Unchanged from ADR-044, ADR-051 and ADR-053. 20–30 known users, all in Iran, private
handover; international connectivity possibly absent while domestic connectivity reaches
the backend; **no foreign runtime dependency of any kind at any layer**; an Android/Flutter
client installed as a directly signed artifact, never through a store; a server that is an
untrusted relay for end-to-end encrypted content. `minSdk` 24, `compileSdk` 36,
`targetSdk` 36, Flutter 3.44.7 / Dart 3.12.2, AGP 9.0.1, Kotlin 2.3.20.

### How the integration points were derived

Not from a list of candidate packages. From four traces over the repository, unioned:

1. every method channel the delivery and notification code opens, in both directions —
   `communication_platform/background_delivery`, `.../sustained_delivery`,
   `.../message_alerts`, `.../protected_storage`;
2. every Android framework or AndroidX symbol the Kotlin under
   `android/app/src/main/kotlin` actually calls, read file by file rather than from its
   imports alone;
3. every non-Flutter Dart package the delivery and notification code imports;
4. every element the *merged* manifest of a built artifact carries for this path,
   including what arrived from outside — read out of
   `build/app/intermediates/packaged_manifests/productionRelease/...`, not out of the
   source manifest.

Two things were considered and deliberately left out of the enumeration. The held socket
is `web_socket_channel` over `dart:io`: it contributes no Android component, no
permission and no plugin registration, so it is transport rather than platform
integration, and transport trust is out of scope for this piece. The shared Rust
cryptographic core has its own pinned dependency stack and provenance record under
ADR-032, ADR-036 and ADR-040; it is not reached by delivery or notification and is not
re-decided here.

### Point by point

**1. A deferred wake-up while the application is not in use.** Required: something the
platform will run periodically after the process is gone, that survives a restart, and
that does not fire against a dead network. *Written*, on `android.app.job.JobScheduler`
(`DeferredDeliveryJobService`, ADR-049). Rejected: `androidx.work`, which would add a Room
database, its own service and its own boot receiver to a curated manifest in order to
schedule one job it cannot schedule any better than the framework can at `minSdk` 24;
`AlarmManager` exact alarms, which buy timeliness with a permission the user can revoke;
foreign push, forbidden by ADR-013 and unreachable in this deployment anyway. Strongest
argument against: `JobScheduler`'s quota and Doze behaviour change between platform
versions and this project now tracks that itself, where `androidx.work` would have
absorbed some of it. Accepted, because what it would absorb is scheduling policy this
project has to understand and disclose to users regardless.

**2. A second Dart entry point in a headless process.** Required: start an engine, run a
named entry point, tear it down. *Written*, on `FlutterEngine` and `DartExecutor` from the
embedding that is already in the artifact. Nothing adopted; there is nothing to adopt.

**3. Dart ↔ platform messaging.** Required: a typed request/reply channel in both
directions. Flutter's own `MethodChannel`. Nothing adopted. Strongest argument against
using raw channels — that a plugin would give type generation — is answered by the fact
that four channels carrying booleans, strings and one integer do not need a code
generator, and that every payload is reviewed precisely because it is written out.

**4. Keeping the process out of the cached state.** Required: a foreground service of an
accurate type, started and stopped by this application only, displaying only reviewed
text. *Written* (`SustainedDeliveryService`, ADR-051), using `ServiceCompat.startForeground`
and `ContextCompat.startForegroundService` from **androidx.core** to carry the
foreground-service type across the API 26/29/34 signature changes. Rejected:
`flutter_foreground_task` and its equivalents, which own the service, the notification and
the isolate — exactly the shape where an adopted package's model becomes the product's,
and this project's arbitration between three delivery owners (ADR-050, ADR-051) is not
expressible inside one. Strongest argument against writing it: foreground-service start
rules are among the most frequently changed parts of Android and this project now owns
every one of them. Accepted, because the rules it must honour are stated in the platform
documentation and are already written down and tested here, and because a package that
owned the service would also own the notification text, which must stay reviewed and
localized in this project's own catalogue.

**5. A user-visible message alert.** Required: create a channel with a stable id, post one
notification with a stable tag, withdraw it, set a public version, a visibility, a
category and a small icon — across API 24 to 36. **Adopted: `androidx.core`**
(`NotificationCompat`, `NotificationManagerCompat`, `NotificationChannelCompat`).
Rejected: `flutter_local_notifications` and `awesome_notifications`, which carry
scheduling, timezones, boot receivers, actions, full-screen intents, media styles and
platform code for four platforms — a large surface for one sender-neutral sentence, and
each of them adds receivers and permissions to the merged manifest that this project would
not declare. Rejected: writing it against framework `Notification.Builder` directly, which
would mean re-implementing the version branching `NotificationCompat` already gets right,
in a file no device here can exercise. Strongest argument against adopting: `androidx.core`
is 700-odd classes of which this application uses a handful. Accepted, because it is
**not an addition** — `androidx.core` is already on the classpath behind
`androidx.activity` and `androidx.fragment`, which the Flutter embedding requires — so the
decision is only about the *version*, and the alternative to declaring it is inheriting
whatever transitive resolution picks.

**6. The `POST_NOTIFICATIONS` runtime permission.** Required: request it, know whether a
rationale is owed, and know whether notifications are enabled for the application at all —
which is a different question from whether the permission was granted. **Adopted:
`androidx.core`** (`ActivityCompat.requestPermissions`,
`ActivityCompat.shouldShowRequestPermissionRationale`,
`NotificationManagerCompat.areNotificationsEnabled`). Rejected: `permission_handler`,
which would add a permission model for every Android permission to an application that
asks for exactly one at runtime. Same reasoning as point 5: nothing new arrives.

**7. The battery-optimization exemption.** Required: read whether it is held, and show the
system's own dialog. *Written*, on framework `PowerManager.isIgnoringBatteryOptimizations`
and `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. Nothing to adopt that is
smaller than the framework call.

**8. The two settings screens.** Required: open this application's notification settings,
and open a manufacturer's background-restriction screen where one is documented. *Written*,
on framework intents. The one vendor deep link comes from Samsung's published
documentation and is tried rather than detected; ADR-053's hardware probe confirmed it
resolves on One UI 8.5.

**9. Network availability.** Required, and load-bearing in two directions: suppress a
delivery cycle and give up a held socket when the operating system says there is no
network, and resume within seconds of one appearing rather than waiting out a backoff.
**Adopted: `connectivity_plus` 6.0.5.** Rejected: writing it on
`ConnectivityManager.registerDefaultNetworkCallback`, which is about eighty lines of
Kotlin and eighty of Dart, and which this project cannot exercise on any device it has —
and whose failure mode is severe and silent, because `SyncLifecycleSupervisor` refuses to
start a cycle at all while the port says *unavailable*, so a written adapter that got one
callback wrong would stop delivery rather than degrade it. Rejected: doing without, which
would keep delivery correct but would spin cycles against a dead radio and would delay
recovery after an outage to the next backoff or lifecycle transition — in a deployment
where intermittent connectivity is the normal case. Strongest argument against adopting:
see *the frozen dependency* below; this pin cannot move.

**10. Application lifecycle.** Required: foreground, background, detached. Flutter's own
`WidgetsBindingObserver`. Nothing adopted.

**11. The durable store a headless engine opens.** Required: the database key, and the
database file's location. The key is *written* (`ProtectedStorageChannel`, AndroidKeystore
AES-GCM). The **location is inherited**: `drift_flutter` calls `path_provider`, which on
Android is `path_provider_android`, which since 2.3.0 is implemented over `jni` and
`jni_flutter` and therefore over `com.getkeepsafe.relinker`. This is the only place on the
delivery path where a native library and a plugin registration arrive through a chain
nobody chose, and it is where this piece found a **retracted** package version. Not
re-decided here beyond the version correction below: replacing it means replacing how the
database file is located, which is storage, not delivery.

**12. The alert's small icon.** *Written* — `res/drawable/ic_message_alert.xml`, a vector
drawable in this repository. ADR-031 already forbids a general-purpose icon package.

### What was found in the repository, by trace rather than by documentation

- **`androidx.core:core:1.16.0` was declared for one reason and used for four.** The
  comment in `android/app/build.gradle.kts` justified it as `FileProvider` for attachment
  sharing. It also supplies every notification API, both foreground-service compatibility
  calls, and the runtime-permission calls. Corrected in place.
- **`ACCESS_NETWORK_STATE` was in the artifact and justified nowhere.** It arrives from
  `connectivity_plus`'s own manifest. The application's manifest is a curated document
  where every permission carries the reason it is there; a reviewer reading it would have
  had a complete-looking list that was not complete. Now declared locally, with its
  justification, next to the others.
- **An exported receiver this project never chose was in every artifact.**
  `androidx.profileinstaller:1.3.1`, which arrives behind `androidx.core` and
  `androidx.activity`, merges in `androidx.profileinstaller.ProfileInstallReceiver` —
  `android:exported="true"`, four intent filters, guarded by `android.permission.DUMP`.
  Nothing in this application starts it or benefits from it. It is now refused with
  `tools:node="remove"`. The baseline profile is still written on first run:
  `ProfileInstallerInitializer.create()` calls `ProfileInstaller.writeProfile(Context)`
  directly and never names the receiver — read out of `classes.jar` with `javap`, not
  assumed. What is lost is the shell- and store-triggered profile operations, and this
  artifact is never submitted to a store.
- **The Android half of the dependency set was not pinned at all.** `pubspec.lock` plus
  `flutter pub get --enforce-lockfile` pinned Dart exactly. Gradle had static versions —
  so resolution was deterministic — but nothing recorded the resolved set and nothing
  would have failed if it changed. That is not hypothetical: see *the frozen dependency*.
- **`jni` 1.0.1 was in the shipped artifact and had been retracted by its publisher**, one
  day after publication, for the breaking Kotlin-plugin change this repository was
  carrying a hand-written workaround for in `android/build.gradle.kts`. `--enforce-lockfile`
  guaranteed it would be reinstalled forever. Upgraded to `jni` 1.0.3 and `jni_flutter`
  1.0.2, and the workaround is deleted — `jni` 1.0.2's changelog is "Revert an unnecessary
  (and breaking) KGP migration", which is exactly what the workaround existed for. The
  Gradle-resolved set is byte-identical before and after, verified.
- **Four direct Dart dependencies were declared and unused.** `flutter_chat_core` 2.9.0
  and `flutter_chat_ui` 2.11.1 are imported by no file in `lib/`: piece 15 chose a custom
  reversed-sliver timeline adapter because Flyer 2.11.1 requires mutable controller-owned
  message state, and the checklist records that, but ADR-007 was never superseded and the
  packages stayed declared. `riverpod_annotation` 4.0.3 and `riverpod_generator` 4.0.4 are
  referenced by nothing at all — there is no `@riverpod` annotation and no generated
  Riverpod file anywhere; the generator's only trace is the `build_runner` entry point it
  installs. Removing the four takes **eighteen packages** out of the resolved set,
  including `riverpod_analyzer_utils` at a `1.0.0-dev.10` pre-release and a transitive
  `mockito` in the build toolchain.
- **Eight direct dependencies were declared as caret ranges, not pins.** The lockfile held
  them, so nothing drifted, but the *declared* intent was "whatever is compatible", and
  the repository's own instruction is to use pinned dependencies. Two of the eight were
  the unused Flyer packages and are gone; the other six — `dio`, `drift`, `drift_flutter`,
  `forui`, `go_router` and `flutter_lints` — are exact now, which is what the majority of
  the file already did.

### The frozen dependency, and why `connectivity_plus` stays at 6.0.5

6.0.5 was published on 2024-08-09; 7.3.1 on 2026-07-23. Two years and one major version
behind is exactly the kind of inherited pin this piece exists to interrogate, so it was
interrogated, and the upgrade was attempted rather than argued about.

The whole of `connectivity_plus` 6.0.5's Android implementation was read: four Java files,
about 250 lines, reaching `android.net.ConnectivityManager` and nothing else. Its manifest
contributes exactly one permission. Its `SDK_INT < N` branch is dead at `minSdk` 24. Only
one change since then is relevant to this application — 7.3.0's `safelyUnregisterNetworkCallback`,
which wraps `unregisterNetworkCallback` in a `try`/`catch`, and which matters because
`ConnectivityPlugin.teardownChannels()` calls `onCancel` directly from
`onDetachedFromEngine`, outside the `EventChannel`'s own error handling, and this
application destroys headless engines routinely.

The upgrade was applied and resolved cleanly on the Dart side: `pubspec.lock` changed by
exactly one line, with no transitive difference at all. It then **failed on the Android
side**, and the failure is the finding:

```
+--- androidx.core:core:1.16.0 -> 1.18.0 FAILED
```

`connectivity_plus` 7.1.0 and every later version declare `implementation
"androidx.core:core:1.18.0"` in their own `android/build.gradle`. 7.0.0 declares no
androidx dependency and contains none of the fixes. So taking any `connectivity_plus`
that improves anything carries this project's explicitly pinned, reviewed `androidx.core`
upward by two minor versions — and `androidx.core` 1.18.0 raises its required `compileSdk`
to **36.1**, while this toolchain compiles at `flutter.compileSdkVersion`, which is 36.
That is an Android SDK migration and a fresh review of a new AndroidX set, arriving
through a plugin upgrade, with no line of this repository's build files changing.

So: **`connectivity_plus` 6.0.5, deliberately, and frozen.** The honest statement of the
cost is that this project cannot take a `connectivity_plus` fix without first moving
`compileSdk` to 36.1 — recorded below as a revisit condition, not as a resolved problem.
The reason this is tolerable rather than alarming is that the package is 250 lines of
read code against one system service, and the fix being forgone is a defensive `catch`
around a call this application's own usage keeps balanced.

The second finding is more general, and is why the Android set is now locked: **a Dart
lockfile does not describe the Android dependency consequence of a Flutter plugin.** The
`pubspec.lock` diff for this upgrade was one line and looked entirely safe.

### The exact pins, and why those versions

| Adopted | Version | Why this version |
|---|---|---|
| `androidx.core:core` | **1.16.0** | 1.17.0 adds only `NotificationCompat.ProgressStyle`, `setRequestPromotedOngoing` and a `Parcel` extension, none of which this application uses. 1.18.0 raises the required `compileSdk` from 36 to **36.1**; 1.19.0 keeps that. 1.16.0 is also already in the local Gradle cache, so the build stays offline. |
| `connectivity_plus` | **6.0.5** | The last version that declares no `androidx.core` dependency of its own, and therefore the last one that cannot move the pin above. See *the frozen dependency*. |
| `jni` / `jni_flutter` | **1.0.3 / 1.0.2** | 1.0.1 is retracted. 1.0.2 reverts the breaking KGP migration this repository carried a workaround for; 1.0.3 adds a Linux arm64 build fix and changes nothing here. The Gradle-resolved set is identical to what 1.0.1 produced. |

Everything else in the artifact is transitive and is recorded, module by module, in
`android/app/gradle.lockfile`.

### What a released artifact now contains that this project did not write

Fifty-one external Android modules on `betaReleaseRuntimeClasspath`, identical to
`productionReleaseRuntimeClasspath`: thirty-five `androidx.*`, nine `org.jetbrains.*`
(the Kotlin standard library, the coroutines runtime and the annotations jar), four
`io.flutter:*` (the embedding and three engine ABIs), `org.jspecify:jspecify`,
`com.google.guava:listenablefuture` and `com.getkeepsafe.relinker`. Alongside them are
this project's three plugin subprojects — `:connectivity_plus`, `:jni`, `:jni_flutter` —
which are Dart packages compiled as Gradle modules and so are pinned by `pubspec.lock`
rather than by the Gradle lock. The complete module list is in
`android/app/gradle.lockfile`, is asserted literally in
`test/architecture/dependency_policy_test.dart`, and is reproduced with its licences in
`docs/third-party-notices.md`.

Arriving in the merged manifest from outside, in full:

- `<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />` — from
  `connectivity_plus`. Now also declared and justified locally.
- `<permission android:name="${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
  android:protectionLevel="signature" />` and its matching `<uses-permission>` — from
  `androidx.core`, read out of the AAR's own manifest. It is a signature-level permission
  scoped to this application's own id, used by `ContextCompat.registerReceiver` for
  runtime-registered receivers; nothing outside a build signed with this project's key can
  hold it.
- `android:appComponentFactory="androidx.core.app.CoreComponentFactory"` on
  `<application>` — from `androidx.core`.
- `<uses-library android:name="androidx.window.extensions" android:required="false" />`
  and the same for `androidx.window.sidecar` — from the Flutter embedding.
- `<provider android:name="androidx.startup.InitializationProvider"
  android:exported="false" />` carrying `ProcessLifecycleInitializer` and
  `ProfileInstallerInitializer`.
- `<receiver android:name="androidx.profileinstaller.ProfileInstallReceiver"
  android:exported="true" ... />` — **refused**, see above.

Native libraries in the artifact that this project did not write: `libflutter.so` (the
engine) and `libdartjni.so` (from `jni`). `libcommunication_crypto_core.so` is this
project's own, decided elsewhere.

### Evidence that nothing in the resolved set reaches anywhere it must not

Asserted nowhere; measured. Every artifact for the fifty-one modules on
`betaReleaseRuntimeClasspath` was taken out of the local Gradle cache and **4,559 class
files** were scanned for references to `java/net/`, `javax/net/ssl`, `android/net/http`,
`android/webkit`, `okhttp3`, `retrofit2`, `org/apache/http`, `android/app/DownloadManager`,
`java/nio/channels/SocketChannel`, `java/nio/channels/DatagramChannel` and
`com/google/android/gms`. Three modules matched, and every match was read:

- `androidx.core` — `ContextCompat$LegacyServiceMapHolder` names
  `android.app.DownloadManager` as one entry in the `getSystemService` name-to-class map;
  `FileProvider` and `LinkifyCompat` use `android.webkit.MimeTypeMap` and
  `android.webkit.URLUtil` for MIME and URL *parsing*; `TrafficStatsCompat` and
  `DatagramSocketWrapper` tag a socket the caller already owns. None opens a connection.
- `org.jetbrains.kotlin:kotlin-stdlib` — `TextStreamsKt` and `PathsKt__PathUtilsKt`, the
  `java.net.URL`/`URI` extension functions of the standard library. Nothing calls them
  here.
- `org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm` — `FastServiceLoader`, which uses
  `java.net.URL` to enumerate `META-INF/services` resources on the local classpath.

No match anywhere in `io.flutter:flutter_embedding_release`,
`androidx.profileinstaller`, `com.getkeepsafe.relinker` or any other module. Five
coordinates have no artifact of their own (`androidx.annotation:annotation`,
`androidx.collection:collection`, `kotlin-stdlib-common`, `kotlinx-coroutines-core`, and
the `kotlinx-coroutines-bom` platform); the first four are relocation pointers whose code
was scanned through their `-jvm` siblings, and a BOM has no code at all.

`connectivity_plus` 6.0.5's Android source was read in full rather than scanned: it
resolves `ConnectivityManager` from the context, calls `getActiveNetwork`,
`getNetworkCapabilities` and `registerDefaultNetworkCallback`, and reports transport
names. It reaches no host.

And then the shipped artifact itself was read, which is the answer that actually matters,
because R8 removes what is never called. The `classes.dex` of
`app-production-release.apk` — every line of Java and Kotlin in the artifact, 574 KB after
shrinking — contains **no reference at all** to `java/net/*`, `javax/net/ssl/*`,
`android/net/http/*`, `okhttp3`, `retrofit2`, `org/apache/http`,
`android.app.DownloadManager`, `java.nio.channels.SocketChannel` or
`com/google/android/gms/*`. The only three network-adjacent types it references are
`android.net.Uri`, `android.webkit.MimeTypeMap` (MIME lookup inside `FileProvider`) and
`android.net.ConnectivityManager`. **No Java or Kotlin code in this artifact is capable of
opening a connection.** Every byte this application sends leaves through `dart:io` inside
`libflutter.so`, on the one reviewed transport with the provisioned trust store.

The artifact carries five native libraries. `libapp.so` is this application's own Dart
AOT image; `libcommunication_crypto_core.so` is this project's Rust core;
`libflutter.so` is the engine; `libsqlcipher.so` arrives with `sqlite3`'s `sqlcipher`
source under the encrypted-storage decision; `libdartjni.so` arrives with `jni`, from
point 11's inherited chain.

Existing architecture assertions already forbid `http://`, `https://` and `InetAddress`
in the delivery Kotlin, and forbid Firebase, WorkManager, UnifiedPush and every
notification package by name; those are unchanged and still pass.

### Licence obligations, and the honest state of them

Every distributed component is permissively licensed and none is copyleft:

- **Apache License 2.0** — all thirty-five `androidx.*` modules (Copyright The Android
  Open Source Project; `androidx.core`'s AAR carries the full text at
  `META-INF/androidx/core/core/LICENSE.txt`), all nine `org.jetbrains.*` modules
  (JetBrains s.r.o.), `org.jspecify:jspecify` (The JSpecify Authors),
  `com.google.guava:listenablefuture` (The Guava Authors),
  `com.getkeepsafe.relinker` (Copyright 2015 KeepSafe Software Inc.).
- **BSD 3-Clause** — `io.flutter:*` (The Flutter Authors) and `connectivity_plus`
  (Copyright 2017 The Chromium Authors), together with the Dart packages that carry the
  same Chromium-derived notice.

Both licences require that a recipient of a binary be given the licence text and the
attribution notices. **This was not being done.** The Flutter build writes
`flutter_assets/NOTICES` into the artifact for the Dart and engine side, but nothing in
the application ever shows it, and the Android libraries are not in it — of the fifty-one
modules, only `androidx.core` ships a licence file inside its own artifact at all.

Discharged here by `docs/third-party-notices.md`, which lists every distributed component
with its licence and copyright and reproduces both licence texts, and by
`deployment-and-release.md`, which now names it as part of the written handover ADR-044
already requires. That is a real discharge for a private handover of 20–30 artifacts and
is not a substitute for an in-app notices screen, which is recorded as follow-up F2. The
document deliberately does **not** claim to cover the native cryptographic core's Rust
and vendored C dependencies; those are pinned and provenance-tracked under ADR-032,
ADR-036 and ADR-040 and are follow-up F3.

### Supply-chain exposure, and what would detect a change in it

Three surfaces, and each now has something that fails:

1. **The Dart set.** `pubspec.yaml` declares fourteen runtime and five development
   dependencies, every one an exact version. `pubspec.lock` records 129 packages.
   `flutter pub get --enforce-lockfile` in `tool/ci.sh` fails on any drift.
   `dependency_policy_test.dart` additionally asserts the literal direct set, that no
   declaration is a range, that the lock and the pubspec agree about what is direct, and
   that nothing in the resolved set is a pre-release — the last because a `-dev` package
   sat in this project's build toolchain unnoticed.
2. **The Android set.** New. `android/app/gradle.lockfile` records 78 modules across the
   six configurations that decide what a built artifact contains, in `LockMode.STRICT`.
   A new transitive arrival fails artifact resolution with *"Resolved 'x' which is not
   part of the dependency lock state"* — demonstrated deliberately by adding an unlocked
   module and reading the failure, not assumed from the documentation. A *version* change
   behaves differently: locking silently forces the recorded version instead of
   reporting, so `dependency_policy_test.dart` also requires the declared pin and the
   locked version to agree, which is what stops the build file and the lock drifting
   apart.
3. **The merged manifest.** `dependency_policy_test.dart` asserts the complete
   `uses-permission` set of the source manifest, that the profileinstaller receiver is
   refused, and that exactly one component is exported. `tool/verify_release_apk.sh` reads
   the permissions and components back out of the *packaged* artifact, which is the only
   place a declaration that arrived from a dependency can be seen.

What an update could still introduce without anyone noticing: a change *inside* a module
at a version that is already locked is impossible — Gradle and pub both verify content
hashes — but a deliberate regeneration of either lockfile by a future change is only
caught by review of the diff, which is why both lockfiles and the literal expected sets
live in source control where a diff is visible.

### Maintenance and abandonment, in both directions

- **`androidx.core`.** Abandonment risk is negligible; the risk is the opposite, that it
  moves faster than this project's `compileSdk`. It already has. The mitigation is the pin
  and the lock, and the cost is that the pin has to be moved on purpose.
- **`connectivity_plus`.** Actively maintained by the Flutter Community organisation, and
  effectively abandoned *by this project*: it cannot move without a `compileSdk`
  migration. If it had to be replaced, the replacement is the eighty-line adapter this
  decision rejected, and the port it sits behind — `NetworkAvailabilityPort`, two members
  — is unchanged by the swap. That is the whole reason the port exists.
- **`jni` / `jni_flutter` / `path_provider`.** The least deliberate part of the set and
  the most likely to move under this project. It arrives entirely because `drift_flutter`
  wants a directory path. Follow-up F1 asks whether that path should be supplied by the
  protected-storage channel this project already owns, which would remove the plugin, the
  native library and the ReLinker dependency together.
- **What this project now maintains itself**: the job scheduling policy, the foreground
  service lifecycle and its type declaration, the exemption flow, two settings intents,
  the notification content and channel policy, and the arbitration between three delivery
  owners. All of it is Android platform behaviour that changes about once a year, and all
  of it is already covered by architecture assertions that read the Kotlin source.

### Removal paths, and what each leaves behind

- **`androidx.core`**: cannot be removed — the embedding requires it. The *declaration*
  can be removed, which would surrender the version to transitive resolution. Nothing is
  left on a device.
- **`connectivity_plus`**: delete the dependency, delete
  `ConnectivityNetworkAvailabilityPort`, supply `NetworkAvailabilityPort` another way. It
  registers no receiver in the manifest, schedules nothing, and stores nothing; a network
  callback lives only as long as the process. **Nothing survives its removal on a user's
  device.**
- **`androidx.profileinstaller`** (already partly refused): the baseline profile it writes
  lives at `/data/misc/profiles/cur/0/<package>/primary.prof`, inside this application's
  own profile directory, and is removed with the application. It contains method
  identifiers from this application's own dex, no user data.
- **`jni`/`jni_flutter`**: removing them means removing `path_provider`, which means
  telling `drift_flutter` where the database is. The database file itself is unaffected,
  provided the replacement resolves the same directory — which is the one real hazard in
  F1 and the reason it is a separate piece.

### What is enforced automatically, and what rests on review

Automatic: the Dart lock (`--enforce-lockfile`), the Android lock (`LockMode.STRICT`), the
fourteen assertions in `dependency_policy_test.dart` — one of which requires
`docs/third-party-notices.md` to list exactly the modules the lock says a release links,
so the licence discharge cannot drift from the set it discharges — the receiver assertions
in `message_alert_policy_test.dart` and `sustained_delivery_policy_test.dart`, narrowed in
place from "the manifest contains no `<receiver`" to "the manifest declares no receiver",
and the three packaged-artifact checks in `tool/verify_release_apk.sh`.

Review-only: whether a *new* adopted package's source has actually been read; whether a
regenerated lockfile was regenerated for a stated reason; whether the notices document was
updated with the set; and whether the justification comments in the manifest and the build
file still match what the code does — which is the exact thing that had silently stopped
being true for `androidx.core`.

### Beta and production

The two distributed flavors resolve **identical** Android sets, asserted. The development
debug flavor additionally resolves Espresso 3.3.0, JUnit 4.12, Guava 28.1-android,
Hamcrest 1.3, `javax.inject`, `com.squareup:javawriter` and the debug engine ABIs — all of
which arrive with `integration_test`, a development dependency. Nothing enforced that they
stayed out of a distributed artifact; the lockfile now records the configuration each
module reaches, and a test fails if any of them appears outside `developmentDebug*`.

No choice here is acceptable-for-now-only in a way that wider distribution would change,
with one exception: the licence discharge relies on a written handover to 20–30 known
people. Any distribution that is not hand-delivered needs the in-app notices surface of
follow-up F2 first.

### Known limitations

- Nothing about this decision was measured on a physical device, and nothing about it
  needs to be: it changes no runtime behaviour. The one behavioural change is the removal
  of an exported receiver nothing calls, and its replacement path was read out of the
  library's own bytecode rather than exercised.
- The dependency lock covers the six configurations a built artifact resolves. A future
  AGP release that renames them would switch locking off for the renamed ones; that is why
  the six names are also asserted in a Dart test, but the assertion can only catch a
  rename, not a new configuration that matters.
- `dependency_policy_test.dart` pins the Flutter engine as a placeholder rather than a
  literal revision, so a Flutter SDK upgrade fails the Gradle lock rather than the test.
  That is deliberate; the lock is the stricter of the two.
- The network-reachability scan is over compiled classes, and it establishes what the
  libraries *can* reference. R8 shrinking means the shipped dex contains less than that,
  never more.

### Follow-up

- **F1.** `path_provider` and its `jni`/`jni_flutter`/ReLinker chain exist so that
  `drift_flutter` can find a directory. Decide whether the protected-storage channel this
  project already owns should supply it, which would remove a plugin registration and a
  native library from the artifact. Storage piece, not delivery.
- **F2.** An in-app third-party notices surface, so the licence texts travel with the
  artifact rather than with the handover document.
- **F3.** Extend `docs/third-party-notices.md` to the native cryptographic core's Rust and
  vendored C dependencies, whose licences are recorded per-crate but not aggregated.
- **F4.** `dart format` reports one pre-existing unformatted file at this commit's parent
  (`lib/features/authentication/infrastructure/secure_session_token_adapter.dart`), and
  `tool/ci.sh` still fails on the two `0x7fffffffffffffff` literals in the post-v1 web
  build. Neither is this decision's, and neither is fixed here.

### When each choice must be revisited

- **`androidx.core:core:1.16.0`** — when `compileSdk` moves to 36.1 or later, or when a
  notification, foreground-service or permission API this application needs lands in a
  later version. Moving it requires re-reading what the new version merges into the
  manifest and re-recording the lock.
- **`connectivity_plus:6.0.5`** — the moment `compileSdk` reaches 36.1, because that is
  what unblocks 7.x; or immediately, if a defect is found in the code that was read here.
  If neither happens, revisit in any case before this project's Flutter SDK moves past
  the last version 6.0.5 supports.
- **`jni`/`jni_flutter`** — with F1, or when `path_provider_android` next changes its
  implementation strategy.
- **Everything written rather than adopted** — at every `targetSdk` increase, because that
  is when the platform's job, foreground-service and notification rules start applying to
  this artifact. The existing policy tests read the Kotlin source and will not notice a
  rule that changed without the source changing.
- **The whole decision** — if this project ever distributes through a store, which brings
  review of the `specialUse` justification and a notices requirement, or if it stops being
  possible to fetch a package from outside Iran at all, at which point every pin here
  becomes permanent and the questions above have to be answered with what is already in
  the local caches.

## ADR-053 in full — whether receiving while the application is not in use actually works (2026-08-23)

**Status:** Accepted. Amends ADR-051's *Beta and production* clause and restores, in a
stronger form, the distribution clause ADR-046 wrote and ADR-051 removed. Adds a release
gate, a validation document and a measurement instrument. Changes nothing about the
capability itself, no cryptography, no protocol, no backend. Corrects two fleet figures
and one user-facing claim.

**Addendum, 2026-08-23 — one physical device, probed, no cell opened.** A Samsung
Galaxy A56 (SM-A566B, Android 16, API 36, One UI 8.5, retail `user` build)
became available after this decision was written and was probed. Nothing was
installed on it and the capability was never started, so **the gate is unmoved
and every cell of the matrix is still unrun** — the `samsungAndroid14Plus` cell
now has hardware and still has no measurement. Four things were established,
and each is one reading on one phone on one date. *One:* the whole procedure
runs on retail Samsung hardware from an unrooted shell, including
`dumpsys deviceidle force-idle` genuinely reaching deep `IDLE`. *Two:* the
Samsung settings intent this decision took from vendor documentation and shipped
unverified — `ACTION_OPEN_CHECKABLE_LISTACTIVITY` on `com.samsung.android.lool`
— resolves on One UI 8.5, so the button goes somewhere real. *Three:* this
phone's Doze schedule is thirty times slower than the API 35 emulator this
decision reasoned from (`inactive_to` 30 m against 1 m; first deep idle on the
order of 35 minutes, not 2), which would have made every emulator-derived
duration wrong by more than an order of magnitude. *Four:* whether the
cached-apps freezer is even active on One UI 8.5 **could not be determined** by
any configuration read available — and that behaviour is the entire
justification for the foreground service, so it has to be answered by a run.

The instrument also had two defects that only hardware could expose, both fixed:
`probe` would have committed 446 lines of the phone owner's installed-app
allowlist, and `watch` was reading a `frozen=` field that exists on none of the
three devices — a column that would have been recorded at every sample while
never being measured, which is this piece's own failure mode in miniature. It
now reads the adj label and state triple from `dumpsys activity oom`.

Full detail in `docs/sustained-delivery-validation.md` §6.1.

### The question

> The capability under test depends on behaviour the platform permits but does not
> guarantee, and on behaviour that individual manufacturers are free to override. What
> actually happens on real devices, over real durations, under the conditions real users
> create — and what should this repository do about the fact that nobody knows?

Nothing was assumed: not the fleet, not what "works" means, not the way to observe it,
not the durations, not the tooling, not the answer. That the capability works and that it
fails were treated as equally open.

### Exact environment, fixed

Unchanged from ADR-044 and ADR-051. 20–30 known users, all in Iran, private handover with
written instructions, international connectivity possibly absent while domestic
connectivity reaches the backend, no foreign runtime dependency at any layer, an
Android/Flutter client installed as a directly signed artifact, and a server that is an
untrusted relay for end-to-end encrypted content. `minSdk` 24, `targetSdk` 36, Flutter
3.44.7 / Dart 3.12.2.

### How the fleet was derived, and two corrections

Statcounter Global Stats for Iran, twelve months 2025-08 to 2026-07, **read 2026-08-23**:
`gs.statcounter.com/vendor-market-share/mobile/iran` and
`gs.statcounter.com/android-version-market-share/mobile-tablet/iran`. Re-read rather than
carried forward. The vendor headline figures ADR-046 and ADR-051 quote survive — Samsung
46.31%, Xiaomi 30.99% for July 2026 — but the use both decisions made of them does not.

**Correction 1.** ADR-051 says Samsung and Xiaomi are "roughly 77% of this fleet". That is
their share of all mobile devices, iPhones included, and this is an Android-only artifact.
Excluding Apple's 14.25%, the two are **about 90%** of the Android fleet this deployment
will meet — Samsung 54.0%, Xiaomi 36.1%. The repository understated its own vendor
concentration by thirteen points, in the one place where that concentration is the whole
argument.

**Correction 2.** ADR-051 says "roughly half this fleet by version share is Android 13 or
earlier", and uses it to bound how much of the fleet Samsung's One UI 6.0 statement
covers. The figure is **60.0%**. Android 14 and later — the only band One UI 6.0+ can
occupy — is 39.98%. So at most two fifths of this fleet is covered by any vendor statement
at all, and once every Xiaomi device is removed from the covered side, the uncovered
fraction is about **78%**, not half.

**And the limit of all of it.** This deployment has 20–30 *known* users. A country panel
statistic is a prior over an unobserved fleet, not the fleet. The strongest available
derivation is to ask the twenty-odd people what phone they have; nobody has, and until
somebody does the matrix rests on a proxy. That is recorded as follow-up F1 rather than
hidden.

### What was found in the repository, by trace rather than by documentation

- The capability is genuinely composed and reachable: `SustainedDelivery.attach` on the
  activity's engine, a listener in `app.dart` refreshing on resume, a Settings row, and a
  route at `/settings/receiving-while-closed`. This is not a feature that exists only in
  tests.
- **It cannot be exercised at all without an activated account.** `runSustainedDelivery`
  refuses any session that is not `AccountSessionScope.full` with `securitySetupComplete`
  and a `deviceId`, and the screen sits behind the signed-in shell.
  `backend/accounts/API.md` creates every account inactive and makes activation a human
  action by the operator. So the measurement needs hardware **and** an operator-activated
  pair of test accounts.
- `SustainedDeliveryService` is `exported="false"`, so nothing outside the application can
  start it — correct, pinned by test, and also the reason there is no shortcut around the
  previous point.
- **`platform-android.md` already said the physical-device matrix "remains a release
  validation gate for any *claim* about timeliness".** It was enforced by nothing. A gate
  expressed only as prose in a document is a sentence, not a gate; this decision is the
  difference.
- `sustainedWhatItDoes` told users "messages can reach you within seconds of being sent",
  in a build where no latency had ever been timed by anybody. A user-facing latency claim
  may only ever come from a measurement. It is corrected here, and a test now fails on the
  phrase.

### Defining "works", before measuring anything

Ten falsifiable criteria were written on 2026-08-23 **before any measurement of any kind
was attempted**, and are in `docs/sustained-delivery-validation.md` §3 in full. Their
thresholds:

| # | Condition | Observed | Threshold | Reps |
|---|---|---|---|---|
| C1 | idle, unplugged, screen off, stationary | `dumpsys activity services` | service present and `isForeground=true` at 100% of samples for ≥ 24 h | 3/3 |
| C2 | as C1 | `/proc/net/tcp6` by app UID and origin port, state `01` | socket present at ≥ 99% of samples, no gap > 10 min | 3/3 |
| C3 | receiver in deep Doze ≥ 60 min | host clock from send mark to `dumpsys notification` | p50 ≤ 30 s, p95 ≤ 120 s; > 1 miss in 20 fails | ≥ 20 sends |
| C4 | ≥ 9 days genuinely unused | bucket, plus C1/C2/C3 | all still hold on day 9 | 1 |
| C5 | reboot | time to service running | ≤ 20 min after first unlock | 3/3 |
| C6 | in-place update | as C5 | ≤ 20 min after first unlock | 3/3 |
| C7 | factory-default vendor settings, step **not** performed | as C1/C2 | C1 and C2 hold | 3/3 |
| C8 | vendor exclusion set, then a manufacturer OTA | exemption list and a photograph | both still set | opportunistic |
| C9 | capability on | `dumpsys notification --noredact`, lock screen | `vis=SECRET`, low importance, nothing on a secure lock screen | 1 |
| C10 | never enabled; enabled then disabled | service, notification, socket, durable row | all absent | 1 each |

Three of these are answers to questions this piece had to decide rather than inherit.
**Intermittent is failure**: a cell passing 2 of 3 runs fails, because a background
capability that works most of the time is one that fails silently, which is the whole
hazard. **The platform behaving while the manufacturer does not is failure**: the gate is
about the phone in a user's hand, not about AOSP. **A single failure closes its own cell
and generalises to nothing** — a Samsung result is not a Xiaomi result and one day is not
the next — but it keeps the gate closed, because the gate wants every cell.

A criterion later found wrong is corrected in the open and its measurements discarded or
marked unusable. It is never kept under a relaxed threshold.

### The matrix

Seven cells: Samsung and Xiaomi crossed with Android 11–12, 13, and 14+, plus a
platform-reference cell with no manufacturer layer. Together the six fleet cells cover
about **79%** of the Android devices this deployment expects — two manufacturers at 90%
combined, crossed with three version bands at 87.5%. The seventh is mandatory and not for
coverage: without a device whose behaviour is the platform's own, a failure cannot be
attributed, and "broken" cannot be told apart from "this manufacturer kills it".

**Every one of the seven is NOT RUN.** Not covered at all: Huawei (~3.7% of the Android
fleet, its own PowerGenie management), Honor, "Unknown", the long tail, and Android 10 and
below (12.49% of version share, and installable at `minSdk` 24).

### The measurement design, and why it is this

**Nothing is added to the application.** No log line, no counter, no diagnostic screen, no
export, no outbound call. This project forbids the application reporting anything about
itself to anybody, and an instrument requiring such a report is an instrument that could
survive into a distributed build. Everything is read instead from the *platform's* own
debug surfaces over adb by `tool/measure_sustained_delivery.sh`: service state from
`dumpsys activity services`, socket state from `/proc/net/tcp6` by UID, freeze state from
`dumpsys activity processes`, Doze from `dumpsys deviceidle`, bucket from
`am get-standby-bucket`, the exemption from `dumpsys deviceidle whitelist`, and the
permanent entry from `dumpsys notification --noredact`. The device therefore runs exactly
the artifact a user would run, and there is nothing to remove afterwards.

**The measuring host is the single time base.** It drives the sender and reads the
receiver, both over adb, so a send mark and the sample that first shows the alert are two
readings of one clock. Device offset is recorded before and after. No time service,
domestic or foreign, is contacted.

**Forced and natural Doze are two arms of one cell, and whether they agree is a result.**
`force-idle` reaches deep idle in seconds and skips light Doze, the inactivity timer and
the motion gate; the natural arm unplugs nothing and only watches. A cell whose arms
disagree has no usable forced result. That is written down before any measurement so that
a convenient forced number cannot later be presented as a natural one.

**An idle device is not a device on a cable.** Runs are unplugged, screen off, stationary,
reached over adb on the local Wi-Fi; `dumpsys battery unplug` is used only in the forced
arm and never in a 24-hour or 9-day run.

### What was actually run, and what stopped the rest

**Two environment probes, both on emulators, and that is all.** No cell of the matrix was
run. Six were blocked by there being no physical Android device of any kind available —
not a Samsung, not a Xiaomi, not a Pixel. The seventh, the platform reference, was
*substituted* with an emulator, and the substitution answers a different question: an
emulator can say whether AOSP behaves as documented; it cannot say whether this service
survives 24 hours on a device with a radio, a carrier NAT and a battery, and it has no
manufacturer to be distinguished from, which is the control cell's entire purpose.

A third blocker sits behind both and would survive the arrival of hardware: the capability
cannot be exercised without an operator-activated account, as above.

### Guarantees, permissions, observations — three different things

**Guaranteed by the platform (as restrictions; measurement cannot disprove them).** "When
an app process is frozen, all of its threads are suspended"; "If all processes for a
particular app are frozen, the system terminates any active TCP sockets maintained by the
app"; "App processes in the cached state are frozen 10 seconds after entering the cached
state", Android 14+ (source.android.com/docs/core/perf/cached-apps-freezer, 2026-06-17).
Network is **Disabled** in the *rare* and *restricted* buckets and **Restricted during
doze** at device level (developer.android.com/topic/performance/power/power-details,
2026-05-19).

**Permitted, never promised.** App state "app process is running a foreground service"
gives Network **"No restrictions"** (same page). `specialUse` carries permission
`FOREGROUND_SERVICE_SPECIAL_USE`, runtime prerequisites **None**, and no timeout — the
6 h/24 h cap is `dataSync` and `mediaProcessing`, `shortService` is tighter
(fgs/service-types and fgs/timeout, both 2026-08-14). "The user turns off battery
optimizations for your app" is an enumerated exemption from the background-start
restriction (fgs/restrictions-bg-start, 2026-08-14). An app is in the *active* bucket
while it "Runs a long running foreground service", and "Apps that are on the Doze exemption
list are exempted from the App Standby Bucket-based restrictions"
(topic/performance/appstandby, 2026-08-14) — both of ADR-051's load-bearing claims here
were re-checked and both hold. Android 17 (API 37) adds no foreground-service or network
change; its background hardening is about audio. It does add "app memory limits based on
the device's total RAM", which is new pressure on a long-lived process and is recorded for
the next re-run.

**Observed here, on two AOSP emulator images, 2026-08-23, one reading each.** Every
observation surface the procedure needs works from an unrooted `user` build:
`dumpsys deviceidle force-idle` reaches deep idle, `am set-standby-bucket` and
`get-standby-bucket` work, `/proc/net/tcp6` is readable by the shell user, and
`dumpsys notification --noredact` and `dumpsys deviceidle whitelist` are both readable. And
one finding that changed the design: **the two images' Doze constants differ by a factor of
thirty** — `inactive_to` 30 m at API 30 against 1 m at API 35, `idle_to` 1 h against 15 m —
and **`use_freezer` is false on the API 30 image and true on the API 35 one**, consistent
with AOSP documenting the ten-second freeze for Android 14 and higher. So the procedure
reads each device's own constants rather than assuming a schedule, and the two Android
11–12 cells now have to answer explicitly whether the mechanism this capability defeats
even exists there.

**Nothing else.** Nothing about Samsung, nothing about Xiaomi, nothing about a real radio,
nothing about battery, nothing about a system update.

### The strongest claim the evidence supports

*On two AOSP emulator images on 2026-08-23, every observation surface this procedure
depends on worked from an unrooted shell, and the two images' Doze constants differed by a
factor of thirty with the cached-apps freezer off on one and on on the other — which
establishes that the procedure is runnable and that its timings must be read per device,
and establishes nothing whatsoever about whether sustained delivery works on any phone.*

### The weakest link

A Xiaomi device on Android 13 or 14 whose owner has not touched the autostart setting.
Roughly a fifth of the fleet on its own; the manufacturer publishes nothing about
foreground services; "Background autostart" is off by default for sideloaded applications;
and this application is sideloaded by definition, because it is never distributed through a
store.

### Decision

**A. The capability is withheld from every build that reaches a user, until the matrix is
run.** `lib/app/config/sustained_delivery_gate.dart` holds a compile-time constant with an
evidence ledger, which is empty. Beta — the artifact ADR-044's people receive — and
production both resolve `withheld`; development resolves `measurementOnly`, so the matrix
can be run at all, including in a release AOT build, which is the only way ADR-051's
outstanding item 7 can ever close.

**B. Withheld is a complete state, and it is fail-closed.** The controller publishes
`SustainedDeliveryStatus.withheld`, never attaches its authentication listener, never
reconciles, and refuses `enable()` before the platform is asked anything — so no
permission is requested, no system dialog appears, no durable choice is written, and the
service is never started. The connection policy therefore answers *no* in every
distributed build and `SyncLifecycleSupervisor` closes its socket on backgrounding exactly
as it did before ADR-051. One positive act: a withheld build **stops** a service an
earlier build may have left running, because a permanent notification must never outlive
the decision to stand behind it. It does not clear the user's durable choice, which is
theirs.

**C. The gate cannot be satisfied by assumption.** Opening it needs seven records, one per
cell, each passing `SustainedDeliveryFieldEvidence.isAdmissible`: `emulated` false,
hardware and platform version as the device reports them, a strict ISO date that survives
a round trip, a committed run record, ≥ 24 holding hours, ≥ 20 timed deliveries, ≥ 3
repetitions. An inadmissible record is not rejected — it may and should be written down —
it simply does not count, so its cell stays outstanding. There is no environment define, no
remote value, no runtime setter and no debug override, and
`test/architecture/sustained_delivery_gate_test.dart` fails if one appears.

**D. A partially satisfied matrix opens nothing**, and every cell is mandatory. A per-cell
release would be a claim about which phone a user has, and this deployment does not know.

**E. `withheld` is its own sentence in both catalogues, not borrowed from `unavailable`.**
"There is nothing behind this" and "there is something behind this and nobody has measured
it" are different facts, and the user is owed the one that is true.

**F. The user-facing latency claim is withdrawn.** "Messages can reach you within seconds
of being sent" becomes a statement of the mechanism plus "How quickly it does on your
phone has not been measured", in both languages, and a test fails on the old phrase.

**G. The procedure is an instrument, not a paragraph.**
`tool/measure_sustained_delivery.sh` has `probe`, `doze`, `watch`, `mark` and `verdict`;
`verdict` prints each threshold beside its result so that a reader is not asked to take the
word PASS on trust. Run records live under `docs/validation/sustained-delivery/`.

### Alternatives evaluated

**1 — Leave ADR-051's amendment standing and ship the capability off-by-default.** Its
argument was that the matrix could not be run here, so the clause would cancel the
capability rather than defer it, and that the permanent indicator cannot lie because the
platform displays it only while the service is genuinely running. The second half is true
and is not the risk. The risk is a user who turns this on, is told what it does, sees the
notification, and is not told about a message for nine hours because their Xiaomi put the
app to sleep — a failure whose entire signature is *absence*, which the design's own
honesty about status cannot surface, because a stopped service reports *stopped* only to
somebody who opens the screen and looks. Rejected: "we cannot measure this" is a reason to
withhold a capability, never a reason to ship it.

**2 — Ship it, but only to users who confirm they have a device the matrix covers.** Needs
the matrix to have been run, which is the thing that has not happened, and needs users to
maintain a setting, which ADR-044 says they do not.

**3 — A runtime flag or a signed configuration switch.** A gate a build flag can open is a
gate that opens on the machine of whoever is in a hurry. Rejected for the reason
`GroupProductionGate` was made source-only.

**4 — Document the gate and enforce nothing.** This is what `platform-android.md` already
did, and the capability shipped anyway. Rejected by its own outcome.

**5 — Write a throwaway probe application with a `specialUse` service and measure that on
the emulator.** It would answer a real question — whether AOSP permits *a* foreground
service to hold *a* socket — and not this one, which is about this application on a
manufacturer's build. It would also produce exactly the green cell this piece exists to
prevent. Rejected; the platform-reference cell is recorded as substituted and unrun
instead.

**6 — Remove the capability entirely.** Premature. Nothing measured says it does not work;
nothing measured says it does. Withholding preserves the work and the honesty at once. If
the matrix is run and fails on Samsung or Xiaomi even when configured, ADR-051's own
revisit condition 3 applies and removal becomes the honest answer.

### Correctness questions, answered

- **Which cells were run?** None. Two emulator probes, neither of which is a cell.
- **What prevented the rest?** No physical device of any kind; and, behind that, no
  operator-activated test account, without which the capability cannot start on any target.
- **What remains unknown for every unrun cell?** Everything the criteria ask: whether the
  service survives a day, whether the socket does, how fast delivery is, whether nine
  unused days end it, whether a reboot restores it, whether the manufacturer kills it with
  and without the vendor step, and whether an update undoes the arrangement.
- **What would it take to know it?** Seven phones, a pair of activated test accounts, and
  about a fortnight of elapsed time running the cells in parallel; three months on one
  device.
- **Where a substitute was used, what does it answer?** The emulator answers whether the
  observation surfaces work and what a given image's Doze constants are. It does not
  answer anything about hardware, radios, batteries, or manufacturers.
- **Which results are measurements?** The six emulator observations above, and only those.
- **Does anything recorded here survive contact with what was measured?** Two fleet
  figures and one user-facing claim do not, and are corrected. ADR-051's platform findings
  were re-checked against the same sources and all hold.
- **What does the gate require?** Section C.

### Security and privacy

- **What the measurement records.** Timestamps, booleans, counts, and the device's own
  build identity, under `docs/validation/sustained-delivery/`. Kept for as long as the
  gate references them, because a ledger row naming a run record that has been deleted is
  a row with nothing behind it.
- **What it may never record.** Message content, conversation, account, username, token,
  key, notification text, server host, IP address. The origin is passed to the harness as a
  port and reduced to a socket *count* before anything is written, so a run record can be
  committed here without disclosing where this deployment lives or who is on it. Runs use
  dedicated test accounts and never a real user's device.
- **Could instrumentation survive into a distributed build?** There is none to survive.
  Nothing was added to the application; the instrument is a shell script under `tool/`,
  which is not compiled, not packaged, and not reachable from any Dart or Kotlin source.
- **Does anything introduce an outbound call?** No. The harness speaks adb to a device on
  the local network and nothing else. No time service, no telemetry, no reporting endpoint.
- **Does the gate itself weaken anything?** It removes a capability from the distributed
  artifact. Everything it touches moves in the fail-closed direction: no service, no
  exemption request, no notification permission request, no held socket.

### Beta and production

**The results apply to nothing, because there are none.** The gate applies to the beta and
production artifacts by the same compiled constant, so it is not a developer-build
convention. Measurement will have to run on a development build, which shares the entire
`main` Android source set — manifest, `SustainedDelivery.kt`, `BackgroundDelivery.kt`,
`MainActivity.kt` — and `minSdk`/`targetSdk`/`compileSdk` with beta, and differs in
application ID, launcher label, signing identity, provisioning prefix and packaged native
crypto profile. A result therefore transfers for the Android platform mechanics and does
**not** transfer for the beta MLS core, the provisioned origin's TLS path, or the frozen
signing identity across an upgrade — and can never measure the beta artifact's *gate*,
only its mechanics, because a build with the gate open is by construction not the build
users get. Nothing about the Beta/Production separation, the two Cargo profiles, the frozen
signing identity or `signingConfig = null` on release is touched, and no production gate is
opened.

### Known limitations of this validation

- The fleet is a country panel statistic, not this deployment's twenty-odd actual phones.
- Statcounter's own series has two months (2026-03, 2026-04) in which Apple's share moves
  by sixteen points; a panel that can do that is not a precision instrument.
- C8 cannot be scheduled and may never be observed. It is also the criterion whose failure
  mode is exactly this deployment's users: people who do not repeat setup and do not notice
  when an update undoes it.
- The four-minute keepalive has still never been measured against an Iranian carrier's NAT.
- Battery and data cost are measured by no criterion here. They should be, and are not,
  because they need hardware too.
- Huawei, Honor and Android 10-and-below are outside the matrix entirely.

### What would change the conclusion

1. Seven devices and an activated test-account pair — then the matrix can be run and the
   gate can open or the capability can be withdrawn on evidence.
2. Enumerating the twenty-odd real devices (F1), which could shrink the matrix to what
   this deployment actually meets.
3. A measured failure on Samsung or Xiaomi *with* the vendor step performed. Then
   near-real-time background delivery is not achievable for this fleet, ADR-051's revisit
   condition 3 fires, and the capability should be removed rather than left withheld.
4. Android changing the `specialUse` contract, the freezer, or the standby-bucket network
   rules.
5. The backend growing a push endpoint, which reopens ADR-046's alternative 6.

### When this must be re-run

The earliest of: **2027-02-23** (six months from the fleet read — Android 16 gained
fourteen points of share in the last twelve); any new Android major version reaching
material share in this country; any change to `specialUse`, the freezer, the standby-bucket
rules, or the Doze-exemption implication for buckets; any change to the capability, its
service type, its keepalive or its reconciliation; or the user base ceasing to be 20–30
known people receiving a written handover.

### Follow-up work

1. **F1** — enumerate the real fleet at handover and replace the panel statistic.
2. Obtain the seven devices and the activated test-account pair, and run the matrix.
3. Add battery and data cost as criteria once hardware exists; ADR-051's follow-up 4 —
   the keepalive interval — depends on them.
4. If the capability is later withdrawn rather than evidenced, the handover disclosure
   moves again, as ADR-051's revisit condition 3 requires.

This decision amends ADR-051's *Beta and production* clause and restores ADR-046's
distribution requirement in an enforced form; corrects two fleet figures and one
user-facing claim; adds no dependency; changes no cryptographic behaviour; touches no
backend file; and opens no production gate.

## ADR-052 in full — making what the application says about itself true (2026-08-23)

**Status:** Accepted. Amends ADR-045, which established the disclosure and built only half
of it. Amends ADR-048's and ADR-049's user-facing claims where later work made them false.
Adds no dependency, changes no feature behaviour, touches no backend file, opens no
production gate. Disclosure revision moves 4 → 5.

### Context

Roughly 20–30 people in Iran receive this application by private handover with written
material. They are not a test audience; some of them may decide what to say, and to whom,
partly on the strength of what this software tells them it does. An overstatement here is
not a documentation nit.

ADR-045 built the disclosure surface and got the hard judgement right: it rejected
periodic re-consent, because repetition of an unchanged warning destroys the attention
paid to it, and made re-acknowledgement content-triggered instead. Three subsequent
pieces moved the statement — ADR-048 added notifications, ADR-049 added background
catch-up, ADR-051 added the opt-in sustained tier — and each raised the revision.

Nothing on the device recorded what any user had accepted. The whole of the obligation to
an existing recipient was step 9 of the release checklist in `deployment-and-release.md`:
re-deliver the written disclosure by hand. No test enforced it, no build gate observed it,
and the running application could not tell that the statement its user agreed to had since
been corrected.

### The problem

Two problems, and the second is the one that is easy to skip.

1. Some of what the application says about itself is not true of the application.
2. People have already been shown, and already accepted, the version being corrected.

### The audit

Ground truth was established from the composed artifact — the code paths that run in the
Private Experimental build — not from this register, not from `docs/`, and not from tests.

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | `disclosureNoIndependentReview` — nobody outside the project has reviewed the encryption | **True** | ADR-017 is a Release gate and is open for every layer. No external review artifact exists in the repository. |
| 2 | `disclosureBestEffortDelivery` — delivery is immediate open, best-effort closed | **True but incomplete** | `BackgroundDelivery.schedule` builds `setPeriodic` at `JobInfo.getMinPeriodMillis()`, `NETWORK_TYPE_ANY`, `setPersisted(true)`; `sustained_delivery_page.dart` exists and `SustainedDelivery.kt` runs a `specialUse` service. Two omissions: Data Saver, which blocks background network on a metered connection and which `NETWORK_TYPE_ANY` cannot ask around; and the fact that a reader takes "slow" to mean "eventual". |
| 3 | *(new)* messages expire on the server unread | **Was not disclosed at all** | `backend/messaging/API.md`: "Undelivered envelopes are pruned after `ENVELOPE_TTL_DAYS` (default 7)". The client never learns the operator's value. `drift_sync_store.dart` records the gap as `queueGapState`; `drift_group_repository.dart` overlays it onto groups; `SyncProjection.isSecurityBlocked` has **no consumer at all**, so a one-to-one gap is surfaced nowhere. |
| 4 | `disclosureDeviceOnlyHistory` — stored only on this phone, no server copy, no backup | **True, one sentence catchable** | `allowBackup="false"` and `fullBackupContent="false"` in the manifest; the database key is a non-exportable Keystore key. But the mailbox *does* hold ciphertext in transit, so "the server keeps no copy" was narrowed to "no copy of your history". |
| 5 | `disclosureRecoveryExcludesHistory` | **True** | ADR-030 identity-only backup; ADR-028 device-to-device history transfer. |
| 6 | `disclosureExperimentalGroups` | **True** | `GroupProductionGate.privateExperimentalPermit` is granted to `AppEnvironment.beta`, which composes `NativeBetaGroupMls`; ADR-036 makes the state disposable. |
| 7 | `disclosureUnbuiltSurfaces` — "voice rooms, search and file attachments do nothing" | **False in part** | Voice rooms: `StructuralPlaceholderPage`, correct. Attachments: `AttachmentSheet._pickerAvailable` is false in every composition root, correct. Profile: `ProfilePublishing.notBuilt`, correct. **Search is built**: `chat_pages.dart` filters the list on `item.title`/`item.preview`, and the in-conversation sheet filters `widget.model.messages`, which `watchMessages` loads without a `LIMIT` — the whole of that conversation's local history. |
| 8 | `disclosureIntendedUse` | **True**, and correctly conservative | A judgement, and the conservative one. |
| 9 | `enrollmentProtectsBody` — "messages, files, and voice audio" unreadable to the server | **Misleading** | Permanent section. Two of the three named capabilities do not exist in the artifact carrying the sentence. |
| 10 | `enrollmentDoesNotProtectBody` | **True, undecodable** | Accurate about metadata, but says "social graph", "out of band" and "compare fingerprints" while the screen it points at is `safetyTitle` — *Safety number*. A limitation the reader cannot act on has not been disclosed. |
| 11 | `settingsNotificationsOn` — "can only reach you while this app is running" | **False** | `deferred_delivery_catch_up.dart:_reconcileAlerts` and `sustained_delivery_run.dart:_SustainedAlertReconciler` both post alerts with `BackgroundVisibleConversation` — no activity, no foreground. Written at ADR-048 and never edited since, through two revisions that invalidated it. |
| 12 | `chatsSearchHint` — "Search chats and messages on this device" | **Over-promising** | The box matches title and last-message preview only. Typing a word from an older message finds nothing. `chatsDeviceSearchScopeNotice` was rendered beneath it, promising this device's history. |
| 13 | `voiceRoomsPlaceholderBody`, `attachmentsNotBuiltNotice`, `profileNotBuiltNotice`, `groupExperimentalBanner`, `sustainedWhatItDoes` / `Costs` / `CannotPromise` | **True** | Verified against the placeholder router entries, `AttachmentSheet`, `ProfilePublishing`, the beta permit, and `SustainedDelivery.kt` — including `VISIBILITY_SECRET`, which is what makes "It is hidden on the lock screen" true. |

Found outside the expected subject:

- **`SyncProjection.isSecurityBlocked` is dead code.** A one-to-one mailbox gap is detected
  and recorded and then never shown to anyone. Groups get `groupQueueGapState`; direct
  conversations get silence. This is a *product* gap and is out of scope for a piece that
  may not change feature behaviour, so the corrected text discloses the silence instead of
  removing it, and it is recorded as follow-up.
- **`chatsPinViaMessageNotice`** existed in both catalogues, was rendered nowhere, and said
  "unavailable in the current local schema" — internal vocabulary in a user-facing string.
  Deleted.
- **Language parity was not enforced.** Three tests each pinned their own feature's key
  list. A key added to `app_en.arb` alone passed every gate in the repository, and the
  right-to-left half of the audience would have seen English.
- **The written handover material is stale.** `deployment-and-release.md` step 8 says "the
  same seven facts" and then lists six, omitting the unbuilt surfaces; it never mentioned
  ADR-051's opt-in tier; and it states a Data Saver limit the application did not.

### What the repository said before, and why it was wrong

`deployment_disclosure.dart` said the revision "exists to make re-acknowledgement
*content-triggered* — when what the build promises changes, the revision changes, every
later enrollment reads the new text, and re-delivering the written handover disclosure to
existing recipients becomes release-blocking". Every clause of that is true and the whole
is misleading: "every later enrollment" is every *new* device, and an existing recipient
enrolls exactly once. For them the sentence describes a manual step, not a mechanism.

`deployment-and-release.md` step 9 made the manual step explicit and honest — "their
install will not re-show the notice; that is the deliberate rejection of periodic
re-acknowledgement recorded in ADR-045, and this step is what pays for it". It does not
pay for it. It is unenforced by anything, and it had already gone stale.

### Research

Read 2026-08-23 unless stated.

**Warnings and repetition.** Vance, Jenkins, Anderson, Bjornn and Kirwan, "Tuning Out
Security Warnings: A Longitudinal Examination of Habituation Through fMRI, Eye Tracking,
and Field Experiments", *MIS Quarterly* 42(2):355–380, 2018
(<https://scholarsarchive.byu.edu/facpub/6495>): attention to a repeated warning declines
across days with only partial overnight recovery; polymorphic warnings — ones that change
appearance — kept adherence high at three weeks where standard warnings did not, confirmed
in a three-week field study of mobile permission warnings. This is the evidence ADR-045
relied on and it still holds: do not repeat an unchanged warning.

**Generalisation to other warnings.** Vance, Eargle, Kirwan, Anderson and Jenkins, "The Fog
of Warnings: How Non-Security-Related Notifications Diminish the Efficacy of Security
Warnings", *MIS Quarterly* 49(4):1357–1384, 2025
(<https://vtechworks.lib.vt.edu/bitstreams/e17e21c2-fc39-45b8-9de4-04096a414ee5/download>):
habituation to routine notifications *transfers* to security warnings the user has never
seen, and the mitigations that worked were visual differentiation and a changed mode of
interaction. This is newer than ADR-045 and it is decisive for this application, which
since ADR-048 posts message alerts and since ADR-051 can post a permanent service notice.
A correction delivered as a banner or a notification would arrive pre-ignored.

**Consent dialogs.** Böhme and Köpsell, "Trained to Accept? A Field Experiment on Consent
Dialogs", *CHI 2010*, 2403–2406, doi:10.1145/1753326.1753689: across 80,000 users, the
more a dialog's presentation resembled a EULA the more blindly it was accepted. Read as: do
not pad, do not format this like terms, keep it short enough to be read.

**Reading level.** W3C WCAG 2.2, SC 3.1.5 Reading Level (AAA) (<https://www.w3.org/TR/WCAG22/>):
text should not require reading ability beyond lower secondary education, which the
glossary defines against ISCED as roughly nine years of schooling. Taken as the target for
every corrected string.

**Platform facts the corrected text asserts.** All from official Android documentation:

- Fifteen-minute floor: `PeriodicWorkRequest` — "Periodic work has a minimum interval of 15
  minutes" (<https://developer.android.com/reference/androidx/work/PeriodicWorkRequest>);
  `JobInfo.getMinPeriodMillis()` is the framework equivalent this application clamps to
  (<https://developer.android.com/reference/android/app/job/JobInfo>).
- No network in the *rare* and *restricted* buckets, and Doze deferral to maintenance
  windows: the power-management limits table
  (<https://developer.android.com/topic/performance/power/power-details>), which lists
  Network as **Disabled** for both buckets and jobs "deferred to doze maintenance window"
  while the screen is off. The same table records that a job's network is "Unrestricted
  unless device is in data saver mode" — the basis for the Data Saver clause.
- Data Saver: "the system blocks background data usage" when enabled and the device is on a
  metered network (<https://developer.android.com/develop/connectivity/network-ops/data-saver>).
- Force-stop: an app in `FLAG_STOPPED` stays there "until the user explicitly removes the
  app from this state by directly launching the app", and Android 15 cancels its pending
  intents (<https://developer.android.com/about/versions/15/behavior-changes-all>). Note
  the distinction the corrected text does **not** need to make: the Task Manager *Stop*
  button is a different action, after which "Scheduled jobs execute at their scheduled
  time"
  (<https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping>).
- `specialUse` carries no timeout: the six-hour-in-twenty-four limit introduced in Android
  15 applies to `dataSync` and `mediaProcessing` only
  (<https://developer.android.com/about/versions/15/behavior-changes-15>). This confirms
  ADR-051's claim rather than changing it.

The application's supported range is `minSdk` 24 to `targetSdk` 36 (Flutter 3.44.7
defaults), so App Standby Buckets (API 28+), Data Saver (API 24+) and the runtime
notification permission (API 33+) are each true for part of that range — which is why the
text describes the *behaviour the user sees* and never an API level.

**Not obtainable.** The ACM Digital Library and the MIS Quarterly article pages are behind
an anti-bot wall from this workstation; the two MIS Quarterly papers were traced instead to
the authors' institutional repositories, which carry the full text. No load-bearing claim
rests on a source that could not be read in full.

### Alternatives considered

**For reaching people who accepted an older statement**

1. *Keep the written re-delivery as the only remedy* — the status quo. Rejected: it is
   unenforced by anything in software, it had already gone stale in the very document that
   defines it, and it reaches only people the operator successfully contacts. Kept
   **in addition**, because it is the only thing that reaches somebody who has not
   installed the update.
2. *Re-present on a timer* — rejected on Vance et al. 2018, and rejected again on Vance et
   al. 2025, which makes the collateral damage worse than ADR-045 knew: it would degrade
   the messaging-withheld states as well as itself.
3. *Re-present as a banner or a notification* — rejected on Vance et al. 2025. Both are the
   surfaces this application has trained the reader to dismiss.
4. *Re-present the whole statement with no indication of what moved* — rejected. It is
   truthful but it makes the reader re-derive the delta, and the polymorphism finding says
   the visible change is precisely what restores attention.
5. *Show a written diff of the previous and current text* — rejected. It requires keeping
   every superseded string in the catalogue and translated, which rots by default and which
   nothing could hold true.
6. **Chosen:** a full-screen, blocking, one-time re-presentation of the single shared
   statement, with the moved points marked by a labelled badge. Differentiated by surface
   and by interaction; costs nothing to a current user; verifiable by test.

**For the record of what was accepted**

1. *Server-side* — rejected outright. The server is an untrusted relay, has no such
   endpoint, and would learn who read a warning and when.
2. *Extend the enrollment journal* — rejected: `_complete` deletes the `enrollment_intents`
   row, by design, so the record would not survive the moment it describes.
3. *A timestamped acceptance log* — rejected. Nothing reads a time, and a record of when a
   person read a warning is a record about that person.
4. **Chosen:** one integer in the existing encrypted `local_preferences` table, never
   lowered, never deleted.

**For the revision itself**

1. *Keep it a hand-edited constant with a pinning test* — rejected. That is what existed,
   and three revisions shipped where the test was updated in the same edit as the string,
   which is exactly the motion that skips the thought.
2. **Chosen:** derive it. Each point carries its own `since`; the revision must equal the
   maximum; the pinning test fails on any edit. The edit forces the `since`, the `since`
   forces the revision.

**For the wording**

1. *Name the retention window ("about a week")* — rejected. `ENVELOPE_TTL_DAYS` is an
   operator setting the client is never told, so a number would be a reassurance the
   application cannot verify. The text says "after a time set by whoever runs the server",
   which is true at any setting.
2. *Keep the feature list in the permanent section and prune it as features land* —
   rejected. It goes stale by default and it went stale unnoticed for the whole life of
   ADR-045. The section now describes the boundary; a test forbids feature words in it.
3. *Add "appearance" to the unbuilt list* — rejected. `/settings/appearance` is a
   not-built placeholder and is badged as one where the user meets it. Adding a
   non-safety item to a seven-item safety list is the padding Böhme and Köpsell measured.

### The corrected statements

- **`disclosureBestEffortDelivery`** gains Data Saver. Unchanged otherwise.
- **`disclosureMessagesExpireUnread`** (new): "A message waits on the server only until
  your phone collects it. After a time set by whoever runs the server, whatever is still
  waiting is deleted and never arrives, and you will not be told which messages those were.
  If you go a long time without opening the app, assume you have missed some."
- **`disclosureDeviceOnlyHistory`**: "keeps no copy" → "keeps no copy of your history".
- **`disclosureUnbuiltSurfaces`**: "search" removed.
- **`enrollmentProtectsBody`**: "Everything you write is encrypted on this phone before it
  leaves it. The server, anyone watching the network, and anyone who takes the server can
  see that you are using this app, but not what you wrote."
- **`enrollmentDoesNotProtectBody`**: rewritten into the reader's vocabulary and pointed at
  the *Safety number* screen by that name.
- **`settingsNotificationsOn`**: "It can reach you while the app is closed, but only when
  your phone next lets the app look for messages."
- **`chatsSearchHint`** → "Search names and the latest message"; **`chatsListSearchScopeNotice`**
  (new) states the list's real scope and points at the in-conversation search.
- **`disclosureChangedTitle` / `Lead` / `Label`** (new) carry the re-presentation.

All present and complete in `app_en.arb` and `app_fa.arb`.

### What this application now guarantees

- **Guaranteed.** Message text is encrypted on the device before it leaves; the server
  cannot read it. Local history is on the device only, and uninstalling destroys it. A
  build that carries no disclosure cannot render one.
- **Usually happens, not guaranteed.** Delivery while the application is open. Delivery
  while it is closed, at any tier including the opt-in one. Any alert reaching the user.
- **Does not happen at all.** Voice rooms. File attachments. Publishing a display name or
  photo. Independent review of the cryptography. Any server-side history, backup or
  recovery of messages. Any notification that a one-to-one message expired unread.

### Security and privacy

The corrected text reveals nothing new about the deployment, the operator or the users.
"A time set by whoever runs the server" discloses that an operator exists and sets a
retention window, which the disclosure already implied by calling the server a relay the
user's history is not on; it names no host, no value and no person.

The acceptance record is one small integer in the encrypted preference table behind the
non-exportable Keystore-wrapped database key. It carries no timestamp and no identifier, is
never transmitted, and the server has no endpoint that could receive it. It is strictly
less sensitive than the sustained-delivery flag beside it, which reveals an arrangement the
user made with their phone.

Telling users more precisely what is not protected reduces exposure rather than increasing
it: every corrected claim moves in the conservative direction, and the two additions
(expiry, Data Saver) tell a reader when *not* to rely on the application.

### Known limitations

- **No test in this repository can establish that a reader understands the result.** The
  tests pin the words, the languages, the surfaces and the mechanism. Comprehension would
  need a study with people from the actual audience, in Persian, which has not been done.
- The Persian text has not been reviewed by a second Persian speaker. It is complete,
  non-empty, distinct from the English, right-to-left, and does not overflow at 160% text
  scale — none of which is review.
- The gate has been exercised in widget tests and on no device. What it looks like on a
  real phone is a release check, not a claim.
- A user who never installs the update is reached only by the written re-delivery.

### Follow-up

1. Surface a one-to-one mailbox gap. `SyncProjection.isSecurityBlocked` exists, is correct,
   and has no consumer. Until it does, the disclosure has to say the loss is unannounced.
   This is feature work and was deliberately not done here.
2. Have the Persian reviewed by a second speaker before the next handover.
3. Photograph the re-presentation gate on a device in both languages as part of the
   ADR-051 device matrix.
4. If `ENVELOPE_TTL_DAYS` is ever raised or lowered materially by the operator, re-read
   whether "a long time" is still the right phrase.

### Revisit when

- Any point's wording moves — the mechanism forces the revision, but the *decision* to move
  it still belongs here.
- Attachments, voice, or profile publishing land: `disclosureUnbuiltSurfaces` must shrink,
  and the permanent section must still name no feature.
- ADR-017 closes: `disclosureNoIndependentReview` becomes false in the user's favour and
  must be corrected with the same rigour as a false claim in the other direction.
- The audience grows past private handover, at which point the written re-delivery stops
  being a workable remedy and the in-application mechanism becomes the only one.

## ADR-051 in full — receiving while the application is not in use (2026-08-22)

**Amended 2026-08-23 by [ADR-053](#adr-053-in-full--whether-receiving-while-the-application-is-not-in-use-actually-works-2026-08-23):**
the *Beta and production* clause below is superseded. ADR-046's distribution requirement
is restored in an enforced form — a compile-time gate with an empty evidence ledger — and
the capability is withheld from the beta and production artifacts until the matrix in
*Outstanding validation* has actually been run. ADR-053 also corrects two fleet figures
used below (Samsung and Xiaomi are ~90% of the *Android* fleet, not 77% of all mobile;
Android 13-or-earlier is 60%, not "roughly half") and withdraws the "within seconds"
delivery sentence this decision shipped. Everything else here stands, and its platform
findings were re-checked against the same sources on 2026-08-23 and all hold.

**Status:** Accepted. Builds ADR-046's Layer 2 and closes its follow-up step 5, on
re-derived evidence rather than by inheritance. Amends ADR-046's distribution clause and
ADR-045's delivery disclosure, which moves to revision 4. Extends ADR-050's ownership
arbitration to the third owner it named. Adds no dependency, changes no cryptographic
behaviour, touches no backend, opens no production gate.

### The question

> A user wants to be told about messages soon after they arrive, without having the
> application open. What does Android actually make possible for that, what does it cost
> them in visibility, battery, permissions and effort, what does it demand of their
> particular phone, how much survives a restart, an update and a manufacturer's own
> decisions — and is the best available version of it worth building at all?

Nothing was assumed: not the mechanism, not the service type, not the permissions, not
where the user's choice lives, not the shape of the surface that asks for it, not any
dependency, and not that ADR-046's sketch was right. The alternative of building nothing
was evaluated on the same footing as the rest.

### Exact environment, fixed

Unchanged from ADR-044, ADR-049 and ADR-050. 20–30 known users, all in Iran, private
handover with written instructions, international connectivity possibly absent while
domestic connectivity reaches the backend, no foreign runtime dependency at any layer, an
Android/Flutter client installed as a directly signed artifact, and a server that is an
untrusted relay for end-to-end encrypted content. `minSdk` 24, `targetSdk` 36,
`compileSdk` 36, Flutter 3.44.7 / Dart 3.12.2.

Fleet, from ADR-046 and unchanged: Samsung 46.34% and Xiaomi 30.98% of Android devices in
Iran, and every release from Android 11 to 16 materially represented. Android 17 (API 37)
now exists and its behaviour changes were read for this decision.

### What the repository actually did before

Layers 0, 1 and 3 ship. `MessageDeliveryController` composes one `MessageDeliverySession`
per device-bound full session (ADR-047); a persisted periodic `JobScheduler` job catches up
when nobody is looking (ADR-049); one sender-neutral alert is reconciled from committed
local state (ADR-048); and exactly one part of the process drives delivery at a time
(ADR-050). Layer 2 was specified in ADR-046 in one paragraph and never built.

Three things in the composed artifact bear directly on this piece, and all three were
verified by trace rather than by documentation:

- `SyncLifecycleSupervisor._canUseRealtime` required
  `_lifecycle.current == ApplicationExecutionState.foreground`, and `_enterBackground`
  closed the socket unconditionally. Backgrounding therefore *always* gave up the
  connection, which was correct while nothing kept the process alive and is exactly the
  line this piece has to move.
- `PlatformSocketConnector` passed no `pingInterval`, so a held connection had **no
  keepalive at all**. That is harmless for a foreground socket and disqualifying for one
  held for hours: a connection a carrier's NAT has dropped is not closed, it is never
  heard from again, and the application would have gone on believing it was connected.
- `BackgroundDelivery` arbitrated exactly two owners. ADR-050's follow-up step 3 said in
  terms that a third owner requires the arbitration to be re-derived, not extended by
  assumption.

Two documentation statements this piece makes untrue, both corrected here:
`platform-android.md` said Layer 2 was unbuilt and that background delivery was therefore
"*eventual* and never near-real-time"; ADR-045's disclosure described the deferred
catch-up as the whole of what happens while the application is closed.

### Research findings

Primary sources only, all read 2026-08-22 unless stated. Blogs, forums and generated
summaries were used for discovery and are cited nowhere.

**Every mechanism that runs while the user is not using the application**, and why each
does or does not survive this piece's constraints. This is the same table ADR-049 built,
re-derived with the *opposite* scope: ADR-049 excluded everything the user must grant,
which is exactly what this layer is allowed to ask for.

| Mechanism | What it needs from the user | Verdict here |
|---|---|---|
| Periodic `JobScheduler` job | nothing | already built; kept as the floor beneath this |
| Foreground service, `specialUse` type | battery exemption, notifications, per-vendor setup | **selected** |
| Foreground service, `dataSync` | same | disqualified by the platform, below |
| Foreground service, `remoteMessaging` | same | accurate for something else, below |
| Foreground service, `systemExempted` | a role this app does not have | throws `ForegroundServiceTypeNotAllowedException` |
| `setExactAndAllowWhileIdle` | `SCHEDULE_EXACT_ALARM`, revocable | rejected, below |
| `setAndAllowWhileIdle` | nothing | rejected by ADR-049 on evidence; nothing has changed |
| Platform push (FCM) | nothing | excluded by ADR-013 and unreachable in the outage this deployment exists for |
| UnifiedPush / self-hosted distributor | a second app, a second service | rejected by ADR-046; the backend still has no push endpoint and this piece may not change it |
| SMS wake | a phone number and an SMS permission | rejected outright by ADR-046 on the threat model |

**A foreground service is the one documented way to keep both the process and the
network.** AOSP's cached-apps freezer states that "when an app process is frozen, all of
its threads are suspended", and that "if all processes for a particular app are frozen,
the system terminates any active TCP sockets maintained by the app"
(source.android.com/docs/core/perf/cached-apps-freezer). Android 14's own behaviour notes
define a cached process as one "moved to the background" with "no other app process
components … running", so a process with a running service component is not cached. The
power-management table gives, for the app state "app process is running a foreground
service", **"Network: No restrictions"**
(developer.android.com/topic/performance/power/power-details).

**But the service alone does not defeat Doze, and the exemption does more than expected.**
The same table gives, for the device state "screen off and doze is active", network access
"restricted during doze". The Doze page states that an app that is partially exempt "can
use the network and hold partial wake locks during Doze and App Standby"
(developer.android.com/training/monitoring-device-state/doze-standby, page last updated
2026-08-18). Two further facts were found that neither ADR-046 nor ADR-049 recorded and
that materially change this decision's arithmetic:

- **"Apps that are on the Doze exemption list are exempted from the App Standby
  Bucket-based restrictions"** (developer.android.com/topic/performance/appstandby). The
  *rare* and *restricted* buckets — where background network is disabled entirely, and
  where Android 13+ puts an app after eight days without interaction — are the hard
  ceiling ADR-049 named for the mandatory floor. The exemption removes them. Enabling this
  capability therefore repairs Layer 1 for the same user, not just adds a layer above it.
- **"An app is in the *active* bucket while it is used, is very recently used, or when it
  does any of the following: … Runs a long running foreground service"** (same page). The
  service is self-reinforcing for the bucket in its own right.

**Android sanctions asking for the exemption, for this application specifically.** The
Doze page's acceptable-use table lists "instant messaging, chat, or calling app; enterprise
VOIP apps" with "no, can't use FCM because of technical dependency on another messaging
service or Doze and App Standby break the core function of the app" and rates the exemption
**Acceptable**. The row immediately above rates it *Not Acceptable* for an app that *can*
use FCM — so it is the impossibility of FCM in this deployment that makes asking legitimate,
and that impossibility is a premise of the whole project (ADR-013). Using
`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` requires holding
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, and `PowerManager.isIgnoringBatteryOptimizations()`
reports the result (developer.android.com/reference/android/provider/Settings). The
attached Play-policy sentence does not reach an artifact that is never submitted to Play;
the technical grant does.

**`specialUse` is unrestricted, and still is at Android 17.** The service-types page gives
`specialUse`: permission `FOREGROUND_SERVICE_SPECIAL_USE`, **runtime prerequisites None**,
"covers any valid foreground service use cases that aren't covered by the other foreground
service types", and a mandatory `<property>` naming
`android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE` whose values "are reviewed when you submit
your app in the Google Play Console"
(developer.android.com/develop/background-work/services/fgs/service-types). The
foreground-service timeout page states the six-hour cap applies to `dataSync` and
`mediaProcessing` only
(developer.android.com/develop/background-work/services/fgs/timeout). Android 15's
`BOOT_COMPLETED` prohibition lists `dataSync`, `camera`, `mediaPlayback`, `phoneCall`,
`mediaProjection` and `microphone` — not `specialUse`
(developer.android.com/about/versions/15/behavior-changes-15). The consolidated "changes to
foreground services" page (last updated 2026-08-14) lists nothing new for Android 16 or 17
that reaches this type, and Android 17's own behaviour-changes pages add only background
*audio* hardening
(developer.android.com/develop/background-work/services/fgs/changes,
developer.android.com/about/versions/17/behavior-changes-all).

**Starting it from the background is permitted in exactly the cases this design has.** The
enumerated exemptions include "your app transitions from a user-visible state, such as an
activity", receiving `ACTION_BOOT_COMPLETED`, `ACTION_LOCKED_BOOT_COMPLETED` or
`ACTION_MY_PACKAGE_REPLACED` in a receiver, and — decisively — "the user turns off battery
optimizations for your app"
(developer.android.com/develop/background-work/services/fgs/restrictions-bg-start). The
exemption this capability requires is itself the background-start exemption, which is why
no boot receiver is needed and none is declared.

**What the entry costs in visibility, exactly.** "Apps don't need to request the
`POST_NOTIFICATIONS` permission in order to launch a foreground service. However, apps must
include a notification when they start a foreground service." If the user denies
notifications, "they still see notices related to foreground services in the Task Manager
but don't see them in the notification drawer"
(developer.android.com/develop/ui/views/notifications/notification-permission). Android 13
added that Task Manager — "users can complete a workflow from the notification drawer to
stop apps that have ongoing foreground services" — and made foreground-service
notifications user-dismissible by default
(developer.android.com/about/versions/13/behavior-changes-all). So the *existence* of the
service is visible on any unlocked phone whatever this application does, and the platform
gives the user a first-class control to end it.

**What can be done about that visibility.** `IMPORTANCE_LOW` "shows in the shade, and
potentially in the status bar (see `shouldHideSilentStatusBarIcons()`), but is not audibly
intrusive"; `IMPORTANCE_MIN` is documented as wrong here — "this should not be used with
`Service.startForeground` … the system will show a higher-priority notification about your
app running in the background". `VISIBILITY_SECRET`: "do not reveal any part of this
notification on a secure lockscreen or while screen sharing"
(developer.android.com/reference/android/app/NotificationManager,
developer.android.com/reference/android/app/Notification).

**Android 16 taxes jobs that run beside a foreground service.** "Jobs that are executing
concurrently with a foreground service will adhere to the job runtime quota"
(developer.android.com/about/versions/16/behavior-changes-all). This is a cost of keeping
the floor armed underneath, and it is accepted: the floor's whole purpose is to be there
when the service is not.

**Vendor behaviour, from the vendors, not from community reporting.** ADR-046 recorded the
OEM half as "community documentation … not normative evidence" and left it unmeasured.
First-party sources exist and were read for this decision.

- **Samsung** (developer.samsung.com/mobile/app-management.html): "background applications
  that have not been used for about 3 days and causing poor system health (ex. battery
  consumption) will go into the sleeping mode. A bucket restriction applies to any sleeping
  applications, and features such as **Job, Alarm, and Foreground-service are restricted**."
  Apps unused "for a long period of time (currently set to 16 days …)" go into *deep
  sleeping* and "only become active when the user opens them". The user's exception path is
  documented — Settings > Device care > Battery > Background usage limits — as is a
  deep-link intent to it: `com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY` on
  package `com.samsung.android.lool` with `activity_type` 2 for "never sleeping apps". And
  the page states that "since One UI 6.0, foreground services of apps targeting Android 14
  will be guaranteed to work as intended so long as they are developed according to
  Android's new foreground service API policy."
- **Xiaomi** (mi.com global support, e.g. KA-492576): a per-app "Background autostart"
  permission at Settings > Apps > Permissions > Background autostart, with Xiaomi's own
  advice to "be cautious not to disable the Background autostart feature for … APPs that
  you rely on for notifications". No developer-facing statement about foreground services
  was found on a Xiaomi property, and none is invented here.

This is better evidence than ADR-046 had and it is still not measurement. Samsung's
sentence is a vendor's statement of intent about One UI 6.0 and above; it says nothing
about One UI 5.x, which is what a Samsung device on Android 13 or earlier runs, and Android
13 and earlier is roughly half of this fleet by version share. Xiaomi has said nothing
about foreground services at all. **The manufacturer half remains unresolved and is treated
as unresolved.**

**Backend, read-only.** `backend/realtime/API.md` documents no server-side heartbeat, no
idle timeout and no ping frame; close 4001 means refresh and reconnect, 4003 means the
device is revoked. Nothing was changed and nothing was needed.

**Dependencies.** None added. `flutter_foreground_task` 11.0.1 exists and needs no Firebase,
and was still rejected: it would put a second foreground service, its own notification
policy and its own boot receiver into an audited manifest to do what forty lines of Kotlin
do, and the two things this piece must be able to prove — the declared type is accurate,
and the entry reveals as little as a foreground service can — would move into a dependency
this project does not review. `androidx.core:core`, already declared for `FileProvider`,
supplies `ServiceCompat`, `NotificationCompat` and `NotificationChannelCompat`.

### Alternatives evaluated

**1 — Build nothing, and say so.** The brief's explicit permission, and the option this
decision took most seriously. It costs the user nothing: no permission, no battery, no
permanent entry, no per-vendor setup, and no possibility of a capability that quietly fails
while a notice on the phone implies otherwise. What it costs is the whole question: a
backgrounded user is told about a message within fifteen minutes *at best*, in practice at
Doze's maintenance-window cadence, and after eight unopened days not at all.

Rejected, on three findings. First, the mechanism is real and documented rather than
speculative: a foreground service is what Android itself names as the app state with
unrestricted network, and `specialUse` carries no timeout, no runtime prerequisite and no
boot restriction at every release from 24 to 37. Second, the exemption is *sanctioned* for
this exact application by Android's own table, and — newly established here — it removes
the standby-bucket restrictions that are the floor's hard ceiling, so enabling this makes
even the fallback better. Third, and decisively for the brief's own test, the failure mode
this option exists to prevent is avoidable by construction: the permanent entry is
displayed by the platform *only while the service is actually running*, the application
re-reads every precondition every time it is resumed, and it stops the service and says so
whenever the arrangement is incomplete. The indicator cannot claim what is not true,
because the thing that displays it is the thing it is claiming.

Revisit conditions are recorded below; finding 4 in particular would bring this option back.

**2 — `dataSync` instead of `specialUse`.** Rejected by the platform, not by preference:
six hours per twenty-four with `Service.onTimeout()` and a `RemoteServiceException` for
overrunning, and forbidden from a `BOOT_COMPLETED` receiver at `targetSdk` 35+. A
capability that stops after six hours and cannot restart itself is not this capability.

**3 — `remoteMessaging`.** Technically unrestricted and semantically wrong: the type
documents "transfer text messages from one device to another … continuity of a user's
messaging tasks when they switch devices", which is not holding a connection to the user's
own server. ADR-046 forbade reaching for it to dodge lifecycle policy and this decision
re-derives that rather than inheriting it. The architecture test that pins the prohibition
is unchanged in substance.

**4 — Exact alarms (`setExactAndAllowWhileIdle`).** Rejected again, on ADR-049's evidence
plus one this layer adds: `SCHEDULE_EXACT_ALARM` is revocable, and on revocation "your app
stops, and all future exact alarms are canceled" — a capability whose failure mode is
*silent permanent cessation* is the worst possible shape for something a user has been told
to rely on. `USE_EXACT_ALARM` requires an alarm-clock or calendar core function this
application does not have, and using it would be the kind of inaccurate declaration this
decision exists to avoid.

**5 — A foreground service that polls on a timer instead of holding a connection.** Same
permission cost, same permanent entry, same vendor exposure, and strictly worse timeliness
and battery: every poll is a full TLS handshake to a private CA plus a drain, where a held
socket is one connection and a four-minute ping. Rejected.

**6 — Hold the connection in the activity's isolate and keep only the service alive.**
Attractive because it needs no third owner. Rejected: `FlutterActivity` destroys its engine
when the activity is destroyed, and the user swiping the application out of Recents does
exactly that — so the case this capability exists for is the case where that isolate does
not exist.

**7 — A boot receiver, to restart it after a restart.** Rejected on the first
non-negotiable property. The choice lives in the SQLCipher-encrypted database, so a Kotlin
receiver cannot read it; the alternatives are to start the service unconditionally and stop
it once Dart says so — which shows a permanent entry at every boot to people who chose
nothing — or to move the choice into a plaintext preference, which puts a fact about its
owner outside the one place this application keeps such facts. Restarting is done by the
already-persisted periodic job instead, which needs no new permission and no new component,
and whose cost is a bounded delay that is disclosed.

**8 — A maintained plugin.** Rejected, above.

### Decision

**An opt-in capability, off by default, that keeps this process out of the cached state so
the delivery path this application already has can keep its connection while nobody is
looking — and that reports, in the user's own terms, every condition under which it is not
doing so.**

**A. What it is.** A `specialUse` foreground service, `exported="false"`, declaring
`android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE` with the actual justification in prose. The
service holds no data, opens no connection and makes no decision; it exists so that this
process has a running component, because a process with one is not cached, and a process
that is not cached does not have its sockets terminated. Everything that decides *what* to
do is the Dart isolate it hosts.

**B. What changes in the delivery path, and it is one thing.**
`SyncLifecycleSupervisor` gains a `BackgroundConnectionPolicy` port. It answers *no* by
default — `NeverHoldsInBackground` — which is every composition until somebody turns this
on, and the supervisor behaves exactly as it did. It answers *yes* only while the whole
arrangement is genuinely in place, and then `_canUseRealtime` permits a backgrounded
connection. The policy is a port and not a flag because the answer changes underneath a
running session, and a supervisor already backgrounded would otherwise never re-evaluate.

**C. Three owners, arbitrated where ADR-050 put the arbitration.** `BackgroundDelivery`
now ranks the activity's isolate, the service's isolate and a deferred catch-up's, on the
one main looper all three are delivered on. Attaching a foreground engine asks the
sustained run to stand down through the same latched handshake the catch-up uses, and the
service keeps running while its isolate gives way. A deferred tick goes to whichever owner
already exists. `awaitExclusiveOwnership` waits for both. Nothing durable records any of
it, so process death releases all of it at once — ADR-050's argument, unchanged and now
covering three owners instead of two.

**D. The connection proves it is alive.** `SocketConnector.connect` gains an optional
`keepAlive`, null everywhere except a sustained run, which passes four minutes. `dart:io`
pings at that interval and closes the connection as `goingAway` when a ping goes
unanswered, so a socket a carrier's NAT silently dropped becomes a close the supervisor
reconnects from — instead of an open handle nothing will ever hear from again, displayed
under a notice saying the application is kept open.

**E. The choice is durable, encrypted, and deleted rather than falsified.** One row in
`local_preferences`, the same SQLCipher-encrypted table every other durable preference uses.
Turning the capability off deletes the row, so an installation that never enabled it and one
that enabled and disabled it are indistinguishable on disk.

**F. Enabling is one flow, in one order, with the user present.** Notifications first —
because a connection held for messages nobody is told about is battery spent for nothing,
and because asking the harder question first spends the user's attention on the wrong one.
Then the exemption, through Android's own dialog, whose answer is read back from
`isIgnoringBatteryOptimizations()` rather than from the dialog, which reports refusal and
dismissal identically. Then the durable choice. Then the service. Every exit that is not
success leaves the application exactly as it found it, and a service that will not start
withdraws the choice again rather than leaving a later launch to retry silently what the
user was just told had failed.

**F′. Starting and stopping are answered when they land.** `onStartCommand` and `onDestroy`
are posted to the same looper the call that asked for them runs on, so neither can have
happened by the time it returns. A platform side that answered immediately would report
*not running* for every start, and the enable flow would read a service that was about to
appear as one the platform had refused — roll the choice back and tell the user it failed.
The answer therefore waits for the transition itself, bounded at ten seconds, well inside
the few the platform allows a `startForegroundService` before it throws. Nothing in a host
test can catch this, so the shape is pinned by an architecture assertion.

**G. Reconciliation, not memory.** The status is established from the platform every time
the application is resumed, after every transition, and at the end of every deferred
catch-up. It starts a stopped service, and — equally — **stops a running one whenever the
arrangement is incomplete**, because a service kept alive for a connection this application
will not hold and an alert it cannot post is battery spent and a permanent entry displayed
for nothing. That reconciliation is also how the capability returns after a restart and
after an update, both of which end the service without ending the choice.

**H. What the user is shown.** One Settings row and one screen, reached only from Settings,
never suggested anywhere. The screen states what it does, what it costs — more battery, and
a permanent notice anyone who unlocks the phone can see, which stays until they turn it off
— and what it cannot promise, in that order, before the switch. The three requirements are
listed, including the manufacturer step, stated plainly as something only the user can do
and something **this application cannot check**. Every degraded state has a sentence of its
own. Both catalogues carry all of it.

**I. What the permanent entry says and reveals.** `IMPORTANCE_LOW` and silent — never
`IMPORTANCE_MIN`, which the platform answers by showing something louder.
`VISIBILITY_SECRET`, so no part of it appears on a secure lock screen or while the screen is
shared. No timestamp, no badge, no count, no name, no message. Its tap target is the
launcher intent and nothing else. Its text is one reviewed, localized sentence that crosses
the channel *with the start*, so a service can never run displaying text this project did
not write, and a start carrying no text starts nothing.

**J. The disclosure moves to revision 4.** ADR-045's mechanism is content-triggered
re-acknowledgement, and a recipient deciding what this build is good for is deciding it
without a material fact if they are not told that a better tier exists, what it costs, and
that it is still not guaranteed. The added sentence says exactly those three things.

### Correctness questions, answered

- **What starts it, and under what complete set of conditions?** Only this application, and
  only after a Dart isolate has read the durable choice out of the encrypted database. Two
  callers: the enable flow, with the user present and every precondition just verified; and
  the reconciliation, which starts a service only when the choice is recorded, notifications
  are enabled, the exemption is held, and nothing is running. A background start is
  permitted because the exemption *is* the background-start exemption.
- **What stops it, and how does the application find out?** The user, from the screen. The
  reconciliation, when the arrangement is incomplete. The isolate itself, when the session
  ends or the choice is off. The platform, at any time, without telling anyone — which is
  observed at the next reconciliation and reported as *not running*.
- **After a restart?** The service is gone and the choice is not. The persisted periodic job
  survives the restart (`setPersisted(true)`, ADR-049), and its next run reconciles the
  capability back on. Until then, delivery is the floor. This is disclosed as a bounded
  delay, not engineered around with a boot receiver, for the reason in alternative 7.
- **After an update?** The same: the process is replaced, the service is gone, the job
  survives, the next tick restores it. Whether a persisted job survives an in-place upgrade
  is not specified by the platform; ADR-049 already records that and mitigates it by
  re-arming on launch, and that mitigation covers this too.
- **After a force-stop?** Nothing, until the user opens the application. No architecture
  changes this and none pretends to.
- **The user grants what it needs and later revokes it silently?** Detected — both
  `areNotificationsEnabled()` and `isIgnoringBatteryOptimizations()` are read fresh, never
  remembered — the service is stopped, and the screen says which one went and that a phone
  update can do it by itself.
- **The manufacturer overrides the user's choice?** Not detectable as such. What is
  detectable is the consequence: the service is not running. The screen says so and does not
  guess why. The application never claims to have checked a vendor setting.
- **How does this coexist with everything else that drives the same work?** C above, and
  ADR-050's argument extended to three owners: one process, one Dart VM, one main looper,
  no durable coordinating state, and a ranked answer at every transition.
- **What does the user see while it is on?** On an unlocked phone, one silent low-importance
  row in the shade and an entry in the platform's own Task Manager. On a locked phone,
  nothing at all. They can dismiss the row (Android 13+), stop the service from the Task
  Manager, or turn the capability off, and the last of those is the only one that is
  durable.
- **Is what the application says about delivery still true?** Not without the change in J,
  which is why J is part of this decision rather than a follow-up.

### Guarantees, permissions, observations — three different things

**Guaranteed by the platform (these are guaranteed *restrictions*; testing cannot disprove
them):** a force-stopped app runs nothing; an app in the "Restricted" background battery
state cannot launch a foreground service and has running ones removed from the foreground;
`dataSync` is capped at 6 h/24 h and cannot start from `BOOT_COMPLETED` at `targetSdk` 35+;
a cached process is frozen and its TCP sockets terminated; `POST_NOTIFICATIONS` denial keeps
every non-exempt notification out of the drawer; the periodic job floor is fifteen minutes.

**Permitted, not guaranteed — a green test run is evidence of nothing:** that a foreground
service keeps running (the system may kill it under memory pressure, and OEMs kill more
aggressively); that an exempt app keeps network through Doze on a given vendor's build; that
`specialUse` continues to carry no timeout; that a started service is restarted after a
low-memory kill; that a persisted job survives an in-place upgrade.

**Observed here, and proving nothing about a device:** every Android-side statement in this
decision rests on documentation and on the shape of the source. No device and no usable
emulator were available — every installed AVD is a Play-Store image — so nothing about
timing, battery, vendor behaviour, service survival or notification appearance was measured.

### Failure modes

- **The exemption is refused, or later withdrawn.** The service is stopped and the screen
  says so. Delivery is the floor, which is what it was before.
- **Notifications are refused.** Same, and the enable flow stops before it asks for anything
  else.
- **The platform refuses to start the service.** The choice is withdrawn, the user is told
  that some phones do this until the application is excluded from putting apps to sleep, and
  the vendor-settings button is on the same screen.
- **The manufacturer kills the process.** The entry disappears with it, because the platform
  removes a foreground service's notification when the service dies. The next reconciliation
  reports *not running*, and the floor is what delivers meanwhile.
- **The socket dies silently.** Detected within eight minutes at worst by the keepalive, and
  repaired by the supervisor's ordinary backoff reconnect.
- **The user dismisses the notification but leaves the capability on (Android 13+).** The
  service keeps running; absence of the entry is then not evidence of absence of the service,
  which is why the screen — not the shade — is where the truthful status lives.
- **A transition never lands.** The waiting answer is released after ten seconds with
  whatever the platform then reports, so an enable can conclude *refused* but never hang.
- **A restarted service is handed no text.** It stops itself without ever promoting, which is
  the fail-closed direction: a foreground service must display something, and anything this
  code assembled would be unreviewed and untranslated.
- **Two owners.** Covered by C; the worst case if the arbitration fails entirely is
  ADR-050's, which is a repaired token rotation and a duplicated unit of work, not a
  sign-out.

### Security and privacy

- **What this makes observable, and for how long.** While it is armed: one silent
  low-importance shade entry naming the application, plus an entry in Android 13+'s Task
  Manager, both visible to anyone holding the *unlocked* phone, and both persisting beyond
  the moment the user chose them. `VISIBILITY_SECRET` keeps every part of it off a secure
  lock screen and out of screen sharing. The Task Manager entry exists for **any** app
  running a foreground service and is not removable by anything this application does; it is
  disclosed rather than worked around.
- **Is that proportionate?** The marginal exposure over what the device already reveals — the
  application is installed, has a launcher entry, and posts message alerts — is a persistent
  silent row on an unlocked phone. It is stated before the choice rather than after it, it is
  reversible in one tap, and the capability is off until somebody deliberately turns it on.
  On that basis, yes. It is also the single reason this is opt-in rather than default, and
  the reason the wording names nothing, counts nothing and promises nothing.
- **What the component starting outside the ordinary path can reach.** Exactly what the
  activity reaches, because it composes through the same `ApplicationRuntime`: the
  provisioned `SecurityContext`, the one `TokenCoordinator`, the environment-gated crypto
  core. It has no window, so it cannot show a permission dialog, and the exemption request
  is attached only to the activity's engine.
- **Could the provisioned trust be silently absent here?** No, and this is the failure that
  would be quiet rather than loud. One constructor builds transport trust for both entry
  points, and `test/architecture/sustained_delivery_policy_test.dart` fails if this path ever
  names `TransportSecurity.platformDefault`, builds its own `DioRestClient`, or constructs a
  second `TokenCoordinator`.
- **Credentials.** One coordinator, one single-flight refresh, one durable token store, and
  ADR-050's repair underneath. The third owner does not change that; it participates in the
  same arbitration.
- **What a longer-lived connection tells the server.** The backend already sees when a device
  drains and already touches `last_active_date`. Holding a socket makes this device's online
  periods more continuous and therefore more legible to a relay the threat model already
  treats as untrusted. It creates no new party and no new content exposure, and it is
  disclosed as "the app stays connected".
- **What an attacker can cause.** A hostile relay can flood `envelope` hints; each is only a
  trigger for a bounded, backed-off REST drain that finds nothing, and the cost is battery,
  not correctness. Nothing an attacker controls can start the service, displace an owner, or
  change what the entry says: the channel carries booleans in and verbs plus one reviewed
  sentence out.
- **What it writes and logs.** One encrypted preference row. No log line, no file, no shared
  preference, no telemetry, no outbound call beyond the provisioned backend. The Kotlin
  contains no `Log.` and no `println`, pinned by test.
- **No existing invariant was weakened.** The prohibitions on `dataSync`, `remoteMessaging`,
  foreign push, exact alarms and SMS all stand and are still enforced; what changed is that
  three assertions written for the *mandatory floor* were narrowed to the floor rather than
  the whole artifact, deliberately and in place.

### User requirements

Once, deliberately, with the application open:

1. Allow notifications. Without it nothing announces anything, whatever else is arranged.
2. Grant the battery-optimization exemption in Android's own dialog.
3. On Samsung and Xiaomi — roughly 77% of this fleet — exclude the application from the
   manufacturer's own app-sleeping. Samsung documents the destination and an intent for it;
   Xiaomi documents the destination. **The application cannot read either and says so.**

And, ongoing: do not force-stop the application, and do not set its battery use to
"Restricted". Both are stated on the screen. No maintenance is assumed, nothing is repeated
on a timer, and the surface never implies that completing the steps guarantees the result.

### Beta and production

> **Superseded 2026-08-23 by ADR-053.** This clause no longer holds. The matrix below
> still cannot be run here — there is no physical Android device of any kind, and the
> capability additionally cannot start on any target without an operator-activated
> account — so the capability is now **withheld from the beta and production artifacts**
> by a compile-time gate with an empty evidence ledger, rather than shipped off by
> default. The argument this clause rests on treats "we cannot measure this" as a reason
> to ship; ADR-053 holds that it is a reason to withhold. The paragraph is kept as
> written, because a changed decision is not edited out of history.

**Present and enableable in the distributed artifact now, off by default.** ADR-046 held
that Layer 2 "may not be enabled in any distributed artifact before the physical-device
matrix … has actually been run and recorded". That clause is **amended here**, on three
pieces of evidence ADR-046 did not have: first-party vendor documentation in place of
community reporting; the standby-bucket consequence of the Doze exemption, which makes
enabling this improve the mandatory floor as well; and a design in which the permanent
indicator is displayed by the platform only while the service is genuinely running, so it
cannot be the false claim ADR-046 was protecting against. Against that stands the fact that
the matrix still cannot be run — there is no device and no usable emulator — so keeping the
clause would not defer the capability, it would cancel it.

The evidence that would change this answer is in *Review and revisit conditions* below,
finding 4 in particular. Nothing about the Beta/Production separation, the two Cargo
profiles, the frozen signing identity or `signingConfig = null` on release is touched, and
no production gate is opened. Production remains unsigned and undistributable, verified by
`tool/verify_release_apk.sh` in this run.

### Known limitations

- Near-real-time background delivery is best-effort and vendor-dependent for most of this
  fleet, and no design available in this environment removes that.
- Samsung's foreground-service statement covers One UI 6.0 and above only. Roughly half this
  fleet by version share is Android 13 or earlier, where no vendor statement exists.
- Xiaomi has published nothing about foreground services; only the autostart permission is
  documented, and its effect on a started service is unknown.
- A force-stopped or battery-"Restricted" application is silent, permanently, by design.
- The capability returns after a restart or an update only at the next periodic job, which is
  fifteen minutes at best and Doze-dependent in practice.
- The permanent entry appears in the Task Manager whatever this application does, and the
  user may dismiss the shade entry while the service continues.
- The keepalive detects a dead connection within eight minutes at worst, not immediately.
- Everything Android-side is argued from documentation and source shape. Nothing was measured.

### Outstanding validation

Enumerated, with what each requires. None of it can be inferred from this run.

1. **That the service starts, is displayed as described, and keeps running.** A physical
   device per manufacturer. Nothing about `startForeground`, the `specialUse` type check, the
   notification's appearance, `VISIBILITY_SECRET` on a secure lock screen, or the Task
   Manager entry has been seen.
2. **That the exemption dialog appears and its answer is read correctly**, including a
   dismissal and a refusal, on Android 11 through 17.
3. **That a held connection survives Doze with the exemption**, and how long it survives
   without it. Requires `adb shell dumpsys deviceidle force-idle` on a device.
4. **The manufacturer matrix**: Samsung (One UI 5.x *and* 6.0+) and Xiaomi (MIUI and
   HyperOS), with and without the vendor exclusion, over hours and over days, including
   after a system update — which is the case both vendors' own documentation implies can
   revert a user's choice.
5. **That the periodic job restores the service after a restart and after an in-place
   upgrade**, which is the only restart path this design has.
6. **That the third owner arbitration behaves as argued on one looper.** No Dart test can
   drive the Kotlin arbiter; what is pinned is the shape of the source, not its behaviour.
7. **That a headless engine starts the `sustainedDelivery` entry point in a release AOT
   snapshot.** Inherited unchanged from ADR-049, and now applying to a second entry point.
8. **Battery and data cost, measured.** Every number in this decision about battery is a
   direction, not a measurement.
9. **Android 13+ Task Manager "Stop" behaviour**: whether it is equivalent to a force-stop
   for this application, and therefore whether the floor survives it.

### Follow-up work

1. Everything in *Outstanding validation*, on hardware.
2. Re-delivering the handover disclosure at revision 4 remains **release-blocking**, and now
   supersedes the revision-3 obligation that was already outstanding.
3. If voice ships, two foreground services can be armed at once and their notifications and
   lifetimes must be decided rather than discovered (ADR-046's revisit condition 6).
4. `sustainedKeepAlive` is a compromise chosen from documentation, not from measurement on
   an Iranian carrier's NAT. Item 8 above should inform it.

### Review and revisit conditions

1. **Android changes the `specialUse` contract** — a timeout, a runtime prerequisite, a boot
   restriction, or a Play-style justification requirement reaching non-Play artifacts. The
   whole of this rests on its being unrestricted.
2. **Android changes the freezer or the standby-bucket network rules**, or the Doze
   exemption stops implying standby-bucket exemption.
3. **The device matrix shows this is unreliable on Samsung or Xiaomi even when configured.**
   Then near-real-time background delivery is not achievable for this fleet, alternative 1
   becomes the honest answer, and the capability should be withdrawn rather than left
   available — with the disclosure moving again.
4. **The backend grows a push endpoint**, making a domestic self-hosted distributor
   buildable; ADR-046's alternative 6 and its metadata question reopen.
5. **A fourth delivery owner appears.** ADR-050's arbitration must be re-derived again.
6. **The user base stops being 20–30 known people receiving a written handover.** The
   per-device setup burden accepted here does not survive that change.

This decision builds ADR-046's Layer 2 and closes its follow-up step 5; amends ADR-046's
distribution clause and ADR-045's disclosure to revision 4; extends ADR-050 to three owners;
reaffirms ADR-013 and ADR-029's successor reasoning; opens no production gate; changes no
cryptographic behaviour; and adds no dependency.

## ADR-050 in full — guaranteeing that one part of the application drives delivery (2026-08-22)

**Status:** Accepted. Corrects ADR-049's ownership arbitration, which was placed downstream
of the operation it existed to protect, and adds the repair that makes the shared durable
row safe when the arbitration cannot run at all. Reaffirms ADR-049's *choice* of mechanism
on re-derived evidence. Adds no dependency, changes no cryptographic behaviour, touches no
backend, opens no production gate.

### The question

> More than one part of this application may be capable of driving the same delivery work
> against the same device, at the same time, without sharing memory. Is that true, exactly
> which shared things are unsafe when it is, and what makes it impossible for two of them
> to be doing the unsafe part at once — including when one of them stops existing
> mid-operation and never gets to clean up?

Nothing was assumed: not that the hazard exists, not the mechanism, not where the
coordinating state lives, not the unit of exclusion, not what a loser does, and not that
ADR-049's answer was right.

### Exact environment, fixed

Unchanged from ADR-044 and ADR-049. 20–30 users, all in Iran, private handover, no foreign
runtime dependency at any layer, backend inside Iran and reachable, Android/Flutter client
installed as a signed artifact, server an untrusted relay, devices killed and restarted
without cooperation. `minSdk` 24, `targetSdk` 36, Flutter 3.44.7 / Dart 3.12.2.

### Is the hazard real? Yes, and it is reachable on an ordinary user action

Established from the composed artifact on 2026-08-22, by trace rather than by inference.

**Two drivers can exist.** `DeferredDeliveryJobService` is declared with no
`android:process`, so it runs in the default process; `beginCatchUp` starts a headless
`FlutterEngine` when no activity engine is attached. Two `FlutterEngine`s in one process
share one Dart VM but **not** one heap: two Dart *root isolates*, no shared memory, one
shared SQLCipher file.

**They meet on a user action, not on a rare interleaving.** The job fires while the process
is gone → a headless run starts → the user opens the application. ADR-048 makes that
sequence *more* likely rather than less: a catch-up that finds a message posts a
notification, and tapping it is what starts the activity.

**What they both touch, and how badly.**

| Shared thing | What two drivers do to it | Severity |
|---|---|---|
| `account_session.token_metadata_ciphertext` — the **rotating** refresh token | both read `R0`; both present it; the backend blacklists on rotation, so the loser gets `401 invalid_token`, which `_endsSession` reads as the server ending the session → `store.clear()` deletes the shared row | **destroys session state**: the device is signed out and the user must log in again |
| `inbox_envelopes` rows in `received`/`inspecting` | `beginNextEnvelopeInspection` deliberately re-offers `inspecting` rows so a crashed inspection is retried, so both claim the same lowest-sequence envelope and hand one ciphertext to the ratchet twice | corrupted/duplicated ratchet work |
| outbox target rows | same claim-and-send shape | duplicated sends; recipients deduplicate by event id, so mostly wasted effort |
| alert markers (ADR-048) | two reconciliations of one shade | cosmetic |
| group KeyPackage maintenance, pending eviction, outbound dispatch | concurrency properties never established | unknown, therefore treated as unsafe |

The first row is the sharp one and it is not theoretical. `config/settings/base.py` sets
`ROTATE_REFRESH_TOKENS: True` and `BLACKLIST_AFTER_ROTATION: True`;
`backend/accounts/API.md` states it in the contract — "the presented token is blacklisted
and a new access/refresh pair is issued", "replaying an already-rotated token is a 401",
and that `401 invalid_token` "also covers expired and already-blacklisted tokens". In the
client, `BackendFailureCode.invalidToken` is in `_endsSession`, so the loser terminates.

**And the window is not narrow.** `SecureSessionTokenAdapter` never persists an access
token; a restored process reconstructs one with `expiresAt` at the epoch, precisely so that
"the coordinator rotates the persisted refresh token before any authenticated request can
be sent". So the *first* authenticated act of *every* fresh root isolate is a rotation of
the shared row. Two isolates starting within one network round trip of each other both
present `R0`.

### What the repository actually did before, and where it disagreed with itself

ADR-049 identified this hazard precisely and named the right mechanism. Its arbitration is
sound: `BackgroundDelivery` is a Kotlin object in the one process, mutated only on the main
looper — `JobService` "executes each incoming job on a `Handler` running on your
application's main thread", and `FlutterActivity.configureFlutterEngine` is on the same
looper.

**But the gate was in the wrong place.** ADR-049 states: "`MessageDeliverySession.compose`
calls `awaitExclusiveOwnership()` before it opens storage or reads a token". Traced through
the composed application, that is false:

1. `MessageDeliveryController` starts a session only for `fullScope`/`offlineFullScope`;
2. that access state is produced only by `AuthenticationController.restore()`;
3. `restore()` calls `CoordinatedAuthenticationSession.restore()` → `tokens.read()` (opens
   protected storage) → `coordinator.accessToken()` (**rotates the shared refresh token**);
4. the router sends a dormant launch to `/session-restoring`, whose first post-frame
   callback is that `restore()`.

So the ownership question was asked *strictly after* the operation it existed to protect.
The mechanism prevented two engines; it did not prevent the two token coordinators whose
collision ADR-049 traced to "401 `invalid_token`, `_endsSession`, `store.clear()`, and a
user signed out who did nothing".

**A test asserted the opposite and passed.**
`test/app/dependencies/message_delivery_composition_test.dart` — "a session waits for a
catch-up that already owns delivery" — asserts `harness.http.requests` is empty while
ownership is held, with the comment "before it opens storage or reads a token — not
after". It passes because its harness overrides `restore` with a fake session, so the real
`TokenCoordinator` never runs. It is a true statement about the delivery session and was
read as a true statement about the application.

**Documentation contradicted itself.** `docs/sync-engine.md` said, in *Token lifecycle*,
that "the durable delivery lease of ADR-046 is what actually prevents two coordinators from
racing the rotating refresh token" — while, forty lines later, recording that ADR-049 had
removed that lease. Both halves cannot be true, and the half that was load-bearing for the
sharpest hazard named a mechanism that does not exist in the artifact.

**A separate, pre-existing defect made the whole area unverifiable.**
`SecureSessionTokenAdapter._writeFullSession` built `AccountSessionsCompanion.insert`
without `singletonId`. `singleton_id` is the sole `INTEGER` primary key of a rowid table, so
SQLite treats it as an alias for the rowid: an insert that omits it is assigned
`max(rowid) + 1` and the `DEFAULT 1` is never reached. The first write to a database
succeeds with rowid 1; **every write after it fails** `CHECK("singleton_id" = 1)` with
`SqliteException(275)`, thrown out of `store.replace(...)` inside `_performRefresh`. Every
token rotation after the first, on any given device, would have thrown. Reproduced directly
on 2026-08-22 against a real `LocalDatabase`; no test covered a second write.
`drift_enrollment_journal_store.dart` had the identical omission for `account_identity`.
`DriftSyncStore._ensureCheckpoint` has it too but is harmless by accident, because
`INSERT OR IGNORE` swallows the CHECK violation and the "ensure exists" intent is met
anyway.

### Research findings

Primary sources only; blogs and forums were used for discovery and are cited nowhere.

**One Dart VM per process, and one `IsolateNameServer` owned by it.** Read at the exact
pinned revision — `flutter/flutter@84fc5cbb22` (Flutter 3.44.7), 2026-08-22.
`engine/src/flutter/runtime/dart_vm_lifecycle.h`: "There can only be one VM running in the
process at any given time." `dart_vm_lifecycle.cc`: `DartVMRef::Create` takes `gVMMutex`,
and "If there is already a running VM in the process, grab a strong reference to it" —
returning the existing VM and logging "Ignoring arguments for current VM create call and
reusing the old VM". The name server is created once per VM
(`auto isolate_name_server = std::make_shared<IsolateNameServer>()`), stored as
`gVMIsolateNameServer`, and served to every caller by `DartVMRef::GetIsolateNameServer()`.
`dart:ui`'s own documentation: "All isolates share a global mapping of names to ports."
ADR-049 asserted this; it is now verified at the pinned revision.

**Which settles what the storage layer actually is.** `drift_flutter` 0.3.1
(`lib/src/native.dart`, read 2026-08-22) implements `shareAcrossIsolates: true` by looking
up `drift-db/<name>` in `IsolateNameServer` and, if present,
`DriftIsolate.fromConnectPort(port).connect()`; only when absent does it spawn an isolate
that registers itself. Because the name server is VM-wide, the headless root isolate and
the activity root isolate **connect to the same database server isolate**: one
`NativeDatabase`, one SQLCipher connection, one file. There is no second connection and no
file-level locking question to answer.

**What that server guarantees under concurrent clients.** drift 2.34.2,
`lib/src/remote/server_impl.dart`: "when a transaction is active, all queries that don't
operate on another query executor have to wait", implemented by `_executorBacklog` and
`_waitForTurn`; and `lib/src/runtime/executor/helpers/engines.dart`, where
`_StatementBasedTransactionExecutor.ensureOpen` holds the parent executor's `Lock` until
the transaction completes ("Block the main database or the parent transaction while this
transaction is active"). So **a drift write transaction is already mutually exclusive
across isolates**. `singleClientMode` defaults to `false` on this path, so closing one
client does not shut the server down for the other, and table-update notifications are
forwarded to every *other* connected client (`dispatchTableUpdateNotification`).

This is a precise and load-bearing limit: transactions are atomic and serialized across
owners, so nothing is half-written. What is *not* protected is any logical operation that
spans transactions with I/O in between — read token → rotate over the network → write
token, or claim envelope → decrypt → commit. Those are exactly the unsafe operations above.

**Platform threading and process death.** `JobService`: "This service executes each
incoming job on a `Handler` running on your application's main thread"; "Job services must
be protected with this permission" (`BIND_JOB_SERVICE`), and one that is not "will be
ignored by the system"; `jobFinished` releases the wakelock the system holds for the job
(developer.android.com/reference/android/app/job/JobService, read 2026-08-22). AOSP cached
apps freezer: "If all processes for a particular app are frozen, the system terminates any
active TCP sockets maintained by the app" (source.android.com/docs/core/perf/
cached-apps-freezer, read 2026-08-22).

**Clocks.** Deliberately not researched into a dependency, because the design uses none.
No part of this decision reads wall-clock time, elapsed time, or a timer whose value
affects who owns delivery. That removes the entire class of failures a lease-based design
inherits from a clock a user can set.

**Backend, read-only.** `backend/config/settings/base.py` and `backend/accounts/API.md`, as
quoted above. No backend file was read for anything other than its contract, and none was
changed.

### Alternatives evaluated

**1 — Nothing; the hazard is not real.** Rejected on the trace above and on
`delivery_owner_contention_test.dart`, which reproduces the damage with two real isolates
over one real shared store.

**2 — Keep ADR-049's arbitration exactly as it is.** Rejected: it does not cover
`restore()`, which is where the damage is. This is a placement defect, not a mechanism
defect.

**3 — Reinstate ADR-046's durable Drift delivery lease.** Re-examined independently rather
than inherited from ADR-049's rejection, and rejected again, more firmly. Every owner that
can exist lives in one OS process (no `android:process`; one Dart VM per process; the job
service runs in the default process), so a durable lease coordinates between things that
always die together. What it *adds* is the entire stale-holder problem: an expiry, a clock
to measure it with, a heartbeat writing to an encrypted database forever, and a window
after every crash in which delivery is blocked by a lease nobody holds. That is a permanent
availability failure introduced to fix an intermittent correctness one, which the brief
names as the worse outcome. It is also strictly weaker in the case that matters most: the
headless engine is destroyed by `onStopJob` or by the four-minute deadline **while the
process survives**, and a durable lease would then be stale with nothing to release it,
whereas the Kotlin arbiter is *the same code that destroys the engine* and releases in the
same call.

**4 — A Dart-side lock over `IsolateNameServer`.** Genuinely available — it is VM-wide and
`registerPortWithName` is an atomic test-and-set, which is how `drift_flutter` elects its
database server. Rejected: `FlutterEngine.destroy()` kills the headless root isolate
abruptly and leaves the name registered, wedging the foreground until the process dies.
Recovering from that needs `Isolate.ping` liveness probing with a timeout — more machinery,
a new failure mode, and no advantage over an arbiter that already owns the engine's
lifetime.

**5 — Remove the concurrency instead of coordinating it.** Two shapes. Delete the headless
entry point: rejected, that is ADR-049's whole value and a backgrounded client would
receive nothing. Or never start a headless run when an activity might appear: impossible,
the platform starts the activity, not this application.

**6 — Kill the in-flight headless run when the user opens the application.** Rejected for
ADR-049's reason, re-checked: the run may be inside the shared native cryptographic core
(on a worker isolate spawned from the headless root, so engine teardown takes the whole
group). Abandoning remains what happens when the *platform* takes the decision — `onStopJob`
and the four-minute deadline — and is not made the ordinary path.

**7 — Let the foreground wait for the headless run to finish naturally.** This is what
ADR-049's design does. Rejected as the *whole* answer once the gate moves to launch: the
bound on that wait is a complete drain — up to 100 pages of 100 envelopes — and blocking
application launch on it is a visible failure. Waiting is kept; what changes is that the
thing being waited for is asked to stop.

**8 — Protect only the refresh token and let the rest overlap.** Rejected for ADR-049's
reason, which still holds: `beginNextEnvelopeInspection` re-offers `inspecting` rows by
design, and the post-inbox composite's concurrency properties are not established.
Exclusion covers the whole cycle.

**9 — Make the refresh token safe and *also* exclude.** Selected. The two are not
alternatives: one is the guarantee, the other is what the guarantee's own failure costs.

### Decision

**Three changes. One moves the gate to where the damage is, one makes the losing owner give
way promptly, and one makes the sharpest shared row survive the mechanism failing
altogether.**

**A. The ownership question is asked by the entry point, before anything exists.**
`bootstrap()` awaits `DeliveryOwnershipGate.awaitExclusiveOwnership()` before
`ApplicationRuntime.create` — before protected storage is opened, before a token is read,
before `runApp`. One gate, at the one place every foreground path passes through, covering
session restoration, delivery, alerts, and anything added later. The session-level
`awaitExclusiveOwnership` in `MessageDeliverySession.compose` stays as a second, normally
instant check.

**B. The catch-up gives way; the foreground never yields.** The two owners are not
symmetric. A catch-up runs *because* nobody is looking; the moment somebody is, the
foreground drains the same mailbox within seconds and the run has no reason left to exist.
`BackgroundDelivery.attachForeground` — which runs in `configureFlutterEngine`, before that
engine's Dart entry point does anything — invokes `standDown` on the headless engine's
channel. `DeferredCatchUpHandshake` latches it and *is* the `DeliveryStandDownSignal` the
engine reads, so what the platform says and what the engine sees cannot drift apart through
a mapping layer. `DurableSyncEngine` reads it between units of work: before each envelope
inspection, each drain page, and each outbox batch. A displaced cycle finishes the
transaction it holds, reports `deferred`, and stops; the catch-up returns `displaced`,
skips the alert pass, and reports finished. Nothing is abandoned part-way.

**C. Losing a rotation is repaired, not read as the session ending.** `TokenCoordinator`
now distinguishes the two things a `401 invalid_token` can mean, using the shared durable
row rather than its own per-isolate cache:

- the success path compares against `store.readDurable()`, so a rotation cannot overwrite a
  newer pair another owner persisted while it was in flight;
- the failure path, and only for `invalid_token`/`token_not_valid` (never `token_revoked`,
  which means a revoked device or a dead account and cannot be repaired by presenting a
  different token), waits briefly and finitely for the row to move. If it moves, another
  owner rotated first: adopt what it wrote and rotate that, up to a small budget. If it
  never moves, the session really is over and is ended exactly as before.
- Exhausting the budget while the row keeps moving is reported as a **transient** failure,
  never a termination — a row that keeps moving is positive evidence that the session is
  alive, and ending it there would be the one outcome that cannot be undone.

The wait is bounded by a **count**, not by elapsed time (default 40 × 25 ms), because a
device clock can move backwards and a wait that cannot terminate is the failure this whole
piece exists to avoid. `readDurable()` is a new `SessionTokenStore` method; it reads the row
without disturbing the in-memory access token, which the durable row never holds.

**D (correction, separately reported).** `singletonId: const Value(1)` is now stated
explicitly in the `account_session` and `account_identity` upserts. Without it the second
write to either table on any device throws.

### Correctness questions, answered

- **Can two contexts genuinely run at once in the shipped artifact?** Yes — two Dart root
  isolates in one process, shown above, and reproduced in test.
- **What is the unit of exclusion, and why that unit?** *All of what one delivery owner
  does with the application runtime*, from the entry point until the run ends. Not a job,
  not a resource, not an envelope: the unsafe operations span transactions with network I/O
  in between, and the composite post-inbox work has no established concurrency properties.
  A finer unit would require establishing safety for every one of them.
- **How does a contender acquire, and what does it observe when it cannot?** It asks the
  platform on the main looper. A headless run in flight is recorded; the question is
  answered when that run ends. When the platform cannot answer at all, the foreground
  proceeds after a bounded wait — see *worst case* below.
- **How does a holder release, on the ordinary path and every extraordinary one?** Ordinary:
  the Dart side reports finished, Kotlin destroys the engine, `headless = null`, waiters
  released. Displaced: the same path, reached sooner. `onStopJob`: `abandonCatchUp` →
  `finish()` → same release. Four-minute deadline: same. Engine start failure: `headless`
  cleared and waiters released in the same statement. **Process death: nothing to release,
  because nothing durable was held.**
- **How is a holder that will never release detected, and how long does that take?** It is
  not detected, because it cannot exist. Every holder is inside one process; the release is
  performed by the object that owns the holder's lifetime, on the same thread. The only
  "undetected" case is a Dart side that never reports, and that is bounded by Kotlin's
  four-minute deadline and, behind it, the platform's ten-minute job limit.
- **What stops a displaced holder still running from acting as though it holds?** The
  latched signal it reads between units of work, plus the fact that its engine is destroyed
  when it reports. In the interval between the two, it holds no exclusive resource: its
  transactions are serialized by the one drift server, and its token rotation is repairable.
- **Can the mechanism deadlock, starve, or wedge delivery permanently?** No. The arbiter has
  one waiter list and one release path, all on one thread. Every wait has a bound: 20 s at
  the entry point, 5 min at the session, 4 min for the headless engine, 2 min for a tick.
  Every bound expires into *proceeding*, never into stopping. Nothing durable records
  ownership, so nothing survives a restart to block the next run.
- **What happens on the very first run, before any coordinating state exists?** Nothing to
  wait for: `headless` is null and the question returns immediately. There is no first-run
  case because there is no state to create.
- **What if the coordinating state is corrupt, from an older version, or absent?** It cannot
  be any of those. It is two fields in a process-lifetime Kotlin object; a new process
  starts with them empty, which is the correct state.
- **Does anything the user sees change?** No new screen, no new string, no new permission,
  no new notification. The only visible change is the *absence* of an unexplained sign-out.

### Guarantees, assumptions, observations — three different things

**Guaranteed by construction, with the argument:**

1. *No stale holder can exist.* Every owner lives in the one process (manifest declares no
   `android:process`; the Flutter engine documents one Dart VM per process and reuses it),
   and the only coordinating state is process-lifetime memory. Process death releases
   everything simultaneously with the things it was protecting.
2. *The mechanism cannot block delivery permanently.* Every wait is bounded and every bound
   expires into proceeding. Nothing durable is written by it.
3. *Transactions cannot interleave destructively.* One SQLCipher connection behind one drift
   server, and drift serializes transactions across clients at the pinned version.
4. *An unanswerable ownership question is never read as "somebody else rotated".* The repair
   adopts only a value that is present *and* different; a store that cannot be read answers
   null and the session ends as it would have.

**Guaranteed only under assumptions, and here they are:**

5. *Exactly one owner drives the engine* — assuming `JobService` callbacks and
   `FlutterActivity.configureFlutterEngine` really are delivered on one looper in order
   (documented, not measured here), and assuming no future code path starts a Dart root
   isolate outside `BackgroundDelivery`.
6. *The foreground's wait is short* — assuming the displaced run reaches a unit boundary
   promptly. The bound is one envelope's inspection, one drain page, or one outbox batch,
   not a whole cycle. It is not a bound on wall-clock time.
7. *The repair converges* — assuming the losing owner can read the durable row and that the
   winner persists what it was issued.

**Merely not observed to fail, and proving nothing:**

8. That a job runs at all on a device. No device or emulator run was possible; every
   Android-side statement rests on documentation and on source assertions.
9. That the Kotlin arbiter behaves as argued. No Dart test can drive it, and what is pinned
   is the *shape* of the source, not its behaviour.
10. That a headless engine starts the `backgroundDelivery` entry point in a release AOT
    snapshot. Inherited unchanged from ADR-049.

### Failure modes, including of the mechanism itself

- **The platform never answers the ownership question.** The entry point proceeds after
  20 s. Exclusion is then absent for that launch, and the sharpest damage is bounded by the
  repair in C: a redundant rotation instead of a sign-out.
- **The stand-down request never arrives, or arrives at an engine not yet listening.**
  Kotlin re-sends on a second attach, and `standDownImmediately` covers a run started while
  an activity was already attaching. If it is still missed, the foreground waits for the run
  to end naturally — ADR-049's behaviour, with ADR-049's bounds.
- **The displaced run ignores the request.** It cannot ignore it for longer than one unit of
  work; if it is wedged inside one, the four-minute engine deadline ends it.
- **The repair adopts a token that is itself immediately retired.** Bounded by the adoption
  budget and then reported as transient. The user stays signed in and the next call retries.
- **The winner dies between being issued a token and persisting it.** The loser waits, sees
  a row that never moves, and ends the session — which is *correct*: the issued pair is lost
  and the presented one is blacklisted, so no working token exists. Covered by test.
- **The durable store is unavailable during the repair.** Fail-closed: no adoption, session
  ends as before.
- **A future second process.** Invalidates the entire argument. An architecture test fails
  if `android:process` appears anywhere in the manifest.

### Worst case if the mechanism itself fails

Both gates absent and both owners running: the loser's rotation is repaired, so the user
stays signed in; the same envelope may be handed to the ratchet twice and the same outbox
batch sent twice. The first is a decryption failure that is retried; the second is
deduplicated by recipients on the logical event id. Nothing is destroyed that a later
session cannot re-derive. That is a strictly better worst case than the one this decision
found in the artifact, where the user was signed out.

### Security and privacy

- **Can failure invalidate a session, lock a user out, or destroy account state?** That was
  the *pre-existing* behaviour and it is what C removes. The remaining path to a
  termination is a durable row that genuinely never moves, which means no working token
  exists.
- **Can anything an attacker controls influence who holds, or displace a holder?** No. The
  arbitration reads no network input and no server-supplied value. A hostile relay can
  answer `token_revoked` to end a session, which it could already do, and which the repair
  deliberately does not soften.
- **Does the coordinating state reveal anything?** It is two in-memory fields holding a
  channel reference and a run object. Nothing is written to disk, no log line, no
  preference. The stand-down call carries no arguments.
- **Can an interrupted operation leave security-relevant state in a middle position?** The
  refresh is the one that can: a rotation may be issued and not persisted. That is the case
  in *Failure modes* above, and its resolution is to end the session, not to guess.
- **Can this be used to suppress delivery or notification silently?** A displaced catch-up
  skips its alert pass — but it skips it *because* the foreground owns the shade from that
  moment and reconciles from the same committed state, and `MessageAlertController` starts
  with `_alertPosted = true` precisely so a new process can withdraw or re-post what a
  previous one left. Nothing an attacker can reach triggers a displacement.
- **No existing invariant was weakened.** Both entry points still compose through one
  `ApplicationRuntime`; the headless container's one extra override is additive and typed
  as `DeliveryStandDownSignal`, so it cannot replace a transport, storage or crypto
  override.

### Beta and production

Suitable for both, now. No dependency added, no cryptographic surface touched, no production
gate crossed, and the Beta/Production separation is exactly where ADR-042 and ADR-044 left
it. It changes nothing the application says about itself: ADR-045's disclosure revision is
unchanged at 3, because the delivery *tiers* are unchanged — this decision makes the
existing claims true rather than making new ones.

### Known limitations

- **The Kotlin arbiter is argued, not tested.** Its correctness rests on the one-looper
  argument and on source assertions.
- **The foreground's wait is bounded by a unit of work, not by a duration.** A single
  pathological envelope inspection bounds it, and nothing here caps that.
- **The repair costs up to a second before a genuinely ended session signs out.** Deliberate:
  a user who is being signed out anyway is not harmed by a second, and a user who is not
  being signed out is spared entirely.
- **`MessageAlertController` has no gate of its own.** It starts after restoration, by which
  time any headless run has been asked to stand down; its worst case is a duplicate
  notification, and it is not made a reason to add a second gate.

### Outstanding validation

1. **Everything Android-side.** No device and no usable emulator (all installed AVDs are
   Play-Store images). The displacement path, the stand-down channel call, the headless
   engine teardown and the one-looper ordering are unexercised on hardware.
2. **The interaction with `onStopJob` under real Doze/quota pressure.**
3. **That the pre-existing singleton-write defect is now genuinely absent end-to-end**, i.e.
   that a real device can rotate twice. Verified against a real `LocalDatabase` on the host;
   not on a device.
4. **The device matrix** from ADR-049 remains open and unchanged.

### Follow-up work

1. Device validation of everything in *Outstanding validation*.
2. `DriftSyncStore._ensureCheckpoint` relies on `INSERT OR IGNORE` swallowing a CHECK
   violation that a stated `singletonId` would turn into an intended primary-key conflict.
   Harmless today, fragile if the insert mode ever changes.
3. ~~ADR-046's Layer 2 (`specialUse` foreground service) remains unbuilt. When it ships it is
   a third owner and this arbitration must be re-derived, not extended by assumption.~~
   **Shipped 2026-08-22 — ADR-051**, and the arbitration was re-derived rather than extended:
   the third owner is ranked below the activity's isolate and above a deferred catch-up, it
   is asked to stand down through the same latched handshake, `awaitExclusiveOwnership` waits
   for both, and nothing about any of it is durable — so the argument that process death
   releases everything at once is unchanged and now covers three owners.
4. Re-delivering the ADR-049/ADR-048 handover disclosure at revision 3 remains
   release-blocking and is untouched by this decision. **Superseded 2026-08-22 — ADR-051**
   took the disclosure to revision 4; the obligation is unchanged in kind and now applies to
   the revision-4 text.

### Review and revisit conditions

1. **Any second process appears** — the whole argument is that there is one. The
   architecture test fails first.
2. **A third delivery owner appears** (Layer 2, or anything else that starts a root isolate).
3. **The Flutter engine stops guaranteeing one Dart VM per process**, or `drift_flutter`
   stops sharing one database server across isolates. Both are pinned-version facts.
4. **The backend stops blacklisting on rotation, or starts revoking the whole token family
   on reuse.** The second would make the repair in C useless and would demand real exclusion
   over the refresh, not repair.
5. **Any wait here becomes unbounded**, or any coordinating state becomes durable.

## ADR-049 in full — what makes a backgrounded client take delivery (2026-08-21)

**Status:** Accepted. Implements ADR-046's Layer 1 and **replaces two of its
mechanisms** — the `WorkManager` dependency and the durable Drift delivery lease — on
evidence recorded below. Amends ADR-045's delivery disclosure to revision 3. Opens no
production gate.

### The question

The user has closed the application, or has not opened it for some time. Messages are
waiting for this device on a server it can reach. **What causes the application to take
delivery of them, how often can that honestly be expected to happen, and what must be
true for it to be safe every time it does?**

The scope excludes, by definition, anything that requires the user to grant, configure or
change something; anything that requires the application to keep running; and anything
that needs per-manufacturer instructions to work at all. This is the floor beneath every
better mechanism, and the only thing that will be true for a user who never reads the
instructions.

Nothing was assumed. The mechanism, the cadence, the entry point, the process model, the
ownership model, the dependency and the native/Dart split were all re-derived, including
the ones ADR-046 had already named.

### Exact environment, fixed

- 20–30 users, all in Iran, known to the operator, receiving the artifact by private
  handover. Nothing configured, nothing granted, no setting changed.
- International connectivity may be entirely unavailable; domestic connectivity reaches
  the backend, which is inside Iran and is the authoritative durable mailbox
  (`GET /api/v1/me/envelopes`, seven-day TTL).
- Fleet dominated by Samsung and Xiaomi, whose background-management behaviour AOSP does
  not specify. Android 11 through 16 all materially represented.
- `minSdk` 24, `targetSdk` 36, `compileSdk` 36 (read from the pinned Flutter 3.44.7
  Gradle extension, 2026-08-21). Directly installed signed APK; Play policy does not bind
  it, platform behaviour binds it completely.
- ADR-013 stands: no foreign push, no Firebase, no foreign runtime call. FCM is excluded
  twice over — by decision, and because Google's servers are unreachable exactly when
  this application is most needed.

### What the repository actually did before

Verified in the composed application on 2026-08-21, not in its documentation.

| Component | Existed | Reachable at runtime |
|---|---|---|
| Foreground socket, engine, drain, commit (ADR-047) | yes | yes |
| Alert reconciliation from committed state (ADR-048) | yes | yes |
| `AndroidPollingScheduler` port | yes | **no adapter** |
| `UnscheduledBestEffortPolling` composed as the polling port | yes | yes — it schedules nothing and emits nothing |
| Any `<service>`, job, alarm or receiver in the manifest | **no** | no |

So a backgrounded application performed no catch-up whatsoever, exactly as
`sync_platform_adapters.dart` said and exactly as ADR-045's disclosure told recipients.
Three further findings came out of that inspection and changed what could be built:

1. **The protected-storage boundary was unreachable from any second entry point.**
   `loadOrCreateStorageKey` was a method-channel handler registered in
   `MainActivity.configureFlutterEngine`, and a channel handler exists only on the engine
   that registered it. A headless engine calling it would have received
   `MissingPluginException` — which `AndroidKeystoreProtectedStorage` does not catch, so
   it would have propagated out of `SecureLocalStorageRuntime.open()`. The same was true
   of the message-alert channel. Both are now Context-bound classes with exactly one
   implementation each, and `MainActivity` keeps only what genuinely needs a window: the
   permission dialog, the settings screen, `FLAG_SECURE`, and the clipboard.
2. **The supervisor armed and disarmed the scheduler on lifecycle transitions.**
   `_enterBackground` called `polling.schedule`, `_resumeForeground` called
   `polling.cancel`. Against a *periodic* platform job that is a defect rather than a
   detail: registering one restarts its window, so a user who opens the application more
   often than the interval would never receive a single wake-up, and a process that died
   while foregrounded would have left nothing scheduled at all. Arming moved to the
   session.
3. **`SyncLifecycleSupervisor.dispose()` did not cancel polling**, so a job armed for a
   session would have outlived logout.

### Research findings

All from primary sources, read 2026-08-21, plus the pinned Android SDK sources
(`android-35`) and the pinned Flutter engine sources shipped with Flutter 3.44.7.

**Deferrable jobs are the only mechanism inside this scope.** Everything Android offers
for running without the user, and why each does or does not survive the exclusions:

| Mechanism | Needs from the user | Verdict |
|---|---|---|
| `JobScheduler` / `WorkManager` periodic job | nothing | **the only candidate** |
| Foreground service (`specialUse`, ADR-046 Layer 2) | battery-optimization exemption, notification permission, per-vendor setup | out of scope by definition; still unbuilt |
| `setExactAndAllowWhileIdle` | `SCHEDULE_EXACT_ALARM`, which the user can revoke | out of scope, and see below |
| `setAndAllowWhileIdle` | nothing | in scope, and rejected on evidence below |
| `BOOT_COMPLETED` receiver | nothing (normal permission) | not needed: `setPersisted(true)` does it |
| `MY_PACKAGE_REPLACED` receiver | nothing | rejected: deliverability not established, see *outstanding validation* |
| Sync adapter | a visible account | worse than a job in every respect, and Doze stops it too |
| Home-screen widget `updatePeriodMillis` | the user must place a widget | out of scope |
| Platform push (FCM) | nothing | excluded by ADR-013 and unreachable in the outage this deployment exists for |
| UnifiedPush / self-hosted distributor | a second app, a second service | out of scope here; ADR-046 rejected it and nothing has changed |
| SMS wake | a phone number and an SMS permission | rejected outright by ADR-046 on the threat model |

**What the job floor actually is.** `JobInfo.java` in the pinned API 35 SDK:
`MIN_PERIOD_MILLIS = 15 * 60 * 1000L`, and `setPeriodic` logs and silently raises anything
shorter. `MIN_FLEX_MILLIS = 5 * 60 * 1000L`, and flex is clamped to
`max(5% of the period, 5 minutes)`, so a 15-minute job is eligible in the last five
minutes of each period. `setPeriodic`'s own contract is an upper bound on frequency, not
a lower bound on delivery: "You have no control over when within this interval this job
will be executed, only the guarantee that it will be executed **at most** once within
this interval, as long as the constraints are satisfied."

**Doze suspends what a catch-up needs.** In Doze the system "suspends network access",
"ignores wake locks", "defers standard `AlarmManager` alarms" and "doesn't let
`JobScheduler` run. `WorkManager` uses `JobScheduler` internally, so `WorkManager` tasks
don't run", releasing them only in maintenance windows of which "over time … the system
schedules … less frequently"
([Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)).

**Two standby buckets have no background network at all, and an unopened app lands in
one.** The power table gives, per bucket: *active* — 20 min of jobs per rolling hour, no
network restriction; *working set* — 10 min per 4 h; *frequent* — 10 min per 12 h;
*rare* — 10 min per 24 h, **network disabled**; *restricted* — once per day for 10 min,
**network disabled**
([power details](https://developer.android.com/topic/performance/power/power-details)).
The same page notes that "execution quota behavior for jobs changed in Android 16. Prior
to Android 16 there was no execution limit when the app is in the active standby bucket",
which Android 16's own notes confirm reaches "tasks scheduled using WorkManager,
JobScheduler, and DownloadManager"
([Android 16 behavior changes](https://developer.android.com/about/versions/16/behavior-changes-all)).
Decisively for this deployment: "On Android 13 (API level 33) and higher, unless your app
qualifies for an exemption, the system places your app in the restricted bucket … [when]
the user doesn't interact with your app for a specific number of days … Android 13
reduces the number of days to 8", and in that bucket "restricted jobs don't run by
themselves. There must be at least one other job running or pending at the same time"
([app standby buckets](https://developer.android.com/topic/performance/appstandby)).
The same page also records the counter-pressure this design gets for free: the system
does **not** treat an app as idle while "the app generates a notification that users see
on the lock screen or in the notification tray", and an app returns to *active* when
"the user taps on a notification that your app sends". A catch-up that finds a message
and alerts (ADR-048) is therefore self-reinforcing; a catch-up that finds nothing for
eight days is not, and that is the honest limit.

**While-idle alarms buy nothing here, and the two primary sources disagree about how
little.** The Doze page says "neither `setAndAllowWhileIdle()` nor
`setExactAndAllowWhileIdle()` can fire alarms more than once per nine minutes, per app".
The pinned SDK's own `AlarmManager.java` javadoc is less generous: "Under normal system
operation, it will not dispatch these alarms more than about every minute …; **when in
low-power idle modes this duration may be significantly longer, such as 15 minutes**",
and the dispatch grants only that "the app will also be added to the system's temporary
power exemption list for **approximately 10 seconds**". Ten seconds does not cover a
Keystore unwrap, a SQLCipher open, a TLS handshake to a private CA and a drain. Alarms
are also bucket-quota'd (one per hour in *rare*, one per day in *restricted*), do not
survive a reboot, and the javadoc restricts the API to cases "where it is actually
required that the alarm go off while in idle — a reasonable example would be … a calendar
notification". Rejected on all four counts, more firmly than ADR-046 rejected it.

**A job is the one thing that both runs and has a network.** `JobScheduler`'s own
javadoc: "While a job is running, the system holds a wakelock on behalf of your app", and
the network constraint means the job is not started until there is one. Its limits are
recorded honestly: from Android 12 "jobs will still be stopped after 10 minutes if the
system is busy or needs the resources"; from Android 14 the scheduler "may try to optimize
job execution by shifting execution to times with more available system resources", and
`onStartJob` that does not return "within several seconds" is an ANR; `JobService`
"executes each incoming job on a Handler running on your application's main thread".
`setPersisted(true)` carries `@RequiresPermission(RECEIVE_BOOT_COMPLETED)` and is what
loads the job at boot, so no receiver of this application's own is needed.

**A backgrounded process cannot hold anything.** Android 14: "an app's process is in a
cached state when it's moved to the background", and "shortly after an app process enters
a cached state, background work is disallowed". AOSP: "if all processes for a particular
app are frozen, the system terminates any active TCP sockets maintained by the app"
([cached apps freezer](https://source.android.com/docs/core/perf/cached-apps-freezer)).
This is why a catch-up opens no socket, and why an unacknowledged wake-up is not a slow
catch-up but an interrupted one.

**Force-stop is absolute.** An app the user force-stops, or that has never been launched
since install, receives no broadcasts and runs no scheduled work until it is launched
manually. No architecture changes this.

**Data Saver is a user setting this design cannot and will not work around.** With Data
Saver on and the device on a metered network, "the system blocks background data usage";
an app may ask for an allowlist exemption through
`ACTION_IGNORE_BACKGROUND_DATA_RESTRICTIONS_SETTINGS`
([Data Saver](https://developer.android.com/training/basics/network-ops/data-saver)).
Asking is out of scope for this piece by definition, so it is disclosed instead.

**One process, one Dart VM — verified in source, not assumed.** The pinned Flutter engine
states in `dart_vm_lifecycle.h` that "there can only be one VM running in the process at
any given time", and `DartVMRef::Create` reuses a running one; `IsolateNameServer` is
owned by that `DartVM` and its Dart-side documentation says "all isolates share a global
mapping of names to ports". Two `FlutterEngine`s in one Android process therefore share
one VM and one name server — which is also why `drift_flutter`'s
`shareAcrossIsolates: true`, already used by this application, connects a headless isolate
to the *same* database server isolate rather than opening a second connection to the same
SQLCipher file.

**The headless entry point is a documented Flutter API.** `new FlutterEngine(context)`
registers generated plugins automatically (verified in `FlutterEngine.java`), and
`DartExecutor.executeDartEntrypoint(DartEntrypoint(bundlePath, functionName))` runs a
named top-level function. Plugins Flutter generates are registered; **channels this
application registers on its activity are not**, which is finding 1 above.

### Alternatives evaluated

**1 — Nothing; keep `UnscheduledBestEffortPolling` (the status quo).** Costs nothing,
leaks nothing, promises nothing, and is exactly what the disclosure said. Rejected as the
answer, because the question is what happens when the application is not open, and for a
private messenger with no push the difference between "never" and "usually within tens of
minutes" is the difference between usable and not.

**2 — Tell the user something arrived without draining it.** There is no such signal
without push, and inventing one would mean announcing something this device has not
authenticated. Rejected: it is the one thing ADR-046's Layer 3 principle forbids.

**3 — Do the catch-up in Kotlin.** Would avoid a second Dart context entirely. Rejected
outright: the drain, the envelope inspection, the ratchet, the group stack and the
projection are Dart over a reviewed Rust core, and a Kotlin reimplementation would be a
second, unreviewed copy of the security-critical path.

**4 — `androidx.work` (ADR-046 as written).** The documented recommendation, and it
handles reboot rescheduling itself. Rejected. At `minSdk` 24 WorkManager delegates to
`JobScheduler` anyway, and `setPersisted(true)` gives the reboot property directly. What
it would add is a Room database, a `SystemJobService`, a `RescheduleReceiver`, an
`androidx.startup` `InitializationProvider` and `RECEIVE_BOOT_COMPLETED` — merged
invisibly into the manifest of an artifact whose manifest is an audited surface — in
order to schedule one job. ADR-048 set the precedent for exactly this trade and the
evidence points the same way. The existing test forbidding the `workmanager` package
therefore stands unchanged and now records a decision rather than an absence.

**5 — The `workmanager` Flutter plugin.** Adds all of the above plus a plugin, a
`SharedPreferences`-held callback handle, and a generic background channel. Rejected for
the same reasons, more so.

**6 — A self-rescheduling one-shot job with `setMinimumLatency` and
`setOverrideDeadline`.** A deadline gets better treatment from the Android 14 shifting
behaviour. Rejected on two counts: `setOverrideDeadline` runs the job when the deadline
expires **even if its constraints are not met**, which means waking with no network; and a
chain that fails to reschedule itself once is a chain that is broken permanently, while a
periodic job is self-healing by construction.

**7 — While-idle alarms.** Rejected on the four grounds recorded under *Research*.

**8 — Keeping ADR-046's durable Drift delivery lease.** ADR-046 required "a durable
leased row in Drift with an owner identity and a heartbeat, not an in-memory flag, so a
crash releases it and a restart reclaims it". Re-examined against evidence and
**rejected**. Its stated advantage does not exist here: a crash of the process releases an
in-memory flag too, because the process is what held it, and there is no second process to
coordinate with — the job service is declared with no `android:process`, and one Dart VM
per process is the engine's own documented invariant. What it would cost is real: a
heartbeat writing to an encrypted database on a timer forever, and a stale lease after a
crash that blocks catch-up until it expires. What replaces it is more precise, not weaker
— see below.

**9 — Letting the two owners overlap and only protecting the token refresh.** Tempting,
because the refresh is the sharpest hazard. Rejected: `beginNextEnvelopeInspection`
deliberately selects rows in `received` *or* `inspecting` so a crashed inspection is
retried, which means two concurrent engines would hand the same envelope to the ratchet
twice; and the post-inbox composite runs group KeyPackage maintenance, pending eviction
and outbound dispatch, whose concurrency properties are not established. Exclusion covers
the whole cycle.

**10 — Killing an in-flight headless run when the user opens the application.** Equivalent
to process death for the durable engine, which it is built to survive. Rejected anyway:
the run may be inside an FFI call into the shared native cryptographic core, and abandoning
one is a worse trade than waiting the seconds a catch-up takes.

### Decision

**One persisted periodic `JobScheduler` job at the platform floor, delivered to whichever
Dart isolate already exists, and to a headless one only when none does.**

**The mechanism.** `JobInfo.Builder(JOB_ID, DeferredDeliveryJobService)` with
`setPeriodic(max(requested, JobInfo.getMinPeriodMillis()))`,
`setRequiredNetworkType(NETWORK_TYPE_ANY)` and `setPersisted(true)`. The floor is read
from the platform rather than repeated as a number. No dependency is added: `JobInfo` is
in the framework at `minSdk` 24. The service is a plain service — `exported="false"`,
`android:permission="android.permission.BIND_JOB_SERVICE"`, no `foregroundServiceType`,
no `android:process` — so the job scheduler is the only thing that can start it and
everything runs in the one process the ownership argument rests on.

**Arming belongs to the session, not to the lifecycle.** A `MessageDeliverySession` arms
the job once when it starts and disarms it when it stops; the supervisor no longer
schedules or cancels anything. This is the correction of finding 2: a periodic job
restarts its window each time it is registered.

**Exactly one delivery owner, arbitrated in the process rather than in the database.**
`onStartJob` runs on the application's main looper, and so does
`FlutterActivity.configureFlutterEngine`. `MainActivity` registers its engine's channel as
the delivery owner and clears it in `cleanUpFlutterEngine`. A tick therefore takes one of
three paths, decided on that one thread:

- a live activity engine exists → `runCatchUp` is invoked into that isolate, the
  supervisor runs one cycle, and the job finishes when the reply arrives. This is the
  common case: a cached process keeps its engine for as long as the system leaves it
  alone, and starting a second engine beside it is precisely the hazard;
- no engine exists → a headless `FlutterEngine` is created, this application's
  protected-storage, message-alert and delivery channels are attached to it, and the
  `backgroundDelivery` entry point runs;
- a headless run is already in flight → the tick is dropped.

For the one remaining race — the user opening the application while a headless run is in
flight — the foreground **waits**. `MessageDeliverySession.compose` calls
`awaitExclusiveOwnership()` before it opens storage or reads a token, and the platform
completes it when the headless run ends.

**A tick is acknowledged.** `BestEffortDeliveryTick.complete()` is what tells the platform
the wake-up may end, and it is called unconditionally — including when the cycle failed or
was refused for want of a network — because the scheduler is asking whether the process
may be let go, not whether delivery succeeded. The adapter applies its own two-minute
deadline so a stalled owner cannot hold the wake-up open until the platform's ten-minute
limit kills it mid-drain.

**The headless run holds nothing.** It opens **no socket**: a cached process is frozen and
its TCP sockets are terminated, so a connection is not a thing a bounded wake-up can own.
It restores the session, runs one `DurableSyncEngine.synchronize()` — the same engine, the
same store, the same inspector, the same group stack — reconciles the alert from committed
state, and stops. It runs the alert pass even when the drain failed, because an alert is a
projection of committed local state and messages committed by an earlier run may still
never have been announced.

**Both entry points compose through one `ApplicationRuntime`.** The provisioned
`SecurityContext`, the single `TokenCoordinator` and the environment-gated crypto core are
built in one constructor that `bootstrap()` and the headless entry point both call. The
dangerous background failure is not a crash; it is a quieter posture — the public root
store instead of the provisioned authority, a second coordinator, a crypto core without
the compiled environment's permit — and this removes the possibility rather than testing
for its absence.

**Which build a background run believes it is, is compiled in.** Each flavor's entry-point
file exports a `@pragma('vm:entry-point')` `backgroundDelivery()` that names its own
`AppEnvironment`. The platform picks a *name*; which environment that name resolves to is
decided by which file was compiled, so nothing about the provisioned server, the trust
anchor or the closed-beta group permit is selectable at runtime. A build asked for an
entry point it does not contain fails to start one, which is the fail-closed direction.

### Correctness questions, answered

- **What causes the work, and what stops it?** A periodic job armed when a device-bound
  full session starts. It stops on logout, when a headless run finds no session (it
  disarms itself), on force-stop, and on uninstall. It does not stop on a locked phone or
  a dropped connection, because neither says anything about the next attempt.
- **What may it assume?** Nothing. It reconstructs storage, configuration, trust, crypto
  and session for itself, in the same order and through the same constructor the activity
  uses.
- **What if protected state cannot be opened?** It concludes `storageUnavailable`: nothing
  read, nothing written, nothing announced, no marker spent, schedule untouched. The
  device being locked after a restart reaches here, and it can never be mistaken for
  "nothing was waiting" because it does not touch the mailbox at all.
- **What if another part of the application is doing the same job?** It cannot be. A live
  engine takes the tick itself; a headless run blocks a foreground session from composing
  until it finishes; a second job tick while one is in flight is dropped.
- **What if it is interrupted mid-way?** Identical to process death, which the durable
  engine is designed for: every write is a transaction, an abandoned drain leaves
  committed state consistent, and an envelope left `inspecting` is picked up again.
- **The very first time?** There is no session, so nothing is armed; enrollment arms it.
- **After force-stop?** Nothing, until the user opens the application. Disclosed, not
  engineered around.
- **How is failure surfaced?** It is not surfaced as an event at all. There is no
  background error state and no notification about failing to check — that would be noise
  the user cannot act on. What the user has is the alert when something *is* delivered,
  and one sentence in the enrollment disclosure telling them what not to rely on.
- **What does the application now claim?** Revision 3, in both catalogues.

### Security and privacy

- **What the new entry point can reach**: exactly what the activity reaches, because it
  composes from the same constructor — and nothing that needs a window. `FLAG_SECURE`,
  the clipboard, the permission dialog and the settings screen stay on `MainActivity` and
  are unreachable from a headless engine.
- **Transport trust cannot be silently absent.** One `ApplicationRuntime` builds the
  provisioned `SecurityContext`; the headless path contains no
  `TransportSecurity.platformDefault`, no second `NetworkingFoundation`, no second
  `TokenCoordinator` and no second `DioRestClient`, and an architecture test asserts each
  of those absences.
- **Credentials**: obtained by restoring the same device-bound session, refreshed through
  the same single-flight coordinator, invalidated the same way. Two coordinators are what
  this design exists to prevent, and the cost of failing was traced to its end: 401
  `invalid_token` from the backend, `_endsSession`, `store.clear()`, and a user signed out
  who did nothing.
- **Protected material** is opened only when the platform can unwrap it, which is after
  first unlock. The application is not direct-boot aware, so the platform itself withholds
  the job until then; the Dart path fails closed on top of that rather than relying on it.
- **What an untrusted server or a network attacker can cause.** Nothing new. The job's
  cadence is set by the platform, not by anything on the wire, so a hostile relay cannot
  increase how often this device wakes; it can only make each drain find nothing. Envelope
  flooding costs battery, not correctness, and the existing backoff and circuit-breaker
  paths bound it. Nothing that fails authentication reaches `messages`, so nothing a
  server sends can produce an alert.
- **What it writes or leaves behind**: one job record in the platform's own scheduler
  store, containing an id, an interval and a component name. Nothing else. No log line,
  no file, no preference. The Kotlin half contains no `Log.` and no `println`, asserted by
  test.
- **New metadata, stated plainly.** A device that catches up in the background makes its
  online periods visible to the server on a roughly-fifteen-minute cadence whether or not
  its owner is present. The server is already an untrusted relay that sees every drain, so
  this creates no new party and no new class of observation — but it does make an idle
  device look like an active one, and that is a real change from an artifact that only
  ever spoke while its owner was looking at it.
- **Truthfulness of what is declared to the platform.** The one service is what it says it
  is: a job service, bound with `BIND_JOB_SERVICE`, showing no notification, holding no
  connection, claiming no foreground-service type. `RECEIVE_BOOT_COMPLETED` is declared
  because `setPersisted(true)` requires it and for no other purpose; no receiver is
  declared. Nothing here describes work as something it is not in order to obtain
  behaviour the platform would otherwise withhold.

### Reliability, stated honestly

**Guaranteed — these are guaranteed *restrictions*, and no test run can disprove them:**
a force-stopped application runs nothing; the periodic floor is fifteen minutes and a
shorter request is silently raised; the *rare* and *restricted* buckets disable background
network; Android 13+ places an app in *restricted* after eight days without interaction
unless exempt; a cached process is frozen and its TCP sockets terminated; a job is stopped
after ten minutes when the system wants the resources; `setPeriodic` promises *at most*
one run per interval, never at least one.

**Merely permitted — a green run proves nothing:** that a job runs at any particular
moment; that a maintenance window arrives promptly; that a vendor's build honours the
schedule at all; that a cached process survives long enough for its engine to take the
tick; that `setPersisted` work is restored across an application upgrade.

**What was observed here:** nothing about timing. No device or emulator run was possible
(see *Outstanding validation*), so every timing statement above is documentation, not
measurement.

| Condition | Tier | What actually happens |
|---|---|---|
| Foreground, network up | **Near-real-time** (seconds) | Socket hint → REST drain → commit → alert if the conversation is not on screen |
| Backgrounded, process alive, *active*/*working set* bucket | **Eventual, minutes** | The job wakes the existing isolate; fifteen minutes at best, and only if Doze is not deferring it |
| Backgrounded, process gone | **Eventual, minutes** | A headless engine is started for one drain; same cadence, higher cost per run |
| Device in Doze | **Eventual, hours** | Jobs run only in maintenance windows, which the system schedules less frequently the longer the device is idle |
| Not opened for eight days (Android 13+) | **None** | *Restricted* bucket: background network disabled, one batched job a day that will not run alone |
| Data Saver on, metered network | **None** | Background data blocked; asking for the exemption is out of scope for this piece |
| Force-stopped, or battery usage set to "Restricted" | **None** | Unfixable by any design |
| After a reboot, before first unlock | **None, safely** | Not direct-boot aware, and the database key is credential-encrypted; the job is restored and waits |
| After a reboot, after first unlock | **Best-effort** | `setPersisted(true)` restored the job with no receiver of this application's own |
| Intermittent connectivity | **Eventual, no loss inside 7 days** | The network constraint holds the job until there is one; seven-day server retention; `pruned_through` turns permanent loss into a visible blocking state rather than silence |

### Failure modes

- **The platform refuses to schedule.** Caught; delivery reverts to foreground-only, which
  is what the artifact already tells its users can happen.
- **No implementation behind the channel** (a host test, a future Web build). The port
  resolves to `UnscheduledBestEffortPolling` and says so; nothing pretends to be armed.
- **The owner never acknowledges a tick.** The adapter answers after two minutes, and the
  platform's own ten-minute limit is behind that.
- **A headless run hangs.** The platform side tears the engine down after four minutes,
  which is equivalent to process death and leaves committed state consistent.
- **The platform stops the job** (`onStopJob`: constraints no longer met, quota, the
  system wanting the resources). Whatever is in flight is released — the headless engine
  is destroyed, or a tick handed to the foreground is settled — and `false` is returned so
  the job is rescheduled by its own periodic policy rather than backed off. Nothing
  inconsistent is left behind, because every durable write is a transaction.
- **The user opens the application mid-run.** The session waits, bounded by that same
  deadline. If the platform stops answering the ownership question altogether, the wait
  fails after five minutes and the session composes nothing rather than proceeding as
  though it had established that it is the only owner.
- **A run finds no session.** It disarms the job, so a signed-out device is not woken
  every interval to rediscover it.
- **A run cannot open storage.** It concludes nothing and leaves the job armed.
- **Logout while a job is armed.** The session disarms it; if that call fails, the next
  headless run disarms it instead.
- **An upgrade cancels the job.** Not established either way (see below); the next launch
  re-arms it.

### User requirements

**None.** No permission the user can refuse, no exemption to grant, no vendor setting to
change, no second application to install. The two permissions in the manifest that this
piece touches are `RECEIVE_BOOT_COMPLETED` (normal, install-time, no prompt) and, from
ADR-048, `POST_NOTIFICATIONS` — which gates being *told*, not being *delivered to*: a
catch-up with notifications refused still drains, commits and marks unread.

What the user can nevertheless do that silently disables it, all disclosed:

1. Force-stop the application, or set its battery usage to "Restricted".
2. Not open it for eight days on Android 13+, which moves it to the *restricted* bucket.
3. Turn on Data Saver and stay on a metered network.
4. A vendor's own battery manager doing any of the above on the user's behalf, which on
   this fleet is the likeliest of the four and the one nothing in this repository can
   detect.

### Beta and production

Suitable for both, now, subject to the device matrix below for any *claim* about timing.
It adds no dependency, introduces no cryptographic surface, crosses no production gate,
and leaves the Beta/Production separation exactly as ADR-042 and ADR-044 left it —
verified after the change against the built artifact: the production release packages
unsigned, carries the production application ID, and exports no beta MLS symbol.

It changes what the artifact says about itself. ADR-045's `DisclosurePoint` is renamed
`bestEffortDelivery`, its text is rewritten in both catalogues, and
`DeploymentDisclosure.revision` moves 2 → 3. Per ADR-045's mechanism that makes every
later enrollment re-acknowledge, and **re-delivering the written handover disclosure to
existing recipients is release-blocking** — a requirement that was already outstanding
from ADR-048 and is now outstanding at a higher revision.

### Known limitations

- **Eventual is the ceiling.** Nothing in this piece can produce near-real-time background
  delivery; that is ADR-046's Layer 2 and it is deliberately out of scope here.
- **An application nobody opens for eight days stops receiving anything in the
  background**, and the user most likely to be caught by that is the one who has not been
  messaged recently — which is exactly the person an urgent message would be for.
- **The OEM half is unmeasured**, and 77% of the target fleet is Samsung or Xiaomi.
- **A live-engine tick depends on the process still being cached.** How long that lasts is
  the system's decision and varies by device and memory pressure.
- **Battery and data cost are real but small**: one wake-up per interval at best, holding
  a wakelock for the seconds a drain takes, over a connection that must already exist for
  the job to start.

### Outstanding validation

None of the following could be established here, and none may be inferred from the passing
checks:

1. **That the job runs at all on a device.** No physical device was available, and the
   installed emulator images are Play-Store images without root; reaching a signed-in
   session on this workstation is additionally blocked by server-side account activation.
   Everything about timing in this record is documentation, not observation.
2. **That a headless `FlutterEngine` starts the `backgroundDelivery` entry point in the
   release AOT snapshot.** What *is* established: the entry-point name, both channel names
   and `runDeferredDeliveryEntryPoint` all survive tree-shaking into the shipped
   `libapp.so`. That the platform can then look the function up and run it needs a device.
3. **Whether a persisted job survives an in-place application upgrade.** Not specified by
   the platform documentation that could be found, and therefore not assumed. Mitigated by
   re-arming on every session start. `ACTION_MY_PACKAGE_REPLACED` was **not** used: the
   background-execution-limits exemption list does not name it, and the page's note about
   package broadcasts not being exempt names `ACTION_PACKAGE_REPLACED` rather than the
   targeted variant, so its deliverability to a manifest receiver on a modern release is
   undocumented either way.
4. **The device matrix**: Doze, standby-bucket transitions, the eight-day restricted-bucket
   move, reboot, force-stop, Data Saver, and vendor battery managers, on Samsung and Xiaomi
   hardware and an AOSP image across Android 11 to 16. Release-blocking for any *claim*
   about timeliness; not release-blocking for shipping the mechanism, which cannot make
   anything worse than the absence it replaces.

### Follow-up work

1. **Re-deliver the written handover disclosure** at revision 3 to existing recipients.
   Release-blocking, and inherited from ADR-048.
2. **The device matrix** above.
3. **ADR-046's Layer 2** (`specialUse` foreground service, opt-in, off by default) remains
   the only route to near-real-time background delivery and remains unbuilt. Nothing here
   forecloses it: it would hold the same connection, drive the same engine, and reuse the
   ownership arbitration this decision introduces.
4. **Group messages still produce no alert**, because the piece-18 group projection sets no
   unread state (ADR-048). A background catch-up that drains a group message therefore
   commits it silently.

### Review and revisit conditions

Reopen when any of the following becomes true:

1. **The platform changes the job floor, the standby-bucket network rules, the eight-day
   restricted-bucket rule, or the freezer.** Every tier above rests on those four.
2. **Layer 2 ships.** The ownership arbitration then has a third owner to consider, and a
   foreground service changes which bucket the application sits in.
3. **The device matrix shows the job does not run on Samsung or Xiaomi even unconfigured.**
   Then this floor is not a floor for this fleet, and the honest answer is to say so rather
   than to keep the mechanism as reassurance.
4. **The application ever needs a second process.** The whole ownership argument is that
   there is one, and an `android:process` attribute anywhere would invalidate it. An
   architecture test fails if one appears.
5. **The backend grows a push endpoint**, which reopens ADR-046 alternative 6 and would
   make this floor much less load-bearing.
6. **The deployment stops being 20–30 known people receiving a written handover.** The
   disclosure this decision rewrote is calibrated to a reader who was handed the artifact
   in person.

This decision implements ADR-046's Layer 1, replaces its `WorkManager` mechanism and its
durable delivery lease for the reasons recorded above, amends ADR-045's delivery
disclosure to revision 3, reaffirms ADR-013 and ADR-043, adds no dependency, changes no
cryptographic behaviour, and opens no production gate.

## ADR-048 in full — how the user finds out a message arrived (2026-08-21)

### The question

A message has been drained, authenticated, decrypted and committed to this device's
database. The user is not looking at that conversation. **How do they find out — once,
correctly, and without being told anything untrue?**

ADR-046 answered the surrounding question, "how does a backgrounded client learn an
envelope is waiting", and sketched an answer to this one in three sentences of its
Layer 3. ADR-047 built its Layer 0. This decision is the piece in between: the one that
turns a committed row into something a person notices. Nothing was assumed — not the
presentation mechanism, not the trigger point, not the marker, not the dependency, and
not ADR-046's own sketch.

### What the repository actually did before

Verified in the composed application on 2026-08-21, not in its documentation:

| Component | Existed | Reachable at runtime |
|---|---|---|
| Delivery path (socket, engine, drain, commit) | yes | **yes**, since ADR-047 |
| `messages.unread` written inside the inbox transaction | yes | yes |
| `conversations.unread_count`, `muted_until` | yes | yes |
| Any notification port, adapter, channel or dependency | **no** | no |
| Any record of which conversation is on screen | **no** | no |

So the delivery half was real and the alert half did not exist in any form. Two further
findings came out of that inspection and are recorded here because they change what could
honestly be built:

1. **A message that arrives while its conversation is on screen is still marked unread.**
   `ChatConversationView` marks a conversation read exactly once, from a post-frame
   callback in `initState`. Nothing re-marks it while the route stays mounted. So
   `messages.unread` alone cannot answer "is the user looking at this", and an alert path
   that assumed it could would announce messages the user was watching arrive.
2. **Inbound group messages set no unread state at all.**
   `DriftGroupRepository.commitMessageInsideTransaction` inserts into `messages` without
   `unread` and updates `conversations` without `unread_count`, so a group message leaves
   no unread trace anywhere. This is a pre-existing gap in the piece-18 group projection,
   not in this one; its consequence for this decision is stated under *Known limitations*
   and it is deliberately **not** fixed here, because `GroupChatPage` also never marks a
   group read, so setting the flag would produce a badge nothing could clear.

### Research findings

All read at primary source on 2026-08-21, against `minSdk` 24 / `targetSdk` 36 /
`compileSdk` 36 as pinned by Flutter 3.44.7.

**Notifications need a runtime permission that can be refused, and refused permanently.**
`POST_NOTIFICATIONS` arrived in Android 13 (API 33); "if a user installs your app on a
device that runs Android 13 or higher, your app's notifications are off by default", and
on refusal "your app can't send notifications unless it qualifies for an exemption. All
notification channels are blocked"
([notification permission](https://developer.android.com/develop/ui/views/notifications/notification-permission)).
An app targeting 33+ "has complete control over when the permission dialog is displayed" —
and that control is finite: "if the user taps Deny for a specific permission more than once
during your app's lifetime of installation on a device, the user will no longer see the
system permissions dialog if your app requests that permission again. The user's action
implies 'don't ask again,' and is considered a permanent denial"
([requesting permissions](https://developer.android.com/training/permissions/requesting)).
`shouldShowRequestPermissionRationale` is false both *before* the first request and *after*
the permanent denial, so the platform cannot distinguish those two states for the
application.

**Every notification needs a channel, and its behaviour is the user's after the first
post.** Channels are mandatory from Android 8.0 (API 26): "if you target Android 8.0 (API
level 26) or higher and post a notification without specifying a notification channel, the
notification doesn't appear and the system logs an error". "After you create a notification
channel, you can't change the notification behaviors. The user has complete control at that
point. However, you can still change a channel's name and description"
([channels](https://developer.android.com/develop/ui/views/notifications/channels)).
The platform source for `NotificationChannel` in the API 35 SDK confirms the constructor
defaults this decision relies on: `mSound = Settings.System.DEFAULT_NOTIFICATION_URI`,
`mVibrationEnabled = false`, `mLights = false`, `mShowBadge = true`, and
`mLockscreenVisibility = VISIBILITY_NO_OVERRIDE` — so a per-notification visibility is what
actually applies. `enableVibration(boolean)` carries no `@RequiresPermission` annotation.

**What a lock screen shows is the application's choice.** `setVisibility()` takes
`VISIBILITY_PUBLIC` ("the notification's full content shows on the lock screen"),
`VISIBILITY_PRIVATE` ("only basic information, such as the notification's icon and the
content title") or `VISIBILITY_SECRET` ("no part of the notification shows on the lock
screen")
([create a notification](https://developer.android.com/develop/ui/views/notifications/build-notification)).
Android 15 adds a second consumer of the same mechanism: "notification content is hidden
during screen sharing sessions to preserve the user's privacy. If the app implements
`setPublicVersion()`, Android shows the public version of the notification which serves as
a replacement notification in insecure contexts. Otherwise, the notification content is
redacted without any further context"
([Android 15 behavior changes](https://developer.android.com/about/versions/15/behavior-changes-all)).

**Tapping must go through a `PendingIntent`, and it must be immutable.** "Apps that target
Android 12 or higher can't start activities from services or broadcast receivers that are
used as notification trampolines", and "if your app targets Android 12, you must specify the
mutability of each `PendingIntent` object that your app creates"
([Android 12 behavior changes](https://developer.android.com/about/versions/12/behavior-changes-12)).

**More than one notification is a shade full of them.** "If your app sends four or more
notifications and doesn't specify a group, the system automatically groups them on Android
7.0 and higher", and grouping requires the app to build and maintain a summary
notification; "you always need to manually set a summary to enable grouped notifications"
([grouped notifications](https://developer.android.com/develop/ui/views/notifications/group)).
Conversation notifications go further still: "**MessagingStyle**: … Your notifications must
be created with this style to use Android's conversation features", together with long-lived
share shortcuts
([conversations](https://developer.android.com/social-and-messaging/guides/communication/notifications-conversations)).
The per-package notification cap is not a documented API — `NotificationManagerService`
carries a constant near 50, OEMs vary it, and there is no way to query it — so a design
whose count grows with traffic is a design whose behaviour is unspecified. Android also
rate-limits: updates posted many times in less than a second may be dropped, and from
Android 8.1 an app "cannot make a notification sound more than once per second".

**Android 16 introduces nothing here.** Its all-apps behaviour changes cover JobScheduler
quota, broadcasts, ART, 16 KB pages, accessibility announcements, navigation, themed icons,
intent redirection and Bluetooth; none of them touches posting, channels, ranking or the
permission
([Android 16 behavior changes](https://developer.android.com/about/versions/16/behavior-changes-all)).

**The dependency question answers itself.** `flutter_local_notifications` 22.3.0 (pub.dev,
read 2026-08-21) is current, requires Flutter 3.38.1 or newer, needs no Firebase and no
Play services — it would work. But `NotificationCompat`, `NotificationManagerCompat`,
`NotificationChannelCompat` and `ActivityCompat` all live in `androidx.core:core`, which
this build **already declares at 1.16.0** for `FileProvider`, and `MainActivity` already
owns two method channels. Every API this decision needs is therefore already on the
classpath.

### Alternatives evaluated

**Presentation.**

**1 — Nothing; rely on the unread badge (the status quo).** Costs no permission, leaks
nothing, needs no platform code. Rejected: it answers "how does a user who opens the app
find out" and the question is about a user who does not.

**2 — An in-app banner only.** Correct and free while the app is foregrounded, and worth
having later. Rejected as the answer, because it says nothing to a user who has switched to
another app, which is most of the window in which delivery still works.

**3 — One notification per message, bounded, plus a group summary.** This is the shape
ADR-046 sketched. Rejected on the evidence above. With a sender-neutral preview, N
notifications are N copies of one sentence, so the only thing they add over one
notification is a per-message identifier visible to the system notification service and to
any application the user has granted notification access. They also drag in summary
management, automatic-grouping differences across OEMs, and an unspecified per-package cap.

**4 — One notification per conversation, with `MessagingStyle` and conversation
shortcuts.** The mainstream messenger design, and the one Android optimises for. Rejected
squarely on the threat model. It requires a stable per-conversation notification id and a
long-lived share shortcut, which publish a pseudonymous per-contact identifier into
`system_server` and the launcher, where they persist and can be correlated over time by
anything holding notification access. `MessagingStyle` exists to show senders and message
text. The threat model names "a person with filesystem access to a locked but otherwise
uncompromised Android device" as an adversary and lists "notification previews" among
protected assets; this option trades directly against both, and buys a per-conversation tap
target that a sender-neutral alert cannot use anyway.

**5 — One aggregate notification, sender-neutral, tapping to the launcher. Selected.**
One id, one tag, one channel, one sentence. See below.

**6 — Full previews (sender and message text) by default.** Rejected. It is the single
change that would most improve the experience and it is the wrong default for a deployment
of 20–30 people in Iran, where a name on a lock screen implicates two people rather than
one. Not shipped even as an opt-in in this piece: the switch is small, but the reviewed
bilingual warning around it is not, and adding a way for a user to make themselves less
safe is not a good use of the first notification release. Recorded as follow-up.

**Trigger.**

**7 — Emit from `PostInboxCommitWorkPort`, as ADR-046 specified.** It is a real
post-commit hook and it would work for the announce case. Rejected as the whole answer:
it fires only when the sync engine runs, so it cannot *withdraw*. A user who opens the app
and reads a conversation, or who reads it on another device, leaves the alert standing in
the shade until the next drain. Every question this piece has to answer that is not
"announce" — read elsewhere, withdrawn by its sender, conversation opened, mute applied —
is a change to committed state that no post-drain hook observes.

**8 — Reconcile from a durable-state signal. Selected.** Drift buffers table updates
inside a transaction and dispatches them to the parent stream store only after `COMMIT`
(`Transaction.complete()` runs before `disposeChildStreams()`, verified in the pinned
drift 2.34.2 source), so a stream over `messages` and `conversations` is a strictly
post-commit trigger. This preserves ADR-046's actual principle — an alert is a projection
of committed local state and never of a transport event — more directly than the hook did,
and it makes withdrawal fall out of the same rule as announcement.

**Marker.**

**9 — `notified_at` timestamp, per ADR-046.** Rejected in favour of a boolean
`messages.alerted`. Nothing in the design reads the time, a timestamp would be one more
wall-clock value to reason about under skew, and a column nothing reads is a column that
will eventually be read for the wrong reason.

**Dependency.**

**10 — `flutter_local_notifications` 22.3.0.** Rejected: it would add a maintained
dependency, a plugin registration, and a second scheduling/timezone surface, to reach APIs
already on the classpath through `androidx.core:core:1.16.0`. ADR-046 step 8 stated the
preference for app-owned Kotlin behind a port for exactly this surface, and the evidence
supports it. No dependency is added by this decision.

### Decision

**The user is told by one system notification that says only that something arrived, and
that notification is a reconciliation of committed local state rather than an event.**

**One alert.** A single notification, fixed id and tag, in one channel whose id
(`"messages"`) is frozen for the life of the installation because it keys the user's own
sound and importance settings. Its entire content is `New message` or `New messages` —
grammatical number and nothing else. No sender, no conversation, no text, no count, no
timestamp (`setShowWhen(false)`). It is `VISIBILITY_PRIVATE` and supplies a
`setPublicVersion` carrying the same sentence, so a lock screen and a screen-sharing
session show exactly what the application chose rather than whatever the system's own
redaction produces.

**Tapping carries nothing.** The content intent is the launcher intent obtained from
`getLaunchIntentForPackage`, wrapped `FLAG_IMMUTABLE`, with `setAutoCancel(true)`. There is
no destination, no extra, and no identifier — so there is nothing to validate, nothing to
forge, and no path that could bypass the routing guards that already stand between an entry
point and content. Tapping opens the application exactly as its icon does, and the guards
decide what may be shown.

**A reconciliation, not an emission.** Each pass reads the committed rows that are unread,
not deleted for this device, not withdrawn by their sender, and not in Saved Messages;
subtracts the muted conversations and the conversation currently on screen; and brings the
shade into agreement with what is left. Announce when something un-alerted survives that
subtraction, withdraw when nothing survives it at all. Every hard case falls out of that
one rule instead of needing its own.

**Idempotence is durable.** `messages.alerted` (schema 12) is spent in the same pass that
posts. It survives a projection rebuild because the projector writes messages through
`insertOnConflictUpdate` with a companion that omits the column — drift documents that
"columns from the old row that are not present on [entity] are unchanged" — the same
mechanism that already preserves `starred`. It is written *after* a successful post, never
before: a crash in between costs one repeated alert on the same notification id, while the
opposite order costs a message the user is never told about.

**Deliberate silence still spends the marker.** A message suppressed because its
conversation is muted or on screen is marked alerted without being announced. Without that,
leaving the conversation or outliving the mute would produce a late alert for something the
user has already seen or has asked not to hear about.

**What could not be delivered is not spent.** When the platform refuses — no permission, no
implementation, a failed post — no marker is spent, so granting permission later announces
the backlog instead of losing it.

**"On screen" is a conjunction.** `VisibleConversationRegistry` reports a conversation only
when its route is mounted *and* the application is in the foreground. A chat route left
mounted behind a backgrounded application is not something anyone is looking at. An
unreported lifecycle state at launch is read as foreground, for the same reason ADR-047
gave: Flutter leaves `lifecycleState` null until the first platform message, and the
opposite reading would silence every alert until one arrives.

**One automatic prompt, at the point of use, guarded twice.** The permission is requested
the first time a message is waiting that cannot be announced, and only while the
application is foregrounded, because the prompt belongs to an activity the user is looking
at. It is guarded by a durable marker in `local_preferences` — which stops it repeating on
every launch — and by Android's own `shouldShowRequestPermissionRationale`, which is true
in exactly one situation, the user has refused once and not yet twice. Honouring the second
guard means an automatic prompt can never be the refusal that makes the denial permanent,
and it means a refusal the user made from Settings is respected even though Settings writes
no marker of its own.

**Settings states the truth and offers one action.** The row reads the operating system,
not the application's beliefs, and shows three states: on, off, or not available in this
build. When off, one button asks Android, and falls through to this application's own
notification settings screen when asking changed nothing — so one tap always ends somewhere
the user can act, and never on a button that silently does nothing.

**The platform side holds no policy.** `MainActivity` gains one method channel that reports
what Android says, posts the sentence Dart hands it, withdraws it, and opens the settings
screen. Nothing identifying a conversation, a sender or a message crosses it. Every
decision is Dart, so every decision is covered by host tests.

### What is guaranteed and what is merely permitted

**Guaranteed, and testing cannot disprove it:** a refused `POST_NOTIFICATIONS` blocks every
non-exempt channel; a second refusal is permanent and the application can no longer prompt;
a channel's importance cannot be changed after creation; a notification posted without a
channel on API 26+ does not appear; sound is capped at once per second from Android 8.1.

**Merely permitted, and a green test run is evidence of nothing:** that a heads-up appears
on a given vendor's build; that vibration occurs; that the notification survives however
long the user leaves it; that a vector drawable renders identically as a status-bar icon
across the fleet; that the per-package cap is where AOSP puts it.

**And the tier this piece actually delivers:** an alert reaches the user only while the
application's process is alive. ADR-046's Layers 1 and 2 remain unbuilt, this build still
composes `UnscheduledBestEffortPolling`, and nothing re-arms after Android stops the app.
That is a real limit and it is now what the enrollment disclosure says.

### Failure modes

- **Permission refused, or revoked after being granted.** Nothing is announced, no marker
  is spent, and Settings says so plainly. Granting later announces the backlog.
- **A crash between posting and marking.** The same notification id is re-posted on the
  next pass, so the user sees one notification and may hear one extra sound. Chosen over
  the alternative, which loses the message silently.
- **A burst of arrivals.** Passes are serialized behind a dirty flag and a pass spends every
  marker it read, so a wave of commits collapses into one alert. Verified at 25 messages in
  one transaction.
- **A backlog larger than one read page.** The read is ordered so unspent markers come
  first, so consecutive passes drain it rather than returning the same page. Because there
  is only ever one notification, those extra passes update it rather than adding to a pile.
- **Storage unavailable.** The pass concludes nothing: nothing posted, nothing withdrawn,
  no marker spent, so the next pass reaches the same conclusion.
- **No platform implementation.** Resolves to *unavailable*; nothing is posted and the
  Settings row says so, rather than a screen failing.
- **A hostile relay floods envelopes.** Nothing that fails authentication reaches
  `messages`, so nothing it sends can produce an alert. What it can do is cause repeated
  bounded drains, which is the cost ADR-046 already accepted.
- **A stale alert from a previous process.** The first pass of a session assumes one may be
  posted and withdraws it when nothing is outstanding, which is what covers a message read
  on another device while this one was not running.

### Security and privacy

- **On an unlocked device, a bystander sees** the application name and `New messages`.
  **On a locked one, the same**, by declaration rather than by the system's redaction.
  **During screen sharing on Android 15+, the same again**, through `setPublicVersion`.
- **To an application holding notification access**: the package name, that same sentence,
  one constant id and one constant tag. No conversation, no sender, no count, no timing
  beyond the moment of posting, and nothing that can be correlated per contact.
- **New metadata created on the device**: one boolean per message row inside the existing
  SQLCipher database, and one preference key recording that the permission prompt was
  shown. Both are erased with the database by the existing wipe paths. Nothing is written
  outside it, and `allowBackup="false"` is unchanged.
- **Logs**: nothing is logged. The channel carries a localized sentence and nothing derived
  from content, identifiers or keys.
- **Forgery and suppression by a server or a network attacker**: an alert can only be
  produced by a row that survived authenticated decryption and a durable commit, so a relay
  cannot cause one. It can suppress by withholding envelopes, which it could already do.
- **Credentials and keys**: no component gains access to anything it did not hold. The
  platform side receives strings.
- **The safe posture is the only posture.** There is no preview setting to get wrong, and
  the one user action available — turning notifications on — increases what the device
  shows only by the sentence above.
- **Permissions added**: `POST_NOTIFICATIONS` (dangerous, runtime, requested at point of
  use) and `VIBRATE` (normal, granted at install, no prompt). No foreground service, no
  boot receiver, no exact alarm, no SMS. The architecture test that forbids
  `remoteMessaging` and `FOREGROUND_SERVICE_DATA_SYNC` is untouched and a new one forbids
  every foreground-service and boot permission outright while ADR-046's layers stay
  unbuilt.

### User requirements

One, and it is unavoidable: on Android 13 and above the user must allow notifications.
They are asked once, automatically, at the moment a message is waiting that cannot be
announced, and never again automatically. Everything after that is theirs: Settings offers
the action whenever they want it, and the channel's sound, vibration and importance are
theirs to change from the moment it first appears. There is no vendor setup to explain,
because this piece starts no service and schedules no work.

### Beta and production

Suitable for both, now. It introduces no cryptographic surface, crosses no production gate,
adds no dependency, and leaves the Beta/Production separation exactly as ADR-042 and
ADR-044 left it — verified after the change: the production release still packages
unsigned, still carries the production application ID, and still contains no beta MLS
symbol.

It does change what the artifact says about itself. ADR-045's
`DisclosurePoint.foregroundDeliveryOnly` read "Messages arrive only while this app is open.
There are no notifications and nothing runs in the background", and the second clause is now
false. `DeploymentDisclosure.revision` moves 1 → 2, the text is rewritten to say that
messages arrive and the application can alert only while it is running and that nothing
re-arms once Android stops it, and both language catalogues move with it. Per ADR-045's
mechanism, that makes every later enrollment re-acknowledge, and **re-delivering the
written handover disclosure to existing recipients is release-blocking**.

### Known limitations

- **Nothing reaches a user whose application Android has stopped.** This is ADR-046's
  Layers 1 and 2, and they are still unbuilt.
- **Group messages produce no alert**, because the piece-18 group projection sets no unread
  state (see *What the repository actually did before*). The alert path needs no change when
  that is fixed; the group projection and `GroupChatPage` do.
- **A message that arrives while its conversation is on screen stays unread** after the user
  leaves it. That is the pre-existing mark-read behaviour, unchanged here; this decision only
  makes sure it is never announced.
- **No preview option**, so a user cannot tell which conversation an alert is about without
  opening the application.
- **The Kotlin half is unmeasured.** No device or emulator run was possible: the available
  images are Play-Store images without root, and reaching a signed-in session on this
  workstation is blocked by server-side account activation. What the notification looks like,
  whether the vector icon renders correctly in the status bar, whether the channel vibrates,
  and how the permission dialog behaves are all **unverified on a device**.
- **A refusal made from Settings is not recorded durably**, so in one sequence — turn on
  from Settings, refuse — the automatic prompt may still be spent later. Android's rationale
  flag prevents that in the common case; the residue is at most one extra dialog, ever.

### Follow-up work

1. **Device matrix for this piece**: Android 13 first-install prompt, refusal, second
   refusal, revocation after grant, lock-screen rendering, heads-up, status-bar icon,
   channel settings, and the Persian rendering of both strings — on Samsung, Xiaomi and an
   AOSP image across Android 11 to 16. Release-blocking for any claim about what the user
   sees.
2. **Re-deliver the written handover disclosure** to existing recipients — still not done,
   and now outstanding at revision 3, which ADR-049 moved it to.
3. **Group unread state** in the piece-18 projection, plus mark-read in `GroupChatPage`;
   the alert path then covers groups with no change.
4. **Mark-read while a conversation is on screen**, which also makes read receipts correct.
5. **An in-app presentation** for the foregrounded case, so an alert does not appear over
   the application that produced it.
6. **A preview setting**, if and only if the reviewed bilingual lock-screen warning is
   written first.

### Review and revisit conditions

Reopen when any of the following becomes true:

1. ~~**ADR-046's Layer 1 or Layer 2 ships.**~~ **Layer 1 shipped 2026-08-21 — ADR-049**,
   and this prediction held exactly: the alert path needed no change, because a headless
   run supplies a `VisibleConversationPort` reporting the truth — nothing on screen, not
   in the foreground — and the existing `visible.isForeground` guard is therefore what
   keeps the single automatic prompt from being spent into a context with no activity.
   What did *not* hold is the prerequisite: ADR-049 replaced the durable delivery lease
   with in-process arbitration on evidence. Layer 2 shipping still reopens this.
2. **The deployment stops being 20–30 known people receiving a written handover.** The
   sender-neutral default is calibrated to a threat model where a name on a lock screen
   implicates two people; a different population may weigh that differently.
3. **Voice ships.** A microphone foreground service posts its own notification, and the
   interaction between the two must be decided rather than discovered.
4. **Android changes the permission model, the channel contract, or lock-screen
   redaction.** Every claim above about what a bystander sees rests on `setVisibility`,
   `setPublicVersion` and channel-level user control.
5. **The device matrix contradicts anything in "merely permitted".**

This decision implements ADR-046's step 2 and amends its Layer 3 sketch — one aggregate
alert instead of bounded individual notifications plus a summary, a durable-state
reconciliation instead of a post-inbox-commit emission, and a boolean marker instead of a
timestamp — for the reasons recorded above. It amends ADR-045's
`DisclosurePoint.foregroundDeliveryOnly` and moves the disclosure to revision 2. It adds no
dependency, changes no cryptographic behaviour, opens no production gate, and leaves the
Beta/Production boundary untouched.

## ADR-046 in full — how a backgrounded Android client learns a message arrived (2026-08-21)

### The question

The deployment is roughly 20–30 private users in Iran. The failure condition this
project is built for is that international connectivity is unavailable while domestic
connectivity keeps working, and the backend is inside Iran and stays reachable through
the domestic network. Backend reachability is therefore **not** the problem this
decision solves and is treated as given.

The problem is the one that remains after the server is reachable: **when the user is
not looking at the application, how does the Android client find out that an envelope is
waiting in its domestic mailbox, and how does it tell the user?**

No technology was assumed. `WebSocket`, polling, WorkManager, foreground services, local
notifications and platform push were all treated as candidates to be argued for or
rejected on evidence, including the ones already named in ADR-029 and in
`platform-android.md`.

### What the repository actually does today

Inspection of the composed application, not of its documentation, found this:

| Component | Exists in `lib/` | Composed into the running app |
|---|---|---|
| `DurableSyncEngine` (drain, inspect, commit, ack, outbox) | yes, 509 lines, tested | **no** |
| `SyncLifecycleSupervisor` (lifecycle, reconnect, backoff, polling triggers) | yes, 299 lines, tested | **no** — constructed only in tests |
| `DioWebSocketGateway` (authenticated socket, close-code mapping) | yes, 381 lines, tested | **no** |
| `GatewayRealtimeSyncAdapter` (socket event → drain hint) | yes | **no** |
| `NetworkingFoundation` (the one client + coordinator + gateway) | yes | **no** — nothing constructs it |
| `AndroidPollingScheduler` | port only | no adapter exists |
| Local notifications | — | no dependency, no port, no adapter |

`durableSyncEngineProvider` is declared in `lib/app/dependencies/sync_providers.dart`
and is read by nothing: a repository-wide search for it, for `syncProjectionProvider`,
for `SyncLifecycleSupervisor` and for `GatewayRealtimeSyncAdapter` returns their
declarations and their unit tests, and no presentation, controller, router or bootstrap
reference at all. `bootstrap.dart` composes `AuthenticationAssembly`, which builds a REST
client and a token coordinator and no socket.

The consequence is larger than a missing notification. `SendConversationEvents` ends at
`fanout.prepareAndQueue`, which writes durable outbox rows; the component that would
transmit them is the engine that never runs. **In the artifact as composed, a sent
message is queued locally and never leaves the device, and an incoming envelope is never
drained.** Sending and receiving are both unwired, not merely un-notified.

### The defect this decision had to resolve first

ADR-044 and ADR-045 tell every recipient, in the mandatory enrollment disclosure, that
"messages arrive only while this app is open". Measured against the composed artifact
that sentence is not conservative, it is **wrong in the user's favour**: messages do not
arrive while the app is open either. The disclosure describes ADR-029's intended
architecture rather than the shipped one.

That correction is recorded here because it changes what this decision is. This is not
"add notifications to a working messenger". It is "decide the delivery and notification
architecture for a messenger whose delivery path exists, is tested, and has never been
plugged in". Any notification mechanism chosen below is worthless until that path is
composed, so composing it is step one of the follow-up work and is not optional.

### Exact network and deployment assumptions

Fixed for this decision:

- International connectivity may be entirely unavailable; domestic Iranian connectivity
  keeps working and reaches the backend.
- The backend is inside Iran, is the authoritative durable mailbox
  (`GET /api/v1/me/envelopes`, seven-day TTL, `pruned_through`), and also offers the
  `wss://<host>/ws` gateway, whose `envelope` frame the client already treats as a
  wake-up hint only.
- Distribution is a directly installed signed APK under the frozen Beta identity
  (ADR-042, ADR-044). **Google Play policy does not bind this artifact**, because it is
  never submitted to Play. Platform behaviour still binds it completely.
- `minSdk` 24, `targetSdk` 36, `compileSdk` 36 (Flutter 3.44.7 defaults, read from the
  pinned SDK on 2026-08-21). The client must therefore behave correctly against Android
  16 restrictions while still running on Android 7.
- Fleet: Statcounter for Iran, July 2026, read 2026-08-21 — Samsung 46.34%, Xiaomi
  30.98% (77% combined); Android 13 20.38%, 14 15.77%, 16 14.09%, 12 13.60%, 11 13.55%,
  15 10.10%. The two most aggressive OEM background-management vendors are the fleet, and
  every supported release from 11 to 16 is materially represented.
- ADR-013 stands: no foreign push, no Firebase, no foreign runtime call. FCM is excluded
  twice over — by decision, and by the premise that Google's servers are unreachable
  exactly when this application is most needed.

### Research findings — what Android actually guarantees

All from primary sources, read 2026-08-21.

**A process that is merely backgrounded cannot hold a connection.** Android 14 states
that "an app's process is in a cached state when it's moved to the background and no
other app process components are running", and that "shortly after an app process enters
a cached state, background work is disallowed, until a process component re-enters an
active state of the lifecycle"
([behaviour changes, all apps](https://developer.android.com/about/versions/14/behavior-changes-all)).
AOSP is blunter about what happens next: "When an app process is frozen, all of its
threads are suspended and can't perform CPU work until unfrozen", and "if all processes
for a particular app are frozen, the system terminates any active TCP sockets maintained
by the app"
([cached apps freezer](https://source.android.com/docs/core/perf/cached-apps-freezer)).
A background `WebSocket` with no running component is not slow; it is closed by the
platform.

**Deferrable jobs are quota-bound, and in two standby buckets have no network at all.**
Android's power-management table
([power details](https://developer.android.com/topic/performance/power/power-details))
gives, per app standby bucket: *active* — jobs up to 20 min per rolling 60 min, no
network restriction; *working set* — 10 min per 4 h, 10 alarms/h; *frequent* — 10 min per
12 h, 2 alarms/h; *rare* — 10 min per 24 h, 1 alarm/h, **network disabled**;
*restricted* — once per day for up to 10 min, one alarm per day, **network disabled**.
The same page notes "execution quota behavior for jobs changed in Android 16. Prior to
Android 16 there was no execution limit when the app is in the active standby bucket",
which Android 16's own notes confirm applies to "tasks scheduled using WorkManager,
JobScheduler, and DownloadManager"
([Android 16 behaviour changes](https://developer.android.com/about/versions/16/behavior-changes-all)).
`WorkManager`'s floor is fixed: "the minimum repeat interval that can be defined is 15
minutes (same as the JobScheduler API)"
([define work](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)).

**Doze suspends the very things a poll needs.** In Doze the system "suspends network
access", "ignores wake locks", "defers standard `AlarmManager` alarms", "doesn't let
sync adapters run" and "doesn't let `JobScheduler` run. `WorkManager` uses
`JobScheduler` internally, so `WorkManager` tasks don't run", releasing them only in
maintenance windows that "over time … the system schedules … less frequently"
([Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)).
While-idle alarms are the escape hatch and are themselves throttled: "neither
`setAndAllowWhileIdle()` nor `setExactAndAllowWhileIdle()` can fire alarms more than once
per nine minutes, per app", and the power table caps while-idle alarms at 7 per hour.

**A foreground service is the one documented way to keep both the process and the
network.** The power table's app-state axis gives "app process is running a foreground
service → Network: No restrictions", and by Android 14's own definition a process with a
running service component is not cached, so it is not frozen and its sockets are not
terminated. Foreground services are not equal, though:

- `dataSync` "is not allowed to launch … from a `BOOT_COMPLETED` broadcast receiver" for
  apps targeting Android 15+, and is capped: "the system permits an app's `dataSync`
  services to run for a total of 6 hours in a 24-hour period", after which
  `Service.onTimeout()` fires and a failure to stop produces
  `RemoteServiceException`, while a further start throws
  `ForegroundServiceStartNotAllowedException`
  ([Android 15 behaviour changes](https://developer.android.com/about/versions/15/behavior-changes-15),
  [FGS timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout)).
- `shortService` runs "about 3 minutes" and ANRs if it overruns.
- `remoteMessaging` has no runtime prerequisite, no timeout and no boot restriction, but
  its documented description is narrow: "Transfer text messages from one device to
  another. Assists with continuity of a user's messaging tasks when they switch devices."
- `specialUse` "covers any valid foreground service use cases that aren't covered by the
  other foreground service types", has no runtime prerequisite, no timeout and no boot
  restriction, and asks the developer to declare the use case in a manifest `<property>`
  whose values "are reviewed when you submit your app in the Google Play Console"
  ([FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types)).
- `systemExempted` is gated on being a device owner, VPN, emergency-role or exact-alarm
  app, and otherwise throws `ForegroundServiceTypeNotAllowedException`.

**Starting that service from the background is allowed in exactly the cases we have.**
Apps targeting Android 12+ "can't start foreground services while the app is running in
the background, except for a few special cases", and the enumerated exemptions include
receiving `ACTION_BOOT_COMPLETED`, `ACTION_LOCKED_BOOT_COMPLETED` or
`ACTION_MY_PACKAGE_REPLACED` in a receiver, invoking an exact alarm for a user-requested
action, and — decisively — "the user turns off battery optimizations for your app"
([background-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)).

**Android's own guidance sanctions the battery-optimization exemption for precisely this
application.** The Doze page's acceptable-use table lists "instant messaging, chat, or
calling app" twice. Where the app *can* use FCM, exemption is "Not Acceptable — use FCM
high priority messages". Where the app answers "no, can't use FCM because of technical
dependency on another messaging service or Doze and App Standby break the core function
of the app", exemption is "**Acceptable**". What the exemption buys is stated exactly:
"an app that is partially exempt can use the network and hold partial wake locks during
Doze and App Standby. However, other restrictions still apply … its regular
`AlarmManager` alarms don't fire." The Play-policy sentence attached to that table does
not reach a directly distributed APK, but the technical grant does.

**Notifications need a permission that can be refused.** `POST_NOTIFICATIONS` arrived in
Android 13; "if a user installs your app on a device that runs Android 13 or higher, your
app's notifications are off by default", and on refusal "your app can't send
notifications unless it qualifies for an exemption. All notification channels are
blocked"
([notification permission](https://developer.android.com/develop/ui/views/notifications/notification-permission)).
An app targeting 33+ chooses when to ask.

**Force-stop is absolute.** An app the user force-stops, or that has never been launched
since install, is in the stopped state and receives no broadcasts and runs no scheduled
work until the user launches it manually. No architecture changes this.

**OEM behaviour is the fleet's dominant variable and is not specified by AOSP.** Android
itself only says "the precise restrictions imposed are determined by the device
manufacturer"
([background-task restrictions](https://developer.android.com/develop/background-work/background-tasks/bg-work-restrictions)).
Community documentation for Samsung ("put apps to sleep", adaptive battery, unused-for-
three-days background start blocking, settings that revert after updates) and Xiaomi
(autostart permission, MIUI/HyperOS battery saver) is not normative evidence and is
recorded here as a *risk to be measured on devices*, not as a fact this decision rests
on. It is the reason the physical-device matrix is a release gate rather than a nicety:
77% of the target fleet is Samsung or Xiaomi.

### Alternatives evaluated

**1 — Foreign push (FCM/APNs).** Rejected on the premise, not on preference. FCM's
transport is Google infrastructure reached over international links; during the exact
outage this deployment exists for, it is unreachable. ADR-013 already forbids it. It is
also the only mechanism whose absence Android's own documentation accepts as grounds for
the Doze exemption, so its rejection is what unlocks alternative 5.

**2 — Foreground-only delivery (the status quo, and ADR-029's practical outcome).**
Works while the app is open, needs no permission, costs no battery, leaks nothing, and
provides *no* notification. It is what the current disclosure promises. Rejected as the
final answer, because the whole question is what happens when the app is not open — but
kept as the innermost layer, since it is strictly the best tier when it applies.

**3 — Deferrable background work only (WorkManager/JobScheduler), i.e. ADR-029 as
written.** Survives reboot through WorkManager's own rescheduling, needs no special
permission, costs little battery, and is the mechanism the backend contract names ("no
foreign push (FCM/APNs) is available. Background polling only", `CLIENT_CONTRACT.md` §L).
Its ceiling is hard: 15-minute floor, Doze deferral to maintenance windows that thin out
over time, Android 16 quota enforcement even in the active bucket, and **no network at
all** in the *rare* and *restricted* buckets — which is where an app the user has not
opened for days will sit. It yields *eventual* notification and cannot honestly be
described as anything better. Rejected as the primary mechanism; **retained as the
guaranteed floor**, because it is the only layer that needs nothing from the user.

**4 — While-idle alarms (`setAndAllowWhileIdle` / `setExactAndAllowWhileIdle`).**
Slightly better best-case cadence than WorkManager (nine minutes rather than fifteen) and
fires inside Doze. Rejected: the exact variant needs `SCHEDULE_EXACT_ALARM`, which the
user grants and can revoke — and on revocation "your app stops, and all future exact
alarms are canceled" — or `USE_EXACT_ALARM`, whose acceptable use is an alarm-clock or
calendar core function this application does not have; alarms are cancelled by reboot and
must be re-armed from a boot receiver; and, fatally, an alarm that fires in the *rare* or
*restricted* bucket wakes an app that still has no network. It buys six minutes of
best-case latency for a revocable permission and a semantic overstatement.

**5 — An opt-in persistent connection held by a foreground service.** The only
mechanism that produces near-real-time delivery without Google. It defeats the freezer by
keeping a service component running, and the power table grants that state unrestricted
network; the battery-optimization exemption, which Android's own table calls acceptable
for a chat app that cannot use FCM, additionally grants network and partial wake locks
during Doze and App Standby, and is itself an exemption from the Android 12 background
FGS-start restriction. Costs: a permanent status-bar entry, real battery use, two user
permissions, per-OEM setup on 77% of the fleet, and nothing at all after force-stop.
**Selected, as an opt-in layer above the floor.**

**6 — Self-hosted push through UnifiedPush (a domestic ntfy/NextPush distributor).**
Genuinely the right pattern in general: one distributor app carries the persistent
connection for many applications, the push server can be self-hosted inside Iran, and no
Google dependency appears. Rejected here for four reasons, any one of which is
sufficient. (a) The backend has no push endpoint of any kind and this work may not modify
backend files, so the server half cannot be built. (b) It requires every user to install
and configure a second application and the project to operate a second self-hosted
service, for a 20–30 person deployment. (c) The distributor learns *when* each user
receives a message; that timing metadata moves outside the reviewed trust boundary to a
component this project does not sign, pin, review or update, which is a worse trade than
the one it replaces. (d) It does not remove the Android constraint — the distributor
needs the same foreground service, the same exemption and the same OEM settings — it
relocates it into software the project cannot fix. Worth revisiting only if the backend
ever grows a push endpoint and the metadata question is answered.

**7 — SMS-triggered wake.** The one mechanism genuinely independent of data
connectivity, and the only one rejected on security grounds alone. It requires an SMS
receive permission, requires the backend to send SMS, binds every account to a phone
number held by a carrier, and hands the carrier a precise log of who is messaged and
when. That is the opposite of this project's threat model. Rejected outright.

**8 — `dataSync` or `remoteMessaging` for the foreground service, or `systemExempted`.**
`dataSync` is disqualified by the platform: 6 hours per 24, and no launch from
`BOOT_COMPLETED` at `targetSdk` 35+. `remoteMessaging` is technically unrestricted but
describes device-to-device message continuity, not "hold a socket to my own server";
`platform-android.md` already forbids reaching for it to dodge lifecycle policy, and that
rule survives this decision. `systemExempted` is gated on roles this app does not have.

### Decision

**Delivery and notification are layered, each layer honest about its tier, and all of
them converge on the one durable engine that already exists.**

**Layer 0 — compose what is already built (mandatory, no user action).**
`SyncLifecycleSupervisor`, `GatewayRealtimeSyncAdapter`, `DioWebSocketGateway` and the
platform adapters are wired into the application, attached to the **single**
`TokenCoordinator` and the **single** provisioned-CA `SecurityContext` that
`AuthenticationAssembly` already owns. No second REST client, no second coordinator, no
second trust context. Socket frames stay what they already are: wake-up hints that
trigger an authoritative REST drain and never carry trusted content.

**Layer 1 — best-effort deferrable catch-up (mandatory, no user action).** An Android
`WorkManager` adapter behind the existing `AndroidPollingScheduler` port: a periodic
request at the platform floor with a connected-network constraint, plus one-shot requests
on connectivity recovery and on `ACTION_BOOT_COMPLETED`. Its headless entry point
reconstructs protected storage, database, transport and engine and runs the same
`DurableSyncEngine.synchronize()`. It promises nothing exact and never starts a service.

**Layer 2 — an opt-in persistent-connection foreground service (off by default).** A
`specialUse` foreground service that keeps the process non-cached so the already-composed
socket survives, declared with a truthful
`android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE`. It hosts the same Dart isolate and the
same supervisor; it adds no second delivery implementation. It is started when the user
enables background delivery, and re-started from an `ACTION_BOOT_COMPLETED` receiver.
Enabling it walks the user through `POST_NOTIFICATIONS`, through
`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, and through the vendor settings the
application cannot check for itself.

**Layer 3 — notification as a projection of durable local state.** A `NotificationPort`
whose only trigger is the existing `PostInboxCommitWorkPort` composite, running after the
inbox transaction commits. It reads rows that are committed, unread, and not yet
notified; it posts; it records a durable `notified_at` in the same transaction. Nothing
about the transport reaches it.

**Exactly one delivery owner at a time.** The foreground isolate, the service isolate and
the headless worker isolate must never run the engine concurrently: they would open
several sockets and, far worse, several `TokenCoordinator` instances racing on a
*rotating* refresh token, which can invalidate the session. Ownership is a durable
leased row in Drift with an owner identity and a heartbeat, not an in-memory flag, so a
crash releases it and a restart reclaims it. Layer 1 stands down while Layer 2 holds the
lease — the supervisor already cancels polling whenever it takes over.

### Why `specialUse`

`specialUse` is the type Android defines for "any valid foreground service use cases that
aren't covered by the other foreground service types", and holding an authenticated
connection to the application's own self-hosted server, in a country where the platform's
push transport is unreachable, is exactly such a case. It carries no timeout, no
`BOOT_COMPLETED` prohibition and no runtime prerequisite, and its mandatory subtype
property is a place to write the truth in the manifest rather than a place to hide.
`remoteMessaging` would be a semantic overstatement of a type that means device
continuity; `dataSync` would be both an overstatement and technically unusable. The
existing architecture test that forbids `remoteMessaging` and
`FOREGROUND_SERVICE_DATA_SYNC` in the manifest therefore remains correct and unchanged,
and this decision does not weaken it.

Play review is not a factor because this artifact is never submitted to Play; if that
ever changes, the subtype property already states the justification, and "the deployment
country cannot reach FCM" is a real one.

### Notification versus synchronization

They are deliberately different mechanisms and this decision keeps them apart.

- **Discovery** has three independent triggers — a socket `envelope` frame, a
  lifecycle/network/lease transition, and a WorkManager tick — and all three do the same
  thing: request one engine cycle.
- **Retrieval** is always the authoritative REST drain with post-commit acknowledgement.
  A socket payload is never the message.
- **Unread state** is already durable and already maintained: `conversations.unread_count`
  and `messages.unread` are written by `DriftApplicationEventProjector` inside the commit
  transaction and cleared by the conversation repository on read.
- **Notification** is generated only from that committed state, only after authenticated
  decryption, and never from an envelope that was quarantined, rejected, or blocked by
  queue-gap recovery.
- **Duplicates** are prevented twice: envelope identity already deduplicates delivery, and
  a durable `notified_at` marker prevents a second notification for a row a re-drain
  re-observes. A durable marker is required precisely because the notifying isolate may
  not be the one that comes back.
- **Missed notifications recover by query, not by replay.** Everything unread and
  un-notified is eligible at the next successful commit pass, with a bounded number of
  individual notifications and one grouped summary beyond that threshold, so returning
  from three days offline produces a summary rather than two hundred alerts.

### Reliability, stated honestly in four tiers

No architecture available on Android delivers a **guaranteed** notification, and none
delivers an **immediate** one; that is true with a platform push service and is more true
without one. What this decision buys is the best available tier under each condition.

| Condition | Tier | What actually happens |
|---|---|---|
| App foreground, domestic network up | **Near-real-time** (seconds) | Socket hint → REST drain → commit → in-app state; a notification only if the conversation is not on screen |
| Backgrounded, Layer 2 enabled, exemption granted, OEM settings correct | **Near-real-time, best-effort** | Socket held by the `specialUse` service; same path; the platform *permits* this indefinitely but guarantees nothing |
| Backgrounded, Layer 2 off or killed | **Eventual** | 15 minutes at best; in practice bound to Doze maintenance windows, which thin out; **nothing at all** in the *rare* or *restricted* standby buckets, where background network is disabled |
| Force-stopped, or "Restricted" battery setting applied, or `POST_NOTIFICATIONS` denied | **None** | No broadcast, no job, no alarm, no notification, until the user opens the app. Unfixable by any design |
| Intermittent domestic connectivity | **Eventual, no loss inside 7 days** | Backoff reconnect, drain on every recovery, seven-day server retention, `pruned_through` turning permanent loss into a visible blocking state rather than silence |
| Process killed by the system (memory pressure) | **Best-effort recovery** | The service is restarted by the platform and Layer 1 re-runs; neither is promised |
| After reboot | **Best-effort** | `ACTION_BOOT_COMPLETED` restarts Layer 2 and rearms Layer 1 — but only if the app has been launched at least once since install and has not been force-stopped. `ACTION_LOCKED_BOOT_COMPLETED` is deliberately **not** used: the database key is credential-encrypted and nothing can be decrypted before first unlock |

### What Android guarantees, and what it merely permits

The distinction is load-bearing and must never be blurred in a user-facing string.

**Guaranteed (these are guaranteed *restrictions*, and testing cannot disprove them):** a
force-stopped app runs nothing; `dataSync` is capped at 6 h/24 h and cannot start from
`BOOT_COMPLETED` at `targetSdk` 35+; *rare* and *restricted* buckets have no background
network; a cached process is frozen and its TCP sockets are terminated; `POST_NOTIFICATIONS`
denial blocks every non-exempt channel; `WorkManager`'s periodic floor is 15 minutes.

**Merely permitted (a green test run is evidence of nothing):** that a foreground service
keeps running — the system may still kill it under memory pressure and OEMs kill more
aggressively; that an exempt app keeps network through Doze on a given vendor's build;
that `WorkManager` runs at any particular moment; that `BOOT_COMPLETED` arrives promptly;
that a vendor's battery UI leaves the user's choice in place after a system update.

Every claim in the second group must be measured on the device matrix and may never be
promoted into a promise by observation alone.

### Failure modes

- **The user never grants the exemption, or a vendor silently re-applies its own.**
  Layer 2 degrades to Layer 1 and delivery becomes eventual. The application must detect
  the lost exemption (`isIgnoringBatteryOptimizations()`) and say so plainly rather than
  keep implying real-time delivery.
- **The service is killed and not restarted.** Same degradation; Layer 1 is the floor
  that makes this survivable.
- **The app is force-stopped.** Total silence until manual launch. This is disclosed, not
  engineered around.
- **A hostile relay floods `envelope` hints.** Hints are only triggers; each causes a
  bounded, backed-off REST drain that finds nothing. The cost is battery, not
  correctness, and the existing backoff and circuit-breaker paths bound it.
- **Two isolates race the rotating refresh token.** Prevented by the durable delivery
  lease. This is the single most dangerous implementation mistake available in this design
  and must be covered by a test that runs two owners against one store.
- **A notification for content that was later quarantined.** Prevented by notifying only
  from committed, non-quarantined rows.
- **Notification storm after a long offline period.** Bounded count plus a grouped
  summary.
- **Direct-boot start before first unlock.** Fails closed: the Keystore-wrapped database
  key is unavailable, the worker must abort rather than degrade.

### Security and privacy

- **Client authentication** is unchanged: one device-bound token coordinator, one
  single-flight refresh, one durable token store. Background components attach to it;
  they never mint a second.
- **Transport trust is unchanged and must be re-asserted in every background entry
  point.** The headless isolate and the service must build the same
  `TransportSecurity.provisioned` context (ADR-043); falling back to
  `TransportSecurity.platformDefault()` in a background path would silently restore the
  public root store. This warrants its own architecture test.
- **Server events are not authenticated and are not trusted.** They are hints. All
  authentication remains in the crypto core, behind the drain.
- **Replay and duplicates** are handled by envelope identity, event identity, ratchet
  state and the new durable `notified_at`, not by in-memory state.
- **Notification content keeps the existing rule**: hidden preview by default — app name,
  sender-neutral text, open action — with decrypted previews only as an explicit opt-in
  carrying a lock-screen warning.
- **New exposure this decision creates, stated plainly:** a persistent foreground-service
  notification is a durable, visible indication on the device that this application is
  running, present on the status bar and potentially the lock screen. In this deployment
  that is not a cosmetic cost; it is an observable that survives the user putting the
  phone down, and it is the principal reason Layer 2 is opt-in rather than default. Its
  channel must be low importance, silent, and neutrally worded, and the trade must be
  described to the user in the same voice as the rest of the disclosure.
- **Timing metadata** is unchanged relative to the backend, which already sees when a
  device drains. Holding a socket makes the device's online periods more legible to the
  server, which is already an untrusted relay in the threat model; it does not create a
  new party.
- **No credential leaves its existing boundary.** The service holds no copy of the
  database key or the tokens; it hosts the same isolate and the same composition.

### User and device requirements

Unavoidable, and acceptable for 20–30 trusted users receiving a written handover:

1. Grant `POST_NOTIFICATIONS` (Android 13+). Without it there are no notifications at
   all, whatever the delivery layer does.
2. For Layer 2 only: grant the battery-optimization exemption. Android's own acceptable-
   use table sanctions asking, because this app cannot use FCM.
3. For Layer 2 on most of this fleet: vendor settings — on Samsung, exclude the app from
   "put apps to sleep" and adaptive battery; on Xiaomi, allow autostart and set battery
   saver to no restrictions. The application **cannot verify these** and must say so
   rather than imply it has checked.
4. Do not force-stop the app and do not set its battery usage to "Restricted".

The application explains this once, in one screen reached from enabling background
delivery, in the same plain register as the deployment disclosure: what it will do, what
it costs, what it cannot promise, and what the user must do on their particular phone. It
must not nag, and it must not present the vendor steps as a guarantee.

### Beta and Production

- Layers 0, 1 and 3 are suitable for both Beta and a future Production, once implemented
  and once the device matrix has been run. They introduce no cryptographic surface and
  cross no production gate.
- Layer 2 is suitable for both **as an opt-in that ships off by default**. It is not
  Beta-only — there is no reason a future production build should be worse at delivery —
  but it may not be enabled in any distributed artifact before the physical-device matrix
  on Samsung, Xiaomi and an AOSP image across Android 11 to 16 has actually been run and
  recorded. **Amended 2026-08-22 — ADR-051.** The matrix is still open and still cannot be
  run here, so this clause would not defer the capability, it would cancel it. It is
  replaced on three pieces of evidence ADR-046 did not have — first-party vendor
  documentation, the standby-bucket consequence of the Doze exemption, and a design whose
  permanent indicator is displayed by the platform only while the service is genuinely
  running — and the capability is present and enableable, off by default, with the matrix
  recorded as outstanding validation rather than as a gate nobody can open.
- The Beta/Production artifact separation, the two Cargo profiles, the signing identity
  and `signingConfig = null` on release are untouched. Nothing here weakens the production
  boundary to make the private deployment work, and no production gate is opened.

### Known limitations

- Near-real-time delivery is best-effort and vendor-dependent for 77% of the target
  fleet, and cannot be made otherwise without a push service that does not exist in this
  environment.
- A force-stopped application is silent, permanently, by platform design.
- Layer 1 alone provides nothing in the *rare* and *restricted* standby buckets, which is
  where an unopened app eventually lands.
- Layer 2 makes the application visible in the notification shade whenever it is armed.
- The decision rests on documented platform behaviour; the OEM half rests on community
  reporting and is unmeasured until the device matrix runs.
- No experiment was run for this decision: the available emulator images are Play-Store
  images without root, and no Samsung or Xiaomi hardware was available, so any local
  result would have proved nothing about the fleet that matters.

### Follow-up implementation requirements

In order. Each is a piece of work, not a checkbox.

1. **Compose the delivery path** (Layer 0). ~~Until this lands, nothing else in this ADR
   can be observed to work, and neither sending nor receiving functions at all. Includes
   resolving the two composition roots: `NetworkingFoundation` is currently dead code
   while `AuthenticationAssembly` builds the live client, and the socket must attach to
   the live one.~~ **Done 2026-08-21 — ADR-047.** The two roots are resolved into one
   and the socket attaches to the live coordinator. One correction to the inventory
   above: `NetworkingFoundation` was not "tested and constructed only in tests" — it had
   no tests and no callers at all.
2. ~~**Notification port, `notified_at` column, post-inbox-commit notifier,
   `POST_NOTIFICATIONS` request at point of use.** Useful on its own, before any
   background layer exists.~~ **Done 2026-08-21 — ADR-048**, with three of this
   line amended on evidence: one aggregate alert rather than bounded individual
   notifications plus a grouped summary; a reconciliation driven by committed
   durable state rather than an emission from `PostInboxCommitWorkPort`, which
   can announce but never withdraw; and a boolean `messages.alerted` rather than
   a `notified_at` timestamp nothing reads. The `POST_NOTIFICATIONS` request is
   at point of use and spent at most once automatically.
3. ~~**WorkManager adapter behind `AndroidPollingScheduler`** (Layer 1), with the headless
   entry point reconstructing its own dependencies and failing closed before first unlock.~~
   **Done 2026-08-21 — ADR-049**, with the mechanism amended on evidence: a persisted
   periodic `JobScheduler` job rather than `WorkManager`, because `JobInfo` is in the
   framework at `minSdk` 24 and `setPersisted(true)` survives a reboot, so the dependency
   would only have added a Room database, a service and a boot receiver to an audited
   manifest. Arming also moved off the lifecycle and onto the session, because registering
   a periodic job restarts its window. The headless entry point does reconstruct its own
   dependencies and does fail closed before first unlock, as required here.
4. ~~**Durable delivery lease**, with a test that runs two owners against one store.~~
   **Replaced 2026-08-21 — ADR-049.** The lease was specified for a hazard that is real
   and a topology that is not: the job service is declared with no `android:process`, and
   the Flutter engine documents one Dart VM per process, so every owner this design can
   produce is on one main looper. Ownership is arbitrated there instead — a tick goes to
   the isolate that already exists, a headless engine starts only when none does, and a
   foreground session waits for a headless run rather than racing it. The two-owner test
   this line asked for exists as a composition test that holds ownership and asserts that
   nothing authenticated happens until it is released. **Corrected 2026-08-22 — ADR-050.**
   That test proves less than this sentence claims: its harness replaces the real
   `TokenCoordinator` with a fake session, so "nothing authenticated happens" was true of
   the delivery session and untrue of the application, which rotates the shared refresh
   token during session restoration well before a session composes. The two-owner test
   this line originally asked for now exists as
   `test/features/networking/delivery_owner_contention_test.dart`: two real isolates, one
   real shared SQLCipher store, both orderings, repeated contention, and a contender
   killed mid-rotation. The conclusion that a lease was specified for a topology that does
   not exist is unchanged and was re-derived independently.
5. ~~**`specialUse` foreground service, boot receiver, background-delivery setting, and the
   setup screen** (Layer 2), off by default.~~ **Done 2026-08-22 — ADR-051**, with two of
   this line amended on evidence: there is **no boot receiver**, because the durable choice
   lives in the encrypted database and only a Dart isolate that has opened it knows whether
   there is anything to start — the already-persisted periodic job restores the capability
   instead; and the service hosts its **own** isolate rather than "the same isolate", because
   `FlutterActivity` destroys its engine when the user swipes the application out of Recents,
   which is exactly the case this layer exists for. ADR-051 also adds what this line did not
   ask for and the layer cannot be honest without: a keepalive on the held connection, and a
   reconciliation that *stops* the service whenever the arrangement is incomplete.
6. **Disclosure revision.** Shipping any of steps 2 to 5 makes ADR-045's original
   `DisclosurePoint.foregroundDeliveryOnly` false. `DeploymentDisclosure.revision` must
   move, the text must be rewritten to the tier language above, and the written handover
   must be re-delivered to existing recipients. **Moved twice: 2026-08-21 — ADR-048**
   took it to revision 2 when alerts shipped, and **ADR-049** took it to revision 3 when
   background catch-up did, renaming the point `bestEffortDelivery`. Re-delivering the
   written handover to existing recipients has **not** happened and is release-blocking
   at revision 3.
7. **Device matrix**: Doze, standby buckets, reboot, force-stop, permission revocation,
   exemption revocation and vendor battery settings, on Samsung and Xiaomi hardware and
   an AOSP image, across Android 11 to 16. This is a release gate for Layer 2.
8. **Dependency decision, recorded with pinned versions when it is made.** The preference
   is app-owned Kotlin behind ports for the notification poster and the foreground service
   — both are small, security-relevant surfaces and `MainActivity` already owns two method
   channels — and a maintained plugin only where the platform glue is genuinely large,
   which is the headless Dart entry point. `flutter_local_notifications` 22.3.0,
   `workmanager` 0.10.9 and `flutter_foreground_task` 11.0.1 all exist and none requires
   Firebase or Play services (pub.dev, read 2026-08-21); none is adopted by this decision.

### Review and revisit conditions

Reopen this decision when any of the following becomes true:

1. **The backend grows a push endpoint.** UnifiedPush against a domestic distributor
   becomes buildable, and alternative 6's balance changes — though its metadata question
   must be answered before it is chosen.
2. **A domestic push service the project controls end to end becomes available**, making
   a shared connection cheaper than a per-app one.
3. **Android changes the freezer, the standby-bucket network rules, the `specialUse`
   contract, or introduces a timeout for it.** The whole of Layer 2 rests on `specialUse`
   having no timeout and no boot restriction.
4. **The device matrix shows Layer 2 is unreliable on Samsung or Xiaomi even when
   configured.** Then near-real-time background delivery is not achievable for this fleet
   and the honest answer reverts to Layer 1 plus a truthful statement. Carried into ADR-051
   as its own revisit condition 3, where it additionally requires withdrawing the capability
   rather than leaving it available, and moving the disclosure again.
5. **The user base stops being 20–30 known people receiving a written handover.** The
   per-device setup burden accepted here does not survive that change.
6. **Voice ships.** A microphone foreground service already exists for active calls; the
   interaction between two foreground services and their notifications must be decided
   rather than discovered.

This decision supersedes ADR-029, reaffirms ADR-013, opens no production gate, changes no
cryptographic behaviour, and adds no dependency by itself.

## ADR-045 in full — what the application tells its users about itself (2026-08-20)

**Status:** Accepted. User-facing communication decision. **Opens no production gate.**
Amends two rows of ADR-044's tier table; supersedes nothing.

### The question

ADR-044 defined what the initial deployment *is*. It did not define what the software
*says*. It listed a persistent banner, per-tier honesty on group screens, visibly absent
features, and a written handover disclosure, and it deferred the in-app first-run
disclosure as follow-up work.

That leaves the question this decision answers: **what must a user understand before
using this application, how should the application say it, and what has to be true for
that statement to stay true?** Concretely — one maturity label or several, which words,
where they appear, whether anything must be acknowledged, and who keeps it accurate.

The answer was derived from the running application, not from ADR-044's list. That
matters, because inspecting the surfaces found that ADR-044's list was itself partly
wrong.

### What the application actually said to users, before this decision

Every row was read out of the working tree on 2026-08-20.

| Surface | What a user saw | Verdict |
|---|---|---|
| Shell and Connection banner | "Private experimental build" | Correct. Kept |
| Android launcher label (beta flavor) | "Communication Platform (Experimental)" | Correct. Kept |
| Window and task-switcher title | "Communication Platform (Development)" | **Wrong.** `app.dart` branched on `isProduction` alone, so the Private Experimental artifact named itself a developer build in the task switcher while its own launcher icon said Experimental |
| Navigation rail footer, wide layouts, **every** flavor | "Structural placeholder — not for shipping" | **Wrong.** Developer wording, shown permanently, and flatly false in production. The golden file `shell_wide_dark.png` is a production shell containing it |
| Voice rooms, appearance | "Structural placeholder — not for shipping" plus "The routed voice-room list and detail regions are ready for later feature pieces" | **Wrong.** Engineering vocabulary a user cannot act on, and self-contradictory in a build that does ship |
| Voice rooms placeholder | A button opening `/voice-rooms/sample-room`, another placeholder | Half-presence, which ADR-044 forbids for absent features |
| Group screens | "Experimental group encryption — not reviewed or standardized. An update may reset these groups and delete their messages." | Correct. Kept |
| Edit profile | "Profile encryption and key delivery are using development-only fake transport until pairwise messaging is available. Production remains blocked." | **Wrong in the artifact that ships it.** See below |
| Attachment sheet, reached by the composer's paperclip | "Choose encrypted media or a file." and three options: Photo, File, Camera | **Wrong.** All three are inert |
| Connection screen, five status lines | "Loading secure configurationâ€¦", and four more | **Wrong.** Double-encoded ellipsis, on the first screen every recipient sees |
| Enrollment security notice | What it does and does not protect, with a mandatory "I understand" | Correct, and the right mechanism. Silent about the deployment |
| Pre-login "Security & how this app protects you" | A *different*, shorter notice titled "Security boundary" | **Wrong.** `ui-specification.md` §5 requires the same notice to be re-viewable, not a weaker one |
| Settings | No security-notice entry at all | Missing. §15 has always required one |
| Settings | Entirely hard-coded English | Missing. The product ships English and Persian |

Four different vocabularies reached users — "private experimental build", "experimental",
"structural placeholder — not for shipping", "development-only fake transport" — and two
of them were false in the artifact that carries them. ADR-044's "declared maturity tiers"
had no single expression anywhere in the code.

### The defects this decision had to resolve first

**D-a. Two of ADR-044's "supported" features do not exist in the artifact.**

`profileProtectionProvider` and `profileKeyDistributionProvider` return
`UnsupportedProfileProtection` and `UnsupportedProfileKeyDistribution` for every
environment except development. In the Private Experimental build, `publishOwn` therefore
fails at `protection.seal` and `refreshPeer` fails at `keyDistribution.receive`. Encrypted
profiles do not work at all: a user could type a display name, press Save, and get
`authGenericErrorMessage` — under a warning claiming a "development-only fake transport"
that build does not contain.

`AttachmentTransferService` exists in `lib/features/attachments/application/` and is
composed by no provider anywhere. `pubspec.yaml` declares no file or image picker. The
composer's paperclip dispatches `OpenAttachmentIntent()` with no attachment, and
`AttachmentSheet` renders three `ListTile`s whose `onTap` is `null` because the chat page
passes no `onCancelled`. `docs/implementation-checklist.md` has said attachments are
pending all along.

ADR-044's supported tier lists "contacts and encrypted profiles" and "attachments". Two
of those are not supported, not experimental, and not present. **This decision amends that
row** rather than editing ADR-044 in place, and relabels both surfaces so the application
agrees with the correction.

**D-b. The notice a user must acknowledge and the notice a user can go back and read were
not the same statement.** The enrollment gate showed the protect/does-not-protect
boundary; the pre-login link showed a two-sentence paragraph about passwords and recovery
secrets under a different title. Whichever one is right, they cannot both be the notice.

**D-c. The build's own name disagreed with itself.** Launcher label "Experimental", task
title "Development".

An ADR about honest communication cannot be written over these, so they are fixed here.

### The word

Evaluated independently of ADR-044, against what the artifact provably is.

| Term | What it conventionally promises | Fits this artifact? |
|---|---|---|
| **Experimental** | Google's published launch-stage definition, read at primary source on 2026-08-20: "Experiments are focused on getting customer feedback about a prototype. They are not intended for production use or covered by any SLA, support obligation, or deprecation policy and might be subject to backward-incompatible changes." | **Yes, precisely** — including the backward-incompatible clause, which is exactly ADR-036's disposable group state |
| **Preview** | Same source: "ready for testing by customers before adopting it for production use at GA … not necessarily feature-complete … no SLAs or technical support commitments" | No. "Preview" promises that the thing previewed is what will ship. The group layer will be *replaced* and its data discarded (ADR-036), so it is not a preview of anything |
| **Beta** | Feature-complete, final testing before release. Mozilla's release channels describe Beta as the version "destined to become the next released Firefox"; Google Cloud retired the stage in favour of Preview and GA | No. No background delivery, no notifications, no voice, no search, no attachments, no profiles, and no review of any layer |
| **Alpha** | Incomplete, expect breakage — arguably accurate | No. It is a release-train word: alpha implies a beta and a release follow on a schedule. There is no schedule, and the group layer is not on a train to production |
| **Development** / **Testing** | Not a shipped artifact / a purpose, not a maturity | No. "Development" already names another flavor and would be false on a signed artifact installed by other people; "Testing" invites "so it's finished, you're just testing it?" |
| **Stable**, **Production**, **1.0** | Production-ready, covered by support | **Provably false.** Forbidden |

**"Private Experimental" is kept.** The two words are orthogonal — *private* describes
distribution, *experimental* describes maturity — so combining them adds information
rather than confusion, and *private* carries a real instruction: do not pass the artifact
on. This lands where ADR-044 landed, by a different route.

### Decision

**D1. One application-level maturity designation: Experimental.** It is carried by the
persistent banner, by the launcher label, and now by the task-switcher title, which must
agree with the launcher label and no longer says "Development". Production carries no
designation at all, because it has none to carry and cannot be installed.

**D2. Feature-level labels exist, there are exactly two of them, and both read *down*
from the application label.**

| Label | Meaning | Where it appears today |
|---|---|---|
| **Experimental** | The surface really transmits and really encrypts, using a maintained implementation, but nothing about it is reviewed or standardised and its state is disposable by decision | Group screens, and the build-disclosure section of the security notice |
| **Not built yet** | The surface is routed and visible and has no implementation behind it. Nothing it appears to offer happens | Voice rooms, appearance, file attachments, profile publishing |

**There is no third label, and no label meaning "supported", "stable", "verified" or
"audited".** An unlabelled surface is governed by the application-level Experimental
designation and by nothing stronger. This is the load-bearing part of the model: the
absence of a badge must never be readable as an assurance, so no badge may ever assert
one. `SurfaceMaturity` in `lib/app/config/deployment_disclosure.dart` holds both values
and an architecture test fails if a third is added or if any screen renders a maturity
word without it.

ADR-044's three *tiers* are unchanged as a description of the deployment. What changes is
that only the two tiers that reduce a user's expectations are expressed on screen. The
supported tier is deliberately silent, because "supported" in ADR-044 means "its local
state is intended to survive updates" — a durability claim that would be read as a safety
claim if it were printed next to an encryption feature.

**D3. Disclosure has four placements, each with one job, and nothing is repeated for
emphasis.**

| Placement | Job | Surface |
|---|---|---|
| Continuous, low salience | Identity: which build this is | The environment banner. It is not a warning and must not be turned into one |
| Once, high salience, blocking | Consequences: what a user must know before trusting the app with a conversation | The deployment disclosure inside the existing mandatory enrollment notice |
| Contextual, persistent, per surface | The specific consequence of *this* feature | The group banner; the not-built pages, the profile notice, the attachment sheet |
| On demand, always | Re-reading what was acknowledged | Settings → "Security & how this app protects you", and the pre-login links, both opening the same notice |

**D4. Consent: one mandatory acknowledgement, at first enrollment on a device, inside the
gate that already exists. Never on a timer.**

The mechanism was already in the repository and was not being used for this:
`EnrollmentPhase.securityNotice` is the last step of device enrollment for both the
first-device and later-device flows, it is durably persisted in the enrollment journal,
messaging is withheld until it is accepted, and it already ends in an explicit "I
understand". The deployment disclosure becomes a section of that screen. No second consent
screen is created.

Re-acknowledgement is **content-triggered, not time-triggered**.
`DeploymentDisclosure.revision` moves when, and only when, the disclosed facts move; a
test pins the revision to the exact English text of every point, so changing a word
without raising the revision fails CI. Raising it makes re-delivering the written handover
disclosure to existing recipients release-blocking, and every later enrollment reads the
new text.

Coverage at launch is complete: no external install exists yet, because
`docs/release-signing.md` makes the off-site key-custody procedure mandatory *before* the
first external install and ADR-044 records those backups as still outstanding. Every
recipient of the first artifact will therefore enrol under revision 1. (That is an
inference from the recorded custody state, not an observation of a device.)

**D5. Disclosure content is exactly the set of facts that make an ordinary expectation of
a chat application wrong.** Seven points, ordered by consequence, in
`DisclosurePoint`. Each was chosen because the system's actual behavior contradicts what a
user would otherwise assume:

| Point | The expectation it corrects | Evidence in this repository |
|---|---|---|
| No independent review | "Someone competent has checked the encryption" | ADR-017 is open for every layer; both review packets are prepared and no reviewer is retained |
| Delivery only while the app is open | "Messages arrive when they are sent" | `AndroidPollingScheduler` is a port with no adapter in `lib/`; `pubspec.yaml` declares no notification dependency |
| History lives only on this phone | "My chats are backed up somewhere" | No server history by design (ADR-028); `allowBackup="false"`; the database key is a non-exportable AndroidKeyStore key |
| Recovery restores identity, not messages | "My recovery secret gets everything back" | ADR-030; the backup carries cross-signing identity material only |
| Groups are experimental and can be reset | "A group chat is a chat" | ADR-036: beta group state is disposable and is reinitialised, never migrated |
| Parts of the interface are not built | "If I can see it, it works" | Voice, search, attachments and profile publishing are absent or fail closed |
| Intended use | "This is a secure messenger" | The threat model's release gates are closed; the deployment is private evaluation among people who already trust each other |

**Cryptographic detail is excluded by decision.** `0xFE4C`, `TBD2`, draft revisions, IANA
registry state, `withTrustedRoots: false` and the Cargo feature split are all true and all
unusable by a reader. Printing them beside the seven consequences would bury the
consequences, which is itself a disclosure failure. They stay in the ADRs, in
`docs/mls-profile.md`, and in the written handover.

**D6. The one notice has one title and one body, rendered from one widget.**
`SecurityNoticeSections` renders the permanent boundary — what the protocol does and does
not protect, which stays true in a production release — followed by the build disclosure,
which exists only in a build that is handed to someone else. Production and development
resolve `deploymentDisclosure` to null, so Private Experimental wording is structurally
incapable of appearing in either.

### Scope

In scope: what the Android Private Experimental artifact says about its own maturity,
where it says it, what a user must acknowledge, and the corrections needed to make those
statements true.

Out of scope and unchanged: the deployment definition (ADR-044), signing and identity
(ADR-042), transport trust (ADR-043), every protocol decision, the backend, and the
production gates.

### Explicit non-goals

- It does not implement attachments, profile publishing, search, voice, notifications or
  background delivery. It labels their absence honestly; that is the opposite of building
  them.
- It does not add a consent screen, a terms-of-service flow, a legal agreement, an
  age gate, or any acceptance the application does not act on.
- It does not add analytics, acknowledgement reporting, or any signal that a disclosure
  was read. There is no telemetry in this product and this decision does not introduce the
  first of it.
- It does not change what the group layer is, only how it is labelled.
- It does not open a production gate or relax the written-handover requirement, which
  ADR-044 makes a condition of distribution.

### Alternatives evaluated

**Consent model.**

**A. No acknowledgement, banner only.** Rejected. Three of the seven facts have durable,
irreversible consequences — missed messages, permanently destroyed history, discarded
group state. A banner communicates identity, not consequence, and a permanent banner is
the single most habituated element on a screen.

**B. A second, dedicated consent screen after enrollment.** Rejected, and this is the
alternative that looks most like the obvious answer. Two blocking screens in a row do not
double the attention paid; they split it, and the second is the one that gets dismissed.
The enrollment gate is already mandatory, already durable, already tested, and already the
last thing before a user's first message.

**C. First-run acknowledgement inside the existing gate.** **Selected.**

**D. Periodic re-acknowledgement — monthly, or on every update.** Rejected on evidence,
and it is worth stating why plainly: re-showing an unchanged warning does not refresh it,
it trains dismissal. Kirwan, Bjornn, Anderson, Vance, Eargle and Jenkins measured "a
continued, linear decrease in activation through all six repetitions" of a security
warning in the brain's visual processing regions, and found "the learned negative valence
of computer security warnings is not enough to overcome habituation" (*Frontiers in
Psychology*, 2020). Worse, the damage generalises: this application depends on genuinely
blocking states — unverified identity, unsigned device, changed master key, queue-gap
rejoin — and training a user to click past a familiar warning degrades those too. A
periodic notice would make the app less safe, not more.

**E. Re-acknowledgement when the disclosed facts change.** **Selected, in the narrow
content-triggered form of D4.** The version that was rejected is the runtime one: storing
an acknowledged revision per install and re-opening the notice when it advances. That
needs a new column on `enrollmentIntents`, a schema migration, and a new transition out of
`EnrollmentPhase.complete` — new states in a security-critical state machine, to buy
enforcement that this deployment's distribution model already provides. There is no
over-the-air update here: when a fact changes, the maintainer builds an artifact and hands
it to named people with a written disclosure, which is already release-blocking. The
revision is enforced in CI and bound to that process instead.

**F. Feature-specific acknowledgement, for example a modal before creating a first
group.** Rejected. The group screens already carry a persistent contextual statement of
the exact consequence, which outperforms a modal in front of the least-used feature, where
click-through is highest. A persistent statement cannot be dismissed; a modal exists to be
dismissed.

**Feature labelling.**

**G. One uniform application-level label, no per-feature labels.** Rejected. It forces a
single claim over components with genuinely different failure modes: either the group
layer is overstated and users lose group history unwarned, or the pairwise layer is
understated and the deployment fails to produce the piece-19 evidence it exists to
produce.

**H. A full maturity taxonomy — stable / supported / beta / experimental / planned — with
a badge on every feature.** Rejected on two grounds. It cannot be kept accurate: a badge
on every surface is a maintenance obligation on every change, and the first stale badge
poisons all of them. And it requires a word meaning "assessed", which no evidence in this
repository supports for any layer.

**I. Two labels, both meaning "less than the application label", applied only to
exceptions.** **Selected.** Only the exceptions carry a badge, there are only two kinds,
and both are honest downgrades. Nothing has to be re-audited when a feature is unchanged.

**Where the disclosure lives.**

**J. Out-of-band written handover only, as ADR-044 left it.** Rejected as *sufficient*,
kept as *required*. A document delivered with an APK is read once, by whoever opens the
message, and is not present at the moment a user decides to trust the app with a
conversation. It also cannot reach a second person who installs from a forwarded file.
ADR-044's requirement stands unchanged; this decision adds the in-app statement it
deferred.

**K. Store-listing style disclosure.** Not applicable. There is no store listing;
distribution is a direct APK over the self-hosted channel.

### External evidence, and what it decided

Three findings changed the decision. Everything else was decided from the repository.

| Question | Source | Finding | Effect |
|---|---|---|---|
| Is a warning worth building at all, or do users click through everything? | Akhawe and Felt, "Alice in Warningland: A Large-Scale Field Study of Browser Security Warning Effectiveness", *USENIX Security* 2013 (read at primary source, 2026-08-20) | Measured clickthrough over ~25 million warning impressions: 7.2% and 23.2% for Firefox and Chrome malware warnings, 9.1% and 18.0% for phishing, 33.0% for Firefox SSL — but 70.2% for Chrome SSL. The authors conclude warnings "can be effective in practice; security experts and system architects should not dismiss the goal of communicating security information to end users", and that the variance shows "the user experience of a warning can have a significant impact on user behavior" | Build the disclosure, and design it. The 70.2% outlier is the warning users met most often and could bypass most easily — which is the argument against repetition, not against warning |
| Does repeating the notice help? | Kirwan, Bjornn, Anderson, Vance, Eargle, Jenkins, "Repetition of Computer Security Warnings Results in Differential Repetition Suppression Effects as Revealed With Functional MRI", *Frontiers in Psychology*, 2020 | Continuous linear decrease in visual-processing activation across all six repetitions; the negative valence of a security warning does not overcome habituation | No periodic re-acknowledgement. Re-consent is content-triggered only |
| What does each maturity word promise, in published industry usage? | Google Maps Platform launch stages, `developers.google.com/maps/launch-stages`, last updated 2026-08-19 (read 2026-08-20) | Experimental: "not intended for production use or covered by any SLA, support obligation, or deprecation policy and might be subject to backward-incompatible changes". Preview: "ready for testing by customers before adopting it for production use at GA … not necessarily feature-complete". GA: "production ready" | "Experimental" is the accurate word, on a published definition, and the backward-incompatible clause matches ADR-036 exactly |

Separately, ADR-044's revisit condition 6 required that Android's developer-verification
documentation "be read and dated" at primary source before any of it becomes binding. It
was, on 2026-08-20:
`developer.android.com/developer-verification` records enforcement from **2026-09-30** for
Brazil, Indonesia, Singapore and Thailand on certified devices running Android 7+, with a
global rollout in 2027;
`developer.android.com/developer-verification/guides/limited-distribution` (page dated
2026-08-20) describes the free account type as requiring no government ID and permitting
developers to "Share apps with up to 20 devices that end-users have explicitly
authorized", registered through a QR-code or link handshake. **This changes no part of the
disclosure model** and is recorded because the condition asked for it: the 20-device cap
is per account and this deployment targets 20–30 *users*, several of whom will enrol more
than one device, so the free tier may not cover it. That is a distribution question for
ADR-044's revisit process, not a communication question.

Nothing else external was consulted, and no secondary source was treated as evidence.

### Threats and failure modes

Each was checked against the model, not asserted.

| Failure | How the model addresses it | Residual |
|---|---|---|
| A user assumes the app is production-ready | Application-level Experimental label, on the banner, the launcher and the task title; the disclosure names the absence of review first | A user who ignores all of them. Accepted; the audience is personally known |
| A user assumes stronger encryption than the evidence supports | "Audited", "reviewed", "verified", "standards-compliant" and "interoperable" are forbidden; the disclosure states plainly that nobody outside the project has reviewed it | The word "encrypted" still appears throughout, and is true |
| A user misses time-critical messages | The single most consequential fact is disclosure point 2, and it is stated in the user's terms — "there are no notifications and nothing runs in the background" — not as "best-effort background polling is not implemented" | Real. It is a usability cost ADR-044 accepted deliberately |
| A user loses history to an uninstall or a group reset | Points 3, 4 and 5, plus the persistent group banner at the point of use | The user must act on it. No backup exists to offer |
| Warnings are vague enough to be ignored | Every point states a consequence and an implied action. None says "may", "could" or "we cannot guarantee" | — |
| Warnings are so heavy that adoption fails | Seven short facts on one screen, once. The banner is identity, not alarm. Nothing repeats | If it is still too heavy, that is information about the artifact, not about the wording |
| A user shares the APK beyond the intended group | "Private" is in the application-level label, and the disclosure says who the build is for. A second-hand installer still meets the mandatory enrollment gate, so the in-app disclosure reaches them even though the written handover does not | Distribution beyond named recipients is ADR-044 revisit condition 1 |
| A user relies on it for something it was never built for | Point 7 states the intended use and the excluded use in one sentence | A user whose safety depends on it should not be a recipient at all |
| A label goes stale as features land | Labels are downgrades only, held in one enum, rendered from one place, asserted by tests. A feature that starts working loses its badge; nothing has to be re-certified | A feature that *stops* working needs a badge added, which no test can detect |

### Relationship with the deployment architecture

Checked against the artifact, not against the documentation.

| Claim the model makes | What enforces it |
|---|---|
| Only a build handed to someone else states what it is | `deploymentDisclosure` is null for development and production; asserted per environment |
| Production shows no maturity wording anywhere | No banner, no disclosure, and the navigation-rail "not for shipping" footer is gone. The `shell_wide_dark.png` golden is regenerated from a production shell |
| The task title, the launcher label and the banner name one build | `userFacingTitle` and `configurationBanner` are one extension over `AppEnvironment`; the launcher label is the beta flavor's `resValue` |
| The group label matches the group stack | Both come from `GroupProductionGate.privateExperimentalPermit` through `groupFeatureAvailabilityProvider` (ADR-044) |
| The profile label matches the composed adapters | `profilePublishingProvider` reads the installed adapters, never the environment, so a screen cannot claim a capability the composition root did not install |
| The disclosure and the shell name the same build | `bootstrap()` sets `appEnvironmentProvider` and the app's `environment` from one argument; asserted |

### What may and may not be claimed

ADR-044's table stands. This decision adds:

| Term | Permitted? |
|---|---|
| **Supported**, **stable**, **verified** as a badge on any feature | **No.** There is no such label and none may be added |
| **Not built yet** | Yes, for a routed surface with no implementation behind it |
| **Experimental** as a feature badge | Yes, only for a surface that really transmits and whose state is disposable |
| A feature name in the interface with no working implementation and no label | **No.** Either it works, or it says it does not |
| "Development" in any Private Experimental surface | **No** |

### Maintenance and ownership

One file owns the vocabulary and the disclosure: `lib/app/config/deployment_disclosure.dart`.
The maintainer who changes what the software does owns changing what it says, in the same
change. Enforced by `test/architecture/deployment_disclosure_test.dart`:

- the disclosure exists for the Private Experimental build and for no other;
- every `DisclosurePoint` is rendered, and the order is the ADR's order;
- the revision is pinned to the exact English text of every point;
- every point and label has an English and a Persian string;
- no user-facing string says "beta", "audited", "production ready" or "stable release";
- `SurfaceMaturity` has exactly two values, both downgrades;
- every screen rendering a maturity label renders it from `SurfaceMaturity`;
- `bootstrap()` keeps the composed environment and the rendered environment identical.

### Consequences

- A recipient cannot reach their first message without reading a screen that states, in
  their own language, that nothing is reviewed, that messages arrive only while the app is
  open, and that history has no second copy.
- The written handover disclosure ADR-044 requires is unchanged and still
  release-blocking. It is now a duplicate of an in-app statement rather than the only copy.
- Two features ADR-044 called supported are labelled as not built, and one of them no
  longer offers a Save button that cannot work.
- The application stopped calling itself a development build in the task switcher, and
  stopped telling production users they are running something not for shipping.
- Five status lines on the first screen a user sees are no longer mojibake.
- Settings is localized and, for the first time, satisfies §15's requirement that the
  security notice be re-openable.
- Adding a maturity word to a screen now fails a test unless it comes from the shared
  vocabulary; editing the disclosure fails a test unless the revision moves with it.
- Nothing here opens a production gate, and no accepted decision is superseded.

### Corrections to ADR-044

Recorded here rather than edited into ADR-044, per this register's rule.

1. **D2's supported tier is amended.** "Attachments" and "encrypted profiles" are removed
   from it. Attachments have no composed transfer service, no picker dependency, and an
   inert sheet; profile publishing and profile decryption fail closed in every flavor but
   development. Both belong to the absent tier and are labelled "Not built yet". The rest
   of the supported tier was checked and stands.
2. **The disclosure-requirements section's item 4 note is discharged.** "An in-app
   first-run disclosure is the correct home for item 4 and is recorded as follow-up work"
   — it is now implemented, in the existing mandatory gate, and the written handover
   remains required alongside it.
3. **Revisit condition 6's primary-source requirement is discharged**, with the dates and
   figures recorded above. The condition itself remains open.

### Review and revisit conditions

ADR-044's eight conditions apply unchanged. This decision adds four:

1. **A feature changes tier** — anything absent starts working, or anything working stops.
   The label and the disclosure both move, and the revision moves with them.
2. **A new user-facing surface makes a security or maturity claim** that is not rendered
   from `SurfaceMaturity` or `DisclosurePoint`.
3. **`DeploymentDisclosure.revision` changes.** Re-delivering the written disclosure to
   every existing recipient becomes release-blocking for that build.
4. **Background delivery or notifications ship.** Disclosure point 2 becomes false, which
   is a revision change and, under ADR-044's own condition 8, a re-open of that decision
   too.

## ADR-044 in full — the initial private deployment (2026-08-20)

**Status:** Accepted. Deployment decision. **Opens no production gate.**
**Amended by ADR-055 (2026-08-24):** tier 2 is withheld from the distributed artifact until the packaged closed-beta MLS core has been observed executing on real hardware. D2's tier table, alternative E, the production-boundary table's group rows and disclosure item 2 read as written only once that gate opens; everything else in this decision stands.
**Amended by ADR-058 (2026-08-25):** the *Piece 20* section's re-scope stands and is completed. Its finding, its two exporter paths and its refusal to grant either are unchanged; what it left unset — the bar the granting decision must clear — is now seven checkable conditions in ADR-058, which also carry the per-ABI evidence rule ADR-056 introduced four days after this decision was written.
**Amended by ADR-067 (2026-09-07):** the serving origin moved to `chat.orviniq.com` and the application IDs were rebased onto `com.orviniq.chat{,.beta,.development}`, so every identifier this decision names reads as written above rather than as it was first recorded; the Beta signing identity was reissued under a matching subject on the same day. What the decision *decides* is untouched — the deployment, its tiers, its disclosures and its boundary all stand on the reasoning written here. Every artifact built before that date is superseded and may not be distributed, which includes the 2026-08-20 production verification run recorded below: what it checked is still the check, but the identity it checked against has moved.

### The question

The project needs an initial deployment usable by roughly 20–30 trusted people. The
repository already contains an Android `beta` flavor, a frozen application ID, a
persistent signing identity, a release pipeline, and a large closed-beta PQ MLS
implementation. What it does not contain is one authoritative answer to: what is that
deployment, what may honestly be said about it, what stays mandatory, what may be
deferred, and how it reaches public production without becoming a dead end.

This decision answers that. It is not a plan for future work; it describes what the
next artifact handed to a user is, and it corrects the places where the code and the
documentation disagreed about it.

### What the repository actually ships today

Verified against the working tree on 2026-08-20, not assumed:

| Area | State |
|---|---|
| Flavors | `development`, `beta`, `production` on one `environment` dimension in `android/app/build.gradle.kts` |
| Application IDs | `com.orviniq.chat.development`, `com.orviniq.chat.beta`, `com.orviniq.chat` |
| Entry points | `lib/main_development.dart`, `lib/main_beta.dart`, `lib/main_production.dart`; `lib/main.dart` delegates to development |
| Provisioning | `String.fromEnvironment` under one `<ENV>_` prefix per flavor; no runtime origin selection anywhere |
| Native core | Two Cargo profiles. `foundation` (development, production) exports 15 symbols; `beta` (`--features beta-pq-mls`) exports those plus `cp_crypto_v1_beta_mls_operation` |
| Signing | Beta signs with a persistent RSA-4096 v2+v3 identity attached at flavor level; `buildTypes.release` sets `signingConfig = null`, so Production packages unsigned |
| Signing identity | **Reissued**, on 2026-09-07, under ADR-067; read back out of the keystore the same day. Certificate SHA-256 `a1189203…fb9a7ba9`, subject `CN=com.orviniq.chat.beta`, valid to 2054-01-23, matching `android/beta-release-identity.properties` exactly. The identity this row recorded when the decision was written is archived, not destroyed, and signs nothing from here on. Off-site encrypted backups are still required before the first external install, and none exists for the reissued key: the reissue reset that obligation rather than inheriting it |
| Transport trust | `SecurityContext(withTrustedRoots: false)` plus the provisioned authority, on both REST and WebSocket (ADR-043) |
| Local state | SQLCipher database keyed by a non-exportable AndroidKeyStore key; `allowBackup="false"`; isolation between flavors is the Android application sandbox, which follows the application ID |
| Background delivery | **Absent.** `AndroidPollingScheduler` is a port with no adapter in `lib/` |
| Notifications | **Absent.** No notification dependency is declared in `pubspec.yaml` |
| Voice | **Absent.** `/voice-rooms` renders `StructuralPlaceholderPage`, badged as a non-shipping placeholder |
| Search | **Absent** |
| Independent review | **None**, for any layer. ADR-017 is open; both review packets are prepared and no reviewer is retained |

Two documented facts were wrong and are corrected by this decision rather than left
standing: `docs/implementation-checklist.md` said the real signing identity had not been
created, and `README.md` said Android release signing was absent. Both predate ADR-042.
`docs/deployment-and-release.md` also listed a `staging` flavor that has never existed in
`build.gradle.kts`, in `lib/`, or in any provisioning prefix.

### The defect this decision had to resolve first

`groupFeatureAvailabilityProvider` derived availability solely from
`GroupProductionGate.developmentPreviewPermit`, which returns non-null only when
`!kReleaseMode && environment == development`. The beta flavor is a release build, so
**every group screen in the Beta artifact rendered `GroupProductionGatePage`** — while
the same artifact composed `NativeBetaGroupMls`, ran `GroupKeyPackageMaintenanceService`
as post-inbox work, and processed inbound Welcome, control, and application objects
through `GroupMlsInboundCoordinator`.

The shipped Beta artifact therefore generated and uploaded MLS KeyPackages, advertising
to the backend and to peers a capability its own interface would never honour, for
groups no user of it could create. Piece 18 introduced the screen gate before piece 19
wired the beta stack, and piece 19 never revisited it. No test covered the beta case.

An ADR cannot state what Beta can access while that contradiction stands, so it is fixed
here: one source-only permit now decides both the stack and its screens.

### The name

"Beta" is the wrong word and this decision stops using it in front of users.

Beta ordinarily means feature-complete, pre-release, expected to work. This build has no
independent cryptographic review of any layer, a group ciphersuite on MLS Private Use
`0xFE4C` that is not `TBD2`-conformant (ADR-040), no background delivery, no
notifications, no voice, and no search. **Experimental** is the accurate word.

The application ID keeps its `.beta` suffix. ADR-042 froze it, and changing it would
force every install through an uninstall that destroys local state irrecoverably. An
application ID is an opaque identifier, not a claim; a launcher label and a persistent
banner are claims. So the identifier stays `com.orviniq.chat.beta`, the Dart enum
stays `AppEnvironment.beta`, the Gradle flavor stays `beta` — and every string a user
reads says Experimental.

### Decision

**D1. The initial deployment is the Private Experimental build.** One Android artifact,
application ID `com.orviniq.chat.beta`, signed by the frozen Beta identity, compiled
against one private origin, distributed as a direct APK with its SHA-256 and metadata
file to a known, named set of roughly 20–30 trusted recipients over the self-hosted
channel. It is not a beta, a release candidate, or a preview of a shipping product, and
no document, screen, or release note may present it as one.

**D2. One artifact carrying declared maturity tiers, not a uniform product.** The
functionality in it is at genuinely different maturity levels and the deployment says so
rather than averaging them into a single claim:

| Tier | Contents | What is promised |
|---|---|---|
| **Supported** | Registration, login, two-phase device enrollment, cross-signing, SAS/QR verification, the signed device log, recovery secret, contacts and encrypted profiles, hybrid PQXDH + Double Ratchet direct messages, the application-event protocol, Saved Messages, attachments, linked devices, device-to-device history transfer, the durable inbox/outbox | Its failure modes are understood, it is covered by tests and vectors, and its local state is intended to survive every update. **Not** that it is audited |
| **Experimental** | Closed-beta PQ MLS groups | It really transmits and really encrypts, using a maintained implementation. Its state is disposable by decision (ADR-036) and an update may reset it. No standards conformance, no interoperability, no review |
| **Absent** | Voice rooms, local search, notifications, background delivery, appearance settings | Nothing. These are visibly missing and must stay visibly missing rather than half-present |

Neither of the first two tiers is independently reviewed. "Supported" distinguishes
expected state durability, not assessed security.

**D3. The existing build-time separation is confirmed and completed, not replaced.**
Separate flavors, separate application IDs, separate native crypto profiles, separate
provisioning prefixes, and a signing identity attached at flavor level are the correct
architecture and are kept exactly as they are. What changes is that the group boundary,
which was expressed inconsistently in four places, now has one source-only expression:
`GroupProductionGate.privateExperimentalPermit`. `group_providers.dart` and
`sync_providers.dart` reach the beta stack only through it, and the five group screens
gate on `GroupFeatureAvailability.isAvailable` rather than naming one tier, so adding a
tier can never silently close them again.

### Scope

In scope: the Android Private Experimental artifact, its distribution, its disclosure,
its isolation from Production, and the conditions under which it is revisited.

Out of scope, and unchanged by this decision: the backend, which stays read-only; the
production ciphersuite selection (ADR-026); the closed-beta protocol decisions (ADR-036,
ADR-037, ADR-039, ADR-040, ADR-041); the signing and identity decision (ADR-042); the
transport trust decision (ADR-043); and the post-v1 Web backlog (ADR-033).

### Explicit non-goals

- This is not a public release, a soft launch, or a staged rollout of one.
- It does not open any of the seven production gates in `docs/mls-profile.md`, and it
  does not touch `GroupProductionGate.releaseAssertion`, ADR-017, or ADR-026.
- It does not give Production a signing identity, and it does not make Production
  installable.
- It does not authorize a locally assigned production ciphersuite identifier, a
  classical fallback, a production KeyPackage path, or a project-local cryptographic
  fork.
- It does not create a second product, a second repository, or a long-lived branch.
- It does not implement background delivery, notifications, search, or voice, and it
  does not permit shipping a partial version of any of them.

### Alternatives evaluated

**A. One artifact containing everything, gated at runtime.** Rejected. The production
artifact would then package a native core exporting `cp_crypto_v1_beta_mls_operation`,
and the only boundary between an unreviewed draft ciphersuite and a production user
would be a runtime branch — defeated by one bug, one define, or one refactor. Today that
boundary is provable from the artifact itself: `tool/verify_release_apk.sh --production`
extracts the packaged `.so` and fails if the beta symbol is present. That evidence is
worth more than the build simplicity it costs.

**B. Separate Beta and Production build flavors.** Selected, because it is what already
exists and it survives every objection raised against the others. Two application IDs
that can never upgrade into one another, two native profiles proven distinct at the
artifact level, one signing identity that reaches only Beta, and a Production artifact
that the OS refuses to install.

**C. A separate private-experimental application, developed as its own product.**
Rejected. It duplicates the entire pairwise stack, doubles the surface any future review
must cover, and guarantees drift from the line it must eventually graduate into. It buys
isolation the flavor split already provides, at the cost of the shared reviewed core
that ADR-032 and ADR-017 depend on.

**D. A long-lived branch or materially separate product.** Rejected for the same reasons
as C, plus one specific to this project: ADR-042 makes the signing identity and
application ID unchangeable, so any divergence that later needs to merge back cannot be
resolved by shipping a different application. The merge cost is paid in user data.

**E. Ship the private deployment with groups closed, as a direct-message-only client.**
Seriously considered and rejected. It is the smallest attack surface, and if the group
stack were unproven *and* unwired it would be the right answer. But the group stack is
already wired into the beta artifact's sync engine and KeyPackage maintenance, so
closing only the screens produces the current defect rather than safety. Closing it
properly means unwiring the work of ADR-036, ADR-037, ADR-039, ADR-040 and ADR-041 and
leaving them permanently unexercisable, since the only remaining piece-19 evidence —
execution against the packaged Rust core on physical devices against a live backend — can
only be produced by people using it. That is a dead end, and it would need to supersede
five accepted decisions to reach. Rejected in favour of exposing it as a declared
experimental tier with honest disclosure.

### Security invariants that remain mandatory

A small, trusted audience reduces the *adversary population*. It changes nothing about
the server, the network, or a lost phone. These stay mandatory and each one is enforced,
not merely asserted:

| Invariant | Enforcement |
|---|---|
| The server stays an untrusted relay; every signature, identity, device-log, version, replay, and AEAD check happens on the client | Runtime, throughout `lib/features/**` |
| No cryptographic primitive or zeroization is implemented in Dart | The primitives live in the Rust core. `test/architecture/crypto_core_boundary_test.dart` asserts the narrow FFI surface and fails if any Dart file imports a cryptography package |
| Confidentiality and integrity of message content, including against a seized backend | Runtime; `docs/threat-model.md` is unchanged by this decision |
| Hybrid PQXDH with no classical fallback and no silent downgrade | Build-time and runtime (ADR-025, ADR-034) |
| Device authentication by cross-signing and the client-signed device log; unsigned devices are never messaged | Runtime (ADR-027) |
| Transport trusts the provisioned private authority and nothing else; absent or malformed authority material fails configuration closed | Runtime (ADR-043); `test/features/networking/transport_security_test.dart` proves it against a real handshake |
| Local state is encrypted at rest under a non-exportable AndroidKeyStore key, with backup disabled | Runtime and manifest |
| Key continuity: the application ID and signing certificate are frozen, and every artifact is verified against the recorded fingerprint before distribution | Build-time and tooling (ADR-042); `tool/verify_release_apk.sh` fails closed |
| Production cannot execute the beta MLS core | Build-time and artifact-level: the Cargo feature is non-default, the symbol allowlist in `tool/build_rust_android.sh` exits 5 on any mismatch, and `verify_release_apk.sh --production` re-checks the packaged library |
| Production cannot be installed | Build-time: `signingConfig = null`; asserted on every CI run by `tool/ci.sh` |
| No arbitrary server selection, certificate bypass, remote configuration, telemetry, foreign push, or third-party runtime resource | Structural: origins come only from `String.fromEnvironment`, `badCertificateCallback` returns false unconditionally, and `pubspec.yaml` declares no such dependency. `AppRuntimePolicy.lockedDown` records the policy and is asserted in `test/features/bootstrap/application/app_configuration_test.dart` |
| No plaintext, credential, key, or ciphertext in logs | Runtime, with redaction tests |
| Catastrophic local data loss is treated as unrecoverable, never as an acceptable migration | Process: ADR-042 and `docs/release-signing.md` |

The signing key custody procedure in `docs/release-signing.md` is mandatory before the
first external install, not after it, and this decision does not relax it. Its one
unmitigated risk — a single key holder — remains accepted and recorded there.

**On `docs/threat-model.md`'s security release gates.** They include "no shipping an
unreviewed cross-platform protocol implementation" and an independent sign-off. Handing
an artifact to 20–30 people is plainly shipping *something*, so the tension is real and
is resolved explicitly rather than by wordplay: those gates are **release** gates and
they stay closed. This decision does not open them, does not claim they are satisfied,
and does not make this artifact a release. It authorizes one narrower thing — private,
named, disclosed distribution of an artifact that says what it is — and it pays for that
by requiring the written disclosure in the user-disclosure section to reach every
recipient. If the disclosure is not delivered, the distribution is not authorized.

### Requirements deferred, and the risk each deferral keeps

| Deferred | Why it is not a prerequisite here | Residual risk |
|---|---|---|
| Independent cryptographic review (ADR-017, production gate 7) | It is a public-release gate. Retaining a reviewer is an external event with unknown availability and cost, and blocking a 20–30 person private deployment on it would leave the implementation permanently unexercised against real devices | **The largest one.** No layer, pairwise included, has been assessed by anyone outside the project. A design or implementation flaw in PQXDH, the ratchet, the device log, or the storage layer would not be caught. Users must be told this plainly |
| An IANA-assigned MLS ciphersuite value and a non-expiring primitive specification (gates 1, 2) | No amount of work in this repository can advance either. The private deployment does not interoperate with anything | Group state is tied to a Private Use identifier and a moving draft, so it is disposable by construction. Disclosed in tier 2 |
| A maintained provider implementing `TBD2`'s KEM (gate 3) | ADR-040 determined that no such provider exists and that supplying one locally would be a project-local cryptographic fork | The beta KEM is hybrid ML-KEM-768/X25519 from a maintained implementation, but it is not `TBD2` and can never be `TBD2` evidence |
| Cross-implementation interoperability | `docs/mls-profile.md` determined it structurally unobtainable: the beta KEM has one implementation and no specification, so no second implementation can be *configured* to it | No independent implementation can validate the group wire format |
| Upstream MLS interoperability vectors (part of gate 4) | The MLS WG repository publishes only classical fixtures | Project vectors and NIST ACVP anchors are the only fixture evidence |
| Web, Wasm, and browser vectors | Post-v1 under ADR-033; crypto-dependent Web behavior stays fail-closed | None for this deployment |
| Background delivery, notifications, search, voice | None is required for the deployment to be usable, and a partial implementation of any of them would make a delivery promise the system cannot keep | Messages arrive only while the app is running. This is the single most consequential user-visible limitation and must be disclosed |
| Reproducible builds and SBOM | Public-release supply-chain requirements. The artifact is built by one maintainer from a recorded revision, and the metadata file records that revision and warns when the tree is dirty | A recipient cannot independently reproduce the artifact; they can only verify that it carries the expected signer and hash |

### What may and may not be claimed

| Term | Permitted? |
|---|---|
| **Experimental** | Yes, everywhere. It is the accurate description of the artifact as a whole |
| **Beta** | Not in user-facing text. Permitted only where it names the frozen identifier, the Gradle flavor, or the `AppEnvironment` value |
| **End-to-end encrypted** | Yes for direct messages, attachments, and profiles. The pairwise construction is implemented, tested against vectors, and has no fallback path |
| **Post-quantum** | Yes, with precision: hybrid X25519 + ML-KEM-768 for direct-message session establishment, and hybrid ML-KEM-768/X25519 for the experimental group layer. Never as a bare adjective for the product |
| **MLS** | Only as "based on the MLS protocol (RFC 9420) with an experimental non-standard ciphersuite". Never unqualified; the suite is Private Use `0xFE4C` |
| **Standards-compliant**, **interoperable**, **conformant** | **No.** For the group layer these are provably false (ADR-040) |
| **Audited**, **reviewed**, **verified** | **No**, for any layer, until ADR-017 closes |
| **Secure** | Not as a bare claim. Specific, scoped statements only — what is protected, against whom, and what is not |
| **Production**, **release**, **stable**, **1.0** | **No** |

### User disclosure requirements

The goal is that the user's expectations match the system's actual behavior. Every item
below is a requirement of this decision:

1. **A persistent build-identity banner.** Present on the blocking Connection screen and
   inside the application shell, reading "Private experimental build". Production shows
   no banner. *Implemented:* `AppEnvironmentBanner`.
2. **Per-tier honesty on the experimental surfaces.** Group screens state that the
   encryption is experimental, unreviewed, non-standard, and that an update may reset
   those groups and delete their messages. The development preview keeps its own distinct
   wording, because it transmits nothing and the experimental build does. *Implemented:*
   `_GroupMaturityBanner`, covered by a widget test asserting the two builds do not share
   one string.
3. **Absent features stay visibly absent.** Voice rooms and appearance remain badged
   non-shipping placeholders. *Implemented:* `StructuralPlaceholderPage`.
4. **Out-of-band disclosure at handover.** Because there is no store listing and no
   in-app onboarding disclosure yet, the following must be delivered in writing with the
   APK, alongside the SHA-256 and the metadata file, and is a release-blocking checklist
   item:
   - no part of the cryptography has been independently reviewed;
   - messages arrive only while the app is running — there is no background delivery and
     no notifications, so this must not be relied on for anything time-critical;
   - group messaging is experimental and its history can be lost on an update;
   - message history exists only on the device; the server holds none, and uninstalling
     destroys it permanently;
   - a recovery secret plus a second enrolled device is the only way to recover an
     identity, and it does not recover history;
   - this build is for evaluation among people who already trust each other, and is not
     appropriate for anyone whose safety depends on the confidentiality of their
     messages.
5. **What must never be communicated:** any claim from the "No" rows above, any implied
   delivery guarantee, and any statement that the private CA pin-set in the Android
   network security configuration protects the app's API traffic — ADR-043 established
   that it does not.

An in-app first-run disclosure is the correct home for item 4 and is recorded as
follow-up work. It is deliberately not implemented here: this decision does not
introduce product surfaces, and a written handover is sufficient and verifiable for a
named 20–30 person audience.

### The production boundary

Unchanged by this decision except that the group boundary now has one expression instead
of being restated in each composition root and again on every screen. Nothing here
weakens an existing boundary.

| | Production | Private Experimental |
|---|---|---|
| Installable | **No.** Packages unsigned; the OS refuses it | Yes, signed by the frozen Beta identity |
| Native core | `foundation` profile. Does not export `cp_crypto_v1_beta_mls_operation` | `beta` profile. Exports it |
| Group stack | `UnsupportedGroupMlsCrypto`, failing closed on all nine port methods | `NativeBetaGroupMls` |
| Group screens | `GroupProductionGatePage` | Reachable, with the experimental banner |
| KeyPackage upload | Impossible: the maintenance provider throws | Generated and uploaded |
| Origin, CA, pins | `PRODUCTION_*` only | `BETA_*` only. A separate backend deployment and separate accounts |
| Local state | Its own sandbox, its own KeyStore alias | Its own sandbox, its own KeyStore alias |
| Signing identity | None | The frozen persistent identity |

**Nothing crosses.** The two are different applications; neither upgrades into the other,
no data migrates between them, and no MLS state, group, ratchet, or KeyPackage produced
by one is ever readable by the other.

**If someone tries to enable beta functionality in Production**, in order of which fails
first: `GroupProductionGate.privateExperimentalPermit` returns null for production, so
the composition root installs the unsupported adapter; `main_production.dart` references
`GroupProductionGate.releaseAssertion`, whose `assert` and explicit `StateError` fail
release compilation if the constant is edited; the production Cargo build does not enable
`beta-pq-mls`, so the symbol does not exist to call; `tool/build_rust_android.sh` exits 5
if the exported symbol set differs from its allowlist; `tool/verify_release_apk.sh
--production` extracts the packaged library and fails if the symbol is present;
`tool/ci.sh` runs that check on every run; and the artifact is unsigned regardless, so no
device can install it.

Compile-time and build-time: the Cargo feature, the flavor source sets, the symbol
allowlist, the provisioning prefixes, `signingConfig = null`, and the
`GroupProductionGate` constants. Runtime: the permits and the composed adapters.
CI-enforced: the production build, the artifact verification, analysis, and the test
suite.

This was run, not assumed. A production release APK built from this working tree on
2026-08-20 passed `tool/verify_release_apk.sh --production`: application ID
`com.orviniq.chat`, unsigned so the OS cannot install it, and a packaged native core
that does not export `cp_crypto_v1_beta_mls_operation`.

### Piece 19 under this deployment

The deployment objective changes how piece 19's remaining work is classified. It changes
none of its findings.

| Classification | Work |
|---|---|
| **Mandatory for this deployment** | Nothing new to build. What ships is what exists. The one genuinely required outstanding item is execution of the closed-beta group stack against the packaged Rust core, on physical devices, against a live backend — which this deployment is the mechanism for producing |
| **Useful but deferrable** | Broader adversarial and multi-device matrices; the manual product-state upgrade tier in `docs/release-signing.md` before any storage-, schema-, or crypto-state-touching release |
| **Primarily public production** | Gates 1, 2, 3, 5 and 7: registry assignment, suite identifier, maintained provider support, KeyPackage bucket conformance for the production suite, and independent review. Gates 4 and 6 each have an Android device half that this deployment does exercise, but neither can be *evidenced* until the suite those fixtures must be run against exists |
| **Externally blocked** | Gates 1, 2, 3, upstream vectors, and a retained reviewer. Five prerequisites, none movable from inside this repository |
| **Obsolete as previously framed** | Re-running the Phase-A preflight audit as the deliverable of every attempt at piece 19. It is now trigger-driven: re-run it when one of the revisit conditions below fires, not on a schedule. The audit's *content*, its stop-and-decide rule, and the prohibition on locally assigning an identifier are all unchanged |

Piece 19 is therefore not "blocked pending five gates" for the purposes of this
deployment. Its closed-beta half is **delivered**, as the experimental tier. Its
production half stays blocked exactly as `docs/mls-profile.md` records.

### Piece 20

> **Amended 2026-08-25 by ADR-058.** Everything below stands: the finding, the two
> exporter paths, and the refusal to grant either. What it does not carry is the bar
> the granting decision must clear, and it predates ADR-055 and ADR-056, which made
> the experimental exporter's availability per-ABI. ADR-058 supplies both as seven
> checkable conditions and still grants no exporter.

Its prerequisite was written for a public-release objective and no longer says anything
actionable: it requires that piece 19 pass every production gate, and gates 1–3 cannot be
reached from inside this project, so as written piece 20 is permanently dead rather than
merely blocked.

Re-scoped, without touching any implementation, because none exists: **piece 20's real
prerequisite is a decision about which MLS exporter it may derive media keys from.** Two
paths, and this ADR grants neither:

- the production gates close and voice consumes the reviewed production exporter; or
- a separate, later ADR explicitly accepts the private-experimental exporter for
  experimental voice only, under the same disposable-state and disclosure rules.

The second is available but is deliberately not taken here. Real-time audio would rest on
the least mature layer in the system, and it needs its own evidence: a self-hosted
LiveKit and TURN deployment, an Android SFrame wire spike proving the SFU cannot decrypt,
and a truthful foreground-service integration. That is a decision to make with that
evidence in hand, not a corollary of this one.

`docs/implementation-prompts.md` is untracked, so this re-scope is recorded here, and
this ADR is authoritative over the prompt text.

### Evolution toward public production

The private deployment must not become an architectural dead end. It does not, because
almost everything in it graduates unchanged.

**Graduates as-is:** the entire supported tier — the Rust core and its FFI boundary, the
pairwise transport, the application-event protocol, device enrollment and cross-signing,
the device log, recovery, attachments, history transfer, the durable sync engine, the
storage layer, the design system, and the transport trust model.

**Needs replacement, not migration:** the experimental group layer. When production gates
1–3 close, the suite changes, and ADR-036 already fixes the consequence: beta group state
is reinitialized, never silently migrated. Groups are recreated and rejoined. This is
disclosed to users in advance rather than discovered by them.

**Needs building:** background delivery, notifications, search, and voice.

**How users migrate.** They do not upgrade from the experimental application into the
production one — the application IDs differ, so no upgrade path can exist. A user moving
to the public product installs a second application, registers against the production
backend, and starts fresh. Their experimental install keeps working independently until
they remove it. Anyone expecting their experimental history to appear in the production
app will be wrong, and must be told so before they invest in that history.

**Application identity.** Production keeps `com.orviniq.chat`, already reserved and
already the flavor's ID. It gains its own signing identity only through an explicit,
separate release decision, created offline, with its own custody procedure. Nothing in
this decision authorizes creating it.

**Cryptographic state.** Identity material — the account master key, device keys, the
device log — is portable in principle through the existing recovery format, but it is
bound to a backend deployment, and the experimental and production backends are separate.
In practice, production enrollment is a fresh enrollment.

### Irreversible decisions

Recorded plainly, because pretending migration will be easy is how projects lose user
data:

1. **The Beta application ID and signing certificate are permanent.** Losing the key ends
   the deployment's ability to update. Rotation cannot fix key loss, and with `minSdk` 24
   the original key must keep signing the v2 block forever, so a compromised key can
   never be fully retired.
2. **Local history has no second copy.** No server history by design, backup disabled,
   database key non-exportable. Any event that erases app data erases history for a
   single-device user, permanently.
3. **Experimental group state is disposable and will be discarded.** Not a risk — a
   scheduled outcome, whenever the draft, the identifier, or the suite changes.
4. **The private CA is the only trust anchor.** `withTrustedRoots: false` means a lost or
   compromised authority requires a new build, distributed out of band, to restore
   connectivity. This is deliberate and stronger than the public-CA model it replaced,
   and it has no runtime recovery path.
5. **Every user who receives this artifact learns the project exists.** A private
   deployment is not anonymous distribution.

### Consequences

- The Beta artifact's group stack becomes reachable by the people who install it, which
  is the only way the last outstanding piece-19 evidence can be produced.
- The KeyPackages that artifact was already uploading now correspond to groups that can
  actually exist.
- One permit, in one file, decides the experimental boundary. Three architecture tests
  and one widget test fail if either half drifts from the other.
- Users see "Experimental" rather than "Closed beta", which is a weaker and truer claim.
- Production's fail-closed posture is unchanged and now stated in one place: it cannot
  execute the beta core, and it cannot be installed at all.
- The deployment ships without background delivery or notifications. That is a real
  usability cost, accepted deliberately in exchange for not making a delivery promise the
  system cannot keep.
- Nothing here opens a production gate, and no accepted decision is superseded.

### Review and revisit conditions

Deadlines are not triggers. Re-open this decision when one of these occurs:

1. **The audience changes shape** — distribution beyond the known, named recipients, or
   any distribution to someone who is not personally trusted by the maintainer.
2. **Public distribution is proposed**, in any form, including a store listing.
3. **An independent cryptographic review is retained**, or reports findings. This is the
   single largest deferred requirement and its closure changes what may be claimed.
4. **A production gate closes**, particularly gates 1 or 2, which would begin the group
   layer's replacement and its state reinitialization.
5. **A signing or application-identity event** — key loss, suspected key exposure, or a
   second key holder being added.
6. **Android's developer-verification requirement reaches the deployment's users.**
   Google's developer-verification documentation, read on 2026-08-20, records enforcement
   for certified Android devices in Brazil, Indonesia, Singapore and Thailand from
   2026-09-30, a global rollout in 2027, ADB and an advanced install flow remaining
   available for unregistered apps, and a free limited-distribution account capped at
   about 20 devices. This deployment targets 20–30 *users*, several of whom will enrol
   more than one device, so that cap may not cover it. This was established from search
   summaries of official Google domains, not from a page read end to end; the primary
   documentation must be read and dated before any of it becomes binding, and no
   distribution decision may rest on the numbers above until it is.
7. **The threat model changes** — a user whose safety depends on this software, or a
   materially different adversary than `docs/threat-model.md` records.
8. **Background delivery or notifications are implemented**, which changes the delivery
   promise and therefore the disclosure.

## ADR-041 in full — same-revision fork ordering (2026-08-17)

**Status:** Accepted. Closed-beta protocol decision. Supersedes ADR-038. **Opens no
production gate.**

### Question

Can the branch author bias ADR-038's same-revision tie-break, and if so what ordering rule
replaces it?

### Finding: confirmed, and cheap

The ordered value was the control state hash, computed in
`native/crypto_core/src/mls_beta.rs` as
`SHA-256("chat:v1:group-control-state" ‖ frame(canonical) ‖ frame(signature))`. Its inputs
are the CBOR canonical descriptor — event id, group id, revision, previous control state
hash, MLS epoch, commit hash, signer user and device id, `created_ms`, operation — and the
Ed25519 signature over that descriptor.

Of those, the author freely chooses the 16-byte `event_id` (nothing derives, binds, or
range-checks it; honest clients draw it at random), `created_ms` (read as a bare `u64`,
validated against no clock), and the operation payload's own text. `ed25519-dalek 3.0.0`
signs per RFC 8032, deterministically, so one descriptor yields exactly one signature and
one hash — grinding therefore means re-signing under a fresh event id, at a cost of one
Ed25519 signature plus one SHA-256 per candidate, with a fresh uniform 256-bit result each
time.

Measured on 2026-08-17 through the shipped signing path on this workstation (release,
x86-64): **1,000 candidate branches in 40.8 ms — about 24,500 per second per core — and 9
trials to place a branch below one known rival.** Against a *known* rival hash `H` the
expected trial count is `2^256 / H`, whose median over uniform rivals is two. Against an
*unknown* future rival, grinding `N` candidates and keeping the smallest loses only with
probability about `1/N`: one second of one core is `N ≈ 24,500`, or 99.996 %. The standing
evidence is the Rust test
`an_author_grinds_the_control_state_hash_below_a_known_rival`, which reproduces the shipped
hash byte for byte, grinds, and then re-signs the winning event id through the real
operation entry point.

### Finding: who could use it, and against what

A competing branch at the shared parent revision must pass authentication, replay against
the reconstructed parent, and `GroupControlStateMachine` authorization. Enumerating what
each role may author there:

| Role of the member facing eviction | Branches it can author at the parent | Under ADR-038 |
|---|---|---|
| Owner | not evictable at all — `GroupAuthorization.canRemove` refuses an owner target | n/a |
| Admin | `UpdateMetadata` at every revision, `Leave` once, `Invite` where the policy allows, and its own `Remove` of a plain member | defeats the eviction indefinitely |
| Member, `allMembers` invitations | `Invite` at every revision, `Leave` once | defeats the eviction indefinitely |
| Member, `ownerOnly`/`ownerAndAdmins` | `Leave` once | defeats one eviction |

A departing member's own `Leave` is the sharpest case: every active member holds
`GroupPermission.leave`, it carries no Commit, and under ADR-038 a ground `Leave` displaced
the `Remove` that was evicting its author. Because `GroupPendingEvictionService` retries the
eviction on the next drain, any role with a repeatable authorized operation — an admin's
metadata edit, a member's invite under `allMembers` — could repeat the grind at every
revision and never be evicted, while each round either fork-quarantined the evicting owner
or left the attacker in the group holding the current epoch secret. So: **confirmed,
exploitable by the eviction target itself, and repeatable for two of the four cases.**

### The rule

Sibling branches are compared on a tuple, smallest first:

1. `GroupControlPrecedence` of the operation — `eviction`, then `authority`
   (`ChangeRole`, `TransferOwnership`, `UpdatePolicies`, `Create`), then `membership`
   (`Invite`, `Leave`), then `descriptive` (`UpdateMetadata`).
2. The signer's role **in the reconstructed shared parent** — owner, admin, member.
3. The signer's authenticated user id, then device id.
4. The control state hash.

Key 1 removes the class of attack outright: the target of an eviction cannot reach the
eviction class, because reaching it means holding `removeMembers`, which is the same check
the branch already has to pass. Key 2 closes the one remaining case, an admin under
eviction issuing its own `Remove`: `canRemove` only lets an owner evict an admin, so the
competing branch is always the owner's and always outranks it. Neither key is variable by
the author — the class follows from the permission it actually holds, and the role comes
from the parent roster, not from the branch's claims about itself, so an operation that
promotes its own signer cannot promote its own ordering. Key 3 is bound by the device
credential the sibling was authenticated against.

Key 4 survives only as the last resort, and it is reached only when two branches agree on
class, role, user and device — that is, when one device signed two controls at one
revision. Grinding there reorders the equivocating author's own branches, which it could
already do by choosing which one to send, so it wins nothing.

The order stays **total** (four keys over a finite domain, with the hash total on the
remainder), **deterministic** (every input is carried in the authenticated branch or the
replayed parent), and needs **no server order and no extra round trip**. Sibling
authentication, replay against the reconstructed parent, and authorization are unchanged;
`branchOf` additionally refuses to place a signer that is not an active member of the shared
parent, which fails closed rather than ordering a branch on its own claims.

### Options evaluated

**1. Precedence class, then parent authority, then signer identity, then hash — CHOSEN.**
Removes the grindable input from every position that can decide a real conflict, states the
security property directly ("an eviction is not displaced by a convenience operation"), and
keeps convergence total and server-independent.

**2. Keep the hash but bind the event id to something unchosen — REJECTED.** There is
nothing to bind it to that the author does not also control: the parent hash, revision and
epoch are shared constants at a fork, so any derivation still leaves `created_ms` and the
operation payload free. It would also make the wire format's event id derived rather than
opaque, for no gain.

**3. Order by a key derived from the epoch secret — REJECTED.** Every member knows the
epoch secret, so the attacker computes the same PRF and grinds exactly as before. It only
hides the order from non-members, who are already unable to place a branch.

**4. Prefer the branch that carries an MLS Commit — REJECTED.** `Invite` also carries one,
and every member holds `inviteMembers` under `allMembers`, so it would hand the same
displacement back to the same attacker.

**5. Order by signer identity alone — REJECTED.** It is not author-variable per fork, but
it is grindable at account registration and it says nothing about what the branches do: a
low-id member's metadata edit would still beat a high-id owner's eviction.

### Consequences

No state, schema, or wire format changes: the ordering key is derived from data every
branch already carries. `BETA_STATE_FORMAT_VERSION`, transport v3, the control descriptor,
and the control state hash are all unchanged — the hash keeps its jobs as branch identity,
chain link, and audit digest, and only stops being the deciding input. No reinitialization
is triggered.

Honest concurrent branches of the same class and authority now converge on the lower signer
id instead of the lower hash. Both were arbitrary; this one is stable and explains itself in
the quarantine record. A superseded branch is still recovered by fork-quarantine plus
remove/re-add, because an applied MLS commit cannot be rewound.

**This decision does not open any production gate.** All seven gates in
`docs/mls-profile.md` remain closed. It does not touch the production adapter,
`GroupProductionGate`, ADR-017, or ADR-026.

**Reversal trigger.** Re-open if a future control operation cannot be honestly placed in one
of the four precedence classes, or if a delivery service that serializes commits is ever
introduced, which would remove the need for a client-side tie-break entirely.

## ADR-040 in full — closed-beta hybrid KEM (2026-08-17)

**Status:** Accepted. Closed-beta protocol decision. **Opens no production gate.**

### Question

Must the closed-beta hybrid KEM be changed to match the selected candidate suite's KEM,
and what exactly is the divergence?

### Divergence set

Ten divergences, each independently verified on 2026-08-17 against the pinned crate sources
in the local cargo registry and against the X-Wing draft text: combiner input order (label
last in `-06`/`-10`, label first in the vendored combiner), label bytes (6 vs 7, with an
embedded `0x0a`), the traditional contribution (raw X25519 vs a DHKEM(X25519, HKDF-SHA256)
secret), HPKE `kem_id` (`0x647a` vs `15`, unassigned at IANA), `DeriveKeyPair` structure (no
`dkp_prk` step vs an extra HKDF-SHA384 `dkp_prk` extraction), seed expansion (SHAKE-256 vs
SHAKE-128), X25519 key derivation (raw scalar vs RFC 9180 labeled expand), the mandatory
ML-KEM encapsulation-key check (required vs no-op), the serialized private key (`Nsk` 32 vs
2,432 bytes), and the targeted revision (`-06`/`-10` vs `draft-01`). `docs/mls-profile.md`
holds the table with per-row file-and-line evidence as rows D1-D10; that table is the
binding record and this ADR does not restate it.

`kem_id` is the divergence that makes the rest non-cosmetic: `0x000F` is bound into the
HPKE `suite_id` every key-schedule `LabeledExtract`/`LabeledExpand` consumes and into the
`"KEM" || kem_id` suite ID that derives `dkp_prk` for every HPKE key pair, so it reaches
every beta Welcome, update-path node key, KeyPackage init key, and HPKE export. `Npk`,
`Nenc`, and `Nsecret` are byte-identical between the two constructions, so the divergence
is silent on the wire and fails at decryption rather than at parsing.

### Specification stability of the candidate KEM

`TBD2` names HPKE KEM `0x647a`. That code point is assigned in the IANA HPKE KEM registry
(last updated 2026-04-16) with `draft-connolly-cfrg-xwing-kem-06` as its only normative
reference, while the draft itself has advanced to `-10` (2026-03-02, Independent stream,
expires 2026-09-03) and moved the combiner label between those revisions.
`draft-ietf-hpke-pq-05` (2026-07-06) defers the algorithms to
`draft-irtf-cfrg-concrete-hybrid-kems`, cited there at `-03` and now at `-04` in
datatracker state `I-D Exists::Revised I-D Needed`. `draft-ietf-mls-pq-ciphersuites-06`
(2026-07-21, expires 2027-01-22) is annotated "Waiting for WG Chair Go-Ahead" and "Revised
I-D Needed - Issue raised by WG", and `TBD2` still has no value in the IANA MLS Cipher
Suites registry (last updated 2025-11-17). The candidate KEM is therefore defined by a
superseded, expiring Internet-Draft revision whose successor already differs, under a
chain that is still moving.

### Extension points, and why using them is a fork

The extension points are real. `mls_rs::CryptoProvider` and
`mls_rs_core::crypto::CipherSuiteProvider` are public traits; the project already
implements the former. `mls_rs_crypto_traits::{KemType, DhType, Hash, VariableLengthHash}`
are public; `CombinedKem::new_custom` and the `SharedSecretHashInput` trait are public, so
the correct 6-byte label and label-last order are expressible; and aws-lc's ML-KEM,
X25519, and SHA3-256 are reachable through public constructors, including the 64-byte
`(d ‖ z)` deterministic ML-KEM keygen X-Wing needs. None of this requires editing vendored
source.

They are still not usable here. `AwsLcCipherSuite` cannot be re-parameterized: its fields
are private, the `AwsLcHpke` enum is private, and both hybrid builder entry points
hard-code `CombinedKem::new_xwing`. So the project would have to implement the ~25-method
`CipherSuiteProvider` itself; that needs `mls_rs_crypto_hpke::{hpke::Hpke,
context::{ContextS, ContextR}}`, which `mls-rs-crypto-awslc` imports privately and does not
re-export, so it also needs a new direct dependency, and `HpkeKdf` is `pub(crate)` so the
labeled-KDF helpers would be rewritten too. SHAKE-256 is not exposed by any current
dependency's safe API, so it would need project-local `unsafe` FFI against `aws-lc-sys`.

**Explicit reasoning on the fork question.** Read narrowly, "project-local cryptographic
fork" means a patched copy of upstream source, and this route is not one. That reading does
not survive contact with the gate the phrase belongs to. Production gate 3 requires that
*a maintained OpenMLS/provider combination implements* the final KEM, KDF, AEAD, hash, and
signature mappings; the operative question is who implements the KEM, not how the code is
delivered. On this route upstream would ship `new_xwing` unchanged and the project would
author and own the combiner, the raw-X25519 KEM, the SHAKE-256 expansion, the `(d ‖ z)`
split, the encapsulation-key check, and the whole cipher-suite provider — code no upstream
maintainer tests, versions, fuzzes, or patches. That is the condition gate 3 exists to
exclude, is what ADR-017 calls "a custom, unaudited cryptographic implementation", is what
ADR-036 excludes by permitting "only maintained external cryptographic implementations",
and is what prompt 19 names directly. So the answer is yes: it is a project-local
cryptographic fork for the purposes of AGENTS.md and gate 3, even though no vendored file
would change.

Two qualifications, so the finding is not overstated. It would **not** be invented
cryptography — X-Wing is a specified construction with published vectors, and transcribing
a specification is not invention; the prohibition that bites is the maintained-provider and
reviewed-core one. And selecting and composing maintained primitives is **not** a fork:
`combined_hpke(...)` selects among upstream constructions, which is what the beta does
today and is legitimate. The line is crossed when the project authors a KEM's own algorithm
steps.

### Options evaluated

**1. Retain the current combiner and document the divergence — CHOSEN.** The beta's purpose
under ADR-036 is to exercise the real lifecycle — authenticated credentials, KeyPackage
maintenance, Welcome and transcript replay, epoch and exporter state, sealed state,
pairwise fan-out, ADR-038 convergence, ADR-039 leave — on a Private Use identifier with
disposable state. It was never wire-compatible with anything, and nothing in that purpose
depends on the KEM's code point. Every property the beta needs it already has: hybrid
ML-KEM-768 + X25519 confidentiality from a maintained implementation, `TBD2`'s exact
signature, AEAD, KDF, and hash mapping, and no classical fallback. The divergence costs
exactly one thing, `TBD2` interoperability, and no gate can consume it: gate 2 has no suite
value to be interoperable on, and gate 4's upstream vectors do not exist for any
post-quantum suite. Retaining is also the only option that leaves the KEM in maintained
hands, which is the state gate 3 requires.

**2. Implement a conformant KEM through supported extension points — REJECTED.** It is a
project-local cryptographic fork under gate 3, ADR-017, ADR-036, and prompt 19, for the
reasons stated above. It closes no gate: gates 1, 2, 4, and 7 are untouched, and gate 3
moves away from satisfaction, because the implementation becomes project-local rather than
maintained. It enlarges the reviewable surface at the most sensitive layer in the build,
replacing a maintained cipher-suite provider with a project one. It requires a new direct
dependency and project-local `unsafe` FFI, each a reviewed decision in its own right. It
targets a specification still in motion — `-06` and `-10` differ in label position and the
chain beneath is mid-revision — so the code would be written to a revision expected to
change and then discarded. And it would buy nothing even if perfect: the MLS suite
identifier stays Private Use `0xFE4C`, no counterparty implements `TBD2`, and the change
would still cost the full beta reinitialization below.

**3. Migrate to a different maintained MLS provider — REJECTED.** OpenMLS stable is 0.8.1
(2026-02-13) and 0.9.0-rc.2 (2026-08-06) is still a release candidate; both document only
the three classical RFC 9420 suites. Its post-quantum work targets
`MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519` at experimental `0x004D` with no IANA code
point. That provider has the right KEM and the wrong AEAD, KDF, and hash; `mls-rs` has the
right AEAD, KDF, and hash and the wrong KEM. Migrating trades one divergence set for
another of the same class while discarding a working, tested beta stack and reinitializing
every beta group. No maintained provider implements `TBD2`. OpenMLS remains the production
preference precisely because its X-Wing path could one day satisfy gate 3 with maintained,
formally verified primitives — but on a different suite, and not today.

**4. Defer entirely — REJECTED.** The divergence is not prospective: it is on disk, in
built beta artifacts, and already governs every beta key schedule. ADR-036's 2026-08-16
correction of fact recorded *that* the KEM diverges but did not resolve *whether it must
change*, and the divergence set it referenced was incomplete — it lacked the
`DeriveKeyPair` structural difference, the missing encapsulation-key check, and the finding
that no newer maintained crate exists. Deferring leaves an unresolved protocol question
attached to live beta state and makes the next auditor re-derive the same evidence.
Deciding "no change, here is the complete set, here is the cost of changing" resolves it
and stays reversible, because the reversal trigger is written down.

### Consequences

No reinitialization is triggered by this decision. `BETA_STATE_FORMAT_VERSION`, transport
v3, schema v11, sealed key-package snapshots, sealed group state, existing beta groups, and
queued beta group objects all remain valid, and the ciphersuite identifier stays Private
Use `0xFE4C`. Whenever the KEM does change, in either direction, the cost is fixed by the
divergence set: no stored beta HPKE key pair or epoch secret survives, because every one is
bound to `kem_id 0x000F` through `dkp_prk` and the HPKE `suite_id`; the serialized
private-key layout changes, so sealed snapshots must be reinitialized rather than migrated;
uploaded consumable and last-resort beta KeyPackages must be replaced; in-flight queued
group objects must be dropped; every beta group must be recreated and re-invited; and the
state-format version must reject old state explicitly, because `Npk` and `Nenc` are
unchanged and nothing fails at parse time. That is the ADR-036 disposability rule already
exercised for v2 to v3 under ADR-037, and it is a closed-beta reinitialization, never a
production migration.

The beta remains a hybrid ML-KEM-768 + X25519 group implementation that is **not** a
`TBD2` implementation and MUST NOT be offered as `TBD2` interoperability evidence.

**This decision does not open any production gate.** All seven gates in
`docs/mls-profile.md` remain closed and none is weakened or partially satisfied. It does
not satisfy or relax ADR-017 or ADR-026, does not authorize a classical fallback, a
production ciphersuite identifier, or a production KeyPackage path. Production continues to
resolve the unsupported adapter, `GroupProductionGate.releaseAssertion` stays closed, and
production KeyPackage generation and group creation remain impossible.

**Reversal trigger.** Re-open this decision when a maintained provider implements `TBD2`'s
KEM `0x647a` against a stable, non-expiring specification — production gates 1 and 3. That
is an upstream event, not a task this project can perform.

## Dependency opinion

The mandated Flutter stack is appropriate. The main qualification is that packages are
replaceable infrastructure/presentation adapters. No package's model is allowed to become
the product protocol. Versions are selected and pinned during scaffolding after platform
spikes, not guessed in this document.

## Decisions that do not block development

- Product name, logo, and app icon remain placeholders. The Android application IDs are
  **not** placeholders: ADR-042 froze them, and ADR-044 makes the Private Experimental
  one the identity the initial deployment ships under.
- Direct signed APK distribution is the initial release channel, defined by ADR-044.
  Self-hosted Web distribution is post-v1 and requires a later approved release decision.
- Django Admin remains the administration surface; a client admin feature is out of
  scope.
