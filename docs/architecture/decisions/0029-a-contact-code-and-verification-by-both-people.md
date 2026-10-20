# 0029. A contact code finds a person beside the lookup, and a direct conversation needs both people verified

- Status: Accepted
- Phase: — (a change to the released `v1` client contract, after the rebuild's eleven phases)
- Date: 2026-10-20
- Landed: 2026-10-20, as binding client text: `backend/CLIENT_CONTACTS_AND_TRUST.md` and
  `backend/CLIENT_CONTRACT.md` §Q. No server code, route, column, setting or rate scope
  changed; the client's work is `CLIENT_WORK.md`.

## Context

[0028](0028-an-exact-username-lookup-replaces-the-directory.md) replaced the directory
with an exact username lookup and named its own flip trigger: a need to find a person by
something other than a name they have told you — "an invite link, a QR code, a phone
number — which is a new surface with an exposure review of its own". The owner has now
decided on a contact QR code. This record is that review.

The same decision changes the verification model the client contract states.
`backend/CLIENT_CONTRACT.md` §C made verification one-sided: a sender encrypts only to
peers it verified, and a receiver accepts only from peers it verified. So a message from a
sender who had verified its recipient, to a recipient who had not verified the sender,
could not be read, and neither person could tell why; a field test on 2026-10-17 found
exactly that, and client ADR-093 made the recipient hold the message rather than lose it.
The owner has decided that a direct conversation carries content only when both people have
verified each other, with a notice between them so each knows where the other stands; that
the contact list is the client's alone; that the profile key is rotated when the user blocks
someone or removes a contact; and that a file's metadata is removed where it safely can be
and announced where it cannot. Those four need no server and move no position of this
record; they are bound in the same client text.

## Decision

### 1. The contact code needs no server surface

A code is `CP-CONTACT-V1:` and the base32 of the account's `user_id`, a SHA-256
fingerprint of its master key under the domain `chat:v1:contact-code`, and its username
(`backend/CLIENT_CONTACTS_AND_TRUST.md` §4). A client that reads one reads the account's
identity by id — `GET /api/v1/users/{user_id}/identity` and the existing peer refresh —
and compares the fingerprint with the master key served. No route is added and none is
needed: the id is what every route addressed by an account already takes.

### 2. Its exposure

- **What a code reveals**, to whoever sees it or an image of it: the account's `user_id`,
  its username and a hash of a public key. Nothing secret, and nothing the lookup does not
  already answer for a discoverable name.
- **It goes around the discoverability setting, by design.** Showing a code is its owner's
  consent to be added. A code passed on as an image keeps working for whoever receives it,
  exactly as a passed-on `user_id` does today (`backend/SECURITY.md`: a `user_id` reaches
  everything addressed by one).
- **What the server learns** from a scan is one identity read by id — the read any first
  contact makes. It never sees the code.
- **What a code proves**, on its own: nothing. The fingerprint is a hash of public values
  anyone can compute. A code verifies only when it was read live, with the scanning phone's
  own camera from the other person's own screen, and its fingerprint matches the key the
  server serves. Read from an image it adds a contact and verifies nothing; a mismatch adds
  nothing at all.

### 3. A direct conversation needs both people verified, and the server takes no part

The rule, its allowlist, the notice, the state machine and the migration are
`backend/CLIENT_CONTACTS_AND_TRUST.md` §5 and §6. What matters to this record is that none
of it is server state: the notice is an ordinary padded envelope, the contact list and the
verifications travel between a user's own devices inside ordinary envelopes, and the server
stores, checks and learns nothing beyond the envelopes themselves (§9 there).

### 4. Where the text lives

`backend/CLIENT_CONTACTS_AND_TRUST.md`, beside the contract and binding as it is: the wire
formats, the state machine and the golden vectors would have doubled the contract's length.
The contract's §Q routes to it, and §C, §D, §E, §G and §P point at it where their text
moved. The document map of [0015](0015-the-document-map.md) holds: the new file is a
`backend/` document, and `CLIENT_WORK.md` routes to it.

## What this does not do

- **It does not hide that two accounts verify each other.** Live root sees the envelopes,
  and, once, the notices a device sends to every peer it has verified when the new client
  first starts. That is the social graph `backend/SECURITY.md` already says is not hidden.
- **It does not let anyone withdraw a verification.** An attestation stays true until either
  master key changes.
- **It does not change groups.** A group send still verifies every member and, when one is
  not verified, withholds the whole copy. The owner's brief assumed the send skips that
  member; the client does not, and the binding text records it as a decision for the owner
  (§5.9 there).
- **It does not make a removed contact forget** a profile version they already opened.

## Position fields

- **Forcing function.** The flip trigger of [0028](0028-an-exact-username-lookup-replaces-the-directory.md)
  fired: a person can now be found by a code they showed, which needed an exposure review.
  And a one-sided verification left a sender's message unreadable with no way for either
  person to know why.
- **Scale band.** Band 0, holding through band 2. The new traffic is a handful of 1 KiB
  envelopes per verification, one envelope per peer device at the first start, and one per
  audience device for each profile publish — sized in the review log.
- **Flip trigger.** For the code: a need to find a person by something neither told nor
  shown — an invite link, a phone number — which is a new surface again. For the rule: a
  decision to require it of groups, or a need for a third party to verify on a user's
  behalf.
- **Cost.** Two verifications, one in each direction, before a first message, where one was
  enough to send. A conversation with a peer whose client has not updated keeps working only
  if they had already verified each other. The client carries a new payload family, one new
  library (`com.google.zxing:core`, for the scanner) and the `CAMERA` permission. A profile
  publish costs one envelope per audience device, and live root can compare two of them.
- **Evidence.** Read from the client on 2026-10-20 at `be0eba5`: the hold of an unverified
  initial (`pairwise_opaque_envelope_inspector.dart`, `drift_sync_store.dart`, client
  ADR-093), the budgeted `policyBlocked` path (`durable_sync_engine.dart`), a session
  accepted earlier being opened with no trust check, and the group send that withholds the
  whole copy (`pairwise_fanout_coordinator_test.dart`). The golden vectors of the code and
  of every new payload were reproduced by three implementations of Ed25519 and a second
  SHA-256. No server measurement: nothing on the server changed. **Currency:** current.

## Consequences

- `backend/CLIENT_CONTACTS_AND_TRUST.md` is new and binding; `backend/CLIENT_CONTRACT.md`
  gains §Q and amends §C, §D, §E, §G and §P.
- `backend/SECURITY.md` restates residual risk 7 and the trust boundary, and gains
  § "Verification by both people, the contact code and the profile key".
- `REJECTED_PROPOSALS.md` records SPQR, the post-quantum ratchet, as entry 20.
- `CLIENT_WORK.md` carries the client's work and the client documents it changes.
- The "Contact discovery" position of `DESIGN-RECORD.md` names the code beside the lookup,
  and its flip trigger moves on.
- `API_CHANGES.md` is unchanged: no observable server behaviour moved.
