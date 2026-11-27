# ADR-078: Pinning `flutter_webrtc` 1.6.2+hotfix.3 and Android call permissions

- **Status:** Accepted (2026-09-28); `turns:` relay trust question answered for client (2026-09-30)
- **Date:** 2026-09-28 (explicitly recorded in register and full section; dependency/build changes in `d5e1dd24`, `141fce47`, `b8679dff`, `b2af5b20`, `8d759c00`; `turns:` answer in `8f6d724a`)
- **Related:** [ADR-043](043-private-ca-transport.md), [ADR-051](051-sustained-delivery.md), [ADR-054](054-dependency-policy.md), [ADR-059](059-emoji-surface.md), [ADR-077](077-voice-mesh.md), [ADR-079](079-voice-device-run.md), server [ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)

## Decision (Position)

Evaluated and pinned the Android WebRTC dependency under [ADR-054](054-dependency-policy.md) rules for [ADR-077](077-voice-mesh.md)'s relayed voice design:

1. **D1 — Exact pin of `flutter_webrtc` `1.6.2+hotfix.3` ([pubspec.yaml](../../../pubspec.yaml)):**
   - Pinned `flutter_webrtc: 1.6.2+hotfix.3` (MIT license, verified publisher `flutter-webrtc.org`, published 2026-09-15; newest release as of 2026-09-28). Rejected `livekit_client` because it requires `connectivity_plus` 7, which pulls `androidx.core` 1.18.0 and `compileSdk` 36.1 against [ADR-054](054-dependency-policy.md).
   - Its `android/build.gradle` is byte-identical to `1.6.1`, linking `io.github.webrtc-sdk:android:150.7871.01` and `com.github.davidliu:audioswitch:039a35aefab7747c557242fa216c9ea11743b604` with `compileSdkVersion 36`, `minSdkVersion 21`, no `androidx.core` dependency, and `iceTransportPolicy` / `setConfiguration` / `restartIce` support.
   - Opt-in `initialize()` field trials added in 1.6.2 (`enableWARP` / `WebRTC-IceHandshakeDtls` and `zeroPlayoutDelay`) stay off unless decided separately; `dependency_policy_test.dart` ([dependency_policy_test.dart](../../../test/architecture/dependency_policy_test.dart)) was updated to permit dot-separated build identifiers in exact `pub_semver` pins.
2. **D2 — Complete transitive Dart and Android payload recorded:**
   - **Dart (`pubspec.lock`):** Added `flutter_webrtc` 1.6.2+hotfix.3, `webrtc_interface` 1.5.1, `logger` 2.8.0, `synchronized` 3.4.2, and `dart_webrtc` 1.8.2 (browser implementation, uncompiled on Android); moved zero existing pins.
   - **Android ([gradle.lockfile](../../../android/app/gradle.lockfile)):** Release runtime classpath grew from 91 to 93 modules, adding:
     - `io.github.webrtc-sdk:android:150.7871.01` (Maven Central, BSD 3-Clause, SHA-256 `0a1627b1a48c2bc17d9a40d62fc47bd45166f44a311e95917f147c402de379b0`; licence/patent notices copied to [WebRTC-LICENSE.txt](../../licenses/WebRTC-LICENSE.txt) and [WebRTC-PATENTS.txt](../../licenses/WebRTC-PATENTS.txt)).
     - `com.github.davidliu:audioswitch:039a35aefab7747c557242fa216c9ea11743b604` (JitPack, Apache-2.0, SHA-256 `c8240221daa9a96d4ea01a4dc6f6f6b10b4903d2a71f9b57f838bdfeb6c3fcbc`).
     - Added zero manifest components (still 5 components, 1 exported at ADR-078).
   - **Native binary & TLS correction:** Added `libjingle_peerconnection_so.so` across three ABIs (`16,166,352` bytes `x86_64`, `12,287,312` bytes `arm64-v8a`, `6,809,404` bytes `armeabi-v7a` — `35,263,068` bytes of the `+35,504,421`-byte unsigned production APK growth from `88,199,375` to `123,703,796` bytes, plus `237,127` bytes compressed `classes.dex`). The native library bundles BoringSSL (for endpoint-to-endpoint DTLS-SRTP), libsrtp, Opus, libvpx 1.16.0, libaom, dav1d, dcsctp, libyuv, and abseil-cpp, and opens call sockets outside `dart:io` and the provisioned trust store (`NetworkMonitorAutoDetect`, `PlatformCertificateVerifier`), correcting [platform-android.md](https://github.com/Orviniq/communication-platform/blob/6fec14ee3a099d3455f8d8f968bdf2565c9599ba/frontend/docs/platform-android.md)'s claim that no Java/Kotlin/native code outside `dart:io` opens a network connection.
3. **D3 — Bidirectional JitPack restriction ([build.gradle.kts](../../../android/build.gradle.kts), [settings.gradle.kts](../../../android/settings.gradle.kts)):**
   - Because `flutter_webrtc`'s build script injects an unfiltered JitPack repository into every project and JitPack builds arbitrary public coordinates, `android/build.gradle.kts` places JitPack inside `exclusiveContent` for `com.github.davidliu:audioswitch`, and `android/settings.gradle.kts` registers a `gradle.allprojects` repository rule restricting every `jitpack.io` repository declaration (including `flutter_webrtc`'s) solely to `com.github.davidliu:audioswitch`.
   - Verified with an unpublished probe coordinate and an offline `:app:assembleDevelopmentDebug` build (43 s); pinned by [dependency_policy_test.dart](../../../test/architecture/dependency_policy_test.dart).
4. **D4 — Call permissions and `BLUETOOTH` refusal ([AndroidManifest.xml](../../../android/app/src/main/AndroidManifest.xml)):**
   - Added `RECORD_AUDIO` (dangerous; requested strictly at call join per [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) §N rule 11) and `FOREGROUND_SERVICE_MICROPHONE` (normal; required on Android 14+ for `microphone` foreground service) alongside existing `FOREGROUND_SERVICE` ([ADR-051](051-sustained-delivery.md)).
   - Explicitly declared `MODIFY_AUDIO_SETTINGS` merged from `audioswitch` so all 12 manifest permissions are visible and checked by [verify_release_apk.sh](../../../tool/verify_release_apk.sh) and [message_alert_policy_test.dart](../../../test/architecture/message_alert_policy_test.dart).
   - Refused `audioswitch`'s `BLUETOOTH` (`maxSdkVersion` 30) via `tools:node="remove"` because `flutter_webrtc` constructs `AudioSwitch` (not `LegacyAudioSwitch`'s `BluetoothHeadsetManager`, which would otherwise target `BLUETOOTH_CONNECT` at targetSdk 36) and no Bluetooth route exists in [ADR-077](077-voice-mesh.md) or [Live Voice Room Screen](../../ui/SCREENS.md#live-voice-room-screen).
5. **D5 & D6 — Preserved pins and Gradle lockfile workaround:**
   - Retained `androidx.core:core:1.16.0`, `connectivity_plus` 6.0.5, `compileSdk` 36, `androidx.annotation` 1.8.1, and `kotlin-stdlib` 2.3.20.
   - Kept `org.jetbrains.kotlin:kotlin-stdlib-common:2.3.20` in `android/app/gradle.lockfile` because `./gradlew :app:writeDependencyLocks --write-locks` drops it even on the unmodified baseline while `dependencyInsight` still resolves it for `kotlinx-coroutines-core` 1.7.3 and `okio` 3.4.0.

## Rationale

- Isolating `flutter_webrtc` 1.6.2+hotfix.3 behind [ADR-054](054-dependency-policy.md) pins, `exclusiveContent` JitPack filtering, and explicit manifest refusal keeps the existing `androidx.core` 1.16.0 and `compileSdk` 36 boundary intact while allowing offline-reproducible Android builds and endpoint-to-endpoint DTLS-SRTP media.

## Constraints and Open Gates

- **Scope at ADR-078 (`b2af5b20`):** Initial ADR-078 added the dependency and manifest/repository rules without Dart usage (`flutter_webrtc_local_audio.dart` and `flutter_webrtc_peer_media.dart` were added subsequently in phase 6 prompt 5 and guarded by [voice_media_boundary_test.dart](../../../test/architecture/voice_media_boundary_test.dart)); changed no cryptographic construction, wire format, signing config, or `backend/` file; opened no production gate.
- **`turns:` TLS relay resolution (2026-09-30, `8f6d724a`):** libwebrtc's `PlatformCertificateVerifier` consults compiled-in `ssl_roots.h` and platform trust managers rather than the client's provisioned private CA. Answered for the client on 2026-09-30 ([VOICE-V1.md](../../contracts/VOICE-V1.md)): only `turn:` URLs are accepted, and any credential naming a `turns:` URL is refused whole while [SECURITY.md](../../../../docs/security/SECURITY.md) / server coturn has no TLS listener; trusting a future TLS relay remains undecided until the server adds one.
- **Recorded follow-ups (F1–F5):**
  - **F1:** Aggregated third-party notices for libwebrtc m150 (`libjingle_peerconnection_so.so`) are not yet generated from source (`tools_webrtc/libs/generate_licenses.py`), leaving notices in [third-party-notices.md](../../third-party-notices.md) incomplete alongside the Rust core ([ADR-054](054-dependency-policy.md) F3).
  - **F2:** `flutter_webrtc` still applies the legacy Kotlin Gradle Plugin rather than built-in Kotlin (similar to `emoji_picker_flutter` in [ADR-059](059-emoji-surface.md) F2).
  - **F3:** Checksums in D2 are documented rather than enforced via Gradle dependency verification metadata, and JitPack pins source commit rather than a reproducible binary checksum.
  - **F4:** Gradle `--write-locks` vs. `kotlin-stdlib-common` validation mismatch remains until a toolchain upgrade.
  - **F5:** Retaining `x86_64` `libjingle_peerconnection_so.so` adds 16.17 MB solely for emulators; ABI splitting/pruning for distributed builds remains a separate distribution decision.

## Costs

- Adds 35.5 MB to the unsigned production APK (mostly `libjingle_peerconnection_so.so` across three ABIs) and introduces a second unreviewed native TLS/crypto stack (BoringSSL inside libwebrtc, used strictly for DTLS-SRTP media and never invoked directly by app code).
- Depends on JitPack availability (requiring a mirror per [deployment-and-release.md](../../deployment-and-release.md) for air-gapped/CI resilience).

## Reversal Trigger

Reopen if upgrading `flutter_webrtc` (e.g., to adopt built-in Kotlin or enable `enableWARP`/`zeroPlayoutDelay`), adding a Bluetooth headset route (`BLUETOOTH_CONNECT`), supporting a `turns:` TLS relay, pruning `x86_64` from distributed APKs, or regenerating complete m150 libwebrtc third-party notices.

## History, Amendments, and Supersession

- **2026-09-28 (`d5e1dd24`, `141fce47`, `b8679dff`, `b2af5b20`, `8d759c00`):** Recorded and implemented ADR-078 (`Accepted`), pinning `flutter_webrtc` `1.6.2+hotfix.3`, scoping JitPack to `com.github.davidliu:audioswitch`, updating manifest permissions/APK verification, and correcting [platform-android.md](https://github.com/Orviniq/communication-platform/blob/b8679dff5999ad427a34e0e62e2bba1f524c24cf/frontend/docs/platform-android.md) and libwebrtc TLS documentation.
- **2026-09-30 (`8f6d724a`):** Answered D6/unresolved `turns:` trust question for the client by accepting only `turn:` relay URLs and refusing `turns:` whole until a server TLS listener exists.
