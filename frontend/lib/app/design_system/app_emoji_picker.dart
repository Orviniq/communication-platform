import 'dart:math' as math;

import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as picker;
import 'package:flutter/material.dart';

/// The application's only import of `package:emoji_picker_flutter` (ADR-059).
///
/// Feature screens use this component and `showAppEmojiPicker`; the package
/// name does not appear outside this file, on the same rule Forui follows under
/// ADR-006. Two settings below are properties of the application rather than of
/// any screen, so they are decided here and not at a call site:
///
///   * `recentTabBehavior` is `NONE` and `SkinToneConfig.rememberSkinTone`
///     stays at its default `false`. Those two flags guard every
///     `shared_preferences` call the package makes -
///     `EmojiPickerState._onEmojiSelected` reaches `addEmojiToRecentlyUsed` /
///     `addEmojiToPopularUsed` only under `RECENT` / `POPULAR`, and the skin
///     tone is read and written only when it is remembered - so with both off
///     the picker writes nothing to disk. That is deliberate: everything else
///     this application knows about a person is in SQLCipher under a
///     Keystore-wrapped key, and a plaintext list of the emoji they most
///     recently used would be a durable record of their behaviour sitting
///     outside that boundary.
///   * `Config.emojiTextStyle` is left unset, which is the only place a font
///     family could be named, so glyphs are drawn with the platform emoji font.
///     Nothing is fetched, and no font is bundled.
///
/// `checkPlatformCompatibility` is left on. On Android it asks the platform,
/// over the package's one method channel, which glyphs the device font can
/// actually draw, and drops the rest - which is the difference between a grid
/// of emoji and a grid with tofu in it. The call is answered by
/// `PaintCompat.hasGlyph` from `androidx.core`, which this module already
/// adopts at 1.16.0 under ADR-054. Off Android the package short-circuits
/// before the channel, so a widget test on this workstation never reaches it.
class AppEmojiPicker extends StatelessWidget {
  const AppEmojiPicker({
    this.onSelected,
    this.controller,
    this.showBackspace = false,
    this.height,
    super.key,
  }) : assert(
         onSelected != null || controller != null,
         'A picker that neither reports a selection nor edits a field does '
         'nothing when it is tapped.',
       );

  /// Called with the selected emoji grapheme. The component neither inserts nor
  /// sends it: what happens next belongs to the caller.
  ///
  /// A caller that passes [controller] does not need this: the package has
  /// already written the emoji into the field by the time this runs, so a
  /// listener that inserted again would type every emoji twice.
  final ValueChanged<String>? onSelected;

  /// The field this picker edits directly.
  ///
  /// Given one, the package inserts at the caret and the backspace button
  /// deletes by grapheme cluster, which is what a picker that stays open across
  /// many selections needs. Leave it null for a picker that reports a single
  /// choice and closes.
  final TextEditingController? controller;

  /// Whether to draw the backspace button.
  ///
  /// Backspace edits a text field the caller may not have: the reaction
  /// selector has none. A control that cannot act is one the UI specification's
  /// core rules refuse to draw, so this stays off unless [controller] is given.
  final bool showBackspace;

  /// Explicit height. When absent the picker takes a share of the viewport, so
  /// it stays usable at the narrow breakpoint without swallowing a wide one.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    final size = MediaQuery.sizeOf(context);
    final resolvedHeight =
        height ?? math.max(224.0, math.min(340.0, size.height * 0.42));
    // The cell size is capped by `emojiSizeMax`, so a fixed column count would
    // leave a wide layout mostly gaps. Deriving columns from the measured width
    // keeps the grid at one density across every breakpoint.
    final columns = (size.width / 44).floor().clamp(7, 14);
    return Semantics(
      container: true,
      label: strings.emojiPickerLabel,
      explicitChildNodes: true,
      child: Material(
        color: colors.surface,
        child: SizedBox(
          height: resolvedHeight,
          child: picker.EmojiPicker(
            textEditingController: controller,
            onEmojiSelected: (_, selected) => onSelected?.call(selected.emoji),
            config: picker.Config(
              height: resolvedHeight,
              // Only the emoji *names* are localized, and the package carries
              // no Persian set, so `fa` falls back to the English names its own
              // `getDefaultEmojiLocale` returns. Search therefore matches
              // English keywords in both locales; the glyphs and the layout are
              // unaffected. Recorded as ADR-059 follow-up F1.
              locale: Localizations.localeOf(context),
              // Only the English set is compiled in, and that is not a
              // reduction in what anybody sees: the package's own
              // `getDefaultEmojiLocale` returns `emojiSetEnglish` for `en`
              // directly and for `fa` through its default branch, because it
              // carries no Persian set. Naming it here instead lets the tree
              // shaker drop eleven unreachable translations of 1500 emoji
              // names, which are megabytes of string constants in `libapp.so`
              // for an artifact that is handed to people over a slow link.
              // Revisit together with ADR-059 follow-up F1.
              emojiSet: (_) => picker.emojiSetEnglish,
              // No `emojiTextStyle`: naming a family here would put Vazirmatn,
              // which has no emoji glyphs, in front of the platform emoji font
              // and leave every cell to font fallback. The size comes from
              // `emojiSizeMax` instead.
              emojiViewConfig: picker.EmojiViewConfig(
                columns: columns,
                backgroundColor: colors.surface,
                gridPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x2,
                  vertical: AppSpacing.x1,
                ),
                loadingIndicator: const Center(
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              categoryViewConfig: picker.CategoryViewConfig(
                // No recent tab, so nothing is persisted. The first category
                // has to move with it: the default initial category is RECENT,
                // which does not exist here.
                recentTabBehavior: picker.RecentTabBehavior.NONE,
                initCategory: picker.Category.SMILEYS,
                backgroundColor: colors.surface,
                indicatorColor: colors.accent,
                iconColor: colors.textMuted,
                iconColorSelected: colors.accent,
                backspaceColor: colors.accent,
                dividerColor: colors.border,
              ),
              bottomActionBarConfig: picker.BottomActionBarConfig(
                // Off unless the caller gave a field to edit: see
                // [showBackspace].
                showBackspaceButton: showBackspace,
                backgroundColor: colors.surfaceRaised,
                buttonColor: colors.surfaceRaised,
                buttonIconColor: colors.textPrimary,
              ),
              searchViewConfig: picker.SearchViewConfig(
                hintText: strings.emojiPickerSearchHint,
                backgroundColor: colors.surfaceRaised,
                buttonIconColor: colors.textMuted,
                inputTextStyle: context.tokens.typography.body,
                hintTextStyle: context.tokens.typography.body.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [AppEmojiPicker] as a modal sheet.
///
/// Completes with the chosen emoji, or `null` when the sheet was dismissed by
/// the backdrop or the back gesture. Dismissal is a no-op for the caller, which
/// is what lets the composer keep its draft.
Future<String?> showAppEmojiPicker(BuildContext context) =>
    showAppSheet<String>(
      context: context,
      semanticLabel: AppLocalizations.of(context).emojiPickerLabel,
      childScrolls: true,
      child: AppEmojiPicker(
        onSelected: (emoji) => popAppModal<String>(context, emoji),
      ),
    );
