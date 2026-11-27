# Client threat model

## Security objective

Protect content confidentiality and integrity when the backend, database, attachment
store, coturn relay, or network is observed or later seized. The system does not hide
that a device contacted the service or eliminate traffic-analysis metadata.

## Protected assets

- Message, profile, group, room, attachment, locally held history, and voice plaintext.
- Cross-signing, device identity, ML-KEM, ratchet, attachment, and media private keys.
- Login credentials and device-bound session tokens (register and full-scope; there is no
  refresh token).
- Recovery secrets.
- Local decrypted indexes, thumbnails, drafts, and notification previews.
- The fact that background delivery is armed. Two different exposures, and they are not
  equal. The shipped floor (ADR-049) leaves nothing on the device to see — one record in
  the platform's own job store holding an id, an interval and a component name — but it
  does make this device's *online periods* visible to the server on a roughly
  fifteen-minute cadence whether or not its owner is present, so an idle device now looks
  like an active one to a relay that already saw every drain. The opt-in `specialUse`
  foreground service (ADR-051) is the heavier one, in two ways.

  **Since ADR-094 a production artifact can arm it, as best effort.** ADR-053 had gated
  the capability closed until it was measured on real phones, and ADR-094 supersedes
  that for production: the owner wants it offered, the matrix cannot be run here, and the
  disclosure (revision 10) states the cost and that it is untested. So everything in the
  two paragraphs below describes an exposure a user of this deployment can now choose,
  and the choice is theirs, off by default.

  On the device: while it is armed it posts a persistent notification, which is a durable
  on-device indication that this application is running, and on Android 13 and above the
  *existence* of any foreground service is additionally listed in the platform's own Task
  Manager whatever the application does. Both are visible only on an **unlocked** phone —
  the channel is low importance, silent and `VISIBILITY_SECRET`, so no part of it appears
  on a secure lock screen or during screen sharing — and its entire content names nothing,
  counts nothing and promises nothing. It persists beyond the moment the user chose it,
  which is why the layer is opt-in, why the cost is stated on the screen that turns it on
  *before* the switch, and why turning it off removes both the service and its durable
  record. The user may also dismiss the shade entry (Android 13+) or stop the service from
  the Task Manager.

  On the wire: a held connection makes this device's online periods continuous rather than
  sampled, so a relay that already saw every drain now sees presence. That is a change in
  degree against a party the model already treats as untrusted, it creates no new party and
  no new content exposure, and it is disclosed to the user as "the app stays connected".
- Who is talking to whom, as it would appear in a message alert. The shipped alert
  (ADR-048) is a single sender-neutral notification whose entire content is "New message"
  or "New messages": no sender, no conversation, no text, no count, no timestamp, one
  constant id and tag, and a tap intent carrying no identifier. That is what a bystander
  sees on a locked or unlocked screen, what an Android 15+ screen-sharing session shows,
  and what an application holding notification access can read. Conversation notifications,
  `MessagingStyle` and long-lived conversation shortcuts are excluded by decision, because
  each publishes a stable per-contact identifier outside the encrypted database.

## Adversaries considered

- A passive network observer.
- An active network attacker without the provisioned trust anchors.
- A malicious or seized backend that returns forged keys, drops, reorders, duplicates,
  delays, or replays traffic.
- A state actor with live root access to the VPS, including TLS-terminated request
  metadata, authenticated routing, timing, IP addresses, and the ability to modify server
  responses.
- Theft of backend disks, database dumps, Redis state, attachment storage, or logs.
- A recipient who retains content after a deletion request.
- A person with filesystem access to a locked but otherwise uncompromised Android device.
- Malformed ciphertext and protocol input intended to crash or exhaust a client.
- Dependency or web-content injection attempts.

## Explicitly outside the guarantee

- A device compromised while it can decrypt content.
- A user voluntarily sharing plaintext, screenshots, or a recovery secret.
- Traffic-analysis resistance, anonymity, or cover traffic.
- Availability against a server or network that refuses service.
- Guaranteed remote deletion after another device decrypted content.
- Reliable delivery to a force-stopped Android process. Background delivery remains
  best-effort at every tier (ADR-046, ADR-051). The platform or a manufacturer may end
  opt-in delivery at any moment without telling the application or its owner.
- Hiding the social graph, group fan-out, or communication timing from live server root.

## Trust boundaries

### Backend

The backend is trusted to authenticate accounts and attempt delivery, but not trusted
with content. Clients validate signatures, identity changes, protocol versions, group
authorization, replay identifiers, and authenticated encryption independently.

### Android

The signed application binary and Android Keystore are trusted within documented OS
limits. A random database-wrapping key is non-exportable where supported. Hardware
backing is preferred but not assumed on every device.

### Trust boundary if a browser target is approved

Android is the sole target under
[server ADR-0020](../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md).
If a browser target is approved, the browser origin, browser implementation, and served
application code would be trusted for the duration of a session: non-extractable WebCrypto keys reduce
accidental extraction, they do not defend against malicious JavaScript executing in the
same origin, a server that can replace the web bundle can compromise future sessions, and
the UI would have to disclose that the installed Android client has a stronger
distribution trust boundary.

### Dependencies

Dependencies are pinned, checksummed, cached for offline builds, license-reviewed, and
scanned. Crypto debug features and sensitive logging features are forbidden in release
builds.

Version 1 implements only the shared Rust primitive foundation and Android FFI/isolate
adapter. A browser target would require evidence for its own trust boundary and browser
vectors.

## Required controls

- TLS 1.3 and strict origin/network controls:
  - **Runtime (`dart:io`):** All REST, attachment, and WebSocket traffic uses
    `TransportSecurity.provisioned`, anchoring `HttpClient` exclusively to the provisioned
    private CA (`SecurityContext(withTrustedRoots: false)`), with `badCertificateCallback`
    returning `false`. Leaf SPKI pins are **not** checked in Dart at runtime.
  - **Build-time and Android XML:** `tool/build_production_release.sh` checks
    `PRODUCTION_PRIMARY_SPKI_SHA256` against the live host at build time, and
    `tool/render_production_trust.sh` embeds primary and backup SPKI pins into Android's
    `network_security_config.xml` (which governs Android Java HTTP stacks and WebView only,
    not `dart:io`).
  - **Owner decision (ADR-076 D7):** Whether Dart runtime must also enforce SPKI pins (or
    whether exclusive private-CA anchoring in `dart:io` suffices) remains an open owner
    decision.
- Authenticated end-to-end encryption with domain-separated associated data.
- Safety-number / contact-code verification and prominent identity-change state. Currently
  the client implements one-sided out-of-band verification (and `SafetyNumberPage` still
  displays `CP-SAFETY-V1`); under
  [`CLIENT_CONTACTS_AND_TRUST.md`](../../../docs/client/CLIENT_CONTACTS_AND_TRUST.md) and
  [`SECURITY.md`](../../../docs/security/SECURITY.md) (residual risk 7), direct
  conversations must require both people verified (`MUTUAL`) before carrying content,
  replacing `CP-SAFETY-V1` with `CP-CONTACT-V1`.
- Cross-signing of the exact canonical device-bundle key bytes against an out-of-band
  confirmed account master key; unsigned devices are never messaged.
- Client-signed device-log verification and encrypted head gossip; a fork raises a global
  blocking equivocation alert.
- Hybrid X25519 + ML-KEM-768 session establishment with no silent classical downgrade.
- Exact replay and duplicate handling with bounded caches.
- Explicit `pruned_through` mailbox-gap detection, and group state recovery from a member
  over repaired pairwise sessions.
- Limits on message size, nesting, skipped ratchet keys, group control payloads,
  attachments, retries, and decompression.
- Encrypted local Android database; a future Web client must not persist plaintext.
- Redacted local diagnostics and hidden notification previews by default.
- Clipboard warnings/expiry where supported for recovery secrets.
- Screen capture blocked in the whole app, in every build: no screenshot, no screen recording
  and no recent-apps preview of its window (`FLAG_SECURE` from the first frame, ADR-092). It does
  not hide notification text and does not stop a second camera.
- Local wipe on logout, self-revocation, remote revocation, and unrecoverable key errors.
- Reproducible release artifacts and independent security review.

## Residual metadata

The server can observe usernames, public device bundles, day-level activity, recipient
device IDs for pending envelopes, timing, IP addresses, size buckets, attachment
capabilities during download, and the voice metadata below. Live root can observe which
authenticated connection writes to which device queues and infer the social graph and
group fan-out. At rest there is no sender column or conversation graph, but that does
not protect routing metadata from a live operator. The client MUST not claim otherwise.

### What a call costs

A call hides its audio and hides nothing about who is in it. Both costs are server
[ADR-0021](../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)'s
own, and the client states them rather than implying a mesh is anonymous.

- **The relay sees the peer pairs, the packet sizes and the timing.** Every media path
  crosses the self-hosted coturn, so it allocates one relay address for each connection
  and forwards packets between them. It cannot open a packet — SRTP is keyed by DTLS
  between the two endpoints — and the credential it is shown carries no account and no
  device identifier, but it sees each caller's source address as every server sees its
  caller's, and it sees which allocations talk to each other, how much and when. Who is
  in a call is therefore inferable at the relay.
- **The gateway sees which device signals which device.** A `signal` frame names its
  target device in the clear; only the blob is ciphertext. So the fan-out of a join
  announcement is the participant list, one relay hop at a time, exactly as envelope
  fan-out is the group roster. The bucket rule makes the length uniform at 1024, 4096 or
  16384 bytes and buys nothing above that: it is a malformed-input guard and never a
  security control, because a modified server would relay anything (server ADR-0022).
- **A room's membership is not hidden either**, for the same reason a group's is not:
  control events are one envelope per member device, and the server sees each target. Under
  [`CLIENT_VOICE_ROLES.md`](../../../docs/client/CLIENT_VOICE_ROLES.md) §6, in-call role
  actions (mute, remove, end call) are `signal`-frame requests enforced by each honest
  participant rather than by the server.
- What is **not** exposed: the audio, the room's name, the roster's contents, the SDP,
  the DTLS fingerprints and the ephemeral room text. None of those exists in plaintext
  anywhere outside a member's device, and no application-level media key exists to leak.

### Reading activity and presence signals

As documented in [`SECURITY.md`](../../../docs/security/SECURITY.md) § "Residual risk" and
built under ADR-098, client-side online status and typing over `signal` frames
(`CPPSV001`, 1024-byte frames) reveal reading activity when a conversation is open on
screen (when, with which peer devices, and which devices are in the foreground answering
watches), even when no durable message is sent. Under
[`CLIENT_PRESENCE_AND_RECEIPTS.md`](../../../docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md) §4,
choosing an audience of `nobody` stops sending and answering these frames.

## Security release gates

These are gates on a **release**. The Private Experimental deployment that ADR-044
defined was not one: it was private, named, disclosed distribution of an artifact that
stated its own maturity, and it left every gate below closed and unsatisfied. ADR-075
closed ADR-044 and deleted the `beta` flavor that carried it. The production builds that
ADR-076 hands to named people for testing are not a release for the same reason: each
reaches its recipient by hand with the written disclosure, carries the in-app statement
of what it is, and opens, satisfies or narrows no gate below. Nothing in either decision
may be read as clearing one of them, and the written disclosure is what makes handing a
build over under them acceptable.

- No handwritten cryptographic primitive.
- No shipping an unreviewed cross-platform protocol implementation.
- All official and project test vectors pass on Android for the version-1 release.
- Fuzzing covers binary decoders and state-machine transitions.
- Dependency audit and SBOM are clean or formally accepted.
- An independent reviewer signs off the protocol, implementation boundary, Android key
  storage, and release configuration. Web limitations and browser configuration are
  reviewed if a browser target is approved.

## Primary references

- [Backend security contract](../../../docs/security/SECURITY.md)
- [Binding client contract](../../../docs/client/CLIENT_CONTRACT.md)
- [OWASP MASVS](https://mas.owasp.org/MASVS/)
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [Web Cryptography API](https://www.w3.org/TR/WebCryptoAPI/)
