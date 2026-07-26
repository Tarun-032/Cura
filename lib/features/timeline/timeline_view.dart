import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../app/theme/app_colors.dart';
import '../library/document.dart';
import '../library/widgets/document_row.dart';

/// Chronological "what happened, when": the user's
/// documents grouped by month on a vertical timeline rail. Reads the same live
/// document list as the Library.
class TimelineView extends StatelessWidget {
  const TimelineView({
    super.key,
    required this.documents,
    required this.onOpenDocument,
  });

  final List<CuraDocument> documents;
  final ValueChanged<CuraDocument> onOpenDocument;

  static const List<String> _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  List<MapEntry<String, List<CuraDocument>>> _groupByMonth() {
    final sorted = [...documents]..sort((a, b) => b.date.compareTo(a.date));
    final map = <String, List<CuraDocument>>{};
    for (final d in sorted) {
      final key = '${_monthNames[d.date.month - 1]} ${d.date.year}';
      map.putIfAbsent(key, () => []).add(d);
    }
    return map.entries.toList();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Timeline', style: textTheme.headlineMedium),
        const SizedBox(height: 2),
        Text(
          'What happened, when',
          style: textTheme.bodyMedium?.copyWith(color: AppColors.secondary),
        ),
      ],
    );

    if (documents.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'Nothing here yet. Scan a document to start your timeline.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 14.5,
                      height: 1.5,
                      color: AppColors.faint,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final groups = _groupByMonth();
    final children = <Widget>[header, const SizedBox(height: 18)];
    var entryIndex = 0;

    for (final group in groups) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 12),
          child: Text(group.key, style: textTheme.titleMedium),
        ),
      );
      for (var i = 0; i < group.value.length; i++) {
        final doc = group.value[i];
        final entry = _TimelineEntry(
          document: doc,
          isLastInMonth: i == group.value.length - 1,
          onTap: () => onOpenDocument(doc),
        );
        // Only the first screenful animates in. Entries below the fold mount
        // when scrolled into view, so a delayed fade there shows as a blank row.
        children.add(
          entryIndex > 6
              ? entry
              : entry
                  .animate()
                  .fadeIn(duration: 250.ms, delay: (entryIndex * 40).ms)
                  .slideY(begin: 0.12, curve: Curves.easeOutCubic),
        );
        entryIndex++;
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
      children: children,
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.document,
    required this.isLastInMonth,
    required this.onTap,
  });

  final CuraDocument document;
  final bool isLastInMonth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Rail + node gutter.
          SizedBox(
            width: 28,
            child: Stack(
              children: [
                // Vertical rail (stops short on the last entry of a month).
                Positioned(
                  left: 13.25,
                  top: 0,
                  bottom: isLastInMonth ? null : 0,
                  height: isLastInMonth ? 14 : null,
                  child: Container(width: 1.5, color: AppColors.hairline),
                ),
                // Node circle, aligned to the date label.
                Positioned(
                  left: 7,
                  top: 2,
                  child: Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: document.type.accentColor,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Date label + card.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  document.shortDateLabel,
                  style: textTheme.bodySmall?.copyWith(
                    color: AppColors.secondary,
                  ),
                ),
                const SizedBox(height: 6),
                DocumentRow(
                  document: document,
                  metadata: document.type.label,
                  showChevron: false,
                  onTap: onTap,
                ),
                const SizedBox(height: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
