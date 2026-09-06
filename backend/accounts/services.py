"""The synchronous units of work behind the accounts routes.

Each function opens its own transaction and never awaits. No released Django has
an async transaction, and a unit that awaited would hold its row lock while other
work ran on the same thread.
"""

import base64

from django.contrib.auth.hashers import check_password, make_password
from django.db import IntegrityError, transaction
from django.db.models import F

from accounts.models import ProfileBlob, User
from api.auth import issue_register_scope, issue_session
from api.errors import ApiError
from core import lockout
from devices.models import Device
from realtime.bus import close_device_sockets

INVALID_CREDENTIALS = "Username or password is incorrect."
NAME_LOCKED = "Too many sign-in attempts for this name. Wait and try again."

# A fixed invalid hash so an unknown-username login still spends Argon2 time.
DUMMY_HASH = make_password("timing-equalizer-not-a-real-password")


def _stale_version():
    return ApiError(409, "stale_version", "Version must increase.")


def _profile_body(profile):
    return {
        "blob": base64.b64encode(bytes(profile.blob)).decode(),
        "version": profile.version,
    }


def register(username, password):
    """Create the account in the inactive state; the owner activates it."""
    try:
        with transaction.atomic():
            user = User.objects.create_user(username=username, password=password)
    except IntegrityError:
        # The unique index is what settles two concurrent registrations on one
        # name. A prior existence probe would add a query and still race.
        raise ApiError(409, "username_taken", "That username is taken.")
    return {"user_id": str(user.id)}


def _live_device(user_id, device_id):
    """The account's live device of that id, or None.

    A login writes nothing: it mints a token at the generation the row already
    carries, so a second login neither retires the first one's token nor needs a
    lock to decide the order of the two.
    """
    return (
        Device.objects.filter(id=device_id, user_id=user_id, revoked_date__isnull=True)
        .only("id", "token_generation")
        .first()
    )


def login(username, password, device_id):
    # The cool-off is checked before the password is hashed, so a locked name
    # buys no Argon2 work, and it fails closed like the address limiter above it.
    try:
        wait = lockout.locked_for(username, lockout.API)
    except lockout.LockoutUnavailable:
        raise ApiError(503, "unavailable", "The service is temporarily unavailable.")
    if wait:
        raise ApiError(429, "throttled", NAME_LOCKED, {"Retry-After": str(wait)})
    if "\x00" in username:
        # PostgreSQL text carries no NUL, so psycopg refuses the lookup outright
        # rather than returning no row, and the route answers an unauthenticated
        # 500 without this. `RegisterIn` refuses the byte, so no stored name can
        # hold one: a name carrying it is a name nobody has, which is the branch
        # below. Deliberately not a `400` — `LoginIn` documents that a badly
        # shaped name is wrong credentials rather than a malformed request, and
        # answering otherwise here would tell an anonymous caller which names the
        # column could have held.
        user = None
    else:
        user = (
            User.objects.filter(username=username)
            .only("id", "password", "is_active")
            .first()
        )
    if user is None:
        check_password(password, DUMMY_HASH)  # equalize timing
        lockout.note_failure(username, lockout.API)
        raise ApiError(401, "invalid_credentials", INVALID_CREDENTIALS)
    # user.check_password (not the bare function) carries the setter that
    # transparently re-hashes when the configured Argon2 cost changes.
    if not user.check_password(password):
        lockout.note_failure(username, lockout.API)
        raise ApiError(401, "invalid_credentials", INVALID_CREDENTIALS)
    lockout.clear(username, lockout.API)
    # Only once the password is proven does activation state become observable.
    if not user.is_active:
        raise ApiError(403, "account_inactive", "This account is awaiting activation.")

    device = _live_device(user.id, device_id) if device_id else None
    if device is None:
        # No device, or one this account does not own: a short register-scope
        # token whose only power is POST /me/devices.
        token, expires_in = issue_register_scope(user)
        return {
            "token": token,
            "expires_in": expires_in,
            "user_id": str(user.id),
            "scope": "register",
        }
    token, expires_in = issue_session(user, device)
    return {
        "token": token,
        "expires_in": expires_in,
        "user_id": str(user.id),
        "device_id": str(device.id),
        "scope": "full",
    }


def logout(user_id, device_id):
    """End the session: every token of the device dies and its sockets drop."""
    Device.objects.filter(id=device_id, user_id=user_id).update(
        token_generation=F("token_generation") + 1
    )
    close_device_sockets(device_id)


def directory():
    """Every activated account, ordered by username. This is a small private
    server and the directory is how clients pick conversation partners."""
    return {
        "users": [
            {"user_id": str(row["id"]), "username": row["username"]}
            for row in User.objects.filter(is_active=True)
            .order_by("username")
            .values("id", "username")
        ]
    }


def peer_profile(user_id):
    profile = (
        ProfileBlob.objects.filter(user_id=user_id, user__is_active=True)
        .only("blob", "version")
        .first()
    )
    if profile is None:
        raise ApiError(404, "not_found", "No profile for that user.")
    return _profile_body(profile)


def my_profile(user_id):
    profile = ProfileBlob.objects.filter(user_id=user_id).only("blob", "version").first()
    if profile is None:
        raise ApiError(404, "not_found", "No profile yet.")
    return _profile_body(profile)


def write_profile(user_id, raw, version):
    try:
        with transaction.atomic():
            # .only("version"): the locked read exists to compare versions, so
            # the stored blob is not dragged back with it. Branching here rather
            # than calling update_or_create avoids a second identical SELECT.
            profile = (
                ProfileBlob.objects.select_for_update()
                .filter(user_id=user_id)
                .only("version")
                .first()
            )
            if profile is None:
                ProfileBlob.objects.create(user_id=user_id, blob=raw, version=version)
            elif version <= profile.version:
                raise _stale_version()
            else:
                profile.blob = raw
                profile.version = version
                profile.save(update_fields=["blob", "version"])
    except IntegrityError:
        # select_for_update locks nothing when the row does not exist yet, so two
        # concurrent first writes can both clear the version check above.
        raise _stale_version()
