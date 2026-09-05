"""The inbound models of the accounts surface, exercised without a request.

Every accounts body reaches these classes before it reaches a unit of work, so
the shape refusals belong here; what the routes add on top is the envelope, and
`accounts/tests/test_routes.py` is where that is proven. Nothing here touches the
database: the username rule is a regex and the password rules are Django's
configured validator set, neither of which reads a row.
"""

import base64
import re
import uuid

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from pydantic import ValidationError

from accounts.schemas import MAX_PROFILE_CHARS, LoginIn, ProfileIn, RegisterIn
from core.buckets import PROFILE_BUCKETS
from core.fields import BadBucket

GOOD_PASSWORD = "a-sufficiently-long-passphrase"
# The configured MinimumLengthValidator (settings.AUTH_PASSWORD_VALIDATORS).
MIN_PASSWORD_LENGTH = 10
SHAPE = re.compile(r"[a-z0-9_]{3,32}")
NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"


def error_types(exc_info):
    return {error["type"] for error in exc_info.value.errors()}


def error_fields(exc_info):
    return {error["loc"][0] for error in exc_info.value.errors()}


def b64_of(nbytes, fill=b"\x11"):
    return base64.b64encode(fill * nbytes).decode()


class TestRegisterIn:
    def test_a_mixed_case_name_is_lowercased_before_it_is_validated(self):
        assert RegisterIn(username="BoB_9", password=GOOD_PASSWORD).username == "bob_9"

    @pytest.mark.parametrize("length", [3, 32])
    def test_the_shortest_and_the_longest_name_are_both_accepted(self, length):
        name = "a" * length

        assert RegisterIn(username=name, password=GOOD_PASSWORD).username == name

    @pytest.mark.parametrize("length", [0, 2, 33])
    def test_a_name_one_step_outside_the_bounds_is_refused(self, length):
        with pytest.raises(ValidationError) as exc_info:
            RegisterIn(username="a" * length, password=GOOD_PASSWORD)

        assert error_fields(exc_info) == {"username"}

    def test_a_name_above_the_field_cap_is_refused_by_length_alone(self):
        """33 characters trips `max_length`, which runs before the shape check, so
        a 4096-character name never reaches the regex."""
        with pytest.raises(ValidationError) as exc_info:
            RegisterIn(username="a" * 4096, password=GOOD_PASSWORD)

        assert error_types(exc_info) == {"string_too_long"}

    @pytest.mark.parametrize("name", ["has space", "dash-es", "Ünicode", "up.dot"])
    def test_a_character_outside_the_alphabet_is_a_shape_error(self, name):
        with pytest.raises(ValidationError) as exc_info:
            RegisterIn(username=name, password=GOOD_PASSWORD)

        assert error_types(exc_info) == {"username_shape"}

    def test_a_password_at_the_exact_minimum_length_is_accepted(self):
        password = "v" + "ujthaxpqz"  # exactly MIN_PASSWORD_LENGTH characters

        assert len(password) == MIN_PASSWORD_LENGTH
        assert RegisterIn(username="bob", password=password).password == password

    def test_a_password_one_character_short_of_the_minimum_is_refused(self):
        password = "ujthaxpqz"

        assert len(password) == MIN_PASSWORD_LENGTH - 1
        with pytest.raises(ValidationError) as exc_info:
            RegisterIn(username="bob", password=password)

        assert error_types(exc_info) == {"password_strength"}
        assert "10 characters" in exc_info.value.errors()[0]["msg"]

    def test_a_long_but_common_password_is_still_refused(self):
        with pytest.raises(ValidationError) as exc_info:
            RegisterIn(username="bob", password="password123")

        assert error_types(exc_info) == {"password_strength"}

    def test_the_refusal_message_names_the_rule_and_never_the_value(self):
        """Pydantic's own error object still carries the offending input; the
        envelope is what drops it, and the route-level proof of that is
        `test_auth_api.py::TestRegister::test_error_never_echoes_the_submitted_password`.
        What this pins is the half the client is shown: the message."""
        with pytest.raises(ValidationError) as exc_info:
            RegisterIn(username="bob", password="vujthaxpq")

        assert [error["msg"] for error in exc_info.value.errors()] == [
            "This password is too short. It must contain at least 10 characters."
        ]

    @pytest.mark.parametrize("password", [12345, None, ["x" * 12]])
    def test_a_password_of_the_wrong_type_is_refused_rather_than_coerced(self, password):
        with pytest.raises(ValidationError) as exc_info:
            RegisterIn(username="bob", password=password)

        assert error_fields(exc_info) == {"password"}

    def test_an_unknown_field_is_refused(self):
        with pytest.raises(ValidationError) as exc_info:
            RegisterIn(username="bob", password=GOOD_PASSWORD, is_staff=True)

        assert error_types(exc_info) == {"extra_forbidden"}

    @given(st.text(alphabet=NAME_CHARS.upper() + NAME_CHARS, min_size=3, max_size=32))
    def test_a_well_shaped_name_only_ever_loses_its_case(self, name):
        assert RegisterIn(username=name, password=GOOD_PASSWORD).username == name.lower()

    @settings(max_examples=100)
    @given(st.text(alphabet="abZ09_-. Éﬁ\x00", max_size=40))
    def test_no_name_the_model_accepts_can_fail_the_stored_shape(self, raw):
        """The property the whole username rule exists for: whatever the client
        sends, the value that reaches the row either matched the shape or never
        got past the model."""
        try:
            parsed = RegisterIn(username=raw, password=GOOD_PASSWORD)
        except ValidationError:
            return
        assert SHAPE.fullmatch(parsed.username)


class TestLoginIn:
    def test_a_device_id_string_arrives_as_a_uuid(self):
        device_id = uuid.uuid4()

        parsed = LoginIn(
            username="alice", password=GOOD_PASSWORD, device_id=str(device_id)
        )

        assert parsed.device_id == device_id

    def test_an_absent_device_id_is_none(self):
        assert LoginIn(username="alice", password=GOOD_PASSWORD).device_id is None

    @pytest.mark.parametrize("device_id", [5, ["not-a-uuid"], "not-a-uuid", {}])
    def test_a_device_id_that_is_not_a_uuid_is_refused(self, device_id):
        with pytest.raises(ValidationError) as exc_info:
            LoginIn(username="alice", password=GOOD_PASSWORD, device_id=device_id)

        assert error_fields(exc_info) == {"device_id"}

    def test_a_badly_shaped_username_is_not_a_shape_error_here(self):
        """A name that could never have been registered is wrong credentials, not
        a malformed request, so login validates the type and nothing else."""
        assert LoginIn(username="Ünicode!", password=GOOD_PASSWORD).username == "Ünicode!"

    @pytest.mark.parametrize(
        "payload",
        [
            {"username": {"$ne": None}, "password": GOOD_PASSWORD},
            {"username": ["alice"], "password": GOOD_PASSWORD},
            {"username": "alice", "password": 12345},
            {"username": "a" * 33, "password": GOOD_PASSWORD},
            {"username": "alice", "password": "p" * 257},
        ],
    )
    def test_a_field_of_the_wrong_type_or_size_is_refused(self, payload):
        with pytest.raises(ValidationError):
            LoginIn(**payload)


class TestProfileIn:
    @pytest.mark.parametrize("bucket", PROFILE_BUCKETS)
    def test_a_bucket_sized_blob_decodes_to_its_raw_bytes(self, bucket):
        parsed = ProfileIn(blob=b64_of(bucket), version=1)

        assert parsed.raw == b"\x11" * bucket

    @pytest.mark.parametrize(
        "size",
        [0, 1, PROFILE_BUCKETS[0] - 1, PROFILE_BUCKETS[0] + 1, PROFILE_BUCKETS[-1] + 1],
    )
    def test_an_off_bucket_blob_is_a_bad_bucket_and_not_a_validation_error(self, size):
        with pytest.raises(BadBucket):
            ProfileIn(blob=b64_of(size), version=1)

    @pytest.mark.parametrize(
        "blob",
        [
            "definitely not base64 !!",
            "q83vEjRWeJ",  # length is not a multiple of four
            "_" * 1368,  # the URL-safe alphabet, which the strict decoder refuses
        ],
    )
    def test_a_blob_that_is_not_strict_base64_is_a_bad_bucket(self, blob):
        with pytest.raises(BadBucket):
            ProfileIn(blob=blob, version=1)

    def test_the_longest_blob_string_the_field_admits_is_still_bucket_checked(self):
        """8192 base64 characters decode to 6144 bytes, which is no bucket: the
        length cap is headroom, never a second bucket."""
        blob = b64_of(6144)

        assert len(blob) == MAX_PROFILE_CHARS
        with pytest.raises(BadBucket):
            ProfileIn(blob=blob, version=1)

    def test_one_character_more_is_refused_before_the_decode(self):
        with pytest.raises(ValidationError) as exc_info:
            ProfileIn(blob="A" * (MAX_PROFILE_CHARS + 1), version=1)

        assert error_types(exc_info) == {"string_too_long"}

    def test_a_missing_version_is_a_validation_error_rather_than_a_bad_bucket(self):
        """The decode is an after-validator, so it runs only once every field has
        validated: a body that is both malformed and off-bucket reports the field."""
        with pytest.raises(ValidationError) as exc_info:
            ProfileIn(blob=b64_of(PROFILE_BUCKETS[0] + 1))

        assert error_fields(exc_info) == {"version"}

    @pytest.mark.parametrize("version", [-1, True, "1", 1.0])
    def test_a_negative_or_coerced_version_is_refused(self, version):
        with pytest.raises(ValidationError) as exc_info:
            ProfileIn(blob=b64_of(PROFILE_BUCKETS[0]), version=version)

        assert error_fields(exc_info) == {"version"}

    def test_version_zero_is_a_legal_first_version(self):
        assert ProfileIn(blob=b64_of(PROFILE_BUCKETS[0]), version=0).version == 0

    @settings(max_examples=50)
    @given(
        st.one_of(
            st.sampled_from(PROFILE_BUCKETS), st.integers(min_value=0, max_value=2048)
        )
    )
    def test_a_length_decodes_exactly_when_it_is_a_bucket(self, size):
        """Drawn from the buckets and from the range around them, so both answers
        are exercised: whichever the model gives, the length is what decided it."""
        try:
            parsed = ProfileIn(blob=b64_of(size), version=1)
        except BadBucket:
            assert size not in PROFILE_BUCKETS
            return
        assert size in PROFILE_BUCKETS
        assert len(parsed.raw) == size
