import '../library/document.dart';
import 'table_parser.dart' show OcrGeometryPage, OcrLine;

/// Deterministic bill reader. A purchased item is accepted only when its name
/// sits in the printed item/description column and its value sits in the
/// printed amount column on the same visual row. The language model may later
/// clean a label, but it is never allowed to invent or re-pair these numbers.

final _moneyRe = RegExp(
  r'(?:(?:₹|\brs\b\.?|\binr\b)\s*\d[\d,]*(?:\.\d{1,2})?|'
  r'(?<![\d.,])\d[\d,]*\.\d{2})(?![\d/])',
  caseSensitive: false,
);

final _inrContextRe = RegExp(
  r'₹|\brs\b\.?|\binr\b|\bgstin\b|\bgst\b|\bpaise\b',
  caseSensitive: false,
);

final _itemHeaderRe = RegExp(
  r'\b(product|item|description|particulars?|service(?:\s+type)?|'
  r'service\s+name|procedure|investigation|medicine|drug|test\s+name)\b',
  caseSensitive: false,
);

final _amountHeaderRe = RegExp(
  r'\b(net\s+amount|line\s+total|amount|charges?|value)\b',
  caseSensitive: false,
);

final _otherHeaderRe = RegExp(
  r'^(s\.?\s*no|sr\.?|qty|quantity|mrp|rate|tariff|department|dept|comp|'
  r'company|manufacturer|mfr|batch|expiry|exp|gst|cgst|sgst|igst|discount|'
  r'dis\s*\(?%?\)?|amount|total)$',
  caseSensitive: false,
);

final _totalLabelRe = RegExp(
  r'^(grand\s*total|net\s*(?:payable|amount)?|final\s*(?:payment|amount)?|'
  r'total\s*bill\s*amount|bill\s*amount|amount\s*(?:paid|payable)|'
  r'total|payable|paid|balance|received|receipt\s*details)\b',
  caseSensitive: false,
);

final _subtotalLabelRe = RegExp(
  r'^(sub\s*-?\s*total|gross|service\s*amount)\b',
  caseSensitive: false,
);

final _taxLabelRe = RegExp(
  r'^(cgst|sgst|igst|vat|tax|gst\s*tax)\b'
  r'(?!\s*\.?\s*(no|number|in|tin|reg))',
  caseSensitive: false,
);

final _discountLabelRe = RegExp(
  r'^(discount|less|round\s*off|rounding)\b',
  caseSensitive: false,
);

final _ignoredSummaryRe = RegExp(
  r'^(amount\s*in\s*words|ref\.?\s*tariff|tariff|mrp|rate)\b',
  caseSensitive: false,
);

/// Administrative text that must never become a purchased item. Structural
/// rather than vendor-specific: registrations, locations, contacts, payment
/// prose, greetings and table headers are noise on every bill.
final _administrativeRe = RegExp(
  r'(?:^|\b)(?:gst\s*(?:no|number|in)|gstin|pan|tan|cin|uin|tin|'
  // "Registration Fee" is a genuine charge; only registration *numbers* are
  // administrative.
  r'd\.?\s*l\.?\s*(?:no|number)|drug\s*lic|licen[cs]e\s*(?:no|number)|'
  r'reg(?:istration|d|n)?\.?\s*(?:no|number)\b|'
  r'inv(?:oice)?\s*(?:no|number)|bill\s*(?:no|number)|receipt\s*(?:no|number)|'
  r'uhid|mrn|patient|doctor|mobile|mob\.?\s*no|phone|tel|fax|email|address|'
  r'shop\s*(?:no|number|#|o)|plot\s*(?:no|number|#|n)|sector|pincode|pin\s*code|'
  r'barcode|batch|expiry|exp\.?\s*date|get\s+well|thank\s+you|goods\s+once|'
  r'cash\s*[:=]|non\s*cash|amount\s+in\s+words)(?:\b|$)',
  caseSensitive: false,
);

final _codeTokenRe = RegExp(r'\b(?=\w*\d)(?=\w*[A-Za-z])[\w/\-]{4,}\b');
final _doseTokenRe = RegExp(
  r'^\d+(?:\.\d+)?\s*(?:mg|ml|gm?|mcg|ug|iu|kg|%|x|s)$',
  caseSensitive: false,
);

enum _RowClass { item, subtotal, tax, discount, total }

class _BillRow {
  const _BillRow(this.label, this.amountText, this.kind, this.order);

  final String label;
  final String amountText;
  final _RowClass kind;
  final int order;
}

class _MoneyToken {
  const _MoneyToken(this.row, this.piece, this.text, this.x);

  final int row;
  final int piece;
  final String text;
  final double x;
}

class _TextGroup {
  const _TextGroup(this.pieces, this.text, this.left, this.right);

  final List<OcrLine> pieces;
  final String text;
  final double left;
  final double right;

  double get center => (left + right) / 2;
}

class _TableHeader {
  const _TableHeader({
    required this.row,
    required this.itemX,
    required this.amountX,
  });

  final int row;
  final double itemX;
  final double amountX;
}

_RowClass? _summaryClass(String label) {
  final clean = _clean(label);
  if (_totalLabelRe.hasMatch(clean)) return _RowClass.total;
  if (_subtotalLabelRe.hasMatch(clean)) return _RowClass.subtotal;
  if (_discountLabelRe.hasMatch(clean)) return _RowClass.discount;
  if (_taxLabelRe.hasMatch(clean)) return _RowClass.tax;
  return _fuzzySummaryClass(clean);
}

/// OCR mangles "Total Bill Amount" differently on every scan of the same page,
/// defeating the anchored classes above. This last line of defence matches each
/// word fuzzily: a short label made almost entirely of near-misses is a summary
/// row, never a purchase.
const _totalVocab = [
  'total',
  'bill',
  'amount',
  'final',
  'payment',
  'net',
  'grand',
  'paid',
  'payable',
  'balance',
  'received',
];
const _subtotalVocab = ['sub', 'subtotal', 'gross'];

int _editDistance(String a, String b) {
  final previous = List<int>.generate(b.length + 1, (i) => i);
  final current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      current[j] = [
        previous[j] + 1,
        current[j - 1] + 1,
        substitution,
      ].reduce((x, y) => x < y ? x : y);
    }
    previous.setAll(0, current);
  }
  return previous[b.length];
}

bool _fuzzyWordEq(String word, String target) {
  if (word == target) return true;
  if ((word.length - target.length).abs() > 2) return false;
  return _editDistance(word, target) <= (target.length >= 6 ? 2 : 1);
}

_RowClass? _fuzzySummaryClass(String clean) {
  final words = RegExp(r'[A-Za-z]{3,}')
      .allMatches(clean)
      .map((match) => match.group(0)!.toLowerCase())
      .toList();
  if (words.length < 2 || words.length > 5) return null;
  var totalHits = 0;
  var subHits = 0;
  for (final word in words) {
    if (_totalVocab.any((target) => _fuzzyWordEq(word, target))) {
      totalHits++;
    } else if (_subtotalVocab.any((target) => _fuzzyWordEq(word, target))) {
      subHits++;
    }
  }
  final hits = totalHits + subHits;
  // Nearly every word must be money vocabulary: "Total Knee Replacement"
  // stays an item question, "loal Bil Amount" does not.
  if (hits < 2 || hits < words.length - 1) return null;
  return subHits > totalHits ? _RowClass.subtotal : _RowClass.total;
}

/// Strong wording decides immediately. Weaker billing signals need at least
/// two matches so a laboratory page containing only "Bill No" stays a lab.
bool looksLikeBill(String text) {
  final lower = text.toLowerCase();
  if (RegExp(
    r'\breceipt\b|\binvoice\b|cash\s*bill|tax\s*invoice|bill\s*of\s*supply|'
    r'\bgstin\b|amount\s*paid|total\s*paid|grand\s*total|amount\s*in\s*words|'
    r'net\s*(payable|amount)|\bcash\s*memo\b',
  ).hasMatch(lower)) {
    return true;
  }
  var weak = 0;
  for (final re in [
    RegExp(r'sub\s*-?\s*total'),
    RegExp(r'\bmrp\b'),
    RegExp(r'bill\s*(no|amount|date)'),
    RegExp(r'\bgst\b'),
    RegExp(r'₹|\brs\.?\s*\d'),
    RegExp(r'final\s*payment'),
  ]) {
    if (re.hasMatch(lower)) weak++;
  }
  return weak >= 2;
}

/// Reads item/amount pairs and summary amounts from OCR geometry. Word-level
/// [geometry] preserves true columns when ML Kit merges a printed row into one
/// TextLine; callers may omit it and use line boxes instead.
List<DocumentResult> parseReceiptBreakdown(
  List<OcrLine> lines, {
  OcrGeometryPage? geometry,
  String pageText = '',
}) {
  if (lines.isEmpty) return const [];
  final pieces = geometry != null && geometry.elements.isNotEmpty
      ? [
          for (final element in geometry.elements)
            OcrLine(
              element.text,
              element.left,
              element.top,
              element.right,
              element.bottom,
              confidence: element.confidence,
            ),
        ]
      : lines;
  final rows = _visualRows(pieces);
  if (rows.isEmpty) return const [];

  var minLeft = double.infinity;
  var maxRight = double.negativeInfinity;
  for (final piece in pieces) {
    if (piece.left < minLeft) minLeft = piece.left;
    if (piece.right > maxRight) maxRight = piece.right;
  }
  final pageWidth = (maxRight - minLeft).abs().clamp(1.0, double.infinity);
  final groups = [for (final row in rows) _groupsForRow(row, pageWidth)];
  final header = _findTableHeader(rows, groups);
  final tokens = _moneyTokens(rows);
  if (tokens.isEmpty) return const [];

  final amountColumn = _amountColumnTokens(
    tokens,
    pageWidth: pageWidth,
    headerX: header?.amountX,
  );
  final firstSummaryAfterHeader = header == null
      ? null
      : _firstSummaryRow(groups, after: header.row);

  final parsed = <_BillRow>[];
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    final rowGroups = groups[rowIndex];
    final rowTokens = tokens.where((token) => token.row == rowIndex).toList();
    if (rowTokens.isEmpty) continue;

    final summaryGroup = rowGroups.cast<_TextGroup?>().firstWhere(
      (group) => group != null && _summaryClass(group.text) != null,
      orElse: () => null,
    );
    if (summaryGroup != null) {
      final kind = _summaryClass(summaryGroup.text)!;
      if (_ignoredSummaryRe.hasMatch(_clean(summaryGroup.text))) continue;
      final amount = rowTokens.reduce((a, b) => a.x >= b.x ? a : b);
      if ((_amountValue(amount.text) ?? 0) == 0) continue;
      parsed.add(
        _BillRow(_clean(summaryGroup.text), amount.text, kind, rowIndex),
      );
      continue;
    }

    // With a printed header, item rows exist only inside its table body. This
    // single boundary prevents letterhead/footer money from becoming items.
    if (header != null && rowIndex <= header.row) continue;
    if (firstSummaryAfterHeader != null &&
        rowIndex >= firstSummaryAfterHeader) {
      continue;
    }

    final rowAmountTokens = rowTokens.where(amountColumn.contains).toList();
    if (rowAmountTokens.isEmpty) continue;
    final amount = rowAmountTokens.reduce((a, b) => a.x >= b.x ? a : b);
    if ((_amountValue(amount.text) ?? 0) == 0) continue;

    final label = _itemLabel(
      rowGroups,
      amountX: amount.x,
      preferredX: header?.itemX,
    );
    if (label == null || !isPlausibleReceiptItemLabel(label)) continue;
    parsed.add(_BillRow(label, amount.text, _RowClass.item, rowIndex));
  }
  return _shapeReceiptRows(parsed, pageText: pageText);
}

List<List<OcrLine>> _visualRows(List<OcrLine> pieces) {
  final sorted = [...pieces]
    ..sort((a, b) {
      final vertical = a.cy.compareTo(b.cy);
      return vertical != 0 ? vertical : a.left.compareTo(b.left);
    });
  final rows = <List<OcrLine>>[];
  final centers = <double>[];
  for (final piece in sorted) {
    final height = (piece.bottom - piece.top).abs().clamp(1.0, double.infinity);
    var best = -1;
    var bestDistance = double.infinity;
    for (var i = rows.length - 1; i >= 0 && i >= rows.length - 3; i--) {
      final referenceHeight = (rows[i].first.bottom - rows[i].first.top)
          .abs()
          .clamp(1.0, double.infinity);
      final distance = (centers[i] - piece.cy).abs();
      if (distance <=
              (height > referenceHeight ? height : referenceHeight) * 0.65 &&
          distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    if (best < 0) {
      rows.add([piece]);
      centers.add(piece.cy);
    } else {
      rows[best].add(piece);
      centers[best] =
          rows[best].map((p) => p.cy).reduce((a, b) => a + b) /
          rows[best].length;
    }
  }
  for (final row in rows) {
    row.sort((a, b) => a.left.compareTo(b.left));
  }
  return rows;
}

List<_TextGroup> _groupsForRow(List<OcrLine> row, double pageWidth) {
  if (row.isEmpty) return const [];
  // Camera photos are ~3500 px wide and fixtures ~900, so an absolute pixel cap
  // can't serve both. Text height scales with resolution, and a column gap is
  // always wider than ~1.2 line heights while word spaces are far narrower.
  final heights = [for (final piece in row) (piece.bottom - piece.top).abs()]
    ..sort();
  final rowHeight = heights[heights.length ~/ 2].clamp(1.0, double.infinity);
  final gapLimit = (rowHeight * 1.2).clamp(10.0, pageWidth * 0.06);
  final grouped = <List<OcrLine>>[];
  for (final piece in row) {
    if (grouped.isEmpty || piece.left - grouped.last.last.right > gapLimit) {
      grouped.add([piece]);
    } else {
      grouped.last.add(piece);
    }
  }
  return [
    for (final group in grouped)
      _TextGroup(
        group,
        group.map((piece) => piece.text).join(' '),
        group.first.left,
        group.last.right,
      ),
  ];
}

_TableHeader? _findTableHeader(
  List<List<OcrLine>> rows,
  List<List<_TextGroup>> groups,
) {
  for (var rowIndex = 0; rowIndex < groups.length; rowIndex++) {
    final combined = groups[rowIndex].map((g) => g.text).join(' ');
    if (!_itemHeaderRe.hasMatch(combined) ||
        !_amountHeaderRe.hasMatch(combined)) {
      continue;
    }
    final itemX = _matchCenter(rows[rowIndex], _itemHeaderRe);
    final amountX = _matchCenter(
      rows[rowIndex],
      _amountHeaderRe,
      last: true,
      rightEdge: true,
    );
    if (itemX != null && amountX != null && amountX > itemX) {
      return _TableHeader(row: rowIndex, itemX: itemX, amountX: amountX);
    }
  }
  return null;
}

double? _matchCenter(
  List<OcrLine> row,
  RegExp expression, {
  bool last = false,
  bool rightEdge = false,
}) {
  final matches = <double>[];
  for (final piece in row) {
    for (final match in expression.allMatches(piece.text)) {
      final width = piece.right - piece.left;
      final centerOffset = (match.start + match.end) / 2;
      matches.add(
        rightEdge
            ? piece.right
            : piece.text.isEmpty
            ? (piece.left + piece.right) / 2
            : piece.left + width * (centerOffset / piece.text.length),
      );
    }
  }
  if (matches.isEmpty) return null;
  return last ? matches.last : matches.first;
}

List<_MoneyToken> _moneyTokens(List<List<OcrLine>> rows) {
  final tokens = <_MoneyToken>[];
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    for (var pieceIndex = 0; pieceIndex < rows[rowIndex].length; pieceIndex++) {
      final piece = rows[rowIndex][pieceIndex];
      final width = piece.right - piece.left;
      for (final match in _moneyRe.allMatches(piece.text)) {
        final x = piece.text.isEmpty
            ? piece.right
            : piece.left + width * (match.end / piece.text.length);
        tokens.add(_MoneyToken(rowIndex, pieceIndex, match.group(0)!, x));
      }
    }
  }
  return tokens;
}

Set<_MoneyToken> _amountColumnTokens(
  List<_MoneyToken> tokens, {
  required double pageWidth,
  double? headerX,
}) {
  final gap = (pageWidth * 0.055).clamp(12.0, double.infinity);
  final sorted = [...tokens]..sort((a, b) => a.x.compareTo(b.x));
  final clusters = <List<_MoneyToken>>[];
  for (final token in sorted) {
    if (clusters.isEmpty || token.x - clusters.last.last.x > gap) {
      clusters.add([token]);
    } else {
      clusters.last.add(token);
    }
  }

  List<_MoneyToken> selected;
  if (headerX != null) {
    selected = clusters.reduce((a, b) {
      double center(List<_MoneyToken> c) =>
          c.map((token) => token.x).reduce((x, y) => x + y) / c.length;
      return (center(a) - headerX).abs() <= (center(b) - headerX).abs() ? a : b;
    });
  } else {
    selected = clusters.lastWhere(
      (cluster) => cluster.length >= 2,
      orElse: () => clusters.last,
    );
  }
  return selected.toSet();
}

int? _firstSummaryRow(List<List<_TextGroup>> groups, {required int after}) {
  for (var i = after + 1; i < groups.length; i++) {
    if (groups[i].any((group) => _summaryClass(group.text) != null)) return i;
  }
  return null;
}

String? _itemLabel(
  List<_TextGroup> groups, {
  required double amountX,
  double? preferredX,
}) {
  final candidates = <_TextGroup>[];
  for (final group in groups) {
    if (group.center >= amountX) continue;
    final clean = _cleanItemLabel(group.text);
    if (clean == null || !isPlausibleReceiptItemLabel(clean)) continue;
    if (_otherHeaderRe.hasMatch(clean)) continue;
    candidates.add(_TextGroup(group.pieces, clean, group.left, group.right));
  }
  if (candidates.isEmpty) return null;
  if (preferredX != null) {
    candidates.sort(
      (a, b) => (a.center - preferredX).abs().compareTo(
        (b.center - preferredX).abs(),
      ),
    );
  } else {
    candidates.sort((a, b) => a.left.compareTo(b.left));
  }
  return candidates.first.text;
}

String? _cleanItemLabel(String raw) {
  var value = _clean(raw).replaceFirst(RegExp(r'^\d+[\s.)]+'), '');
  value = _clean(
    value.replaceAllMapped(
      _codeTokenRe,
      (match) => _doseTokenRe.hasMatch(match.group(0)!) ? match.group(0)! : '',
    ),
  );
  if (value.isEmpty) return null;
  return value.length <= 80 ? value : '${value.substring(0, 77)}…';
}

/// Public because the cloud validator and merge path use the exact same
/// administrative/noise policy as the geometry parser.
bool isPlausibleReceiptItemLabel(String label) {
  final clean = _clean(label);
  if (clean.length < 3 || clean.length > 80) return false;
  if (_summaryClass(clean) != null ||
      _ignoredSummaryRe.hasMatch(clean) ||
      _administrativeRe.hasMatch(clean) ||
      _otherHeaderRe.hasMatch(clean)) {
    return false;
  }
  final letters = clean.replaceAll(RegExp(r'[^A-Za-z]'), '');
  final digits = clean.replaceAll(RegExp(r'[^0-9]'), '');
  return letters.length >= 3 && digits.length <= letters.length;
}

List<DocumentResult> _shapeReceiptRows(
  List<_BillRow> parsed, {
  required String pageText,
}) {
  if (parsed.isEmpty) return const [];
  final totals = parsed.where((row) => row.kind == _RowClass.total).toList();
  _BillRow? finalAmount;
  if (totals.isNotEmpty) {
    totals.sort((a, b) {
      final score = _totalPriority(a.label).compareTo(_totalPriority(b.label));
      return score != 0 ? score : a.order.compareTo(b.order);
    });
    finalAmount = totals.last;
  } else {
    final subtotals = parsed
        .where((row) => row.kind == _RowClass.subtotal)
        .toList();
    if (subtotals.isNotEmpty) finalAmount = subtotals.last;
  }
  final finalValue = finalAmount == null
      ? null
      : _amountValue(finalAmount.amountText);
  final symbol = _inrContextRe.hasMatch(pageText) ? '₹' : '';

  String money(String raw) {
    final value = raw.trim();
    return RegExp(r'^[\d,.]').hasMatch(value) ? '$symbol$value' : value;
  }

  final output = <DocumentResult>[];
  final seen = <String>{};
  void emit(String label, String amount) {
    final key = '${_normalLabel(label)}|${_normalAmount(amount)}';
    if (seen.add(key)) output.add(DocumentResult(label, money(amount)));
  }

  for (final row in parsed.where((row) => row.kind == _RowClass.item)) {
    emit(row.label, row.amountText);
  }
  for (final row in parsed.where((row) => row.kind == _RowClass.subtotal)) {
    if (identical(row, finalAmount) ||
        (finalValue != null && _amountValue(row.amountText) == finalValue)) {
      continue;
    }
    emit(_canonicalSummaryLabel(row.label, row.kind), row.amountText);
  }
  for (final row in parsed.where(
    (row) => row.kind == _RowClass.discount || row.kind == _RowClass.tax,
  )) {
    emit(_canonicalSummaryLabel(row.label, row.kind), row.amountText);
  }
  if (finalAmount != null) emit('Final amount', finalAmount.amountText);
  return output;
}

int _totalPriority(String label) {
  final clean = _clean(label).toLowerCase();
  if (clean.startsWith('net') ||
      clean.startsWith('grand total') ||
      clean.startsWith('final')) {
    return 4;
  }
  if (clean.startsWith('amount payable') ||
      clean.startsWith('total bill amount')) {
    return 3;
  }
  if (clean.startsWith('total') || clean.startsWith('bill amount')) return 2;
  return 1;
}

String _canonicalSummaryLabel(String label, _RowClass kind) => switch (kind) {
  _RowClass.tax => _clean(label),
  _RowClass.discount => _clean(label),
  _RowClass.subtotal => _clean(label),
  _ => _clean(label),
};

double? _amountValue(String value) =>
    double.tryParse(value.replaceAll(RegExp(r'[^\d.]'), ''));

String _normalAmount(String value) => value.replaceAll(RegExp(r'[^\d.]'), '');

String _normalLabel(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

String _clean(String value) => value
    .replaceAll(RegExp(r'[\s:\-–—.`*]+$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool hasMoneyToken(String text) => _moneyRe.hasMatch(text);

bool isReceiptSummaryLabel(String label) {
  final clean = _clean(label);
  return clean.toLowerCase() == 'final amount' || _summaryClass(clean) != null;
}

bool isFinalReceiptAmountLabel(String label) {
  final clean = _clean(label);
  return clean.toLowerCase() == 'final amount' ||
      _summaryClass(clean) == _RowClass.total;
}
