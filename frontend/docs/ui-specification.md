# UI specification — Page-by-Page

> **Repository scope note.** The original specification refers to web, mobile, and
> desktop layout modes. Version 1 ships Android only. The responsive web layout remains
> a post-v1 design direction; “desktop” below means a future wide-browser layout and
> does not add Windows, macOS, or Linux application targets.
>
> **Backend authority note.** Backend `API.md` contracts take precedence wherever this
> UI specification implies an unavailable endpoint, stronger server guarantee, or
> different limit. Client-only behavior must remain compatible with the backend's blind,
> opaque transport model.

> **Purpose.** This is a **layout and screen-flow specification** for the Flutter client
> (Android, with a post-v1 responsive Web direction). It describes **every screen, sub-screen, sheet, dialog, and
> menu**: what each contains, where each element sits, what every button/action does,
> where each action leads, and what states each screen can be in. It is **self-contained**
> — you do not need any other document to lay out and build these screens.
>
> **Scope boundary — read this.**
> - This document specifies **layout structure and screen content**: the arrangement of
>   top bar / body / bottom bar, what components exist, their order, and the navigation
>   between screens.
> - It does **NOT** duplicate visual styling. Colors, typography, spacing, theming,
>   component treatment, and motion are defined by
>   [`visual-design-system.md`](visual-design-system.md).
> - It does **NOT** duplicate cryptographic protocol detail (key exchange, ratchets,
>   key-backup internals). Those rules live in
>   [`cryptographic-protocol.md`](cryptographic-protocol.md) and
>   [`message-protocol.md`](message-protocol.md). Where
>   the UI must respect a privacy or honesty rule, it is stated inline and flagged
>   **[PRIVACY]** — you can build the screen correctly from that flag alone.
>
> **The product in one paragraph.** A private, self-hosted, real-time chat app for a small
> circle of friends. It has exactly **three peer features**: **DMs** (1-on-1 chat),
> **Group chats** (named, invite-only, up to ~50 people, roles), and **Voice rooms**
> (standalone audio rooms with ephemeral text). Flat model — no Discord-style
> server/channel hierarchy. Everything is end-to-end encrypted: the server is a blind
> relay that stores only unreadable ciphertext and can never read messages, names, files,
> or audio. It may run on a self-hosted server inside a country during an internet
> shutdown, so the client uses **no foreign services** — no Google/Apple push, no CDNs, no
> external fonts/JS, no third-party analytics. Telegram is an interaction reference; the
> product's visual identity is defined in [`visual-design-system.md`](visual-design-system.md).

---

## Core rules that shape the whole UI (read once, applies everywhere)

These recur across screens. They are stated here so the individual screens can stay short.

- **The server can never read content.** Messages, files, images, voice audio, and even
  group/room **names, photos, and descriptions** are encrypted on the device before they
  leave it. The UI decrypts them locally for display. Never build a screen that assumes
  the server can provide readable content, search results, or a plaintext name.
- **Presence, typing, and read/delivery receipts are private, encrypted signals.** They
  travel inside the encrypted channel. Accepted tradeoff: they may **lag slightly** vs. a
  normal chat app. Design for a small delay; don't treat them as instant.
- **Search is client-side only.** The server never indexes or helps search, and never sees
  the query. Search covers only history stored and decrypted on **this device** — and each
  search surface states its own narrower scope, because the chat list matches names and one
  preview line while in-conversation search reads that conversation's whole local history
  (§6.5).
- **Foreground delivery uses the app's own server; Android background delivery is
  best-effort — never Google/Apple push.** By default that is deferred polling; a user may
  additionally turn on keeping the app connected while it is closed (§15), which is faster
  and still not a guarantee. Do not offer FCM/APNs-style options.
  Uncollected envelopes expire after seven days; a detected queue gap becomes a visible
  group-rejoin state.
- **Honesty over false comfort.** Several actions are **best-effort, not guarantees**, and
  the UI must say so plainly (detailed at each spot): *Delete for everyone*, voice-room
  *ephemeral* text, and history recovery. Never word a dialog to imply a stronger promise
  than the system can keep.
- **Two maturity labels, and they only read down.** A surface may be badged
  **Experimental** (it really transmits, nothing about it is reviewed or standardised,
  and its state is disposable) or **Not built yet** (routed and visible, nothing behind
  it). There is no badge meaning supported, stable, verified or audited, and none may be
  added: an unbadged surface is covered by the application-level label and by nothing
  stronger. Both words come from `SurfaceMaturity`; a screen that invents its own
  maturity wording is a defect ([ADR-045](decisions.md)).
- **A feature that does not work does not offer itself.** Where an action cannot
  succeed - no adapter is composed, no picker exists - the screen says so and disables
  the action. It never presents a control that fails into a generic error.
- **Two separate secrets, never conflated.** A **login password** authenticates to the
  server; a **recovery secret** protects cross-signing private identity material. Neither
  recovers message history from the server because the server stores none.
- **Verification precedes messaging.** SAS/QR verifies a contact's master key out of
  band. Until verified, Message/Invite actions are blocked. Unsigned devices, master-key
  changes, and device-log forks are blocking security states.

---

## 0. Global Layout & Navigation Model

### 0.1 Adaptive shell
One adaptive shell that changes structure by viewport width.

- **Mobile (narrow):** a **bottom tab bar** with three tabs: **Chats**, **Voice Rooms**,
  **Settings**. Each tab is a full-screen stack; tapping a list item pushes a detail
  screen; back gesture/button pops it.
- **Post-v1 desktop / web (wide):** a **two-pane layout**. A **left rail** holds the same three
  destinations plus the list for the selected one; the **right pane** shows the open
  conversation/room/detail. Selecting a list item swaps the right pane in place.
- **Tablet / medium:** two panes when wide enough, otherwise mobile behavior.

The destination set is identical across form factors; only the container differs.

### 0.2 Persistent elements
- **Active voice-room banner.** Whenever the user is joined to a voice room, a thin
  persistent banner sits above the bottom tab bar (mobile) or atop the left rail
  (desktop): room name, a live mic-state icon, and a "return to room" tap target. It stays
  on every screen until the user leaves the room; tapping it opens the Live Voice Room
  (§10).
- **Connection status strip.** When the client can't reach the server, a strip appears at
  the top of the current screen: "Connecting…" / "No connection to server". It clears only
  when the connection returns, not by user dismissal.

### 0.3 Global "new" affordance
- **Mobile:** a floating compose button (FAB) on the Chats and Voice Rooms lists; its
  action depends on the active tab (§7.3 recap).
- **Desktop:** a compose "+" at the top of the left rail's list header.

---

## 1. Splash / Connection Screen

**Purpose.** First screen on launch. Decides whether the app has a stored identity, whether
it can reach the server, and where to route. Also loads the pre-installed server-trust
setup the app was provisioned with.

**Layout.**
- Centered app name/logo placeholder (you supply the mark).
- A status line reflecting boot state.
- No top bar, no bottom bar — a standalone gate.

**Boot logic & routing.**
- Stored identity + reachable server → **Chats** (§6), already signed in.
- Stored identity + expired credential → **Login** (§2), username pre-filled.
- No stored identity → **Login** (§2) with a Register path.
- Server unreachable with no usable local identity → stay here in the unreachable state.
- Server unreachable with a usable Android identity → open cached Chats in offline mode;
  queued sends wait for reconnection. A future online-session-first Web client stays on
  the unreachable state until its configured server returns.

**States.**
- *Loading* — "Starting…" while local keys/trust load.
- *Reachable* — brief; auto-advances.
- *Unreachable* — "Can't reach the server" + **Retry**. **[PRIVACY]** No detail beyond
  reachable/unreachable; the app never pings any foreign service to test connectivity.
- *Not provisioned* — if the app was never set up with its server-trust config, show a
  blocking message that it must be installed from a trusted source, with no bypass.

---

## 2. Login Screen

**Purpose.** Sign an existing user in with username + password.

**Layout (top → bottom).**
1. Back/close only if reached from deeper; otherwise none.
2. App name/logo placeholder.
3. **Username** field.
4. **Password** field with show/hide toggle.
5. **Log In** primary button.
6. **Create account** link → Register (§3).
7. Footer link **"Security & how this app protects you"** → Security Notice (§5), viewable
   before login.

**Actions.**
- **Log In** → on success, if this device has no encryption identity yet, go to Encryption
  Setup (§4); otherwise go to Chats (§6).
- **Create account** → Register (§3).

**States.**
- *Idle* — Log In disabled until both fields filled.
- *Submitting* — busy button, fields locked.
- *Invalid credentials* — generic inline error ("Username or password is incorrect").
  **[PRIVACY]** No hint which field was wrong or whether the username exists.
- *Account inactive* — distinct message: the account exists but the owner hasn't activated
  it yet (see §3's Pending-Activation).
- *Server unreachable* — banner; Log In disabled.

**[PRIVACY]** The password only signs the user in; it never protects or recovers message
content. Nothing here should imply otherwise.

---

## 3. Register Screen (+ Pending-Activation state)

**Purpose.** Create a new account with minimal personal info — **username + password
only**.

**Layout (top → bottom).**
1. Back → Login.
2. Title "Create account".
3. **Username** field (inline format validation). Availability is checked only when the
   registration request is submitted because the backend exposes no availability probe.
4. **Password** field with show/hide + strength hint.
5. **Confirm password** field.
6. **Create account** primary button.
7. Footer link to Security Notice (§5).

**Actions.**
- **Create account** → account is created **inactive** (the owner must manually approve
  new accounts before they can be used). Route to **Pending-Activation** (below).

**Pending-Activation screen.**
- **Purpose.** Tell the user the account exists but is waiting for the owner to activate
  it.
- **Layout.** Centered text ("Your account is waiting for the owner to activate it"), a
  **Check again** button, a **Back to login** link. Check Again returns to Login with the
  username prefilled and asks for the password again; the pending screen does not retain
  the password or call a nonexistent activation-status endpoint.
- **States.** *Still pending* (unchanged on re-check) / *Now active* (route to Login §2 or
  into Encryption Setup §4).

**States (Register form).**
- *Idle / validating / submitting*.
- *Username taken* — inline error.
- *Passwords don't match* — inline error under Confirm.
- *Server unreachable* — banner; submit disabled.

---

## 4. Encryption Setup (First Run on a Device)

**Purpose.** The first installation creates account cross-signing keys plus independent
X25519 and ML-KEM-768 device material. MLS device material is created only after the
[PQ MLS production gates](mls-profile.md#production-gates) pass. A new account creates a
recovery-protected identity backup; an existing account restores that identity material.
Message history is a later transfer from an existing online device, not part of the
backup.

**Enrollment order.** Register the new device without `cross_sig`/`bundle_version`, then
use the returned device ID and full-scope tokens to finish cross-signing through the
prekey endpoint. For an existing account, retrieve and unwrap the identity backup only
after that response. While this second phase is pending, show "Finishing secure device
setup", support safe retry/resume, and withhold messaging; never offer an unsigned or
placeholder-key bypass.

### 4.1 Step — Generating identity
- **Layout.** Centered status ("Setting up encryption on this device") + progress
  indicator.
- **Behavior.** Device-private keys remain on this device. Cross-signing private keys may
  leave only inside the recovery-encrypted backup. Auto-advances when secure enrollment
  is possible; no user action.

### 4.2 Step — Recovery

**New-account branch — Your recovery secret.** Show the newly generated recovery secret
**once** and make the user save it.
- **Layout (top → bottom).**
  1. Title "Your recovery secret".
  2. Explanation: this restores the account's cross-signing identity if devices are
     lost. It does **not** restore messages; losing every device that holds history makes
     that history permanently unavailable because the server has no copy.
  3. The recovery secret in a clearly presented block.
  4. **Copy** button and, where the platform allows, **Download / Save**.
  5. **Continue** — disabled until the user copies/downloads or ticks an "I've saved it"
     checkbox.
- **[PRIVACY]** This recovery secret is **separate from the login password**, and the
  server never sees it. State that plainly on-screen.

**Existing-account branch — Restore identity.** Ask for the recovery secret, download
the opaque key backup, and decrypt cross-signing identity locally. Show wrong-secret,
restoring, and Retry states. History remains a separate online-device transfer.

### 4.3 Step — Confirm or restore
- **New-account purpose.** Stop users skipping the save.
- **Layout.** Either re-enter part of the secret, or an explicit "Yes, I've stored my
  recovery secret somewhere safe" checkbox + **Confirm**, plus a **Back** link to view it
  again during this onboarding flow only.
- **Existing-account purpose.** Show authenticated identity-restore progress and
  completion; never display or persist the entered recovery secret after the backup is
  unwrapped.

### 4.4 Step — Security notice handoff
- On completing setup, route into the **Security Notice** (§5) as a mandatory full-screen
  step before entering the app.

**States across the flow.** Standard loading/error. If uploading the user's public setup
fails (server unreachable), the flow **blocks with a retry** and never proceeds as if setup
succeeded.

---

## 5. Security Notice (Honest Safety Boundary)

**Purpose.** Tell the user plainly what the app does and does not protect. **This screen is
required and must be shown** — it is not optional marketing, and its "does NOT protect"
section must not be softened or omitted.

**When shown.**
- As a **mandatory full-screen step** at the end of first-run onboarding (§4.4), with an
  explicit acknowledge action to proceed.
- **Re-viewable anytime** from Settings (§15) and from the pre-login footer links (§2, §3).

**Layout (top → bottom).**
1. Title, e.g. "What this app protects — and what it doesn't".
2. **What it DOES protect** — what the user writes is encrypted on the device before it
   leaves it, and is unreadable to the server, to anyone watching the network, and to
   anyone who seizes the server. **It must name no feature.** This section is permanent
   and outlives any feature list, so an enumeration goes stale by default: until
   [ADR-052](decisions.md) it promised "messages, files, and voice audio" in an artifact
   that could send no file and carry no audio, and a test now forbids feature words here.
3. **What it does NOT protect** — stated plainly, and **in the reader's vocabulary rather
   than the project's**:
   - **when** the user connects, **from where**, **how much** they send, and **who they
     talk to** — whoever runs the server sees all of it, even though not *what* was said;
   - that a new contact is really who they say they are, until the two of them compare the
     **safety number** — by the name the app's own screen uses for it (§10), not "SAS",
     "fingerprint" or "out of band";
   - messages **already open on a phone somebody else has taken or broken into**.
   Wording must not imply the app makes communication "safe from the government"; it makes
   **content** unreadable — the rest is the user's informed risk. A limitation the reader
   cannot decode is a limitation that has not been disclosed (ADR-052).
4. **What this build is** — the deployment disclosure required by
   [ADR-045](decisions.md), whose exact points and order are
   `DeploymentDisclosure.privateExperimental`. Present **only** in a build that is
   distributed to someone. At revision 7 that is eight short facts, ordered by
   consequence — no independent review; how and when messages arrive while the app is
   closed, including the opt-in tier and its cost; that messages left waiting on the
   server are deleted unread and never arrive; history stored only on this device;
   recovery restores identity and never messages; group chats use experimental encryption
   that can be reset, and are switched off entirely on a processor it has not been tested
   on (ADR-055 moved this point to "switched off" when no group stack was reachable at all;
   ADR-056 restored the first half once one ABI was measured, and kept the second, because
   the point now has to be true for a reader on either kind of phone);
   parts of the interface are not built; who the build is and is not for.
   **[PRIVACY]** No cryptographic identifiers, draft names, or registry state here — they
   are true and unreadable, and they would bury the facts that matter. Sections 2 and 3
   are permanent and stay true in a production release; this section must be absent from
   one.
5. In onboarding: an **"I understand"** button (required to proceed). From Settings: a
   plain **Close/Back**. In the re-presentation (below): the same **"I understand"**.

**One notice, three entry points.** The onboarding step, the Settings entry (§15) and
the pre-login links (§2, §3) render the same sections in the same order. A shorter or
differently-titled variant at any entry point is a defect: a user re-reading what they
acknowledged must find the statement they acknowledged.

**Not repeated.** Acknowledgement happens once per device, in onboarding. The notice is
never re-shown on a schedule or after an ordinary update; ADR-045 records the measured
evidence that repetition destroys a warning and degrades the app's other blocking
security states. Re-acknowledgement is triggered only by the disclosure content
changing.

**Shown again, once, when the content does change.** The revision the user accepted is
recorded on the device, so a build whose disclosure revision is higher re-presents the
statement on the first launch after the update ([ADR-052](decisions.md)). It is a
**full screen**, not a banner and not a notification: the app posts message alerts (§15)
and can post a permanent service notice, and habituation to routine notifications
transfers to warnings that resemble them. It renders **the same sections in the same
order** as every other entry point, adds a heading saying the statement has changed, and
marks the points that moved with a **labelled badge** — never colour alone, because the
mark is the reason the screen exists and a screen reader must reach it. A reader with no
recorded revision is shown the whole statement with **nothing** marked: marking every
point marks none of them, and no record means the app does not know what they saw. It is
never shown before enrollment completes, and never shown at all if the record cannot be
read — an honesty mechanism must not lock somebody out of their messages.

---

## 6. Chats List (Home / Chats tab)

**Purpose.** Telegram-style unified list of all DMs and group chats, plus any active voice
rooms pinned at top. The primary hub.

**Layout.**
- **Top bar:** left — title "Chats" (or an avatar/menu affordance opening Settings on
  mobile); center/right — a **search** entry point and, on desktop, the compose "+".
- **Search:** tapping the search entry opens Search (§6.5).
- **Body:** scrollable list. Order: pinned items first (including active voice rooms and
  pinned conversations), then the rest by most recent activity.
- **Bottom (mobile):** the tab bar (Chats / Voice Rooms / Settings) + FAB.
- **Active voice-room banner** (§0.2) sits above the tab bar when applicable.

**Each conversation item shows:**
- Avatar (contact photo for DMs; group photo for groups — decrypted locally).
- Title (contact/group name — decrypted locally).
- Last-message preview (decrypted locally).
- Timestamp of last activity.
- Unread count badge.
- Mute icon if muted. A mute that expires while the list is on screen clears the icon at the
  moment it expires ([ADR-064](decisions.md)) — the row is not left claiming a mute that has
  ended until something else happens to redraw it.
- Pin marker if pinned.
- Optional delivery/read state on the last outgoing message.

**Item interactions.**
- **Tap** → DM (§8) or Group (§9) chat screen.
- **Long-press (mobile) / right-click (desktop)** → context menu: **Pin/Unpin**,
  **Mute/Unmute** (opens mute options §17), **Mark as read/unread**, **Delete chat**
  (→ confirm; for DMs this clears the conversation locally — honest wording).

**FAB / compose (§0.3)** → **Contacts / New** (§7).

**States.**
- *Loading* — skeleton list while the local store loads and the connection comes up.
- *Empty* — friendly empty state with "Start a chat" → Contacts (§7).
- *Offline* — connection strip at top; cached conversations still show and are fully
  readable (content is stored and decrypted locally). New sends queue (§8 states).

### 6.5 Search (client-side only)
**Purpose.** Find the user's own conversations and messages. **[PRIVACY] The server never
indexes or assists — nothing searchable ever leaves the device, and neither does the query.**

Search is built, and it is **two separate surfaces with two different scopes**. Each must
state its own scope; borrowing the other's is a false promise ([ADR-052](decisions.md)).

- **The chat-list box (this screen).** Filters the conversation list on **name and latest
  message only**. It does not read history. Its hint and its empty state say so, and point
  the user at the in-conversation search for anything older.
- **In-conversation search (§8, §9, §14).** One surface, opened from the overflow of
  every conversation kind — direct, saved and group. It reads **that conversation's loaded
  local history** — the message stream carries a window since [ADR-062](decisions.md), and
  what is loaded grows as the reader pages backwards — and a matching result scrolls the
  timeline to the message, loading it first if it sits outside the window. Its notice says
  the search covers only messages stored on this phone, and that the server never sees them
  or the query. It shows at most 30 matches at a time and **says so** when it is showing
  that many, because a silently capped result set misdescribes the scope the notice just
  promised ([ADR-057](decisions.md)).
- **States.** Empty query, no results, the match count, the truncation notice, and the
  scope note belonging to that surface.

A single merged results screen grouping **Chats** / **Messages** / **Contacts** is not
built. Nothing in the app offers it, and the disclosure does not imply it. Contacts are
filtered where they are listed (§7), which is the third and last search surface.

**[PRIVACY]** There is no separate search index. The encrypted database is the index:
the decrypted message projection lives inside it, under the Keystore-wrapped key, and a
search is a filter over rows that are already there. A second structure would hold a
second copy of every message body ([ADR-057](decisions.md)).

---

## 7. Contacts / New Chat

**Purpose.** Start a DM, create a group, or create a voice room. Reached via compose
(§0.3) or the empty-state CTA.

**Layout.**
- **Top bar:** back/close; title "New".
- **Action rows at top:** **New Group** → Create Group (§12.1); **New Voice Room** →
  Create Voice Room (§13.1).
- **Contacts list:** the users this client knows about. Each row shows the authenticated
  profile avatar/display name when available. Before a profile key is received, it shows
  the backend username and a locally generated placeholder avatar, plus no verified-key
  indicator. A verified indicator appears only after the safety number (§11.1) is
  verified; unverified cached profile content never replaces the fallback.

**Interactions.**
- **Tap a contact** → open/create a DM (§8).
- **Search field** filters by name.

**States.** *Loading*, *empty* (no other users known yet), *offline* (cached contacts).

### 7.3 Compose behavior recap (tab-dependent "+")
- On **Chats**, compose opens **Contacts / New** (§7) → DM, or branch into New Group /
  New Voice Room.
- On **Voice Rooms**, compose opens **Create Voice Room** (§13.1) directly.

---

## 8. DM Chat Screen

**Purpose.** 1-on-1 encrypted text conversation with the full chat experience.

**Layout (top → bottom).**
1. **Top bar:**
   - Left: back (mobile).
   - Center: contact avatar + name + a presence/last-seen line (**[PRIVACY]** encrypted,
     volatile signal; may lag).
   - Tapping name/avatar → **Contact Profile** (§11).
   - Right: overflow (**⋮**) → **Search in chat**, **Mute** (§17), **Verify safety number**
     (§11.1), **Clear history** (→ confirm, honest wording), **Block/Unblock**.
2. **Message list (body):** scrollable oldest→newest, sticky date separators.
   - **Message bubble:** text (decrypted locally), timestamp, outgoing delivery/read state,
     an **edited** marker if edited, a reply-quote block if it's a reply, reaction chips
     beneath, a star marker if starred.
   - **Pinned banner** atop the list if any message is pinned; tap to jump; expand → all
     pinned messages (§8.3).
3. **Input bar (bottom):**
   - **Attachment** button → attachment sheet (§8.2).
   - Text input (multiline, grows).
   - **Emoji** — always present; opens the full emoji picker and inserts the chosen
     glyph at the caret. Dismissing the picker leaves the draft untouched.
   - **Send** (appears when text present, beside the emoji button rather than in place
     of it).
   - When replying/editing, a **context strip** above the input shows the quoted/edited
     message with a cancel (×).
   - **Draft.** An unsent draft is kept per conversation and restored when it is reopened.
     It is written down on a short trailing pause rather than on every character
     ([ADR-064](decisions.md)), and it is written down *immediately* on every way out of the
     composer: losing focus, leaving the screen, the application leaving the foreground, and
     sending. So a draft is never lost by backgrounding or by leaving, and sending never
     leaves the sent text behind as a draft. What is on screen is always the draft; the
     debounce is about when storage catches up, and nothing the user can do reads the stored
     copy back over what they are typing.

**Message interactions.** A **single tap** or a right-click opens the context menu with the
**reaction selector** floating above it, anchored to the message. A **double tap** sets 👍
straight away, or removes it when it is already this user's, and opens nothing. There is no
long-press.

- **React** — the floating selector: twenty-four common reactions in one horizontally
  scrollable row, the current user's marked as selected, tapping it again removes it, and
  an expand control at the trailing edge that opens the full emoji picker. Reactions are a
  set operation per `(message, user)`, so choosing a second one replaces the first.
  **[PRIVACY]** the reaction is encrypted, and the server never sees the emoji. No control
  anywhere sends a fixed emoji ([ADR-059](decisions.md)).
- **Reply** — sets the reply strip.
- **Edit** (own messages) — loads the message into the input with an edit strip.
- **Forward** — Forward target picker (§8.4).
- **Copy** — local clipboard.
- **Star/Unstar** — client-side flag.
- **Pin/Unpin**.
- **Delete** → **Delete dialog** with two clearly labeled options: **Delete for me** (local
  only) and **Delete for everyone** (**best-effort**). **[PRIVACY]** The dialog must state
  honestly that *Delete for everyone* cannot force other devices to forget content they've
  already received and decrypted.

**States.**
- *Loading* — history loads locally; older messages page in on scroll-up. The timeline holds
  a window rather than the whole conversation ([ADR-062](decisions.md)): reaching the top of
  what is drawn widens the drawn range first and then asks local storage for an older page,
  the marker at the top shows loading and offers a retry when that page fails, and a message
  arriving joins the timeline without moving the line being read. A jump — from the pinned
  banner, a reply quote or a search result — loads its target when it is older than anything
  loaded.
- *Empty* — new-conversation placeholder.
- *Sending / queued* — pending state; **offline** sends queue locally and flush on the
  next active connection or background poll; there is no foreign push.
- *Failed send* — retry affordance on the message.
- *Offline* — connection strip; existing history fully readable; composing allowed, sends
  queued.

### 8.2 Attachment sheet
- Options: **Photo/Image**, **File**, and camera on mobile. Picking shows a **preview +
  caption** step with send/cancel. **[PRIVACY]** Files/images are encrypted on the device
  before upload; the server stores only ciphertext.

### 8.3 Pinned messages screen
- All pinned messages in the conversation. Each row: preview + jump-to + **Unpin**.

### 8.4 Forward target picker
- **Purpose.** Choose where to forward a message. **[PRIVACY]** Forwarding re-encrypts the
  message for the new recipients — it is not a server-side copy.
- **Layout.** Searchable list of DMs and groups (and Saved Messages). Multi-select; a
  **Forward** confirm button.

---

## 9. Group Chat Screen

**Purpose.** Named, invite-only encrypted group chat, full chat experience. Persistent
history; up to ~50 members; roles **owner → admins → members**.

**Layout.** Same skeleton as the DM screen (§8), with group differences:
1. **Top bar:**
   - Center: group photo + name + a subtitle with member count / a few names (decrypted
     locally).
   - Tapping title/photo → **Group Info** (§12.2).
   - Overflow (**⋮**): **Search in chat**, **Mute**, **Group info**, **Leave group**
     (→ confirm), and admin/owner-only entries here or in Group Info (**Add members**,
     **Edit group**).
2. **Message list:** as §8, but incoming bubbles also show the **sender's name/avatar**.
   Inline system lines appear for membership changes ("X was added", "Y left").
3. **Input bar:** as §8. By default all members can post; if you implement any
   posting restriction, disabled states must explain why.

**Message interactions:** identical to §8 (reply, react, edit own, forward, copy, star,
pin, delete-for-me / delete-for-everyone). A pin is visible to all members via the pinned
banner.

**Role-gated actions** (owner/admins only): appear on member rows within Group Info
(§12.2), not on individual messages.

**States.** As §8, plus: *membership updating*; *removed* (read-only/exited, with no access
to future epochs); and *queue gap — rejoin required*. The queue-gap state disables the
composer until peers remove and re-add this device with a fresh Welcome.

---

## 10. Live Voice Room Screen

**Purpose.** The active audio session for a **standalone, persistent, audio-only** voice
room with an **ephemeral** alongside text chat. All members are equal peers — no admin
hierarchy.

**Layout (top → bottom).**
1. **Top bar:** room name; a **participant count**; a **Room info** affordance (§13.2); a
   **minimize** control that collapses to the persistent banner (§0.2) while keeping the
   user in the room.
2. **Participants area (main):** tiles for each participant — avatar + name + a **live
   speaking/mic indicator** (speaking, muted). **[PRIVACY]** Audio is end-to-end
   encrypted; the media server forwards it without being able to listen.
3. **Ephemeral text chat panel** (a toggle/tab on mobile, a side panel on desktop):
   messages here **disappear when the room empties** and are not stored on the server. The
   panel must plainly indicate it's ephemeral. Simplified input (text + send); no
   persistent features like pin/star here.
4. **Bottom control bar:** **Mute/Unmute** self, **Speaker/output** where applicable,
   **Invite** (§13.3), **Leave** (leaves the session; the room persists and can be rejoined
   later).

**Interactions.**
- Tapping a participant tile → a small sheet with their name and, if not yet verified, a
  link to verify their safety number (§11.1).
- **Leave** returns to the previous screen; the persistent banner disappears.

**States.**
- *Connecting* — establishing the session; connecting indicators on tiles.
- *Connected* — normal.
- *Reconnecting* — a network blip; audio drops with a reconnecting indicator; the text
  panel shows its volatile state.
- *Empty room (you're alone)* — a single-tile state inviting others.
- *Room ended / everyone left* — ephemeral text is dropped; next open shows the room empty
  and rejoinable.
- *Offline / can't reach the server* — an honest error; no foreign fallback is attempted.

---

## 11. Contact Profile (+ Safety-Number Verification)

**Purpose.** View a contact, control per-contact settings, and verify their identity key.

**Layout (top → bottom).**
1. **Top bar:** back; overflow if needed.
2. **Header:** large avatar, display name, presence/last-seen line (encrypted, volatile).
3. **Action rows:**
   - **Message** → DM (§8).
   - **Mute** → mute options (§17).
   - **Verify safety number** → Safety Number screen (§11.1).
   - **Shared media/files** → a media grid from this DM, decrypted locally (§11.2).
   - **Clear history** → confirm, honest wording.
   - **Block/Unblock** → confirm. Blocking is private client state synchronized only to
     the user's own devices. It suppresses display, receipts, presence, typing, and
     notifications from the contact, but cannot prevent the sender from submitting
     ciphertext to the backend; the client still safely drains and acknowledges it.

### 11.1 Safety Number screen
- **Purpose.** Compare a contact's key fingerprint to make sure no one — not even a
  malicious server — is impersonating them or intercepting messages.
- **Layout.** SAS emoji/number text derived from both users' exact master keys, a QR code
  containing the master-key fingerprint, a **Confirm verified** action, and instructions
  to compare in person or over another trusted channel. Confirmation cross-signs the
  peer's exact master-key bytes with the user's user-signing key.
- **States.** *Unverified — messaging withheld*, *verified*, **master key changed**,
  **unsigned/invalid device**, and **device-log fork**. The latter states block sending;
  they are not dismissible warnings or automatic TOFU resets.

### 11.2 Shared media screen
- A grid of images/files from the conversation, decrypted locally, with tap-to-open and
  jump-to-message.

---

## 12. Groups — Create & Info

### 12.1 Create Group flow
Reached from Contacts (§7). Multi-step:
1. **Pick members** — searchable contact list, multi-select, **Next**. (~50 cap guidance.)
2. **Group details** — set **name**, **photo**, optional **description**. **[PRIVACY]** All
   three are encrypted; the server stores only ciphertext.
3. **Create** — the creator becomes **owner**; opens the Group chat (§9).
- **States.** validating name, creating, error/offline.

### 12.2 Group Info screen
**Purpose.** View/manage a group. Some controls are visible only to owner/admins.

**Layout (top → bottom).**
1. **Top bar:** back; an **Edit** affordance for owner/admins → §12.3.
2. **Header:** group photo, name, description, member count.
3. **Quick actions:** **Mute**, **Search in chat**, **Shared media** (grid like §11.2).
4. **Members section:** each row — avatar, name, a **role tag** (owner/admin/member), a
   verified-key indicator if verified.
   - **Tap a member** → sheet with **Message** (DM), **Verify safety number** (§11.1), and
     **owner/admin-only**: **Remove from group** (→ confirm). **[PRIVACY]** Removing a
     member cuts off their access to future messages.
   - **Add members** (visible per the group's invite policy) → member picker (like §12.1
     step 1).
5. **Leave group** (all members) → confirm.

### 12.3 Edit Group screen (owner/admin)
**Purpose.** Edit group identity and settings. These are owner/admin powers.

**Controls.**
- **Group name** field (encrypted).
- **Group photo** picker (encrypted).
- **Description** field (encrypted).
- **Invite policy** — **the owner sets who may add new members** (present as a selectable
  policy; you'll implement the exact options the backend supports).
- **History for new members** toggle — an **owner, per-group** setting, **default = show
  past history**. Include an honest note: when on, an existing member's device **re-shares
  the backlog** to the newcomer (the server can't, since it only holds ciphertext the
  newcomer can't read), and this is an intentional, accepted tradeoff.
- **Save** / **Cancel**.
- **States.** saving, error, permission-denied (if the user's role changed underneath).

---

## 13. Voice Rooms — List, Create & Info

### 13.0 Voice Rooms list (Voice Rooms tab)
- **Layout.** A list of the user's voice rooms. Each row: room name (decrypted locally) and
  a state line (**Live now** with participant count / **Empty**). Any room the user is
  currently in also drives the persistent banner (§0.2).
- **Interactions.** Tap → Voice Room Info (§13.2) or straight into the Live Room (§10) if
  already live — your call which; be consistent. Compose (§7.3) → Create Voice Room.
- **States.** loading, empty ("No voice rooms yet"), offline (cached list).

### 13.1 Create Voice Room flow
Reached from Contacts (§7) or the Voice Rooms tab compose. Multi-step:
1. **Room details** — set **room name** (encrypted). Voice rooms are standalone, not tied
   to any DM or group.
2. **Invite members** — searchable contact multi-select (all invited are equal peers).
3. **Create** — creates the persistent room and opens it (or its info card).

### 13.2 Voice Room Info screen
**Purpose.** View/manage a room outside the live session.

**Layout (top → bottom).**
1. **Top bar:** back; **Edit** (rename / manage invites — no admin gating, all peers).
2. **Header:** room name; a state line (**Live now** + count / **Empty**).
3. **Primary action:** **Join** (→ Live Voice Room §10), or **Rejoin** if empty (the room
   is persistent and outlives everyone leaving).
4. **Members/invited list:** each row — avatar + name; an **Invite** action → picker
   (§13.3). No role tags (all peers).
5. **Leave room / remove yourself** as applicable. Confirmation explains that this
   removes local membership, keys, capability, and live access after notifying peers; it
   does not delete the persistent backend room or revoke copies of its capability held by
   others. Returning requires a fresh authenticated invite.

**[PRIVACY]** Room name is encrypted; the server stores ciphertext. The alongside text
chat exists only during a live session and is dropped when the room empties.

### 13.3 Voice Room invite picker
- Searchable contact multi-select + **Invite** confirm. Adds peers to the room.

---

## 14. Saved Messages

**Purpose.** A personal self-conversation to save/keep your own messages, encrypted to your
own device keys.

**Layout.** Same skeleton as the DM chat (§8), with the "contact" being the user
themselves. Supports the features that make sense solo: send text/files, star, pin, search,
forward (into other chats), delete-for-me. No receipts/presence (no other participant).

**Access.** From Settings (§15) and as a target in the Forward picker (§8.4). May also
appear pinned in the Chats list.

---

## 15. Settings (Settings tab / home)

**Purpose.** Account, security, devices, and app preferences hub.

**Layout (top → bottom list):**
1. **Profile header** — the user's avatar + display name; tap → **Edit profile** (§15.1).
2. **Saved Messages** → §14.
3. **Linked Devices** → §16.
4. **Security & recovery** → Security settings (§15.2).
5. **Notifications** — what the operating system will actually do, read from the operating
   system rather than from a stored preference (ADR-048). Three states: **on**, with a line
   stating that an alert says only that something arrived, never who sent it or what it
   says, and that it can only reach the user while the app is running; **off**, with one
   action that asks Android and falls through to this app's system notification settings
   when asking changes nothing, because a second refusal is permanent and the app can no
   longer prompt; and **not available in this build**, on any target with no alert
   implementation behind it.
   **[PRIVACY]** Active-app delivery uses the self-hosted connection and Android
   background delivery is best-effort, **not** Google/Apple push. Do not offer
   push-service or always-instant options, and do not offer a decrypted-preview switch
   without the reviewed bilingual lock-screen warning that has to accompany it. Per-
   conversation mute already lives on the conversation, not here.
5b. **Receiving while closed** — the opt-in capability that keeps the app connected while
   it is not in use (ADR-051). A row stating the current state, and one screen behind it.
   The screen states, in this order and before any switch: what it does; what it costs —
   more battery, and a permanent notice anyone who unlocks the phone can see, which stays
   until it is turned off; what it cannot promise — the phone may stop it at any time
   without saying so, and a force-stop or a "restricted" battery setting ends it entirely.
   Then the three things the phone needs: notifications, the battery-optimization
   exemption, and, on Samsung and Xiaomi, exclusion from the manufacturer's own
   app-sleeping — the last stated plainly as something **only the user can do and this app
   cannot check**, with one button that opens the phone's own screen and reports nothing
   back. Every degraded state has a sentence of its own: notifications withheld, exemption
   withdrawn (which can happen by itself after a phone update), not running, not available
   in this build. **Off is the default and a complete state**: nothing runs, nothing is
   requested, nothing appears anywhere, and the row says so. This surface is reached only
   from Settings and is never suggested, prompted or advertised elsewhere.
6. **Appearance** — client-only display preferences (the option *set* is your call; no
   styling prescribed here).
7. **Security notice** — re-open the honest boundary screen (§5).
8. **Log out** → confirm. **[PRIVACY]** The confirm clearly states whether local
   history/keys are wiped. The recovery secret can recover cross-signing identity, not
   messages; history returns only from another device that still has it.
9. **About** — app/version info (all local; no external calls): the build's own name,
   the packaged version, which build it is, and the revision of the statement this
   build carries. It states that nothing on it was fetched. Behind it sits
   **Diagnostics** (§15.3).
10. **Erase this account** → confirm (§15.4). Last in the list, marked destructive, and
   separated from log out by a gap of its own: the two are not a pair, and a thumb that
   missed the reversible one must not land on the irreversible one.

### 15.1 Edit Profile
- Set display name and avatar. State clearly what is visible to contacts. (Keep personal
  info minimal.)

### 15.2 Security settings
- **Recovery secret** — replacement guidance; an already-saved secret is never re-shown
  because the app does not retain it. An unlocked device may generate a fresh secret,
  rewrap the same cross-signing identity material, upload a higher backup version, show
  the new secret once, and invalidate the old secret. Honest note: the server holds only
  an **unreadable identity backup** and no message history.
- **Safety numbers** — a shortcut to review verified contacts (§11.1): every known
  contact with the trust state the conversation screens gate on, tapping through to that
  contact's Safety Number screen. An unverified row never renders cached profile
  identity.
- **Security notice** link (§5).

**Replacement flow states.** *Explain* (what it does, what it costs, and that a recovery
secret restores identity and never history) → *working* → *shown once* → *done*, with a
single *failed* state. Screen capture is blocked for as long as the screen is open, and a
copy goes through the clipboard path that expires; a build without that path says copying
is unavailable rather than using a clipboard that never clears. **The new secret is shown
only after the server has accepted the higher backup version.** Every failure says the
current secret still works, because it does ([ADR-057](decisions.md)).

### 15.3 Diagnostics

**Purpose.** A short technical report the user can copy and hand to whoever runs their
server. Reached from About and from nowhere else.

**[PRIVACY]** The report cannot contain a message, a name, an address, a key, a token or
any identifier — not by review but by construction: its values are booleans,
enumerations, order-of-magnitude counts and compile-time constants, and there is no way
to put text into one. Counts are bucketed and the timestamp is an hour, because an exact
description of one person's usage is a needlessly precise thing to put in a document they
may pass on.

**Layout.** The explanation, a statement that the application sends it nowhere, the
**complete report text exactly as it will be copied**, and a Copy action. What is on the
screen and what reaches the clipboard are the same bytes; showing a summary and copying
something larger would ask a person to share a document they have not read. The report
itself is locale-independent ASCII — its recipient may not read the sender's language —
while the chrome around it is translated.

**States.** *Reading this device*, *report*, *copied*, *clipboard refused*, and a re-read
action.

### 15.4 Erase this account

**Purpose.** Leave. `DELETE /api/v1/me` deletes the account and every row that depends
on it — devices, prekeys, published identity, key backup, device-list log, profile
blob, and every queued envelope of every device. Until the client offered it, a user who
wanted to go had to ask the operator, who could only deactivate.

**The confirmation asks for the account password.** It is the only authenticated route in
this API that does, because a session token lives thirty days and nothing detects its
theft, so the one irreversible act asks for the secret a stolen token does not carry. The
password goes in the request body and is stored, cached and logged nowhere. The
ten-character rule this client applies when a password is *created* is deliberately not
applied here: an account whose password predates that rule must still be able to leave.

**[PRIVACY] The wording is the requirement, not decoration around it.** `SECURITY.md`
§ "Best-effort features, worded honestly" keeps three deletion meanings apart — a
remote-deletion request, server ciphertext deletion, and cryptographic erasure — and
none may ever be described as another. A dialog reading "delete my data" or "erase my
messages" claims the third and performs the second. All four statements below are
present before the field, and none may be dropped, summarised into another, or moved
behind a "more" affordance:

1. **What it erases** — everything the server holds for this account.
2. **What it does not** — the copies other people hold. Every message this account sent
   was decrypted on the recipient's device and is stored there; nothing in this call
   reaches another device. This is the load-bearing sentence and carries the emphasis.
3. **Attachments** — they stay on the server until the retention window expires them,
   stated as *up to N days*. Nothing on a stored attachment names an account, so there is
   no set of them this call could identify as the account's. `N` is 30 while it is a
   constant in client code; a later phase reads `attachment_ttl_days` from
   `GET /api/v1/config`, which an operator may change.
4. **The username** — free again at once, and another person may register it.

**States.** *Confirm* (the four statements, the password field, erase and cancel) →
*working* → gone. Cancel is a complete outcome and the barrier is not a way out: a form
holding a typed password may not be dismissed by a stray tap beside it.

**Failure states**, each in reviewed application strings and never a server `detail`:

- **Wrong password** — said plainly, with the tries counted, and with the cost of the
  last one stated *before* it is spent: five wrong tries lock the username for fifteen
  minutes on this route and on the sign-in route alike, on every device. The count is
  this client's own tally, so an attempt from another device is absent from it and the
  server may lock sooner than the number suggests.
- **Throttled** — the `Retry-After` wait, rounded *up*, because naming a moment the
  server still refuses costs the user a second refusal. The same `throttled` code carries
  both the account's ordinary rate limit and the per-name lock, and only the `detail`
  text tells them apart — which is not a thing to branch on — so one wording holds for
  both.

**After it lands.** The local store is cleared the way a log-out clears it and the user
arrives at the sign-in screen. A retry whose first answer was lost gets `401
token_revoked`; the device that token named went with the account, so that is the same
outcome and is never reported as a revoked session.

---

## 16. Linked Devices

**Purpose.** Manage the user's Android device. A future Web profile will be independently
keyed and cross-signed by the account identity. Add a device, authorize it, and optionally
transfer locally held history.

**Layout (top → bottom).**
1. **Top bar:** back; title "Linked Devices".
2. **This device** row — current device, marked.
3. **Other devices** list — each row: device label, last-active (as available, at the
   day-level coarseness the backend reports and **not** shifted into local time), and
   **Remove device** (→ confirm). Removing revokes it. Removing *this* device is a
   distinct confirmation, because it also erases everything on this phone.
4. **Add device** — an explanation, not a button. The flow in §16.1 starts on the *other*
   device, so this screen has nothing to start; what it says is what the other device
   needs, and that this one should stay online afterwards so it can send its history
   across, because the server has none to send ([ADR-057](decisions.md)).

### 16.1 Add Device flow
- **Purpose.** Bring a new device online, recover/cross-sign identity, then optionally
  transfer encrypted history from an existing online device.
- **Steps.**
  1. On the **new** device, login and enter Encryption Setup (§4).
  2. After unsigned registration returns full-scope tokens, restore cross-signing
     identity using the recovery secret and finish the device cross-signature through
     the prekey endpoint.
  3. Establish fresh hybrid sessions; peers remove/re-add the device to groups for fresh
     Welcomes where required.
  4. Ask an existing online device to send its locally held history through ordinary
     encrypted envelopes. Show the source device and whether its history is partial.
- **States.** *registering device*, *awaiting secret*, *restoring identity*, *wrong
  secret*, *finishing secure setup*, *identity recovered*, *waiting for existing
  device*, *transferring history*, *no history source online*, *group re-invitation
  required*, *queue gap recovery*, and *done*. **[PRIVACY]** The server supplies no
  ciphertext history and the recovery secret cannot reconstruct it.

---

## 17. Global Dialogs, Sheets & Menus (referenced above)

The recurring modal surfaces and their contents:

- **Delete message dialog** (§8) — two labeled options, *Delete for me* / *Delete for
  everyone*, with the honest note that "for everyone" is best-effort.
- **Confirm dialogs** — Leave group, Remove member, Remove device, Clear history, Log out:
  each states the consequence plainly, including irreversibility where true.
- **Mute options sheet** — durations / until toggled.
- **Emoji reactor** (§8) — the floating reaction selector, which opens with the message
  context menu and is drawn above it, plus the full emoji picker its expand control opens.
  The same picker serves the composer's emoji button ([ADR-059](decisions.md)).
- **Attachment sheet** (§8.2).
- **Context menus** — message long-press menu (§8/§9) and conversation-list item menu (§6).
- **Forward target picker** (§8.4).
- **Member/participant sheets** — group member sheet (§12.2), voice participant sheet
  (§10).

Every dialog that performs an irreversible or best-effort action must carry honest wording
— no dialog may imply a stronger guarantee than the app can keep.

---

## Appendix A — Screen Inventory (flat list)

1. Splash / Connection (§1)
2. Login (§2)
3. Register (§3)
4. Pending-Activation (§3)
5. Encryption Setup — Generating (§4.1)
6. Encryption Setup — Recovery (§4.2)
7. Encryption Setup — Confirm or restore (§4.3)
8. Security Notice (§5)
9. Chats List (§6)
10. Search (§6.5)
11. Contacts / New (§7)
12. DM Chat (§8)
13. Attachment sheet (§8.2)
14. Pinned messages (§8.3)
15. Forward target picker (§8.4)
16. Group Chat (§9)
17. Live Voice Room (§10)
18. Contact Profile (§11)
19. Safety Number (§11.1)
20. Shared media (§11.2)
21. Create Group (§12.1)
22. Group Info (§12.2)
23. Edit Group (§12.3)
24. Voice Rooms list (§13.0)
25. Create Voice Room (§13.1)
26. Voice Room Info (§13.2)
27. Voice Room invite picker (§13.3)
28. Saved Messages (§14)
29. Settings home (§15)
30. Edit Profile (§15.1)
31. Security settings (§15.2)
32. Appearance (§15, item 6)
33. Recovery-secret replacement (§15.2)
34. Safety-number review (§15.2)
35. About (§15, item 9)
36. Diagnostics (§15.3)
37. Linked Devices (§16)
38. Add Device (§16.1)
39. Global dialogs/sheets/menus (§17)
