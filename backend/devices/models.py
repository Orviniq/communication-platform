import uuid

from django.db import models

from core.buckets import DEVICELOG_BUCKETS, LABEL_BUCKETS
from core.fields import OpaqueBlobField


class UserIdentity(models.Model):
    """The account's cross-signing public keys and self-signature, all opaque.

    Stored and relayed, never parsed or verified: every verification (master over
    subkeys, self-signing over device bundles) happens client-side against keys the
    server has never seen. A server-side check here would look like enforcement and
    invite clients to skip the verification that actually matters — the server is
    the adversary in this design.
    """

    user = models.OneToOneField(
        "accounts.User",
        on_delete=models.CASCADE,
        primary_key=True,
        related_name="identity",
    )
    master_pub = models.BinaryField()
    self_signing_pub = models.BinaryField()
    user_signing_pub = models.BinaryField()
    # Ed25519 signature by master over the canonical encoding of the two subkeys.
    master_sig = models.BinaryField()
    version = models.PositiveIntegerField(default=0)


class Device(models.Model):
    """A registered client device. Every key column holds a public key, opaque to
    the server."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        "accounts.User", on_delete=models.CASCADE, related_name="devices"
    )
    ik_pub = models.BinaryField()
    spk_id = models.PositiveIntegerField()
    spk_pub = models.BinaryField()
    spk_sig = models.BinaryField()
    registration_id = models.PositiveIntegerField()
    # Ed25519 signature by the user's self-signing key over the canonical device
    # bundle. Opaque: stored and relayed, never verified — peers verify it against
    # the published identity. Null means the device was never cross-signed and peers
    # will treat it as unverified.
    cross_sig = models.BinaryField(null=True)
    # Incremented by the client whenever any signed bundle field changes, so a stale
    # cross_sig is detectable client-side. The server never compares it to anything.
    bundle_version = models.PositiveIntegerField(default=0)
    label_blob = OpaqueBlobField(bucket_set=LABEL_BUCKETS, null=True)
    # Bumping this invalidates every outstanding JWT for this device.
    token_generation = models.PositiveIntegerField(default=1)
    created_date = models.DateField(auto_now_add=True)
    revoked_date = models.DateField(null=True)
    # Per-device envelope counter. Ordering the mailbox needs a monotonic number, and
    # a server-wide sequence would let row adjacency correlate activity across devices
    # in a dump. Incremented with an F() expression inside the enqueue transaction,
    # whose row lock is what makes concurrent assignment atomic.
    queue_seq = models.BigIntegerField(default=0)
    # Highest seq the TTL prune has ever deleted from this device's mailbox. A
    # returning device whose last acked seq is below this lost envelopes it can
    # never re-fetch — possibly ratchet messages or group control events. Surfaced
    # as `pruned_through` so the client knows to repair each affected pairwise
    # session and ask a member for the current group state, rather than failing
    # silently (CLIENT_CONTRACT.md §H).
    queue_pruned_through = models.BigIntegerField(default=0)
    # ML-KEM-768 signed prekey for hybrid PQXDH. All nullable: a device that never
    # uploaded PQ material serves classical-only bundles with the PQ fields omitted,
    # and the client — never the server — decides whether to refuse or flag that.
    pq_spk_id = models.PositiveIntegerField(null=True)
    pq_spk_pub = models.BinaryField(null=True)  # encapsulation key, 1184 bytes
    pq_spk_sig = models.BinaryField(null=True)  # Ed25519 by the device identity key


class OneTimePrekey(models.Model):
    """X3DH one-time prekey. Claiming one deletes it, inside the claim transaction."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # db_index=False: the unique constraint below already indexes this column as its
    # leading key, so the default FK index would be a redundant B-tree maintained on
    # every insert.
    device = models.ForeignKey(
        Device, on_delete=models.CASCADE, related_name="onetime_prekeys", db_index=False
    )
    key_id = models.PositiveIntegerField()
    pub = models.BinaryField()

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["device", "key_id"], name="uniq_onetimeprekey_device_key_id"
            ),
        ]


class PqOneTimePrekey(models.Model):
    """ML-KEM-768 one-time prekey (1184-byte encapsulation key). Claiming one
    deletes it, inside the claim transaction — the same single-consumption contract
    as OneTimePrekey."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # db_index=False: the unique constraint below already indexes this column as its
    # leading key, so the default FK index would be a redundant B-tree maintained on
    # every insert.
    device = models.ForeignKey(
        Device,
        on_delete=models.CASCADE,
        related_name="pq_onetime_prekeys",
        db_index=False,
    )
    key_id = models.PositiveIntegerField()
    pub = models.BinaryField()

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["device", "key_id"], name="uniq_pq_onetimeprekey_device_key_id"
            ),
        ]


class DeviceLogRecord(models.Model):
    """One record in the user's client-signed, hash-chained device-list log.

    Contents are client-defined and opaque: prev_hash, device-set hash, identity
    version, seq, coarse timestamp, and a self-signing-key signature over all of
    it — but the server never parses any of that. It assigns `seq` and serves the
    records verbatim; the hash chain is verified only by clients comparing heads
    (equivocation detection is the whole point of the log, and it is detection,
    not prevention).
    """

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # db_index=False: the unique constraint below already indexes this column as its
    # leading key, so the default FK index would be a redundant B-tree maintained on
    # every insert.
    user = models.ForeignKey(
        "accounts.User",
        on_delete=models.CASCADE,
        related_name="device_log",
        db_index=False,
    )
    seq = models.BigIntegerField()
    blob = OpaqueBlobField(bucket_set=DEVICELOG_BUCKETS)

    class Meta:
        # The unique (user, seq) index also serves keyset paging and the Max(seq)
        # append probe, so a separate Index(user, seq) is deliberately not declared.
        constraints = [
            models.UniqueConstraint(fields=["user", "seq"], name="uq_devicelog_user_seq")
        ]
