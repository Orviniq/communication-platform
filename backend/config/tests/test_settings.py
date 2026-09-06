"""The settings modules, read at their environment boundary.

`core/tests/test_env.py` covers the four accessors themselves and
`core/tests/test_settings_posture.py` covers the posture the loaded settings must
hold. What is left, and what this file holds, is the wiring between them: which
variable each setting reads, what an operator gets when they set nothing, what
stops the process when they set something unusable, and what each of the two
environment modules layers on top of `base`.

Every test here executes `config/settings/base.py` again, as a module of its own
against an environment it chooses. Reloading the installed one is not an option:
`django.conf.settings` copied its values at startup, so a reload would change the
module without changing what the rest of the process reads, and it would leave the
suite's own settings module holding whatever the last test set.
"""

import importlib.util
import re
from pathlib import Path

import pytest
from django.conf import settings

from core.env import ImproperlyConfigured

SETTINGS = Path(settings.BASE_DIR) / "config" / "settings"
BASE = SETTINGS / "base.py"

# The same shape `core/tests/test_settings_posture.py` reads the example file with:
# every environment variable the module names, whichever accessor it names it
# through.
READS_ENV = re.compile(r"\benv(?:_bool|_int|_list)?\(\s*[\"']([A-Z][A-Z0-9_]*)[\"']")

# The variables with no default at all. Each is a value only the operator can
# supply — two secrets and the three halves of a database credential — and the
# process refuses to start without it rather than inventing one.
REQUIRED = (
    "DJANGO_SECRET_KEY",
    "JWT_SIGNING_KEY",
    "POSTGRES_DB",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
)
# Fabricated, and distinct from each other so a setting that reads the wrong one
# is visible. Nothing here is a credential: no process outside this test reads it.
MINIMUM = {key: f"chosen-{key.lower()}" for key in REQUIRED}

# Every numeric setting, and the variable it reads. The name on the left is the
# operator's and the path on the right is the reader's, and the two differ often
# enough — `ENVELOPE_TTL_DAYS` for a plain name, `DB_POOL_MAX_SIZE` for a key
# three levels inside `DATABASES` — that a copy-paste between two of them would
# otherwise be invisible.
NUMERIC = {
    "ADMIN_AUDIT_RETENTION_DAYS": "ADMIN_AUDIT_RETENTION_DAYS",
    "ATTACH_TTL_DAYS": "ATTACH_TTL_DAYS",
    "ATTACH_USER_QUOTA_BYTES": "ATTACH_USER_QUOTA_BYTES",
    "BODY_CAP_BACKUP_BYTES": "BODY_CAP_BACKUP_BYTES",
    "BODY_CAP_BATCH_BYTES": "BODY_CAP_BATCH_BYTES",
    "BODY_CAP_JSON_BYTES": "BODY_CAP_JSON_BYTES",
    "DB_CONN_MAX_AGE": "DATABASES.default.CONN_MAX_AGE",
    "DB_POOL_MAX_SIZE": "DATABASES.default.OPTIONS.pool.max_size",
    "DB_POOL_MIN_SIZE": "DATABASES.default.OPTIONS.pool.min_size",
    "DB_POOL_TIMEOUT": "DATABASES.default.OPTIONS.pool.timeout",
    "ENVELOPE_TTL_DAYS": "ENVELOPE_TTL_DAYS",
    "MAILBOX_MAX_BYTES": "MAILBOX_MAX_BYTES",
    "MAX_DEVICELOG_RECORDS": "MAX_DEVICELOG_RECORDS",
    "MAX_DEVICES_PER_USER": "MAX_DEVICES_PER_USER",
    "MULTIPART_OVERHEAD_BYTES": "MULTIPART_OVERHEAD_BYTES",
    "REDIS_COMMAND_TIMEOUT_SECONDS": "REDIS_COMMAND_TIMEOUT_SECONDS",
    "REGISTER_SCOPE_ACCESS_MIN": "REGISTER_SCOPE_ACCESS_MIN",
    "RELAY_CREDENTIAL_TTL_SECONDS": "RELAY_CREDENTIAL_TTL_SECONDS",
    "REQUEST_DEADLINE_SECONDS": "REQUEST_DEADLINE_SECONDS",
    "SESSION_TOKEN_DAYS": "SESSION_TOKEN_DAYS",
    "UPLOAD_DEADLINE_SECONDS": "UPLOAD_DEADLINE_SECONDS",
    "WS_MAX_FRAME": "WS_MAX_FRAME",
}

# What an operator who sets none of them gets. These are the values the deployment
# actually runs on — `.env.example` carries no line for most of them — so a number
# changed here is a number changed in production, and the retention windows and
# the caps are the ones the threat model is written against.
NUMERIC_DEFAULTS = {
    "ADMIN_AUDIT_RETENTION_DAYS": 90,
    "ATTACH_TTL_DAYS": 30,
    "ATTACH_USER_QUOTA_BYTES": 2 * 1024**3,
    "BODY_CAP_BACKUP_BYTES": 2 * 1024 * 1024,
    "BODY_CAP_BATCH_BYTES": 70 * 1024 * 1024,
    "BODY_CAP_JSON_BYTES": 16 * 1024,
    "DATABASES.default.CONN_MAX_AGE": 0,
    "DATABASES.default.OPTIONS.pool.max_size": 16,
    "DATABASES.default.OPTIONS.pool.min_size": 1,
    "DATABASES.default.OPTIONS.pool.timeout": 10,
    "ENVELOPE_TTL_DAYS": 7,
    "MAILBOX_MAX_BYTES": 32 * 1024 * 1024,
    "MAX_DEVICELOG_RECORDS": 10000,
    "MAX_DEVICES_PER_USER": 10,
    "MULTIPART_OVERHEAD_BYTES": 8 * 1024,
    "REDIS_COMMAND_TIMEOUT_SECONDS": 2,
    "REGISTER_SCOPE_ACCESS_MIN": 10,
    "RELAY_CREDENTIAL_TTL_SECONDS": 21600,
    "REQUEST_DEADLINE_SECONDS": 15,
    "SESSION_TOKEN_DAYS": 30,
    "UPLOAD_DEADLINE_SECONDS": 120,
    "WS_MAX_FRAME": 512 * 1024,
}

# The rate-limit scopes, and the variable each reads.
THROTTLE_VARIABLES = {
    "accounts": "THROTTLE_ACCOUNTS",
    "attachments": "THROTTLE_ATTACHMENTS",
    "claim": "THROTTLE_CLAIM",
    "envelopes": "THROTTLE_ENVELOPES",
    "login": "THROTTLE_LOGIN",
    "register": "THROTTLE_REGISTER",
    "relay": "THROTTLE_RELAY",
}


def read(module, path):
    """A setting by the dotted path `NUMERIC` names it with."""
    parts = path.split(".")
    value = getattr(module, parts[0])
    for part in parts[1:]:
        value = value[part]
    return value


def load(monkeypatch, module_path=BASE, name="settings_under_test", **environment):
    """Execute a settings module against exactly the environment named here.

    Every variable the module reads is unset first, so the developer's own shell
    and the `.env` the suite is run with decide nothing. The module is given a
    name of its own and never registered in `sys.modules`: it has no relative
    imports, and the installed `config.settings.base` must keep the values
    `django.conf.settings` was built from.
    """
    for key in READS_ENV.findall(module_path.read_text()):
        monkeypatch.delenv(key, raising=False)
    for key, value in environment.items():
        monkeypatch.setenv(key, value)
    spec = importlib.util.spec_from_file_location(name, module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_base(monkeypatch, **environment):
    return load(monkeypatch, **{**MINIMUM, **environment})


def assigned_names(module_path):
    """The uppercase names a settings module assigns in its own source, which is
    what it layers on top of whatever it imported."""
    import ast

    tree = ast.parse(module_path.read_text())
    return {
        target.id
        for node in tree.body
        if isinstance(node, ast.Assign)
        for target in node.targets
        if isinstance(target, ast.Name) and target.id.isupper()
    }


class TestTheRequiredEnvironment:
    def test_the_five_required_variables_are_the_ones_with_no_default(self):
        """The record, checked against the source: a variable that loses its
        default becomes a start-up failure on every host that never set it, and a
        variable that gains one becomes a value nobody chose."""
        source = BASE.read_text()
        has_default = r'env(?:_bool|_int|_list)?\(\s*"{}",\s*default='
        without_default = {
            name
            for name in READS_ENV.findall(source)
            if not re.search(has_default.format(name), source)
        }

        assert without_default == set(REQUIRED)

    @pytest.mark.parametrize("missing", REQUIRED)
    def test_a_missing_required_variable_names_itself_and_stops_the_boot(
        self, monkeypatch, missing
    ):
        """The half-filled `.env`. The operator has to be told which line is
        empty, and the process has to refuse rather than run on a fallback."""
        supplied = {key: value for key, value in MINIMUM.items() if key != missing}

        with pytest.raises(ImproperlyConfigured) as raised:
            load(monkeypatch, **supplied)

        assert missing in str(raised.value)

    def test_the_five_are_enough_to_load_the_whole_module(self, monkeypatch):
        """The normal path: everything else has a default, so a deployment that
        supplies the secrets and the database credential boots."""
        module = load_base(monkeypatch)

        assert module.SECRET_KEY == MINIMUM["DJANGO_SECRET_KEY"]
        assert module.JWT_SIGNING_KEY == MINIMUM["JWT_SIGNING_KEY"]
        assert module.DATABASES["default"]["NAME"] == MINIMUM["POSTGRES_DB"]
        assert module.DATABASES["default"]["USER"] == MINIMUM["POSTGRES_USER"]
        assert module.DATABASES["default"]["PASSWORD"] == MINIMUM["POSTGRES_PASSWORD"]

    def test_base_dir_is_the_directory_manage_py_runs_from(self, monkeypatch):
        """Three `parent`s up from a file two directories deep. Every path setting
        is built on it: the templates directory, `STATIC_ROOT` and the default
        attachment root."""
        module = load_base(monkeypatch)

        assert (module.BASE_DIR / "manage.py").exists()
        assert module.STATIC_ROOT == module.BASE_DIR / "static_root"


class TestWhatAnOperatorGetsBySettingNothing:
    def test_no_host_is_admitted_until_one_is_named(self, monkeypatch):
        """Closed by default, in the place a default of "everything" would be
        invisible: `ALLOWED_HOSTS` is what `TrustedHost` refuses on."""
        module = load_base(monkeypatch)

        assert module.ALLOWED_HOSTS == []
        assert module.DEBUG is False

    def test_the_datastores_default_to_loopback(self, monkeypatch):
        module = load_base(monkeypatch)

        assert module.DATABASES["default"]["HOST"] == "127.0.0.1"
        assert module.DATABASES["default"]["PORT"] == "5432"
        assert module.REDIS_URL == "redis://127.0.0.1:6379/0"

    def test_every_numeric_setting_takes_the_default_recorded_here(self, monkeypatch):
        """The values the deployment runs on. Most have no line in `.env.example`,
        so the default is the setting, and the retention windows and the body caps
        among them are what the threat model is written against."""
        module = load_base(monkeypatch)

        assert {path: read(module, path) for path in NUMERIC_DEFAULTS} == NUMERIC_DEFAULTS

    def test_the_attachment_root_defaults_inside_the_repository(self, monkeypatch):
        module = load_base(monkeypatch)

        assert module.ATTACHMENTS_ROOT == module.BASE_DIR / "media_root"

    def test_every_throttle_scope_has_a_default_rate(self, monkeypatch):
        """A scope with no rate is a route with no limit: the limiter reads this
        table by the name the route declares."""
        module = load_base(monkeypatch)

        assert set(module.THROTTLE_RATES) == set(THROTTLE_VARIABLES)
        assert all(module.THROTTLE_RATES.values())


class TestTheNumericBoundary:
    def test_the_recorded_numeric_settings_are_all_of_them(self):
        """The gate on the table below: a numeric setting added to `base.py` and
        not recorded here is one nothing proves reads its own variable."""
        read_as_numbers = set(
            re.findall(r'\benv_int\(\s*"([A-Z][A-Z0-9_]*)"', BASE.read_text())
        )

        assert read_as_numbers == set(NUMERIC)

    def test_each_numeric_setting_reads_the_variable_recorded_against_it(
        self, monkeypatch
    ):
        """Every variable set to a value of its own, in one load. Two settings
        reading one variable, or a setting reading its neighbour's, is a mistake
        that no single-variable test can see."""
        chosen = {name: str(101 + index) for index, name in enumerate(sorted(NUMERIC))}

        module = load_base(monkeypatch, **chosen)

        assert {path: read(module, path) for path in NUMERIC.values()} == {
            path: int(chosen[name]) for name, path in NUMERIC.items()
        }

    @pytest.mark.parametrize("name", sorted(NUMERIC))
    def test_a_blank_numeric_variable_falls_back_to_its_default(self, monkeypatch, name):
        """The boundary an operator produces by leaving a key in `.env` with
        nothing after the equals sign. `int("")` would be a start-up crash."""
        module = load_base(monkeypatch, **{name: ""})

        assert read(module, NUMERIC[name]) == NUMERIC_DEFAULTS[NUMERIC[name]]

    def test_a_numeric_variable_that_is_not_a_number_stops_the_boot(self, monkeypatch):
        """The rare case, and deliberately loud: a mistyped deadline that fell back
        to its default would run at a value the operator believes they changed."""
        with pytest.raises(ValueError):
            load_base(monkeypatch, REQUEST_DEADLINE_SECONDS="fifteen")


class TestTheStringAndListBoundary:
    def test_the_allowed_hosts_are_split_stripped_and_never_blank(self, monkeypatch):
        """A trailing comma must not produce an empty host: `TrustedHost` compares
        against this list, and an empty entry would match a request that carries no
        `Host` header at all."""
        module = load_base(monkeypatch, DJANGO_ALLOWED_HOSTS="chat.example, 10.0.0.1,,")

        assert module.ALLOWED_HOSTS == ["chat.example", "10.0.0.1"]

    @pytest.mark.parametrize(("scope", "variable"), sorted(THROTTLE_VARIABLES.items()))
    def test_each_throttle_scope_reads_its_own_variable(
        self, monkeypatch, scope, variable
    ):
        """Eight scopes and eight variables. A scope pointed at the wrong one gives
        a route somebody else's limit — `register` at the `envelopes` rate is 600
        registrations a minute."""
        module = load_base(monkeypatch, **{variable: "3/hour"})

        assert module.THROTTLE_RATES[scope] == "3/hour"
        assert [
            other for other, rate in module.THROTTLE_RATES.items() if rate == "3/hour"
        ] == [scope]

    def test_an_absolute_attachment_root_is_taken_as_given(self, monkeypatch):
        """The deployment puts it outside the repository, and the systemd unit
        lists that path as the one writable tree the process has."""
        module = load_base(monkeypatch, ATTACHMENTS_ROOT="/srv/chat/media")

        assert module.ATTACHMENTS_ROOT == Path("/srv/chat/media")

    def test_the_redis_url_is_taken_verbatim(self, monkeypatch):
        """Including the password the deploy check requires. It is read as a URL by
        the redis client and never parsed here."""
        module = load_base(monkeypatch, REDIS_URL="redis://:pw@127.0.0.1:6380/3")

        assert module.REDIS_URL == "redis://:pw@127.0.0.1:6380/3"


class TestTheLayering:
    """What `dev` and `prod` add to `base`, and what neither may quietly drop."""

    # Everything `config/settings/prod.py` assigns. The list is the review: a name
    # added to it is a production-only setting nobody else's test would see.
    PROD_OVERRIDES = {
        "DEBUG",
        "SECURE_SSL_REDIRECT",
        "SESSION_COOKIE_SECURE",
        "CSRF_COOKIE_SECURE",
        "SESSION_COOKIE_NAME",
        "CSRF_COOKIE_NAME",
        "SECURE_HSTS_SECONDS",
        "SECURE_HSTS_INCLUDE_SUBDOMAINS",
        "SECURE_HSTS_PRELOAD",
        "SECURE_PROXY_SSL_HEADER",
        "USE_X_FORWARDED_HOST",
    }
    # And everything `config/settings/dev.py` assigns. `DEBUG` is what opens the
    # static files; `ALLOWED_HOSTS` widens what the base closes.
    DEV_OVERRIDES = {"DEBUG", "ALLOWED_HOSTS"}

    def test_prod_assigns_only_the_names_recorded_here(self):
        from config.settings import prod

        assert assigned_names(SETTINGS / "prod.py") == self.PROD_OVERRIDES
        assert prod.DEBUG is False

    def test_dev_assigns_only_the_names_recorded_here(self):
        assert assigned_names(SETTINGS / "dev.py") == self.DEV_OVERRIDES

    def test_prod_carries_every_setting_the_base_defines(self, monkeypatch):
        """The star import is the whole of the layering, and it is silent: a
        `prod.py` that imported a submodule instead would still be a valid settings
        module, with every default of `base` missing."""
        from config.settings import prod

        base = load_base(monkeypatch)
        defined = {name for name in vars(base) if name.isupper()}

        assert defined
        assert defined <= {name for name in dir(prod) if name.isupper()}

    def test_prod_widens_nothing_the_base_closed(self):
        """`prod` tightens transport and cookies and touches the host allowlist
        not at all: a production host names its own `DJANGO_ALLOWED_HOSTS`, and a
        fallback here would be one that every deployment silently inherits."""
        assigned = assigned_names(SETTINGS / "prod.py")

        assert "ALLOWED_HOSTS" not in assigned

    def test_dev_is_reachable_over_loopback_and_by_the_test_client(self):
        """`testserver` is the host `httpx` sends through the composed stack, so
        without it every request in the suite would meet `TrustedHost` first."""
        from config.settings import dev

        assert dev.DEBUG is True
        assert dev.ALLOWED_HOSTS == ["127.0.0.1", "localhost", "testserver"]
