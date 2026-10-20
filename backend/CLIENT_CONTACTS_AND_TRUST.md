# CLIENT_CONTACTS_AND_TRUST.md — Contacts, the contact code, verification by both people, the profile key, and what a file carries

This document binds the Flutter client exactly as [`CLIENT_CONTRACT.md`](CLIENT_CONTRACT.md)
does, and the contract routes here from its §Q. It specifies client behaviour only.
**Nothing in it adds, changes or needs a server route, a column, a setting or a rate
scope**: every route it names is served today, and the server stays what
[`SECURITY.md`](SECURITY.md) says it is — a relay that verifies nothing that matters
for security. The decision is recorded in
[ADR-0029](../docs/architecture/decisions/0029-a-contact-code-and-verification-by-both-people.md);
the work it gives the client, in the order to do it, is
[`../CLIENT_WORK.md`](../CLIENT_WORK.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be read as described in
RFC 2119 and RFC 8174 when, and only when, they appear in capitals.

Where this document and a client document under `frontend/docs/` disagree about what it
specifies, this document is authoritative and the client document is the one to change.
`CLIENT_WORK.md` names each of them.

## 1. Terms

- **Peer.** Another account.
- **Trust record.** What one device holds about a peer's identity, as the client keeps it
  today (`ContactTrustRecord`): `unverified`, `verified` — with the confirmed master key
  and this account's attestation over it — `masterKeyChanged`, `invalidDevice`,
  `deviceLogFork` or `identityUnavailable`. Only an out-of-band verification made on one of
  this account's own devices makes a peer `verified` (§5.3).
- **Attestation.** The signature the shared core already makes in `attest_peer_master` and
  checks in `verify_user_attestation`: Ed25519 by the signer's **user-signing** key over

  ```text
  "chat:v1:user-signing-attestation" || frame(signer_user_id) || frame(subject_user_id) || frame(subject_master_public)
  frame(x) = u32be(length of x) || x
  ```

  It means: *the signer's account verified, out of band, that the subject's master key is
  these 32 bytes.* Ed25519 is deterministic, so every device of one account produces the
  same 64 bytes for the same subject and key.
- **Claim.** An attestation whose subject is this account: a peer saying it verified you.
  A claim is **authentic** or **unauthenticated** (§5.4), and it never writes a trust record.
- **Carried-over confirmation.** The one-time migration record of §5.10.
- **Direct conversation.** The conversation between this account and one peer, whose id is
  the domain-separated hash of the sorted pair (`frontend/docs/message-protocol.md`).
- **Both verified.** The conversation state `MUTUAL` of §5.5.
- **Short identity.** The name Chats already gives a user this phone holds no name for
  (`chatShortIdentity`, client ADR-093 D18).

## 2. What a direct envelope from an unverified sender meets today, and what replaces it

Read from the client on 2026-10-20, at `be0eba5`. Paths are under `frontend/lib/`.

| The sender, as this device holds it | What happens today | Is the server copy kept? |
|---|---|---|
| `unverified`, with a published identity, no unsigned device, and an initial envelope whose sender block matches a device the server lists | **Held on the phone and acknowledged.** `PairwiseOpaqueEnvelopeInspector._inspectInitial` (`features/synchronization/infrastructure/pairwise_opaque_envelope_inspector.dart`) answers `HeldEnvelopeInspection`; `DurableSyncEngine._holdEnvelope` (`features/synchronization/application/durable_sync_engine.dart`) hands it to `DriftSyncStore.recordEnvelopeHold` (`features/synchronization/infrastructure/drift_sync_store.dart`), which marks the row ready to acknowledge, and `recordAcknowledgementSuccess` moves it to state 5, `held`. A regular envelope of the same session is held behind it (`_holdFollowUp`). At most 64 per sender, 128 per phone, for 7 days (`HeldEnvelopePolicy`, `features/synchronization/domain/sync_model.dart`); a verification releases them (`ClientAuthenticationService.confirmOutOfBand` → `PeerVerificationObserver`, and the sweep in `_maintainHeldEnvelopes`). Client ADR-093, merged on 2026-10-18 | **No.** Acknowledged in the pass that held it, so it does not count against `MAILBOX_MAX_BYTES` and never waits for the 7-day prune |
| `masterKeyChanged`, a device-log fork, the global fork gate, a device set that changed under an unchanged log head, or a repair replacement from an unverified sender | The refresh fails with `policyBlocked`. `DurableSyncEngine._recordEnvelopeFailure` treats it as neither rejectable nor transient: the row goes back to `received` with a retry time (`recordEnvelopeInspectionRetry`), each inspection spends one of `maximumInspectionAttempts` (8), with full-jitter backoff from 1 s capped at 15 min (`SyncRetryPolicy`), and the eighth quarantines it (`recordEnvelopeRejection`) and queues the acknowledgement. **The message is lost** | **Yes, for the retry budget only** — minutes in the foreground, longer on background cycles — counting against `MAILBOX_MAX_BYTES`. Never left for the 7-day prune unless the phone stops running cycles |
| An invalid or unsigned device, or an identity that cannot be read or checked | A security failure, quarantined at once and acknowledged | No |
| Any sender, on a **session this device already holds** | **Opened and applied with no trust check at all.** `_inspectRegular` decrypts with the stored session, and `DriftApplicationConversationResolver.resolve` (`features/messaging/infrastructure/drift_application_conversation_resolver.dart`) checks the conversation, not the trust record. A peer whose master key changed after the session was accepted is still shown, which `CLIENT_CONTRACT.md` §E does not intend | No |

So the answer to "is it held as `policyBlocked`, never acknowledged, and left in the
mailbox until the TTL prunes it?" is **no** for a sender in the `unverified` state — it is
held on the phone and acknowledged at once — and **only for the retry budget** for the
other states, after which the message is dropped rather than delivered.

From this version, a direct conversation follows §5 in every one of these rows, and the
last row is closed: admission reads the conversation state whether or not a session
already exists (§5.6).

## 3. The contact list

### 3.1 What it is, and where it may live

- The contact list is the set of peers this account chose to keep. An entry is a peer's
  `user_id` and a username label, and nothing else. Verification, blocking and profiles
  are records of their own (§5, §3.3, §7), so an edit of one never races an edit of
  another.
- The contact list MUST exist only on the account's own devices. It MUST NOT be uploaded
  in any form: not as a list, not as hashes of names or ids, not as a set of `user_id`s on
  a route, not encrypted to the server, and not inside the key backup, which carries the
  three identity keys and nothing else. Between the account's own devices it travels only
  as the end-to-end encrypted `CPCTV001` payloads of §6 — live (§3.4) and in the
  history-transfer snapshot (§3.5).
- An entry is held by its `user_id`. Its username is a label from the lookup answer or the
  contact code, and is never authenticated: the server has no route from an id to a name,
  and `CLIENT_CONTRACT.md` §P forbids a lookup the user did not ask for. A label MAY be
  absent (§3.6); the short identity is shown in its place.

### 3.2 Adding and removing

- **Three ways in, and no others.** The exact username lookup (`POST /api/v1/users/lookup`,
  `CLIENT_CONTRACT.md` §P) adds an entry **unverified**. A contact code scanned live with the
  camera (§4.3) adds **and verifies**. A contact code read from an image (§4.5) adds
  **unverified**. A comparison of safety numbers verifies without adding; a notice, a group
  roster and an incoming message add nothing.
- Until an authenticated profile arrives, an entry shows its username label and the
  placeholder avatar (client ADR-021), and an entry whose peer is not verified never shows
  a display name. A profile arrives only through §7.
- **Removing** turns the entry into a removed record (§6, kind 1). The trust record, the
  direct conversation and its history stay; a removed peer simply leaves the pickers and
  the contacts screen. Removing publishes a new profile version (§7.4).
- **The pickers.** The new-conversation picker lists entries on the list. The
  add-group-members picker and the voice-room invite picker list entries on the list whose
  trust record is `verified` — the existing rule that verification precedes inviting. No
  picker lists anyone else.
- **The discoverability toggle** is a user setting, specified in
  [`../CLIENT_WORK.md`](../CLIENT_WORK.md) § "Required before release — the
  discoverability toggle". Its text MUST also say that the user's contact code (§4) adds
  them whatever the setting says: "Anyone you show your code to can still add you."

### 3.3 Blocking

Blocking is private account state (`contact.block_set` in the client's registry): its own
record per peer (§6, kind 2), sent only to this account's other devices and never to the
blocked peer. It is independent of the contact list — a peer who is not a contact can be
blocked, and a blocked peer can stay on the list. Its effects are §5.6 (nothing of theirs
is admitted into the direct conversation), §5.8 (no alert, no reply) and §7.2 (no profile
key). Groups keep the existing rule of `frontend/docs/message-protocol.md` § "Blocking": a
blocked member's control events are still verified and applied.

### 3.4 Between the account's own devices

- Every change to an entry, a block, a verification (§5.3) or a carried-over confirmation
  (§5.10) MUST be sent at once as `CPCTV001` to every other live device of this account,
  and to no other account's device.
- Kinds 1 and 2 are **last-writer-wins registers**, one per peer each. The order key is
  `(revision, author_device_id)`: the revision as an unsigned 32-bit integer, then the 16
  raw device-id bytes compared lexicographically. A received record replaces the stored
  one only when its key is greater; an equal key is the same write and changes nothing. A
  change made on this device writes `revision = stored revision + 1` (1 when there is
  none) and `author_device_id = this device`. A register at revision 4,294,967,295 takes no
  further change.
- Kind 3 from an own device is this account's verification of a peer, or a peer's claim
  forwarded in a snapshot; kind 6 is a carried-over confirmation; kind 5 with scope 0 is a
  profile key. §5.3, §5.10 and §7.6 say how each is applied.

### 3.5 The history-transfer snapshot

The contact state travels with the own-device history transfer (`CLIENT_CONTRACT.md` §G).
The source device MUST send, to the target device alone, after the last history batch and
before the transfer's completion event:

- every kind-1 record it holds, removed ones included, and every kind-2 record;
- a kind-3 record for every peer it holds `verified`, and a kind-3 record for every claim it
  holds that is authentic on the source;
- every kind-6 confirmation;
- kind-5 scope-0 records for this account's current profile key and for every peer's
  profile key it holds.

Up to 256 records go in one payload. The target applies them exactly as live records, so a
snapshot and a live change that cross in flight converge. A device that receives no
history transfer has only the changes made after it was added — the same limit
`CLIENT_CONTRACT.md` §G states for history.

### 3.6 Migrating the cached directory

The local `users` table still holds what `GET /api/v1/users` returned before
[ADR-0028](../docs/architecture/decisions/0028-an-exact-username-lookup-replaces-the-directory.md)
removed it: the server's whole user list. At the first start of a build that implements
this document, the device MUST:

1. create an entry — on the list, revision 1, authored by this device, labelled with the
   cached username — for every peer that has a direct conversation on this device or whose
   trust record is `verified`, and send those entries to its own devices (§3.4);
2. keep, as names only and not as contacts, the cached usernames of the active members of
   the groups and voice rooms this account is an active member of, so that their messages
   stay named; a name kept this way is deleted once its account shares no group or room
   with this one and is not a contact;
3. delete every other cached directory row.

## 4. The contact code

### 4.1 Format

```text
code        = "CP-CONTACT-V1:" || BASE32(payload)
payload     = user_id[16] || fingerprint[32] || username
fingerprint = SHA-256("chat:v1:contact-code" || u32be(16) || user_id || u32be(32) || master_public)
```

- `user_id`: the account's 16 raw UUID bytes. `master_public`: the account's 32-byte
  Ed25519 master public key, read from this device's own identity package — **never** from
  a server answer. `username`: the account's own name as the server holds it, 3 to 32 bytes
  of `[a-z0-9_]`, occupying the rest of the payload.
- `BASE32` is RFC 4648 §6 — the alphabet `A–Z2–7`, upper case, **no padding** — and an
  encoder writes the canonical form, its unused trailing bits zero.
- It carries **no secret**: an id, a name, and a hash of a public key.
- Sizes: a payload of 51 to 80 bytes, 82 to 128 characters of BASE32, 96 to 142 characters
  in all.
- The version is the prefix. A later format takes a new prefix, and a reader of this one
  refuses every other prefix.
- The fingerprint's domain keeps it apart from the safety fingerprint
  (`"chat:v1:safety-fingerprint"`, over both users) and binds it to the account's id. It is
  a hash of public values and authenticates nothing on its own: what makes a code verify is
  the comparison of §4.3 together with the channel it came through.

### 4.2 Showing a code

- A **My code** screen, reached from the contacts screen's add sheet, the safety-number page
  (§5.11) and Settings, shows the code as a QR symbol, `@username` under it, and: "Let the
  person you are with scan this from your screen. A scan in person verifies you; a copy of
  this code only lets someone add you." It also offers **Scan their code** (§4.3).
- The symbol: error-correction level M, alphanumeric mode (every character of the text is
  in the QR alphanumeric set), a quiet zone of at least four modules, dark modules on a
  light background in both themes. That is version 5 for names of up to 18 characters and
  version 6 above. An encoder with byte mode only produces a larger symbol of the same text,
  which decoders read the same way.
- The code is computed from the identity package each time it is shown and never kept as
  an image, so it changes when the account's master key changes.
- **Share as an image** hands a PNG of the symbol and `@username` to the system share sheet,
  through the existing share path (client ADR-089), with the sentence "Anyone who gets this
  image can add you. Nobody can verify you with it." It exists because the whole
  application blocks screen capture (client ADR-092), so a screenshot of this screen is
  blank.

### 4.3 Scanning live: adds and verifies

The scanner is this application's own camera view (§4.7). It acts on a code only when two
consecutive frames decode to the same text. Then, in order:

1. **Parse** (§4.6). A refusal adds nothing and says "This is not a contact code." — or, for
   a text beginning `CP-SAFETY-V1:`, "This is a safety number, not a contact code. Ask them
   to show their code."
2. A code carrying **this account's own id** says "This is your own code." and adds nothing.
3. **Read the identity**: `GET /api/v1/users/{user_id}/identity`, conditional on the stored
   tag as today. A `404` says "No account can be found for this code." and adds nothing.
4. **Check the identity itself**: `master_sig` over the served subkeys, as the existing
   refresh does. A failure says "This account's keys could not be checked." and adds
   nothing.
5. **Compare**: compute the fingerprint of `(user_id, served master_public)` and compare it
   with the code's, in constant time. A mismatch is the hard failure of §4.4.
6. **On a match**: create the entry, or update an existing one, on the list with the code's
   username as its label; then run the existing out-of-band confirmation —
   `confirmOutOfBand(userId, exactMasterPublic: the served master key)` — which refreshes
   the devices and the log and writes the attestation. Then send the notice (§5.3).
7. If the confirmation fails after the match — a device set changing under an unchanged
   log head, an invalid device, a fork — the entry stays added and unverified, and the
   scanner says why in the words those states already use. Scanning again verifies.

A peer already `verified` under the same master key is not verified again: the scanner
says "You already verified @username.", and when this device holds no authentic claim from
them it sends the notice again with a reply requested, within the limits of §5.8.

On success: "You verified @username." and, when the conversation is not `MUTUAL`, "Ask them
to scan your code too." Verification by both people therefore takes one scan in each
direction.

### 4.4 A code that does not match fails hard

A fingerprint that differs from the one computed from the master key the server serves for
the code's `user_id` MUST be treated as a possible man-in-the-middle, on both paths:

- nothing is added, and no record changes — an existing entry, trust record or claim stays
  exactly as it was;
- one alert, with no other action than **OK**: title "This code does not match", body "The
  keys the server gives for the account in this code are not the keys in the code. Someone
  may be trying to read your messages with this person. Nothing was added or changed.
  Check with them in person.";
- no "add anyway", and no retry that skips the comparison.

### 4.5 Reading a code from an image: adds only

- The image comes from the system photo picker (the mechanism of client ADR-089, with no
  permission). It is decoded in memory, never written to storage, never sent, and never
  becomes an attachment.
- Steps 1 to 5 of §4.3 apply unchanged, the hard failure of §4.4 included. On a match, the
  entry is created **unverified**, labelled with the code's username only if it is new.
  The confirmation is never run. The result says "Added @username. Not verified yet:
  compare safety numbers or scan their code in person."
- A code from any source other than the live scanner — an image file, the clipboard, a
  shared item, a photo another application took — MUST be treated as an image.

### 4.6 Parsing

A reader MUST refuse, adding nothing, unless:

- the text begins with exactly `CP-CONTACT-V1:`;
- the rest is canonical BASE32: only `A–Z2–7`, no `=`, and equal to the encoding of the
  bytes it decodes to — which refuses a non-zero unused trailing bit and an impossible
  length;
- the payload is 51 to 80 bytes;
- its last `length − 48` bytes match `^[a-z0-9_]{3,32}$`.

### 4.7 The camera and the decoder

The Android framework has no QR decoder, so the scanner needs exactly one new library.

- **Decoder:** `com.google.zxing:core`, the newest 3.5.x on Maven Central when it is added
  — pure Java, Apache-2.0, no network access, no native code and no Google Play services —
  pinned exactly and added to the offline Gradle mirror. ML Kit, the Google Play services
  code scanner and every package that wraps them are excluded: each is a Google dependency
  the client refuses (`frontend/AGENTS.md`). Decoding is restricted to `QR_CODE`.
- **Frames** come from the framework `android.hardware.camera2` API through the
  application's own Android code; no camera library is added. A frame is decoded in memory
  and dropped: it is never written to storage, never logged and never leaves the process.
  The same decoder reads the image of §4.5.
- **Permission:** `android.permission.CAMERA`, requested when the scanner opens and at no
  other time, with `<uses-feature android:name="android.hardware.camera.any"
  android:required="false"/>`. Declaring it has one consequence for the existing photo
  capture: an application that declares `CAMERA` and does not hold it gets a
  `SecurityException` from `MediaStore.ACTION_IMAGE_CAPTURE`, so the capture flow MUST
  request the permission before it starts the camera application, and say plainly when it
  is refused.
- A refused permission or a phone with no camera: the scanner says so and offers the
  comparison of safety numbers and the image path, which adds without verifying.

### 4.8 Golden vectors

Line breaks inside a value are not part of it. The inputs, used again in §6.6:

| Name | Value |
|---|---|
| Alice's `user_id` | `6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10` |
| Bob's `user_id` | `2a77d4b9-e611-4c0f-9f1c-6a2e3b7d4e0f` |
| Alice's master key, from the Ed25519 seed `11` × 32 | `d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737` |
| Alice's user-signing key, from the seed `12` × 32 | `204040e364c10f2bec9c1fe500a1cd4c247c89d650a01ed7e82caba867877c21` |
| Bob's master key, from the seed `21` × 32 | `884b8857f4eaa1613c61504db34d4beaf346517a0e31de3cddd4d9b4201d9d0b` |
| Bob's user-signing key, from the seed `22` × 32 | `a09aa5f47a6759802ff955f8dc2d2a14a5c99d23be97f864127ff9383455a4f0` |

**Alice's code**, username `alice`:

```text
fingerprint input  636861743a76313a636f6e746163742d636f6465000000106f0c2f5e8a414c9e
                   9a341f3d8f2b7c1000000020d04ab232742bb4ab3a1368bd4615e4e6d0224ab7
                   1a016baf8520a332c9778737
fingerprint        61afe326e91a7ff97f8bab818ba390c70fb7ad5652e29aecf2f5887c86f79ac3
payload (53 bytes) 6f0c2f5e8a414c9e9a341f3d8f2b7c1061afe326e91a7ff97f8bab818ba390c7
                   0fb7ad5652e29aecf2f5887c86f79ac3616c696365
code (99 chars)    CP-CONTACT-V1:N4GC6XUKIFGJ5GRUD46Y6K34CBQ27YZG5ENH76L7ROVYDC5DSDDQ7N5NKZJOFGXM6L2YQ7EG66NMGYLMNFRWK
```

**The longest name**, Bob's id and master key with the username
`a_very_long_username_of_32_chars` — a payload of 80 bytes and a code of 142 characters:

```text
fingerprint  9d12547648b3354469cc21e7368da4ac6f41f91011cd295bf0d644fed1b5c139
code         CP-CONTACT-V1:FJ35JOPGCFGA7HY4NIXDW7KOB6OREVDWJCZTKRDJZQQ6ONUNUSWG6QPZCAI42KK36DLEJ7WRWXATSYK7OZSXE6K7NRXW4Z27OVZWK4TOMFWWKX3PMZPTGMS7MNUGC4TT
```

**A mismatch.** Alice's code, read while the server serves Bob's master key for Alice's id:
the served fingerprint is
`e5d241648bff0a1878f21d3ae5baf7522678339a306f1055bf17232a73614fc0`, not the code's
`61afe326…`, so §4.4 applies.

**Refused**, each by the rule in brackets:

| Text | Rule |
|---|---|
| `cp-contact-v1:N4GC6XUKIFGJ5GRUD46Y6K34CBQ27YZG5ENH76L7ROVYDC5DSDDQ7N5NKZJOFGXM6L2YQ7EG66NMGYLMNFRWK` | prefix |
| Alice's code followed by `======` | alphabet (padding) |
| Alice's code with its BASE32 in lower case | alphabet |
| `CP-SAFETY-V1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | prefix (a safety number) |
| `CP-CONTACT-V1:N4GC6XUKIFGJ5GRUD46Y6K34CBQ27YZG5ENH76L7ROVYDC5DSDDQ7N5NKZJOFGXM6L2YQ7EG66NMGYLMNFRWL` | canonical form (the last symbol's unused bit is set) |
| `CP-CONTACT-V1:N4GC6XUKIFGJ5GRUD46Y6K34CBQ27YZG5ENH76L7ROVYDC5DSDDQ7N5NKZJOFGXM6L2YQ7EG66NMGYLM` | size (the name `al` is too short) |
| `CP-CONTACT-V1:N4GC6XUKIFGJ5GRUD46Y6K34CBQ27YZG5ENH76L7ROVYDC5DSDDQ7N5NKZJOFGXM6L2YQ7EG66NMGQLMNFRWK` | username (`Alice` is not lower case) |

## 5. Verification by both people, for direct conversations

### 5.1 The rule

A direct conversation carries content only when **both** people have verified each other's
master keys out of band — by comparing safety numbers or by scanning each other's code in
person. Until then:

- a device MUST NOT send anything into it except the allowlist of §5.2, and the composer is
  replaced by the state's panel (§5.11);
- a device MUST NOT admit anything from the peer into it except the allowlist (§5.6).

Groups are unchanged (§5.9).

### 5.2 The allowlist

Nothing else passes before both people have verified. Each entry is there because without
it the two people could never get to `MUTUAL`:

| Entry | What it is | Why it must pass before both have verified |
|---|---|---|
| Session establishment | A PQXDH initial envelope — or an authenticated repair replacement — from a sender **this device has verified**. From a sender it has not verified the envelope is held unopened as today (ADR-093), apart from the read of §5.3 | The notice travels inside a pairwise session, so without one no verification could ever reach the peer. Accepting the initial only from a verified sender keeps the precondition of `frontend/docs/pairwise-transport-v1.md` § "Sender-hidden initial header": a session is committed only for a device under a master key this account confirmed |
| The verification notice | `CPCTV001` kind 3 from the peer, the peer signing and this account its subject (§5.3) — `contact.master_verify` sent to the peer | It is the only thing that tells a person the other one has verified them. It is admitted as a claim and never changes a trust record |
| `session.repair` | The authenticated repair control and its replacement (`pairwise-transport-v1.md` § "Replay, skipped keys, and repair"), unchanged | A session that reaches its skipped-key bound stops carrying anything, the notice included. Repair needs a session this account accepted, so it exists only after a verification on this side |
| `protocol.notice` | `CPCTV001` kind 4 (§6.4) | Two clients that do not speak the same version of this allowlist could otherwise never learn it, and would wait on each other forever. It is advisory and changes no state |

`device_log.gossip` is not a direct-conversation event, so it needs no place on the list: it
is admitted as today (§5.6). A device sends it behind a direct message (`CLIENT_CONTRACT.md`
§J), so between two people who have not both verified it is simply not sent, and it resumes
with the first message once the conversation is `MUTUAL`.

### 5.3 The verification notice

**When a device sends one.**

1. On every out-of-band verification of a peer made on this device: a confirmed comparison
   of safety numbers, or a live scan (§4.3).
2. As a reply, when it receives an authentic claim that asks for one (§5.7).
3. Once, at the migration of §5.10.
4. After a queue gap (`CLIENT_CONTRACT.md` §H), to every peer whose conversation is
   `AWAITING_PEER`.
5. When the user taps **Notify again** (§5.11).

Sends 2, 4 and 5 together are limited to one for each peer for each UTC day (§5.8).

**What it carries.** One kind-3 record: this account as signer, the peer as subject, the
peer's verified master key, the attestation the confirmation stored, and `reply_requested`
set unless this device already holds an authentic claim or a carried-over confirmation from
the peer.

**To whom.** Every live device of the peer and, **in the same `POST /api/v1/envelopes`
call**, every other live device of this account — that copy is the own-device
`contact.master_verify`. One call carries at most 10 plus 9 items. Never to a blocked peer:
a blocked peer is not offered for verification.

**On another device of this account** (the signer is this account): verify the signature
under this account's own user-signing public key, read from this device's own identity package
and never from a server answer; refresh the subject with the existing refresh; if the master
key served now equals `subject_master_public`, write the trust record `verified` with this
attestation — the record `confirmOutOfBand` writes — and release the subject's held envelopes
through the existing ADR-093 port; if it differs, write the record `masterKeyChanged`, with the
attested key as the confirmed one. That device sends no notice of its own for it.

**From the peer** (the peer signing, this account the subject):

1. The peer is blocked: the record is dropped and acknowledged; nothing is stored and
   nothing is shown.
2. `subject_master_public` is not this account's current master key: dropped silently, as
   stale.
3. Verify the signature under the user-signing key of the peer's identity — the one this
   device holds, then, if that fails, one fresh read — with `master_sig` checked as always.
   A failure is quarantined with a security reason and changes nothing.
4. Store it as the peer's claim, replacing an older one. Identical bytes are a duplicate and
   change nothing.
5. When the peer's trust record is `verified`, the claim is authentic (§5.4) and the
   conversation may become `MUTUAL`; answer a `reply_requested` per §5.7.
6. Otherwise it is unauthenticated, and the alert of §5.11 shows, unless it already shows
   for this claim. A claim forwarded by an own device in a snapshot (§3.5) is stored the same
   way and never shows an alert.
7. Never: a trust-record write, a verification, a "verify back" action, a system
   notification or a receipt.

**Reading a notice from a sender this device has not verified.** An initial envelope from
such a sender is held unopened (ADR-093). Before the hold is recorded, the inspector MAY run
the core's acceptance of that initial **in memory and commit nothing** — no session, no
device-state transition, no consumed one-time key, no replay marker — and read the opened
payload for one thing only: whether it is a `CPCTV001` kind-3 record of exactly 140 bytes
whose signer is the claimed sender and whose subject is this account. If it is, steps 1 to
4 and 6 above run on it, with the signature checked under the identity the server serves
for that sender, and the envelope is then held as it would have been. Every other payload
is discarded unread, any failure leaves the envelope held exactly as today, and nothing past
those 140 bytes is ever parsed. Follow-ups of a held session are not read this way. This is
the one place this document opens anything from an unverified sender, and it exists so that
the alert can say what the sender actually claims; `CLIENT_CONTRACT.md` §C states the
exception.

### 5.4 When a claim is authentic

A claim from peer P is **authentic** exactly when all of these hold, evaluated whenever the
conversation's state is read, against what this device has stored — no state read waits on the
network:

- P's trust record on this device is `verified`, which means the identity this device last read
  for P carries the confirmed master key: every refresh checks that, and writes
  `masterKeyChanged` when it does not;
- the signature verifies under the user-signing key of that identity, whose `master_sig`
  verifies under that master key;
- `subject_master_public` is this account's current master key.

Before P's master key is verified, the channel itself is unverified: a server that
substituted P's identity can produce a claim that verifies under the substitute. So an
unauthenticated claim proves nothing and changes nothing, however it arrived. Once P's key is
verified, the same bytes are P's own account speaking, whichever channel carried them — a
claim stored earlier becomes authentic at that moment, with no new message.

### 5.5 The conversation state

One state per peer, derived on each device from its own records:

| State | Condition | Sends into the conversation | Admits from the peer |
|---|---|---|---|
| `BLOCKED` | The peer is blocked | Nothing | Nothing (§5.6) |
| `DEVICE_PROBLEM` | Trust record `invalidDevice`, `deviceLogFork` or `identityUnavailable`, or the global fork gate | Nothing | The allowlist |
| `KEY_CHANGED` | Trust record `masterKeyChanged` | Nothing | The allowlist |
| `UNVERIFIED` | Trust record `unverified` (or none), no stored unauthenticated claim | Nothing | The allowlist |
| `PEER_SAYS_VERIFIED` | Trust record `unverified` (or none), an unauthenticated claim stored | Nothing | The allowlist |
| `AWAITING_PEER` | Trust record `verified`, no authentic claim, no carried-over confirmation | Notices only | The allowlist |
| `MUTUAL` | Trust record `verified`, and an authentic claim or a carried-over confirmation | Everything | Everything |

The first matching row wins, from the top.

| Event | Transition |
|---|---|
| This account verifies P, on any of its devices | `UNVERIFIED`, `PEER_SAYS_VERIFIED` or `KEY_CHANGED` → `MUTUAL` when a stored claim is now authentic, else `AWAITING_PEER`; the device that verified sends the notice (§5.3) |
| A notice from P | Stored as a claim: `UNVERIFIED` → `PEER_SAYS_VERIFIED`; `AWAITING_PEER` → `MUTUAL` |
| P's master key changes — a refresh serves a key other than the confirmed one | → `KEY_CHANGED`. The claim and any carried-over confirmation are void, being bound to the old key. The state's panel and the contacts screen re-alert, and P's own device drops back too, by the next row |
| This account's master key changes | Every attestation this account made stops verifying under its new user-signing key, so every trust record reads `unverified`; every claim and carried-over confirmation names the old key and is void; every conversation → `UNVERIFIED`; the code changes. Peers see the previous row |
| P adds a device whose bundle chains to the verified master key and extends P's log | No transition: the trust record, the claim and the confirmation belong to the account, not to a device. The new device is sent to like any other of P's devices. On P's side it holds what arrives (ADR-093) until P's own snapshot or live records bring P's verification of this account and this account's claim, and then releases it |
| This account adds a device | The same, from this side: the snapshot of §3.5 brings the state |
| A device of P is revoked | No transition |
| This account blocks or unblocks P | → `BLOCKED`, or back to the state the stored records give |
| An unauthenticated claim expires (§5.8) | `PEER_SAYS_VERIFIED` → `UNVERIFIED` |

What no event does: a received notice never makes P `verified`; no server answer ever makes P
`verified`; no state reaches `MUTUAL` without this account's own out-of-band verification of
P on one of its devices.

### 5.6 Admission, by what arrives

**Dropped** means acknowledged, with no message row, no notification, no receipt, no typing
indicator and no unsupported-event row. An event is dropped, never a session: the envelope is
committed with its session transition and without the event — an initial from a sender this
device has verified establishes its session, and a regular envelope advances its ratchet — so
later envelopes of that session still open. A dropped envelope is never left at the server: it
is acknowledged in the batch that inspected it.

| What arrives from peer P | `MUTUAL` | `BLOCKED` | Any other state |
|---|---|---|---|
| An envelope from a sender this device has not verified | — | Held unopened, as today; no alert | Held unopened, as today (ADR-093); the read of §5.3 may surface a claim |
| A direct-conversation application event — `message.create`, `message.edit`, `message.delete`, `message.reaction_set`, `message.pin_set`, `receipt.delivered`, `receipt.read`, or an unsupported kind | Applied as today | Dropped | Dropped, at its first inspection: no retry and no budget spent |
| Typing and online status (`CPPSV001`) for the direct conversation | As today (client ADR-098) | Dropped | Dropped; none is sent |
| `CPCTV001` kind 3 (the notice) | §5.3 | Dropped | §5.3 |
| `CPCTV001` kind 4 | §6.4 | Dropped | §6.4 |
| `CPCTV001` kind 5, direct scope (§7) | Applied | Dropped | Dropped |
| `CPCTV001` kinds 1, 2 and 6, or kind 5 with scope 0 — which only this account's own devices send | Refused: quarantined with a security reason | Refused | Refused |
| `session.repair` | As today | As today | As today |

Unchanged, because none of it is the direct conversation: group payloads and group events,
voice-room payloads and signalling, device-log gossip, and everything from this account's own
devices — own-device copies of this account's direct messages and history-transfer batches
included.

The sending side mirrors this: the send path MUST refuse to seal any direct-conversation event
of the table above into a conversation that is not `MUTUAL` — the composer is gone, and the
fan-out refuses it again with `policyBlocked` (every send asks, client ADR-082). An event already
queued when the state drops back stays unsent and is shown as not sent, with the state's panel,
until the user sends it again after the conversation is `MUTUAL`.

### 5.7 Ordering, and what a lag can cost

- No client following this document sends a direct-conversation event before the
  conversation is `MUTUAL` on its own side. So an event the table does not admit reaches a
  device only from a client that predates this document, from a drop-back while it was in
  flight, or because this device's own records lag.
- The notice and the own-device copy go in one call (§5.3), and a server call is one
  transaction, so this account's other devices hold its verification before the peer can
  react to it, and each device drains its mailbox in sequence order.
- A device whose trust record for P is `verified` and that receives an authentic claim with
  `reply_requested` replies with its own notice, `reply_requested` clear, to P's devices only
  — at most once per peer per UTC day. A device never replies to an unauthenticated claim.
  So if this account verified P first, P's verification produces P's notice, which makes
  this side `MUTUAL`; if P verified first, the stored claim becomes authentic the moment this
  account verifies P, and this side's notice — sent with `reply_requested` clear — makes P's
  side `MUTUAL`. Either order converges in one exchange and never ping-pongs.
- A notice is processed from what the device holds — the peer's stored identity — and a claim
  that arrives before this device holds the peer as verified is stored, not dropped, and
  becomes authentic when the verification arrives (§5.4). A peer's envelopes to a device that
  does not yet hold it as verified are held unopened and released by that verification
  (ADR-093). So a lag in this account's own records loses nothing, with one exception: a
  device that already holds a session with the peer while it does not hold the peer as
  verified — after a key change, before its own re-verification arrives from another device —
  drops the peer's direct messages that arrive in that window, and the peer sees no receipt
  for them.

### 5.8 Limits and deduplication

- **Sending.** One notice per verification; replies, gap re-sends and **Notify again**
  together at most once per peer per UTC day; one at migration.
- **Receiving.** An identical claim changes nothing. At most one alert per peer at a time,
  and none for a blocked peer or a peer this device already holds as `verified`. At most 64
  unauthenticated claims are stored; past that, the oldest goes. An unauthenticated claim
  expires 30 days after it arrived. An authentic claim is kept while it stays authentic.
- **Parsing.** A kind-3 record is fixed-length (§6.2), so nothing variable is parsed before
  its signature is checked.

### 5.9 Groups are unchanged

This document changes no group admission and no group fan-out. What "unchanged" is, read from
the code on 2026-10-20:

- **Receiving:** a group copy whose sender this device has not verified is held unopened and
  released by a verification of that sender (ADR-093 D8). The read of §5.3 does not change
  this: a group payload found by it is discarded unread and the envelope held.
- **Sending:** a group send verifies every active member through
  `resolveVerifiedLiveDevicesForUsers`, which fails the **whole** batch with `policyBlocked`
  when one member is not verified (`ContactPairwiseLiveDeviceResolverAdapter`,
  `features/pairwise/infrastructure/contact_selective_pairwise_claim_adapter.dart`), and
  `pairwise_fanout_coordinator_test.dart` pins it: "a member that fails verification
  withholds the whole copy". **The send does not skip that member, as the brief for this
  document assumed; it sends to nobody.** This document leaves that as it is, and
  [`../CLIENT_WORK.md`](../CLIENT_WORK.md) records it as an open decision for the owner.

The same reading shows one gap this document does not close for groups: a group event that
arrives on a session this device accepted earlier is admitted with no check of its sender's
current trust record — the gap of §2's last row, which §5.6 closes for direct conversations.
It belongs to the same decision.

The group-scoped profile key of §7 follows group admission.

### 5.10 When this version lands

Once, at the first start of a build that implements this document, each device:

1. migrates the cached directory (§3.6);
2. records a **carried-over confirmation** — P's confirmed master key and this account's
   master key — for each peer P whose trust record is `verified`, with a valid attestation,
   when this device holds at least one committed application event of the direct
   conversation with P authored by P. Under the rules before this document, P's client
   sealed a direct-conversation event for this account only after verifying this account's
   current master key — the verified fan-out refuses an unverified recipient
   (`ContactPairwiseLiveDeviceResolverAdapter._verified`), and has since the pairwise
   transport first landed (`d0092ee`, 2026-07-29) — and this device opened it only after
   verifying P. So both people had verified each other out of band, and the conversation
   keeps working with a peer whose client has not updated yet. A confirmation is never
   recorded after this step;
3. sends its notice to every live device of every peer it holds `verified`, with
   `reply_requested` set unless it holds a carried-over confirmation;
4. sends its kind-1 entries and kind-6 confirmations to its own devices.

A carried-over confirmation counts like an authentic claim until either master key changes,
and a real claim replaces it when one arrives. Every other conversation shows its state's
panel, so nothing is blocked silently: a conversation that was one-sided before this version
reads `AWAITING_PEER` or `PEER_SAYS_VERIFIED`, and says why.

One loss is accepted here. Direct messages a peer's earlier client sent to this device before
this device verified that peer are held (ADR-093), and open when the verification releases
them. Those that open before the peer's first notice — before the conversation is `MUTUAL` —
are dropped by §5.6, and the peer saw no receipt for them.

### 5.11 What the screens say

These states carry security meaning, so their words are part of the requirement. The English
is binding; the Persian MUST say the same and be read by a native reader. A name is
`@username` from the contact list, or the short identity without `@` when this phone has no
entry.

**The panel that replaces the composer:**

| State | Text | Actions |
|---|---|---|
| `UNVERIFIED` | "Messages start once you and @x have verified each other. Compare safety numbers, or scan @x's code in person." | **Compare safety numbers**, **Scan their code** |
| `PEER_SAYS_VERIFIED` | "@x says they verified you. Messages start once you verify @x too." | **Compare safety numbers**, **Scan their code** |
| `AWAITING_PEER` | "You verified @x. Messages start once @x verifies you too. If @x already has, their app needs the update that sends that confirmation." | **Show my code**, **Notify again** — disabled, reading "Sent today", once a notice has gone to @x in that UTC day (§5.8) |
| `KEY_CHANGED` | "@x's safety number changed. Messages stop until you verify @x again." — followed, when an unauthenticated claim under the new key is stored, by "@x says they verified you again." | **Compare safety numbers**, **Scan their code** |
| `BLOCKED`, `DEVICE_PROBLEM` | The existing words of those states (`frontend/docs/ui-specification.md` §11, §11.1) | As today |

**Chats.** One row per peer for whom this phone holds held envelopes or an unauthenticated
claim. With a claim: "@x says they verified you. Verify them to start messaging." — or, when
the conversation is `KEY_CHANGED`, "@x's safety number changed. @x says they verified you
again." Without a claim, the row of ADR-093 D18 as it is. The row shows no content, no time
and no badge, and its only action opens `/contacts/:userId/safety`. The row of a direct
conversation that is not `MUTUAL` shows, in place of its preview, "Not verified yet",
"Waiting for @x to verify you" or "Safety number changed".

**Contacts.** Each entry carries one of: "Verified each other", "You verified", "Says they
verified you", "Not verified", "Safety number changed", "Blocked".

**The safety-number page** (`/contacts/:userId/safety`) keeps the numeric and emoji
comparison and its "I compared these" confirmation, which takes a deliberate tick and a
deliberate tap. It drops the display-only `CP-SAFETY-V1` QR symbol, which nothing scans, and
offers **Scan their code** and **Show my code** in its place. After a confirmation it says
"You verified @x.", and, when the conversation is not `MUTUAL`, "Messages start once @x
verifies you too."

**Nowhere** is there a one-tap "verify back": an alert opens the comparison or the scanner and
nothing else. The hint of ADR-093 D19 ("Not delivered yet. If @username has not verified you,
ask them to.") is withdrawn: a direct message is now sent only when both people have verified
each other, so the cause it names cannot occur.

### 5.12 Failures

- **A notice that cannot be sent** is an ordinary outbox job: `stale_devices` and
  `full_devices` are handled as for any send, and a recipient device that is unsigned or
  pending waits as any send does. A notice that never lands is recovered by the reply and the
  gap rules, and by **Notify again**.
- **A record that fails its checks** — a signature that does not verify, a malformed payload,
  a kind that may not come from its sender — is quarantined with a security reason and
  changes no state.
- **The read of §5.3** never fails anything: a core refusal or a payload that is not a notice
  leaves the envelope held exactly as today, and records nothing.
- **An identity that cannot be read** while a state is evaluated leaves the state as it was,
  until the next refresh.

## 6. The `CPCTV001` payloads

### 6.1 Carriage

A `CPCTV001` payload is the opened plaintext of an ordinary **durable** envelope, sealed and
padded exactly as an application payload is. It is never carried in a `signal` frame: the
signal router reads only `CPVSV001` and `CPPSV001` and leaves any other magic uncommitted, which
drops it. The inspector MUST recognise the magic before it hands a payload to the application
decoder.

A client that predates this document sends that payload to the application decoder, which
cannot decode it, and refuses it like any payload that does not decode: quarantined and
acknowledged, at the latest when its inspection budget is spent, and nothing else happens.
That is why no flag day is needed.

### 6.2 Layout

```text
payload = "CPCTV001" || kind:u8 || count:u16be || count × record

kind 1  contact entry       target_user_id[16] || revision:u32be || author_device_id[16]
                            || state:u8 || username_length:u8 || username[username_length]
kind 2  block               target_user_id[16] || revision:u32be || author_device_id[16]
                            || blocked:u8
kind 3  attestation         signer_user_id[16] || subject_user_id[16]
                            || subject_master_public[32] || signature[64] || flags:u8
kind 4  protocol notice     contact_protocol_version:u8
kind 5  profile key         owner_user_id[16] || profile_version:u32be || profile_key[32]
                            || scope:u8 || [group_id[32] when scope = 2]
                            || audience_count:u16be || audience_count × user_id[16]
kind 6  carried-over        peer_user_id[16] || peer_master_public[32] || own_master_public[32]
```

A payload is refused whole when any of these fails:

- `count` is 1 to 256, and exactly 1 for kinds 3, 4 and 5 sent to a peer;
- the records fill the payload exactly — no trailing byte;
- kind 1: `state` is 1 (on the list) or 0 (removed); with 1, `username_length` is 0 or 3 to 32
  and the name matches `^[a-z0-9_]+$`; with 0, `username_length` is 0;
- kind 2: `blocked` is 0 or 1;
- kind 3: bit 0 of `flags` is `reply_requested` and the other seven bits are zero; the
  signature is checked as §5.3 says;
- kind 4: the version is at least 1;
- kind 5: `scope` is 0 (own devices), 1 (direct) or 2 (a group or a voice room, named by
  its 32-byte id, which the receiver looks up among both); `audience_count` is 0 unless the
  scope is 0 and the owner is this account;
- the ids agree with the sender, which the pairwise session authenticated:
  - kinds 1, 2 and 6 and scope-0 kind 5 come from this account's own devices, and a kind-1,
    kind-2 or kind-6 record never names this account;
  - kind 3 has this account as exactly one of signer and subject. From a peer, the peer is the
    signer and this account the subject. From an own device, either this account signs — its
    own verification — or the record is a peer's claim forwarded in a snapshot (§3.5);
  - kind 5 with scope 1 or 2 names its sender as the owner;
- the kind is 1 to 6.

### 6.3 Who sends what to whom

| Kind | Registry name | Sent by | Sent to |
|---|---|---|---|
| 1 | `contact.entry_set` (new) | This account's devices | This account's other devices only |
| 2 | `contact.block_set` | This account's devices | This account's other devices only |
| 3 | `contact.master_verify` | The signer's devices | The subject's devices — the notice — and the signer's other devices; and, in a snapshot, a claim forwarded to a new own device |
| 4 | `protocol.notice` | Any device, in reply only (§6.4) | The devices of the peer it answers |
| 5 | `profile.publish` | The owner's devices | §7.3; in a snapshot, peers' keys forwarded to a new own device |
| 6 | (new) carried-over confirmation | This account's devices | This account's other devices only |

A kind that arrives from the wrong kind of sender is refused (§5.6).

### 6.4 Versions

`CPCTV` followed by three ASCII digits is the version. A device that opens a payload from a
peer whose version is higher than any it implements MUST drop it and reply to that peer's
devices with one kind-4 record naming the highest version it implements, at most once per peer
per UTC day. A higher version from one of this account's own devices is dropped with no reply:
the remedy is to update this device.

A device that receives kind 4 records the peer's version and uses it only to tell its user that
the peer's application is newer or older; it changes no state. Between two clients of this
version no kind 4 is ever sent.

### 6.5 Idempotency

A send of `POST /api/v1/envelopes` that is retried after a lost answer queues its items twice
(`backend/messaging/API.md`). Every kind is idempotent: kinds 1 and 2 by their order key, kind 3
by its bytes, kind 4 by being advisory, kind 5 by the profile version, kind 6 by its bytes.

### 6.6 Golden vectors

The inputs are those of §4.8, with Alice's phone `b3a91c77-2e5d-4f28-a1c9-8d64e0f3b522`, Alice's
tablet `0d4c8e2a-5b7f-4c1d-9e3a-7f2b6c8d1e40`, a removed account
`9c1e5f3a-2b4d-4e6f-8a0b-1c2d3e4f5a6b`, the profile key `a0a1…bebf` (the 32 bytes `a0` to `bf`)
and the group id `4041…5e5f` (the 32 bytes `40` to `5f`).

**Bob's attestation of Alice**, the signature inside Bob's notice:

```text
signed bytes  636861743a76313a757365722d7369676e696e672d6174746573746174696f6e
              000000102a77d4b9e6114c0f9f1c6a2e3b7d4e0f000000106f0c2f5e8a414c9e
              9a341f3d8f2b7c1000000020d04ab232742bb4ab3a1368bd4615e4e6d0224ab7
              1a016baf8520a332c9778737
signature     465adcc96c946dc02032601c0afd62cbe617b9b42d7d9b5273aa3f28084d0c77
              7b5307bb5603ee39b705dfb50da60f9b2efcac4fde2c01a4ed5421943a65e201
```

**Kind 3, Bob's notice to Alice's devices, a reply requested** (140 bytes):

```text
43504354563030310300012a77d4b9e6114c0f9f1c6a2e3b7d4e0f6f0c2f5e8a
414c9e9a341f3d8f2b7c10d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a
016baf8520a332c9778737465adcc96c946dc02032601c0afd62cbe617b9b42d
7d9b5273aa3f28084d0c777b5307bb5603ee39b705dfb50da60f9b2efcac4fde
2c01a4ed5421943a65e20101
```

**Kind 3, Alice's verification of Bob, for her own devices** (140 bytes; the signature is her
user-signing key's over her attestation of Bob's master key):

```text
43504354563030310300016f0c2f5e8a414c9e9a341f3d8f2b7c102a77d4b9e6
114c0f9f1c6a2e3b7d4e0f884b8857f4eaa1613c61504db34d4beaf346517a0e
31de3cddd4d9b4201d9d0b6bc3c92c3779abdff64a7f40019b6f68a16cc882e0
faacbb5a24dda68926ccd0ceaab476b423d0ec1eb7550ce58c03237f8bcb0464
7f9e00bf2cc946b235f10600
```

**Kind 1, two entries** — Bob on the list at revision 1 from Alice's phone, and the removed
account at revision 4 from her tablet (90 bytes):

```text
43504354563030310100022a77d4b9e6114c0f9f1c6a2e3b7d4e0f00000001b3
a91c772e5d4f28a1c98d64e0f3b5220103626f629c1e5f3a2b4d4e6f8a0b1c2d
3e4f5a6b000000040d4c8e2a5b7f4c1d9e3a7f2b6c8d1e400000
```

**Kind 2** — the removed account blocked at revision 2 from Alice's phone (48 bytes):

```text
43504354563030310200019c1e5f3a2b4d4e6f8a0b1c2d3e4f5a6b00000002b3
a91c772e5d4f28a1c98d64e0f3b52201
```

**Kind 4** — version 1: `435043545630303104000101`

**Kind 5** — Alice's key for profile version 7: to her own devices, with an audience of Bob;
direct; and group-scoped:

```text
own     43504354563030310500016f0c2f5e8a414c9e9a341f3d8f2b7c1000000007a0
        a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf00
        00012a77d4b9e6114c0f9f1c6a2e3b7d4e0f
direct  43504354563030310500016f0c2f5e8a414c9e9a341f3d8f2b7c1000000007a0
        a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf01
        0000
group   43504354563030310500016f0c2f5e8a414c9e9a341f3d8f2b7c1000000007a0
        a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf02
        404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f
        0000
```

**Kind 6** — a carried-over confirmation of Bob on Alice's devices (91 bytes):

```text
43504354563030310600012a77d4b9e6114c0f9f1c6a2e3b7d4e0f884b8857f4
eaa1613c61504db34d4beaf346517a0e31de3cddd4d9b4201d9d0bd04ab232742
bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737
```

The signatures were reproduced by three independent implementations of Ed25519 — the
`cryptography` package, OpenSSL 3.6.4 and the reference code of RFC 8032 §6 — and the
fingerprint by a second SHA-256. A client MUST reproduce every value here byte for byte, and
verify both signatures with `verify_user_attestation`, before any of this is enabled.

## 7. The profile key, and its rotation on blocking and on removal

### 7.1 One key per profile version

Every profile version an account publishes (`PUT /api/v1/me/profile`, whose version must
increase) is sealed in the `MetadataBlobV1` form of `frontend/docs/cryptographic-protocol.md`
§ "Profiles and labels" under a **fresh 32-byte key** from the shared core's random source. The
key of a version goes to the audience of the moment it is published (§7.2) and to nobody else.
So a person who leaves the audience can open no version published after they left — whatever
the reason they left — and "rotating the key" is publishing a new version.

### 7.2 The audience

Evaluated by the publishing device, from its own records, when it publishes:

- this account's other devices;
- every peer that is on the contact list, not blocked, and whose direct conversation is
  `MUTUAL`;
- every peer that is an active member of a group, or of a voice room, in which this account
  is an active member, and is not blocked.

Nobody else: not a removed contact who shares no group, not a peer whose conversation is not
`MUTUAL` and who shares no group, never a blocked peer.

**People who share a group stay in the audience** even when they are not, or are no longer,
contacts: their copies of this account's group messages are named from this profile, and
removing a contact is not a group act. To stop a person who shares a group from getting the
profile, the user blocks them or leaves the group.

### 7.3 Distribution

One kind-5 record per receiving person, carrying the owner (this account), the profile version,
and its key:

- **scope 0** to this account's other devices, with the audience as a list of user ids (§7.5);
- **scope 1, direct**, to a peer whose direct conversation is `MUTUAL` — admitted on the other
  side only in `MUTUAL` (§5.6);
- **scope 2, group**, naming one active group (or voice room) both accounts are active members
  of, to a peer reached only through a group — admitted on the other side exactly as a group
  event is: from an active member of a group it holds, while it is one itself, and held
  unopened when it has not verified the sender. When several groups are shared, the one with
  the lowest id is named. A group-scoped record naming a group or room the receiver does not
  hold, or one in which either account is not an active member, is dropped; it never prompts a
  state request.

The record goes to every live device of that person and to no one else. A person who enters
the audience — a conversation becomes `MUTUAL`, a contact is added back, a group gains a
member, this account joins a group — is sent the current version's record at once, and is not
the occasion for a new version.

### 7.4 Rotation on blocking and on removal

When the user blocks a peer, or removes a contact, the device that made the change:

1. applies the change and sends it to its own devices (§3.4);
2. reads its own profile with `GET /api/v1/me/profile`; with no profile there is nothing to
   rotate, and it stops;
3. seals the profile it holds, unchanged, under a fresh key as the next version and writes it
   with `PUT /api/v1/me/profile`; on `409 stale_version` it reads again and seals the next
   version under another fresh key, up to three times, and otherwise reports the failure and
   retries in the next delivery cycle;
4. computes the audience after the change (§7.2) and distributes the new version's key
   (§7.3), its own devices first.

The old key is never sent again. An unblock, or a contact added back, publishes nothing: the
person is sent the current version's record (§7.3).

### 7.5 Two devices of one account at once

Two devices can block or remove at the same moment, each publishing a version whose audience
lacks the other's change, and a device can miss the other's record altogether — an envelope
pruned while it was offline. The server's increasing version makes one publish newest. A
device that receives a scope-0 record with a profile version newer than any it holds MUST
compare its audience with its own records. When the audience names a peer this device holds as
blocked, or as removed and sharing no group or room with this account, the device:

1. sends again, to its own devices, the kind-1 or kind-2 record behind each such contradiction,
   so the other device learns what it missed;
2. then publishes again (§7.4, steps 2 to 4).

Each publish excludes everything its device knows, and the re-sent records reach the other
device before its next comparison, so the round ends with a version that excludes both
changes. A device publishes for this reason at most four times in one UTC day, and then waits
for the next: without the re-send of step 1, two devices that each lack the other's record
would publish in turn without end, and the newest version would alternate between excluding one
blocked person and the other.

### 7.6 Receiving a key

A device keeps, for each owner, the record with the highest profile version it has admitted,
fetches that version (`GET /api/v1/users/{user_id}/profile`) and opens it with that version's
key, under the existing checks — the author is a live device of the owner, the revision equals
the version (`ProfileService.refreshPeer`). A fetched version newer than its key — because the
owner published again and this device is not in the audience, or its record has not arrived —
is not opened, and the last authenticated profile stays on screen. A device forwards the keys it
holds only in a history-transfer snapshot (§3.5).

### 7.7 What this does not do

- **A removed or blocked person keeps what they already decrypted** — every version they opened
  and its key. They can still fetch the newest blob, since the server serves a profile to anyone
  who holds the `user_id` (`SECURITY.md` § "Finding a contact by name"), but cannot open it.
- People who share a group with the user keep receiving the profile (§7.2).
- Until a round of §7.5 ends, the newest version can be one that another of the user's devices
  published without knowing of a block or a removal.
- Live root sees each publish's fan-out, and can compare two of them to learn who stopped
  receiving the profile (§9).

## 8. What a file carries

### 8.1 What is removed, by kind

Every attachment is copied before it is encrypted (`frontend/docs/platform-android.md`,
"Attachments"). The removal happens on that copy, before it is encrypted, and the bytes it
leaves are the bytes that are sent; it never makes a copy larger. The format is recognised by
its content, never by its name or by the type the provider reports.

| Picked with | Kind | What is removed | Name sent | Warning (§8.4) |
|---|---|---|---|---|
| **Photo or video**, or **Camera** | A still image other than GIF | Everything: the existing re-encode to JPEG, kept as it is | `photo.jpg` | None |
| Photo or video | GIF | §8.2, GIF | `animation.gif` | None |
| Photo or video | MP4, MOV, 3GP | §8.2, ISO BMFF | `video.mp4`, `video.mov`, `video.3gp` | None, unless §8.2 reports a timed-metadata track |
| Photo or video | WebM | Nothing | `video.webm` | W1 |
| **File** | MP4, MOV, 3GP, M4A (ISO BMFF) | §8.2, ISO BMFF | Its own | W2, or W1 when a timed-metadata track remains |
| File | MP3 | §8.2, MP3 | Its own | W2 |
| File | GIF | §8.2, GIF | Its own | W2 |
| File | PNG | §8.2, PNG | Its own | W2 |
| File | Every other kind — JPEG, HEIC, WebP and other images, WebM, Matroska, Ogg, Opus, FLAC, WAV, AMR, PDF, office documents, text, archives | Nothing | Its own | W1 |

A name sent as "its own" is the provider's display name as the copy already cleans it. The
neutral names of the first column replace a name that a camera or a gallery usually derives from
the moment of capture, and a photo picked today keeps that name's base (`jpegName`); that changes.

### 8.2 The procedures

Each is a walk over the format's own structure, written over the Android framework with no
library. Each runs on the outgoing copy, and any structure it does not expect — a truncated
box, a size that runs past its container, an unknown critical chunk, a missing trailer — stops
it: the copy is sent as it was picked, with W1.

- **ISO BMFF** (a file whose first box is `ftyp`). Walk the boxes — `size:u32be`, `type[4]`;
  a size of 1 is followed by a 64-bit size, and a size of 0 runs to the end of its container —
  descending into `moov`, `trak`, `mdia`, `moof` and `traf`. **In place, without moving a
  byte:** rewrite the type of every `udta`, `meta` and `uuid` box found at the top level or
  directly in one of those containers to `free` and zero its contents; zero the creation and
  modification times of `mvhd`, `tkhd` and `mdhd` (bytes 4 to 11 of the contents in version 0,
  4 to 19 in version 1); zero the name of every `hdlr`. Nothing else is touched — not `mdat`,
  not a sample table, not `tfdt`. Location (QuickTime `©xyz`, Apple's
  `com.apple.quicktime.location.ISO6709`, 3GPP `loci`), maker, model, software, dates, titles
  and XMP all live in those boxes. A track whose `mdia/hdlr` type is neither `vide` nor `soun`
  is timed metadata — a camera's GPS or motion track — whose samples sit in `mdat` and cannot
  be removed in place, so the file keeps them and the warning is W1.
- **GIF.** Keep the header, the logical screen descriptor, the global colour table, every image
  block, every graphic-control extension (`0x21 0xF9`), every plain-text extension
  (`0x21 0x01`), and an application extension (`0x21 0xFF`) only when its 11-byte identifier
  is `NETSCAPE2.0` or `ANIMEXTS1.0` — the loop count. Drop comment extensions (`0x21 0xFE`),
  every other application extension (XMP among them), unknown extensions and anything after
  the trailer `0x3B`. A GIF has no internal offsets, so dropping a block moves nothing.
- **MP3.** Drop every ID3v2 tag at the start: `ID3` and a major version of 2 to 4, then its
  10-byte header, the number of bytes its synchsafe size gives, and a 10-byte footer when its
  flags say there is one. Then, until none matches, drop from the end:
  an ID3v1 tag (`TAG`, 128 bytes) and an ID3v1 enhanced tag before it (`TAG+`, 227 bytes), an
  APEv2 tag (footer `APETAGEX`, with its header when the footer says it has one), a Lyrics3v2
  block (`LYRICS200`) and an appended ID3v2.4 tag (footer `3DI`). The audio frames between are
  not touched.
- **PNG.** Keep the signature, the critical chunks `IHDR`, `PLTE`, `IDAT` and `IEND`, and only
  these ancillary chunks: `tRNS`, `cHRM`, `gAMA`, `iCCP`, `sBIT`, `sRGB`, `cICP`, `mDCV`,
  `cLLI`, `bKGD`, `hIST`, `pHYs`, `sPLT`, `acTL`, `fcTL` and `fdAT`. Drop every other ancillary
  chunk — `tEXt`, `zTXt`, `iTXt`, `eXIf` and `tIME` among them — and anything after `IEND`. A
  kept chunk is copied with its own CRC; an unknown critical chunk stops the procedure.

### 8.3 Proof before sending

The stripped copy MUST be opened before it replaces the picked one: by `MediaExtractor` for ISO
BMFF and MP3, which must report the same number of tracks as the original, and by `ImageDecoder`
for GIF and PNG, which must decode it at the same size. A copy that fails is discarded and the
original is sent, with W1. Nothing here needs the network, and nothing leaves the device but the
encrypted attachment.

### 8.4 The warning

Shown in the preview step (`frontend/docs/ui-specification.md` §8.2), above **Send**, for the
attachment it concerns. It informs only: **Send** stays enabled, and there is no extra
confirmation and no "do not show again".

- **W1** — "This file can carry hidden details: where and when it was made, who made it, the
  device it was made on, and its original name. They are sent as they are." For an image picked
  with **File**, followed by "Send it with Photo or video to remove them."
- **W2** — "Hidden details inside this file were removed. Its name is sent as it is."

### 8.5 Why these and not more

The rule applied: remove only where the format lets the metadata go without touching or moving
the media and without a library — then prove the result opens.

| Format | Why it is not stripped |
|---|---|
| JPEG picked with File | The orientation lives in the EXIF block a strip removes, so the picture would turn; a multi-picture or motion photo carries more images and a video after the first end-of-image marker. **Photo or video** already re-encodes it safely |
| HEIC, AVIF, WebP picked with File | Item locations (HEIF) or chunk flags and sizes (WebP) must be rewritten together with the metadata. **Photo or video** re-encodes them |
| WebM, Matroska | Element sizes are variable-length integers that a removal changes; a rewrite of the container is a remux |
| Ogg, Opus | Comments sit in a header packet; removing them re-pages the stream and recomputes every page checksum |
| FLAC, WAV, AMR | FLAC and WAV are rare from a phone and their tags are plain; AMR carries none. Not worth a parser each |
| PDF, office documents, archives | The metadata is an object graph, a set of XML parts or compressed members; a rewrite is a document editor, and their bodies hold what no strip reaches |

What no procedure removes: what is in the pixels, the sound or a document's body — a street
sign, a voice, tracked changes, an image embedded with its own metadata.

## 9. What the server sees

- No route, column, setting, rate scope or stored value changes, and nothing changes at rest:
  the seizure yield of `SECURITY.md` is the same. The contact list, the block list, claims and
  carried-over confirmations never reach the server.
- Everything new travels as ordinary padded envelopes: notices and replies (1 KiB), own-device
  records, the history-transfer snapshot, and profile keys. Live root sees them as it sees every
  envelope — which device writes to which device, and when — so it can see two accounts exchange a
  few small envelopes as they verify each other. At the first start of this version a device sends
  one envelope to each device of each peer it has verified, in a short window, and that set — a
  part of the social graph live root already sees (`SECURITY.md` § "Residual risk", items 1 and
  2) — is plain in it.
- A profile publish is a version written to the server and one envelope to each device of the
  audience. Comparing two publishes' fan-outs tells live root who stopped receiving the profile.
- The snapshot of §3.5 travels as a few envelopes to the new device. Their number and their
  buckets give live root the rough size of the contact state, as the history batches beside
  them give the rough size of the history.
- Scanning or importing a code reads the code's account by id
  (`GET /api/v1/users/{user_id}/identity`, then the existing peer refresh) — the same reads as any
  first contact. The code itself never reaches the server.
- Removing a file's metadata changes only bytes inside the ciphertext.

## 10. Security analysis

- **Downgrade.** No path makes a conversation `MUTUAL` without this account's own out-of-band
  verification on one of its devices; the only other ingredient is the peer's signature, or the
  one-time carried-over confirmation, which needs this device to have opened a message from the
  peer that the peer's earlier client sealed only after verifying this account. A notice from a
  client that predates this document cannot exist; one from a newer client is refused (§6.4)
  rather than half-read, and kind 4 changes no state.
- **Forged notices.** An unauthenticated claim changes no trust record and only shows an alert
  whose one action opens the comparison or the scanner. Forging one past the signature check needs
  the server to substitute the sender's whole identity, and that substitution is exactly what the
  comparison or a live scan exposes. A reply is sent only for an authentic claim.
- **A substituted code.** A code read from an image never verifies. A code whose fingerprint does
  not match the served master key adds nothing (§4.4). A code shown in person verifies the
  account in the code; scanning the right person's screen is the user's part, and the scanner
  names the account it verified.
- **Replay.** The ratchet refuses a replayed envelope. An attestation re-sent by its signer is
  harmless — it is a statement that stays true, or becomes void when either key changes. There is
  no withdrawal of a verification in this version.
- **Confusing trust states.** Trust records, claims and carried-over confirmations are separate
  records, and admission reads one derived state (§5.5). Only an out-of-band act on one of this
  account's devices writes `verified`; an own-device kind 3 is checked under this account's own
  user-signing key, so no peer can make a device believe this account verified someone.
- **The read of §5.3.** It runs the core's acceptance on an envelope from a sender whose key is
  not confirmed, commits nothing, and parses one fixed-length record. That widens no parser's
  reach: a server can already put any bytes in front of the same acceptance today, with a
  sender block forged to name a peer this device has verified, and only the init signature
  check refuses them. What the read adds is that one parse after the core, and one alert row,
  within the limits of §5.8 and ADR-093. It does double the core's work for each held initial,
  which a server can send at the rate it delivers envelopes.
- **Leaks to the server.** §9.
- **Exhaustion.** Claims, alerts, replies, held envelopes and the read are all bounded (§5.8,
  ADR-093), and so are the republishes of §7.5. The server can still drop a notice, as it can
  drop anything (`SECURITY.md`, residual risk 4); the reply and gap rules recover from a lost
  one, and the panel says what is pending.

## 11. What the client must prove

Each of these is a test that fails when the rule is broken, alongside the vectors of §4.8 and
§6.6:

- a notice never writes a trust record, whatever state it arrives in;
- an unauthenticated claim never makes a conversation `MUTUAL`, and becomes authentic, with no new
  message, at the verification of its signer;
- a direct-conversation event is admitted in `MUTUAL` only, on an existing session as on a new one;
  a dropped one still commits its session transition and is acknowledged in the same batch;
- the read of §5.3 commits nothing — no session, no device state, no consumed key — whatever the
  payload;
- a code read from an image never runs the confirmation; a mismatched code changes no record;
- an own-device kind 3 signed by anything but this account's user-signing key is refused;
- a reply is sent at most once per peer per UTC day, and never for an unauthenticated claim;
- a carried-over confirmation is recorded only at the migration, and only with an event from the
  peer;
- a profile version's key reaches no blocked peer and no removed contact outside a shared group;
- two devices that each miss the other's block converge in one round of §7.5, and never
  publish more than four times a day for it;
- every procedure of §8.2 leaves a file that opens, and its failure sends the original with W1.
