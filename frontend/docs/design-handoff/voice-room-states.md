# Voice rooms — screen and state inventory for design

**Status: derived export. Not authoritative.**
Reconciled from [`ui-specification.md`](../ui-specification.md) §0.2, §10, §13 and §17,
[`responsive-ui.md`](../responsive-ui.md), [`voice-and-realtime.md`](../voice-and-realtime.md),
[`platform-android.md`](../platform-android.md),
[`backend/voicerooms/API.md`](../../../backend/voicerooms/API.md), and
[`backend/realtime/API.md`](../../../backend/realtime/API.md). Where they disagree, those
files win. Read alongside [`DESIGN.md`](DESIGN.md).

**Implementation is gated.** `/voice-rooms` currently renders `StructuralPlaceholderPage`,
and piece 20 is blocked on ADR-058's seven prerequisites — most unmet as of 2026-08-25.
Designing these screens is not gated by that. Building them is. This is not a schedule.

---

## 1. Model constraints the design must obey

From the protocol, not from taste. A design that violates one of these cannot be built.

- **All peers are equal.** No owner, no admin, no roles, no kick, no moderation. The
  backend has no member table and no owner column. A room is a capability id plus an
  encrypted name.
- **Anyone holding the capability can read, rename, and join.** Membership is client-side
  MLS state and the backend cannot enforce it. A hostile capability holder *can* rename
  the room server-side; clients authenticate metadata updates and **surface a conflict**
  rather than trusting server ciphertext.
- **Leaving does not delete the room.** It removes local membership, keys, capability and
  live access. The backend row persists, the capability cannot be revoked, and returning
  needs a fresh authenticated invite. The confirmation must say all of this and must not
  imply deletion.
- **Room names are encrypted and padded into two buckets** (256 or 1024 bytes). Off-bucket
  is rejected, so the name field needs a length limit.
- **`live_count` is a coarse, laggy hint counted per *device*.** One person on two devices
  reads as 2. The LiveKit connection is authoritative for tiles; `live_count` is for the
  list row and info header only.
- **Renames are discovered by polling, and `updated_date` is day-coarse.** A rename is not
  a realtime event. Do not design a live "renamed just now" affordance.
- **No data channel.** The grant is audio-only — microphone publish and subscribe, no
  video, no unencrypted data channel. Reactions, raised hands and typing indicators cannot
  ride LiveKit; anything like that is client protocol over the messaging queue. Treat as
  out of scope unless specified.
- **Ephemeral text is genuinely best-effort.** In memory only, dropped when the room
  empties or membership becomes invalid, and another participant can retain what they
  decrypted. Copy says best-effort, never "disappears forever".
- **Voice is never offered where groups are withheld.** Same per-ABI permit as group MLS
  (ADR-056), so "unavailable on this device" is a real reachable screen.
- **Presence is device-granular.** `room_presence` reports a *device* joining or leaving,
  and leave fires on disconnect as well as explicit leave.

---

## 2. Voice Rooms list — `/voice-rooms`

Row: locally decrypted name + state line. The shell owns the tab bar and FAB.

| State | Trigger | On screen |
|---|---|---|
| Loading | First open, no cache | `AppStatePanel.loading` |
| Populated | Rooms known locally | Rows: name + **Live now · N** or **Empty** |
| Empty | No rooms | `AppStatePanel.empty` — one title, one sentence, one action |
| Offline | Server unreachable | Cached list, shell connection strip above, rows still tappable |
| Name undecryptable | Metadata key missing or conflicting | Neutral placeholder + conflict marker, never raw ciphertext |
| Unavailable on this device | Voice withheld by the per-ABI permit | Destination visible, content explains, actions disabled |
| Not built yet | Current shipping reality | `SurfaceMaturity` badge, exact wording **"Not built yet"** |

Ordering, unread affordances and swipe actions are **not** specified upstream. Propose
them and mark the proposal as new.

## 3. Create voice room — `/voice-rooms/new`

Three steps: **room details** → **invite members** → **create**.

| State | Trigger | On screen |
|---|---|---|
| Step 1 idle | — | Name field; standalone room, never tied to a DM or group |
| Name too long | Exceeds the 1024-byte bucket | Inline field error, Create disabled |
| Step 2 picker | — | Searchable contact multi-select, all invitees equal peers |
| No verified contacts | Nothing selectable | Empty state routing to verification — verification precedes messaging |
| Creating | POST in flight | Progress on the primary action, step not dismissible |
| Rate limited | `429`, accounts scope 120/min | Honest retry message, action disabled while cooling down |
| Invalid payload | `400 bad_bucket` | Field-level error, not a toast |
| Created | `201` | Opens the room or its info card |

## 4. Voice room info

| State | Trigger | On screen |
|---|---|---|
| Empty | `live_count == 0` | State line **Empty**, primary action **Rejoin** |
| Live | `live_count > 0` | **Live now · N**, primary action **Join** |
| Unknown room | `404 not_found` | Gone from the backend — explain, offer local cleanup |
| Rename in flight | `PUT` sent | Progress on the field, same bucket limit as create |
| Rename rejected | `400 bad_bucket` / `429` | Field error or cooldown |
| Rename conflict | Authenticated metadata disagrees with server ciphertext | Surface the conflict; do not silently prefer either side |
| Offline | Server unreachable | Cached state, Join disabled **with a stated reason** |
| Leave confirmation | User taps leave | See below |

Member rows are avatar + name with **no role tags**. Invite is available to every peer —
there is no permission gate to design.

**Leave dialog** (a §17 confirm dialog) must state: removes local membership, keys,
capability and live access; does **not** delete the backend room or revoke copies of the
capability held by others; returning requires a fresh authenticated invite. Honest wording
is a release rule, not a preference.

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
| Requesting notifications | `POST_NOTIFICATIONS` for active-voice disclosure | Off by default on a fresh install, so this is the common path, not the edge |
| Notifications denied | Refused | A **stated outcome**, not a retry loop; the foreground-service disclosure is degraded and the screen says so |

### 5.2 Session lifecycle

| State | Trigger | On screen |
|---|---|---|
| Minting token | `POST /rooms/{id}/token` | Connecting indicator |
| Negotiating encryption | Deriving media keys from room MLS state | Distinct from connecting — publishing has **not** started |
| Connecting | LiveKit connect before token expiry | Connecting indicators on tiles |
| Connected | Normal | Tiles live, controls enabled |
| Alone in room | Only participant | Single-tile state inviting others |
| Reconnecting | Network change or drop | Audio drops, reconnecting indicator, **speaking indicators must stop**, text panel shows volatile state, token re-minted |
| Key rotation | A participant left or was removed | Audio pauses until rotation completes |
| Encryption failure | Media key unavailable or rejected | **Publishing is muted and a blocking encryption error shows.** Never degrade to unencrypted |
| Room emptied | Last peer left | Ephemeral text dropped; room stays rejoinable |
| Left | User taps leave | Returns to previous screen, banner disappears |

### 5.3 REST failure states

| State | Response | On screen |
|---|---|---|
| Device not bound | `403 device_scope_required` | Explain the binding requirement; do not offer a retry that cannot succeed |
| Voice not configured | `503 voice_unconfigured` | Server has no LiveKit — honest, non-retryable, **no foreign fallback** |
| Token rate limited | `429`, roomtoken scope 60/min | Cooldown on join |
| Room gone | `404 not_found` | Cannot join; offer local cleanup |
| Token expired mid-join | 300s lifetime elapsed | Silent re-mint; surface only if the re-mint fails |
| Offline | Server unreachable | Honest error, no foreign fallback attempted |

### 5.4 Realtime socket states

The room's presence and ephemeral text ride the app's WebSocket, which fails
independently of LiveKit. **The room can be audio-connected while the socket is down** —
audio continues, ephemeral text and presence do not. That split needs a visible design.

| State | Trigger | On screen |
|---|---|---|
| Socket degraded | Socket down, LiveKit up | Audio unaffected; text panel and presence marked stale, not silently frozen |
| Auth expired | Close **4001** | Client refreshes the token and reconnects; transient, usually invisible |
| Device revoked | Close **4003** | **Hard blocking state.** The token is dead, the session ends, and recovery requires a fresh login on another device. Can land mid-call |
| Protocol violation | Close **4008** | Should not be user-reachable; if it is, it is a defect, not a state to style |
| Subscription cap | 100 rooms per socket, subscribe silently dropped | Only reachable with very many rooms; presence silently absent |
| Room subscribe ignored | Nonexistent room — silently ignored | There is **no error frame**; absence of presence is the only signal |

### 5.5 Participant tiles

Speaking · muted · connecting · reconnecting · unverified peer.

Speaking and mic state come from local and LiveKit media state, never from the server.
**Each needs a non-color signal** — shape, icon or text — this is an explicit
accessibility gate, and speaking/mute are named in it. Tapping a tile opens the
participant sheet (§17) with the name and, if unverified, a link to verify the safety
number. On wide layouts that sheet becomes a dialog or panel.

### 5.6 Ephemeral text panel

**For the voice phase.** `room_signal` is not a frame (server ADR-0021). Room text is
relayed `signal` by `signal`, addressed to one device at a time, so there is no subscriber
fan-out and no echo of the sender's own message to account for; the panel renders what this
client sent because it sent it. The states below survive that change and the triggers are
restated when the phase specifies the relay.

| State | Trigger | On screen |
|---|---|---|
| Idle | — | Persistent, plain indication that it is ephemeral and best-effort |
| Empty | No messages | One line explaining messages vanish when the room empties |
| Sending | Blob relayed | Simple send state; no pin, star, reply, edit, receipts |
| Too large | **For the voice phase.** `SIGNAL_MAX` is gone: a `signal` blob is now base64 of exactly 1024, 4096 or 16384 bytes, and anything off a bucket is **silently dropped** (server ADR-0022). The phase sets the composer rule against the bucket the plaintext is padded to, not against a ceiling | Composer limit must prevent this; there is no server error to surface |
| Stale | Socket degraded | Marked stale rather than appearing merely quiet |
| Dropped | Membership invalid or room emptied | Panel clears with an explanation |

### 5.7 Output selection

Earpiece / speaker / Bluetooth, plus device change mid-call. States: available routes,
active route, route changed by the system, no route available. Not specified upstream —
propose and mark as new.

### 5.8 Minimized

Collapses to the shell's persistent banner: room name, live mic-state icon, return
target. Above the bottom tab bar on narrow, atop the rail on wide, on **every** screen
until leave. Android additionally runs a microphone/communication foreground service
**with visible controls** in its notification for the duration of the joined room.

Minimizing keeps audio **only when the platform can truthfully maintain it**. The
notification is its own privacy surface: when privacy mode is on, sensitive text and
images must not appear in it or in the blurred app-switcher preview.

## 6. Invite picker

Searchable contact multi-select + Invite confirm. States: loading, empty, no verified
contacts, sending, **per-contact encrypted invite status**, rate limited, sent. On wide
layouts this is a dialog or panel rather than a sheet.

---

## 7. Cross-cutting obligations

### Responsive

- Wide: destination rail/list at **300–340px**; the ephemeral text side panel maps to the
  optional details panel at **340–400px**.
- Modals are **sheets on narrow, dialogs or panels on wide** — every sheet above needs
  both forms.
- Resizing preserves state. Crossing a breakpoint must not drop the user out of the room,
  lose the text draft, or close an active modal intent.
- Deliver narrow and wide. Medium may follow from wide.

### Accessibility — these are release gates

- **Live regions need a deliberate policy.** Participant join/leave and speaking changes
  are the obvious candidates and the obvious hazard: announcing every speaker change makes
  the screen unusable with a screen reader. Decide what is announced, and say so.
- **Focus restoration** across minimize → return, and on every sheet open and close.
- **Text at maximum scale must not hide primary or destructive actions** — Leave and Mute
  must survive it. Layout reflows before text truncates.
- **Keyboard-only** operation on web, including context menus and dialogs.
- **Color is never the only carrier** of verification, failure, mute, speaking or receipt
  state.
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
  large participant counts, which no upstream document bounds
- Output-route control design (§5.7)
- Whether tapping a list row opens info or joins directly — §13.0 explicitly leaves this
  open and asks only for consistency
- How the socket-degraded split (§5.4) is expressed without alarming a user whose audio is
  fine
- Live-region announcement policy (§7)
