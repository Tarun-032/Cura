/// Parse printed directions → dose times (no model).
library;

/// Default dose times (minutes since midnight).
const kMorning = 8 * 60;
const kNoon = 14 * 60;
const kEvening = 18 * 60;
const kNight = 21 * 60;
const kBedtime = 22 * 60;

/// Slot times by doses/day.
const _slotsByCount = <int, List<int>>{
  1: [kMorning],
  2: [kMorning, kNight],
  3: [kMorning, kNoon, kNight],
  4: [kMorning, kNoon, kEvening, kBedtime],
};

/// Parsed times + optional course length.
class MedicineSchedule {
  const MedicineSchedule(this.times, {this.days});

  /// Minutes since midnight, ascending.
  final List<int> times;

  /// Days, or null if open-ended.
  final int? days;
}

/// Null if nothing to schedule (SOS / empty).
MedicineSchedule? parseMedicineSchedule(String directions) {
  final text = directions.trim();
  if (text.isEmpty) return null;
  // SOS/PRN → no schedule.
  if (_onDemandRe.hasMatch(text)) return null;

  final times = _timesFor(text);
  if (times == null || times.isEmpty) return null;
  final ordered = times.toSet().toList()..sort();
  return MedicineSchedule(ordered, days: _daysFor(text));
}

List<int>? _timesFor(String text) {
  // Prefer 1-0-1 style.
  final slots = _scheduleRe.firstMatch(text);
  if (slots != null) {
    final digits = slots.group(0)!
        .split(RegExp(r'[^0-9]+'))
        .where((d) => d.isNotEmpty)
        .toList();
    final positions = _slotsByCount[digits.length];
    if (positions != null) {
      return [
        for (var i = 0; i < digits.length; i++)
          if (digits[i] != '0') positions[i],
      ];
    }
  }

  // every N hours from morning.
  final hourly = _everyHoursRe.firstMatch(text);
  if (hourly != null) {
    final step = int.parse(hourly.group(1)!);
    if (step >= 1 && step <= 24) {
      final count = 24 ~/ step;
      return [
        for (var i = 0; i < count; i++) (kMorning + i * step * 60) % (24 * 60),
      ];
    }
  }

  if (_bedtimeRe.hasMatch(text)) return const [kBedtime];

  final count = _doseCount(text);
  return count == null ? null : _slotsByCount[count];
}

/// Doses/day from frequency words.
int? _doseCount(String text) {
  if (_freqRe(r'od|once').hasMatch(text)) return 1;
  if (_freqRe(r'bd|bid|twice').hasMatch(text)) return 2;
  if (_freqRe(r'tds|tid|thrice').hasMatch(text)) return 3;
  if (_freqRe(r'qid|qds').hasMatch(text)) return 4;
  // "N times a day".
  final n = _timesADayRe.firstMatch(text);
  if (n != null) {
    final count = int.parse(n.group(1)!);
    return _slotsByCount.containsKey(count) ? count : null;
  }
  return null;
}

int? _daysFor(String text) {
  final m = _durationRe.firstMatch(text);
  if (m == null) return null;
  // x N days / N/7.
  if (m.group(1) != null) {
    final n = int.parse(m.group(1)!);
    final unit = m.group(2)!.toLowerCase();
    if (unit.startsWith('w')) return n * 7;
    if (unit.startsWith('m')) return n * 30;
    return n;
  }
  final n = int.parse(m.group(3)!);
  return switch (m.group(4)) { '52' => n * 7, '12' => n * 30, _ => n };
}

/// Whole-word frequency match.
RegExp _freqRe(String alternatives) =>
    RegExp('\\b(?:$alternatives)\\b', caseSensitive: false);

/// On-demand → never schedule.
final _onDemandRe = RegExp(
  r'\b(?:sos|prn|stat|as\s+(?:needed|required))\b',
  caseSensitive: false,
);

/// 1-0-1 / 1-0-1-1.
final _scheduleRe = RegExp(r'\b\d\s*-\s*\d\s*-\s*\d(?:\s*-\s*\d)?\b');

final _everyHoursRe = RegExp(
  r'\b(?:every|q)\s*(\d+)\s*(?:hours?|hrs?|h)\b',
  caseSensitive: false,
);

/// Bedtime / HS.
final _bedtimeRe = RegExp(
  r'\bhs\b|\bat\s+(?:night|bedtime)\b',
  caseSensitive: false,
);

final _timesADayRe = RegExp(
  r'\b(\d+)\s*times?\s+(?:a\s+day|daily|per\s+day|in\s+a\s+day)\b',
  caseSensitive: false,
);

/// Duration; skips date-like fractions.
final _durationRe = RegExp(
  r'\b(?:x|for)\s*(\d+)\s*(days?|d|weeks?|wks?|months?|mon)\b'
  r'|\b(\d+)\s*/\s*(7|52|12)\b(?!\s*/\s*\d)',
  caseSensitive: false,
);
