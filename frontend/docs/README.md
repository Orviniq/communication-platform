# Frontend documentation

Use this index to work on the Android Flutter client.

| Task | Start here |
|---|---|
| Set up the pinned SDK and run the app | [Frontend setup](../README.md), [Android platform](architecture/ANDROID.md) |
| Find current behavior, contract gaps, and release gates | [Frontend status](STATUS.md) |
| Check a server guarantee or a binding client requirement | [Backend API index](contracts/BACKEND.md), [server design record](../../docs/architecture/DESIGN-RECORD.md), [client contract](../../docs/client/CLIENT_CONTRACT.md), [security](../../docs/security/SECURITY.md), [contacts and trust](../../docs/client/CLIENT_CONTACTS_AND_TRUST.md), [presence and receipts](../../docs/client/CLIENT_PRESENCE_AND_RECEIPTS.md), [voice roles](../../docs/client/CLIENT_VOICE_ROLES.md) |
| Change or review a client wire profile | [Crypto](contracts/CRYPTO.md), [pairwise v1](contracts/PAIRWISE-V1.md), [messages](contracts/MESSAGES.md), [authentication and devices](contracts/AUTH-AND-DEVICES.md), [attachments](contracts/ATTACHMENTS.md), [voice v1](contracts/VOICE-V1.md) |
| Trace client architecture or a decision | [Architecture](architecture/OVERVIEW.md), [local data](architecture/LOCAL-DATA.md), [sync](architecture/SYNC.md), [ADR index](architecture/decisions/README.md) |
| Design or review a screen | [Screens and flows](ui/SCREENS.md), [adaptive layout and accessibility](ui/ADAPTIVE-LAYOUT.md), [visual tokens and assets](ui/DESIGN-SYSTEM.md) |
| Review a security boundary or prepare an independent review | [Client threat model](security/CLIENT-THREAT-MODEL.md), [review scope](security/REVIEW-SCOPE.md), [pairwise v1 review packet](security/REVIEW-SCOPE.md#pairwise-v1-review-packet) |
| Run a check or find field evidence | [Verification](runbooks/VERIFY.md), [validation index](validation/README.md), [sustained-delivery procedure](runbooks/SUSTAINED-DELIVERY.md) |
| Build, sign, or distribute an APK | [Release runbook](runbooks/RELEASE.md), [signing and key continuity](runbooks/SIGNING.md), [third-party notices](third-party-notices.md) |
| Diagnose a build, provisioning, or runtime problem | [Troubleshooting](runbooks/TROUBLESHOOTING.md) |

## Authority and change control

The backend API documents own server behavior. The root client and security
contracts bind client behavior. See the [frontend instructions](../AGENTS.md) for
document ownership, contract gaps, and maintenance checks.

**MUST** marks a requirement for correctness, privacy, or release. **SHOULD** marks
the default and requires an ADR for a deviation. **MAY** marks an option.
