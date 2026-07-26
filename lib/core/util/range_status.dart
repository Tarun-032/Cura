// Pure helpers for comparing a measured value against a printed reference range
// — used by the Ask router (to say "within/above/below") and by the scan
// summary (to count how many results are outside range). No model, no I/O.

/// 'within' | 'above' | 'below', or null when either side can't be parsed.
String? rangeStatus(String value, String? range) {
  if (range == null) return null;
  // Multi-category serology intervals describe interpretations, not one normal
  // low/high band, so calling a positive titre "above normal" would mislead.
  // Keep the printed categories and leave the interpretation null.
  final categories = RegExp(
    r'\b(?:non[- ]?reactive|reactive|negative|positive|equivocal|borderline)\s*:',
    caseSensitive: false,
  ).allMatches(range).length;
  if (categories >= 2) return null;
  final v = firstNumber(value);
  final bounds = parseRange(range);
  if (v == null || bounds == null) return null;
  if (bounds.low != null && v < bounds.low!) return 'below';
  if (bounds.high != null && v > bounds.high!) return 'above';
  return 'within';
}

/// The first number in [s] (e.g. "14.2 g/dL" → 14.2). No sign — lab values and
/// ranges never go negative, and a leading '-' is a range separator.
double? firstNumber(String s) {
  final m = RegExp(r'\d+(?:\.\d+)?').firstMatch(s);
  return m == null ? null : double.tryParse(m.group(0)!);
}

/// Parses a reference range into numeric bounds. Handles "13 - 17", "<100",
/// ">40", "4.0 – 5.6"; null when no number is present.
({double? low, double? high})? parseRange(String range) {
  final r = range.toLowerCase().replaceAll(',', '');
  final nums = RegExp(
    r'\d+(?:\.\d+)?',
  ).allMatches(r).map((m) => double.parse(m.group(0)!)).toList();
  if (nums.isEmpty) return null;
  if (r.contains('<') ||
      r.contains('less than') ||
      r.contains('under') ||
      r.contains('up to') ||
      r.contains('upto')) {
    return (low: null, high: nums.first);
  }
  if (r.contains('>') ||
      r.contains('greater than') ||
      r.contains('over') ||
      r.contains('at least') ||
      r.contains('min')) {
    return (low: nums.first, high: null);
  }
  if (nums.length >= 2) return (low: nums.first, high: nums[1]);
  return null;
}
