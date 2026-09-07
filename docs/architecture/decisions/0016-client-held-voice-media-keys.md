# 0016. Client-held voice media keys

- Status: Superseded
- Phase: 1
- Date: 2026-09-03
- Landed: 2026-09-03, in the second run of phase 1
- Superseded by [0021](0021-relayed-webrtc-mesh-and-no-server-room.md) on
  2026-09-05: the SFU, the room object and the per-sender media key are gone, and
  a voice connection is keyed by DTLS between its two endpoints.

## Context

Voice runs through LiveKit, a selective forwarding unit on the same VPS as
everything else. An SFU forwards media; it does not need to decrypt it. But an
SFU that holds the media key is a wiretap at exactly the point the threat model
assumes is hostile, because the attacker with live root on the VPS has the SFU
too.

The system already has a mechanism for getting a secret from one device to
another without the server reading it: the pairwise PQXDH plus Double Ratchet
session that [0001](0001-pairwise-double-ratchet-group-fan-out.md) makes the
basis of everything else.

## Decision

Each voice participant generates a per-sender media key and distributes it to
every participant device over the pairwise session, carried in volatile `signal`
frames.

A `room_presence` leave triggers key rotation.

The server, LiveKit and coturn never hold a media key. The server side of voice
is unchanged.

## Position fields

- **Forcing function.** An SFU that can decrypt is a wiretap at the point the
  threat model assumes is hostile.
- **Scale band.** Band 0, holding through band 1. A room holds a small number of
  participants at this band.
- **Flip trigger.** A room needs a participant count at which per-sender key
  distribution over pairwise sessions stops being affordable — the same fan-out
  ceiling as [0001](0001-pairwise-double-ratchet-group-fan-out.md), reached
  sooner because a rotation repeats the distribution.
- **Cost.** Key distribution is O(participants) for each sender, and it repeats
  on every leave. A participant who joins mid-call needs every current sender's
  key before hearing anything.
- **Evidence.** Per-participant keys distributed out of band, with rotation on a
  membership change, is the model an SFU supports for end-to-end encrypted media:
  the SFU forwards frames whose payload it cannot read. **Currency:** current.

## Consequences

- The server side of voice does not change. LiveKit still mints join tokens and
  still forwards media; it simply never sees a key.
- Rotation on leave is what makes the guarantee forward-looking: a participant
  who leaves keeps the key for the media it already received, and nothing after.
- The `signal` frames that carry the keys are volatile and never touch disk, per
  invariant 7. That also means a key distribution missed during a reconnect is
  gone, and the client must ask again.
- `voicerooms/tests/test_media_key_isolation.py` was the executable form of the
  server-side half: no media key reaches a model, a serializer or a migration. It
  left with the `voicerooms` package — the tests when [0021](0021-relayed-webrtc-mesh-and-no-server-room.md)
  removed the room object, and the package itself in phase 10 run 08. The property
  it held is now held more broadly and by construction: `core/tests/test_manifest.py`
  and `core/tests/test_seizure_guard.py` walk **every** registered model and fail on
  any key-material column, so there is no voice-shaped exemption left to test for.
