import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// Cura brand mark.
class CuraMark extends StatelessWidget {
  const CuraMark({
    super.key,
    this.size = 96,
    this.ringColor = AppColors.accent,
    this.dotColor = AppColors.accent,
    this.accentColor = AppColors.mint,
  });

  final double size;

  /// Ring stroke color.
  final Color ringColor;

  /// Main dot color.
  final Color dotColor;

  /// Accent dot color.
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

/// Brand logo halo.
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
        // Soft mint glow.
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
          // Gentle shadow for floating effect.
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
