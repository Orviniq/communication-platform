# Contributing

This is a two-person project with strict split ownership. Read this before opening a pull
request; it is not a generic template and the constraints below are real.

## Ownership boundary

| Area | Owner |
|---|---|
| `backend/`, system architecture, deployment under `backend/ops/` | [Nima Shadloo](https://github.com/n-shadloo) |
| `frontend/`, including all client-side cryptography and UI | [realSeyed](https://github.com/realSeyed) |

A pull request should stay on one side of that boundary. Changes that genuinely need both
— a protocol change almost always does — are split into one pull request per side, in
dependency order, after the design is agreed.

Agent-assisted work under `frontend/` is governed by
[`frontend/AGENTS.md`](../frontend/AGENTS.md), which additionally treats everything under
`backend/` as read-only from a frontend task.

## Decisions come before implementation

Architectural and protocol decisions are made before implementation, not in review. If a
change adds or alters an endpoint, changes a wire format or a size bucket, touches key
handling, or moves a trust boundary, open an issue and settle the design first. Review
checks that the code matches the decision; it is not where the decision gets made.

Where backend and frontend documentation appear to conflict, stop and name the conflict.
Never resolve one by inventing an undocumented server capability or by weakening a
security invariant.

## The client-server contract

[`docs/client/CLIENT_CONTRACT.md`](../docs/client/CLIENT_CONTRACT.md) is authoritative for the
client-server contract and for the client-side half of every security property. The
per-app `API.md` files are authoritative for endpoints, scopes, limits, and errors.

That surface is still moving. Check it against `main` rather than against the branch you
started from, and update it in the same pull request that changes the behaviour it
describes.

## Setup and verification

Setup, dependencies, and test commands are not repeated here. They live in
[`backend/README.md`](../backend/README.md) and
[`frontend/README.md`](../frontend/README.md). Run the affected side's suite before
opening a pull request and record the result in the pull request template.

## Security

Never report a vulnerability through a public issue or a public pull request. Follow
[SECURITY.md](SECURITY.md).
