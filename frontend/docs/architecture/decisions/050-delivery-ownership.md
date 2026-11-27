# ADR-050: Entry-point delivery ownership gate, stand-down handshake, and singleton upsert fix

- **Status:** Accepted (Decision C's bounded rotation-race wait deleted by ADR-068 on 2026-09-08 and `SessionTokenStore.readDurable` deleted by ADR-083 on 2026-10-07 after server ADR-0023 retired rotating refresh tokens; Decisions A, B, and correction D remain in force for duplicate-envelope exclusion and singleton DB writes; extended to three owners by [ADR-051](051-sustained-delivery.md))
- **Date:** 2026-08-22 (explicitly recorded in register and full section; implemented in `3e77ba8` and documented in `ff2bb3f`)
- **Amends / Corrects:** [ADR-049](049-background-catch-up.md) (fixes ownership gate placement and displacement; independently reaffirms rejection of [ADR-046](046-layered-delivery.md)'s durable Drift lease)
- **Related:** [ADR-046](046-layered-delivery.md), [ADR-047](047-networking-composition.md), [ADR-048](048-generic-notifications.md), [ADR-049](049-background-catch-up.md), [ADR-051](051-sustained-delivery.md)

## Decision (Position)

Corrects [ADR-049](049-background-catch-up.md)'s ownership arbitration after tracing the composed application revealed that `MessageDeliverySession.compose` ran *after* `AuthenticationController.restore()` had already opened protected storage and rotated the shared refresh token (while `message_delivery_composition_test.dart` masked this using a fake restore, and [sync-engine.md](../../sync-engine.md) still contradicted itself by referencing ADR-046's removed durable lease):

1. **Decision A — Entry-point ownership gate in [bootstrap.dart](../../../lib/app/bootstrap.dart):**
   - `bootstrap()` awaits `DeliveryOwnershipGate().awaitExclusiveOwnership()` *before* `ApplicationRuntime.create(...)`, before protected storage opens, before any token is read, and before `runApp(...)`.
   - The secondary `awaitExclusiveOwnership()` inside `MessageDeliverySession.compose` ([message_delivery.dart](../../../lib/app/dependencies/message_delivery.dart)) remains as an instant check when no background run is active.
2. **Decision B — Asymmetric foreground-wins stand-down handshake:**
   - Because a background catch-up only exists when nobody is looking, `BackgroundDelivery.attachForeground` (invoked in `MainActivity.configureFlutterEngine` before the foreground Dart entrypoint runs) invokes `standDown` on any active headless engine's channel.
   - `DeferredCatchUpHandshake` implements `DeliveryStandDownSignal`, which `DurableSyncEngine` inspects between units of work (before each envelope inspection, drain page, and outbox batch).
   - A displaced catch-up finishes its active Drift transaction, returns `DeferredCatchUpOutcome.displaced`, skips its alert reconciliation pass (leaving the shade to the foreground's `MessageAlertController`), and terminates cleanly without abandoning an FFI call or DB transaction part-way.
   - Bounded waits prevent permanent delivery wedging (`20 s` at `bootstrap()`, `5 min` at `MessageDeliverySession`, `4 min` headless engine timeout, `2 min` foreground tick timeout); every bound expires into proceeding (or safe refusal at session) with **zero durable coordinating state**.
3. **Decision C — Refresh-token rotation race repair *(historical; deleted by ADR-068 & ADR-083)*:**
   - Added `SessionTokenStore.readDurable()` so `TokenCoordinator` checked the shared durable row before persisting on success and, on `401 invalid_token` / `token_not_valid` (never `token_revoked`), polled up to a bounded iteration count (`40 × 25 ms`, never wall clock) for a co-owner's newer token instead of clearing the session; exhausting the budget while the row moved returned a transient failure.
   - *Deleted in two steps:* ADR-068 (2026-09-08) removed the wait and retry budget and ADR-083 (2026-10-07) removed `SessionTokenStore.readDurable` after server ADR-0023 replaced rotating refresh tokens with a single renewable session token.
4. **Decision D — Pre-existing singleton-row `CHECK` defect fix:**
   - Explicitly passed `singletonId: const Value(1)` in `account_session` (`SecureSessionTokenAdapter._writeFullSession`) and `account_identity` (`drift_enrollment_journal_store.dart`) upserts. Without it, SQLite treated `INTEGER` primary key `singleton_id` as a rowid alias (`max(rowid) + 1`), bypassing `DEFAULT 1` and throwing `SqliteException(275)` on every write after the first.

## Rationale

- **Verified runtime model (read 2026-08-22 at pinned Flutter `84fc5cbb22` / Flutter 3.44.7, `drift_flutter` 0.3.1, `drift` 2.34.2):**
  - `DartVMRef::Create` (`dart_vm_lifecycle.cc`) enforces one Dart VM per process and one VM-wide `IsolateNameServer`.
  - `drift_flutter` (`shareAcrossIsolates: true`) connects both root isolates to one `DriftIsolate` database server and one SQLCipher file.
  - `drift`'s `_StatementBasedTransactionExecutor` serializes write transactions across clients, ensuring atomic commits, but does **not** protect multi-step I/O operations spanning transactions (claim envelope → decrypt/ratchet → commit, or read token → network renew → write token).
- **Alternatives rejected:**
  - *Keep ADR-049 unchanged:* Leaves `restore()` outside the gate.
  - *Reinstate ADR-046 durable Drift lease:* All owners share one OS process so they die together; a durable lease adds clocks, periodic encrypted-DB heartbeats, stale-holder lockouts after crashes, and fails when `onStopJob` destroys a headless engine inside a surviving process (where the Kotlin arbiter directly owns engine teardown and releases waiters in the same call).
  - *Dart `IsolateNameServer` lock:* `FlutterEngine.destroy()` abruptly kills the isolate and leaves the name registered, requiring timeout ping recovery.
  - *Kill headless run immediately / let foreground wait for full 100-page drain / protect token only:* Risk abandoning native crypto FFI calls, blocking app launch on an entire drain, or corrupting ratchet/post-inbox state (`beginNextEnvelopeInspection` re-offers `inspecting` rows).
- **Evidence:** Host contention test ([delivery_owner_contention_test.dart](../../../test/features/networking/delivery_owner_contention_test.dart)) proved two real isolates over one SQLCipher store in both orderings and under repeated contention; `LocalDatabase` reproduction proved the `singletonId` fix on repeated writes.

## Constraints and Open Gates

- **Single-process invariant:** [background_delivery_policy_test.dart](../../../test/architecture/background_delivery_policy_test.dart) continues to forbid `android:process` in [AndroidManifest.xml](../../../android/app/src/main/AndroidManifest.xml); introducing a second OS process would invalidate in-process arbitration.
- **Discharged follow-up — Layer 2 third owner:** Follow-up item 3 required re-deriving arbitration if Layer 2 shipped; discharged on 2026-08-22 by [ADR-051](051-sustained-delivery.md) (ranking activity > sustained service > deferred catch-up on the same main looper with zero durable state).
- **Remaining minor follow-up:** `DriftSyncStore._ensureCheckpoint` still omits `singletonId` and relies on `INSERT OR IGNORE` swallowing the `CHECK` violation (harmless unless insert mode changes).
- **Unverified on hardware:** Kotlin arbiter one-looper behavior, `standDown` channel delivery, headless teardown under `onStopJob`/Doze quotas, and end-to-end repeated token renewal on a real Android device remain unrun on hardware ([STATUS.md](../../STATUS.md#presence-voice-and-delivery)).
- **Disclosure unchanged:** ADR-050 kept `DeploymentDisclosure.revision` at 3 because delivery tiers did not change.

## Costs

- Foreground startup waits up to one unit of engine work (one envelope inspection, one drain page, or one outbox batch — bounded by the 20 s gate / 4 min engine timeout) if a headless catch-up is mid-step at launch.
- Until ADR-068 retired rotating tokens, a genuinely ended session waited ~1 s (`40 × 25 ms`) before signing out.

## Reversal Trigger

Reopen if the manifest ever introduces `android:process`, if Flutter changes the single-Dart-VM-per-process invariant or `drift_flutter` stops sharing one DB server across isolates, if a fourth delivery owner is added, or if any wait in the arbiter becomes unbounded or durable.

## History, Amendments, and Supersession

- **2026-08-22 (`3e77ba8`, `ff2bb3f`):** Recorded ADR-050 (`Accepted`), moving the ownership gate to `bootstrap()`, adding `DeliveryStandDownSignal`, adding Decision C's rotation-race repair, and fixing `singletonId` upserts.
- **2026-08-22 ([ADR-051](051-sustained-delivery.md)):** Extended main-looper arbitration to three owners (activity > sustained service > deferred catch-up).
- **2026-09-08 (ADR-068) & 2026-10-07 (ADR-083):** Deleted Decision C's bounded wait and `SessionTokenStore.readDurable` after server ADR-0023 retired rotating refresh tokens; retained Decisions A, B, and D for envelope-inspection exclusion and singleton writes.
