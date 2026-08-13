import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../library/document.dart';
import 'trend_card.dart';
import 'trend_detail_screen.dart';
import 'trend_picker.dart';
import 'trend_prefs.dart';
import 'trend_series.dart';

/// Same test across reports; live doc list.
class TrendsView extends ConsumerWidget {
  const TrendsView({
    super.key,
    required this.documents,
    required this.onOpenDocument,
  });

  final List<CuraDocument> documents;
  final ValueChanged<CuraDocument> onOpenDocument;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final pinned = ref.watch(pinnedTrendsProvider).value ?? const <String>{};
    final scan = scanTrends(documents, pinned: pinned);
    final series = scan.series;

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Trends', style: textTheme.headlineMedium),
        const SizedBox(height: 2),
        Text(
          'The same test, over time',
          style: textTheme.bodyMedium?.copyWith(color: AppColors.secondary),
        ),
      ],
    );

    if (series.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        scan.others.isNotEmpty
                            ? 'None of the usual measures repeat yet, but '
                                  '${scan.others.length} others do. Pick any '
                                  'of them to chart.'
                            : 'A measure charts once it shows up in two or '
                                  'more of your reports.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: AppColors.secondary,
                        ),
                      ),
                      // Once-only tests: one more report away.
                      if (scan.others.isEmpty && scan.pending.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          'Read once so far: '
                          '${namesFrom([
                            for (final m in scan.pending) m.label,
                          ], cap: 12)}.',
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall?.copyWith(
                            color: AppColors.faint,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (!scan.isEmpty) _TrackButton(scan: scan),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
      children: [
        header,
        const SizedBox(height: 18),
        for (final s in series)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: TrendCard(
              series: s,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TrendDetailScreen(
                    seriesKey: s.key,
                    onOpenDocument: onOpenDocument,
                  ),
                ),
              ),
            ),
          ),
        _TrackButton(scan: scan),
      ],
    );
  }
}

/// Opens the measure picker.
class _TrackButton extends ConsumerWidget {
  const _TrackButton({required this.scan});

  final TrendScan scan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = scan.others.length + scan.pending.length;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: TextButton.icon(
        onPressed: () => showTrendPicker(context, ref, scan),
        icon: const Icon(Icons.add, size: 18),
        label: Text(
          waiting == 0 ? 'Track a measure' : 'Track one of $waiting more',
        ),
        style: TextButton.styleFrom(foregroundColor: AppColors.accent),
      ),
    );
  }
}

