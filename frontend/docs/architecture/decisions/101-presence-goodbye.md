# ADR-101: Presence reads stale peer answers and goodbye never waits for the network

- **Status:** Accepted (2026-11-13); proposed 2026-11-13
- **Date:** 2026-11-13 (explicitly recorded in register and full section; implemented across `878bd5f7`, `2fa399cc`, `bb399e6c`, `8b4d66bd`, `685ac9a3` and documented in `c561db4e` on `frontend-presence-hot-path`, PR #97 `80e9e9cb`)
- **Amends:** [ADR-098](098-presence-and-typing.md) D5 and D7 (stale-while-revalidate peer cache, lock-free resolution, immediate non-blocking cached `gone`, and 1,500 ms generation-guarded farewell limit)
- **Related:** [ADR-094](094-best-effort-delivery.md), [ADR-098](098-presence-and-typing.md), [ADR-099](099-typing-sessions.md), [ADR-100](100-socket-presence.md), [STATUS.md](../../STATUS.md), [message-protocol.md](../../message-protocol.md), [CLIENT_PRESENCE_AND_RECEIPTS.md](../../../../docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md)

## Decision (Position)

Removed peer-read stalls from the presence hot path and made foreground departure seal `gone` without waiting on the serial queue or the network:

1. **H1–H10 — Stale-while-revalidate peer cache and lock-free reads ([cached_presence_peers.dart](../../../lib/features/signals/infrastructure/cached_presence_peers.dart)):**
   - `CachedPresencePeers` serves answers < 10 s old directly, and serves verified answers **10 s to < 60 s** old immediately while triggering a single shared background `POST /api/v1/peers` refresh per account (failed refreshes leave stale verified entries intact and pause background refreshes for that account for 5 s; refused/unverified/blocked answers are never served stale and retry after 10 s; trust changes drop the cache entry immediately).
   - Unknown devices not present in a stale answer wait for one refresh (`verifiedDevices(..., including:)`).
   - `PresenceChannel._send` resolves target accounts *before* taking `SignalRouter.exclusively`; the seal's resolver reads only cached entries and skips uncached targets, so `SignalRouter.exclusively` is never held across a peer HTTP read.
   - `peek(userId)` returns the latest trust-checked verified device list of any age without issuing a network request.
   - Keeps the 10 s freshness target, 64-account batch size, trust check per hit, per-send durable/voice resolvers, P1/P2/L1, and wire format.
2. **G1–G4 — Immediate, zero-read goodbye ([presence_channel.dart](../../../lib/features/signals/application/presence_channel.dart), [signal_providers.dart](../../../lib/app/dependencies/signal_providers.dart)):**
   - Whichever observer sees foreground departure first (`VisibleConversationRegistry` or `SyncLifecycleSupervisor.farewell()`) triggers `_depart()` synchronously without waiting in `_serially`: it reads live lease holders without an `await`, filters targets via `peek`, and seals `gone` via `goodbyeSealer` over `CachedPresencePeers.goodbyeResolver` (serving the last verifying answer of any age with zero network reads, skipping targets with none). Cleanup (`_leaveForeground`) runs afterward in `_serially`; `farewell()` awaits the single active departure.
   - Goodbye sends **`gone` only** (no typing-stop frame; `gone` ends the peer's typing indicator directly).
   - While `_departing`, queued watch rounds, received frames, activity events, socket opens, and typing timers return immediately (`_unlessDeparting`; `SignalRouter` still commits inbound frames so senders lose no keys) and nothing except the goodbye may seal. Returning to foreground ends `_departing`; heard timestamps, L1, probe ledger updates, socket close, and switch changes still run.
3. **G5–G7 — Supervisor farewell wait and generation guard ([sync_lifecycle_supervisor.dart](../../../lib/features/synchronization/application/sync_lifecycle_supervisor.dart)):**
   - Raised `SyncLifecycleSupervisor.farewellLimit` from 500 ms to **1,500 ms** (closing earlier if `farewell()` finishes sooner), and `_enterBackground` closes the socket only if no newer lifecycle transition started during the wait.
   - Kept the 40 s online window, 25 s renewal, 40 s lease, 10 s cache freshness, `inactive` background mapping, P1/P2/L1, and wire format.

## Rationale

- On `be0eba57` (2026-10-20 field test), expired 10 s peer answers blocked 20%–60% of renewal cycles, held `SignalRouter.exclusively` across network calls (and TCP/TLS re-handshakes past 30 s HTTP idle), and queued `farewell()` behind `_serially` and fresh peer reads while the supervisor closed the socket at 500 ms.
- Primary Android documentation (`source.android.com/docs/core/perf/cached-apps-freezer`, read 2026-10-20 and 2026-11-13) confirms Android 14+ freezes cached processes after 10 s and terminates their TCP sockets, giving goodbye seconds — not sub-500 ms — if it does not stall behind HTTP reads or queued handlers.
- Rejected bypassing the 10 s cache (adds latency per frame), changing `inactive`/`paused` triggers (already trigger departure), shortening the online window to 20–25 s (doubles `watch`/`here` traffic when 25 s renewals overlap), or solely raising the flush budget without removing queue/network waits.

## Constraints and Open Gates

- **Scope:** Changed `CachedPresencePeers`, `PresenceChannel` (`_depart`, `_sayGoodbye`, `_unlessDeparting`, `_send(goodbye:)`), `signal_providers.dart` (`goodbyeSealer`), `sync_lifecycle_supervisor.dart` (`farewellLimit`, transition generation guard), and [message-protocol.md](../../message-protocol.md); changed no server route, wire format, database table, dependency, or Android permission.
- **Verification:** Covered by host suites: [presence_peer_reads_test.dart](../../../test/features/signals/presence_peer_reads_test.dart), [presence_goodbye_test.dart](../../../test/features/signals/presence_goodbye_test.dart), [cached_presence_peers_test.dart](../../../test/features/signals/cached_presence_peers_test.dart), [presence_round_trip_test.dart](../../../test/features/signals/presence_round_trip_test.dart), [presence_channel_test.dart](../../../test/features/signals/presence_channel_test.dart), [presence_status_test.dart](../../../test/features/signals/presence_status_test.dart), and [sync_lifecycle_supervisor_test.dart](../../../test/features/synchronization/sync_lifecycle_supervisor_test.dart) (T1–T11 plus 9 targeted mutation checks; 3 earlier tests updated for `gone`-only goodbye and G4 background departure behavior).
- **Left open / not verified:**
  - **No device run:** No phone ran this change; real-device peer-read latency remains unmeasured.
  - **Contract conflict on `farewellLimit`:** [STATUS.md](../../STATUS.md) and `CLIENT_PRESENCE_AND_RECEIPTS.md` §3.6 record an open owner decision reconciling ADR-101's 1,500 ms wait against the binding 500 ms limit and pacer release bound.
  - **Open owner options:** Whether `AppLifecycleState.inactive` (notification shade, system dialogs, pickers) should continue closing the socket and sending `gone`, and whether returning to the Chats list should emit a bounded return notice to prior watchers.

## Costs

- A device revoked by its peer can receive presence frames (`watch`, `here`, `typing`, `gone`) for up to **60 s** instead of 10 s, and a single `gone` up to **120 s** after revocation (trust changes locally still invalidate immediately, and voice/durable sends still resolve live every send).
- Leaving sends no explicit typing-stop frame; peers skipped by `gone` keep the typing line up to its 15 s TTL.
- Frames received during `_departing` are discarded unread (even when [ADR-094](094-best-effort-delivery.md) holds the socket open in the background), leaving peers online until their 40 s window expires.
- A stalled goodbye holds the socket open up to 1,000 ms longer than before; the 40 s window remains fallback for process kills, crashes, or lost networks.

## Reversal Trigger

Reopen for the owner decision reconciling `farewellLimit` (1,500 ms vs 500 ms in [STATUS.md](../../STATUS.md)), `inactive` lifecycle mapping, Chats-list return announcements, or physical-device validation.

## History, Amendments, and Supersession

- **2026-11-13 (`878bd5f7`, `2fa399cc`, `bb399e6c`, `8b4d66bd`, `685ac9a3`, `c561db4e`, PR #97 `80e9e9cb`):** Proposed, implemented across two prompts, and accepted ADR-101 as phase 3 of the three-phase presence fix, amending [ADR-098](098-presence-and-typing.md) D5 and D7.
