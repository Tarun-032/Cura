import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme/app_colors.dart';
import 'cura_mark.dart';

/// Intro clip plays once, then hands off to the exact static [CuraLogoHalo].
class CuraLogoIntro extends StatefulWidget {
  const CuraLogoIntro({super.key, this.size = 208});

  /// Halo diameter, matching [CuraLogoHalo.size].
  final double size;

  @override
  State<CuraLogoIntro> createState() => _CuraLogoIntroState();
}

class _CuraLogoIntroState extends State<CuraLogoIntro> {
  VideoPlayerController? _controller;

  /// True once the clip has played out (or was never going to).
  bool _settled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the system "remove animations" setting: never touch the decoder,
    // just show the static lockup.
    if (MediaQuery.of(context).disableAnimations) {
      _settled = true;
    } else if (_controller == null && !_settled) {
      _start();
    }
  }

  Future<void> _start() async {
    final controller = VideoPlayerController.asset(
      'assets/video/Cura_intro_1.mp4',
      // The clip still carries a silent audio track. Mixing keeps Android from
      // taking audio focus and ducking whatever the user is already playing.
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller = controller;
    controller.addListener(_onTick);
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.play();
    } catch (_) {
      // Asset missing or no decoder — fall back to the static lockup.
      _settle();
      return;
    }
    if (mounted) setState(() {});
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    // Some platforms stop slightly short of the reported duration.
    final left = controller.value.duration - controller.value.position;
    if (controller.value.isCompleted ||
        left <= const Duration(milliseconds: 60)) {
      _settle();
    }
  }

  /// Swap to the static lockup and let the decoder go.
  void _settle() {
    if (_settled) return;
    _settled = true;
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    _controller = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    // While the decoder spins up, keep the space empty; the clip starts on a
    // bare canvas, so showing the settled logo would flash.
    final Widget child;
    if (_settled) {
      child = CuraLogoHalo(key: const ValueKey('settled'), size: widget.size);
    } else if (!ready) {
      child = SizedBox.square(
        key: const ValueKey('warmup'),
        dimension: widget.size,
      );
    } else {
      child = SizedBox.square(
        key: const ValueKey('intro'),
        dimension: widget.size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoPlayer(controller),
            // Paint a radial fade over the video to feather its edges, match the halo, and avoid ShaderMask/saveLayer issues on Android.
            DecoratedBox(
              decoration: BoxDecoration(
                // Short fade to match the halo.
                gradient: RadialGradient(
                  radius: 0.5,
                  colors: [
                    AppColors.canvas.withValues(alpha: 0),
                    AppColors.canvas.withValues(alpha: 0),
                    AppColors.canvas,
                  ],
                  stops: const [0.0, 0.70, 1.0],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: child,
    );
  }
}
