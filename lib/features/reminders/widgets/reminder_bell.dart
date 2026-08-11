import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/data/providers.dart';
import '../reminder.dart';
import '../reminder_screen.dart';

/// Home bell + today's remaining count.
class ReminderBell extends ConsumerWidget {
  const ReminderBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.watch(remindersProvider).value ?? const [];
    final left = dosesLeftToday(reminders, DateTime.now());

    return IconButton(
      tooltip: 'Reminders',
      visualDensity: VisualDensity.compact,
      icon: Badge(
        isLabelVisible: left > 0,
        label: Text('$left'),
        backgroundColor: AppColors.accent,
        child: const Icon(Icons.notifications_none, color: AppColors.secondary),
      ),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ReminderScreen()),
      ),
    );
  }
}
