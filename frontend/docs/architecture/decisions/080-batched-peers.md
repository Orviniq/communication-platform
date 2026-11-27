# ADR-080: Batched peer-state verification via `POST /api/v1/peers`

- **Status:** Accepted (2026-10-06); D3 (`identityEtag`) and D4 (cache removal) amended/superseded the same day by [ADR-082](082-fresh-peer-resolution.md)
- **Date:** 2026-10-06 (explicitly recorded in register and full section; implemented in `16b84fa5`–`bf0432ba`, documented in `011b4705`)
- **Related:** [ADR-060](060-delivery-latency.md), [ADR-065](065-peer-read-cost.md), [ADR-075](075-pairwise-groups.md), [ADR-081](081-unsigned-device-state.md), [ADR-082](082-fresh-peer-resolution.md), [ADR-084](084-pending-device-log.md)

## Decision (Position)

Replaced per-recipient `GET` loops on pairwise fan-out with a single batched `POST /api/v1/peers` call (up to 64 users per request per [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) §L and [devices API](../../../../backend/devices/API.md)) while keeping verification unified:

1. **D1 — One batched read feeding the shared `_refresh` verifier ([client_authentication_service.dart](../../../lib/features/contacts/application/client_authentication_service.dart)):**
   - `ClientAuthenticationService.resolveLiveDevicesForUsers` fetches peers via `PeerIdentityRemotePort.fetchPeerStates` (`POST /api/v1/peers`, sorted recipients plus own account) and feeds each item into `_refresh`, the exact same verification pipeline and DTO field decoders used by per-user reads (identity signature, own-identity check, confirmed master key, unsigned-device rule, device transitions, same-head pending window, device-log hash chain, `requireCurrentLiveSet`, attestations, and trust persistence).
   - Device-log records are absent from `/api/v1/peers`; when a peer's `log_head_seq` moved, new log pages are still fetched and verified before persisting.
   - Global fork gate runs before verification; fan-out fails with the first failing user in sorted order, while deliberately still verifying and persisting subsequent users returned in the same batch.
2. **D2 — Strict `PeerStatesResponseDto` matching and absent-user handling ([contact_api_dtos.dart](../../../lib/features/contacts/infrastructure/contact_api_dtos.dart)):**
   - `unchanged` is decided strictly by presence (`unchanged: true`, carrying only `user_id`, `etag`, `unchanged`, and matching the request's `etag`; any extra body field or mismatched tag is malformed). An `unchanged` item stands for stored identity, device list, and head, and still runs full re-verification.
   - Items match requested users by case-insensitive `user_id` (never by index or count); unexpected or duplicate user IDs fail as malformed.
   - Users omitted by the server (missing, unactivated, or deactivated) and users with `identity: null` map to `BackendFailure(notFound)` / `identityUnavailable` (settled failure retiring the send), matching per-user `404 not_found`.
3. **D3 — Three ETags isolated by route *(amended 2026-10-06 by [ADR-082](082-fresh-peer-resolution.md))*:**
   - Kept the device-list ETag (`etag`, sent via `If-None-Match` to `/devices`) separate from the batched `peerStateEtag` (stored in trust JSON under `peer_etag` and sent in `POST /api/v1/peers`).
   - A route's tag is persisted on response, while another route's tag survives only when identity, device list, and head stayed unchanged and the record was not blocked; `_persistBlocked` clears tags and refused records send none. Verified trust records accept either route's tag on decode.
   - *Amendment ([ADR-082](082-fresh-peer-resolution.md)):* Subsequently started sending `identityEtag` via `If-None-Match` on `/identity` and storing it alongside `peerStateEtag` / `etag` (requiring all three tags to clear on block).
4. **D4 — Cache pass-through and stale-flight invalidation *(superseded 2026-10-06 by [ADR-082](082-fresh-peer-resolution.md))*:**
   - Originally bypassed historical `PeerIdentityRoundTripCache` for `fetchPeerStates`, invalidated moved peers, and blocked older in-flight per-user reads from entering the cache.
   - *Superseded ([ADR-082](082-fresh-peer-resolution.md)):* Deleted `PeerIdentityRoundTripCache` and `peer_resolution_cache_test.dart` altogether (`083dc5c5`).
5. **D5 — Single-peer paths retained on per-user routes:**
   - `refreshPeer`, `confirmOutOfBand`, `refreshPeerForDevices` (prekey claim), and `resolveLiveDevices` (inbound sender, session repair, and `PairwiseVolatileSealer` voice signals, which need per-device failure granularity) remain on per-user routes.

## Rationale

- Under [ADR-060](060-delivery-latency.md) and [ADR-065](065-peer-read-cost.md) measured round trips of 107–137 ms, a 50-member group send cost up to 150 HTTP calls before sealing its first message, and [ADR-065](065-peer-read-cost.md)'s cache never helped the first ask.
- Batching up to 64 peers per `POST /api/v1/peers` reduced a 50-member group's initial peer/identity read from up to 150 round trips to 1 batched call (plus log pages for moved heads and prekey claims for new sessions), cutting composed single-send requests from 4 → 1 and send+gossip from 4 → 2.

## Constraints and Open Gates

- **Scope:** Local schema unchanged (optional `peer_etag` key inside serialized trust JSON); changed no cryptographic construction, wire format, or `backend/` file; opened no production gate.
- **No live-server run:** Verified via mock-adapter / fake-server tests against [backend/openapi.json](../../../../backend/openapi.json); request counts rather than wall-clock timings.
- **Unsigned peer parser gap found and deferred:** Noted that `_devices` and `PublicDeviceDto` expected `bundle_version: null` instead of `bundle_version: 0` alongside `cross_sig: null` (`backend/devices/tests/test_cross_signing.py` and `test_peer_state.py`), causing a peer with a mid-enrollment unsigned device to fail the whole batched call as `malformedServerResponse`. Fixed for peer routes the same day by [ADR-081](081-unsigned-device-state.md) and for own-account checks the next day by [ADR-084](084-pending-device-log.md).

## Costs

- When a batched response includes a malformed item (prior to [ADR-081](081-unsigned-device-state.md)) or when a single recipient fails verification, the fan-out stops for that batch, though valid peers verified earlier/later in the same response are still persisted (unlike the old loop).
- `PairwiseVolatileSealer` and single-peer paths still perform per-user reads.

## Reversal Trigger

Reopen if `PairwiseVolatileSealer` is moved to batched resolution or if backend `POST /api/v1/peers` semantics change.

## History, Amendments, and Supersession

- **2026-10-06 (`16b84fa5`–`bf0432ba`, `011b4705`):** Implemented and recorded ADR-080 (`Accepted`), introducing `POST /api/v1/peers` fan-out verification and `peerStateEtag`.
- **2026-10-06 (`ab287902` / [ADR-081](081-unsigned-device-state.md)):** Fixed peer-route handling of `cross_sig: null, bundle_version: 0` so one unsigned peer device no longer invalidates the whole batch.
- **2026-10-06 (`083dc5c5`, `109c6079`, `05c6ab59` / [ADR-082](082-fresh-peer-resolution.md)):** Deleted `PeerIdentityRoundTripCache` (superseding D4) and added conditional `/identity` `If-None-Match` (`identityEtag`, amending D3).
