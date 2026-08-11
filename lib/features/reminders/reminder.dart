/// One dose; UI model (no Drift).
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

  /// Row / notification id.
  final int id;
  final String documentId;
  final String medicineLabel;

  /// Minutes since midnight.
  final int minuteOfDay;
  final DateTime startDate;

  /// Last day, or null if open-ended.
  final DateTime? endDate;
  final bool enabled;

  /// Last taken day (display only).
  final DateTime? lastTakenDay;

  /// e.g. "8:00 AM".
  String get timeLabel => clockLabel(minuteOfDay);

  /// Active on [day] (ignores enabled).
  bool coversDay(DateTime day) {
    final at = _dayOnly(day);
    if (at.isBefore(_dayOnly(startDate))) return false;
    final end = endDate;
    return end == null || !at.isAfter(_dayOnly(end));
  }

  /// Taken on [day]?
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

/// Format minute-of-day as clock time.
String clockLabel(int minuteOfDay) {
  final hour = minuteOfDay ~/ 60;
  final display = hour % 12 == 0 ? 12 : hour % 12;
  final minute = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$display:$minute ${hour < 12 ? 'AM' : 'PM'}';
}

/// Enabled doses covering [day], earliest first.
List<MedicineReminder> dosesOn(List<MedicineReminder> all, DateTime day) {
  final due = [
    for (final r in all)
      if (r.enabled && r.coversDay(day)) r,
  ];
  due.sort((a, b) => a.minuteOfDay.compareTo(b.minuteOfDay));
  return due;
}

/// Untaken doses today (bell badge).
int dosesLeftToday(List<MedicineReminder> all, DateTime now) =>
    dosesOn(all, now).where((r) => !r.takenOn(now)).length;

/// Course end from [start] + [days]; null if open-ended.
DateTime? courseEnd(DateTime start, int? days) =>
    days == null ? null : _dayOnly(start).add(Duration(days: days - 1));
