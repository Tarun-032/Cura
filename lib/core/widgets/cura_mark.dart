import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// The Cura brand mark: a ring with an offset main dot and a small mint accent
/// dot. Drawn in code so it stays crisp at any size and re-colours for
/// light/dark. Geometry in a 100×100 space: ring r34 at (50,50), main dot r16 at
/// (44,46), accent dot r5 at (61,63).
class CuraMark extends StatelessWidget {
  const CuraMark({
    super.key,
    this.size = 96,
    this.ringColor = AppColors.accent,
    this.dotColor = AppColors.accent,
    this.accentColor = AppColors.mint,
  });

  final double size;

  /// Boundary ring stroke colour.
  final Color ringColor;

  /// Main (large) dot fill.
  final Color dotColor;

  /// Small lower-right accent dot fill.
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _CuraMarkPainter(
          ringColor: ringColor,
          dotColor: dotColor,
          accentColor: accentColor,
        ),
      ),
    );
  }
}

class _CuraMarkPainter extends CustomPainter {
  const _CuraMarkPainter({
    required this.ringColor,
    required this.dotColor,
    required this.accentColor,
  });

  final Color ringColor;
  final Color dotColor;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Everything below is authored in a 100×100 space, then scaled to fit.
    final s = size.width / 100.0;
    Offset p(double x, double y) => Offset(x * s, y * s);

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * s
      ..color = ringColor
      ..isAntiAlias = true;
    canvas.drawCircle(p(50, 50), 34 * s, ring);

    final main = Paint()
      ..color = dotColor
      ..isAntiAlias = true;
    canvas.drawCircle(p(44, 46), 16 * s, main);

    final accent = Paint()
      ..color = accentColor
      ..isAntiAlias = true;
    canvas.drawCircle(p(61, 63), 5 * s, accent);
  }

  @override
  bool shouldRepaint(_CuraMarkPainter old) =>
      old.ringColor != ringColor ||
      old.dotColor != dotColor ||
      old.accentColor != accentColor;
}

/// The onboarding brand lockup: the [CuraMark] on a floating white circle wrapped
/// in a soft mint halo (glow). [size] is the halo's overall diameter.
class CuraLogoHalo extends StatelessWidget {
  const CuraLogoHalo({super.key, this.size = 208});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Soft mint glow: full at the core, fading to nothing at the rim so the
        // halo feathers out rather than ending on a hard circle edge.
        gradient: RadialGradient(
          colors: [
            AppColors.softTint,
            AppColors.softTint,
            AppColors.softTint.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.64, 1.0],
        ),
      ),
      alignment: Alignment.center,
      child: Container(
        width: size * 0.64,
        height: size * 0.64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surface,
          // Gentle emerald-tinted shadow so the white disc reads as floating.
          boxShadow: [
            BoxShadow(
              color: AppColors.ink.withValues(alpha: 0.10),
              blurRadius: 26,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: CuraMark(size: size * 0.46),
      ),
    );
  }
}
