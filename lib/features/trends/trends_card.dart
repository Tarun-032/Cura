import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../library/document.dart';
import '../library/result_range.dart';
import 'trend_chart.dart';
import 'trend_prefs.dart';
import 'trend_series.dart';

/// Home Trends entry; hidden until something trends.
class TrendsCard extends ConsumerWidget {
  const TrendsCard({super.key, required this.documents, required this.onTap});

  final List<CuraDocument> documents;
  final VoidCallback onTap;

  /// Preview row count.
  static const _preview = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(pinnedTrendsProvider).value ?? const <String>{};
    final scan = scanTrends(documents, pinned: pinned);
    // Nothing to show.
    if (scan.isEmpty) return const SizedBox.shrink();

    final textTheme = Theme.of(context).textTheme;
    final shown = scan.series.take(_preview).toList();
    final rest = scan.series.length - shown.length;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.hairline),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Trends', style: textTheme.titleMedium),
                    ),
                    Text(
                      shown.isEmpty
                          ? 'Not yet'
                          : (rest > 0 ? '$rest more' : 'See all'),
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.secondary,
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: AppColors.chevron),
                  ],
                ),
                // Empty preview: say what's waiting.
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      scan.others.isNotEmpty
                          ? '${scan.others.length} measures ready to track.'
                          : 'Waiting on a second reading of '
                                '${namesFrom([
                                  for (final m in scan.pending) m.label,
                                ])}.',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.secondary,
                      ),
                    ),
                  ),
                for (final s in shown) ...[
                  const SizedBox(height: 4),
                  _PreviewRow(series: s),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Name · sparkline · value (fixed value column).
class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.series});

  final TrendSeries series;

  /// Fits "13.0 gm/dL".
  static const _valueWidth = 86.0;
  static const _sparkWidth = 48.0;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final verdict = verdictFor(series.latest.result).label;

    return SizedBox(
      // Fixed row height.
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: Text(
              series.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: _sparkWidth,
            child: TrendChart(series: series, compact: true),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: _valueWidth,
            child: Text(
              series.latest.result.valueWithUnit,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: textTheme.titleMedium?.copyWith(
                fontSize: 14.5,
                color: verdict == null ? AppColors.ink : AppColors.destructive,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
