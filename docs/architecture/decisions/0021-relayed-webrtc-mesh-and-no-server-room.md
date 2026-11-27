# 0021. Voice is a relayed WebRTC mesh, and the server holds no room

- Status: Accepted
- Phase: 6 and 7
- Landed: 2026-09-05. Phase 6 removed the SFU, the room object, the join token
  and the four room frames; phase 7 landed the route that mints a coturn
  credential, `POST /api/v1/me/relay`, and the client contract for the offer,
  the answer and the candidates.
- Date: 2026-09-05

## Context

Voice was designed around a self-hosted LiveKit SFU behind nginx at `/rtc`, a
`POST /api/v1/rooms/{room_id}/token` route that minted join tokens, a persistent
`Room` row holding an encrypted name, live membership in Redis, four room frames
on `/ws`, and the per-sender media keys of
[0016](0016-client-held-voice-media-keys.md). None of it was ever built on the
client: `frontend/pubspec.yaml` declares no media package and
[`frontend/docs/voice-and-realtime.md`](https://github.com/Orviniq/communication-platform/blob/a75e70004d598835806b28ef95ac7d5b595960e8/frontend/docs/voice-and-realtime.md#status) records the design as unbuilt.

Three things make that design undeliverable at this band.

**The client cannot encrypt the frames the design assumes.** `livekit_client`
2.11.0 requires `connectivity_plus ^7.0.0`, and the client froze
`connectivity_plus` at 6.0.5 because 7.1.0 and later force `androidx.core` 1.18.0
and `compileSdk` 36.1 (`frontend/docs/decisions.md`, ADR-054). It also pins
`flutter_webrtc` 1.6.0 exactly and adds twelve Dart packages. Its own frame cipher
is not SFrame: it derives a 128-bit AES-GCM key with PBKDF2-HMAC-SHA256 from the
raw key material and a ratchet salt, in `frame_crypto_transformer.cc` of
webrtc-sdk, and leaves one byte of each audio frame unencrypted. That format is
not RFC 9605. No SFrame implementation exists for Dart on pub.dev, and
`flutter_webrtc` exposes no frame-transform hook apart from that cipher. So the
recorded design needs a fork, a native patch or a new protocol implementation in
Dart — each of which the client shipping rule names as a defect.

**The room object is server-held group state.** A `Room` row, a live membership
set, a room topic and a join token are the same class of thing
[0001](0001-pairwise-double-ratchet-group-fan-out.md) removed from group
messaging: state on the server that describes who talks to whom. Keeping it for
voice contradicts the position that removed it for text.

**An SFU is a third party in the media path.** It is one more process, holding one
more infrastructure secret, on a host whose adversary already has root, for a band
whose rooms hold ten people.

## Decision

1. Voice is audio only. The media transport is WebRTC between client devices:
   audio over SRTP, keyed by DTLS between the two endpoints of each connection.
2. The topology is a full mesh. Every media path crosses the self-hosted coturn
   relay. The client uses a relay-only ICE policy, so no peer learns another
   peer's address and no STUN exists.
3. The key source is DTLS-SRTP. The keys of a connection exist on its two
   endpoints only. The backend and coturn hold no DTLS key and no media key. No
   application-level media key exists.
4. The frame encryption is SRTP under the profile the two endpoints negotiate.
   coturn relays encrypted packets it cannot open.
5. Key rotation is inherent. A connection's keys die with the connection. A
   removed member has no connection and gets no offer.
6. The SDP offers, the SDP answers and the ICE candidates travel inside
   pairwise-session ciphertext over `/ws` `signal` frames. The server relays them
   and cannot read or replace a DTLS fingerprint.
7. The server holds no room object. The room record, the room capability and the
   join token leave the server. The live membership, the room topic, the room
   presence and the ephemeral text topic leave the server. A room is client
   state, carried by client-signed control events over ordinary envelopes,
   exactly as a group is. Ephemeral room text and join and leave announcements
   are `signal` frames the client fans out to each member device.
8. The SFU leaves. LiveKit, its unit, its configuration, its nginx location, its
   ports and its settings leave.
9. coturn stays as the only media relay, without TLS: it listens on UDP and TCP
   port 3478, answers no STUN, denies private, link-local and loopback peers, and
   writes no log. Its credentials are the TURN REST API form under
   `use-auth-secret`. The backend mints them in phase 7.

## Position fields

- **Forcing function.** The recorded design cannot be built by the client
  developer with maintained packages at their published state, and it keeps
  server-side room state that
  [0001](0001-pairwise-double-ratchet-group-fan-out.md) removed everywhere else.
- **Scale band.** Band 0, holding through band 1. The design point is at most ten
  participants in one room.
- **Flip trigger.** A room needs more participants than a mesh affords — each
  participant carries one uplink for each peer — or the relay's uplink saturates.
  The answer at that point is an SFU again, and it costs the client an end-to-end
  media-encryption layer that does not exist for Dart today.
- **Cost.** Uplink is O(participants) for each participant, and every stream
  crosses the relay twice, so the relay carries O(participants²) of traffic for
  one room. coturn sees the relay peer pairs, the packet sizes and the timing.
  The gateway sees which device signals which device.
- **Evidence.** Verified on 2026-09-05. `flutter_webrtc` 1.6.1 on pub.dev,
  published 2026-09-01 by the verified publisher flutter-webrtc.org, MIT, Dart SDK
  3.3 or later. Its Android build declares `compileSdkVersion 36` and
  `minSdkVersion 21`, depends on `io.github.webrtc-sdk:android:150.7871.01`,
  `com.github.davidliu:audioswitch` at commit
  `039a35aefab7747c557242fa216c9ea11743b604` from JitPack, and
  `androidx.annotation:annotation:1.1.0`. It declares no `androidx.core`
  dependency, so the client's frozen `androidx.core` 1.16.0 and
  `connectivity_plus` 6.0.5 pins hold. Its Android plugin parses
  `iceTransportPolicy` with the value `relay`. The `flutter_webrtc` 1.6.1 plugin
  manifest declares no permission; the `audioswitch` manifest declares `BLUETOOTH`
  with `maxSdkVersion` 30 and `MODIFY_AUDIO_SETTINGS`; the libwebrtc AAR manifest
  declares no permission. DTLS-SRTP is the key exchange every WebRTC endpoint
  implements, so the media path needs no protocol this project writes. coturn's
  `use-auth-secret` form is a username of a Unix expiry timestamp, a colon and any
  string, with the password base64 of HMAC-SHA1 over the username under the shared
  secret; coturn denies loopback peers unless `--allow-loopback-peers` is set, and
  `--denied-peer-ip`, `--no-tls`, `--user-quota` and `--total-quota` exist.
  **Currency:** current.

## Consequences

- The server surface of voice is smaller than the server surface of text. One
  route mints a relay credential and there is no other: no voice model, and no
  frame of the call's own — a call is `signal` frames between devices, and the
  room itself is control events over ordinary envelopes.
- The honest limit, which `backend/SECURITY.md` repeats: a mesh costs each
  participant one uplink for each peer. At ten participants that is nine encodes
  and nine uplinks on a phone, and the relay carries every one of them twice.
  coturn sees the relay peer pairs, the packet sizes and the timing, and room
  membership is inferable from the gateway's signal fan-out exactly as group
  membership is inferable from envelope fan-out.
- coturn is no longer behind a certificate. It had been reading
  `/etc/letsencrypt/live/`, a public-CA path the rest of the deployment left
  behind when nginx moved to the private CA; a relay that carries SRTP it cannot
  open needs no TLS listener of its own, so the listener, the certificate paths
  and the deferral about them all go with it.
- The join token is gone, and with it the second issuer of a token this API
  accepts. `backend/api/auth.py` is the only issuer and verifier of one again,
  which is invariant 8: the coturn credential phase 7 mints is presented to the
  relay and never to this server. `core.E005` weighed one secret from phase 6
  until phase 7 gave it the relay secret, which it weighs only where `TURN_URLS`
  names a relay to mint for.
- Phase 7 landed what this ADR deferred. `POST /api/v1/me/relay`
  (`backend/realtime/routes.py` and `backend/realtime/relay.py`) mints a coturn
  credential from `TURN_STATIC_AUTH_SECRET` — a username of a Unix expiry
  timestamp, a colon and sixteen random bytes, and a password of base64 of
  HMAC-SHA1 over that username — good for `RELAY_CREDENTIAL_TTL_SECONDS` and
  carrying no account identifier and no device identifier.
  `backend/realtime/API.md` publishes the route and
  `backend/CLIENT_CONTRACT.md` §N is the client contract for the offer, the
  answer and the candidates.
- Supersedes [0016](0016-client-held-voice-media-keys.md) in whole. Its per-sender
  media keys, its rotation on a `room_presence` leave and its `signal`-frame
  distribution all describe a surface that no longer exists, and DTLS-SRTP gives
  the property it was reaching for without an application-level key at all.
