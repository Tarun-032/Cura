import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import 'voice_input_controller.dart';

/// One-time prompt to download the on-device Whisper voice model. Mirrors
/// [ModelDownloadSheet] so setting up voice feels identical to setting up the
/// on-device LLM. Returns `true` (via pop) once the model is on disk.
class VoiceModelSheet extends StatefulWidget {
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
  State<VoiceModelSheet> createState() => _VoiceModelSheetState();
}

class _VoiceModelSheetState extends State<VoiceModelSheet> {
  bool _downloading = false;
  int _progress = 0;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _downloading = true;
      _error = null;
      _progress = 0;
    });
    try {
      await widget.voice.downloadModel(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
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
            if (_downloading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress / 100 : null,
                  minHeight: 8,
                  backgroundColor: AppColors.hairline,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _progress > 0 ? 'Downloading… $_progress%' : 'Starting…',
                style: textTheme.bodySmall,
              ),
            ] else ...[
              if (_error != null) ...[
                Text(
                  _error!,
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
                          _error == null
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
