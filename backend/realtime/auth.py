"""The database half of the gateway: the token check and the one write.

Each unit of work is a module-level synchronous function that opens no
transaction of its own and never awaits, and each has a thin `async` wrapper that
runs it through `api/orm.py`. That is the same shape every FastAPI route uses,
for the same reason: the ORM is synchronous, and a call to it from the event loop
raises. Splitting the pair also keeps the unit measurable — `tests/
test_query_counts.py` counts the queries of the synchronous half directly, which
it cannot do through the wrapper, because the wrapper's connection bracket closes
the connection the test's own transaction holds.
"""

from api.auth import decode_session, load_device
from api.errors import ApiError
from api.orm import run_unit


def _authenticate_session(token_str):
    """Validate a session token through the one verifier, exactly as the HTTP
    surface does: a device-bound token, a live device, an active account. Returns
    (user, device) on success, None on any failure."""
    try:
        claims = decode_session(token_str)
    except ApiError:
        return None
    device = load_device(claims)
    if device is None:
        return None
    return device.user, device


def _delete_envelopes(device_id, ids):
    from messaging.models import QueuedEnvelope

    QueuedEnvelope.objects.filter(recipient_device_id=device_id, id__in=ids).delete()


async def authenticate_session(token_str):
    return await run_unit(_authenticate_session, token_str)


async def delete_envelopes(device_id, ids):
    return await run_unit(_delete_envelopes, device_id, ids)
