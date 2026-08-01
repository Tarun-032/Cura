import 'dart:convert';

import '../library/document.dart';
import 'document_shape.dart';

/// A single OCR text line with its geometry. Deliberately decoupled from ML Kit
/// (no plugin types) so [parseResultsTable] is pure Dart and unit-testable.
class OcrLine {
  const OcrLine(
    this.text,
    this.left,
    this.top,
    this.right,
    this.bottom, {
    this.confidence,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double? confidence;

  double get cy => (top + bottom) / 2;
}

/// OCR detail below a text line, mirroring only the subset of ML Kit data the
/// parser needs so this file stays plugin-free and testable with fixtures.
class OcrSymbolBox {
  const OcrSymbolBox(
    this.text,
    this.left,
    this.top,
    this.right,
    this.bottom, {
    this.confidence,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double? confidence;
}

class OcrElementBox {
  const OcrElementBox(
    this.text,
    this.left,
    this.top,
    this.right,
    this.bottom, {
    required this.parentLine,
    this.confidence,
    this.symbols = const [],
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final int parentLine;
  final double? confidence;
  final List<OcrSymbolBox> symbols;

  double get width => right - left;
  double get height => bottom - top;
}

class OcrGeometryPage {
  const OcrGeometryPage({required this.lines, required this.elements});

  final List<OcrLine> lines;
  final List<OcrElementBox> elements;
}

/// Reads a lab-style results table — Test │ Observed value │ Normal range —
/// straight from the OCR geometry, instead of asking a small language model to
/// re-align columns it can't see.
///
/// The hard case: the *range* column is often printed vertically staggered from
/// its test rows, so grouping cells by nearest-y mis-pairs them. Each column is
/// therefore read as an ordered top-to-bottom stream and, when the three streams
/// have equal length, paired **by index**, which is immune to vertical drift.
///
/// Returns one [DocumentResult] per detected row (value/range copied verbatim).
/// Returns an empty list when the page doesn't look like a results table; the
/// caller then keeps the language-model fallback.
class TableParseStats {
  const TableParseStats({
    required this.labels,
    required this.values,
    required this.ranges,
    required this.units,
    required this.matched,
    required this.incomplete,
  });

  final int labels;
  final int values;
  final int ranges;
  final int units;
  final int matched;
  final int incomplete;
}

class TableParseResult {
  const TableParseResult(this.results, this.stats, this.evidence, this.quality);
  final List<DocumentResult> results;
  final TableParseStats stats;
  final TableRepairEvidence evidence;
  final TableGridQuality quality;
}

enum TableCellColumn { label, value, unit, range }

enum TableCellGranularity { line, element }

class TableGridCell {
  const TableGridCell({
    required this.id,
    required this.text,
    required this.column,
    required this.rowHint,
    this.pass = 1,
    this.granularity = TableCellGranularity.line,
    this.confidence,
    this.section = 0,
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  final String id;
  final String text;
  final TableCellColumn column;
  final int rowHint;
  final int pass;
  final TableCellGranularity granularity;
  final double? confidence;
  final int section;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get cy => (top + bottom) / 2;
}

class TableGridQuality {
  const TableGridQuality({
    required this.hasTable,
    required this.needsRetry,
    this.unmatchedLabels = 0,
    this.valueOutliers = 0,
  });

  final bool hasTable;
  final bool needsRetry;
  final int unmatchedLabels;
  final int valueOutliers;
}

/// Local-only proof for a possible table row: a cloud repair is accepted only
/// when its fields occur in one of these bounded OCR rows. Coordinates never
/// leave the phone.
class TableEvidenceRow {
  const TableEvidenceRow({
    required this.label,
    required this.rowText,
    required this.order,
    required this.incomplete,
  });

  final String label;
  final String rowText;
  final int order;
  final bool incomplete;
}

class TableRepairEvidence {
  const TableRepairEvidence(
    this.rows, {
    this.cells = const [],
    this.requiresReconciliation = false,
  });

  final List<TableEvidenceRow> rows;
  final List<TableGridCell> cells;
  final bool requiresReconciliation;

  int get unresolvedCount => rows.where((row) => row.incomplete).length;
  bool get needsRepair => unresolvedCount > 0;
  bool get canReconcile => cells.isNotEmpty;

  /// Deliberately contains only table rows. It is still passed through the
  /// authoritative cloud privacy gate before a network request is constructed.
  String get tableText => rows.map((row) => row.rowText).join('\n');

  String get gridText {
    final groups = <String, List<TableGridCell>>{};
    for (final cell in cells) {
      groups.putIfAbsent('${cell.pass}:${cell.rowHint}', () => []).add(cell);
    }
    return groups.entries
        .map((entry) {
          final parts = entry.value.map(
            (cell) => '${cell.column.name}[${cell.id}]=${cell.text}',
          );
          return 'TABLE ROW ${entry.key} ${parts.join(' | ')}';
        })
        .join('\n');
  }

  List<TableRepairEvidence> get sections {
    final grouped = <String, List<TableGridCell>>{};
    for (final cell in cells) {
      final page = cell.pass ~/ 100;
      grouped.putIfAbsent('$page:${cell.section}', () => []).add(cell);
    }
    final keys = grouped.keys.toList()..sort();
    return [
      for (final key in keys)
        TableRepairEvidence(
          const [],
          cells: grouped[key]!,
          requiresReconciliation: requiresReconciliation,
        ),
    ];
  }

  TableRepairEvidence cellsPresentIn(String serializedSafeText) =>
      TableRepairEvidence(
        const [],
        requiresReconciliation: requiresReconciliation,
        cells: [
          for (final cell in cells)
            if (serializedSafeText.contains('[${cell.id}]')) cell,
        ],
      );

  TableRepairEvidence withPass(int pass) => TableRepairEvidence(
    rows,
    requiresReconciliation: requiresReconciliation,
    cells: [
      for (final cell in cells)
        TableGridCell(
          id: 'p${pass}_${cell.id}',
          text: cell.text,
          column: cell.column,
          rowHint: cell.rowHint,
          pass: pass,
          granularity: cell.granularity,
          confidence: cell.confidence,
          section: cell.section,
          left: cell.left,
          top: cell.top,
          right: cell.right,
          bottom: cell.bottom,
        ),
    ],
  );

  TableRepairEvidence merge(TableRepairEvidence other) => TableRepairEvidence(
    [...rows, ...other.rows],
    cells: [...cells, ...other.cells],
    requiresReconciliation:
        requiresReconciliation || other.requiresReconciliation,
  );

  TableRepairEvidence withReconciliationRequired(bool required) =>
      TableRepairEvidence(rows, cells: cells, requiresReconciliation: required);
}

List<DocumentResult> parseResultsTable(List<OcrLine> lines) =>
    parseResultsTableDetailed(lines).results;

/// Repairs rows with an empty value by copying a numeric token from the
/// observed-value geometry on the same physical row, handling the common CBC
/// zero failure without another OCR pass. Every character comes from a bounded
/// local OCR cell, so nothing can be invented.
List<DocumentResult> repairIncompleteResultsFromGeometry(
  List<DocumentResult> results,
  TableRepairEvidence evidence,
) {
  if (results.every((result) => !result.needsReview) ||
      evidence.cells.isEmpty) {
    return results;
  }
  final labels = evidence.cells
      .where((cell) => cell.column == TableCellColumn.label)
      .toList();
  return [
    for (final result in results)
      if (!result.needsReview)
        result
      else
        _repairIncompleteResult(result, labels, evidence.cells) ?? result,
  ];
}

/// Normalizes text from a crop holding one observed-value cell. Narrower than
/// the general classifier: the crop already proved the column, but the text must
/// still be one complete number. A bare dash or empty crop never becomes zero.
String? normalizeObservedValueCandidate(String raw) {
  final trimmed = raw.trim().replaceAll(RegExp(r'^[\s_]+|[\s_]+$'), '');
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;
  final fixed = _stripFlags(_fixNumeric(trimmed)).trim();
  final match = RegExp(r'^[<>]?(?:\d[\d,]*)(?:\.\d+)?$').firstMatch(fixed);
  if (match == null) return null;
  return fixed;
}

DocumentResult? _repairIncompleteResult(
  DocumentResult result,
  List<TableGridCell> labels,
  List<TableGridCell> cells,
) {
  final matches = <({TableGridCell label, int score})>[
    for (final label in labels)
      if (_labelMatchScore(result.label, label.text) > 0)
        (label: label, score: _labelMatchScore(result.label, label.text)),
  ];
  if (matches.isEmpty) return null;
  final bestScore = matches
      .map((match) => match.score)
      .reduce((a, b) => a > b ? a : b);
  final best = matches.where((match) => match.score == bestScore).toList();
  if (best.length != 1) return null;
  final label = best.single.label;
  final values = cells.where((cell) {
    if (cell.pass != label.pass ||
        cell.rowHint != label.rowHint ||
        cell.column != TableCellColumn.value) {
      return false;
    }
    final normalized = _stripFlags(_fixNumeric(cell.text)).trim();
    return _digit.hasMatch(normalized);
  }).toList();
  if (values.length != 1) return null;
  final value = _stripFlags(_fixNumeric(values.single.text)).trim();
  final units = cells
      .where(
        (cell) =>
            cell.pass == label.pass &&
            cell.rowHint == label.rowHint &&
            cell.column == TableCellColumn.unit,
      )
      .toList();
  final ranges = cells
      .where(
        (cell) =>
            cell.pass == label.pass &&
            cell.rowHint == label.rowHint &&
            cell.column == TableCellColumn.range,
      )
      .toList();
  final rawRange = ranges.isEmpty
      ? null
      : ranges.map((cell) => _fixNumeric(cell.text.trim())).join(' ');
  final splitRange = _splitRangeUnit(
    rawRange == null ? null : _fixUnits(rawRange),
  );
  return DocumentResult(
    result.label,
    value,
    unit:
        _fixUnitToken(units.length == 1 ? units.single.text : null) ??
        result.unit ??
        splitRange.unit ??
        _standardUnit(result.label),
    range: splitRange.range?.trim().isNotEmpty ?? false
        ? splitRange.range!.trim()
        : result.range,
  );
}

TableParseResult parseResultsTableDetailed(
  List<OcrLine> lines, {
  OcrGeometryPage? geometry,
}) {
  final lineRegion = _tableRegion(lines);
  final elementLines = geometry == null
      ? const <OcrLine>[]
      : _semanticElementLines(geometry, lineRegion);
  final elementResults = elementLines.isEmpty
      ? const <DocumentResult>[]
      : _parseResultsTable(elementLines);
  final lineResults = _parseResultsTable(lines);

  // Element boxes recover columns hidden inside one ML Kit TextLine. The line
  // result is kept when the finer view is incomplete, so element geometry only
  // ever adds rows rather than replacing them.
  final useElements =
      elementResults.isNotEmpty &&
      _completeCount(elementResults) >= _completeCount(lineResults) &&
      elementResults.length >= lineResults.length &&
      !_hasElementValueConflict(lineResults, elementResults);
  final region = useElements ? _tableRegion(elementLines) : lineRegion;
  final cells = [for (final l in region) _Cell(l, _fixNumeric(l.text))];
  final primaryResults = useElements ? elementResults : lineResults;
  // Some serology reports are one-row blocks separated by prose, with a
  // composite observed cell ("Reactive,45.90"). The contiguous reader stops at
  // Interpretation and accepts bare measurements only, so read those cells
  // page-wide and merge them with any ordinary rows.
  final results = _mergeResultRows(
    primaryResults,
    _parseVerdictMeasurements(lines),
  );
  final grid = _buildTableGrid(
    region,
    granularity: useElements
        ? TableCellGranularity.element
        : TableCellGranularity.line,
  );
  final baseEvidence = _buildRepairEvidence(region, results, grid: grid.cells);
  final evidence = baseEvidence.withReconciliationRequired(
    grid.quality.needsRetry || results.any((result) => result.needsReview),
  );
  return TableParseResult(
    results,
    TableParseStats(
      labels: cells.where((c) => _classify(c.norm) == _Kind.label).length,
      values: cells.where((c) => _classify(c.norm) == _Kind.value).length,
      ranges: cells.where((c) => _classify(c.norm) == _Kind.range).length,
      units: cells.where((c) => _isUnitLine(c.norm)).length,
      matched: results.where((r) => !r.needsReview).length,
      incomplete: results.where((r) => r.needsReview).length,
    ),
    evidence,
    grid.quality,
  );
}

List<DocumentResult> _mergeResultRows(
  List<DocumentResult> primary,
  List<DocumentResult> additional,
) {
  if (additional.isEmpty) return primary;
  final out = [...primary];
  String key(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  for (final candidate in additional) {
    final candidateKey = key(candidate.label);
    final index = out.indexWhere((row) {
      final rowKey = key(row.label);
      return rowKey == candidateKey ||
          (rowKey.length >= 6 && candidateKey.startsWith(rowKey)) ||
          (candidateKey.length >= 6 && rowKey.startsWith(candidateKey));
    });
    if (index < 0) {
      out.add(candidate);
    } else if (out[index].needsReview && !candidate.needsReview) {
      out[index] = candidate;
    }
  }
  return out;
}

/// Group 1 is the test name when ML Kit merged it into the cell, which it does
/// whenever the name reaches the value column. The number tolerates the letters
/// OCR swaps for digits ("Positive,l61.00"); [_fixNumeric] repairs the capture.
final _verdictMeasurementRe = RegExp(
  r'^\s*(?:(.*[A-Za-z]{3}.*?)[\s,;:]+)?'
  r'(not\s+detected|non[\s-]?react[iIl1]ve|react[iIl1]ve|'
  r'pos[iIl1]tive|negative|equ[iIl1]vocal|borderline|detected)'
  r'\s*[,;:]?\s*([<>]?[\dlIioO][\d,lIioO]*(?:\.[\d,lIioO]+)?)\s*'
  r'([A-Za-z%/µ.]+)?\s*$',
  caseSensitive: false,
);

final _categoricalReferenceLineRe = RegExp(
  r'^\s*(?:non[\s-]?reactive|reactive|positive|negative|equivocal|borderline)'
  r'\s*:\s*(?:[<>]=?|[≤≥])?\s*\d|'
  r'^\s*(?:non[\s-]?reactive|reactive|positive|negative|equivocal|borderline)'
  r'\s*:\s*\d+(?:\.\d+)?\s*(?:[-–—]|to)\s*\d',
  caseSensitive: false,
);

/// Reads serology rows whose observed cell combines a verdict and a measurement.
/// Scans the whole page, since prose can sit between real rows.
List<DocumentResult> _parseVerdictMeasurements(List<OcrLine> lines) {
  if (lines.isEmpty) return const [];
  final ordered = [...lines]..sort((a, b) => a.cy.compareTo(b.cy));
  final heights = [
    for (final line in ordered)
      if (line.bottom > line.top) line.bottom - line.top,
  ]..sort();
  final rowTolerance = heights.isEmpty
      ? 14.0
      : heights[heights.length ~/ 2] * 1.15;

  final observed = <({OcrLine line, RegExpMatch match})>[];
  for (final line in ordered) {
    // Match the raw token first: numeric repair across "Positive,161.00" would
    // turn both `i`s into `1`s. Only the captured numeric field is repaired.
    final match = _verdictMeasurementRe.firstMatch(line.text);
    // A capture of only OCR letters is not a measurement.
    if (match != null && _digit.hasMatch(match.group(3)!)) {
      observed.add((line: line, match: match));
    }
  }
  if (observed.isEmpty) return const [];

  final results = <DocumentResult>[];
  for (var i = 0; i < observed.length; i++) {
    final item = observed[i];
    final valueLine = item.line;
    final inlineLabel = item.match.group(1)?.trim();
    final labelCandidates = ordered.where((line) {
      if (line.left >= valueLine.left) return false;
      if ((line.cy - valueLine.cy).abs() > rowTolerance) return false;
      final text = line.text.trim();
      if (text.length < 3 || _noiseRe.hasMatch(text)) return false;
      if (_headerRe.hasMatch(text) || _narrativeStartRe.hasMatch(text)) {
        return false;
      }
      final letters = RegExp(r'[A-Za-z]').allMatches(text).length;
      if (letters < 3 || _verdictMeasurementRe.hasMatch(text)) return false;
      // Filtered here, not after picking, so the method sub-line printed under
      // a test name loses to the name instead of taking the row with it.
      return !isIdentityFieldLabel(_cleanLabel(text));
    }).toList();
    if (labelCandidates.isEmpty && inlineLabel == null) continue;
    labelCandidates.sort((a, b) {
      final vertical = (a.cy - valueLine.cy).abs().compareTo(
        (b.cy - valueLine.cy).abs(),
      );
      return vertical != 0 ? vertical : b.right.compareTo(a.right);
    });
    // A name printed in the cell beats one guessed from a neighbouring column.
    final label = _cleanLabel(
      (inlineLabel ?? labelCandidates.first.text).replaceAll(
        RegExp(r'[,;]+$'),
        '',
      ),
    );
    // Otherwise a reference-interval line takes the unit header as its label.
    if (label.isEmpty || isIdentityFieldLabel(label)) continue;

    final unitCandidates = ordered.where((line) {
      return line.left > valueLine.left &&
          (line.cy - valueLine.cy).abs() <= rowTolerance &&
          _isUnitLine(_fixUnits(line.text));
    }).toList();
    unitCandidates.sort(
      (a, b) =>
          (a.cy - valueLine.cy).abs().compareTo((b.cy - valueLine.cy).abs()),
    );
    final inlineUnit = item.match.group(4)?.trim();
    final unit = _fixUnitToken(
      inlineUnit?.isNotEmpty == true
          ? inlineUnit
          : (unitCandidates.isEmpty ? null : unitCandidates.first.text),
    );

    final nextValueCy = i + 1 < observed.length
        ? observed[i + 1].line.cy
        : double.infinity;
    final rangeLines = ordered.where((line) {
      if (line.cy < valueLine.cy - rowTolerance || line.cy >= nextValueCy) {
        return false;
      }
      if (line.left <= valueLine.left) return false;
      return _categoricalReferenceLineRe.hasMatch(_fixNumeric(line.text));
    }).toList()..sort((a, b) => a.cy.compareTo(b.cy));
    final range = rangeLines
        .map((line) => _fixNumeric(line.text).trim())
        .where((text) => text.isNotEmpty)
        .join('; ');
    final verdict = _canonicalVerdict(item.match.group(2)!);
    final number = _stripFlags(_fixNumeric(item.match.group(3)!));
    results.add(
      DocumentResult(
        label,
        '$verdict, $number',
        unit: unit,
        range: range.isEmpty ? null : range,
      ),
    );
  }
  return results;
}

String _canonicalVerdict(String raw) {
  final key = raw.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (key.startsWith('non') && key.contains('react')) return 'Non-reactive';
  if (key.contains('react')) return 'Reactive';
  if (key.startsWith('pos')) return 'Positive';
  if (key.startsWith('neg')) return 'Negative';
  if (key.startsWith('equ')) return 'Equivocal';
  if (key.startsWith('border')) return 'Borderline';
  if (key.startsWith('not')) return 'Not Detected';
  return 'Detected';
}

int _completeCount(List<DocumentResult> results) =>
    results.where((result) => !result.needsReview).length;

bool _hasElementValueConflict(
  List<DocumentResult> lineResults,
  List<DocumentResult> elementResults,
) {
  final lineByLabel = <String, List<DocumentResult>>{};
  final elementByLabel = <String, List<DocumentResult>>{};
  void index(
    List<DocumentResult> source,
    Map<String, List<DocumentResult>> target,
  ) {
    for (final result in source) {
      final key = result.label.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      target.putIfAbsent(key, () => []).add(result);
    }
  }

  index(lineResults, lineByLabel);
  index(elementResults, elementByLabel);
  for (final entry in lineByLabel.entries) {
    final finer = elementByLabel[entry.key];
    if (finer == null) continue;
    final count = entry.value.length < finer.length
        ? entry.value.length
        : finer.length;
    for (var i = 0; i < count; i++) {
      final lineValue = entry.value[i].value.trim();
      final elementValue = finer[i].value.trim();
      if (lineValue.isNotEmpty &&
          elementValue.isNotEmpty &&
          _fixNumeric(lineValue).replaceAll(',', '') !=
              _fixNumeric(elementValue).replaceAll(',', '')) {
        return true;
      }
    }
  }
  return false;
}

List<DocumentResult> _parseResultsTable(List<OcrLine> lines) {
  final region = _tableRegion(lines)..sort((a, b) => a.top.compareTo(b.top));
  if (region.isEmpty) return const [];

  // Carry a numeric-repaired copy alongside each line; classify on the repaired
  // text so an OCR-mangled range ("Q - Q.8") is seen as a range, not a label.
  final cells = [for (final l in region) _Cell(l, _fixNumeric(l.text))];

  var labels = <_Cell>[];
  final values = <_Cell>[];
  final ranges = <_Cell>[];
  final unitCol = <_Cell>[];
  for (final c in cells) {
    if (_isUnitLine(c.norm)) {
      unitCol.add(c);
      continue;
    }
    switch (_classify(c.norm)) {
      case _Kind.label:
        labels.add(c);
      case _Kind.value:
        values.add(c);
      case _Kind.range:
        // OCR glues a lone observed value onto the range when both sit close
        // ("0 0-2"). Split only when the leading token is a complete value and
        // the remainder is itself a full range.
        final split = _splitLeadingValueFromRange(c.norm);
        if (split != null) {
          values.add(_Cell(c.line, split.value));
          ranges.add(_Cell(c.line, split.range));
        } else {
          ranges.add(c);
        }
      case _Kind.ignore:
        break;
    }
  }

  // If OCR merged whole rows onto single lines, parse those directly.
  final merged = _fullRowMode(region);
  if (merged.length >= 3 && merged.length >= (labels.length * 0.6).ceil()) {
    return merged;
  }

  // x-position backstop: a line that physically sits in the value column is
  // never a test name, however OCR mangled it — pull it back into its column.
  if (values.isNotEmpty) {
    final valueLeft = values.map((c) => c.left).reduce((a, b) => a < b ? a : b);
    final kept = <_Cell>[];
    for (final c in labels) {
      if (c.left >= valueLeft) {
        if (_rangeRe.hasMatch(c.norm)) {
          ranges.add(c);
        } else if (_digit.hasMatch(c.norm)) {
          values.add(c);
        }
      } else {
        kept.add(c);
      }
    }
    labels = kept;
  }
  ranges.sort((a, b) => a.cy.compareTo(b.cy));
  values.sort((a, b) => a.cy.compareTo(b.cy));
  unitCol.sort((a, b) => a.cy.compareTo(b.cy));

  // No value column → not a results table (e.g. a narrative/qualitative report).
  // Better to return nothing than invent rows from headings.
  if (labels.isEmpty || values.isEmpty) return const [];

  final cleanValues = _dropColumnOutliers(values);
  final cleanRanges = _dropColumnOutliers(ranges);

  // A real test row has a value on its text line, so assign each value to its
  // nearest label and drop labels with none. Zero is a value and is kept.
  final tol = _lineTol(cells, labels);
  final assigned = <int, _Cell>{}; // label index → its value
  for (final v in cleanValues) {
    var best = -1;
    var bestD = tol + 1;
    for (var i = 0; i < labels.length; i++) {
      if (assigned.containsKey(i)) continue;
      if (_isLikelySectionHeading(
        i,
        labels,
        values: cleanValues,
        tolerance: tol,
      )) {
        continue;
      }
      final d = (labels[i].cy - v.cy).abs();
      if (d <= tol && d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best >= 0) assigned[best] = v;
  }
  final rowIdx = <int>[
    for (var i = 0; i < labels.length; i++)
      if (assigned.containsKey(i) ||
          (!_isLikelySectionHeading(
                i,
                labels,
                values: cleanValues,
                tolerance: tol,
              ) &&
              (_hasNearby(labels[i], cleanRanges, tol) ||
                  _hasNearby(labels[i], unitCol, tol))))
        i,
  ];
  if (rowIdx.isEmpty) return const [];
  final realLabels = [for (final i in rowIdx) labels[i]];
  final rowValues = [for (final i in rowIdx) assigned[i]];

  // Ranges drift off their row → pair by index when the counts line up, else by
  // nearest-y. A separate units column attaches by nearest-y.
  final rowRanges = cleanRanges.length == realLabels.length
      ? List<_Cell?>.from(cleanRanges)
      : _assignByOrder(realLabels, cleanRanges);
  final rowUnits = _assignByOrder(realLabels, unitCol);

  final out = <DocumentResult>[];
  for (var i = 0; i < realLabels.length; i++) {
    var label = _cleanLabel(realLabels[i].original); // labels never altered
    var value = _stripFlags(_fixUnits(rowValues[i]?.norm.trim() ?? ''));
    // ML Kit sometimes keeps the observed value inside the final label element.
    // Recover only a trailing numeric token, and only when the value column is
    // otherwise empty.
    if (value.isEmpty) {
      final recovered = _splitTrailingObservedValue(label);
      if (recovered != null) {
        label = recovered.label;
        value = recovered.value;
      }
    }
    // The patient block has the same two-column shape, so it parses cleanly.
    if (label.isEmpty || isIdentityFieldLabel(label)) continue;
    var range = rowRanges[i]?.norm.trim();
    // Merge a separate units-column cell into the range when it lacks a unit.
    if (range != null && range.isNotEmpty && rowUnits[i] != null) {
      final lastTok = range.split(RegExp(r'\s+')).last;
      if (!RegExp(r'[A-Za-zµ%]').hasMatch(lastTok)) {
        range = '$range ${rowUnits[i]!.norm.trim()}';
      }
    }
    range = range == null ? null : _applyStandardUnit(label, _fixUnits(range));
    final splitRange = _splitRangeUnit(range);
    range = splitRange.range;
    final splitValue = _splitValueUnit(value);
    value = splitValue.value;
    final unit =
        _fixUnitToken(
          splitRange.unit ?? splitValue.unit ?? rowUnits[i]?.norm.trim(),
        ) ??
        _standardUnit(label);
    out.add(
      DocumentResult(
        label,
        value,
        unit: unit,
        range: (range == null || range.isEmpty) ? null : range,
      ),
    );
  }
  return out;
}

({String label, String value})? _splitTrailingObservedValue(String source) {
  final match = RegExp(
    r'^(.*[A-Za-z)])\s+([<>]?[0-9OoQDlI|BSZg][0-9OoQDlI|BSZg,]*(?:\.[0-9OoQDlI|BSZg]+)?)$',
  ).firstMatch(source.trim());
  if (match == null) return null;
  final label = match.group(1)!.trim();
  final numeric = _stripFlags(_fixNumeric(match.group(2)!)).trim();
  if (label.length < 2 || !_digit.hasMatch(numeric)) return null;
  return (label: label, value: numeric);
}

/// Splits a range cell whose OCR merged an observed value onto its front
/// ("0 0-2" → "0" and "0-2"). Null unless the leading token is a complete value
/// and the remainder is itself a full range, which rejects a genuine spaced
/// range or a split-range fragment.
({String value, String range})? _splitLeadingValueFromRange(String norm) {
  final match = RegExp(
    r'^([<>]?\d[\d,]*(?:\.\d+)?)\s+(\S.*)$',
  ).firstMatch(norm.trim());
  if (match == null) return null;
  final value = _stripFlags(match.group(1)!).trim();
  final range = match.group(2)!.trim();
  if (!_digit.hasMatch(value)) return null;
  // The remainder must be a self-contained range, not a lone fragment.
  if (!_rangeRe.hasMatch(range)) return null;
  if (_valueRe.hasMatch(range)) return null; // remainder is just another value
  return (value: value, range: range);
}

/// A region line with its numeric-repaired text. [original] is the untouched OCR
/// used for labels; [norm] classifies and stores value/range cells.
class _Cell {
  _Cell(this.line, this.norm);

  final OcrLine line;
  final String norm;

  double get left => line.left;
  double get cy => line.cy;
  String get original => line.text;
}

// ─────────────────────────────────────────────────────────────────────────────
// Region: keep only the lines between the column header and the footer.
// ─────────────────────────────────────────────────────────────────────────────

final _headerRe = RegExp(
  r'observed value|normal range|test done|reference (range|value)',
  caseSensitive: false,
);
final _footerRe = RegExp(
  r'done on|biosystem|bio system|analyser|analyzer|end of report|verified by',
  caseSensitive: false,
);
final _narrativeStartRe = RegExp(
  r'^\s*(?:interpretation(?:\s*&\s*remarks?)?|remarks?|comments?|method|note)\s*:?\s*$',
  caseSensitive: false,
);
final _categoricalRangeRe = RegExp(
  r'\b(?:non[- ]?diabetic|pre[- ]?diabetic|diabetic|good control|poor control|'
  r'unsatisfactory control)\b',
  caseSensitive: false,
);
final _methodDetailRe = RegExp(
  r'^\s*\(.*(?:chromatograph|immunoassay|method|hplc).*\)\s*$',
  caseSensitive: false,
);
final _noiseRe = RegExp(
  r'patient|referred|reg\.?\s*no|consulting|pathologist|laborator|'
  r'age\s*/\s*sex|^date\b|sample|collected|received|reported|^mr\.?\b|^mrs\.?\b|'
  r'^ms\.?\b|^dr\.?\b',
  caseSensitive: false,
);

/// Lines that plausibly belong to the results table: between the column header
/// and the footer, minus letterhead noise. Falls back to everything minus noise.
List<OcrLine> _tableRegion(List<OcrLine> lines) {
  double? headerCy;
  double? footerCy;
  for (final l in lines) {
    if (_headerRe.hasMatch(l.text)) {
      headerCy = headerCy == null ? l.cy : (l.cy > headerCy ? l.cy : headerCy);
    }
    if (_footerRe.hasMatch(l.text)) {
      footerCy = footerCy == null ? l.cy : (l.cy < footerCy ? l.cy : footerCy);
    }
  }
  if (headerCy != null) {
    for (final l in lines) {
      if (l.cy > headerCy && _narrativeStartRe.hasMatch(l.text)) {
        footerCy = footerCy == null
            ? l.cy
            : (l.cy < footerCy ? l.cy : footerCy);
      }
    }
  }
  // Bound on the header/footer centres, so a range printed slightly above its
  // row survives, and skip the header/footer lines themselves by text.
  return [
    for (final l in lines)
      if (!_noiseRe.hasMatch(l.text) &&
          !_headerRe.hasMatch(l.text) &&
          !_footerRe.hasMatch(l.text) &&
          !_narrativeStartRe.hasMatch(l.text) &&
          !_categoricalRangeRe.hasMatch(l.text) &&
          !_methodDetailRe.hasMatch(l.text) &&
          (headerCy == null || l.cy >= headerCy) &&
          (footerCy == null || l.cy < footerCy))
        l,
  ];
}

/// Turns ML Kit word boxes into table cells: a line that is already one column
/// is rejoined, a line holding a whole row is split at the wide column gaps.
List<OcrLine> _semanticElementLines(
  OcrGeometryPage geometry,
  List<OcrLine> lineRegion,
) {
  if (geometry.elements.isEmpty || lineRegion.isEmpty) return const [];
  final acceptedParents = <int>{};
  for (var i = 0; i < geometry.lines.length; i++) {
    final line = geometry.lines[i];
    if (lineRegion.contains(line) ||
        lineRegion.any(
          (candidate) =>
              candidate.text == line.text &&
              (candidate.cy - line.cy).abs() < 0.5 &&
              (candidate.left - line.left).abs() < 0.5,
        )) {
      acceptedParents.add(i);
    }
  }

  final byParent = <int, List<OcrElementBox>>{};
  for (final element in geometry.elements) {
    if (acceptedParents.contains(element.parentLine) &&
        element.text.trim().isNotEmpty) {
      byParent.putIfAbsent(element.parentLine, () => []).add(element);
    }
  }
  final output = <OcrLine>[];
  for (final elements in byParent.values) {
    elements.sort((a, b) => a.left.compareTo(b.left));
    final charWidths = <double>[
      for (final element in elements)
        if (element.width > 0 && _elementText(element).isNotEmpty)
          element.width / _elementText(element).length,
    ]..sort();
    final heights = <double>[
      for (final element in elements)
        if (element.height > 0) element.height,
    ]..sort();
    final charWidth = charWidths.isEmpty
        ? 8.0
        : charWidths[charWidths.length ~/ 2];
    final height = heights.isEmpty ? 12.0 : heights[heights.length ~/ 2];
    final splitGap = charWidth * 3.2 > height * 1.35
        ? charWidth * 3.2
        : height * 1.35;

    var group = <OcrElementBox>[];
    void flush() {
      if (group.isEmpty) return;
      final text = _joinElementText(group);
      if (text.isNotEmpty) {
        output.add(
          OcrLine(
            text,
            group.first.left,
            group.map((e) => e.top).reduce((a, b) => a < b ? a : b),
            group.last.right,
            group.map((e) => e.bottom).reduce((a, b) => a > b ? a : b),
            confidence: _minimumElementConfidence(group),
          ),
        );
      }
      group = <OcrElementBox>[];
    }

    for (final element in elements) {
      if (group.isNotEmpty && element.left - group.last.right > splitGap) {
        flush();
      }
      group.add(element);
    }
    flush();
  }
  output.sort((a, b) {
    final vertical = a.cy.compareTo(b.cy);
    return vertical == 0 ? a.left.compareTo(b.left) : vertical;
  });
  return output;
}

double? _minimumElementConfidence(List<OcrElementBox> elements) {
  final values = [
    for (final element in elements)
      if (element.confidence != null) element.confidence!,
  ];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a < b ? a : b);
}

String _elementText(OcrElementBox element) {
  if (element.symbols.isEmpty) return element.text.trim();
  final symbols = [...element.symbols]
    ..sort((a, b) => a.left.compareTo(b.left));
  final rebuilt = symbols.map((symbol) => symbol.text).join().trim();
  if (rebuilt.isEmpty) return element.text.trim();
  final original = element.text.replaceAll(RegExp(r'\s+'), '');
  return (rebuilt.length - original.length).abs() <= 2
      ? rebuilt
      : element.text.trim();
}

String _joinElementText(List<OcrElementBox> elements) {
  final parts = [for (final element in elements) _elementText(element)];
  final out = StringBuffer();
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    if (part.isEmpty) continue;
    if (out.isNotEmpty) {
      final previous = parts[i - 1];
      final punctuation =
          RegExp(r'^[.,/%<>-]$').hasMatch(part) ||
          RegExp(r'[./<>=-]$').hasMatch(previous);
      if (!punctuation) out.write(' ');
    }
    out.write(part);
  }
  return out.toString().trim();
}

// ─────────────────────────────────────────────────────────────────────────────
// OCR character-confusion repair (numeric fields only).
// ─────────────────────────────────────────────────────────────────────────────

/// Letters OCR commonly mistakes for digits, and the digit each should be.
const _confusable = {
  'O': '0',
  'o': '0',
  'Q': '0',
  'D': '0',
  'l': '1',
  'I': '1',
  '|': '1',
  'B': '8',
  'S': '5',
  'Z': '2',
  'g': '9',
};

final _digit = RegExp(r'\d');
final _allConfusableOrPunct = RegExp(r'^[OoQDlI|BSZg.,\-–—<>/]+$');

/// Repairs digit-as-letter OCR slips, only inside clearly numeric tokens: one
/// already containing a digit, or made entirely of confusable letters. Units and
/// test names are left untouched.
String _fixNumeric(String text) {
  return text
      .split(' ')
      .map((token) {
        if (token.isEmpty) return token;
        final numericContext =
            _digit.hasMatch(token) || _allConfusableOrPunct.hasMatch(token);
        if (!numericContext) return token;
        final b = StringBuffer();
        for (final ch in token.split('')) {
          b.write(_confusable[ch] ?? ch);
        }
        return b.toString();
      })
      .join(' ');
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit repair: OCR turns "mg/dl" → "mgld!", "IU/L" → "IUIL" (the slash read as a
// letter). A recognised unit token is snapped back to its canonical spelling.
// ─────────────────────────────────────────────────────────────────────────────

/// Characters OCR routinely swaps for one another around a unit's slash.
const _slashish = {'i', 'l', '1', '!', '|', '/', r'\'};

const _knownUnits = [
  'mg/dl',
  'g/dl',
  'gm%',
  'g%',
  'IU/L',
  'IU/mL',
  'AU/mL',
  'U/L',
  'mIU/L',
  'mmol/L',
  'mEq/L',
  'ng/mL',
  'ng/dL',
  'pg/mL',
  'µg/dL',
  'mg/L',
  '/µL',
  '%',
  'mill/cu.mm',
  'cells/cu.mm',
  '/c.mm',
  '/cu.mm',
  '10^3/µL',
  'fL',
  'pg',
];

/// Collapses the slash/I/l/1 family to one placeholder and µ→u, so a mangled
/// unit and its canonical spelling compare equal.
String _canonUnit(String s) {
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    if (ch == 'µ') {
      b.write('u');
    } else if (_slashish.contains(ch)) {
      b.write('_');
    } else {
      b.write(ch);
    }
  }
  return b.toString();
}

/// Snaps each non-numeric token of a value/range to a known unit spelling.
String _fixUnits(String field) {
  return field
      .split(' ')
      .map((tok) {
        if (tok.isEmpty || _digit.hasMatch(tok)) return tok;
        final core = tok.replaceAll(RegExp(r'[.,;:]+$'), '');
        if (core.length < 2) return tok;
        final canon = _canonUnit(core);
        for (final u in _knownUnits) {
          if (_canonUnit(u) == canon) return tok.replaceFirst(core, u);
        }
        return tok;
      })
      .join(' ');
}

bool _looksLikeUnit(String text) {
  final compact = text.trim().replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty || compact.length > 18) return false;
  if (_knownUnits.any((u) => _canonUnit(u) == _canonUnit(compact))) return true;
  return RegExp(
    r'^(?:10\^?\d+)?/?(?:cells?|mill|g|mg|mcg|ug|ng|pg|iu|miu|mmol|meq|fl)?'
    r'(?:[/\.]?(?:cu\.?mm|c\.?mm|ul|ml|dl|l))?%?$',
    caseSensitive: false,
  ).hasMatch(compact);
}

String? _fixUnitToken(String? unit) {
  if (unit == null || unit.trim().isEmpty) return null;
  final fixed = _fixUnits(unit.trim());
  return _looksLikeUnit(fixed) ? fixed : null;
}

({String? range, String? unit}) _splitRangeUnit(String? field) {
  if (field == null || field.trim().isEmpty) return (range: field, unit: null);
  final text = field.trim();
  // A CBC unit can start with a number (10^3/µL), so splitting on the final
  // numeric token would eat the exponent. Take the earliest whitespace boundary
  // whose suffix is wholly a recognised unit.
  for (final boundary in RegExp(r'\s+').allMatches(text)) {
    final prefix = text.substring(0, boundary.start).trim();
    final suffix = text.substring(boundary.end).trim();
    if (_digit.hasMatch(prefix) && _looksLikeUnit(suffix)) {
      return (range: prefix, unit: suffix);
    }
  }
  final nums = RegExp(r'\d+(?:\.\d+)?').allMatches(text).toList();
  if (nums.isEmpty) return (range: text, unit: null);
  final suffix = text.substring(nums.last.end).trim();
  if (!_looksLikeUnit(suffix)) return (range: text, unit: null);
  return (range: text.substring(0, nums.last.end).trim(), unit: suffix);
}

({String value, String? unit}) _splitValueUnit(String field) {
  final text = field.trim();
  final number = RegExp(r'^\d[\d,]*(?:\.\d+)?').firstMatch(text);
  if (number == null) return (value: text, unit: null);
  final suffix = text.substring(number.end).trim();
  if (!_looksLikeUnit(suffix)) return (value: text, unit: null);
  return (value: number.group(0)!, unit: suffix);
}

/// The standard unit for tests whose unit is universal, so a garbled "IU/L"
/// still reads correctly. Omits proteins and ratios, whose unit varies by lab.
/// Null means keep the scanned unit.
String? _standardUnit(String label) {
  // Strip punctuation/spaces so "S.G.P.T." matches "sgpt".
  final l = label.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  const enzymes = [
    'sgpt',
    'sgot',
    'alkaline',
    'phosphatase',
    'ggt',
    'gammagt',
    'ldh',
    'amylase',
    'lipase',
    'transaminase',
  ];
  const mgdl = [
    'bilirubin',
    'glucose',
    'cholesterol',
    'ldl',
    'hdl',
    'triglycer',
    'creatinine',
    'urea',
    'uricacid',
    'calcium',
    'phosphorus',
  ];
  if (enzymes.any(l.contains)) return 'IU/L';
  if (mgdl.any(l.contains)) return 'mg/dl';
  return null;
}

/// Replaces the trailing unit of a range with the test's standard unit (numbers
/// untouched). Appends it when the range has no unit. No-op for tests without a
/// standard unit.
String _applyStandardUnit(String label, String range) {
  final std = _standardUnit(label);
  if (std == null || range.isEmpty) return range;
  final tokens = range.split(RegExp(r'\s+'));
  final last = tokens.last;
  final isNumber = RegExp(r'^[\d.]+$').hasMatch(last);
  if (!isNumber && RegExp(r'[A-Za-zµ%]').hasMatch(last)) {
    tokens[tokens.length - 1] = std; // replace the (possibly garbled) unit
  } else {
    tokens.add(std); // range had no unit
  }
  return tokens.join(' ');
}

// ─────────────────────────────────────────────────────────────────────────────
// Classification.
// ─────────────────────────────────────────────────────────────────────────────

enum _Kind { label, value, range, ignore }

final _rangeRe = RegExp(
  r'[<>≤≥]\s*\d|\d+(?:\.\d+)?\s*(?:[-–—]|to)\s*\d+(?:\.\d+)?',
);
// A lone measurement, tolerating a trailing abnormal-flag (*, #, ↑, ↓).
final _valueRe = RegExp(r'^\d[\d,]*(?:\.\d+)?\s*[*#↑↓]?\s*[a-zA-Z%/µ]*$');

/// Strips a trailing abnormal-flag marker from a value (e.g. "0.86 *" → "0.86").
String _stripFlags(String s) =>
    s.replaceAll(RegExp(r'\s*[*#↑↓]\s*$'), '').trim();

/// A line whose whole text is just a unit (the 4th column on some reports).
bool _isUnitLine(String text) {
  final t = text.trim().replaceAll(RegExp(r'[.,;:]+$'), '');
  if (t.isEmpty || t.length > 18) return false;
  if (_digit.hasMatch(t) &&
      !RegExp(r'^10\^?\d+', caseSensitive: false).hasMatch(t)) {
    return false;
  }
  final canon = _canonUnit(t);
  if (_knownUnits.any((u) => _canonUnit(u) == canon)) return true;
  return const {'%', 'fl', 'pg', 'gm%', 'g%'}.contains(t.toLowerCase());
}

/// ~0.7 of the median text-line height: how close a value must be to a label to
/// count as sharing its row.
double _lineTol(List<_Cell> cells, List<_Cell> labels) {
  final heights = [
    for (final c in cells)
      if (c.line.bottom - c.line.top > 0) c.line.bottom - c.line.top,
  ]..sort();
  final medianHeight = heights.isEmpty ? 12.0 : heights[heights.length ~/ 2];
  final ys = labels.map((c) => c.cy).toList()..sort();
  final gaps = <double>[
    for (var i = 1; i < ys.length; i++)
      if (ys[i] - ys[i - 1] > medianHeight * 0.8) ys[i] - ys[i - 1],
  ]..sort();
  final pitch = gaps.isEmpty ? medianHeight * 2 : gaps[gaps.length ~/ 2];
  final desired = medianHeight * 1.15 > pitch * 0.42
      ? medianHeight * 1.15
      : pitch * 0.42;
  return desired < pitch * 0.48 ? desired : pitch * 0.48;
}

bool _hasNearby(_Cell anchor, List<_Cell> items, double tolerance) =>
    items.any((item) => (item.cy - anchor.cy).abs() <= tolerance);

TableRepairEvidence _buildRepairEvidence(
  List<OcrLine> region,
  List<DocumentResult> results, {
  List<TableGridCell> grid = const [],
}) {
  if (region.isEmpty || results.isEmpty) {
    return TableRepairEvidence(const [], cells: grid);
  }
  final cells = [
    for (final line in region) _Cell(line, _fixNumeric(line.text)),
  ];
  final labelCells = cells
      .where((cell) => _classify(cell.norm) == _Kind.label)
      .toList();
  if (labelCells.isEmpty) return TableRepairEvidence(const [], cells: grid);
  final tolerance = _lineTol(cells, labelCells);
  final evidence = <TableEvidenceRow>[];
  for (var order = 0; order < results.length; order++) {
    final result = results[order];
    _Cell? anchor;
    var bestScore = 0;
    for (final candidate in labelCells) {
      final score = _labelMatchScore(result.label, candidate.original);
      if (score > bestScore) {
        anchor = candidate;
        bestScore = score;
      }
    }
    if (anchor == null || bestScore == 0) continue;
    final row =
        cells
            .where((cell) => (cell.cy - anchor!.cy).abs() <= tolerance)
            .toList()
          ..sort((a, b) => a.left.compareTo(b.left));
    evidence.add(
      TableEvidenceRow(
        label: result.label,
        rowText: row.map((cell) => cell.original.trim()).join(' '),
        order: order,
        incomplete: result.needsReview,
      ),
    );
  }
  return TableRepairEvidence(evidence, cells: grid);
}

({List<TableGridCell> cells, TableGridQuality quality}) _buildTableGrid(
  List<OcrLine> region, {
  TableCellGranularity granularity = TableCellGranularity.line,
}) {
  if (region.isEmpty) {
    return (
      cells: const [],
      quality: const TableGridQuality(hasTable: false, needsRetry: false),
    );
  }
  final all = [for (final line in region) _Cell(line, _fixNumeric(line.text))];
  final classifiedLabels =
      all.where((cell) => _classify(cell.norm) == _Kind.label).toList()
        ..sort((a, b) => a.cy.compareTo(b.cy));
  final rawValues = all
      .where((cell) => _classify(cell.norm) == _Kind.value)
      .toList();
  if (classifiedLabels.isEmpty || rawValues.isEmpty) {
    return (
      cells: const [],
      quality: const TableGridQuality(hasTable: false, needsRetry: false),
    );
  }

  // Column membership is geometry-derived; text classification only supplies
  // anchors. That is what lets an unfamiliar unit or an OCR "O" still reach the
  // reconciler instead of being discarded locally.
  final anchors = _geometryColumnAnchors(all);
  TableCellColumn columnFor(_Cell cell) {
    var best = anchors.keys.first;
    var distance = double.infinity;
    for (final entry in anchors.entries) {
      final d = (cell.left - entry.value).abs();
      if (d < distance) {
        distance = d;
        best = entry.key;
      }
    }
    return best;
  }

  final labels =
      all.where((cell) => columnFor(cell) == TableCellColumn.label).toList()
        ..sort((a, b) => a.cy.compareTo(b.cy));
  final valueCells = all
      .where((cell) => columnFor(cell) == TableCellColumn.value)
      .toList();

  int rowFor(_Cell cell) {
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < labels.length; i++) {
      final distance = (labels[i].cy - cell.cy).abs();
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    return best;
  }

  final grid = <TableGridCell>[];
  for (final cell in all) {
    final row = rowFor(cell);
    grid.add(
      TableGridCell(
        id: 'c${grid.length}',
        text: cell.original.trim(),
        column: columnFor(cell),
        rowHint: row,
        section: row ~/ 12,
        granularity: granularity,
        confidence: cell.line.confidence,
        left: cell.line.left,
        top: cell.line.top,
        right: cell.line.right,
        bottom: cell.line.bottom,
      ),
    );
  }

  final tolerance = _lineTol(all, labels);
  var unmatched = 0;
  for (var i = 0; i < labels.length; i++) {
    if (_isLikelySectionHeading(
      i,
      labels,
      values: valueCells,
      tolerance: tolerance,
    )) {
      continue;
    }
    if (!_hasNearby(labels[i], valueCells, tolerance)) unmatched++;
  }
  final outliers = rawValues
      .where((cell) => columnFor(cell) != TableCellColumn.value)
      .length;
  return (
    cells: grid,
    quality: TableGridQuality(
      hasTable: true,
      needsRetry: unmatched > 0 || outliers > 0,
      unmatchedLabels: unmatched,
      valueOutliers: outliers,
    ),
  );
}

Map<TableCellColumn, double> _geometryColumnAnchors(List<_Cell> cells) {
  double? median(Iterable<_Cell> source) {
    final xs = source.map((cell) => cell.left).toList()..sort();
    return xs.isEmpty ? null : xs[xs.length ~/ 2];
  }

  final label =
      median(
        cells.where(
          (cell) =>
              _classify(cell.norm) == _Kind.label && !_isUnitLine(cell.norm),
        ),
      ) ??
      cells.map((cell) => cell.left).reduce((a, b) => a < b ? a : b);
  final value = median(
    cells.where((cell) => _classify(cell.norm) == _Kind.value),
  );
  final unit = median(cells.where((cell) => _isUnitLine(cell.norm)));
  final range = median(
    cells.where((cell) => _classify(cell.norm) == _Kind.range),
  );
  final clusters = cells.map((cell) => cell.left).toList()..sort();
  final distinct = <double>[];
  for (final x in clusters) {
    if (distinct.isEmpty || (x - distinct.last).abs() > 35) distinct.add(x);
  }
  final fallbackValue = distinct.length > 1 ? distinct[1] : label + 200;
  final fallbackRange = distinct.length > 2
      ? distinct.last
      : fallbackValue + 200;
  final anchors = <TableCellColumn, double>{
    TableCellColumn.label: label,
    TableCellColumn.value: value ?? fallbackValue,
    TableCellColumn.range: range ?? fallbackRange,
  };
  if (unit != null &&
      (unit - anchors[TableCellColumn.value]!).abs() > 25 &&
      (unit - anchors[TableCellColumn.range]!).abs() > 25) {
    anchors[TableCellColumn.unit] = unit;
  } else if (distinct.length >= 4) {
    anchors[TableCellColumn.unit] = distinct[distinct.length - 2];
  }
  return anchors;
}

/// Accepts a model proposal only when its label and every field occur together
/// in one bounded OCR row. Stricter than the general JSON grounding check, which
/// proves only that digits occur somewhere on the page.
List<DocumentResult> verifyTableRepairProposals(
  List<DocumentResult> proposals,
  TableRepairEvidence evidence,
) {
  final verified = <({int order, DocumentResult result})>[];
  final usedRows = <int>{};
  for (final proposal in proposals) {
    final candidates = <({TableEvidenceRow row, int score})>[];
    for (final row in evidence.rows) {
      if (usedRows.contains(row.order)) continue;
      final score = _labelMatchScore(proposal.label, row.label);
      if (score == 0) continue;
      if (!_containsExactField(row.rowText, proposal.value, numeric: true)) {
        continue;
      }
      if (proposal.unit != null &&
          !_containsExactField(row.rowText, proposal.unit!)) {
        continue;
      }
      if (proposal.range != null &&
          !_containsExactField(row.rowText, proposal.range!)) {
        continue;
      }
      candidates.add((row: row, score: score));
    }
    if (candidates.isEmpty) continue;
    final bestScore = candidates
        .map((candidate) => candidate.score)
        .reduce((a, b) => a > b ? a : b);
    final best = candidates
        .where((candidate) => candidate.score == bestScore)
        .toList();
    // Equal-quality matches are ambiguous (often repeated CBC labels). Leave
    // the row unresolved instead of picking whichever happened to come first.
    if (best.length != 1) continue;
    final matched = best.single.row;
    usedRows.add(matched.order);
    verified.add((
      order: matched.order,
      result: DocumentResult(
        matched.label,
        proposal.value,
        unit: proposal.unit,
        range: proposal.range,
      ),
    ));
  }
  verified.sort((a, b) => a.order.compareTo(b.order));
  return [for (final item in verified) item.result];
}

/// Parses the cloud model's row choices but copies every medical field from
/// local OCR cells. The response carries IDs only, so invented text has no path
/// into [DocumentResult].
List<DocumentResult> parseTableCellReconciliation(
  String raw,
  TableRepairEvidence evidence,
) {
  final object = _firstReconciliationObject(raw);
  final rows = object?['tableRows'];
  if (rows is! List || evidence.cells.isEmpty) return const [];
  final byId = {for (final cell in evidence.cells) cell.id: cell};
  final usedLabels = <String>{};
  final usedValues = <String>{};
  final accepted = <({int pass, int row, DocumentResult result})>[];

  for (final rawRow in rows) {
    if (rawRow is! Map) continue;
    final labelId = rawRow['labelCell']?.toString();
    final valueId = rawRow['valueCell']?.toString();
    final label = byId[labelId];
    final value = byId[valueId];
    if (label == null || value == null) continue;
    if (label.column != TableCellColumn.label ||
        value.column != TableCellColumn.value) {
      continue;
    }
    if (label.pass != value.pass || label.rowHint != value.rowHint) continue;
    if (usedLabels.contains(label.id) || usedValues.contains(value.id)) {
      continue;
    }
    if (_sectionHeading.hasMatch(label.text.trim())) continue;

    TableGridCell? unit;
    final unitId = rawRow['unitCell']?.toString();
    if (unitId != null && unitId.isNotEmpty) {
      unit = byId[unitId];
      if (unit == null ||
          unit.column != TableCellColumn.unit ||
          unit.pass != label.pass ||
          (unit.rowHint - label.rowHint).abs() > 1) {
        continue;
      }
    }

    final ranges = <TableGridCell>[];
    final rangeIds = rawRow['rangeCells'];
    if (rangeIds is List) {
      var invalid = false;
      for (final id in rangeIds) {
        final range = byId[id.toString()];
        if (range == null ||
            range.column != TableCellColumn.range ||
            range.pass != label.pass ||
            (range.rowHint - label.rowHint).abs() > 1) {
          invalid = true;
          break;
        }
        ranges.add(range);
      }
      if (invalid) continue;
    }

    final splitValue = _splitValueUnit(_fixUnits(_fixNumeric(value.text)));
    final rawRange = ranges.isEmpty
        ? null
        : ranges.map((cell) => _fixNumeric(cell.text.trim())).join(' ');
    final splitRange = _splitRangeUnit(
      rawRange == null ? null : _fixUnits(rawRange),
    );
    final resultUnit =
        _fixUnitToken(unit?.text ?? splitValue.unit ?? splitRange.unit) ??
        _standardUnit(label.text);
    final resultValue = _stripFlags(splitValue.value.trim());
    if (resultValue.isEmpty || !_digit.hasMatch(resultValue)) continue;

    usedLabels.add(label.id);
    usedValues.add(value.id);
    accepted.add((
      pass: label.pass,
      row: label.rowHint,
      result: DocumentResult(
        _cleanLabel(label.text),
        resultValue,
        unit: resultUnit,
        range: splitRange.range?.trim().isEmpty ?? true
            ? null
            : splitRange.range!.trim(),
      ),
    ));
  }
  // Keep recoveries from every pass: overlapping-tile duplicates collapse
  // locally, and a later merge keeps deterministic rows when passes disagree.
  accepted.sort((a, b) {
    final passOrder = a.pass.compareTo(b.pass);
    return passOrder != 0 ? passOrder : a.row.compareTo(b.row);
  });
  final seen = <String>{};
  final selected = <DocumentResult>[];
  for (final item in accepted) {
    final result = item.result;
    final signature =
        [result.label, result.value, result.unit ?? '', result.range ?? '']
            .map((part) => part.toLowerCase().replaceAll(RegExp(r'\s+'), ''))
            .join('|');
    if (seen.add(signature)) selected.add(result);
  }
  return selected;
}

Map<String, dynamic>? _firstReconciliationObject(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final decoded = jsonDecode(raw.substring(start, end + 1));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

int _labelMatchScore(String a, String b) {
  final left = _fieldKey(a);
  final right = _fieldKey(b);
  if (left.isEmpty || right.isEmpty) return 0;
  if (left == right) return 3;
  final shorter = left.length < right.length ? left : right;
  if (shorter.length >= 4 && (left.contains(right) || right.contains(left))) {
    return 2;
  }
  final leftWords = _wordKeys(a);
  final rightWords = _wordKeys(b);
  final overlap = leftWords.intersection(rightWords).length;
  return overlap >= 2 ? 1 : 0;
}

Set<String> _wordKeys(String value) => value
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((word) => word.length >= 2)
    .toSet();

String _fieldKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

bool _containsExactField(String rowText, String field, {bool numeric = false}) {
  final needle = field.trim();
  if (needle.isEmpty) return false;
  final haystack = rowText.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final normalizedNeedle = needle.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  if (!numeric) return haystack.contains(normalizedNeedle);
  final escaped = RegExp.escape(normalizedNeedle);
  return RegExp('(?:^|[^0-9.,])$escaped(?=\$|[^0-9.,])').hasMatch(haystack);
}

final _sectionHeading = RegExp(
  r'^(?:erythrocytes|leucocytes|leukocytes|platelets?|differential(?: count)?|'
  r'absolute differential counts?|blood indices|investigation)$',
  caseSensitive: false,
);

bool _isLikelySectionHeading(
  int index,
  List<_Cell> labels, {
  List<_Cell> values = const [],
  double tolerance = 0,
}) {
  final text = labels[index].norm.toLowerCase().trim();
  if (!_sectionHeading.hasMatch(text)) {
    final original = labels[index].original.trim();
    final letters = original.replaceAll(RegExp(r'[^A-Za-z]+'), '');
    final allCaps = letters.length >= 8 && letters == letters.toUpperCase();
    final multiWord = original.trim().split(RegExp(r'\s+')).length >= 2;
    final hasOwnValue =
        tolerance > 0 &&
        values.any(
          (value) => (value.cy - labels[index].cy).abs() <= tolerance * 0.55,
        );
    return allCaps && multiWord && !hasOwnValue && index + 1 < labels.length;
  }
  final stem = text.startsWith('erythro')
      ? 'erythro'
      : text.startsWith('leuco') || text.startsWith('leuko')
      ? 'leuco'
      : text.startsWith('platelet')
      ? 'platelet'
      : null;
  if (stem == null) return true;
  for (var i = index + 1; i < labels.length && i <= index + 2; i++) {
    final next = labels[i].norm.toLowerCase().replaceAll('leuko', 'leuco');
    if (next.contains(stem)) return true;
  }
  return false;
}

_Kind _classify(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return _Kind.ignore;
  if (_rangeRe.hasMatch(t)) return _Kind.range;
  if (_valueRe.hasMatch(t)) return _Kind.value;
  final letters = RegExp(r'[A-Za-z]').allMatches(t).length;
  final digits = RegExp(r'\d').allMatches(t).length;
  if (letters >= 2 && letters > digits) return _Kind.label;
  return _Kind.ignore;
}

/// Tidies a recognised test name (collapses whitespace; trims trailing colons).
String _cleanLabel(String raw) => raw
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'[:\-\s]+$'), '')
    .trim();

// ─────────────────────────────────────────────────────────────────────────────
// Merged-row mode: one line carries label + value + range.
// ─────────────────────────────────────────────────────────────────────────────

final _trailingRangeRe = RegExp(
  r'([<>≤≥]\s*\d+(?:\.\d+)?|\d+(?:\.\d+)?\s*[-–—]\s*\d+(?:\.\d+)?)\s*[a-zA-Z%/µ.]*\s*$',
);
final _trailingValueRe = RegExp(r'\d[\d,]*(?:\.\d+)?\s*[a-zA-Z%/µ]*$');

List<DocumentResult> _fullRowMode(List<OcrLine> region) {
  final out = <DocumentResult>[];
  for (final line in region) {
    final fr = _tryFullRow(_fixNumeric(line.text));
    if (fr != null) out.add(fr);
  }
  return out;
}

DocumentResult? _tryFullRow(String raw) {
  var rest = raw.trim();
  String? range;
  final rm = _trailingRangeRe.firstMatch(rest);
  if (rm != null) {
    range = rm.group(0)!.trim();
    rest = rest.substring(0, rm.start).trim();
  }
  final vm = _trailingValueRe.firstMatch(rest);
  if (vm == null) return null;
  final rawValue = vm.group(0)!.trim();
  final label = _cleanLabel(rest.substring(0, vm.start));
  if (RegExp(r'[A-Za-z].*[A-Za-z]').hasMatch(label) == false) return null;
  final splitValue = _splitValueUnit(rawValue);
  final splitRange = _splitRangeUnit(range);
  return DocumentResult(
    label,
    splitValue.value,
    unit:
        _fixUnitToken(splitValue.unit ?? splitRange.unit) ??
        _standardUnit(label),
    range: splitRange.range,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Column helpers.
// ─────────────────────────────────────────────────────────────────────────────

/// Removes items whose left edge is far from the column's median (a stray number
/// from elsewhere on the page). No-op for small/tight columns.
List<_Cell> _dropColumnOutliers(List<_Cell> items) {
  if (items.length < 4) return items;
  final lefts = items.map((e) => e.left).toList()..sort();
  final median = lefts[lefts.length ~/ 2];
  final devs = lefts.map((x) => (x - median).abs()).toList()..sort();
  final mad = devs[devs.length ~/ 2];
  // A perfectly aligned value column has MAD=0, which is the strongest signal,
  // not a reason to keep every outlier. Scale the tight fallback by cell width
  // so it stays stable across camera resolutions.
  final widths = items.map((e) => e.line.right - e.line.left).toList()..sort();
  final medianWidth = widths[widths.length ~/ 2];
  final tol = mad == 0 ? (medianWidth * 0.75).clamp(12.0, 48.0) : mad * 4 + 1;
  return [
    for (final e in items)
      if ((e.left - median).abs() <= tol) e,
  ];
}

/// Monotonic nearest-y assignment of [items] to [anchors], used only when the
/// counts differ. Leaves a slot null rather than shifting an item onto the wrong
/// row.
List<_Cell?> _assignByOrder(List<_Cell> anchors, List<_Cell> items) {
  final result = List<_Cell?>.filled(anchors.length, null);
  var i = 0;
  for (var m = 0; m < anchors.length && i < items.length; m++) {
    final here = (items[i].cy - anchors[m].cy).abs();
    final next = m + 1 < anchors.length
        ? (items[i].cy - anchors[m + 1].cy).abs()
        : double.infinity;
    if (here <= next) {
      result[m] = items[i];
      i++;
    }
  }
  return result;
}
