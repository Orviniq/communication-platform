# ADR-021: Missing profile keys render username plus a deterministic local avatar

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-027](027-device-cross-signing.md)

## Decision (Position)

When a peer's encrypted profile key has not been authorized and received, or when a contact is unverified, the UI MUST render only the **backend username** plus a **deterministic local avatar** ([ContactAvatar](../../../lib/features/contacts/presentation/contact_avatar.dart) / `PlaceholderAvatarStyle.fromUsername`), never unauthenticated profile display names or photos.

## Rationale

Avoids presenting unauthenticated or spoofable profile identity during contact bootstrap before mutual out-of-band verification and authorized profile-key distribution occur.

## Constraints and Open Gates

- Enforced in [SafetyNumbersPage](../../../lib/features/settings/presentation/safety_numbers_page.dart), [ContactAvatar](../../../lib/features/contacts/presentation/contact_avatar.dart), and ADR-057 / ADR-098 D4 (unverified contacts display username and deterministic local avatar, never cached display names).
- Open gate: [Frontend status](../../STATUS.md#platform-identity-and-content) notes that profile publication and authorized profile-key distribution (`docs/client/CLIENT_CONTACTS_AND_TRUST.md` §§3–7, `docs/security/SECURITY.md`) remain unimplemented; the profile UI currently uses the username fallback and does not publish display names or photos (ADR-045).

## Costs

- Users see usernames and deterministic initials/colored avatars rather than custom names or photos until contact verification and profile-key distribution are implemented and completed.

## Reversal Trigger

None; even after encrypted profile publication ships, contacts without an authorized profile key continue to fall back to username and deterministic local avatar.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-08-20 (ADR-045) & 2026-08-25 (ADR-057):** Clarified that profile publishing/editing is not built yet, so fallback rendering remains universal for now.
- No supersession.
