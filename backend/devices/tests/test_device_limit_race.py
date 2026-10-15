"""The device cap holds under concurrent registration.

`transaction=True` for the same reason as the claim race: the guard is a row lock
held to commit, which a wrapping test transaction would hide.
"""

import threading

import pytest
from django.db import connections, transaction

from core.tests.workers import many_connections
from devices.models import Device

from .conftest import (
    DEVICES_URL,
    connect_then_wait,
    make_device,
    publish_identity,
    register_payload,
)

pytestmark = [pytest.mark.django_db(transaction=True), many_connections]

CONCURRENT_REGISTRATIONS = 4
CAP = 10  # settings.MAX_DEVICES_PER_USER


@pytest.fixture
def collector(active_user):
    """An account with one free device slot and a published identity, which
    registration past the first device requires."""
    publish_identity(active_user)
    for i in range(CAP - 1):
        make_device(active_user, registration_id=300 + i)
    return active_user


def test_concurrent_registrations_cannot_exceed_the_cap(
    new_http, collector, register_bearer
):
    start = threading.Barrier(CONCURRENT_REGISTRATIONS)
    statuses = []
    lock = threading.Lock()

    def register():
        try:
            connect_then_wait(start)
            response = new_http().post(
                DEVICES_URL,
                json=register_payload(),
                headers=register_bearer(collector),
            )
            with lock:
                statuses.append(response.status_code)
        finally:
            connections.close_all()

    threads = [threading.Thread(target=register) for _ in range(CONCURRENT_REGISTRATIONS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    live = Device.objects.filter(user=collector, revoked_date__isnull=True).count()
    assert live <= CAP, f"cap breached: {live} live devices"
    assert statuses.count(201) == 1
    assert statuses.count(409) == CONCURRENT_REGISTRATIONS - 1


def test_locking_the_device_rows_would_not_have_held(collector):
    """Guards the guard. The obvious implementation, `select_for_update()` over
    the account's existing devices, does not stop a concurrent INSERT, and Django
    silently drops FOR UPDATE altogether when the queryset ends in `.count()`.
    Under this same load it lets the account past the cap, which is why the unit
    of work locks the user row instead."""
    start = threading.Barrier(CONCURRENT_REGISTRATIONS)

    def naive_register():
        try:
            connect_then_wait(start)
            with transaction.atomic():
                n = (
                    Device.objects.select_for_update()
                    .filter(user_id=collector.id, revoked_date__isnull=True)
                    .count()
                )
                if n >= CAP:
                    return
                make_device(collector, registration_id=999)
        finally:
            connections.close_all()

    threads = [
        threading.Thread(target=naive_register) for _ in range(CONCURRENT_REGISTRATIONS)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    live = Device.objects.filter(user=collector, revoked_date__isnull=True).count()
    assert live > CAP, (
        "the device-row lock held after all, so the user-row lock in the unit of "
        "work is not what is keeping the cap"
    )


@pytest.fixture
def two_slots_left(active_user):
    """The same account with two free slots rather than one: the cap is a number,
    not a boolean, so the interesting race is the one where some racers must win."""
    publish_identity(active_user)
    for i in range(CAP - 2):
        make_device(active_user, registration_id=400 + i)
    return active_user


def test_concurrent_registrations_fill_the_free_slots_exactly(
    new_http, two_slots_left, register_bearer
):
    """Three times as many racers as slots. The lock must let exactly the free
    slots through — neither over the cap, which is the breach, nor under it, which
    would be a lock that serialises devices out of existence."""
    racers = 6
    free = 2
    start = threading.Barrier(racers)
    statuses = []
    lock = threading.Lock()

    def register():
        try:
            connect_then_wait(start)
            response = new_http().post(
                DEVICES_URL,
                json=register_payload(),
                headers=register_bearer(two_slots_left),
            )
            with lock:
                statuses.append(response.status_code)
        finally:
            connections.close_all()

    threads = [threading.Thread(target=register) for _ in range(racers)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    live = Device.objects.filter(user=two_slots_left, revoked_date__isnull=True).count()
    assert live == CAP
    assert statuses.count(201) == free
    assert statuses.count(409) == racers - free


def test_a_concurrent_revocation_frees_the_slot_it_took(
    new_http, two_slots_left, register_bearer, bearer
):
    """Registration and revocation race over the same counter from opposite ends,
    on an account that is already full: the registration can only succeed if it
    reads the count after the revocation committed. Either order is legitimate, and
    both leave the account inside the cap with the device set its two answers
    describe."""
    for i in range(2):
        make_device(two_slots_left, registration_id=800 + i)
    collector = two_slots_left
    doomed = Device.objects.filter(user=collector).first()
    start = threading.Barrier(2)
    answers = {}

    def register():
        try:
            connect_then_wait(start)
            answers["register"] = (
                new_http()
                .post(
                    DEVICES_URL,
                    json=register_payload(),
                    headers=register_bearer(collector),
                )
                .status_code
            )
        finally:
            connections.close_all()

    def revoke():
        try:
            connect_then_wait(start)
            answers["revoke"] = (
                new_http()
                .delete(f"{DEVICES_URL}/{doomed.id}", headers=bearer(collector, doomed))
                .status_code
            )
        finally:
            connections.close_all()

    threads = [threading.Thread(target=register), threading.Thread(target=revoke)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    live = Device.objects.filter(user=collector, revoked_date__isnull=True).count()
    assert answers["revoke"] == 204
    assert answers["register"] in (201, 409)
    assert live == (CAP if answers["register"] == 201 else CAP - 1)
    assert live <= CAP
