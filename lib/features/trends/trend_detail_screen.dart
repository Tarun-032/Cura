import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/data/providers.dart';
import '../../core/widgets/working_label.dart';
import '../library/document.dart';
import '../library/result_range.dart';
import 'trend_card.dart';
import 'trend_note.dart';
import 'trend_series.dart';

/// Chart + source reports. Rebuilds from live docs via [seriesKey].
class TrendDetailScreen extends ConsumerWidget {
  const TrendDetailScreen({
    super.key,
    required this.seriesKey,
    required this.onOpenDocument,
  });

  final String seriesKey;
  final ValueChanged<CuraDocument> onOpenDocument;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final documents = ref.watch(documentsProvider).value ?? const [];
    final scan = scanTrends(documents);

    TrendSeries? series;
    for (final s in [...scan.series, ...scan.others]) {
      if (s.key == seriesKey) series = s;
    }

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.ink),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(series?.label ?? 'Trend', style: textTheme.titleMedium),
      ),
      body: SafeArea(
        top: false,
        child: series == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'This measure is down to one reading, so there is no '
                    'longer a trend to draw.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: AppColors.secondary,
                    ),
                  ),
                ),
              )
            : _Readings(
                series: series,
                documents: documents,
                onOpenDocument: onOpenDocument,
              ),
      ),
    );
  }
}

class _Readings extends StatelessWidget {
  const _Readings({
    required this.series,
    required this.documents,
    required this.onOpenDocument,
  });

  final TrendSeries series;
  final List<CuraDocument> documents;
  final ValueChanged<CuraDocument> onOpenDocument;

  CuraDocument? _documentFor(TrendPoint p) {
    for (final d in documents) {
      if (d.id == p.documentId) return d;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Newest first.
    final readings = series.points.reversed.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: [
        TrendCard(series: series),
        _TrendNote(series: series),
        const SizedBox(height: 22),
        Text('Where these came from', style: textTheme.bodySmall),
        const SizedBox(height: 12),
        for (var i = 0; i < readings.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _ReadingRow(
            point: readings[i],
            document: _documentFor(readings[i]),
            onTap: () {
              final doc = _documentFor(readings[i]);
              if (doc != null) onOpenDocument(doc);
            },
          ),
        ],
      ],
    );
  }
}

String _breakable(String s) =>
    s.replaceAll(RegExp('[\u00A0\u2007\u2009\u202F\u2060\uFEFF]'), ' ');

/// Chart note block; hidden until ready.
class _TrendNote extends ConsumerWidget {
  const _TrendNote({required this.series});

  final TrendSeries series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final facts = trendFacts(series);
    final note = ref.watch(trendNoteProvider((key: series.key, facts: facts)));

    final line = textTheme.bodyMedium?.copyWith(
      fontSize: kTrendRowTextSize,
      height: 1.5,
    );

    final body = note.when(
      loading: () => const WorkingLabel(text: 'Reading the trend…'),
      // Provider refusal reason.
      error: (e, _) => e is TrendNoteFailure
          ? Text(e.message, style: line?.copyWith(color: AppColors.secondary))
          : null,
      data: (text) => text == null ? null : Text(_breakable(text), style: line),
    );
    if (body == null) return const SizedBox.shrink();

    // Match reports section spacing.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 22),
        Text('Summary', style: textTheme.bodySmall),
        const SizedBox(height: 12),

        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.hairline),
          ),
          child: body,
        ),
      ],
    );
  }
}

class _ReadingRow extends StatelessWidget {
  const _ReadingRow({
    required this.point,
    required this.document,
    required this.onTap,
  });

  final TrendPoint point;

  /// Null if the report was deleted mid-view.
  final CuraDocument? document;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final verdict = verdictFor(point.result).label;

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: document == null ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            children: [
              // Report first; value is already on the chart.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document?.title ?? 'Report removed',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        fontSize: kTrendRowTextSize,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '${point.dateLabel}, ${point.date.year}',
                        ?verdict,
                      ].join(' · '),
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 12.5,
                        color: AppColors.secondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                point.result.valueWithUnit,
                // Match card value styling.
                style: textTheme.titleMedium?.copyWith(
                  fontSize: kTrendRowTextSize,
                  color: verdict == null
                      ? AppColors.ink
                      : AppColors.destructive,
                ),
              ),
              if (document != null)
                const Icon(Icons.chevron_right, color: AppColors.chevron),
            ],
          ),
        ),
      ),
    );
  }
}
