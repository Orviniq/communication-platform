# ADR-066: App-owned reversed-sliver timeline, UI boundary, and first-strong bidi

- **Status:** Accepted
- **Date:** 2026-08-30 (explicitly recorded in register and full section; committed in `ef3ad255`)
- **Supersedes:** [ADR-007](007-flyer-timeline.md) (and records a correction of fact removing "Flyer builders" from [ADR-024](024-visual-system.md))
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-006](006-forui-boundary.md), [ADR-016](016-english-and-persian.md), [ADR-024](024-visual-system.md), [ADR-054](054-dependency-policy.md), [ADR-062](062-timeline-window.md), [ADR-063](063-event-projection.md), [ADR-064](064-incremental-rebuild.md)

## Decision (Position)

Replaced [ADR-007](007-flyer-timeline.md) in the decision register to match shipped architecture, bounded custom UI ownership explicitly, and fixed first-strong bidirectional text resolution and isolation defects:

1. **D1 — Architectural reason for replacing Flyer Chat ([chat_timeline_adapter.dart](../../../lib/features/messaging/presentation/chat_timeline_adapter.dart)):**
   - Piece 15 replaced Flyer Chat with an app-owned reversed `CustomScrollView` sliver because `flutter_chat_core`/`flutter_chat_ui` 2.11.1 require mutable, controller-owned message state (`ChatController`), conflicting directly with [ADR-002](002-drift-source-of-truth.md) (Drift as single source of truth).
   - [ADR-054](054-dependency-policy.md) removed the unimported Flyer packages from [pubspec.yaml](../../../pubspec.yaml). `ChatTimelineAdapter` keeps the boundary seam: immutable view models in, typed intents out, stable indices so upward pagination appends at the far edge without moving the visible reading row.
2. **D2 — Corrected performance record:**
   - Recorded explicitly that [ADR-062](062-timeline-window.md), [ADR-063](063-event-projection.md), and [ADR-064](064-incremental-rebuild.md) eliminated application-layer costs (per-message reads, whole-conversation re-projection, and mapper/key-registry/provider-cascade findings F8–F10) that no rendering package caused or would have fixed.
3. **D3 — Explicit custom-UI boundary ([design_system_boundary_test.dart](../../../test/architecture/design_system_boundary_test.dart)):**
   - **App-owned:** reversed sliver, scroll physics, per-message keys and `findChildIndexCallback`, pagination and reading anchor, author grouping, date/unread separators, bubble geometry/directional padding, reaction rows, and delivery indicators.
   - **Material retained:** text fields, bottom sheets, menus, dialogs, selection controls, focus traversal, IME composition, RTL caret placement, selection handles, and TalkBack semantics.
   - **Forui unchanged:** [ADR-006](006-forui-boundary.md) and `design_system_boundary_test.dart` keep Forui isolated under `lib/app/design_system/`.
4. **D4 — First-strong direction resolver ([app_text_direction.dart](../../../lib/app/design_system/app_text_direction.dart), [app_text_direction_test.dart](../../../test/unit/app_text_direction_test.dart)):**
   - Replaced `_contentDirection` (which treated `U+0660–U+0669` Arabic-Indic AN digits and `U+06F0–U+06F9` Persian EN digits in `֐-ࣿ` as RTL and missed Arabic Presentation Forms-A/B `U+FB50–U+FDFF` / `U+FE70–U+FEFF`).
   - Rejected `intl` 0.20.2 `Bidi.startsWithRtl` (whose `_RTL_CHARS` `֑-߿` repeats the digit defect and whose `_LTR_CHARS` `ࠀ-῿` misclassifies Samaritan/Mandaic/Syriac Supplement/Arabic Extended-A as LTR) and `Bidi.detectRtlDirectionality` (0.40 whitespace-token threshold, `^http://` special case missing `https://`), importing `intl` only in the comparison test.
   - Implemented `resolveFirstStrongDirection` using UAX #9 P2/P3 over `DerivedBidiClass` R/AL/L ranges (checking RTL before LTR so combining marks are not captured, skipping isolate runs per P2, and deliberately returning `null` when no strong character is present so bare numbers inherit surrounding conversation direction), verified by 29 tests.
5. **D5 — Bidi isolation scoped to real defect:**
   - Verified by box-position tests that an embedded Latin URL with trailing punctuation in Persian (`سلام https://example.com/a?b=1.`) needs no FSI/PDI (Flutter runs UAX #9 per paragraph on a single string) and reaction chip `{emoji} {count}` mirrors intentionally.
   - Pinned the composer character counter (`$currentLength / $maxLength`) to `TextDirection.ltr` so UAX #9 N1 does not reverse `20 / 500` to `500 / 20` in RTL locales.
6. **D6 — Mixed-RTL golden ([chat_medium_rtl_mixed.png](../../../test/golden/goldens/chat_medium_rtl_mixed.png)):**
   - Added a fourth golden holding Persian + embedded URL + final stop, Persian digits followed by Latin, and an outgoing Latin bubble in an `fa` frame without altering the existing three goldens.

## Rationale

- Resolving [ADR-007](007-flyer-timeline.md) on the Drift single-source-of-truth conflict rather than retrospective performance claims keeps future package decisions grounded in measured evidence.
- Fixing UAX #9 P2/P3 in one bounded helper ensures [ADR-016](016-english-and-persian.md) mixed-direction correctness without re-implementing Material text editing or selection.

## Constraints and Open Gates

- **Scope:** Presentation layer and decision register only; schema stayed at 18; no repository, projector, outbox, sync, wire, crypto, or `backend/` change; opens no production gate.
- **Follow-ups recorded at ADR-066:**
  - **F1:** `message.replyQuote` `Text` carried no explicit `textDirection` and inherited ambient locale direction.
  - **F2:** `resolveFirstStrongDirection` covers BMP RTL scripts, both Presentation Forms blocks, supplementary RTL planes, and Latin/Greek/Cyrillic/Armenian/Indic/SE-Asian/CJK/Kana/Hangul LTR scripts, returning `null` for scripts outside that set.

## Costs

- Maintaining an app-owned reversed-sliver timeline (`ChatTimelineAdapter`) and explicit UAX #9 `DerivedBidiClass` range tables (`app_text_direction.dart`) in application code.

## Reversal Trigger

Reopen if the timeline adapter is swapped to another virtualized widget that supports immutable external state, if additional scripts must be added to `resolveFirstStrongDirection`, or if F1 (`replyQuote` direction) is addressed.

## History, Amendments, and Supersession

- **2026-08-30 (`ef3ad255`):** Recorded and implemented ADR-066 (`Accepted`), superseding [ADR-007](007-flyer-timeline.md), correcting [ADR-024](024-visual-system.md), adding `resolveFirstStrongDirection` and 29 unit/bidi tests, pinning composer counter LTR, and adding `chat_medium_rtl_mixed.png`.
