# 0023. One device-bound session token, renewed without rotation

- Status: Accepted
- Phase: 8
- Date: 2026-09-05
- Landed: 2026-09-05, in the fourth run of phase 8. `POST /api/v1/auth/refresh`,
  the `refresh` throttle scope, the `rgen` claim, the `scope` claim, the replay
  detection and every reader and writer of `Device.refresh_generation` are gone;
  `POST /api/v1/auth/renew` is in their place.

## Context

[0006](0006-device-bound-tokens-on-pyjwt.md) issued an access token of
`ACCESS_MIN` minutes beside a refresh token of `REFRESH_DAYS` days. A refresh
rotated the pair inside one transaction, advanced `Device.refresh_generation`,
and treated a token presenting an older `rgen` as a replay: `token_generation`
advanced and every token of the device died at once.

That rule is the OAuth 2.0 best current practice, and on this client it is a
sign-out. The client is one Flutter application running two Dart isolates in one
process, both holding the same refresh token from the same encrypted store. When
both reach expiry they both rotate, one of them wins, and the loser presents a
token the server has already retired. The server cannot tell that from a stolen
token — that is the whole point of the rule — so it ends the session of a device
that did nothing wrong.

The client paid for it. `frontend/docs/decisions.md` ADR-049 and ADR-050 and
`frontend/docs/sync-engine.md` record what it built: an in-process
exclusive-ownership gate around the token, a bounded re-read repair path for the
isolate that lost, and a three-owner arbitration so that only one of them may
rotate. That is a distributed-consensus problem inside one process, and it exists
because the server made one token unshareable between two readers of one store.

What reuse detection buys here is smaller than it looks. The adversary of this
threat model holds live root on the VPS, and so holds `JWT_SIGNING_KEY` and mints
whatever token it likes without touching the refresh route. What is left is a
token stolen off a client — from a SQLCipher database under a Keystore-wrapped
key, or from a TLS session pinned to a private CA. Reuse detection defends the
case those two already cover, and it defends it by ending the honest device's
session as often as the thief's.

## Decision

One device-bound session token. It is renewed on demand, and it never rotates.

1. **The claims.** `user_id`, `device_id`, `tgen`, `typ` with the value
   `session`, `jti`, `iat`, `exp`. Its lifetime is `SESSION_TOKEN_DAYS`, default
   30. The `scope` claim leaves: `typ` decides the power of a token, and the
   verifier requires and checks it on every decode.
2. **The register token is unchanged in power and lifetime.** `typ` with the
   value `register`, `user_id`, `jti`, `iat`, `exp`, lifetime
   `REGISTER_SCOPE_ACCESS_MIN`. It reaches `POST /api/v1/me/devices` and nothing
   else; presented anywhere else it is `403 scope_forbidden`, exactly as before.
3. **Login issues, and writes nothing.** With a `device_id` naming a live device
   of the account it answers `200` with `token`, `expires_in`, `user_id`,
   `device_id` and `scope` `full`; without one it answers `200` with `token`,
   `expires_in`, `user_id` and `scope` `register`. No generation moves, so a
   token the device already held survives the login.
4. **`POST /api/v1/me/devices` answers `201`** with `device_id`, `token`,
   `expires_in` and `scope` `full`.
5. **`POST /api/v1/auth/renew` takes a full-scope bearer token and no body.** It
   re-checks the device and the account through the same verifier every
   authenticated route uses, and answers `200` with `token` and `expires_in`. The
   presented token stays valid until its own `exp`. The rate-limit scope is
   `accounts`, and the route is safe to repeat.
6. **What leaves.** `POST /api/v1/auth/refresh`, the `refresh` throttle scope,
   `THROTTLE_REFRESH`, `ACCESS_MIN`, `REFRESH_DAYS`, the `rgen` claim, the replay
   detection, and every read and write of `Device.refresh_generation`.
7. **The column stays for one run.** `Device.refresh_generation` keeps its
   default and has no reader and no writer. A column leaves in two steps; run 08
   drops it.
8. **Revocation is unchanged.** Logout, device revocation, account deactivation
   and the socket close each advance `token_generation`, and every token of the
   device dies at once. `backend/api/auth.py` stays the only issuer and the only
   verifier, and `realtime/auth.py` calls it for the socket bind.
9. **An expiry does not close a live socket.** Revocation closes it.

## Position fields

- **Forcing function.** Rotation with reuse detection made a lost race between
  two readers of one token store a sign-out, and forced the client to build
  exclusive-ownership arbitration around one token. The server adversary of the
  threat model mints any token with the signing key regardless, so reuse
  detection defended only against a theft the transport pinning and the encrypted
  client store already prevent.
- **Scale band.** Band 0, holding through band 2. At most 500 devices. What
  changes with traffic is one route: the renewal runs once a session lifetime per
  device instead of once an access lifetime, so 30 days replaces 15 minutes as
  the interval, and it costs one query where the refresh cost two and a row lock.
- **Flip trigger.** A client platform with a weaker token store than a
  Keystore-wrapped SQLCipher database, or evidence of a stolen token. Either
  restores the value reuse detection was buying, and the answer is rotation
  again — with the client-side arbitration it needs.
- **Cost.** No reuse detection. A token stolen from a device stays valid until
  its `exp`, a logout or a revocation, and 30 days is a long window to hold one.
  Revocation granularity is one counter on the device row: there is no way to end
  one token and keep its siblings, and there never was.
  [`../../ACCEPTED_RISKS.md`](../../ACCEPTED_RISKS.md) AR-18 carries the row.
- **Evidence.** The client cost is recorded rather than predicted:
  `frontend/docs/decisions.md` ADR-049 and ADR-050 and
  `frontend/docs/sync-engine.md` describe the ownership gate, the repair path and
  the three-owner arbitration the rotation forced, and name the lost race as the
  reason each exists (read 2026-09-05). The rule this removes is
  [RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html) (BCP 240) §2.2.2, which
  requires a public client's refresh token to be sender-constrained or rotated,
  and §4.14, which describes rotation. Stated plainly rather than argued around:
  that requirement governs refresh tokens, and this design keeps none — it takes
  the third option the BCP does not offer, one long-lived bearer token, and pays
  the cost above for it. Sender-constraining is the alternative that would satisfy
  it, and it needs a key the client holds and proves per request, which is the
  flip trigger's answer if the cost stops being acceptable. PyJWT remains the
  reference Python implementation and still pins the algorithm list at decode.
  **Currency:** current.

## Consequences

- Supersedes [0006](0006-device-bound-tokens-on-pyjwt.md). What survives from it
  is the whole of the rest: PyJWT with HS256, no token table, device binding
  through `tgen`, the algorithm pin at every decode, and the register scope.
- The client may drop the rotation arbitration. It is not obliged to: an
  ownership gate around a token that no longer retires is harmless, and
  `CLIENT_WORK.md` records the removal as optional and the DTO change as
  required.
- A device may now hold several live tokens at once — from a login, from a
  registration, and from each renewal — and all of them work. Nothing in the
  server counts them, because nothing stores them.
- `scope` leaves the claims and stays in the response body of login and device
  registration, where it is the discriminator a client branches on. The
  `scope_forbidden` code keeps its meaning: an authentic register token used past
  its one route.
- `API_CHANGES.md` carries the removed route, the two changed bodies, the new
  route, the removed replay rule and the removed settings, each with the client
  action.
- `backend/SECURITY.md` states the model in the key table, the trust boundary and
  the seizure yield: the yield is one integer per device, where it was two.
