# ADR-043: Exclusive private-CA transport trust in dart:io; Android network security config as defence in depth

- **Status:** Accepted (runtime leaf SPKI pinning vs. exclusive private-CA trust flagged as open owner decision by [ADR-076](076-production-signing.md) D7, 2026-09-14)
- **Date:** 2026-08-20 (explicitly recorded in register; committed in `9515be30`)
- **Related:** [ADR-004](004-rest-and-websocket.md), [ADR-042](042-beta-signing.md), [ADR-044](044-private-deployment.md), [ADR-047](047-networking-composition.md)

## Decision (Position)

*(Extracted from the ADR-043 register row, its introducing commit `9515be30`, and verified current implementation; no separate full section existed in `decisions.md`.)*

The client's own API and WebSocket traffic trusts the provisioned private certificate authority (CA) exclusively inside `dart:io`, while Android's `network_security_config.xml` is retained strictly as defence in depth for non-Dart traffic:

1. **Exclusive private-CA `SecurityContext` in `dart:io`:** [TransportSecurity.provisioned](../../../lib/features/networking/infrastructure/tls/transport_security_native.dart) builds a `SecurityContext(withTrustedRoots: false)` loaded with the provisioned private CA bytes (`<ENV>_PRIVATE_CA_PEM_BASE64`). This **replaces** rather than extends the platform root store so no public CA can issue an accepted certificate, while BoringSSL / platform TLS still performs full chain construction, expiry, and hostname verification. `badCertificateCallback` unconditionally returns `false`.
2. **Shared trust context and fail-closed startup:** Both REST (plus attachments) and WebSocket transports consume the same `TransportSecurity` instance ([NetworkingFoundation](../../../lib/app/dependencies/networking_foundation.dart)). Absent or malformed CA material fails configuration closed rather than falling back to public roots.
3. **No hand-rolled leaf SPKI pinning in Dart:** Leaf SPKI pinning is deliberately not reimplemented in Dart (`X509Certificate` exposes neither an SPKI accessor nor SHA-256), avoiding unreviewed ASN.1 parsing and hashing inside the TLS path.
4. **Android `network_security_config` demoted to non-Dart defence in depth:** The rendered Android XML and its primary/backup SPKI pins remain verified in release builds, but strictly for any future WebView or Java-side traffic. Documentation must never claim Android's network security configuration protects the app's API traffic.
5. **Distinguished trust failures:** Health checks distinguish `trustRejected` (`HandshakeException` / `CertificateException`) from ordinary connectivity failures so a refused certificate is never reported or retried as an outage.

## Rationale

- During release validation of a real signed Beta APK, the app could not reach a healthy, correctly provisioned server even though DNS, TCP, TLS, CA chain verification, and ~1.1 s latency all held — and removing `<pin-set>` changed nothing.
- Inspection showed Android's `network_security_config` governs Java HTTP stacks and WebView, whereas this app's REST (`Dio`) and WebSocket (`IOWebSocketChannel`) traffic both run on `dart:io`, which does not consult Android's XML config. The prior setup left API traffic both unreachable and, had it connected, unpinned.
- Replacing the built-in root store with a single offline private CA is a stronger constraint than public-CA-plus-leaf-pinning, and avoids violating [AGENTS.md](../../../AGENTS.md)'s ban on custom cryptographic/ASN.1 parsing code in Dart.

## Constraints and Open Gates

- **Open owner decision (ADR-076 D7, [STATUS.md](../../STATUS.md#platform-identity-and-content), [ANDROID.md](../ANDROID.md#network-trust)):** ADR-043 and the current code ([transport_security_native.dart](../../../lib/features/networking/infrastructure/tls/transport_security_native.dart)) enforce exclusive private-CA trust in `dart:io` without runtime leaf SPKI pinning, whereas ADR-067 D4, [server ADR-0027](../../../../docs/architecture/decisions/0027-the-serving-origin-moves-and-a-pin-moves-with-it.md), and [SECURITY.md](../../../../docs/security/SECURITY.md#trust-boundaries) describe or rely on runtime SPKI pinning. Build scripts still check `PRODUCTION_PRIMARY_SPKI_SHA256` against the live host and render `network_security_config.xml` with primary and backup pins ([ANDROID.md](../ANDROID.md#network-trust)). Whether runtime SPKI pinning must also be enforced in Dart remains an open owner decision.
- All background and foreground entry points must construct the provisioned context through `ApplicationRuntime` ([background_delivery_policy_test.dart](../../../test/architecture/background_delivery_policy_test.dart)).

## Costs

- **Accepted residual risk:** Because leaf SPKI pinning is absent at runtime in `dart:io`, a stolen private CA key could mint an accepted leaf certificate.
- **No runtime CA recovery:** Replacing `withTrustedRoots` means a lost or compromised private CA requires an out-of-band client rebuild and redistribution to restore connectivity ([ADR-044](044-private-deployment.md)).

## Reversal Trigger

Reopen if the owner decides Dart runtime SPKI pinning must be enforced alongside exclusive private-CA anchoring (ADR-076 D7), or if the deployment moves away from a single private CA.

## History, Amendments, and Supersession

- **2026-08-20 (`9515be30`):** Recorded ADR-043 (`Accepted`), correcting [platform-android.md](https://github.com/Orviniq/communication-platform/blob/9515be300ffe62a6e80b3e6d96ff26ac31028f67/frontend/docs/platform-android.md), [provisioning README](../../../android/provisioning/README.md), and [SIGNING.md](../../runbooks/SIGNING.md).
- **2026-09-07 (ADR-067):** Reused the private CA unchanged across the `chat.orviniq.com` origin move, while leaf regeneration moved `BETA_PRIMARY_SPKI_SHA256` in build-time pin config.
- **2026-09-14 (ADR-076 D7):** Flagged the mismatch between exclusive private-CA trust in `dart:io` and SPKI-pinning expectations in server/security documentation as an open owner decision.
