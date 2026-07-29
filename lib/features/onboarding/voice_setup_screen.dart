import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/widgets/circle_icon_badge.dart';
import '../ai/ai_providers.dart';
import '../ask/voice_input_controller.dart';
import 'biometric_setup_screen.dart';

/// Onboarding step 3: optionally download the Whisper voice model. Skippable,
/// since voice can also be set up later in Settings. Either way the next step is
/// the app lock.
class VoiceSetupScreen extends ConsumerStatefulWidget {
  const VoiceSetupScreen({super.key});

  @override
  ConsumerState<VoiceSetupScreen> createState() => _VoiceSetupScreenState();
}

class _VoiceSetupScreenState extends ConsumerState<VoiceSetupScreen> {
  final VoiceInputController _voice = VoiceInputController();

  bool _ready = false; // model already on disk (e.g. from a prior run)

  /// Set on tap so the screen shows progress before the native side reports.
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _voice.isModelReady().then((ready) {
      if (mounted) setState(() => _ready = ready);
    });
  }

  @override
  void dispose() {
    _voice.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    // Go to the last step, the optional app lock; it ends onboarding for us.
    if (!mounted) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const BiometricSetupScreen()));
  }

  Future<void> _downloadAndContinue() async {
    if (_ready) {
      await _finish();
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      // Returns on accept; the listener in build moves on once it lands.
      final started = await _voice.downloadModel(
        ref.read(modelDownloaderProvider),
      );
      if (!started) await _finish();
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Voice only: the LLM from the previous step may still be running here.
    final download = ref.watch(voiceDownloadProvider);
    ref.listen(voiceDownloadProvider, (previous, next) {
      if (!mounted) return;
      // Gone means done; a failure reports through ModelDownload.error.
      if (previous != null && next == null) {
        _finish();
      } else if (next?.error != null && _starting) {
        setState(() => _starting = false);
      }
    });
    // Ignore the previous attempt's error mid-retry, or Retry shows it back.
    final error = _starting ? null : (download?.error ?? _error);
    final downloading =
        _starting || (download != null && download.error == null);
    final progress = download?.percent ?? 0;

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
                const _StepBar(step: 2),
                const SizedBox(height: 22),
                Text(
                  'Ask questions out loud?',
                  style: textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  'Use Whisper to transcribe your speech on your device! No audio is sent to the cloud.',
                  style: textTheme.bodyLarge?.copyWith(
                    color: AppColors.secondary,
                  ),
                ),
                // Centered when there's room; scrolls instead of overflowing
                // if the screen is short.
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: const _PulsingMicBadge(),
                    ),
                  ),
                ),
                _WhisperCard(ready: _ready),
                const SizedBox(height: 16),
                if (error != null) ...[
                  Text(
                    error,
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.destructive,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (downloading) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress > 0 ? progress / 100 : null,
                      minHeight: 8,
                      backgroundColor: AppColors.hairline,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    switch (download) {
                      final d? when d.paused => 'Paused, waiting to reconnect…',
                      final d? when d.percent > 0 =>
                        'Downloading… ${d.percent}%',
                      _ => 'Starting…',
                    },
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall,
                  ),
                  // Same escape as the idle branch, reachable mid-download.
                  TextButton(
                    onPressed: _finish,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.secondary,
                    ),
                    child: const Text('Continue'),
                  ),
                ] else ...[
                  SizedBox(
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: _downloadAndContinue,
                      icon: Icon(
                        _ready
                            ? Icons.check
                            : (error == null
                                  ? Icons.download_outlined
                                  : Icons.refresh),
                        size: 20,
                      ),
                      label: Text(
                        _ready
                            ? 'Continue'
                            : (error == null ? 'Download & continue' : 'Retry'),
                      ),
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
                    onPressed: _finish,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.secondary,
                    ),
                    child: const Text('Skip for now'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The mic hero mark, with rings breathing outward behind it.
class _PulsingMicBadge extends StatefulWidget {
  const _PulsingMicBadge();

  @override
  State<_PulsingMicBadge> createState() => _PulsingMicBadgeState();
}

class _PulsingMicBadgeState extends State<_PulsingMicBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the system "remove animations" setting.
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) =>
                  CustomPaint(painter: _PulseRingsPainter(_controller.value)),
            ),
          ),
          const CircleIconBadge(icon: Icons.mic_none),
        ],
      ),
    );
  }
}

/// Three rings on the same loop, staggered a third of a cycle apart, each
/// expanding away from the badge edge and fading as it goes.
class _PulseRingsPainter extends CustomPainter {
  const _PulseRingsPainter(this.t);

  final double t; // 0→1, repeating

  @override
  void paint(Canvas canvas, Size size) {
    const badgeRadius = 60.0;
    const maxRadius = 96.0;
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1;
      paint.color = AppColors.accent.withValues(alpha: 0.18 * (1 - phase));
      canvas.drawCircle(
        center,
        badgeRadius + (maxRadius - badgeRadius) * phase,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PulseRingsPainter oldDelegate) => oldDelegate.t != t;
}

/// The Whisper details card: model name, size/readiness, and what it does.
class _WhisperCard extends StatelessWidget {
  const _WhisperCard({required this.ready});

  final bool ready;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.mintCardBorder),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Whisper for Voice Input', style: textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(
            ready
                ? 'Ready · ${VoiceInputController.modelSizeLabel}'
                : '${VoiceInputController.modelSizeLabel} one-time download',
            style: textTheme.bodySmall?.copyWith(color: AppColors.secondary),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: 14),
          Text(
            'Whisper is a small open source speech-to-text model by Openai that runs entirely on your '
            'phone. In the app you can navigate to the Ask page, tap the mic and speak your question. Whisper turns '
            'it into text on the device, so your voice is never uploaded anywhere. You '
            'can also set this up later in Settings.',
            style: textTheme.bodyMedium?.copyWith(
              color: AppColors.secondary,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

/// The four-segment onboarding progress bar (voice is the third step).
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
