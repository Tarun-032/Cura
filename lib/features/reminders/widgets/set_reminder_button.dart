import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/data/providers.dart';
import '../reminder.dart';
import '../reminder_screen.dart';
import '../reminder_service.dart';
import '../schedule_parser.dart';

/// Per-medicine remind chip.
class SetReminderButton extends ConsumerWidget {
  const SetReminderButton({
    super.key,
    required this.documentId,
    required this.documentTitle,
    required this.medicineLabel,
    required this.directions,
  });

  final String documentId;
  final String documentTitle;
  final String medicineLabel;

  /// Printed directions.
  final String directions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = [
      for (final r in ref.watch(remindersProvider).value ?? const [])
        if (r.documentId == documentId && r.medicineLabel == medicineLabel) r,
    ]..sort((a, b) => a.minuteOfDay.compareTo(b.minuteOfDay));

    if (mine.isEmpty) {
      return _Chip(
        icon: Icons.alarm_add_outlined,
        label: 'Remind',
        color: AppColors.accent,
        onTap: () => _set(context, ref),
      );
    }
    return _Chip(
      icon: Icons.alarm_on_outlined,
      label: mine.length == 1 ? mine.first.timeLabel : '${mine.length} doses',
      color: AppColors.secondary,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PrescriptionRemindersScreen(
            documentId: documentId,
            title: documentTitle,
          ),
        ),
      ),
    );
  }

  Future<void> _set(BuildContext context, WidgetRef ref) async {
    final parsed = parseMedicineSchedule(directions);
    // SOS / empty → manual pickers.
    final schedule = parsed == null
        ? await _pickOwn(context)
        : await showModalBottomSheet<MedicineSchedule>(
            context: context,
            backgroundColor: AppColors.surface,
            showDragHandle: true,
            builder: (_) =>
                _ChoiceSheet(medicineLabel: medicineLabel, parsed: parsed),
          );
    if (schedule == null || !context.mounted) return;

    final service = ref.read(reminderServiceProvider);
    if (!await service.requestPermissions()) {
      if (context.mounted) {
        _toast(context, 'Allow notifications to get medicine reminders.');
      }
      return;
    }

    final today = DateTime.now();
    final repository = ref.read(reminderRepositoryProvider);
    final saved = await repository.addAll(
      documentId: documentId,
      medicineLabel: medicineLabel,
      minutes: schedule.times,
      startDate: DateTime(today.year, today.month, today.day),
      endDate: courseEnd(today, schedule.days),
    );
    await service.sync(await repository.all());

    if (!context.mounted) return;
    final times = saved.map((r) => r.timeLabel).join(', ');
    final until = schedule.days == null
        ? 'every day'
        : 'for ${schedule.days} days';
    _toast(context, 'Reminder set for $times, $until.');
    if (!await service.canScheduleExactly() && context.mounted) {
      _toast(
        context,
        'Reminders are on. Allow Alarms & reminders in system settings for '
        'exact times.',
      );
    }
  }

}

/// Remind all parseable medicines.
class RemindAllButton extends ConsumerWidget {
  const RemindAllButton({
    super.key,
    required this.documentId,
    required this.documentTitle,
    required this.medicines,
  });

  final String documentId;
  final String documentTitle;

  /// Medicines in card order.
  final List<({String label, String directions})> medicines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = [
      for (final r in ref.watch(remindersProvider).value ?? const [])
        if (r.documentId == documentId) r,
    ];
    if (mine.isNotEmpty) {
      return _Chip(
        icon: Icons.alarm_on_outlined,
        label: '${mine.length} set',
        color: AppColors.secondary,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PrescriptionRemindersScreen(
              documentId: documentId,
              title: documentTitle,
            ),
          ),
        ),
      );
    }
    return _Chip(
      icon: Icons.alarm_add_outlined,
      label: 'Remind for all',
      color: AppColors.accent,
      onTap: () => _setAll(context, ref),
    );
  }

  Future<void> _setAll(BuildContext context, WidgetRef ref) async {
    final schedules = <String, MedicineSchedule>{};
    for (final medicine in medicines) {
      final parsed = parseMedicineSchedule(medicine.directions);
      if (parsed != null) schedules.putIfAbsent(medicine.label, () => parsed);
    }
    if (schedules.isEmpty) {
      _toast(context, 'No times are printed here. Set these one at a time.');
      return;
    }

    final service = ref.read(reminderServiceProvider);
    if (!await service.requestPermissions()) {
      if (context.mounted) {
        _toast(context, 'Allow notifications to get medicine reminders.');
      }
      return;
    }

    final today = DateTime.now();
    final repository = ref.read(reminderRepositoryProvider);
    for (final entry in schedules.entries) {
      await repository.addAll(
        documentId: documentId,
        medicineLabel: entry.key,
        minutes: entry.value.times,
        startDate: DateTime(today.year, today.month, today.day),
        endDate: courseEnd(today, entry.value.days),
      );
    }
    await service.sync(await repository.all());

    if (!context.mounted) return;
    final skipped = medicines.length - schedules.length;
    _toast(
      context,
      'Reminders set for ${schedules.length} medicines.'
      '${skipped > 0 ? ' $skipped had no times printed.' : ''}',
    );
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
}

/// Printed vs custom time.
class _ChoiceSheet extends StatelessWidget {
  const _ChoiceSheet({required this.medicineLabel, required this.parsed});

  final String medicineLabel;
  final MedicineSchedule parsed;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final times = parsed.times.map(clockLabel).join(', ');
    final days = parsed.days;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(medicineLabel, style: textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(
              Icons.medication_outlined,
              color: AppColors.accent,
            ),
            title: const Text('Use the printed directions'),
            subtitle: Text(
              '$times · ${days == null ? 'every day' : 'for $days days'}',
            ),
            onTap: () => Navigator.of(context).pop(parsed),
          ),
          ListTile(
            leading: const Icon(Icons.schedule, color: AppColors.accent),
            title: const Text('Choose the time myself'),
            subtitle: const Text('Pick a time, then how long'),
            onTap: () async {
              final own = await _pickOwn(context);
              if (own != null && context.mounted) {
                Navigator.of(context).pop(own);
              }
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Time picker, then optional end date.
Future<MedicineSchedule?> _pickOwn(BuildContext context) async {
  final time = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 8, minute: 0),
    helpText: 'Remind me at',
  );
  if (time == null || !context.mounted) return null;

  final today = DateTime.now();
  final start = DateTime(today.year, today.month, today.day);
  final last = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: start,
    lastDate: DateTime(start.year + 1, start.month, start.day),
    helpText: 'Take until',
    cancelText: 'No end date',
  );
  return MedicineSchedule(
    [time.hour * 60 + time.minute],
    days: last == null ? null : last.difference(start).inDays + 1,
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: color,
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: color)),
      onPressed: onTap,
    );
  }
}
