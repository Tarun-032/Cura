import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../security/app_lock.dart';
import 'onboarding_flow.dart';

/// Final onboarding step: optionally turn on the biometric app lock. Skippable,
/// and also available later in Settings. Both buttons end onboarding.
class BiometricSetupScreen extends ConsumerStatefulWidget {
  const BiometricSetupScreen({super.key});

  @override
  ConsumerState<BiometricSetupScreen> createState() =>
      _BiometricSetupScreenState();
}

class _BiometricSetupScreenState extends ConsumerState<BiometricSetupScreen> {
  final BiometricAuth _auth = BiometricAuth();
  bool _working = false;

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _finish() async {
    if (mounted) await finishOnboarding(context, ref);
  }

  Future<void> _enable() async {
    setState(() => _working = true);
    // Only enable if the phone has a lock to enforce.
    if (!await _auth.canAuthenticate()) {
      if (mounted) {
        setState(() => _working = false);
        _toast('Set up a fingerprint or screen lock in your phone settings first');
      }
      return;
    }
    // Prove they can pass the prompt before saving it on.
    final ok = await _auth.authenticate('Confirm to turn on Cura app lock');
    if (!ok) {
      if (mounted) setState(() => _working = false);
      return;
    }
    await setAppLockEnabled(true);
    await _finish();
  }

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
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _StepBar(step: 3),
                const SizedBox(height: 22),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const FingerprintBadge(),
                      const SizedBox(height: 28),
                      Text(
                        'Lock Cura with your fingerprint?',
                        textAlign: TextAlign.center,
                        style: textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Require your fingerprint or screen lock each time Cura '
                        'opens, so only you can open your records. You can change '
                        'this anytime in Settings.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyLarge?.copyWith(
                          color: AppColors.secondary,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 54,
                  child: ElevatedButton.icon(
                    onPressed: _working ? null : _enable,
                    icon: _working
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.canvas,
                            ),
                          )
                        : const Icon(Icons.lock_outline, size: 20),
                    label: const Text('Enable lock'),
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
                ),
                TextButton(
                  onPressed: _working ? null : _finish,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.secondary,
                  ),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The four-segment onboarding progress bar (biometric lock is the final step).
class _StepBar extends StatelessWidget {
  const _StepBar({required this.step});
  final int step; // 0-based index of the current segment

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: i <= step ? AppColors.accent : AppColors.hairline,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
