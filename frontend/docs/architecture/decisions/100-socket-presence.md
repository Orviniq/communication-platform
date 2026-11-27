# ADR-100: Presence follows socket state and reciprocates new watchers immediately

- **Status:** Accepted (2026-11-13); proposed 2026-11-13
- **Date:** 2026-11-13 (explicitly recorded in register and full section; implemented in `1060d7b1`, `95c8745e`, `68364720`, and documented in `9631890d` on `frontend-presence-connection`, PR #96 `bda6f4e3`)
- **Amends:** [ADR-098](098-presence-and-typing.md) D4 (gates seals on open socket, re-watches/re-types on socket open, and sends an immediate reciprocal `watch` to newly watching targets)
- **Related:** [ADR-098](098-presence-and-typing.md), [ADR-099](099-typing-sessions.md), [ADR-101](101-presence-goodbye.md), [message-protocol.md](../../message-protocol.md)

## Decision (Position)

Aligned `PresenceChannel` ([presence_channel.dart](../../../lib/features/signals/application/presence_channel.dart)) with live WebSocket connectivity and eliminated the asymmetric watch-lease gap when a peer opens a chat late:

1. **K1–K2 — Socket open state and stream (`SignalSocketPort` in [signal_ports.dart](../../../lib/core/application/ports/signal_ports.dart)):**
   - Added `isOpen` and `opens` (one event after each successful connect) to `SignalSocketPort` / `RealtimeGateway` ([dio_websocket_gateway.dart](../../../lib/features/networking/infrastructure/realtime/dio_websocket_gateway.dart)) and forwarded them through `GatewayVoiceSignalSocket` ([gateway_voice_signal_socket.dart](../../../lib/features/voice/infrastructure/gateway_voice_signal_socket.dart)) on a broadcast stream surviving attach/detach.
2. **K3 — Never seal while the socket is closed:**
   - `PresenceChannel._send` checks `socket.isOpen` both before taking `SignalRouter.exclusively` and again inside the lock; skipped frames spend no probe token, add no L1 count, and advance no Double Ratchet chain.
3. **K4–K5 — Replay on socket open and clear typing on close:**
   - On each `socket.opens` event, runs the watch round for the visible conversation and re-sends a typing start for any `wanted` typing session. Socket close continues clearing displayed typing states while leases/watches expire by time.
4. **W1–W3 — Immediate reciprocal `watch` (`_watchBack`):**
   - When the channel in foreground (switch on) accepts a `watch` for the visible conversation from a target included in the current watch, and has not sent a live `watch` to that device in the last 40 s, it immediately sends a live `watch` back after the `here` reply.
   - The reciprocal `watch` counts toward L1, spends no probe token, updates `renewedAt` on the current watch, and leaves the 25 s renewal timer unchanged.
   - Suppressed in the background, when the switch is off, when the chat is not on screen, or for non-targeted devices (e.g., groups > 32 members or a member's 3rd+ device).
5. **Gone handling and K6/W4 preservation:**
   - Accepting `gone` forgets any `renewedAt`/`answeredAt` watch record for that device (so a peer returning within 40 s receives a reciprocal watch), while accepting a `watch` clears that sender's `gone` state. Renewals (25 s), leases (40 s), answer window (10 s), P1/P2/L1, wire format, and voice behavior are unchanged.

## Rationale

- Field testing (`be0eba57`, 2026-10-20) and `PresenceRig` measurements showed two defects:
  1. `_send` sealed frames before the socket opened or during `inactive`/disconnects, advancing Double Ratchet chains and burning P1/P2 probes on frames never transmitted (S4: first watch lost at 0 s, next at 75 s; S6: 4 watches lost and probes burned in a 5-minute outage).
  2. Receiving a `watch` granted a lease only to the watcher, forcing an already-open peer to wait up to 25 s until its next renewal before sending its own `watch` and receiving a lease to type back.
- Rejected bypassing peer reads (handled in phase 3, [ADR-101](101-presence-goodbye.md)) and shortening the online window (phase 3).

## Constraints and Open Gates

- **Scope:** Changed `SignalSocketPort`, `RealtimeGateway` / `DioWebSocketGateway`, `GatewayVoiceSignalSocket`, `PresenceChannel` (`_watchBack`, open gate, `opens` replay, `gone` state reset), and [message-protocol.md](../../message-protocol.md); changed no server route, wire format, database table, dependency, or Android permission.
- **Verification:** Covered by [websocket_gateway_test.dart](../../../test/features/networking/infrastructure/websocket_gateway_test.dart), [gateway_voice_signal_socket_test.dart](../../../test/features/voice/gateway_voice_signal_socket_test.dart), [presence_connection_test.dart](../../../test/features/signals/presence_connection_test.dart), [presence_reciprocal_watch_test.dart](../../../test/features/signals/presence_reciprocal_watch_test.dart), and [presence_round_trip_test.dart](../../../test/features/signals/presence_round_trip_test.dart) (T1–T9 covering S4/S6, mutual open convergence, group-of-3 vs > 32, post-`gone` return, L1 bound, plus 5 mutation checks including unbounded-exchange guard).
- **Left open / not verified:** No physical-device run; peer-read stalls and goodbye waits addressed in [ADR-101](101-presence-goodbye.md); `inactive` lifecycle mapping and Chats-list return announcements remain open options for the owner.

## Costs

- Adds one live `watch` (and its `here` reply) on late join, leaving 6 of 8 L1 frames for typing before the peer's next frame.
- When both phones open a chat within seconds of each other, because initial watches are probes (not live), each side sends one reciprocal `watch` (6 frames total before convergence, bounded by the 40 s `renewedAt` guard).
- Adds two `isOpen` checks per seal; frames sealed in the final milliseconds before an abrupt socket close can still be lost as dead skipped keys within [ADR-098](098-presence-and-typing.md) D6's budget.

## Reversal Trigger

Reopen if reciprocal watches count answered probes as live (reducing simultaneous-open exchanges from 6 frames to 4) or if lifecycle `inactive` handling or Chats-list presence announcements change.

## History, Amendments, and Supersession

- **2026-11-13 (`1060d7b1`, `95c8745e`, `68364720`, `9631890d`, PR #96 `bda6f4e3`):** Proposed, implemented, and accepted ADR-100 as phase 2 of the three-phase presence fix, amending [ADR-098](098-presence-and-typing.md) D4.
