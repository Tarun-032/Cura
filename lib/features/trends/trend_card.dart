import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../library/result_range.dart';
import 'trend_chart.dart';
import 'trend_series.dart';

/// Shared Trends text size (a step above list rows).
const kTrendTextSize = 16.5;

/// Meta under the value.
const kTrendMetaSize = 13.5;

/// Reading-row text under a chart.
const kTrendRowTextSize = 15.0;

/// One measure card; tap opens its readings.
class TrendCard extends StatelessWidget {
  const TrendCard({super.key, required this.series, this.onTap});

  final TrendSeries series;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final latest = series.latest;
    final verdict = verdictFor(latest.result).label;
    final range = rangeText(latest.result);

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      series.label,
                      style: textTheme.bodyMedium?.copyWith(
                        fontSize: kTrendTextSize,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    latest.result.valueWithUnit,
                    // Same size, medium weight.
                    style: textTheme.titleMedium?.copyWith(
                      fontSize: kTrendTextSize,
                      color: verdict == null
                          ? AppColors.ink
                          : AppColors.destructive,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  '${series.points.length} readings',
                  ?verdict,
                  if (range != null) 'normal $range',
                ].join(' · '),
                style: textTheme.bodySmall?.copyWith(
                  fontSize: kTrendMetaSize,
                  color: AppColors.faint,
                ),
              ),
              const SizedBox(height: 8),
              TrendChart(series: series),
            ],
          ),
        ),
      ),
    );
  }
}
