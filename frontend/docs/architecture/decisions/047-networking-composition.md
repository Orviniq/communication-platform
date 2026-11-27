# ADR-047: Application-root delivery composition on one NetworkingFoundation

- **Status:** Accepted (token-rotation hazard of a second coordinator retired by [server ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md) / [ADR-068](068-session-token.md) & [ADR-083](083-resumable-download.md); `bootstrap()` ownership gate added by [ADR-050](050-delivery-ownership.md); `UnscheduledBestEffortPolling` replaced on Android by `PlatformDeferredDeliveryScheduler` in [ADR-049](049-background-catch-up.md))
- **Date:** 2026-08-21 (explicitly recorded in register; committed in `1b181c75`)
- **Implements:** [ADR-046](046-layered-delivery.md) Layer 0 (follow-up step 1)
- **Related:** [ADR-003](003-riverpod-composition.md), [ADR-004](004-rest-and-websocket.md), [ADR-043](043-private-ca-transport.md), [ADR-045](045-maturity-disclosure.md), [ADR-046](046-layered-delivery.md), [ADR-048](048-generic-notifications.md)

## Decision (Position)

*(Extracted from the ADR-047 register row, its introducing commit `1b181c75`, and verified current implementation in [SYNC.md](../SYNC.md#composition-and-ownership) and [message_delivery.dart](../../../lib/app/dependencies/message_delivery.dart); no separate full section existed in `decisions.md`.)*

Composes [ADR-046](046-layered-delivery.md)'s Layer 0 delivery path at the application root on one shared networking foundation:

1. **Single `NetworkingFoundation` composition root:** [AuthenticationAssembly](../../../lib/app/dependencies/authentication_assembly.dart) owns a single [NetworkingFoundation](../../../lib/app/dependencies/networking_foundation.dart) — one `DioRestClient`, one `TokenCoordinator`, and one provisioned `TransportSecurity` / `SecurityContext` ([ADR-043](043-private-ca-transport.md)). The WebSocket gateway is constructed from it via `NetworkingFoundation.realtimeGateway`, so REST and WebSocket share the same access token, renewal coordinator, revocation handling, and trust root. (Corrected [ADR-046](046-layered-delivery.md)'s inventory: `NetworkingFoundation` previously had no tests and no callers at all, and was made live rather than deleted.)
2. **Application-root ownership via `listenManual`:** `MessageDeliveryController` (`lib/app/dependencies/message_delivery.dart`) is a Riverpod notifier held at the application root via `listenManual` (never in a screen or `ref.watch` inside `build`). It serializes session transitions onto one queue, re-checking the wanted scope after every `await`, runs `MessageDeliverySession` only for `fullScope` / `offlineFullScope`, and stops when logout *begins* (rather than on termination emission).
3. **Sending is a durable write observed by outbox depth growth:** Feature composers write exact per-recipient ciphertext into `outbox_operations` and return; `SyncLifecycleSupervisor` observes the durable `SyncProjection` and triggers a cycle only when `outbox_depth` *increases* (not merely when non-zero).
4. **Unified `DeliveryPlatformPorts` and two platform-edge fixes:**
   - Connectivity, application lifecycle, wall-clock delay, and the deferred scheduler resolve and release together as `DeliveryPlatformPorts` (enabling deterministic host testing without a device).
   - **Null initial `WidgetsBinding.lifecycleState` treated as foreground:** Reading unreported initial lifecycle state as background caused a launch-started session to stand itself down and never connect.
   - **Connectivity re-checked on resume:** Android 8.0+ does not deliver connectivity changes to backgrounded apps, so cached `unavailable` status is refreshed on foreground resume to avoid blocking reconnect.
5. **Scope boundary at ADR-047:** Initially composed `UnscheduledBestEffortPolling` (scheduling nothing; Layers 1–3 unbuilt at that commit, making [ADR-045](045-maturity-disclosure.md)'s `foregroundDeliveryOnly` disclosure true without moving revision 1). Added no dependency, changed no cryptographic behavior, opened no production gate, and preserved the Beta/Production boundary.

## Rationale

- **Why one `TokenCoordinator`:** Under the rotating-refresh-token backend contract in effect on 2026-08-21, a second coordinator would rotate the same refresh token and cause the loser to present a retired token, revoking the session for both. (Although [server ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md) / ADR-068 / ADR-083 later removed rotating tokens, keeping one `NetworkingFoundation` continues to unify trust anchors, single-flight renewal contention control, and logout/revocation teardown.)
- **Why `listenManual` at the root:** Verified in pinned `flutter_riverpod` 3.3.2 source (`ConsumerStatefulElement._applyTickerMode`): subscriptions created in `build` are paused when their widget leaves view, which would silently stop a screen-owned controller from managing delivery sessions when navigated over.
- **Why stop when logout begins:** `TokenCoordinator.logout` wipes protected storage and closes the database *before* emitting session termination, so stopping on completion would race storage teardown.
- **Why outbox-depth increase rather than non-zero or an in-memory port:** Every engine run rewrites connection phase and re-emits the projection; reacting to `outbox_depth > 0` spins against a row waiting out backoff (verified by loop-safety test). An in-memory trigger port would require cross-feature wiring and would not survive restart.

## Constraints and Open Gates

- **Subsequent evolutions verified in current code:**
  - **ADR-049 (2026-08-21):** Replaced `UnscheduledBestEffortPolling` on Android with `PlatformDeferredDeliveryScheduler` behind `AndroidBestEffortPollingPort` ([message_delivery.dart](../../../lib/app/dependencies/message_delivery.dart)); non-Android targets compose a null scheduler.
  - **ADR-050 (2026-08-22):** Added `DeliveryOwnershipGate().awaitExclusiveOwnership()` to `bootstrap()` before `ApplicationRuntime.create()` so foreground startup arbitrates single-owner delivery before storage/session access.
  - **ADR-068 / ADR-069 (2026-09-08):** Retired rotating refresh tokens and WebSocket close codes `4001` and `4403` (gateway auth moved to handshake upgrade; `4003` / `4008` remain; see [SYNC.md](../SYNC.md#token-lifecycle)).
  - **2026-10-05 correction ([SYNC.md](../SYNC.md#composition-and-ownership)):** `outbox_depth` counts owed send preparations (including signed group/room control changes) as well as sealed target rows.

## Costs

- Requires explicit `DeliveryPlatformPorts` lifecycle management and host test overrides in composition tests.
- Leaves cross-isolate arbitration out of `MessageDeliverySession` itself (initially deferred because ADR-047 composed one isolate, then implemented via ADR-049/ADR-050 when background catch-up arrived).

## Reversal Trigger

Reopen if the application moves away from single-root Riverpod composition or splits REST and WebSocket authentication/trust boundaries.

## History, Amendments, and Supersession

- **2026-08-21 (`1b181c75`):** Recorded ADR-047 (`Accepted`), composing [ADR-046](046-layered-delivery.md) Layer 0 and updating [sync-engine.md](https://github.com/Orviniq/communication-platform/blob/1b181c75dbf65cd0485812623dbac742030bd73b/frontend/docs/sync-engine.md), [`platform-android.md`](https://github.com/Orviniq/communication-platform/blob/1b181c75dbf65cd0485812623dbac742030bd73b/frontend/docs/platform-android.md), and `implementation-checklist.md`.
- **2026-08-21 – 2026-08-22 (ADR-049, ADR-050):** Composed `PlatformDeferredDeliveryScheduler` on Android and moved single-owner gating into `bootstrap()`.
- **2026-09-08 & 2026-10-07 (ADR-068, ADR-069, ADR-083):** Retired close code `4001` and rotating-refresh-token failure premise while keeping one `NetworkingFoundation` and `TokenCoordinator`.
