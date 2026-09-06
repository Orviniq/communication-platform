"""The Redis rate limiter.

Counters are volatile data, so they live in Redis and never on disk, and they
live outside the process so that raising `WEB_CONCURRENCY` cannot multiply the
effective limit by the worker count. The scope names and the `N/period` syntax are
the ones the deployment already holds, so no operator value is re-tuned.
"""

import time

import pytest
from django.conf import settings
from redis.exceptions import ConnectionError as RedisConnectionError

from api.ratelimit import parse_rate

pytestmark = pytest.mark.django_db(transaction=True)

DIRECTORY_URL = "/api/v1/users"
LOGIN_URL = "/api/v1/auth/login"


@pytest.mark.parametrize(
    "rate, expected",
    [
        ("10/hour", (10, 3600)),
        ("120/min", (120, 60)),
        ("600/minute", (600, 60)),
        ("5/s", (5, 1)),
        ("1/day", (1, 86400)),
    ],
)
def test_the_rate_syntax_is_the_one_the_deployment_already_holds(rate, expected):
    assert parse_rate(rate) == expected


def test_every_declared_scope_has_a_rate():
    assert set(settings.THROTTLE_RATES) == {
        "register",
        "login",
        "accounts",
        "claim",
        "envelopes",
        "attachments",
        "relay",
    }


def test_the_limit_answers_429_with_a_retry_after(
    http, active_user, device, bearer, settings
):
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": "2/min"}
    headers = bearer(active_user, device)

    assert http.get(DIRECTORY_URL, headers=headers).status_code == 200
    assert http.get(DIRECTORY_URL, headers=headers).status_code == 200

    throttled = http.get(DIRECTORY_URL, headers=headers)

    assert throttled.status_code == 429
    assert throttled.json()["code"] == "throttled"
    assert 0 < int(throttled.headers["retry-after"]) <= 60


def test_an_authenticated_limit_follows_the_account_across_its_devices(
    http, active_user, device, bearer, settings
):
    """Keyed on the account, so a caller cannot buy a second allowance by adding
    a device."""
    from devices.models import Device

    second = Device.objects.create(
        user=active_user,
        ik_pub=b"ik2",
        spk_id=2,
        spk_pub=b"spk2",
        spk_sig=b"sig2",
        registration_id=7777,
    )
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": "1/min"}

    assert http.get(DIRECTORY_URL, headers=bearer(active_user, device)).status_code == 200

    assert http.get(DIRECTORY_URL, headers=bearer(active_user, second)).status_code == 429


def test_an_anonymous_limit_counts_the_caller_address(http, settings):
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "login": "1/min"}
    body = {"username": "ghost", "password": "a-sufficiently-long-passphrase"}

    assert http.post(LOGIN_URL, json=body).status_code == 401

    assert http.post(LOGIN_URL, json=body).status_code == 429


def test_a_scope_counts_only_itself(http, active_user, device, bearer, settings):
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": "1/min"}
    headers = bearer(active_user, device)

    assert http.get(DIRECTORY_URL, headers=headers).status_code == 200
    assert http.get(DIRECTORY_URL, headers=headers).status_code == 429

    # A different scope, untouched by the exhausted one.
    assert http.get("/api/v1/health").status_code == 200


def test_an_unreachable_store_fails_closed(
    http, active_user, device, bearer, monkeypatch
):
    """A control whose whole purpose is to refuse traffic must not open the door
    when its store is down. `503 unavailable` is a distinct signal from `429
    throttled`: one is an outage, the other is backoff."""

    class Unreachable:
        async def incr(self, key):
            raise RedisConnectionError("refused")

    monkeypatch.setattr("api.ratelimit.get_client", lambda: Unreachable())

    response = http.get(DIRECTORY_URL, headers=bearer(active_user, device))

    assert response.status_code == 503
    assert response.json()["code"] == "unavailable"


def test_an_unthrottled_route_survives_an_unreachable_store(http, monkeypatch):
    """Health carries no scope, so the probe an operator uses to see the outage is
    not itself taken down by it."""

    class Unreachable:
        async def incr(self, key):
            raise RedisConnectionError("refused")

    monkeypatch.setattr("api.ratelimit.get_client", lambda: Unreachable())

    assert http.get("/api/v1/health").status_code == 200


@pytest.mark.parametrize(
    "rate, failure",
    [
        ("10/fortnight", KeyError),
        ("10", IndexError),
        ("ten/min", ValueError),
        ("", ValueError),
        ("/min", ValueError),
        ("10/", IndexError),
    ],
)
def test_a_malformed_rate_fails_loudly_rather_than_becoming_no_limit(rate, failure):
    """The rates are operator settings, so a typo is reachable. It has to raise:
    a parser that fell back to a default would answer a mistyped `THROTTLE_LOGIN`
    with a limit nobody chose, and one that returned `None` would take the limiter
    out of the request path in silence."""
    with pytest.raises(failure):
        parse_rate(rate)


def test_every_rate_this_deployment_carries_parses():
    """The other side: no configured scope may be one of the shapes above."""
    for scope, rate in settings.THROTTLE_RATES.items():
        count, period = parse_rate(rate)

        assert count > 0, scope
        assert period > 0, scope


def test_the_last_request_inside_the_window_is_served_and_the_next_is_not(
    http, active_user, device, bearer, settings
):
    """The boundary itself. `count > rate` is what refuses, so the request that
    makes the count equal to the limit is the last one served — an off-by-one here
    is a limit of two where the operator configured three."""
    limit = 3
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": f"{limit}/min"}
    headers = bearer(active_user, device)

    served = [http.get(DIRECTORY_URL, headers=headers).status_code for _ in range(limit)]

    assert served == [200] * limit
    assert http.get(DIRECTORY_URL, headers=headers).status_code == 429


def test_a_throttled_answer_carries_the_envelope_and_echoes_no_input(
    http, active_user, device, bearer, settings
):
    """`429` is a refusal like any other on this surface: one envelope, a fixed
    detail, and nothing of the request that was refused."""
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": "1/min"}
    headers = bearer(active_user, device)
    http.get(DIRECTORY_URL, headers=headers)

    throttled = http.get(f"{DIRECTORY_URL}?q=a-search-term", headers=headers)

    assert throttled.status_code == 429
    assert throttled.json() == {"code": "throttled", "detail": "Request was throttled."}
    assert "a-search-term" not in throttled.text
    assert headers["Authorization"].removeprefix("Bearer ") not in throttled.text


def test_the_retry_after_never_exceeds_the_window_it_names(
    http, active_user, device, bearer, settings
):
    """The header is what a client waits on. Longer than the window and every
    client backs off past the point the counter reset; zero and they all return at
    once."""
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": "1/min"}
    headers = bearer(active_user, device)
    http.get(DIRECTORY_URL, headers=headers)

    throttled = http.get(DIRECTORY_URL, headers=headers)

    assert 0 < int(throttled.headers["retry-after"]) <= 60


def test_the_counter_lives_in_redis_under_a_key_that_names_the_window(
    http, active_user, device, bearer, settings
):
    """Volatile by rule (invariant 7), and outside the process so that raising
    `WEB_CONCURRENCY` cannot multiply the effective limit by the worker count."""
    import redis

    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": "5/min"}
    before = int(time.time()) // 60
    http.get(DIRECTORY_URL, headers=bearer(active_user, device))
    after = int(time.time()) // 60

    store = redis.Redis.from_url(settings.REDIS_URL)
    try:
        keys = [key.decode() for key in store.keys("ratelimit:accounts:*")]
        assert len(keys) == 1
        # One of the two windows the request could have landed in, so a run that
        # straddles a minute boundary is still a pass and never a flake.
        assert keys[0].rsplit(":", 1)[1] in {str(before), str(after)}
        assert 0 < store.ttl(keys[0]) <= 60
    finally:
        store.close()


def test_the_key_names_the_account_and_never_the_token(
    http, active_user, device, bearer, settings
):
    """An authenticated request counts per account. The key is written to a store
    another process on the host can read, so what it may carry is the account id
    and nothing that would let that process act as the account."""
    import redis

    headers = bearer(active_user, device)
    http.get(DIRECTORY_URL, headers=headers)

    store = redis.Redis.from_url(settings.REDIS_URL)
    try:
        key = [key.decode() for key in store.keys("ratelimit:accounts:*")][0]
    finally:
        store.close()

    assert f"user:{active_user.id}" in key
    assert headers["Authorization"].removeprefix("Bearer ") not in key
