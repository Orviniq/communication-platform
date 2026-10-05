# Voice rooms — screen and state inventory for design

**Status: derived export. Not authoritative.**
Reconciled from [`ui-specification.md`](../ui-specification.md) §0.2, §10, §13 and §17,
[`responsive-ui.md`](../responsive-ui.md), [`voice-and-realtime.md`](../voice-and-realtime.md),
[`voice-signalling-v1.md`](../voice-signalling-v1.md),
[`platform-android.md`](../platform-android.md),
[`backend/CLIENT_CONTRACT.md`](../../../backend/CLIENT_CONTRACT.md) §N, and
[`backend/realtime/API.md`](../../../backend/realtime/API.md). Where they disagree, those
files win. Read alongside [`DESIGN.md`](DESIGN.md).

**Implementation is not gated, and the screens are built.** Phase 6 prompt 9 replaced the
`/voice-rooms` placeholder on 2026-10-02; [`ui-specification.md`](../ui-specification.md)
§10 and §13 say, as built, which states below are drawn and which are not built.
[ADR-058](../decisions.md)'s seven prerequisites named an MLS exporter, a per-ABI permit
and a LiveKit deployment, none of which exists to be met; [ADR-077](../decisions.md)
supersedes them with the design this document draws.

**The design canvas** at `Desktop\voice-rooms-design\artboards\` draws every state below
as a `.dc.html` file with each value inline. It binds nothing: where an artboard and this
document disagree, this document wins, and where this document and §N or server ADR-0021
disagree, those win.

---

## 1. Model constraints the design must obey

From the protocol, not from taste. A design that violates one of these cannot be built.

- **The server holds no room.** No room row, no name, no roster, no capability, no join
  token, no live count and no participant list. The whole voice surface it serves is
  `POST /api/v1/me/relay` and the relaying of `signal` frames. A room is client state
  carried by signed control events, exactly as a group is (server ADR-0021 point 7).
- **All peers are equal.** No owner, no admin, no roles. Every active member may add a
  member, remove a member and rename the room. The cost is real and is stated rather than
  designed away: any member can eject any other, and the remedy is a new room.
- **Creating, renaming and inviting are not server calls.** Each is a signed control
  event fanned out as ordinary envelopes. There is no `POST`, no `201`, no `PUT` and no
  `400 bad_bucket` to design a state for, and no server-set name limit — a room name is
  at most 100 Unicode scalar values, the same bound a group name has. The one throttle in
  reach is `429` on the envelope fan-out, `envelopes` scope, 600/min per account.
- **Leaving does not reach the server.** It is a signed `remove member` event naming
  yourself. The other members keep the room, nothing is deleted anywhere, and returning
  needs a fresh invite. The confirmation must say that and must not imply deletion.
- **A conflict is a fork, not a server disagreement.** Two members who rename at the same
  revision produce two valid signed events, and the room is quarantined: the client never
  picks a branch. There is no server copy of the name to disagree with.
- **A room's name is decryptable or the room is not held.** The name lives inside the
  control events this device verified, so there is no state where a held room has an
  unreadable name. A room this device has no state for is *waiting for its state*, which
  is a different row with different copy.
- **Audio is end to end, and there is no media server.** Each connection is keyed by
  DTLS-SRTP between its two endpoints, and every path crosses the self-hosted coturn
  relay, which forwards packets it cannot open. There is no SFU and no application-level
  media key, so there is no key rotation, no encryption-negotiation step and no
  "publishing paused while keys rotate".
- **Trouble is per person.** Each tile is its own encrypted connection, so one peer can be
  unreachable or blocked by a changed safety number while everybody else keeps talking.
  Nothing pauses when one connection fails and nothing pauses when somebody leaves.
- **A call holds ten joined devices**, refused by the client and by nothing on the server
  (§N rule 10). A person on two devices occupies two of the ten.
- **No video and no data channel.** One audio track for each connection (§N rule 1).
  Reactions, raised hands and typing indicators cannot ride the media path; anything like
  that is client protocol. Treat as out of scope unless specified.
- **Ephemeral text is genuinely best-effort.** A `signal` frame to one device at a time,
  in memory only, dropped when the call empties or membership becomes invalid, and another
  participant can retain what they decrypted. Copy says best-effort, never "disappears
  forever".
- **Presence is what a connection says.** There is no presence frame, no subscription and
  no `live_count` (server ADR-0022). A participant is present because a connection to them
  is open. A room nobody has told this device about reads as *Empty*, which is honest.
- **Voice is withheld by the server, not by the device.** `voice_configured` from
  `GET /api/v1/config` is the one gate, and it is per deployment. The per-ABI permit that
  would have withheld voice per device was deleted with the MLS core
  ([ADR-075](../decisions.md)).
- **There is no web client** (server ADR-0020). Android only. Keyboard-only operation is
  not a gate here; the external-keyboard and screen-reader paths on Android are.

---

## 2. Voice Rooms list — `/voice-rooms`

Row: locally decrypted name + state line. The shell owns the tab bar and FAB.

| State | Trigger | On screen |
|---|---|---|
| Loading | First open, no cache | `AppStatePanel.loading` |
| Populated | Rooms known locally | Rows: name + **Live now · N** or **Empty** |
| Empty | No rooms | `AppStatePanel.empty` — one title, one sentence, one action |
| Offline | Server unreachable | Cached list, shell connection strip above, rows still tappable |
| Room waiting for its state | A queue gap may have carried a control event, or an event arrived building on state this device does not hold | Row state line **Asking a member for its state**. The room is visible and tappable; joining waits |
| Room quarantined | Two valid events at one revision — a fork | Row state line names the conflict and routes to info; joining, inviting, renaming and leaving are paused |
| No voice on this server | `voice_configured` is false | Destination visible, content explains, the compose button is hidden as well |
| Not built yet | Current shipping reality | `SurfaceMaturity` badge, exact wording **"Not built yet"** |

Ordering, unread affordances and swipe actions are **not** specified upstream. Propose
them and mark the proposal as new.

## 3. Create voice room — `/voice-rooms/new`

Three steps: **room details** → **invite members** → **create**. Nothing here calls the
server: the create event is signed locally and fanned out as envelopes.

| State | Trigger | On screen |
|---|---|---|
| Step 1 idle | — | Name field; standalone room, never tied to a DM or group |
| Name too long | Over 100 Unicode scalar values | Inline field error, Create disabled |
| Step 2 picker | — | Searchable contact multi-select, all invitees equal peers |
| No verified contacts | Nothing selectable | Empty state routing to verification — verification precedes messaging |
| Creating | Event signed, envelopes in flight | Progress on the primary action, step not dismissible |
| Rate limited | `429` on the fan-out, `envelopes` scope 600/min | Honest retry message, action disabled while cooling down |
| Created | Every member's copies accepted | Opens the room or its info card |
| Partly delivered | Some members' devices are gone or full | The room exists and is usable; the info card says who has not been reached yet |

## 4. Voice room info

| State | Trigger | On screen |
|---|---|---|
| Empty | No call this device knows of | State line **Empty**, primary action **Start a call** |
| Live | A call this device has been told about | **Live now · N**, primary action **Join** |
| Waiting for its state | Queue gap, or an event on state this device does not hold | Explains that changes may have been lost, that a member has been asked, and that joining resumes when the answer arrives |
| Conflicting changes | Two valid events at one revision | Names both changes and both signers; states that the app will not choose; joining, inviting, renaming and leaving are paused |
| Rename in flight | Event signed, envelopes in flight | Progress on the field, same 100-scalar limit as create |
| Rename rate limited | `429` on the fan-out | Field-level cooldown, not a toast |
| Removed from this room | A member signed an event removing you | Room is read-only history; explains who signed it and that returning needs a fresh invite |
| Offline | Server unreachable | Cached state, Join disabled **with a stated reason** |
| Leave confirmation | User taps leave | See below |

Member rows are avatar + name with **no role tags**. Invite is available to every peer —
there is no permission gate to design.

**Leave dialog** (a §17 confirm dialog) must state: it is a signed event the other members
apply; it removes this account from the room and ends its access to calls; it does **not**
delete the room, which the remaining members keep; and returning requires a fresh invite.
Honest wording is a release rule, not a preference.

## 5. Live voice room

Layout, top to bottom: top bar (name, participant count, info, minimize) · participant
tiles · ephemeral text panel (tab on narrow, side panel on wide) · control bar
(mute/unmute, output, invite, leave).

### 5.1 Pre-join and permissions

Android requests **only at point of use**, and two permissions are in play. Both denials
are terminal states, not retry loops.

| State | Trigger | On screen |
|---|---|---|
| Requesting microphone | Explicit join only — never on screen open | Pre-join state |
| Microphone denied | Refused | Blocking explanation + route to settings; no partial join |
| Requesting notifications | `POST_NOTIFICATIONS` for the active-call disclosure | Off by default on a fresh install, so this is the common path, not the edge |
| Notifications denied | Refused | A **stated outcome**, not a retry loop; the foreground-service disclosure is degraded and the screen says so |

### 5.2 Session lifecycle

| State | Trigger | On screen |
|---|---|---|
| Minting a relay credential | `POST /api/v1/me/relay` | Connecting indicator |
| Announcing | `join` fanned out to each member device | Connecting indicator; no tile has answered yet |
| Connecting | Offers exchanged, DTLS handshaking | Connecting indicators on tiles, one per peer |
| Connected | At least one connection open | Tiles live, controls enabled |
| Alone in the call | Nobody else joined | Single-tile state inviting others |
| Reconnecting | Network change or drop | Audio drops, reconnecting indicator, **speaking indicators must stop**, text panel shows its volatile state |
| Participant not reachable | Four attempts over about 20 s and no answer (§N rule 7) | **That tile only** says not reachable, with *Try again*. Everybody else's audio carries on |
| Participant's safety number changed | The peer's cross-signature changed in a way that is not an expected rotation | **That tile only** is stopped, with a route to verify. Everybody else's audio carries on. Audio to that peer does not resume until the user checks the new number |
| Everyone has left | The last connection closed | Ephemeral text dropped; the room stays and any member can start a call again |
| Left | User taps leave | Returns to the previous screen, banner disappears |

There is no *negotiating encryption* state and no *key rotation* state. DTLS-SRTP keys each
connection during its own handshake, and a connection's keys die with it, so there is
nothing to rotate when somebody leaves and nothing to pause for.

### 5.3 Getting-in failure states

| State | Trigger | On screen |
|---|---|---|
| Voice not set up on this server | `voice_configured` false, or `503 voice_unconfigured` | No relay is configured — honest, **non-retryable**, and **no foreign fallback**. The call action is not offered in the first place when the config already said so |
| Relay not answering | A credential minted, but no connection reached `connected` within 15 s and every candidate pair failed | The server answered and its relay did not. **Retryable**, and the copy says nothing else will carry the call |
| Call full | This device's participant set already holds ten joined devices, or it was the eleventh by device-id sort and nobody offered | States the ceiling and why it exists — every phone sends its audio to every other phone. Retryable when somebody leaves |
| Rate limited | `429` on `POST /api/v1/me/relay`, `relay` scope 60/min | Cooldown on join for exactly the `Retry-After` seconds |
| Room waiting for its state | A queue gap may have carried a removal | Join is held, not failed; it resumes when a member answers |
| Room quarantined | A fork | Join is paused with the conflict named |
| Offline | Server unreachable | Honest error, no foreign fallback attempted |

A credential minted against a relay that is down is a `200`, because the route reads a
setting and never reaches coturn. *Relay not answering* is how that surfaces, and telling
it apart from nine unreachable people is the reason it is its own state.

### 5.4 Realtime socket states

The call's signalling and its ephemeral text ride the app's WebSocket, which fails
independently of the media. **A call can be audio-connected while the socket is down** —
audio continues, ephemeral text and joins and leaves do not. That split needs a visible
design, and it is deliberately quiet: the warning belongs where it can mislead someone,
not over a call that is working.

| State | Trigger | On screen |
|---|---|---|
| Socket degraded | Socket down, connections up | Audio unaffected and calm; the text panel says loudly that it has stopped updating, and the participant count reads *last known* |
| Device revoked | Close **4003** | **Hard blocking state.** The token is dead, the session ends, and recovery requires a fresh login on another device. Can land mid-call |
| Server restarting | Close **1012** | Reconnect after a backoff; a deploy, not a fault. Behaves as *socket degraded* while it lasts |
| Protocol violation | Close **4008** | Should not be user-reachable; if it is, it is a defect, not a state to style |

A refused handshake carries **no close code**: authentication is decided before the accept
and arrives as `403 Forbidden` on the upgrade (§O). It reads as "renew the token and
reconnect" and is invisible unless the renewal fails.

### 5.5 Participant tiles

Speaking · muted · connecting · reconnecting · not reachable · safety number changed ·
unverified peer.

Speaking and mic state come from local media state, never from the server.
**Each needs a non-color signal** — shape, icon or text — this is an explicit
accessibility gate, and speaking and mute are named in it. Tapping a tile opens the
participant sheet (§17) with the name and, if unverified, a link to verify the safety
number. On wide layouts that sheet becomes a dialog or panel.

*Not reachable* and *safety number changed* are per tile and never global. Both must read
as "audio with this one person has stopped" and never as "the call is broken".

### 5.6 Ephemeral text panel

Room text is a `CPVSV001` frame addressed to one device at a time, so there is no
subscriber fan-out and no echo of the sender's own message to account for: the panel
renders what this client sent because it sent it.

| State | Trigger | On screen |
|---|---|---|
| Idle | — | Persistent, plain indication that it is ephemeral and best-effort |
| Empty | No messages | One line explaining messages vanish when the call empties |
| Sending | Frames sealed and relayed | Simple send state; no pin, star, reply, edit, receipts |
| Too long | Over 2,000 scalar values or 8,000 encoded bytes | The composer's limit prevents it. A blob off a bucket is **dropped in silence** by the server (ADR-0022), so there is no error to surface and the limit is the whole of the defence |
| Stale | Socket degraded | Marked stale rather than appearing merely quiet |
| Dropped | Membership invalid or the call emptied | Panel clears with an explanation |

### 5.7 Output selection

Earpiece / speaker / Bluetooth, plus device change mid-call. States: available routes,
active route, route changed by the system, no route available. Not specified upstream —
propose and mark as new.

### 5.8 Minimized

Collapses to the shell's persistent banner: room name, live mic-state icon, return
target. Above the bottom tab bar on narrow, atop the rail on wide, on **every** screen
until leave. Android additionally runs a microphone-type foreground service **with visible
controls** in its notification for the duration of the call.

Minimizing keeps audio **only when the platform can truthfully maintain it**. The
notification is its own privacy surface: when privacy mode is on, sensitive text and
images must not appear in it or in the blurred app-switcher preview.

## 6. Invite picker

Searchable contact multi-select + Invite confirm. Inviting signs an `add members` event
and fans the whole transcript out to the new member. States: loading, empty, no verified
contacts, sending, **per-contact delivery status**, rate limited, sent, and a member whose
devices could not be reached — the room is 50 members at most, and a transcript that would
not fit one payload means the member is not added. On wide layouts this is a dialog or
panel rather than a sheet.

---

## 7. Cross-cutting obligations

### Responsive

- Wide: destination rail/list at **300–340px**; the ephemeral text side panel maps to the
  optional details panel at **340–400px**.
- Modals are **sheets on narrow, dialogs or panels on wide** — every sheet above needs
  both forms.
- Resizing preserves state. Crossing a breakpoint must not drop the user out of the call,
  lose the text draft, or close an active modal intent.
- Deliver narrow and wide. Medium may follow from wide.

### Accessibility — these are release gates

- **Live regions need a deliberate policy.** Participant join/leave and speaking changes
  are the obvious candidates and the obvious hazard: announcing every speaker change makes
  the screen unusable with a screen reader. Decide what is announced, and say so. A
  participant becoming *not reachable* or *safety number changed* is the one change that
  clearly must be announced.
- **Focus restoration** across minimize → return, and on every sheet open and close.
- **Text at maximum scale must not hide primary or destructive actions** — Leave and Mute
  must survive it. Layout reflows before text truncates.
- **External keyboard and switch access** on Android, including context menus and dialogs.
  There is no web client to cover (server ADR-0020).
- **Color is never the only carrier** of verification, failure, mute, speaking or
  reachability state.
- Persian RTL and English LTR both covered for the shell and mixed text direction.
- The global error and toast host announces accessibly and carries **no sensitive detail**.

---

## 8. Deliverable checklist

Five screens — list, create, info, live room, invite picker. For each: narrow **and**
wide, light **and** dark, every state in its table, plus Persian mirrored for the live
room and the list.

The live room's §5.1–§5.6 states are the substance of this hand-off. A set of mockups
covering only *connected* is not usable.

---

## 9. Where the spec is silent

Genuine latitude — propose, and flag as new rather than presenting as spec:

- List ordering, unread affordances, swipe actions (§2)
- Participant tile grid — shape, size, count before scrolling or paging, and behaviour at
  ten participants, which no upstream document lays out
- Output-route control design (§5.7)
- Whether tapping a list row opens info or joins directly — §13.0 explicitly leaves this
  open and asks only for consistency
- How the socket-degraded split (§5.4) is expressed without alarming a user whose audio is
  fine
- Live-region announcement policy (§7)
- How a room that is *waiting for its state* or *quarantined* reads in a list row beside
  rooms that are fine
