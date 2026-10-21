# 0015. The document map

- Status: Accepted
- Phase: 1 to 5
- Date: 2026-09-03
- Superseded in part by [0030](0030-the-security-model-and-the-client-contract-move-under-docs.md)
  on 2026-10-21: `backend/SECURITY.md` and `backend/CLIENT_CONTRACT.md` moved under
  `docs/`, and their old paths hold pointer files

## Context

`frontend/docs/` links to `backend/SECURITY.md`, `backend/CLIENT_CONTRACT.md` and
the per-app `backend/*/API.md` files by path. The client is owned by a different
person, and `frontend/` is out of scope for this rebuild — so a move of any of
those three sets breaks references this work is not allowed to repair.

The repository also carried two documents that were deliberately kept out of
version control, `ARCHITECTURE.md` and `CLAUDE.md`, and five tracked files
pointed at them. A reader who followed one of those pointers found nothing.

## Decision

`backend/SECURITY.md` and `backend/CLIENT_CONTRACT.md` stay at their paths and
are rewritten in place.

New root documents: `API_CHANGES.md`, `ACCEPTED_RISKS.md`, `docs/architecture/`
and `docs/admin/`. `backend/ops/RUNBOOK.md` becomes the operator runbook.

Root documents route to the `backend/` documents and never repeat them.

## Position fields

- **Forcing function.** `frontend/docs/` links to the three `backend/` document
  sets by path, and this work may not change `frontend/`.
- **Scale band.** Band 0 to band 4. The document count grows with the age of the
  system, not with the traffic.
- **Flip trigger.** The client stops depending on the `backend/` paths, at which
  point the documents can be consolidated under one root.
- **Cost.** Two document roots to keep consistent, and one routing rule that only
  review enforces. A root document that starts explaining rather than routing is
  the failure mode.
- **Evidence.** Docs-as-code — plain-text documents in version control, next to
  the code, changed in the same pull request as the code — is the practice this
  map follows. **Currency:** current.

## Consequences

- `ARCHITECTURE.md` and `CLAUDE.md` are gone, and the five tracked files that
  referenced them now point at the document that holds that content today:
  `SECURITY.md` for the residual-risk statement, `CLIENT_CONTRACT.md` §B for the
  signature encoding rule, and `README.md` for the local service setup.
- `docs/architecture/` is the system of record for the architecture from this run
  on. `DESIGN-RECORD.md` holds decisions, `GROUND-TRUTH.md` holds measurements,
  and no fact lives in both.
- `API_CHANGES.md` is the only record of a breaking change while the version
  stays `v1`, per [0007](0007-contract-conventions.md).
- The root `README.md` links the record. `ACCEPTED_RISKS.md`, `docs/admin/` and
  the runbook are on the deferral list with the phase that creates each.
