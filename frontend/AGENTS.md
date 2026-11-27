# Frontend Codex instructions

## Scope

These instructions apply to everything under `frontend/`.

- Implement the Flutter client for Android only. There is no Web target and no Web
  scaffold: the server serves no browser surface, so a web build cannot connect and
  none is built. Do not reintroduce a browser target, a conditional import selecting
  one, or a `kIsWeb` branch.
- Treat every file under `backend/` as read-only. Backend code and documentation may be
  inspected, but MUST NOT be edited from a frontend implementation task.
- Work on one scoped task at a time.

## Authority and required reading

Before changing code, read:

1. the [frontend task index](docs/README.md);
2. the [status matrix](docs/STATUS.md);
3. the documents that own the behavior in scope; and
4. the relevant [backend API documents](docs/contracts/BACKEND.md), plus the
   [client contract](../docs/client/CLIENT_CONTRACT.md) and
   [security contract](../docs/security/SECURITY.md) for security or protocol work.

Backend API documents own endpoints, scopes, limits, errors, and server guarantees.
The root client and security contracts are binding within their scope. The
[server design record](../docs/architecture/DESIGN-RECORD.md) owns server architecture.
Frontend documents own client architecture, encrypted formats, UX, local state,
and platform behavior within those boundaries. If they conflict, stop implementation,
identify the exact conflict, and do not invent an endpoint, wire format, or weaker
security behavior.

## Documentation maintenance

- Assign each fact one owning document. Update it there and link from indexes,
  runbooks, and summaries. The [status matrix](docs/STATUS.md) owns current
  implementation status and contract gaps. The [ADR register](docs/architecture/decisions/README.md)
  indexes the decisions, which belong in their individual ADRs. Keep screen content,
  actions, states, and navigation in [Screens](docs/ui/SCREENS.md), layout,
  RTL/accessibility, and timeline boundaries in [Adaptive layout](docs/ui/ADAPTIVE-LAYOUT.md),
  and tokens, font provenance, and visual rules in the [design system](docs/ui/DESIGN-SYSTEM.md).
- For a wire claim, cite the implementing code and the matching test vectors in the
  relevant [wire profile](docs/README.md). Verify both at the claimed revision and
  record missing coverage explicitly. Use reviewed cryptographic libraries and
  obtain the independent assessment required by the
  [review scope](docs/security/REVIEW-SCOPE.md) before production release.
- For a release claim, cite a [dated build record](docs/validation/README.md) with its
  source revision, device class, result, and limits. Check acceptance against the
  [release runbook](docs/runbooks/RELEASE.md). Preserve the raw evidence bytes and
  resolve historical citations against their original revision.
- When an ADR supersedes another, link both ways using `Supersedes` on the new
  decision and `Superseded by` on the old decision. Update the register to agree
  with both records.
- When moving docs, check exact-case Markdown links, anchors, reference definitions,
  and raw path mentions. Search code comments, ARB strings and generated localization,
  scripts, and tests that read docs. Update the readers and run their checks from the
  [verification runbook](docs/runbooks/VERIFY.md). Verify links against the staged
  tree and resolve first-party frontend link failures before closing the phase.
- Label an unresolved difference between the contract and implementation
  **Contract gap** in the status matrix. Cite the binding requirement and what the
  code or evidence shows. Keep the required behavior in its owning contract and
  leave changes to it for an explicit decision.
- Keep prompt dumps and session diaries out of live documentation. Record decisions
  in ADRs and dated evidence in validation records.

## External source policy

- When a required implementation detail is missing, ambiguous, or time-sensitive in
  the repository documentation, consult current official primary sources before making
  a decision. Do not guess.
- Prefer the Flutter and Dart documentation, the documentation/source repository for
  the exact pinned package version, Android developer documentation, browser-vendor or
  Web standards documentation, RFC Editor/IETF/IANA/NIST publications, and the official
  WebRTC, libwebrtc or coturn documentation/repositories as applicable.
- Blogs, tutorials, forums, search-result summaries, generated answers, and unofficial
  examples may help discovery but are never normative evidence. Trace important claims
  back to the primary source.
- External material does not override the authority rules above. If an official source
  conflicts with the backend contract or an accepted frontend decision, stop, cite the
  exact conflict, and request a documentation decision instead of silently changing the
  protocol or product behavior.
- For a security, interoperability, dependency, browser-compatibility, or other
  time-sensitive decision, record the source URL, relevant version or revision, and
  verification date in the completion report and update the owning frontend document
  when the result becomes a binding project decision.
- If authoritative information cannot be obtained, leave the affected behavior
  fail-closed or explicitly incomplete and report the missing evidence. Never fill the
  gap with a speculative implementation.

## Architecture

- Preserve Modular Feature-First Clean Architecture with an Offline-First,
  Event-Driven Core.
- Presentation depends on application use cases and immutable view state. Application
  code depends on domain types and ports. Infrastructure implements those ports.
- Domain and protocol code MUST NOT import Flutter widgets, Dio, Drift, Forui, Flyer
  Chat, or platform plugins.
- Drift is the durable source of truth. Riverpod provides dependency injection,
  lifecycle, commands, and projections of database streams; providers are not a second
  database.
- Dio owns REST transport through one reviewed client and token coordinator.
  `go_router` owns guarded/deep-linkable navigation.
- Forui stays behind app-owned components. The
  [app-owned timeline](docs/architecture/decisions/066-sliver-timeline.md) keeps its
  builders presentation-only. They never decrypt, call APIs, or write storage.
- Use Forui's bundled `FLucideIcons` only through the app-owned semantic `AppIcons`
  mapping. Do not import general-purpose icon packages or reference package icons
  directly in feature screens without an accepted ADR.
- Platform differences live behind ports/adapters. Do not scatter `kIsWeb` or platform
  checks through domain/application code.

## Security and privacy

- The server is an untrusted opaque relay for encrypted content. Perform every required
  signature, identity, device-log, version, replay, and authenticated-encryption check
  in the client.
- Dart may orchestrate cryptographic operations but MUST NOT implement cryptographic
  primitives or secret zeroization. Version 1 uses the reviewed shared Rust core
  through Android FFI; a future Web release must use the same core through a reviewed
  Wasm boundary.
- Never add classical-only fallback for PQXDH or PQ MLS, placeholder signatures,
  private-use production ciphersuite identifiers, TOFU messaging, TLS bypasses, or
  arbitrary server selection.
- A group is a set of pairwise sessions, and the client uploads no group key material
  (`../docs/client/CLIENT_CONTRACT.md` §F).
- Never log plaintext, credentials, stable identifiers, keys, recovery secrets,
  ciphertext, attachment capabilities, or decoded tokens. Test redaction.
- Android and future Web protection are different threat boundaries. Do not claim
  browser storage offers Android-equivalent secrecy or imply that Web is part of the
  version-1 release.
- Preserve operation without international internet: no Google/Firebase dependency,
  CDN, remote font, telemetry, public connectivity probe, or other foreign runtime call.

## Implementation discipline

- Inspect the existing implementation and working tree before editing. Preserve user
  changes and do not rewrite unrelated files.
- Prefer small, typed, testable APIs and explicit state machines. Avoid speculative
  abstractions, global mutable state, generated-code edits, and placeholder TODO paths
  presented as complete behavior.
- Use pinned compatible dependencies. Do not replace an accepted dependency or ADR
  without documenting the reason and obtaining user approval when the decision changes.
- Error messages shown to users are reviewed/localized application strings, not raw
  backend detail.
- Update `docs/STATUS.md` only for work actually completed and
  verified. Update other frontend docs when implementation establishes a binding detail.
- Do not create commits, push branches, or open pull requests unless the user asks.

## Verification

For every implementation piece, run the narrowest relevant tests plus all currently
available frontend-wide gates:

1. format changed Dart/Rust files;
2. `flutter analyze`;
3. Flutter unit/widget tests;
4. relevant Rust tests and Android fixtures;
5. Android build/tests when the piece affects the release target; and
6. `git diff --check` and a final scope review.

If a required tool or dependency is unavailable, report the exact unrun command and
reason. Never describe an unrun check as passing.

## Completion report

Finish each piece with:

- the implemented outcome;
- important files changed;
- tests/checks run and their results;
- remaining risks, gates, or follow-up work; and
- confirmation that no backend file was changed.
