import 'package:flutter/material.dart';

import 'app_colors.dart';

/// The Cura app theme: the light "Emerald Calm" palette.
abstract final class CuraTheme {
  static const String _fontFamily = 'PlusJakartaSans';

  /// Plus Jakarta Sans is a variable font, used at two weights via
  /// [FontVariation]. Hierarchy comes from size + color, never bold.
  static const List<FontVariation> _regular = [FontVariation('wght', 400)];
  static const List<FontVariation> _medium = [FontVariation('wght', 500)];

  static TextStyle _style({
    required double size,
    bool medium = false,
    double letterSpacing = 0,
    double? height,
    Color color = AppColors.ink,
  }) {
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: size,
      fontWeight: medium ? FontWeight.w500 : FontWeight.w400,
      fontVariations: medium ? _medium : _regular,
      letterSpacing: letterSpacing,
      height: height,
      color: color,
    );
  }

  static final TextTheme _textTheme = TextTheme(
    // Large headline (e.g. onboarding).
    displaySmall: _style(size: 29, medium: true, letterSpacing: -0.4, height: 1.2),
    // Screen titles.
    headlineMedium: _style(size: 25, medium: true, letterSpacing: -0.3),
    titleLarge: _style(size: 22, medium: true, letterSpacing: -0.3),
    // Section headings.
    titleMedium: _style(size: 18.5, medium: true, letterSpacing: -0.2),
    // Body.
    bodyLarge: _style(size: 15, height: 1.45),
    bodyMedium: _style(size: 14.5, height: 1.4),
    // Metadata.
    bodySmall: _style(size: 12.5, color: AppColors.faint),
    // Micro.
    labelSmall: _style(size: 11.5, color: AppColors.faint),
  );

  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      primary: AppColors.accent,
      surface: AppColors.surface,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: _fontFamily,
      scaffoldBackgroundColor: AppColors.canvas,
      colorScheme: colorScheme,
      textTheme: _textTheme,
      splashFactory: InkRipple.splashFactory,
    );
  }
}
