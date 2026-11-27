# ADR-060: Delivery-cycle ordering, poison-envelope retirement, and latency fixes

- **Status:** Accepted; D10 wire facts corrected by ADR-069 (2026-09-08); where D11 status shows amended by ADR-087 (2026-10-09); D10 header rule superseded by ADR-098 (2026-10-19)
- **Date:** 2026-08-26 (explicitly recorded in register and full section; docs committed in `ee7af86f`, implementation in `4d673d03`, `68e2f8aa`, and `c372ac66`)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-004](004-rest-and-websocket.md), [ADR-047](047-networking-composition.md), [ADR-049](049-background-catch-up.md), [ADR-057](057-measured-settings.md), ADR-061, ADR-065, ADR-069, ADR-087, ADR-098

## Decision (Position)

Investigated 15–20 s DM send delays, undelivered messages, ~1.1 MB/min idle traffic, and high idle CPU on real beta builds (with the network and backend measured clean: 27.9 ms ICMP, 107–137 ms HTTP round trips, zero backend rejections), and implemented twelve client-side changes across `DurableSyncEngine`, `SyncLifecycleSupervisor`, Drift storage, `DioRestClient`, and chat presentation:

1. **D1 — Outbox first, per-envelope isolation ([durable_sync_engine.dart](../../../lib/features/synchronization/application/durable_sync_engine.dart)):**
   - Moved outbox flushing ahead of inbound stages, keeping a second outbox pass at the end (skipped if the first pass hit a transport-shaped failure) to transmit receipts, group commits, and eviction fan-out queued during the cycle.
   - Per-envelope inspection failures record against that envelope while the loop continues; only a `_store` `StorageFailure` aborts `_run`. Session-unhealthy failures ride `_RunProgress.failure` to the end so backoff still triggers without starving local progress.
2. **D2 — Bounded inspection budget and quarantine ([durable_sync_engine.dart](../../../lib/features/synchronization/application/durable_sync_engine.dart), [drift_sync_store.dart](../../../lib/features/synchronization/infrastructure/drift_sync_store.dart)):**
   - Added `SyncEngineLimits.maximumInspectionAttempts = 8` backed by a dedicated column `inbox_envelopes.inspection_failures` (separate from `attempt_count`, which drives offline retry backoff).
   - Split failures into *transient* (`TransportFailure`, `StorageFailure`, `CancellationFailure`, `AuthenticationFailure`, `BackendFailure` `rateLimited`/`quotaExceeded`/`unknown` 5xx, `CryptoCoreFailure` `resourceExhausted`/`entropyUnavailable` — zero budget spent) and *settled* (all other native, policy, or unsupported-protocol failures — spend budget; the 8th calls `recordEnvelopeRejection` with numeric `reasonCode` + empty digest and acknowledges the envelope so the server deletes it).
   - Added count-only fields `quarantinedEnvelopes` and `failedInspections` to `SyncRunReport`.
3. **D3 — Sequence order preserved with retry floor and pass exit:**
   - Kept oldest-due-first `beginNextEnvelopeInspection` ordering for healthy in-order delivery, adding `SyncEngineLimits.minimumInspectionRetry` (`1 s`) above `SyncRetryPolicy.delayFor`'s uniform `[0, cap]` draw plus per-pass deferred tracking that exits the inspection pass if a deferred row returns to the head.
4. **D4 — Transport-only reconnect backoff and scheduled retry wake-up ([sync_lifecycle_supervisor.dart](../../../lib/features/synchronization/application/sync_lifecycle_supervisor.dart)):**
   - Restricted `_scheduleReconnect` (uniform draw up to 5 min) to `TransportFailure`, `AuthenticationFailure`, and `BackendFailure.rateLimited`; local cycle failures schedule no reconnect backoff and re-run immediately if requested.
   - Any completed cycle clears the reconnect attempt counter once per process.
   - Supervisor arms a timer on `SyncProjection.nextRetryAt` (earliest future retry across inbox, outbox, and reconnect) so rows waiting out backoff wake up without relying on stray reconnect delays.
5. **D5 — Schema 14 in-place device repair ([local_database.dart](../../../lib/features/local_storage/infrastructure/database/local_database.dart)):**
   - Added `inbox_envelopes.inspection_failures` and an idempotent repair resetting non-terminal inbox/outbox rows to `received`/queued with zero attempt count and no due time, un-tombstoning conversations that hold messages, and inserting minimal conversation rows for orphaned messages.
   - Applied via in-place upgrade (`adb install -r`) without uninstalling (never pointing the historical `tool/verify_upgrade_continuity.sh`, present at `4d673d03` and deleted in `92211fa2` with beta tooling, at beta data devices).
6. **D6 — `cipher_memory_security` disabled; `shareAcrossIsolates` kept ([platform_local_storage_native.dart](../../../lib/features/local_storage/infrastructure/platform/platform_local_storage_native.dart)):**
   - Disabled `cipher_memory_security` (live-process memory compromise is outside [threat-model.md](../../threat-model.md), and Dart heap, text-shaping/raster buffers, and platform views already hold plaintext; the 256-bit Keystore-wrapped SQLCipher key remains the at-rest control).
   - Explicitly retained `shareAcrossIsolates: true` for concurrent foreground and background catch-up isolates ([ADR-049](049-background-catch-up.md)).
7. **D7 — Set-based drain checks, cached gap flag, and conflated projection watch:**
   - `persistDrainPage` uses two set-based lookups plus a primary-key headroom check (4 statements for a 100-envelope re-served page vs. ~200) while preserving `_ServerInvariant` semantics.
   - `readProjection()` inside the inbox loop replaced by `readQueueGapState()` on the singleton checkpoint row; `_ensureCheckpoint` reads before writing.
   - `watchProjection` conflates over a 250 ms window (configurable in tests), emitting the first value immediately, always delivering the trailing state, and bypassing the open window whenever `outbox_depth` grows.
8. **D8 — Socket hint remains a hint ([gateway_realtime_sync_adapter.dart](../../../lib/features/synchronization/infrastructure/gateway_realtime_sync_adapter.dart)):**
   - Retained the authoritative REST drain after each socket hint because `GET /api/v1/me/envelopes` carries `pruned_through`, required for queue-gap detection.
9. **D9 — Request cancellation on refused/overflowed responses and 30 s idle timeout ([dio_rest_client.dart](../../../lib/features/networking/infrastructure/api/dio_rest_client.dart), [transport_security_native.dart](../../../lib/features/networking/infrastructure/tls/transport_security_native.dart)):**
   - Cancelled the request `CancelToken` on declared `Content-Length` rejection, mid-stream overflow, and caller cancellation, rewriting `_readBounded` around an explicit stream subscription so `dart:io` stops reading instead of buffering into an unread Dio `StreamController` (ending 20-minute `CLOSE_WAIT` leaks).
   - Set `idleTimeout` to 30 s (replacing 3 s Dio / 15 s `dart:io` defaults while staying under stock nginx 65 s `keepalive_timeout`).
10. **D10 — Withdrew false presence claim:**
    - Removed the always-"offline" chat header status so the header spoke only while someone typed.
    - *(Amended 2026-09-08 by ADR-069)*: D10 originally kept the presence port, projection, and frame validation on the incorrect premise that `subscribe_presence` was an unimplemented frame and `auth` the only sent frame; ADR-069 deleted that dead surface after server ADR-0020 and ADR-0022 removed both frames.
    - *(Superseded 2026-10-19 by ADR-098)*: Replaced the "speaks only while someone types" header rule when real presence and online/last-seen surfaces landed.
11. **D11 — Visible content-free sync phase on Chats list:**
    - Surfaced `SyncConnectionPhase` (`connecting`, `syncing`, `waiting to reconnect`, or silent when settled; terminal states collapsed to waiting) in the Chats offline banner slot.
    - *(Amended 2026-10-09 by ADR-087)*: Changed where the status line renders in the Chats top area while retaining the four content-free states.
12. **D12 — Schema 15 `messages.delivered_receipt_sent` one-shot guard ([local_database.dart](../../../lib/features/local_storage/infrastructure/database/local_database.dart), [drift_application_event_projector.dart](../../../lib/features/messaging/infrastructure/drift_application_event_projector.dart)):**
    - Added `delivered_receipt_sent` (preserved across rebuilds like `messages.alerted`, cleared/marked true for existing messages on upgrade and emptying pending delivered receipts) to break an infinite cross-device delivered-receipt echo loop (70–180 envelopes/min) unmasked once D1 unblocked the outbox.

## Rationale

- Separating per-envelope failure isolation from transport health and ordering outbox ahead of inbox stopped one unreadable peer envelope from blocking user sends indefinitely.
- Giving settled failures an 8-attempt budget rather than first-occurrence quarantine protects against transient classification mistakes while still retiring unopenable payloads permanently.
- Cancelling `CancelToken` rather than draining oversized bodies avoids turning size limits into unbounded transfers.

## Constraints and Open Gates

- **Scope:** Touched zero `backend/` files, zero cryptographic constructions, and zero wire contracts; opened no production gate.
- **Measured before/after ([2026-08-26-adr-060/README.md](../../validation/delivery-latency/2026-08-26-adr-060/README.md)):** Upgraded Galaxy A56 (`SM-A566B`) and API 36 `x86_64` emulator in place (build 12 schema 13 → build 15 schema 15): `pending_inbound` `10-99`/`100-999` → `0`, `quarantined_input` `0` → `100-999`, idle CPU `4.37` → `0.00` CPU-s/10 s, peer arrival **2.33 s** (vs. never), stranded probes delivered.
- **Open items recorded at ADR-060:**
  - Connection-reuse `TIME_WAIT` churn (D9) unverified on device.
  - `shareAcrossIsolates` port overhead (D6) unmeasured after D7.
  - Idle traffic `< 20 KB/min` uncertified (device-wide `/proc/net/dev` only, VPN double-counting on A56, WebSocket reconnect churn).
  - Send latency `< 1 s` below the ~2.4 s `uiautomator` polling floor (inferred sub-second from 2.33 s peer arrival).
  - `subscribe_presence` open item subsequently closed by ADR-069 (no such server frame exists).

## Costs

- Up to 8 inspection attempts before retiring a permanently unopenable envelope.
- Retained `shareAcrossIsolates: true` cross-isolate port hop per database statement.
- Retained one extra REST round trip per socket hint (107–137 ms) to obtain `pruned_through`.

## Reversal Trigger

Reopen if `shareAcrossIsolates` port overhead proves material in profiling, if `TIME_WAIT` churn persists in on-device socket inspection, if the sync indicator placement or presence rules change (subsequently triggered by ADR-069, ADR-087, and ADR-098), or if per-UID traffic accounting becomes measurable on target kernels.

## History, Amendments, and Supersession

- **2026-08-26 (`ee7af86f`, `4d673d03`, `68e2f8aa`, `c372ac66`):** Recorded and implemented ADR-060 (`Accepted`), including schema 14 repair, schema 15 `delivered_receipt_sent`, sync engine isolation, Dio cancellation, and Chats/header updates.
- **2026-09-08 (ADR-069 / `78faa708`):** Corrected D10 wire facts (`subscribe_presence` and `auth` frames do not exist) and deleted the leftover presence projection machinery.
- **2026-10-09 (ADR-087 / `e0bdcf83`):** Amended where D11's sync status line appears on the Chats screen.
- **2026-10-19 (ADR-098 / `b2bc4818`):** Superseded D10's rule that the chat header speaks only while somebody types.
