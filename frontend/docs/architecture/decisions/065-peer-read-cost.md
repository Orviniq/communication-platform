# ADR-065: Delivery-cycle peer read cost and deferred device-log gossip

- **Status:** Accepted; peer cache (D1–D5) superseded by ADR-082 (2026-10-06); gossip deferral (D6–D7) stands
- **Date:** 2026-08-28 (explicitly recorded in register and full section; implemented and documented in `3991a440`)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-049](049-background-catch-up.md), [ADR-050](050-delivery-ownership.md), [ADR-060](060-delivery-latency.md), [ADR-061](061-durable-send.md), [ADR-062](062-timeline-window.md), [ADR-063](063-event-projection.md), [ADR-064](064-incremental-rebuild.md), ADR-080, ADR-082

## Decision (Position)

Closed the remaining two root-cause findings (F6 and F7) from the delivery-latency investigation opened in [ADR-060](060-delivery-latency.md) across contacts, devices, and synchronization composition without changing schema 18, wire contracts, cryptography, or `backend/` files:

1. **D1–D5 — 30-second process-local `PeerIdentityRemotePort` cache *(superseded 2026-10-06 by ADR-082)*:**
   - Wrapped `DioContactRepository` with `PeerIdentityRoundTripCache` (implemented at `3991a440`, deleted in `083dc5c5` under ADR-082) below `ClientAuthenticationService` rather than memoizing `AuthenticatedPeer` above it, so every cache hit still ran the master-key check, unsigned-device rejection, `_isValidDeviceTransition`, hash-chain/sequence verification, `requireCurrentLiveSet`, pending-window rules, trust states, and global fork gate.
   - Cached identity responses by `userId` and device responses by `(userId, ETag)` in process memory for 30 s (matching one delivery cycle; negative results never cached).
   - Excluded `claimPrekeyBundles` structurally (`ReplaySafety.never`, zero cache lookup or coalescing); forced `refreshPeer` and `confirmOutOfBand` live via `PeerResolutionCachePort.live` (keeping `NoPeerResolutionCache` as default for `ClientAuthenticationService` tests); and coalesced in-flight `fetchDeviceLog` calls without storing pages so stale pages could not manufacture false `deviceLogFork` alerts.
   - *Why superseded:* ADR-080 (`011b4705`) replaced per-user fan-out polling with batched `POST /api/v1/peers`, and ADR-082 (`083dc5c5` / `05c6ab59`) added conditional `ETag`/`If-None-Match` reads on `/identity` and deleted the peer cache so every resolution asks the server against current state.
2. **D6 — Device-log gossip becomes a cycle-paid debt (`onPreparedForPeer`, `OwedDeviceLogGossip`, `DeviceLogGossipPostInboxWork`):**
   - Replaced `PairwiseSendPreparationAdapter`'s awaited `Future<void> Function(String) afterSuccessfulQueue` with a synchronous `void Function(String) onPreparedForPeer` recorded into the in-memory `OwedDeviceLogGossip` set ([owed_device_log_gossip.dart](../../../lib/features/devices/application/owed_device_log_gossip.dart)), so preparation completes as soon as the send's own ciphertext is durable.
   - `DeviceLogGossipPostInboxWork` ([device_log_gossip_coordinator.dart](../../../lib/features/devices/infrastructure/device_log_gossip_coordinator.dart)) runs last inside `_CompositePostInboxWork` — after the first outbox flush (preserving [ADR-060](060-delivery-latency.md)'s rule that user sends precede peer maintenance) and after the inbox commits (so gossip advertises device-log heads just learned in the same cycle, with queued gossip sealed and sent on the cycle's second pass).
   - Gossip failure isolation is structural via the `void` callback (replacing a swallowed `try`/`catch`); coalesces within one cycle via the owed set and across cycles via a one-minute window ([sync-engine.md](../../sync-engine.md#cycle-order)).
3. **D7 — Synchronous cycle accounting over `unawaited` futures ([owed_gossip_lifetime_test.dart](../../../test/features/synchronization/owed_gossip_lifetime_test.dart), [pairwise_send_preparation_adapter_test.dart](../../../test/features/messaging/pairwise_send_preparation_adapter_test.dart)):**
   - Rejected `unawaited(gossip(peer))` because headless background catch-up ([ADR-049](049-background-catch-up.md), [ADR-050](050-delivery-ownership.md)) disposes its `ProviderContainer` and closes the database as soon as `synchronize()` returns; all owed gossip begins and completes inside `synchronize()`.

## Rationale

- `ClientAuthenticationService` originally resolved peer and own identities unconditionally on every preparation, prekey claim, and immediate gossip round against 107–137 ms real HTTP round trips, while `await`-ing gossip placed a second fan-out in front of posting the user's already-sealed message.
- Coupling cache reuse (later superseded by server `ETag` support and `POST /api/v1/peers`) with post-outbox gossip execution halved `prepare`-to-postable-ciphertext latency while preserving crash-safe cycle lifetimes.

## Constraints and Open Gates

- **Scope:** Local schema remained at 18; changed no endpoint, header, status code, cryptographic construction, or `backend/` file; opened no production gate.
- **Historical host measurements (at `3991a440`, synthetic 122 ms round-trip harness over `PeerIdentityRoundTripCache`):**
  - Established conversation send: 4 round trips / 521 ms → 4 / 497 ms.
  - Session-establishing send: 7 / 874 ms → 5 / 619 ms.
  - Send + owed gossip: 8 / 1051 ms → 4 / 528 ms.
  - First contact + owed gossip: 14 / 1828 ms → 6 / 788 ms.
  - Two sends to one peer in one cycle: 8 / 1037 ms → 4 / 522 ms.
  - `prepare` start → postable ciphertext (F7 alone): 8 / 1028 ms → 4 / 512 ms.
- **Explicitly left undone at ADR-065:** Claim-path re-verification from cached bytes, per-container cache scope, skipping own-account verification, cross-peer gossip batching, on-device field timing, and adaptive gossip window.

## Costs

- While active, the 30 s cache could delay observing an unannounced peer device revocation/addition by up to 30 s (removed by ADR-082).
- Gossip across multiple peers within one cycle still produces one fan-out per peer and uses a fixed 1-minute cross-cycle window.

## Reversal Trigger

Peer cache (D1–D5) already triggered and superseded by ADR-080 / ADR-082 (2026-10-06). Reopen D6–D7 if cross-peer gossip batching or an adaptive gossip cadence becomes necessary, or if cycle lifetime guarantees change.

## History, Amendments, and Supersession

- **2026-08-28 (`3991a440`):** Recorded and implemented ADR-065 (`Accepted`), closing the delivery-latency RCA ([ADR-060](060-delivery-latency.md)–[ADR-064](064-incremental-rebuild.md)) with `PeerIdentityRoundTripCache` (later verified by historical `peer_resolution_cache_test.dart`) and cycle-bound `OwedDeviceLogGossip`.
- **2026-10-06 (`011b4705`, `083dc5c5`, `05c6ab59` / ADR-080 & ADR-082):** Superseded D1–D5 and deleted `PeerIdentityRoundTripCache` and `peer_resolution_cache_test.dart` once `POST /api/v1/peers` and `/identity` `ETag`/`If-None-Match` landed; D6–D7 remain in force.
