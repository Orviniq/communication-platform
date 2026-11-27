# ADR-016: English and Persian at first release

- **Status:** Accepted
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-024](024-visual-system.md), [ADR-031](031-semantic-icons.md)

## Decision (Position)

Support **English (`en`) and Persian (`fa`)** from the first release, with **structural RTL and mixed-direction (bidi) behavior** built into layout, typography, icons, and text rendering rather than retrofitted later.

1. Localization catalogs live in [app_en.arb](../../../lib/l10n/app_en.arb) and [app_fa.arb](../../../lib/l10n/app_fa.arb), with generated localizations under `frontend/lib/l10n/generated/` and `AppearanceLanguage` supporting `system`, `en`, and `fa` ([appearance_model.dart](../../../lib/features/settings/domain/appearance_model.dart)).
2. Typography bundles the official `Vazirmatn v33.003` variable font (`assets/fonts/vazirmatn/Vazirmatn-Variable.ttf`) for complete Latin and Persian coverage without runtime font downloads ([Visual design system](../../ui/DESIGN-SYSTEM.md)).
3. Bubbles align by sender (`AlignmentDirectional`), message content resolves first-strong directionality per UAX #9 P2/P3 via [app_text_direction.dart](../../../lib/app/design_system/app_text_direction.dart) (ADR-066 D4), and directional icons mirror explicitly via `AppIconData.mirrorsInRtl` ([app_icons.dart](../../../lib/app/design_system/app_icons.dart)).

## Rationale

RTL, mixed-script message content, and Persian typography affect widget geometry, alignment, icon mirroring, and bidi isolation throughout the app and cannot be bolted on after initial UI construction.

## Constraints and Open Gates

- Enforced by [Visual design system](../../ui/DESIGN-SYSTEM.md), [Adaptive layout](../../ui/ADAPTIVE-LAYOUT.md), and ADR-066 D4–D6 (`goldens/chat_medium_rtl_mixed.png`).
- ADR-066 recorded two open/bounded items on first-strong bidi: `message.replyQuote` `Text` did not yet apply `textDirection` (ADR-066 F1), and `resolveFirstStrongDirection` intentionally returns `null` for neutral/digit-only strings and scripts outside its covered blocks so they inherit ambient direction (ADR-066 F2).
- User-facing errors and deployment disclosures must be localized in both English and Persian, and written handover disclosures are bilingual ([Frontend status](../../STATUS.md#artifact-and-release-acceptance)).

## Costs

- Every new UI surface, error code, and disclosure point requires both English and Persian strings and RTL/mixed-direction verification.
- Custom UAX #9 first-strong range maintenance in `app_text_direction.dart` (adopted after rejecting both the prior regex and `intl`'s `Bidi.startsWithRtl` in ADR-066 D4).

## Reversal Trigger

If additional release locales are added or if Flutter/ICU exposes a conformant, non-broken UAX #9 first-strong helper that replaces `app_text_direction.dart`.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-07-27 (`ef47bc6a`):** Bundled `Vazirmatn v33.003` and added `mirrorsInRtl` semantic icons ([ADR-031](031-semantic-icons.md)).
- **2026-08-30 (ADR-066 D4–D6):** Replaced regex direction detection with UAX #9 P2/P3 first-strong resolution in `app_text_direction.dart`, pinned composer counter `'current / max'` to `TextDirection.ltr`, and added mixed RTL golden coverage.
- No supersession.
