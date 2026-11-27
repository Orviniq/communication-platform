# ADR-093: Hold first messages from unverified senders until verification

- **Status:** Accepted (2026-10-18); proposed 2026-10-17; prekey-maintenance wiring completed by [ADR-095](095-prekey-maintenance.md) (2026-10-18)
- **Date:** 2026-10-17 proposed, 2026-10-18 accepted (explicitly recorded in register and full section; proposed in `76cd553f`, implemented on `frontend-held-unverified-messages` in `f2d78018`–`938c4a1c`, PR #85 `0db432f1`)
- **Amends:** [pairwise-transport-v1.md](../../pairwise-transport-v1.md) and [cryptographic-protocol.md](../../cryptographic-protocol.md) (adds exception keeping retired signed prekey pairs needed by held envelopes and postponing conflicting rotations)
- **Related:** [ADR-021](021-profile-fallback.md), [ADR-060](060-delivery-latency.md), [ADR-095](095-prekey-maintenance.md), [SYNC.md](../SYNC.md), [LOCAL-DATA.md](../LOCAL-DATA.md), [ui-specification.md](../../ui-specification.md), [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) (cited historically as `backend/CLIENT_CONTRACT.md` before [server ADR-0030](../../../../docs/architecture/decisions/0030-the-security-model-and-the-client-contract-move-under-docs.md)), [messaging API](../../../../backend/messaging/API.md)

## Decision (Position)

Held unopened initial envelopes and their follow-ups from `unverified` senders in the local encrypted database until out-of-band verification, without spending inspection attempts, losing messages, or violating no-TOFU guarantees:

1. **D1–D4, D10 — Hold, preserve ciphertext, isolate to `unverified`, and release on verification:**
   - A first message whose sender the recipient has not verified is held: not opened past the sender block, not shown, and not receipted.
   - Its exact ciphertext remains in `inbox_envelopes`, the server copy is acknowledged, and no inspection budget (`inspection_failures`) is spent.
   - Only `ContactTrustState.unverified` triggers holding; changed master key, invalid/unsigned device, device-log fork, and unavailable identity keep their existing failure/budget handling.
   - On out-of-band verification, each held envelope of that sender returns to inspection in mailbox (`sequence`) order, with no wire or server change.
2. **D5, D14 — Bounded retention and cascade eviction:**
   - **7-day expiry:** A held-marked row expires 7 × 24 hours after `held_at` (matching default `ENVELOPE_TTL_DAYS`), evaluated by `DurableSyncEngine` at the start of each cycle's inbox pass (quarantine reason `5`).
   - **Count caps:** At most **64** held-marked rows per sender and **128** per phone (worst-case 128 × 262,144 B = 32 MiB, matching `MAILBOX_MAX_BYTES`). Before holding a 65th sender row or 129th device row, `DurableSyncStore.recordEnvelopeHold` quarantines the oldest qualifying row (reason `6`).
   - **Session cascade:** When an initial held row leaves via expiry, eviction, or failed re-inspection, all follow-up rows for that `held_session_id` move to quarantine in the same transaction (orphaned follow-ups use reason `2`). Cleared rows already acknowledged at the server move to `processing_state = 4` so the contiguity walk deletes them in order without stalling.
3. **D6, D17 — Keep retired signed prekeys usable ([prekey_maintenance_service.dart](../../../lib/features/devices/application/prekey_maintenance_service.dart)):**
   - Without changing the Rust core, `PrekeyMaintenanceService` reads the earliest UTC hold day `H` via `HeldEnvelopeRetentionPort` (`SyncHeldEnvelopeRetention` in [held_envelope_adapters.dart](../../../lib/features/synchronization/infrastructure/held_envelope_adapters.dart)).
   - `pruneRetainedSignedPrekeys` receives `min(today, H)` (while creation-time future checks still use `today`).
   - Due rotations (which prune with `today` internally in Rust) are postponed while `H ≤ L + 1` or (`T > L + 8` and `H ≤ L + 8`), delaying rotation until at most `L + 8` (when on schedule) or `L + 16` (if already late); one-time prekey replenishment still runs.
   - Prekey maintenance was unwired at ADR-093 close and wired into the delivery cycle by [ADR-095](095-prekey-maintenance.md).
4. **D11 — Local storage (`inbox_envelopes`, schema 25 in [local_database.dart](../../../lib/features/local_storage/infrastructure/database/local_database.dart)):**
   - Reused `InboxProcessingState` value `5` (renamed `held`, resetting any legacy state `5` rows to `0` on migration) rather than rebuilding the table for a new CHECK value or copying ciphertext to a separate table.
   - Added four nullable columns: `held_sender_user_id` (lowercase claimed sender), `held_session_id` (16-byte CHECK), `held_initial` (boolean), and `held_at` (date-time).
   - Added two partial indexes: `inbox_envelopes_held_by_sender` on `(held_sender_user_id, sequence) WHERE held_sender_user_id IS NOT NULL` and `inbox_envelopes_held_by_session` on `(held_session_id) WHERE held_session_id IS NOT NULL` (phone-wide oldest/expiry reads scan at most 128 held rows and sort in Dart so SQLite does not pick the inbox sequence index).
   - Both contiguity walks (`DurableSyncStore.recordAcknowledgementSuccess` in [drift_sync_store.dart](../../../lib/features/synchronization/infrastructure/drift_sync_store.dart) and `DriftGroupRepository` in [drift_group_repository.dart](../../../lib/features/groups/infrastructure/drift_group_repository.dart)) treat state `5` as acknowledged while deleting only state `4`. `inbox_depth` and `pending_inbound` exclude states `4` and `5`.
5. **D12, D13, D15 — Inbound classification, follow-up correlation, and single acknowledgement:**
   - `PairwiseLiveDeviceResolverPort.resolveInboundSender(userId)` ([contact_selective_pairwise_claim_adapter.dart](../../../lib/features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart)) returns `VerifiedInboundSender` or `UnverifiedInboundSender` (only when refresh succeeds in `unverified` with present identity and signed devices), leaving `resolveVerifiedLiveDevices` and `policyBlocked` unchanged.
   - `OpaqueEnvelopeInspector.inspect` ([pairwise_opaque_envelope_inspector.dart](../../../lib/features/synchronization/infrastructure/pairwise_opaque_envelope_inspector.dart)) returns `HeldEnvelopeInspection` when an initial non-repair envelope probes to a device matching `UnverifiedInboundSender` checks (no `acceptVerifiedInitial`, no consumed OTPK), or when a regular envelope with no local session matches exactly one held initial via `HeldSessionLookupPort` (`held_initial = false`).
   - Held rows enter state `2` (`ready_to_acknowledge`), transition to `5` on `recordAcknowledgementSuccess`, and never re-acknowledge on post-release commit (moving directly to `4` with held columns cleared; re-hold restores `5` and keeps original `held_at`).
6. **D16 — Verification release trigger and engine sweep:**
   - `ClientAuthenticationService` ([client_authentication_service.dart](../../../lib/features/contacts/application/client_authentication_service.dart)) notifies `PeerVerificationObserver.peerVerified(userId)` best-effort after `confirmOutOfBand`, releasing state-`5` rows to `0` due 1 s ahead (`minimumInspectionRetry`).
   - At the start of each cycle's inbox pass (after expiry), `DurableSyncEngine` ([durable_sync_engine.dart](../../../lib/features/synchronization/application/durable_sync_engine.dart)) checks held senders via `HeldSenderTrustPort.verifiedAmong` (reading local `ContactLocalPort` without network) and releases verified senders immediately in sequence order, ensuring subsequent full inspection re-verifies the sender and opens initial envelopes before follow-ups.
7. **D7, D8, D18 — Chats held-sender row ([chats_list_page.dart](../../../lib/features/messaging/presentation/chats_list_page.dart), [chat_list_row.dart](../../../lib/features/messaging/presentation/chat_list_row.dart)):**
   - `watchHeldSenders()` / `heldSendersProvider` ([sync_providers.dart](../../../lib/app/dependencies/sync_providers.dart)) stream senders with rows in states `2`, `3`, or `5` (released rows excluded).
   - `chatListEntries` keeps pinned conversations first, then merges held-sender rows by `latest_held_at` descending (tie-broken by user ID). Held group copies count in the same sender row.
   - Displays `@username` from `contactListProvider` (or `chatShortIdentity` without `@` if unknown), wrapped in a left-to-right isolate in RTL locales (`chatNameForSentence`), with pluralized `"… sent you 1 message. Verify to read it."` / `"N messages. Verify to read them."` (en/fa), deterministic local avatar ([ADR-021](021-profile-fallback.md)), no preview/time/badge/menu, single semantic button opening `/contacts/:userId/safety`, excluded from Chats search.
8. **D9, D19 — Sender undelivered hint ([chat_undelivered_hint.dart](../../../lib/features/messaging/presentation/chat_undelivered_hint.dart)):**
   - Shown below the timeline (between timeline and composer in [chat_conversation_view.dart](../../../lib/features/messaging/presentation/chat_conversation_view.dart)) in direct chats only (never in groups or Saved Messages) when the newest own message is non-deleted, `relayAccepted`, has no delivery receipt, and is ≥ 1 hour old (`chatUndeliveredHintDelay`, measured from `createdMs` with a single one-shot timer scheduled for the exact due moment): `"Not delivered yet. If @username has not verified you, ask them to."`
9. **D20 — Privacy and diagnostics ([diagnostics_report.dart](../../../lib/features/diagnostics/domain/diagnostics_report.dart)):**
   - `SyncRunReport` adds `heldEnvelopes`, `DiagnosticsReport.formatVersion` bumps `2 → 3`, and `DiagnosticField.heldInbound` (`held_inbound`) counts state-`5` rows while `pending_inbound` excludes them. No log or report records claimed senders, session IDs, envelope IDs, or timestamps.

## Rationale

- Field testing on 2026-10-17 showed direct messages from user A (who verified B) to user B (who had not verified A) staying at one tick and disappearing: initial envelopes exhausted 8 `policyBlocked` retries, were quarantined and acknowledged, and follow-up regular envelopes were quarantined on their first inspection (`unauthenticatedInput`).
- Holding the exact ciphertext in `inbox_envelopes` avoids server changes, preserves single-acknowledgement timing privacy (acknowledging in the same batch as opened envelopes), prevents unverified-sender TOFU acceptance, and avoids a separate table or second inspection pipeline.

## Constraints and Open Gates

- **Scope:** Added schema 25 columns/partial indexes to `inbox_envelopes`, resolver/inspector/store/engine hold & release logic, `PrekeyMaintenanceService` hold-day awareness, `DiagnosticsReport` format version 3 (`held_inbound`), Chats held-sender rows, and `ChatUndeliveredHint`; changed no wire format, event kind, cryptographic construction, Rust core, dependency, Android permission, or `backend/` file.
- **Verification:** Covered by host and widget suites over in-memory databases: [local_database_migration_test.dart](../../../test/features/local_storage/infrastructure/local_database_migration_test.dart), [local_database_index_plan_test.dart](../../../test/features/local_storage/infrastructure/local_database_index_plan_test.dart), [contact_selective_pairwise_claim_adapter_test.dart](../../../test/features/pairwise/contact_selective_pairwise_claim_adapter_test.dart), [pairwise_opaque_envelope_inspector_test.dart](../../../test/features/synchronization/pairwise_opaque_envelope_inspector_test.dart), [durable_sync_engine_test.dart](../../../test/features/synchronization/durable_sync_engine_test.dart), [drift_sync_store_test.dart](../../../test/features/synchronization/drift_sync_store_test.dart), [prekey_maintenance_service_test.dart](../../../test/features/devices/application/prekey_maintenance_service_test.dart), [held_inbound_diagnostics_test.dart](../../../test/features/diagnostics/held_inbound_diagnostics_test.dart), [held_first_message_flow_test.dart](../../../test/features/synchronization/held_first_message_flow_test.dart), [chats_held_senders_test.dart](../../../test/widget/chats_held_senders_test.dart), [chat_undelivered_hint_test.dart](../../../test/widget/chat_undelivered_hint_test.dart), and [group_message_actions_test.dart](../../../test/widget/group_message_actions_test.dart), plus 12 storage/engine mutation checks and 5 UI mutation checks.
- **Left open / not verified:**
  - **No device run:** Neither two-phone verification/release nor the 1-hour hint under Doze-stretched catch-up has run on hardware; Persian copy awaits native-speaker review.
  - **Follow-ups behind transiently deferred initials:** D13 matches held initials only; a regular envelope inspected while its verified sender's initial is transiently deferred still finds no session and quarantines at once.
  - **No sender name lookup:** Senders absent from contacts display `chatShortIdentity` (`CLIENT_CONTRACT.md` §P forbids unrequested lookups; the server has no user-ID-to-name route).
  - **Hint placement:** `ChatUndeliveredHint` sits below the timeline rather than scrolling inside it so message view-model caching stays stable.

## Costs

- Up to 32 MiB of held ciphertext in the encrypted database for up to 7 days.
- Past 64 held envelopes from one sender, evicting the oldest initial quarantines its entire held session; subsequent messages on that session fail until a new session starts.
- Signed prekey rotation can be postponed up to `L + 8` (or `L + 16` when already late) while held envelopes depend on retired keys, extending retired-key exposure on device compromise by that window.
- Held row names and counts represent unauthenticated sender claims until verification (a hostile server can spoof claims naming real contacts to prompt opening Safety Number, though out-of-band comparison protects verification).
- Each released initial envelope re-runs identity/device refresh; released group copies land at their original timestamp. The sender's 1-hour hint can also appear when a peer's phone is simply offline.

## Reversal Trigger

Reopen if the Rust core adds caller-supplied prune days to `prepare_rotation` (removing D17's rotation postponement), if follow-up matching is extended to transiently deferred initials, or when implementing mutual-verification / `CPCTV001` verification-notice handling ([cryptographic-protocol.md](../../cryptographic-protocol.md), [STATUS.md](../../STATUS.md)).

## History, Amendments, and Supersession

- **2026-10-17 (`76cd553f`):** Proposed ADR-093 design for holding unverified first messages and follow-ups.
- **2026-10-17 – 2026-10-18 (`f2d78018`–`938c4a1c`, PR #85 `0db432f1`):** Implemented schema 25, hold/release/expiry/eviction, D17 key retention, Chats held-sender rows, and `ChatUndeliveredHint`; amended `pairwise-transport-v1.md` and `cryptographic-protocol.md`; accepted ADR-093.
- **2026-10-18 ([ADR-095](095-prekey-maintenance.md)):** Wired `PrekeyMaintenanceService` into `DurableSyncEngine` with D17 unchanged.
