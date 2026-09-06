from pathlib import Path

from django.urls import reverse_lazy
from django.utils.translation import gettext_lazy as _

from core.env import env, env_int, env_list

BASE_DIR = Path(__file__).resolve().parent.parent.parent

SECRET_KEY = env("DJANGO_SECRET_KEY")
DEBUG = False
ALLOWED_HOSTS = env_list("DJANGO_ALLOWED_HOSTS", default=[])

INSTALLED_APPS = [
    # `unfold` before `django.contrib.admin`, and the order is load-bearing: the
    # admin's AppConfig.ready() runs autodiscover(), and unfold's replaces
    # `admin.site` with an `UnfoldAdminSite`. Reversed, every registration lands on
    # the site that is then thrown away and the panel index lists nothing.
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
    "realtime",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",  # admin only; API is token-auth
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = None  # ASGI-only; uvicorn runs `config.asgi:application`

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        # Ahead of every application, which is what lets `templates/admin/index.html`
        # and `templates/403.html` win over the ones `unfold` and Django ship.
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ]
        },
    }
]

AUTH_USER_MODEL = "accounts.User"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": env("POSTGRES_DB"),
        "USER": env("POSTGRES_USER"),
        "PASSWORD": env("POSTGRES_PASSWORD"),
        "HOST": env("POSTGRES_HOST", default="127.0.0.1"),
        "PORT": env("POSTGRES_PORT", default="5432"),
        "CONN_MAX_AGE": env_int("DB_CONN_MAX_AGE", default=0),
        "OPTIONS": {
            "pool": {
                "min_size": env_int("DB_POOL_MIN_SIZE", default=1),
                "max_size": env_int("DB_POOL_MAX_SIZE", default=16),
                "timeout": env_int("DB_POOL_TIMEOUT", default=10),
            }
        },
    }
}

# Read as strings by the redis client, and never through the Django cache
# framework: every built-in cache backend unpickles what it reads, and Redis is a
# store another process on the host can write to (ADR-0018). `CACHES` therefore
# stays on Django's process-local default, which nothing in this project uses.
REDIS_URL = env("REDIS_URL", default="redis://127.0.0.1:6379/0")
# Both the connect timeout and the per-command timeout of every Redis client this
# process builds. Without one, a Redis that accepts the connection and then stops
# answering — a blocked instance, or a half-open socket after the network moved
# under it — holds its caller for ever. On the HTTP surface the request deadline
# would eventually answer `503`; the WebSocket gateway has no deadline at all, so
# a signal relay would wait until the client gave up.
# Loopback commands on this host are sub-millisecond, so two seconds is a hang and
# never a slow answer, and the throttled routes fail closed on it exactly as they
# already do when Redis refuses the connection (ADR-0010).
#
# It does not silence the fan-out bus: redis-py hands `math.inf` to the blocking
# pub/sub read, which opts that one read out of the socket timeout while the
# reconnect, AUTH and re-subscribe it performs around it still honour it.
REDIS_COMMAND_TIMEOUT_SECONDS = env_int("REDIS_COMMAND_TIMEOUT_SECONDS", default=2)
# Argon2id first. Password hashing protects auth only, never content.
PASSWORD_HASHERS = [
    "django.contrib.auth.hashers.Argon2PasswordHasher",
    "django.contrib.auth.hashers.PBKDF2PasswordHasher",
]
AUTH_PASSWORD_VALIDATORS = [
    {
        "NAME": "django.contrib.auth.password_validation.MinimumLengthValidator",
        "OPTIONS": {"min_length": 10},
    },
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "static_root"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# No email is ever sent by this system.
EMAIL_BACKEND = "django.core.mail.backends.console.EmailBackend"

# --- Authentication (ADR-0023): PyJWT, and no token table -----------------------
# A token table would be a per-device login record at rest, which the threat model
# refuses to keep. Revocation is one counter on the device row instead.
JWT_SIGNING_KEY = env("JWT_SIGNING_KEY")
JWT_ALGORITHM = "HS256"
SESSION_TOKEN_DAYS = env_int("SESSION_TOKEN_DAYS", default=30)
REGISTER_SCOPE_ACCESS_MIN = env_int("REGISTER_SCOPE_ACCESS_MIN", default=10)

# --- Rate limits (ADR-0010) -----------------------------------------------------
# One table, read by the one limiter. A request counts against exactly one scope,
# named by the route that declares it.
THROTTLE_RATES = {
    "register": env("THROTTLE_REGISTER", default="10/hour"),
    "login": env("THROTTLE_LOGIN", default="20/hour"),
    # 300/min: a 50-member fan-out with per-user reads reached the old 120 in one
    # cycle, and the peer-state route removes most of those reads (ADR-0024) while
    # the raise covers the rest.
    "accounts": env("THROTTLE_ACCOUNTS", default="300/min"),
    "claim": env("THROTTLE_CLAIM", default="120/min"),
    "envelopes": env("THROTTLE_ENVELOPES", default="600/min"),
    "attachments": env("THROTTLE_ATTACHMENTS", default="60/min"),
    "relay": env("THROTTLE_RELAY", default="60/min"),
}

# --- Request limits (ADR-0014) --------------------------------------------------
# One process on 1 GB of RAM has no headroom for an unbounded body or a request
# that never ends, and no second host to fail over to. The batch cap covers the
# `devices` and `messaging` bodies, whose length is a list cap times a base64 cap;
# nginx caps the same value at 70m. The attachment upload takes the largest
# attachment bucket plus the overhead below, which is the multipart wrapper around
# the file part: two boundary lines and the Content-Disposition header.
REQUEST_DEADLINE_SECONDS = env_int("REQUEST_DEADLINE_SECONDS", default=15)
UPLOAD_DEADLINE_SECONDS = env_int("UPLOAD_DEADLINE_SECONDS", default=120)
BODY_CAP_JSON_BYTES = env_int("BODY_CAP_JSON_BYTES", default=16 * 1024)
BODY_CAP_BACKUP_BYTES = env_int("BODY_CAP_BACKUP_BYTES", default=2 * 1024 * 1024)
BODY_CAP_BATCH_BYTES = env_int("BODY_CAP_BATCH_BYTES", default=70 * 1024 * 1024)
MULTIPART_OVERHEAD_BYTES = env_int("MULTIPART_OVERHEAD_BYTES", default=8 * 1024)

# Storage limits and retention.
ATTACHMENTS_ROOT = Path(env("ATTACHMENTS_ROOT", default=str(BASE_DIR / "media_root")))
# What one account may upload in one UTC day. It replaces the lifetime sum over an
# uploader column, which was the one thing that tied stored bytes to an account
# (ADR-0025): the counter lives in Redis, names the account and the day, expires
# after two days and never reaches disk. A day is the unit because the cost this
# bounds is a burst against the disk, not a balance an account carries.
ATTACH_DAILY_BYTES = env_int("ATTACH_DAILY_BYTES", default=256 * 1024**2)
# The free space `ATTACHMENTS_ROOT` must still have for an upload to be admitted.
# The daily allowance bounds one account; nothing bounds the sum of every account,
# so this is what stands between a busy day and a full disk — and a full disk on
# this host is PostgreSQL and Redis losing their writes, not one refused upload.
ATTACH_MIN_FREE_BYTES = env_int("ATTACH_MIN_FREE_BYTES", default=2 * 1024**3)
ATTACH_TTL_DAYS = env_int("ATTACH_TTL_DAYS", default=30)
# 7 days bounds what a live seizure captures to at most a week of *undelivered*
# ciphertext (delivery deletes on ack). It is also the window an offline device
# has to collect its mail: an envelope pruned first may have carried a ratchet
# message or a group control event, and the device must then repair the affected
# pairwise sessions — see queue_pruned_through.
ENVELOPE_TTL_DAYS = env_int("ENVELOPE_TTL_DAYS", default=7)
# The ceiling on the undelivered bytes one mailbox holds. Any member can address
# any mailbox, so without it a member's sends are a write primitive against the
# disk of the host; with it the worst case is the ceiling times the device count.
# A device whose mailbox would pass it is refused whole and named in
# `full_devices`, and the sender retries once the device has drained.
MAILBOX_MAX_BYTES = env_int("MAILBOX_MAX_BYTES", default=32 * 1024 * 1024)
MAX_DEVICES_PER_USER = env_int("MAX_DEVICES_PER_USER", default=10)
# The ceiling on one account's device-list log. The log is append-only and never
# pruned, and a client appends one record for each device-set change, so ten
# thousand is a lifetime of changes; without a ceiling one account grows the
# table at the batch cap times the rate limit for as long as it likes.
MAX_DEVICELOG_RECORDS = env_int("MAX_DEVICELOG_RECORDS", default=10000)

# Realtime gateway bounds. A `signal` blob is bounded by `SIGNAL_BUCKETS` in
# `core/buckets.py` rather than by a setting: it is base64 of exactly one bucket.
WS_MAX_FRAME = env_int("WS_MAX_FRAME", default=512 * 1024)

# --- The voice relay (ADR-0021) -------------------------------------------------
# coturn is the only media service of this deployment, and `POST /me/relay` is the
# only route voice has. The secret is shared with `ops/coturn/turnserver.conf` and
# is read here as well from this release: it is the HMAC key a credential is signed
# under, never a value that travels. An empty `TURN_URLS` is a deployment that
# serves no voice, and the route answers `503 voice_unconfigured` — so voice is
# configured on, rather than off, by an operator who fills these two in.
TURN_URLS = env_list("TURN_URLS", default=[])
TURN_STATIC_AUTH_SECRET = env("TURN_STATIC_AUTH_SECRET", default="")
# Six hours. Long enough that a call outlives its credential only rarely, and
# short enough that a leaked one buys an attacker relay bandwidth for an evening
# rather than for the life of the deployment (AR-17). The client refreshes with
# under an hour left, and performs an ICE restart if one expires mid-call.
RELAY_CREDENTIAL_TTL_SECONDS = env_int("RELAY_CREDENTIAL_TTL_SECONDS", default=21600)

# Security headers (prod tightens further).
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = "DENY"
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Strict"
CSRF_COOKIE_SAMESITE = "Strict"

# --- The admin panel (ADR-0011) -------------------------------------------------
# The cookie session exists for the admin alone; the API is token-auth and reads
# none of these. The two settings do different jobs and both are wanted: the age is
# the server-side ceiling the session record carries, and the browser-close flag
# drops `Max-Age` from the cookie so a closed browser ends the session before that
# ceiling does.
SESSION_COOKIE_AGE = 8 * 60 * 60
SESSION_EXPIRE_AT_BROWSER_CLOSE = True
# The admin is the only session-authenticated surface in this process, so its index
# is the only place a sign-in can land. This is not a preference: django-unfold
# 0.105.0's `admin/login.html` drops the hidden `next` field that Django's own
# template carries, so a sign-in with no `?next=` falls through to
# `LOGIN_REDIRECT_URL` — which by default is `/accounts/profile/`, a path this
# deployment answers with the API's `not_found` envelope. `UNFOLD["LOGIN"]
# ["redirect_after"]` does not fix it: the key is declared in unfold's settings and
# read nowhere else in the release.
LOGIN_REDIRECT_URL = reverse_lazy("admin:index")
# How long an audit row survives. `manage.py prune` deletes the rest. Thirty days
# with the day-granularity rows of ADR-0025: a seizure takes at most one month of
# operator history, and the day a row holds says nothing about the hour.
ADMIN_AUDIT_RETENTION_DAYS = env_int("ADMIN_AUDIT_RETENTION_DAYS", default=30)

# The panel is designed in `core/panel.py`; this is only its configuration. Every
# key below is read by django-unfold 0.105.0 — an unknown key changes nothing and
# reports nothing, so nothing speculative belongs here.
UNFOLD = {
    "SITE_TITLE": _("Chat operations"),
    "SITE_HEADER": _("Chat operations"),
    "SITE_SUBHEADER": _("Operator back office"),
    # No public site to return to: `/` is a 404 by design. Without this the header
    # and the account menu both draw a "View site" link to it.
    "SITE_URL": None,
    # The audit log is the one history surface. Django's per-object history page
    # reads the same rows behind a second URL for each object.
    "SHOW_HISTORY": False,
    "SHOW_VIEW_ON_SITE": False,
    "SHOW_LANGUAGES": False,
    "SHOW_BACK_BUTTON": True,
    # `search_models` False keeps the command palette off the rows: it would run a
    # `search_fields` query for each registered model on every keystroke, and for
    # `Attachment` the row it found could only be named by its capability id.
    "COMMAND": {"search_models": False, "show_history": False},
    "LOGIN": {"form": "core.lockout.AdminLoginForm"},
    "DASHBOARD_CALLBACK": "core.panel.dashboard",
    "SIDEBAR": {
        "show_search": False,
        # The drawer this opens lists every registered model under its app label,
        # which is the database's shape rather than the operator's.
        "show_all_applications": False,
        # Named for what the operator does, not for the applications the models
        # live in. A non-empty tree replaces the automatic app list entirely.
        "navigation": [
            {
                "title": _("Overview"),
                "items": [
                    {
                        "title": _("Dashboard"),
                        "icon": "space_dashboard",
                        "permission": "core.panel.is_owner",
                        "link": reverse_lazy("admin:index"),
                    }
                ],
            },
            {
                "title": _("People"),
                "items": [
                    {
                        "title": _("Accounts"),
                        "icon": "person",
                        "permission": "core.panel.is_owner",
                        "link": reverse_lazy("admin:accounts_user_changelist"),
                    },
                    {
                        "title": _("Devices"),
                        "icon": "smartphone",
                        "permission": "core.panel.is_owner",
                        "link": reverse_lazy("admin:devices_device_changelist"),
                    },
                ],
            },
            {
                "title": _("Storage"),
                "items": [
                    {
                        "title": _("Attachments"),
                        "icon": "attach_file",
                        "permission": "core.panel.is_owner",
                        "link": reverse_lazy("admin:attachments_attachment_changelist"),
                    },
                ],
            },
            {
                "title": _("Audit"),
                "items": [
                    {
                        "title": _("Administrative actions"),
                        "icon": "history",
                        "permission": "core.panel.is_owner",
                        "link": reverse_lazy("admin:admin_logentry_changelist"),
                    }
                ],
            },
        ],
    },
}

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "filters": {"scrub": {"()": "core.logging_filters.ScrubFilter"}},
    "formatters": {"plain": {"format": "%(levelname)s %(name)s %(message)s"}},
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "plain",
            "filters": ["scrub"],
        }
    },
    "root": {"handlers": ["console"], "level": "INFO"},
    "loggers": {
        # No request/access logging: never record method, path, or bodies.
        "django.request": {"handlers": ["console"], "level": "ERROR", "propagate": False},
        "django.server": {"handlers": ["console"], "level": "ERROR", "propagate": False},
        # The server's own loggers. `--no-access-log` already stops uvicorn from
        # writing a request line, and these are the second half of the same rule:
        # each is named here so it goes through the console handler, and therefore
        # through the scrub filter, rather than through a root logger it does not
        # propagate to. WARNING keeps the connection-level chatter — which carries
        # a client address and a request path — out of the journal.
        "uvicorn": {"handlers": ["console"], "level": "WARNING", "propagate": False},
        "uvicorn.error": {
            "handlers": ["console"],
            "level": "WARNING",
            "propagate": False,
        },
        "uvicorn.access": {
            "handlers": ["console"],
            "level": "WARNING",
            "propagate": False,
        },
        "websockets": {"handlers": ["console"], "level": "WARNING", "propagate": False},
        # redis-py logs every publish-and-subscribe push it receives — the topic
        # and the payload, so a device id and a ciphertext blob — and installs a
        # `StreamHandler` to stdout for it the first time a `PubSub` is built
        # without a push handler. Naming the logger here is what stops that: the
        # library only installs its handler when the logger does not exist yet,
        # and `dictConfig` creates it. `realtime.bus` passes its own handler as
        # well, so nothing formats the push in the first place.
        "push_response": {
            "handlers": ["console"],
            "level": "WARNING",
            "propagate": False,
        },
    },
}
