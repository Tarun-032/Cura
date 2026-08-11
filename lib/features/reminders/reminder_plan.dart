library;

import 'reminder.dart';

const _datedBase = 10000;
const _horizonDays = 60;
const _courseEndBase = 500000;
const _courseEndOffsetMinutes = 60;

DateTime _atMinute(DateTime day, int minuteOfDay) =>
    DateTime(day.year, day.month, day.day, 0, minuteOfDay);

class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    required this.doseIds,
    this.repeatDaily = false,
    this.courseEnd = false,
  });

  final int id;
  final DateTime at;
  final String title;
  final String body;

  final List<int> doseIds;
  final bool repeatDaily;
  final bool courseEnd;

  String get payload =>
      '${doseIds.join(',')}|${at.year}-${at.month}-${at.day}';
}

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
  planned.addAll(_planCourseEnds(all, now));
  planned.sort((a, b) => a.at.compareTo(b.at));
  return planned;
}

List<PlannedNotification> _planCourseEnds(
  List<MedicineReminder> all,
  DateTime now,
) {
  final courses = <String, List<MedicineReminder>>{};
  for (final r in all) {
    final end = r.endDate;
    if (!r.enabled || end == null) continue;
    courses
        .putIfAbsent('${r.documentId}|${end.toIso8601String()}', () => [])
        .add(r);
  }

  final planned = <PlannedNotification>[];
  for (final course in courses.values) {
    final end = course.first.endDate!;
    var lastDose = course.first.minuteOfDay;
    var lowestId = course.first.id;
    final names = <String>{};
    for (final r in course) {
      if (r.minuteOfDay > lastDose) lastDose = r.minuteOfDay;
      if (r.id < lowestId) lowestId = r.id;
      names.add(r.medicineLabel);
    }
    final at = _atMinute(end, lastDose + _courseEndOffsetMinutes);
    if (!at.isAfter(now)) continue;
    planned.add(
      PlannedNotification(
        id: _courseEndBase + lowestId,
        at: at,
        title: 'Last day of this course',
        body: names.join(', '),
        doseIds: const [],
        courseEnd: true,
      ),
    );
  }
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
  DateTime? lastDated;
  for (final r in slot) {
    final end = r.endDate;
    if (end == null) continue;
    final day = DateTime(end.year, end.month, end.day);
    if (lastDated == null || day.isAfter(lastDated)) lastDated = day;
  }

  // ponytail: over-horizon → daily repeat.
  final horizon = addDays(today, _horizonDays);
  final overHorizon = lastDated != null && lastDated.isAfter(horizon);

  final planned = <PlannedNotification>[];
  var repeatFrom = today;

  if (lastDated != null && !overHorizon) {
    for (var i = 0; i <= daysBetween(today, lastDated); i++) {
      final day = addDays(today, i);
      final at = _atMinute(day, minuteOfDay);
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
    repeatFrom = addDays(lastDated, 1);
  }

  final repeating = overHorizon ? slot : openEnded;
  if (repeating.isNotEmpty) {
    var at = _atMinute(repeatFrom, minuteOfDay);
    if (!at.isAfter(now)) at = _atMinute(addDays(repeatFrom, 1), minuteOfDay);
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
