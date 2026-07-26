import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/data/providers.dart';
import '../../core/widgets/cura_spark.dart';
import '../ai/ai_models.dart';
import '../ai/ai_providers.dart';
import '../ask/voice_input_controller.dart';
import 'settings_view.dart' show SettingsChevron;
import 'storage_info.dart';

// Storage category colors. Documents blue and cache olive are used only on this
// screen, so they live here rather than in AppColors.
const _docsDot = Color(0xFF8FC2E0);
const _docsTile = Color(0xFFEAF3FA);
const _docsIcon = Color(0xFF5B93B8);
const _cacheDot = Color(0xFFC2C78F);
const _cacheIcon = Color(0xFF97A98C);

/// Settings → Storage: a donut breakdown of what Cura keeps on the device
/// (AI models, documents, voice model, cache) plus per-category management —
/// model deletion reuses the same manager flows as the Settings model cards.
class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  bool _modelsExpanded = false;
  final VoiceInputController _voice = VoiceInputController();

  @override
  void dispose() {
    _voice.dispose();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _deleteModel(AiModel model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this model?'),
        content: Text(
          '${model.displayName} (${model.sizeLabel}) will be removed from this '
          'device. You can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Release any loaded model before deleting its file, same as Settings.
    ref.invalidate(aiServiceProvider);
    await ref.read(aiModelManagerProvider).delete(model);
    ref.invalidate(aiModelStateProvider);
    ref.invalidate(storageBreakdownProvider);
    _toast('Model deleted');
  }

  Future<void> _deleteVoiceModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete the voice model?'),
        content: const Text(
          'The voice model (${VoiceInputController.modelSizeLabel}) will be '
          'removed from this device. You can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _voice.deleteModel();
    ref.invalidate(voiceModelReadyProvider);
    ref.invalidate(storageBreakdownProvider);
    _toast('Voice model deleted');
  }

  Future<void> _clearCache() async {
    await clearCache();
    ref.invalidate(storageBreakdownProvider);
    _toast('Cache cleared');
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final breakdown = ref.watch(storageBreakdownProvider).value;
    final modelState = ref.watch(aiModelStateProvider).value;
    final voiceReady = ref.watch(voiceModelReadyProvider).value ?? false;
    final records = ref.watch(documentsProvider).value?.length ?? 0;
    final installed = modelState == null
        ? const <AiModel>[]
        : [
            for (final m in kAiModelCatalog)
              if (modelState.installed.contains(m.id)) m,
          ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppColors.canvas,
      ),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                    color: AppColors.ink,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
                  children: [
                    Text('Storage', style: textTheme.headlineMedium),
                    const SizedBox(height: 16),
                    _SummaryCard(breakdown: breakdown),
                    const SizedBox(height: 22),
                    Text(
                      'Manage storage',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.secondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.hairline),
                      ),
                      child: Column(
                        children: [
                          _CategoryRow(
                            iconTile: const CuraSpark(size: 32),
                            tileColor: AppColors.softTint,
                            title: 'AI models',
                            subtitle: installed.isEmpty
                                ? 'No models installed'
                                : installed.length == 1
                                ? '1 language model installed'
                                : '${installed.length} language models installed',
                            size: breakdown == null
                                ? null
                                : formatBytes(breakdown.aiModels),
                            trailing: AnimatedRotation(
                              turns: _modelsExpanded ? 0.25 : 0,
                              duration: const Duration(milliseconds: 180),
                              child: const SettingsChevron(),
                            ),
                            onTap: installed.isEmpty
                                ? null
                                : () => setState(
                                    () => _modelsExpanded = !_modelsExpanded,
                                  ),
                          ),
                          if (_modelsExpanded)
                            for (final model in installed)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  64,
                                  0,
                                  8,
                                  4,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${model.displayName} · ${model.sizeLabel}',
                                        style: textTheme.bodySmall,
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () => _deleteModel(model),
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: AppColors.destructive,
                                        size: 20,
                                      ),
                                      tooltip: 'Delete',
                                    ),
                                  ],
                                ),
                              ),
                          const _RowDivider(),
                          _CategoryRow(
                            iconTile: const Icon(
                              Icons.description_outlined,
                              size: 20,
                              color: _docsIcon,
                            ),
                            tileColor: _docsTile,
                            title: 'Documents',
                            subtitle: records == 1
                                ? '1 scanned record'
                                : '$records scanned records',
                            size: breakdown == null
                                ? null
                                : formatBytes(breakdown.documents),
                          ),
                          const _RowDivider(),
                          _CategoryRow(
                            iconTile: const Icon(
                              Icons.mic_none,
                              size: 20,
                              color: AppColors.mint,
                            ),
                            tileColor: AppColors.softTint,
                            title: 'Voice model',
                            subtitle: voiceReady
                                ? 'Whisper · on-device'
                                : 'Not downloaded',
                            size: breakdown == null
                                ? null
                                : formatBytes(breakdown.voiceModel),
                            trailing: voiceReady
                                ? IconButton(
                                    onPressed: _deleteVoiceModel,
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: AppColors.destructive,
                                      size: 22,
                                    ),
                                    tooltip: 'Delete',
                                  )
                                : null,
                          ),
                          const _RowDivider(),
                          _CategoryRow(
                            iconTile: const Icon(
                              Icons.layers_outlined,
                              size: 20,
                              color: _cacheIcon,
                            ),
                            tileColor: AppColors.divider,
                            title: 'Cache & temporary files',
                            subtitle: 'Safe to clear',
                            size: breakdown == null
                                ? null
                                : formatBytes(breakdown.cache),
                            trailing: IconButton(
                              onPressed: _clearCache,
                              icon: const Icon(
                                Icons.delete_outline,
                                color: AppColors.destructive,
                                size: 22,
                              ),
                              tooltip: 'Clear cache',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// White card with the donut chart, centered total, and 2-column legend.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.breakdown});

  final StorageBreakdown? breakdown;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final b = breakdown;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.hairline),
      ),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        children: [
          SizedBox(
            width: 148,
            height: 148,
            child: Stack(
              alignment: Alignment.center,
              children: [
                TweenAnimationBuilder<double>(
                  // Remount when data loads so the ring sweeps from 0 over real values.
                  key: ValueKey(b != null),
                  tween: Tween(begin: 0, end: b == null ? 0 : 1),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => CustomPaint(
                    size: const Size(148, 148),
                    painter: _DonutPainter(b, t),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      b == null ? '…' : formatBytes(b.total),
                      style: const TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        fontVariations: [FontVariation('wght', 600)],
                        color: AppColors.ink,
                      ),
                    ),
                    Text(
                      'used by Cura',
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        color: AppColors.faint,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _Legend(
                color: AppColors.accent,
                label: 'AI models',
                size: b == null ? '' : formatBytes(b.aiModels),
              ),
              const SizedBox(width: 16),
              _Legend(
                color: _docsDot,
                label: 'Documents',
                size: b == null ? '' : formatBytes(b.documents),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Legend(
                color: AppColors.mint,
                label: 'Voice model',
                size: b == null ? '' : formatBytes(b.voiceModel),
              ),
              const SizedBox(width: 16),
              _Legend(
                color: _cacheDot,
                label: 'Cache',
                size: b == null ? '' : formatBytes(b.cache),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label, required this.size});

  final Color color;
  final String label;
  final String size;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              style: textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                color: AppColors.ink,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            size,
            style: textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: AppColors.faint,
            ),
          ),
        ],
      ),
    );
  }
}

/// Ring segments drawn clockwise from 12 o'clock over a full faint track.
class _DonutPainter extends CustomPainter {
  const _DonutPainter(this.breakdown, [this.progress = 1]);

  final StorageBreakdown? breakdown;

  /// 0→1 sweep: draws only the leading `2π·progress` of the ring, so it fills
  /// clockwise from 12 o'clock as this grows.
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 18.0;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;

    paint.color = AppColors.divider;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint);

    final b = breakdown;
    if (b == null || b.total == 0) return;

    final segments = [
      (b.aiModels, AppColors.accent),
      (b.documents, _docsDot),
      (b.voiceModel, AppColors.mint),
      (b.cache, _cacheDot),
    ];
    final revealed = 2 * math.pi * progress; // leading edge from 12 o'clock
    var start = -math.pi / 2;
    var drawn = 0.0;
    for (final (bytes, color) in segments) {
      if (bytes == 0) continue;
      final sweep = 2 * math.pi * bytes / b.total;
      final visible = (revealed - drawn).clamp(0.0, sweep);
      if (visible <= 0) break; // past the leading edge
      paint.color = color;
      canvas.drawArc(rect, start, visible, false, paint);
      start += sweep;
      drawn += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.breakdown != breakdown;
}

/// A manage-storage row: icon tile, title/subtitle, right-aligned size, and an
/// optional trailing control (chevron / delete / clear pill).
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.iconTile,
    required this.tileColor,
    required this.title,
    required this.subtitle,
    required this.size,
    this.trailing,
    this.onTap,
  });

  final Widget iconTile;
  final Color tileColor;
  final String title;
  final String subtitle;
  final String? size;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: tileColor,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: iconTile,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            size ?? '…',
            style: textTheme.bodySmall?.copyWith(fontSize: 13.5),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: content,
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      thickness: 1,
      indent: 64,
      color: AppColors.divider,
    );
  }
}
