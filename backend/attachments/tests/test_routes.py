"""What the two attachment routes do with a body, an id, or a disk they cannot use.

One rule holds across the whole surface: a refusal is the `{code, detail}`
envelope with the documented status, never a `500`, and never an echo of what the
client sent — not in the body, and not in a log line. The upload is the one
non-JSON body of this API, so its malformed class is a multipart matrix rather
than a JSON one, and the id of the download is a bare path segment that reaches
the database with no schema in front of it.

`transaction=True` because the ORM bracket of `api.orm.run_unit` closes the
connection around every unit of work, which under a wrapping test transaction
would sever the connection the test itself holds.
"""

import base64
import logging
import os
import stat
from urllib.parse import quote

import pytest
import redis
from django.conf import settings as configured
from django.db import OperationalError
from django.utils import timezone
from hypothesis import given
from hypothesis import settings as hypothesis_settings
from hypothesis import strategies as st

from api import app as api_app
from attachments import allowance
from attachments.models import Attachment
from config.asgi import api_application, application
from conftest import AsgiClient
from core.buckets import ATTACHMENT_BUCKETS
from ops.audit.log_silence import CANARY_CLOSE, CANARY_OPEN, capture_all_logging

pytestmark = pytest.mark.django_db(transaction=True)

UPLOAD_URL = "/api/v1/attachments"
SMALLEST = min(ATTACHMENT_BUCKETS)
CANARY = "canary-value-that-must-not-come-back"


def envelope(response, code):
    body = response.json()
    assert set(body) == {"code", "detail"}, body
    assert body["code"] == code, body
    return body


def files_under(root):
    return [path for path in root.rglob("*") if path.is_file()]


def spent_today(user):
    """The bytes this account has charged against today's allowance.

    Read from Redis rather than from a row, because that is the only place the
    count exists: a refund that did not happen is invisible to every assertion the
    database can make.
    """
    store = redis.Redis.from_url(configured.REDIS_URL)
    charged = store.get(allowance._key(user.id, timezone.now().date()))
    return int(charged) if charged else 0


# Every shape of upload body the route has to refuse, and none of them is a `500`.
# Each carries the canary somewhere a careless error path would read back.
MALFORMED_UPLOADS = [
    ("no body at all", {}),
    (
        "raw bytes with no multipart wrapper",
        {
            "content": b"\x01" * SMALLEST,
            "headers": {"Content-Type": "application/octet-stream"},
        },
    ),
    (
        "a multipart content type with no boundary",
        {
            "content": b"--x\r\nContent-Disposition: form-data; name=blob\r\n\r\n",
            "headers": {"Content-Type": "multipart/form-data"},
        },
    ),
    ("a text field where the file part belongs", {"data": {"blob": CANARY}}),
    ("an oversized text field", {"data": {"blob": CANARY * 400}}),
    (
        "two file parts under the one name",
        {"files": [("blob", ("a", b"\x01" * SMALLEST)), ("blob", ("b", CANARY))]},
    ),
    (
        "a file part beside a field",
        {
            "files": {"blob": ("blob", b"\x01" * SMALLEST)},
            "data": {"unknown": CANARY},
        },
    ),
    (
        "the blob base64-encoded as a field rather than sent as bytes",
        {"data": {"blob": base64.b64encode(b"\x01" * SMALLEST).decode()}},
    ),
]


def post_upload(http, auth, case):
    """One upload, with the case's own `Content-Type` over the credential."""
    case = dict(case)
    return http.post(UPLOAD_URL, headers={**auth, **case.pop("headers", {})}, **case)


@pytest.mark.parametrize(
    "case",
    [case for _label, case in MALFORMED_UPLOADS],
    ids=[label for label, _case in MALFORMED_UPLOADS],
)
def test_an_upload_body_the_route_cannot_read_is_a_400_that_echoes_nothing(
    http, active_user, device, bearer, attachments_root, case
):
    response = post_upload(http, bearer(active_user, device), case)

    assert response.status_code == 400
    envelope(response, "invalid_request")
    assert CANARY not in response.text
    assert Attachment.objects.count() == 0
    assert files_under(attachments_root) == []


def test_the_part_filename_is_never_read_however_hostile_it_is(
    http, active_user, device, bearer, attachments_root
):
    """The rare case a filename-driven store would fall to: control characters, a
    NUL and a traversal in the name of the part. The server reads the length and
    nothing else, so the upload succeeds and the name reaches neither the disk nor
    the body — the path is the server's own capability, shard and all."""
    hostile = f"..\r\n\x00\x1f/{CANARY}"

    response = http.post(
        UPLOAD_URL,
        files={"blob": (hostile, b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 201
    body = response.json()
    assert set(body) == {"attachment_id", "size"}
    assert CANARY not in response.text
    stored = [path.name for path in files_under(attachments_root)]
    assert stored == [body["attachment_id"]]


@pytest.mark.parametrize("bucket", ATTACHMENT_BUCKETS)
@pytest.mark.parametrize("offset", [-1, 1])
def test_a_body_one_byte_off_a_bucket_is_bad_bucket_and_reaches_no_disk(
    http, active_user, device, bearer, attachments_root, bucket, offset
):
    """Both edges of every bucket. The length is the only thing the server reads
    about the content, so one byte either side of each of the six is the whole
    boundary of the surface."""
    response = http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * (bucket + offset))},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400
    assert envelope(response, "bad_bucket")["detail"] == "Invalid payload."
    assert Attachment.objects.count() == 0
    assert files_under(attachments_root) == []


@pytest.mark.parametrize("length", [0, 42, 43, 44, 10000])
def test_a_capability_of_any_length_is_answered_rather_than_refused(
    http, active_user, device, bearer, length
):
    """The column is 43 wide, so 42 and 44 straddle it and 10 000 is far past every
    index the lookup could use. None of them is a shape error: an id that names no
    row is a `404`, and a zero-length one is a path no route claims."""
    response = http.get(
        f"{UPLOAD_URL}/{'z' * length}", headers=bearer(active_user, device)
    )

    assert response.status_code == 404
    envelope(response, "not_found")
    assert "X-Accel-Redirect" not in response.headers


HOSTILE_IDS = [
    ("a path separator", "one/two"),
    ("an encoded path separator", "one%2Ftwo"),
    ("a parent-directory hop", "..%2F..%2Fetc%2Fpasswd"),
    ("a doubly encoded hop", "%252e%252e%252fetc%252fpasswd"),
    ("an absolute path", "%2Fetc%2Fpasswd"),
    ("a newline", "one%0Atwo"),
    ("a carriage return and a tab", "one%0D%09two"),
    ("a low control character", "one%1Ftwo"),
    ("a delete character", "one%7Ftwo"),
    ("a percent sign of its own", "100%25"),
]


@pytest.mark.parametrize(
    "candidate",
    [value for _label, value in HOSTILE_IDS],
    ids=[label for label, _value in HOSTILE_IDS],
)
def test_a_hostile_capability_is_a_404_that_names_no_path(
    http, active_user, device, bearer, candidate
):
    """The stored path is built from the id the row holds, which is
    server-generated, so none of these can steer it. What must also hold is that
    the refusal reads back nothing: no echo of the id, and no `X-Accel-Redirect`."""
    response = http.get(f"{UPLOAD_URL}/{candidate}", headers=bearer(active_user, device))

    assert response.status_code == 404
    envelope(response, "not_found")
    assert "X-Accel-Redirect" not in response.headers
    assert "etc" not in response.text and "passwd" not in response.text


# --- The body cap, and the disconnect the route sees when it fires ---------------


@pytest.fixture
def capped_http(monkeypatch, settings):
    """A client over the same application, behind a body cap one upload can cross.

    The cap is `max(ATTACHMENT_BUCKETS) + MULTIPART_OVERHEAD_BYTES`, read once when
    the middleware stack is built, so it is shrunk by rebuilding the stack rather
    than by uploading 70 MiB to reach the real one. The application below it is
    the one every other test drives.
    """
    monkeypatch.setattr(api_app, "ATTACHMENT_BUCKETS", [SMALLEST])
    settings.MULTIPART_OVERHEAD_BYTES = 0
    return AsgiClient(api_app.wrap(api_application), api_application)


def test_a_body_above_the_route_cap_is_413_and_stores_nothing(
    capped_http, active_user, device, bearer, attachments_root
):
    """`BodyCap` refuses an oversized body by answering the read with a
    disconnect, so the route meets a `ClientDisconnect` mid-parse. Its answer has
    to be a response rather than an escaping exception — the cap drops whatever the
    route sends and writes its own `413` in its place, and an exception would carry
    neither. The blob is exactly one bucket, so nothing but the cap can refuse it.
    """
    response = capped_http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 413
    assert envelope(response, "payload_too_large")["detail"] == (
        "Request body is too large."
    )
    assert Attachment.objects.count() == 0
    assert files_under(attachments_root) == []


# --- The disk fails, and nothing partial survives it -----------------------------


@pytest.fixture
def unwritable_root(attachments_root):
    """The storage volume refuses the write, which is what a full or read-only disk
    looks like from inside the copy."""
    os.chmod(attachments_root, stat.S_IRUSR | stat.S_IXUSR)
    try:
        yield attachments_root
    finally:
        os.chmod(attachments_root, stat.S_IRWXU)


@pytest.fixture
def reading_http():
    """The whole composed stack, handing back the `500` body instead of re-raising.

    `raise_app_exceptions` is on everywhere else, because an unhandled failure
    reaching the test is what keeps a `500` from passing for a served request.
    Reading the body of one is the single thing that default hides — and it has to
    be read through the middleware, because that is where the headers of the
    answer a client actually receives are added.
    """
    return AsgiClient(application, api_application, reraise=False)


def test_an_upload_that_cannot_reach_the_disk_leaves_no_row_and_no_capability(
    reading_http, active_user, device, bearer, unwritable_root
):
    """The bytes reach the disk before any row names them, so a failed write leaves
    nothing a download could reach: no row, and therefore no id to ask for."""
    response = reading_http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 500
    assert response.json() == {"code": "server_error", "detail": "Internal error."}
    assert Attachment.objects.count() == 0
    assert files_under(unwritable_root) == []


def test_nothing_partial_from_a_failed_upload_is_reachable_afterwards(
    reading_http, http, active_user, device, bearer, unwritable_root
):
    """Every id is a `404` after the failure, including the shard prefix a half
    written file would have landed under."""
    reading_http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    for candidate in ("z" * 43, "zz", ""):
        response = http.get(
            f"{UPLOAD_URL}/{candidate}", headers=bearer(active_user, device)
        )
        assert response.status_code == 404, candidate
        assert "X-Accel-Redirect" not in response.headers


def test_the_failure_names_no_path_no_capability_and_no_traceback_anywhere(
    reading_http, active_user, device, bearer, unwritable_root
):
    """A `500` is where a stack trace, a filesystem path or a token most easily
    reaches a log line, and this surface has no access log to hide it in."""
    headers = bearer(active_user, device)
    token = headers["Authorization"].split()[1]

    with capture_all_logging() as lines:
        # The canaries the log-silence audit uses: without a line of its own in
        # the capture, an empty `lines` would make every assertion below vacuous.
        logging.getLogger("ops.audit.canary").debug(CANARY_OPEN)
        response = reading_http.post(
            UPLOAD_URL, files={"blob": ("blob", b"\x01" * SMALLEST)}, headers=headers
        )
        logging.getLogger("ops.audit.canary").debug(CANARY_CLOSE)

    assert response.status_code == 500
    assert response.json() == {"code": "server_error", "detail": "Internal error."}
    assert any(CANARY_OPEN in line for line in lines)
    assert any(CANARY_CLOSE in line for line in lines)
    leaked = [
        line
        for line in lines
        if str(unwritable_root) in line
        or token in line
        or UPLOAD_URL in line
        or "Traceback" in line
        or "PermissionError" in line
    ]
    assert leaked == []


def test_an_allowance_refusal_writes_no_row_and_no_file(
    http, active_user, device, bearer, attachments_root, settings
):
    """The reservation is taken before the copy, so a refused upload never reaches
    the disk at all — the case the refund path exists for is a failure after it."""
    settings.ATTACH_DAILY_BYTES = SMALLEST - 1

    response = http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 413
    assert envelope(response, "quota_exceeded")["detail"] == allowance.DAY_SPENT
    assert Attachment.objects.count() == 0
    assert files_under(attachments_root) == []


def test_a_failure_after_the_reservation_gives_the_allowance_and_the_bytes_back(
    reading_http, active_user, device, bearer, attachments_root, settings, monkeypatch
):
    """The window the refund exists for: the reservation is spent, the bytes are on
    disk, and the row write fails. Both have to be given back — the allowance
    because the account stored nothing, and the file because no row names it and
    the sweep only ever walks rows."""
    settings.ATTACH_DAILY_BYTES = SMALLEST * 2
    monkeypatch.setattr(
        "attachments.services.record",
        lambda attachment: (_ for _ in ()).throw(OperationalError("gone")),
    )

    response = reading_http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 500
    assert Attachment.objects.count() == 0
    assert files_under(attachments_root) == []
    assert spent_today(active_user) == 0


def test_a_copy_that_cannot_reach_the_disk_gives_the_allowance_back(
    reading_http, active_user, device, bearer, unwritable_root
):
    """The earlier half of the same window, through the real failure rather than a
    stub: the reservation is spent and the copy itself raises. An account whose
    disk write failed must not lose the day's allowance for it."""
    response = reading_http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 500
    assert spent_today(active_user) == 0


def test_a_disk_below_the_floor_refuses_the_upload_before_it_writes(
    http, active_user, device, bearer, attachments_root, settings
):
    """The guard the per-account allowance does not give: nothing bounds the sum of
    every account, and a full disk on this host is PostgreSQL and Redis losing
    their writes rather than one refused upload."""
    settings.ATTACH_MIN_FREE_BYTES = 2**62

    response = http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * SMALLEST)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 503
    assert envelope(response, "storage_full")["detail"] == "Attachment storage is full."
    assert Attachment.objects.count() == 0
    assert files_under(attachments_root) == []


# --- Properties -------------------------------------------------------------------

# The throttle is 60/min, shared by both routes, so it would cap the examples
# rather than the property. What it does is proven in `core/tests/test_rate_limits.py`.
UNTHROTTLED = "10000/min"


# Every refusal a capability that names no row can produce, each a fixed string
# that holds nothing the client sent. The last two are reached by a candidate the
# client's own URL normalisation collapses — `.` and `..` segments never leave it —
# so the path that arrives is one no route claims, or the upload route under the
# wrong method.
DOCUMENTED_MISSES = {
    (404, "not_found", "No such attachment."),
    (404, "not_found", "No such route or resource."),
    (405, "method_not_allowed", "That method is not allowed."),
}


@hypothesis_settings(max_examples=60)
@given(
    candidate=st.one_of(
        st.text(
            alphabet=st.characters(min_codepoint=32, max_codepoint=126),
            min_size=0,
            max_size=60,
        ),
        st.sampled_from(["", ".", "..", "../..", "%2e%2e", "\x7f", " "]),
    )
)
def test_any_capability_a_client_can_send_is_answered_not_broken_property(
    http, active_user, device, bearer, attachments_root, settings, candidate
):
    """Whatever the id, the answer is a documented envelope and never a `500`, its
    detail is a fixed string that echoes nothing, and no `X-Accel-Redirect` is
    built from what the client sent — the header comes off the stored row alone."""
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "attachments": UNTHROTTLED}
    headers = bearer(active_user, device)

    response = http.get(f"{UPLOAD_URL}/{quote(candidate, safe='')}", headers=headers)

    body = response.json()
    assert set(body) == {"code", "detail"}, body
    assert (response.status_code, body["code"], body["detail"]) in DOCUMENTED_MISSES
    assert "X-Accel-Redirect" not in response.headers


def test_a_stored_capability_is_the_only_thing_that_builds_the_redirect(
    http, active_user, device, bearer, attachments_root, settings
):
    """The other half of the property above: the one id that answers `200` is the
    one the server generated, and the header it builds is that id's own shard."""
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "attachments": UNTHROTTLED}
    headers = bearer(active_user, device)
    stored = http.post(
        UPLOAD_URL, files={"blob": ("blob", b"\x01" * SMALLEST)}, headers=headers
    ).json()["attachment_id"]

    # One character different is a different capability, and no row holds it.
    near_miss = stored[:-1] + ("y" if stored.endswith("x") else "x")

    served = http.get(f"{UPLOAD_URL}/{stored}", headers=headers)
    missed = http.get(f"{UPLOAD_URL}/{near_miss}", headers=headers)

    assert served.status_code == 200
    assert served.headers["X-Accel-Redirect"] == (
        f"/_protected_attachments/{stored[:2]}/{stored}"
    )
    assert missed.status_code == 404
    assert "X-Accel-Redirect" not in missed.headers


@hypothesis_settings(max_examples=25)
@given(
    bucket=st.sampled_from(sorted(ATTACHMENT_BUCKETS)[:2]),
    offset=st.integers(min_value=-2, max_value=2),
)
def test_only_an_exact_bucket_length_is_stored_property(
    http, active_user, device, bearer, attachments_root, settings, bucket, offset
):
    """The bucket set is the whole content rule, and it is exact: the length either
    is one of the six or it is refused. The two smallest are swept here, because
    the property is about the boundary and the largest four would move a quarter of
    a gigabyte through the parser to say the same thing."""
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "attachments": UNTHROTTLED}
    before = Attachment.objects.count()

    response = http.post(
        UPLOAD_URL,
        files={"blob": ("blob", b"\x01" * (bucket + offset))},
        headers=bearer(active_user, device),
    )

    if offset == 0:
        assert response.status_code == 201
        body = response.json()
        assert body["size"] == bucket
        assert Attachment.objects.count() == before + 1
        stored = attachments_root / body["attachment_id"][:2] / body["attachment_id"]
        assert stored.stat().st_size == bucket
    else:
        assert response.status_code == 400
        assert envelope(response, "bad_bucket")["detail"] == "Invalid payload."
        assert Attachment.objects.count() == before
