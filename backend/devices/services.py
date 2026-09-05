"""The synchronous units of work behind the devices routes.

Each function opens its own transaction where it needs one, and never awaits. No
released Django has an async transaction, and a unit that awaited would hold its
row lock while other work ran on the same thread.
"""

import base64
import hashlib

from django.conf import settings
from django.db import transaction
from django.db.models import Max
from django.utils import timezone

from accounts.models import User
from api.auth import issue_session
from api.errors import ApiError
from devices.models import (
    Device,
    DeviceLogRecord,
    OneTimePrekey,
    PqOneTimePrekey,
    UserIdentity,
)
from devices.schemas import MAX_STORED_OTPKS, MAX_STORED_PQ_OTPKS

NOT_FOUND = "No such device."


def _b64(value):
    return base64.b64encode(bytes(value)).decode()


def _b64_or_none(value):
    return _b64(value) if value else None


def _stale_version():
    return ApiError(409, "stale_version", "Version must increase.")


def _device_list_etag(user_id):
    """One query over the account's live device set, one over its log head.
    Returns (etag, log_head_seq) so callers surface the head without re-querying.

    Live-only on purpose: hashing revoked rows too would still change the tag on
    every add/remove/revoke, but it would also give an account whose devices were
    all revoked a different tag from an account that never had any, while both
    serve the same empty list. Any authenticated peer can read that difference,
    and it leaks device churn the peer list deliberately hides.

    `user__is_active` matches the peer view's filter: without it a deactivation
    would leave the tag unchanged and every polling peer would sit on a 304
    holding devices the list no longer returns. The log-head query carries the
    same filter for the same reason.

    The head record's blob hash is an input alongside the live device id set: a
    log append must change the tag, or a polling peer would sit on a 304 and
    never see the new head it is supposed to gossip.
    """
    rows = list(
        Device.objects.filter(
            user_id=user_id, user__is_active=True, revoked_date__isnull=True
        )
        .values_list("id", flat=True)
        .order_by("id")
    )
    head = (
        DeviceLogRecord.objects.filter(user_id=user_id, user__is_active=True)
        .order_by("-seq")
        .values_list("seq", "blob")
        .first()
    )
    head_hash = hashlib.sha256(bytes(head[1])).hexdigest() if head else None
    digest = hashlib.sha256(repr((rows, head_hash)).encode()).hexdigest()
    return f'"{digest[:32]}"', (head[0] if head else None)


def publish_identity(user_id, payload):
    with transaction.atomic():
        # Lock the always-present User row, not the identity row: on the first
        # publish the identity row does not exist yet, so select_for_update() on it
        # would take no lock and two concurrent first publishes could both pass the
        # version check (the same reasoning as vault.services.write). The version
        # check itself is anti-accident — it stops a stale client clobbering a newer
        # identity — not a security control: a modified server would simply not
        # apply it, and clients must detect identity changes on their own.
        User.objects.select_for_update().filter(pk=user_id).only("id").first()
        current = (
            UserIdentity.objects.filter(user_id=user_id)
            .values_list("version", flat=True)
            .first()
        )
        if current is not None and payload.version <= current:
            raise _stale_version()
        UserIdentity.objects.update_or_create(
            user_id=user_id,
            defaults={
                "master_pub": payload.master_pub,
                "self_signing_pub": payload.self_signing_pub,
                "user_signing_pub": payload.user_signing_pub,
                "master_sig": payload.master_sig,
                "version": payload.version,
            },
        )


def peer_identity(user_id):
    """Serve a user's cross-signing identity verbatim. No smoothing, no history:
    if the stored master key changed, peers get the new bytes and must raise their
    own alarm — hiding or merging a change here would defeat exactly the check the
    clients are required to make."""
    # user__is_active matches peer_devices: a deactivated account publishes nothing.
    identity = (
        UserIdentity.objects.filter(user_id=user_id, user__is_active=True)
        .only(
            "master_pub",
            "self_signing_pub",
            "user_signing_pub",
            "master_sig",
            "version",
        )
        .first()
    )
    if identity is None:
        raise ApiError(404, "not_found", "No published identity.")
    return {
        "master_pub": _b64(identity.master_pub),
        "self_signing_pub": _b64(identity.self_signing_pub),
        "user_signing_pub": _b64(identity.user_signing_pub),
        "master_sig": _b64(identity.master_sig),
        "version": identity.version,
    }


def register_device(user, payload):
    with transaction.atomic():
        # Lock the account row, not the device rows. select_for_update() on a
        # .count() is silently dropped by Django when it builds the aggregate,
        # and even a real row lock over existing devices would not block a
        # concurrent INSERT.
        User.objects.select_for_update().filter(pk=user.id).only("id").first()
        count = Device.objects.filter(user_id=user.id, revoked_date__isnull=True).count()
        if count >= settings.MAX_DEVICES_PER_USER:
            raise ApiError(409, "device_limit", "This account has too many devices.")
        # A published identity is a precondition of registration — but only once the
        # account has a live device. The first device is exempt by necessity:
        # register-scope tokens reach exactly this endpoint, so a fresh account
        # cannot publish an identity before registering (the client publishes
        # immediately after, with the full token issued below). This is a
        # completeness check against a mis-sequenced client, NOT a security control:
        # a modified server would simply not apply it, and peers must treat a device
        # with no verifiable identity chain as unverified regardless.
        if count and not UserIdentity.objects.filter(user_id=user.id).exists():
            raise ApiError(
                400,
                "identity_required",
                "Publish a cross-signing identity before adding another device.",
            )
        pq_spk = payload.pq_spk
        device = Device.objects.create(
            user_id=user.id,
            ik_pub=payload.ik_pub,
            spk_id=payload.spk_id,
            spk_pub=payload.spk_pub,
            spk_sig=payload.spk_sig,
            registration_id=payload.registration_id,
            # cross_sig/bundle_version are not settable here and the schema refuses
            # them: the client cannot sign a bundle whose device_id this INSERT is
            # about to mint, and a later device cannot reach its self-signing key
            # without the token issued below. The row is born in the model-default
            # "never cross-signed" state (null/0) that peers already refuse, and the
            # client cross-signs via the prekeys route as its next call
            # (CLIENT_CONTRACT.md §M).
            pq_spk_id=pq_spk.spk_id if pq_spk else None,
            pq_spk_pub=pq_spk.pub if pq_spk else None,
            pq_spk_sig=pq_spk.sig if pq_spk else None,
            pq_spk_updated_date=timezone.now().date() if pq_spk else None,
            label_blob=payload.label_raw,
        )  # spk_updated_date is auto_now_add
        if payload.otpks:
            OneTimePrekey.objects.bulk_create(
                [
                    OneTimePrekey(device=device, key_id=otpk.key_id, pub=otpk.pub)
                    for otpk in payload.otpks
                ]
            )
        if payload.pq_otpks:
            PqOneTimePrekey.objects.bulk_create(
                [
                    PqOneTimePrekey(device=device, key_id=otpk.key_id, pub=otpk.pub)
                    for otpk in payload.pq_otpks
                ]
            )

    token, expires_in = issue_session(user, device)
    return {
        "device_id": str(device.id),
        "token": token,
        "expires_in": expires_in,
        "scope": "full",
    }


def own_devices(user_id, this_device_id, if_none_match):
    """The account's live devices. Returns None when the caller's tag still holds,
    which is what keeps a 304 off the list query entirely."""
    etag, log_head_seq = _device_list_etag(user_id)
    if if_none_match == etag:
        return None

    devices = (
        Device.objects.filter(user_id=user_id, revoked_date__isnull=True)
        .only(
            # created_date is day-coarse, so it alone leaves same-day devices in an
            # arbitrary order that can shuffle between polls; id breaks the tie.
            "id",
            "label_blob",
            "created_date",
            "last_active_date",
        )
        .order_by("created_date", "id")
    )
    body = {
        "devices": [
            {
                "device_id": str(device.id),
                "label_blob": _b64_or_none(device.label_blob),
                "created_date": device.created_date.isoformat(),
                "last_active_date": device.last_active_date.isoformat()
                if device.last_active_date
                else None,
                "this_device": (device.id == this_device_id),
            }
            for device in devices
        ],
        "log_head_seq": log_head_seq,
    }
    return etag, body


def peer_devices(user_id, if_none_match):
    """Public identity and registration id of another user's live devices."""
    etag, log_head_seq = _device_list_etag(user_id)
    if if_none_match == etag:
        return None

    devices = (
        Device.objects.filter(
            user_id=user_id, revoked_date__isnull=True, user__is_active=True
        )
        .only("id", "ik_pub", "registration_id", "cross_sig", "bundle_version")
        .order_by("id")
    )
    # cross_sig is surfaced verbatim, null included: a device that was never
    # cross-signed must be visible as such so peers can refuse it. Substituting or
    # defaulting anything here would forge exactly the attestation the design keeps
    # out of the server's hands.
    body = {
        "devices": [
            {
                "device_id": str(device.id),
                "ik_pub": _b64(device.ik_pub),
                "registration_id": device.registration_id,
                "cross_sig": _b64_or_none(device.cross_sig),
                "bundle_version": device.bundle_version,
            }
            for device in devices
        ],
        "etag": etag,
        "log_head_seq": log_head_seq,
    }
    return etag, body


def relabel(user_id, device_id, raw):
    """The ownership predicate is in the UPDATE, so a device of another account is
    never loaded and answers exactly as a device that does not exist."""
    updated = Device.objects.filter(
        id=device_id, user_id=user_id, revoked_date__isnull=True
    ).update(label_blob=raw)
    if not updated:
        raise ApiError(404, "not_found", NOT_FOUND)


def revoke(user_id, device_id):
    """One unit of work: the row, its tokens, its one-time key material and its
    mailbox. The socket close runs after this returns, on the committed state."""
    with transaction.atomic():
        device = (
            Device.objects.select_for_update()
            .filter(id=device_id, user_id=user_id, revoked_date__isnull=True)
            .first()
        )
        if device is None:
            raise ApiError(404, "not_found", NOT_FOUND)
        device.revoked_date = timezone.now().date()
        device.token_generation += 1  # invalidates all outstanding tokens
        device.save(update_fields=["revoked_date", "token_generation"])
        OneTimePrekey.objects.filter(device=device).delete()
        PqOneTimePrekey.objects.filter(device=device).delete()
        device.queue.all().delete()  # its mailbox


def replenish(device_id, payload):
    with transaction.atomic():
        # The device row exists (authentication proved it), so this lock is real
        # and serialises two concurrent replenishments against the stored cap.
        Device.objects.select_for_update().filter(pk=device_id).only("id").first()
        # Cap first, mutate second. The refusal raises, so the transaction rolls
        # back either way; the ordering is what makes the guarantee independent of
        # that, because a device told "409, nothing stored" must never find its
        # signed prekey rotated anyway, and peers must never fetch an spk the
        # client believes was never installed. Both caps are checked before either
        # write for the same reason.
        stored = OneTimePrekey.objects.filter(device_id=device_id).count()
        if stored + len(payload.otpks) > MAX_STORED_OTPKS:
            raise ApiError(
                409, "prekey_limit", "Too many stored one-time prekeys for this device."
            )
        if payload.pq_otpks:
            pq_stored = PqOneTimePrekey.objects.filter(device_id=device_id).count()
            if pq_stored + len(payload.pq_otpks) > MAX_STORED_PQ_OTPKS:
                raise ApiError(
                    409,
                    "prekey_limit",
                    "Too many stored PQ one-time prekeys for this device.",
                )
        # One UPDATE for the signed-bundle fields. Rotating the spk stales the
        # stored cross_sig, so a rotating client is expected to send a fresh
        # cross_sig and bundle_version in the same call; the server stores what it
        # is given and never checks the pairing — only peers can.
        bundle = {}
        if payload.spk:
            bundle.update(
                spk_id=payload.spk.spk_id,
                spk_pub=payload.spk.pub,
                spk_sig=payload.spk.sig,
                spk_updated_date=timezone.now().date(),
            )
        if payload.pq_spk:
            bundle.update(
                pq_spk_id=payload.pq_spk.spk_id,
                pq_spk_pub=payload.pq_spk.pub,
                pq_spk_sig=payload.pq_spk.sig,
                pq_spk_updated_date=timezone.now().date(),
            )
        if "cross_sig" in payload.model_fields_set:
            bundle["cross_sig"] = payload.cross_sig
            bundle["bundle_version"] = payload.bundle_version
        if bundle:
            Device.objects.filter(pk=device_id).update(**bundle)
        if payload.otpks:
            # ignore_conflicts: re-uploading a key_id the device already stored is
            # an idempotent retry, not an error.
            OneTimePrekey.objects.bulk_create(
                [
                    OneTimePrekey(device_id=device_id, key_id=otpk.key_id, pub=otpk.pub)
                    for otpk in payload.otpks
                ],
                ignore_conflicts=True,
            )
        if payload.pq_otpks:
            PqOneTimePrekey.objects.bulk_create(
                [
                    PqOneTimePrekey(device_id=device_id, key_id=otpk.key_id, pub=otpk.pub)
                    for otpk in payload.pq_otpks
                ],
                ignore_conflicts=True,
            )
        count = OneTimePrekey.objects.filter(device_id=device_id).count()
    return {"otpk_count": count}


def prekey_counts(device_id):
    return {
        "otpk_count": OneTimePrekey.objects.filter(device_id=device_id).count(),
        "pq_otpk_count": PqOneTimePrekey.objects.filter(device_id=device_id).count(),
    }


def append_log(user_id, records):
    """Append client-signed device-list log records.

    The server must not verify the hash chain: a record whose prev_hash links to
    nothing is accepted and served verbatim. Chain validation here would be fake
    enforcement — a modified server (the adversary) would simply not apply it, and
    its existence would train clients to skip the head comparison that actually
    detects equivocation. The server's whole contribution is assigning seq and
    serving bytes back unchanged.
    """
    with transaction.atomic():
        # Serialise appends for this user by locking the user row.
        User.objects.select_for_update().filter(id=user_id).only("id").first()
        current = DeviceLogRecord.objects.filter(user_id=user_id).aggregate(m=Max("seq"))[
            "m"
        ]
        start = (current if current is not None else -1) + 1
        # `seq` is contiguous from 0 and the log is never pruned, so `start` is
        # the record count. The ceiling is a storage bound: the log is append-only
        # and a client appends one record for each device-set change, so an
        # account that reaches it is growing the table on purpose.
        if start + len(records) > settings.MAX_DEVICELOG_RECORDS:
            raise ApiError(
                409, "devicelog_limit", "The device-list log of this account is full."
            )
        DeviceLogRecord.objects.bulk_create(
            [
                DeviceLogRecord(user_id=user_id, seq=start + i, blob=record.raw)
                for i, record in enumerate(records)
            ]
        )
    return {"first_seq": start, "last_seq": start + len(records) - 1}


def peer_log(user_id, after, limit):
    """Keyset-paged read of a user's device-list log, served verbatim: no repair,
    no reordering, no dropping of records that fail to link — see `append_log` for
    why the server never validates the chain."""
    base = DeviceLogRecord.objects.filter(user_id=user_id, user__is_active=True)
    rows = list(
        base.filter(seq__gt=after).order_by("seq").only("seq", "blob")[: limit + 1]
    )
    has_more = len(rows) > limit
    rows = rows[:limit]
    return {
        "records": [{"seq": row.seq, "blob": _b64(row.blob)} for row in rows],
        "has_more": has_more,
        "head_seq": base.aggregate(m=Max("seq"))["m"],
    }


def _take_one_each(model, device_ids):
    """One one-time prekey per device, locked and then deleted in one statement.

    `skip_locked` is what makes a key single-consumption: a concurrent claim never
    waits on the row this transaction holds, it takes the next one instead. The
    delete is hoisted out of the loop because the locks are already held, so a row
    picked here cannot move until this transaction ends.
    """
    taken = {}
    consumed = []
    for device_id in device_ids:
        row = (
            model.objects.select_for_update(skip_locked=True)
            .filter(device_id=device_id)
            .order_by("key_id")
            .first()
        )
        if row is not None:
            taken[device_id] = {"key_id": row.key_id, "pub": _b64(row.pub)}
            consumed.append(row.id)
    if consumed:
        # By primary key, never by (device, key_id) sets: two devices that happen
        # to hold the same key_id would make that pair of filters a cross product
        # and delete keys this call never handed out.
        model.objects.filter(id__in=consumed).delete()
    return taken


def claim(user_id, device_ids):
    """One X3DH bundle per requested live device, consuming one one-time prekey
    each. One call is one transaction, so a bundle and the key it carries are
    committed together or not at all."""
    with transaction.atomic():
        targets = Device.objects.filter(
            user_id=user_id, revoked_date__isnull=True, user__is_active=True
        )
        # Presence, not truthiness: an explicit `device_ids: []` asks for no
        # devices. Treating it as "all" would silently burn a one-time prekey on
        # every device.
        if device_ids is not None:
            targets = targets.filter(id__in=device_ids)
        targets = list(
            targets.only(
                "id",
                "registration_id",
                "ik_pub",
                "spk_id",
                "spk_pub",
                "spk_sig",
                "cross_sig",
                "bundle_version",
                "pq_spk_id",
                "pq_spk_pub",
                "pq_spk_sig",
            ).order_by("id")
        )
        otpks = _take_one_each(OneTimePrekey, [device.id for device in targets])
        # A PQ one-time prekey is only consumed alongside the signed PQ prekey:
        # without pq_spk the bundle is classical-only anyway, and burning a stored
        # PQ key for it would waste the key without ever serving PQ material.
        pq_otpks = _take_one_each(
            PqOneTimePrekey, [device.id for device in targets if device.pq_spk_pub]
        )

    bundles = []
    for device in targets:
        bundle = {
            "device_id": str(device.id),
            "registration_id": device.registration_id,
            "ik_pub": _b64(device.ik_pub),
            "spk_id": device.spk_id,
            "spk_pub": _b64(device.spk_pub),
            "spk_sig": _b64(device.spk_sig),
            # Verbatim, null included — an unsigned device must look unsigned.
            "cross_sig": _b64_or_none(device.cross_sig),
            "bundle_version": device.bundle_version,
        }
        # When a device holds no PQ material the PQ fields are omitted entirely,
        # never defaulted or zero-filled: a classical-only bundle must be visibly
        # classical-only. Deciding whether to refuse it or flag the session is the
        # client's job (CLIENT_CONTRACT.md) — quietly making the bundle look
        # complete here would remove exactly the signal that decision needs.
        if device.pq_spk_pub:
            bundle["pq_spk_id"] = device.pq_spk_id
            bundle["pq_spk_pub"] = _b64(device.pq_spk_pub)
            bundle["pq_spk_sig"] = _b64(device.pq_spk_sig)
            if device.id in pq_otpks:
                bundle["pq_otpk"] = pq_otpks[device.id]
        if device.id in otpks:
            bundle["otpk"] = otpks[device.id]
        bundles.append(bundle)
    return {"bundles": bundles}
