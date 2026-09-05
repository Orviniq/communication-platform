# 0006. Device-bound tokens on PyJWT, with no token table

- Status: Superseded
- Phase: 2
- Date: 2026-09-03
- Landed: 2026-09-04, in the first run of phase 2
- Superseded by [0023](0023-one-device-bound-session-token.md) on 2026-09-05: the
  refresh token, the `rgen` claim, the `scope` claim, the rotation and its replay
  detection are gone, and one device-bound session token renewed without rotation
  replaces the pair. What that decision keeps from this one is the rest of it:
  PyJWT with HS256, no token table, device binding through `tgen`, the algorithm
  pin at every decode, and the register scope.

## Context

Authentication today is `djangorestframework-simplejwt` with its
`token_blacklist` app. That app keeps a row for every outstanding and every
blacklisted token.

A token table is a per-device login record at rest: which device authenticated,
when, and how often. The threat model assumes an attacker with live root on the
VPS, and invariant 3 already forbids a sender column and a membership table for
the same reason. A blacklist is a smaller version of the same leak.

simplejwt also leaves with DRF, per [0002](0002-fastapi-as-the-only-http-api-surface.md).

## Decision

PyJWT issues and verifies HS256 tokens with `JWT_SIGNING_KEY`. The claims are
`user_id`, `device_id`, `tgen`, `rgen`, `scope`, `typ`, `jti`, `iat` and `exp`.
Every decode pins the algorithm list, the token type and the required claims.

A full-scope access token is bound to one device; `tgen` is checked against
`Device.token_generation` on every request. A register-scope access token lives
`REGISTER_SCOPE_ACCESS_MIN` minutes and reaches only `POST /me/devices`.

`Device` gains `refresh_generation`. A refresh token carries `rgen`; a refresh
advances `refresh_generation` in one transaction and returns a new pair. A
refresh with a stale `rgen` and a valid `tgen` is reuse: the server advances
`token_generation`, kills every token of the device, and answers
`401 token_revoked`.

Login with a device id advances `refresh_generation`. Logout advances
`token_generation`, closes the device's sockets, and answers `204`. No token
table exists. `djangorestframework-simplejwt` and its `token_blacklist` app
leave.

## Position fields

- **Forcing function.** A token table is a per-device login record at rest, and
  the threat model refuses to keep one.
- **Scale band.** Band 0, holding through band 2. At most 500 devices.
- **Flip trigger.** Revocation must reach a live access token whose device is not
  the subject, or a second relying party appears and a shared HS256 secret stops
  being the right choice.
- **Cost.** Revocation granularity is exactly two counters on the device row. A
  stolen access token stays valid until it expires or one of the two generations
  moves. There is no way to revoke one token and keep its siblings.
- **Evidence.** Refresh-token rotation with reuse detection that revokes the
  whole family is the OAuth 2.0 security best current practice; this design
  applies it with the device row as the family. PyJWT is the reference Python
  implementation and supports pinning the algorithm list at decode.
  **Currency:** current.

## Consequences

- Two integer columns on `Device` replace a table that grows with every login.
  A seizure yields two counters, not a login history.
- Pinning `algorithms=["HS256"]` at every decode is what stops an `alg: none` or
  an algorithm-confusion token. It is a required part of the decision, not an
  implementation detail.
- Logout must close the device's sockets, so the gateway of
  [0004](0004-websocket-gateway-on-redis-pubsub.md) needs a revocation signal.
- `secure-code-auditor` owns the review of the implementation. This ADR fixes the
  claims, the binding and the revocation semantics.
