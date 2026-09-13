# Local data model

## Principle

Drift is the durable source of truth. REST, WebSocket, user commands, crypto results, and
background work may modify UI-visible state only through repositories that execute Drift
transactions. Riverpod observes database queries and exposes immutable projections.

## Storage classes

### Android

Use SQLite encryption with a random database key. Wrap that key with an Android Keystore
AES key, preferring hardware-backed storage when available. Exclude the database,
wrapping material, attachments, and key files from Android backup. Plaintext may exist
inside the unlocked encrypted database and process memory, never in ordinary files.

### Web (post-v1)

Persist device state and content only as encrypted records. Store a non-extractable
WebCrypto wrapping key in IndexedDB when supported and wrap the local storage key. Drift
Wasm may store ciphertext/index metadata, but decrypted message bodies and the search
index remain memory-only and are cleared on logout/page teardown as far as the browser
allows. Same-origin malicious code remains an acknowledged limit.

## Logical tables

Names are conceptual; migrations may refine physical layout without changing ownership.

| Table | Purpose |
|---|---|
| `account_session` | Current user/device IDs, scope, token metadata, server profile |
| `enrollment_intents` | Resumable first/later-device phase, generated opaque device/identity state, assigned device ID, backup, and exact pending device-log append |
| `secure_secrets` | Wrapped cross-signing/device/PQ/storage key handles; never raw loggable bytes |
| `account_identity` | Verified master/self/user-signing public state, backup version, recovery status |
| `users` | Activated directory entries and local presentation state |
| `profiles` | Encrypted/decrypted profile cache, version, verification state |
| `devices` | Own and peer public bundles, ETags, labels, revocation state |
| `device_log` | Verified signed hash-chain records, last head/hash, fork state, gossip state |
| `pairwise_sessions` | Opaque crypto-core Double Ratchet state per device pair |
| `prekeys` | Local private prekey handles and upload/use state |
| `mls_groups` | Accepted epoch, control revision/hash, lifecycle/quarantine state, and pending mutation CAS marker |
| `group_control_events` | Deterministic accepted control projection, exact signed-control payload, and signer Authentication Service proof |
| `group_outbound_objects` | Exact prepared opaque group object and send-readiness state; piece 18 never marks development preview data production-ready |
| `conversations` | DM/group/saved identity and list projection |
| `memberships` | Decrypted current group roles/policy projection |
| `messages` | Current logical message projection, plus the columns the projector preserves rather than rebuilds: `deleted_for_me`, `pinned`, `starred`, `unread`, `alerted` (the durable one-shot marker that stops an arrival being announced twice, ADR-048), `delivered_receipt_sent` ([ADR-060](decisions.md)), and `status` ([ADR-061](decisions.md)) |
| `message_events` | Immutable create/edit/delete/reaction/control facts |
| `application_event_targets` | Which logical messages each stored event is a fact about: one row per (message, event) pair, one for a create or a mutation and one per named id for a receipt. Derived state and only an index — the authoritative fact is the event, and every read joins back to it, so a stale row matches nothing. It is what lets an apply re-fold the messages an event touches instead of the conversation it is in ([ADR-063](decisions.md)) |
| `attachments` | Encrypted descriptor, transfer state, bounded cache handle |
| `inbox_envelopes` | Backend envelope ID/seq, processing and ack state |
| `outbox_operations` | Durable logical sends, deterministic <=256-target batches, and per-recipient attempts/ciphertext. Authoritative for a message's transport state |
| `pending_send_preparations` | Sends whose event is committed and whose per-recipient ciphertext is still owed: audience, attempt count and due time, keyed by the same operation id as the payload in `pairwise_local_applications`. A row exists while the fan-out is owed and is deleted in the transaction that writes the outbox rows; a terminally failed one is kept, because it is the only durable record that a visible message has no route to the wire ([ADR-061](decisions.md)) |
| `receipts` | Per-message/device/user delivered/read projection |
| `voice_rooms` | Local room capability, encrypted metadata, live state |
| `history_transfers` | Device-to-device content transfer manifests, event progress, source completeness |
| `sync_checkpoint` | Highest contiguous acked seq, `pruned_through`, ETags, retry state, protocol version |
| `local_preferences` | Theme and language (`appearance.theme.v1`, `appearance.language.v1`), mute, pin, star, preview policy, the accepted disclosure revision, and whether the notification permission prompt has ever been shown. Client-only display values live here rather than in a plain file so that the logout wipe, which destroys the database key, destroys them too |
| `quarantine` | Bounded metadata about rejected input; never plaintext or raw secrets |

## Indexes

The schema declared no indexes at all until version 17, so every lookup by a column that was
not the leading component of a primary key was a full table scan — under SQLCipher, where each
page read is a decrypt. Each is chosen from `EXPLAIN QUERY PLAN` against a seeded database and
asserted against the planner in
`test/features/local_storage/infrastructure/local_database_index_plan_test.dart`, because an
index the planner never chooses is write cost with no read benefit ([ADR-062](decisions.md)) —
and because on a join the planner also chooses the *order*, which changes the cost by a factor
of the conversation's length while changing neither the statement count nor the rows returned
([ADR-063](decisions.md)).

| Index | Columns | What it answers |
|---|---|---|
| `messages_conversation_ordering` | `messages (conversation_id, ordering_ms, ordering_event_id, message_id)` | Every read of one conversation. Column order follows the timeline's own ordering key, so the same index answers the `WHERE`, satisfies the `ORDER BY` in both directions without a temporary B-tree, and covers the keyset cursor probe |
| `messages_pinned_by_conversation` | `messages (conversation_id, message_id) WHERE pinned` | The conversation's pins, and every conversation's pins in one query. Partial, so it holds a handful of entries; SQLite will only choose it for a query whose `WHERE` contains the bare term `pinned`, so both callers spell it unbound and neither sorts in SQL |
| `attachments_by_message` | `attachments (message_id)` | A page's attachments — and, on the write path, the `ON DELETE CASCADE` foreign-key check SQLite runs on **every** write to a `messages` row. Without it that check is a full scan of `attachments` per parent row |
| `application_events_conversation_apply_state` | `application_events (conversation_id, apply_state)` | The candidate events of one conversation, for a **projection rebuild**. Since [ADR-063](decisions.md) that is the recovery path — an event-id conflict, a sender-counter rollback, an unsupported-event collision, a fork or a repair — and not the event path, which reads `application_event_targets` instead. It stays indexed because a fork is exactly when a device can least afford to read its whole log |
| `application_events_sender_counter` | `application_events (sender_device_id, sender_counter)` | The sender-counter uniqueness check every applied event runs. It has no conversation to narrow it: a replayed counter is a fact about a device |
| `outbox_operations_by_event` | `outbox_operations (event_id)` | A message's transport state |
| `messages_unread_by_conversation` | `messages (conversation_id, unread) WHERE unread` | `conversations.unread_count`, which both projection paths recompute from the message rows so that the incremental one cannot disagree with a rebuild. Partial, so it holds only unread rows; `unread` is a column as well as the predicate, which is what makes it covering — without it SQLite keeps the query's own `unread` term as a filter and visits every row to evaluate it. Like the pinned index it is only chosen for a query whose `WHERE` spells the bare term ([ADR-063](decisions.md)) |

`message_reactions` and `receipts` are keyed by `(message_id, ...)`, so their implicit primary-key
index already serves a lookup by message and no index is added for them.
`application_event_targets` is keyed by `(message_id, event_id)` for the same reason: its
implicit index answers the only question asked of it, and no foreign key is declared, because
`event_id` would then be an unindexed child key and SQLite would scan the table on every write
to `application_events`.
`unsupported_application_events` runs the same sender-counter check and is empty on a client at
the current protocol version, so it is deliberately left unindexed.

## The conversation window

`ConversationRepositoryPort.watchMessages` returns a **bounded page**, not the conversation.

- The window is a range over `(ordering_ms, ordering_event_id, message_id)`: the newest *n*
  for the first read, and an open-ended range anchored at the oldest loaded message for every
  read after it. Anchoring at the bottom is what lets a message arriving at the top join the
  window without displacing the message at the other end of it.
- Paging backwards resolves the next lower bound by key (`olderMessageCursor`), which reads
  that page and nothing before it. `OFFSET` is not used: it re-scans what it skips.
- One emission is a fixed six statements whatever the conversation's length — the page,
  whether anything older exists, the page's reactions, receipts and attachments as three
  set-based reads, and the conversation's pins. `test/features/messaging/local_read_cost_test.dart`
  asserts these as equalities across two conversation lengths.
- The pins on the page are **complete for the conversation**, not page-scoped, because the
  surface that lists them also counts them.
- A jump to a message outside the window (`messageCursor`, then `reveal`) opens the window far
  enough back to contain it, with a page of context below it.

## Identity and uniqueness

- `event_id` and logical `message_id` are globally unique random IDs.
- Backend envelope IDs are unique inbox keys.
- Applying the same event more than once is a no-op.
- Outbox uniqueness includes logical operation and recipient device, so a refreshed
  device list can add work without duplicating accepted recipients.
- Each target persists the exact encrypted blob until terminal acceptance/staleness so an
  ambiguous retry cannot advance the Double Ratchet a second time.
- Database constraints enforce uniqueness; application pre-checks alone are insufficient.

## Transaction boundaries

### Send

**Two transactions, and the request between them is what makes that safe.** The first —
the local echo — writes the logical event, the opaque payload, a `pending_send_preparations`
row, and the message projection. It touches no network, so the message is on the timeline
at the speed of a local write. The second, run by the delivery cycle after it has resolved
the recipient set and sealed one envelope per device, writes the outbox rows and deletes
the preparation row *in the same transaction*. A process killed anywhere between them comes
back to a send that is either owed or queued, never both and never neither
([ADR-061](decisions.md)).

Encryption and network execution still occur outside any database transaction, and the
result is still committed in a second one; what changed is which side of the first
transaction the user's message is on.

A message's transport state is derived from `outbox_operations` when it has rows there and
from `pending_send_preparations` before it does. It is written to `messages.status` at
projection time and updated narrowly on every attempt transition, and a projection rebuild
carries the existing value through rather than re-deriving it — the same rule `alerted`,
`starred` and `delivered_receipt_sent` already follow.

### Receive

One transaction records the envelope, applies a verified event, updates projections,
creates receipts, advances the contiguous sequence checkpoint when allowed, and marks
the envelope ready to acknowledge. The ack is
sent only after commit. A crash before ack causes a safe duplicate.

Applying a verified event re-folds **only the messages that event is a fact about** — one for a
create, an edit, a delete, a reaction or a pin, and one per named id for a receipt — reading
each message's own facts out of `application_event_targets` and writing back through the same
projection function a rebuild uses. The full rebuild remains the definition of a correct
projection and remains the path for an event-id conflict, a sender-counter rollback, an
unsupported-event collision, and any fork or repair; where the two disagree the incremental one
is wrong ([ADR-063](decisions.md)). Both are inside the same write transaction as the event
insert they belong to, so a process killed mid-apply rolls back to a state from which
re-presenting the event converges.

### Device enrollment

Before the registration POST, one encrypted-database transaction persists the flow,
phase, public-key fingerprint, and complete Rust-owned device key package. The POST is
never automatically replayed after an in-flight process death or transport response
loss. Its assigned device ID, full-scope refresh material, and `registeredUnsigned`
journal phase commit in one transaction; an in-flight row observed after restart is
converted to the explicit ambiguous-outcome reconciliation phase.

Every later phase is persisted before its network side effect can be retried. In
particular, the exact device-log record and predicted sequence are durable before
append. Completion atomically moves the opaque device and cross-signing identity
packages to `secure_secrets`, writes the verified local public projections, deletes the
enrollment row and new-account marker, and only then releases the route-level messaging
withhold. The entered recovery secret is never a column. The first-device display
secret exists only inside the encrypted, resumable identity package until explicit
confirmation, after which display material is sanitized and overwritten.

### MLS state

New MLS state, control event, membership projection, conversation projection, and exact
outbound object commit atomically with a control revision/hash compare-and-swap. A
process crash or persistence failure cannot expose a group transition or application
message from an epoch whose complete opaque state was not persisted. Queue gaps and
invalid or concurrent controls move the projection to a blocking quarantine state
without guessing or replacing crypto-core state.

A later closed-beta Welcome transaction additionally consumes the claimed KeyPackage and
stores the complete verified control transcript with the joined opaque state and roster
projection. Transcript rows redundantly preserve the deterministic projection, exact
signed payload, and signer authentication proof so a new device can reconstruct and
cross-check authorization rather than trusting a server-supplied projection.

## Migrations

- Every schema change has forward and rollback/restore tests using representative
  encrypted databases.
- Migrations are transactional where SQLite permits.
- Crypto-format changes are separate from SQL schema changes.
- A failed migration leaves the previous database recoverable and blocks normal startup
  with a non-destructive error.
- Release builds never auto-delete a database to "fix" migration failure.
- Schema version 11 adds nullable deterministic-projection, signed-payload, and signer-
  proof columns to `group_control_events` while preserving older rows. An older row may
  remain readable as local history, but absent cryptographic evidence cannot construct a
  verified v3 Welcome transcript and therefore fails closed. Disposable v2 beta groups
  must be recreated/rejoined; no opaque MLS state is silently rewritten.
- Schema version 14 adds `inbox_envelopes.inspection_failures` and carries a one-shot,
  idempotent repair for the devices that ran the delivery engine before
  [ADR-060](decisions.md): non-terminal inbox and outbox rows are reset to a zero attempt
  count with no due time, a conversation that has messages is un-tombstoned, and a
  conversation whose row is missing entirely is rebuilt minimally from `MAX(ordering_ms)`.
  It touches no message content, no envelope ciphertext and no projection ciphertext, and
  is safe to run twice.
- Schema version 15 adds `messages.delivered_receipt_sent`, a durable one-shot marker in the
  style of `messages.alerted`. Whether a delivered receipt was owed used to be re-derived on
  every projection rebuild from properties of the message that never change, so every rebuild
  re-queued one for every message the conversation had received — and a receipt is an event
  at the far end, so two devices sustained the loop indefinitely ([ADR-060](decisions.md)).
  The upgrade marks every existing message as already acknowledged and empties the pending
  queue, so it does not itself send one more round.

- Schema version 16 adds `pending_send_preparations`, the durable request for a fan-out a
  committed message is still owed ([ADR-061](decisions.md)). Nothing is back-filled and
  nothing is repaired: every message already on a device either has its outbox rows or has
  reached a terminal state, so there is no send this table would have been holding.

- Schema version 17 creates the first six indexes above and does nothing else
  ([ADR-062](decisions.md)). It is additive: no table is created, dropped, re-keyed or
  rewritten, and no row moves. Each declaration carries `IF NOT EXISTS`, so the same statement
  serves `createAll` on a fresh install and the upgrade step on an existing one. It is **not
  free on a populated database**: `CREATE INDEX` reads its whole table once, so this is two
  passes over `messages`, two over `application_events` and one each over `attachments` and
  `outbox_operations`, under SQLCipher where every page read is a decrypt. It is paid once, at
  the first open after the update, alongside the `PRAGMA quick_check` already run at every
  open, and the database file grows by roughly 18%.

- Schema version 18 adds `application_event_targets` and
  `messages_unread_by_conversation`, and **back-fills the first from the events already
  stored** ([ADR-063](decisions.md)). The back-fill is not an optimisation: an empty target
  table would not be a slower projection but a wrong one, because an edit landing on a message
  whose create has no row there would fold the edit alone and find no message to edit. The four
  single-target kinds are one set-based statement; creates and receipts carry their message ids
  inside the projected body, so those are read in keyset pages over the primary key, decoded
  and written back in batches — one pass over `application_events`, of the same order as the
  `CREATE INDEX` statements schema 17 already paid, with a JSON decode on top, and never the
  bodies of a whole event log in memory at once. SQLite's JSON functions are not used: whether
  the SQLCipher build has them is not something to discover during a migration on a phone. Every insert is `INSERT OR IGNORE`, so an
  interrupted upgrade that is retried cannot collide with itself, and a body that cannot be
  decoded is skipped rather than failing the upgrade. No column is added, no table is dropped
  or re-keyed, and no existing row is rewritten. A projection rebuild also rewrites the index
  rows for every fact it folds, so the recovery path repairs an interrupted back-fill.

- Schema version 20 drops `mls_key_package_maintenance_states`. The server deleted MLS and
  its KeyPackage routes, so nothing uploads a KeyPackage and the table's upload bookkeeping
  has no writer and no reader. Only a closed-beta database ever held a row; on every other
  the table was created empty and stayed empty. The step issues `DROP TABLE IF EXISTS`, so a
  database that never had the table upgrades as well, and schema 9 no longer creates it on
  the way.

- Schema version 21 drops `mls_groups.opaque_crypto_state_handle`. The column held each
  group's sealed MLS state, which only the closed-beta core could open, and its one reader
  went with the MLS port. Production never wrote a group row; the closed-beta build and the
  development preview did, and no build can use that state now. The step reads
  `PRAGMA table_info` before it drops, so a database that never had the column upgrades as
  well. The rest of the group row stays.

## Retention and deletion

- Acked raw envelopes are removed after their logical event and local projection are safe.
- Retained pairwise metadata is pruned on a sixteen-day cutoff, **except** the opaque
  payload of a send whose preparation is still owed. Discarding those bytes would leave a
  message on screen that nothing can ever seal.
- Ratchet skipped keys and old MLS states obey strict protocol bounds.
- Decrypted attachment files and thumbnails use bounded LRU caches with explicit expiry.
- Delete-for-me creates a tombstone before cache cleanup.
- Logout/revocation closes handles, deletes the database key, then removes database and
  cache files. Key destruction is the primary cryptographic erasure boundary.

## Search

The encrypted database **is** the index. `messages` holds the decrypted message
projection inside SQLCipher, under the Keystore-wrapped key, and a search is a filter
over rows that are already there. Since [ADR-062](decisions.md) a conversation's stream
carries a window, so an in-conversation search covers that conversation's **loaded** local
history: the filter still reads every row it is given, and what it is given grows as the user
pages backwards. A result outside the window is still reachable, because a jump to a message
loads it first. No separate
index structure is built: it would hold a second copy of every message body, enlarge what
a wipe has to reach, and buy nothing at this scale ([ADR-057](decisions.md)). A future Web
build uses an in-memory index from decrypted session content. Search input and results
never leave the device. Each surface states its own scope.
