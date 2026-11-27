# Delivery-latency run records

One directory per measurement run, named `YYYY-MM-DD-<what-was-measured>`. These
are the before-and-after evidence for [ADR-060](../../architecture/decisions/060-delivery-latency.md), which is
the only place the reasoning behind the changes they measure is recorded.

Unlike the sustained-delivery records these are hand-driven rather than produced
by a harness, so each one states its own instrument and that instrument's floor.
A number without a stated resolution is not evidence.

## What must never appear in one

Message content, conversation, account, username, token, key, notification text,
server host, IP address, or a device serial. A device is identified by model and
ABI, the way the beta-MLS-core records identify one. Runs use the dedicated test
accounts on the private deployment and never a real user's device or account.
Anything else that turns up in a record is a defect in how it was taken, not a
file to redact by hand.
