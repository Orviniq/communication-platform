# Android platform contract

## Baseline

Use the Flutter stable version pinned during scaffolding and target the current Android
SDK required for distribution. The minimum SDK is chosen after crypto, Keystore, and
LiveKit device testing; lowering it may not weaken required security controls silently.

## Key and data protection

- Generate a non-exportable Android Keystore AES-256 key to wrap the random local database
  key. Prefer StrongBox/TEE when available and record only coarse capability state.
- Do not require hardware attestation or Google services; operation during disconnection
  takes precedence and the documented threat model does not trust a remote Google check.
- Store identity/ratchet/MLS material only through the encrypted database/crypto-core
  boundary.
- Store cross-signing private keys in platform-protected storage and in the
  recovery-encrypted backup only; device X25519/ML-KEM/ratchet/MLS private state never
  enters that backup.
- Disable Android Auto Backup/data extraction for databases, keys, tokens, caches, and
  attachments.
- Use internal app storage and scoped `content://` sharing only.
- Apply `FLAG_SECURE` to recovery-secret/key-verification surfaces and privacy-sensitive
  app-switcher content.
- Clear clipboard recovery data after a short interval when platform behavior permits.

### Piece-05 storage baseline

The pinned `sqlite3` 3.5.0 build hook selects its SQLCipher community build. Drift opens
the database only after a 32-byte random database key has been authenticated and
unwrapped by an Android Keystore AES-256-GCM key. The Keystore adapter prefers StrongBox
on API 28+ and retries with the ordinary Android Keystore provider when StrongBox is not
available. Wrapped key material lives in `noBackupFilesDir`; application backup is
disabled. Logout, self-revocation, remote revocation, wrapping-key loss, and wrapping
envelope authentication failure close database handles, destroy the Keystore alias,
and then remove database/cache artifacts.

This baseline was verified on 2026-07-27 against the Android Keystore documentation and
the `sqlite3` 3.5.0 build-hook documentation. Hardware-backed behavior still requires
the physical-device matrix; no hardware guarantee is inferred from compilation alone.

### Piece-07 crypto-core delivery scope

Piece 07 is intentionally limited to the shared Rust primitive core and its versioned
Android native FFI boundary, invoked away from the Flutter UI isolate. The Android
adapter MUST expose failures only as stable payload-free status codes and secret state
only as opaque handles, contain Rust panics at every exported boundary, reject
out-of-bound or malformed inputs before state mutation or unbounded allocation, and
destroy Rust-owned secret state through an explicit lifecycle. Dart may orchestrate calls
and carry opaque bytes or handles but does not implement primitives, export private-key
material, select weaker parameters, or receive native error strings.

The verified foundation is locked to Rust 1.97.1, Cargo's committed lockfile, Android
NDK 28.2.13676358, API 24, and `arm64-v8a`, `armeabi-v7a`, and `x86_64`. The native
library statically links the signed libsodium 1.0.22 source archive, compiles
`mlkem-native` v1.2.0 at commit
`0ba906cb14b1c241476134d7403a811b382ca498`, and pins the RustCrypto,
`minicbor`, and binding crates in `native/crypto_core/Cargo.toml`. The build rejects an
unexpected toolchain, archive hash/signature, dynamic libsodium dependency, ELF load
alignment, or exported symbol.

ABI version 1's exact export allowlist for the `foundation` crypto profile — the profile
packaged into the development and production flavors — is `cp_crypto_v1_abi_version`,
`cp_crypto_v1_application_operation`, `cp_crypto_v1_attachment_operation`,
`cp_crypto_v1_attest_peer_master`, `cp_crypto_v1_capabilities`,
`cp_crypto_v1_create_device_log_record`, `cp_crypto_v1_cross_sign_device`,
`cp_crypto_v1_identity_operation`, `cp_crypto_v1_inspect_device_log_record`,
`cp_crypto_v1_pairwise_operation`, `cp_crypto_v1_prepare_device`,
`cp_crypto_v1_prepare_first_identity`, `cp_crypto_v1_restore_identity`,
`cp_crypto_v1_rotate_recovery_secret`, `cp_crypto_v1_sanitize_identity`, and
`cp_crypto_v1_self_test`.

No other crypto profile exists. The isolated `beta` profile, its `beta-pq-mls` Cargo
feature, and its one extra export, `cp_crypto_v1_beta_mls_operation`, were deleted with
the closed-beta MLS core. The build script fails the build on any deviation from this
list, and `tool/verify_release_apk.sh` still refuses that one symbol by name in a
packaged production artifact. The ABI's public status range is the payload-free integer
set 0 through 14 frozen in `native/crypto_core/include/communication_crypto.h`. Enrollment,
peer identity/device/prekey/log verification, safety fingerprints, and user-signing
attestation cross only through these bounded typed operations; private key material
remains inside opaque Rust identity packages. Rust-owned `SecretBytes` and `SecretVec` values are
non-`Debug`, non-`Clone`, and zeroized on drop, while the testable provider owns secure
randomness, allocation/input bounds, and primitive implementations.

### Windows host prerequisites

Cargo compiles build scripts and proc-macros for the **host** even when
cross-compiling, so every gate — including the Android cross-builds — needs a
complete host toolchain. `rust-toolchain.toml` pins Rust 1.97.1 and the host is
`x86_64-pc-windows-msvc`, so install these once and use the pinned toolchain
unmodified. Do not override `RUSTUP_TOOLCHAIN`.

| Prerequisite | Needed by | Install |
|---|---|---|
| VS 2022 Build Tools, `VC.Tools.x86.x64` + Windows SDK | host `link.exe`/`cl.exe`; without it nothing links | `winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621"` |
| Android NDK 28.2.13676358 | Android targets | Android Studio SDK manager |

Put `%USERPROFILE%\.cargo\bin` on `PATH`, and Git's `bash.exe` must be resolvable for
the POSIX build scripts.

One cross-compilation detail is handled by the build scripts rather than the
environment. `libsodium-sys-stable` 1.24.0 picks its link name with
`cfg!(target_env = "msvc")`, which a build script evaluates against the host
instead of the target, so `build_libsodium_android.sh` installs the archive as
both `libsodium.a` and `liblibsodium.a`.

Verification on 2026-07-28 passed:

- `cargo fmt --manifest-path native/crypto_core/Cargo.toml -- --check`;
- `cargo test --locked --manifest-path native/crypto_core/Cargo.toml`;
- `cargo clippy --locked --all-targets --all-features --manifest-path
  native/crypto_core/Cargo.toml -- -D warnings`;
- `powershell -File tool/build_rust_android.ps1 all`;
- debug and production-release APK builds with all three native ABIs; and
- `flutter test integration_test/crypto_core_android_smoke_test.dart -d
  <android-device> --flavor development` on an Android 15/API 35 x86_64 emulator.

This Android scope does not implement PQXDH, Double Ratchet, MLS state,
application-message schemas, production KeyPackages, or the post-v1 Web/Wasm adapter.
It is sufficient for the Android-only version-1 foundation; browser interoperability
remains a post-v1 release gate.

## Network trust

Production accepts only the provisioned origin and private CA. Native network security
configuration and the HTTP/WebSocket clients enforce primary and backup SPKI pins. Pin
failure is blocking and never offers "continue anyway". Development trust is compiled
only into visibly non-production flavors.

**Android's network security configuration does not govern this app's API
traffic.** It applies to the platform's Java HTTP stacks and WebView. Both of
this client's transports — Dio for REST and `IOWebSocketChannel` for the socket
— run on `dart:io`, which does not consult it. Release validation established
this against a live server: every network precondition held and the connection
still failed, and removing the pin-set changed nothing (ADR-043).

Trust for the app's own traffic is therefore installed in Dart, at
`features/networking/infrastructure/tls/`. `TransportSecurity.provisioned`
builds a `SecurityContext` with `withTrustedRoots: false` and the provisioned
authority, so the built-in root store is **replaced**, not extended: no public
authority can issue a certificate this client accepts. Chain construction,
expiry, and hostname verification are still performed in full by the platform
TLS implementation. The REST client and the WebSocket connector share one
context, so neither can be left on default trust.

The authority reaches the app as `<ENVIRONMENT>_PRIVATE_CA_PEM_BASE64`, because
`dart:io` verifies against a certificate rather than the fingerprint the
configuration carries. Absent or malformed authority material blocks at
configuration rather than falling back to public roots.

The Android network security resources that
[`android/provisioning/README.md`](../android/provisioning/README.md) describes are
retained as defence in depth for any future WebView or Java-side traffic. They are not
what protects the API traffic, and must not be described as though they were.

Leaf SPKI pinning is deliberately not reimplemented in Dart: `X509Certificate`
exposes no SPKI accessor and no SHA-256, so it would take hand-written ASN.1
parsing and a hashing dependency inside the TLS path. Anchoring exclusively to
one offline private root is the stronger constraint; see ADR-043 for the
residual exposure that choice accepts.

## Background delivery

There is no FCM/APNs fallback and there never will be: the transport this deployment must
survive without is exactly the one FCM depends on. Correctness therefore rests on the
backend durable queue, not on instant background notification.

ADR-046 replaces ADR-029's single mechanism with three layers, because measurement of the
platform showed one mechanism cannot span the range. A backgrounded process with no
running component is cached, and a frozen app's "active TCP sockets" are terminated by the
system, so an unattended socket is closed rather than merely slow. The periodic job floor
is 15 minutes, Doze defers `JobScheduler` to maintenance windows that thin out over time,
Android 16 enforces job runtime quota even in the *active* standby bucket, and the *rare*
and *restricted* buckets disable background network entirely — and Android 13 and above
move an application into *restricted* after **eight days** without user interaction. The
one app state Android documents as having unrestricted background network is "app process
is running a foreground service".

Modes:

- **Active app (Layer 0, mandatory, no user action):** WebSocket wake-up hints plus
  authoritative REST drain. Composed 2026-08-21 (ADR-047).
- **Background floor (Layer 1, mandatory, no user action):** one persisted periodic
  `JobScheduler` job behind the existing `AndroidPollingScheduler` port, at the platform
  floor, with a connected-network constraint. Built 2026-08-21 (ADR-049). It starts no
  service, asks for nothing the user can refuse, and is never advertised as instant or
  exact-periodic. Its honest tier is *eventual*; in the *rare* and *restricted* buckets it
  is nothing at all.
- **Background near-real-time (Layer 2, opt-in, and WITHHELD from every distributed
  artifact since 2026-08-23 — see [sustained-delivery-validation.md](sustained-delivery-validation.md)
  and ADR-053):** a `specialUse`
  foreground service that keeps the process non-cached so the composed socket survives,
  declared with a truthful `android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE`. It hosts its own
  isolate and adds no second delivery implementation — the engine, the store, the inspector,
  the group stack, the socket and the alert reconciliation are the same objects, resolved
  from the same `ApplicationRuntime`. Enabling it asks for `POST_NOTIFICATIONS`, asks for the
  battery-optimization exemption through `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, and
  explains the vendor settings the app cannot check for itself. **Built 2026-08-22
  (ADR-051)** and described in full below, but **not offered to anyone**: ADR-053 found
  that no cell of the physical-device matrix had ever been run, and gates the capability
  closed in the beta and production artifacts until it is. Only the development flavour
  resolves it, so that the matrix can be run at all.
- **Active voice:** microphone/communication foreground service for the duration of the
  joined room with visible controls.

`specialUse` is chosen deliberately for Layer 2. `dataSync` is capped at six hours per
twenty-four and cannot be launched from a `BOOT_COMPLETED` receiver at `targetSdk` 35+;
`remoteMessaging` documents device-to-device message continuity, not holding a connection
to the application's own server; `systemExempted` is gated on device-owner, VPN or
exact-alarm roles this app does not have. **The app still MUST NOT label delivery work as
`remoteMessaging` or `dataSync`**, and `test/architecture/sync_platform_policy_test.dart`
continues to enforce that.

Force-stop, Doze, standby buckets, Data Saver and OEM restrictions may delay messages or
stop them entirely; resume always drains the authoritative queue and checks
`pruned_through`. What the platform *guarantees* and what it merely *permits* are recorded
separately in ADR-046, ADR-049 and ADR-051 and may not be conflated in any user-facing
string.

One consequence of the exemption, established for ADR-051 and not recorded by either earlier
decision, changes how the layers relate: **"apps that are on the Doze exemption list are
exempted from the App Standby Bucket-based restrictions"**
([app standby buckets](https://developer.android.com/topic/performance/appstandby), read
2026-08-22). The *rare* and *restricted* buckets are the hard ceiling of Layer 1, so a user
who enables Layer 2 also lifts that ceiling for Layer 1. The same page gives the other half:
an app "is in the *active* bucket while it … runs a long running foreground service".

### Layer 2 as built (ADR-051)

**One service, off until it is chosen.** `SustainedDeliveryService` is declared
`exported="false"` with `android:foregroundServiceType="specialUse"` and a
`<property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE">` stating the actual
justification in prose. It holds no data, opens no connection and makes no decision; it
exists so this process has a running component, because a process with one is not cached and
a process that is not cached does not have its sockets terminated.

**Nothing starts it but this application.** There is **no boot receiver**, no launcher entry
and no exported way in. The two callers are the enable flow, with the user present and every
precondition just verified, and the reconciliation, which starts a service only when the
durable choice is recorded, notifications are enabled, the exemption is held and nothing is
running. Both are Dart isolates that have already opened the SQLCipher-encrypted database, so
a build nobody enabled the capability in never reaches any of it. A background start is
permitted because the exemption *is* the enumerated background-start exemption.

**What changes in the delivery path is one thing.** `SyncLifecycleSupervisor` takes a
`BackgroundConnectionPolicy`. It answers *no* by default — which is every composition until
somebody turns this on — and the supervisor closes its socket on backgrounding exactly as
before. It answers *yes* only while the whole arrangement is in place, and then a
backgrounded connection is permitted. It is a port rather than a flag because the answer
changes underneath a running session and a backgrounded supervisor would otherwise never
re-evaluate.

**The connection proves it is alive.** `SocketConnector.connect` takes an optional
`keepAlive`, null everywhere except a sustained run, which passes four minutes. `dart:io`
pings at that interval and closes the connection as `goingAway` when a ping goes unanswered,
so a socket a carrier's NAT dropped becomes a close the supervisor reconnects from rather
than an open handle nothing will ever hear from again.

**Three delivery owners, arbitrated where ADR-050 put the arbitration.** The activity's
isolate outranks the service's, and both outrank a deferred catch-up. Attaching a foreground
engine asks the sustained run to stand down through the same latched handshake; the service
keeps running while its isolate gives way. A deferred tick goes to whichever owner already
exists. `awaitExclusiveOwnership` waits for both. Nothing durable records any of it.

**Reconciliation, not memory.** Every precondition is re-read from the platform on every
resume, after every transition and at the end of every deferred catch-up. The same pass
*stops* a running service whenever the arrangement is incomplete, because a service kept
alive for a connection this application will not hold and an alert it cannot post is battery
spent and a permanent entry displayed for nothing. It is also how the capability returns
after a restart and after an update: both end the service without ending the choice, and the
already-persisted periodic job is what restores it — at the next tick, which is fifteen
minutes at best.

**The permanent entry.** `IMPORTANCE_LOW` and silent, never `IMPORTANCE_MIN` (which the
platform answers by showing something louder); `VISIBILITY_SECRET`, so no part of it appears
on a secure lock screen or during screen sharing; no timestamp, no badge, no count, no name,
no message; the launcher intent as its only tap target. Its text is one reviewed, localized
sentence that crosses the channel *with the start*, so a service can never run displaying
text this project did not write, and a start carrying no text starts nothing. Note that on
Android 13 and above the *existence* of any foreground service is visible in the platform's
Task Manager whatever this application does, and the user may dismiss the shade entry while
the service keeps running — which is why the truthful status lives on the Settings screen
and not in the shade.

`test/architecture/sustained_delivery_policy_test.dart` pins the parts of this that live in
Kotlin and in the manifest, because no device is available to exercise them. That no
device is available is the whole finding of ADR-053: source shape is not behaviour, and
the capability is gated closed until behaviour has been observed. The criteria, the
matrix, the measurement procedure and the current results are in
[sustained-delivery-validation.md](sustained-delivery-validation.md), and
`tool/measure_sustained_delivery.sh` is the instrument.

### Layer 1 as built (ADR-049)

**One `JobInfo`, no dependency.** `JobInfo.Builder(JOB_ID, DeferredDeliveryJobService)`
with `setPeriodic(max(requested, JobInfo.getMinPeriodMillis()))`,
`setRequiredNetworkType(NETWORK_TYPE_ANY)` and `setPersisted(true)`. `JobInfo` is in the
framework at `minSdk` 24, and `setPersisted(true)` is what restores the job after a
reboot, so this application declares **no boot receiver of its own** and adds **no
`androidx.work`**. `RECEIVE_BOOT_COMPLETED` is declared because `setPersisted` requires
it and for no other purpose. The service is a plain service: `exported="false"`,
`android:permission="android.permission.BIND_JOB_SERVICE"`, no `foregroundServiceType`,
and no `android:process`.

**Armed by the session, not by the lifecycle.** A `MessageDeliverySession` arms the job
once when it starts and disarms it when it stops. Registering a periodic job restarts its
window, so arming on every background transition would mean a user who opens the
application more often than the interval never receives a single wake-up, and a process
that died while foregrounded would leave nothing scheduled. A headless run that finds no
session disarms the job for itself.

**Exactly one delivery owner, arbitrated in the process.** `JobService` callbacks and
`FlutterActivity.configureFlutterEngine` are both delivered on the application's main
looper, the job service runs in the default process, and the Flutter engine documents one
Dart VM per process — so all of it is one thread in one process and needs no lock. A tick
goes to the isolate the user already has when one exists; a headless `FlutterEngine` is
started only when none does; a second tick during a run is dropped; and a foreground
session calls `awaitExclusiveOwnership()` **before** it opens storage or reads a token, so
it waits for a headless run rather than racing it. This replaces ADR-046's durable Drift
lease, which was specified for a cross-process topology this application does not have.

**A tick is acknowledged.** The platform lets the process be frozen again once the job is
finished, so an unacknowledged wake-up is not a slow catch-up but an interrupted one.
`BestEffortDeliveryTick.complete()` is called unconditionally — including when the cycle
failed or was refused for want of a network — and the adapter applies its own two-minute
deadline behind the platform's ten-minute limit.

**The headless run holds nothing.** No socket: a cached process is frozen and its TCP
sockets are terminated. It restores the session, runs one `DurableSyncEngine.synchronize()`
— the same engine, store, inspector and group stack the foreground uses — reconciles the
alert from committed state, and stops. Both entry points compose through one
`ApplicationRuntime`, so the provisioned authority, the single `TokenCoordinator` and the
environment-gated crypto core cannot be silently absent from the background path.

**Which build a background run believes it is, is compiled in.** Each flavor's entry-point
file exports a `@pragma('vm:entry-point')` `backgroundDelivery()` naming its own
`AppEnvironment`. The platform picks a *name*; the environment is decided by which file was
compiled, and a build asked for an entry point it does not contain starts nothing.

**Channels a headless engine must be given.** `FlutterEngine(context)` registers generated
plugins automatically, but not channels this application registers on its activity. The
protected-storage and message-alert boundaries were Activity-scoped and are now
Context-bound classes attached to whichever engine needs them, with one implementation
each. What genuinely needs a window — `FLAG_SECURE`, the clipboard, the permission dialog
and the notification settings screen — stays on `MainActivity` and is unreachable from a
headless engine.

### Piece-12 synchronization baseline

Piece 12 pins `connectivity_plus` 6.0.5 for OS-reported link transitions, and ADR-054
re-derived that pin rather than inheriting it: the whole of the package's Android
implementation was read at 6.0.5, it reaches only `ConnectivityManager`, and it
contributes exactly one permission, `ACCESS_NETWORK_STATE`, which this application's own
manifest now declares and justifies alongside the rest. The version is **frozen** —
`connectivity_plus` 7.1.0 and later declare `androidx.core:core:1.18.0` in their own
`android/build.gradle`, which would carry this project's reviewed pin upwards and require
`compileSdk` 36.1. A reported transport is only a scheduling hint: Android explicitly
does not guarantee that an available network can reach a particular server, so the
provisioned backend REST result remains authoritative and no public connectivity probe is
added. The lifecycle
supervisor pauses reconnect timers while no transport is reported and always performs a
REST drain after foreground resume, network recovery, or a WebSocket envelope hint.

Android background polling is exposed through an app-owned best-effort scheduler port
whose headless callback reconstructs its own database and network dependencies; it never
assumes foreground-isolate memory survived. The port makes no exact-periodic or
instant-delivery promise and starts no service of its own; the opt-in Layer 2 service is a
separate capability the user turns on, and the floor is unchanged whether it is on or off.
The physical-device Doze, standby, reboot, force-stop and vendor-battery matrix remains a
release validation gate for any *claim* about timeliness. Until 2026-08-23 that sentence
was enforced by nothing, which is how Layer 2 came to ship with the matrix unrun; the
gate now lives in `lib/app/config/sustained_delivery_gate.dart` and in
[sustained-delivery-validation.md](sustained-delivery-validation.md), and
`test/architecture/sustained_delivery_gate_test.dart` fails if it opens without evidence.

This choice was verified on 2026-07-29 against the
[`connectivity_plus` 6.0.5 release](https://pub.dev/packages/connectivity_plus/versions/6.0.5)
and Android's
[`ConnectivityManager.NetworkCallback`](https://developer.android.com/reference/android/net/ConnectivityManager.NetworkCallback)
and [network-state guidance](https://developer.android.com/develop/connectivity/network-ops/reading-network-state).

**Composed on 2026-08-21 (ADR-047), correcting the gap ADR-046 recorded.** Until then
`SyncLifecycleSupervisor`, `DioWebSocketGateway` and `GatewayRealtimeSyncAdapter` were
constructed only in tests and `durableSyncEngineProvider` was read by nothing, so the
artifact opened no socket, ran no drain, and — because `SendConversationEvents` ends at
`fanout.prepareAndQueue` — transmitted no outbox row either. ADR-046's Layer 0 is now
implemented: `MessageDeliveryController` starts one `MessageDeliverySession` per
device-bound full session and stops it on logout, and the two composition roots are
resolved into one, so the socket presents the same access token, refreshes through the
same single-flight `TokenCoordinator`, and terminates its TLS chain at the same
provisioned authority as every REST call. Layer 1 followed on 2026-08-21 under ADR-049 and
is described above. Layer 2 followed on 2026-08-22 under ADR-051 and was
withheld again on 2026-08-23 under ADR-053, so in every artifact a user receives
background delivery is **eventual, and nothing else**. Layer 2 is present in the source
and unreachable in the build; what it would give if it worked is unmeasured, which is
precisely why it is unreachable. Layer 3 — the alert itself — was implemented
separately on 2026-08-21 under ADR-048 and is described below; it depends on committed local
state rather than on any delivery layer, so both a headless catch-up and a sustained run
reach it with no change.

## Notifications

Implemented on 2026-08-21 under ADR-048, which amends three details of ADR-046's Layer 3
sketch on evidence. What ships:

- **One notification, not one per message or per conversation.** A fixed id and tag in one
  channel (`"messages"`, frozen for the life of the installation because it keys the
  user's own sound and importance settings). With a sender-neutral preview, several
  notifications would be several copies of one sentence, and the only thing they would add
  is a per-message or per-conversation identifier visible to the system notification
  service and to any application holding notification access. `MessagingStyle` and
  conversation shortcuts are forbidden for the same reason: they exist to show senders and
  text, and their long-lived shortcuts publish a per-contact identifier into the launcher.
- **Its entire content is `New message` or `New messages`.** No sender, no conversation, no
  message text, no count, and no timestamp (`setShowWhen(false)`). It is
  `VISIBILITY_PRIVATE` and supplies a `setPublicVersion` carrying the same sentence, so a
  lock screen and an Android 15+ screen-sharing session show what the application chose
  rather than the system's contextless redaction.
- **It is a reconciliation of committed local state, never an emission.** Each pass reads
  rows that are unread, not deleted for this device, not withdrawn by their sender and not
  in Saved Messages; subtracts muted conversations and the conversation on screen; then
  announces what is left over or withdraws the alert when nothing is. Announcement,
  withdrawal after a read on another device, withdrawal of content its sender deleted, and
  silence for the conversation being read all fall out of that one rule. A transport event
  can never produce one: an envelope that was quarantined, rejected or held by queue-gap
  recovery never becomes a message row.
- **The trigger is a committed write.** Drift dispatches table updates only after the
  transaction commits, so a stream over `messages` and `conversations` is strictly
  post-commit. Passes are serialized behind a dirty flag, so a drain that commits many
  envelopes produces one alert.
- **Idempotence is the durable `messages.alerted` boolean.** It is spent after a
  successful post, never before: a crash in between costs one repeated alert on the same
  notification id, while the opposite order loses a message silently. A deliberate
  suppression — muted, or on screen — spends it too, so leaving the conversation or
  outliving the mute cannot produce a late alert. A platform refusal spends nothing, so
  granting permission later announces the backlog.
- **"On screen" means a mounted conversation route and a foregrounded application.** A
  chat route left mounted behind a backgrounded application is not something anyone is
  looking at. An unreported lifecycle state at launch is read as foreground.
- **Tapping carries nothing.** The content intent is the launcher intent under
  `FLAG_IMMUTABLE` with `setAutoCancel(true)`: no destination, no extra, no identifier. It
  opens the application exactly as its icon does, and the routing guards that already stand
  between an entry point and content decide what may be shown. There are no notification
  actions.
- **The platform side holds no policy.** One method channel reports what Android says,
  posts the reviewed localized sentence Dart hands it, withdraws it, and opens the system
  notification settings. Nothing identifying a conversation, a sender or a message crosses
  it. No notification dependency is declared: `NotificationCompat`,
  `NotificationManagerCompat`, `NotificationChannelCompat` and `ActivityCompat` all come
  from `androidx.core:core`, which is pinned at 1.16.0 and is also what supplies
  `FileProvider`, `ServiceCompat.startForeground` and
  `ContextCompat.startForegroundService` (ADR-054).
- **The honest tier**: an alert reaches the user only while the application's process is
  alive. Layer 1 (ADR-049) wakes the process on the platform's own schedule and Layer 2
  (ADR-051) keeps it alive while the user has that capability on; neither makes an alert
  certain, and after a force-stop nothing arrives and nothing announces.
  **"Process alive" is not "app running", and user-facing text may not conflate them**
  ([ADR-052](decisions.md)): `_reconcileAlerts` in the deferred catch-up and
  `_SustainedAlertReconciler` in the sustained run both post from isolates with no activity
  in the process, so an alert does reach a user whose application is closed. The Settings
  row said the opposite from ADR-048 until ADR-052 corrected it; the limit worth stating to
  a user is that the phone decides when the application may look, not that it must be open.
- Still true and still pending: **decrypted previews are not built**, and would need a
  reviewed bilingual lock-screen warning before they could be.
- Layer 2's foreground-service notification is its own privacy surface — a durable, visible
  indication that the application is armed — and is a separate channel from the message
  alert: low importance, silent, `VISIBILITY_SECRET`, no badge and no timestamp, so it is
  absent from a locked screen entirely. Its channel id is `sustained-delivery` and is frozen
  for the life of the installation, because the id keys the user's own settings for it.
- **Group messages produce no alert**, because the piece-18 group projection writes neither
  `messages.unread` nor `conversations.unread_count`. The alert path needs no change when
  that is fixed; the group projection and `GroupChatPage` do.
- `test/architecture/message_alert_policy_test.dart` pins the parts of this that live in
  Kotlin and in the manifest, because no device is available to exercise them.

## Permissions

Request only at point of use:

- notifications (`POST_NOTIFICATIONS`, Android 13+) for locally received message alerts
  and active-voice disclosure. Notifications are off by default on a fresh install and a
  refusal blocks every non-exempt channel, so denial is a stated outcome, not a retry loop.
  It is requested at the moment a message is waiting that cannot be announced, and only
  while the application is foregrounded, because the prompt belongs to an activity the user
  is looking at. It is spent **at most once automatically**, guarded both by a durable
  marker in `local_preferences` and by `shouldShowRequestPermissionRationale`, which is
  true in exactly the one state — refused once, not yet twice — where an automatic prompt
  would be the refusal that makes the denial permanent. Every later attempt is the user's
  own, from the Settings row, which asks Android and falls through to this application's
  system notification settings when asking changes nothing;
- vibration (`VIBRATE`, normal protection level, granted at install with no prompt) for the
  message alert channel, which is what reaches a phone in a pocket;
- the battery-optimization exemption, requested through
  `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` only when the user enables background
  delivery. Android's own Doze acceptable-use table rates this **acceptable** for a chat
  application that cannot use FCM for a technical reason, which is this application
  exactly; the grant is what lets the app "use the network and hold partial wake locks
  during Doze and App Standby" — and, established for ADR-051, exempts the app from App
  Standby Bucket restrictions entirely. It is requested from the activity only, because the
  dialog is an activity; its answer is read back from
  `PowerManager.isIgnoringBatteryOptimizations()` and never inferred from the dialog
  returning, which reports refusal and dismissal identically. Losing it stops the Layer 2
  service and is surfaced on its own screen, never hidden;
- microphone for joining voice;
- camera for capture/optional safety QR;
- media/files through system pickers without broad storage permission.

`ACCESS_NETWORK_STATE` is declared, and is the one permission in this artifact that
arrives from a package rather than from this application's own manifest —
`connectivity_plus` merges it in whether it is written here or not. It is declared here
anyway, with its justification, so that the manifest a reviewer reads is a complete
statement of what the application asks for (ADR-054). It is normal protection level,
granted at install with no prompt, and it reports the transport and its capabilities,
never an address, an operator or a payload.

`RECEIVE_BOOT_COMPLETED` is declared, and it is a normal permission: granted at install
with no prompt, granting no data, no network and no location. It exists for exactly one
reason — `JobInfo.Builder.setPersisted(true)` requires it — and **this application declares
no boot receiver at all**. The platform restores the persisted job itself, and because the
application is not direct-boot aware it cannot run before the first unlock, which is the
correct outcome: the database key is credential-encrypted and nothing can be decrypted
before then. The Dart path fails closed on top of that rather than relying on it.

Vendor battery settings — Samsung's "put apps to sleep" and adaptive battery, Xiaomi's
autostart and battery saver — govern roughly 77% of the target fleet and cannot be read or
changed by the application. They are explained to the user once, as instructions, and never
presented as something the app has verified.

Two first-party sources were established for ADR-051 and replace the community reporting
ADR-046 recorded. Samsung
([Samsung Application Management](https://developer.samsung.com/mobile/app-management.html),
read 2026-08-22) states that apps unused for about three days *and* causing poor system
health enter *sleeping* mode, where "Job, Alarm, and Foreground-service are restricted", and
that apps unused for about sixteen days enter *deep sleeping* and "only become active when
the user opens them"; it documents the user's exception path (Settings > Device care >
Battery > Background usage limits), publishes a deep-link intent to it
(`com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY`, package
`com.samsung.android.lool`, `activity_type` 2 for "never sleeping apps"), and states that
"since One UI 6.0, foreground services of apps targeting Android 14 will be guaranteed to
work as intended so long as they are developed according to Android's new foreground service
API policy". Xiaomi
([mi.com support](https://www.mi.com/global/support/faq/details/KA-492576/), read 2026-08-22)
documents a per-app Background autostart permission at Settings > Apps > Permissions >
Background autostart and advises against disabling it for apps the user relies on for
notifications; it publishes nothing about foreground services.

The application opens the documented Samsung screen when it exists and this device's
application-details screen otherwise, in one button, and reports **nothing** back: it cannot
read either setting and must never appear to have confirmed it. Samsung's One UI 6.0
statement covers Android 14 and above only, so roughly half this fleet by version share is
covered by no vendor statement at all, and the manufacturer half stays **unresolved**.

Denial has a functional fallback and never blocks unrelated messaging.

## Lifecycle and reliability

- Process death at any inbox/outbox stage is recoverable from Drift.
- App upgrade closes old crypto workers before migration and validates stored protocol
  state after migration.
- Network switching, captive/no-internet local networks, Doze, standby, force-stop,
  reboot, permission revocation, clock skew, and low storage have explicit tests.
- The client never contacts a public internet endpoint to classify connectivity.

## What the artifact links from outside

Decided point by point in ADR-054, from the integration points the code actually reaches
rather than from a list of candidate packages. Nine of the twelve points are written
against the Android framework — the `JobScheduler` catch-up, the foreground service, the
headless engine, the exemption flow, both settings intents, the method channels, the
lifecycle observer and the alert's vector icon. Three adopt `androidx.core`, and one
adopts `connectivity_plus`.

**`androidx.core:core:1.16.0`** is declared explicitly in `android/app/build.gradle.kts`.
It is not an addition — `androidx.activity` and `androidx.fragment` put it on the
classpath behind the Flutter embedding regardless — so the declaration exists to make the
*version* a decision. It supplies `FileProvider`, the whole notification surface
(`NotificationCompat`, `NotificationManagerCompat`, `NotificationChannelCompat`), both
foreground-service compatibility calls, and the runtime-permission calls. 1.17.0 adds
nothing this application uses and 1.18.0 requires `compileSdk` 36.1, which this toolchain
does not set.

**The resolved Android set is locked.** `android/app/gradle.lockfile` records 78 modules
across the six configurations a built artifact resolves, in `LockMode.STRICT`. A new
transitive arrival fails artifact resolution rather than shipping; a *version* change is
forced back to the recorded one, so `test/architecture/dependency_policy_test.dart`
additionally requires the declared pin and the locked version to agree. Fifty-one modules
reach a distributed runtime classpath, and the Espresso/JUnit set that arrives with
`integration_test` provably reaches only `developmentDebug`.

**What arrives in the merged manifest from outside**, in full: `ACCESS_NETWORK_STATE`
(from `connectivity_plus`, now also declared locally); a signature-level
`${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` and
`android:appComponentFactory="androidx.core.app.CoreComponentFactory"` (from
`androidx.core`); two optional `androidx.window` `<uses-library>` entries and an
unexported `androidx.startup.InitializationProvider` carrying the process-lifecycle and
profile-installer initializers (from the Flutter embedding). One thing is **refused**:
`androidx.profileinstaller` merges in an exported `ProfileInstallReceiver` with four
intent filters, which nothing here starts, so the manifest deletes it with
`tools:node="remove"`. The baseline profile is still written on first run by
`ProfileInstallerInitializer`.

**Nothing in the artifact's Java or Kotlin can open a connection.** The shrunk
`classes.dex` of a production release build references no `java.net`, no `javax.net.ssl`,
no `android.net.http`, no OkHttp, no Retrofit, no `DownloadManager` and no Google Play
Services type at all; the only network-adjacent types it names are `android.net.Uri`,
`android.webkit.MimeTypeMap` and `android.net.ConnectivityManager`. Every byte this
application sends leaves through `dart:io` inside `libflutter.so`, on the one reviewed
transport with the provisioned trust store. `tool/verify_release_apk.sh` additionally
reads the packaged manifest's permissions and components back out of the artifact and
fails on anything ADR-054 did not record.

Third-party licence obligations are listed in
[third-party-notices.md](third-party-notices.md), which travels with the handover.

## Distribution

Initial distribution is a reproducibly signed direct APK plus self-hosted update
metadata, all usable on the local network. Update signatures are verified independently
of TLS. A store channel may be added later but cannot become a runtime dependency.

Because distribution is a direct APK rather than an App Bundle through a store,
Play App Signing does not apply: the application signing key is the distribution
identity permanently, and there is no upload-key reset if it is lost. The deleted
`beta` flavor carried a frozen application ID and a single persistent signing key for
that reason; [Beta release signing and key continuity](release-signing.md) (ADR-042)
records its custody and what the retained key still controls. No flavor is signed now,
and production gains an identity only through an explicit release decision.

## Primary references

- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [`sqlite3` 3.5.0 build-hook options](https://pub.dev/documentation/sqlite3/3.5.0/topics/hook-topic.html)
- [SQLCipher keying order](https://github.com/sqlcipher/sqlcipher#encrypting-a-database)
- [Android background work](https://developer.android.com/develop/background-work)
- [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [Foreground-service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout)
- [Restrictions on starting a foreground service from the background](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Power-management restrictions and app standby buckets](https://developer.android.com/topic/performance/power/power-details)
- [Doze and App Standby, including the exemption acceptable-use table](https://developer.android.com/training/monitoring-device-state/doze-standby)
- [Cached apps freezer (AOSP)](https://source.android.com/docs/core/perf/cached-apps-freezer)
- [Android 14 behavior changes: cached-app resource enforcement](https://developer.android.com/about/versions/14/behavior-changes-all)
- [Android 15 behavior changes: foreground-service boot restrictions and timeouts](https://developer.android.com/about/versions/15/behavior-changes-15)
- [Android 16 behavior changes: JobScheduler quota enforcement](https://developer.android.com/about/versions/16/behavior-changes-all)
- [Notification runtime permission](https://developer.android.com/develop/ui/views/notifications/notification-permission)
- [Requesting runtime permissions, including the two-refusal permanent denial](https://developer.android.com/training/permissions/requesting)
- [Notification channels](https://developer.android.com/develop/ui/views/notifications/channels)
- [Creating a notification, including lock-screen visibility](https://developer.android.com/develop/ui/views/notifications/build-notification)
- [Grouped notifications and summaries](https://developer.android.com/develop/ui/views/notifications/group)
- [Conversation notifications and their shortcut requirement](https://developer.android.com/social-and-messaging/guides/communication/notifications-conversations)
- [Android 12 behavior changes: notification trampolines and PendingIntent mutability](https://developer.android.com/about/versions/12/behavior-changes-12)
- [Android 15 behavior changes: notification content during screen sharing](https://developer.android.com/about/versions/15/behavior-changes-all)
- [WorkManager periodic work and constraints](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)
- [App standby buckets, including the eight-day restricted-bucket rule](https://developer.android.com/topic/performance/appstandby)
- [Data Saver and `getRestrictBackgroundStatus`](https://developer.android.com/training/basics/network-ops/data-saver)
- [Implicit broadcasts exempt from the background execution limits](https://developer.android.com/develop/background-work/background-tasks/broadcasts/broadcast-exceptions)
- `JobInfo.java`, `JobScheduler.java`, `JobService.java` and `AlarmManager.java` from the
  pinned `android-35` SDK sources, which carry the normative javadoc for the periodic
  floor, `setPersisted`, the job execution limits and the while-idle alarm contract
- `dart_vm_lifecycle.h`, `dart_vm.h`, `FlutterEngine.java` and `DartExecutor.java` from the
  Flutter 3.44.7 engine sources, for one Dart VM per process, the VM-owned
  `IsolateNameServer`, automatic plugin registration and named Dart entry points

The background-delivery and notification sources above were read at primary source on
2026-08-21 for ADR-046 and ADR-049, against `minSdk` 24 / `targetSdk` 36 / `compileSdk` 36 as pinned
by Flutter 3.44.7.
