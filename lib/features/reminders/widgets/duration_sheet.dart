import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../reminder.dart';

typedef CourseChoice = ({String label, int? printedDays});

/// Course length sheet.
Future<Map<String, int?>?> showDurationSheet(
  BuildContext context,
  List<CourseChoice> medicines,
) => showModalBottomSheet<Map<String, int?>>(
  context: context,
  backgroundColor: AppColors.surface,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => DurationSheet(medicines: medicines),
);

class DurationSheet extends StatefulWidget {
  const DurationSheet({super.key, required this.medicines});

  final List<CourseChoice> medicines;

  @override
  State<DurationSheet> createState() => _DurationSheetState();
}

class _DurationSheetState extends State<DurationSheet> {
  late final Map<String, int?> _days = {
    for (final m in widget.medicines) m.label: m.printedDays,
  };

  bool get _single => widget.medicines.length == 1;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                _single
                    ? 'How long did the doctor say to take this?'
                    : 'How long did the doctor say to take these?',
                style: textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_single)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('Set all', style: textTheme.bodySmall),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in kCourseOptions)
                        _Chip(
                          label: option.label,
                          onTap: () => _setAll(option.days),
                        ),
                      // Only route to an arbitrary date when there is one
                      // medicine: no rows, so no per-row menu.
                      _Chip(
                        label: 'Pick an end date',
                        onTap: () async {
                          final days = await _pickDays(context);
                          if (days != null) _setAll(days);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!_single) ...[
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    for (var i = 0; i < widget.medicines.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, color: AppColors.divider),
                      _MedicineRow(
                        medicine: widget.medicines[i],
                        days: _days[widget.medicines[i].label],
                        textTheme: textTheme,
                        onChanged: (days) => setState(
                          () => _days[widget.medicines[i].label] = days,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_days),
                  child: const Text('Set reminders'),
                ),
              ),
            ] else
              const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _setAll(int? days) {
    for (final label in _days.keys) {
      _days[label] = days;
    }
    if (_single) {
      Navigator.of(context).pop(_days);
    } else {
      setState(() {});
    }
  }
}

class _MedicineRow extends StatelessWidget {
  const _MedicineRow({
    required this.medicine,
    required this.days,
    required this.textTheme,
    required this.onChanged,
  });

  final CourseChoice medicine;
  final int? days;
  final TextTheme textTheme;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  medicine.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
                if (medicine.printedDays != null)
                  Text(
                    'from the prescription',
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.faint,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Fixed width so every arrow lines up down the column.
          SizedBox(
            width: 104,
            child: _CoursePicker(
              days: days,
              onChanged: onChanged,
              style: textTheme.bodyMedium,
              alignEnd: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _CoursePicker extends StatelessWidget {
  const _CoursePicker({
    required this.days,
    required this.onChanged,
    this.style,
    this.alignEnd = false,
  });

  final int? days;
  final ValueChanged<int?> onChanged;
  final TextStyle? style;

  /// Fill the given width, label to the right.
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Change how long',
      position: PopupMenuPosition.under,
      onSelected: (choice) async {
        if (choice < kCourseOptions.length) {
          onChanged(kCourseOptions[choice].days);
          return;
        }
        final picked = await _pickDays(context);
        if (picked != null) onChanged(picked);
      },
      itemBuilder: (_) => [
        for (var i = 0; i < kCourseOptions.length; i++)
          PopupMenuItem(value: i, child: Text(kCourseOptions[i].label)),
        PopupMenuItem(
          value: kCourseOptions.length,
          child: const Text('Pick an end date'),
        ),
      ],
      child: Row(
        mainAxisSize: alignEnd ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: alignEnd
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Text(
              courseLabel(days),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: alignEnd ? TextAlign.right : TextAlign.left,
              style: style?.copyWith(color: AppColors.accent),
            ),
          ),
          const Icon(
            Icons.arrow_drop_down,
            size: 20,
            color: AppColors.chevron,
          ),
        ],
      ),
    );
  }
}

Future<int?> _pickDays(BuildContext context) async {
  final today = DateTime.now();
  final start = DateTime(today.year, today.month, today.day);
  final last = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: start,
    lastDate: DateTime(start.year + 2, start.month, start.day),
    helpText: 'Take until',
  );
  return last == null ? null : daysBetween(start, last) + 1;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      onPressed: onTap,
      side: const BorderSide(color: AppColors.hairline),
      backgroundColor: AppColors.canvas,
      labelStyle: Theme.of(context).textTheme.bodyMedium,
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class CourseButton extends StatelessWidget {
  const CourseButton({super.key, required this.days, required this.onChanged});

  final int? days;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) => _CoursePicker(
    days: days,
    onChanged: onChanged,
    style: Theme.of(context).textTheme.bodySmall,
  );
}
