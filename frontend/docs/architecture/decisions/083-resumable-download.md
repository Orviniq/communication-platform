# ADR-083: Resumable large attachment downloads and single-flight token contention control

- **Status:** Accepted (2026-10-07); early-window single-flight behavior amended the same day by [ADR-085](085-session-renewal.md)
- **Date:** 2026-10-07 (explicitly recorded in register and full section; attachment changes in `2757cf17`, `bad7c5e5`; token changes in `01028e72`, `9ceab84a`; docs in `a3b1bbf8`, `5816282f`)
- **Amends:** [ADR-049](049-background-catch-up.md), [ADR-050](050-delivery-ownership.md), and [ADR-068](068-session-token.md) (updates token single-flight rationale from rotation-safety invariant to contention control; leaves [ADR-050](050-delivery-ownership.md) A–B envelope arbitration intact)
- **Related:** [ADR-080](080-batched-peers.md), [ADR-082](082-fresh-peer-resolution.md), [ADR-085](085-session-renewal.md), [attachments.md](../../attachments.md), [SYNC.md](../SYNC.md), [attachments API](../../../../backend/attachments/API.md), [CLIENT_WORK.md](../../../../CLIENT_WORK.md), server [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md), server [ADR-0024](../../../../docs/architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md), server [ADR-0025](../../../../docs/architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md)

## Decision (Position)

Closed the two remaining optional items from [CLIENT_WORK.md](../../../../CLIENT_WORK.md) in response to server [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md), [ADR-0024](../../../../docs/architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md), and [ADR-0025](../../../../docs/architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md):

1. **D1 — HTTP `Range` / `If-Range` resume for the two largest attachment buckets ([attachment_transport.dart](../../../lib/features/attachments/infrastructure/attachment_transport.dart)):**
   - Applies exclusively to the two largest protocol buckets in `AttachmentCryptoProtocolV1.buckets` (16 MiB and 64 MiB; ≤ 4 MiB buckets restart from byte 0).
   - When a partial file exists for a capability, `DioAttachmentTransport.download` sends `Range: bytes=<offset>-` (RFC 9110 §14.1.2) and `If-Range: <exact strong ETag>` (RFC 9110 §13.1.5 / §8.8.3.2; responses without a strong ETag download without resume).
   - Accepts `206` only for an exact continuation (`Content-Range: bytes <offset>-<bucket - 1>/<bucket>`) with matching strong ETag (RFC 9110 §15.3.7); counts downloaded length from `<offset>` so the finished file is always exactly one bucket. A `200` to a ranged request truncates and writes from byte 0; a changed ETag on `200` or `206` deletes the partial and reports `BackendFailure(notFound)` (retention sweep replaced/removed object).
2. **D2 — Retention vs. deletion of partial bytes:**
   - Retains partial bytes only after failures leaving the remote object and written prefix intact: dropped connections (catching `IOException` emitted directly on Dio 5.11.0's response stream as `offline`, after `FileSystemException` storage errors), cancellations, or `4xx`/`5xx` refusals other than `404` and `416`.
   - Deletes the partial file immediately on `404`, `416`, ETag mismatch, mismatched `Content-Range` offset, length overrun/underrun, or disk write failure.
3. **D3 — Single in-memory partial record and transport-owned `File` return (`2757cf17`):**
   - Because attachment capabilities must stay inside protected storage (`attachments.md`) and Dart has no exposed capability hash, `DioAttachmentTransport` keeps at most one `_PartialDownload` record (capability, bucket, `File`, strong ETag) in memory; a new failed download replaces the prior partial, bounding leftover disk state to one bucket, and taking the record before starting avoids concurrent same-capability writes.
   - Changed `AttachmentTransportPort.download` ([attachment_transfer_ports.dart](../../../lib/features/attachments/application/ports/attachment_transfer_ports.dart)) to return the completed `File` rather than streaming into a caller sink; `AttachmentTransferService` ([attachment_transfer_service.dart](../../../lib/features/attachments/application/attachment_transfer_service.dart)) decrypts and deletes it.
4. **D4 — Keep single-flight renewal as contention control; delete `SessionTokenStore.readDurable` (`01028e72`):**
   - Because server [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md) makes `POST /api/v1/auth/renew` non-retiring (concurrent renewals in [delivery_owner_contention_test.dart](../../../test/features/networking/delivery_owner_contention_test.dart) both leave working tokens), `TokenCoordinator`'s single flight ([token_coordinator.dart](../../../lib/features/networking/infrastructure/auth/token_coordinator.dart)) is retained solely to coalesce concurrent callers in the renewal window onto one `accounts`-scoped call (300/min limit shared with [ADR-080](080-batched-peers.md) and [ADR-082](082-fresh-peer-resolution.md)), alongside the `Zone` marker ([ADR-068](068-session-token.md) D3) and `_sessionGeneration`.
   - Deleted unused `SessionTokenStore.readDurable` (`01028e72`) left behind when [ADR-068](068-session-token.md) removed [ADR-050](050-delivery-ownership.md) decision C's rotation repair.
   - *Amendment ([ADR-085](085-session-renewal.md), 2026-10-07):* Early renewals from half-lifetime onward no longer block callers waiting on `_renewalInFlight` (only preventing duplicate concurrent renewals), while callers inside `proactiveRenewalWindow` + `clockSkewAllowance` still join and wait on `_renewalInFlight`.
5. **D5 — Documentation corrections:**
   - Added dated notes to [ADR-049](049-background-catch-up.md) and [ADR-050](050-delivery-ownership.md) clarifying that the token-retirement hazard is gone while [ADR-050](050-delivery-ownership.md)'s envelope-inspection arbitration gate stands; updated [SYNC.md](../SYNC.md), [testing-strategy.md](../../testing-strategy.md), and wait comments in [message_delivery.dart](../../../lib/app/dependencies/message_delivery.dart), [sync_ports.dart](../../../lib/features/synchronization/application/ports/sync_ports.dart), [sync_platform_adapters.dart](../../../lib/features/synchronization/infrastructure/sync_platform_adapters.dart), and [platform_deferred_delivery_scheduler.dart](../../../lib/features/synchronization/infrastructure/platform_deferred_delivery_scheduler.dart) (`9ceab84a`, `5816282f`).

## Rationale

- nginx serves attachment downloads via internal redirect and supports RFC 9110 `Range` / `If-Range` ([backend/attachments/API.md](../../../../backend/attachments/API.md), [GROUND-TRUTH.md](../../../../docs/architecture/GROUND-TRUTH.md) §4), avoiding full re-downloads on interrupted 16 MiB and 64 MiB transfers without adding a database table or leaking capability hashes onto temporary filenames.
- Keeping `TokenCoordinator`'s single flight avoids redundant `accounts`-scoped `/auth/renew` calls during bursts while deleting dead `readDurable` keeps the port truthful.

## Constraints and Open Gates

- **Scope:** Local schema, wire formats, cryptographic constructions, and `backend/` files unchanged; opened no production gate.
- **Verification:** Covered by [attachment_pipeline_test.dart](../../../test/features/attachments/attachment_pipeline_test.dart) (with 9 fault-injection checks), [token_coordinator_test.dart](../../../test/features/networking/infrastructure/token_coordinator_test.dart), and [delivery_owner_contention_test.dart](../../../test/features/networking/delivery_owner_contention_test.dart).
- **Not verified / left open at ADR-083:**
  - **No live nginx run:** Tested against a fake server; direct app server responses do not implement `Range` (nginx internal redirect does), and [GROUND-TRUTH.md](../../../../docs/architecture/GROUND-TRUTH.md) tested a closed byte range rather than the open `bytes=<offset>-` form.
  - **Attachment composition & killed-process cleanup:** At ADR-083, `AttachmentTransferService` was not yet wired to a UI screen (subsequently composed in ADR-089), and an OS-killed process's orphaned partial file is not swept on restart.
  - **`500` / `503` download status mapping *(fixed 2026-10-10 in `01621c03`)*:** ADR-083 noted `DioAttachmentTransport` still mapped `500` and `503` on download as malformed responses despite [backend/openapi.json](../../../../backend/openapi.json); later fixed in `01621c03` to map them as server failures.
  - **2.5-minute renewal window defect *(fixed 2026-10-07 by [ADR-085](085-session-renewal.md))*:** Noted in passing that renewing only inside the final `proactiveRenewalWindow` + `clockSkewAllowance` logged out idle users after expiry; resolved the same day by [ADR-085](085-session-renewal.md).

## Costs

- Holds up to one 64 MiB partial ciphertext file in the private cache directory between attempts; process death discards the in-memory `_PartialDownload` pointer and forces restart from byte 0.
- Interrupted downloads in buckets ≤ 4 MiB restart from byte 0 by design.

## Reversal Trigger

Reopen if multi-download parallel transfers or restart-resumable partials require a durable encrypted partial-download table, or if server token renewal semantics change from [ADR-0023](../../../../docs/architecture/decisions/0023-one-device-bound-session-token.md).

## History, Amendments, and Supersession

- **2026-10-07 (`2757cf17`, `bad7c5e5`, `01028e72`, `9ceab84a`, `a3b1bbf8`, `5816282f`):** Implemented and recorded ADR-083 (`Accepted`), adding `Range`/`If-Range` download resume for 16 MiB and 64 MiB buckets, deleting `SessionTokenStore.readDurable`, and documenting single-flight renewal as contention control.
- **2026-10-07 (`5d92987f` / [ADR-085](085-session-renewal.md)):** Moved proactive session renewal to half-lifetime without blocking callers until the final 2.5-minute window, closing the defect noted in ADR-083.
- **2026-10-10 (`01621c03`):** Mapped attachment download `500` and `503` responses to server failures rather than malformed answers.
