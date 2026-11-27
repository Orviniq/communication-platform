# ADR-064: Incremental timeline projection, mounted anchor registry, and debounced drafts

- **Status:** Accepted *(Note: `chat_pages.dart` and `chat_timeline.dart` present at `34dff6e` were later split into [direct_chat_page.dart](../../../lib/features/messaging/presentation/direct_chat_page.dart), [chat_conversation_view.dart](../../../lib/features/messaging/presentation/chat_conversation_view.dart), [chats_list_page.dart](../../../lib/features/messaging/presentation/chats_list_page.dart), [chat_timeline_adapter.dart](../../../lib/features/messaging/presentation/chat_timeline_adapter.dart), and [chat_message_builder.dart](../../../lib/features/messaging/presentation/chat_message_builder.dart))*
- **Date:** 2026-08-28 (explicitly recorded in register and full section; implemented in `34dff6e`, documented in `74df7ca`)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-061](061-durable-send.md), [ADR-062](062-timeline-window.md), [ADR-063](063-event-projection.md), [ADR-065](065-peer-read-cost.md), [ADR-066](066-sliver-timeline.md)

## Decision (Position)

Removed the remaining main-isolate UI rendering and keystroke cascades (findings F8, F9, F10) without altering the schema, repositories, projectors, sync engine, or backend:

1. **D1 — Per-message view-model memoization (`ChatMessageProjection` in [chat_view_model_mapper.dart](../../../lib/features/messaging/presentation/chat_view_model_mapper.dart)):**
   - `_ProjectedConversationPageState` holds `ChatMessageProjection` instances (one for window messages, one for pins) returning identical `ChatMessageViewModel` instances for unchanged rows so `Element.updateChild` skips rebuilding unchanged widgets.
   - Memo key checks every field of `ConversationMessage` (`_sameMessage`) plus positional inputs (`groupedWithPrevious`, `groupedWithNext`, reply target author/text) and capability-matched attachments (failing toward "changed" when unmatchable); cache prunes only when entry count differs from page length.
2. **D2 — Two-generation row cache and keyed element relocation (`_rowWidget`, `findChildIndexCallback`):**
   - Timeline retains built row widgets in a two-generation cache that rolls on entry count (supporting layout-time scroll materialization without adapter rebuilds).
   - Rows carry keys (date headings keyed by the message beneath them so skewed timestamps cannot collide) paired with `findChildIndexCallback` to relocate shifted items on arrival without per-row `GlobalKey` re-parenting; integer day keys avoid per-message `DateTime` construction.
3. **D3 — Narrowed provider subscriptions and mute-expiry clock:**
   - `conversationDraftProvider` is a one-shot read (composer adopts a late draft only if the field is untouched and empty).
   - `typingProjectionsProvider` is watched through `.select` for `anyTyping`; forward targets resolve via callback (`listenManual`) on sheet open so draft writes never rebuild the chat page.
   - Removed `DateTime.now()` from `build`: conversation list refreshes its clock only when the earliest visible mute expires (zero timer when unmuted); Chats search query moved into controller so typing filters without re-mapping conversations.
4. **D4 — Mounted-only reading-anchor registry and jump scheduling ([chat_timeline_adapter.dart](../../../lib/features/messaging/presentation/chat_timeline_adapter.dart)):**
   - Replaced unbounded `_messageKeys` `GlobalKey` map with a mounted-rows registry (`_anchoredRows` in current code), dropping the standing anchor on `ScrollStartNotification` and capturing only in `didUpdateWidget`, `didChangeDependencies`, and `ScrollEndNotification` (never in `build` or per scroll tick).
   - Jumps drop the standing anchor so resize notifications cannot cancel them, schedule a frame when targeting an already-drawn row, estimate landing position using the drawn range's average row height (instead of `88.0`), and run `ensureVisible` after settle.
5. **D5 — 500 ms debounced drafts with five explicit exit flushes:**
   - `_onTextChanged` arms a 500 ms timer while Send button listens to the `TextEditingController` via `ValueListenableBuilder`.
   - Flushes immediately (and idempotently via dirty tracking) on five exits: `FocusNode` blur, `PopScope.onPopInvokedWithResult` (`didPop`), lifecycle leaving `resumed`, `dispose`, and `_submit` post-clear, keeping drafts durable in the `conversations` row ([ui-specification.md](../../ui-specification.md)).

## Rationale

- After ADR-061–063 bounded SQL/projection costs, main-isolate frame costs still scaled with window length because view models were re-allocated wholesale, `GlobalKey` anchor walks grew unboundedly, and every keystroke wrote to `conversations` and rebuilt the entire chat page via watched summaries.

## Constraints and Open Gates

- **Scope:** Presentation and provider layers only; SQLCipher schema stays at 18; opens no production gate.
- **Measured on Galaxy A56 (`SM-A566B`, Android 16, 219-message Saved Messages, temporary `FrameTiming` harness):**
  - Typing 30 chars: build p50/p90/worst **5.25 / 8.13 / 9.89 ms** (55 frames) → **2.33 / 3.76 / 6.57 ms** (38 frames).
  - Message arrival: build **1.77 / 5.02 / 7.49 ms** → **0.82 / 3.23 / 5.97 ms**; scrolling build unchanged (~0.58 ms p50).
- **Measured on host (`flutter test` JIT, 48 vs. 1200 messages):** Arrival frame **19.68 → 36.71 ms** before vs. **13.71 → 10.93 ms** after; keystroke **16.84 → 32.72 ms** before vs. **5.08 → 3.95 ms** after.
- **Test obligations:** [chat_render_cost_test.dart](../../../test/widget/chat_render_cost_test.dart) asserts window-size invariance (2 elements derived on arrival, 1 on reaction, 0 on keystroke across 48 vs. 240); [chat_draft_durability_test.dart](../../../test/widget/chat_draft_durability_test.dart) covers all five flush triggers and late-draft adoption; [chat_pagination_test.dart](../../../test/widget/chat_pagination_test.dart) bounds retained rows/anchors across 300-message scroll and verifies bi-directional reading-line preservation; existing goldens remain byte-identical.
- **Explicitly left undone at ADR-064:** F6/F7 (subsequently fixed in ADR-065), whole-list conversation re-mapping in the conversation list, O(1) `ChatConversationView` scaffold rebuild, >219-message on-device F9 proof, and variable-height jump estimate correction.

## Costs

- Adds memoization equality maintenance (`_sameMessage`) that must be kept aligned with `ConversationMessage` fields so new display properties are not skipped.
- Holds a two-generation widget cache in timeline state and relies on five explicit composer exit hooks to prevent draft loss within the 500 ms debounce window.

## Reversal Trigger

Reopen if `ChatConversationView` O(1) scaffold rebuild becomes a bottleneck, if conversation counts outgrow whole-list summary mapping, or if `ConversationMessage` changes introduce fields without updating `_sameMessage`.

## History, Amendments, and Supersession

- **2026-08-28 (`34dff6e`, `74df7ca`):** Recorded and implemented ADR-064 (`Accepted`), adding `ChatMessageProjection`, keyed row caching with `findChildIndexCallback`, mounted anchor registry, narrowed provider watches, and 500 ms debounced draft flushes.
- **Later structural splits (post-ADR-064):** Split `chat_pages.dart` and `chat_timeline.dart` into per-component files while preserving `ChatMessageProjection`, `_ProjectedConversationPageState`, `_rowWidget`, `_anchoredRows`, `findChildIndexCallback`, and the five-trigger draft flush behavior.
