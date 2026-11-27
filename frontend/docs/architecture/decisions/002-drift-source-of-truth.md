# ADR-002: Drift is the local source of truth

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-001](001-feature-first-architecture.md), [ADR-003](003-riverpod-composition.md), [ADR-007](007-flyer-timeline.md), [ADR-019](019-durable-fan-out.md)

## Decision (Position)

**Drift is the durable local source of truth** for application, synchronization, and cryptographic state.

1. REST responses, WebSocket events, user commands, crypto results, and background work may modify UI-visible state only through repository adapters executing Drift transactions.
2. Incoming envelopes are decrypted, validated, applied, and marked processed inside one Drift transaction before acknowledgement.
3. Outbound sends commit the logical event and durable work (`pending_send_preparations` / `outbox_operations`) in Drift; widgets observe Drift-backed Riverpod streams and never merge REST, socket, and optimistic lists in memory.
4. On Android, SQLCipher (`sqlite3` with `source: sqlcipher` in [pubspec.yaml](../../../pubspec.yaml)) backs Drift (`drift: 2.34.2`, `drift_flutter: 0.3.1`), with the database key wrapped by an Android Keystore AES key and excluded from backup.

## Rationale

Prevents REST, WebSocket, and optimistic UI state from diverging in widgets and guarantees crash-safe, single-transaction persistence across foreground and background catch-up work.

## Constraints and Open Gates

- Defined in [Architecture](../../architecture.md) and [Local data model](../../local-data-model.md); implemented in [local_database.dart](../../../lib/features/local_storage/infrastructure/database/local_database.dart) (currently at `currentSchemaVersion = 26`).
- Open gates: None for the Drift choice itself; database schema/index performance and incremental projection behavior are refined in ADR-062 and ADR-063, and `allowBackup="false"` / non-exportable Keystore protection mean uninstalling or erasing data permanently deletes local history ([ADR-028](028-device-history-transfer.md)).

## Costs

- Schema changes require explicit Drift migrations and generated code (`drift_dev: 2.34.0`, `build_runner: 2.15.1`).
- Every page read under SQLCipher incurs page decryption cost, requiring explicit query indexing and `EXPLAIN QUERY PLAN` verification (ADR-062, ADR-063).
- Incompatible with widget packages that demand mutable controller-owned message state (which drove the replacement of Flyer Chat in [ADR-007](007-flyer-timeline.md) / ADR-066).

## Reversal Trigger

If Drift or SQLCipher cannot support required local storage semantics, multi-isolate database access, or query latency within target Android frame budgets after indexing.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-08-24 / 2026-08-30 (ADR-054, ADR-066):** Reaffirmed as the architectural constraint that ruled out Flyer Chat's mutable `ChatController` ([ADR-007](007-flyer-timeline.md)).
- No supersession.
