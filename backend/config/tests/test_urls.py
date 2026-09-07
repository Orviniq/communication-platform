"""`config/urls.py`: the whole of what the Django application routes.

Every route of this API is FastAPI's. Django is behind it for one thing — the
admin panel at an operator-chosen path — and this file is where that path is
read, where `DEBUG` decides whether the panel's own CSS is served, and where a
second URL added to the project would land.

`core/tests/test_route_table.py` proves the composed topology from outside, by
driving the stack. This proves the URLconf itself, including the branch that
process never takes: the suite runs under `DEBUG=True`, so the production shape
of `urlpatterns` exists nowhere in a normal run.
"""

import re

import pytest
from django.conf import settings
from django.contrib.staticfiles.views import serve
from django.test import override_settings
from django.urls import Resolver404, resolve, reverse

from config.tests.test_settings import SETTINGS, load

URLS = SETTINGS.parent / "urls.py"
EXAMPLE = settings.BASE_DIR / ".env.example"
NGINX = settings.BASE_DIR / "ops" / "nginx" / "chat.nimashadloo.dev.conf"


def urlconf(monkeypatch, debug, **environment):
    """`config/urls.py` executed again, under a chosen `DEBUG` and environment.

    Executed rather than reloaded: `urlpatterns` is built once at import time from
    `DEBUG` and `ADMIN_PATH`, and the installed module has to keep the values the
    running process resolves against.
    """
    with override_settings(DEBUG=debug):
        return load(
            monkeypatch,
            module_path=URLS,
            name="config_urls_under_test",
            **environment,
        )


class TestTheAdminPath:
    def test_the_admin_is_the_whole_of_what_django_routes(self, monkeypatch):
        """One entry, and it is the admin. A second URL here is a Django view
        answering on the API's own origin, outside every requirement
        `core/tests/test_route_table.py` holds the FastAPI surface to."""
        module = urlconf(monkeypatch, debug=False)

        assert len(module.urlpatterns) == 1
        assert reverse("admin:index", urlconf=module) == "/admin/"

    def test_the_path_comes_from_the_environment(self, monkeypatch):
        """Operator-chosen: the stock admin behind a name nobody scans for. The
        whole panel moves with it, so the sign-in page has to move too."""
        module = urlconf(monkeypatch, debug=False, ADMIN_PATH="ops-7f31/")

        assert reverse("admin:index", urlconf=module) == "/ops-7f31/"
        assert reverse("admin:login", urlconf=module) == "/ops-7f31/login/"

    def test_the_nginx_site_needs_no_copy_of_the_admin_path(self, monkeypatch):
        """`ADMIN_PATH` was one setting in two places — here and an nginx
        `location` — and the nginx half could not name an operator's chosen path
        without writing that path into a public repository. Every value but the
        default therefore left the panel unreachable behind nginx's own 404. The
        site's most general location is a catch-all instead: it carries whatever
        this variable holds, and `api.app.django_paths` is what separates the
        admin prefix from the paths that get this API's `not_found` envelope."""
        module = urlconf(monkeypatch, debug=False, ADMIN_PATH="ops-7f31/")
        routed = re.findall(r"^\s*location (\S+) \{", NGINX.read_text(), re.M)

        assert reverse("admin:index", urlconf=module) == "/ops-7f31/"
        assert "/" in routed
        assert "/admin/" not in routed

    def test_the_example_environment_carries_the_trailing_slash(self):
        """The boundary an operator can cross by hand. `path()` concatenates, so
        `ADMIN_PATH=ops` puts the sign-in page at `/opslogin/` — outside the
        `/ops/` prefix `api.app.django_paths` admits and outside the nginx
        `location`, leaving a panel whose index loads and whose login is a 404."""
        declared = re.search(r"^ADMIN_PATH=(\S*)$", EXAMPLE.read_text(), re.M)

        assert declared is not None
        assert declared.group(1).endswith("/")

    def test_a_path_without_a_trailing_slash_puts_the_login_outside_the_prefix(
        self, monkeypatch
    ):
        """The same boundary, measured. This is why the line above is asserted:
        the failure is silent, and it is the panel's sign-in that disappears."""
        module = urlconf(monkeypatch, debug=False, ADMIN_PATH="ops")

        assert reverse("admin:login", urlconf=module) == "/opslogin/"
        assert not reverse("admin:login", urlconf=module).startswith("/ops/")


class TestWhatDebugAdds:
    def test_the_static_files_are_routed_in_development_only(self, monkeypatch):
        """uvicorn serves this process rather than `runserver`, so in development
        nothing else would serve the panel's own CSS and JavaScript. In production
        nginx serves `STATIC_ROOT` and the process routes none of it."""
        development = urlconf(monkeypatch, debug=True)
        production = urlconf(monkeypatch, debug=False)
        asset = f"{settings.STATIC_URL}admin/css/base.css"

        assert resolve(asset, urlconf=development).func is serve
        with pytest.raises(Resolver404):
            resolve(asset, urlconf=production)

    def test_the_admin_answers_at_the_same_path_either_way(self, monkeypatch):
        """`DEBUG` adds routes and moves none: the panel is at one address in both
        environments, which is what lets one nginx `location` serve it."""
        development = urlconf(monkeypatch, debug=True)
        production = urlconf(monkeypatch, debug=False)

        assert reverse("admin:index", urlconf=development) == reverse(
            "admin:index", urlconf=production
        )


class TestWhatDjangoNeverRoutes:
    @pytest.mark.parametrize(
        "path", ["/api/v1/health", "/api/v1/envelopes", "/ws", "/", "/openapi.json"]
    )
    def test_no_api_path_resolves_through_the_django_urlconf(self, monkeypatch, path):
        """The rule ADR-0003 rests on. If one of these resolved here, a request
        that reached the Django application by any route would be answered by
        Django — with Django's error pages, Django's middleware and none of the
        requirements the FastAPI table declares."""
        module = urlconf(monkeypatch, debug=True)

        with pytest.raises(Resolver404):
            resolve(path, urlconf=module)
