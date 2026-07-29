import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../ai/ai_providers.dart';
import 'voice_input_controller.dart';

/// One-time prompt to download the on-device Whisper voice model. Mirrors
/// [ModelDownloadSheet] so setting up voice feels identical to setting up the
/// on-device LLM. Returns `true` (via pop) once the model is on disk.
class VoiceModelSheet extends ConsumerStatefulWidget {
  const VoiceModelSheet({super.key, required this.voice});

  final VoiceInputController voice;

  /// Shows the sheet; resolves to true when the model finishes downloading.
  static Future<bool?> show(BuildContext context, VoiceInputController voice) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => VoiceModelSheet(voice: voice),
    );
  }

  @override
  ConsumerState<VoiceModelSheet> createState() => _VoiceModelSheetState();
}

class _VoiceModelSheetState extends ConsumerState<VoiceModelSheet> {
  /// Set on tap so the sheet shows progress before the native side reports.
  bool _starting = false;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final started = await widget.voice.downloadModel(
        ref.read(modelDownloaderProvider),
      );
      // Already on disk, so there is no transfer to watch.
      if (!started && mounted) Navigator.of(context).pop(true);
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
    // From the provider, not local state, so reopening picks up where it is.
    final download = ref.watch(voiceDownloadProvider);
    ref.listen(voiceDownloadProvider, (previous, next) {
      if (!mounted) return;
      // Gone means done; a failure reports through ModelDownload.error.
      if (previous != null && next == null) {
        Navigator.of(context).pop(true);
      } else if (next?.error != null && _starting) {
        setState(() => _starting = false);
      }
    });
    // Ignore the previous attempt's error mid-retry, or Retry shows it back.
    final error = _starting ? null : (download?.error ?? _error);
    final downloading =
        _starting || (download != null && download.error == null);
    final progress = download?.percent ?? 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.mic_none, color: AppColors.mint, size: 22),
                const SizedBox(width: 10),
                Text('Set up voice input', style: textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Voice input uses a small speech model. Download it once '
              '(${VoiceInputController.modelSizeLabel}) to turn speech into text.',
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.secondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),
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
              Row(
                children: [
                  Expanded(
                    child: Text(switch (download) {
                      final d? when d.paused => 'Paused, waiting to reconnect…',
                      final d? when d.percent > 0 =>
                        'Downloading… ${d.percent}%',
                      _ => 'Starting…',
                    }, style: textTheme.bodySmall),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.secondary,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Continue in background'),
                  ),
                ],
              ),
            ] else ...[
              if (error != null) ...[
                Text(
                  error,
                  style: textTheme.bodySmall?.copyWith(
                    color: AppColors.destructive,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _start,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: AppColors.canvas,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          textStyle: const TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: 15.5,
                            fontWeight: FontWeight.w500,
                            fontVariations: [FontVariation('wght', 500)],
                          ),
                        ),
                        child: Text(
                          error == null
                              ? 'Download (${VoiceInputController.modelSizeLabel})'
                              : 'Retry',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.secondary,
                    ),
                    child: const Text('Not now'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
