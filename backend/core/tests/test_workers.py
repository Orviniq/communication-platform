"""The state each test process holds alone under pytest-xdist.

`core/tests/workers.py` carries the scheme. These hold the arithmetic, and hold
that the process running them is wired to it: a worker whose Redis index or test
database were shared would pass every test that reads them only by luck.
"""

import os
from urllib.parse import urlsplit

import pytest
from django.conf import settings
from django.db import connection

from core.tests.workers import redis_url_for, worker_number

WORKER = os.environ.get("PYTEST_XDIST_WORKER")


def test_a_serial_run_keeps_the_configured_url():
    url = "redis://:secret@127.0.0.1:6379/1"

    assert redis_url_for(url, None) == url


@pytest.mark.parametrize(
    ("url", "worker", "expected"),
    [
        ("redis://127.0.0.1:6379/0", "gw0", "redis://127.0.0.1:6379/0"),
        ("redis://127.0.0.1:6379/0", "gw3", "redis://127.0.0.1:6379/3"),
        # Up from the configured index, never down to a serving instance's /0.
        ("redis://:secret@127.0.0.1:6379/1", "gw2", "redis://:secret@127.0.0.1:6379/3"),
        # No path is Redis's own default index, 0.
        ("redis://127.0.0.1:6379", "gw5", "redis://127.0.0.1:6379/5"),
    ],
)
def test_a_worker_moves_up_by_its_number_and_keeps_everything_else(url, worker, expected):
    assert redis_url_for(url, worker) == expected


def test_two_workers_never_share_an_index():
    url = "redis://127.0.0.1:6379/0"
    indexes = {redis_url_for(url, f"gw{number}") for number in range(16)}

    assert len(indexes) == 16


@pytest.mark.django_db
def test_this_process_holds_its_own_redis_index_and_its_own_test_database():
    """The wiring, not the arithmetic: the root `conftest.py` really moved this
    process's `REDIS_URL`, and pytest-django really gave it a database of its own.
    In a serial run neither moved, and the names say so."""
    index = int(urlsplit(settings.REDIS_URL).path.lstrip("/") or 0)
    name = connection.settings_dict["NAME"]
    configured = urlsplit(os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0"))

    if WORKER is None:
        assert index == int(configured.path.lstrip("/") or 0)
        assert "_gw" not in name
    else:
        assert index == int(configured.path.lstrip("/") or 0) + worker_number(WORKER)
        assert name.endswith(f"_{WORKER}")
