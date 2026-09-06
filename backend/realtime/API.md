# realtime API — the `/ws` gateway and the relay credential

One WebSocket endpoint carries everything live: instant envelope delivery and volatile
device-to-device signals. Frames are JSON text objects in both directions — binary
frames are a protocol violation. Nothing relayed here is persisted or logged; the
durable message queue (see `messaging/API.md`) is the source of truth, and this socket
only makes it fast.

Delivery between sockets is Redis publish and subscribe, which holds a message only
for the instant it takes to hand it to whoever is connected. A frame published for a
device that is mid-reconnect is dropped, and the client's next REST drain is what
recovers it — which is why the queue, not this socket, is the contract for delivery.

**The gateway holds no presence.** There is no subscription frame, no `presence` frame
and no announcement on connect or on disconnect. A presence subscription is a contact
list the client declares to the server, and the server needs none of it
([ADR-0022](../../docs/architecture/decisions/0022-the-gateway-holds-no-presence.md)):
who is in a conversation is the client's knowledge, and presence between its members is
client protocol carried over `signal` frames like every other announcement.

**URL:** `wss://<host>/ws`

This app also serves one HTTP route, [at the end of this file](#mint-a-relay-credential):
the coturn credential a client needs before it can place a call. It is the whole of the
voice surface — everything else about a call is `signal` frames and client state.

## Connection and authentication

One handshake path. Send `Authorization: Bearer <session token>` on the upgrade
request. A valid session token accepts the connection; anything else — a bad token,
or no header at all — **refuses the handshake**: the server answers the upgrade
request with `403 Forbidden` and no WebSocket is ever established. There is no close
code to read, because the refusal is decided before the accept and there is no socket
to send one on. Treat a failed handshake as "renew the session token and reconnect".

The token is validated with the same strength as REST: signature and expiry, `typ`
`session` (a register token opens no socket), a live device whose `token_generation`
matches, and an active account. On success the socket subscribes to the device's
delivery topic, and that is the whole of the bind: it writes no row, so connecting
records nothing about the device (ADR-0024).

Every accepted socket is therefore already bound to a device: there is no
unauthenticated state, no in-band authentication frame and no deadline to meet.
`auth` is not a frame type, and one sent on a live socket is ignored like any other
unknown type.

## Frame limits

| Limit | Value | On violation |
|---|---|---|
| Frame encoding | JSON text object | close 4008 |
| Frame size | `WS_MAX_FRAME` (default 524288 bytes) | close 4008 |
| Message rate | 100 frames per rolling second | close 4008 |
| `signal` blob | standard base64 of exactly 1024, 4096 or 16384 bytes (`SIGNAL_BUCKETS`) | frame dropped |
| `ack` ids | ≤ 200 | frame dropped |
| Undelivered server frames queued for one socket | 256 | close 4008 |

Undecodable JSON, non-object JSON, and binary frames close 4008. Frames with an
unknown `type` are ignored (but still count against the rate limit). Malformed but
well-typed frames — a bad UUID, an off-bucket blob, a wrong-typed field — are silently
dropped without closing the socket, matching the volatile, fire-and-forget semantics.

The two size bounds are independent and a client never has to choose between them: the
longest legal `signal` blob is the base64 of the largest bucket, 21848 characters,
which rides inside a frame far below `WS_MAX_FRAME`.

The last row is backpressure rather than a frame the client sent. Server frames for a
socket that is not reading them are held in a bounded queue; past the bound the socket
is a slow consumer and is closed 4008. Read continuously, and treat a 4008 with no
preceding protocol error as a signal to reconnect and drain over REST.

## Client → server messages

### `ack`

```json
{ "type": "ack", "ids": ["e4f8a1c2-9b3d-4e5f-8a70-6c1d2e3f4a5b"] }
```

Deletes the named envelopes from this device's durable queue, exactly like
`POST /api/v1/me/envelopes/ack`. 1–200 UUIDs. Ids outside this device's mailbox match
nothing. No reply frame; the deletion is idempotent.

### `signal`

```json
{ "type": "signal", "to_device": "2a77d4b9-e611-4c0f-9f1c-6a2e3b7d4e0f", "blob": "kzXhc…" }
```

Volatile relay of an opaque string to one device. Delivered as a `signal` frame to
every live socket of the target device; dropped silently if the target is offline.

`blob` must be standard base64 that decodes to **exactly 1024, 4096 or 16384 bytes** —
one of `SIGNAL_BUCKETS`, the padding rule every stored ciphertext obeys, applied here
to the one ciphertext the server relays without storing. Pad the plaintext to a bucket
before you encrypt and encode; there is no shorter frame to fall back to, and an
announcement that would fit in a hundred bytes goes out as 1024.

A blob outside the rule drops the frame in silence, exactly like every other malformed
but well-typed frame: no close code, and no error frame to read. A blob longer than
the base64 of the largest bucket is refused on its length alone, before anything
decodes it.

The rule is a malformed-input guard and **never a security control**. A modified server
would relay anything a client sent it, so what it buys is length uniformity on the one
ciphertext that crosses this socket without being stored — nothing more, and no claim
above that.

The relayed frame does not name the sender — the sender identifies itself inside the
ciphertext if the protocol needs it.

## Server → client messages

### `envelope`

```json
{ "type": "envelope", "id": "e4f8a1c2-9b3d-4e5f-8a70-6c1d2e3f4a5b", "seq": 12, "blob": "kzXhc…" }
```

Live push of a queued envelope the moment it is accepted for this device. The same
envelope remains in the durable queue until acked, so a client may receive it here
and again on its next REST drain; deduplicate by `id`.

### `signal`

```json
{ "type": "signal", "blob": "kzXhc…" }
```

A volatile signal relayed from some device, carrying the sender's blob unchanged. The
type and the blob are the whole frame: there is no sender field, and the blob is base64
of one `SIGNAL_BUCKETS` length, because a blob that was not could not have been
relayed. Who sent it is whatever the ciphertext says, decrypted under the pairwise
session it belongs to.

## Close codes

| Code | Meaning | What the client does |
|---|---|---|
| 4003 | The device was revoked or its account deactivated while connected | Stop reconnecting; the token is dead and a fresh login on another device is required |
| 4008 | Protocol violation — binary frame, oversized frame, undecodable or non-object JSON, rate cap exceeded — or a slow consumer whose server-frame queue overflowed | Fix the frame, or read faster; reconnect and drain over REST |
| 1012 | The server is restarting and drained its sockets | Reconnect after a backoff; this is a deploy, not a fault |

**A refused handshake carries no code.** Authentication is decided before the accept,
so a server has no socket to send a close frame on and answers the upgrade request
with `403 Forbidden` instead. A failed handshake therefore means "refused": renew
the session token and retry. Once a socket has been accepted, every code above arrives
as a close frame.

## Mint a relay credential

**Method:** `POST`
**Path:** `/api/v1/me/relay`

The one HTTP route voice has, and the whole of what a call costs this server. A client
needs an ICE server to place a call, and the only one this deployment has is the
self-hosted coturn of
[ADR-0021](../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md).
Under coturn's `use-auth-secret` a credential is computed from a shared secret rather
than stored, so this route reads no row and writes none: there is no table behind it,
nothing to revoke, and a credential dies of its own expiry.

**The request takes no body.** A body, if sent, is ignored. The caller is identified by
the session token it presents, and the answer names nothing the caller asked for.

What the client does with the credential — the relay-only ICE policy, the mesh, the
signalling over `signal` frames, and when to refresh — is
[`CLIENT_CONTRACT.md`](../CLIENT_CONTRACT.md) §N, which is binding.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| — | | | none |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

None.

**Retry semantics.** Safe to repeat, and the route stores nothing for a retry to
conflict with. Every call mints a fresh username, and a credential already issued stays
good until its own expiry — so a client that retries a timed-out request holds two
working credentials rather than none, and either one works.

**Responses**

### Minted — `200 OK`

```json
{
  "urls": ["turn:chat.nimashadloo.dev:3478?transport=udp"],
  "username": "1757352000:qkT2wR1mVbA4cJ7fKpN0Zg==",
  "credential": "b0Zk9Qd4rXm2sT1uV7wY8aB3cD0=",
  "expires_in": 21600
}
```

| Field | What it is |
|---|---|
| `urls` | The configured `turn:` URLs, in the order the operator wrote them. This is the entire ICE server list: configure these and nothing else — no STUN server, and no relay this answer did not name |
| `username` | The Unix timestamp the credential expires at, a colon, and sixteen random bytes as URL-safe base64. It is the TURN REST API user name; pass it through unchanged |
| `credential` | Standard base64 of HMAC-SHA1 over `username` under the secret the backend and coturn share. It is the TURN REST API password. SHA-1 is not a choice this project makes — it is the digest coturn computes and compares, and what stands on it is an HMAC over a name that expires |
| `expires_in` | The seconds the pair stays good for, counted from the moment it was minted: `RELAY_CREDENTIAL_TTL_SECONDS`, default 21600 (six hours) |

**The username carries no account identifier and no device identifier**, and nothing
derived from either. It travels in the clear on a control channel that carries no TLS,
and it is the whole of what the credential tells the relay about a caller: two
credentials of one device look exactly like credentials of two devices, and nothing in
one joins to anything the backend holds. The relay still sees the source address of
each allocation, as every server sees its caller's address; `SECURITY.md` § "Voice"
states that visibility beside the rest.

### No relay configured — `503 Service Unavailable`

```json
{ "code": "voice_unconfigured", "detail": "This deployment serves no voice relay." }
```

`TURN_URLS` is empty, so there is no relay to mint a credential for. This is not a
fault and not a backoff: a client reads it as "this server does not do voice" and
offers no call button. It reports nothing about a relay that is configured but down —
the route reads the setting and never reaches coturn, so a credential minted against a
dead relay is a `200` and the call simply fails to connect.

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `relay`, default 60/min per account. `Retry-After` carries the seconds to wait.
The route makes no database query of its own, so the scope is there to bound how fast
one account can mint relay allocations rather than to protect the handler.
