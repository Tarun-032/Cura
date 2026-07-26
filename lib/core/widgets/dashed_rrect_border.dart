import 'package:flutter/material.dart';

/// Paints a dashed rounded-rectangle border around [child].
///
/// Flutter has no built-in dashed border, so this strokes the rounded-rect path
/// in short dash/gap segments. Dependency-free: a small [CustomPainter].
class DashedBorder extends StatelessWidget {
  const DashedBorder({
    super.key,
    required this.child,
    this.radius = 16,
    this.color = const Color(0xFFDCECE5),
    this.strokeWidth = 2,
    this.dashLength = 6,
    this.gapLength = 5,
  });

  final Widget child;
  final double radius;
  final Color color;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(
        radius: radius,
        color: color,
        strokeWidth: strokeWidth,
        dashLength: dashLength,
        gapLength: gapLength,
      ),
      child: child,
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({
    required this.radius,
    required this.color,
    required this.strokeWidth,
    required this.dashLength,
    required this.gapLength,
  });

  final double radius;
  final Color color;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Inset by half the stroke so the dashes sit fully inside the bounds.
    final inset = strokeWidth / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        inset,
        inset,
        size.width - strokeWidth,
        size.height - strokeWidth,
      ),
      Radius.circular(radius),
    );

    final path = Path()..addRRect(rrect);

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + dashLength;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) {
    return old.radius != radius ||
        old.color != color ||
        old.strokeWidth != strokeWidth ||
        old.dashLength != dashLength ||
        old.gapLength != gapLength;
  }
}
