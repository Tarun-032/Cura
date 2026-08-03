import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/widgets/cura_spark.dart';
import '../ai/ai_providers.dart';
import '../ai/remote/remote_ai_store.dart';
import '../ai/widgets/model_download_sheet.dart';
import 'cloud_setup_screen.dart';
import 'device_scan.dart';
import 'voice_setup_screen.dart';

/// Onboarding step 2 (after the logo): choose where AI runs, private on-device
/// or a cloud model, guided by an automatic hardware scan. The scan only
/// *recommends*; the user always chooses. Privacy-first stays the default.
class EngineChoiceScreen extends ConsumerStatefulWidget {
  const EngineChoiceScreen({super.key});

  @override
  ConsumerState<EngineChoiceScreen> createState() => _EngineChoiceScreenState();
}

class _EngineChoiceScreenState extends ConsumerState<EngineChoiceScreen> {
  // Null until the user taps a card; before then the selection follows the
  // hardware recommendation.
  AiEngine? _picked;

  Future<void> _onContinue(AiEngine engine, DeviceProfile profile) async {
    if (engine == AiEngine.local) {
      // Picker with the device-appropriate model pre-selected.
      final ok = await ModelDownloadSheet.show(
        context,
        null,
        recommendModel(profile).id,
      );
      if (!mounted) return;
      // "Continue in background" pops false but leaves a run going; "Not now"
      // leaves nothing, so only the former moves on.
      final running = ref.read(llmDownloadProvider) != null;
      if (ok == true || running) {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const VoiceSetupScreen()));
      }
    } else {
      if (!mounted) return;
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const CloudSetupScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final profileAsync = ref.watch(deviceProfileProvider);
    final profile = profileAsync.value ?? DeviceProfile.unknown;
    final scanning = profileAsync.isLoading;
    final advice = adviseEngine(profile);
    final selected = _picked ?? advice.recommended;

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
                const _StepBar(step: 1),
                const SizedBox(height: 22),
                Text(
                  'How should Cura read your documents?',
                  style: textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  'Cura uses AI to read and answer questions about your reports. '
                  'Choose where it runs.',
                  style: textTheme.bodyLarge?.copyWith(
                    color: AppColors.secondary,
                  ),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      _EngineCard(
                        icon: const CuraSpark(size: 32),
                        iconBackground: AppColors.canvas,
                        title: 'On-device',
                        body:
                            'Runs entirely on your phone. Values are copied '
                            'straight off your reports, never written by a '
                            'model. A one-time '
                            'model download is required, but after that Cura '
                            'works completely offline. Nothing you scan ever '
                            'leaves the device. The scans sometimes have '
                            'incorrect or missing values because we don\'t use '
                            'a vision model, so double-check before saving.',
                        footnote:
                            'Best on phones with 6 GB+ RAM. Answers take longer '
                            'than cloud; the speed depends completely on your '
                            'phone\'s performance.',
                        recommended: advice.recommendsOnDevice,
                        slowNote: advice.onDeviceSlow
                            ? 'May run slowly on this phone'
                            : null,
                        selected: selected == AiEngine.local,
                        onTap: () => setState(() => _picked = AiEngine.local),
                      ),
                      const SizedBox(height: 14),
                      _EngineCard(
                        icon: Icon(
                          Icons.cloud_outlined,
                          size: 20,
                          color: selected == AiEngine.remote
                              ? AppColors.canvas
                              : AppColors.mint,
                        ),
                        title: 'Cloud model',
                        body:
                            'Faster, sharper answers using your own API key. '
                            'Only medical lines are sent. Your name, address, '
                            'phone number and IDs are removed on your phone '
                            'first. Values are still read from your scan, so '
                            'numbers can\'t be invented. Your API key is stored '
                            'encrypted on this device. The scans sometimes have '
                            'incorrect or missing values, so double-check '
                            'before saving. When enabled, the cloud model helps '
                            'label a scan, like its title, type and date, and '
                            'can point out lab rows the scan missed. '
                            'Prescriptions are never sent.',
                        footnote:
                            'Needs internet. You\'re billed by your provider, '
                            'not Cura. You can use some of the available free '
                            'API providers or use a custom one.',
                        recommended: !advice.recommendsOnDevice,
                        selected: selected == AiEngine.remote,
                        onTap: () => setState(() => _picked = AiEngine.remote),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: Text(
                          scanning
                              ? 'Checking your device…'
                              : 'Detected on your device: ${profile.summary}',
                          style: textTheme.bodySmall?.copyWith(
                            color: AppColors.faint,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 54,
                  child: ElevatedButton(
                    onPressed: () => _onContinue(selected, profile),
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
                    child: const Text('Continue'),
                  ),
                ),
                TextButton(
                  // Skips the AI choice but still runs voice and the app lock.
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const VoiceSetupScreen()),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.secondary,
                  ),
                  child: const Text('Decide later'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A four-segment progress bar at the top of the onboarding steps.
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

/// One selectable engine option card.
class _EngineCard extends StatelessWidget {
  const _EngineCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.recommended,
    required this.selected,
    required this.onTap,
    this.footnote,
    this.slowNote,
    this.iconBackground,
  });

  final Widget icon;
  final String title;
  final String body;
  final bool recommended;
  final bool selected;
  final VoidCallback onTap;
  final String? footnote;
  final String? slowNote;
  final Color? iconBackground;

  static const _warn = Color(0xFFB07D2B); // muted amber for the "slow" note

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: selected
          ? AppColors.softTint.withValues(alpha: 0.5)
          : AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color:
                          iconBackground ??
                          (selected ? AppColors.accent : AppColors.softTint),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: icon,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: textTheme.titleMedium),
                        if (recommended) ...[
                          const SizedBox(height: 6),
                          const _Pill(text: 'Recommended'),
                        ],
                        if (slowNote != null) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                size: 15,
                                color: _warn,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                slowNote!,
                                style: textTheme.bodySmall?.copyWith(
                                  color: _warn,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 22,
                    color: selected ? AppColors.accent : AppColors.chevron,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                body,
                style: textTheme.bodyMedium?.copyWith(
                  color: AppColors.secondary,
                  height: 1.45,
                ),
              ),
              if (footnote != null) ...[
                const SizedBox(height: 8),
                Text(
                  footnote!,
                  style: textTheme.bodySmall?.copyWith(color: AppColors.faint),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.softTint,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'PlusJakartaSans',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontVariations: [FontVariation('wght', 600)],
          color: AppColors.accent,
        ),
      ),
    );
  }
}
