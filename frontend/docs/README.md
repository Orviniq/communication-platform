# Frontend documentation

This directory is the engineering contract for the Flutter client. It targets Android
only, talks only to the self-hosted backend, and treats the server as an untrusted
relay for end-to-end encrypted content. There is no browser target: the server serves
no browser surface, so a web build of this client cannot connect.

The documents use three requirement words:

- **MUST**: required for correctness, privacy, or release.
- **SHOULD**: the default; deviations require an architecture decision record (ADR).
- **MAY**: optional.

## Product and architecture

- [Current implementation, evidence, release gates, and web removal](STATUS.md)
- [UI screens and flows](ui/SCREENS.md)
- [Architecture](architecture/OVERVIEW.md), including [voice and realtime](architecture/OVERVIEW.md#voice-and-realtime)
- [Architecture decisions](architecture/decisions/README.md)
- [Adaptive layout](ui/ADAPTIVE-LAYOUT.md)
- [Visual design system](ui/DESIGN-SYSTEM.md)

## Security and protocols

- [Client threat model](security/CLIENT-THREAT-MODEL.md)
- [Cryptographic protocol](contracts/CRYPTO.md)
- [Pairwise transport version 1](contracts/PAIRWISE-V1.md)
- [Independent cryptographic review scope and engagement](security/REVIEW-SCOPE.md) ([Pairwise v1 review packet](security/REVIEW-SCOPE.md#pairwise-v1-review-packet))
- [Application-message protocol](contracts/MESSAGES.md)
- [Authentication and devices](contracts/AUTH-AND-DEVICES.md)
- [Attachments](contracts/ATTACHMENTS.md)
- [Voice room control and signalling v1](contracts/VOICE-V1.md)
- [Live voice room](ui/SCREENS.md#live-voice-room-screen) and
  [voice room list, creation, and info](ui/SCREENS.md#voice-rooms--list-create--info)

## Data, synchronization, and platforms

- [Local data model](architecture/LOCAL-DATA.md)
- [Synchronization engine](architecture/SYNC.md)
- [Android platform](architecture/ANDROID.md)

## Delivery

- [Backend API index](contracts/BACKEND.md)
- [Release scope and gates](STATUS.md#release-scope-and-gates)
- [Testing strategy and verification](runbooks/VERIFY.md)
- [Sustained delivery: field validation and its gate](runbooks/SUSTAINED-DELIVERY.md)
- [Deployment and release](runbooks/RELEASE.md)
- [Production release signing and key continuity](runbooks/SIGNING.md)
- [Third-party notices](third-party-notices.md)

## Authority and change control

The backend `API.md` files are authoritative for available endpoints, HTTP/WebSocket
behavior, scopes, limits, and server guarantees. The
[`CLIENT_CONTRACT.md`](../../docs/client/CLIENT_CONTRACT.md) is additionally binding for
client-side security behavior, and [`SECURITY.md`](../../docs/security/SECURITY.md) is binding
for protected properties and residual risk. Frontend documents define client-owned
encrypted content and UX only within those guarantees. If a UI/product statement
conflicts with backend documentation, the backend contract takes precedence and the
frontend documentation MUST be corrected before implementation. A conflict is never
resolved by inventing an undocumented server capability or weakening a security
invariant.

For UI work, [`ui/SCREENS.md`](ui/SCREENS.md) is authoritative for screen inventory,
content, actions, states, and navigation. [`ui/ADAPTIVE-LAYOUT.md`](ui/ADAPTIVE-LAYOUT.md)
is authoritative for adaptive layout, width rules, RTL/accessibility, design-system
integration, and timeline boundaries. [`ui/DESIGN-SYSTEM.md`](ui/DESIGN-SYSTEM.md) owns
the initial production tokens, semantic usage, font provenance, and visual grammar.
Product name, logo, and later reviewed brand assets may refine brand tokens without
changing screen behavior.

The protocol documents describe a version-1 design, not a claim of a completed security
audit. Cryptography MUST be implemented with reviewed libraries, verified against test
vectors, and independently reviewed before production release.
