"""Nothing on the account paths logs a name, a password, an identifier or a token.

accounts is the app that handles the two values a person types, so invariant 6 has
the most to lose here: a username in a log line is a directory at rest, and a
password in one is the account itself.

The capture replaces every handler, so the configured `ScrubFilter` never runs on
what it collects. That is deliberate, and it is why `caplog` is not used here: the
filter mutates the record in place on the console handler, so any capture that runs
after it grades the scrubber rather than the code. The scrubber is a backstop; what
these tests assert is that nothing is emitted in the first place, and
`core/tests/test_scrub.py` covers the filter itself.
"""

import base64
import logging

import pytest

from accounts.models import User
from core.buckets import PROFILE_BUCKETS
from core.lockout import FAILURE_THRESHOLD
from devices.models import Device
from ops.audit.log_silence import capture_all_logging

pytestmark = pytest.mark.django_db(transaction=True)

# Distinctive on purpose: every assertion below is a substring search, so a value
# that could occur by chance in a log line would pass for the wrong reason.
NAME = "canary_9317"
SECRET = "loud-canary-passphrase-9317"
REGISTER_URL = "/api/v1/auth/register"
LOGIN_URL = "/api/v1/auth/login"
RENEW_URL = "/api/v1/auth/renew"
LOGOUT_URL = "/api/v1/auth/logout"
LOOKUP_URL = "/api/v1/users/lookup"
DISCOVERABILITY_URL = "/api/v1/me/discoverability"
MY_PROFILE_URL = "/api/v1/me/profile"


def assert_absent(lines, forbidden):
    for line in lines:
        for label, secret in forbidden.items():
            assert secret not in line, f"{label} leaked into a log line: {line[:160]}"


def profile_blob(fill=b"\xc3"):
    return base64.b64encode(fill * PROFILE_BUCKETS[0]).decode()


def test_the_whole_account_lifecycle_emits_no_name_password_or_token(http):
    """Register, activate, log in twice, rotate, write and read a profile, find
    the account by its name, hide it, miss it, log out. Every value any of those
    calls generated is then searched for in every line the run emitted."""
    with capture_all_logging() as lines:
        registered = http.post(REGISTER_URL, json={"username": NAME, "password": SECRET})
        user_id = registered.json()["user_id"]
        User.objects.filter(id=user_id).update(is_active=True)
        first = http.post(LOGIN_URL, json={"username": NAME, "password": SECRET})
        device = Device.objects.create(
            user_id=user_id,
            ik_pub=b"ik-public",
            spk_id=1,
            spk_pub=b"spk-public",
            spk_sig=b"spk-signature",
            registration_id=7788,
        )
        full = http.post(
            LOGIN_URL,
            json={"username": NAME, "password": SECRET, "device_id": str(device.id)},
        )
        auth = {"Authorization": f"Bearer {full.json()['token']}"}
        renewed = http.post(RENEW_URL, headers=auth)
        blob = profile_blob()
        written = http.put(
            MY_PROFILE_URL, json={"blob": blob, "version": 1}, headers=auth
        )
        http.get(MY_PROFILE_URL, headers=auth)
        http.get(f"/api/v1/users/{user_id}/profile", headers=auth)
        found = http.post(LOOKUP_URL, headers=auth, json={"username": NAME})
        hidden = http.put(DISCOVERABILITY_URL, headers=auth, json={"discoverable": False})
        http.get(DISCOVERABILITY_URL, headers=auth)
        missed = http.post(LOOKUP_URL, headers=auth, json={"username": NAME})
        loggedout = http.post(LOGOUT_URL, headers=auth)

    assert (registered.status_code, written.status_code) == (201, 200)
    assert (renewed.status_code, loggedout.status_code) == (200, 204)
    assert (found.status_code, hidden.status_code, missed.status_code) == (200, 200, 404)
    assert_absent(
        lines,
        {
            "username": NAME,
            "password": SECRET,
            "user id": user_id,
            "device id": str(device.id),
            "register-scope token": first.json()["token"],
            "session token": full.json()["token"],
            "renewed session token": renewed.json()["token"],
            "profile blob": blob,
        },
    )


def test_no_account_request_puts_its_path_in_a_log_line(
    http, active_user, device, bearer
):
    """The other half of invariant 6: no access log exists, so not even the route
    a request reached may be recovered from the log stream."""
    with capture_all_logging() as lines:
        http.post(LOGIN_URL, json={"username": "alice", "password": SECRET})
        http.post(
            LOOKUP_URL, headers=bearer(active_user, device), json={"username": "alice"}
        )
        http.get(DISCOVERABILITY_URL, headers=bearer(active_user, device))
        http.get(MY_PROFILE_URL, headers=bearer(active_user, device))

    for line in lines:
        assert "/api/v1/" not in line, f"a request path reached a log line: {line[:160]}"


def test_a_refused_and_then_locked_sign_in_never_names_the_account(http, active_user):
    """The failure path is the one an attacker drives, so it is the one most likely
    to be logged: neither the refusals nor the lock that follows them may name the
    account they were about."""
    with capture_all_logging() as lines:
        refusals = [
            http.post(LOGIN_URL, json={"username": "alice", "password": SECRET})
            for _ in range(FAILURE_THRESHOLD)
        ]
        locked = http.post(LOGIN_URL, json={"username": "alice", "password": SECRET})

    assert {response.status_code for response in refusals} == {401}
    assert locked.status_code == 429
    assert_absent(lines, {"username": "alice", "password": SECRET})


def test_rejected_input_is_not_echoed_into_the_logs(
    http, active_user, device, bearer, register_bearer
):
    """The refusal paths must not log what they refused: an off-bucket payload, a
    name that failed the shape rule, or a token that failed to verify."""
    off_bucket = base64.b64encode(b"q" * 77).decode()
    bad_name = "canary" + "\x00" + "9317"
    garbage_token = "not-a-jwt-canary-9317"

    with capture_all_logging() as lines:
        rejected = http.put(
            MY_PROFILE_URL,
            json={"blob": off_bucket, "version": 1},
            headers=bearer(active_user, device),
        )
        refused_name = http.post(
            REGISTER_URL, json={"username": bad_name, "password": SECRET}
        )
        bad_token = http.get(
            DISCOVERABILITY_URL, headers={"Authorization": f"Bearer {garbage_token}"}
        )
        scoped_out = http.get(DISCOVERABILITY_URL, headers=register_bearer(active_user))

    assert rejected.status_code == 400
    assert refused_name.status_code == 400
    assert bad_token.status_code == 401
    assert scoped_out.status_code == 403
    assert_absent(
        lines,
        {
            "off-bucket payload": off_bucket,
            "refused username": "canary",
            "rejected token": garbage_token,
            "caller id": str(active_user.id),
        },
    )


def test_the_capture_is_live_and_unscrubbed(active_user):
    """Guards the guards above. A clean request logs nothing at all, so a loop over
    an empty list would pass no matter what the code emitted; and a capture that ran
    behind the console handler would read `[ID]` where the leak was, and pass for the
    second wrong reason."""
    with capture_all_logging() as lines:
        logging.getLogger("accounts.tests.canary").debug(
            "account %s signed in with %s", active_user.username, SECRET
        )

    assert any(SECRET in line and "alice" in line for line in lines)


def test_no_lookup_puts_the_name_it_was_asked_for_in_a_log_line(
    http, active_user, device, bearer, settings, one_rate_limit_window
):
    """The lookup is the one authenticated route whose input is a name, and a name
    in a log line is the who-looked-for-whom record the route exists to avoid. Every
    outcome is driven — found, unknown, hidden, refused by shape, throttled — and
    none may emit the name it was given or the id it answered."""
    found_name, unknown_name, hidden_name = (
        "canary_found",
        "canary_unknown",
        "canary_hide",
    )
    found = User.objects.create_user(username=found_name, is_active=True)
    User.objects.create_user(username=hidden_name, is_active=True, discoverable=False)
    headers = bearer(active_user, device)
    # Four answers and then the refusal, all inside one pinned window.
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "lookup": "4/day"}

    with capture_all_logging() as lines:
        answers = [
            http.post(LOOKUP_URL, headers=headers, json={"username": name}).status_code
            for name in (found_name, unknown_name, hidden_name, "canary refused")
        ]
        throttled = http.post(LOOKUP_URL, headers=headers, json={"username": found_name})

    assert answers == [200, 404, 404, 400]
    assert throttled.status_code == 429
    assert_absent(
        lines,
        {
            "found name": found_name,
            "unknown name": unknown_name,
            "hidden name": hidden_name,
            "refused name": "canary refused",
            "found id": str(found.id),
            "caller id": str(active_user.id),
        },
    )
