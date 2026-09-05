"""The database half of the gateway: the token check and the three writes.

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


def _touch_active(device_id):
    """Record the day the device was last seen, and only on the day it changes.

    `exclude` is not an optimisation of the write, it is what keeps the bind off
    a lock. `send` holds `SELECT ... FOR UPDATE` on each target device row until
    it commits (ADR-0017), and the device a send is delivering to is the device
    most likely to be reconnecting. An unconditional `UPDATE` waits out that
    transaction, and because a websocket scope enters no `ThreadSensitiveContext`
    (ADR-0005) it waits on the one executor thread every socket in the worker
    shares — so one bind stalls every socket's ORM work. A row that already says
    today fails the qual, takes no row lock, and never reaches the wait.
    """
    from django.utils import timezone

    from devices.models import Device

    today = timezone.now().date()
    Device.objects.filter(id=device_id).exclude(last_active_date=today).update(
        last_active_date=today
    )


async def authenticate_session(token_str):
    return await run_unit(_authenticate_session, token_str)


async def delete_envelopes(device_id, ids):
    return await run_unit(_delete_envelopes, device_id, ids)


async def touch_active(device_id):
    return await run_unit(_touch_active, device_id)
