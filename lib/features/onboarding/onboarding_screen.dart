import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../app/theme/app_colors.dart';
import '../../core/widgets/cura_mark.dart';
import 'engine_choice_screen.dart';

/// First screen on launch. States the privacy promise over a staggered fade-up
/// entrance: shield → headline → sub-text → pill + button.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  // Shared entrance tuning so every element fades up the same way.
  static const Duration _enterDuration = Duration(milliseconds: 900);
  static const Curve _enterCurve = Curves.easeOutCubic;
  static const double _slideDy = 0.3;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppColors.canvas,
      ),
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Centered hero block: shield + wordmark + headline + sub-text.
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CuraLogoHalo(size: 208)
                          .animate()
                          .fadeIn(duration: _enterDuration, delay: 400.ms)
                          .slideY(
                            begin: _slideDy,
                            duration: _enterDuration,
                            curve: _enterCurve,
                          )
                          .scale(
                            begin: const Offset(0.85, 0.85),
                            end: const Offset(1, 1),
                            duration: _enterDuration,
                            curve: _enterCurve,
                          ),
                      const SizedBox(height: 20),
                      // Wordmark, sitting directly under the shield.
                      Text(
                            'Cura',
                            style: const TextStyle(
                              fontFamily: 'PlusJakartaSans',
                              fontSize: 22,
                              fontWeight: FontWeight.w500,
                              fontVariations: [FontVariation('wght', 500)],
                              letterSpacing: 0.2,
                              color: AppColors.accent,
                            ),
                          )
                          .animate()
                          .fadeIn(duration: _enterDuration, delay: 600.ms)
                          .slideY(
                            begin: _slideDy,
                            duration: _enterDuration,
                            curve: _enterCurve,
                          ),
                      const SizedBox(height: 24),
                      Text(
                            'Your medical records, in one place on your phone.',
                            textAlign: TextAlign.center,
                            style: textTheme.displaySmall,
                          )
                          .animate()
                          .fadeIn(duration: _enterDuration, delay: 800.ms)
                          .slideY(
                            begin: _slideDy,
                            duration: _enterDuration,
                            curve: _enterCurve,
                          ),
                      const SizedBox(height: 16),
                      Text(
                            'Scan reports, prescriptions and receipts. Cura reads '
                            'them, sorts them, and answers your questions.',
                            textAlign: TextAlign.center,
                            style: textTheme.bodyLarge?.copyWith(
                              color: AppColors.secondary,
                            ),
                          )
                          .animate()
                          .fadeIn(duration: _enterDuration, delay: 1050.ms)
                          .slideY(
                            begin: _slideDy,
                            duration: _enterDuration,
                            curve: _enterCurve,
                          ),
                    ],
                  ),
                ),

                // Bottom action group.
                SizedBox(
                      height: 54,
                      child: ElevatedButton(
                        onPressed: () => _onGetStarted(context),
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
                        child: const Text('Get started'),
                      ),
                    )
                    .animate()
                    .fadeIn(duration: _enterDuration, delay: 1350.ms)
                    .slideY(
                      begin: _slideDy,
                      duration: _enterDuration,
                      curve: _enterCurve,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onGetStarted(BuildContext context) {
    // Continue to the AI engine choice (hardware scan → on-device vs cloud).
    // Kept in the stack so back works; the flow's terminals clear it and mark
    // onboarding done (see finishOnboarding).
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const EngineChoiceScreen()));
  }
}
