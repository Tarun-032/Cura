import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// A rounded, mint-tinted card with faint diagonal hatching and a centered
/// label, shown in place of a scanned page image when there is none.
class HatchedPlaceholder extends StatelessWidget {
  const HatchedPlaceholder({
    super.key,
    required this.height,
    required this.label,
  });

  final double height;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: CustomPaint(
        painter: _HatchPainter(),
        child: Container(
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.mintCardFill,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.mintCardBorder),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 12.5,
              letterSpacing: 2,
              color: AppColors.faint,
            ),
          ),
        ),
      ),
    );
  }
}

class _HatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.mintCardBorder.withValues(alpha: 0.55)
      ..strokeWidth = 1;

    const gap = 14.0;
    // Diagonal lines (top-left to bottom-right) covering the whole box.
    for (var x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HatchPainter oldDelegate) => false;
}
