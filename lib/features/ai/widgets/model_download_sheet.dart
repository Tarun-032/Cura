import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/widgets/cura_spark.dart';
import '../ai_models.dart';
import '../ai_providers.dart';

/// Notes that a different model is mid-download and returns true so the caller
/// skips the sheet. No progress here: it would read as the model just tapped.
Future<bool> warnIfAnotherModelIsDownloading(
  BuildContext context,
  WidgetRef ref,
  AiModel wanted,
) async {
  final running = ref.read(llmDownloadProvider);
  if (running == null ||
      !running.running ||
      running.fileName == wanted.fileName) {
    return false;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('One model at a time'),
      content: Text(
        '${running.name} is still downloading. Wait for it to finish, or '
        'cancel it from the notification, then download '
        '${wanted.displayName}.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
  return true;
}

/// Bottom sheet offering to download an on-device model, popping `true` once one
/// is installed. Pass a [model] to download that one, or none to show the full
/// catalog as a picker.
class ModelDownloadSheet extends ConsumerStatefulWidget {
  const ModelDownloadSheet({super.key, this.model, this.recommendedId});

  /// The single model to download. When null, the sheet shows the catalog and
  /// lets the user pick one.
  final AiModel? model;

  /// In picker mode, the catalog id to pre-select and badge "Recommended"
  /// (e.g. the onboarding hardware-scan pick). Ignored when [model] is set.
  final String? recommendedId;

  /// Resolves true once a model is installed, false on any back-out. False
  /// covers both "Not now" and "Continue in background", so a caller that needs
  /// to tell them apart checks `llmDownloadProvider`.
  static Future<bool?> show(
    BuildContext context, [
    AiModel? model,
    String? recommendedId,
  ]) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) =>
          ModelDownloadSheet(model: model, recommendedId: recommendedId),
    );
  }

  @override
  ConsumerState<ModelDownloadSheet> createState() => _ModelDownloadSheetState();
}

class _ModelDownloadSheetState extends ConsumerState<ModelDownloadSheet> {
  /// Set on tap so the sheet shows progress before the native side reports.
  bool _starting = false;
  String? _error;

  /// The model that will be downloaded. Fixed when [widget.model] is set;
  /// otherwise the user's current pick from the catalog — defaulting to the
  /// recommended model (hardware scan) if one was passed, else the catalog default.
  late AiModel _selected =
      widget.model ?? aiModelById(widget.recommendedId) ?? kDefaultModel;

  /// Whether the user gets to choose (no fixed model was passed in).
  bool get _picker => widget.model == null;

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final started = await ref
          .read(aiModelManagerProvider)
          .download(_selected, ref.read(modelDownloaderProvider));
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
    final download = ref.watch(llmDownloadProvider);
    ref.listen(llmDownloadProvider, (previous, next) {
      if (!mounted) return;
      // Gone means done, but only claim it for our own model.
      if (previous != null &&
          next == null &&
          previous.fileName == _selected.fileName) {
        Navigator.of(context).pop(true);
      } else if (next?.error != null && _starting) {
        setState(() => _starting = false);
      }
    });
    // Ignore the previous attempt's error mid-retry, or Retry shows it back.
    final error = _starting ? null : (download?.error ?? _error);
    final downloading = _starting || (download != null && download.running);
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
                const CuraSpark(size: 32),
                const SizedBox(width: 10),
                Text('Set up AI', style: textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _picker
                  ? 'Choose a model to answer questions about your documents. '
                        'Download it once, then switch models later in Settings.'
                  : 'Download the ${_selected.sizeLabel} model once to tidy up '
                        'scanned documents.',
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
                      null => 'Starting…',
                      final d when d.paused => 'Paused, waiting to reconnect…',
                      // Name from the download, never from _selected.
                      final d when d.percent > 0 =>
                        'Downloading ${d.name}… ${d.percent}%',
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
              // Catalog picker — only when no specific model was requested.
              if (_picker) ...[
                for (final model in kAiModelCatalog)
                  _ModelChoice(
                    model: model,
                    selected: model.id == _selected.id,
                    recommended: model.id == widget.recommendedId,
                    onTap: () => setState(() => _selected = model),
                  ),
                const SizedBox(height: 12),
              ],
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
                              ? 'Download (${_selected.sizeLabel})'
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

/// A selectable model row in the picker: name, size, and a radio indicator.
class _ModelChoice extends StatelessWidget {
  const _ModelChoice({
    required this.model,
    required this.selected,
    required this.onTap,
    this.recommended = false,
  });

  final AiModel model;
  final bool selected;
  final bool recommended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? AppColors.softTint : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? AppColors.accent : AppColors.hairline,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: selected ? AppColors.accent : AppColors.chevron,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(model.displayName, style: textTheme.bodyMedium),
                      const SizedBox(height: 2),
                      Text(model.sizeLabel, style: textTheme.bodySmall),
                      if (recommended) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.softTint,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'Recommended for your device',
                            style: TextStyle(
                              fontFamily: 'PlusJakartaSans',
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              fontVariations: [FontVariation('wght', 600)],
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
