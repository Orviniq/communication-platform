"""Device revocation reaches live sockets: the cascade's close event on the
device's bus topic closes the socket 4003, and the revoked token can never
reconnect.

Three publishers reach the same bus in this file, which is the point of it: the
test process itself, a FastAPI route, and the synchronous Django admin.
"""

import pytest

from api.orm import run_unit
from realtime import bus

from .conftest import (
    bearer,
    connect_ok,
    expect_close,
    expect_refused,
    http_request,
    mint_session,
    probe,
)

pytestmark = pytest.mark.django_db(transaction=True)


async def test_connection_close_event_closes_the_socket_4003(active_user, device):
    comm = await connect_ok(bearer(await mint_session(active_user, device)))

    await bus.publish(bus.device_topic(device.id), {"type": bus.CLOSE})

    await expect_close(comm, 4003)


async def test_rest_revocation_closes_the_live_socket_and_bars_reconnect(
    active_user, device
):
    """End to end: a sibling device calls DELETE /me/devices/{id}; the doomed
    device's socket drops 4003 and its outstanding token is dead for good."""
    from devices.models import Device

    doomed = await run_unit(
        Device.objects.create,
        user=active_user,
        ik_pub=b"ik",
        spk_id=2,
        spk_pub=b"spk",
        spk_sig=b"sig",
        registration_id=3003,
    )
    doomed_access = await mint_session(active_user, doomed)
    comm = await connect_ok(bearer(doomed_access))

    revoker = await mint_session(active_user, device)
    resp = await http_request("DELETE", f"/api/v1/me/devices/{doomed.id}", revoker)
    assert resp.status_code == 204

    await expect_close(comm, 4003)

    await expect_refused(bearer(doomed_access))


async def test_admin_deactivation_closes_the_users_live_sockets(active_user, device):
    """REST re-checks is_active per request; the socket, authenticated at connect
    time, must be told, otherwise a deactivated account keeps its volatile relay
    until the connection happens to drop."""
    from django.contrib import admin as django_admin
    from django.test import RequestFactory

    from accounts.admin import AccountAdmin
    from accounts.models import User

    comm = await connect_ok(bearer(await mint_session(active_user, device)))

    def deactivate_via_admin_action():
        # A real request with a real operator on it: the action writes an audit row
        # naming the actor, and the socket close it registers runs on commit.
        request = RequestFactory().post("/")
        request.user = User.objects.create_superuser(
            username="operator", password="a-long-enough-pw"
        )
        request._messages = _SwallowMessages()
        AccountAdmin(User, django_admin.site).deactivate_accounts(
            request, User.objects.filter(id=active_user.id)
        )

    await run_unit(deactivate_via_admin_action)

    await expect_close(comm, 4003)


class _SwallowMessages:
    """`django.contrib.messages` needs middleware this bare request never ran."""

    def add(self, level, message, extra_tags=""):
        pass


async def test_the_logout_route_closes_every_socket_of_the_device(active_user, device):
    """Signing out on the phone has to take the phone's socket with it. The route
    bumps `token_generation` and publishes the close, and both sockets the device
    holds are on one topic, so both hear it."""
    access = await mint_session(active_user, device)
    first = await connect_ok(bearer(access))
    second = await connect_ok(bearer(access))

    resp = await http_request("POST", "/api/v1/auth/logout", access)
    assert resp.status_code == 204

    await expect_close(first, 4003)
    await expect_close(second, 4003)

    await expect_refused(bearer(access))


async def test_a_close_event_for_another_device_leaves_this_socket_alone(
    active_user, device, peer, peer_device
):
    """The close rides the revoked device's own topic, so it reaches that device's
    sockets and nothing else. A close that fanned out wider would sign out every
    client of the account each time one of them lost a device."""
    comm = await connect_ok(bearer(await mint_session(active_user, device)))

    await bus.publish(bus.device_topic(peer_device.id), {"type": bus.CLOSE})

    await probe(comm, device.id)
    await comm.disconnect()
