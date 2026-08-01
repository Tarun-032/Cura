import '../library/document.dart';
import 'document_shape.dart';
import 'table_parser.dart';

/// Reads qualitative results ("MTB COMPLEX │ Not Detected") off pages the
/// numeric reader skips, since it requires a numeric value column.
///
/// Deterministic: a row is emitted only when a cell's entire text is a known
/// verdict word, so prose can never become a result. Narrative prose becomes a
/// findings summary instead.
///
/// [textLines] are reading-order lines, where a label and its verdict often
/// already share a line, catching rows the geometry pass alone would miss. Only
/// called when [parseResultsTable] found nothing.
List<DocumentResult> parseQualitativeResults(
  List<OcrLine> lines, {
  List<String> textLines = const [],
}) {
  final out = <DocumentResult>[];
  final seen = <String>{};

  void add(String label, String value) {
    final cleanLabel = label
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[:\-\s]+$'), '')
        .trim();
    if (!_plausibleLabel(cleanLabel)) return;
    final key = cleanLabel.toLowerCase();
    if (!seen.add(key)) return; // headers repeat across pages — keep the first
    out.add(DocumentResult(cleanLabel, value));
  }

  // A standalone verdict is handled by the geometry pass, so the inline matcher
  // must not split it into label "Not" + verdict "Detected".
  void tryInline(String raw) {
    final t = raw.trim();
    if (_verdictCellRe.hasMatch(t)) return;
    final m = _inlineVerdictRe.firstMatch(t);
    if (m != null) add(m.group(1)!, _canonVerdict(m.group(2)!));
  }

  // Pass 1 — geometry: group lines into visual rows (same idea as the table
  // reader's row tolerance) and pair "label cell │ verdict cell".
  final sorted = [...lines]..sort((a, b) => a.top.compareTo(b.top));
  final tol = _rowTol(sorted);
  final rows = <List<OcrLine>>[];
  for (final line in sorted) {
    if (rows.isNotEmpty && (rows.last.first.cy - line.cy).abs() <= tol) {
      rows.last.add(line);
    } else {
      rows.add([line]);
    }
  }
  for (final row in rows) {
    row.sort((a, b) => a.left.compareTo(b.left));
    final vi = row.indexWhere((c) => _verdictCellRe.hasMatch(c.text.trim()));
    if (vi <= 0) continue; // no verdict cell, or nothing to its left to label it
    final label = row.take(vi).map((c) => c.text).join(' ');
    add(label, _canonVerdict(row[vi].text));
  }

  // Pass 2 — merged rows on a single line ("MTB COMPLEX  Not Detected"), from
  // both the raw OCR lines and the reading-order text where label + verdict are
  // most reliably together.
  for (final line in lines) {
    tryInline(line.text);
  }
  for (final line in textLines) {
    tryInline(line);
  }

  return out;
}

/// The verdict vocabulary, anchored to the whole cell so a verdict word inside
/// prose never matches. Longer forms come first so they win the alternation.
const _verdicts = r'not\s+detected|detected|non[\s-]?reactive|reactive|'
    r'positive|negative|abnormal|normal|present|absent|nil|'
    r'indeterminate|equivocal|borderline';

final _verdictCellRe = RegExp('^($_verdicts)\\s*\$', caseSensitive: false);

/// "LABEL : Verdict" / "LABEL  Verdict" merged onto one OCR line. The label is
/// kept short so a prose sentence ending in a verdict word can't sneak in.
final _inlineVerdictRe = RegExp(
  '^([A-Za-z][^:]{1,45}?)\\s*:?\\s+($_verdicts)\\s*\$',
  caseSensitive: false,
);

/// Canonical Title Case for a matched verdict ("not  detected" → "Not Detected").
String _canonVerdict(String raw) => raw
    .trim()
    .toLowerCase()
    .split(RegExp(r'[\s-]+'))
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(raw.contains('-') ? '-' : ' ');

/// Boilerplate a label must never be; patient fields are [isIdentityFieldLabel].
final _labelNoiseRe = RegExp(r'method|end of report', caseSensitive: false);

bool _plausibleLabel(String label) {
  if (label.length < 2 || label.length > 60) return false;
  if (_labelNoiseRe.hasMatch(label) || isIdentityFieldLabel(label)) return false;
  final letters = RegExp('[A-Za-z]').allMatches(label).length;
  final digits = RegExp(r'\d').allMatches(label).length;
  if (letters < 2 || digits > letters) return false;
  // A verdict can't label another verdict ("Detected: Not Detected").
  if (_verdictCellRe.hasMatch(label)) return false;
  return true;
}

/// How close two line centres must be to share a visual row, ~0.8 of the median
/// line height. Looser than the table reader, since these pages are sparse.
double _rowTol(List<OcrLine> lines) {
  final heights = [
    for (final l in lines)
      if (l.bottom - l.top > 0) l.bottom - l.top,
  ]..sort();
  if (heights.isEmpty) return 12;
  return heights[heights.length ~/ 2] * 0.8;
}
