"""What the one token verifier accepts, and what it refuses.

`api.auth` is the only issuer and the only verifier in the system. These cover the
HTTP surface; the other reader of the same two functions is the WebSocket gateway,
and that a token this surface revokes is dead on the socket is proven in
`realtime/tests/test_revoke_close.py` and `realtime/tests/test_auth.py`.
"""

import base64
import json
import uuid
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from django.conf import settings

from api.auth import issue_register_scope, issue_session
from devices.models import Device

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

DIRECTORY_URL = "/api/v1/users"
DEVICES_URL = "/api/v1/me/devices"
PROFILE_URL = "/api/v1/me/profile"
KEYBACKUP_URL = "/api/v1/me/keybackup"


def signed(claims):
    return jwt.encode(claims, settings.JWT_SIGNING_KEY, algorithm="HS256")


def live_claims(user, device, **overrides):
    issued = datetime.now(timezone.utc)
    claims = {
        "user_id": str(user.id),
        "device_id": str(device.id),
        "tgen": device.token_generation,
        "typ": "session",
        "jti": uuid.uuid4().hex,
        "iat": issued,
        "exp": issued + timedelta(days=30),
    }
    claims.update(overrides)
    return claims


def unsigned(claims):
    """An `alg: none` token: a header, a payload, and an empty signature."""

    def segment(obj):
        raw = json.dumps(obj, default=str).encode()
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    return f"{segment({'alg': 'none', 'typ': 'JWT'})}.{segment(claims)}."


def token(raw):
    return {"Authorization": f"Bearer {raw}"}


def test_a_live_device_token_is_accepted(http, active_user, device):
    access, _expires_in = issue_session(active_user, device)

    assert http.get(DIRECTORY_URL, headers=token(access)).status_code == 200


def test_revoking_a_device_rejects_its_outstanding_session_token(
    http, active_user, device
):
    access, _expires_in = issue_session(active_user, device)
    device.revoked_date = "2026-01-01"
    device.save(update_fields=["revoked_date"])

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"


def test_bumping_token_generation_rejects_outstanding_session_tokens(
    http, active_user, device
):
    access, _expires_in = issue_session(active_user, device)
    device.token_generation += 1
    device.save(update_fields=["token_generation"])

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"


def test_deleting_the_device_rejects_its_token(http, active_user, device):
    access, _expires_in = issue_session(active_user, device)
    device.delete()

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"


def test_deactivating_the_account_rejects_its_tokens(http, active_user, device):
    access, _expires_in = issue_session(active_user, device)
    active_user.is_active = False
    active_user.save(update_fields=["is_active"])

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"


@pytest.mark.parametrize(
    "method, url",
    [
        ("GET", DIRECTORY_URL),
        ("GET", "/api/v1/users/11111111-1111-1111-1111-111111111111/profile"),
        ("GET", PROFILE_URL),
        ("PUT", PROFILE_URL),
        ("GET", KEYBACKUP_URL),
        ("PUT", KEYBACKUP_URL),
        ("POST", "/api/v1/auth/logout"),
    ],
)
def test_register_scope_reaches_no_moved_route(http, active_user, method, url):
    """A register-scope token is authentic; the scope check is what holds the
    line, and it holds before any database read happens."""
    response = http.request(
        method, url, headers=token(issue_register_scope(active_user)[0])
    )

    assert response.status_code == 403
    assert response.json()["code"] == "scope_forbidden"


def test_anonymous_requests_are_refused_with_a_challenge(http):
    response = http.get(DIRECTORY_URL)

    assert response.status_code == 401
    assert response.json()["code"] == "unauthenticated"
    assert response.headers["www-authenticate"] == "Bearer"


@pytest.mark.parametrize("header", ["", "Bearer", "Bearer ", "Token abc", "abc"])
def test_a_malformed_authorization_header_is_unauthenticated(http, header):
    response = http.get(DIRECTORY_URL, headers={"Authorization": header})

    assert response.status_code == 401
    assert response.json()["code"] == "unauthenticated"


def test_a_garbage_token_is_an_invalid_token(http):
    response = http.get(DIRECTORY_URL, headers=token("not-a-jwt"))

    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


def test_an_expired_token_is_refused(http, active_user, device):
    expired = datetime.now(timezone.utc) - timedelta(minutes=1)
    access = signed(live_claims(active_user, device, exp=expired))

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


def test_an_unsigned_token_is_refused(http, active_user, device):
    """Pinning the algorithm list at decode is what stops `alg: none`."""
    response = http.get(
        DIRECTORY_URL, headers=token(unsigned(live_claims(active_user, device)))
    )

    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


# The point of the token below is the algorithm, not the key length PyJWT warns
# about: it is signed with this deployment's own HS256 key.
@pytest.mark.filterwarnings("ignore:The HMAC key is")
def test_a_token_signed_with_another_algorithm_is_refused(http, active_user, device):
    """The decode pins one algorithm. A verifier that accepts whatever the header
    names lets an attacker choose the family the signature is checked against."""
    access = jwt.encode(
        live_claims(active_user, device), settings.JWT_SIGNING_KEY, algorithm="HS512"
    )

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


def test_a_token_signed_with_another_key_is_refused(http, active_user, device):
    access = jwt.encode(
        live_claims(active_user, device),
        "a-different-signing-key-of-at-least-32-bytes",
        algorithm="HS256",
    )

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


@pytest.mark.parametrize(
    "claim", ["exp", "iat", "jti", "typ", "user_id", "device_id", "tgen"]
)
def test_a_token_missing_a_required_claim_is_refused(http, active_user, device, claim):
    """The library skips a check on an absent claim, so a decode without the
    require list would accept a token that simply omits what the code reads."""
    claims = live_claims(active_user, device)
    del claims[claim]

    response = http.get(DIRECTORY_URL, headers=token(signed(claims)))

    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


@pytest.mark.parametrize("typ", ["root", "access", "refresh", "", 7, None])
def test_an_unknown_token_type_is_refused(http, active_user, device, typ):
    """`typ` is what carries the power of a token now that no scope claim does,
    so a value outside the two this issuer mints is refused at the parser rather
    than interpreted anywhere below it."""
    access = signed(live_claims(active_user, device, typ=typ))

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


def test_a_register_token_that_names_a_device_still_reaches_no_session_route(
    http, active_user, device
):
    """The two powers are separated by `typ` alone, so a forged register token
    carrying the device binding of a session token must not pass for one."""
    access = signed(live_claims(active_user, device, typ="register"))

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 403
    assert response.json()["code"] == "scope_forbidden"


def test_a_token_cannot_name_another_accounts_device(http, active_user, device, bob):
    """The device is looked up by (id, user_id) together, so a token that names a
    device it does not own finds no row."""
    access = signed(live_claims(bob, device))

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"


def test_a_token_whose_generation_runs_ahead_of_the_row_is_refused(
    http, active_user, device
):
    """The check is equality, not `>=`: a forged claim that names a generation the
    row has not reached yet would otherwise survive every future revocation."""
    access = signed(live_claims(active_user, device, tgen=device.token_generation + 1))

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"


def test_a_token_naming_a_device_that_never_existed_is_refused(http, active_user, device):
    access = signed(live_claims(active_user, device, device_id=str(uuid.uuid4())))

    response = http.get(DIRECTORY_URL, headers=token(access))

    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"


def test_revoking_one_device_leaves_the_other_devices_token_alive(
    http, active_user, device
):
    """Revocation is per device, and the account's other sessions are not part of
    it: the counter that dies is the one on the revoked row."""
    second = Device.objects.create(
        user=active_user,
        ik_pub=b"ik",
        spk_id=2,
        spk_pub=b"spk",
        spk_sig=b"sig",
        registration_id=3003,
    )
    revoked_access, _ = issue_session(active_user, device)
    surviving_access, _ = issue_session(active_user, second)
    device.revoked_date = "2026-01-01"
    device.save(update_fields=["revoked_date"])

    assert http.get(DIRECTORY_URL, headers=token(revoked_access)).status_code == 401
    assert http.get(DIRECTORY_URL, headers=token(surviving_access)).status_code == 200


@pytest.mark.parametrize("scheme", ["Bearer", "bearer", "BEARER", "BeArEr"])
def test_the_bearer_scheme_is_matched_case_insensitively(
    http, active_user, device, scheme
):
    """RFC 7235 makes the scheme case-insensitive, and a client that sends it in
    lower case is not an attacker."""
    access, _expires_in = issue_session(active_user, device)

    response = http.get(DIRECTORY_URL, headers={"Authorization": f"{scheme} {access}"})

    assert response.status_code == 200


def test_padding_around_the_token_is_ignored(http, active_user, device):
    access, _expires_in = issue_session(active_user, device)

    response = http.get(DIRECTORY_URL, headers={"Authorization": f"Bearer   {access}  "})

    assert response.status_code == 200
