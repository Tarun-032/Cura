/// One dose (UI model).
class MedicineReminder {
  const MedicineReminder({
    required this.id,
    required this.documentId,
    required this.medicineLabel,
    required this.minuteOfDay,
    required this.startDate,
    this.endDate,
    this.enabled = true,
    this.lastTakenDay,
  });

  final int id;
  final String documentId;
  final String medicineLabel;
  final int minuteOfDay;
  final DateTime startDate;
  final DateTime? endDate;
  final bool enabled;
  final DateTime? lastTakenDay;

  String get timeLabel => clockLabel(minuteOfDay);

  bool coversDay(DateTime day) {
    final at = _dayOnly(day);
    if (at.isBefore(_dayOnly(startDate))) return false;
    final end = endDate;
    return end == null || !at.isAfter(_dayOnly(end));
  }

  bool takenOn(DateTime day) {
    final taken = lastTakenDay;
    return taken != null && _dayOnly(taken) == _dayOnly(day);
  }

  MedicineReminder copyWith({
    int? minuteOfDay,
    bool? enabled,
    DateTime? lastTakenDay,
    bool clearTaken = false,
  }) => MedicineReminder(
    id: id,
    documentId: documentId,
    medicineLabel: medicineLabel,
    minuteOfDay: minuteOfDay ?? this.minuteOfDay,
    startDate: startDate,
    endDate: endDate,
    enabled: enabled ?? this.enabled,
    lastTakenDay: clearTaken ? null : (lastTakenDay ?? this.lastTakenDay),
  );
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Calendar-day add (DST-safe).
DateTime addDays(DateTime from, int days) =>
    DateTime(from.year, from.month, from.day + days);

/// Whole days between dates (DST-safe).
int daysBetween(DateTime from, DateTime to) =>
    (_dayOnly(to).difference(_dayOnly(from)).inHours / 24).round();

String clockLabel(int minuteOfDay) {
  final hour = minuteOfDay ~/ 60;
  final display = hour % 12 == 0 ? 12 : hour % 12;
  final minute = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$display:$minute ${hour < 12 ? 'AM' : 'PM'}';
}

List<MedicineReminder> dosesOn(List<MedicineReminder> all, DateTime day) {
  final due = [
    for (final r in all)
      if (r.enabled && r.coversDay(day)) r,
  ];
  due.sort((a, b) => a.minuteOfDay.compareTo(b.minuteOfDay));
  return due;
}

int dosesLeftToday(List<MedicineReminder> all, DateTime now) =>
    dosesOn(all, now).where((r) => !r.takenOn(now)).length;

DateTime? courseEnd(DateTime start, int? days) =>
    days == null ? null : addDays(start, days - 1);

/// Null days = ongoing.
const kCourseOptions = <({String label, int? days})>[
  (label: '1 week', days: 7),
  (label: '2 weeks', days: 14),
  (label: '1 month', days: 30),
  (label: '3 months', days: 90),
  (label: '6 months', days: 180),
  (label: 'Ongoing', days: null),
];

String courseLabel(int? days) {
  if (days == null) return 'Ongoing';
  for (final option in kCourseOptions) {
    if (option.days == days) return option.label;
  }
  return '$days days';
}

String? courseProgress(List<MedicineReminder> doses, DateTime day) {
  if (doses.isEmpty) return null;
  final end = doses.first.endDate;
  if (end == null) return null;
  final start = _dayOnly(doses.first.startDate);
  for (final dose in doses) {
    if (dose.endDate != end || _dayOnly(dose.startDate) != start) return null;
  }
  final total = daysBetween(start, end) + 1;
  final current = daysBetween(start, day) + 1;
  if (current < 1 || current > total) return null;
  return 'Day $current of $total';
}
