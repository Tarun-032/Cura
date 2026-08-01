import '../library/document.dart';

/// Narrative laboratory reports have clinical prose rather than a value table.
/// They remain `Lab report` for browsing/search, but use the Summary data shape.
final _narrativeLab = RegExp(
  r'\bhistopatholog|\bhistolog(?:y|ical)|\bcytopatholog|\bcytolog(?:y|ical)|'
  r'\bsurgical\s+patholog|\bbiopsy\s+report|\bmicroscopic\s+description|'
  r'\bmacroscopic\s+description',
  caseSensitive: false,
);

bool isNarrativeLabText(String text) => _narrativeLab.hasMatch(text);

/// Whether a document shows a narrative Summary instead of editable result rows.
/// Unlike [DocumentType.isSummaryShaped] this reads the actual OCR, so pathology
/// isn't forced into a numeric lab table.
///
/// Never keys on the row count, or the screen would flip shape mid-edit.
bool isSummaryDocument(DocumentType type, String extractedText) =>
    type.isSummaryShaped ||
    (type == DocumentType.lab && isNarrativeLabText(extractedText));

/// A header or method field, never a test result: *every* word is a header
/// word, so "Sex Hormone Binding Globulin" survives and "Age / Gender" does not.
bool isIdentityFieldLabel(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return true;
  // "(Serum, Chemiluminescence Immunoassay)" prints under the test name.
  if (trimmed.startsWith('(')) return true;
  if (_bareUnitRe.hasMatch(trimmed)) return true;
  final all = trimmed
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), ' ')
      .trim()
      .split(' ')
      .where((word) => word.isNotEmpty)
      .toList();
  if (all.isEmpty) return true;
  // All-letters is a dotted acronym (S.G.P.T), judged on what they spell.
  final words = all.where((word) => word.length > 1).toList();
  if (words.isEmpty) return _headerWords.contains(all.join());
  return words.every(_headerWords.contains);
}

/// Slashed units and "%" only, so T3/TSH/Na are never caught.
final _bareUnitRe = RegExp(
  r'^\s*(?:%|10\^?\d\s*/\s*[a-zµu]{1,3}|[a-zµ]{1,6}\s*/\s*[a-z]{1,6})\s*$',
  caseSensitive: false,
);

/// A test name always has at least one word from outside this set. Specimen and
/// assay words are here so a method sub-line is not a row, but a name that only
/// ends in one ("Mumps virus IgG antibody, Serum") still is.
const _headerWords = {
  'accession', 'adm', 'address', 'age', 'at', 'barcode', 'bed', 'bill',
  'birth', 'by', 'checked', 'chemiluminescence', 'clia', 'clinician', 'cmia',
  'code', 'collected', 'consultant', 'contact', 'date', 'dob', 'doctor', 'dt',
  'dttm', 'dtm', 'eclia', 'edta', 'electrochemiluminescence', 'elisa', 'ex',
  'fluid', 'gender', 'id',
  'ilrn', 'immunoassay', 'ip', 'lab', 'location', 'method', 'methodology',
  'mobile', 'mrn', 'name', 'no', 'nos', 'number', 'of', 'on', 'op', 'order',
  'page', 'passport', 'patient', 'phone', 'physician', 'pid', 'pin', 'plasma',
  'printed', 'recd', 'received', 'ref', 'referred', 'reg', 'regd', 'regn',
  'registration', 'released', 'report', 'reported', 'result', 'results', 'rpt',
  'sample', 'serum', 'sex', 'sin', 'specimen', 'status', 'test', 'time', 'type',
  'uhid', 'vid', 'ward',
};

/// Whether refinement may replace [current] with the type it read. The cloud
/// sometimes calls a narrative report a plain lab table, which would swap the
/// Summary for an empty result table, so a report with a summary keeps its shape.
bool acceptsRefinedType({
  required DocumentType current,
  required DocumentType next,
  required String extractedText,
  required bool hasSummary,
}) =>
    !hasSummary ||
    !isSummaryDocument(current, extractedText) ||
    isSummaryDocument(next, extractedText);
