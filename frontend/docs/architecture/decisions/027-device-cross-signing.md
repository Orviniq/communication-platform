# ADR-027: Account cross-signing and client-signed device log authenticate devices

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `7e4930f8`, 2026-07-25)
- **Related:** [ADR-021](021-profile-fallback.md), [ADR-025](025-hybrid-pqxdh.md), [ADR-030](030-recovery-key-material.md), [ADR-035](035-prekey-rotation.md)

## Decision (Position)

Devices are authenticated client-side via **account cross-signing** (Ed25519 master, self-signing, and user-signing keys) and a **client-signed hash-chained device log** (`CPDLV001`), never by trusting the server's device directory alone.

1. The master key signs `chat:v1:cross-signing-keys` over `(user_id, self_signing_pub, user_signing_pub)`.
2. The self-signing key signs each device's canonical `chat:v1:device-bundle` (`cross_sig`) and signs each 256-byte `CPDLV001` record (`chat:v1:device-log-record`) committing to the `SHA-256` hash of the sorted canonical live-device set (`chat:v1:device-set`), previous record hash, sequence, and identity version.
3. Peers verify `master_sig`, `cross_sig`, prekey signatures, and the device log against their out-of-band-confirmed peer master key (`CP-SAFETY-V1` / `chat:v1:user-signing-attestation`) before encrypting to or accepting messages from a device; no TOFU acceptance is permitted.
4. Unsigned devices, invalid cross-signatures, unverified master-key changes, and device-log forks block messaging or quarantine as appropriate.

## Rationale

Prevents a hostile or compromised server from silently injecting an unsigned device or substituting an account's identity keys without client detection.

## Constraints and Open Gates

- Defined in [Cryptographic protocol](../../cryptographic-protocol.md#account-cross-signing-identity) and [Authentication and devices](../../authentication-and-devices.md).
- Extended by [ADR-035](035-prekey-rotation.md) (monotonic `bundle_version + 1` prekey rotation), ADR-080 (`POST /api/v1/peers` fan-out resolution), ADR-081 (an unsigned peer device as listed by the server), ADR-082 (server resolution on every send), and ADR-084 (a device not yet covered by the log is `pending`, not a fork).
- Open gates:
  - Independent cryptographic review under [ADR-017](017-independent-crypto-review.md).
  - [Frontend status](../../STATUS.md#platform-identity-and-content) notes that mutual verification (`CP-CONTACT-V1`, `MUTUAL` direct-content gate, and encrypted own-device contact/trust sync under `docs/client/CLIENT_CONTACTS_AND_TRUST.md` §§3–7) remains required before release.

## Costs

- Two-phase device enrollment (`POST /me/devices`, then `PUT /me/devices/{device_id}/prekeys` + `CPDLV001` append), serialized log appends, and device-log gossip overhead (ADR-065).
- Unverified peers or pending/forked devices cannot exchange encrypted messages until resolved.

## Reversal Trigger

None compatible with end-to-end device authentication against an untrusted server (`docs/security/SECURITY.md`).

## History, Amendments, and Supersession

- **2026-07-25 (`7e4930f8`):** Original decision added to the register (`Accepted`).
- **2026-07-29 (`d0092ee9`):** Supplemented by [ADR-035](035-prekey-rotation.md) for routine prekey rotation continuity.
- **2026-10-06 – 2026-10-07:** Refined in ADR-080, ADR-081, ADR-082, and ADR-084 for peer list resolution, unsigned devices, and pending-log devices.
- No supersession.
