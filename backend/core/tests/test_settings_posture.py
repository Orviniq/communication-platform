import re

from django.conf import settings
from django.core.checks import Tags, run_checks
from django.test import SimpleTestCase, override_settings

from config.settings import prod
from core.checks import no_foreign_or_telemetry

# The band's ceiling on concurrent WebSocket connections: fewer than 50 accounts
# at `MAX_DEVICES_PER_USER` devices each, recorded as A1 in
# `docs/architecture/DESIGN-RECORD.md`. It lives there rather than in a setting,
# because nothing in this process enforces it.
SOCKET_CEILING = 500

# The one site file `ops/nginx/` carries; the per-location assertions below read
# it by name rather than by glob, so a rename fails here instead of passing over
# an empty match.
SITE = "chat.nimashadloo.dev.conf"

# The two modules the relay's shared-secret posture is read out of, named here so a
# failure quotes the path rather than the file.
BASE = "config/settings/base.py"
MINTING = "realtime/relay.py"


def deploy_check_ids():
    """The ids `manage.py check --deploy` would report under the current settings,
    read through the registry so a check that is written but never registered
    for deployment fails here."""
    return {
        message.id
        for message in run_checks(tags=[Tags.security], include_deployment_checks=True)
    }


BANNED_TELEMETRY = {"sentry_sdk", "ddtrace", "newrelic", "elasticapm"}

# The modules that read the environment. Every other module reads `settings`.
CONFIGURED_BY = ("config/settings/base.py", "config/settings/dev.py", "config/urls.py")
READS_ENV = re.compile(r"\benv(?:_bool|_int|_list)?\(\s*[\"']([A-Z][A-Z0-9_]*)[\"']")
DECLARES = re.compile(r"^([A-Z][A-Z0-9_]*)=", re.M)
DOCUMENTED = re.compile(r"^\| `([A-Z][A-Z0-9_]*)` \|", re.M)

# Variables the example carries that no Python module reads, each with the process
# that does read it. Nothing else may be in the file.
READ_OUTSIDE_PYTHON = {
    "DJANGO_SETTINGS_MODULE": "django, to find the settings module at all",
    "WEB_CONCURRENCY": "the systemd unit, as uvicorn's --workers argument",
    # `TURN_STATIC_AUTH_SECRET` is not here: from this release Python reads it too,
    # to sign a relay credential, so it is one value in two places rather than a
    # value the example carries for another process alone.
    "TURN_REALM": "ops/coturn/turnserver.conf",
}


def nginx_locations(conf):
    """Every `location` block of the TLS server block, as {spec: body}.

    Written here rather than pulled from a parser package: the properties below
    are per-location, and `str.count` over the whole file cannot tell a cap in
    one location from a cap in another.
    """
    tls = next(
        body
        for match in re.finditer(r"^server\s*\{", conf, re.M)
        for body in [_block(conf, match.start())]
        if "listen 443" in body
    )
    blocks = {}
    for match in re.finditer(r"^\s*location\s+(?P<spec>[^{#]+?)\s*\{", tls, re.M):
        blocks[match.group("spec")] = _block(tls, match.start())
    return blocks


def _block(text, at):
    """The body of the brace-delimited block whose opening brace follows `at`."""
    start = text.index("{", at)
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1 : index]
    raise AssertionError("unbalanced braces")


def nginx_size(value):
    """An nginx size — a number with an optional `k` or `m` suffix — as bytes."""
    scale = {"k": 1024, "m": 1024**2}
    if value[-1].lower() in scale:
        return int(value[:-1]) * scale[value[-1].lower()]
    return int(value)


def nginx_seconds(value):
    """An nginx time — a number with an optional `s` suffix — as seconds."""
    return int(value.removesuffix("s"))


class BasePostureTests(SimpleTestCase):
    """Posture that must hold in every environment."""

    def test_argon2id_is_the_first_password_hasher(self):
        self.assertTrue(settings.PASSWORD_HASHERS[0].endswith("Argon2PasswordHasher"))

    def test_no_email_is_ever_sent(self):
        self.assertFalse(settings.EMAIL_BACKEND.endswith("smtp.EmailBackend"))

    def test_no_telemetry_or_error_reporting_app_is_installed(self):
        installed = {app.split(".")[0] for app in settings.INSTALLED_APPS}
        self.assertEqual(BANNED_TELEMETRY & installed, set())

    def test_deployment_is_asgi_only(self):
        """There is no `ASGI_APPLICATION` to assert against: that setting is read
        by Channels, which is gone. uvicorn is told the application on its command
        line, and the unit test below is what pins it."""
        self.assertIsNone(settings.WSGI_APPLICATION)
        self.assertFalse(hasattr(settings, "ASGI_APPLICATION"))
        self.assertFalse(hasattr(settings, "CHANNEL_LAYERS"))

    def test_no_token_application_is_installed(self):
        """A token table is a per-device login record at rest. Revocation lives in
        two counters on the device row, so nothing keeps one."""
        self.assertFalse(
            any("simplejwt" in app for app in settings.INSTALLED_APPS),
            settings.INSTALLED_APPS,
        )
        self.assertFalse(hasattr(settings, "SIMPLE_JWT"))

    def test_tokens_are_signed_with_a_pinned_symmetric_algorithm(self):
        self.assertEqual(settings.JWT_ALGORITHM, "HS256")
        self.assertTrue(settings.JWT_SIGNING_KEY)
        self.assertNotEqual(settings.JWT_SIGNING_KEY, settings.SECRET_KEY)

    def test_every_served_route_declares_a_requirement_of_its_own(self):
        """FastAPI has no project-wide permission default, so closed-by-default is
        a per-route declaration and `core/tests/test_route_table.py` is the gate
        that proves each one carries it. This asserts the gate covers the whole
        table rather than a subset of it."""
        from core.tests import test_route_table

        served = set(test_route_table.served())

        self.assertEqual(served, set(test_route_table.EXPECTED))
        self.assertTrue(served)
        for route, (requirement, _scope) in test_route_table.EXPECTED.items():
            self.assertIn(requirement, test_route_table.REQUIREMENTS, route)

    def test_the_installed_applications_are_exactly_the_declared_set(self):
        """One HTTP surface, one set of defaults. A second API framework here is a
        block of defaults that no code reads and every reader trusts, and the list
        is short enough to pin rather than to spot-check.

        The order is pinned with the list because one pair of it is load-bearing:
        `unfold` before `django.contrib.admin`. Reversed, the admin's `ready()` runs
        autodiscover first and unfold then replaces the site those registrations
        landed on, so the panel lists nothing and `manage.py check` still passes.
        """
        self.assertEqual(
            settings.INSTALLED_APPS,
            [
                "unfold",
                "django.contrib.admin",
                "django.contrib.auth",
                "django.contrib.contenttypes",
                "django.contrib.sessions",
                "django.contrib.messages",
                "django.contrib.staticfiles",
                "core",
                "accounts",
                "devices",
                "vault",
                "messaging",
                "attachments",
                "voicerooms",
                "realtime",
            ],
        )
        self.assertLess(
            settings.INSTALLED_APPS.index("unfold"),
            settings.INSTALLED_APPS.index("django.contrib.admin"),
        )
        self.assertFalse(hasattr(settings, "REST_FRAMEWORK"))

    def test_the_orm_holds_no_persistent_connection_and_takes_the_pool(self):
        """Nothing fires Django's request signals in this process, so a persistent
        connection would never be reaped or health-checked. The pool is what
        removes the setup cost that CONN_MAX_AGE=0 would otherwise pay."""
        default = settings.DATABASES["default"]

        self.assertEqual(default["CONN_MAX_AGE"], 0)
        self.assertIn("pool", default["OPTIONS"])
        self.assertGreaterEqual(default["OPTIONS"]["pool"]["max_size"], 1)

    def test_datastores_are_localhost_only(self):
        self.assertIn(settings.DATABASES["default"]["HOST"], {"127.0.0.1", "localhost"})
        # One Redis URL: the rate counters, the lockout and the gateway's fan-out
        # bus all read `REDIS_URL`.
        self.assertRegex(
            settings.REDIS_URL, r"^redis://(:[^@]+@)?(127\.0\.0\.1|localhost):"
        )

    def test_scrub_filter_is_attached_and_access_logging_is_off(self):
        logging = settings.LOGGING

        self.assertIn("scrub", logging["handlers"]["console"]["filters"])
        self.assertEqual(
            logging["filters"]["scrub"]["()"], "core.logging_filters.ScrubFilter"
        )
        for logger in ("django.request", "django.server"):
            self.assertEqual(logging["loggers"][logger]["level"], "ERROR")

    def test_every_library_that_can_log_an_identifier_is_claimed(self):
        """Each of these writes a device id, a request path or a ciphertext blob at
        its own default level, and each is claimed here so it goes through the
        console handler — and therefore through ScrubFilter — instead of through a
        stream of its own. `push_response` is the one that matters most: redis-py
        installs a `StreamHandler` to stdout for it the first time a `PubSub` is
        built, unless the logger already exists."""
        loggers = settings.LOGGING["loggers"]

        for name in (
            "uvicorn",
            "uvicorn.error",
            "uvicorn.access",
            "websockets",
            "push_response",
        ):
            self.assertEqual(loggers[name]["handlers"], ["console"], name)
            self.assertEqual(loggers[name]["level"], "WARNING", name)
            self.assertFalse(loggers[name]["propagate"], name)

    def test_the_asgi_unit_runs_uvicorn_with_the_hardened_flags(self):
        """The flags of ADR-0014, read from the unit that actually runs.

        `--no-access-log` is the load-bearing one: uvicorn writes a request line
        for every request, and a request path in the journal is the conversation
        graph the schema refuses to hold. The forwarded-header pin is what makes
        the anonymous rate limit mean anything, and the pinned loop, HTTP and
        WebSocket implementations are what make the process fail loudly on a
        missing wheel rather than fall back to a pure-Python one.
        """
        unit = (settings.BASE_DIR / "ops" / "systemd" / "chat.service").read_text()

        self.assertIn("/uvicorn", unit)
        for flag in (
            "--no-access-log",
            "--proxy-headers",
            "--forwarded-allow-ips 127.0.0.1",
            "--loop uvloop",
            "--http httptools",
            "--ws websockets-sansio",
            "--workers ${WEB_CONCURRENCY}",
            "--limit-concurrency",
            "--ws-ping-interval",
            "--ws-ping-timeout",
            "--timeout-graceful-shutdown",
        ):
            self.assertIn(flag, unit)

    def test_the_socket_keepalive_is_the_one_adr_0024_set(self):
        """uvicorn pings every live WebSocket, and its own defaults are 20 s and
        20 s. The client holds the socket in the background under a foreground
        service, so a ping every twenty seconds wakes a mobile radio every twenty
        seconds for the life of the session — the socket is this product's only
        push path, so nothing else pays that cost down.

        The two numbers together are what a dead peer costs: the interval before
        the ping goes out, plus the timeout before the pong is given up on, so at
        most 300 s of a socket held for a peer that is gone. The interval is
        pinned below the edge's own read timeout as well, because an idle socket
        must be closed by the keepalive rather than cut by nginx.
        """
        unit = (settings.BASE_DIR / "ops" / "systemd" / "chat.service").read_text()
        conf = (settings.BASE_DIR / "ops" / "nginx" / SITE).read_text()

        interval = int(re.search(r"--ws-ping-interval (\d+)", unit).group(1))
        timeout = int(re.search(r"--ws-ping-timeout (\d+)", unit).group(1))
        ws_block = conf.split("location /ws")[1]
        read_timeout = int(re.search(r"proxy_read_timeout (\d+)s", ws_block).group(1))

        self.assertEqual((interval, timeout), (240, 60))
        self.assertGreater(read_timeout, interval)

    def test_the_edge_writes_no_access_log_and_no_request_line(self):
        """The other half of `--no-access-log`, one layer out.

        nginx sees every request the process sees, one hop earlier, and it has no
        `access_log off` of its own to inherit: the compiled-in default is
        `access_log logs/access.log combined`, and every packaged `nginx.conf`
        sets one in the `http` block that a `server` block inherits unless it
        overrides it. The `combined` format writes `$remote_addr` and `$request`,
        which is the client address and the whole URI — the peer user UUID of the
        key-claim and device routes, the operator-chosen admin path, and the
        bearer capability that downloads an attachment.

        `error_log` carries the same line: an upstream failure is logged at
        `error` level with `client:` and `request:` fields, so a restarting worker
        would write the paths the access log no longer does. `crit` is the level
        above it.
        """
        for conf in (settings.BASE_DIR / "ops" / "nginx").glob("*.conf"):
            body = conf.read_text()
            # Per server block, not per file: a directive in one block does not
            # reach the other, and the plaintext block sees a URI too — whatever
            # path a request named before the redirect sends it on.
            blocks = len(re.findall(r"^server \{", body, re.M))

            self.assertEqual(body.count("access_log off;"), blocks, conf.name)
            self.assertEqual(
                len(re.findall(r"error_log\s+\S+\s+crit;", body)), blocks, conf.name
            )

    def test_every_location_of_the_edge_caps_the_body_it_admits(self):
        """A cap on the server block alone is the cap of whichever location admits
        the most, applied to every location that admits less. The upload route
        needs 70 MiB, so one server-level number would let a 70 MiB body reach the
        admin path — which the application then refuses with `413` after nginx has
        already carried it to loopback. Each location states its own instead, and
        the server-level value is the deny-by-default for a path that matches
        none."""
        conf = (settings.BASE_DIR / "ops" / "nginx" / SITE).read_text()
        locations = nginx_locations(conf)

        self.assertTrue(locations)
        for spec, body in locations.items():
            self.assertIn("client_max_body_size", body, spec)

    def test_the_edge_admits_exactly_what_each_upstream_admits(self):
        """The two caps are one setting in two places. nginx above the application
        would 413 a body the routes accept; nginx below it would carry a body the
        routes refuse. `/api/` takes the largest route class, and the admin claims
        no route at all, so `api.app.route_limits` gives it the fallback class."""
        locations = nginx_locations(
            (settings.BASE_DIR / "ops" / "nginx" / SITE).read_text()
        )
        caps = {
            spec: nginx_size(re.search(r"client_max_body_size\s+(\S+);", body).group(1))
            for spec, body in locations.items()
        }

        self.assertEqual(caps["/api/"], settings.BODY_CAP_BATCH_BYTES)
        self.assertEqual(caps["/admin/"], settings.BODY_CAP_JSON_BYTES)

    def test_the_edge_waits_longer_than_the_deadline_below_it(self):
        """Timeouts nest innermost first. The application answers its own
        `503 unavailable` at its deadline; nginx must still be waiting then, or a
        slow request becomes a `504` with no answer from the application and the
        deadline's envelope never reaches the client. nginx's own default is 60 s,
        which is below the 120 s the upload and batch routes take."""
        locations = nginx_locations(
            (settings.BASE_DIR / "ops" / "nginx" / SITE).read_text()
        )
        waits = {
            spec: nginx_seconds(re.search(r"proxy_read_timeout\s+(\S+);", body).group(1))
            for spec, body in locations.items()
            if "proxy_pass" in body
        }

        self.assertGreater(waits["/api/"], settings.UPLOAD_DEADLINE_SECONDS)
        self.assertGreater(waits["/admin/"], settings.REQUEST_DEADLINE_SECONDS)

    def test_the_body_of_a_slow_upload_is_absorbed_by_the_edge(self):
        """The two directives that decide where a slow client's upload is paid for.

        With `proxy_request_buffering on` nginx reads the whole body before it
        opens the loopback connection, so `UPLOAD_DEADLINE_SECONDS` covers the
        loopback hop alone. Turned off, the same body is read inside the
        application's own deadline and a slow link on a 64 MiB upload becomes a
        `503` the client cannot act on. It is nginx's default, which is exactly why
        it is stated: nothing else in this tree would report it changing.

        `client_body_timeout` is the other half. Once nginx owns the read, the
        bound on a client that stalls mid-body lives here and nowhere else, and
        the default 60 s is twice what a live link ever needs between two reads.
        """
        api = nginx_locations((settings.BASE_DIR / "ops" / "nginx" / SITE).read_text())[
            "/api/"
        ]

        self.assertIn("proxy_request_buffering on;", api)
        self.assertLess(
            nginx_seconds(re.search(r"client_body_timeout\s+(\S+);", api).group(1)), 60
        )

    def test_one_layer_owns_the_transport_security_header(self):
        """`add_header` appends; it never replaces. Django's SecurityMiddleware
        emits HSTS on the admin path it serves, and SECURE_HSTS_SECONDS has to stay
        set there because `check --deploy` requires it — so without the hide the
        admin response carries the header twice. nginx is the layer that keeps it,
        because it is the only one that sees every response on this host: the
        proxied ones, the files it serves from disk, and its own 404 and 413.

        The mirror of that rule is the second assertion: a location that adds a
        header of its own drops every inherited one, so it repeats HSTS or it
        serves without it.
        """
        conf = (settings.BASE_DIR / "ops" / "nginx" / SITE).read_text()
        snippet = (
            settings.BASE_DIR / "ops" / "nginx" / "snippets" / "proxy-headers.conf"
        ).read_text()

        self.assertIn("proxy_hide_header Strict-Transport-Security;", snippet)
        self.assertTrue(prod.SECURE_HSTS_SECONDS)
        for spec, body in nginx_locations(conf).items():
            if "proxy_pass" in body:
                self.assertIn("snippets/proxy-headers.conf", body, spec)
            elif "add_header" in body:
                self.assertIn("Strict-Transport-Security", body, spec)

    def test_the_edge_includes_only_snippets_this_repository_ships(self):
        """An `include` that names a file nobody wrote is a site that does not
        load, and the snippet behind this one carries X-Forwarded-Proto — the
        header SECURE_PROXY_SSL_HEADER trusts. An operator inventing it is an
        operator choosing that trust boundary by hand."""
        conf = (settings.BASE_DIR / "ops" / "nginx" / SITE).read_text()

        for included in re.findall(r"include\s+(\S+);", conf):
            self.assertTrue(
                (settings.BASE_DIR / "ops" / "nginx" / included).is_file(), included
            )

    def test_the_three_windows_of_a_stop_nest(self):
        """A deploy is a stop, and three windows have to nest around it: the
        longest request the surface admits, the drain uvicorn takes, and the time
        systemd waits before SIGKILL. Measured on this application with the drain
        below the request: the request was cut and the client read
        `HTTP/1.1 500 Internal Server Error`, so a deploy that caught a slow upload
        reported itself as a fault of the API. With the drain above it the same
        probe completed and read its real status.

        systemd's own `DefaultTimeoutStopSec` is 90 s, so the outermost window is
        stated rather than inherited: an unset value would be below the drain and
        would kill the process in the middle of it.
        """
        unit = (settings.BASE_DIR / "ops" / "systemd" / "chat.service").read_text()
        drain = int(re.search(r"--timeout-graceful-shutdown (\d+)", unit).group(1))
        stop = int(re.search(r"TimeoutStopSec=(\d+)", unit).group(1))

        self.assertGreater(drain, settings.UPLOAD_DEADLINE_SECONDS)
        self.assertGreater(stop, drain)

    def test_the_maintenance_run_is_bounded_rather_than_left_to_a_default(self):
        """systemd will not start a second instance of the unit while one is
        active, so a sweep that never returns holds the timer's every later fire
        behind it. The distribution default would instead kill a large sweep at
        90 s and mark the unit failed. The bound is stated so it is neither."""
        unit = (
            settings.BASE_DIR / "ops" / "systemd" / "chat-maintenance.service"
        ).read_text()

        self.assertIsNotNone(re.search(r"^TimeoutStartSec=\S+$", unit, re.M))

    def test_the_concurrency_limit_leaves_room_for_http_beside_the_sockets(self):
        """uvicorn's `--limit-concurrency` counts *connections*, and a live
        WebSocket is one: both protocols share `server_state.connections`, and the
        HTTP path answers `503` from the length of that shared set. The WebSocket
        handshake never consults it — the upgrade returns before the check — so
        sockets take from the budget and never give it back.

        Measured with the limit at 6: six live sockets, and every HTTP request
        answers uvicorn's own plain-text `503 Service Unavailable`, not even this
        API's envelope. At the band's ceiling of `SOCKET_CEILING` concurrent
        sockets, a limit of 512 would leave twelve connections for every send, ack,
        drain and key claim the deployment makes.

        So the limit carries both: the socket ceiling, plus one keep-alive HTTP
        connection for each of those devices. 500 live sockets cost 47 MB of
        resident set (189.8 MB idle against 237.0 MB), and an idle HTTP connection
        is cheaper than a socket, so the memory stays inside A3's 700 MB ceiling.
        """
        unit = (settings.BASE_DIR / "ops" / "systemd" / "chat.service").read_text()
        limit = int(re.search(r"--limit-concurrency (\d+)", unit).group(1))

        self.assertGreaterEqual(limit, 2 * SOCKET_CEILING)

    def test_the_serving_unit_raises_its_file_descriptor_limit_to_match(self):
        """A connection is a file descriptor, and systemd's own default soft
        `LimitNOFILE` is 1024. Admitting more connections than the process has
        descriptors for moves the failure rather than removing it: the accept fails
        instead of the concurrency check, and it fails without a `503`.

        The budget is the connection limit, plus the sixteen the database pool
        holds, plus the Redis client and its subscription, plus the listening
        socket and stdio.
        """
        unit = (settings.BASE_DIR / "ops" / "systemd" / "chat.service").read_text()
        limit = int(re.search(r"--limit-concurrency (\d+)", unit).group(1))
        descriptors = re.search(r"LimitNOFILE=(\d+)", unit)

        self.assertIsNotNone(descriptors, "the unit sets no LimitNOFILE")
        self.assertGreater(int(descriptors.group(1)), limit)

    def test_the_units_write_only_what_they_must_and_drop_what_they_never_use(self):
        """`ReadWritePaths` is the whole of what a compromised process can change
        on a `ProtectSystem=strict` host. The serving process never writes the
        collected static tree — `collectstatic` is the operator's command and
        nginx serves the result — so a writable `static_root` was a way for a
        compromised process to replace the panel's own JavaScript. The rest are the
        directives a Python service never needs and a hardened unit drops."""
        units = settings.BASE_DIR / "ops" / "systemd"
        serving = (units / "chat.service").read_text()
        maintenance = (units / "chat-maintenance.service").read_text()

        self.assertIn("ReadWritePaths=/srv/chat/backend/media_root\n", serving)
        self.assertNotIn("static_root", serving)
        for unit in (serving, maintenance):
            for directive in (
                "RestrictRealtime=true",
                "RestrictSUIDSGID=true",
                "ProtectClock=true",
                "ProtectHostname=true",
                "SystemCallArchitectures=native",
            ):
                self.assertIn(directive, unit)

    def test_the_backup_unit_writes_the_backup_directory_and_nothing_else(self):
        """`ReadWritePaths` is the whole of what a compromised backup run can change
        on a `ProtectSystem=strict` host, and this one holds the only encrypted copy
        of every account's identity. It reads the database and writes one directory;
        it never touches `media_root`, which is where the attachment bytes it
        deliberately does not dump live."""
        unit = (settings.BASE_DIR / "ops" / "systemd" / "chat-backup.service").read_text()
        maintenance = (
            settings.BASE_DIR / "ops" / "systemd" / "chat-maintenance.service"
        ).read_text()

        self.assertEqual(
            re.findall(r"^ReadWritePaths=(\S+)$", unit, re.M), ["/srv/chat/backups"]
        )
        hardening = re.findall(
            r"^(?:Protect|Restrict|Lock|NoNew)\S+=\S+$", maintenance, re.M
        )
        self.assertTrue(hardening)
        for directive in hardening:
            self.assertIn(directive, unit)

    def test_the_backup_timer_survives_a_missed_run_and_lands_off_the_hour(self):
        """`Persistent=true` fires one missed run after a reboot rather than
        skipping the day — the dump is idempotent, so replaying it costs a file the
        retention rotation then removes. `RandomizedDelaySec` keeps the run off a
        predictable wall-clock edge, which is the same reason the maintenance timer
        carries one."""
        timer = (settings.BASE_DIR / "ops" / "systemd" / "chat-backup.timer").read_text()

        self.assertIsNotNone(re.search(r"^OnCalendar=daily$", timer, re.M))
        self.assertIsNotNone(re.search(r"^RandomizedDelaySec=\S+$", timer, re.M))
        self.assertIsNotNone(re.search(r"^Persistent=true$", timer, re.M))

    def test_the_example_environment_lists_every_variable_the_code_reads(self):
        """An operator fills in `.env.example` and expects a working deployment. A
        variable the code reads and the example omits is a default nobody chose."""
        read = set()
        for name in CONFIGURED_BY:
            read |= set(READS_ENV.findall((settings.BASE_DIR / name).read_text()))
        declared = set(DECLARES.findall((settings.BASE_DIR / ".env.example").read_text()))

        self.assertEqual(read - declared, set())

    def test_the_example_environment_lists_nothing_the_code_ignores(self):
        """A variable in the example that nothing reads is a setting an operator
        believes they configured. The four the file carries for another process are
        recorded above with the process that reads each one."""
        read = set()
        for name in CONFIGURED_BY:
            read |= set(READS_ENV.findall((settings.BASE_DIR / name).read_text()))
        declared = set(DECLARES.findall((settings.BASE_DIR / ".env.example").read_text()))

        self.assertEqual(declared - read, set(READ_OUTSIDE_PYTHON))

    def test_the_configuration_table_of_the_readme_matches_the_code(self):
        """`backend/README.md` is where the operator reads what a variable does and
        what it defaults to. A row that no code reads describes a knob that does
        nothing; a variable with no row is one nobody can find."""
        documented = set(
            DOCUMENTED.findall((settings.BASE_DIR / "README.md").read_text())
        )
        read = set()
        for name in CONFIGURED_BY:
            read |= set(READS_ENV.findall((settings.BASE_DIR / name).read_text()))

        # `WEB_CONCURRENCY` is read by the systemd unit rather than by Python, and
        # the operator sets it in the same file, so the table carries it too.
        self.assertEqual(documented, read | {"WEB_CONCURRENCY"})

    def test_the_worker_count_has_a_documented_default(self):
        """`--workers ${WEB_CONCURRENCY}` is an empty argument if the operator's
        environment file does not set it, and uvicorn then fails to start."""
        example = (settings.BASE_DIR / ".env.example").read_text()

        self.assertIn("WEB_CONCURRENCY=1", example)

    def test_core_deploy_check_reports_nothing(self):
        self.assertEqual(no_foreign_or_telemetry(None), [])

    def test_no_django_cache_backend_reads_redis(self):
        """Every built-in Django cache backend unpickles what it reads, and Redis
        is a store another process on the host can write to. Nothing in this
        process may turn Redis bytes back into Python objects: the counters and
        the lockout state are read as strings through the redis client, and the
        Django cache framework is left on its process-local default that no other
        software reaches."""
        backend = settings.CACHES["default"]["BACKEND"]

        self.assertNotIn("redis", backend.lower())
        self.assertTrue(backend.endswith("LocMemCache"), backend)

    def test_the_deploy_checks_refuse_a_redis_url_without_a_password(self):
        """Redis listens on loopback of a host shared with other projects. Without
        `requirepass` every local process can flush the rate counters and the
        lockout and inject frames on the fan-out bus."""
        with override_settings(REDIS_URL="redis://127.0.0.1:6379/0"):
            failing = deploy_check_ids()
        with override_settings(REDIS_URL="redis://:generated-secret@127.0.0.1:6379/0"):
            passing = deploy_check_ids()

        self.assertIn("core.E004", failing)
        self.assertNotIn("core.E004", passing)

    def test_the_deploy_checks_refuse_a_weak_infrastructure_secret(self):
        """The signing key mints a token for any account. Django checks its own
        SECRET_KEY's strength and nothing checked this one, so a short value or the
        development fallback reached production in silence."""
        strong = "s" * 32
        cases = {
            "short signing key": {"JWT_SIGNING_KEY": "s" * 31},
            "the development fallback": {"JWT_SIGNING_KEY": "dev-insecure-jwt-key"},
            "the signing key reused as SECRET_KEY": {
                "JWT_SIGNING_KEY": strong,
                "SECRET_KEY": strong,
            },
        }
        for label, overrides in cases.items():
            with self.subTest(label), override_settings(**overrides):
                self.assertIn("core.E005", deploy_check_ids(), label)

        with override_settings(JWT_SIGNING_KEY=strong, SECRET_KEY="k" * 50):
            self.assertNotIn("core.E005", deploy_check_ids())

    def test_the_deploy_checks_refuse_a_weak_relay_secret_once_voice_is_served(self):
        """`TURN_STATIC_AUTH_SECRET` is the HMAC key every relay credential is
        signed under, and from this release Python reads it as well as coturn. A
        holder of it mints credentials for this deployment's relay until the value
        is rotated in both of the two places that carry it.

        It is weighed only when `TURN_URLS` names a relay: a deployment that
        serves no voice answers `503 voice_unconfigured` and never reads the
        secret, so refusing it a value would refuse a deployment that is correct.
        Driven through the registry, so a check written and never registered for
        deployment fails here rather than passing in silence.
        """
        # 198.51.100.0/24 is the documentation range: the check reads only whether
        # `TURN_URLS` is empty, and nothing resolves this.
        relay = ["turn:198.51.100.10:3478"]

        with override_settings(TURN_URLS=[], TURN_STATIC_AUTH_SECRET=""):
            self.assertNotIn("core.E005", deploy_check_ids())
        with override_settings(TURN_URLS=relay, TURN_STATIC_AUTH_SECRET="t" * 31):
            self.assertIn("core.E005", deploy_check_ids())
        with override_settings(TURN_URLS=relay, TURN_STATIC_AUTH_SECRET="t" * 32):
            self.assertNotIn("core.E005", deploy_check_ids())


class CoturnPostureTests(SimpleTestCase):
    """The only media service of this deployment, read from the file that runs it.

    No Python module reads coturn's configuration, so nothing else in this suite
    would notice a posture that drifted. ADR-0021 is what these assert: a relay
    that carries SRTP it cannot open, answers no discovery, reaches nothing on
    this host, and writes nothing down.
    """

    @staticmethod
    def relay():
        return (settings.BASE_DIR / "ops" / "coturn" / "turnserver.conf").read_text()

    @staticmethod
    def directives(conf):
        """Every directive the file actually sets, as (key, value) pairs.

        A `#` starts a comment wherever it appears, so a whole-line comment
        disappears — which is what keeps a commented-out `cert=` from reading as a
        certificate this relay serves — and a trailing one is cut off the value it
        follows.
        """
        return [
            (line.split("=", 1) + [""])[:2]
            for line in (raw.split("#", 1)[0].strip() for raw in conf.splitlines())
            if line
        ]

    def test_the_relay_carries_no_tls_listener_and_no_certificate(self):
        """The hop between a client and this relay already carries SRTP keyed by
        DTLS between two client devices, so a TLS or DTLS listener of coturn's own
        would encrypt what is already encrypted and put a certificate, a private
        key and a renewal on the host. The previous release read
        `/etc/letsencrypt/live/`, a public-CA path the rest of the deployment left
        behind when nginx moved to the private CA."""
        keys = {key for key, _value in self.directives(self.relay())}

        self.assertIn("no-tls", keys)
        self.assertIn("no-dtls", keys)
        for absent in ("tls-listening-port", "cert", "pkey"):
            self.assertNotIn(absent, keys)

    def test_the_relay_answers_no_discovery(self):
        """A relay-only client never asks for its own address, and a STUN
        responder is a reflector any host on the internet can point somewhere
        else."""
        keys = {key for key, _value in self.directives(self.relay())}

        for directive in (
            "no-stun",
            "no-rfc5780",
            "no-stun-backward-compatibility",
            "no-multicast-peers",
            "no-software-attribute",
            "no-cli",
        ):
            self.assertIn(directive, keys)

    def test_the_relay_reaches_nothing_on_this_host_or_its_network(self):
        """A TURN server that relays to loopback is an SSRF pivot into every
        service of a shared VPS: PostgreSQL, Redis, uvicorn and the panel all
        listen there. coturn denies loopback by default, and the default is not
        what a reader can check — so every range is written out, and this is what
        holds them there."""
        denied = {
            value
            for key, value in self.directives(self.relay())
            if key == "denied-peer-ip"
        }

        self.assertNotIn(
            "allow-loopback-peers", {k for k, _v in self.directives(self.relay())}
        )
        # The host itself, filled with `listening-ip` at deploy time. An allocation
        # that may name this box relays into nginx from the relay's own address,
        # which is the caller's address laundered past the anonymous rate limiter.
        self.assertIn(dict(self.directives(self.relay()))["listening-ip"], denied)
        for required in (
            "10.0.0.0-10.255.255.255",
            "100.64.0.0-100.127.255.255",
            "127.0.0.0-127.255.255.255",
            "169.254.0.0-169.254.255.255",
            "172.16.0.0-172.31.255.255",
            "192.168.0.0-192.168.255.255",
            "::1",
            "fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
        ):
            self.assertIn(required, denied)

    def test_the_relay_writes_no_log_anywhere(self):
        """Invariant 4 at the one layer no Python touches. A TURN log line names
        the relay peer pair, which is two devices in one call — the same record as
        an access log, one hop further out. `simple-log` is load-bearing: without
        it coturn appends a date to the file name and writes a real file beside
        the sink."""
        directives = dict(self.directives(self.relay()))

        self.assertEqual(directives.get("log-file"), "/dev/null")
        self.assertIn("no-stdout-log", directives)
        self.assertIn("simple-log", directives)
        self.assertNotIn("syslog", directives)
        self.assertNotIn("verbose", directives)

    def test_the_quotas_bound_the_band_and_the_ports_bound_the_quotas(self):
        """The band is fewer than 50 accounts, at most 500 devices and at most ten
        participants in one room, and every number here comes off it: nine relay
        allocations for one device in a full mesh, five such rooms at once for the
        host. One allocation takes one relay port, so a port range narrower than
        `total-quota` would make the range the limit and the quota a decoration —
        which is the state a later widening of the quota alone would restore."""
        directives = dict(self.directives(self.relay()))
        user, total = int(directives["user-quota"]), int(directives["total-quota"])
        ports = int(directives["max-port"]) - int(directives["min-port"]) + 1

        self.assertGreaterEqual(user, 9)
        self.assertGreaterEqual(total, 10 * user)
        self.assertGreater(ports, total)

    def test_the_relay_listens_on_one_port_of_its_own_address(self):
        """UDP and TCP 3478, and the firewall list of `ops/RUNBOOK.md` §1 is the
        same three numbers. A wildcard listener on a host shared with two other
        projects would answer on every address the box holds."""
        directives = dict(self.directives(self.relay()))

        self.assertEqual(directives["listening-port"], "3478")
        self.assertNotIn("no-tcp-relay", directives)
        for key in ("listening-ip", "relay-ip"):
            self.assertNotIn("0.0.0.0", directives[key])

    def test_the_credentials_are_the_shared_secret_form_and_no_value_is_committed(self):
        """`use-auth-secret` is the TURN REST API form: the username is an expiry
        timestamp and the password is an HMAC over it, so no per-user account
        state is stored on the relay. The realm and the secret are filled inline at
        deploy time, and a value committed here would be a credential in git."""
        directives = dict(self.directives(self.relay()))

        self.assertIn("use-auth-secret", directives)
        for absent in ("realm", "static-auth-secret", "user", "userdb"):
            self.assertNotIn(absent, directives)

    def test_no_denied_peer_range_ends_at_the_all_zero_any_address(self):
        """The one directive in this file whose plain reading is the opposite of
        what it does.

        coturn stores a single address as a range whose min and max are that
        address, and `ioa_addr_in_range` returns a match whenever the range's max
        is the all-zero "any" address — so `denied-peer-ip=::` denies every peer of
        every family, IPv4 included, and no call ever connects. Measured against a
        real coturn 4.17.2 on 2026-09-05: with the line present, a relay bind to an
        IPv4 peer was refused `403` and the relay logged
        `A peer IP 192.168.0.102 denied in the range: ::`; with the line removed the
        same bind succeeded; and with the host's own address denied instead, only
        that address was refused. The 4.6.1 that Debian bookworm and Ubuntu noble
        install carries the identical matcher in `ns_turn_ioaddr.c`.

        None of that is in the coturn documentation, and the relay writes no log
        (AR-15) — so a deployment that grew the line back would fail silently, with
        voice simply never connecting. The upper bound of every range is what is
        asserted: `0.0.0.0-0.255.255.255` is a real range ending at
        `0.255.255.255` and stays, while `::`, `0.0.0.0` and any range written to
        end at one of them is the whole-internet deny this test refuses.
        """
        any_address = {"0.0.0.0", "::", "0:0:0:0:0:0:0:0"}
        denied = [
            value
            for key, value in self.directives(self.relay())
            if key == "denied-peer-ip"
        ]

        self.assertTrue(denied)
        for entry in denied:
            self.assertNotIn(entry.split("-")[-1].strip(), any_address, entry)

    def test_the_relay_and_the_backend_sign_under_one_shared_secret(self):
        """`TURN_STATIC_AUTH_SECRET` is one value in two places from this release:
        coturn checks a credential with it, and `realtime/relay.py` signs one with
        it. Two copies that drift are a relay that refuses every credential the
        backend mints, and the failure is invisible — coturn writes no log, so
        what an operator sees is calls that never connect.

        What the repository can assert is the shape on both sides and that no value
        is committed to either: the coturn file asks for the TURN REST API form,
        commits no `static-auth-secret`, and names the variable that fills it; the
        settings module reads that same variable and defaults it to empty; and the
        minting code signs with SHA-1, which is not a choice this project makes but
        the digest coturn compares — a credential under any other digest is one the
        relay refuses. The two copies being *equal* is the operator's job — they
        fill both from the environment file of `ops/RUNBOOK.md` §5 — and no
        assertion in this repository can reach it.
        """
        conf = self.relay()
        directives = dict(self.directives(conf))
        base = (settings.BASE_DIR / BASE).read_text()
        minting = (settings.BASE_DIR / MINTING).read_text()

        self.assertIn("use-auth-secret", directives)
        self.assertNotIn("static-auth-secret", directives)
        self.assertIn("TURN_STATIC_AUTH_SECRET", conf)  # named in the comments only
        # The three below read a whole module, and `assertIn` would quote the whole
        # of it on a failure. A failure report is a terminal, so each says what is
        # missing and names the file rather than printing it.
        self.assertTrue(
            'env("TURN_STATIC_AUTH_SECRET", default="")' in base,
            f"{BASE} reads no TURN_STATIC_AUTH_SECRET with an empty default",
        )
        self.assertTrue(
            "settings.TURN_STATIC_AUTH_SECRET.encode()" in minting,
            f"{MINTING} signs under some other key",
        )
        self.assertTrue(
            "hashlib.sha1" in minting,
            f"{MINTING} signs under a digest coturn does not compare",
        )


class ProdPostureTests(SimpleTestCase):
    """`config.settings.prod` is what `check --deploy` runs against."""

    def test_debug_is_off(self):
        self.assertFalse(prod.DEBUG)

    def test_transport_is_https_only(self):
        self.assertTrue(prod.SECURE_SSL_REDIRECT)
        self.assertEqual(
            prod.SECURE_PROXY_SSL_HEADER, ("HTTP_X_FORWARDED_PROTO", "https")
        )

    def test_cookies_are_secure(self):
        self.assertTrue(prod.SESSION_COOKIE_SECURE)
        self.assertTrue(prod.CSRF_COOKIE_SECURE)
        self.assertTrue(prod.SESSION_COOKIE_HTTPONLY)
        self.assertEqual(prod.SESSION_COOKIE_SAMESITE, "Strict")
        self.assertEqual(prod.CSRF_COOKIE_SAMESITE, "Strict")

    def test_the_admin_cookies_carry_the_host_prefix(self):
        """The VPS serves two other projects, on sibling names of the same domain
        for all this configuration knows. A `__Host-` cookie is accepted only over
        HTTPS, without a `Domain`, and with `Path=/`, so a sibling site — or a
        subdomain an attacker controls — cannot set one for the panel and no
        broader cookie of the same name can shadow it."""
        from django.conf import global_settings

        def effective(name):
            return getattr(prod, name, getattr(global_settings, name))

        self.assertEqual(prod.SESSION_COOKIE_NAME, "__Host-sessionid")
        self.assertEqual(prod.CSRF_COOKIE_NAME, "__Host-csrftoken")
        self.assertIsNone(effective("SESSION_COOKIE_DOMAIN"))
        self.assertIsNone(effective("CSRF_COOKIE_DOMAIN"))
        self.assertEqual(effective("SESSION_COOKIE_PATH"), "/")
        self.assertEqual(effective("CSRF_COOKIE_PATH"), "/")

    def test_hsts_is_a_full_year_with_subdomains_and_preload(self):
        self.assertEqual(prod.SECURE_HSTS_SECONDS, 31536000)
        self.assertTrue(prod.SECURE_HSTS_INCLUDE_SUBDOMAINS)
        self.assertTrue(prod.SECURE_HSTS_PRELOAD)

    def test_content_type_and_framing_are_locked_down(self):
        self.assertTrue(prod.SECURE_CONTENT_TYPE_NOSNIFF)
        self.assertEqual(prod.X_FRAME_OPTIONS, "DENY")


# The trees `coverage` omits that are not this project's code: the installed
# toolchain, and the untracked wheel cache of ADR-0012.
NOT_PROJECT_CODE = frozenset({".venv/*", "vendor/*"})
# The project code it omits, and the reason each one is not measured.
UNMEASURED = {
    "*/migrations/*": "generated by makemigrations; the migration suite replays them",
    "*/tests/*": "the suite does not measure itself",
    "manage.py": "a four-line Django entry point",
    "devices/vectors/generate.py": "a developer tool that writes the golden vectors",
}


class TestToolchainPostureTests(SimpleTestCase):
    """How the suite itself is configured to run.

    Two knobs decide what the numbers this run produces mean. The coverage omit
    list decides what the figure is a figure *of* — an omission added quietly is a
    module that stops being measured and never fails a floor. And the Hypothesis
    profile decides whether the property tests explore the same inputs twice: the
    suite runs under `pytest-randomly`, which reseeds the global RNG for every
    test, so an entropy-driven profile would give the gate's two orderings two
    different sets of examples and a failure nobody could reproduce.
    """

    def coverage_config(self):
        import tomllib

        text = (settings.BASE_DIR / "pyproject.toml").read_text()
        return tomllib.loads(text)["tool"]["coverage"]

    def test_coverage_measures_branches_over_the_whole_repository(self):
        """`source` is the repository rather than a list of apps, so a new app is
        measured the day it is created and not the day somebody remembers it."""
        run = self.coverage_config()["run"]

        self.assertIs(run["branch"], True)
        self.assertEqual(run["source"], ["."])

    def test_coverage_omits_exactly_the_four_project_paths_that_were_decided(self):
        """Anything else in this list is code that silently stops being counted."""
        omitted = set(self.coverage_config()["run"]["omit"])

        self.assertEqual(omitted - NOT_PROJECT_CODE, set(UNMEASURED))
        self.assertEqual(omitted & NOT_PROJECT_CODE, NOT_PROJECT_CODE)

    def test_every_omitted_file_still_exists(self):
        """An omit for a path that moved excludes nothing and reads as though it
        still does."""
        for name in UNMEASURED:
            if "*" in name:
                continue
            with self.subTest(name=name):
                self.assertTrue((settings.BASE_DIR / name).exists(), name)

    def test_the_property_tests_run_under_the_derandomised_profile(self):
        """`conftest.py` registers it and loads it. Entropy here would mean a
        property that fails in one ordering and passes in the other, with the
        failing example behind a seed nobody recorded."""
        from hypothesis import settings as hypothesis_settings

        profile = hypothesis_settings.default

        self.assertIs(profile.derandomize, True)
        self.assertIsNone(profile.database)
        self.assertIsNone(profile.deadline)

    def test_the_example_budget_is_fixed_and_bounded(self):
        """This is a suite, not a fuzzing campaign: the gate has to finish, and a
        budget nobody can read from the code is a runtime nobody can predict."""
        from hypothesis import settings as hypothesis_settings

        self.assertEqual(hypothesis_settings.default.max_examples, 200)

    def test_no_hypothesis_example_database_is_written_into_the_tree(self):
        """`database=None` is what keeps the example database off disk.

        Without it a property that failed once replays its failing example from a
        directory in the working tree, so a run's result depends on an earlier
        run's — and the derandomised profile above would no longer be the whole
        story. Hypothesis writes its own constant and unicode caches under
        `.hypothesis/` whatever the database setting is, and ships a `.gitignore`
        of its own that keeps them out of git; that is the part the repository
        tolerates.
        """
        tree = settings.BASE_DIR / ".hypothesis"

        self.assertFalse((tree / "examples").exists())
        if tree.exists():
            self.assertIn("\n*", (tree / ".gitignore").read_text())
