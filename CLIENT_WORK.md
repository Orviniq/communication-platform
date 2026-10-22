# Client work

What the client developer owes, and nothing else. The server cannot change a file
under `frontend/`, so an obligation that lands there is recorded here instead.

This file routes; it never repeats. The contract the client implements is
[`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md), the observable changes
are in [`API_CHANGES.md`](API_CHANGES.md), and the endpoint reference is the per-app
`API.md` files with [`backend/openapi.json`](backend/openapi.json) beside them.

Each run of the server appends its section, so the body below is in the order the
work arrived. Nothing is removed from this file except by the developer who did the
work.

## The order to do it in

Release necessity, not arrival. **Required** means a release without it is broken or
misleading to a user; **recommended** means the client works without it and costs the
user something; **optional** is an improvement with no obligation behind it. Each row
names the `backend/` document that binds the obligation — that document is
authoritative and this one never restates it.

### Required before release

| Work | Section | Bound by |
|---|---|---|
| The `/ws` handshake takes the token in the `Authorization` header; the query-parameter form is gone | [The `/ws` handshake](#the-ws-handshake--this-is-the-breaking-one) | [`backend/realtime/API.md`](backend/realtime/API.md) |
| One session token replaces the access/refresh pair: the response bodies of register, login and renew moved, and `POST /api/v1/auth/refresh` is gone | [Required — the response bodies moved](#required--the-response-bodies-moved) | [`backend/accounts/API.md`](backend/accounts/API.md), [`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §B |
| The linked-devices screen must stop reading `last_active_date`, which no route serves | [Required — the linked-devices screen loses the last-active value](#required--the-linked-devices-screen-loses-the-last-active-value) | [`backend/devices/API.md`](backend/devices/API.md) |
| The gateway handles `ack` and `signal` and emits `envelope` and `signal` and nothing else; the frames that left must go from the client | [The gateway frames that left](#the-gateway-frames-that-left-and-the-one-that-changed-shape) | [`backend/realtime/API.md`](backend/realtime/API.md) |
| The account-erasure action, so a user who wants to leave has a way to | [Required before release — the erase-account action](#required-before-release--the-erase-account-action) | [`backend/accounts/API.md`](backend/accounts/API.md) |
| `GET /api/v1/users` is gone: find people by exact name, one lookup at a time, and keep the contact list on the client | [Required before release — find people by exact name](#required-before-release--find-people-by-exact-name) | [`backend/accounts/API.md`](backend/accounts/API.md), [`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §P |
| The "find me by username" toggle, worded so it does not promise more than it hides | [Required before release — the discoverability toggle](#required-before-release--the-discoverability-toggle) | [`backend/accounts/API.md`](backend/accounts/API.md) |
| The contact list kept on the client and synced only between the user's own devices; the pickers read it alone; the cached directory goes | [Required before release — the contact list](#required-before-release--the-contact-list) | [`docs/client/CLIENT_CONTACTS_AND_TRUST.md`](docs/client/CLIENT_CONTACTS_AND_TRUST.md) §3 |
| The contact code: a code to show, a live scanner that verifies, an image path that only adds, and a hard failure on a mismatch | [Required before release — the contact code](#required-before-release--the-contact-code) | [`docs/client/CLIENT_CONTACTS_AND_TRUST.md`](docs/client/CLIENT_CONTACTS_AND_TRUST.md) §4 |
| A direct conversation carries content only once both people have verified each other: the notice, the claims, the conversation state, the admission rule and the migration | [Required before release — verification by both people](#required-before-release--verification-by-both-people) | [`docs/client/CLIENT_CONTACTS_AND_TRUST.md`](docs/client/CLIENT_CONTACTS_AND_TRUST.md) §5, §6 |
| What a file carries: removed where the format allows it, and a warning before sending where it does not | [Required before release — what a file carries](#required-before-release--what-a-file-carries) | [`docs/client/CLIENT_CONTACTS_AND_TRUST.md`](docs/client/CLIENT_CONTACTS_AND_TRUST.md) §8 |
| The profile key, if the release publishes profiles: a fresh key for every version, its audience, and a new version when the user blocks someone or removes a contact | [Required before profiles ship — the profile key](#required-before-profiles-ship--the-profile-key) | [`docs/client/CLIENT_CONTACTS_AND_TRUST.md`](docs/client/CLIENT_CONTACTS_AND_TRUST.md) §7 |
| Who can see my online status — everyone I share a chat with, my contacts or nobody, for the whole account — with presence in every group of up to 50 members, both people verified, blocks refused, three sending rules tightened, and the switch migrated | [Required before release — who can see my online status](#required-before-release--who-can-see-my-online-status) | [`docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md`](docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md) §2 to §5, §8 |
| The read-receipt setting for direct conversations: on by default, for the whole account, reciprocal; groups always send read receipts | [Required before release — the read-receipt setting](#required-before-release--the-read-receipt-setting) | [`docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md`](docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md) §5, §6 |
| Roles in voice rooms, if voice ships: room protocol version 2, the upgrade of every existing room, version negotiation and the in-call actions | [Required if voice ships — roles in voice rooms](#required-if-voice-ships--roles-in-voice-rooms) | [`docs/client/CLIENT_VOICE_ROLES.md`](docs/client/CLIENT_VOICE_ROLES.md), [`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §N rule 12 |
| The web platform files, the conditional-import stubs and the web build step the removed web target left behind | [The web platform files](#the-web-platform-files), [The conditional-import stubs](#the-conditional-import-stubs), [The build](#the-build) | [`backend/README.md`](backend/README.md) |
| Voice, if voice ships in the release: the media package, the manifest permissions, and the eleven rules of the contract | [Voice](#voice) | [`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §N, [`backend/realtime/API.md`](backend/realtime/API.md) |

### Recommended

| Work | Section | Bound by |
|---|---|---|
| Read the published limits from `GET /api/v1/config` rather than hard-coding them | [Recommended — read the limits rather than hard-coding them](#recommended--read-the-limits-rather-than-hard-coding-them) | [`backend/core/API.md`](backend/core/API.md) |
| Say what the day's upload allowance is before the refusal, rather than after it | [Recommended — say what the day's allowance is, before the refusal](#recommended--say-what-the-days-allowance-is-before-the-refusal) | [`backend/attachments/API.md`](backend/attachments/API.md) |
| The user-facing wording the removed web target left in the client | [The wording](#the-wording) | [`backend/README.md`](backend/README.md) |
| Point the client's documents at the three documents that moved under `docs/` | [Recommended — the documents that moved](#recommended--the-documents-that-moved) | [ADR-0030](docs/architecture/decisions/0030-the-security-model-and-the-client-contract-move-under-docs.md) |
| Who reacted: a list for each emoji and each person, built from the reactions already held | [Recommended — who reacted](#recommended--who-reacted) | [`docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md`](docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md) §7 |

### Optional

| Work | Section | Bound by |
|---|---|---|
| One call for a fan-out, and a conditional identity read under `ETag` | [Optional — one call for a fan-out, and a conditional identity read](#optional--one-call-for-a-fan-out-and-a-conditional-identity-read) | [`backend/devices/API.md`](backend/devices/API.md) |
| Resume an interrupted attachment download with a `Range` request | [Optional — resume an attachment download](#optional--resume-an-attachment-download) | [`backend/attachments/API.md`](backend/attachments/API.md) |
| The arbitration the token rotation forced, where two devices race | [Optional — the arbitration the rotation forced](#optional--the-arbitration-the-rotation-forced) | [`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §B |

## Remove the web target

The product is one Flutter application for Android
([ADR-0020](docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md)).
The server no longer carries a browser-only surface, so a web build of the client
cannot connect: the `/ws` gateway refuses a handshake that presents no
`Authorization: Bearer` header, and a browser cannot set one.

### The `/ws` handshake — this is the breaking one

The client already authenticates the native socket with the header, so the Android
build is unaffected. What must go is the second path beside it and the two close
codes it produced.

| Path | What is there |
|---|---|
| `frontend/lib/features/networking/infrastructure/realtime/socket_connector.dart` | `enum SocketAuthenticationMode { nativeBearerHeader, webFirstFrame }` and the `authenticationMode` getter on the connector interface. With one mode left, the enum and the getter have nothing to select |
| `frontend/lib/features/networking/infrastructure/realtime/dio_websocket_gateway.dart` | The `SocketAuthenticationMode.webFirstFrame` branch that sends the in-band `{"type": "auth", "access": …}` frame, and the close-code mapping for `4001` and `4403`, including the `code == 4001` recovery branch. Both codes are retired: authentication is now decided before the accept, so a refusal reaches the client as a failed upgrade (`403 Forbidden`) and never as a close frame |
| `frontend/lib/app/dependencies/networking_foundation.dart` | The comment describing the coordinator's `4001` refresh path |

The remaining behaviour a client needs is
[`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §O.

### The response headers the client may assert on

`X-Content-Type-Options`, `Referrer-Policy` and — on the attachment download —
`Content-Disposition` are no longer set. Any client test that asserts on one will
fail. `Cache-Control: no-store`, `Cache-Control: private, no-store` and
`X-Accel-Redirect` are unchanged. `API_CHANGES.md` § "The web target is gone" is the
full list.

### The web platform files

| Path | What is there |
|---|---|
| `frontend/web/` | The web application shell: `index.html`, `manifest.json`, `favicon.png`, `icons/`, and the two runtime assets the storage layer loads — `sqlite3.wasm` and `drift_worker.js` — plus `protected_storage.js` |
| `frontend/docs/platform-web.md` | The web platform note |

### The conditional-import stubs

Each of these five is an `export … if (dart.library.js_interop) …` trio: the
selector, the native implementation, the stub and the web implementation. With no web
target the selector and the stub have one implementation to choose between.

| Selector | Web implementation to remove |
|---|---|
| `frontend/lib/app/config/runtime_abi.dart` (with `runtime_abi_stub.dart`) | `frontend/lib/app/config/runtime_abi_web.dart` |
| `frontend/lib/features/local_storage/infrastructure/platform/platform_local_storage.dart` (with `platform_local_storage_stub.dart`) | `frontend/lib/features/local_storage/infrastructure/platform/platform_local_storage_web.dart` |
| `frontend/lib/features/networking/infrastructure/realtime/platform_socket_connector.dart` (with `platform_socket_connector_stub.dart`) | `frontend/lib/features/networking/infrastructure/realtime/platform_socket_connector_web.dart` |
| `frontend/lib/features/networking/infrastructure/tls/transport_security.dart` (with `transport_security_stub.dart`) | `frontend/lib/features/networking/infrastructure/tls/transport_security_web.dart` |
| `frontend/lib/shared/infrastructure/crypto/platform_crypto_core.dart` (with `platform_crypto_core_stub.dart`) | `frontend/lib/shared/infrastructure/crypto/platform_crypto_core_web.dart` |

### The build

| Path | What is there |
|---|---|
| `frontend/tool/ci.sh` | `flutter build web --release --target lib/main_production.dart` |
| `frontend/tool/ci.ps1` | The same build, as an `Invoke-CheckedCommand 'flutter' @('build', 'web', '--release', '--target', 'lib/main_production.dart')` |

### The wording

| Path | What is there |
|---|---|
| `frontend/README.md` | "Flutter client for Android, with a preserved post-v1 Web foundation", "Android and Web targets only" under **Toolchain**, the `flutter build web` line, the Web CA-install paragraph, and the Web step in the local-CI description |
| `frontend/pubspec.yaml` | `description: "Android and Web client foundation for Communication Platform."` |

`frontend/docs/implementation-checklist.md` carries the same "preserved post-v1 Web
scaffold" status in several rows. It is the client's live status document, so its
wording is the client developer's call — but it should stop describing a target the
server no longer serves.

## Voice

The server half of the voice design is served
([ADR-0021](docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)):
phase 6 removed the SFU and the room object, and phase 7 added the one route that
mints a coturn credential. Nothing under `frontend/` implements voice today, so none
of this is a removal: it is what the client now owes, and the evidence behind the
package facts below was gathered on 2026-09-05.

**The client contract for voice is written.**
[`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §N is the binding text, the
route is in [`backend/realtime/API.md`](backend/realtime/API.md) with
[`backend/openapi.json`](backend/openapi.json) beside it, and
[`API_CHANGES.md`](API_CHANGES.md) records what moved. Where this file and §N could
differ, §N is authoritative: what follows is the work each of its rules lands under
`frontend/`, not a second statement of the rule.

### The media package

`flutter_webrtc` 1.6.1 — pub.dev, published 2026-09-01 by the verified publisher
flutter-webrtc.org, MIT, Dart SDK 3.3 or later. It is the only maintained WebRTC
package for Flutter, and it is what the design assumes.

| What it brings | Detail |
|---|---|
| Android build | `compileSdkVersion 36`, `minSdkVersion 21` |
| Native dependencies | `io.github.webrtc-sdk:android:150.7871.01`; `com.github.davidliu:audioswitch` at commit `039a35aefab7747c557242fa216c9ea11743b604`, **from JitPack**; `androidx.annotation:annotation:1.1.0` |
| What it does **not** bring | No `androidx.core` dependency of its own, so the frozen `androidx.core` 1.16.0 and `connectivity_plus` 6.0.5 pins of `frontend/docs/decisions.md` ADR-054 both hold |
| The relay policy | Its Android plugin parses `iceTransportPolicy`, and `relay` is the value the design needs: every path crosses coturn, and no peer learns another peer's address |
| The calls §N leans on | `RTCPeerConnection.setConfiguration` and `restartIce` are in the published API, so the ICE restart of rule 9 under a fresh credential is a library call and not a fork (pub.dev API reference, 1.6.1, read 2026-09-05) |

**The offline Gradle mirror has to carry the JitPack artefact.** `audioswitch` is
resolved from JitPack by commit hash, not from Maven Central, so a mirror built only
from Central resolves everything else and fails on that one — during a shutdown, on a
build that has to work offline. Add the JitPack coordinate to the mirror while the
network is up, and prove it by building with the network off.

`livekit_client` is not the package to take. 2.11.0 requires `connectivity_plus
^7.0.0`, and 7.1.0 and later force `androidx.core` 1.18.0 and `compileSdk` 36.1 —
which is the bump ADR-054 froze against. It also pins `flutter_webrtc` 1.6.0 exactly
and adds twelve Dart packages, and its frame cipher is not RFC 9605 SFrame: it derives
a 128-bit AES-GCM key with PBKDF2-HMAC-SHA256 and leaves one byte of each audio frame
unencrypted. The mesh design needs none of it, because SRTP is keyed by DTLS between
the two endpoints of each connection.

### The manifest permissions

The manifest merger decides what the shipped application declares, so the set below is
what to keep and what to remove deliberately rather than by omission.

| Source manifest | What it declares | Keep or remove |
|---|---|---|
| `flutter_webrtc` 1.6.1 | Nothing | — |
| The libwebrtc AAR | Nothing | — |
| `audioswitch` | `BLUETOOTH` with `maxSdkVersion` 30 | Remove with `tools:node="remove"` unless a Bluetooth headset route is a feature you are shipping |
| `audioswitch` | `MODIFY_AUDIO_SETTINGS` | Keep. Audio routing during a call needs it |

`RECORD_AUDIO` is the client's own to declare, and it is the one a user is prompted
for. Nothing in the dependency set declares it for you. The microphone
foreground-service permission is the client's own as well: a call holds the
microphone while the application is in the background, and the service that keeps it
is a microphone-typed one.

### What the client now owes

§N binds eleven rules, and this file does not restate them. Rules 1 to 10 are the
protocol — the mesh, the relay-only ICE configuration, glare, join and leave, presence
and room text, bucketed signalling, the retry of a volatile frame, removal, the
credential lifetime and the participant ceiling — and each is Dart against
`flutter_webrtc` 1.6.1 as published: no fork, no patched native library, no second
package and no protocol of this project's own, because DTLS-SRTP is what every WebRTC
endpoint already implements. The ceiling of rule 10 is the server's accepted risk
([`ACCEPTED_RISKS.md`](ACCEPTED_RISKS.md) AR-16). Rule 11 is the platform half, and the
package and manifest work it implies is the two subsections above.

No media key is distributed, rotated or stored anywhere in §N: each connection is keyed
by DTLS between its two endpoints and its keys die with it.

### The gateway frames that left, and the one that changed shape

The gateway now handles `ack` and `signal` and emits `envelope` and `signal`, and
nothing else ([ADR-0022](docs/architecture/decisions/0022-the-gateway-holds-no-presence.md)).
The client never sent `subscribe_presence`, so nothing it does today breaks — but the
code and the documents that describe the old surface now describe a server that does
not exist, and `API_CHANGES.md` § "Voice comes back, as a relay credential" is the
full statement of what moved.

| Path | What is there |
|---|---|
| `frontend/lib/features/networking/infrastructure/realtime/dio_websocket_gateway.dart` | The `'subscribe_presence'` arm of the outbound frame validator, and the `'presence'` arm of `_decodeEvent` with the `RealtimePresence` event behind it. Neither frame exists on the server. The `'signal'` arm's bound is the other half: it validates a blob against `maximumSignalCharacters`, and the rule is now a bucket rather than a ceiling — base64 of exactly 1024, 4096 or 16384 bytes, and anything else is dropped in silence |
| `frontend/lib/features/networking/infrastructure/api/api_request.dart` | `maximumSignalCharacters = 16384` and `maximumPresenceTargets = 500`. The first is not the bound any more — the longest legal blob is 21848 characters, the base64 of the largest bucket — and the second bounds a frame that is gone |
| `frontend/lib/app/dependencies/messaging_providers.dart` | `presenceProjectionProvider`, and the comment saying nothing should read it "until `subscribe_presence` is sent". It will not be sent: presence between conversation members is client protocol over `signal` frames now, per `docs/client/CLIENT_CONTRACT.md` §N rule 5 |
| `frontend/lib/features/messaging/presentation/chat_conversation_view.dart` | The comment describing why presence is absent, which now has a different reason behind it |
| `frontend/docs/design-handoff/voice-room-states.md` | The "Too large" row reads `Blob over SIGNAL_MAX, 16384 chars`. `SIGNAL_MAX` is gone as a setting and as an environment variable, and a blob is dropped for being off-bucket rather than for being over a maximum — a 1500-character blob is dropped too |
| `frontend/docs/sync-engine.md`, `frontend/docs/decisions.md` | Both describe `subscribe_presence` as a frame the client has not implemented yet. It is not unimplemented now; it is not a frame |

## One session token replaces the pair

The access and refresh pair is gone
([ADR-0023](docs/architecture/decisions/0023-one-device-bound-session-token.md), which
supersedes [ADR-0006](docs/architecture/decisions/0006-device-bound-tokens-on-pyjwt.md)).
`POST /api/v1/auth/refresh` is gone with it, and `POST /api/v1/auth/renew` — a bearer
token, no body — is in its place. `API_CHANGES.md` § "The token pair becomes one
session token" is the full statement of what moved, and
[`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §M states both enrollment
flows against one token. Paths below were read on 2026-09-05.

This section has two halves, and they are not the same obligation. **The DTO changes
are required**: a client that does not make them cannot parse a login. **The removal
of the rotation arbitration is optional**, and a client that keeps it stays correct —
an ownership gate around a token that no longer retires costs a little contention and
protects nothing, but it breaks nothing either.

### Required — the response bodies moved

| Path | What must change |
|---|---|
| `frontend/lib/features/authentication/infrastructure/authentication_api_dtos.dart` | The login parser reads `json['access']` and, on the full branch, requires `json['refresh']` to be a non-empty string. Both fields are gone: read `token` and `expires_in` instead. The register branch's rejection of a body carrying `refresh` also has nothing left to reject. `scope` is unchanged and is still the discriminator between the two success shapes |
| `frontend/lib/features/devices/infrastructure/device_enrollment_dtos.dart` | The `201` parser requires `access`, `refresh` and `scope == 'full'`. It is now `device_id`, `token`, `expires_in` and `scope` |
| `frontend/lib/features/networking/domain/session_tokens.dart` | `SessionTokens.refreshToken`, `refreshExpiresAt` and the `canRefresh` getter describe a token that no longer exists, and the class comment calls the session rotating. `SessionTerminationReason.refreshRejected` names a refusal the server can no longer produce |
| `frontend/lib/features/networking/infrastructure/auth/dio_token_endpoints.dart` | `DioRefreshTokenExchange` posts `RefreshRequestDto` to `/api/v1/auth/refresh`, which is now `404`. Renewal is `POST /api/v1/auth/renew` with the session token in the `Authorization` header and no body, answering `{"token", "expires_in"}` |
| `frontend/lib/features/networking/application/ports/token_ports.dart` | `RefreshTokenExchange.rotate(String refreshToken)` takes the token that is gone. What replaces it takes no argument beyond the current session token and returns the next one |

**Stop reading the expiry out of the token.** The login parser derives
`accessExpiresAt` with `readJwtExpiry(access)`, which decodes this server's claim set
on the client. `expires_in` is published on every issuing route for exactly that
reason; read it, and let the claim set stay the server's business.

**A login no longer retires anything.** The old rule was that a login advanced the
refresh generation, so a token held elsewhere in the process died. It does not: the
device row is read and never written. Code that discards a held token when a login
returns is now discarding a working one.

### Optional — the arbitration the rotation forced

`frontend/docs/decisions.md` ADR-049 and ADR-050 and `frontend/docs/sync-engine.md`
record why this exists: two owners in one process held one rotating refresh token, the
loser of the race presented a retired token, and the server ended the session. That
race is gone. Nothing retires a token, so two owners may renew concurrently and both
keep working tokens.

| Path | What it is, and what it protects now |
|---|---|
| `frontend/lib/features/networking/infrastructure/auth/token_coordinator.dart` | The single-flight coordinator, the bounded re-read budget, and `_awaitRotationByAnotherOwner`, which waits for another owner to publish a token this one can adopt. With nothing retiring a token, an owner that renews and loses the write race simply holds a second valid token |
| `frontend/lib/app/dependencies/networking_foundation.dart` | The comment describing why a second `TokenCoordinator` against one rotating refresh token is unsafe, and the wiring that follows from it |
| `frontend/lib/features/networking/application/ports/token_ports.dart` | `SessionTokenStore.readDurable` and its contract that a cached answer is one owner's last observation rather than the truth, so a session-ending decision is made against it rather than against `read`. That was true because the rotation moved the row under each owner; it no longer moves |
| `frontend/lib/app/dependencies/message_delivery.dart` | The comments describing a wait on the rotating refresh rather than a race with it |

If the arbitration is kept, keep it as a contention control and not as a correctness
one, and say so where it is written down: the failure it was built to prevent cannot
occur against this server. If it is removed, `frontend/docs/decisions.md` ADR-049 and
ADR-050 and `frontend/docs/sync-engine.md` are the documents that then describe a
server that does not exist.

### What did not change

Revocation is unchanged, and is still the only thing that ends a token early:
`token_generation` advances on a logout, a device revocation or an account
deactivation, and every token of that device dies at once — including a live socket,
which closes with `4003`. A token that merely expires does not close its socket. The
register token keeps its name, its ten-minute lifetime and its one route, and a
register token presented anywhere else — `POST /api/v1/auth/renew` included — is still
`403 scope_forbidden`.

## Take the contract cost off the client

[ADR-0024](docs/architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md)
removes four costs the client was carrying and one column it could read. One entry
below is required; the rest are the client developer's call.

The observable changes, each with its old and new behaviour, are in
[`API_CHANGES.md`](API_CHANGES.md) § "The client stops paying for the contract".

### Required — the linked-devices screen loses the last-active value

`GET /api/v1/me/devices` no longer carries `last_active_date` on a device item. A
DTO that requires the field will fail to parse the response.

| Path | What is there |
|---|---|
| The linked-devices DTO and the screen that renders it | The `lastActiveDate` field, its parse, and whatever the screen shows with it — a "last seen" line, a sort by recency, or an idle-device warning |

There is no replacement value, by decision. The server records no activity day for
a device at all: the socket bind stopped writing one, and no other column stands in
for it. `docs/security/SECURITY.md` states the new seizure yield — a creation day, a
revocation day, and nothing about when a device was last seen. A screen that needs
to tell the user which device this is has `label_blob`, `created_date` and
`this_device`.

### Optional — one call for a fan-out, and a conditional identity read

`frontend/docs/decisions.md` ADR-060 and ADR-065 and `frontend/docs/sync-engine.md`
record what verifying a send costs today: three reads for each recipient, 107 to
137 ms a round trip, 150 round trips for a 50-member group, and a 30-second
in-memory cache built to survive the rate limit. That cache is a correctness
compromise — for those thirty seconds the client encrypts against state it has not
re-checked — and it exists because of a server shape that is now gone.

`POST /api/v1/peers` answers up to 64 peers in one call, each under a tag the
client can send back to get `unchanged` and no body. It serves the same bytes the
per-user routes serve, so the verification code that already reads those answers
reads these without a change.

`GET /api/v1/users/{user_id}/identity` now carries an `ETag` and answers `304` to a
matching `If-None-Match`, for the case where one peer is read on its own.

The per-user routes are unchanged and are not deprecated: a client that wants one
peer's devices should keep using them. What is worth reconsidering is the cache
built around their cost.

### Recommended — read the limits rather than hard-coding them

`GET /api/v1/config` publishes the retention windows, the storage and device
ceilings, the batch sizes, the padding bucket sets and whether this deployment
serves voice. `envelope_ttl_days` is the one the client cannot get any other way:
`frontend/docs/sync-engine.md` records that the retention window is an operator
setting the client cannot state, and the queue-gap disclosure of
`docs/client/CLIENT_CONTRACT.md` §H needs it.

Every other value is one the client learns today from a refusal — a `413`, a
`409`, a `400 bad_bucket` — or has hard-coded against this deployment's defaults. An
operator may change any of them.

### What did not change

The per-user identity, device-list, device-log and claim routes keep their paths,
their bodies and their semantics. `THROTTLE_ACCOUNTS` rose from `120/min` to
`300/min`, which is more headroom rather than less. The server's WebSocket ping
interval moved from 20 seconds to 240; the client's own four-minute keepalive is
untouched and stays the client's decision.

## The attachment allowance, disclosed

[ADR-0025](docs/architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md)
replaces the per-account lifetime attachment quota with an allowance for the UTC day.
Nothing on a stored attachment names an account any more.

The observable changes, each with its old and new behaviour, are in
[`API_CHANGES.md`](API_CHANGES.md) § "The attachment store stops naming accounts".

### Recommended — say what the day's allowance is, before the refusal

`GET /api/v1/config` now carries `attachment_daily_bytes`, the value
`POST /api/v1/attachments` enforces. A client that shows a storage figure at all
should show this one: what is left of today rather than a lifetime total, which the
server no longer keeps.

| Path | What changes |
|---|---|
| Any screen that said "X of 2 GiB used" | There is no lifetime total behind it. Either drop the figure or show today's allowance, and remember that deleting an attachment gives nothing back |
| The upload failure path | `413 quota_exceeded` now means "spent for today". Its `detail` string changed; branch on `code`, which the contract has always required. A retry before 00:00 UTC answers the same way, so hold the attachment rather than retrying at once |
| The same failure path | `503 storage_full` is a new code: the server's disk is low, not the account's allowance. Treat it as retry later with backoff and say so in different words from a quota message — the operator has to free space before it clears |


## Optional — resume an attachment download

`GET /api/v1/attachments/{attachment_id}` honours a `Range` request through nginx
and answers `206 Partial Content`. Nothing in the API moved; what moved is that the
behaviour is now documented and measured, so a client may rely on it.

The observable changes are in [`API_CHANGES.md`](API_CHANGES.md) § "An attachment
download resumes", and `backend/attachments/API.md` carries the headers.

`frontend/lib/features/attachments/infrastructure/attachment_transport.dart` refuses
any status but `200` and requires the streamed byte count to equal the bucket exactly,
so it declines a `206` as it stands. What a resume needs there:

| Path | What changes |
|---|---|
| The download call | Send `Range: bytes=<bytes already written>-` and `If-Range: <ETag of the first response>` when a partial file exists for this capability id |
| The status check | Accept `206` beside `200`. A `200` in answer to a `Range` means the server chose to send the whole object — truncate the partial file and start again rather than appending |
| The length check | Count from the resume offset, not from zero. The rule is unchanged: what ends up on disk must be exactly one bucket, and anything else is refused |
| The partial file | Keep it only while the `ETag` matches. An attachment is immutable and its id is never reused, so a mismatch means the retention sweep deleted the object — discard the partial and report the attachment as gone |

Worth doing only for the two largest buckets. A 64 KiB or 256 KiB attachment costs
less to fetch again than the bookkeeping costs to maintain.

## Required before release — the erase-account action

[ADR-0025](docs/architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md)
adds `DELETE /api/v1/me`. Until the client offers it, a user who wants to leave has
to ask the operator, and the operator can only deactivate the account — the rows stay.

The observable behaviour is in [`API_CHANGES.md`](API_CHANGES.md) § "An account can
erase itself", and `backend/accounts/API.md` carries the section.

| Path | What is needed |
|---|---|
| Settings | An "Erase this account" action, apart from log-out and marked destructive |
| Its confirmation | A dialog that asks for the account password and states the consequence in the wording below. The password goes in the request body and is never stored |
| The call | `DELETE /api/v1/me` with a full-scope token and `{"password": "…"}`. `204` is success |
| `401 invalid_credentials` | The wrong password. Say so and let the user retry — but count: five wrong attempts lock the username for fifteen minutes on the login route as well, so the user would be locked out of the app entirely |
| `429 throttled` | The name is in its cool-off, or the `accounts` scope is spent. Show the `Retry-After` wait |
| After `204` | Clear the local store the way a log-out does, and go to the sign-in screen. The token is dead and the socket is already closed with `4003` |
| A retry after a lost response | `401 token_revoked`. Treat it as success: the first call landed |

### The wording is part of the requirement

The dialog must say that this erases what the server holds and **not** copies peers
already have. Every message this account sent was decrypted on the recipient's device
and is stored there; nothing in this call reaches another device. A dialog that says
"delete my data" or "erase my messages" without that sentence is a claim the system
does not keep, and `docs/security/SECURITY.md` § "Best-effort features, worded honestly"
is the rule it breaks.

Two smaller facts belong in the same text if the screen mentions them at all:

- Attachments this account uploaded stay on the server until the retention window
  expires them — `attachment_ttl_days` from `GET /api/v1/config`, 30 days by default.
  Nothing on a stored attachment names an account, so there is no set of them the
  call could delete.
- The username becomes available again immediately. Someone else may register it.

## The directory leaves

[ADR-0028](docs/architecture/decisions/0028-an-exact-username-lookup-replaces-the-directory.md)
removes `GET /api/v1/users`, the list of every activated account, and replaces it with
`POST /api/v1/users/lookup`, which finds one account by its exact name. An account's
owner can hide it from that lookup. **The contact picker fails from the server merge
until this lands**: it calls the removed route.

The observable behaviour is in [`API_CHANGES.md`](API_CHANGES.md) § "The directory
leaves: one exact name finds one account", and `backend/accounts/API.md` carries both
sections.

### Required before release — find people by exact name

What the client does today, read on 2026-10-15: `DirectoryService.refresh()` fetches
the whole list through `fetchActivatedUsers()` and hands it to `replaceDirectory`,
which replaces the local `users` table with it, and the new-contact page searches
that table locally.

| Path | What is needed |
|---|---|
| `frontend/lib/features/contacts/infrastructure/dio_contact_repository.dart` | `fetchActivatedUsers()` and its `GET /api/v1/users` go. In their place, one call: `POST /api/v1/users/lookup` with `{"username": "…"}` in the body — never in the URL — answering `{user_id, username}` or `404` |
| `DirectoryService` and `replaceDirectory` | Nothing refreshes a directory any more, and nothing may replace the local table wholesale: an add-only contact list built from lookups would be erased by the next "refresh". A contact is added when the user adds one and removed when the user removes one |
| The new-contact page | The user types the exact name a person gave them, and the client looks it up once. The local search over contacts already added stays — it is a search of the client's own list. The string "Activated users will appear here after the directory refreshes." describes a server that no longer exists |
| `404 not_found` | One message for every case: no account by that name **can be found**. Never "does not exist" — the account may exist and be hidden or awaiting activation, and the server deliberately does not say which |
| `400 invalid_request` | The name cannot be a username at all: 3 to 32 lowercase letters, digits or underscores. Say so before the call if the field validates as the user types |
| `429 throttled` | The `lookup` scope is fifty a day per account, across all its devices, and every call spends it — found, missed or refused. Show the `Retry-After` wait, which can be hours |
| The contact list | Kept on the client. If it is synced between the user's own devices, it travels only inside end-to-end encrypted blobs the server cannot read — the key backup, or a device-to-device transfer — and never as anything the server can parse. A contact is held by its `user_id`, so the client never needs to look a name up again to reach it |
| The answer | A claim of the server, not a verified identity. Before the first message, the contact's identity is verified exactly as `docs/client/CLIENT_CONTRACT.md` §C and §D require of any peer — §P says why this matters more for a lookup |

### Required before release — the discoverability toggle

`GET` and `PUT /api/v1/me/discoverability` read and set the account's own "find me by
username" setting. It is on for every account, including every account that existed
before this change.

| Path | What is needed |
|---|---|
| Settings | A toggle, on by default, that reads its state with `GET` and sets it with `PUT {"discoverable": true\|false}` — a JSON boolean, not a string. `PUT` sets rather than flips, so a retry after a lost response is safe |
| The toggle's wording | Below |

**The wording is part of the requirement.** Off means one thing: a person who types
this user's name into the lookup is told no account can be found. It does **not**
hide the account from anyone who already has it — a contact, or a member of a group
they share, holds the `user_id` and reaches the account through every route addressed
by one — and registration still reports the name as taken to anyone who tries to
register it. A label such as "Hide my account" or "Make me invisible" is a claim the
system does not keep; "Let people find me by my username" is the setting as it is.
`docs/security/SECURITY.md` states the same limits.

## Contacts, the contact code, and verification by both people

[ADR-0029](docs/architecture/decisions/0029-a-contact-code-and-verification-by-both-people.md)
records the owner's decisions of 2026-10-20: the contact list is the client's alone, a
contact QR code finds and verifies a person, a direct conversation carries content only
once both people have verified each other, the profile key is rotated when the user blocks
someone or removes a contact, and a file's metadata is removed where it safely can be and
announced where it cannot. The binding text is
[`docs/client/CLIENT_CONTACTS_AND_TRUST.md`](docs/client/CLIENT_CONTACTS_AND_TRUST.md), routed from
[`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §Q; where this file and it could
differ, it is authoritative. **Nothing on the server changed**, so no server merge forces
any of this; each section below is client work the owner decided, and the client's own
documents move with it (the last section).

What a direct envelope from an unverified sender meets today, read on 2026-10-20 at
`be0eba5`, is §2 of the binding text: held on the phone and acknowledged when the sender is
merely unverified (client ADR-093), retried unacknowledged for the inspection budget and
then dropped in the other states, and opened with no trust check at all on a session
accepted earlier.

**In this order.** The contact list first, because everything else reads it; then the
`CPCTV001` codec with the vectors of §6.6; then verification by both people, with its
migration; then the contact code, which needs the notice of §5.3; then what a file carries,
which depends on nothing above. The profile key waits for profiles.

### Required before release — the contact list

The lookup work of § "Required before release — find people by exact name" lands in the
same files, and the two are one change.

| Path | What is needed |
|---|---|
| `frontend/lib/features/contacts/infrastructure/drift_contact_repository.dart`, `DirectoryService` in `frontend/lib/features/contacts/application/contact_services.dart` | The `users` table stops being a copy of the server's user list and becomes the contact list of §3.1 to §3.4: entries on and off the list, last-writer-wins by `(revision, author_device_id)`, every change sent at once to this account's other devices as `CPCTV001` kind 1. Blocking is a record of its own (kind 2, §3.3) |
| The first start of the new build | The migration of §3.6: an entry for each peer with a direct conversation or a verified trust record, the usernames of group and voice-room co-members kept as names only, and every other cached directory row deleted |
| `frontend/lib/features/messaging/infrastructure/drift_application_conversation_resolver.dart` | Resolves an own-device copy of a direct message by scanning the `users` table for activated rows. After §3.6 it MUST resolve against the contact list and the peers of the direct conversations this device holds, or an own copy of a message to a peer who is not a contact is refused |
| `frontend/lib/app/dependencies/group_member_name_providers.dart` | Names group members from the contacts store; after §3.6 it reads the kept names, then authenticated profiles, and otherwise says "Unknown member" as today |
| `frontend/lib/features/contacts/presentation/contacts_new_page.dart`, `frontend/lib/features/groups/presentation/group_member_picker.dart`, `frontend/lib/features/voice/presentation/voice_room_invite_page.dart` | The pickers of §3.2: the new-conversation picker lists entries on the list; the two invite pickers list entries on the list whose trust record is `verified` |
| `frontend/lib/features/synchronization/infrastructure/history_transfer_coordinator.dart` | Sends the snapshot of §3.5 to the new device before the transfer's completion event, and the receiving side applies it as live records |
| Settings, the discoverability toggle | The added sentence of §3.2: "Anyone you show your code to can still add you." |

### Required before release — the contact code

| Path | What is needed |
|---|---|
| New screens | **My code**, the scanner, the image path and the mismatch alert, worded as §4.2 to §4.5 say |
| The application's own Android code, beside `frontend/android/app/src/main/kotlin/com/example/communication_platform/AttachmentChannel.kt` | The camera frames from `android.hardware.camera2` and the decoder of §4.7, `com.google.zxing:core`, pinned exactly and added to the offline Gradle mirror |
| `frontend/android/app/src/main/AndroidManifest.xml` | `android.permission.CAMERA`, and `<uses-feature android:name="android.hardware.camera.any" android:required="false"/>` |
| `AttachmentChannel.kt`, the camera capture | With `CAMERA` declared, `MediaStore.ACTION_IMAGE_CAPTURE` throws `SecurityException` unless the permission is held, so the capture requests it first and says plainly when it is refused (§4.7) |
| `frontend/lib/features/contacts/presentation/safety_number_page.dart` | Drop the display-only `CP-SAFETY-V1` symbol; offer **Scan their code** and **Show my code** in its place (§5.11) |
| The tests | The vectors of §4.8, the refusals among them |

### Required before release — verification by both people

| Path | What is needed |
|---|---|
| `frontend/lib/features/synchronization/infrastructure/pairwise_opaque_envelope_inspector.dart`, `frontend/lib/features/synchronization/application/durable_sync_engine.dart` | Recognise `CPCTV001` before `_prepareApplication` (§6.1); apply the admission of §5.6 in `_inspectRegular` and after an accepted initial alike — a session accepted earlier no longer bypasses it. A dropped event is a new outcome: the envelope is committed with its session transition and without the event, and acknowledged at once — not a `policyBlocked` failure that spends the budget. Add the read of §5.3 to the unverified branch of `_inspectInitial`, committing nothing |
| `frontend/lib/features/contacts/application/client_authentication_service.dart`, `frontend/lib/features/contacts/application/ports/contact_ports.dart` | The claims, the carried-over confirmations and the derived state of §5.4 and §5.5. A verification sends the notice to the peer's devices and the own-device copy in one call (§5.3) |
| `frontend/lib/features/pairwise/application/pairwise_fanout_coordinator.dart`, `frontend/lib/features/messaging/application/conversation_use_cases.dart` | Refuse a direct-conversation event unless the conversation is `MUTUAL` (§5.6) |
| `frontend/lib/features/signals/application/presence_channel.dart` | Typing and online status for a direct conversation in `MUTUAL` only; groups as [§ "Required before release — who can see my online status"](#required-before-release--who-can-see-my-online-status) says |
| `frontend/lib/features/messaging/presentation/chats_list_page.dart`, `frontend/lib/features/messaging/presentation/direct_chat_page.dart`, the contacts screens | The panels, rows and words of §5.11 |
| `frontend/lib/features/messaging/presentation/chat_undelivered_hint.dart` | Withdrawn, with its tests: the cause it names cannot occur any more (§5.11) |
| The first start of the new build | The migration of §5.10, once |

**Groups are unchanged, and there is a decision the owner has not made.** The brief for
this work said that a group send skips the members its sender has not verified. It does
not: a group send withholds the whole copy when one member is not verified
(`pairwise_fanout_coordinator_test.dart`, "a member that fails verification withholds the
whole copy"). The same reading shows that a group event arriving on a session accepted
earlier is admitted with no check of its sender's current trust record — the gap §5.6
closes for direct conversations. The binding text leaves both as they are (§5.9). Nothing
here is the client developer's to change until the owner decides.

### Required before release — what a file carries

| Path | What is needed |
|---|---|
| `AttachmentChannel.kt`, the copy | The procedures of §8.2 on the outgoing copy, the proof of §8.3, the neutral names of §8.1 — a photo becomes `photo.jpg` in place of `jpegName`'s base of the original — and, in the answer to Dart, which of W1, W2 or none applies |
| The preview step (`frontend/docs/ui-specification.md` §8.2) | The warnings of §8.4, above **Send**, which stays enabled |

### Required before profiles ship — the profile key

Profiles are not published by any production build today: `profilePublishingProvider`
resolves the unsupported adapters, so nothing here is due until real profile encryption
and key delivery are.

| Path | What is needed |
|---|---|
| `ProfileService` in `frontend/lib/features/contacts/application/contact_services.dart`, and the two profile ports | §7: a fresh key for every version, the audience of §7.2, the kind-5 records of §7.3, the publish on a block or a removal of §7.4, and the rule of §7.5 for two devices at once |

### The client documents to update

Each of these describes behaviour this work changes. The client developer updates them as
the work lands, and the binding text wins where they differ.

| Document | What changes |
|---|---|
| `frontend/docs/message-protocol.md` | The registry: `contact.master_verify`, `contact.block_set`, `protocol.notice` and `profile.publish`, and the new `contact.entry_set`, are carried as `CPCTV001` payloads rather than application-event kinds, as `group.control` is carried as `CPGSV001`; `contact.master_verify` goes to the peer as well as to own devices. § "Blocking" against §3.3 and §5.6. A section for the admission of a direct conversation (§5.6). § "Receipts and typing" and the presence rules: a direct conversation in `MUTUAL` only. § "Own-device history": the snapshot |
| `frontend/docs/cryptographic-protocol.md` | § "Safety numbers and cross-signing": the contact code replaces the `CP-SAFETY-V1` symbol, and verification is by both people. § "Recovery and device-to-device history": correct the sentence that says the backup includes user-signing signatures over verified peers' master keys — the `CPKBV001` plaintext is the three private keys and nothing else — and say that contacts and verifications travel in the snapshot. § "Profiles and labels": §7. § "Direct messages and per-device channels": the read of §5.3 |
| `frontend/docs/pairwise-transport-v1.md` | § "Sender-hidden initial header", steps 2 to 4: the non-committing read of §5.3 as the one exception to "under the already confirmed master key" |
| `frontend/docs/sync-engine.md` | Held envelopes: the read of §5.3. The history transfer: the snapshot of §3.5 |
| `frontend/docs/ui-specification.md` | §6 (the rows and previews), §7 (the add sheet and the state words), §8 (the panel), §8.2 (the warnings), §11 and §11.1 (the safety-number page), §15 (My code, the discoverability sentence) |
| `frontend/docs/platform-android.md` | "Why there is no `CAMERA` permission" no longer holds (§4.7). The scanner. The copy's removal of metadata (§8) |
| `frontend/docs/local-data-model.md` | The contact, block, claim, carried-over and profile-key records |
| `frontend/docs/threat-model.md` | The verification statements, against `docs/security/SECURITY.md` residual risk 7 |
| `frontend/docs/decisions.md` | One new ADR recording this work on the client side — as ADR-068 to ADR-070 recorded server ADRs — that amends ADR-093 (the read of §5.3 beside D12; the row of D18 gains the claim; the hint of D19 is withdrawn), ADR-089 and ADR-097 (the neutral names and the removal of metadata) and ADR-098 (presence for a direct conversation in `MUTUAL` only), and records `com.google.zxing:core` under ADR-054's rules: the exact version, its licence, and the date and source it was read from |
| `frontend/docs/implementation-checklist.md` | Only as each piece is done and verified |


## Recommended — the documents that moved

[ADR-0030](docs/architecture/decisions/0030-the-security-model-and-the-client-contract-move-under-docs.md)
moves three documents under the root `docs/` directory. Nothing the client does changes,
and nothing breaks: each old path keeps a pointer file that links the new one. What is left
is the client's own documents, which still name the old paths.

| Old path | New path |
|---|---|
| `backend/SECURITY.md` | [`docs/security/SECURITY.md`](docs/security/SECURITY.md) |
| `backend/CLIENT_CONTRACT.md` | [`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) |
| `backend/CLIENT_CONTACTS_AND_TRUST.md` | [`docs/client/CLIENT_CONTACTS_AND_TRUST.md`](docs/client/CLIENT_CONTACTS_AND_TRUST.md) |

On 2026-10-21, 53 files under `frontend/` linked these paths 146 times — 74 of them the
contract, `frontend/AGENTS.md` and `frontend/docs/backend-api.md` among them — and none of
them names a section, so a search for the three old paths finds every link to change. The
per-app `API.md` files did not move. Once no client document names an old path, the pointer
files can go; say so here and the server side deletes them.

## Online status, read receipts, who reacted and roles in voice rooms

[ADR-0031](docs/architecture/decisions/0031-online-status-stays-client-protocol-over-signal-frames.md)
records the owner's decisions of 2026-10-22: who can see a person's online status, a
read-receipt setting for direct conversations, a list of who reacted, and roles in voice rooms.
The binding texts are
[`docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md`](docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md),
routed from [`docs/client/CLIENT_CONTRACT.md`](docs/client/CLIENT_CONTRACT.md) §R, and
[`docs/client/CLIENT_VOICE_ROLES.md`](docs/client/CLIENT_VOICE_ROLES.md), routed from §N rule
12; where this file and they could differ, they are authoritative. **Nothing on the server
changed**: the gateway still holds no presence, and no server merge forces any of this.

Online status starts from what client ADR-098 built (PR #90): the binding text states that
protocol as binding and lists every change to it in its §2. Two of the changes are choices the
owner made on 2026-10-22, when asked: presence in every group of up to 50 members, still at most
two devices of each; and the status audience and the read-receipt setting held for the whole
account, synced between its own devices, rather than per phone.

**In this order.** `CPCTV001` kind 7 first, inside the codec of § "Required before release —
verification by both people", because both settings live in it; then who can see my online
status, with the migration of the switch; then the read-receipt setting, which reads the same
record; then who reacted, which depends on nothing above. Roles in voice rooms come last and are
due only if voice ships: they need a change to the shared Rust core and the client ADR below.

### Required before release — who can see my online status

| Path | What is needed |
|---|---|
| `frontend/lib/features/signals/application/presence_channel.dart` | The admission of §3.3 on every `watch`, `here`, `typing` and `gone`: `MUTUAL` for a direct conversation, never a blocked account, always inside the audience — and again for every frame it seals, with a block, a trust drop, a group removal or a change of the audience ending that account's leases at once (`_typingTargets` checks only the lease's expiry today). The targets of §3.4, drawn from the audience. `maximumGroupMembers` from 32 to 50, with `devicesPerMember` still 2. The renewal's answer window counted from the moment its frame leaves the pacer — `_watchRound` sets `renewedAt` at the round's start today. Sealing on release (§3.8) — `_send` seals a whole round before it paces it. The goodbye's limit (§3.6). The narrowing of §4.3 |
| `frontend/lib/features/signals/application/presence_share_setting.dart`, `DriftPresenceSharePreference` in `frontend/lib/features/signals/infrastructure/drift_presence_stores.dart` | Replaced by the audience of the privacy record (§4, §5): three values, for the whole account. `presence.share.v1` is migrated once and deleted, on a database an earlier build created (§5.4). A device that holds no record while its account has another live device, or that cannot read its record, sends no presence frame and no read receipt until it has one (§5.2) |
| `frontend/lib/features/signals/application/presence_status_book.dart` | N counts the audience only; the last seen of an account that leaves the audience is deleted |
| `frontend/lib/features/signals/presentation/online_status_settings_entry.dart` | The row **Who can see my online status**, its three choices and its line (§4.4) |
| `frontend/lib/features/signals/presentation/peer_status_line.dart` | A last seen in an earlier year carries its year (§3.9) |
| The disclosure: `DisclosurePoint.onlineStatus` and `disclosureOnlineStatus` | Revision 12, with the text of §4.4 |
| The `CPCTV001` codec of § "Required before release — verification by both people" | Kind 7, its register and its migration (§5), against the vectors of §12.2; the record goes to each new own device as soon as it appears, with or without a history transfer (§5.3) |
| The tests | §11, and the vectors of §12 — the `CPPSV001` ones are the client's own golden bytes |

### Required before release — the read-receipt setting

| Path | What is needed |
|---|---|
| `MarkConversationVisiblyRead` in `frontend/lib/features/messaging/application/conversation_use_cases.dart` | With the setting off, a direct conversation's read receipt is sealed for this account's other devices only, and nothing is sent later for what was read while it was off (§6) |
| `frontend/lib/features/messaging/presentation/direct_chat_page.dart` | `allowReadReceipts: !widget.savedMessages` becomes three answers: none in Saved Messages, own devices only with the setting off, the peer and own devices with it on |
| `_delivery` in `frontend/lib/features/messaging/presentation/chat_view_model_mapper.dart` | With the setting off, an own message of a direct conversation shows at most its delivered state |
| Settings | The switch row **Read receipts** and its line (§6) |
| `frontend/lib/features/groups/presentation/group_chat_page.dart` | Nothing: a group always sends its read receipts, and client ADR-091's reader list is unchanged |

### Recommended — who reacted

| Path | What is needed |
|---|---|
| `frontend/lib/features/messaging/presentation/chat_message_builder.dart` | **Reactions** in the message's context menu when it has a reaction; the chip's own tap is unchanged |
| A new sheet, and the read behind it | §7: the tabs and their order, the rows and their names, and every chip's count equal to its tab's rows; the read needs the `ordering_ms` of the event the fold kept |

### Required if voice ships — roles in voice rooms

| Path | What is needed |
|---|---|
| `frontend/native/crypto_core/src/room_control.rs` | Version 2: operations 5 and 6, their bodies and checks, with version 1 still refusing both (§3.1), and the vectors of §10.2 beside the core's own golden tests |
| `frontend/lib/features/voice/infrastructure/native_room_control_crypto.dart` | The projection of a version-2 event |
| `frontend/lib/features/voice/domain/room_model.dart` | `RoomState` carries its version and each member's role; `RoomControlStateMachine` applies §3.3, the derived owner of §4.1 and the upgrade; `RoomAuthorization` answers the matrix of §2 |
| `frontend/lib/features/voice/domain/room_sync_payload.dart`, `frontend/lib/features/voice/application/room_inbound_coordinator.dart` | `CPVRV001` kind 4, and the version each peer device announced (§4.2) |
| `frontend/lib/features/voice/application/room_session_starter.dart` | The announcements of §4.2, and their daily re-sending to a device whose announcement is missing |
| `frontend/lib/features/voice/application/room_use_cases.dart` | The version a new room is created at (§3.2), change of role, **Hand over and leave**, the upgrade by the owner's lowest live device and its fallback, and no upgrade of a room whose creator has left (§3.4, §4.1, §4.3) |
| `frontend/lib/features/voice/domain/voice_signal_codec.dart`, `frontend/lib/features/voice/domain/voice_signal_model.dart` | Signalling version 2: kinds 9 to 12 and leave reasons 4 and 5 (§5.2) |
| `frontend/lib/features/voice/application/voice_call_engine.dart`, `frontend/lib/features/voice/application/voice_signal_transport.dart` | The signalling version of each room (§5.1), the checks and effects of §5.4 and §5.5, a newcomer's `moderation` (§5.6), and the allowance of 16 (§5.3) |
| `frontend/lib/features/voice/presentation/voice_room_info_page.dart`, `frontend/lib/features/voice/presentation/voice_call_page.dart`, `frontend/lib/features/voice/presentation/voice_room_invite_page.dart` | Role tags, the actions each role has, the words of §5.7, and the messages of §4.3 and §4.4 |
| The tests | §9, and the vectors and scenarios of §10 |

### The client documents to update

Each of these describes behaviour this work changes. The client developer updates them as the
work lands, and the binding texts win where they differ.

| Document | What changes |
|---|---|
| `frontend/docs/message-protocol.md` | § "Receipts and typing": every statement §2.2 of `CLIENT_PRESENCE_AND_RECEIPTS.md` lists — the list in "No claim the client cannot observe" loses "a group over 32 members" and gains "a peer outside your audience"; "Who may send and receive"; "Watching"; "The switch", replaced by the audience; and the opening sentence's "user privacy settings", which becomes the read-receipt setting. § "Event registry": `privacy.settings_set` as `CPCTV001` kind 7, and `room.control` with its version 2. § "Edits, reactions, pins, and deletion": who reacted. § "Blocking": presence refuses a blocked account. § "Voice rooms": "every active member has the same authority … There is no owner and no admin" holds for version-1 rooms only |
| `frontend/docs/voice-signalling-v1.md` | `CLIENT_VOICE_ROLES.md` folded in as its version-2 part: in Part 1, § "The operations, and who may sign each", § "Applying an event", § "The payload" (kind 4) and § "Starting the sessions a call needs" (the announcement); in Part 2, § "The kinds" (9 to 12, leave reasons 4 and 5), § "Removal" and § "The call" (the in-call actions), and the allowance beside § "Volatile seal and open" |
| `frontend/docs/decisions.md` | One new client ADR that amends ADR-098 — D4 (every group, the answer window), D5 (the goodbye's limit), D7 (sealing on release), D9 (the audience and the privacy record in place of the switch), D10 (revision 12) and D11 (the year) — records the read-receipt setting beside ADR-091, whose reader list it leaves as it is, and supersedes ADR-077's D1 for version-2 rooms, with the allowance of 16 beside D5's 32 frames. ADR-077's open question about room text stays open |
| `frontend/docs/ui-specification.md` | §15: item 5c becomes **Who can see my online status**, and a **Read receipts** row joins it. §8 and §9: the **Reactions** sheet. §13.2: role tags, the actions of each role and the removal confirmation, for version-2 rooms |
| `frontend/docs/design-handoff/voice-room-states.md` | The new states: muted by the owner or an admin, removed from the call, the call ended, waiting for members to update, and a member who needs the app update |
| `frontend/docs/local-data-model.md` | The privacy record, the room version each peer device announced, and a room's version and roles |
| `frontend/docs/threat-model.md` | The reading activity presence shows (`docs/security/SECURITY.md` § "Residual risk") and what a mesh can enforce (`CLIENT_VOICE_ROLES.md` §6) |
| `frontend/docs/implementation-checklist.md` | Only as each piece is done and verified |
