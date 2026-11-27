# ADR-072: Wire-aligned backend error vocabulary and shared-status disambiguation

- **Status:** Accepted
- **Date:** 2026-09-09 (explicitly recorded in register; implemented in `e1225353`, `9871b4bd`, `68a445ec`, documented in `fe19501c`)
- **Related:** [ADR-004](004-rest-and-websocket.md), [ADR-060](060-delivery-latency.md), [ADR-070](070-published-peer-state.md), [ADR-071](071-published-limits.md), [BACKEND.md](../../contracts/BACKEND.md)

## Decision (Position)

*(Extracted from the ADR-072 register row and commits `e1225353`, `9871b4bd`, `68a445ec`, and `fe19501c`; no separate full section existed in `decisions.md`.)*

Aligned `BackendFailureCode` ([failure.dart](../../../lib/core/result/failure.dart)), `mapBackendFailure` ([backend_error_mapper.dart](../../../lib/features/networking/infrastructure/api/backend_error_mapper.dart)), attachment error handling, and [BACKEND.md](../../contracts/BACKEND.md) strictly with the active error codes in [backend/openapi.json](../../../../backend/openapi.json) and [backend/core/API.md](../../../../backend/core/API.md):

1. **1:1 wire error vocabulary:**
   - **Deleted four dead codes:** `bad_request` (renamed `invalid_request`), `token_not_valid` (renamed `invalid_token`), `device_scope_required` (returned by no route), and `keypackage_limit` (removed with MLS).
   - **Added seven active codes:** `throttled`, `unavailable`, `payload_too_large`, `devicelog_limit`, `storage_full`, `method_not_allowed`, and `server_error`, naming every `BackendFailureCode` enum member as the lowerCamelCase of its wire `code`.
   - Enforced bidirectionally in [backend_error_mapper_test.dart](../../../test/features/networking/infrastructure/backend_error_mapper_test.dart): any undocumented code or unreachable enum value fails the test.
2. **Code-first branching for shared HTTP status pairs:**
   - `429 throttled` vs. `503 unavailable`: `Retry-After` is attached only to `BackendFailureCode.throttled` and dropped everywhere else so an outage (`unavailable`) never quotes a fake retry delay.
   - `413 quota_exceeded` vs. `413 payload_too_large` vs. `503 storage_full`: attachment upload (`attachment_transport.dart`, `9871b4bd`) now routes through `mapBackendFailure` rather than treating all `413` responses as `quota_exceeded` (an oversized file cannot succeed by waiting for 00:00 UTC, and a full server disk is not the user's daily quota). Status-only fallback in `mapBackendFailure` deliberately omits `413` and `503` (returning `unknown` when no known `code` is present) so two distinct meanings are never guessed from status alone.
   - Kept `503 voice_unconfigured` mapped to `FailureCategory.unsupportedProtocol` (never replayed as transient).
3. **Durable sync-queue classification preserved for 5xx (`68a445ec`):**
   - Explicitly listed `unavailable`, `storage_full`, and `server_error` as transient in `DurableSyncEngine` (matching their prior behavior when they arrived as `unknown`), so a server outage or disk-full condition retries instead of burning inspection/outbox budget.
   - Added `payload_too_large` and `method_not_allowed` to the permanent/settled set alongside `invalid_request` / `bad_bucket`.
4. **Client binding API rules ([BACKEND.md](../../contracts/BACKEND.md#the-error-vocabulary)):**
   - Branch on `code`, never display `detail` prose, and parse `invalid_request` validation `detail` keys as flat dotted paths (e.g., `otpks.0.pub`).

## Rationale

- Keeping unreturned enum values creates false coverage (`bad_request` branches silently bypassed while `invalid_request` hit catch-all handling), and switching on HTTP status alone conflates user-facing recovery actions on `413` and `503`.

## Constraints and Open Gates

- **Scope:** Added no dependency, opened no production gate, changed no wire format, and touched no `backend/` file.
- **Not done at ADR-072:** Added no new localized UI strings for the seven newly named codes until screens surface them explicitly.
- **Verification scope:** Verified by unit tests and mock-adapter tests against `backend/openapi.json` and `backend/core/API.md`; no live-server run was executed for this change.

## Costs

- `413` and `503` responses lacking a recognized `code` (e.g., reverse-proxy error pages) fall to `BackendFailureCode.unknown` rather than guessing one branch of the pair.

## Reversal Trigger

Reopen whenever backend routes add, rename, or retire error `code` values in `backend/core/API.md` / `openapi.json`, or when presentation adds distinct user-facing copy for the new codes.

## History, Amendments, and Supersession

- **2026-09-09 (`e1225353`, `9871b4bd`, `68a445ec`, `fe19501c`):** Recorded and implemented ADR-072 (`Accepted`), aligning `BackendFailureCode`, `mapBackendFailure`, `attachment_transport.dart`, `DurableSyncEngine`, and [`backend-api.md`](https://github.com/Orviniq/communication-platform/blob/fe19501cf965e612c471ef24ea0c113a3f8536aa/frontend/docs/backend-api.md#the-error-vocabulary).
