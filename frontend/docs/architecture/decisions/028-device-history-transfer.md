# ADR-028: History exists only on clients and transfers device-to-device

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `7e4930f8`, 2026-07-25)
- **Supersedes (with [ADR-030](030-recovery-key-material.md)):** [ADR-022](022-history-recovery.md)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-012](012-local-search.md), [ADR-030](030-recovery-key-material.md)

## Decision (Position)

Message history exists **only on enrolled client devices** and transfers **device-to-device** from an existing online device (`history_transfers` manifests over pairwise encrypted envelopes), never from a server archive.

1. Users MUST be honestly informed — both in the mandatory enrollment security notice (`DeploymentDisclosure.deviceOnlyHistory` and `DeploymentDisclosure.recoveryExcludesHistory` in [deployment_disclosure.dart](../../../lib/app/config/deployment_disclosure.dart)) and in device-linking UX — that erasing all devices or losing access to an existing online device permanently loses local history.
2. History transfer moves message content only; it does not transfer ratchet session state or serve as a substitute for queue-gap group state recovery ([Synchronization engine](../../sync-engine.md#queue-gap-recovery)).

## Rationale

Matches the backend's removal of server-side history storage and communicates the online existing-device dependency honestly to users.

## Constraints and Open Gates

- Defined in [Local data model](../../local-data-model.md) and [DeploymentDisclosure](../../../lib/app/config/deployment_disclosure.dart); Android `android:allowBackup="false"` and non-exportable AndroidKeyStore key wrapping prevent OS backup extraction.
- Open gate: [Frontend status](../../STATUS.md#platform-identity-and-content) records that implementing the required encrypted contact, block, trust, and profile-key snapshot in device-to-device history transfer (`docs/client/CLIENT_CONTRACT.md`, `docs/client/CLIENT_CONTACTS_AND_TRUST.md`) remains an open contract gap.

## Costs

- If a user loses all existing devices (or uninstalls their sole device), no message history can be recovered even with a valid identity recovery secret ([ADR-030](030-recovery-key-material.md)).
- History transfer requires another enrolled device to be online and authenticated to stream encrypted manifests/chunks.

## Reversal Trigger

Would require a server-side encrypted history backup architecture, which is excluded by the current server design and threat model.

## History, Amendments, and Supersession

- **2026-07-25 (`7e4930f8`):** Original decision added to the register (`Accepted`), superseding [ADR-022](022-history-recovery.md) alongside [ADR-030](030-recovery-key-material.md).
- **2026-08-20 – 2026-08-23 (ADR-045, ADR-052):** Codified in `DeploymentDisclosure.deviceOnlyHistory` (narrowed at revision 5 to "no copy of your history") and `DeploymentDisclosure.recoveryExcludesHistory`.
- No supersession.
