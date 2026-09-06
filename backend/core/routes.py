from django.conf import settings
from fastapi import APIRouter, Depends

from api.auth import allow_anonymous, require_full_device
from api.ratelimit import rate_limit
from api.schema import FULL_DEVICE, errors
from core.buckets import ATTACHMENT_BUCKETS, ENVELOPE_BUCKETS, SIGNAL_BUCKETS
from core.schemas import ConfigOut, HealthOut
from devices.schemas import MAX_CLAIM_DEVICE_IDS
from messaging.schemas import MAX_ACK_IDS, MAX_DRAIN_LIMIT, MAX_SEND_BATCH

router = APIRouter(tags=["core"])


@router.get(
    "/health",
    response_model=HealthOut,
    responses=errors(),
    dependencies=[Depends(allow_anonymous)],
)
async def health():
    """The client's startup reachability probe. It reads no state, so it needs no
    unit of work and carries no throttle scope."""
    return {"status": "ok"}


@router.get(
    "/config",
    response_model=ConfigOut,
    responses=errors(*FULL_DEVICE, "throttled"),
    # Declared here rather than on the router, because the router already carries
    # the anonymous health probe. The requirement still comes before the limiter
    # that keys on the account it puts on the request.
    dependencies=[Depends(require_full_device), Depends(rate_limit("accounts"))],
)
async def config():
    """The limits the client contract names, read from the settings and the
    constants the routes enforce rather than restated here.

    It exists because the client cannot otherwise state them. `ENVELOPE_TTL_DAYS`
    is an operator setting, and a client that tells a user how long an undelivered
    message survives has to be told what it is. Authenticated, because none of it
    is a secret and none of it is anyone's business before they hold a session.

    It touches no row, so it needs no unit of work.
    """
    return {
        "envelope_ttl_days": settings.ENVELOPE_TTL_DAYS,
        "attachment_ttl_days": settings.ATTACH_TTL_DAYS,
        "mailbox_max_bytes": settings.MAILBOX_MAX_BYTES,
        "max_devices_per_user": settings.MAX_DEVICES_PER_USER,
        "max_devicelog_records": settings.MAX_DEVICELOG_RECORDS,
        "session_token_days": settings.SESSION_TOKEN_DAYS,
        "send_batch_max": MAX_SEND_BATCH,
        "ack_max": MAX_ACK_IDS,
        "drain_page_max": MAX_DRAIN_LIMIT,
        "claim_max": MAX_CLAIM_DEVICE_IDS,
        "envelope_buckets": ENVELOPE_BUCKETS,
        "attachment_buckets": ATTACHMENT_BUCKETS,
        "signal_buckets": SIGNAL_BUCKETS,
        # Whether `POST /me/relay` mints a credential or answers
        # `503 voice_unconfigured`. A deployment with no relay serves no voice, and
        # a client that knows it can hide the call button rather than offer one
        # that fails.
        "voice_configured": bool(settings.TURN_URLS),
    }
