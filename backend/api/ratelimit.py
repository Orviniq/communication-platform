"""The Redis rate limiter.

Counters are volatile data, so they live in Redis and never on disk, and they
live outside the process so that raising `WEB_CONCURRENCY` cannot multiply the
effective limit by the worker count. The window is fixed: one `INCR` under a key
that carries the window index, and one `EXPIRE` that arms it. `INCR` is a single
atomic round trip, so two concurrent requests can never read the same count.

The two commands travel as one pipeline, and the expiry is `NX` rather than
conditional on the count. Issued as two awaits with the `EXPIRE` guarded by
`count == 1`, they could be split: anything that stopped the coroutine between
them — a `RedisError` on the second command, or the cancellation a client
disconnect raises — left the key with no expiry at all, and no later request of
that window ever re-armed it, because `count == 1` is true once. Measured: a
handler cancelled between the two left `ratelimit:login:addr:…:<window>` at
`TTL -1`, permanently, in a store with no `maxmemory` bound. As one pipeline
neither command can land without the other, and `NX` makes the pair safe to
repeat, so a key that lost its expiry is re-armed by the next request of its
window instead of outliving the process. It is the same repair
`attachments/allowance.py` carries, for the same failure.

When Redis is unreachable a throttled route fails closed with `503`. A control
whose whole purpose is to refuse traffic must not open the door when its store
is down.
"""

import time

from django.conf import settings
from fastapi import Request
from redis.exceptions import RedisError

from api.errors import ApiError
from api.redis import get_client

# The period suffixes the throttle rates are written in, so the THROTTLE_* values
# and their defaults read the same as they always did.
_PERIODS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


def parse_rate(rate):
    """`"120/min"` to `(120, 60)`."""
    count, _, period = rate.partition("/")
    return int(count), _PERIODS[period[0]]


def _ident(request):
    """An authenticated request counts per account, so the limit follows the
    caller across their devices. Anything else counts per client address, which
    is trustworthy only because the process trusts a forwarded header from the
    proxy's own address alone."""
    principal = getattr(request.state, "principal", None)
    if principal is not None:
        return f"user:{principal.user.id}"
    client = request.client
    return f"addr:{client.host if client else 'unknown'}"


def rate_limit(scope):
    """The dependency that counts one request against `scope`."""

    async def limit(request: Request):
        rate, period = parse_rate(settings.THROTTLE_RATES[scope])
        now = int(time.time())
        key = f"ratelimit:{scope}:{_ident(request)}:{now // period}"
        try:
            # One round trip for both, so nothing can stop the coroutine between
            # them. `nx=True` sets the expiry only where the key has none, so a
            # request that finds an unarmed key arms it and one that finds an
            # armed key never pushes its window forward.
            async with get_client().pipeline(transaction=False) as pipe:
                pipe.incr(key)
                pipe.expire(key, period, nx=True)
                count, _armed = await pipe.execute()
        except RedisError:
            raise ApiError(503, "unavailable", "The service is temporarily unavailable.")
        if count > rate:
            raise ApiError(
                429,
                "throttled",
                "Request was throttled.",
                {"Retry-After": str(period - now % period)},
            )

    # The route table test reads the scope of each route off this name.
    limit.__name__ = f"rate_limit_{scope}"
    return limit
