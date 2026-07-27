import 'dart:convert';

import '../library/document.dart';
import 'document_shape.dart';
import 'receipt_parser.dart' show hasMoneyToken, isPlausibleReceiptItemLabel;

/// A review-screen field an in-flight model request may still update. The set is
/// fixed before generation starts, so the UI never infers progress from a
/// half-streamed JSON object. Summary is absent: scan summaries are deterministic.
enum ScanRefinementField { title, type, date, results, receiptNote }

/// One cancellable background refinement plus the exact fields it may change, so
/// Review can status each affected field and refuse any unexpected JSON key.
class ScanRefinementJob {
  factory ScanRefinementJob({
    required Set<ScanRefinementField> fields,
    required Future<ScanExtraction?> result,
    required void Function() onCancel,
  }) => ScanRefinementJob._(Set.unmodifiable(fields), result, onCancel);

  ScanRefinementJob._(this.fields, this.result, this._onCancel);

  final Set<ScanRefinementField> fields;
  final Future<ScanExtraction?> result;
  final void Function() _onCancel;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel();
  }
}

/// The fields a refinement pass proposes for a scanned document. All optional:
/// the model fills what it is confident about and Review patches only what the
/// user hasn't edited. Pure, so the validation is unit-testable.
class ScanExtraction {
  const ScanExtraction({
    this.title,
    this.type,
    this.date,
    this.results = const [],
    this.note,
    this.verifiedTableRepair = false,
  });

  final String? title;
  final DocumentType? type;
  final DateTime? date;
  final List<DocumentResult> results;
  final String? note;

  /// True only when proposed lab rows passed bounded, same-row OCR evidence
  /// validation on the device. JSON parsing alone can never set this flag.
  final bool verifiedTableRepair;

  bool get isEmpty =>
      title == null &&
      type == null &&
      date == null &&
      results.isEmpty &&
      (note == null || note!.isEmpty);

  /// Drops provider output that was not part of the declared refinement job.
  /// Prompt instructions are useful guidance, but this allowlist is the actual
  /// enforcement boundary.
  ScanExtraction only(Set<ScanRefinementField> fields) => ScanExtraction(
    title: fields.contains(ScanRefinementField.title) ? title : null,
    type: fields.contains(ScanRefinementField.type) ? type : null,
    date: fields.contains(ScanRefinementField.date) ? date : null,
    results: fields.contains(ScanRefinementField.results) ? results : const [],
    note: fields.contains(ScanRefinementField.receiptNote) ? note : null,
    verifiedTableRepair:
        fields.contains(ScanRefinementField.results) && verifiedTableRepair,
  );
}

/// The bounded OCR payload for when scan extraction falls through to an LLM.
/// Long serology pages are mostly bibliography, which crowds the investigation
/// labels out of a small context, so a page with composite observed cells keeps
/// only compact windows around each real row. Other shapes keep the broader
/// selector, since their narrative is the clinical content.
String selectScanOcrForExtraction(
  String text, {
  required DocumentType type,
  int maxChars = 3500,
}) {
  final lines = text.split('\n');
  if (lines.isEmpty) return text;
  final strongRows = <int>[
    for (var i = 0; i < lines.length; i++)
      if (_compositeObservedValue.hasMatch(lines[i])) i,
  ];
  if (type == DocumentType.lab && strongRows.isNotEmpty) {
    final selected = <int>{};
    // Keep the pre-table header, but not a blind first 14 lines: on a
    // one-row-per-section report those are already Interpretation prose.
    final headerEnd = strongRows.first < 14 ? strongRows.first : 14;
    for (var i = 0; i < lines.length && i < headerEnd; i++) {
      selected.add(i);
    }
    for (final row in strongRows) {
      // The investigation label is commonly one OCR line above the observed
      // cell; categorical ranges occupy the following two or three lines.
      for (var i = row - 1; i <= row + 3; i++) {
        if (i >= 0 && i < lines.length) selected.add(i);
      }
    }
    for (var i = 0; i < lines.length; i++) {
      if (_scanMetadataLine.hasMatch(lines[i])) selected.add(i);
    }
    final ordered = selected.toList()..sort();
    final out = StringBuffer();
    for (final index in ordered) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      final separator = out.isEmpty ? '' : '\n';
      if (out.length + separator.length + line.length > maxChars) continue;
      out.write(separator);
      out.write(line);
    }
    if (out.isNotEmpty) return out.toString();
  }

  if (text.length <= maxChars) return text;
  final keep = <String>[];
  var length = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final isHeader = i < 14;
    final isSignal = _generalExtractionSignal.hasMatch(line);
    if (!isHeader && !isSignal) continue;
    final added = line.length + (keep.isEmpty ? 0 : 1);
    if (length + added > maxChars) break;
    keep.add(line);
    length += added;
  }
  final out = keep.join('\n');
  return out.length <= maxChars ? out : out.substring(0, maxChars);
}

final _compositeObservedValue = RegExp(
  r'\b(?:not\s+detected|non[\s-]?reactive|reactive|positive|negative|'
  r'equivocal|borderline|posltive)\s*[,;:]?\s*[<>]?\d',
  caseSensitive: false,
);

final _scanMetadataLine = RegExp(
  r'\b(?:medical\s+laboratory\s+report|printed\s+on|reprinted\s+on|'
  r'reported\s+on|report\s+date)\b',
  caseSensitive: false,
);

final _generalExtractionSignal = RegExp(
  r'\d|not detected|detected|positive|negative|reactive|normal|abnormal|'
  r'present|absent|reported|collected|received|printed|'
  r'diagnosis|procedure|hospital\s*course|discharge|treatment|complaint|'
  r'operative|surgery|impression|findings?|indication|specimen|macroscopic|'
  r'microscopic|histopatholog|cytolog|biopsy',
  caseSensitive: false,
);

/// Parses and validates a model's JSON against the OCR text it was read from.
/// Null when the output isn't usable; never throws.
///
/// This is where "numbers never come from a model" is enforced: a value is kept
/// only when its exact text, or every number in it, appears in the OCR. Dates
/// need [parseDate] to read them and their digits to be present.
///
/// [parseDate] is injected so this stays pure and free of the scan service.
ScanExtraction? parseScanExtraction(
  String raw,
  String ocrText, {
  DateTime? Function(String)? parseDate,
}) {
  final completeJson = firstCompleteJsonObject(raw);
  if (completeJson == null) return null;
  final obj = jsonDecode(completeJson) as Map<String, dynamic>;

  final normOcr = _normSpaced(ocrText);
  final normDigits = _digitsOnly(ocrText);

  var title = _asString(obj['title'])?.trim();
  if (title != null &&
      (title.isEmpty || title.length > 80 || _refusalRe.hasMatch(title))) {
    title = null;
  }
  // Titles are grounded like values, or a sparse payload turns a pharmacy
  // invoice into "COMPREHENSIVE METABOLIC PANEL". The 60% bar tolerates OCR
  // typos while a real copied heading always passes.
  if (title != null && !_titleGrounded(ocrText.toLowerCase(), title)) {
    title = null;
  }

  final type = _asType(obj['type']);

  DateTime? date;
  final dateStr = _asString(obj['date']);
  if (dateStr != null && parseDate != null) {
    final d = parseDate(dateStr);
    // Only trust a parsed date whose year actually appears in the OCR text, so
    // the model can't hand back today's date or one it made up.
    if (d != null && normDigits.contains('${d.year}')) date = d;
  }

  final results = <DocumentResult>[];
  final rawResults = obj['results'];
  if (rawResults is List) {
    for (final r in rawResults) {
      if (r is! Map) continue;
      final label = _asString(r['label'])?.trim();
      final value = _asString(r['value'])?.trim();
      if (label == null || value == null || label.isEmpty || value.isEmpty) {
        continue;
      }
      if (!_valueGrounded(normOcr, normDigits, value)) {
        continue; // anti-hallucination
      }
      // A medicine row needs both halves printed. Numeric-only grounding is too
      // weak: it would let a real dose pair with an invented medicine.
      if (type == DocumentType.prescription &&
          (!_phraseGrounded(normOcr, label) ||
              !_phraseGrounded(normOcr, value))) {
        continue;
      }
      // A bill breakdown is geometry-only, so the model may not propose rows.
      // The prompt asks for results: [] on receipts; this enforces it.
      if (type == DocumentType.receipt) continue;
      final range = _asString(r['range'])?.trim();
      final unit = _asString(r['unit'])?.trim();
      results.add(
        DocumentResult(
          label,
          value,
          unit: (unit == null || unit.isEmpty) ? null : unit,
          range: (range == null || range.isEmpty) ? null : range,
        ),
      );
    }
  }

  var note = _asString(obj['note'])?.trim();
  if (note != null && note.isEmpty) note = null;
  // A prescription summary may rephrase the page, but every number in it must
  // occur in the OCR. Drop the summary rather than show an invented dose.
  if (type == DocumentType.prescription &&
      note != null &&
      !numbersGrounded(ocrText, note)) {
    note = null;
  }

  final ext = ScanExtraction(
    title: title,
    type: type,
    date: date,
    results: results,
    note: note,
  );
  if (ext.isEmpty) return null;
  return enforceScanShape(ext, ocrText: ocrText);
}

/// Shape rules so narrative reports never keep vitals as Results rows. Imaging
/// and discharge drop [results] and keep [note]; the rest keep grounded results.
ScanExtraction enforceScanShape(ScanExtraction ext, {String ocrText = ''}) {
  var type = ext.type;
  if (type == null) return ext;
  // Histopathology/cytology/biopsy is narrative laboratory medicine, not
  // radiology. Correct the model's occasional Imaging guess deterministically.
  if (isNarrativeLabText(ocrText)) type = DocumentType.lab;
  if (isSummaryDocument(type, ocrText)) {
    return ScanExtraction(
      title: ext.title,
      type: type,
      date: ext.date,
      results: const [],
      note: ext.note,
      verifiedTableRepair: ext.verifiedTableRepair,
    );
  }
  if (type != ext.type) {
    return ScanExtraction(
      title: ext.title,
      type: type,
      date: ext.date,
      results: ext.results,
      note: ext.note,
      verifiedTableRepair: ext.verifiedTableRepair,
    );
  }
  return ext;
}

/// Geometry-parsed lab rows are complete and spatially grounded, so a model,
/// which has no column geometry, may never replace or append to them.
List<DocumentResult> mergeRefinedResults({
  required DocumentType type,
  required List<DocumentResult> deterministic,
  required List<DocumentResult> refined,
  bool verifiedTableRepair = false,
}) {
  if (type == DocumentType.lab) {
    if (!verifiedTableRepair || refined.isEmpty) return deterministic;
    final remaining = [...refined];
    final merged = <DocumentResult>[];
    for (final local in deterministic) {
      final index = remaining.indexWhere(
        (remote) => _resultLabelsEquivalent(remote.label, local.label),
      );
      if (index < 0) {
        merged.add(local);
      } else {
        merged.add(remaining.removeAt(index));
      }
    }
    // Rows missed by every deterministic full-page pass but recovered from a
    // tile are appended rather than forcing a whole-table replacement.
    merged.addAll(remaining);
    return merged;
  }
  // Receipts: the breakdown is deterministic-only; the model contributes
  // title/date/note but never rows.
  if (type == DocumentType.receipt) return deterministic;
  return refined.isNotEmpty ? refined : deterministic;
}

String _resultLabelKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

bool _resultLabelsEquivalent(String a, String b) {
  final ak = _resultLabelKey(a);
  final bk = _resultLabelKey(b);
  if (ak == bk) return true;
  final shorter = ak.length <= bk.length ? ak : bk;
  final longer = ak.length <= bk.length ? bk : ak;
  // OCR can append a value or parenthetical to a short acronym label, so a
  // verified cell mapping replaces the malformed draft instead of duplicating
  // the row. Tiny prefixes like T3/T4 are excluded.
  return shorter.length >= 4 && longer.startsWith(shorter);
}

/// A value is grounded when its words appear in the OCR, and a textual value
/// must appear un-negated so "Not Detected" can never become "Detected". Numeric
/// values need every digit-run present, tolerating unit reformatting.
bool _valueGrounded(String normOcr, String normDigits, String value) {
  final digits = RegExp(
    r'\d+',
  ).allMatches(value).map((m) => m.group(0)!).toList();
  if (digits.isNotEmpty) return digits.every(normDigits.contains);

  final v = _normSpaced(value).trim();
  if (v.isEmpty) return false;
  final phrase = RegExp(r'(?:^|\s)' + RegExp.escape(v) + r'(?:\s|$)');
  if (!phrase.hasMatch(normOcr)) return false;
  // Strip negated occurrences, then require a clean (un-negated) one to remain.
  final negated = RegExp(
    r'(?:^|\s)(?:not|non|no)\s+' + RegExp.escape(v) + r'(?:\s|$)',
  );
  return phrase.hasMatch(normOcr.replaceAll(negated, ' '));
}

bool _phraseGrounded(String normOcr, String value) {
  final phrase = _normSpaced(value);
  return phrase.trim().isNotEmpty && normOcr.contains(phrase);
}

/// True when every number in [value] also appears in [ocrText]. A model may
/// rephrase, never renumber.
bool numbersGrounded(String ocrText, String value) {
  final source = RegExp(
    r'\d+',
  ).allMatches(ocrText).map((match) => match.group(0)!).toSet();
  final proposed = RegExp(
    r'\d+',
  ).allMatches(value).map((match) => match.group(0)!);
  return proposed.every(source.contains);
}

/// OCR selection for on-device bill refinement: the top of the page plus every
/// money or billing line. Unredacted, since nothing leaves the phone here, but
/// filtered to keep the prefill small.
String selectBillOcrForExtraction(String text, {int maxChars = 2400}) {
  final billWord = RegExp(
    r'sub\s*-?\s*total|\btotal\b|\bnet\b|\bgross\b|\bgst\b|\btax\b|discount|'
    r'\bamount\b|\bqty\b|\bmrp\b|\brate\b|\bitem\b|product|service|'
    r'particulars|consult|charge|\bpaid\b|payment|balance|payable|\bbill\b|'
    r'invoice|receipt',
    caseSensitive: false,
  );
  final lines = text.split('\n');
  final kept = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    // A standalone service description carries neither money nor a billing
    // word, but without it the model can't say what the bill was for.
    if (i < 8 ||
        hasMoneyToken(line) ||
        billWord.hasMatch(line) ||
        isPlausibleReceiptItemLabel(line)) {
      kept.add(line);
    }
  }
  final out = kept.join('\n');
  return out.length <= maxChars ? out : out.substring(0, maxChars);
}

/// A title is grounded when most of its ≥3-letter words appear in the OCR.
/// Abbreviation-only titles have nothing to check and pass.
bool _titleGrounded(String lowerOcr, String title) {
  final tokens = RegExp(
    r'[a-z]{3,}',
  ).allMatches(title.toLowerCase()).map((m) => m.group(0)!).toList();
  if (tokens.isEmpty) return true;
  final hits = tokens.where(lowerOcr.contains).length;
  return hits / tokens.length >= 0.6;
}

/// Lowercased, non-alphanumerics collapsed to single spaces (padded), so word
/// boundaries survive: "Not Detected." → " not detected ".
String _normSpaced(String s) =>
    ' ${s.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), ' ').trim()} ';

String _digitsOnly(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

/// Refusal / boilerplate a title must never be.
final _refusalRe = RegExp(
  r"i (can't|cannot|'m sorry)|as an ai|unknown|not (sure|found)|n/a",
  caseSensitive: false,
);

/// True when the model apologised or hedged instead of answering.
bool looksLikeModelRefusal(String value) => _refusalRe.hasMatch(value);

String? _asString(Object? v) => v is String ? v : (v == null ? null : '$v');

DocumentType? _asType(Object? v) {
  final s = _asString(v)?.toLowerCase().trim();
  switch (s) {
    case 'lab':
    case 'lab report':
      return DocumentType.lab;
    case 'prescription':
      return DocumentType.prescription;
    case 'receipt':
    case 'bill':
    case 'invoice':
    case 'cash bill':
    case 'tax invoice':
    case 'bill/invoice':
      return DocumentType.receipt;
    case 'discharge':
    case 'discharge summary':
      return DocumentType.discharge;
    case 'imaging':
    case 'scan':
    case 'radiology':
      return DocumentType.imaging;
    default:
      return null;
  }
}

/// Pulls the first complete, valid JSON object out of model output, tolerating
/// code fences and chatter around it. Returning the object text lets a streaming
/// caller stop early instead of waiting for trailing prose. Null until the object
/// is both closed and valid.
String? firstCompleteJsonObject(String raw) {
  final start = raw.indexOf('{');
  if (start == -1) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < raw.length; i++) {
    final ch = raw[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        final candidate = raw.substring(start, i + 1);
        try {
          final decoded = jsonDecode(candidate);
          return decoded is Map ? candidate : null;
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null; // never closed (truncated output)
}
