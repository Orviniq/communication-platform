# ADR-071: Published deployment limits, `full_devices` handling, and retention disclosure

- **Status:** Accepted; `DeploymentDisclosure` subsequently evolved through [ADR-075](075-pairwise-groups.md), [ADR-076](076-production-signing.md), ADR-089, ADR-094, and ADR-098 (now revision 11)
- **Date:** 2026-09-09 (explicitly recorded in register; implemented and documented across PR #47 / `5589e23e`, register row in `238ec4d4`)
- **Amends:** [ADR-045](045-maturity-disclosure.md), [ADR-052](052-accurate-capability-claims.md) (raises `DeploymentDisclosure` to revision 8, superseding the outstanding rev-7 written-handover obligation), [ADR-070](070-published-peer-state.md) (replaces copied `attachmentRetentionDays` with `publishedLimitsProvider.attachmentTtlDays`)
- **Related:** [ADR-069](069-gateway-frames.md), [ADR-070](070-published-peer-state.md), [ADR-072](072-wire-errors.md), [ADR-075](075-pairwise-groups.md), [ADR-076](076-production-signing.md), server [ADR-0024](../../../../docs/architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md)

## Decision (Position)

*(Extracted from the ADR-071 register row and PR #47 commits `00f69dfe`, `4393d2ae`, `d4ce1a20`, `238ec4d4`, `21cdf1fe`, and `7e059dc2`; no separate full section existed in `decisions.md`.)*

Consumed `GET /api/v1/config` across networking, storage, synchronization, attachments, and user-facing disclosures:

1. **Synchronous published limits replacing hardcoded duplicates ([server_config_model.dart](../../../lib/features/server_config/domain/server_config_model.dart), [server_config_snapshot.dart](../../../lib/features/server_config/application/server_config_snapshot.dart), [server_config_limits.dart](../../../lib/app/dependencies/server_config_limits.dart)):**
   - Replaced static copies in `ApiContractLimits` ([api_request.dart](../../../lib/features/networking/infrastructure/api/api_request.dart)) and Drift stores with `ServerConfig` read from `GET /api/v1/config` (`send_batch_max`, `ack_max`, `claim_max`, `drain_page_max`, `mailbox_max_bytes`, `envelope_buckets`, `attachment_buckets`, `signal_buckets`, `envelope_ttl_days`, `attachment_ttl_days`, `attachment_daily_bytes`, `max_devices_per_user`, `max_device_log_records`, `session_token_days`, `voice_configured`).
   - `LatestServerConfig` (`serverConfigSnapshotProvider`) tracks the durable row synchronously for callers that cannot `await` or rebuild (`DioWebSocketGateway` frame decoding, REST response decoding, `DurableSyncEngine`, stores), starting from `ServerConfig.fallback` before storage opens (`server_config_startup_test.dart`).
   - Retained only unpublished limits in `ApiContractLimits` (`maximumDeviceLogRecords`, `maximumWebSocketFrameBytes`, `maximumPeerStateUsers`, `maximumPeerStateEtagCharacters`, profile/label/name/device-log/backup buckets, and HTTP `PayloadLimits`).
2. **Clamping vs. caller-fault ceilings:**
   - `drain_page_max` and `ack_max` are clamped silently inside transport adapters (`DioSyncRemotePort`) so an out-of-sync page/ack size never strands undrained envelopes and `DurableSyncEngine` stays decoupled from `server_config`.
   - Bodies exceeding `send_batch_max` or `claim_max` remain caller faults (avoiding partial/accidental prekey consumption).
3. **`full_devices` handling on `POST /api/v1/envelopes` (`d4ce1a20`):**
   - Parsed `full_devices` alongside `stale_devices`: unlike a stale device (terminal row, session torn down, peer refreshed), a full device is live with a full mailbox (`MAILBOX_MAX_BYTES`), so its outbox target stays queued for backoff retry with sessions intact.
   - Verified `accepted == batch.length - stale_devices.length - full_devices.length`; oversized items exceeding `mailbox_max_bytes` fail once locally instead of retrying as full indefinitely.
4. **Provenance-gated retention disclosure (revision 8) and erase-dialog window ([deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart), [erase_account_dialog.dart](../../../lib/features/settings/presentation/erase_account_dialog.dart)):**
   - Added non-wire `ServerConfig.fromDeployment` flag (`false` in `ServerConfig.fallback`, `true` when parsed from server/stored response) so `DisclosurePoint.messagesExpireUnread` (`since: 8`) states `envelopeTtlDays` only once obtained from the deployment and retains unnumbered phrasing beforehand (preventing presenting a build default as server fact).
   - Replaced [ADR-070](070-published-peer-state.md)'s copied `30` in the account-erasure confirmation with `publishedLimitsProvider.attachmentTtlDays`.
   - Raised `DeploymentDisclosure` to revision 8 (superseding the outstanding rev-7 written-handover obligation).
5. **Local daily attachment-upload tracking (`21cdf1fe`):**
   - Added `DriftAttachmentAllowanceStore` tracking device-local UTC-day upload bytes against `attachment_daily_bytes` and `attachment_buckets` at upload time, while recording in the ADR register that no live attachment picker/upload surface was composed yet (left uncomposed until ADR-089).

## Rationale

- Removing duplicate client copies of operator-configurable ceilings eliminates client/server disagreement and internal transport-vs-store mismatches where a drained envelope could be accepted over HTTP and rejected at SQLite persistence.
- Separating `full_devices` from `stale_devices` prevents tearing down active sessions and dropping live recipients simply because a peer's mailbox reached `MAILBOX_MAX_BYTES`.

## Constraints and Open Gates

- **Scope:** Added no dependency, opened no production gate, changed no wire format, and touched no `backend/` file.
- **Release obligation at ADR-071:** Written handover disclosure re-delivery remained release-blocking at revision 8 (subsequently superseded by later revisions up to rev 11).

## Costs

- `LatestServerConfig` adds an in-process stream follower; device-local `attachment_daily_bytes` tracking is a lower bound across multiple devices of the same account (safe direction: avoids false refusals).

## Reversal Trigger

Reopen if `GET /api/v1/config` changes schema, if remaining unpublished constants in `ApiContractLimits` move to server configuration, or when `DisclosurePoint` content changes (subsequently triggered across ADR-075, ADR-076, ADR-089, ADR-094, and ADR-098).

## History, Amendments, and Supersession

- **2026-09-09 (`00f69dfe`, `4393d2ae`, `d4ce1a20`, `238ec4d4`, `21cdf1fe`, `7e059dc2` in `5589e23e`):** Recorded and implemented ADR-071 (`Accepted`), wiring `ServerConfigSnapshot`, `full_devices`, retention disclosure rev 8, and allowance store.
- **2026-09-13 – 2026-10-19 ([ADR-075](075-pairwise-groups.md), [ADR-076](076-production-signing.md), ADR-089, ADR-094, ADR-098):** Evolved `DeploymentDisclosure` from revision 8 through revision 11; ADR-089 composed the direct/Saved attachment picker and upload flow over the allowance store.
