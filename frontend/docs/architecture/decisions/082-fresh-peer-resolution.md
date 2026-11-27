# ADR-082: Live server verification on every send and conditional `/identity` reads

- **Status:** Accepted (2026-10-06)
- **Date:** 2026-10-06 (explicitly recorded in register and full section; code in `083dc5c5`, `109c6079`, `04537640`, docs in `05c6ab59`, `ebe18f74`)
- **Supersedes in part:** [ADR-065](065-peer-read-cost.md) (deletes D1–D5 peer resolution cache; D6–D7 owed gossip stands)
- **Amends:** [ADR-080](080-batched-peers.md) (adds `/identity` ETag to D3 and deletes cache pass-through in D4)
- **Related:** [ADR-060](060-delivery-latency.md), [ADR-065](065-peer-read-cost.md), [ADR-080](080-batched-peers.md), [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md), [devices API](../../../../backend/devices/API.md)

## Decision (Position)

Removed the 30-second process-local peer cache and made per-user `/identity` reads conditional so every resolution verifies current server state:

1. **D1 — Delete the 30-second peer cache ([client_authentication_service.dart](../../../lib/features/contacts/application/client_authentication_service.dart), [contact_composition_test.dart](../../../test/app/dependencies/contact_composition_test.dart)):**
   - Deleted historical `PeerIdentityRoundTripCache` (`frontend/lib/features/contacts/application/peer_resolution_cache.dart` and `frontend/test/features/contacts/application/peer_resolution_cache_test.dart` in `083dc5c5`), `PeerResolutionCachePort`, `NoPeerResolutionCache`, and the cache wrapper provider, wiring `ClientAuthenticationService` directly to `DioContactRepository`.
   - `PeerIdentityRemotePort` ([contact_ports.dart](../../../lib/features/contacts/application/ports/contact_ports.dart)) requires every call to hit the server with no memory cache in between, enforced at the composition root by [contact_composition_test.dart](../../../test/app/dependencies/contact_composition_test.dart).
   - Removes the up-to-30 s staleness window on prekey claims, inbound sender checks, session repair, and voice resolution as well as the cache-invalidation/flight-floor complexity from [ADR-080](080-batched-peers.md) D4.
2. **D2 — Conditional `If-None-Match` on `GET /api/v1/users/{user_id}/identity` ([dio_contact_repository.dart](../../../lib/features/contacts/infrastructure/dio_contact_repository.dart)):**
   - `fetchIdentity` sends the stored `identityEtag` as `If-None-Match` only beside the verified identity it belongs to (never for a refused record).
   - A `304` response reconstructs the stored identity and re-runs all verification checks (signature chain, own-identity comparison, confirmed master key) — saving body transfer, never verification. A `304` on an unconditional read is malformed and blocks the record as `identityUnavailable`; every identity body (on `/identity` or inside `POST /api/v1/peers`) must include `etag`.
3. **D3 — Unmodified `404 not_found` for absent identities:**
   - `peer_identity` checks row existence before ETag comparison, returning `404` regardless of `If-None-Match`; client keeps `404` out of accepted statuses, persisting `BackendFailure(notFound)` / `identityUnavailable` and clearing all stored ETags via `_persistBlocked`.
4. **D4 — Three route-isolated ETags ([drift_contact_repository.dart](../../../lib/features/contacts/infrastructure/drift_contact_repository.dart)):**
   - `identityEtag` (`identity_etag` in trust JSON) is sent only to `/identity` and updates whenever an identity is stored (`200`, `304`, full batched item, or preserved across `unchanged` batched item), while `etag` (`/devices`) and `peerStateEtag` (`peer_etag` for `POST /api/v1/peers`) remain isolated per [ADR-080](080-batched-peers.md) D3.
   - Refused records send none of the three tags; master-key-mismatch blocks store the new identity and its tag without sending it while blocked; decoded verified trust records still require either `etag` or `peerStateEtag`.

## Rationale

- Once [ADR-080](080-batched-peers.md) batched fan-out resolution into one `POST /api/v1/peers` against the `accounts` scope's 300 calls/minute (`THROTTLE_ACCOUNTS`), the original motivation for [ADR-065](065-peer-read-cost.md)'s cache disappeared while `/identity` gained server-side `ETag`/`304` support.
- Removing the cache closes the 30-second stale-identity/revoked-device exposure on prekey claims and single-peer paths, while conditional `/identity` reads keep repeated claim-path checks body-free (`304`).

## Constraints and Open Gates

- **Scope:** Local schema unchanged (`identity_etag` added inside serialized trust record JSON); changed no cryptographic construction, wire format, or `backend/` file; opened no production gate.
- **Verification:** Covered by [send_rechecks_peer_state_test.dart](../../../test/features/pairwise/send_rechecks_peer_state_test.dart), [contact_composition_test.dart](../../../test/app/dependencies/contact_composition_test.dart), [client_authentication_service_test.dart](../../../test/features/contacts/application/client_authentication_service_test.dart), [dio_contact_repository_test.dart](../../../test/features/contacts/infrastructure/dio_contact_repository_test.dart), [contact_api_dtos_test.dart](../../../test/features/contacts/infrastructure/contact_api_dtos_test.dart), and [drift_contact_repository_test.dart](../../../test/features/contacts/infrastructure/drift_contact_repository_test.dart) using fake/mock adapters against [backend/openapi.json](../../../../backend/openapi.json); no live-server run at ADR-082.
- **Own-account `/identity` left unconditional:** `IdentityResponseDto` in [device_enrollment_dtos.dart](../../../lib/features/devices/infrastructure/device_enrollment_dtos.dart) (used only during enrollment and identity rotation) ignores the `etag` field.
- **[ADR-060](060-delivery-latency.md) timings unchanged:** Per-request 107–137 ms round-trip latency remains unaltered.

## Costs

- Measured request counts on composed send paths ([send_rechecks_peer_state_test.dart](../../../test/features/pairwise/send_rechecks_peer_state_test.dart)):
  - Two sends to one peer: stays 2 requests (second batched read answered `unchanged`).
  - First contact + owed gossip: increases from 6 to 8 requests (6 on `accounts`, 2 on `claim`), with 5 answered without bodies (one `unchanged`, two `/identity` `304`s, two `/devices` `304`s).

## Reversal Trigger

Reopen if single-peer claim-path round trips become a bottleneck under high first-contact churn or if own-account `/identity` reads need conditional caching.

## History, Amendments, and Supersession

- **2026-10-06 (`083dc5c5`, `109c6079`, `04537640`, `05c6ab59`, `ebe18f74`):** Implemented and recorded ADR-082 (`Accepted`), superseding [ADR-065](065-peer-read-cost.md) D1–D5 (deleting `peer_resolution_cache.dart` and `peer_resolution_cache_test.dart`) and amending [ADR-080](080-batched-peers.md) D3–D4.
