# 0030. The security model and the client contract move under docs/

- Status: Accepted
- Phase: — (a change to the document map, after the rebuild's eleven phases)
- Date: 2026-10-21
- Landed: 2026-10-21. `backend/SECURITY.md` is `docs/security/SECURITY.md`,
  `backend/CLIENT_CONTRACT.md` is `docs/client/CLIENT_CONTRACT.md`, and
  `backend/CLIENT_CONTACTS_AND_TRUST.md` is `docs/client/CLIENT_CONTACTS_AND_TRUST.md`.
  Each old path holds a pointer file and nothing else.
- Supersedes in part [0015](0015-the-document-map.md): the decision that
  `backend/SECURITY.md` and `backend/CLIENT_CONTRACT.md` stay at their paths.

## Context

[0015](0015-the-document-map.md) kept the security model and the client contract under
`backend/` because `frontend/docs/` links them by path, the client is owned by another
person, and server-side work may not edit `frontend/`. Its flip trigger was the client
ceasing to depend on those paths. That has not happened: on 2026-10-21, 146 links in 53
files under `frontend/` named the three documents this record moves, 74 of them the
contract.

The owner asked, on 2026-10-20, for the documents to live under the root `docs/`
directory. The three that describe the whole system rather than one app — what the system
protects, and the two binding client texts — are documents of the repository, not of the
server's package. Keeping them beside the server's code has also put the binding client
text one directory away from the record that decides it (`docs/architecture/`), and the
contract's newest companion, `CLIENT_CONTACTS_AND_TRUST.md`, was added there only because
the contract already was.

## Decision

1. `backend/SECURITY.md` moves to `docs/security/SECURITY.md`. A subdirectory and not
   `docs/SECURITY.md`, because GitHub reads a `SECURITY.md` in `docs/` as a vulnerability
   reporting policy; that policy is `.github/SECURITY.md`, and the security model is not one.
2. `backend/CLIENT_CONTRACT.md` and `backend/CLIENT_CONTACTS_AND_TRUST.md` move to
   `docs/client/`.
3. **Each old path keeps a pointer file**: a heading saying the document moved, a link to its
   new path, and nothing else. Every link the client's documents carry still leads to the
   document, so the move breaks nothing that this work may not repair. No client link names a
   section of these files, so no anchor is lost.
4. Every live document outside `frontend/` now links the new paths: the root documents,
   `.github/`, `backend/README.md`, each app's `API.md`, the operator runbook, the panel
   record, the design record and the ground truth. The ADRs keep the paths they were written
   against, as records of their day, and code comments keep theirs; the pointer files serve
   both.
5. **What stays:** each app's `API.md` beside the app it documents — a route reference
   belongs with its routes, and `core/tests/test_endpoint_references.py` reads every
   `*/API.md` there — `backend/README.md`, `backend/ops/` and the golden vectors' README.

## Position fields

- **Forcing function.** The owner asked for the documents to live under `docs/`, and the
  cost [0015](0015-the-document-map.md) avoided — broken client references — is now avoided
  by pointer files instead of by not moving.
- **Scale band.** Band 0 to band 4. The document count grows with the age of the system.
- **Flip trigger.** The client's own documents link the new paths. The pointer files are then
  deleted, in the change that confirms no link names them.
- **Cost.** Three pointer files to keep, and a reader who follows a client link takes one more
  click. The client developer has links to update (`CLIENT_WORK.md`). Two document roots
  remain: the per-app references stay under `backend/`.
- **Evidence.** Measured on 2026-10-21 with a relative-link checker over every tracked
  Markdown file: outside `frontend/`, 581 links and none broken before the move, and none
  broken after it; under `frontend/`, the same 38 broken links before and after — all of
  them in vendored third-party READMEs — and no new one. **Currency:** current.

## Consequences

- [0015](0015-the-document-map.md) is superseded in part; the rest of it stands — the root
  documents, `docs/architecture/` as the system of record, and the routing rule.
- `README.md`'s documentation table names the new paths, and lists
  `CLIENT_CONTACTS_AND_TRUST.md`, which it had not.
- `CLIENT_WORK.md` carries the link update as recommended client work.
- The "Documents" position of `DESIGN-RECORD.md` states the new map.
