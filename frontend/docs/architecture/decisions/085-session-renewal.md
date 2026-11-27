# ADR-085: Half-lifetime non-blocking session token renewal

- **Status:** Accepted (2026-10-07); same-day addendum fixed duplicate termination on refused renewal
- **Date:** 2026-10-07 (explicitly recorded in register, full section, and addendum; code in `65648f50`, `5d92987f`, `c428a598`, PR #62 `94d0be59`; docs in `0b98b51d`, `9e6e7a77`)
- **Amends:** [ADR-068](068-session-token.md) and [ADR-083](083-resumable-download.md) (moves proactive renewal trigger from the final 2.5 minutes to half-lifetime and makes early-window renewals non-blocking)
- **Closes:** Renewal-window defect recorded in passing by [ADR-083](083-resumable-download.md)
- **Related:** [ADR-068](068-session-token.md), [ADR-083](083-resumable-download.md), [accounts API](../../../../backend/accounts/API.md), [core API](../../../../backend/core/API.md), [API_CHANGES.md](../../../../API_CHANGES.md), server [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md)

## Decision (Position)

Moved proactive `POST /api/v1/auth/renew` scheduling from the final `proactiveRenewalWindow` + `clockSkewAllowance` (2.5 minutes of a 30-day token) to half of each token's issued lifetime ([token_coordinator.dart](../../../lib/features/networking/infrastructure/auth/token_coordinator.dart)):

1. **D1 — Renewal becomes due at half the token's lifetime:**
   - A full-scope session token is due once `expiresAt - lifetime / 2` has passed (day 15 of the default 30-day `SESSION_TOKEN_DAYS` lifetime, scaling proportionally with deployment configuration).
   - Rejected a fixed span (e.g., 15 days, which loops when `SESSION_TOKEN_DAYS <= 15`), relying solely on published `session_token_days` (which can drift across server config changes), or parsing JWT `iat`/`exp` claims ([ADR-068](068-session-token.md), server [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md)).
2. **D2 — Non-blocking background renewal in the early window:**
   - Between half-lifetime and the final `proactiveRenewalWindow` + `clockSkewAllowance`, the first caller seeing the token due triggers one renewal and **all callers immediately receive the still-valid current token** without waiting (preventing cold-start restore stalls on lossy networks and non-fatal renewal errors from failing valid requests).
   - Inside the final `proactiveRenewalWindow` + `clockSkewAllowance` (or on `forceRefresh: true` after a `401`), callers await and receive the renewal outcome as before.
   - Rejected background timers (which cannot survive a frozen/dead process).
3. **D3 — Failure and retry handling during early renewal:**
   - Session-ending refusals (`invalid_token`, `token_revoked`) terminate the session just as in the final window.
   - Any other failure (offline, timeout, `429`, `5xx`, malformed body, storage error) keeps the current token usable and pauses further early renewals in memory for `earlyRenewalRetryInterval` (1 minute, outlasting `accounts` per-minute rate limits; resets on new process).
4. **D4 — Persist `expires_in` as `AccessToken.lifetime` ([session_tokens.dart](../../../lib/features/networking/domain/session_tokens.dart), [secure_session_token_adapter.dart](../../../lib/features/authentication/infrastructure/secure_session_token_adapter.dart)):**
   - Captured `expires_in` from `SessionTokenResponseDto`, `LoginAccountResponseDto` (`AccountSessionGrant.accessLifetime`), and `RegisterDeviceResponseDto` (`DeviceRegistrationResponse.accessLifetime` in [device_enrollment_dtos.dart](../../../lib/features/devices/infrastructure/device_enrollment_dtos.dart)).
   - Stored as optional whole positive seconds under `"lifetime"` inside the existing `_formatVersion = 1` encrypted `tokenMetadataCiphertext` JSON (non-positive/non-integer `"lifetime"` invalidates the row like other malformed fields; older rows without `"lifetime"` restore cleanly and assume `ServerConfig.fallback.sessionTokenDays` = 30 for that single token before the next renewal records its real lifetime).
5. **D5 — Preserved coordinator invariants:**
   - Register-scope tokens are never renewed (`403 scope_forbidden`).
   - Retained [ADR-083](083-resumable-download.md) D4's `_renewalInFlight` single flight (preventing duplicate concurrent renewals in the early window and coalescing waits in the final window), [ADR-068](068-session-token.md) D3's `_renewalMarker` `Zone`, and `_sessionGeneration`.
6. **Addendum (2026-10-07, `c428a598` / `9e6e7a77`) — Single session termination per refused renewal:**
   - Because `DioRestClient` already calls `handleRevocation` on `401 token_revoked` during the renewal HTTP call itself, `_performRenewal` previously terminated the session a second time when returning the failure (`[revoked, revoked]`). `_performRenewal` now checks that `_sessionGeneration` still matches the generation captured when the renewal started before terminating the session.

## Rationale

- `POST /api/v1/auth/renew` runs behind the standard token verifier (`issue_session` / `decode` in `backend/api/auth.py`), which rejects expired tokens with `401 invalid_token` (`test_an_expired_token_is_refused`). Waiting until the final 2.5 minutes signed out any user whose app made no request during that narrow window (with 15-minute deferred catch-up only hitting it ~1/6 of the time).
- Half-lifetime triggers renewal on any request across the second half of the token's life (15 days by default) without blocking foreground cold starts.

## Constraints and Open Gates

- **Scope:** Added one optional JSON key `"lifetime"` inside encrypted `account_sessions.token_metadata_ciphertext`; no database schema/table/column, wire format, protocol, cryptographic construction, or `backend/` file changed; opened no production gate.
- **Verification:** Covered by 10 new ADR-085 tests + 11 preserved tests in [token_coordinator_test.dart](../../../test/features/networking/infrastructure/token_coordinator_test.dart), [secure_session_token_adapter_test.dart](../../../test/features/authentication/infrastructure/secure_session_token_adapter_test.dart), [drift_enrollment_journal_store_test.dart](../../../test/features/devices/infrastructure/drift_enrollment_journal_store_test.dart), [authentication_api_dtos_test.dart](../../../test/features/authentication/infrastructure/authentication_api_dtos_test.dart), and [dio_token_endpoints_test.dart](../../../test/features/networking/infrastructure/dio_token_endpoints_test.dart); no live-server or physical-device run.
- **Left open:**
  - **No failing-renewal UI warning:** Persistent early-renewal failures produce no user warning before eventual expiry.
  - **Duplicate termination outside renewal (`handleRevocation`):** Two concurrent non-renewal requests refused with `token_revoked` (or a `4003` close alongside a `token_revoked`, or an in-flight request returning `token_revoked` after logout) can still emit `revoked` twice (`[revoked, revoked]` / `[logout, revoked]`) because `DioRestClient.handleRevocation` itself does not guard on session generation.

## Costs

- Doubles routine renewal rate from once per `SESSION_TOKEN_DAYS` to once per half-lifetime (~twice per 30 days per device on the `accounts` scope).
- A device making zero server requests across the entire second half of its token's lifetime (15 days by default) still expires and must sign in again.

## Reversal Trigger

Reopen if the server adds an idle-renewal grace window, changes `SESSION_TOKEN_DAYS` semantics, or if `DioRestClient.handleRevocation` is made idempotent across concurrent in-flight refusals.

## History, Amendments, and Supersession

- **2026-10-07 (`65648f50`, `5d92987f`, PR #62 `94d0be59`, `0b98b51d`):** Implemented and recorded ADR-085 (`Accepted`), storing `expires_in` as `AccessToken.lifetime` and triggering non-blocking renewal at half-lifetime.
- **2026-10-07 (`c428a598`, `9e6e7a77`):** Added same-day addendum gating `_performRenewal` session termination on unchanged `_sessionGeneration` so a renewal's own `401 token_revoked` ends the session once.
