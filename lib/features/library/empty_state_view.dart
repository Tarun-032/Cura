import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../app/theme/app_colors.dart';
import '../../core/widgets/dashed_rrect_border.dart';

/// Home body when there are no documents yet: invites
/// the user to scan their first one. Body only — the surrounding shell (Scaffold,
/// bottom nav, scan FAB) lives in [HomeScreen].
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({super.key, required this.onAdd});

  final VoidCallback onAdd;

  // Calm, short staggered entrance.
  static const Duration _enterDuration = Duration(milliseconds: 500);
  static const Curve _enterCurve = Curves.easeOutCubic;
  static const double _slideDy = 0.2;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header.
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Your records', style: textTheme.titleMedium),
          ).animate().fadeIn(duration: _enterDuration, delay: 100.ms),

          // Centered hero.
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const _ScanIllustration()
                    .animate()
                    .fadeIn(duration: _enterDuration, delay: 200.ms)
                    .slideY(
                      begin: _slideDy,
                      duration: _enterDuration,
                      curve: _enterCurve,
                    ),
                const SizedBox(height: 28),
                Text(
                      'Add your first document',
                      textAlign: TextAlign.center,
                      style: textTheme.titleLarge?.copyWith(fontSize: 23),
                    )
                    .animate()
                    .fadeIn(duration: _enterDuration, delay: 320.ms)
                    .slideY(
                      begin: _slideDy,
                      duration: _enterDuration,
                      curve: _enterCurve,
                    ),
                const SizedBox(height: 12),
                Text(
                      'Scan a report, prescription or receipt,\n'
                      'or import one that arrived as a PDF.\n'
                      'Cura reads it and files it for you \n'
                      'automatically.',
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: AppColors.secondary,
                      ),
                    )
                    .animate()
                    .fadeIn(duration: _enterDuration, delay: 440.ms)
                    .slideY(
                      begin: _slideDy,
                      duration: _enterDuration,
                      curve: _enterCurve,
                    ),

                const SizedBox(height: 28),
                // Primary action, sitting just below the copy.
                SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: onAdd,
                        icon: const Icon(Icons.add, size: 20),
                        label: const Text('Add a document'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: AppColors.canvas,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          textStyle: const TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            fontVariations: [FontVariation('wght', 500)],
                          ),
                        ),
                      ),
                    )
                    .animate()
                    .fadeIn(duration: _enterDuration, delay: 560.ms)
                    .slideY(
                      begin: _slideDy,
                      duration: _enterDuration,
                      curve: _enterCurve,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The dashed mint card with a camera circle — the empty-state illustration.
class _ScanIllustration extends StatelessWidget {
  const _ScanIllustration();

  @override
  Widget build(BuildContext context) {
    return DashedBorder(
      radius: 32,
      color: AppColors.mintCardBorder,
      strokeWidth: 2,
      child: Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(32),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 84,
          height: 84,
          decoration: const BoxDecoration(
            color: AppColors.mintCardFill,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.photo_camera_outlined,
            size: 38,
            color: AppColors.mint,
          ),
        ),
      ),
    );
  }
}
