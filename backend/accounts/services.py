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


def _refuse_a_locked_name(username):
    """The per-name cool-off, checked before any password is hashed.

    Shared by the two surfaces of this API that take a password — `POST
    /auth/login` and `DELETE /me` — so five failures on a name inside fifteen
    minutes lock it on both. A guesser who could spend the lock on one and then
    move to the other would have twice the budget the counter is written for, and
    the erasure route is the more valuable of the two to guess at.

    It fails closed like the address limiter above it: a control whose whole
    purpose is to refuse an attempt cannot answer "allow" when it cannot read its
    state (ADR-0010).
    """
    try:
        wait = lockout.locked_for(username, lockout.API)
    except lockout.LockoutUnavailable:
        raise ApiError(503, "unavailable", "The service is temporarily unavailable.")
    if wait:
        raise ApiError(429, "throttled", NAME_LOCKED, {"Retry-After": str(wait)})


def login(username, password, device_id):
    # Before the password is hashed, so a locked name buys no Argon2 work.
    _refuse_a_locked_name(username)
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


def erase(user, password):
    """Delete the account and every row that depends on it, in one transaction.

    The password is proved first, under the same per-name lockout `login` runs. A
    session token is enough to read this account and deliberately not enough to
    end it: the token lives thirty days and nothing detects its theft (AR-18), so
    the one irreversible act the API offers asks for the secret a thief does not
    have.

    `check_password` rather than `user.check_password`: the model method carries a
    setter that re-hashes when the configured Argon2 cost has moved, and a row
    this call is about to delete must not be written on its way out.

    The delete is one statement to the ORM and a cascade underneath it: the
    devices, the one-time prekeys of both kinds, the identity, the key backup, the
    device-log records, the profile blob, and every queued envelope of every
    device. Nothing is read into this process — each of those is a fast delete —
    so no ciphertext crosses the boundary on the way out. The username is free
    again the moment it commits.

    Attachments stay. `Attachment.uploader` is written by nothing and read by
    nothing (ADR-0025), so no row of that table says these bytes were this
    account's; the retention sweep removes them on its own schedule, and there is
    nothing here that could find them sooner.

    The sockets close after the commit, on state that is already gone: a device
    told `4003` while the transaction could still roll back would be a device that
    reconnects to an account that still exists.
    """
    # Both columns in one statement. The authentication requirement loads a
    # device joined to `only("id", "is_active")` of its owner, so the name and the
    # hash are deferred on the instance it hands over and reading them off it is a
    # `refresh_from_db` each — two queries for two columns of a row already read.
    username, hashed = (
        User.objects.filter(pk=user.id).values_list("username", "password").first()
    )
    _refuse_a_locked_name(username)
    if not check_password(password, hashed):
        lockout.note_failure(username, lockout.API)
        raise ApiError(401, "invalid_credentials", INVALID_CREDENTIALS)
    lockout.clear(username, lockout.API)
    with transaction.atomic():
        device_ids = list(
            Device.objects.filter(user_id=user.id, revoked_date__isnull=True).values_list(
                "id", flat=True
            )
        )
        User.objects.filter(pk=user.id).delete()
    for device_id in device_ids:
        close_device_sockets(device_id)


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
