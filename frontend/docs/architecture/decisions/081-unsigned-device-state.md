# ADR-081: Accepting the server's `bundle_version: 0` encoding for unsigned peer devices

- **Status:** Accepted (2026-10-06); D3 (own-account `PublicDeviceDto` and pending check) completed by [ADR-084](084-pending-device-log.md) (2026-10-07)
- **Date:** 2026-10-06 (explicitly recorded in register and full section; implemented in `ab287902`, documented in `40ca7f50`)
- **Related:** [ADR-080](080-batched-peers.md), [ADR-084](084-pending-device-log.md), [cryptographic-protocol.md](../../cryptographic-protocol.md), [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md)

## Decision (Position)

Resolved the parser mismatch surfaced by [ADR-080](080-batched-peers.md) on peer-device routes without prematurely exposing own-account live-set checks to unlogged enrollments:

1. **D1 — Peer parser reads `cross_sig: null, bundle_version: 0` as unsigned ([contact_api_dtos.dart](../../../lib/features/contacts/infrastructure/contact_api_dtos.dart)):**
   - `_devices` (shared by `GET /api/v1/users/{user_id}/devices` and `POST /api/v1/peers`) now reads `cross_sig: null` beside `bundle_version: 0` as an unsigned `PeerPublicDevice` with `bundleVersion: null`, matching `Device.bundle_version = PositiveIntegerField(default=0)` in `backend/devices/services.py` (`PeerDeviceOut` in [backend/openapi.json](../../../../backend/openapi.json)) and matching the canonical device-set encoding in [cryptographic-protocol.md](../../cryptographic-protocol.md) ("zero only while unsigned").
   - Moves judgment from transport parsing (`malformedServerResponse`, which failed an entire `POST /api/v1/peers` batch) into `_refresh`, which records `invalidDevice` and fails only that peer with `unauthenticatedInput` ([CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) §E) while verifying and storing other peers in the batch.
2. **D2 — Every other `(cross_sig, bundle_version)` combination stays malformed:**
   - Rejects a signature with `bundle_version < 1`, missing signature with `bundle_version > 0`, and negative, null, missing, or non-integer `bundle_version` (tightening away legacy acceptance of `bundle_version: null`, which the server never emits). Matches `inspect_peer_device_log_record` in the Rust core.
   - Note: `PUT /me/devices/{id}/prekeys` permits a device to retract `cross_sig: null` at a higher version; kept malformed rather than silently treated as unsigned because signature retraction is a cross-signature change requiring [CLIENT_CONTRACT.md](../../../../docs/client/CLIENT_CONTRACT.md) §D handling.
3. **D3 — `PublicDeviceDto` deferred until own-account pending window exists *(completed 2026-10-07 by [ADR-084](084-pending-device-log.md))*:**
   - Deliberately kept `PublicDeviceDto.fromJson` refusing `bundle_version: 0` at ADR-081 because `LinkedDeviceManager._verifyPublicList` and `OwnDeviceLogCoordinator._authenticateCurrentLiveSet` lacked a pending window and would have latched an unrecoverable global `deviceLogFork` (`liveSetMismatch`) whenever another own device sat between registration and cross-signature.
   - *Completed ([ADR-084](084-pending-device-log.md)):* Added `OwnLiveSetJudge` pending-window classification and updated `PublicDeviceDto.fromJson` in [device_enrollment_dtos.dart](../../../lib/features/devices/infrastructure/device_enrollment_dtos.dart) to match D1 and D2.

## Rationale

- `PeerDeviceOut.bundle_version` is a non-nullable integer defaulting to `0` prior to `PUT /me/devices/{id}/prekeys`. Expecting `null` caused a single peer with a mid-enrollment device to abort an entire 64-peer `POST /api/v1/peers` response with `malformedServerResponse`.
- Decoupling peer routes (which already hold a same-head pending/refusal path in `_refresh`) from own-account routes avoided opening an immediate `deviceLogFork` trap during multi-device enrollment until [ADR-084](084-pending-device-log.md) added the corresponding own-account pending judge.

## Constraints and Open Gates

- **Scope:** Changed `_devices` in [contact_api_dtos.dart](../../../lib/features/contacts/infrastructure/contact_api_dtos.dart) only; no wire format, protocol, cryptographic construction, local schema, or `backend/` file changed; opened no production gate.
- **Verification:** Covered by `PeerDevicesResponseDto` / `PeerStatesResponseDto` tests ([contact_api_dtos_test.dart](../../../test/features/contacts/infrastructure/contact_api_dtos_test.dart)) and service tests ([client_authentication_service_test.dart](../../../test/features/contacts/application/client_authentication_service_test.dart)) over mock HTTP adapters; no live-server run at ADR-081.
- **Prekey-claim parser (`ClaimedBundlesResponseDto`):** Intentionally continues to require non-null `cross_sig` and `bundle_version >= 1`, since claims only target devices already accepted by `_refresh` and an unsigned claimed bundle indicates a mid-flight change that must withhold the send.

## Costs

- Until a separate decision handles retracted cross-signatures (`cross_sig: null` with `bundle_version > 0`), such a response remains classified as malformed and fails its batch.

## Reversal Trigger

Reopen if the backend changes `PeerDeviceOut.bundle_version` nullability or if retracted-signature handling (`cross_sig: null, bundle_version > 0`) is moved from malformed to `invalidDevice` / §D block.

## History, Amendments, and Supersession

- **2026-10-06 (`ab287902`, `40ca7f50`):** Implemented and recorded ADR-081 (`Accepted`) for peer device routes (`_devices`), deferring `PublicDeviceDto` (D3).
- **2026-10-07 (`74578423`, `7ee55cb1`, `016832eb` / [ADR-084](084-pending-device-log.md)):** Completed D3 by adding `OwnLiveSetJudge` and switching `PublicDeviceDto` in [device_enrollment_dtos.dart](../../../lib/features/devices/infrastructure/device_enrollment_dtos.dart) (and `device_enrollment_dtos_test.dart`) to `cross_sig: null, bundle_version: 0`.
