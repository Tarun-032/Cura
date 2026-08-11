import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/data/providers.dart';
import '../library/document.dart';
import 'reminder.dart';
import 'reminder_service.dart';

/// Reminder list by prescription.
class ReminderScreen extends ConsumerWidget {
  const ReminderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final reminders = ref.watch(remindersProvider).value ?? const [];
    final docs = ref.watch(documentsProvider).value ?? const <CuraDocument>[];

    final byDocument = <String, List<MedicineReminder>>{};
    for (final r in reminders) {
      byDocument.putIfAbsent(r.documentId, () => []).add(r);
    }

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        surfaceTintColor: Colors.transparent,
        title: const Text('Reminders'),
      ),
      body: byDocument.isEmpty
          ? _Empty(textTheme: textTheme)
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: [
                for (final entry in byDocument.entries) ...[
                  _PrescriptionRow(
                    document: findDocumentById(docs, entry.key),
                    doses: entry.value,
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }
}

/// Doc for a reminder, or null if deleted.
CuraDocument? findDocumentById(List<CuraDocument> docs, String id) {
  for (final d in docs) {
    if (d.id == id) return d;
  }
  return null;
}

class _Empty extends StatelessWidget {
  const _Empty({required this.textTheme});

  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.notifications_none,
            size: 44,
            color: AppColors.chevron,
          ),
          const SizedBox(height: 14),
          Text('No reminders yet', style: textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Open a prescription and tap Set reminder on a medicine. Cura reads '
            'the directions to pick the times.',
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(color: AppColors.secondary),
          ),
        ],
      ),
    );
  }
}

/// One prescription summary row.
class _PrescriptionRow extends StatelessWidget {
  const _PrescriptionRow({required this.document, required this.doses});

  final CuraDocument? document;
  final List<MedicineReminder> doses;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final medicines = doses.map((d) => d.medicineLabel).toSet().length;
    final on = doses.where((d) => d.enabled).length;
    final id = doses.first.documentId;

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PrescriptionRemindersScreen(
              documentId: id,
              title: document?.title ?? 'Prescription',
            ),
          ),
        ),
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document?.title ?? 'Prescription',
                      style: textTheme.bodyMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$medicines ${medicines == 1 ? 'medicine' : 'medicines'} '
                      '· $on of ${doses.length} doses on',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.secondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: AppColors.chevron),
            ],
          ),
        ),
      ),
    );
  }
}

/// Doses for one prescription.
class PrescriptionRemindersScreen extends ConsumerWidget {
  const PrescriptionRemindersScreen({
    super.key,
    required this.documentId,
    required this.title,
  });

  final String documentId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final mine = [
      for (final r in ref.watch(remindersProvider).value ?? const [])
        if (r.documentId == documentId) r,
    ];
    final byMedicine = <String, List<MedicineReminder>>{};
    for (final r in mine) {
      byMedicine.putIfAbsent(r.medicineLabel, () => []).add(r);
    }

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        surfaceTintColor: Colors.transparent,
        // Fit long record titles.
        titleTextStyle: textTheme.titleMedium,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (mine.isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: AppColors.destructive,
              ),
              onPressed: () => _deleteAll(context, ref, mine.length),
              child: const Text('Delete all'),
            ),
        ],
      ),
      body: byMedicine.isEmpty
          ? Center(
              child: Text(
                'No reminders on this prescription.',
                style: textTheme.bodyMedium?.copyWith(
                  color: AppColors.secondary,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: [
                for (final entry in byMedicine.entries) ...[
                  _MedicineCard(label: entry.key, doses: entry.value),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }

  /// Delete all doses for this prescription.
  Future<void> _deleteAll(BuildContext context, WidgetRef ref, int n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all reminders?'),
        content: Text(
          '$n ${n == 1 ? 'reminder' : 'reminders'} for "$title" will stop. The '
          'prescription itself is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final repository = ref.read(reminderRepositoryProvider);
    await repository.deleteForDocument(documentId);
    await ref.read(reminderServiceProvider).sync(await repository.all());
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _MedicineCard extends ConsumerWidget {
  const _MedicineCard({required this.label, required this.doses});

  final String label;
  final List<MedicineReminder> doses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final ordered = [...doses]
      ..sort((a, b) => a.minuteOfDay.compareTo(b.minuteOfDay));
    final end = ordered.first.endDate;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: textTheme.bodyMedium),
                    const SizedBox(height: 2),
                    Text(
                      end == null ? 'Every day' : 'Until ${_dayLabel(end)}',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.faint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Remove',
                iconSize: 20,
                icon: const Icon(
                  Icons.delete_outline,
                  color: AppColors.destructive,
                ),
                onPressed: () => _remove(ref),
              ),
            ],
          ),
          for (final dose in ordered) _DoseRow(dose: dose, textTheme: textTheme),
        ],
      ),
    );
  }

  Future<void> _remove(WidgetRef ref) async {
    final repository = ref.read(reminderRepositoryProvider);
    await repository.deleteMedicine(doses.first.documentId, label);
    await ref.read(reminderServiceProvider).sync(await repository.all());
  }
}

class _DoseRow extends ConsumerWidget {
  const _DoseRow({required this.dose, required this.textTheme});

  final MedicineReminder dose;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Expanded(
          child: TextButton(
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(vertical: 10),
              foregroundColor: AppColors.ink,
            ),
            onPressed: () => _editTime(context, ref),
            child: Row(
              children: [
                Text(dose.timeLabel, style: textTheme.bodyMedium),
                const SizedBox(width: 6),
                const Icon(
                  Icons.edit_outlined,
                  size: 15,
                  color: AppColors.chevron,
                ),
              ],
            ),
          ),
        ),
        Switch(value: dose.enabled, onChanged: (on) => _setEnabled(ref, on)),
      ],
    );
  }

  Future<void> _editTime(BuildContext context, WidgetRef ref) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: dose.minuteOfDay ~/ 60,
        minute: dose.minuteOfDay % 60,
      ),
    );
    if (picked == null) return;
    final repository = ref.read(reminderRepositoryProvider);
    await repository.setTime(dose.id, picked.hour * 60 + picked.minute);
    await ref.read(reminderServiceProvider).sync(await repository.all());
  }

  Future<void> _setEnabled(WidgetRef ref, bool enabled) async {
    final repository = ref.read(reminderRepositoryProvider);
    await repository.setEnabled(dose.id, enabled);
    await ref.read(reminderServiceProvider).sync(await repository.all());
  }
}

String _dayLabel(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}
