"""The three deploy checks of `core/checks.py`, each driven onto both branches.

`core/tests/test_settings_posture.py` asks what `manage.py check --deploy` reports
under the settings this deployment actually runs; that is the posture. This file
asks whether each check can report anything at all — every `core.E…` id it can
raise, and the clean case beside it. A check that never fires is a check that
would not have caught the thing it was written for.

`INSTALLED_APPS` is patched onto the settings object rather than through
`override_settings`, which would call `apps.set_installed_apps` and import each
name: none of the four banned packages is installed, by design, so importing them
is exactly what must not happen here.
"""

from unittest import mock

import pytest
from django.conf import settings
from django.core.checks import Tags
from django.core.checks.registry import registry
from django.test import override_settings

from core.checks import (
    infrastructure_secrets_are_strong,
    no_foreign_or_telemetry,
    redis_requires_a_password,
)

CHECKS = (
    no_foreign_or_telemetry,
    redis_requires_a_password,
    infrastructure_secrets_are_strong,
)
BANNED = ("sentry_sdk", "ddtrace", "newrelic", "elasticapm")
STRONG = "g" * 32
# A relay the check can see without one existing. Only the emptiness of
# `TURN_URLS` is read, never what it names, and 198.51.100.0/24 is the
# documentation range so nothing resolves it.
RELAY = ["turn:198.51.100.10:3478"]
# A signing key that passes the length floor, pinned by every test below that reads
# the whole error list. Without it those tests weigh the ambient `JWT_SIGNING_KEY`
# too: `config/settings/dev.py` falls back to a twenty-character value, so a
# developer running the suite on the dev default got a second `core.E005` the
# assertion had not budgeted for, and five tests failed for the environment rather
# than the code. CI exports a long key and hid it.
STRONG = "s" * 32


def ids(errors):
    return [error.id for error in errors]


class TestRegistration:
    def test_every_core_check_is_a_deployment_check_tagged_security(self):
        """A check registered without `deploy=True` runs on every management
        command and never as part of the deploy gate, which is the one place
        these three are read."""
        for check in CHECKS:
            assert check in registry.deployment_checks, check.__name__
            assert check not in registry.registered_checks, check.__name__
            assert Tags.security in check.tags, check.__name__

    def test_each_check_reports_an_error_id_of_its_own(self):
        """Four ids, four distinct failures. A duplicated id is two problems an
        operator reads as one.

        One id covers more than one failure by design: `core.E005` is raised once
        per weak infrastructure secret, so a run with both of them weak reports
        two errors under it. That is the deliberate exception, and
        `TestInfrastructureSecrets` is where it is pinned; what this asserts is
        that no two *checks* share an id.
        """
        raised = set()
        with mock.patch.object(settings, "INSTALLED_APPS", list(BANNED)):
            with override_settings(
                EMAIL_BACKEND="django.core.mail.backends.smtp.EmailBackend"
            ):
                raised |= set(ids(no_foreign_or_telemetry(None)))
        with override_settings(DEBUG=False, REDIS_URL="redis://127.0.0.1:6379/0"):
            raised |= set(ids(redis_requires_a_password(None)))
        with override_settings(JWT_SIGNING_KEY="short"):
            raised |= set(ids(infrastructure_secrets_are_strong(None)))

        assert raised == {"core.E001", "core.E002", "core.E004", "core.E005"}


class TestTelemetryAndEmail:
    @pytest.mark.parametrize("package", BANNED)
    def test_each_banned_reporting_package_is_reported(self, package):
        """This server sends nothing to anyone: an error reporter would ship a
        traceback — and whatever identifier it carries — off the host."""
        with mock.patch.object(settings, "INSTALLED_APPS", ["core", package]):
            errors = no_foreign_or_telemetry(None)

        assert ids(errors) == ["core.E001"]

    def test_a_dotted_app_path_is_matched_on_its_package(self):
        """`sentry_sdk.integrations.django` is the spelling a reader would add,
        and it is the same package."""
        with mock.patch.object(
            settings, "INSTALLED_APPS", ["sentry_sdk.integrations.django"]
        ):
            errors = no_foreign_or_telemetry(None)

        assert ids(errors) == ["core.E001"]

    def test_several_banned_packages_are_all_named(self):
        with mock.patch.object(settings, "INSTALLED_APPS", list(BANNED)):
            errors = no_foreign_or_telemetry(None)

        assert ids(errors) == ["core.E001"] * len(BANNED)

    def test_the_smtp_email_backend_is_refused(self):
        with override_settings(
            EMAIL_BACKEND="django.core.mail.backends.smtp.EmailBackend"
        ):
            errors = no_foreign_or_telemetry(None)

        assert ids(errors) == ["core.E002"]

    def test_a_backend_that_sends_nowhere_passes(self):
        """The boundary of the suffix match: the console backend's dotted path
        carries neither `smtp` nor a destination."""
        with override_settings(
            EMAIL_BACKEND="django.core.mail.backends.console.EmailBackend"
        ):
            assert no_foreign_or_telemetry(None) == []

    def test_the_installed_set_of_this_deployment_reports_nothing(self):
        assert no_foreign_or_telemetry(None) == []


class TestRedisPassword:
    def test_a_url_with_no_password_is_refused(self):
        """Redis listens on loopback of a host shared with other projects, and
        loopback is reachable by every local process."""
        with override_settings(DEBUG=False, REDIS_URL="redis://127.0.0.1:6379/0"):
            assert ids(redis_requires_a_password(None)) == ["core.E004"]

    def test_a_username_without_a_password_is_still_no_password(self):
        """The boundary `urlsplit` makes easy to get wrong: `redis://user@host`
        parses a userinfo section and no password at all."""
        with override_settings(DEBUG=False, REDIS_URL="redis://someone@127.0.0.1:6379/0"):
            assert ids(redis_requires_a_password(None)) == ["core.E004"]

    def test_a_url_that_carries_a_password_passes(self):
        with override_settings(
            DEBUG=False, REDIS_URL="redis://:generated-secret@127.0.0.1:6379/0"
        ):
            assert redis_requires_a_password(None) == []

    def test_a_development_machine_is_allowed_to_run_without_one(self):
        """`DEBUG` is what names a development machine, and the settings a
        deployment runs set it off — `security.W018` is what says so when they
        do not."""
        with override_settings(DEBUG=True, REDIS_URL="redis://127.0.0.1:6379/0"):
            assert redis_requires_a_password(None) == []


class TestInfrastructureSecrets:
    def test_a_signing_key_below_the_hs256_key_size_is_weak(self):
        """HS256 wants at least 256 bits, and nothing else refused a short one."""
        with override_settings(JWT_SIGNING_KEY="s" * 31):
            assert ids(infrastructure_secrets_are_strong(None)) == ["core.E005"]

    def test_a_signing_key_at_the_key_size_passes(self):
        """The boundary: thirty-two characters is the first acceptable length."""
        with override_settings(JWT_SIGNING_KEY="s" * 32):
            assert infrastructure_secrets_are_strong(None) == []

    def test_the_development_fallback_signing_key_is_refused_at_any_length(self):
        """`config/settings/dev.py` sets it so the suite runs without a secret
        set. Reaching production with it means anyone can mint a token for any
        account."""
        with override_settings(JWT_SIGNING_KEY="dev-insecure-jwt-key"):
            assert ids(infrastructure_secrets_are_strong(None)) == ["core.E005"]

    def test_a_signing_key_shared_with_the_django_secret_is_refused(self):
        with override_settings(JWT_SIGNING_KEY=STRONG, SECRET_KEY=STRONG):
            assert ids(infrastructure_secrets_are_strong(None)) == ["core.E005"]

    def test_the_error_names_the_setting_the_operator_has_to_rotate(self):
        """The message is what an operator acts on, and a `check --deploy` run
        that says only "a secret is weak" names nothing to fix."""
        with override_settings(JWT_SIGNING_KEY="dev-insecure-jwt-key"):
            (error,) = infrastructure_secrets_are_strong(None)

        assert "JWT_SIGNING_KEY" in error.msg

    def test_no_error_message_carries_a_secret_value(self):
        """The message is what lands in a deploy log. It names the setting, never
        the value under it."""
        with override_settings(JWT_SIGNING_KEY="s3cr3t-but-far-too-short"):
            errors = infrastructure_secrets_are_strong(None)

        assert "s3cr3t-but-far-too-short" not in " ".join(error.msg for error in errors)

    def test_a_relay_secret_is_not_weighed_when_no_relay_is_configured(self):
        """A deployment that serves no voice reads the secret nowhere, so refusing
        it a value would refuse a deployment that is correct. `TURN_URLS` is what
        says whether voice is served, and it is empty by default."""
        for secret in ("", "far-too-short"):
            with override_settings(
                JWT_SIGNING_KEY=STRONG, TURN_URLS=[], TURN_STATIC_AUTH_SECRET=secret
            ):
                assert infrastructure_secrets_are_strong(None) == []

    def test_a_relay_secret_below_the_key_size_is_weak_once_a_relay_is_named(self):
        """The secret is the HMAC key every relay credential is signed under, and
        a holder of it mints credentials for this deployment's coturn until the
        value is rotated in both of the two places that carry it."""
        with override_settings(
            JWT_SIGNING_KEY=STRONG, TURN_URLS=RELAY, TURN_STATIC_AUTH_SECRET="t" * 31
        ):
            assert ids(infrastructure_secrets_are_strong(None)) == ["core.E005"]

    def test_a_relay_secret_at_the_key_size_passes(self):
        """The boundary: thirty-two characters is the first acceptable length, the
        same floor the signing key is held to."""
        with override_settings(
            JWT_SIGNING_KEY=STRONG, TURN_URLS=RELAY, TURN_STATIC_AUTH_SECRET="t" * 32
        ):
            assert infrastructure_secrets_are_strong(None) == []

    def test_both_secrets_weak_at_once_are_reported_as_two_errors(self):
        """One check, two secrets. A deploy that fixed the signing key and stopped
        reading would leave the relay secret weak, so each one gets a line of its
        own rather than the first one found."""
        with override_settings(
            JWT_SIGNING_KEY="s" * 31, TURN_URLS=RELAY, TURN_STATIC_AUTH_SECRET="t" * 31
        ):
            errors = infrastructure_secrets_are_strong(None)

        assert ids(errors) == ["core.E005", "core.E005"]
        reported = " ".join(error.msg for error in errors)
        assert "JWT_SIGNING_KEY" in reported
        assert "TURN_STATIC_AUTH_SECRET" in reported

    def test_the_relay_error_names_the_setting_the_operator_has_to_rotate(self):
        """Two variables can fail this check and they are rotated differently: the
        relay secret is one value in two places, so a message that named neither
        would leave an operator to guess which."""
        with override_settings(
            JWT_SIGNING_KEY=STRONG, TURN_URLS=RELAY, TURN_STATIC_AUTH_SECRET="t" * 31
        ):
            (error,) = infrastructure_secrets_are_strong(None)

        assert "TURN_STATIC_AUTH_SECRET" in error.msg
        assert "JWT_SIGNING_KEY" not in error.msg

    def test_no_relay_error_message_carries_a_secret_value(self):
        """The same rule as the signing key, at the one other secret this check
        reads: the message lands in a deploy log."""
        with override_settings(
            TURN_URLS=RELAY, TURN_STATIC_AUTH_SECRET="t00-short-for-a-relay"
        ):
            errors = infrastructure_secrets_are_strong(None)

        assert "t00-short-for-a-relay" not in " ".join(error.msg for error in errors)
