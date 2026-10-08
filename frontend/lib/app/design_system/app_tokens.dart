import 'package:flutter/material.dart';

/// Viewport classes preserve navigation identity while changing only layout.
enum AppWidthClass { narrow, medium, wide }

abstract final class AppBreakpoints {
  static const double medium = 600;
  static const double wide = 1024;

  static AppWidthClass of(double width) => switch (width) {
    < medium => AppWidthClass.narrow,
    < wide => AppWidthClass.medium,
    _ => AppWidthClass.wide,
  };
}

abstract final class AppSpacing {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x12 = 48;
}

abstract final class AppRadii {
  static const BorderRadius compact = BorderRadius.all(Radius.circular(8));
  static const BorderRadius card = BorderRadius.all(Radius.circular(14));
  static const BorderRadius control = BorderRadius.all(Radius.circular(18));
  static const BorderRadius message = BorderRadius.all(Radius.circular(20));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

abstract final class AppElevation {
  static const List<BoxShadow> none = [];
  static const List<BoxShadow> level1 = [
    BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2)),
  ];
  static const List<BoxShadow> level2 = [
    BoxShadow(color: Color(0x24000000), blurRadius: 20, offset: Offset(0, 8)),
  ];
}

abstract final class AppFocus {
  static const double ringWidth = 3;
  static const double ringGap = 2;
  static const double minimumTarget = 48;
}

abstract final class AppMotion {
  static const Duration press = Duration(milliseconds: 120);
  static const Duration state = Duration(milliseconds: 180);
  static const Duration route = Duration(milliseconds: 240);
  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;

  static Duration effective(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
}

abstract final class AppContentWidths {
  static const double navigationWide = 320;
  static const double navigationMedium = 88;
  static const double readable = 760;
}

/// The system insets a full-screen page keeps its controls out of: the status
/// bar, the gesture bar and the navigation buttons (`ui-specification.md`
/// §0.1).
abstract final class AppInsets {
  /// [spacing] on every side of a scrolling body below an app bar, plus the
  /// insets the app bar leaves to it: the bottom and the sides. The body
  /// still scrolls under the gesture bar, and its last item comes to rest
  /// clear of it.
  ///
  /// The app bar takes the top inset itself, so none is added here, even from
  /// a [context] above the `Scaffold`, where the top inset is still present.
  static EdgeInsets belowAppBar(BuildContext context, double spacing) =>
      EdgeInsets.all(spacing) + MediaQuery.paddingOf(context).copyWith(top: 0);
}

@immutable
class AppColorTokens {
  const AppColorTokens({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.surfaceRaised,
    required this.textPrimary,
    required this.textMuted,
    required this.border,
    required this.accent,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.danger,
    required this.scrim,
  });

  final Brightness brightness;
  final Color canvas;
  final Color surface;
  final Color surfaceRaised;
  final Color textPrimary;
  final Color textMuted;
  final Color border;
  final Color accent;
  final Color accentSoft;
  final Color success;
  final Color warning;
  final Color danger;
  final Color scrim;

  static const light = AppColorTokens(
    brightness: Brightness.light,
    canvas: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFEEF1F5),
    textPrimary: Color(0xFF17191D),
    textMuted: Color(0xFF626B78),
    border: Color(0xFFDCE1E8),
    accent: Color(0xFF315CF5),
    accentSoft: Color(0xFFE7ECFF),
    success: Color(0xFF167A58),
    warning: Color(0xFF9A6200),
    danger: Color(0xFFBD3E4F),
    scrim: Color(0x9917191D),
  );

  static const dark = AppColorTokens(
    brightness: Brightness.dark,
    canvas: Color(0xFF0E1014),
    surface: Color(0xFF15181E),
    surfaceRaised: Color(0xFF1C2028),
    textPrimary: Color(0xFFF4F6F8),
    textMuted: Color(0xFFA8B0BC),
    border: Color(0xFF2B323D),
    accent: Color(0xFF8298FF),
    accentSoft: Color(0xFF202B52),
    success: Color(0xFF53C995),
    warning: Color(0xFFE6AE55),
    danger: Color(0xFFF07886),
    scrim: Color(0xB3000000),
  );

  /// High contrast is an authored palette, not a color transform.
  static const highContrastLight = AppColorTokens(
    brightness: Brightness.light,
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFE6E6E6),
    textPrimary: Color(0xFF000000),
    textMuted: Color(0xFF333333),
    border: Color(0xFF000000),
    accent: Color(0xFF0037CC),
    accentSoft: Color(0xFFDCE5FF),
    success: Color(0xFF00643D),
    warning: Color(0xFF704600),
    danger: Color(0xFFA4001A),
    scrim: Color(0xCC000000),
  );

  static const highContrastDark = AppColorTokens(
    brightness: Brightness.dark,
    canvas: Color(0xFF000000),
    surface: Color(0xFF050505),
    surfaceRaised: Color(0xFF1A1A1A),
    textPrimary: Color(0xFFFFFFFF),
    textMuted: Color(0xFFD8D8D8),
    border: Color(0xFFFFFFFF),
    accent: Color(0xFFAEBBFF),
    accentSoft: Color(0xFF182B69),
    success: Color(0xFF6DFFBD),
    warning: Color(0xFFFFD27A),
    danger: Color(0xFFFF99A4),
    scrim: Color(0xE6000000),
  );

  AppColorTokens lerp(AppColorTokens other, double t) => AppColorTokens(
    brightness: t < 0.5 ? brightness : other.brightness,
    canvas: Color.lerp(canvas, other.canvas, t)!,
    surface: Color.lerp(surface, other.surface, t)!,
    surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
    textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
    textMuted: Color.lerp(textMuted, other.textMuted, t)!,
    border: Color.lerp(border, other.border, t)!,
    accent: Color.lerp(accent, other.accent, t)!,
    accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
    success: Color.lerp(success, other.success, t)!,
    warning: Color.lerp(warning, other.warning, t)!,
    danger: Color.lerp(danger, other.danger, t)!,
    scrim: Color.lerp(scrim, other.scrim, t)!,
  );
}

@immutable
class AppTypographyTokens {
  const AppTypographyTokens({
    required this.display,
    required this.title,
    required this.section,
    required this.body,
    required this.compact,
    required this.label,
  });

  factory AppTypographyTokens.from(AppColorTokens colors) {
    TextStyle style(double size, double lineHeight, FontWeight weight) =>
        TextStyle(
          color: colors.textPrimary,
          fontFamily: fontFamily,
          fontSize: size,
          fontWeight: weight,
          height: lineHeight / size,
          leadingDistribution: TextLeadingDistribution.even,
        );

    return AppTypographyTokens(
      display: style(32, 40, FontWeight.w600),
      title: style(24, 32, FontWeight.w600),
      section: style(20, 28, FontWeight.w600),
      body: style(16, 24, FontWeight.w400),
      compact: style(14, 20, FontWeight.w400),
      label: style(12, 16, FontWeight.w500),
    );
  }

  static const String fontFamily = 'Vazirmatn';
  final TextStyle display;
  final TextStyle title;
  final TextStyle section;
  final TextStyle body;
  final TextStyle compact;
  final TextStyle label;

  AppTypographyTokens lerp(AppTypographyTokens other, double t) =>
      AppTypographyTokens(
        display: TextStyle.lerp(display, other.display, t)!,
        title: TextStyle.lerp(title, other.title, t)!,
        section: TextStyle.lerp(section, other.section, t)!,
        body: TextStyle.lerp(body, other.body, t)!,
        compact: TextStyle.lerp(compact, other.compact, t)!,
        label: TextStyle.lerp(label, other.label, t)!,
      );
}

@immutable
class AppThemeTokens extends ThemeExtension<AppThemeTokens> {
  const AppThemeTokens({required this.colors, required this.typography});

  final AppColorTokens colors;
  final AppTypographyTokens typography;

  @override
  AppThemeTokens copyWith({
    AppColorTokens? colors,
    AppTypographyTokens? typography,
  }) => AppThemeTokens(
    colors: colors ?? this.colors,
    typography: typography ?? this.typography,
  );

  @override
  AppThemeTokens lerp(covariant AppThemeTokens? other, double t) =>
      other == null
      ? this
      : AppThemeTokens(
          colors: colors.lerp(other.colors, t),
          typography: typography.lerp(other.typography, t),
        );
}

extension AppThemeContext on BuildContext {
  AppThemeTokens get tokens => Theme.of(this).extension<AppThemeTokens>()!;
}
