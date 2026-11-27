# Product requirements

## Product statement

Communication Platform is the working name for a private, self-hosted chat application
for a small circle of friends. It provides direct messages, invite-only groups, and
standalone voice rooms without a foreign runtime dependency. The final name and logo are
placeholders and do not block engineering.

## Supported platforms

- Android is the only version-1 production target.
- The Web target was removed under
  [server ADR-0020](../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md).
  A browser release would require an explicit decision and compatible server support.
- iOS, Windows, macOS, and Linux applications are out of scope.
- The interface supports English and Persian from the first release, including RTL,
  mixed-direction message text, and localized dates.

## Release scope

The first production release includes the complete screen inventory in
[ui-specification.md](ui-specification.md): authentication, encryption onboarding, chat
list, search, contacts, DMs, groups, voice rooms, profiles and safety numbers, Saved
Messages, settings, linked devices, recovery, and all referenced dialogs and states.

The implementation may be delivered in vertical milestones, but an incomplete milestone
is not called the production release. [Frontend status](STATUS.md) records the
implementation and evidence against this scope.

## Privacy invariants

- The server MUST never receive message, profile, group, room, attachment, or media
  plaintext or a content-encryption key.
- The client MUST NOT use FCM, APNs, foreign analytics, CDNs, remote fonts, remote
  scripts, or public connectivity probes.
- Conversation and contact-list search stays local. Explicitly finding a person by exact
  username uses [the lookup contract](../../docs/client/CLIENT_CONTRACT.md#p-finding-a-contact).
- Login passwords and recovery secrets are distinct in storage, behavior, and wording.
- Verify cross-signing master keys out of band before messaging. Direct content requires
  [mutual verification](../../docs/client/CLIENT_CONTACTS_AND_TRUST.md). Unsigned devices,
  master-key changes, and device-log forks fail closed.
- New direct-message and group sessions use hybrid X25519 + ML-KEM-768 without silent
  classical downgrade; a group is a set of pairwise sessions.
- Delete-for-everyone, ephemeral room text, and recovery limitations are described
  honestly and never as guarantees.
- Logs and diagnostics MUST exclude plaintext, identifiers, tokens, keys, ciphertext
  bodies, URLs carrying capabilities, and attachment metadata.

## Functional behavior

- The local database is the UI source of truth.
- Cached Android conversations remain readable offline; sends enter a durable outbox.
- A message received from REST and WebSocket is displayed once.
- Multi-device delivery includes every live peer device and the sender's other devices.
- The server stores no history. Message history remains on client devices and a new
  device receives it only through an encrypted transfer from an existing online device.
- The recovery backup restores cross-signing identity material, not message history,
  ratchets, group control state, or authorization.
- Surface a mailbox `pruned_through` gap as recoverable loss. Affected groups withhold sends
  and changes until a member confirms their signed control state. The Android client has
  no direct-chat gap UI yet. See [queue-gap recovery](architecture/SYNC.md#queue-gap-recovery).
- Revoked devices lose tokens, queued content, local session access, and future group
  access.
- Voice is audio-only: a full mesh of WebRTC connections between devices, each keyed by
  DTLS-SRTP between its two endpoints, every path across the self-hosted coturn relay.
  There is no media server and no application-level media key. A room is client state
  exactly as a group is, and a call holds ten joined devices.

## Non-functional requirements

- Smooth scrolling and stable anchoring with long histories.
- Responsive phone and tablet layouts for Android.
- Keyboard, pointer, touch, screen-reader, large-text, RTL, dark-mode, and high-contrast
  support.
- Deterministic recovery after process death at every send/receive transaction boundary.
- Reproducible builds with pinned dependencies and an offline-capable build cache.
- No release while a required security, protocol, accessibility, or migration gate is
  failing.

## Known platform limits

- Android background messaging is layered and honestly tiered (ADR-046, ADR-049, ADR-051).
  There is no foreign push and never will be. The mandatory floor — requiring nothing from
  the user — is one persisted periodic `JobScheduler` job at the platform's fifteen-minute
  minimum with a network constraint; it gives *eventual* delivery, and it gives **nothing**
  in the *rare* and *restricted* standby buckets, which is where Android 13+ places an
  application after eight days without user interaction. Above it, an opt-in `specialUse`
  foreground service is **offered as best effort** (ADR-094, superseding ADR-053 for
  production): it holds the connection, and what that is worth has never been measured on
  a single phone, so the build says so, promises no time, and the floor is the whole of
  what a user gets until they turn it on. If the
  matrix in [SUSTAINED-DELIVERY.md](runbooks/SUSTAINED-DELIVERY.md) is run
  and passes, it becomes *near-real-time, best-effort* for a user who grants
  notifications and the battery-optimization exemption, and that exemption also lifts the
  standby-bucket ceiling underneath. It is not a guarantee: the platform
  may end it at any time, and on Samsung and Xiaomi the user must additionally exclude the
  application from the manufacturer's own app-sleeping — which this application cannot
  check and never claims to have checked. Delayed delivery is expected under Doze, standby,
  Data Saver, or OEM restrictions, and a force-stopped application is silent until it is
  opened again.
  A separate microphone foreground service starts on an explicit call join and ends
  when the call ends.
- Notifications are a projection of committed local state, never of a transport event, and
  reveal nothing but that something arrived. One alert, sender-neutral, announced when
  something unread and unannounced survives mute and the conversation on screen, and
  withdrawn when nothing does — including when the user reads on another device (ADR-048).
  Decrypted previews are not built, and an alert reaches the user only while the
  application's process is alive — which the deferred catch-up arranges periodically and
  sustained delivery arranges continuously while it is on. That is a statement about the
  *process*, and what the user is told must be a statement about their experience: alerts
  do reach a closed application, and the limit worth disclosing is that the phone decides
  when the application may next look (ADR-052).
