# Client work

What the client developer owes, and nothing else. The server cannot change a file
under `frontend/`, so an obligation that lands there is recorded here instead.

This file routes; it never repeats. The contract the client implements is
[`backend/CLIENT_CONTRACT.md`](backend/CLIENT_CONTRACT.md), the observable changes
are in [`API_CHANGES.md`](API_CHANGES.md), and the endpoint reference is the per-app
`API.md` files with [`backend/openapi.json`](backend/openapi.json) beside them.

Each run of the server appends its section. Nothing is removed from this file except
by the developer who did the work.

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
[`backend/CLIENT_CONTRACT.md`](backend/CLIENT_CONTRACT.md) §O.

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
[`backend/CLIENT_CONTRACT.md`](backend/CLIENT_CONTRACT.md) §N is the binding text, the
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
| `frontend/lib/app/dependencies/messaging_providers.dart` | `presenceProjectionProvider`, and the comment saying nothing should read it "until `subscribe_presence` is sent". It will not be sent: presence between conversation members is client protocol over `signal` frames now, per `backend/CLIENT_CONTRACT.md` §N rule 5 |
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
[`backend/CLIENT_CONTRACT.md`](backend/CLIENT_CONTRACT.md) §M states both enrollment
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
