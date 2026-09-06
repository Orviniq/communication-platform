from pydantic import BaseModel


class HealthOut(BaseModel):
    """Liveness and nothing else: no version, no build, no component status."""

    status: str


class ConfigOut(BaseModel):
    """The limits a client has to know and cannot derive.

    Every value is a setting or a constant a route already enforces, so nothing
    here is a second statement of a limit: a client that ignores this document
    learns the same numbers from a `413`, a `409` or a `400 bad_bucket`.
    """

    envelope_ttl_days: int
    attachment_ttl_days: int
    attachment_daily_bytes: int
    mailbox_max_bytes: int
    max_devices_per_user: int
    max_devicelog_records: int
    session_token_days: int
    send_batch_max: int
    ack_max: int
    drain_page_max: int
    claim_max: int
    envelope_buckets: list[int]
    attachment_buckets: list[int]
    signal_buckets: list[int]
    voice_configured: bool
