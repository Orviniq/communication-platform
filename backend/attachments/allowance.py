"""The daily upload allowance, counted in Redis and nowhere else.

What this replaces is the reason it exists. Until ADR-0025 an upload was charged
against a lifetime sum over `Attachment.uploader`, so the schema had to say which
account owned which stored bytes — a link between a person and a file that a
seizure reads directly. The allowance bounds the same thing without it: the count
is one integer under a key that names the account and the UTC day, it expires
after two days, and it never touches disk (invariant 6, Redis runs with
persistence off).

The cost of holding it outside the database is that a Redis restart forgets the
day's spend. That is recorded rather than hidden — `ACCEPTED_RISKS.md` AR-18 —
and it is bounded by the two controls that do not live in Redis: the free-space
guard of the upload route and the retention sweep.

An unreachable Redis refuses the upload with `503 unavailable`, the fail-closed
posture every other control on this store takes (ADR-0010).
"""

from django.conf import settings
from django.utils import timezone
from redis.exceptions import RedisError

from api.errors import ApiError
from api.redis import get_client

# Two days, so a key outlives the day it counts however the clock and the process
# disagree, and is gone long before the day comes round again.
KEY_TTL_SECONDS = 2 * 24 * 60 * 60

DAY_SPENT = "The day's upload allowance is spent."
UNAVAILABLE = "The service is temporarily unavailable."


def _key(user_id, day):
    return f"attach:day:{user_id}:{day.isoformat()}"


async def reserve(user_id, nbytes):
    """Charge `nbytes` against this account's allowance for today, or refuse.

    The reservation is taken before the bytes are written, so two uploads in
    flight cannot both pass a check and land above the allowance: `INCRBY` is one
    atomic round trip and the second caller reads the first one's charge. An
    upload that fails after this point gives the reservation back through
    `refund`, which is why the key is returned rather than rebuilt — a refund at
    midnight must not credit the day the upload did not spend.
    """
    key = _key(user_id, timezone.now().date())
    try:
        client = get_client()
        reserved = await client.incrby(key, nbytes)
        # Only the increment that created the key sets the expiry, so a busy
        # account pays one round trip an upload rather than two.
        if reserved == nbytes:
            await client.expire(key, KEY_TTL_SECONDS)
    except RedisError:
        raise ApiError(503, "unavailable", UNAVAILABLE)
    if reserved > settings.ATTACH_DAILY_BYTES:
        await refund(key, nbytes)
        raise ApiError(413, "quota_exceeded", DAY_SPENT)
    return key


async def refund(key, nbytes):
    """Give a reservation back, for an upload that was refused or failed.

    Silent when Redis is gone: the caller is already answering a refusal, and a
    second failure here would replace that answer with one about a store the
    client cannot act on. What an unrefunded reservation costs is one account's
    allowance for the rest of the day, and the key expires either way.
    """
    try:
        await get_client().decrby(key, nbytes)
    except RedisError:
        pass
