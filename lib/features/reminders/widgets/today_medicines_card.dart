import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/data/providers.dart';
import '../../library/document.dart';
import '../reminder.dart';
import '../reminder_screen.dart';

class TodayMedicinesCard extends ConsumerStatefulWidget {
  const TodayMedicinesCard({super.key});

  @override
  ConsumerState<TodayMedicinesCard> createState() => _TodayMedicinesCardState();
}

class _TodayMedicinesCardState extends ConsumerState<TodayMedicinesCard> {
  final _open = <String>{};
  bool _doneOpen = false;
  static const _maxRows = 3;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final reminders = ref.watch(remindersProvider).value ?? const [];
    final due = dosesOn(reminders, now);
    if (due.isEmpty) return const SizedBox.shrink();

    final textTheme = Theme.of(context).textTheme;
    final docs = ref.watch(documentsProvider).value ?? const <CuraDocument>[];

    final groups = <String, List<MedicineReminder>>{};
    for (final dose in due) {
      groups.putIfAbsent(dose.documentId, () => []).add(dose);
    }

    final active = <MapEntry<String, List<MedicineReminder>>>[];
    final done = <MedicineReminder>[];
    for (final entry in groups.entries) {
      if (entry.value.every((d) => d.takenOn(now))) {
        done.addAll(entry.value);
      } else {
        active.add(entry);
      }
    }
    final shown = active.take(_maxRows).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: Text("Today's medicines", style: textTheme.bodySmall),
            ),
            Text(
              active.isEmpty ? 'All done' : '${dosesLeftToday(reminders, now)} left',
              style: textTheme.bodySmall?.copyWith(
                color: active.isEmpty ? AppColors.accent : AppColors.faint,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              if (active.isEmpty)
                _Line(
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        size: 20,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'All done for today',
                          style: textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              for (var i = 0; i < shown.length; i++)
                _Line(
                  divided: i > 0,
                  child: _PrescriptionGroup(
                    title:
                        findDocumentById(
                          docs,
                          shown[i].value.first.documentId,
                        )?.title ??
                        'Prescription',
                    doses: shown[i].value,
                    now: now,
                    open: _open.contains(shown[i].key),
                    onToggle: () => setState(
                      () => _open.contains(shown[i].key)
                          ? _open.remove(shown[i].key)
                          : _open.add(shown[i].key),
                    ),
                  ),
                ),
              if (active.length > shown.length)
                _Line(
                  divided: true,
                  child: _LinkRow(
                    label: '${active.length - shown.length} more',
                    onTap: _openAll,
                  ),
                ),
              if (done.isNotEmpty)
                _Line(
                  divided: true,
                  child: _DoneSection(
                    doses: done,
                    open: _doneOpen,
                    onToggle: () => setState(() => _doneOpen = !_doneOpen),
                  ),
                ),
              _Line(
                divided: true,
                child: _LinkRow(label: 'All reminders', onTap: _openAll),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _openAll() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const ReminderScreen()),
  );
}

class _Line extends StatelessWidget {
  const _Line({required this.child, this.divided = false});

  final Widget child;
  final bool divided;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (divided) const Divider(height: 1, color: AppColors.divider),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: child,
        ),
      ],
    );
  }
}

class _PrescriptionGroup extends ConsumerWidget {
  const _PrescriptionGroup({
    required this.title,
    required this.doses,
    required this.now,
    required this.open,
    required this.onToggle,
  });

  final String title;
  final List<MedicineReminder> doses;
  final DateTime now;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final taken = doses.where((d) => d.takenOn(now)).length;

    final slots = <int, List<MedicineReminder>>{};
    for (final dose in doses) {
      slots.putIfAbsent(dose.minuteOfDay, () => []).add(dose);
    }
    final times = slots.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          child: Row(
            children: [
              Icon(
                open ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: AppColors.chevron,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      times.map(clockLabel).join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.faint,
                      ),
                    ),
                    if (courseProgress(doses, now) case final progress?)
                      Text(
                        progress,
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.secondary,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$taken/${doses.length}',
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.secondary,
                ),
              ),
            ],
          ),
        ),
        if (open)
          for (final time in times) ...[
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      clockLabel(time),
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.faint,
                      ),
                    ),
                  ),
                  if (slots[time]!.any((d) => !d.takenOn(now)))
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => ref
                          .read(reminderRepositoryProvider)
                          .setTaken([for (final d in slots[time]!) d.id], now),
                      child: Text(
                        'Mark all taken',
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            for (final dose in slots[time]!)
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: _DoseRow(
                  dose: dose,
                  taken: dose.takenOn(now),
                  textTheme: textTheme,
                  onTap: () => ref
                      .read(reminderRepositoryProvider)
                      .setTaken([dose.id], dose.takenOn(now) ? null : now),
                ),
              ),
          ],
      ],
    );
  }
}

class _DoneSection extends ConsumerWidget {
  const _DoneSection({
    required this.doses,
    required this.open,
    required this.onToggle,
  });

  final List<MedicineReminder> doses;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      children: [
        InkWell(
          onTap: onToggle,
          child: Row(
            children: [
              Icon(
                open ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: AppColors.chevron,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Done today · ${doses.length}',
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.secondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (open)
          for (final dose in doses)
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: _DoseRow(
                dose: dose,
                taken: true,
                textTheme: textTheme,
                onTap: () => ref
                    .read(reminderRepositoryProvider)
                    .setTaken([dose.id], null),
              ),
            ),
      ],
    );
  }
}

class _DoseRow extends StatelessWidget {
  const _DoseRow({
    required this.dose,
    required this.taken,
    required this.textTheme,
    required this.onTap,
  });

  final MedicineReminder dose;
  final bool taken;
  final TextTheme textTheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(
              taken ? Icons.check_circle : Icons.circle_outlined,
              size: 20,
              color: taken ? AppColors.accent : AppColors.chevron,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                dose.medicineLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  color: taken ? AppColors.faint : AppColors.ink,
                  decoration: taken ? TextDecoration.lineThrough : null,
                  decorationColor: AppColors.faint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.secondary,
              ),
            ),
          ),
          const Icon(Icons.chevron_right, size: 18, color: AppColors.chevron),
        ],
      ),
    );
  }
}
