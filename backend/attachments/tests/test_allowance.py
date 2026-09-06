"""The daily upload allowance, driven directly against Redis.

The counter is the one control of this surface that keeps no row, so what it does
is only observable through the store: the assertions below read the key back, or
read the refusal the reservation raised. The same paths through the HTTP surface
are in `test_attachments.py`.
"""

import uuid
from datetime import date, timedelta

import pytest
import redis
from django.conf import settings
from django.utils import timezone
from redis.exceptions import ConnectionError as RedisConnectionError

from api.errors import ApiError
from attachments import allowance
from core.buckets import ATTACHMENT_BUCKETS

SMALLEST = min(ATTACHMENT_BUCKETS)


@pytest.fixture
def store():
    return redis.Redis.from_url(settings.REDIS_URL)


@pytest.fixture
def account():
    """A fresh account id for each test, so a key is never shared between two."""
    return uuid.uuid4()


def refusal(exc_info):
    error = exc_info.value
    return error.status_code, error.code, error.detail


class TestReserve:
    async def test_a_reservation_charges_the_day_and_returns_its_key(
        self, account, store
    ):
        key = await allowance.reserve(account, SMALLEST)

        assert key.endswith(timezone.now().date().isoformat())
        assert int(store.get(key)) == SMALLEST

    async def test_two_reservations_add_up(self, account, store):
        key = await allowance.reserve(account, SMALLEST)
        await allowance.reserve(account, SMALLEST)

        assert int(store.get(key)) == SMALLEST * 2

    async def test_the_key_expires_so_the_counter_never_outlives_its_day(
        self, account, store
    ):
        key = await allowance.reserve(account, SMALLEST)

        assert 0 < store.ttl(key) <= allowance.KEY_TTL_SECONDS

    async def test_a_second_reservation_does_not_push_the_expiry_out_again(
        self, account, store
    ):
        """`EXPIRE … NX` sets the expiry only where the key has none. A busy account
        that re-armed it on every upload would hold a counter for two days after its
        last upload rather than two days after the day it counts."""
        key = await allowance.reserve(account, SMALLEST)
        store.expire(key, 30)

        await allowance.reserve(account, SMALLEST)

        assert store.ttl(key) <= 30

    async def test_a_charge_that_lands_always_carries_an_expiry(self, account, store):
        """The counter and its expiry are one round trip, so there is no window in
        which a key exists without a TTL. Two calls would leave one: an `INCRBY`
        that landed and an `EXPIRE` that did not would spend the account's allowance
        for good, because no later upload would set the expiry either."""
        key = await allowance.reserve(account, SMALLEST)

        assert store.ttl(key) > 0
        assert int(store.get(key)) == SMALLEST

    async def test_the_reservation_that_lands_exactly_on_the_allowance_passes(
        self, account, store, settings
    ):
        """`reserved > allowance` refuses, so the upload that spends the last byte
        of the day is the last one admitted rather than the first refused."""
        settings.ATTACH_DAILY_BYTES = SMALLEST * 2
        await allowance.reserve(account, SMALLEST)

        key = await allowance.reserve(account, SMALLEST)

        assert int(store.get(key)) == SMALLEST * 2

    async def test_one_byte_past_the_allowance_is_refused(self, account, settings):
        settings.ATTACH_DAILY_BYTES = SMALLEST * 2 - 1
        await allowance.reserve(account, SMALLEST)

        with pytest.raises(ApiError) as exc_info:
            await allowance.reserve(account, SMALLEST)

        assert refusal(exc_info) == (413, "quota_exceeded", allowance.DAY_SPENT)

    async def test_a_refused_reservation_is_given_back(self, account, store, settings):
        """The refusal must not spend what it refused: an account at the boundary
        would otherwise lose an upload's worth of allowance every time it retried,
        and a client that retries is the normal case."""
        settings.ATTACH_DAILY_BYTES = SMALLEST * 2 - 1
        key = await allowance.reserve(account, SMALLEST)

        with pytest.raises(ApiError):
            await allowance.reserve(account, SMALLEST)

        assert int(store.get(key)) == SMALLEST

    async def test_an_allowance_below_one_bucket_refuses_the_first_upload(
        self, account, settings
    ):
        settings.ATTACH_DAILY_BYTES = SMALLEST - 1

        with pytest.raises(ApiError) as exc_info:
            await allowance.reserve(account, SMALLEST)

        assert refusal(exc_info)[0] == 413

    async def test_the_day_boundary_starts_a_fresh_allowance(
        self, account, store, settings, monkeypatch
    ):
        """The key names the UTC day, so the account that spent today's allowance
        has tomorrow's untouched. Without that the counter would be a rolling
        window an account could never clear."""
        settings.ATTACH_DAILY_BYTES = SMALLEST
        spent = await allowance.reserve(account, SMALLEST)
        tomorrow = timezone.now() + timedelta(days=1)
        monkeypatch.setattr(allowance.timezone, "now", lambda: tomorrow)

        fresh = await allowance.reserve(account, SMALLEST)

        assert fresh != spent
        assert int(store.get(fresh)) == SMALLEST

    async def test_one_account_never_spends_another_account_s_allowance(
        self, store, settings
    ):
        settings.ATTACH_DAILY_BYTES = SMALLEST
        first, second = uuid.uuid4(), uuid.uuid4()
        await allowance.reserve(first, SMALLEST)

        key = await allowance.reserve(second, SMALLEST)

        assert int(store.get(key)) == SMALLEST

    async def test_an_unreachable_store_fails_closed(self, account, monkeypatch):
        """The same posture the rate limiter takes (ADR-0010): a control that
        exists to refuse cannot answer "allow" when it cannot read its state.
        `503 unavailable` and not `413`, because the caller should retry."""

        class Unreachable:
            def pipeline(self, transaction=False):
                raise RedisConnectionError("refused")

        monkeypatch.setattr(allowance, "get_client", Unreachable)

        with pytest.raises(ApiError) as exc_info:
            await allowance.reserve(account, SMALLEST)

        assert refusal(exc_info) == (503, "unavailable", allowance.UNAVAILABLE)

    async def test_a_store_that_dies_mid_pipeline_fails_closed(
        self, account, monkeypatch
    ):
        """The whole reservation is inside one guard. A `RedisError` escaping it
        would become a `500` on a path whose refusal is a documented `503`."""

        class Broken:
            def pipeline(self, transaction=False):
                return self

            async def __aenter__(self):
                return self

            async def __aexit__(self, *exc):
                return False

            def incrby(self, key, amount):
                return self

            def expire(self, key, seconds, nx=False):
                return self

            async def execute(self):
                raise RedisConnectionError("refused")

        monkeypatch.setattr(allowance, "get_client", Broken)

        with pytest.raises(ApiError) as exc_info:
            await allowance.reserve(account, SMALLEST)

        assert refusal(exc_info)[0] == 503


class TestRefund:
    async def test_a_refund_gives_the_reservation_back(self, account, store):
        key = await allowance.reserve(account, SMALLEST)

        await allowance.refund(key, SMALLEST)

        assert int(store.get(key)) == 0

    async def test_a_refund_survives_an_unreachable_store(self, monkeypatch):
        """The caller is already answering a refusal. A second failure raised from
        here would replace that answer with one about a store the client cannot
        act on, and the key expires either way."""

        class Unreachable:
            async def decrby(self, key, amount):
                raise RedisConnectionError("refused")

        monkeypatch.setattr(allowance, "get_client", Unreachable)

        await allowance.refund("attach:day:whoever:2026-09-06", SMALLEST)


def test_the_key_names_the_account_and_the_day_and_nothing_else():
    """The key is the whole of what this control stores. A shape that carried a
    capability id, a size or a path would put the thing the schema avoids into the
    one store the design keeps off disk."""
    key = allowance._key(uuid.UUID(int=1), date(2026, 9, 6))

    assert key == "attach:day:00000000-0000-0000-0000-000000000001:2026-09-06"
