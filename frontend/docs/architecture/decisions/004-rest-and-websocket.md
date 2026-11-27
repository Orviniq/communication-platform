# ADR-004: Dio for REST and a dedicated WebSocket gateway

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-001](001-feature-first-architecture.md), [ADR-013](013-no-foreign-push.md), [ADR-015](015-web-session.md), [ADR-033](033-android-release-target.md)

## Decision (Position)

Use **Dio** (`dio: 5.11.0` in [pubspec.yaml](../../../pubspec.yaml)) for REST transport and a **dedicated WebSocket gateway** (`web_socket_channel: 3.0.3`) behind application ports.

1. `DioRestClient` ([dio_rest_client.dart](../../../lib/features/networking/infrastructure/api/dio_rest_client.dart)), `TokenCoordinator` ([token_coordinator.dart](../../../lib/features/networking/infrastructure/auth/token_coordinator.dart)), and `DioWebSocketGateway` ([dio_websocket_gateway.dart](../../../lib/features/networking/infrastructure/realtime/dio_websocket_gateway.dart)) are composed on one shared `NetworkingFoundation` ([networking_foundation.dart](../../../lib/app/dependencies/networking_foundation.dart)).
2. Both REST and WebSocket transports share one `dart:io` `SecurityContext` configured exclusively with the provisioned private CA (ADR-043) and enforce redaction, single-flight token renewal, retry rules, and protocol limits.
3. The WebSocket gateway is a wakeup/signal channel and delivery hint; authoritative envelope retrieval and durability stay on the REST drain (`GET /api/v1/me/envelopes`).

## Rationale

Centralizes authentication headers, sensitive-field redaction in logs/diagnostics, single-flight token renewal, retry backoff, TLS trust configuration, and protocol frame limits in one audited networking layer.

## Constraints and Open Gates

- Defined in [Architecture](../../architecture.md) and [Synchronization engine](../../sync-engine.md).
- On Android, `dart:io` does not consult `network_security_config.xml`, so `SecurityContext(withTrustedRoots: false)` plus the provisioned private CA enforces TLS trust (ADR-043).
- Under [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md) and ADR-069, the `/ws` gateway authenticates solely via the `Authorization: Bearer` upgrade header.
- Open gate: [Frontend status](../../STATUS.md#platform-identity-and-content) records an open owner decision on Dart runtime leaf SPKI pinning versus exclusive private-CA trust (ADR-076 D7).

## Costs

- Custom WebSocket gateway and socket connector plumbing (`socket_connector.dart`, `platform_socket_connector_native.dart`) rather than an all-in-one SDK.
- All HTTP/WebSocket traffic must route through `NetworkingFoundation` to prevent concurrent token renewal races (ADR-047; though server ADR-0023 later replaced rotating refresh tokens with a single session token, recorded in ADR-068 / ADR-083 / ADR-085).

## Reversal Trigger

If `dio` or `web_socket_channel` over `dart:io` cannot satisfy TLS pinning requirements, HTTP/2/3 transport changes, or socket lifecycle constraints on Android.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-08-20 (ADR-043):** Transport trust moved to `dart:io` `SecurityContext` trusting the provisioned private CA exclusively.
- **2026-08-21 (ADR-047):** Resolved dual composition roots into the single live `NetworkingFoundation` owned by `AuthenticationAssembly`.
- **2026-09-08 (ADR-068, ADR-069):** Recorded single-token renewal (server ADR-0023) and retirement of the in-band WebSocket `auth` frame (server ADR-0020).
- No supersession.
