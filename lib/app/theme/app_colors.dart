import 'package:flutter/material.dart';

/// Color tokens for the "Emerald Calm" light theme.
abstract final class AppColors {
  /// App background canvas.
  static const Color canvas = Color(0xFFF4FAF7);

  /// Card / surface.
  static const Color surface = Color(0xFFFFFFFF);

  /// Primary text / ink.
  static const Color ink = Color(0xFF0A3C30);

  /// Secondary text.
  static const Color secondary = Color(0xFF558B71);

  /// Faint text / placeholders.
  static const Color faint = Color(0xFF8AA99B);

  /// Primary accent — buttons, key actions, active states.
  static const Color accent = Color(0xFF00674F);

  /// Mint — active highlights, success, the AI.
  static const Color mint = Color(0xFF3EBB9E);

  /// Bright highlight — subtle fills, illustration pops.
  static const Color brightHighlight = Color(0xFF73E6CB);

  /// Soft tint — chips and badges.
  static const Color softTint = Color(0xFFBFFFED);

  /// Hairline borders.
  static const Color hairline = Color(0xFFDCECE5);

  /// Soft mint card / circle fill (e.g. the empty-state illustration).
  static const Color mintCardFill = Color(0xFFEAFBF4);

  /// Mint card border / dashed border around mint-tinted cards.
  static const Color mintCardBorder = Color(0xFFBFE9DA);

  /// Row chevron / quiet trailing affordance.
  static const Color chevron = Color(0xFFC2D8CE);

  // --- Category accents (small icon tiles only — never large fills). ---
  // Prescription reuses [mint].

  /// Lab report — soft blue.
  static const Color catLab = Color(0xFF77B1D4);

  /// Receipt — muted olive (tile accent).
  static const Color catReceipt = Color(0xFFA8AE78);

  /// Receipt — icon shade (slightly deeper than the tile accent).
  static const Color catReceiptIcon = Color(0xFF9AA063);

  /// Discharge summary — muted slate.
  static const Color catDischarge = Color(0xFF6E8B9E);

  /// Imaging (PET/MRI/CT/X-ray) — soft indigo-blue, distinct from lab.
  static const Color catImaging = Color(0xFF7A8FC4);

  /// Visit note (manually typed record) — warm amber, apart from the cool
  /// blue/slate document hues and the terracotta destructive tone.
  static const Color catVisit = Color(0xFFBE9556);

  /// Card-on-card row divider (e.g. between Results rows).
  static const Color divider = Color(0xFFEDF4F0);

  /// Destructive action text (e.g. delete).
  static const Color destructive = Color(0xFFA06A58);

  /// Destructive affordance tile fill.
  static const Color destructiveTint = Color(0xFFF8EFEC);

  /// Dark green text on the mint user chat bubble.
  static const Color userBubbleText = Color(0xFF053A2E);
}
