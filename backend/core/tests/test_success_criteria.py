"""Success-criteria aggregator.

Keeps the four headline invariants executable in one place, through the public
surface, so they cannot silently rot when the per-app suites are refactored:

1. no plaintext, no content key, no graph at rest (re-runs the seizure-guard audit);
2. a brand-new device restores the key backup, and no server-side history exists
   for it to restore — history is client-to-client (vault flow);
3. revoking a device cuts its access and destroys its server state (devices flow);
4. fan-out writes one independent row per recipient device and stores no sender
   (messaging proof).
"""

import base64
import re

import pytest

from api.auth import issue_session
from core.buckets import BACKUP_BUCKETS, ENVELOPE_BUCKETS
from core.tests.test_seizure_guard import (
    dual_user_fk_offenders,
    envelope_graph_offenders,
    forbidden_column_offenders,
    raw_binary_offenders,
    unbucketed_blob_offenders,
)
from devices.models import Device
from messaging.models import QueuedEnvelope

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

DEVICES_URL = "/api/v1/me/devices"
KEYBACKUP_URL = "/api/v1/me/keybackup"
ENVELOPES_URL = "/api/v1/envelopes"


def _b64(size, fill):
    return base64.b64encode(bytes([fill]) * size).decode()


def _second_device(user, registration_id):
    return Device.objects.create(
        user=user,
        ik_pub=b"ik2",
        spk_id=2,
        spk_pub=b"spk2",
        spk_sig=b"sig2",
        registration_id=registration_id,
    )


def test_nothing_readable_or_graph_shaped_can_exist_at_rest():
    """Executes the full seizure-guard audit over the live app registry.
    Infrastructure secrets exist and are expected; content keys and graphs may not."""
    for audit in (
        forbidden_column_offenders,
        unbucketed_blob_offenders,
        raw_binary_offenders,
        envelope_graph_offenders,
        dual_user_fk_offenders,
    ):
        assert audit() == [], f"{audit.__name__} found violations"


# transaction=True because the key backup is a FastAPI route now, and the ORM
# bracket behind it closes the connection a wrapping test transaction would need.
@pytest.mark.django_db(transaction=True)
def test_a_new_device_restores_the_backup_and_no_server_history_exists(
    http, active_user, device, bearer
):
    """A brand-new device reads the key backup back byte-identical — and that is
    all the server has for it. History is client-to-client on enrollment; the old
    "log in on a new device and your chats are there" flow is superseded, and the
    server-side half of it must stay gone (vault/tests/test_no_history.py pins the
    full removal)."""
    first = bearer(active_user, device)
    backup = _b64(min(BACKUP_BUCKETS), 0x4B)

    assert (
        http.put(
            KEYBACKUP_URL, json={"blob": backup, "version": 1}, headers=first
        ).status_code
        == 200
    )

    fresh = bearer(active_user, _second_device(active_user, 9001))
    assert http.get(KEYBACKUP_URL, headers=fresh).json() == {
        "blob": backup,
        "version": 1,
    }
    assert http.get("/api/v1/me/history", headers=fresh).status_code == 404


def test_revoking_a_device_cuts_its_access_and_destroys_its_state(
    http, active_user, device, bearer
):
    """After DELETE, the revoked device's tokens die and its queue is gone (the full
    cascade and ETag behaviour live in devices/tests/test_revocation.py)."""
    doomed = _second_device(active_user, 9002)
    doomed_access, _ = issue_session(active_user, doomed)
    QueuedEnvelope.objects.create(
        recipient_device=doomed, seq=1, blob=b"\xa5" * min(ENVELOPE_BUCKETS)
    )
    doomed_headers = {"Authorization": f"Bearer {doomed_access}"}
    assert http.get(DEVICES_URL, headers=doomed_headers).status_code == 200

    assert (
        http.delete(
            f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device)
        ).status_code
        == 204
    )

    assert http.get(DEVICES_URL, headers=doomed_headers).status_code == 401
    assert QueuedEnvelope.objects.filter(recipient_device=doomed).count() == 0


def test_fanout_writes_independent_copies_and_never_a_sender(
    http, active_user, device, bearer
):
    """No-graph fan-out: N targets become N independent rows, each knowing only its
    recipient device; the sender appears in no stored value (messaging/tests/
    test_send_fanout.py and test_at_rest.py prove the full property)."""
    from accounts.models import User

    bob = User.objects.create_user(
        username="bob", password="x-trellis-9-quartz", is_active=True
    )
    targets = [_second_device(bob, 9003), _second_device(bob, 9004)]
    blob = _b64(min(ENVELOPE_BUCKETS), 0x5A)

    resp = http.post(
        ENVELOPES_URL,
        json={"messages": [{"device_id": str(d.id), "blob": blob} for d in targets]},
        headers=bearer(active_user, device),
    )
    assert resp.status_code == 202

    rows = list(QueuedEnvelope.objects.order_by("seq"))
    assert len(rows) == 2
    assert len({row.id for row in rows}) == 2, "copies must be independent rows"
    assert {row.recipient_device_id for row in rows} == {d.id for d in targets}
    sender_traces = {str(active_user.id), str(device.id)}
    for row in rows:
        stored = {
            str(value)
            for value in (row.id, row.recipient_device_id, row.seq, row.queued_day)
        }
        assert stored & sender_traces == set(), "a stored value identifies the sender"


# 5. every stored ciphertext has an exact bucket length, and an off-bucket payload
#    is refused without the payload being echoed back.
def test_an_off_bucket_payload_is_refused_and_never_echoed(
    http, active_user, device, bearer
):
    """The padding rule, through the surface rather than through the decoder.

    Length is the one thing a blind relay can still see, so every stored blob is
    padded to an exact bucket and anything else is `400 bad_bucket` — with
    `"Invalid payload."` and nothing of the request, because an error body that
    echoed the blob would put ciphertext in a client's log and in this server's.
    `core/tests/test_fields.py` proves the decoder's own totality.
    """
    smallest = min(BACKUP_BUCKETS)
    off_bucket = _b64(smallest + 1, 0x4B)

    refused = http.put(
        KEYBACKUP_URL,
        json={"blob": off_bucket, "version": 1},
        headers=bearer(active_user, device),
    )

    assert refused.status_code == 400
    assert refused.json() == {"code": "bad_bucket", "detail": "Invalid payload."}
    assert off_bucket not in refused.text
    from vault.models import KeyBackup

    assert KeyBackup.objects.count() == 0


def test_a_payload_at_an_exact_bucket_length_is_stored_whole(
    http, active_user, device, bearer
):
    """The other side of the same rule: the boundary is exact, not a maximum, so
    the bucket length itself must be accepted and stored byte for byte."""
    smallest = min(BACKUP_BUCKETS)
    padded = _b64(smallest, 0x4B)

    stored = http.put(
        KEYBACKUP_URL,
        json={"blob": padded, "version": 1},
        headers=bearer(active_user, device),
    )

    assert stored.status_code == 200
    from vault.models import KeyBackup

    assert len(bytes(KeyBackup.objects.get().blob)) == smallest


# 6. the suites that carry these invariants are still there, and still run.
INVARIANT_SUITES = (
    "core/tests/test_seizure_guard.py",
    "core/tests/test_manifest.py",
    "core/tests/test_log_silence.py",
    "core/tests/test_settings_posture.py",
    "core/tests/test_success_criteria.py",
    "accounts/tests/test_log_silence.py",
    "api/tests/test_log_silence.py",
    "devices/tests/test_log_silence.py",
    "messaging/tests/test_log_silence.py",
    "realtime/tests/test_log_silence.py",
    "vault/tests/test_log_silence.py",
)
# The marker syntaxes, not the bare word: this file names them all in the line
# below, and a pattern that matched prose would fail on its own source.
QUARANTINE = re.compile(
    r"pytest\.mark\.(?:skip|xfail)|pytest\.skip\(|unittest\.skip"
    r"|self\.skipTest\(|@skip(?:Unless|If)\b"
)


@pytest.mark.parametrize("name", INVARIANT_SUITES)
def test_no_invariant_suite_is_quarantined(name):
    """The suites above are the executable form of the invariants, and the one way
    to make them stop failing without fixing anything is to stop running them. A
    skip, a conditional skip or an expected failure in any of them is that.

    Named as files rather than discovered, so deleting one fails here instead of
    reducing the set this test walks.
    """
    from django.conf import settings

    path = settings.BASE_DIR / name

    assert path.exists(), name
    body = path.read_text()
    assert QUARANTINE.search(body) is None, name
    assert body.count("def test_") > 0, name


# The two files that prove invariant 2 against a real `pg_dump` of the tables. They
# are not in `INVARIANT_SUITES` above and cannot be: each carries the conditional
# marker assembled below, which `QUARANTINE` matches by design, and that guard is
# legitimate — a developer machine without `pg_dump` cannot run them. What must not
# happen is the proof leaving a run silently, so the two assertions below take the
# place of membership: the only quarantine marker in either file is that one guard,
# and on CI `pg_dump` has to be there.
AT_REST_SUITES = (
    "accounts/tests/test_at_rest.py",
    "messaging/tests/test_at_rest.py",
)
# Assembled rather than written out, for the reason the comment above `QUARANTINE`
# gives: this file is itself in `INVARIANT_SUITES`, so a marker spelled literally in
# its source would fail its own gate.
PG_DUMP_GUARD = "@pytest.mark." + 'skipif(PG_DUMP is None, reason="pg_dump not on PATH")'


@pytest.mark.parametrize("name", AT_REST_SUITES)
def test_the_at_rest_suites_carry_no_marker_but_the_recorded_pg_dump_guard(name):
    """A bare skip added to either file would drop the "no plaintext at rest" proof
    out of every run, and `test_no_invariant_suite_is_quarantined` does not walk
    these two."""
    from django.conf import settings

    path = settings.BASE_DIR / name

    assert path.exists(), name
    body = path.read_text()
    assert body.count("def test_") > 0, name
    markers = QUARANTINE.findall(body)
    assert markers, name  # the guard itself, so a rewrite that lost it fails here
    assert body.count(PG_DUMP_GUARD) == len(markers), name


def test_the_at_rest_proof_cannot_leave_a_ci_run():
    """`pg_dump` is what those seven tests shell out to, and its absence skips them
    with a recorded reason and a green run. That is right on a developer machine and
    wrong on the gate: the proof would leave CI with nothing to say so.

    Written as one implication rather than a skip, because this file is in
    `INVARIANT_SUITES` and may hold no marker of its own. Off CI it asserts that the
    runner is off CI, which is true and says so; on CI it is the whole check.
    """
    import os
    import shutil

    assert shutil.which("pg_dump") or not os.environ.get("CI"), (
        "pg_dump is absent on a CI runner, so the at-rest suites would skip and the "
        "no-plaintext-at-rest proof would leave this run"
    )


def test_the_offline_rehearsal_is_present_and_runnable():
    """The eighth invariant's proof is a shell script rather than a test, so the
    suite cannot run it — what it can do is fail when it goes missing or stops
    being executable, which is how it would silently leave the gate."""
    import os

    from django.conf import settings

    script = settings.BASE_DIR / "ops" / "audit" / "offline_rehearsal.sh"

    assert script.exists()
    assert os.access(script, os.X_OK)
    assert "--require-hashes" in script.read_text()
