# ADR-099: Typing sessions end with the message and start immediately

- **Status:** Accepted (2026-11-13); proposed 2026-11-13
- **Date:** 2026-11-13 (explicitly recorded in register and full section; implemented in `cbf03900` and documented in `ed584148` on `frontend-typing-session-rules`, PR #95 `547bfe68`)
- **Amends:** [ADR-098](098-presence-and-typing.md) D3 (typing session start, send, pace, retry, and first-repeat rules)
- **Related:** [ADR-098](098-presence-and-typing.md), [ADR-100](100-socket-presence.md), [ADR-101](101-presence-goodbye.md), [message-protocol.md](../../message-protocol.md)

## Decision (Position)

Fixed typing-session state transitions in `PresenceChannel` ([presence_channel.dart](../../../lib/features/signals/application/presence_channel.dart)) so consecutive messages show typing on the peer's screen from the first keystroke without exceeding L1:

1. **N1 — Message send ends the session without sending a frame:**
   - On `ChatTextSent`, sets `wanted = false` and `sent = false`, cancels idle, pace, and repeat timers, clears `lastSentAt`, and records the send timestamp; the arriving message clears the indicator on the receiver ([ADR-098](098-presence-and-typing.md) D3) and the subsequent composer clear is a no-op.
2. **N2 — Starts bypass the pace:**
   - Any transition from `sent == false` to `wanted == true` sends immediately without waiting for the 5 s pace window, even directly after a stop.
3. **N3 — Pace applies solely to cleared-composer stops:**
   - The 5 s pace still holds back a stop caused by emptying the composer (preventing noise on a quick backspace/retype); idle stops and leaving-chat stops leave immediately (foreground-leave keeps [ADR-098](098-presence-and-typing.md)'s rule here, later changed by [ADR-101](101-presence-goodbye.md)).
4. **N4 — `sent` reflects actual queued frames (`typingRetry = 1 s`):**
   - `sent` becomes `true` (and `lastSentAt` updates) only when `_send` actually queued ≥ 1 frame. When no frame left (no lease, L1 reached, or refused seal), `sent` stays `false`, `wanted` stays `true`, and subsequent edits retry at most once per second (`typingRetry`); any frame committed from a device lifts L1 and clears the retry wait (`_onHeard`). Repeats blocked similarly reset `sent = false`.
5. **N5 — Early refresh after a recent send (`typingRaceWindow = 5 s`, `typingFirstRefresh = 3 s`):**
   - When a typing start occurs within `typingRaceWindow` (5 s) of the last send in that conversation, its first repeat is scheduled at `typingFirstRefresh` (3 s) instead of 10 s (subsequent repeats stay 10 s), repairing indicators cleared prematurely if the durable message arrives after the next message's volatile `typing` start (C4, inferred).
6. **N6–N7 — Preserved bounds and worst-case rate:**
   - Repeat 10 s, idle stop 5 s, TTL 15 s, lease 40 s, L1 (8), P1 (4), P2 (4 / 6 h), wire format, and receiver rules are unchanged; worst-case typing rate to one watcher is at most **24** frames per 60 s (alternating 1-char edits and 5 s idle stops), still hard-capped at 8 live frames between watcher frames by L1.

## Rationale

- Field testing on two phones (`be0eba57`, 2026-10-20) showed the second message's typing line missing or delayed 3–6 s. `PresenceRig` measurements reproduced four causes: `ChatTextSent` routed through the pace and left `sent == true` (S1: message 2 delayed 6 s or missed if sent < 10 s); the pace delayed starts after stops (S2, S3); `sent`/`lastSentAt` updated even when zero frames left (no lease/L1/refusal); and volatile starts for message 2 can outrun durable delivery of message 1.
- Rejected an owner-suggested 2 s pace / 5 s repeat / 8 s expiry because 2 s pacing (12 frames/25 s) and 5 s repeats (6 frames/25 s) exhaust L1 (8 frames per 25 s renewal cycle), silently suppressing typing indicators without increasing dead skipped keys.

## Constraints and Open Gates

- **Scope:** Changed `PresenceChannel` (`_onActivity`, `_flushTyping`, `_sendTyping`, `_TypingOut`, `_onHeard`, `typingRaceWindow`, `typingFirstRefresh`, `typingRetry`) and protocol doc [message-protocol.md](../../message-protocol.md); changed no server route, wire format, database table, dependency, or Android permission.
- **Verification:** Covered by [presence_channel_test.dart](../../../test/features/signals/presence_channel_test.dart) and [presence_round_trip_test.dart](../../../test/features/signals/presence_round_trip_test.dart) (S1–S3 before/after, no-lease/L1/refused-seal retry, 3 s post-send refresh, N7 24-frame bound, two-phone harness), plus 6 mutation checks (5 caught directly; keeping `lastSentAt` on send is equivalent because `lastSentAt` is read only for stops after a queued start overwrites it).
- **Left open / not verified:** No physical-device run; C4's volatile-vs-durable race remains inferred from code rather than measured on two phones; socket handshake ([ADR-100](100-socket-presence.md)) and peer reads/goodbye ([ADR-101](101-presence-goodbye.md)) left to phases 2 and 3.

## Costs

- Removing the pace from starts raises worst-case typing traffic to one watcher from 12 to 24 frames/minute (bounded by L1 at 8 live frames).
- Typing again within 5 s of a send adds one extra 3 s refresh frame.
- Because sending no longer emits an explicit `typing(active: false)` frame, a message that never delivers leaves the peer's typing indicator active until the 15 s TTL expires.

## Reversal Trigger

Reopen if field measurements on phones show different race windows, L1 sizing, or C4 ordering behavior.

## History, Amendments, and Supersession

- **2026-11-13 (`cbf03900`, `ed584148`, PR #95 `547bfe68`):** Proposed, implemented, and accepted ADR-099 as phase 1 of the three-phase presence fix, amending [ADR-098](098-presence-and-typing.md) D3.
