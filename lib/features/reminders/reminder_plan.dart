/// One notification per dose time.
library;

import 'reminder.dart';

/// Daily-repeat ids: minute-of-day (0–1439).
const _datedBase = 10000;

/// Dated alarms booked ahead; relaunch re-plans.
const _horizonDays = 60;

/// One scheduled alarm.
class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    required this.doseIds,
    this.repeatDaily = false,
  });

  final int id;
  final DateTime at;
  final String title;
  final String body;

  /// Dose ids for Taken.
  final List<int> doseIds;
  final bool repeatDaily;

  /// Payload for the action isolate.
  String get payload =>
      '${doseIds.join(',')}|${at.year}-${at.month}-${at.day}';
}

/// Build alarms from current reminders.
List<PlannedNotification> planNotifications(
  List<MedicineReminder> all,
  DateTime now,
) {
  final slots = <int, List<MedicineReminder>>{};
  for (final r in all) {
    if (r.enabled) slots.putIfAbsent(r.minuteOfDay, () => []).add(r);
  }

  final planned = <PlannedNotification>[];
  final today = DateTime(now.year, now.month, now.day);
  for (final entry in slots.entries) {
    planned.addAll(_planSlot(entry.key, entry.value, now, today));
  }
  planned.sort((a, b) => a.at.compareTo(b.at));
  return planned;
}

List<PlannedNotification> _planSlot(
  int minuteOfDay,
  List<MedicineReminder> slot,
  DateTime now,
  DateTime today,
) {
  final openEnded = [
    for (final r in slot)
      if (r.endDate == null) r,
  ];
  // Finite courses first; daily repeat starts after last end.
  DateTime? lastDated;
  for (final r in slot) {
    final end = r.endDate;
    if (end == null) continue;
    final day = DateTime(end.year, end.month, end.day);
    if (lastDated == null || day.isAfter(lastDated)) lastDated = day;
  }

  // ponytail: past horizon → daily repeat; relaunch drops finished.
  final horizon = today.add(const Duration(days: _horizonDays));
  final overHorizon = lastDated != null && lastDated.isAfter(horizon);

  final planned = <PlannedNotification>[];
  var repeatFrom = today;

  if (lastDated != null && !overHorizon) {
    for (var i = 0; i <= lastDated.difference(today).inDays; i++) {
      final day = today.add(Duration(days: i));
      final at = day.add(Duration(minutes: minuteOfDay));
      final due = [
        for (final r in slot)
          if (r.endDate != null && r.coversDay(day)) r,
      ];
      if (due.isEmpty || !at.isAfter(now)) continue;
      planned.add(
        _notification(
          id: _datedBase + i * 1440 + minuteOfDay,
          at: at,
          due: due,
          minuteOfDay: minuteOfDay,
        ),
      );
    }
    repeatFrom = lastDated.add(const Duration(days: 1));
  }

  // Open-ended or over-horizon → daily repeat.
  final repeating = overHorizon ? slot : openEnded;
  if (repeating.isNotEmpty) {
    var at = repeatFrom.add(Duration(minutes: minuteOfDay));
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    planned.add(
      _notification(
        id: minuteOfDay,
        at: at,
        due: repeating,
        minuteOfDay: minuteOfDay,
        repeatDaily: true,
      ),
    );
  }
  return planned;
}

PlannedNotification _notification({
  required int id,
  required DateTime at,
  required List<MedicineReminder> due,
  required int minuteOfDay,
  bool repeatDaily = false,
}) {
  final time = clockLabel(minuteOfDay);
  final names = [for (final r in due) r.medicineLabel];
  return PlannedNotification(
    id: id,
    at: at,
    title: names.length == 1
        ? 'Time for ${names.first}'
        : '${names.length} medicines at $time',
    body: names.length == 1 ? 'Due at $time.' : names.join(', '),
    doseIds: [for (final r in due) r.id],
    repeatDaily: repeatDaily,
  );
}
