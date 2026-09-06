"""`GET /api/v1/config`: the limits a client cannot derive.

The route exists so the client can state a number it would otherwise have to
guess — the retention window most of all. Its one real failure mode is drift: a
value that stops matching the limit the route behind it enforces is worse than no
value at all, because a client that trusted it would refuse a payload the server
accepts or offer one it refuses. Every assertion below is therefore an equality
against the setting or the constant the enforcing code reads, never against a
literal.
"""

import pytest
from django.conf import settings

from core.buckets import ATTACHMENT_BUCKETS, ENVELOPE_BUCKETS, SIGNAL_BUCKETS
from core.schemas import ConfigOut
from devices.schemas import MAX_CLAIM_DEVICE_IDS
from messaging.schemas import MAX_ACK_IDS, MAX_DRAIN_LIMIT, MAX_SEND_BATCH

pytestmark = pytest.mark.django_db(transaction=True)

CONFIG_URL = "/api/v1/config"

# Field to the value the code that enforces it reads. A field that stops matching
# its source is a client told a limit the server does not keep.
SOURCES = {
    "envelope_ttl_days": lambda: settings.ENVELOPE_TTL_DAYS,
    "attachment_ttl_days": lambda: settings.ATTACH_TTL_DAYS,
    "attachment_daily_bytes": lambda: settings.ATTACH_DAILY_BYTES,
    "mailbox_max_bytes": lambda: settings.MAILBOX_MAX_BYTES,
    "max_devices_per_user": lambda: settings.MAX_DEVICES_PER_USER,
    "max_devicelog_records": lambda: settings.MAX_DEVICELOG_RECORDS,
    "session_token_days": lambda: settings.SESSION_TOKEN_DAYS,
    "send_batch_max": lambda: MAX_SEND_BATCH,
    "ack_max": lambda: MAX_ACK_IDS,
    "drain_page_max": lambda: MAX_DRAIN_LIMIT,
    "claim_max": lambda: MAX_CLAIM_DEVICE_IDS,
    "envelope_buckets": lambda: ENVELOPE_BUCKETS,
    "attachment_buckets": lambda: ATTACHMENT_BUCKETS,
    "signal_buckets": lambda: SIGNAL_BUCKETS,
    "voice_configured": lambda: bool(settings.TURN_URLS),
}


@pytest.mark.parametrize("field", sorted(SOURCES))
def test_every_field_is_the_value_its_own_route_enforces(
    http, active_user, device, bearer, field
):
    body = http.get(CONFIG_URL, headers=bearer(active_user, device)).json()

    assert body[field] == SOURCES[field](), field


def test_the_document_publishes_exactly_these_fields():
    """A field added to the model and to no client contract is a value nobody can
    use; one removed is a client reading `None` off a key that vanished."""
    assert set(ConfigOut.model_fields) == set(SOURCES)


def test_the_answer_carries_nothing_beyond_the_declared_fields(
    http, active_user, device, bearer
):
    body = http.get(CONFIG_URL, headers=bearer(active_user, device)).json()

    assert set(body) == set(SOURCES)


def test_a_changed_setting_changes_the_answer(
    http, active_user, device, bearer, settings
):
    """Read at request time, never frozen at import. An operator who shortens the
    retention window and restarts must not leave clients quoting the old one — and
    a value captured at import would survive exactly that restart."""
    settings.ENVELOPE_TTL_DAYS = 3
    settings.MAX_DEVICES_PER_USER = 4

    body = http.get(CONFIG_URL, headers=bearer(active_user, device)).json()

    assert body["envelope_ttl_days"] == 3
    assert body["max_devices_per_user"] == 4


def test_voice_reports_off_when_the_deployment_names_no_relay(
    http, active_user, device, bearer, settings
):
    """`POST /me/relay` answers `503 voice_unconfigured` with no `TURN_URLS`, and
    this is how a client learns that before it offers a call button."""
    settings.TURN_URLS = []
    headers = bearer(active_user, device)

    assert http.get(CONFIG_URL, headers=headers).json()["voice_configured"] is False
    assert http.post("/api/v1/me/relay", headers=headers).status_code == 503


def test_voice_reports_on_when_a_relay_is_configured(
    http, active_user, device, bearer, settings
):
    settings.TURN_URLS = ["turn:198.51.100.10:3478"]
    settings.TURN_STATIC_AUTH_SECRET = "config-route-test-relay-secret-32"
    headers = bearer(active_user, device)

    assert http.get(CONFIG_URL, headers=headers).json()["voice_configured"] is True
    assert http.post("/api/v1/me/relay", headers=headers).status_code == 200


def test_the_route_needs_a_session_token(http):
    """Nothing here is a secret, and nothing here is anyone's business before they
    hold a session: an unauthenticated caller learns none of the deployment's
    shape."""
    response = http.get(CONFIG_URL)

    assert response.status_code == 401
    assert response.json()["code"] == "unauthenticated"


def test_the_route_takes_no_database_connection(
    http, active_user, device, bearer, django_assert_num_queries
):
    """One query, and it is the authentication dependency's. The values come from
    the settings, so nothing here reads a row."""
    headers = bearer(active_user, device)

    with django_assert_num_queries(1):
        assert http.get(CONFIG_URL, headers=headers).status_code == 200
