# Backend API Documentation

Reference these API specifications when implementing or changing frontend API integrations.

The following backend-wide documents are authoritative before the per-app endpoint
references:

- [Backend overview](../../backend/README.md)
- [Binding client security contract](../../backend/CLIENT_CONTRACT.md)
- [Backend threat model and residual risk](../../backend/SECURITY.md)

These files define transport only. Encrypted content formats and client synchronization
rules are defined by [cryptographic-protocol.md](cryptographic-protocol.md),
[message-protocol.md](message-protocol.md), and [sync-engine.md](sync-engine.md).
Handoff copies MUST NOT be duplicated here; these repository paths remain the single
source of truth.

- [Accounts API](../../backend/accounts/API.md)
- [Attachments API](../../backend/attachments/API.md)
- [Core API](../../backend/core/API.md)
- [Devices API](../../backend/devices/API.md)
- [Messaging API](../../backend/messaging/API.md)
- [Realtime API](../../backend/realtime/API.md)
- [Vault API](../../backend/vault/API.md)
- [Voice Rooms API](../../backend/voicerooms/API.md)

## The error vocabulary

Every error of every route is one envelope, `{"code": ..., "detail": ...}`. The code
table is authoritative in [core API](../../backend/core/API.md); what follows is what
the client does with it, and is binding on this side.

- **Branch on `code`, never on `detail`.** A status is not a branch either: two pairs
  share one. `mapBackendFailure` is the only place a wire code becomes a client value,
  and `BackendFailureCode` holds one value per code, named after it.
- **Never show a `detail` string.** It is the server's wording, unreviewed and
  unlocalized. Nothing but the code and the `Retry-After` seconds crosses the mapper,
  which is what makes that rule structural rather than a habit.
- **Read a validation `detail` field path as a flat dotted string** — `otpks.0.pub` —
  not as a nested object. `invalid_request` is the one code whose `detail` is an object
  at all.
- **No error body echoes request input**, and a `500` carries no traceback.

Two pairs share a status and mean different things. Each half gets its own words on
the screen:

| Pair | Which | What it means | What the client does |
|---|---|---|---|
| `429` / `503` | `throttled` | This client asked too often | Read `Retry-After` and back off. The same request works after the wait |
| | `unavailable` | The server is saturated, or a store it needs is gone | Retry with a backoff of the client's own. No wait is published |
| `413` / `503` | `quota_exceeded` | The account's upload allowance for this UTC day is spent | Hold the attachment. A retry before 00:00 UTC answers the same way |
| | `storage_full` | The server's disk is below its free-space floor | Retry later. It is not the account's fault, nothing was charged, and the operator has to free space |

`503 voice_unconfigured` is a third thing at that status and is not a backoff at all:
the deployment serves no voice, so the client offers no call rather than retrying.

Four codes were deleted from the client because no route answers them: `bad_request`
(now `invalid_request`), `token_not_valid` (now `invalid_token`), `device_scope_required`
(returned by nothing — it stays in the server's vocabulary and nothing reaches it), and
`keypackage_limit` (its route is gone with MLS).

## Contract status

The former device-enrollment circularity is resolved. The binding flow is now
two-phase: register without `cross_sig`/`bundle_version`, receive the backend-assigned
`device_id` and full-scope tokens, then submit the valid signature and version through
`PUT /me/devices/{device_id}/prekeys`. A later device retrieves the recovery backup only
after registration gives it full scope. Until the follow-up succeeds, peers see
`cross_sig: null` and withhold messages.

The Devices API and its [golden vectors](../../backend/devices/vectors/README.md) now
freeze the four canonical signature encodings and the 64-byte `ik_pub` layout (Ed25519
followed by X25519). The Android version-1 implementation MUST reproduce those vectors
byte-for-byte; a future Web implementation must reproduce the same bytes before Web
release.

One client-side security gate remains: the backend requires a reviewed PQ MLS
ciphersuite for groups. The frontend-owned [PQ MLS profile](mls-profile.md) selects the
IETF hybrid ML-KEM-768/X25519 candidate, but its ciphersuite identifier is still
unassigned and maintained Android library support and interoperability evidence are not
yet available. Android group production release remains blocked by that profile's
Android gates; Web gates are post-v1. The client MUST NOT invent an identifier or
silently use a classical MLS suite.
the client MUST NOT invent an identifier or silently use a classical MLS suite.
