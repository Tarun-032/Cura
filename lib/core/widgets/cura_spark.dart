import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// Cura's AI symbol: a four-pointed spark with concave sides, a circular
/// knockout and a solid mint core, in a 100x100 space. Each side is one
/// quadratic Bezier whose control point is the centre; straight lines here give
/// the generic diamond sparkle this mark avoids.
class CuraSpark extends StatelessWidget {
  const CuraSpark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: const _CuraSparkPainter(),
      ),
    );
  }
}

class _CuraSparkPainter extends CustomPainter {
  const _CuraSparkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Keep the exact SVG geometry below in its native 100 x 100 space, then
    // scale the canvas so every rendered size retains perfect 4-fold symmetry.
    final scale = size.shortestSide / 100;
    final dx = (size.width - (100 * scale)) / 2;
    final dy = (size.height - (100 * scale)) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    final body = Path()
      ..moveTo(50, 12)
      ..quadraticBezierTo(50, 50, 12, 50)
      ..quadraticBezierTo(50, 50, 50, 88)
      ..quadraticBezierTo(50, 50, 88, 50)
      ..quadraticBezierTo(50, 50, 50, 12)
      ..close();

    canvas.drawPath(
      body,
      Paint()
        ..color = AppColors.accent
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      const Offset(50, 50),
      14,
      Paint()
        ..color = AppColors.canvas
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      const Offset(50, 50),
      7,
      Paint()
        ..color = AppColors.brightHighlight
        ..isAntiAlias = true,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_CuraSparkPainter oldDelegate) => false;
}
