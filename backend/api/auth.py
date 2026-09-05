"""Token issue, token verification, and the authentication dependencies.

This module is the only issuer and the only verifier of a token in the system.
The FastAPI dependencies below and `realtime.auth` for the WebSocket gateway both
reach the same two functions, so a token the HTTP surface revokes is dead on the
socket as well.

No token is ever stored, and none rotates. One counter on the device row is the
whole of revocation: `token_generation` advances, and every token of the device
dies at once (ADR-0023).
"""

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import jwt
from django.conf import settings
from fastapi import Request

from accounts.models import User
from api.errors import (
    INVALID_TOKEN,
    SCOPE_FORBIDDEN,
    TOKEN_REVOKED,
    UNAUTHENTICATED,
    ApiError,
)
from api.orm import run_unit
from devices.models import Device

SESSION = "session"
REGISTER = "register"

# Every decode requires these. The library skips a check on an absent claim, so
# the require list is what turns a missing claim into a failure instead of a
# silently passed check.
_REQUIRED = ["exp", "iat", "jti", "typ", "user_id"]


@dataclass(frozen=True)
class Principal:
    """The caller of a route, after the token verified and the row was read."""

    user: object
    device: object
    claims: dict


def _now():
    return datetime.now(timezone.utc)


def _encode(claims):
    return jwt.encode(claims, settings.JWT_SIGNING_KEY, algorithm=settings.JWT_ALGORITHM)


def _claims(user_id, typ, lifetime):
    issued = _now()
    return {
        "user_id": str(user_id),
        "typ": typ,
        "jti": uuid.uuid4().hex,
        "iat": issued,
        "exp": issued + lifetime,
    }


def _issued(claims, lifetime):
    """The token and the seconds it lives, which is what every route answers.

    The lifetime is published rather than left in the claims for the client to
    read, so no client has to parse a token whose shape is this server's alone.
    """
    return _encode(claims), int(lifetime.total_seconds())


def issue_session(user, device):
    """The one token, bound to one device at the generation it was cut at."""
    lifetime = timedelta(days=settings.SESSION_TOKEN_DAYS)
    claims = _claims(user.id, SESSION, lifetime)
    claims["device_id"] = str(device.id)
    claims["tgen"] = device.token_generation
    return _issued(claims, lifetime)


def issue_register_scope(user):
    """The short-lived token whose only power is adding a device."""
    lifetime = timedelta(minutes=settings.REGISTER_SCOPE_ACCESS_MIN)
    return _issued(_claims(user.id, REGISTER, lifetime), lifetime)


def _invalid_token():
    return ApiError(401, "invalid_token", INVALID_TOKEN)


def decode(raw):
    """Verify a token and return its claims. No I/O happens here.

    Pinning `algorithms` is what stops an `alg: none` token and an
    algorithm-confusion token. `typ` is what carries the power of a token, so a
    value outside the two this module mints is refused here rather than
    interpreted by a caller below.
    """
    if not isinstance(raw, str):
        raise _invalid_token()
    try:
        claims = jwt.decode(
            raw,
            settings.JWT_SIGNING_KEY,
            algorithms=[settings.JWT_ALGORITHM],
            options={"require": _REQUIRED},
        )
    except jwt.PyJWTError:
        raise _invalid_token()
    if claims["typ"] not in (SESSION, REGISTER):
        raise _invalid_token()
    return claims


def _device_bound(claims):
    """Every session token names a device and the generation it was cut at."""
    try:
        uuid.UUID(str(claims["device_id"]))
    except (KeyError, TypeError, ValueError):
        raise _invalid_token()
    if not isinstance(claims.get("tgen"), int):
        raise _invalid_token()
    return claims


def decode_session(raw):
    """A session token, and nothing else.

    A register token reaching here is authentic and is being used past the one
    route it was given, which is a `403` rather than the `401` a token nobody
    minted answers.
    """
    claims = decode(raw)
    if claims["typ"] != SESSION:
        raise ApiError(403, "scope_forbidden", SCOPE_FORBIDDEN)
    return _device_bound(claims)


def load_device(claims):
    """One query for the device row and its owner's activation state.

    Returns None when the device is gone, revoked, cut at an older token
    generation, or owned by an account the operator deactivated. The caller
    reports all four identically: the client learns only that this token is
    finished.

    `queue_pruned_through` rides along so the envelope drain can report it
    without a second device query.
    """
    device = (
        Device.objects.select_related("user")
        .only(
            "id",
            "user_id",
            "token_generation",
            "revoked_date",
            "queue_pruned_through",
            "user__is_active",
        )
        .filter(
            id=claims["device_id"],
            user_id=claims["user_id"],
            revoked_date__isnull=True,
        )
        .first()
    )
    if device is None or device.token_generation != claims["tgen"]:
        return None
    if not device.user.is_active:
        return None
    return device


def load_register_user(claims):
    """The owner of a register-scope token, or None when the account is gone or
    the operator deactivated it. A register token names no device, so the device
    generation has nothing to check here."""
    return User.objects.filter(id=claims["user_id"], is_active=True).only("id").first()


def bearer(request):
    """The token of an `Authorization: Bearer` header, or a 401."""
    header = request.headers.get("authorization")
    if header is None:
        raise ApiError(
            401, "unauthenticated", UNAUTHENTICATED, {"WWW-Authenticate": "Bearer"}
        )
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise ApiError(
            401, "unauthenticated", UNAUTHENTICATED, {"WWW-Authenticate": "Bearer"}
        )
    return token.strip()


async def require_full_device(request: Request) -> Principal:
    """The default requirement of every route: a session token whose device is
    live and whose account is active."""
    claims = decode_session(bearer(request))
    device = await run_unit(load_device, claims)
    if device is None:
        raise ApiError(401, "token_revoked", TOKEN_REVOKED)
    principal = Principal(user=device.user, device=device, claims=claims)
    request.state.principal = principal
    return principal


async def require_register_or_full(request: Request) -> Principal:
    """The requirement of device registration, and of nothing else.

    A register token names no device, so the principal it builds carries none;
    the route it reaches is the one that mints the device the caller lacks. Every
    other route takes `require_full_device`, which refuses that token.
    """
    claims = decode(bearer(request))
    if claims["typ"] == SESSION:
        _device_bound(claims)
        device = await run_unit(load_device, claims)
        if device is None:
            raise ApiError(401, "token_revoked", TOKEN_REVOKED)
        principal = Principal(user=device.user, device=device, claims=claims)
    else:
        user = await run_unit(load_register_user, claims)
        if user is None:
            raise ApiError(401, "token_revoked", TOKEN_REVOKED)
        principal = Principal(user=user, device=None, claims=claims)
    request.state.principal = principal
    return principal


async def allow_anonymous(request: Request) -> None:
    """The declared requirement of a route that takes no credential. A route
    declares this or `require_full_device`; a route that declares neither is a
    failed gate, and `core/tests/test_route_table.py` is where it fails."""
    request.state.principal = None
