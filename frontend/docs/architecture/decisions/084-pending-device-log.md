# ADR-084: Pending window for own-account live-set checks and unsigned `PublicDeviceDto`

- **Status:** Accepted (2026-10-07, on owner's answers of same date)
- **Date:** 2026-10-07 (explicitly recorded in register and full section; implemented in `74578423`, `7ee55cb1`, PR #61 `dcd7abb3`, documented in `016832eb`)
- **Completes:** [ADR-081](081-unsigned-device-state.md) (D3: own-account device-list parser and live-set checks)
- **Related:** [ADR-027](027-device-cross-signing.md), [ADR-081](081-unsigned-device-state.md), [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md), [devices API](../../../../backend/devices/API.md)

## Decision (Position)

Completed [ADR-081](081-unsigned-device-state.md) D3 by teaching this account's own live-set checks to distinguish unlogged device enrollments/removals from forks before enabling `PublicDeviceDto` to parse the server's unsigned device encoding:

1. **D1 — `OwnLiveSetJudge` bounded pending window ([own_live_set_judge.dart](../../../lib/features/devices/application/own_live_set_judge.dart)):**
   - Used by both `LinkedDeviceManager._verifyPublicList` ([linked_device_manager.dart](../../../lib/features/devices/application/linked_device_manager.dart)) and `OwnDeviceLogCoordinator._authenticateCurrentLiveSet` ([own_device_log_coordinator.dart](../../../lib/features/devices/application/own_device_log_coordinator.dart)).
   - First tests the listed device set directly against the head log record's `SHA-256(canonical_live_device_set)`. If uncovered, classifies the list as **pending** when the head record covers a candidate derived by undoing changes on **at most two devices** (ordered fewest-changes first, bounded to `2n² + 1` inspections — at most 201 for the 10-device cap):
     - **drop the device** (device registered after the head record, or removed by the head record awaiting `DELETE`), or
     - **revert a signed device to unsigned** (same device ID, identity key, and registration ID with `cross_sig: null` and version `0`, covering a device captured unsigned by another device's append before it cross-signed).
   - Owner chose a limit of **2** devices (over 1, which misses concurrent enrollment + removal, or unbounded `3ⁿ`, which reaches 59,049 checks on a genuine 10-device fork). Undone devices are never trusted, stored, or displayed.
2. **D2 — Pending refuses cleanly without mutating state or latching a fork:**
   - Pending answers `SecurityFailure(policyBlocked)` and leaves global fork posture unchanged: Linked Devices keeps existing rows without marking history sources missing, `revoke` refuses before preparing a record, and post-remote-revocation cleanup waits until the next append closes the gap. No timer bounds the pending window.
3. **D3 — Conditions that still latch `deviceLogFork` (`liveSetMismatch`):**
   - Latches whenever no candidate matches: a logged device missing from the server list with no record, a changed identity key or registration ID, a changed signature or version on a device covered signed, a third simultaneous in-flight device, malformed signature/version pairs, or an empty own log.
4. **D4 — Head-sequence mismatch between chain read and list read is a `conflict`:**
   - When `OwnDeviceLogCoordinator._authenticateCurrentLiveSet` reads a `log_head_seq` ahead of the chain it just verified due to a concurrent device append, it returns `ValidationFailure(conflict)` instead of latching `liveSetMismatch` (matching `_verifyPublicList`), while chain checks still catch `invalidRecord`, `nonExtendingHead`, `rollback`, and `sequenceEquivocation`.
5. **D5 — `PublicDeviceDto` parses `cross_sig: null, bundle_version: 0` ([device_enrollment_dtos.dart](../../../lib/features/devices/infrastructure/device_enrollment_dtos.dart)):**
   - With D1–D4 active, `PublicDeviceDto.fromJson` parses `cross_sig: null, bundle_version: 0` as unsigned (`bundleVersion: null`) and rejects every other pair (including legacy `bundle_version: null`) per [ADR-081](081-unsigned-device-state.md) D2. Unblocks ambiguous-registration reconciliation and own-account reads during another device's recovery-secret step.

## Rationale

- A device-log record commits only to the SHA-256 hash of its canonical live set (`create_device_log_record` in [enrollment.rs](../../../native/crypto_core/src/enrollment.rs)), so the client can only verify reconstructed candidates via `inspect_peer_device_log_record`.
- Bounding candidate search to ≤ 2 unlogged device transitions avoids false global `deviceLogFork` lockouts during normal multi-device enrollment and revocation gaps without making fork detection exponential.

## Constraints and Open Gates

- **Scope:** Changed `OwnLiveSetJudge`, `LinkedDeviceManager`, `OwnDeviceLogCoordinator`, `PublicDeviceDto`, and added native test `a_logged_unsigned_device_is_covered_only_in_its_unsigned_form` in [enrollment.rs](../../../native/crypto_core/src/enrollment.rs); local schema, wire formats, protocol, native production paths, and `backend/` files unchanged; opened no production gate.
- **Verification:** Covered by [own_live_set_judge_test.dart](../../../test/features/devices/application/own_live_set_judge_test.dart), [linked_device_manager_test.dart](../../../test/features/devices/application/linked_device_manager_test.dart), [own_device_log_coordinator_test.dart](../../../test/features/devices/application/own_device_log_coordinator_test.dart), [device_enrollment_dtos_test.dart](../../../test/features/devices/infrastructure/device_enrollment_dtos_test.dart), [device_enrollment_coordinator_test.dart](../../../test/features/devices/application/device_enrollment_coordinator_test.dart), and the Rust test in [enrollment.rs](../../../native/crypto_core/src/enrollment.rs); not run against the live server.
- **Explicitly left open (owner-accepted):**
  - **Own prekey-rotation gap:** Because a device-log hash cannot reconstruct an older signed prekey `bundle_version` after `PUT /me/devices/{id}/prekeys` precedes the log append (§I), a Linked Devices refresh or revocation on another device during that gap still latches `deviceLogFork` (closing it would require storing the last authenticated own live set locally via a schema change).
  - **Peer older-head gap:** A peer whose cached head is older than the account's new head verifies the new head against the whole listed set and fails as a per-peer `deviceLogFork` if another peer device is signed but not yet appended.
  - **Revocation block by stalled enrollment:** While an unsigned device remains listed and unlogged, `revoke` refuses both removing it and any other device (matching prior behavior when `PublicDeviceDto` threw `malformedServerResponse`), leaving an incomplete registration (e.g., by someone holding the password without the recovery secret) blocking removals until removed server-side or completed.
  - **No pending UI string:** Linked Devices discards refresh/rename/remove errors, showing existing rows on pending refresh and no message on refused removal.

## Costs

- Up to `2n² + 1` native device-log inspections (`≤ 201` at 10 devices) on a pending or forked own-account check.
- Leaves prekey-rotation and stalled-unsigned-enrollment gaps open as noted above.

## Reversal Trigger

Reopen if storing the last authenticated own live set (to close the prekey-rotation gap), surfacing pending status in Linked Devices UI, or handling > 2 concurrent unlogged devices becomes necessary.

## History, Amendments, and Supersession

- **2026-10-07 (`74578423`, `7ee55cb1`, PR #61 `dcd7abb3`, `016832eb`):** Implemented and recorded ADR-084 (`Accepted`), completing [ADR-081](081-unsigned-device-state.md) D3 with `OwnLiveSetJudge`, `ValidationFailure(conflict)` on stale head sequences, and `PublicDeviceDto`'s `bundle_version: 0` parsing.
