"""The devices routes: the cross-signing identity, the device registry, the prekey
pools, the device-list log, and the key claim.

Two routers, and a route belongs to exactly one of them. `registration` declares
the one requirement that admits a register-scope token; `authenticated` declares
the default, which is a full-scope token bound to a live device. A route on
neither is a failed gate, and `core/tests/test_route_table.py` is where it fails.
"""

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Response, status

from api.auth import Principal, require_full_device, require_register_or_full
from api.errors import ApiError
from api.orm import run_unit
from api.ratelimit import rate_limit
from api.schema import FULL_DEVICE, REGISTER_OR_FULL, errors
from devices import services
from devices.schemas import (
    ClaimIn,
    ClaimOut,
    DeviceLogAppendIn,
    DeviceLogAppendOut,
    DeviceLogPageOut,
    DeviceRegisteredOut,
    IdentityIn,
    IdentityOut,
    LabelUpdateIn,
    OtpkCountOut,
    OwnDeviceListOut,
    PeerDeviceListOut,
    PeerStateIn,
    PeerStateOut,
    PrekeyCountOut,
    PrekeyReplenishIn,
    RegisterDeviceIn,
    page_bounds,
)
from realtime.bus import close_device_sockets

registration = APIRouter(
    tags=["devices"], dependencies=[Depends(require_register_or_full)]
)
authenticated = APIRouter(tags=["devices"], dependencies=[Depends(require_full_device)])

FORBIDDEN = "This token does not belong to that device."


async def require_own_device(
    device_id: uuid.UUID, principal: Principal = Depends(require_full_device)
) -> Principal:
    """The gate on the routes only the device itself may use.

    Declared beside the requirement rather than written inside each handler, and
    resolved from the same cached `require_full_device` the router already ran, so
    the two cannot drift apart.
    """
    if principal.device.id != device_id:
        raise ApiError(403, "forbidden", FORBIDDEN)
    return principal


@registration.post(
    "/me/devices",
    response_model=DeviceRegisteredOut,
    status_code=status.HTTP_201_CREATED,
    responses=errors(
        *REGISTER_OR_FULL,
        "invalid_request",
        "bad_bucket",
        "identity_required",
        "device_limit",
        "payload_too_large",
        "throttled",
    ),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def register_device(
    payload: RegisterDeviceIn,
    principal: Principal = Depends(require_register_or_full),
):
    """The one route a register-scope token reaches: it mints the device that token
    exists to add, and answers with the full-scope pair bound to it."""
    return await run_unit(services.register_device, principal.user, payload)


@authenticated.get(
    "/me/devices",
    response_model=OwnDeviceListOut,
    responses={
        status.HTTP_304_NOT_MODIFIED: {
            "description": "`If-None-Match` carried the current ETag."
        },
        **errors(*FULL_DEVICE, "throttled"),
    },
    dependencies=[Depends(rate_limit("accounts"))],
)
async def own_devices(
    response: Response,
    if_none_match: Annotated[str | None, Header()] = None,
    principal: Principal = Depends(require_full_device),
):
    result = await run_unit(
        services.own_devices, principal.user.id, principal.device.id, if_none_match
    )
    if result is None:
        return Response(status_code=status.HTTP_304_NOT_MODIFIED)
    etag, body = result
    response.headers["ETag"] = etag
    return body


@authenticated.put(
    "/me/devices/{device_id}",
    # An empty body, so the document declares the status and no content rather
    # than the untyped object FastAPI would publish for a route with no model.
    response_class=Response,
    responses=errors(
        *FULL_DEVICE,
        "invalid_request",
        "bad_bucket",
        "not_found",
        "payload_too_large",
        "throttled",
    ),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def relabel_device(
    device_id: uuid.UUID,
    payload: LabelUpdateIn,
    principal: Principal = Depends(require_full_device),
):
    await run_unit(services.relabel, principal.user.id, device_id, payload.raw)
    return Response(status_code=status.HTTP_200_OK)


@authenticated.delete(
    "/me/devices/{device_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    responses=errors(*FULL_DEVICE, "invalid_request", "not_found", "throttled"),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def revoke_device(
    device_id: uuid.UUID, principal: Principal = Depends(require_full_device)
):
    await run_unit(services.revoke, principal.user.id, device_id)
    # After the unit, never inside it: the sockets must close against committed
    # state, and a bus that is down must not roll the revocation back. Through
    # `run_unit` because the helper is synchronous — it opens a connection of its
    # own rather than borrowing the loop's — and blocking calls belong off the
    # loop.
    await run_unit(close_device_sockets, device_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@authenticated.put(
    "/me/devices/{device_id}/prekeys",
    response_model=OtpkCountOut,
    responses=errors(
        *FULL_DEVICE,
        "forbidden",
        "invalid_request",
        "prekey_limit",
        "payload_too_large",
        "throttled",
    ),
    dependencies=[Depends(rate_limit("accounts")), Depends(require_own_device)],
)
async def replenish_prekeys(device_id: uuid.UUID, payload: PrekeyReplenishIn):
    return await run_unit(services.replenish, device_id, payload)


@authenticated.get(
    "/me/devices/{device_id}/prekeys/count",
    response_model=PrekeyCountOut,
    responses=errors(*FULL_DEVICE, "forbidden", "invalid_request", "throttled"),
    dependencies=[Depends(rate_limit("accounts")), Depends(require_own_device)],
)
async def prekey_count(device_id: uuid.UUID):
    return await run_unit(services.prekey_counts, device_id)


@authenticated.put(
    "/me/identity",
    # An empty body, so the document declares the status and no content rather
    # than the untyped object FastAPI would publish for a route with no model.
    response_class=Response,
    responses=errors(
        *FULL_DEVICE,
        "invalid_request",
        "stale_version",
        "payload_too_large",
        "throttled",
    ),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def publish_identity(
    payload: IdentityIn, principal: Principal = Depends(require_full_device)
):
    await run_unit(services.publish_identity, principal.user.id, payload)
    return Response(status_code=status.HTTP_200_OK)


@authenticated.get(
    "/users/{user_id}/identity",
    response_model=IdentityOut,
    responses={
        status.HTTP_304_NOT_MODIFIED: {
            "description": "`If-None-Match` carried the current ETag."
        },
        **errors(*FULL_DEVICE, "invalid_request", "not_found", "throttled"),
    },
    dependencies=[Depends(rate_limit("accounts"))],
)
async def peer_identity(
    user_id: uuid.UUID,
    response: Response,
    if_none_match: Annotated[str | None, Header()] = None,
):
    result = await run_unit(services.peer_identity, user_id, if_none_match)
    if result is None:
        return Response(status_code=status.HTTP_304_NOT_MODIFIED)
    etag, body = result
    response.headers["ETag"] = etag
    return body


@authenticated.post(
    "/peers",
    response_model=PeerStateOut,
    responses=errors(*FULL_DEVICE, "invalid_request", "payload_too_large", "throttled"),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def peer_state(payload: PeerStateIn):
    """Everything a sender needs to verify a set of recipients, in one call.

    A POST because the request carries a body — a list of ids each with the tag the
    client already holds — and a query string would not hold 64 of those. It reads
    state and writes none, which is what the retry paragraph of
    `devices/API.md` states and what keeps it on the `accounts` scope.
    """
    return await run_unit(services.peer_state, payload.peers)


@authenticated.post(
    "/me/devicelog",
    response_model=DeviceLogAppendOut,
    status_code=status.HTTP_201_CREATED,
    responses=errors(
        *FULL_DEVICE,
        "invalid_request",
        "bad_bucket",
        "devicelog_limit",
        "payload_too_large",
        "throttled",
    ),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def append_device_log(
    payload: DeviceLogAppendIn, principal: Principal = Depends(require_full_device)
):
    return await run_unit(services.append_log, principal.user.id, payload.records)


@authenticated.get(
    "/users/{user_id}/devicelog",
    response_model=DeviceLogPageOut,
    responses=errors(*FULL_DEVICE, "invalid_request", "throttled"),
    dependencies=[Depends(rate_limit("accounts"))],
)
async def peer_device_log(
    user_id: uuid.UUID, after: str | None = None, limit: str | None = None
):
    return await run_unit(services.peer_log, user_id, *page_bounds(after, limit))


@authenticated.get(
    "/users/{user_id}/devices",
    response_model=PeerDeviceListOut,
    responses={
        status.HTTP_304_NOT_MODIFIED: {
            "description": "`If-None-Match` carried the current ETag."
        },
        **errors(*FULL_DEVICE, "invalid_request", "throttled"),
    },
    dependencies=[Depends(rate_limit("accounts"))],
)
async def peer_devices(
    user_id: uuid.UUID,
    response: Response,
    if_none_match: Annotated[str | None, Header()] = None,
):
    result = await run_unit(services.peer_devices, user_id, if_none_match)
    if result is None:
        return Response(status_code=status.HTTP_304_NOT_MODIFIED)
    etag, body = result
    response.headers["ETag"] = etag
    return body


@authenticated.post(
    "/users/{user_id}/keys/claim",
    response_model=ClaimOut,
    # A device with no PQ material omits the PQ members entirely rather than
    # sending them as nulls, and an exhausted pool omits `otpk` the same way:
    # that absence is exactly the difference a client reads to tell a
    # classical-only bundle from a hybrid one. `exclude_unset` is what keeps the
    # declared model from filling them back in.
    response_model_exclude_unset=True,
    responses=errors(*FULL_DEVICE, "invalid_request", "payload_too_large", "throttled"),
    dependencies=[Depends(rate_limit("claim"))],
)
async def claim_keys(user_id: uuid.UUID, payload: ClaimIn):
    return await run_unit(services.claim, user_id, payload.device_ids)
