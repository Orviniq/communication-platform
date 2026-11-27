# ADR-012: Local-only search

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-028](028-device-history-transfer.md)

## Decision (Position)

All conversation and message search executes **strictly locally** against the encrypted local Drift/SQLCipher database. The server never receives message plaintext, search indexes, or search queries.

## Rationale

Preserves end-to-end confidentiality against an untrusted relay server; the backend stores no plaintext or search index.

## Constraints and Open Gates

- Implemented in [chats_search_page.dart](../../../lib/features/messaging/presentation/chats_search_page.dart), [chats_search.dart](../../../lib/features/messaging/presentation/chats_search.dart), and [conversation_search.dart](../../../lib/features/messaging/presentation/conversation_search.dart), verified by [chats_search_test.dart](../../../test/features/messaging/chats_search_test.dart) ([Frontend status](../../STATUS.md#platform-identity-and-content)).
- Search scope is bounded by what exists on the local device ([ADR-028](028-device-history-transfer.md)).
- Under ADR-057, local search uses one shared query/projection path over SQLCipher rather than a separate unencrypted or FTS index outside Drift.
- Open gates: None for the local-only constraint; accessibility and representative-data performance checks remain part of release readiness.

## Costs

- A newly enrolled device without device-to-device history transfer cannot search prior messages.
- Search speed is bounded by local SQLCipher query execution rather than server-side inverted indexes.

## Reversal Trigger

None compatible with the current threat model (`docs/security/SECURITY.md`), which forbids server-side plaintext or search-term visibility.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-08-25 (ADR-057, `d344d8aa`):** Delivered Piece 21 local search (Chats search and in-conversation search) and updated disclosure/tier records (originally amending ADR-044's unbuilt tier).
- No supersession.
