"""The accounts routes: registration, login, the token lifecycle, the user
directory and the encrypted profile blobs.

Two routers, and a route belongs to exactly one of them. `anonymous` declares
that a route takes no credential; `authenticated` declares the default, which is
a session token bound to a live device. A route on neither is a failed gate,
and `core/tests/test_route_table.py` is where it fails.
"""

import uuid

from fastapi import APIRouter, Depends, Response, status

from accounts import services
from accounts.schemas import (
    DirectoryOut,
    EraseIn,
    LoginIn,
    LoginOut,
    ProfileIn,
    ProfileOut,
    RegisterIn,
    RegisterOut,
    SessionOut,
)
from api.auth import Principal, allow_anonymous, issue_session, require_full_device
from api.orm import run_unit
from api.ratelimit import rate_limit
from api.schema import FULL_DEVICE, errors

anonymous = APIRouter(tags=["accounts"], dependencies=[Depends(allow_anonymous)])
authenticated = APIRouter(tags=["accounts"], dependencies=[Depends(require_full_device)])


@anonymous.post(
    "/auth/register",
    response_model=RegisterOut,
    status_code=status.HTTP_201_CREATED,
    responses=errors(
        "invalid_request", "username_taken", "payload_too_large", "throttled"
    ),
    dependencies=[Depends(rate_limit("register"))],
)
async def register(payload: RegisterIn):
    return await run_unit(services.register, payload.username, payload.password)


@anonymous.post(
    "/auth/login",
    response_model=LoginOut,
    responses=errors(
        "invalid_request",
        "invalid_credentials",
        "account_inactive",
        "payload_too_large",
        "throttled",
    ),
    dependencies=[Depends(rate_limit("login"))],
)
async def login(payload: LoginIn):
    """Two success shapes: a session token when `device_id` names a live device
    of this account, and a register-scope token otherwise."""
    return await run_unit(
        services.login,
        payload.username.lower(),
        payload.password,
        payload.device_id,
    )


@authenticated.post(
    "/auth/renew",
    response_model=SessionOut,
    responses=errors(*FULL_DEVICE, "throttled"),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def renew(principal: Principal = Depends(require_full_device)):
    """Takes no body: the caller is identified by the token it presents, and the
    requirement above has already re-read the device row and its owner. Nothing
    is written, so a client that repeats the call after a dropped connection gets
    another token and loses nothing — the one it presented stays good until its
    own `exp`."""
    token, expires_in = issue_session(principal.user, principal.device)
    return {"token": token, "expires_in": expires_in}


@authenticated.post(
    "/auth/logout",
    status_code=status.HTTP_204_NO_CONTENT,
    responses=errors(*FULL_DEVICE, "throttled"),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def logout(principal: Principal = Depends(require_full_device)):
    """Takes no body: the caller is identified by the token it presents, and the
    device row is what carries the revocation. The presented token dies with
    every other token of the device, so a second call with it answers 401."""
    await run_unit(services.logout, principal.user.id, principal.device.id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@authenticated.delete(
    "/me",
    status_code=status.HTTP_204_NO_CONTENT,
    responses=errors(
        *FULL_DEVICE,
        "invalid_request",
        "invalid_credentials",
        "payload_too_large",
        "throttled",
    ),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def erase_account(
    payload: EraseIn, principal: Principal = Depends(require_full_device)
):
    """Delete this account and every row that depends on it.

    The one irreversible act the API offers, and the only authenticated route that
    asks for a password: the token that reached it lives thirty days and nothing
    detects its theft (AR-18). A wrong password counts against the same per-name
    cool-off `POST /auth/login` counts against.

    No audit row is written. The operator did nothing, and a row saying that this
    username erased itself on this day is exactly the record the erasure removes.
    """
    await run_unit(services.erase, principal.user, payload.password)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@authenticated.get(
    "/users",
    response_model=DirectoryOut,
    responses=errors(*FULL_DEVICE, "throttled"),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def user_directory():
    return await run_unit(services.directory)


@authenticated.get(
    "/users/{user_id}/profile",
    response_model=ProfileOut,
    responses=errors(*FULL_DEVICE, "invalid_request", "not_found", "throttled"),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def peer_profile(user_id: uuid.UUID):
    return await run_unit(services.peer_profile, user_id)


@authenticated.get(
    "/me/profile",
    response_model=ProfileOut,
    responses=errors(*FULL_DEVICE, "not_found", "throttled"),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def my_profile(principal: Principal = Depends(require_full_device)):
    return await run_unit(services.my_profile, principal.user.id)


@authenticated.put(
    "/me/profile",
    # An empty body, so the document declares the status and no content rather
    # than the untyped object FastAPI would publish for a route with no model.
    response_class=Response,
    responses=errors(
        *FULL_DEVICE,
        "invalid_request",
        "bad_bucket",
        "stale_version",
        "payload_too_large",
        "throttled",
    ),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def write_my_profile(
    payload: ProfileIn, principal: Principal = Depends(require_full_device)
):
    await run_unit(
        services.write_profile, principal.user.id, payload.raw, payload.version
    )
    return Response(status_code=status.HTTP_200_OK)
