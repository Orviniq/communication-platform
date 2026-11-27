# ADR-068: Single device-bound session token and non-rotating renewal

- **Status:** Accepted; renewal trigger later moved to half-lifetime by ADR-085 (2026-10-07); single-flight role clarified by ADR-083 (2026-10-07)
- **Date:** 2026-09-08 (explicitly recorded in register and full section; code in PR #44 / `cab84527`, docs committed in `29a040f1`)
- **Related:** [ADR-004](004-rest-and-websocket.md), [ADR-050](050-delivery-ownership.md), [ADR-069](069-gateway-frames.md), ADR-083, ADR-085, server [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md)

## Decision (Position)

Client-side record aligning authentication, device registration, and token renewal with server [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md) (which superseded server ADR-0006's rotating access/refresh pair):

1. **D1 — Three independent contract breaks fixed against [backend/openapi.json](../../../../backend/openapi.json):**
   - **Single session token:** Login and registration decode `SessionOut` (`token`, `expires_in`, `user_id`, plus `device_id` on full scope) into `FullScopeOut` / `RegisterScopeOut` and `SessionTokens` (holding one `AccessToken` and deriving `SessionScope` from the response discriminator rather than JWT claims).
   - **Device registration payload:** Removed the `keypackages` field from `RegisterDeviceIn` (which sets `additionalProperties: false` and returned `400`).
   - **Authenticated bodiless renewal:** Replaced retired anonymous `POST /api/v1/auth/refresh` (which returned `404`) with `POST /api/v1/auth/renew` using `AuthenticationRequirement.full` (`Authorization: Bearer <token>`, empty body, `RenewTokenExchange.renew()` taking no argument; register-scope tokens refused `403 scope_forbidden`).
2. **D2 — Non-rotating token semantics:**
   - Because `POST /api/v1/auth/renew` writes nothing and retires no token (multiple live tokens per device are valid; immediate revocation works via the device row's `token_generation` counter), the cross-owner refresh-token retirement race cannot occur.
   - Single-flight renewal in `TokenCoordinator` ([token_coordinator.dart](../../../lib/features/networking/infrastructure/auth/token_coordinator.dart)) is retained as an optimization rather than a safety invariant; a refused token (`401`) means a refused session rather than lost rotation; renewal is marked `ReplaySafety.contractIdempotent`.
3. **D3 — Zone-scoped self-authorization during renewal:**
   - Because `POST /api/v1/auth/renew` asks `TokenCoordinator` for its `Authorization` header while the renewal future is in flight, returning the in-flight future would deadlock. The renewal carries its starting token in a Dart `Zone` value so only the renewal call itself uses that token while concurrent callers still join the in-flight renewal.
4. **D4 — Pair-era storage transition and identity merge:**
   - Protected session storage now stores the live session token rather than a refresh token beside an expired placeholder, making cold-start restoration a plain read without forced rotation.
   - Any pair-era stored row lacking `token` is deleted on restore (costing already-signed-in users one sign-in without touching SQLCipher storage or message history).
   - Because `/api/v1/auth/renew` returns only `token` and `expires_in` without identity fields, the store merges the renewed credential into the existing record rather than replacing it (which previously erased `user_id`, `device_id`, and `username` and signed users out on the next cold start).

## Rationale

- Synthesizing a client-side token pair or retaining `keypackages` on `RegisterDeviceIn` would violate server contract authority or trigger `400` rejections.
- Merging durable identity fields on renewal and scoping the renewal's own bearer token via a `Zone` avoided deadlocks and silent cold-start sign-outs while keeping concurrent callers coalesced.

## Constraints and Open Gates

- **Scope:** Local schema stayed at 18; no cryptographic construction, KeyPackage gate, or `backend/` file changed; opens no production gate.
- **Verification:** Covered by `dio_token_endpoints_test.dart`, `token_coordinator_test.dart`, and auth/device fixture updates (`c5748aea`–`846df2a5`).

## Costs

- Users upgrading from a pair-era build must sign in once more (pair-era row cannot be migrated because `/auth/refresh` is `404`).

## Reversal Trigger

Reopen if the server reintroduces a second credential or token-retiring renewal (tracked against server [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md)).

## History, Amendments, and Supersession

- **2026-09-08 (`cab84527` / `29a040f1`):** Recorded and implemented ADR-068 (`Accepted`), aligning login, registration, renewal, and durable token restoration with server [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md).
- **2026-10-07 (ADR-083 & ADR-085):** ADR-083 (`a3b1bbf8`, `5816282f`) removed unused `SessionTokenStore.readDurable` and documented single-flight renewal strictly as contention control; ADR-085 (`0b98b51d`) moved proactive renewal from the final 2.5 minutes to half of `expires_in`.
