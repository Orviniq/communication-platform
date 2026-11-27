# ADR-069: Retired WebSocket gateway frames, close codes, and client wire limits

- **Status:** Accepted; `maximumSignalCharacters` later replaced by published `signal_buckets` ([ADR-071](071-published-limits.md), ADR-077)
- **Date:** 2026-09-08 (explicitly recorded in register; code in `43fecd70`, `a6ec90a6`, docs in `78faa70`)
- **Amends:** [ADR-060](060-delivery-latency.md) (corrects D10 wire facts and closes its `subscribe_presence` open item)
- **Related:** [ADR-004](004-rest-and-websocket.md), [ADR-047](047-networking-composition.md), [ADR-060](060-delivery-latency.md), [ADR-071](071-published-limits.md), ADR-077, ADR-098, server [ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md), server [ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md), server [ADR-0022](../../../../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md)

## Decision (Position)

*(Extracted from the ADR-069 register row and its introducing commits `43fecd70`, `a6ec90a6`, and `78faa70`; no separate full section existed in `decisions.md`.)*

Client-side record aligning [DioWebSocketGateway](../../../lib/features/networking/infrastructure/realtime/dio_websocket_gateway.dart), [realtime_event.dart](../../../lib/features/networking/domain/realtime_event.dart), and client documentation with server [ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md) and server [ADR-0022](../../../../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md):

1. **Retired WebSocket frames:**
   - Gateway handles only `ack` and `signal` outbound and emits only `envelope` and `signal` inbound.
   - Deleted the in-band `auth` frame (`SocketAuthenticationMode`), `subscribe_presence`, the inbound `presence` frame (`RealtimePresence` / `PresenceState`), and the four room frames (`RealtimeRoomSignal`, `RealtimeRoomPresence`, `RoomPresenceState`, and outbound room control/signal frames).
   - Verified by [websocket_gateway_test.dart](../../../test/features/networking/infrastructure/websocket_gateway_test.dart), which asserts each retired frame is refused outbound and ignored inbound so the surface cannot reappear silently.
2. **Retired close codes and connection-budget cleanup:**
   - Authentication moved to the HTTP upgrade handshake (`403` refusal before WebSocket accept, [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) §O), retiring close code `4001`, the one-shot token-recovery budget `4001` spent, and close code `4403` (tied to the browser Origin allowlist).
   - `markStableConnection` remains on the synchronization gateway port as a documented no-op.
   - Left WebSocket close `1012` (server restart) unnamed in the reconnecting arm intentionally so restarts follow plain backoff without triggering a stop action or consuming a recovery budget.
3. **Deleted dead presence projection and retired wire limits:**
   - Deleted `presenceProjectionProvider` and corrected [ADR-060](060-delivery-latency.md) D10 and [sync-engine.md](../../sync-engine.md): `subscribe_presence` never existed on the current server, and the gateway announces no presence on connect or disconnect.
   - Deleted `maximumPresenceTargets` and `maximumRoomSubscriptions` from `ApiContractLimits` ([api_request.dart](../../../lib/features/networking/infrastructure/api/api_request.dart)). Retained `maximumSignalCharacters` temporarily until the voice phase replaced character ceilings with published `signal_buckets` (1024, 4096, 16384 bytes; see [ADR-071](071-published-limits.md), ADR-077).

## Rationale

- Keeping outbound validation and inbound decoders for frames the server no longer accepts or emits made documentation and providers assert false wire capabilities (`auth` frames, server-managed presence, SFU room frames).
- Enforcing rejection of retired frames in [websocket_gateway_test.dart](../../../test/features/networking/infrastructure/websocket_gateway_test.dart) prevents drift back toward retired gateway protocols.

## Constraints and Open Gates

- **Scope:** Local schema stayed at 18; no `lib/` caller used `RealtimeGateway.send`; changed no endpoint, cryptographic construction, or `backend/` file; opened no production gate.

## Costs

- `markStableConnection` remains as an inert port method on the synchronization boundary to avoid breaking synchronization-layer ownership.

## Reversal Trigger

Reopen only if the server gateway reintroduces presence or room-frame protocols (subsequently typing and presence were built client-side over opaque `CPPSV001` `signal` frames under ADR-098, leaving the gateway presence-free).

## History, Amendments, and Supersession

- **2026-09-08 (`43fecd70`, `a6ec90a6`, `78faa70`):** Recorded and implemented ADR-069 (`Accepted`), deleting retired frames/close codes/limits/`presenceProjectionProvider` and annotating [ADR-060](060-delivery-latency.md) D10.
- **2026-09-09 – 2026-09-20 ([ADR-071](071-published-limits.md), ADR-077):** Replaced `maximumSignalCharacters` with published `signal_buckets`.
