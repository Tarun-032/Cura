import 'document.dart';

/// Value vs printed range.
enum RangeVerdict { low, high, inRange, unknown }

extension RangeVerdictLabel on RangeVerdict {
  /// Null = no badge.
  String? get label => switch (this) {
    RangeVerdict.low => 'Low',
    RangeVerdict.high => 'High',
    _ => null,
  };
}

/// ↑/↓ only; * and # just cast doubt.
const _directional = <String, RangeVerdict>{
  '↑': RangeVerdict.high,
  '↓': RangeVerdict.low,
};

/// Range compare; unknown if unsure. No flag beats a wrong one.
RangeVerdict verdictFor(DocumentResult r) {
  final computed = _compare(r);
  final marked = _directional[r.labFlag];
  if (computed == RangeVerdict.unknown) return marked ?? RangeVerdict.unknown;
  // Lab flag vs our normal — distrust.
  if (r.labFlag != null && computed == RangeVerdict.inRange) {
    return RangeVerdict.unknown;
  }
  if (marked != null && marked != computed) return RangeVerdict.unknown;
  return computed;
}

/// Healthy band names. Serology left to [bandFor].
const _normalBands = {
  'nondiabetic',
  'normal',
  'optimal',
  'desirable',
  'lowrisk',
  'goodcontrol',
  'sufficient',
  'adequate',
};

/// Abnormal band names; others stay uncoloured.
const _abnormalBands = {
  'prediabetic',
  'diabetic',
  'reactive',
  'positive',
  'borderline',
  'equivocal',
  'highrisk',
  'poorcontrol',
  'unsatisfactorycontrol',
  'deficient',
  'insufficient',
};

/// Matching band name, or null if ambiguous.
({String name, bool abnormal})? bandFor(DocumentResult r) {
  final parts = (r.range ?? '').split(';');
  if (parts.length < 2) return null;
  final measured = _parseValue(r.value);
  if (measured == null) return null;

  final hits = <String>[];
  for (final part in parts) {
    final split = part.split(':');
    if (split.length != 2) return null;
    final name = split.first.trim();
    if (name.isEmpty || !RegExp('^[A-Za-z]').hasMatch(name)) return null;
    final bounds = _parseRange(split.last, null);
    if (bounds == null) return null;
    final below = bounds.low != null && measured.number < bounds.low!;
    final above = bounds.high != null && measured.number > bounds.high!;
    if (!below && !above) hits.add(name);
  }
  if (hits.length != 1) return null;

  return (
    name: hits.single,
    abnormal: _abnormalBands.contains(_word(hits.single)),
  );
}

/// Letters only for band match.
String _word(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z]'), '');

/// Healthy band's numeric bound.
String? _normalBandBound(String text) {
  for (final part in text.split(';')) {
    final split = part.split(':');
    if (split.length != 2) return null;
    if (_normalBands.contains(_word(split.first))) return split.last.trim();
  }
  return null;
}

/// Precomputed verdict for Ask (no model math).
String? verdictNote(DocumentResult r) {
  final parts = <String>[?verdictFor(r).label, ?bandFor(r)?.name];
  return parts.isEmpty ? null : parts.join(', ').toUpperCase();
}

/// Display range; healthy bound for banded intervals.
String? rangeText(DocumentResult r) {
  final range = r.range?.trim();
  if (range == null || range.isEmpty) return null;
  if (!range.contains(':')) return range;
  return _normalBandBound(range) ?? range;
}

/// Live summary from current rows.
String? resultsSummary(List<DocumentResult> results) {
  if (results.isEmpty) return null;
  final flagged = <String>[];
  var judged = false;
  for (final r in results) {
    final verdict = verdictFor(r);
    final band = verdict == RangeVerdict.unknown ? bandFor(r) : null;
    if (verdict != RangeVerdict.unknown || band != null) judged = true;
    if (verdict == RangeVerdict.low ||
        verdict == RangeVerdict.high ||
        (band?.abnormal ?? false)) {
      flagged.add(r.label);
    }
  }
  final n = results.length;
  final count = '$n result${n == 1 ? '' : 's'}';
  if (!judged) return count;
  if (flagged.isEmpty) return '$count · all within the normal range';
  final names = flagged.length <= 3
      ? flagged.join(', ')
      : '${flagged.take(3).join(', ')} +${flagged.length - 3} more';
  return '$count · ${flagged.length} outside the normal range: $names';
}

RangeVerdict _compare(DocumentResult r) {
  final measured = _parseValue(r.value);
  if (measured == null) return RangeVerdict.unknown;
  final bounds = _parseRange(r.range, r.unit ?? measured.unit);
  if (bounds == null) return RangeVerdict.unknown;
  // Boundary equality stays in-range.
  if (bounds.low != null && measured.number < bounds.low!) {
    return RangeVerdict.low;
  }
  if (bounds.high != null && measured.number > bounds.high!) {
    return RangeVerdict.high;
  }
  return RangeVerdict.inRange;
}

({double number, String? unit})? _parseValue(String raw) {
  final text = raw.trim();
  // Censored (<x / >x) — skip.
  if (text.isEmpty || text.startsWith('<') || text.startsWith('>')) return null;
  final match = RegExp(r'^(\d[\d,]*(?:\.\d+)?)\s*(.*)$').firstMatch(text);
  if (match == null) return null;
  final number = double.tryParse(match[1]!.replaceAll(',', ''));
  if (number == null) return null;
  final tail = match[2]!.trim();
  // Trailing non-unit → not a value.
  if (tail.isNotEmpty && !_looksLikeUnit(tail)) return null;
  return (number: number, unit: tail.isEmpty ? null : tail);
}

({double? low, double? high})? _parseRange(String? raw, String? rowUnit) {
  var text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  // Use healthy band only; refuse sex/branch ranges.
  if (text.contains(':')) {
    final bound = _normalBandBound(text);
    if (bound == null) return null;
    text = bound;
  }
  if (text.contains(';') || text.contains(':')) return null;
  // Leading '-' is a separator.
  if (text.startsWith('-')) return null;
  text = text.replaceAll(RegExp('[–—]'), '-');

  final split = _splitTrailingUnit(text);
  if (_unitsDisagree(split.unit, rowUnit)) return null;
  text = split.rest.replaceAll(RegExp(r'\bto\b', caseSensitive: false), '-');
  // Letters left → not a plain range.
  if (RegExp('[a-zA-Z]').hasMatch(text)) return null;

  final nums = RegExp(r'\d+(?:\.\d+)?').allMatches(text).toList();
  if (nums.isEmpty || nums.length > 2) return null;
  if (nums.length == 2) {
    if (!text.substring(nums[0].end, nums[1].start).contains('-')) return null;
    final low = double.parse(nums[0][0]!);
    final high = double.parse(nums[1][0]!);
    return low > high ? null : (low: low, high: high);
  }
  final bound = double.parse(nums.single[0]!);
  if (text.contains('<') || text.contains('≤')) return (low: null, high: bound);
  if (text.contains('>') || text.contains('≥')) return (low: bound, high: null);
  return null; // a lone number is not a range
}

({String rest, String? unit}) _splitTrailingUnit(String text) {
  final nums = RegExp(r'\d+(?:\.\d+)?').allMatches(text).toList();
  if (nums.isEmpty) return (rest: text, unit: null);
  final tail = text.substring(nums.last.end).trim();
  if (tail.isEmpty) return (rest: text, unit: null);
  return (rest: text.substring(0, nums.last.end), unit: tail);
}

/// True if both units set and differ.
bool _unitsDisagree(String? a, String? b) =>
    a != null && b != null && _canonUnit(a) != _canonUnit(b);

String _canonUnit(String u) =>
    u.toLowerCase().replaceAll(RegExp(r'[^a-z0-9%µ]'), '');

bool _looksLikeUnit(String s) =>
    s.length <= 14 &&
    RegExp(r'^[%A-Za-zµ°0-9]+(?:[/.^-][%A-Za-zµ°0-9]+)*$').hasMatch(s) &&
    RegExp('[A-Za-zµ%]').hasMatch(s);
