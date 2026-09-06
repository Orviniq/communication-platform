"""The inbound and outbound models of the devices surface, and its limits.

Every request model forbids an unknown field and runs in strict mode, so a typo,
an injected key, or a value of the wrong JSON type is a refusal rather than a
silently dropped or converted value.

Two decode mechanisms live here, because they answer with two different codes. A
public key or a signature decodes inside its own field, so a malformed one names
that field in an `invalid_request` body. An opaque blob decodes in a model-level
validator, so it runs only after every field has validated: `BadBucket` carries
its own code and echoes nothing, and a body that is also missing a required field
must answer `invalid_request` first.

**Nothing here is verified.** Every length bound is a malformed-input guard that
keeps a wrong-sized value out of a fixed-width column or away from an unbounded
decode. The signatures and the keys are stored and relayed as opaque bytes; only
peers can check them.
"""

import base64
import binascii
import datetime
import uuid
from typing import Annotated, Any

from pydantic import BaseModel, BeforeValidator, Field, PrivateAttr, model_validator
from pydantic_core import PydanticCustomError

from accounts.schemas import RequestModel
from core.buckets import DEVICELOG_BUCKETS, LABEL_BUCKETS
from core.fields import decode_blob_or_400

PUBKEY_MIN, PUBKEY_MAX = (
    32,
    256,
)  # public-key byte-length sanity bounds (opaque otherwise)
# Ed25519 signatures are fixed-size, so an exact check rejects nothing a real client
# would send. This is a malformed-input guard, not a security control: the signature
# itself is stored and relayed, never verified.
ED25519_SIG_LEN = 64
# ML-KEM-768 encapsulation keys are likewise fixed-size, so an exact length is used
# rather than widening PUBKEY_MAX (which correctly bounds X25519/Ed25519): a range
# check would accept nothing useful that the exact check rejects. Also a
# malformed-input guard, not a security control.
PQ_PUBKEY_LEN = 1184

# Base64 of the largest accepted payload plus padding headroom. Unbounded, a client
# could push an arbitrarily long string into b64decode before any length check runs.
MAX_PUBKEY_CHARS = 4 * ((PUBKEY_MAX + 2) // 3) + 8
MAX_SIG_CHARS = 4 * ((ED25519_SIG_LEN + 2) // 3) + 8
MAX_PQ_PUBKEY_CHARS = 4 * ((PQ_PUBKEY_LEN + 2) // 3) + 8
MAX_DEVICELOG_CHARS = 4 * ((max(DEVICELOG_BUCKETS) + 2) // 3) + 8
MAX_LABEL_CHARS = 4 * ((max(LABEL_BUCKETS) + 2) // 3) + 8

# PositiveIntegerField is a 32-bit signed column with a >= 0 check. Without an upper
# bound a larger int reaches the column and raises psycopg's DataError, a 500 on
# input the schema was supposed to be filtering.
MAX_KEY_INT = 2147483647

MAX_OTPKS = 200
MAX_PQ_OTPKS = 100
# Without a stored cap, replenishment is an unbounded write primitive for any
# authenticated device.
MAX_STORED_OTPKS = 200
# 100 × 1184 B per device keeps the worst-case PQ pool ≈ 24 MB across the whole
# deployment (20 users × 10 devices); the cap is a storage budget, do not raise it.
MAX_STORED_PQ_OTPKS = 100
# Accounts hold at most MAX_DEVICES_PER_USER devices, so a longer id list can only
# be noise; the bound keeps an oversized `IN (...)` out of the planner.
MAX_CLAIM_DEVICE_IDS = 100
MAX_LOG_RECORDS = 50
DEVICELOG_PAGE_CAP = 200

# Registration accepts neither `cross_sig` nor `bundle_version`, because no valid
# value exists for either: the canonical device bundle covers `device_id`, and
# registration is what assigns it. Anything a client could put here would be a
# signature over bytes describing a different device, and storing one is worse than
# storing null — peers read null as "never cross-signed, withhold messages", but a
# cross_sig that later changes to the real one looks like a cross-signature change,
# which CLIENT_CONTRACT.md §D/§E requires them to treat as a safety-number event and
# block the conversation over. So the impossible state is made unrepresentable rather
# than merely optional.
PREMATURE_BUNDLE_DETAIL = (
    "Not accepted at registration: the canonical device bundle covers device_id, which "
    "this request assigns, so no signature computed before the response can be valid. "
    "Send cross_sig and bundle_version to PUT /me/devices/{device_id}/prekeys once you "
    "have the device_id."
)


def _b64(value, cap):
    """Decode base64 after bounding the encoded string, never before it."""
    if not isinstance(value, str):
        raise PydanticCustomError("b64_type", "Input should be a valid string")
    if len(value) > cap:
        raise PydanticCustomError("b64_length", "too long")
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError, TypeError):
        raise PydanticCustomError("b64_invalid", "invalid base64")


def _pubkey(value):
    raw = _b64(value, MAX_PUBKEY_CHARS)
    if not (PUBKEY_MIN <= len(raw) <= PUBKEY_MAX):
        raise PydanticCustomError("key_length", "bad key length")
    return raw


def _ed25519_sig(value):
    raw = _b64(value, MAX_SIG_CHARS)
    if len(raw) != ED25519_SIG_LEN:
        raise PydanticCustomError("sig_length", "bad signature length")
    return raw


def _pq_pubkey(value):
    raw = _b64(value, MAX_PQ_PUBKEY_CHARS)
    if len(raw) != PQ_PUBKEY_LEN:
        raise PydanticCustomError("key_length", "bad key length")
    return raw


def _premature_bundle(_value):
    raise PydanticCustomError("premature_bundle", PREMATURE_BUNDLE_DETAIL)


# Base64 on the wire, decoded bytes in the model. The decode is a before-validator
# so a malformed value names its own field, down to the list index it sits at.
PubKey = Annotated[bytes, BeforeValidator(_pubkey)]
Ed25519Sig = Annotated[bytes, BeforeValidator(_ed25519_sig)]
PqPubKey = Annotated[bytes, BeforeValidator(_pq_pubkey)]
KeyInt = Annotated[int, Field(ge=0, le=MAX_KEY_INT)]
LabelBlob = Annotated[str, Field(min_length=1, max_length=MAX_LABEL_CHARS)]
# strict=False on the identifier itself, not on the list around it: FastAPI
# validates a decoded body as Python objects, and strict mode there admits only a
# UUID instance, which JSON cannot carry. Lax UUID accepts a string and bytes and
# nothing else, so no value changes shape on the way in.
LaxUuid = Annotated[uuid.UUID, Field(strict=False)]


def _reject_duplicate_key_ids(otpks):
    """`unique (device, key_id)` makes a repeated key_id inside one payload an
    IntegrityError from bulk_create, i.e. a 500 on malformed client input."""
    if len({otpk.key_id for otpk in otpks}) != len(otpks):
        raise PydanticCustomError("duplicate_key_id", "duplicate key_id")


class OtpkIn(RequestModel):
    key_id: KeyInt
    pub: PubKey


class SignedPrekeyIn(RequestModel):
    """The signature is stored and relayed, never verified: checking it would mean
    the server parsing key material and committing to a curve, and the client is the
    party that must verify spk_sig against ik_pub as part of X3DH. Validating it
    here would imply a guarantee the server does not keep."""

    spk_id: KeyInt
    pub: PubKey
    sig: PubKey


class PqOtpkIn(RequestModel):
    key_id: KeyInt
    pub: PqPubKey


class PqSignedPrekeyIn(RequestModel):
    """Same stance as SignedPrekeyIn: the signature is stored and relayed, never
    verified — the client verifies it against the device identity key."""

    spk_id: KeyInt
    pub: PqPubKey
    sig: Ed25519Sig


class IdentityIn(RequestModel):
    """Cross-signing identity upload. Like every signature this server stores, the
    bytes are stored and relayed, never verified: master_sig binds the subkeys to
    the master key, and only clients — holding the out-of-band-confirmed master —
    can check that binding."""

    master_pub: PubKey
    self_signing_pub: PubKey
    user_signing_pub: PubKey
    master_sig: Ed25519Sig
    version: KeyInt


class RegisterDeviceIn(RequestModel):
    ik_pub: PubKey
    spk_id: KeyInt
    spk_pub: PubKey
    spk_sig: PubKey
    registration_id: KeyInt
    pq_spk: PqSignedPrekeyIn | None = None
    pq_otpks: Annotated[list[PqOtpkIn], Field(max_length=MAX_PQ_OTPKS)] = []
    label_blob: LabelBlob | None = None
    otpks: Annotated[list[OtpkIn], Field(max_length=MAX_OTPKS)]
    # Declared only so that sending one is refused with an answer rather than with
    # "Extra inputs are not permitted", which on a field that was mandatory until
    # recently reads like a version mismatch and sends the reader hunting. Declaring
    # them per field is what names both of them when a client sends both.
    cross_sig: Annotated[Any, BeforeValidator(_premature_bundle)] = None
    bundle_version: Annotated[Any, BeforeValidator(_premature_bundle)] = None

    _label_raw: bytes | None = PrivateAttr(default=None)

    @property
    def label_raw(self):
        return self._label_raw

    @model_validator(mode="after")
    def _check(self):
        _reject_duplicate_key_ids(self.otpks)
        _reject_duplicate_key_ids(self.pq_otpks)
        if self.label_blob:
            self._label_raw = decode_blob_or_400(self.label_blob, LABEL_BUCKETS)
        return self


class PrekeyReplenishIn(RequestModel):
    # Rotating the spk changes a signed bundle field, so the stored cross_sig goes
    # stale; the client is expected to send a fresh cross_sig and bundle_version in
    # the same call. The server stores whatever it is given without coupling the
    # two — enforcing the pairing here would be fake enforcement of a property only
    # peers can actually check.
    spk: SignedPrekeyIn | None = None
    cross_sig: Ed25519Sig | None = None
    bundle_version: KeyInt | None = None
    pq_spk: PqSignedPrekeyIn | None = None
    pq_otpks: Annotated[list[PqOtpkIn], Field(max_length=MAX_PQ_OTPKS)] = []
    otpks: Annotated[list[OtpkIn], Field(max_length=MAX_OTPKS)] = []

    @model_validator(mode="after")
    def _check(self):
        # Same pairing guard as registration, and load-bearing here for the same
        # reason: this endpoint is where a device's first cross_sig arrives, since
        # registration cannot carry one. A signature stored against bundle_version
        # 0 is one peers must reject, so half a pair is caught as malformed input
        # rather than persisted. Not a security control — the server still never
        # checks that the signature matches the bundle, only peers can.
        sent = self.model_fields_set
        if ("cross_sig" in sent) != ("bundle_version" in sent):
            raise PydanticCustomError(
                "cross_sig_pair", "cross_sig and bundle_version must be sent together"
            )
        # A sent `null` is half a pair in substance, whichever half it is: a
        # cross_sig stored against no version is one peers must reject, and
        # `Device.bundle_version` cannot hold null at all — without this the value
        # reached the column and the route answered `500` rather than refusing the
        # body. The union above exists so that "not sent" is expressible, and
        # nothing else.
        if "bundle_version" in sent and self.bundle_version is None:
            raise PydanticCustomError(
                "cross_sig_pair", "bundle_version must be a number when it is sent"
            )
        _reject_duplicate_key_ids(self.otpks)
        _reject_duplicate_key_ids(self.pq_otpks)
        return self


class DeviceLogRecordIn(RequestModel):
    """Record contents are client-defined ciphertext-shaped blobs; the only check
    is the bucket length. In particular the hash chain inside them is NOT validated
    — see `devices.services.append_log`."""

    blob: Annotated[str, Field(min_length=1, max_length=MAX_DEVICELOG_CHARS)]

    _raw: bytes = PrivateAttr(default=b"")

    @property
    def raw(self):
        return self._raw

    @model_validator(mode="after")
    def _decode(self):
        self._raw = decode_blob_or_400(self.blob, DEVICELOG_BUCKETS)
        return self


class DeviceLogAppendIn(RequestModel):
    records: Annotated[
        list[DeviceLogRecordIn], Field(min_length=1, max_length=MAX_LOG_RECORDS)
    ]


class ClaimIn(RequestModel):
    """`{device_ids?}`. An absent list claims every live device of the account; an
    explicit `[]` claims none."""

    device_ids: (
        Annotated[list[LaxUuid], Field(max_length=MAX_CLAIM_DEVICE_IDS)] | None
    ) = None


class LabelUpdateIn(RequestModel):
    label_blob: LabelBlob

    _raw: bytes = PrivateAttr(default=b"")

    @property
    def raw(self):
        return self._raw

    @model_validator(mode="after")
    def _decode(self):
        self._raw = decode_blob_or_400(self.label_blob, LABEL_BUCKETS)
        return self


def _int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def page_bounds(after, limit):
    """The keyset cursor and the page size, neither of which ever errors.

    A junk cursor falls back to the start of the log and a junk or oversized limit
    clamps into [1, DEVICELOG_PAGE_CAP], which is the contract `devices/API.md`
    publishes. Declared as integers instead, a stale bookmark would answer 400 on
    the one route a client polls.
    """
    return (
        _int(after, -1),
        max(1, min(_int(limit, DEVICELOG_PAGE_CAP), DEVICELOG_PAGE_CAP)),
    )


class IdentityOut(BaseModel):
    master_pub: str
    self_signing_pub: str
    user_signing_pub: str
    master_sig: str
    version: int


class DeviceRegisteredOut(BaseModel):
    device_id: uuid.UUID
    token: str
    expires_in: int
    scope: str


class OwnDeviceOut(BaseModel):
    device_id: uuid.UUID
    label_blob: str | None
    created_date: datetime.date
    this_device: bool


class OwnDeviceListOut(BaseModel):
    devices: list[OwnDeviceOut]
    log_head_seq: int | None


class PeerDeviceOut(BaseModel):
    device_id: uuid.UUID
    ik_pub: str
    registration_id: int
    cross_sig: str | None
    bundle_version: int


class PeerDeviceListOut(BaseModel):
    devices: list[PeerDeviceOut]
    etag: str
    log_head_seq: int | None


class OtpkCountOut(BaseModel):
    otpk_count: int


class PrekeyCountOut(BaseModel):
    otpk_count: int
    pq_otpk_count: int


class DeviceLogAppendOut(BaseModel):
    first_seq: int
    last_seq: int


class DeviceLogRecordOut(BaseModel):
    seq: int
    blob: str


class DeviceLogPageOut(BaseModel):
    records: list[DeviceLogRecordOut]
    has_more: bool
    head_seq: int | None


class ClaimedOtpkOut(BaseModel):
    key_id: int
    pub: str


class ClaimedBundleOut(BaseModel):
    """One X3DH bundle.

    The four PQ members and `otpk` are absent from the body when the device holds
    no such material, never null and never zero-filled: a classical-only bundle
    must be visibly classical-only, and an exhausted one-time pool must be
    visibly exhausted. The route serialises with `exclude_unset`, so a member the
    service left out of the dict does not reach the client. `cross_sig` is the
    opposite case and is always present, null included — an unsigned device must
    look unsigned rather than absent.
    """

    device_id: uuid.UUID
    registration_id: int
    ik_pub: str
    spk_id: int
    spk_pub: str
    spk_sig: str
    cross_sig: str | None
    bundle_version: int
    pq_spk_id: int | None = None
    pq_spk_pub: str | None = None
    pq_spk_sig: str | None = None
    pq_otpk: ClaimedOtpkOut | None = None
    otpk: ClaimedOtpkOut | None = None


class ClaimOut(BaseModel):
    bundles: list[ClaimedBundleOut]
