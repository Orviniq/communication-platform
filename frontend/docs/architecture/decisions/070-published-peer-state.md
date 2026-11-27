# ADR-070: Dropped device last-active date and self-service account erasure

- **Status:** Accepted; `attachment_ttl_days` copy in erase dialog later replaced by `publishedLimitsProvider` under [ADR-071](071-published-limits.md) (2026-09-09)
- **Date:** 2026-09-08 (explicitly recorded in register and full section; implemented in `00f56f89`, `6f9642ea`, docs committed in `acba419a`)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-047](047-networking-composition.md), [ADR-071](071-published-limits.md), [ADR-072](072-wire-errors.md), server [ADR-0024](../../../../docs/architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md), server [ADR-0025](../../../../docs/architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md)

## Decision (Position)

Client-side record of server [ADR-0024](../../../../docs/architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md) (no activity dates) and server [ADR-0025](../../../../docs/architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md) (unlinked attachments, self-service erasure):

1. **D1 — Delete device `last_active_date` across all layers (schema 18 → 19):**
   - Because `GET /api/v1/me/devices` no longer returns `last_active_date`, requiring it in the DTO would fail response parsing for the entire Linked Devices list.
   - Deleted the field from the DTO, domain model, repository read, Linked Devices UI, and both l10n catalogues, and dropped the cached column in local schema 19 rather than defaulting "unknown" (which falsely implies an activity date exists).
2. **D2 — `DELETE /api/v1/me` authorized by password:**
   - Exposed self-service account erasure (`DELETE /api/v1/me`) carrying the account password in the body (the sole authenticated endpoint requiring a password because a 30-day session token's theft is undetectable).
   - Deliberately skipped `AuthenticationInputPolicy.isPasswordValid`'s 10-character creation minimum so accounts created before that rule can still erase, keeping only empty and 256-character `maxLength` guards (avoiding wasting one of the server's five attempts locally).
3. **D3 — Four mandatory honest disclosure statements ([erase_account_dialog.dart](../../../lib/features/settings/presentation/erase_account_dialog.dart), [erase_account_test.dart](../../../test/widget/erase_account_test.dart)):**
   - Per [SECURITY.md](../../../../docs/security/SECURITY.md), kept remote-deletion requests, server ciphertext deletion, and cryptographic erasure distinct by requiring four statements in the confirmation dialog:
     1. everything the server holds for the account is erased;
     2. copies already decrypted on recipients' phones remain untouched and unreachable (emphasized with warning color as styling only, never sole meaning);
     3. unlinked attachments stay on the server up to the retention window (initially a marked copy of `ATTACH_TTL_DAYS = 30` in historical `AccountErasureDisclosure.attachmentRetentionDays`, replaced the next day by `publishedLimitsProvider.attachmentTtlDays` under [ADR-071](071-published-limits.md));
     4. the username becomes immediately free for re-registration.
   - Rejected barrier tap dismissal, autofill password hints, typed-username ceremony, and placing Erase beside Log out (separated at the bottom as destructive).
4. **D4 — `204` and retry `401 token_revoked` collapse to one erased outcome:**
   - On a lost-response retry, `401 token_revoked` indicates the first call already deleted the account and token. Teardown drops the stored token before running the local logout wipe/generation bump without calling `POST /api/v1/auth/logout`.
5. **D5 — Client-counted password failures and ceiling-rounded `429` waits:**
   - Warns using client-local attempt count before the fifth failure locks the username across both `DELETE /api/v1/me` and `POST /api/v1/auth/login` for 15 minutes (never gates locally because another device's failures are absent from the count).
   - Rounds `429 Retry-After` **up** and uses unified localized copy for `throttled` without quoting or branching on server `detail` prose.
6. **D6 — Unified teardown guard (`isTearingDown`):**
   - `AuthenticationOperation.erase` joins `logout` behind `AuthenticationViewState.isTearingDown` so delivery, alert, and sustained-delivery controllers stop before protected storage and SQLCipher close.

## Rationale

- Keeping deletion terminology accurate at the irreversible account-erasure screen prevents users from believing peer-held history is destroyed when only server rows are removed.

## Constraints and Open Gates

- **Scope:** Local schema moved 18 → 19 solely to drop `last_active_date`; changed no cryptographic construction, message wire format, or `backend/` file; opened no production gate.

## Costs

- Linked Devices displays one fewer attribute (device existence/liveness and revocation are unchanged).
- Client-side wrong-password counter can undercount failures originating from other devices.

## Reversal Trigger

Reopen if the server begins recording device activity dates again or decouples the `DELETE /api/v1/me` rate-limit lock from `POST /api/v1/auth/login`. (The copied 30-day constant revisit trigger was resolved by [ADR-071](071-published-limits.md) on 2026-09-09.)

## History, Amendments, and Supersession

- **2026-09-08 (`00f56f89`, `6f9642ea`, `acba419a`):** Recorded and implemented ADR-070 (`Accepted`), dropping `last_active_date` (schema 19) and adding `DELETE /api/v1/me` with `EraseAccountForm`.
- **2026-09-09 (`238ec4d4` / [ADR-071](071-published-limits.md)):** Replaced the copied `AccountErasureDisclosure.attachmentRetentionDays` constant with `publishedLimitsProvider.attachmentTtlDays`.
