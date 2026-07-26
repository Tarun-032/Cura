import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// Accent icon centered in a soft mint disc. The hero mark on the onboarding
/// and lock screens.
class CircleIconBadge extends StatelessWidget {
  const CircleIconBadge({super.key, required this.icon, this.size = 120});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.mintCardFill,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.53, color: AppColors.accent),
    );
  }
}
