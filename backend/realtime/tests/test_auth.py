"""The socket authenticates with REST's strength: a session token, a live device,
a matching token_generation, an active user. The token is on the handshake and
nowhere else, so a socket that fails is never accepted and joins no group."""

import uuid
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from django.conf import settings
from django.forms.models import model_to_dict
from django.utils import timezone as django_timezone

from api.auth import issue_register_scope
from api.orm import run_unit
from realtime.bus import device_topic, get_subscriber

from .conftest import bearer, connect_ok, expect_refused, mint_session, probe

pytestmark = pytest.mark.django_db(transaction=True)


def forged_typ(user, device, typ):
    """A validly signed token carrying a live device's binding under `typ`."""
    issued = datetime.now(timezone.utc)
    return jwt.encode(
        {
            "user_id": str(user.id),
            "device_id": str(device.id),
            "tgen": device.token_generation,
            "typ": typ,
            "jti": uuid.uuid4().hex,
            "iat": issued,
            "exp": issued + timedelta(minutes=10),
        },
        settings.JWT_SIGNING_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )


def no_topic_is_held():
    """The bus subscription registry of this worker is empty.

    The Redis-side twin of the old in-memory `channel_layer.groups == {}`: there is
    no inspectable registry on Redis, so what a refused handshake must leave behind
    is checked where the gateway actually keeps it. A socket that never bound
    subscribed to no device topic, and a socket that bound and then failed
    unsubscribed on its way out.
    """
    return get_subscriber()._sinks == {}


async def test_header_auth_path_connects(active_user, device):
    comm = await connect_ok(bearer(await mint_session(active_user, device)))
    await probe(comm, device.id)
    await comm.disconnect()


async def test_a_connect_records_nothing_about_the_device(active_user, device):
    """ADR-0024: the bind stopped writing the day the device was last seen, and no
    other column stands in for it — `devices.0003_drop_the_retired_columns` then
    took the column. A socket that came up must leave the row exactly as it found
    it, or the seizure yield gains an activity signal again."""
    before = await run_unit(type(device).objects.get, id=device.id)
    comm = await connect_ok(bearer(await mint_session(active_user, device)))
    await probe(comm, device.id)

    after = await run_unit(type(device).objects.get, id=device.id)
    assert model_to_dict(after) == model_to_dict(before)
    assert "last_active_date" not in model_to_dict(after)
    await comm.disconnect()


async def test_a_handshake_with_no_authorization_header_is_refused(db):
    """There is one handshake path and the header is it. A socket accepted without
    a token would be an unauthenticated connection this gateway has no state for."""
    await expect_refused([])
    assert no_topic_is_held()


async def test_garbage_token_is_refused(db):
    await expect_refused(bearer("not-a-jwt"))


async def test_a_token_of_a_type_this_issuer_never_mints_is_refused(active_user, device):
    """`typ` carries the power of a token, so a validly signed one naming a type
    outside the two this issuer mints is refused here exactly as REST refuses
    it."""
    forged = await run_unit(forged_typ, active_user, device, "access")

    await expect_refused(bearer(forged))


async def test_register_scope_token_is_refused_and_joins_no_group(active_user):
    """A register token buys exactly one REST endpoint and no socket."""
    token, _expires_in = await run_unit(issue_register_scope, active_user)

    await expect_refused(bearer(token))

    assert no_topic_is_held()


async def test_register_scope_with_device_claims_is_still_refused(active_user, device):
    """The type is enforced in its own right, not via the missing device claim:
    even a register token carrying a live device's id and tgen opens no
    socket."""
    forged = await run_unit(forged_typ, active_user, device, "register")

    await expect_refused(bearer(forged))


async def test_revoked_devices_token_is_refused(active_user, device):
    access = await mint_session(active_user, device)
    await run_unit(
        type(device).objects.filter(id=device.id).update,
        revoked_date=django_timezone.now().date(),
    )

    await expect_refused(bearer(access))


async def test_stale_token_generation_is_refused(active_user, device):
    """Bumping token_generation (the revoke cascade) invalidates every outstanding
    token immediately, including on the socket."""
    access = await mint_session(active_user, device)
    await run_unit(type(device).objects.filter(id=device.id).update, token_generation=2)

    await expect_refused(bearer(access))


async def test_inactive_users_token_is_refused(active_user, device):
    access = await mint_session(active_user, device)
    await run_unit(
        type(active_user).objects.filter(id=active_user.id).update, is_active=False
    )

    await expect_refused(bearer(access))


async def test_a_header_that_is_not_a_bearer_token_is_refused(db):
    """`Authorization` is parsed, not trusted: a header this gateway cannot read is
    no token at all, and no token refuses the handshake."""
    for header in (b"Basic Zm9vOmJhcg==", b"Bearer", b"Bearer a b", b"   "):
        await expect_refused([(b"authorization", header)])

    assert no_topic_is_held()


async def test_an_auth_frame_on_a_bound_socket_is_ignored(active_user, device):
    """`auth` is not a frame type this gateway knows, so it is dropped like any
    unknown frame. Handling one would let a socket change the device it delivers
    for, mid-session, without the topic it holds changing."""
    comm = await connect_ok(bearer(await mint_session(active_user, device)))

    await comm.send_json_to(
        {"type": "auth", "access": await mint_session(active_user, device)}
    )

    await probe(comm, device.id)
    await comm.disconnect()


async def test_a_bind_takes_the_device_topic_and_a_disconnect_gives_it_back(
    active_user, device
):
    """The subscription is the socket's half of delivery, and it is per topic
    rather than a pattern: a topic left held after the socket is gone keeps this
    worker receiving a departed device's envelopes for the life of the process."""
    comm = await connect_ok(bearer(await mint_session(active_user, device)))
    await probe(comm, device.id)

    assert get_subscriber()._sinks.keys() == {device_topic(device.id)}

    await comm.disconnect()
    assert no_topic_is_held()
