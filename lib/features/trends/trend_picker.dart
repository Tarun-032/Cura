import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import 'trend_prefs.dart';
import 'trend_series.dart';

/// Pin extra measures beyond the shortlist.
Future<void> showTrendPicker(
  BuildContext context,
  WidgetRef ref,
  TrendScan scan,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _TrendPicker(scan: scan),
  );
}

class _TrendPicker extends ConsumerWidget {
  const _TrendPicker({required this.scan});

  final TrendScan scan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final pinned = ref.watch(pinnedTrendsProvider).value ?? const <String>{};

    // Charted first, then once-only (pin now → charts on next read).
    final rows = <({String key, String label, String note})>[
      for (final s in scan.series)
        if (pinned.contains(s.key))
          (
            key: s.key,
            label: s.label,
            note: '${s.points.length} readings',
          ),
      for (final s in scan.others)
        (key: s.key, label: s.label, note: '${s.points.length} readings'),
      for (final m in scan.pending)
        (key: m.key, label: m.label, note: 'read once so far'),
    ];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Track a measure', style: textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Anything you pick here charts alongside the usual ones, '
                    'now and in every report you add later.',
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.secondary,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                      child: Text(
                        'Nothing else in your reports to track yet.',
                        style: textTheme.bodyMedium?.copyWith(
                          color: AppColors.faint,
                        ),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(top: 8, bottom: 16),
                      children: [
                        for (final row in rows)
                          CheckboxListTile(
                            value: pinned.contains(row.key),
                            onChanged: (on) async {
                              await setTrendPinned(row.key, on ?? false);
                              ref.invalidate(pinnedTrendsProvider);
                            },
                            activeColor: AppColors.accent,
                            title: Text(row.label, style: textTheme.bodyMedium),
                            subtitle: Text(
                              row.note,
                              style: textTheme.bodySmall?.copyWith(
                                color: AppColors.faint,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
