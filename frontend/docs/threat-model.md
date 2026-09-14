# Client threat model

## Security objective

Protect content confidentiality and integrity when the backend, database, attachment
store, SFU, TURN relay, or network is observed or later seized. The system does not hide
that a device contacted the service or eliminate traffic-analysis metadata.

## Protected assets

- Message, profile, group, room, attachment, locally held history, and voice plaintext.
- Cross-signing, device identity, ML-KEM, ratchet, attachment, and media private keys.
- Login and refresh credentials.
- Recovery secrets.
- Local decrypted indexes, thumbnails, drafts, and notification previews.
- The fact that background delivery is armed. Two different exposures, and they are not
  equal. The shipped floor (ADR-049) leaves nothing on the device to see — one record in
  the platform's own job store holding an id, an interval and a component name — but it
  does make this device's *online periods* visible to the server on a roughly
  fifteen-minute cadence whether or not its owner is present, so an idle device now looks
  like an active one to a relay that already saw every drain. The opt-in `specialUse`
  foreground service (ADR-051) is the heavier one, in two ways.

  **Since ADR-053 no artifact a user receives can arm it.** The capability is gated
  closed until it has been measured on real phones, so everything in the two paragraphs
  below describes an exposure nobody in this deployment can currently choose. It is kept
  as written because the gate is a decision that can be reversed by evidence, and because
  the exposure has to be understood before it is.

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
- Reliable delivery to a force-stopped Android process or closed browser without a push
  service. Background delivery remains best-effort at every tier (ADR-046, ADR-051), and no
  tier is a guarantee — including the opt-in one, which the platform or a manufacturer may
  end at any moment without telling the application or its owner.
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

### Web

The browser origin, browser implementation, and served application code are trusted for
the duration of a session. Non-extractable WebCrypto keys reduce accidental extraction;
they do not defend against malicious JavaScript executing in the same origin. A server
that can replace the web bundle can compromise future sessions. The UI MUST disclose
that the installed Android client has a stronger distribution trust boundary.

### Dependencies

Dependencies are pinned, checksummed, cached for offline builds, license-reviewed, and
scanned. Crypto debug features and sensitive logging features are forbidden in release
builds.

Version 1 implements only the shared Rust primitive foundation and Android FFI/isolate
adapter. The Web/Wasm boundary is deferred to post-v1 and crypto-dependent Web behavior
remains fail-closed; Android completion is sufficient for the Android release but is not
evidence for a future Web trust boundary or its browser vectors.

## Required controls

- TLS 1.3, provisioned private CA, native SPKI pins with a backup pin, and strict
  Android origin/network controls. Strict Web origin controls are post-v1.
- Authenticated end-to-end encryption with domain-separated associated data.
- Safety-number verification and prominent identity-change state.
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
- Screenshots blocked on Android screens that expose recovery secrets or raw keys.
- Local wipe on logout, self-revocation, remote revocation, and unrecoverable key errors.
- Reproducible release artifacts and independent security review.

## Residual metadata

The server can observe usernames, public device bundles, day-level activity, recipient
device IDs for pending envelopes, timing, IP addresses, size buckets, room IDs presented
to room endpoints, attachment capabilities during download, and voice connection
metadata. Live root can observe which authenticated connection writes to which device
queues and infer the social graph and group fan-out. At rest there is no sender column or
conversation graph, but that does not protect routing metadata from a live operator. The
client MUST not claim otherwise.

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
  reviewed only when the post-v1 Web release is reopened.

## Primary references

- [Backend security contract](../../backend/SECURITY.md)
- [Binding client contract](../../backend/CLIENT_CONTRACT.md)
- [OWASP MASVS](https://mas.owasp.org/MASVS/)
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [Web Cryptography API](https://www.w3.org/TR/WebCryptoAPI/)
