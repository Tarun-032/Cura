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
bool isSummaryDocument(DocumentType type, String extractedText) =>
    type.isSummaryShaped ||
    (type == DocumentType.lab && isNarrativeLabText(extractedText));

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
