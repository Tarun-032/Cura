import '../ai/query_router.dart' show aliasGroupName, aliasGroupOf;
import '../library/document.dart';
import '../library/result_range.dart';

/// One reading from one report.
class TrendPoint {
  const TrendPoint({
    required this.date,
    required this.value,
    required this.unit,
    required this.result,
    required this.documentId,
  });

  final DateTime date;
  final double value;
  final String? unit;

  /// Source row (for verdict).
  final DocumentResult result;
  final String documentId;

  String get dateLabel => shortDate(date);
}

/// One measure across reports (oldest first).
class TrendSeries {
  const TrendSeries({
    required this.key,
    required this.label,
    required this.unit,
    required this.points,
  });

  /// Stable measure key (survives wording changes).
  final String key;

  /// Latest report's wording.
  final String label;
  final String? unit;
  final List<TrendPoint> points;

  TrendPoint get latest => points.last;

  /// Latest reading out of range / abnormal band.
  bool get flagged {
    final verdict = verdictFor(latest.result);
    return verdict == RangeVerdict.low ||
        verdict == RangeVerdict.high ||
        (bandFor(latest.result)?.abnormal ?? false);
  }

  /// Latest − previous.
  double get delta => latest.value - points[points.length - 2].value;
}

/// Mentioned once; not chartable yet.
class TrendMeasure {
  const TrendMeasure({required this.key, required this.label});

  final String key;
  final String label;
}

/// Scan result: charted, other, pending.
class TrendScan {
  const TrendScan({
    required this.series,
    required this.others,
    required this.pending,
  });

  /// Shortlist + pinned.
  final List<TrendSeries> series;

  /// Chartable but not shortlisted/pinned.
  final List<TrendSeries> others;

  /// Read once so far (newest first).
  final List<TrendMeasure> pending;

  bool get isEmpty => series.isEmpty && others.isEmpty && pending.isEmpty;
}

/// Default charted measures (headline markers only).
const kShortlist = {
  'hemoglobin',
  'platelet',
  'bilirubin',
  'sgpt',
  'hba1c',
  'glucose',
  'crp',
};

/// Charted series only.
List<TrendSeries> buildTrends(
  List<CuraDocument> docs, {
  Set<String> pinned = const {},
}) => scanTrends(docs, pinned: pinned).series;

/// Full scan of measures in [docs].
TrendScan scanTrends(List<CuraDocument> docs, {Set<String> pinned = const {}}) {
  // Skip bills and prescriptions.
  final sources = [
    for (final d in docs)
      if (d.type != DocumentType.receipt && d.type != DocumentType.prescription)
        d,
  ]..sort((a, b) => a.date.compareTo(b.date));

  final grouped = <String, List<TrendPoint>>{};
  for (final d in sources) {
    for (final r in d.results) {
      if (r.needsReview) continue;
      final measured = resultNumber(r);
      if (measured == null) continue;
      final group = aliasGroupOf(r.label);
      // Skip dose/frequency/duration rows.
      if (_dosageGroups.contains(group)) continue;
      final points = grouped.putIfAbsent(_keyFor(r.label, group), () => []);
      // One reading per measure per report.
      if (points.isNotEmpty && points.last.documentId == d.id) continue;
      points.add(
        TrendPoint(
          date: d.date,
          value: measured.number,
          unit: measured.unit,
          result: r,
          documentId: d.id,
        ),
      );
    }
  }

  final series = <TrendSeries>[];
  final others = <TrendSeries>[];
  final pending = <({TrendMeasure measure, DateTime date})>[];
  for (final entry in grouped.entries) {
    final points = entry.value;
    // Newest sets unit; drop mismatches.
    final unit = canonicalUnit(points.last.unit);
    final kept = [
      for (final p in points)
        if (unit == null ||
            canonicalUnit(p.unit) == null ||
            canonicalUnit(p.unit) == unit)
          p,
    ];
    if (kept.length < 2) {
      pending.add((
        measure: TrendMeasure(
          key: entry.key,
          label: points.last.result.label,
        ),
        date: points.last.date,
      ));
      continue;
    }
    final built = TrendSeries(
      key: entry.key,
      label: kept.last.result.label,
      unit: kept.last.unit,
      points: kept,
    );
    // Shortlist by base measure; skip fractions.
    final wanted =
        pinned.contains(entry.key) ||
        (kShortlist.contains(_base(entry.key)) && !_isFraction(entry.key));
    (wanted ? series : others).add(built);
  }

  // Flagged → more points → newest.
  int rank(TrendSeries a, TrendSeries b) {
    if (a.flagged != b.flagged) return a.flagged ? -1 : 1;
    if (a.points.length != b.points.length) {
      return b.points.length.compareTo(a.points.length);
    }
    return b.latest.date.compareTo(a.latest.date);
  }

  series.sort(rank);
  others.sort(rank);
  pending.sort((a, b) => b.date.compareTo(a.date));
  return TrendScan(
    series: series,
    others: others,
    pending: [for (final p in pending) p.measure],
  );
}

/// Key without qualifiers.
String _base(String key) => key.split(':').first;

/// Direct/indirect fraction key.
bool _isFraction(String key) =>
    key.contains('direct') || key.contains('indirect');

/// "A, B and N more".
String namesFrom(List<String> labels, {int cap = 3}) {
  if (labels.length == 1) return labels.single;
  if (labels.length <= cap) {
    return '${labels.take(labels.length - 1).join(', ')} and ${labels.last}';
  }
  return '${labels.take(cap).join(', ')} and ${labels.length - cap} more';
}

/// Dosage alias groups (by name, not index).
final _dosageGroups = {
  aliasGroupOf('dose'),
  aliasGroupOf('frequency'),
  aliasGroupOf('duration'),
};

/// Qualifiers that split one measure into separate charts.
const _qualifierWords = <String, List<String>>{
  'direct': ['direct'],
  'indirect': ['indirect'],
  'free': ['free'],
  'fasting': ['fasting', 'fbs'],
  'postprandial': ['post prandial', 'postprandial', 'pp', 'ppbs', 'ppbg'],
  'random': ['random'],
  'absolute': ['absolute'],
  'corrected': ['corrected'],
  'average': ['average'],
  'estimated': ['estimated'],
  'urine': ['urine', 'urinary'],
};

/// Alias group + qualifiers (or raw label).
String _keyFor(String label, int group) {
  final lower = label.toLowerCase();
  final base = group >= 0
      ? aliasGroupName(group)
      : lower.replaceAll(RegExp('[^a-z0-9]'), '');
  final marks = [
    for (final entry in _qualifierWords.entries)
      if (entry.value.any((w) => RegExp('\\b$w\\b').hasMatch(lower))) entry.key,
  ];
  return marks.isEmpty ? base : '$base:${marks.join(',')}';
}
