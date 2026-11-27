# ADR-035: Verified monotonic prekey rotation under unchanged device identity does not reset master-key verification

- **Status:** Accepted
- **Date:** 2026-07-29 (explicitly recorded in register; committed in `d0092ee9`)
- **Related:** [ADR-025](025-hybrid-pqxdh.md), [ADR-027](027-device-cross-signing.md), [ADR-034](034-authenticated-pq-contribution.md)

## Decision (Position)

A **verified monotonic signed-prekey rotation** (`bundle_version + 1`) under an **unchanged device identity (`ik_pub`)** with valid prekey signatures, valid `cross_sig`, and an extending signed device log (`CPDLV001`) is treated as **routine** and **does NOT reset peer master-key verification** (SAS/QR trust). Every other signature or key change remains blocking.

## Rationale

Routine seven-day signed prekey rotation (`spk` and `pq_spk`) necessarily changes `cross_sig` and increments `bundle_version`. Requiring users to re-verify safety numbers out-of-band every week would make safe prekey rotation unusable and induce warning fatigue.

## Constraints and Open Gates

- Implemented across [PrekeyMaintenanceService](../../../lib/features/devices/application/prekey_maintenance_service.dart), [VerifiedRotationDeviceLog](../../../lib/features/devices/infrastructure/verified_rotation_device_log.dart), and peer bundle verification in `native/crypto_core/src/`.
- Superseded private signed prekeys are retained for 8 days (matching the 7-day envelope TTL + 1 day), or longer while a held unverified-sender initial envelope may still need them (ADR-093 D6/D17).
- Under ADR-095, scheduled prekey maintenance runs inside the sync cycle/background catch-up so devices actually rotate on the 7-day cadence.
- Open gate: Independent cryptographic review under [ADR-017](017-independent-crypto-review.md).

## Costs

- Peer verification state machines must check exact monotonic `bundle_version`, unchanged `ik_pub`, valid signatures, and extending device-log continuity rather than treating any `cross_sig` change as a trust reset.

## Reversal Trigger

Only if device-bundle signing or key-continuity semantics change in a future protocol version.

## History, Amendments, and Supersession

- **2026-07-29 (`d0092ee9`):** Original decision added to the register (`Accepted`).
- **2026-10-08 (ADR-093 D6/D17 & ADR-095):** Guarded retired signed-prekey pruning by earliest held-envelope day and scheduled maintenance execution inside the delivery cycle.
- No supersession.
