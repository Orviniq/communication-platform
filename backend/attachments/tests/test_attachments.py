"""The attachment store: the capability id is the only gate."""

import pytest

from attachments.models import Attachment
from attachments.services import purge
from core.buckets import ATTACHMENT_BUCKETS

UPLOAD_URL = "/api/v1/attachments"
SMALLEST = min(ATTACHMENT_BUCKETS)

# transaction=True because the upload runs its unit of work through the ORM
# bracket of `api.orm.run_unit`, which closes the connection a wrapping test
# transaction would need.
pytestmark = pytest.mark.django_db(transaction=True)


def upload(http, headers, payload=None, size=SMALLEST):
    body = payload if payload is not None else b"\x01" * size
    return http.post(UPLOAD_URL, files={"blob": ("blob", body)}, headers=headers)


def test_an_upload_returns_a_43_char_capability_id(
    http, active_user, device, bearer, attachments_root
):
    resp = upload(http, bearer(active_user, device))

    assert resp.status_code == 201
    body = resp.json()
    assert len(body["attachment_id"]) == 43
    assert body["size"] == SMALLEST
    attachment = Attachment.objects.get(id=body["attachment_id"])
    # Bytes land under a two-char shard of the id, never under a client-chosen name.
    stored = attachments_root / body["attachment_id"][:2] / body["attachment_id"]
    assert stored.read_bytes() == b"\x01" * SMALLEST
    assert attachment.disk_path() == str(stored)


def test_a_multi_chunk_attachment_round_trips_byte_identically(
    http, active_user, device, bearer, attachments_root
):
    """A bucket several copy chunks long, so the stored file proves the loop and
    not just its first pass."""
    size = next(b for b in sorted(ATTACHMENT_BUCKETS) if b > SMALLEST)
    payload = bytes(range(256)) * (size // 256)

    cap = upload(http, bearer(active_user, device), payload=payload).json()

    assert cap["size"] == size
    stored = attachments_root / cap["attachment_id"][:2] / cap["attachment_id"]
    assert stored.read_bytes() == payload


def test_capability_ids_are_unguessable_and_distinct(http, active_user, device, bearer):
    first = upload(http, bearer(active_user, device)).json()["attachment_id"]
    second = upload(http, bearer(active_user, device)).json()["attachment_id"]

    assert first != second
    # base64url of 32 random bytes: no padding, no path separators.
    for cap in (first, second):
        assert "/" not in cap and "+" not in cap and "=" not in cap


def test_an_off_bucket_upload_is_rejected(
    http, active_user, device, bearer, attachments_root
):
    resp = upload(http, bearer(active_user, device), payload=b"\x01" * (SMALLEST - 1))

    assert resp.status_code == 400
    assert resp.json() == {"code": "bad_bucket", "detail": "Invalid payload."}
    assert Attachment.objects.count() == 0
    # Refused before anything reached the disk, so no file is left behind either.
    assert list(attachments_root.rglob("*")) == []


def test_a_missing_file_is_an_invalid_request(http, active_user, device, bearer):
    resp = http.post(
        UPLOAD_URL,
        files={"wrong": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 400
    assert resp.json()["code"] == "invalid_request"
    assert Attachment.objects.count() == 0


def test_a_json_body_is_an_invalid_request(http, active_user, device, bearer):
    """The route reads a multipart form and nothing else."""
    resp = http.post(
        UPLOAD_URL, json={"blob": "not-a-file"}, headers=bearer(active_user, device)
    )

    assert resp.status_code == 400
    assert resp.json()["code"] == "invalid_request"


def test_a_second_part_is_refused(http, active_user, device, bearer):
    """`max_files=1` with `max_fields=0`: one file part named `blob`, and nothing
    else. Without the limits Starlette admits a thousand parts, each with a spool
    file of its own."""
    resp = http.post(
        UPLOAD_URL,
        files={
            "blob": ("blob", b"\x01" * SMALLEST),
            "extra": ("extra", b"\x01" * SMALLEST),
        },
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 400
    assert resp.json()["code"] == "invalid_request"
    assert Attachment.objects.count() == 0


def test_no_error_body_echoes_the_request(http, active_user, device, bearer):
    resp = http.post(
        UPLOAD_URL,
        data={"marker": "canary-value-that-must-not-come-back"},
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 400
    assert "canary-value-that-must-not-come-back" not in resp.text


def test_the_daily_allowance_is_spent_per_account(
    http, active_user, device, bearer, settings, bob, bob_device, attachments_root
):
    """The allowance is the account's for the day, so a second account is
    unaffected — and the row that lands names neither of them."""
    settings.ATTACH_DAILY_BYTES = SMALLEST

    first = upload(http, bearer(active_user, device))
    second = upload(http, bearer(active_user, device))
    other = upload(http, bearer(bob, bob_device))

    assert first.status_code == 201
    assert second.status_code == 413
    assert second.json()["code"] == "quota_exceeded"
    assert other.status_code == 201
    assert Attachment.objects.count() == 2
    assert list(Attachment.objects.values_list("uploader_id", flat=True)) == [None, None]
    # The refused upload left no bytes: one file for each of the two rows.
    assert len([p for p in attachments_root.rglob("*") if p.is_file()]) == 2


def test_a_download_hands_the_bytes_to_nginx(http, active_user, device, bearer):
    cap = upload(http, bearer(active_user, device)).json()["attachment_id"]

    resp = http.get(f"{UPLOAD_URL}/{cap}", headers=bearer(active_user, device))

    assert resp.status_code == 200
    assert resp.headers["X-Accel-Redirect"] == f"/_protected_attachments/{cap[:2]}/{cap}"
    # Opaque bytes: fixed type, never cached. `Content-Disposition` left with the
    # web target (ADR-0020) — it steered a browser's download and the one client
    # writes the bytes to its own store.
    assert resp.headers["Content-Type"] == "application/octet-stream"
    assert resp.headers["Cache-Control"] == "private, no-store"
    assert "Content-Disposition" not in resp.headers
    # This process hands the path over; it never streams the bytes itself.
    assert resp.content == b""


def test_any_authenticated_user_may_fetch_by_capability(
    http, active_user, device, bearer, bob, bob_device
):
    """The unguessable id is the access control; a per-recipient ACL would rebuild
    the conversation graph."""
    cap = upload(http, bearer(active_user, device)).json()["attachment_id"]

    resp = http.get(f"{UPLOAD_URL}/{cap}", headers=bearer(bob, bob_device))

    assert resp.status_code == 200


@pytest.mark.parametrize("missing", ["a" * 43, "nope", "..", "%2e%2e%2fetc%2fpasswd"])
def test_an_unknown_capability_is_a_404(http, active_user, device, bearer, missing):
    resp = http.get(f"{UPLOAD_URL}/{missing}", headers=bearer(active_user, device))

    assert resp.status_code == 404
    assert resp.json()["code"] == "not_found"
    assert "X-Accel-Redirect" not in resp.headers


def test_anonymous_access_is_rejected(http, active_user, device, bearer):
    cap = upload(http, bearer(active_user, device)).json()["attachment_id"]

    assert http.post(UPLOAD_URL, files={"blob": ("blob", b"")}).status_code == 401
    assert http.get(f"{UPLOAD_URL}/{cap}").status_code == 401


def test_a_register_scope_token_cannot_upload_or_download(
    http, active_user, device, bearer, register_bearer
):
    cap = upload(http, bearer(active_user, device)).json()["attachment_id"]
    register = register_bearer(active_user)

    assert upload(http, register).status_code == 403
    assert http.get(f"{UPLOAD_URL}/{cap}", headers=register).status_code == 403


def test_the_model_stores_no_recipient_or_acl_data():
    names = {f.name for f in Attachment._meta.get_fields()}

    assert names == {"id", "uploader", "size", "created_date"}


def test_a_nul_byte_in_a_capability_id_is_a_404(http, active_user, device, bearer):
    """PostgreSQL text carries no NUL, so the lookup is refused rather than
    answered, and without the guard the route raises instead of answering (AR-10).
    A capability id is base64url of 32 random bytes, so no stored id can hold one:
    an id carrying it is an id nobody has."""
    resp = http.get(f"{UPLOAD_URL}/a%00b", headers=bearer(active_user, device))

    assert resp.status_code == 404
    assert resp.json() == {"code": "not_found", "detail": "No such attachment."}


def test_the_largest_bucket_round_trips_and_is_stored_at_its_exact_length(
    http, active_user, device, bearer, attachments_root
):
    """The ceiling of the surface: 64 MiB is a thousand copy chunks, and it must
    reach the disk whole and at exactly the bucket length. The route cap sits just
    above it, so this is also the largest body the cap admits."""
    largest = max(ATTACHMENT_BUCKETS)
    payload = bytes(range(256)) * (largest // 256)

    cap = upload(http, bearer(active_user, device), payload=payload).json()

    assert cap["size"] == largest
    stored = attachments_root / cap["attachment_id"][:2] / cap["attachment_id"]
    assert stored.stat().st_size == largest
    assert stored.read_bytes() == payload


def test_two_uploads_of_identical_bytes_never_share_a_file_or_a_capability(
    http, active_user, device, bearer, bob, bob_device, attachments_root
):
    """No deduplication, and no shared-blob link at rest: identical ciphertext from
    two accounts is two capabilities over two files. A shared file would tell an
    operator with the disk that these two accounts hold the same object."""
    payload = b"\x07" * SMALLEST

    mine = upload(http, bearer(active_user, device), payload=payload).json()
    theirs = upload(http, bearer(bob, bob_device), payload=payload).json()

    assert mine["attachment_id"] != theirs["attachment_id"]
    stored = [path for path in attachments_root.rglob("*") if path.is_file()]
    assert len(stored) == 2
    assert {path.read_bytes() for path in stored} == {payload}


def test_the_upload_response_names_the_capability_and_nothing_about_the_account(
    http, active_user, device, bearer
):
    """The body a recipient's sender copies into an encrypted message: two fields,
    and no uploader, no path and no account anywhere in the response."""
    response = upload(http, bearer(active_user, device))

    assert set(response.json()) == {"attachment_id", "size"}
    assert active_user.username not in response.text
    assert str(active_user.id) not in response.text


def test_a_retried_upload_stores_a_second_capability_that_also_fetches(
    http, active_user, device, bearer
):
    """Documented in `attachments/API.md`: the upload is not idempotent, because
    nothing links an attachment to a message. The client that lost the first
    response holds an id it will never use, and both remain fetchable."""
    headers = bearer(active_user, device)
    payload = b"\x09" * SMALLEST

    first = upload(http, headers, payload=payload).json()["attachment_id"]
    second = upload(http, headers, payload=payload).json()["attachment_id"]

    assert first != second
    assert http.get(f"{UPLOAD_URL}/{first}", headers=headers).status_code == 200
    assert http.get(f"{UPLOAD_URL}/{second}", headers=headers).status_code == 200


def test_a_purged_attachment_stops_answering_for_everyone(
    http, active_user, device, bearer, bob, bob_device, attachments_root
):
    """The end of an attachment's life, driven the way the operator's action and
    the retention sweep both drive it: the row and the bytes go together, and the
    capability that was fetchable a moment ago is now an id nobody has."""
    headers = bearer(active_user, device)
    cap = upload(http, headers).json()["attachment_id"]
    assert http.get(f"{UPLOAD_URL}/{cap}", headers=headers).status_code == 200

    purge(Attachment.objects.filter(id=cap))

    assert http.get(f"{UPLOAD_URL}/{cap}", headers=headers).status_code == 404
    assert http.get(f"{UPLOAD_URL}/{cap}", headers=bearer(bob, bob_device)).json() == {
        "code": "not_found",
        "detail": "No such attachment.",
    }
    assert [path for path in attachments_root.rglob("*") if path.is_file()] == []
