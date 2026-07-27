import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// A small spinner and caption for work happening beside the content, not in
/// front of it: a field the model is still filling, a summary being rewritten.
/// Announced as a live region, and a static glyph when animations are off.
class WorkingLabel extends StatelessWidget {
  const WorkingLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Semantics(
      liveRegion: true,
      label: text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reduceMotion)
            const Icon(Icons.more_horiz, size: 14, color: AppColors.secondary)
          else
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: AppColors.secondary,
              ),
            ),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 12,
              color: AppColors.secondary,
            ),
          ),
        ],
      ),
    );
  }
}
